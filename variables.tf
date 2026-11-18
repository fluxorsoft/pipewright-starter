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
    # Pipewright phase 6 (FR-48): in a test environment, the production project whose feature and label tables a
    # closed retrain loop's training may read (retraining.loop.data: production). The read grant in that project and
    # any perimeter rules are yours to add (Pipewright Enterprise's blueprint makes them).
    loop_production_project = optional(string)
    online_features = optional(object({
      nodes = optional(object({ min = number, max = number }), { min = 1, max = 1 })
      views = map(object({
        feature_groups = map(list(string))
        sync           = optional(string, "0 6 * * *")
      }))
    }))
    # Pipewright FR-57 (ab_tests.tf): A/B tests for the team's use cases. {} turns on the exposure sink into the
    # team's dataset, the gateway's identity and the scheduled analysis. feed: a Pub/Sub topic for the team's own
    # tools with the tests' events; feed_exposures: also per-unit lines with a keyed hash of the unit (pseudonymised,
    # still personal data where the unit is a person: off unless the team needs it); feed_subscribers: who may attach
    # subscriptions to the feed.
    ab_test = optional(object({
      feed             = optional(bool, false)
      feed_exposures   = optional(bool, false)
      feed_subscribers = optional(list(string), [])
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
    condition     = alltrue([for v in values(var.tenants) : v.ab_test == null ? true : (!v.ab_test.feed_exposures || v.ab_test.feed)])
    error_message = "ab_test.feed_exposures needs ab_test.feed (the exposures go to the feed's topic)."
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
        # Pipewright 1.4.1: keep approved files protected while in use (the renewer), and the rollback window
        renew         = optional(bool)
        rollback_days = optional(number)
      }))
      inference = optional(string)
      # Pipewright 1.4.1 (FR-101, FR-102): pin scoring and KServe to the approved generations (default on); the
      # launcher's watch (off by default) and its interval; a time-boxed warn (until, reason).
      pin         = optional(string)
      watch       = optional(string)
      watch_every = optional(string)
      until       = optional(string)
      reason      = optional(string)
      # Pipewright 1.4.1 (FR-103): feature definitions checked against each use case's feature contract (features.tf)
      features = optional(object({
        check            = optional(string)
        built_tables     = optional(bool)
        record_reads     = optional(bool)
        fingerprint_rows = optional(bool)
        snapshot_days    = optional(number)
      }))
    }))
    # Pipewright FR-57 (found in its QA round, FR-125: the starter had no way to set them): the platform's rules for
    # A/B tests. Unset is Pipewright's defaults (allowed, no limits, overlap allow). feed_exposures comes from the
    # tenants' ab_test.feed_exposures, not from here.
    # Pipewright 1.4.3 (FR-100): who writes the model registry. runner (default, as before) or launcher: runners
    # cannot write it; the launcher registers each version after its checks (registration.tf).
    registration = optional(string)
    # Pipewright FR-149: who may write the Feature Store registry. runners_read (the default since phase 11): runners
    # only read it (registration.tf); runners_write: roles/aiplatform.user as before, which lets any runner change any
    # team's feature groups. Cost: none.
    feature_registry = optional(string)
    # Pipewright 1.4.3 (FR-130), off by default: manual makes every scoring run wait for a person (the launcher
    # holds it; `pipewright scoring approve` or the pipewright-gate workflow submits it). Cost: one small object
    # per held run in the artifacts bucket and one event; the real cost is a person deciding each run.
    batch_scoring = optional(string)
    ab_test = optional(object({
      allowed             = optional(bool)
      required_approvers  = optional(list(string))
      max_treatment_bp    = optional(number)
      min_days            = optional(number)
      overlap             = optional(string)
      required_guardrails = optional(list(string))
    }))
  })
  default = {}

  validation {
    condition     = var.policies.integrity == null ? true : (try(contains(["refuse", "warn"], var.policies.integrity.mode), true) && try(contains(["off", "warn", "refuse"], var.policies.integrity.inference), true) && try(contains(["unlocked", "locked"], var.policies.integrity.lock.mode), true) && try(contains(["on", "off"], coalesce(var.policies.integrity.pin, "on")), true) && try(contains(["on", "off"], coalesce(var.policies.integrity.watch, "off")), true) && try(can(regex("^[0-9]+[hd]$", coalesce(var.policies.integrity.watch_every, "1h"))), true) && try(can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", coalesce(var.policies.integrity.until, "2000-01-01"))), true))
    error_message = "policies.integrity: mode refuse or warn; inference off, warn or refuse; lock.mode unlocked or locked; pin and watch on or off; watch_every like 1h or 1d; until a date (YYYY-MM-DD)."
  }

  validation {
    condition     = contains(["runner", "launcher"], coalesce(var.policies.registration, "runner"))
    error_message = "policies.registration: runner or launcher."
  }

  validation {
    condition     = contains(["runners_write", "runners_read"], coalesce(var.policies.feature_registry, "runners_read"))
    error_message = "policies.feature_registry: runners_write or runners_read."
  }

  validation {
    condition     = contains(["manual", "auto"], coalesce(var.policies.batch_scoring, "auto"))
    error_message = "policies.batch_scoring: manual or auto."
  }

  validation {
    condition     = var.policies.ab_test == null ? true : (try(contains(["allow", "warn", "refuse"], coalesce(var.policies.ab_test.overlap, "allow")), true) && try(var.policies.ab_test.max_treatment_bp == null || (var.policies.ab_test.max_treatment_bp >= 1 && var.policies.ab_test.max_treatment_bp <= 9999), true) && try(var.policies.ab_test.min_days == null || var.policies.ab_test.min_days >= 1, true))
    error_message = "policies.ab_test: overlap allow, warn or refuse; max_treatment_bp from 1 to 9999; min_days at least 1."
  }
}

variable "isolate_tenant_artifacts" {
  description = "Pipewright 1.4.0: each team's runner may write only under its own pipeline root (pipeline-root/<tenant>/) in the artifacts bucket, so one team's runs cannot overwrite another team's models or evaluation records. Off keeps the starter's shared grant."
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
    Pipewright FR-131, both off by default:
      checks_environment: the GitHub environment pull request checks run in (`pipewright ci init
        --checks-environment`). A read-only identity is made for it, and only that environment's jobs may act as it.
      environments: the GitHub environments the CI identity may act in (releases, decisions, gates, promotion). Unset:
        any workflow of the repository, as before. Set it so a branch's code in another job cannot release or approve.
  EOT
  type = object({
    repository         = string
    checks_environment = optional(string)
    environments       = optional(list(string))
  })
  default = null

  validation {
    condition     = var.github == null || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github.repository))
    error_message = "github.repository: org/repo."
  }

  validation {
    condition     = var.github == null || try(var.github.checks_environment == null || !contains(coalesce(var.github.environments, []), var.github.checks_environment), true)
    error_message = "github.checks_environment must not be one of github.environments: the checks identity only reads."
  }

  validation {
    condition     = var.github == null || try(var.github.environments == null || length(var.github.environments) > 0, true)
    error_message = "github.environments: list at least one GitHub environment, or leave it unset (the whole repository)."
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

# ---------------------------------------------------------------- Pipewright 1.4.1 (FR-101, FR-102) --

variable "renewer" {
  description = "Pipewright 1.4.1: deploy the lock renewer (a separate identity and a Cloud Run job) when policies.integrity.lock.days > 0 and lock.renew is not false."
  type        = bool
  default     = true
}

variable "renewer_schedule" {
  description = "Pipewright 1.4.1: run the renewer daily. Ships false: turn it on after the live gate has passed in this environment (DATA_WRITE logs, the exclusion, the alerts and the watch's cross-identity check tested; a hold released on a test object raised the alert)."
  type        = bool
  default     = false
}

variable "data_write_logs" {
  description = "Pipewright 1.4.1 (FR-102): Cloud Storage DATA_WRITE audit logs, kept only for the artifacts bucket's model folders and contracts, so lineage and the alerts can name who wrote a file. Always on with the renewer."
  type        = bool
  default     = false
}

variable "audit_retention_days" {
  description = "Pipewright 1.4.1 (FR-102): keep Admin Activity for Agent Platform and the artifacts bucket this long in a log bucket (0: off; Cloud Logging keeps 400 days). The approval cross-check reads it."
  type        = number
  default     = 0
}

variable "audit_log_bucket_locked" {
  description = "Pipewright 1.4.1: lock the audit log bucket's retention (nobody can shorten it; the bucket cannot be deleted while it holds entries). Leave true in real environments."
  type        = bool
  default     = true
}

variable "platform_alert_emails" {
  description = "Pipewright 1.4.1: who the environment's integrity alerts email (the watch stopped, an approved file changed, the renewer unhealthy or protection running low, an override in force). Empty: no alerts."
  type        = list(string)
  default     = []
}

# Pipewright 1.4.4, the cause recorded. Both off by default; a use case can also switch each on for itself in
# usecase.yaml (monitoring.failure_records, monitoring.submit_failed). They take effect at a use case's next release.
variable "failure_records" {
  description = <<-EOT
    Every use case released in this environment records why a failed step failed (no data values), and run.failed
    carries the cause and whose it is: the team's or the platform's. Also lets an agent identity read the
    launcher's runs/failed/ markers, where the cause is kept.
  EOT
  type        = bool
  default     = false
}

variable "submit_failed" {
  description = <<-EOT
    A run the orchestrator refuses at submission (a machine the region cannot provide, a refused permission) is
    recorded as run.submit_failed, and a refusal that cannot get better is not retried.
  EOT
  type        = bool
  default     = false
}

# Pipewright 1.4.4, Pipewright Assist (preview). Off by default. This is the platform's switch: each team still opts
# in for itself (assist: { enabled: true, understood: "1.4.4" } in its usecase.yaml) after reading
# `pipewright assist explain`. Assist answers incident questions from what Pipewright recorded; it reads no data
# rows or logs and changes nothing. The model is called in this project, as the person asking, at Google's prices.
variable "assist" {
  description = <<-EOT
    Allow Pipewright Assist (preview) in this environment: teams may then switch it on for their use cases. Turn on
    failure_records too: without recorded causes Assist can only say "read the logs".
  EOT
  type        = bool
  default     = false
}

variable "assist_settings" {
  description = <<-EOT
    What Assist runs with, when assist is true. model: the Gemini model (default gemini-3.8-flash). location: where
    it is called (default global; the fast model runs only there). screening_template: a Model Armor template
    (projects/<project>/locations/<location>/templates/<name>) to screen questions, tool text and answers; without
    one every answer says it was not screened. questions_per_month: per team (counted; default 200).
  EOT
  type = object({
    model               = optional(string)
    location            = optional(string)
    screening_template  = optional(string)
    questions_per_month = optional(number)
  })
  default = {}
}

variable "otlp" {
  description = <<-EOT
    Pipewright FR-127, off by default (null): the launcher's metrics and traces over OpenTelemetry (telemetry.tf).
    {} runs Google's OpenTelemetry Collector as a sidecar, sending to Cloud Trace and Managed Service for Prometheus.
    endpoint: send straight to an OTLP/HTTP backend instead (https; Grafana Cloud, a vendor), with headers_secret a
    Secret Manager version holding key=value headers (a token). sample_ratio: the share of traces kept (default 1).
    cpu_always: instance-based billing, so telemetry is sent at once (default false). collector_image: pin another
    build of the Collector (default otelcol-google 0.141.0).
  EOT
  type = object({
    endpoint        = optional(string)
    headers_secret  = optional(string)
    sample_ratio    = optional(number)
    cpu_always      = optional(bool)
    collector_image = optional(string)
  })
  default = null

  validation {
    condition     = var.otlp == null || try(var.otlp.endpoint == null || startswith(var.otlp.endpoint, "https://"), true)
    error_message = "otlp.endpoint: an https URL (plain http only to the sidecar, which the starter sets itself)."
  }

  validation {
    condition     = var.otlp == null || try(var.otlp.headers_secret == null || can(regex("^projects/[^/]+/secrets/[^/]+/versions/[^/]+$", var.otlp.headers_secret)), true)
    error_message = "otlp.headers_secret: projects/<project>/secrets/<name>/versions/<version>."
  }
}
