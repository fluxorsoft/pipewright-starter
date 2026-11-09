/**
 * Pipewright 1.4.1 (FR-101, FR-102): serving what was approved, and knowing when it changes.
 *
 * - The lock renewer (when policies.integrity.lock.days > 0 and lock.renew is not false): a separate identity from the
 *   launcher, with a custom role of exactly storage.objects.get, setRetention and update on the model folders, the
 *   release contracts and the manifest. The live permission spike (pipewright docs/evidence/fr101-retention-
 *   permissions) showed setRetention alone cannot extend retention, and update also allows releasing holds and
 *   changing metadata: so the renewer is not the launcher, only Terraform may act as it, and its work is watched by
 *   the launcher (the cross-identity check) and by DATA_WRITE audit logs.
 * - The gate, as code: the renewer's daily schedule exists only when the watch is on, DATA_WRITE logs and their
 *   exclusion exist, and the environment alerts exist; it ships paused (renewer_schedule = false) until the live gate
 *   has passed in that environment.
 * - FR-102: Admin Activity entries for Agent Platform and the artifacts bucket routed to a log bucket that keeps them
 *   audit_retention_days (locked by default); Cloud Storage DATA_WRITE audit logs (on with the renewer, or
 *   data_write_logs), with an exclusion that keeps only the artifacts bucket's model folders and contracts.
 * - Environment alerts to platform_alert_emails: the watch's heartbeat missing, an approved file changed or a hold
 *   released (incidents), the renewer's run not healthy or protection running low, and an override in force.
 */

locals {
  integrity_cfg = var.policies.integrity
  lock_days     = coalesce(try(var.policies.integrity.lock.days, null), 0)
  watch_on      = try(var.policies.integrity.watch, "off") == "on"
  watch_hours = try(
    tonumber(trimsuffix(var.policies.integrity.watch_every, "h")),
    tonumber(trimsuffix(var.policies.integrity.watch_every, "d")) * 24,
  1)
  renew_on      = var.renewer && local.lock_days > 0 && try(var.policies.integrity.lock.renew, true) != false
  data_write_on = var.data_write_logs || local.renew_on
  audit_on      = var.audit_retention_days > 0
  alerts_on     = length(var.platform_alert_emails) > 0
  renewer_name  = "${local.p}-renewer"
  manifest_uri  = "gs://${google_storage_bucket.artifacts.name}/pipewright/environment.json"
  protected_condition = join(" || ", [
    "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/pipeline-root/\")",
    "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/contracts/\")",
    "resource.name == \"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/pipewright/environment.json\"",
  ])
}

# ---------------------------------------------------------------- the renewer --

resource "google_service_account" "renewer" {
  count        = local.renew_on ? 1 : 0
  account_id   = substr(local.renewer_name, 0, 30)
  display_name = "Pipewright lock renewer (${var.environment})"
  description  = "Extends retention on approved files while they are in use. Never the launcher. Managed by Terraform."
}

resource "google_project_iam_custom_role" "renewer" {
  count       = local.renew_on ? 1 : 0
  role_id     = replace("pipewrightRenewer_${local.p}", "-", "_")
  title       = "Pipewright lock renewer (${local.p})"
  description = "Read and extend retention on approved files: storage.objects.get, setRetention and update (update is required to extend retention, and also allows releasing holds and changing metadata: watched by the launcher and audit logs)."
  permissions = ["storage.objects.get", "storage.objects.setRetention", "storage.objects.update"]
}

resource "google_storage_bucket_iam_member" "renewer_protected" {
  count  = local.renew_on ? 1 : 0
  bucket = google_storage_bucket.artifacts.name
  role   = google_project_iam_custom_role.renewer[0].id
  member = "serviceAccount:${google_service_account.renewer[0].email}"
  condition {
    title       = "pipewright-protected"
    description = "Model folders, release contracts and the manifest only"
    expression  = local.protected_condition
  }
}

# Reading what is in use: the registry and endpoints (viewer, not the launcher's user role: it cannot move a default),
# the event log, the bucket's retention setting; publishing its events; writing its logs.
resource "google_project_iam_member" "renewer" {
  for_each = local.renew_on ? toset(["roles/aiplatform.viewer", "roles/bigquery.jobUser", "roles/logging.logWriter"]) : toset([])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.renewer[0].email}"
}

resource "google_storage_bucket_iam_member" "renewer_bucket" {
  count  = local.renew_on ? 1 : 0
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.renewer[0].email}"
}

resource "google_bigquery_dataset_iam_member" "renewer_events" {
  count      = local.renew_on && var.event_log ? 1 : 0
  dataset_id = google_bigquery_dataset.evidence[0].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.renewer[0].email}"
}

resource "google_pubsub_topic_iam_member" "renewer_events" {
  count  = local.renew_on ? 1 : 0
  topic  = google_pubsub_topic.this["events"].id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.renewer[0].email}"
}

resource "google_cloud_run_v2_job" "renewer" {
  count               = local.renew_on && local.deployed ? 1 : 0
  name                = local.renewer_name
  location            = var.region
  deletion_protection = false
  labels              = local.labels

  template {
    task_count = 1
    template {
      service_account = google_service_account.renewer[0].email
      max_retries     = 2
      timeout         = "1800s"
      containers {
        image   = var.launcher_image
        command = ["pipewright"]
        args    = ["integrity", "renew", "--manifest", local.manifest_uri]
        resources {
          limits = { cpu = "1", memory = "1Gi" }
        }
      }
    }
  }
  depends_on = [google_storage_bucket_iam_member.renewer_protected]
}

# Only the scheduler (as the renewer itself) runs the job; nobody else is given run or actAs on it.
resource "google_cloud_run_v2_job_iam_member" "renewer_runs_itself" {
  count    = local.renew_on && local.deployed ? 1 : 0 # as the renewer job (not length(): it breaks import)
  name     = google_cloud_run_v2_job.renewer[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.renewer[0].email}"
}

# The gate, as code: the schedule exists only with the watch on and the detective controls in place; it ships paused.
resource "google_cloud_scheduler_job" "renewer" {
  count            = local.renew_on && local.deployed && local.watch_on ? 1 : 0
  name             = local.renewer_name
  region           = var.region
  description      = "Pipewright lock renewal, daily. Paused until the live gate has passed (renewer_schedule). Managed by Terraform."
  schedule         = "23 3 * * *"
  time_zone        = "Etc/UTC"
  paused           = !var.renewer_schedule
  attempt_deadline = "180s"

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${local.renewer_name}:run"
    oauth_token {
      service_account_email = google_service_account.renewer[0].email
    }
  }
  depends_on = [
    google_project_iam_audit_config.storage_data_write,
    google_logging_project_exclusion.storage_data_write,
    google_monitoring_alert_policy.integrity,
    google_cloud_run_v2_job_iam_member.renewer_runs_itself,
  ]
}

# ---------------------------------------------------------------- audit logs (FR-102) --

# Only when ai.tf's agent audit logs do not already own Cloud Storage's audit config (they add DATA_WRITE there).
resource "google_project_iam_audit_config" "storage_data_write" {
  count   = local.data_write_on && !var.agent_audit_logs ? 1 : 0
  project = var.project_id
  service = "storage.googleapis.com"
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# Every DATA_WRITE entry is dropped unless it is about the artifacts bucket's model folders or contracts (excluded
# entries are not charged).
resource "google_logging_project_exclusion" "storage_data_write" {
  count       = local.data_write_on ? 1 : 0
  name        = "${local.p}-storage-data-write-noise"
  description = "Pipewright: keep Cloud Storage DATA_WRITE entries only for approved folders and contracts"
  filter      = <<-EOT
    logName="projects/${var.project_id}/logs/cloudaudit.googleapis.com%2Fdata_access"
    AND protoPayload.serviceName="storage.googleapis.com"
    AND NOT (resource.labels.bucket_name="${google_storage_bucket.artifacts.name}"
             AND (protoPayload.resourceName:"/objects/pipeline-root/" OR protoPayload.resourceName:"/objects/contracts/"))
  EOT
}

resource "google_logging_project_bucket_config" "audit" {
  count          = local.audit_on ? 1 : 0
  project        = var.project_id
  location       = "global"
  bucket_id      = "${local.p}-audit"
  retention_days = var.audit_retention_days
  locked         = var.audit_log_bucket_locked
  description    = "Pipewright: Admin Activity (and DATA_WRITE) for Agent Platform and the artifacts bucket, kept as long as models serve"
}

resource "google_logging_project_sink" "audit" {
  count                  = local.audit_on ? 1 : 0
  name                   = "${local.p}-audit"
  destination            = "logging.googleapis.com/projects/${var.project_id}/locations/global/buckets/${google_logging_project_bucket_config.audit[0].bucket_id}"
  unique_writer_identity = true
  filter                 = <<-EOT
    (logName="projects/${var.project_id}/logs/cloudaudit.googleapis.com%2Factivity"
     AND (protoPayload.serviceName="aiplatform.googleapis.com"
          OR (protoPayload.serviceName="storage.googleapis.com" AND resource.labels.bucket_name="${google_storage_bucket.artifacts.name}")))
    OR (logName="projects/${var.project_id}/logs/cloudaudit.googleapis.com%2Fdata_access"
        AND protoPayload.serviceName="storage.googleapis.com"
        AND resource.labels.bucket_name="${google_storage_bucket.artifacts.name}")
  EOT
}

# A sink into a log bucket of the same project needs no writer grant (found live: its writer_identity is empty).

# ---------------------------------------------------------------- environment alerts --

resource "google_monitoring_notification_channel" "platform" {
  for_each     = local.alerts_on ? toset(var.platform_alert_emails) : toset([])
  display_name = "pipewright platform: ${each.value}"
  type         = "email"
  labels       = { email_address = each.value }
  user_labels  = { "pipewright-environment" = var.environment, "pipewright-managed" = "true" }
}

locals {
  event_filter = "jsonPayload.pipewright_event.environment=\"${var.environment}\""
  integrity_alerts = local.alerts_on ? merge(
    {
      incident = {
        title  = "approved files changed, unapproved, or a hold released"
        filter = "${local.event_filter} AND jsonPayload.pipewright_event.event_type=\"model.integrity\" AND (jsonPayload.pipewright_event.data.severity=\"incident\" OR jsonPayload.pipewright_event.data.status=\"renewal_missing\")"
        doc    = "An approved model's files are not what was approved, a version serves without an approval, a hold on a protected file was released, or the renewer has not run. `pipewright integrity check --env ${var.environment}`; restore with `pipewright model restore-files` (docs/INTEGRITY.md, response plan)."
      }
    },
    local.renew_on ? {
      renewal = {
        title  = "lock renewal not healthy"
        filter = "${local.event_filter} AND jsonPayload.pipewright_event.event_type=\"model.lock.reconciliation\" AND jsonPayload.pipewright_event.data.status!=\"healthy\""
        doc    = "The renewer's run failed or was degraded: some approved files may not stay protected. See the run's model.lock.failed events and `pipewright integrity renew --env ${var.environment} --dry-run`."
      }
      low = {
        title  = "approved files close to losing protection"
        filter = "${local.event_filter} AND jsonPayload.pipewright_event.event_type=\"model.lock.reconciliation\" AND jsonPayload.pipewright_event.data.least_protection_remaining_days<2"
        doc    = "An approved file in use has less than two days of retention left. Run the renewer now (gcloud run jobs execute ${local.renewer_name}) and find out why it did not renew."
      }
    } : {},
    {
      override = {
        title  = "integrity override in force"
        filter = "${local.event_filter} AND jsonPayload.pipewright_event.event_type=\"policy.override\" AND jsonPayload.pipewright_event.data.status=\"active\""
        doc    = "policies.integrity.mode is warn: versions that are not the approved ones are deployed anyway until the date in `until`."
      }
  }) : {}
}

resource "google_monitoring_alert_policy" "integrity" {
  for_each     = local.integrity_alerts
  display_name = "pipewright ${var.environment}: ${each.value.title}"
  combiner     = "OR"
  severity     = each.key == "override" ? "WARNING" : "CRITICAL"
  conditions {
    display_name = each.value.title
    condition_matched_log {
      filter = each.value.filter
    }
  }
  alert_strategy {
    notification_rate_limit {
      period = "3600s"
    }
    auto_close = "86400s"
  }
  notification_channels = [for c in google_monitoring_notification_channel.platform : c.name]
  documentation {
    content   = each.value.doc
    mime_type = "text/markdown"
  }
  user_labels = { "pipewright-environment" = var.environment, "pipewright-managed" = "true" }
}

# The watch's heartbeat: no model.integrity.check for two intervals means the watch stopped (a broken watch must not
# look like "unchanged").
resource "google_logging_metric" "watch_heartbeat" {
  count  = local.alerts_on && local.watch_on ? 1 : 0
  name   = "${local.p}_integrity_watch_heartbeat"
  filter = "${local.event_filter} AND jsonPayload.pipewright_event.event_type=\"model.integrity.check\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "watch_heartbeat" {
  count        = local.alerts_on && local.watch_on ? 1 : 0 # as the metric (not length(): it breaks import)
  display_name = "pipewright ${var.environment}: the integrity watch has stopped"
  combiner     = "OR"
  severity     = "CRITICAL"
  conditions {
    display_name = "no model.integrity.check"
    condition_absent {
      filter   = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.watch_heartbeat[0].name}\" AND resource.type=\"cloud_run_revision\""
      duration = "${min(local.watch_hours * 2 * 3600 + 600, 84600)}s"
      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
  notification_channels = [for c in google_monitoring_notification_channel.platform : c.name]
  documentation {
    content   = "The launcher's integrity watch has not reported for two intervals: nothing is checking approved files. Look at the launcher's /retraining/tick (Cloud Scheduler) and its logs."
    mime_type = "text/markdown"
  }
  user_labels = { "pipewright-environment" = var.environment, "pipewright-managed" = "true" }
}
