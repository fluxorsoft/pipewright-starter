# The environment manifest: the platform side's contract with app teams (Pipewright manifest.schema.json,
# apiVersion pipewright/v1). Every value is known at plan time, so it is written in the same apply.
locals {
  manifest = {
    apiVersion   = "pipewright/v1"
    environment  = var.environment
    blueprint    = "poc"
    orchestrator = "vertex"
    project      = var.project_id
    region       = var.region
    artifact_registry = {
      docker = "${var.region}-docker.pkg.dev/${var.project_id}/${local.p}-images"
      kfp    = "https://${var.region}-kfp.pkg.dev/${var.project_id}/${local.p}-pipelines"
    }
    artifacts_bucket = local.buckets.artifacts
    landing_bucket   = local.buckets.landing
    launcher = {
      url                = local.launcher_url
      service            = local.launcher_name
      service_account    = google_service_account.launcher.email
      subscription       = "${local.launcher_name}-landing"
      run_requests_topic = local.topic_id["run-requests"]
    }
    policies = merge(
      { deploy_model = var.policies.deploy_model, promote_model = var.policies.promote_model },
      var.policies.retraining == null ? {} : {
        retraining = { for k, v in var.policies.retraining : k => v if v != null }
    })
    approver_groups = {
      for g, v in var.approver_groups : g => {
        topic        = local.approver_tpcs[g]
        subscription = "projects/${var.project_id}/subscriptions/${local.p}-approve-${g}-decide"
        description  = coalesce(v.description, "approver group ${g}")
      }
    }
    tenants = {
      for t, v in local.tenants : t => {
        runner_service_account = google_service_account.runner[t].email
        bigquery_dataset       = v.dataset
        landing_prefix         = v.landing_prefix
        online_serving         = v.online_serving
      }
    }
    observability = {
      events_topic = local.topic_id["events"]
    }
  }
}

resource "google_storage_bucket_object" "manifest" {
  bucket        = google_storage_bucket.artifacts.name
  name          = "pipewright/environment.json"
  content       = jsonencode(local.manifest)
  content_type  = "application/json"
  cache_control = "no-cache, max-age=0"
}
