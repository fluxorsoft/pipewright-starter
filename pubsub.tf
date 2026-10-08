/**
 *   landing        GCS notifications from the landing bucket       -> launcher /pubsub
 *   run-requests   runs requested by `pipewright run` and pipelines -> launcher /pubsub/run
 *   events         Pipewright lifecycle events (for alerts, tools and your own apps)
 *   dead-letters   messages the launcher could not take after 5 attempts (pull them to inspect)
 */

resource "google_pubsub_topic" "this" {
  for_each = toset(["landing", "run-requests", "events", "dead-letters"])

  project = var.project_id
  name    = "${local.p}-${each.key}"
  labels  = local.labels

  # Publishes go through the region's endpoint; keeping storage in the region matches that.
  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }

  depends_on = [google_project_service.this]
}

resource "google_pubsub_subscription" "dead_letters" {
  project                    = var.project_id
  name                       = "${local.p}-dead-letters"
  topic                      = google_pubsub_topic.this["dead-letters"].id
  message_retention_duration = "604800s"
  labels                     = local.labels

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.this["dead-letters"].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.pubsub_agent}"

  depends_on = [google_project_service_identity.this]
}

# ---------------------------------------------------------------- landing notifications --

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.this["landing"].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.this.email_address}"
}

resource "google_storage_notification" "landing" {
  bucket             = google_storage_bucket.landing.name
  topic              = google_pubsub_topic.this["landing"].id
  payload_format     = "JSON_API_V1"
  event_types        = ["OBJECT_FINALIZE"]
  object_name_prefix = "incoming/"

  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# ---------------------------------------------------------------- publishers --

# Runners publish run requests (retrain proposals) and events; the launcher publishes events; tenant members may
# request runs with `pipewright run`.
resource "google_pubsub_topic_iam_member" "run_requests" {
  for_each = merge(local.runner_members,
  merge([for t, v in local.tenants : { for i, m in v.members : "${t}|${i}" => m }]...))

  project = var.project_id
  topic   = google_pubsub_topic.this["run-requests"].name
  role    = "roles/pubsub.publisher"
  member  = each.value
}

resource "google_pubsub_topic_iam_member" "events" {
  for_each = merge(local.runner_members, { launcher = "serviceAccount:${google_service_account.launcher.email}" })

  project = var.project_id
  topic   = google_pubsub_topic.this["events"].name
  role    = "roles/pubsub.publisher"
  member  = each.value
}
