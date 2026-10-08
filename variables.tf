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
  }))
  default = { demo = {} }

  validation {
    condition     = alltrue([for t in keys(var.tenants) : can(regex("^[a-z][a-z0-9-]{0,14}$", t))])
    error_message = "Tenant names: lowercase letters, digits and hyphens, at most 15 characters."
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
  })
  default = {}
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
