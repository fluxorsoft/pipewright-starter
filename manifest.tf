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
    launcher = merge({
      url                = local.launcher_url
      service            = local.launcher_name
      service_account    = google_service_account.launcher.email
      subscription       = "${local.launcher_name}-landing"
      run_requests_topic = local.topic_id["run-requests"]
      }, length(google_cloud_run_v2_job.renewer) == 0 ? {} : {
      renewer_job             = google_cloud_run_v2_job.renewer[0].id
      renewer_service_account = google_service_account.renewer[0].email
    })
    policies = merge(
      { deploy_model = var.policies.deploy_model, promote_model = var.policies.promote_model },
      var.policies.retraining == null ? {} : {
        retraining = { for k, v in var.policies.retraining : k => v if v != null }
      },
      var.policies.integrity == null ? {} : {
        integrity = merge(
          { for k, v in var.policies.integrity : k => v if v != null && !contains(["lock", "features"], k) },
          var.policies.integrity.lock == null ? {} : {
            lock = { for k, v in var.policies.integrity.lock : k => v if v != null }
          },
          var.policies.integrity.features == null ? {} : {
            features = { for k, v in var.policies.integrity.features : k => v if v != null }
        })
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
        v.loop_production_project == null ? {} : { loop_production_project = v.loop_production_project },
        v.online_features == null && length(v.feature_datasets) == 0 && !contains(keys(local.online_tenant_manifest), t) ? {} : {
          features = merge(
            length(v.feature_datasets) == 0 ? {} : { datasets = v.feature_datasets },
            v.online_features == null ? {} : {
              online_store = "projects/${var.project_id}/locations/${var.region}/featureOnlineStores/${local.online_store_names[t]}"
            },
          lookup(local.online_tenant_manifest, t, {}))
      })
    }
    observability = merge({
      events_topic = local.topic_id["events"]
      }, var.event_log ? { evidence_dataset = google_bigquery_dataset.evidence[0].dataset_id } : {},
      # Pipewright 1.4.1 (FR-102). Written whatever their value, null when off: a conditional object would turn the
      # number into a string (found live: the manifest failed validation).
      {
        data_write_logs      = local.data_write_on ? true : null
        audit_log_bucket     = local.audit_on ? "projects/${var.project_id}/locations/global/buckets/${local.p}-audit" : null
        audit_retention_days = local.audit_on ? var.audit_retention_days : null
    })
  }
}

resource "google_storage_bucket_object" "manifest" {
  bucket        = google_storage_bucket.artifacts.name
  name          = "pipewright/environment.json"
  content       = jsonencode(merge(local.manifest, length(local.online_manifest) == 0 ? {} : { features = local.online_manifest }))
  content_type  = "application/json"
  cache_control = "no-cache, max-age=0"
}
