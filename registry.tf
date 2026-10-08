resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = "${local.p}-images"
  format        = "DOCKER"
  description   = "Pipewright component images and the launcher image"
  labels        = local.labels

  depends_on = [google_project_service.this]
}

resource "google_artifact_registry_repository" "pipelines" {
  project       = var.project_id
  location      = var.region
  repository_id = "${local.p}-pipelines"
  format        = "KFP"
  description   = "Compiled pipeline templates"
  labels        = local.labels

  depends_on = [google_project_service.this]
}
