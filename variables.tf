variable "project_id" {
  description = "Google Cloud project for this environment (one project per environment)."
  type        = string
}

variable "region" {
  description = "Region for every regional resource: buckets, registries, datasets, the launcher, pipelines."
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name (dev, test, prod). App teams use it as --env."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.environment))
    error_message = "Lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "name_prefix" {
  description = "Prefix of resource names, so several environments can share a project if needed."
  type        = string
  default     = "pw"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}$", var.name_prefix))
    error_message = "2 to 11 lowercase letters, digits and hyphens (service account IDs are limited to 30 characters)."
  }
}

variable "tenants" {
  description = <<-EOT
    App teams (tenants) in this environment. Each gets a runner service account, a BigQuery dataset and a landing
    prefix. members: people or groups who work on the team's use cases (they may start runs and read cases).
  EOT
  type = map(object({
    landing_prefix = optional(string)
    online_serving = optional(bool, false)
    members        = optional(list(string), [])
    # AI build assistance (Pipewright 1.3.0): an agent service account with metadata-only roles, impersonated by
    # the team's members (ai.tf); feature_datasets: project.dataset of the feature tables the team may read.
    agent_identity   = optional(bool, false)
    feature_datasets = optional(list(string), [])
    online_features = optional(object({
      nodes = optional(object({ min = number, max = number }), { min = 1, max = 1 })
      views = map(object({
        feature_groups = map(list(string))
        sync           = optional(string, "0 6 * * *")
      }))
    }))
  }))
  default = { demo = {} }

  validation {
    condition     = alltrue([for t in keys(var.tenants) : can(regex("^[a-z][a-z0-9-]{0,14}$", t))])
    error_message = "Tenant names: lowercase letters, digits and hyphens, at most 15 characters."
  }
  validation {
    condition     = alltrue(flatten([for v in values(var.tenants) : [for d in v.feature_datasets : can(regex("^[a-z][a-z0-9-]{4,61}[a-z0-9][.][A-Za-z0-9_]+$", d))]]))
    error_message = "feature_datasets: project.dataset, e.g. my-project.features."
  }
  validation {
    condition     = alltrue([for v in values(var.tenants) : v.landing_prefix == null || startswith(coalesce(v.landing_prefix, "x"), "incoming/")])
    error_message = "Landing prefixes must sit under incoming/ (the bucket notification watches that prefix), e.g. incoming/churn/."
  }
}

variable "operators" {
  description = <<-EOT
    People or CI identities who release and operate use cases (user:, group: or serviceAccount:): build and push
    images and templates, write release contracts, sync tables, schedules and alerts, start runs, approve models.
    Project owners can do all of this already.
  EOT
  type        = list(string)
  default     = []
}

variable "launcher_image" {
  description = <<-EOT
    The Pipewright launcher image, pinned by digest, in this environment's images repository
    (<region>-docker.pkg.dev/<project>/<prefix>-images/pipewright-launcher@sha256:...). Leave null on the first
    apply: the repository must exist before the image can be pushed (scripts/publish_launcher.sh).
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.launcher_image == null || can(regex("@sha256:[0-9a-f]{64}$", var.launcher_image))
    error_message = "Pin the launcher image by digest: .../pipewright-launcher@sha256:<64 hex characters>."
  }
}

variable "approver_groups" {
  description = <<-EOT
    Approver groups for retrain decisions: name -> members (group:, user: or serviceAccount:). Publishing to the
    group's topic is the membership check. Use cases list the groups they require in retraining.approvals.required.
  EOT
  type = map(object({
    members     = list(string)
    description = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for g in keys(var.approver_groups) : can(regex("^[a-z][a-z0-9-]{0,30}$", g))])
    error_message = "Approver group names: lowercase letters, digits and hyphens."
  }
}

variable "policies" {
  description = "Environment policies: who promotes and deploys models (manual or auto), and retrain decision limits."
  type = object({
    deploy_model  = optional(string, "manual")
    promote_model = optional(string, "manual")
    retraining = optional(object({
      allowed_modes      = optional(list(string))
      required_approvers = optional(list(string))
      max_snooze_days    = optional(number)
    }))
    # Pipewright phase 6: what runs is what was approved. mode refuse (Pipewright's default) or warn; lock the
    # approved model files for lock.days (turns on object retention for the artifacts bucket); inference: off, warn
    # or refuse a scoring run whose default version has no approval.
    integrity = optional(object({
      mode = optional(string)
      lock = optional(object({
        days = optional(number, 0)
        mode = optional(string, "unlocked")
      }))
      inference = optional(string)
    }))
  })
  default = {}

  validation {
    condition     = try(contains(["refuse", "warn"], var.policies.integrity.mode), true) && try(contains(["off", "warn", "refuse"], var.policies.integrity.inference), true) && try(contains(["unlocked", "locked"], var.policies.integrity.lock.mode), true)
    error_message = "policies.integrity: mode refuse or warn; inference off, warn or refuse; lock.mode unlocked or locked."
  }
}

variable "isolate_tenant_artifacts" {
  description = "Pipewright phase 6 (FR-97): each team's runner may write only under its own pipeline root (pipeline-root/<tenant>/) in the artifacts bucket, so one team's runs cannot overwrite another team's models or evaluation records. Off keeps the starter's shared grant."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels on every resource that takes them."
  type        = map(string)
  default     = {}
}

variable "landing_retention_days" {
  description = "Days before files in the landing bucket are deleted."
  type        = number
  default     = 30
}

variable "force_destroy" {
  description = "Let terraform destroy delete buckets, datasets and the launcher with their contents (test environments)."
  type        = bool
  default     = true
}

variable "github" {
  description = <<-EOT
    A CI identity for GitHub Actions in one repository (ci.tf): { repository = "org/repo" }. It becomes an operator;
    the outputs github_variables give the GitHub environment's variables. null: no CI identity.
  EOT
  type = object({
    repository = string
  })
  default = null

  validation {
    condition     = var.github == null || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github.repository))
    error_message = "github.repository: org/repo."
  }
}

variable "promotion_readers" {
  description = <<-EOT
    Identities that promote from this environment into another (the destination's CI account, usually
    serviceAccount:pw-github-ci@<prod project>.iam.gserviceaccount.com). They read the images, release contracts,
    artifacts and models `pipewright promote` copies.
  EOT
  type        = list(string)
  default     = []
}

variable "event_log" {
  description = "Keep every lifecycle event in BigQuery (evidence.tf): the record `pipewright lineage` reads decisions from."
  type        = bool
  default     = true
}

variable "image_retention_days" {
  description = <<-EOT
    Untagged images older than this are deleted by the images repository's cleanup policy. Pipewright tags every
    image it pushes, so releases keep theirs; `pipewright images prune` removes old releases' images safely.
    null: no cleanup policy.
  EOT
  type        = number
  default     = 30
}

variable "agent_audit_logs" {
  description = "AI build assistance: turn on Data Access audit logs for BigQuery, Agent Platform and Cloud Storage, so every metadata read by an agent identity is recorded (billed by volume)."
  type        = bool
  default     = false
}
