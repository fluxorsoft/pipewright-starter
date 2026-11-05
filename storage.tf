# Artifacts: the environment manifest, release contracts and live pointers, pipeline roots, retrain cases.
resource "google_storage_bucket" "artifacts" {
  project                     = var.project_id
  name                        = local.buckets.artifacts
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy
  labels                      = local.labels

  versioning {
    enabled = true # release contracts are write-once; versioning keeps the pointers' history recoverable
  }

  # Pipewright phase 6 (FR-97): approvals lock the approved model files with object retention; only when a lock is
  # configured (policies.integrity.lock.days).
  enable_object_retention = local.integrity_lock

  depends_on = [google_project_service.this]
}

locals {
  integrity_lock = try(var.policies.integrity.lock.days, 0) > 0
}

# Landing: files dropped under a tenant's landing prefix start that tenant's runs.
resource "google_storage_bucket" "landing" {
  project                     = var.project_id
  name                        = local.buckets.landing
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy
  labels                      = local.labels

  lifecycle_rule {
    condition {
      age = var.landing_retention_days
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.this]
}
