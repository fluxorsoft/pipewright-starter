# Pipewright 1.4.3 (FR-100): a runner that cannot move a model's default. Off by default (policies.registration
# runner, as before 1.4.3).
#
# With policies.registration = "launcher":
#   runners     get <prefix>_runner: roles/aiplatform.user without aiplatform.models.upload, update and delete (built
#               from the predefined role at each apply, so it follows Google's changes). No role can stop an identity
#               that uploads from moving any model's default, so runners do not upload.
#   launcher    keeps roles/aiplatform.user: it registers each version after checking the run, its files and the gates
#               (the register step asks it). It answers in gs://<artifacts>/runs/registration/<tenant>/, which each
#               runner may read (its own tenant's only). For BigQuery ML it runs the registration (ALTER MODEL) itself:
#               model metadata on each tenant's dataset and BigQuery jobs.
#   operators   unchanged: approving, promoting and retiring are their decisions, recorded with who made them.
#
# Turn it on after every use case is released with Pipewright 1.4.3 or later: an older register step uploads
# directly and gets 403 (`pipewright validate` and `pipewright doctor` say which).
#
# Cost: none (one extra request to the launcher per training run; the launcher scales to zero).

locals {
  registration_launcher = try(var.policies.registration, "runner") == "launcher"
  runner_role           = local.registration_launcher ? google_project_iam_custom_role.runner[0].name : "roles/aiplatform.user"
}

data "google_iam_role" "aiplatform_user" {
  count = local.registration_launcher ? 1 : 0
  name  = "roles/aiplatform.user"
}

resource "google_project_iam_custom_role" "runner" {
  count = local.registration_launcher ? 1 : 0

  project     = var.project_id
  role_id     = "${replace(local.p, "-", "_")}_runner"
  title       = "Pipewright runner (${var.environment}): Agent Platform user without registry writes"
  description = "roles/aiplatform.user without aiplatform.models.upload, update and delete (Pipewright FR-100). Managed by Terraform."
  permissions = sort(setsubtract(data.google_iam_role.aiplatform_user[0].included_permissions, [
    "aiplatform.models.upload", "aiplatform.models.update", "aiplatform.models.delete",
  ]))
}

# The launcher's answer to each registration request, readable by the tenant's runner only. Needed where runners are
# kept to their own pipeline root (isolate_tenant_artifacts); otherwise the shared grant already covers it.
resource "google_storage_bucket_iam_member" "runner_registration_answers" {
  for_each = local.registration_launcher && var.isolate_tenant_artifacts ? local.tenants : {}

  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectViewer"
  member = local.runner_members[each.key]

  condition {
    title       = "registration-answers-${each.key}"
    description = "The launcher's registration answers for ${each.key}"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/runs/registration/${each.key}/\")"
  }
}

# BigQuery ML: the launcher runs ALTER MODEL ... SET OPTIONS (vertex_ai_model_id) itself, on model metadata only.
resource "google_project_iam_custom_role" "launcher_registrar" {
  count = local.registration_launcher ? 1 : 0

  project     = var.project_id
  role_id     = "${replace(local.p, "-", "_")}_model_registrar"
  title       = "Pipewright launcher (${var.environment}): register BigQuery ML models"
  description = "Read and update BigQuery ML model metadata, to register a version in the Model Registry (Pipewright FR-100). Managed by Terraform."
  permissions = ["bigquery.models.get", "bigquery.models.getData", "bigquery.models.getMetadata", "bigquery.models.updateMetadata"]
}

resource "google_bigquery_dataset_iam_member" "launcher_registrar" {
  for_each = local.registration_launcher ? local.tenants : {}

  project    = var.project_id
  dataset_id = google_bigquery_dataset.tenant[each.key].dataset_id
  role       = google_project_iam_custom_role.launcher_registrar[0].name
  member     = "serviceAccount:${google_service_account.launcher.email}"
}

resource "google_project_iam_member" "launcher_registration_jobs" {
  count = local.registration_launcher ? 1 : 0

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.launcher.email}"
}
