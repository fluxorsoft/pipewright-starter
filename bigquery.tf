# One dataset per tenant: the team creates and evolves its own tables in it with `pipewright tables sync`.
resource "google_bigquery_dataset" "tenant" {
  for_each = local.tenants

  project                    = var.project_id
  dataset_id                 = each.value.dataset
  location                   = var.region
  description                = "Pipewright tenant ${each.key} (${var.environment})"
  delete_contents_on_destroy = var.force_destroy
  labels                     = merge(local.labels, { "pipewright-tenant" = each.key })

  depends_on = [google_project_service.this]
}

resource "google_bigquery_dataset_iam_member" "runner" {
  for_each = local.tenants

  project    = var.project_id
  dataset_id = google_bigquery_dataset.tenant[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = local.runner_members[each.key]
}

resource "google_bigquery_dataset_iam_member" "members" {
  for_each = merge([for t, v in local.tenants : { for i, m in v.members : "${t}|${i}" => { tenant = t, member = m } }]...)

  project    = var.project_id
  dataset_id = google_bigquery_dataset.tenant[each.value.tenant].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = each.value.member
}

# The feature tables a team's pipelines read (tenants.<t>.feature_datasets, data.features_from): read-only, for the
# runner. Found live in the 1.3.0 test: without it, ingest fails with 403 on the feature table.
resource "google_bigquery_dataset_iam_member" "runner_features" {
  for_each = merge([for t, v in local.tenants : { for d in v.feature_datasets : "${t}|${d}" => { tenant = t, dataset = d } }]...)

  project    = split(".", each.value.dataset)[0]
  dataset_id = split(".", each.value.dataset)[1]
  role       = "roles/bigquery.dataViewer"
  member     = local.runner_members[each.value.tenant]
}
