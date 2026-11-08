/**
 * Serving (Pipewright 1.4.2): endpoints in Terraform, public or private (FR-92), and shared pools for model co-hosting
 * (FR-105). Off until serving.yaml says otherwise (copy serving.yaml.example); everything here is created only for
 * what it turns on, and the manifest's `serving` section tells Pipewright what exists.
 *
 * Endpoints: one per listed use case, named <use case>-endpoint, with Pipewright's labels. Terraform ignores the
 * models deployed on it and their traffic: `pipewright deploy-model` deploys them as before.
 * Private endpoints: Private Service Connect, made in the network by Agent Platform (a service connection policy for
 * service class gcp-vertexai and its subnet), a private DNS zone for prediction.p.vertexai.goog and a record per
 * endpoint at the address Agent Platform made. Agent Platform endpoints cannot reach into the network; callers inside
 * it, or the lookup gateway (lookup.mode gateway), call them.
 * Pools: declared here for the manifest; created by `pipewright serving pools apply` (managed_by ci, the default) or
 * here (managed_by terraform).
 */

locals {
  serving_file      = try(yamldecode(file("${path.root}/${var.serving_file}")), {})
  serving_endpoints = try({ for k, v in local.serving_file.endpoints : k => v }, {})
  serving_private   = { for k, v in local.serving_endpoints : k => v if try(v.private, false) }
  serving_psc       = length(local.serving_private) > 0
  serving_pools = { for k, v in try({ for k, v in local.serving_file.pools : k => v }, {}) : k => merge({
    min_replicas = 1, max_replicas = 1, cpu_target = 60, network = "standard", managed_by = "ci"
  }, v) }
  serving_network = !local.serving_psc ? null : coalesce(try(local.serving_file.private.network, null),
  local.online_sql ? google_compute_network.online[0].id : "")
  # Endpoint IDs are numbers chosen by the creator (at most 10 digits, no leading zero): stable per use case.
  serving_ids = { for k, v in local.serving_endpoints : k => tostring(1000000000 + parseint(substr(sha256("${var.environment}/${k}"), 0, 7), 16)) }
}

resource "terraform_data" "serving_checks" {
  count = length(local.serving_file) == 0 ? 0 : 1
  input = keys(local.serving_endpoints)
  lifecycle {
    precondition {
      condition     = !local.serving_psc || local.serving_network != ""
      error_message = "serving.yaml: private endpoints need a network. Turn on the Cloud SQL online store (its network is used) or set private.network."
    }
    precondition {
      condition     = alltrue([for k, v in local.serving_endpoints : contains(keys(local.tenants), try(v.tenant, ""))])
      error_message = "serving.yaml endpoints: every endpoint names its tenant, a tenant in var.tenants."
    }
    precondition {
      condition     = alltrue([for k, v in local.serving_pools : contains(keys(local.tenants), v.tenant) && contains(["ci", "terraform"], v.managed_by) && contains(["standard", "psc"], v.network) && v.min_replicas >= 1 && v.max_replicas >= v.min_replicas])
      error_message = "serving.yaml pools: each pool names a tenant in var.tenants, managed_by ci or terraform, network standard or psc, and 1 <= min_replicas <= max_replicas."
    }
    precondition {
      condition     = alltrue([for k, v in local.serving_pools : can(regex("^(?:[a-z0-9-]+-)?docker\\.pkg\\.dev/vertex-ai(?:-restricted)?/prediction/(tf2|pytorch)-(cpu|gpu)\\.[0-9]+-[0-9]+", v.image))])
      error_message = "serving.yaml pools: a pool runs Google's prebuilt TensorFlow or PyTorch serving image (Agent Platform does not co-host custom containers; those stay on dedicated machines)."
    }
  }
}

resource "google_project_service" "serving" {
  for_each           = toset(local.serving_psc ? ["networkconnectivity.googleapis.com", "dns.googleapis.com", "compute.googleapis.com"] : [])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ------------------------------------------------------------------------------------------- endpoints --

resource "google_vertex_ai_endpoint" "serving" {
  for_each     = local.serving_endpoints
  name         = local.serving_ids[each.key]
  display_name = "${each.key}-endpoint"
  description  = "Pipewright: ${each.key} (${try(each.value.private, false) ? "private" : "public"}); models are deployed by pipewright deploy-model"
  location     = var.region
  region       = var.region
  labels       = merge(local.labels, { "pipewright-usecase" = each.key, "pipewright-tenant" = each.value.tenant })

  dynamic "private_service_connect_config" {
    for_each = try(each.value.private, false) ? [1] : []
    content {
      enable_private_service_connect = true
      project_allowlist              = [var.project_id]
      psc_automation_configs {
        project_id = var.project_id
        network    = local.serving_network
      }
    }
  }
  depends_on = [google_project_service.this, google_network_connectivity_service_connection_policy.serving]
}

resource "google_vertex_ai_endpoint_iam_member" "callers" {
  provider = google-beta
  for_each = { for pair in flatten([for k, v in local.serving_endpoints : [for m in try(tolist(v.callers), []) : { key = "${k}/${m}", uc = k, member = m }]]) : pair.key => pair }
  project  = var.project_id
  location = var.region
  endpoint = google_vertex_ai_endpoint.serving[each.value.uc].name
  role     = "roles/aiplatform.user"
  member   = each.value.member
}

# ------------------------------------------------------------------------------- private endpoints --

resource "google_compute_subnetwork" "serving_psc" {
  count                    = local.serving_psc ? 1 : 0
  name                     = "${local.p}-psc"
  network                  = local.serving_network
  region                   = var.region
  ip_cidr_range            = try(local.serving_file.private.subnet, "10.61.0.0/28")
  private_ip_google_access = true
  depends_on               = [google_project_service.serving]
}

resource "google_network_connectivity_service_connection_policy" "serving" {
  count         = local.serving_psc ? 1 : 0
  name          = "${local.p}-vertexai"
  location      = var.region
  service_class = "gcp-vertexai"
  description   = "Agent Platform makes the private endpoints' addresses here (Pipewright FR-92)"
  network       = local.serving_network
  psc_config {
    subnetworks = [google_compute_subnetwork.serving_psc[0].id]
  }
  depends_on = [google_project_service.serving]
}

resource "google_dns_managed_zone" "serving_psc" {
  count       = local.serving_psc ? 1 : 0
  name        = "${local.p}-vertexai-prediction"
  dns_name    = "prediction.p.vertexai.goog."
  description = "Private endpoints' names (Pipewright FR-92); the certificate names *.prediction.p.vertexai.goog"
  visibility  = "private"
  labels      = local.labels
  private_visibility_config {
    networks {
      network_url = local.serving_network
    }
  }
  depends_on = [google_project_service.serving]
}

resource "google_dns_record_set" "serving_psc" {
  for_each     = local.serving_private
  managed_zone = google_dns_managed_zone.serving_psc[0].name
  name         = "${local.serving_ids[each.key]}-${var.region}-${local.number}.prediction.p.vertexai.goog."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_vertex_ai_endpoint.serving[each.key].private_service_connect_config[0].psc_automation_configs[0].ip_address]
}

# ----------------------------------------------------------------------------------------------- pools --

resource "google_vertex_ai_deployment_resource_pool" "serving" {
  for_each = { for k, v in local.serving_pools : k => v if v.managed_by == "terraform" }
  name     = each.key
  region   = var.region
  dedicated_resources {
    machine_spec {
      machine_type      = each.value.machine
      accelerator_type  = try(each.value.accelerator.type, null)
      accelerator_count = try(each.value.accelerator.count, null)
    }
    min_replica_count = each.value.min_replicas
    max_replica_count = each.value.max_replicas
    autoscaling_metric_specs {
      metric_name = "aiplatform.googleapis.com/prediction/online/cpu/utilization"
      target      = each.value.cpu_target
    }
  }
  lifecycle {
    prevent_destroy = true # every field rebuilds the pool, taking every model on it down
  }
  depends_on = [google_project_service.this]
}

locals {
  serving_manifest = length(local.serving_file) == 0 ? {} : {
    endpoints = { for k, v in local.serving_endpoints : k => merge({
      name     = google_vertex_ai_endpoint.serving[k].display_name
      resource = "projects/${local.number}/locations/${var.region}/endpoints/${local.serving_ids[k]}"
      private  = try(v.private, false)
      }, try(v.private, false) ? {
      dns     = trimsuffix(google_dns_record_set.serving_psc[k].name, ".")
      network = local.serving_network
    } : {}) }
    pools = { for k, v in local.serving_pools : k => merge({
      tenant     = v.tenant, machine = v.machine, min_replicas = v.min_replicas, max_replicas = v.max_replicas,
      cpu_target = v.cpu_target, image = v.image, network = v.network, managed_by = v.managed_by
      }, v.managed_by == "ci" ? { service_account = google_service_account.runner[v.tenant].email } : {},
      try(v.accelerator, null) == null ? {} : { accelerator = v.accelerator },
      v.managed_by == "terraform" ? { resource = google_vertex_ai_deployment_resource_pool.serving[k].id } : {})
    }
  }
  serving_policies = length(try({ for k, v in local.serving_file.policies : k => v }, {})) == 0 ? {} : {
    serving = { pools = local.serving_file.policies }
  }
}

variable "serving_file" {
  description = "Serving settings (FR-92, FR-105), YAML beside this configuration; absent: nothing here is created."
  type        = string
  default     = "serving.yaml"
}
