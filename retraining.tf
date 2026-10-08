/**
 * Retrain decisions: drift opens a case, and approver groups decide.
 *
 * Each approver group is a Pub/Sub topic. Its members may publish to it, and a push subscription delivers what they
 * publish to the launcher's /retraining/decide: publish access is the membership check. Members also read cases.
 * Cloud Scheduler calls /retraining/tick hourly (snooze expiry, escalation) and weekly with a digest.
 */

locals {
  approver_members = merge([
    for g, v in var.approver_groups : { for i, m in v.members : "${g}|${i}" => { group = g, member = m } }
  ]...)
  case_readers = distinct(concat(
    [for v in values(local.approver_members) : v.member],
    flatten([for v in values(local.tenants) : v.members]),
  ))
}

resource "google_pubsub_topic" "approver" {
  for_each = var.approver_groups

  project = var.project_id
  name    = "${local.p}-approve-${each.key}"
  labels  = merge(local.labels, { "pipewright-approver-group" = each.key })
  # Decisions carry short-lived ID tokens: keep nothing for long.
  message_retention_duration = "600s"

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }

  depends_on = [google_project_service.this]
}

resource "google_pubsub_topic_iam_member" "approver" {
  for_each = local.approver_members

  project = var.project_id
  topic   = google_pubsub_topic.approver[each.value.group].name
  role    = "roles/pubsub.publisher"
  member  = each.value.member
}

resource "google_pubsub_subscription" "decide" {
  for_each = local.deployed ? var.approver_groups : {}

  project                    = var.project_id
  name                       = "${local.p}-approve-${each.key}-decide"
  topic                      = google_pubsub_topic.approver[each.key].id
  ack_deadline_seconds       = 300
  message_retention_duration = "600s"
  labels                     = local.labels

  push_config {
    push_endpoint = "${local.launcher_url}/retraining/decide"
    oidc_token {
      service_account_email = google_service_account.launcher.email
      audience              = local.launcher_url
    }
  }

  expiration_policy {
    ttl = ""
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "120s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.this["dead-letters"].id
    max_delivery_attempts = 5
  }

  depends_on = [google_cloud_run_v2_service_iam_member.invoker, google_service_account_iam_member.pubsub_token_creator]
}

resource "google_pubsub_subscription_iam_member" "decide_dead_letters" {
  for_each = google_pubsub_subscription.decide

  project      = var.project_id
  subscription = each.value.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${local.pubsub_agent}"
}

# Approvers and team members read cases (and the manifest) for `pipewright retrain show`.
resource "google_storage_bucket_iam_member" "case_reader" {
  for_each = toset(local.case_readers)

  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectViewer"
  member = each.value

  condition {
    title       = "pipewright-cases"
    description = "Retrain cases and the environment manifest"
    expression = join(" || ", [
      "resource.type == \"storage.googleapis.com/Bucket\"",
      "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/cases/\")",
      "resource.name == \"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/pipewright/environment.json\"",
    ])
  }
}

resource "google_cloud_scheduler_job" "retraining" {
  for_each = local.deployed ? {
    tick   = { schedule = "17 * * * *", body = "{}" }
    digest = { schedule = "0 8 * * 1", body = "{\"digest\": true}" }
  } : {}

  project          = var.project_id
  region           = var.region
  name             = "${local.launcher_name}-retraining-${each.key}"
  description      = "Pipewright retrain decisions: ${each.key}. Managed by Terraform."
  schedule         = each.value.schedule
  time_zone        = "Etc/UTC"
  attempt_deadline = "300s"

  http_target {
    http_method = "POST"
    uri         = "${local.launcher_url}/retraining/tick"
    body        = base64encode(each.value.body)
    headers     = { "Content-Type" = "application/json" }
    oidc_token {
      service_account_email = google_service_account.launcher.email
      audience              = local.launcher_url
    }
  }

  retry_config {
    retry_count = 2
  }

  depends_on = [google_cloud_run_v2_service_iam_member.invoker]
}
