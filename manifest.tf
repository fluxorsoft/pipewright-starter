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
      },
      var.policies.integrity == null ? {} : {
        integrity = merge(
          var.policies.integrity.mode == null ? {} : { mode = var.policies.integrity.mode },
          var.policies.integrity.lock == null ? {} : { lock = var.policies.integrity.lock },
        var.policies.integrity.inference == null ? {} : { inference = var.policies.integrity.inference })
    })
    approver_groups = {
      for g, v in var.approver_groups : g => {
        topic        = local.approver_tpcs[g]
        subscription = "projects/${var.project_id}/subscriptions/${local.p}-approve-${g}-decide"
        description  = coalesce(v.description, "approver group ${g}")
      }
    }
    tenants = {
      for t, v in local.tenants : t => merge({
        runner_service_account = google_service_account.runner[t].email
        bigquery_dataset       = v.dataset
        landing_prefix         = v.landing_prefix
        online_serving         = v.online_serving
        }, v.agent_identity ? { agent_service_account = google_service_account.agent[t].email } : {},
        v.online_features == null && length(v.feature_datasets) == 0 ? {} : {
          features = merge(
            length(v.feature_datasets) == 0 ? {} : { datasets = v.feature_datasets },
            v.online_features == null ? {} : {
              online_store = "projects/${var.project_id}/locations/${var.region}/featureOnlineStores/${local.online_store_names[t]}"
          })
      })
    }
    observability = merge({
      events_topic = local.topic_id["events"]
    }, var.event_log ? { evidence_dataset = google_bigquery_dataset.evidence[0].dataset_id } : {})
  }
}

resource "google_storage_bucket_object" "manifest" {
  bucket        = google_storage_bucket.artifacts.name
  name          = "pipewright/environment.json"
  content       = jsonencode(local.manifest)
  content_type  = "application/json"
  cache_control = "no-cache, max-age=0"
}
