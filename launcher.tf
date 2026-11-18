/**
 * The shared launcher: Cloud Run with IAM authentication (no public access), its push subscriptions and who may
 * call it. Created once var.launcher_image is set (two applies: the images repository must exist first).
 */

# Pub/Sub mints the OIDC tokens it pushes with, as the launcher identity.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.launcher.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.pubsub_agent}"

  depends_on = [google_project_service_identity.this]
}

resource "google_cloud_run_v2_service" "launcher" {
  count = local.deployed ? 1 : 0

  project             = var.project_id
  name                = local.launcher_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL" # reachable, but every call needs an authorised identity
  deletion_protection = !var.force_destroy
  labels              = local.labels

  template {
    service_account                  = google_service_account.launcher.email
    timeout                          = "300s"
    max_instance_request_concurrency = 20
    labels                           = local.labels

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    containers {
      name  = local.otlp_collector ? "launcher" : null # named only beside the FR-127 sidecar
      image = var.launcher_image

      # FR-127: with a sidecar, Cloud Run needs the serving container's port named
      dynamic "ports" {
        for_each = local.otlp_collector ? [1] : []
        content {
          container_port = 8080
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        cpu_idle = !try(var.otlp.cpu_always, false)
      }

      env {
        name  = "MANIFEST_URI"
        value = "gs://${google_storage_bucket.artifacts.name}/${google_storage_bucket_object.manifest.name}"
      }

      # The app loads the manifest and live contracts at startup; an unreadable manifest fails the revision.
      startup_probe {
        initial_delay_seconds = 2
        period_seconds        = 5
        failure_threshold     = 12
        timeout_seconds       = 4
        http_get {
          path = "/health"
        }
      }
    }

    # FR-127: Google's build of the OpenTelemetry Collector beside the launcher (telemetry.tf). The launcher does not
    # wait for it: a Collector that does not start costs telemetry, never runs.
    dynamic "containers" {
      for_each = local.otlp_collector ? [1] : []
      content {
        name  = "otel-collector"
        image = try(var.otlp.collector_image, null) != null ? var.otlp.collector_image : "us-docker.pkg.dev/cloud-ops-agents-artifacts/google-cloud-opentelemetry-collector/otelcol-google:0.141.0"
        args  = ["--config=/etc/otelcol-google/config.yaml"]
        resources {
          limits = {
            cpu    = "1"
            memory = "256Mi"
          }
          cpu_idle = !try(var.otlp.cpu_always, false)
        }
        volume_mounts {
          name       = "otel-config"
          mount_path = "/etc/otelcol-google/"
        }
        startup_probe {
          period_seconds    = 5
          failure_threshold = 12
          http_get {
            path = "/"
            port = 13133
          }
        }
      }
    }

    dynamic "volumes" {
      for_each = local.otlp_collector ? [1] : []
      content {
        name = "otel-config"
        secret {
          secret = google_secret_manager_secret.otel_config[0].secret_id
          items {
            version = google_secret_manager_secret_version.otel_config[0].version
            path    = "config.yaml"
          }
        }
      }
    }
  }

  depends_on = [google_storage_bucket_iam_member.launcher_artifacts, google_project_iam_member.launcher]
}

# The launcher identity (Pub/Sub pushes, Cloud Scheduler) and the tenant runners may call the launcher.
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  for_each = local.deployed ? merge({ launcher = "serviceAccount:${google_service_account.launcher.email}" }, local.runner_members) : {}

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.launcher[0].name
  role     = "roles/run.invoker"
  member   = each.value
}

locals {
  push = local.deployed ? merge({
    landing      = { topic = google_pubsub_topic.this["landing"].id, path = "/pubsub" }
    run-requests = { topic = google_pubsub_topic.this["run-requests"].id, path = "/pubsub/run" }
    }, var.serving_health ? {
    incidents = { topic = google_pubsub_topic.incidents[0].id, path = "/incidents" } # 1.4.3 (FR-98)
  } : {}) : {}
}

resource "google_pubsub_subscription" "push" {
  for_each = local.push

  project                    = var.project_id
  name                       = "${local.launcher_name}-${each.key}"
  topic                      = each.value.topic
  ack_deadline_seconds       = 300
  message_retention_duration = "86400s"
  labels                     = local.labels

  push_config {
    push_endpoint = "${local.launcher_url}${each.value.path}"
    oidc_token {
      service_account_email = google_service_account.launcher.email
      audience              = local.launcher_url
    }
  }

  expiration_policy {
    ttl = ""
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.this["dead-letters"].id
    max_delivery_attempts = 5
  }

  depends_on = [google_cloud_run_v2_service_iam_member.invoker, google_service_account_iam_member.pubsub_token_creator]
}

# The Pub/Sub service agent acknowledges dead-lettered messages on the source subscription.
resource "google_pubsub_subscription_iam_member" "push_dead_letters" {
  for_each = google_pubsub_subscription.push

  project      = var.project_id
  subscription = each.value.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${local.pubsub_agent}"
}
