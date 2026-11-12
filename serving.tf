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
  # The gateway's predict grant: with serving.yaml (private endpoints, pools) as before, or with online_store.yaml
  # lookup.gateway (1.4.2): a gateway in front of a public endpoint had no grant and every call answered 403
  # (found writing the book's Chapter 23).
  serving_gateway = length(local.sql_tenants) > 0 && (length(local.serving_file) > 0 || try(local.online_file.lookup.gateway, false) == true)
  serving_pools = { for k, v in try({ for k, v in local.serving_file.pools : k => v }, {}) : k => merge({
    min_replicas = 1, max_replicas = 1, cpu_target = 60, network = "standard", managed_by = "ci"
  }, v) }
  serving_network = !local.serving_psc ? null : coalesce(try(local.serving_file.private.network, null),
  local.online_sql ? google_compute_network.online[0].id : "")
  # Endpoint IDs are numbers chosen by the creator (at most 10 digits, no leading zero): stable per use case.
  # A deleted endpoint's ID stays reserved for a while: a rebuild soon after a teardown sets id_salt in serving.yaml
  # (1.4.2; empty by default, the IDs unchanged).
  serving_salt = try(tostring(local.serving_file.id_salt), "")
  # An endpoint with capture gets an ID of its own (GA QA): the ID is fixed at creation, so a change of capture makes
  # a new endpoint (a private endpoint's logging is set only at creation). Without capture the ID is as before.
  serving_ids = { for k, v in local.serving_endpoints : k => tostring(1000000000 + parseint(substr(sha256("${var.environment}/${k}${local.serving_salt == "" ? "" : "/${local.serving_salt}"}${try(v.capture.sample_rate, null) == null ? "" : "/capture-${v.capture.sample_rate}"}"), 0, 7), 16)) }
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

  # 1.4.3 (FR-98, GA QA): capture on an endpoint Terraform makes. Agent Platform takes request-response logging on a
  # private (PSC) endpoint only when the endpoint is created, so it is set here, from the platform's serving.yaml
  # (endpoints.<use case>.capture.sample_rate), into the tenant's <use case>_online_log; changing it recreates the
  # endpoint (undeploy first). BigQuery storage and streaming at list prices (capture's own costs, SERVING.md).
  dynamic "predict_request_response_logging_config" {
    for_each = try(each.value.capture.sample_rate, null) != null ? [1] : []
    content {
      enabled       = true
      sampling_rate = tonumber(each.value.capture.sample_rate)
      bigquery_destination {
        output_uri = "bq://${var.project_id}.${local.tenants[each.value.tenant].dataset}.${replace(lower(each.key), "/[^a-z0-9_]/", "_")}_online_log"
      }
    }
  }

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

# The lookup gateway (FR-106): each tenant's lookup identity may predict, and only that. Found live: a private endpoint
# checks aiplatform.endpoints.predict on the project, not on the endpoint (an endpoint-level grant is refused), so the
# grant is project-wide; a custom role keeps it to that one permission.
resource "google_project_iam_custom_role" "gateway_predict" {
  count       = local.serving_gateway || local.ab_any ? 1 : 0
  project     = var.project_id
  role_id     = replace("${local.p}_gateway_predict", "-", "_")
  title       = "Pipewright lookup gateway: predict"
  description = "Call Agent Platform endpoints, nothing else (Pipewright FR-106)"
  permissions = ["aiplatform.endpoints.predict"]
}

resource "google_project_iam_member" "gateway_predict" {
  for_each = toset(concat(local.serving_gateway ? tolist(local.sql_tenants) : [], keys(local.ab_tenants)))
  project  = var.project_id
  role     = google_project_iam_custom_role.gateway_predict[0].id
  member   = "serviceAccount:${google_service_account.lookup[each.value].email}"
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
  count    = local.serving_psc ? 1 : 0
  name     = "${local.p}-vertexai-prediction"
  dns_name = "prediction.p.vertexai.goog."
  # deploy-model writes each endpoint's record here (Terraform cannot know the address), so a destroy removes them
  # with the zone (found live: the zone could not be deleted with records in it).
  force_destroy = true
  description   = "Private endpoints' names (Pipewright FR-92); the certificate names *.prediction.p.vertexai.goog"
  visibility    = "private"
  labels        = local.labels
  private_visibility_config {
    networks {
      network_url = local.serving_network
    }
  }
  depends_on = [google_project_service.serving]
}

# The endpoints' records: Agent Platform makes a private endpoint's address with its first deployed model (found
# live), so Terraform cannot know it here; deploy-model writes the record into this zone once the address exists.

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
  # Always an object (empty maps without serving.yaml); manifest.tf adds it only when the file exists. A `? {} :`
  # here made Terraform unify endpoints and pools into one map type, as strings (found live, book Chapter 24).
  serving_manifest = {
    # One object per endpoint and pool, every key present (null when it does not apply): merge() with a conditional
    # {} made a map, which turned booleans and numbers into strings the manifest schema refuses (found applying
    # serving.yaml live for the book's Chapter 24).
    endpoints = { for k, v in local.serving_endpoints : k => {
      name     = google_vertex_ai_endpoint.serving[k].display_name
      resource = "projects/${local.number}/locations/${var.region}/endpoints/${local.serving_ids[k]}"
      private  = try(tobool(v.private), false)
      dns      = try(tobool(v.private), false) ? "${local.serving_ids[k]}-${var.region}-${local.number}.prediction.p.vertexai.goog" : null
      dns_zone = try(tobool(v.private), false) ? google_dns_managed_zone.serving_psc[0].name : null
      network  = try(tobool(v.private), false) ? local.serving_network : null
    } }
    pools = { for k, v in local.serving_pools : k => {
      tenant          = v.tenant, machine = v.machine, min_replicas = tonumber(v.min_replicas)
      max_replicas    = tonumber(v.max_replicas), cpu_target = tonumber(v.cpu_target), image = v.image
      network         = v.network, managed_by = v.managed_by
      service_account = v.managed_by == "ci" ? google_service_account.runner[v.tenant].email : null
      accelerator     = try(v.accelerator, null)
      resource        = v.managed_by == "terraform" ? google_vertex_ai_deployment_resource_pool.serving[k].id : null
    } }
  }
  # 1.4.3 (found in the GA QA): the FR-98 rules too (capture limits, health required, scale to zero), which the
  # starter could not set; Enterprise's platform file already had them. Off unless serving_policy is set.
  # Each part is JSON text, so every branch of a conditional has one type (found in the FR-129 live test: objects
  # with different attributes in the two branches failed the plan as soon as serving_policy was set).
  serving_rule_parts = var.serving_policy == null ? [] : [
    var.serving_policy.capture == null ? "{}" : jsonencode({ capture = { for k, v in var.serving_policy.capture : k => v if v != null } }),
    var.serving_policy.health_required == null ? "{}" : jsonencode({ health = { required = var.serving_policy.health_required } }),
    var.serving_policy.scale_to_zero == null ? "{}" : jsonencode({ scale_to_zero = var.serving_policy.scale_to_zero }),
  ]
  pool_rules_json = length(try({ for k, v in local.serving_file.policies : k => v }, {})) == 0 ? "{}" : jsonencode({
    pools = local.serving_file.policies
  })
  serving_rules_merged = merge(jsondecode(local.pool_rules_json), [for s in local.serving_rule_parts : jsondecode(s)]...)
  serving_policies     = jsondecode(length(local.serving_rules_merged) == 0 ? "{}" : jsonencode({ serving = local.serving_rules_merged }))
}

variable "serving_file" {
  description = "Serving settings (FR-92, FR-105), YAML beside this configuration; absent: nothing here is created."
  type        = string
  default     = "serving.yaml"
}
