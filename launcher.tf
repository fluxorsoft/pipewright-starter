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
      image = var.launcher_image

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        cpu_idle = true
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
  push = local.deployed ? {
    landing      = { topic = google_pubsub_topic.this["landing"].id, path = "/pubsub" }
    run-requests = { topic = google_pubsub_topic.this["run-requests"].id, path = "/pubsub/run" }
  } : {}
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
