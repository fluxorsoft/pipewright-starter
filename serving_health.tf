# Pipewright 1.4.3 (FR-98): serving health. Off by default (serving_health = false).
#
# On: one Cloud Monitoring notification channel per environment that publishes every incident of a use case's health
# policies (monitoring.health, kept by `pipewright alerts sync` and `deploy-model`) to a Pub/Sub topic; the launcher
# reads it (push to /incidents) and sends serving.degraded and serving.recovered on the events topic. Email stays one
# consumer of the events; every incident goes through Pub/Sub.
#
# Cost: Pub/Sub $40 per TiB (incidents are a few KB each); alert policies are not charged today (Google has announced
# charging from no sooner than 2027-09-01, $0.35 per metric referenced a month: about 4 to 6 conditions per deployed
# version).

variable "serving_health" {
  description = "Pipewright 1.4.3 (FR-98): the incident channel and topic for use cases' monitoring.health policies."
  type        = bool
  default     = false
}

variable "serving_policy" {
  description = "Pipewright 1.4.3 (FR-98), the platform's serving rules every use case is checked against (manifest policies.serving): capture {allowed, max_sample_rate, retention_days}, health_required (every serving use case has monitoring.health on), scale_to_zero (allowed or refused: refused stops any use case setting model.serving.scale_to_zero, an Agent Platform Preview that drops calls while it scales up). Null: no rules, as before. Cost: none."
  type = object({
    capture = optional(object({
      allowed         = optional(bool)
      max_sample_rate = optional(number)
      retention_days  = optional(number)
    }))
    health_required = optional(bool)
    scale_to_zero   = optional(string)
  })
  default = null
  validation {
    condition     = var.serving_policy == null || try(contains(["allowed", "refused"], var.serving_policy.scale_to_zero), true) || try(var.serving_policy.scale_to_zero == null, false)
    error_message = "serving_policy.scale_to_zero is allowed or refused."
  }
}

resource "google_pubsub_topic" "incidents" {
  count = var.serving_health ? 1 : 0

  project = var.project_id
  name    = "${local.p}-incidents"
  labels  = local.labels

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }

  depends_on = [google_project_service.this]
}

resource "google_monitoring_notification_channel" "incidents" {
  count = var.serving_health ? 1 : 0

  project      = var.project_id
  display_name = "pipewright ${var.environment}: serving incidents (Pub/Sub)"
  type         = "pubsub"
  labels       = { topic = google_pubsub_topic.incidents[0].id }
  user_labels  = { pipewright-managed = "true" }
}

# Cloud Monitoring's notification agent exists once the project has a channel (found in the FR-98 spike): granted after.
resource "google_pubsub_topic_iam_member" "incidents_publisher" {
  count = var.serving_health ? 1 : 0

  project = var.project_id
  topic   = google_pubsub_topic.incidents[0].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"

  depends_on = [google_monitoring_notification_channel.incidents]
}

# Capture coverage (FR-98, found in the GA QA): the launcher's hourly tick counts what capture recorded in the last hour
# (<usecase>_online_log) against what the endpoint served. It could read only the tables' metadata, so the count failed
# and coverage never ran. Read access is limited by an IAM condition to the capture tables: no other table of the
# tenant's dataset. Free (IAM); the count is one small query an hour per use case with capture on.
resource "google_bigquery_dataset_iam_member" "launcher_capture_reader" {
  for_each = var.serving_health ? local.tenants : {}

  project    = var.project_id
  dataset_id = google_bigquery_dataset.tenant[each.key].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.launcher.email}"

  condition {
    title       = "capture-tables-only"
    description = "Pipewright capture coverage: the <usecase>_online_log tables only"
    expression  = "resource.name.endsWith(\"_online_log\")"
  }
}
