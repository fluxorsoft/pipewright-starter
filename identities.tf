# ---------------------------------------------------------------- service accounts --

resource "google_service_account" "launcher" {
  project      = var.project_id
  account_id   = local.launcher_name
  display_name = "Pipewright launcher (${var.environment})"
  description  = "Shared launcher: submits pipeline jobs as tenant runners. Managed by Terraform."

  depends_on = [google_project_service.this]
}

resource "google_service_account" "runner" {
  for_each = local.tenants

  project      = var.project_id
  account_id   = each.value.runner_id
  display_name = "Pipewright runner: ${each.key} (${var.environment})"
  description  = "Identity of ${each.key}'s pipeline jobs. Managed by Terraform."

  depends_on = [google_project_service.this]
}

# ---------------------------------------------------------------- launcher --

resource "google_project_iam_member" "launcher" {
  for_each = toset(["roles/aiplatform.user", "roles/logging.logWriter", "roles/monitoring.metricWriter"])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.launcher.email}"
}

# Reads the manifest, contracts and pointers.
resource "google_storage_bucket_iam_member" "launcher_artifacts" {
  for_each = toset(["roles/storage.objectViewer", "roles/storage.legacyBucketReader"])

  bucket = google_storage_bucket.artifacts.name
  role   = each.value
  member = "serviceAccount:${google_service_account.launcher.email}"
}

# The only writer of retrain decision cases.
resource "google_storage_bucket_iam_member" "launcher_cases" {
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.launcher.email}"

  condition {
    title       = "pipewright-cases"
    description = "Retrain decision cases only"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/cases/\")"
  }
}

resource "google_artifact_registry_repository_iam_member" "launcher" {
  for_each = { images = google_artifact_registry_repository.images.name, pipelines = google_artifact_registry_repository.pipelines.name }

  project    = var.project_id
  location   = var.region
  repository = each.value
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.launcher.email}"
}

# Submits pipeline jobs that run as each tenant's runner.
resource "google_service_account_iam_member" "launcher_acts_as_runner" {
  for_each = local.tenants

  service_account_id = google_service_account.runner[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.launcher.email}"
}

# ---------------------------------------------------------------- runners --

resource "google_project_iam_member" "runner" {
  for_each = { for p in setproduct(keys(local.tenants), [
    "roles/aiplatform.user", "roles/bigquery.jobUser", "roles/logging.logWriter", "roles/monitoring.metricWriter",
  ]) : "${p[0]}|${p[1]}" => { tenant = p[0], role = p[1] } }

  project = var.project_id
  role    = each.value.role
  member  = local.runner_members[each.value.tenant]
}

# Pipeline roots and model artifacts. Shared by tenants in this starter: give each team its own bucket or prefix
# conditions in a stricter environment.
resource "google_storage_bucket_iam_member" "runner_artifacts" {
  for_each = local.tenants

  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectAdmin"
  member = local.runner_members[each.key]
}

# Each runner reads only its own landing prefix and samples/<tenant>/ (scoring batches, retrain sources).
resource "google_storage_bucket_iam_member" "runner_landing" {
  for_each = local.tenants

  bucket = google_storage_bucket.landing.name
  role   = "roles/storage.objectViewer"
  member = local.runner_members[each.key]

  condition {
    title       = "tenant-${each.key}-prefixes"
    description = "Only ${each.key}'s landing and samples prefixes"
    expression = join(" || ", [
      "resource.type == \"storage.googleapis.com/Bucket\"",
      "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.landing.name}/objects/${each.value.landing_prefix}\")",
      "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.landing.name}/objects/samples/${each.key}/\")",
    ])
  }
}

resource "google_artifact_registry_repository_iam_member" "runner_images" {
  for_each = local.tenants

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = local.runner_members[each.key]
}

# ---------------------------------------------------------------- operators (people or CI who release) --

resource "google_project_iam_member" "operator" {
  for_each = { for p in setproduct(var.operators, [
    "roles/aiplatform.user", "roles/bigquery.jobUser", "roles/cloudscheduler.admin",
    "roles/monitoring.alertPolicyEditor", "roles/monitoring.notificationChannelEditor", "roles/logging.viewer",
  ]) : "${p[0]}|${p[1]}" => { member = p[0], role = p[1] } }

  project = var.project_id
  role    = each.value.role
  member  = each.value.member
}

resource "google_artifact_registry_repository_iam_member" "operator" {
  for_each = { for p in setproduct(var.operators, ["images", "pipelines"]) : "${p[0]}|${p[1]}" => { member = p[0], repo = p[1] } }

  project    = var.project_id
  location   = var.region
  repository = each.value.repo == "images" ? google_artifact_registry_repository.images.name : google_artifact_registry_repository.pipelines.name
  role       = "roles/artifactregistry.writer"
  member     = each.value.member
}

# Release contracts, pointers and sample data.
resource "google_storage_bucket_iam_member" "operator" {
  for_each = { for p in setproduct(var.operators, ["artifacts", "landing"]) : "${p[0]}|${p[1]}" => { member = p[0], bucket = p[1] } }

  bucket = each.value.bucket == "artifacts" ? google_storage_bucket.artifacts.name : google_storage_bucket.landing.name
  role   = "roles/storage.objectAdmin"
  member = each.value.member
}

resource "google_bigquery_dataset_iam_member" "operator" {
  for_each = { for p in setproduct(var.operators, keys(local.tenants)) : "${p[0]}|${p[1]}" => { member = p[0], tenant = p[1] } }

  project    = var.project_id
  dataset_id = google_bigquery_dataset.tenant[each.value.tenant].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = each.value.member
}

# Scheduler jobs call the launcher as the launcher identity; verification runs use the tenant's runner.
resource "google_service_account_iam_member" "operator_launcher" {
  for_each = toset(var.operators)

  service_account_id = google_service_account.launcher.name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}

resource "google_service_account_iam_member" "operator_runner" {
  for_each = { for p in setproduct(var.operators, keys(local.tenants)) : "${p[0]}|${p[1]}" => { member = p[0], tenant = p[1] } }

  service_account_id = google_service_account.runner[each.value.tenant].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value.member
}

resource "google_pubsub_topic_iam_member" "operator_run_requests" {
  for_each = toset(var.operators)

  project = var.project_id
  topic   = google_pubsub_topic.this["run-requests"].name
  role    = "roles/pubsub.publisher"
  member  = each.value
}
