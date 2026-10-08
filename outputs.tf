output "manifest_uri" {
  description = "The environment manifest: put it in each MLOps repository's environments/<env>.yaml."
  value       = "gs://${google_storage_bucket.artifacts.name}/${google_storage_bucket_object.manifest.name}"
}

output "environment_file" {
  description = "Save as environments/<env>.yaml in an MLOps repository."
  value       = <<-EOT
    apiVersion: pipewright/v1
    kind: Environment
    metadata: { name: ${var.environment} }
    spec:
      manifest: gs://${google_storage_bucket.artifacts.name}/${google_storage_bucket_object.manifest.name}
  EOT
}

output "images_repository" {
  description = "Where scripts/publish_launcher.sh pushes the launcher image."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.name}"
}

output "launcher_url" {
  description = "The launcher's URL (IAM authenticated)."
  value       = local.launcher_url
}

output "launcher_deployed" {
  description = "false until launcher_image is set and applied."
  value       = local.deployed
}

output "landing_bucket" {
  description = "Drop files under gs://<this>/<landing_prefix> to start a tenant's runs; samples/<tenant>/ is readable by its runner."
  value       = google_storage_bucket.landing.name
}

output "tenants" {
  description = "Per tenant: runner service account, dataset and landing prefix."
  value       = local.manifest.tenants
}
