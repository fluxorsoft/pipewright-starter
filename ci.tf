/**
 * A CI identity for GitHub Actions (Pipewright 1.2.0, FR-80), optional: github = { repository = "org/repo" }.
 *
 * A Workload Identity pool and a GitHub provider that accepts tokens from that one repository only (no keys), a CI
 * service account the repository's workflows may act as, and that account among the operators: what CI may do is
 * exactly what the operators may do. The outputs are the GitHub environment's variables GCP_WIF_PROVIDER and
 * PIPEWRIGHT_SERVICE_ACCOUNT (`pipewright ci init` writes workflows that read them).
 *
 * promotion_readers: in an environment other environments promote from (their promotion.from), the identities that
 * promote, usually the destination's CI account. They read this environment's images, release contracts, artifacts
 * and models, which `pipewright promote` copies, and the event log, where promote checks the version was approved.
 */

locals {
  # account_id is known at plan time, so the operators' for_each keys stay known; the reference orders the grants
  # after the account exists.
  ci_operator = var.github == null ? [] : [
    "serviceAccount:${google_service_account.ci[0].account_id}@${var.project_id}.iam.gserviceaccount.com"
  ]
  operators = distinct(concat(var.operators, local.ci_operator))
}

resource "google_project_service" "sts" {
  count = var.github == null ? 0 : 1

  project            = var.project_id
  service            = "sts.googleapis.com"
  disable_on_destroy = false
}

resource "google_iam_workload_identity_pool" "github" {
  count = var.github == null ? 0 : 1

  project                   = var.project_id
  workload_identity_pool_id = "${local.p}-github"
  display_name              = "GitHub Actions"
  description               = "Pipewright CI: GitHub Actions in ${var.github.repository}"

  depends_on = [google_project_service.sts]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count = var.github == null ? 0 : 1

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "github-repo"
  display_name                       = "GitHub repository"
  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.environment" = "assertion.environment"
  }
  attribute_condition = "assertion.repository == '${var.github.repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ci" {
  count = var.github == null ? 0 : 1

  project      = var.project_id
  account_id   = "${local.p}-github-ci"
  display_name = "Pipewright CI (GitHub Actions, ${var.github.repository})"
}

resource "google_service_account_iam_member" "ci_workload_identity" {
  count = var.github == null ? 0 : (try(var.github.environments, null) == null ? 1 : 0)

  service_account_id = google_service_account.ci[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository/${var.github.repository}"
}

# Pipewright FR-131: with github.environments, only jobs in those GitHub environments may act as the CI identity (the
# pool already accepts tokens from this one repository only). A job with no environment, such as pull request checks,
# gets nothing from it.
resource "google_service_account_iam_member" "ci_workload_identity_env" {
  for_each = var.github == null ? toset([]) : toset(coalesce(try(var.github.environments, null), []))

  service_account_id = google_service_account.ci[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.environment/${each.value}"
}

# Pipewright FR-131: a read-only identity for pull request checks (`pipewright ci init --checks-environment`). The
# checks only read: validate, test, doctor, resolve and the dry runs of tables, alerts and schedules sync. A branch's
# code runs in that job, so it gets an identity that can release, run, approve, publish and read data nothing.
# What it reads: the manifest, release contracts and pointers (artifacts bucket), table schemas (BigQuery metadata and
# dry runs, which read no rows), alert policies, schedules, registry and Feature Store metadata, image metadata.
# Cost: none (service accounts and IAM bindings are free).
locals {
  checks_identity = var.github != null && try(var.github.checks_environment, null) != null
  checks_roles = local.checks_identity ? toset([
    "roles/aiplatform.viewer", "roles/bigquery.metadataViewer", "roles/bigquery.jobUser", "roles/monitoring.viewer",
    "roles/cloudscheduler.viewer", "roles/artifactregistry.reader",
  ]) : toset([])
}

resource "google_service_account" "ci_checks" {
  count = local.checks_identity ? 1 : 0

  project      = var.project_id
  account_id   = "${local.p}-github-checks"
  display_name = "Pipewright CI checks, read only (GitHub Actions, ${var.github.repository})"
}

resource "google_service_account_iam_member" "ci_checks_workload_identity" {
  count = local.checks_identity ? 1 : 0

  service_account_id = google_service_account.ci_checks[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.environment/${var.github.checks_environment}"
}

resource "google_project_iam_member" "ci_checks" {
  for_each = local.checks_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ci_checks[0].email}"
}

resource "google_storage_bucket_iam_member" "ci_checks" {
  count = local.checks_identity ? 1 : 0

  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.ci_checks[0].email}"
}

# Promotion copies from here: the promoting identities read images, release contracts, artifacts and models.
resource "google_artifact_registry_repository_iam_member" "promotion_readers" {
  for_each = toset(var.promotion_readers)

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

resource "google_storage_bucket_iam_member" "promotion_readers" {
  for_each = toset(var.promotion_readers)

  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectViewer"
  member = each.value
}

resource "google_project_iam_member" "promotion_readers" {
  for_each = toset(var.promotion_readers)

  project = var.project_id
  role    = "roles/aiplatform.viewer"
  member  = each.value
}

# GA QA (found live, promotion from CI): promote checks that the version was approved here, from this environment's
# event log, so the promoting identity reads that log (the evidence dataset only) and runs the query. Without it the
# destination's CI failed: "the event log cannot be read, so v1's approval cannot be shown". Free (IAM).
resource "google_project_iam_member" "promotion_readers_jobs" {
  for_each = var.event_log ? toset(var.promotion_readers) : toset([])

  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = each.value
}

resource "google_bigquery_dataset_iam_member" "promotion_readers_events" {
  for_each = var.event_log ? toset(var.promotion_readers) : toset([])

  project    = var.project_id
  dataset_id = google_bigquery_dataset.evidence[0].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = each.value
}
