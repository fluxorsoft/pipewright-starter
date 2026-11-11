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
