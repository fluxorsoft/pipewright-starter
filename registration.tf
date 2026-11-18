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
#
# Pipewright FR-149, ON by default (founder, 2026-11-18: a security fix; the one exception to "every change after
# 1.0 is off by default"): policies.feature_registry = "runners_read". The Feature Store registry is one per
# project and region, and roles/aiplatform.user lets every runner create, change and delete any team's feature
# groups, features, online stores and views. With runners_read the runner's custom role (the one above) also leaves
# out those writes: runs still read groups and features, and registering them stays with the people and producer
# identities who do it today (`pipewright features register`, `pipewright features sync`). No runner step writes the
# registry (checked for 1.4.4). runners_write keeps roles/aiplatform.user as before 1.4.5: set it only for a team
# whose own components register feature groups from a run (they would get 403). Cost: none.

locals {
  registration_launcher = try(var.policies.registration, "runner") == "launcher"
  feature_registry_read = coalesce(try(var.policies.feature_registry, null), "runners_read") == "runners_read"
  runner_custom         = local.registration_launcher || local.feature_registry_read
  runner_role           = local.runner_custom ? google_project_iam_custom_role.runner[0].name : "roles/aiplatform.user"
  # Feature Store writes a runner never needs (FR-149): groups, features, online stores, views, direct writes of
  # values, feature monitors, and the legacy featurestores and entity types. Reads stay (checked against
  # roles/aiplatform.user's permissions, 2026-11-18: 31 writes left out, every get, list and read kept)
  feature_writes = "^aiplatform\\.(featureGroups|features|featureOnlineStores|featureViews|featurestores|entityTypes|featureMonitors|featureMonitorJobs)\\.(create|update|delete|sync|directWrite|batchCreateFeatures|importFeatureValues|writeFeatureValues|deleteFeatureValues|exportFeatureValues|importFeatures|writeFeatures|exportFeatures|setIamPolicy)$"
}

data "google_iam_role" "aiplatform_user" {
  count = local.runner_custom ? 1 : 0
  name  = "roles/aiplatform.user"
}

# Custom roles take only the permissions that support them (aiplatform.user also holds resourcemanager.projects.list,
# which a custom role refuses: found in the 1.4.3 battle test).
data "google_iam_testable_permissions" "project" {
  count                = local.runner_custom ? 1 : 0
  full_resource_name   = "//cloudresourcemanager.googleapis.com/projects/${var.project_id}"
  stages               = ["GA", "BETA", "ALPHA", "DEPRECATED"]
  custom_support_level = "SUPPORTED"
}

resource "google_project_iam_custom_role" "runner" {
  count = local.runner_custom ? 1 : 0

  project     = var.project_id
  role_id     = "${replace(local.p, "-", "_")}_runner"
  title       = "Pipewright runner (${var.environment}): Agent Platform user without registry writes"
  description = "roles/aiplatform.user without ${join(" or ", compact([local.registration_launcher ? "model registry writes (FR-100)" : "", local.feature_registry_read ? "Feature Store writes (FR-149)" : ""]))}. Managed by Terraform."
  permissions = sort(setsubtract(setintersection(data.google_iam_role.aiplatform_user[0].included_permissions,
    [for x in data.google_iam_testable_permissions.project[0].permissions : x.name]), concat(
    local.registration_launcher ? ["aiplatform.models.upload", "aiplatform.models.update", "aiplatform.models.delete"] : [],
    local.feature_registry_read ? [for x in data.google_iam_role.aiplatform_user[0].included_permissions : x if can(regex(local.feature_writes, x))] : [],
  )))
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
  permissions = ["bigquery.models.getData", "bigquery.models.getMetadata", "bigquery.models.updateMetadata"]
}

resource "google_bigquery_dataset_iam_member" "launcher_registrar" {
  for_each = local.registration_launcher ? local.tenants : {}

  project    = var.project_id
  dataset_id = google_bigquery_dataset.tenant[each.key].dataset_id
  role       = google_project_iam_custom_role.launcher_registrar[0].name
  member     = "serviceAccount:${google_service_account.launcher.email}"

  depends_on = [time_sleep.registrar_role]
}

resource "google_project_iam_member" "launcher_registration_jobs" {
  count = local.registration_launcher ? 1 : 0

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.launcher.email}"
}

# A new custom role reaches BigQuery's dataset IAM a little later ("does not exist in the resource's hierarchy", found
# in the 1.4.3 battle test): wait before granting it.
resource "time_sleep" "registrar_role" {
  count           = local.registration_launcher ? 1 : 0
  create_duration = "60s"
  depends_on      = [google_project_iam_custom_role.launcher_registrar]
}
