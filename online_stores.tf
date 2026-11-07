/**
 * Choosing the online feature store (Pipewright 1.4.2, FR-104): BigQuery with BI Engine and Cloud SQL for
 * PostgreSQL, next to the Bigtable online stores of online_features.tf. Off until online_store.yaml says otherwise
 * (copy online_store.yaml.example); everything here is created only for what it turns on.
 *
 * Cloud SQL: one instance per environment, a schema per team, sized in online_store.yaml (checked against the machine
 * types Cloud SQL offers), private IP only over Private Services Access (this file makes the small network it needs),
 * IAM database login and no password user, SSL required. For each tenant listed under cloudsql.tenants:
 *   - its runner syncs (a Cloud Run job, pw-sync-<tenant>, in the network, run by the launcher on schedules with
 *     pipeline online_sync) and is an IAM database user;
 *   - a lookup identity (pwl-<tenant>) runs its use cases' lookup services, which the launcher creates;
 *   - the launcher may create and update Cloud Run services (Cloud Run cannot scope that by name: the launcher only
 *     creates pwl-<tenant>-... services from live releases, spike (d)).
 * After the first apply, run the setup job once (it creates the database and the tenants' grants as the admin IAM
 * user): gcloud run jobs execute <prefix>-online-setup --region <region> --wait
 *
 * BigQuery: the environment's BI Engine reservation (one per project and region), with its preferred tables. The
 * launcher may list jobs (bigquery.jobs.listAll) to alert when lookups are billed as full table reads.
 */

locals {
  online_file  = try(yamldecode(file("${path.root}/${var.online_store_file}")), {})
  online_sql   = try(local.online_file.cloudsql, null) != null && try(local.online_file.cloudsql.enabled, true)
  online_bq    = try(local.online_file.bigquery.bi_engine_gib, 0) > 0
  online_types = try(local.online_file.types, distinct(concat(["bigtable"], local.online_sql ? ["cloudsql"] : [], local.online_bq ? ["bigquery"] : [])))
  sql_cfg = local.online_sql ? merge({
    edition             = "enterprise", tier = "db-custom-1-3840", postgres_version = "POSTGRES_16", availability = "zonal",
    deletion_protection = true, database = "features", data_cache = false, tenants = []
  }, local.online_file.cloudsql) : null
  sql_disk    = local.online_sql ? merge({ type = "ssd", size_gb = 10, autoresize = true, autoresize_limit_gb = 0 }, try(local.online_file.cloudsql.disk, {})) : null
  sql_tenants = local.online_sql ? toset(local.sql_cfg.tenants) : toset([])
  sql_name    = "${local.p}-features"
  lookup_cfg  = try(local.online_file.lookup, {})
  # Cloud SQL machine types (docs "Machine series", read 2026-11-07); also checked by pipewright doctor.
  sql_tier_ok = !local.online_sql ? true : (
    contains(["db-f1-micro", "db-g1-small"], local.sql_cfg.tier) ||
    can(regex("^db-custom-(1|[0-9]*[02468])-[0-9]+$", local.sql_cfg.tier)) ||
    can(regex("^db-custom-N4-[0-9]*[02468]-[0-9]+$", local.sql_cfg.tier)) ||
    can(regex("^db-perf-optimized-N-(2|4|8|16|32|48|64|80|96|128)$", local.sql_cfg.tier)) ||
    can(regex("^db-c4a-highmem-(2|4|8|16|32|48|64|72)$", local.sql_cfg.tier)) ||
    can(regex("^db-perf-optimized-C4-(2|4|8)$", local.sql_cfg.tier))
  )
  sql_plus_tier = local.online_sql ? can(regex("^db-(perf-optimized|c4a)", local.sql_cfg.tier)) : false
}

resource "terraform_data" "online_store_checks" {
  count = local.online_sql ? 1 : 0
  input = local.sql_cfg.tier
  lifecycle {
    precondition {
      condition     = local.sql_tier_ok
      error_message = "online_store.yaml cloudsql.tier ${local.sql_cfg.tier}: not a Cloud SQL for PostgreSQL machine type (db-f1-micro, db-g1-small, db-custom-<vCPU>-<MB>, db-custom-N4-<vCPU>-<MB>; Enterprise Plus: db-perf-optimized-N-<n>, db-c4a-highmem-<n>, db-perf-optimized-C4-<n>)."
    }
    precondition {
      condition     = contains(["enterprise", "enterprise_plus"], local.sql_cfg.edition) && (local.sql_plus_tier == (local.sql_cfg.edition == "enterprise_plus"))
      error_message = "online_store.yaml cloudsql.edition ${local.sql_cfg.edition} does not take tier ${local.sql_cfg.tier} (Enterprise Plus takes db-perf-optimized-* and db-c4a-*; Enterprise the others)."
    }
    precondition {
      condition     = contains(["zonal", "regional"], local.sql_cfg.availability)
      error_message = "online_store.yaml cloudsql.availability: zonal or regional."
    }
    precondition {
      condition     = alltrue([for t in local.sql_cfg.tenants : contains(keys(local.tenants), t)])
      error_message = "online_store.yaml cloudsql.tenants: every name must be a tenant in var.tenants."
    }
  }
}

resource "google_project_service" "online" {
  for_each = toset(concat(local.online_sql ? ["sqladmin.googleapis.com", "servicenetworking.googleapis.com", "compute.googleapis.com"] : [],
  local.online_bq ? ["bigqueryreservation.googleapis.com"] : []))
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ------------------------------------------------------------------------------------------- network --

resource "google_compute_network" "online" {
  count                   = local.online_sql ? 1 : 0
  name                    = "${local.p}-online"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.online]
}

resource "google_compute_subnetwork" "online" {
  count                    = local.online_sql ? 1 : 0
  name                     = "${local.p}-online"
  network                  = google_compute_network.online[0].id
  region                   = var.region
  ip_cidr_range            = try(local.online_file.network.subnet, "10.60.0.0/24")
  private_ip_google_access = true
}

resource "google_compute_global_address" "online_psa" {
  count         = local.online_sql ? 1 : 0
  name          = "${local.p}-online-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.online[0].id
}

resource "google_service_networking_connection" "online" {
  count                   = local.online_sql ? 1 : 0
  network                 = google_compute_network.online[0].id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.online_psa[0].name]
  deletion_policy         = "ABANDON" # Cloud SQL releases its side hours after the instance goes (spike (d))
}

# ------------------------------------------------------------------------------------------ instance --

resource "google_sql_database_instance" "online" {
  count               = local.online_sql ? 1 : 0
  name                = local.sql_name
  region              = var.region
  database_version    = local.sql_cfg.postgres_version
  deletion_protection = local.sql_cfg.deletion_protection
  encryption_key_name = try(local.online_file.cloudsql.kms_key, null)

  settings {
    edition                     = upper(local.sql_cfg.edition) # always written out: PostgreSQL 16 defaults to Enterprise Plus
    tier                        = local.sql_cfg.tier
    availability_type           = upper(local.sql_cfg.availability)
    disk_type                   = local.sql_disk.type == "hdd" ? "PD_HDD" : local.sql_disk.type == "hyperdisk" ? "HYPERDISK_BALANCED" : "PD_SSD"
    disk_size                   = local.sql_disk.size_gb
    disk_autoresize             = local.sql_disk.autoresize
    disk_autoresize_limit       = local.sql_disk.autoresize_limit_gb
    deletion_protection_enabled = local.sql_cfg.deletion_protection
    user_labels                 = local.labels

    dynamic "data_cache_config" {
      for_each = local.sql_cfg.edition == "enterprise_plus" ? [1] : []
      content { data_cache_enabled = local.sql_cfg.data_cache }
    }
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.online[0].id
      ssl_mode        = "ENCRYPTED_ONLY"
    }
    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }
    backup_configuration {
      enabled = false # the store is a copy: BigQuery holds the features, a sync rebuilds it
    }
  }
  depends_on = [google_service_networking_connection.online, terraform_data.online_store_checks]
}

# The admin IAM user creates the database and the tenants' grants (features online-setup); no password user exists.
resource "google_service_account" "online_admin" {
  count        = local.online_sql ? 1 : 0
  account_id   = "${local.p}-online-admin"
  display_name = "Pipewright online store admin (${var.environment})"
}

resource "google_sql_user" "online_admin" {
  count          = local.online_sql ? 1 : 0
  instance       = google_sql_database_instance.online[0].name
  name           = trimsuffix(google_service_account.online_admin[0].email, ".gserviceaccount.com")
  type           = "CLOUD_IAM_SERVICE_ACCOUNT"
  database_roles = ["cloudsqlsuperuser"]
}

resource "google_service_account" "lookup" {
  for_each     = local.sql_tenants
  account_id   = "${local.p}-pwl-${each.key}"
  display_name = "Pipewright lookup services: ${each.key} (${var.environment})"
}

resource "google_sql_user" "runner" {
  for_each = local.sql_tenants
  instance = google_sql_database_instance.online[0].name
  name     = trimsuffix(google_service_account.runner[each.key].email, ".gserviceaccount.com")
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_sql_user" "lookup" {
  for_each = local.sql_tenants
  instance = google_sql_database_instance.online[0].name
  name     = trimsuffix(google_service_account.lookup[each.key].email, ".gserviceaccount.com")
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_project_iam_member" "online_sql" {
  # Static keys (role|who): the emails are known only after apply.
  for_each = local.online_sql ? merge(
    { for r in ["client", "instanceUser"] : "${r}|admin" => { role = "roles/cloudsql.${r}", member = "serviceAccount:${google_service_account.online_admin[0].email}" } },
    merge([for t in local.sql_tenants : { for r in ["client", "instanceUser"] : "${r}|runner|${t}" => { role = "roles/cloudsql.${r}", member = "serviceAccount:${google_service_account.runner[t].email}" } }]...),
    merge([for t in local.sql_tenants : { for r in ["client", "instanceUser"] : "${r}|lookup|${t}" => { role = "roles/cloudsql.${r}", member = "serviceAccount:${google_service_account.lookup[t].email}" } }]...)
  ) : {}
  project = var.project_id
  role    = each.value.role
  member  = each.value.member
}

# The sync writes its staging extract and records under the tenant's own prefixes (also with isolate_tenant_artifacts).
resource "google_storage_bucket_iam_member" "runner_online" {
  for_each = var.isolate_tenant_artifacts ? local.sql_tenants : toset([])
  bucket   = google_storage_bucket.artifacts.name
  role     = "roles/storage.objectAdmin"
  member   = local.runner_members[each.key]
  condition {
    title      = "tenant-online-prefixes"
    expression = "resource.type == \"storage.googleapis.com/Bucket\" || resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/online-export/${each.key}/\") || resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/online-sync/${each.key}/\")"
  }
}

# ------------------------------------------------------------------------------------------ jobs --

resource "google_cloud_run_v2_job" "online_sync" {
  for_each = local.deployed ? local.sql_tenants : toset([])
  name     = "${local.p}-sync-${each.key}"
  location = var.region
  labels   = merge(local.labels, { "pipewright-tenant" = each.key })

  template {
    task_count = 1
    template {
      service_account = google_service_account.runner[each.key].email
      timeout         = "3600s"
      max_retries     = 1
      containers {
        image   = var.launcher_image
        command = ["pipewright"]
        args    = ["features", "sync", "--help"] # the launcher passes the use case with each run
        resources {
          limits = { cpu = "2", memory = "4Gi" } # the generation's files are read in memory
        }
      }
      vpc_access {
        network_interfaces {
          network    = google_compute_network.online[0].id
          subnetwork = google_compute_subnetwork.online[0].id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }
    }
  }
  deletion_protection = false
}

resource "google_cloud_run_v2_job" "online_setup" {
  count    = local.deployed && local.online_sql ? 1 : 0
  name     = "${local.p}-online-setup"
  location = var.region
  labels   = local.labels

  template {
    task_count = 1
    template {
      service_account = google_service_account.online_admin[0].email
      max_retries     = 0
      containers {
        image   = var.launcher_image
        command = ["pipewright"]
        args    = ["features", "online-setup", "--manifest", "gs://${google_storage_bucket.artifacts.name}/pipewright/environment.json"]
      }
      vpc_access {
        network_interfaces {
          network    = google_compute_network.online[0].id
          subnetwork = google_compute_subnetwork.online[0].id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }
    }
  }
  deletion_protection = false
}

resource "google_storage_bucket_iam_member" "online_admin_manifest" {
  count  = local.online_sql ? 1 : 0
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.online_admin[0].email}"
}

# The launcher runs the sync jobs, and creates and updates the lookup services as each tenant's lookup identity.
resource "google_project_iam_member" "launcher_run_admin" {
  count   = local.online_sql ? 1 : 0
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.launcher.email}"
}

resource "google_service_account_iam_member" "launcher_acts_as_lookup" {
  for_each           = local.sql_tenants
  service_account_id = google_service_account.lookup[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.launcher.email}"
}

resource "google_service_account_iam_member" "launcher_acts_as_runner_for_sync" {
  for_each           = local.sql_tenants
  service_account_id = google_service_account.runner[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.launcher.email}"
}

# ------------------------------------------------------------------------------------------ BigQuery --

resource "google_bigquery_bi_reservation" "online" {
  count    = local.online_bq ? 1 : 0
  location = var.region
  size     = floor(local.online_file.bigquery.bi_engine_gib * 1073741824)
  dynamic "preferred_tables" {
    for_each = try(local.online_file.bigquery.preferred_tables, [])
    content {
      project_id = split(".", preferred_tables.value)[0]
      dataset_id = split(".", preferred_tables.value)[1]
      table_id   = split(".", preferred_tables.value)[2]
    }
  }
  depends_on = [google_project_service.online]
}

resource "google_project_iam_custom_role" "online_billed" {
  count       = local.online_bq ? 1 : 0
  project     = var.project_id
  role_id     = replace("${local.p}_online_billed", "-", "_")
  title       = "Pipewright: see billed online lookups"
  description = "Pipewright FR-104: list jobs to alert when BigQuery lookups are billed as full table reads."
  permissions = ["bigquery.jobs.listAll"]
}

resource "google_project_iam_member" "launcher_online_billed" {
  count   = local.online_bq ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.online_billed[0].id
  member  = "serviceAccount:${google_service_account.launcher.email}"
}

# ------------------------------------------------------------------------------------------ manifest --

locals {
  online_manifest = length(local.online_file) == 0 ? {} : {
    online_store = merge(
      { types = local.online_types },
      local.online_bq ? { bigquery = { bi_engine_gib = local.online_file.bigquery.bi_engine_gib } } : {},
      local.online_sql ? {
        cloudsql = {
          instance   = google_sql_database_instance.online[0].connection_name
          private_ip = google_sql_database_instance.online[0].private_ip_address
          database   = local.sql_cfg.database
          settings = {
            edition = local.sql_cfg.edition, tier = local.sql_cfg.tier, availability = local.sql_cfg.availability
            disk    = { type = local.sql_disk.type, size_gb = local.sql_disk.size_gb }
          }
        }
      } : {},
      local.online_sql ? {
        lookup = merge(
          { network = google_compute_network.online[0].id, subnetwork = google_compute_subnetwork.online[0].id,
            # Agent Platform's public endpoints call from Google's network, outside the VPC: internal ingress answers
            # them 404 (found live). The service stays IAM-only (the endpoint's identity is its one invoker); private
            # endpoints over Private Service Connect (FR-92) will allow internal ingress.
          ingress = try(local.lookup_cfg.ingress, "INGRESS_TRAFFIC_ALL") },
          var.launcher_image == null ? {} : { image = var.launcher_image },
          try(local.lookup_cfg.defaults, null) == null ? {} : { defaults = local.lookup_cfg.defaults },
        try(local.lookup_cfg.limits, null) == null ? {} : { limits = local.lookup_cfg.limits })
    } : {})
  }
  online_tenant_manifest = {
    for t in local.sql_tenants : t => merge(
      { lookup_service_account = google_service_account.lookup[t].email },
    local.deployed ? { sync_job = google_cloud_run_v2_job.online_sync[t].id } : {})
  }
}

variable "online_store_file" {
  description = "The online store settings (FR-104), YAML beside this configuration; absent: nothing here is created."
  type        = string
  default     = "online_store.yaml"
}

# The launcher hands each scheduled sync its request (the manifest and the released configuration) under
# online-sync/<tenant>/<usecase>/requests/, as it hands a pipeline run its configuration (found live).
resource "google_storage_bucket_iam_member" "launcher_online_requests" {
  count  = length(local.sql_tenants) > 0 || local.online_bq ? 1 : 0
  bucket = google_storage_bucket.artifacts.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.launcher.email}"
  condition {
    title      = "online-sync-requests"
    expression = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.artifacts.name}/objects/online-sync/\")"
  }
}

# The launcher reads the instance's server CA, which it pins in each lookup service (found live: without it the
# service would encrypt but not verify the database; the launcher now refuses to create one).
resource "google_project_iam_member" "launcher_cloudsql_viewer" {
  count   = local.online_sql ? 1 : 0
  project = var.project_id
  role    = "roles/cloudsql.viewer"
  member  = "serviceAccount:${google_service_account.launcher.email}"
}
