/**
 * A/B tests of models (Pipewright FR-57), per tenant with `ab_test` in var.tenants. Off by default: nothing here is
 * created for a tenant without it.
 *
 *   exposures   the gateway writes one line per unit and call to Cloud Logging (log pipewright_ab_exposure, labelled
 *               with the tenant); a log sink per tenant copies them into the tenant's dataset (table
 *               pipewright_ab_exposure), which the analysis reads. Found in spike S4: all lines there within about
 *               five minutes, none lost or doubled.
 *   feed        (ab_test.feed) a topic per tenant for the team's own tools: Pipewright publishes the test's events
 *               (aggregates); with ab_test.feed_exposures, a second sink copies exposure lines that carry a keyed hash
 *               of the unit, never the unit (the key in Secret Manager, read only by the tenant's gateway).
 *   the gateway the tenant's lookup identity (the router-only gateway of a use case whose callers send features runs as
 *               it too): writes the lines, may predict, reads the feed key.
 *   analysis    the scheduled analysis runs as the tenant's runner in the tenant's job (the sync job).
 *   launcher    reads the gateway's lines (logging.viewer, granted for every environment: launcher_logs) and the arms'
 *               endpoints (monitoring.viewer), and keeps the test records (ab-tests/).
 *
 * Arm endpoints: where endpoints are Terraform's (serving.yaml), add `<usecase>-ab` beside `<usecase>`, with the same
 * tenant and privacy; Pipewright deploys the treatment there.
 *
 * Cost (list prices): log routing is free; BigQuery storage of the exposures (about 300 bytes a line: about 7 cents a
 * month per million lines kept); the feed $40 per TiB published (events are a few a day); the key $0.06 a month.
 */

locals {
  ab_tenants      = { for t, v in local.tenants : t => v.ab_test if v.ab_test != null }
  ab_feed         = { for t, v in local.ab_tenants : t => v if v.feed }
  ab_feed_expose  = { for t, v in local.ab_feed : t => v if v.feed_exposures }
  ab_feed_readers = merge([for t, v in local.ab_feed : { for m in v.feed_subscribers : "${t}|${m}" => { tenant = t, member = m } }]...)
  ab_any          = length(local.ab_tenants) > 0

  ab_tenant_manifest = {
    for t, v in local.ab_feed : t => {
      ab_test_feed = merge({ topic = google_pubsub_topic.ab_feed[t].id },
      v.feed_exposures ? { key_secret = google_secret_manager_secret.ab_feed_key[t].id } : {})
    }
  }
  # The platform's A/B rules (policies.ab_test), unset keys left out; an object of mixed types, so no conditional
  ab_rules = try({ for k, v in var.policies.ab_test : k => v if v != null }, {})
  ab_policies = { for k, v in {
    ab_test = merge(local.ab_rules, local.ab_any ? { feed_exposures = length(local.ab_feed_expose) > 0 } : {})
  } : k => v if local.ab_any || length(local.ab_rules) > 0 }
}

# ------------------------------------------------------------------------------------------ exposures --

resource "google_logging_project_sink" "ab_exposure" {
  for_each               = local.ab_tenants
  name                   = "${local.p}-ab-exposure-${each.key}"
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.tenant[each.key].dataset_id}"
  filter                 = "logName=\"projects/${var.project_id}/logs/pipewright_ab_exposure\" AND labels.\"pipewright-tenant\"=\"${each.key}\""
  unique_writer_identity = true
  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_bigquery_dataset_iam_member" "ab_exposure_sink" {
  for_each   = local.ab_tenants
  dataset_id = google_bigquery_dataset.tenant[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.ab_exposure[each.key].writer_identity
}

# ------------------------------------------------------------------------------------------- the feed --

resource "google_pubsub_topic" "ab_feed" {
  for_each = local.ab_feed
  project  = var.project_id
  name     = "${local.p}-ab-feed-${each.key}"
  labels   = merge(local.labels, { "pipewright-tenant" = each.key })
  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }
  depends_on = [google_project_service.this]
}

# Pipewright publishes the events: the launcher (decisions, the tick) and the people who run `pipewright ab`.
resource "google_pubsub_topic_iam_member" "ab_feed_publishers" {
  for_each = merge(
    { for t in keys(local.ab_feed) : "${t}|launcher" => { tenant = t, member = "serviceAccount:${google_service_account.launcher.email}" } },
    merge([for t in keys(local.ab_feed) : { for i, m in local.tenants[t].members : "${t}|m${i}" => { tenant = t, member = m } }]...),
    merge([for t in keys(local.ab_feed) : { for i, m in local.operators : "${t}|o${i}" => { tenant = t, member = m } }]...)
  )
  topic  = google_pubsub_topic.ab_feed[each.value.tenant].id
  role   = "roles/pubsub.publisher"
  member = each.value.member
}

# The team's tools attach their own subscriptions (subscriber includes attaching one).
resource "google_pubsub_topic_iam_member" "ab_feed_subscribers" {
  for_each = local.ab_feed_readers
  topic    = google_pubsub_topic.ab_feed[each.value.tenant].id
  role     = "roles/pubsub.subscriber"
  member   = each.value.member
}

resource "google_logging_project_sink" "ab_feed" {
  for_each               = local.ab_feed_expose
  name                   = "${local.p}-ab-feed-${each.key}"
  destination            = "pubsub.googleapis.com/${google_pubsub_topic.ab_feed[each.key].id}"
  filter                 = "logName=\"projects/${var.project_id}/logs/pipewright_ab_feed\" AND labels.\"pipewright-tenant\"=\"${each.key}\""
  unique_writer_identity = true
}

resource "google_pubsub_topic_iam_member" "ab_feed_sink" {
  for_each = local.ab_feed_expose
  topic    = google_pubsub_topic.ab_feed[each.key].id
  role     = "roles/pubsub.publisher"
  member   = google_logging_project_sink.ab_feed[each.key].writer_identity
}

resource "google_project_service" "ab_secrets" {
  count              = length(local.ab_feed_expose) > 0 ? 1 : 0
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_secret_manager_secret" "ab_feed_key" {
  for_each  = local.ab_feed_expose
  secret_id = "${local.p}-ab-feed-key-${each.key}"
  labels    = merge(local.labels, { "pipewright-tenant" = each.key })
  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [google_project_service.ab_secrets]
}

# The key is made by the provider and kept in the state, as every secret made by Terraform is; rotate it by tainting
# the version (old feed lines then no longer join new ones: the team keys its own copy if it needs to).
resource "random_bytes" "ab_feed_key" {
  for_each = local.ab_feed_expose
  length   = 32
}

resource "google_secret_manager_secret_version" "ab_feed_key" {
  for_each    = local.ab_feed_expose
  secret      = google_secret_manager_secret.ab_feed_key[each.key].id
  secret_data = random_bytes.ab_feed_key[each.key].base64
}

resource "google_secret_manager_secret_iam_member" "ab_feed_key" {
  for_each  = local.ab_feed_expose
  secret_id = google_secret_manager_secret.ab_feed_key[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.lookup[each.key].email}"
}

# ------------------------------------------------------------------------------------------ identities --

resource "google_project_iam_member" "ab_gateway_logs" {
  for_each = local.ab_tenants
  project  = var.project_id
  role     = "roles/logging.logWriter"
  member   = "serviceAccount:${google_service_account.lookup[each.key].email}"
}

resource "google_project_iam_member" "launcher_ab" {
  for_each = local.ab_any ? toset(["roles/monitoring.viewer"]) : toset([])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.launcher.email}"
}

# The launcher reads the project's logs for every environment now (Pipewright FR-124): its tick checks that each
# approved training run registered its model, from the runs' events. It was granted only with A/B tests before.
resource "google_project_iam_member" "launcher_logs" {
  project = var.project_id
  role    = "roles/logging.viewer"
  member  = "serviceAccount:${google_service_account.launcher.email}"
}

moved {
  from = google_project_iam_member.launcher_ab["roles/logging.viewer"]
  to   = google_project_iam_member.launcher_logs
}

resource "google_storage_bucket_iam_member" "launcher_ab_tests" {
  count  = local.ab_any ? 1 : 0
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.launcher.email}"
  condition {
    title       = "ab-tests"
    description = "Pipewright FR-57: the A/B test records (decisions, the tick's guardrails and results)"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/ab-tests/\")"
  }
}
