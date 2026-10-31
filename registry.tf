resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = "${local.p}-images"
  format        = "DOCKER"
  description   = "Pipewright component images and the launcher image"
  labels        = local.labels

  # Untagged images only (FR-87): every image Pipewright pushes is tagged, so a release's images stay for rollback
  # and replay; `pipewright images prune` removes old releases' images, never one a release still needs.
  cleanup_policy_dry_run = false
  dynamic "cleanup_policies" {
    for_each = var.image_retention_days == null ? [] : [var.image_retention_days]
    content {
      id     = "delete-untagged"
      action = "DELETE"
      condition {
        tag_state  = "UNTAGGED"
        older_than = "${cleanup_policies.value * 86400}s"
      }
    }
  }

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
