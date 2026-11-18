/**
 * Pipewright FR-127, off by default: the launcher's metrics and traces over OpenTelemetry (docs/TELEMETRY.md in
 * Pipewright). otlp = {} runs Google's build of the OpenTelemetry Collector as a sidecar beside the launcher, sending
 * traces to Cloud Trace and metrics to Managed Service for Prometheus; otlp = { endpoint = "https://..." } sends
 * straight to an OTLP/HTTP backend instead (a trial, or Grafana Cloud), with any token in Secret Manager.
 *
 * What leaves: the six launcher metrics and the trigger, run and step spans of the contract. Never data, file names
 * or personal data: the launcher exports only allowlisted attributes, and the Collector's redaction processor keeps
 * the same allowlist before anything leaves (defence in depth). Telemetry never fails a run or blocks the launcher;
 * the sidecar is not a startup dependency of the launcher.
 *
 * Cost (list prices): Managed Prometheus $0.06 per million samples (about $0.65 a month for 10 use cases); Cloud Trace
 * 2.5 million spans a month free, then $0.20 per million; the Collector's config secret $0.06 a month; the sidecar's
 * memory (256 MiB) while a launcher instance runs. With cpu_always = false (the default) the launcher keeps
 * request-based billing: telemetry is sent while requests run and at shutdown, so a quiet instance may hold some of
 * it until its next request. cpu_always = true sends it at once, at the cost of instance-based billing.
 */

locals {
  otlp_on        = var.otlp != null
  otlp_collector = local.otlp_on && try(var.otlp.endpoint, null) == null
  otlp_endpoint  = local.otlp_collector ? "http://localhost:4318" : try(var.otlp.endpoint, null)
  # The span attributes of Pipewright's telemetry contract (pipewright.telemetry.catalogue.SPAN_ATTRIBUTES): the
  # Collector drops every other attribute before export.
  otlp_allowed_keys = [
    "pipewright.usecase", "pipewright.tenant", "pipewright.pipeline", "pipewright.trigger", "pipewright.release",
    "pipewright.run_id", "pipewright.job_id", "pipewright.case_id", "pipewright.outcome", "pipewright.reason",
    "pipewright.step", "pipewright.state", "pipewright.check", "exception.type", "exception.message",
  ]
  otlp_collector_config = yamlencode({
    receivers = { otlp = { protocols = { http = { endpoint = "localhost:4318" } } } }
    processors = {
      memory_limiter    = { check_interval = "1s", limit_percentage = 80, spike_limit_percentage = 20 }
      batch             = { timeout = "5s" }
      resourcedetection = { detectors = ["gcp"], timeout = "10s" }
      redaction         = { allow_all_keys = false, allowed_keys = local.otlp_allowed_keys, summary = "silent" }
    }
    exporters = {
      googlecloud             = { project = var.project_id }
      googlemanagedprometheus = { project = var.project_id }
    }
    extensions = { health_check = { endpoint = "0.0.0.0:13133" } }
    service = {
      extensions = ["health_check"]
      pipelines = {
        traces  = { receivers = ["otlp"], processors = ["memory_limiter", "resourcedetection", "redaction", "batch"], exporters = ["googlecloud"] }
        metrics = { receivers = ["otlp"], processors = ["memory_limiter", "resourcedetection", "batch"], exporters = ["googlemanagedprometheus"] }
      }
    }
  })
}

resource "google_project_service" "telemetry" {
  for_each = local.otlp_collector ? toset(["cloudtrace.googleapis.com", "secretmanager.googleapis.com"]) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_secret_manager_secret" "otel_config" {
  count = local.otlp_collector ? 1 : 0

  project   = var.project_id
  secret_id = "${local.p}-otel-collector"
  labels    = local.labels
  replication {
    auto {}
  }
  depends_on = [google_project_service.telemetry]
}

resource "google_secret_manager_secret_version" "otel_config" {
  count = local.otlp_collector ? 1 : 0

  secret      = google_secret_manager_secret.otel_config[0].id
  secret_data = local.otlp_collector_config
}

resource "google_secret_manager_secret_iam_member" "otel_config" {
  count = local.otlp_collector ? 1 : 0

  project   = var.project_id
  secret_id = google_secret_manager_secret.otel_config[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.launcher.email}"
}

# The sidecar runs as the launcher's identity: it writes traces and metrics, nothing else.
resource "google_project_iam_member" "launcher_telemetry" {
  for_each = local.otlp_collector ? toset(["roles/cloudtrace.agent", "roles/monitoring.metricWriter"]) : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.launcher.email}"
}

# A direct endpoint's token (a vendor's), when named: the launcher reads it at startup.
resource "google_secret_manager_secret_iam_member" "otlp_headers" {
  count = try(var.otlp.headers_secret, null) != null ? 1 : 0

  project   = split("/", var.otlp.headers_secret)[1]
  secret_id = split("/", var.otlp.headers_secret)[3]
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.launcher.email}"
}
