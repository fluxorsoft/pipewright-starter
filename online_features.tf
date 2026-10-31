/**
 * Online feature lookup (Pipewright 1.1, model.serving.features online): a Feature Store online store for each tenant
 * that asks for one, with feature views over feature groups the features' owners registered.
 *
 *   tenants.<t>.online_features:
 *     nodes: { min: 1, max: 1 }    Bigtable autoscaling: a standing cost while the store exists
 *     views: { <view>: { feature_groups: { <group>: [<feature>, ...] }, sync: "0 6 * * *" } }
 *
 * The manifest names the store (tenants.<t>.features.online_store). The tenant's runner reads it: endpoints with
 * online features run as the runner (pipewright deploy-model), which has roles/aiplatform.user. A view's sync reads
 * the feature groups' BigQuery tables as the Agent Platform service agent.
 */

locals {
  online_tenants = { for t, v in local.tenants : t => v.online_features if v.online_features != null }
  online_views = merge([for t, o in local.online_tenants : {
    for name, view in o.views : "${t}|${name}" => { tenant = t, name = name, view = view }
  }]...)
  online_store_names = { for t, _ in local.online_tenants : t => replace("${local.p}_${t}_online", "-", "_") }
  aiplatform_agent   = "service-${local.number}@gcp-sa-aiplatform.iam.gserviceaccount.com"
}

resource "google_vertex_ai_feature_online_store" "tenant" {
  for_each = local.online_tenants

  name          = local.online_store_names[each.key]
  region        = var.region
  labels        = merge(local.labels, { "pipewright-tenant" = each.key })
  force_destroy = true # its views go with it

  bigtable {
    auto_scaling {
      min_node_count         = each.value.nodes.min
      max_node_count         = each.value.nodes.max
      cpu_utilization_target = 50
    }
  }
}

resource "google_vertex_ai_feature_online_store_featureview" "tenant" {
  for_each = local.online_views

  name                 = each.value.name
  region               = var.region
  feature_online_store = google_vertex_ai_feature_online_store.tenant[each.value.tenant].name
  labels               = merge(local.labels, { "pipewright-tenant" = each.value.tenant })

  feature_registry_source {
    dynamic "feature_groups" {
      for_each = each.value.view.feature_groups
      content {
        feature_group_id = feature_groups.key
        feature_ids      = feature_groups.value
      }
    }
  }

  sync_config {
    cron = each.value.view.sync
  }
}

resource "google_bigquery_dataset_iam_member" "online_feature_sync" {
  for_each = local.online_tenants

  dataset_id = google_bigquery_dataset.tenant[each.key].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${local.aiplatform_agent}"
}
