resource "google_project_service" "this" {
  for_each = toset([
    "aiplatform.googleapis.com", "artifactregistry.googleapis.com", "bigquery.googleapis.com",
    "bigquerystorage.googleapis.com", "cloudresourcemanager.googleapis.com", "cloudscheduler.googleapis.com",
    "iam.googleapis.com", "iamcredentials.googleapis.com", "logging.googleapis.com", "monitoring.googleapis.com",
    "pubsub.googleapis.com", "run.googleapis.com", "serviceusage.googleapis.com", "storage.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Service agents that act on the project's behalf: Pub/Sub (push tokens, dead letters), Agent Platform.
resource "google_project_service_identity" "this" {
  provider = google-beta
  for_each = toset(["pubsub.googleapis.com", "aiplatform.googleapis.com"])

  project = var.project_id
  service = each.value

  depends_on = [google_project_service.this]
}

data "google_storage_project_service_account" "this" {
  project    = var.project_id
  depends_on = [google_project_service.this]
}
