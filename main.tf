/**
 * A Pipewright environment on Google Cloud: everything the open-source Pipewright needs in one project.
 *
 *   apis.tf        the Google Cloud APIs
 *   storage.tf     artifacts and landing buckets
 *   registry.tf    Artifact Registry: images (Docker) and pipeline templates (KFP)
 *   identities.tf  the launcher and one runner service account per tenant, and their access
 *   bigquery.tf    one dataset per tenant
 *   pubsub.tf      landing notifications, run requests, lifecycle events, dead letters
 *   launcher.tf    the shared launcher on Cloud Run and its push subscriptions
 *   retraining.tf  approver groups and the retrain decision schedules
 *   manifest.tf    the environment manifest the pipewright CLI and the launcher read
 *
 * Public endpoints with IAM authentication: no VPC, no customer-managed keys. Good for trying Pipewright and for
 * development environments. Regulated production environments add private networking, CMEK and guardrails.
 */

locals {
  p      = var.name_prefix
  number = data.google_project.this.number
  labels = merge({ "pipewright-environment" = var.environment, "managed-by" = "terraform" }, var.labels)

  buckets = {
    artifacts = "${var.project_id}-${local.p}-artifacts"
    landing   = "${var.project_id}-${local.p}-landing"
  }
  tenants = {
    for t, v in var.tenants : t => merge(v, {
      landing_prefix = coalesce(v.landing_prefix, "incoming/${t}/")
      runner_id      = substr("${local.p}-${t}-run", 0, 30)
      dataset        = replace("${local.p}_${t}", "-", "_")
    })
  }
  runner_members = { for t in keys(local.tenants) : t => "serviceAccount:${google_service_account.runner[t].email}" }

  launcher_name = "${local.p}-launcher"
  deployed      = var.launcher_image != null
  # The launcher's deterministic URL: known before it exists, so the manifest can carry it in the same apply.
  launcher_url = "https://${local.launcher_name}-${local.number}.${var.region}.run.app"

  pubsub_agent  = "service-${local.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  topic_id      = { for k in ["landing", "run-requests", "events", "dead-letters"] : k => "projects/${var.project_id}/topics/${local.p}-${k}" }
  approver_tpcs = { for g in keys(var.approver_groups) : g => "projects/${var.project_id}/topics/${local.p}-approve-${g}" }
}

data "google_project" "this" {
  project_id = var.project_id
}
