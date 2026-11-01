# AI build assistance (Pipewright 1.3.0): an agent identity per team, off unless `agent_identity = true`.
#
# A coding agent working with `pipewright mcp` acts as this service account, impersonated by the team's members, not
# as the person. Its roles are metadata only: schemas, row counts, model and run status, feature definitions, the
# manifest and release contracts. It cannot read table data, so no route (Pipewright's tools, bq, a data MCP server)
# returns rows to an agent, and Cloud Audit Logs record every call as this account acting for the person.

locals {
  agent_tenants = { for t, v in local.tenants : t => v if v.agent_identity }
  agent_members = { for t in keys(local.agent_tenants) : t => "serviceAccount:${google_service_account.agent[t].email}" }
  # The project-level roles an agent needs to look, never to change or read data.
  agent_project_roles = [
    "roles/bigquery.jobUser",      # dry runs and job metadata (no data access on its own)
    "roles/aiplatform.viewer",     # models, pipeline runs, feature group and view definitions
    "roles/cloudscheduler.viewer", # the plan of a use case's schedules
    "roles/monitoring.viewer",     # the plan of a use case's alert policies
  ]
  agent_project_grants = {
    for pair in setproduct(keys(local.agent_tenants), local.agent_project_roles) : "${pair[0]}|${pair[1]}" => {
      tenant = pair[0]
      role   = pair[1]
    }
  }
  agent_feature_grants = {
    for pair in flatten([for t, v in local.agent_tenants : [for d in v.feature_datasets : { tenant = t, dataset = d }]]) :
    "${pair.tenant}|${pair.dataset}" => pair
  }
  agent_impersonators = {
    for pair in flatten([for t, v in local.agent_tenants : [for m in v.members : { tenant = t, member = m }]]) :
    "${pair.tenant}|${pair.member}" => pair
  }
}

resource "google_service_account" "agent" {
  for_each = local.agent_tenants

  project      = var.project_id
  account_id   = substr("${local.p}-${each.key}-agent", 0, 30)
  display_name = "Pipewright agent: ${each.key} (${var.environment})"
  description  = "Identity of coding agents working on ${each.key}'s use cases: metadata only. Managed by Terraform."

  depends_on = [google_project_service.this]
}

resource "google_project_iam_member" "agent" {
  for_each = local.agent_project_grants

  project = var.project_id
  role    = each.value.role
  member  = local.agent_members[each.value.tenant]
}

# Schemas and row counts of the team's own tables, no data.
resource "google_bigquery_dataset_iam_member" "agent_metadata" {
  for_each = local.agent_tenants

  project    = var.project_id
  dataset_id = google_bigquery_dataset.tenant[each.key].dataset_id
  role       = "roles/bigquery.metadataViewer"
  member     = local.agent_members[each.key]
}

# Schemas of the feature tables the team may read (feature_datasets), no values.
resource "google_bigquery_dataset_iam_member" "agent_features" {
  for_each = local.agent_feature_grants

  project    = split(".", each.value.dataset)[0]
  dataset_id = split(".", each.value.dataset)[1]
  role       = "roles/bigquery.metadataViewer"
  member     = local.agent_members[each.value.tenant]
}

# The manifest and the team's release contracts, nothing else in the artifacts bucket.
resource "google_storage_bucket_iam_member" "agent_manifest" {
  for_each = local.agent_tenants

  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectViewer"
  member = local.agent_members[each.key]
  condition {
    title       = "pipewright-agent-${each.key}"
    description = "The manifest and release contracts only"
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/pipewright/\") || resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/contracts/\")"
  }
}

# The team's members may act as the agent identity (impersonation), and nobody else.
resource "google_service_account_iam_member" "agent_impersonation" {
  for_each = local.agent_impersonators

  service_account_id = google_service_account.agent[each.value.tenant].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value.member
}

# What `doctor` checks, read as configuration: that the platform's buckets, registries, launcher, topics and service
# accounts exist and are set up. No object listing, no image pulls, no data.
resource "google_project_iam_custom_role" "agent_platform_metadata" {
  count = length(local.agent_tenants) > 0 ? 1 : 0

  project     = var.project_id
  role_id     = replace("${local.p}_agent_platform_metadata", "-", "_")
  title       = "Pipewright agent: platform metadata"
  description = "Read the configuration of the platform's resources, for pipewright doctor run by a coding agent."
  permissions = [
    "storage.buckets.get",
    "artifactregistry.repositories.get",
    "iam.serviceAccounts.get",
    "run.services.get",
    "pubsub.topics.get",
    "pubsub.subscriptions.get",
  ]
}

resource "google_project_iam_member" "agent_platform_metadata" {
  for_each = local.agent_tenants

  project = var.project_id
  role    = google_project_iam_custom_role.agent_platform_metadata[0].id
  member  = local.agent_members[each.key]
}

# Optional: Data Access audit logs (ADMIN_READ, DATA_READ) for the services agents read, so every metadata read an
# agent makes is in Cloud Audit Logs with its user agent (pipewright-mcp/<version> agent=<name>) and the person it
# acted for. Refused attempts and BigQuery queries are logged without this. Data Access logs are billed by volume.
resource "google_project_iam_audit_config" "agent" {
  for_each = var.agent_audit_logs ? toset(["bigquery.googleapis.com", "aiplatform.googleapis.com", "storage.googleapis.com"]) : toset([])

  project = var.project_id
  service = each.value
  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
}
