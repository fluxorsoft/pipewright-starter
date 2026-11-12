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
  count = var.github == null ? 0 : 1

  service_account_id = google_service_account.ci[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository/${var.github.repository}"
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
