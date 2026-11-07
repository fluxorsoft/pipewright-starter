# Pipewright 1.4.1 (FR-103): feature definitions checked against each use case's feature contract
# (policies.integrity.features, all off by default). The launcher checks a training run's definitions before it
# submits it, and the watch checks approved ones, so it reads the feature tables' metadata; each further setting
# adds only what it needs. People (approvers, deployers) check with their own access.

locals {
  features_policy  = try(var.policies.integrity.features, null)
  features_check   = try(local.features_policy.check, "off") == "on"
  features_built   = local.features_check && try(local.features_policy.built_tables, false) == true
  features_snap    = coalesce(try(local.features_policy.snapshot_days, null), 0) > 0 # null when unset (found live)
  features_reads   = try(local.features_policy.record_reads, false) == true || try(local.features_policy.fingerprint_rows, false) == true || local.features_snap
  features_any     = local.features_check || local.features_reads
  feature_datasets = distinct(concat([for t, v in local.tenants : "${var.project_id}.${v.dataset}"], flatten([for t, v in local.tenants : v.feature_datasets])))
}

# What a definition is: tables.get on the feature tables and views (metadata only; with record_reads, the rows, for
# the dry run that lists a view's base tables and for row fingerprints).
resource "google_bigquery_dataset_iam_member" "launcher_features" {
  for_each = local.features_any ? toset(local.feature_datasets) : toset([])

  project    = split(".", each.value)[0]
  dataset_id = split(".", each.value)[1]
  role       = local.features_reads ? "roles/bigquery.dataViewer" : "roles/bigquery.metadataViewer"
  member     = "serviceAccount:${google_service_account.launcher.email}"

  depends_on = [google_bigquery_dataset.tenant]
}

# built_tables: the SQL of the job that last wrote a table (INFORMATION_SCHEMA.JOBS_BY_PROJECT needs
# bigquery.jobs.listAll, which shows every job's SQL in the project: granted only with this setting) and a scheduled
# query's config.
resource "google_project_iam_custom_role" "features_built" {
  count       = local.features_built ? 1 : 0
  project     = var.project_id
  role_id     = replace("${local.p}_feature_builds", "-", "_")
  title       = "Pipewright: read how feature tables are built"
  description = "Pipewright 1.4.1 (FR-103): list jobs (their SQL) and read scheduled queries, to check feature definitions."
  permissions = ["bigquery.jobs.listAll", "bigquery.transfers.get"]
}

resource "google_project_iam_member" "launcher_features_built" {
  count   = local.features_built ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.features_built[0].id
  member  = "serviceAccount:${google_service_account.launcher.email}"
}

# snapshot_days: the launcher snapshots the base tables a scoring run reads into the tenant's dataset.
resource "google_bigquery_dataset_iam_member" "launcher_snapshots" {
  for_each = local.features_snap ? toset(keys(local.tenants)) : toset([])

  project    = var.project_id
  dataset_id = google_bigquery_dataset.tenant[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.launcher.email}"
}

# A snapshot with an expiration also needs bigquery.tables.deleteSnapshot (found live: dataEditor lacks it, and the
# broad dataOwner is not granted): a role with only that, on the tenant datasets.
resource "google_project_iam_custom_role" "features_snapshots" {
  count       = local.features_snap ? 1 : 0
  project     = var.project_id
  role_id     = replace("${local.p}_feature_snapshots", "-", "_")
  title       = "Pipewright: expire feature snapshots"
  description = "Pipewright 1.4.1 (FR-103): snapshots of the tables a scoring run read, created with an expiration."
  permissions = ["bigquery.tables.deleteSnapshot"]
}

resource "google_bigquery_dataset_iam_member" "launcher_snapshot_expiry" {
  for_each = local.features_snap ? toset(keys(local.tenants)) : toset([])

  project    = var.project_id
  dataset_id = google_bigquery_dataset.tenant[each.key].dataset_id
  role       = google_project_iam_custom_role.features_snapshots[0].id
  member     = "serviceAccount:${google_service_account.launcher.email}"
}
