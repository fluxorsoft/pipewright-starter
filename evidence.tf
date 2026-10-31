/**
 * The event log (Pipewright 1.2.0, FR-84): every Pipewright lifecycle event, as published on the events topic, kept in
 * BigQuery. Without a subscription Pub/Sub discards what is published, so promotions, approvals, deployments and
 * retrain decisions would leave no record. Ported from Pipewright Enterprise's observability module, without CMEK.
 * Off with event_log = false. The manifest names the dataset (observability.evidence_dataset), where
 * `pipewright lineage` reads a model's decisions.
 */

resource "google_bigquery_dataset" "evidence" {
  count = var.event_log ? 1 : 0

  dataset_id                 = "${replace(local.p, "-", "_")}_evidence"
  location                   = var.region
  description                = "Pipewright evidence: every lifecycle event, as published (append-only by design)"
  delete_contents_on_destroy = var.force_destroy
  labels                     = local.labels
}

resource "google_bigquery_table" "events" {
  count = var.event_log ? 1 : 0

  dataset_id          = google_bigquery_dataset.evidence[0].dataset_id
  table_id            = "events"
  description         = "Every Pipewright lifecycle event, as published (one row per message)"
  deletion_protection = !var.force_destroy
  labels              = local.labels

  time_partitioning {
    type  = "DAY"
    field = "publish_time"
  }

  schema = jsonencode([
    { name = "subscription_name", type = "STRING", mode = "NULLABLE" },
    { name = "message_id", type = "STRING", mode = "NULLABLE" },
    { name = "publish_time", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "attributes", type = "JSON", mode = "NULLABLE" },
    { name = "data", type = "JSON", mode = "NULLABLE" },
  ])
}

# Pub/Sub writes into the table as its service agent.
resource "google_bigquery_table_iam_member" "events_writer" {
  for_each = var.event_log ? toset(["roles/bigquery.dataEditor", "roles/bigquery.metadataViewer"]) : toset([])

  dataset_id = google_bigquery_dataset.evidence[0].dataset_id
  table_id   = google_bigquery_table.events[0].table_id
  role       = each.value
  member     = "serviceAccount:${local.pubsub_agent}"
}

resource "google_pubsub_subscription" "events_to_bigquery" {
  count = var.event_log ? 1 : 0

  name   = "${local.p}-events-to-bigquery"
  topic  = google_pubsub_topic.this["events"].id
  labels = local.labels

  bigquery_config {
    table          = "${var.project_id}.${google_bigquery_dataset.evidence[0].dataset_id}.${google_bigquery_table.events[0].table_id}"
    write_metadata = true
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [google_bigquery_table_iam_member.events_writer]
}

# Operators read the evidence; nobody but Pub/Sub writes it.
resource "google_bigquery_dataset_iam_member" "evidence_readers" {
  for_each = var.event_log ? toset(local.operators) : toset([])

  dataset_id = google_bigquery_dataset.evidence[0].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = each.value
}

# An environment that added the event log before it took event_log keeps it (no replacement).
moved {
  from = google_bigquery_dataset.evidence
  to   = google_bigquery_dataset.evidence[0]
}

moved {
  from = google_bigquery_table.events
  to   = google_bigquery_table.events[0]
}

moved {
  from = google_pubsub_subscription.events_to_bigquery
  to   = google_pubsub_subscription.events_to_bigquery[0]
}
