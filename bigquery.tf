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
