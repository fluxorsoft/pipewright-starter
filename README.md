# Pipewright starter environment

Terraform for a Google Cloud environment that [Pipewright](https://github.com/fluxorsoft/pipewright) (open source)
can use: one project, everything Pipewright needs, ready for an ML team to release its first use case.

It is meant for trying Pipewright and for development environments: public endpoints with IAM authentication, no
VPC and no customer-managed keys. Regulated production environments add private networking, CMEK and guardrails on
top of the same building blocks.

## What it creates

| Building block | Resources |
|---|---|
| APIs | Agent Platform (Vertex AI), Artifact Registry, BigQuery, Cloud Run, Cloud Scheduler, IAM, Logging, Monitoring, Pub/Sub, Storage |
| Storage | `<project>-pw-artifacts` (manifest, release contracts, pipeline roots, retrain cases), `<project>-pw-landing` (files that start runs; deleted after 30 days) |
| Registries | `pw-images` (Docker: component images, the launcher), `pw-pipelines` (KFP: pipeline templates) |
| Identities | `pw-launcher` service account; a runner service account per team (`pw-<team>-run`); IAM so each runner reads only its team's landing and samples prefixes; for operators, a custom role that may manage log-based alert rules only (`alerts sync`, from CI too) |
| Team data | A BigQuery dataset per team (`pw_<team>`) |
| Messaging | Pub/Sub topics `pw-landing`, `pw-run-requests`, `pw-events`, `pw-dead-letters`, and one per approver group |
| Launcher | Cloud Run service `pw-launcher` (IAM authenticated), its push subscriptions, Cloud Scheduler jobs for retrain decisions |
| Manifest | `gs://<project>-pw-artifacts/pipewright/environment.json`: what app teams point their environment file at |
| Event log | BigQuery dataset `pw_evidence`, table `events`: every lifecycle event, kept by a Pub/Sub subscription (`event_log = false` turns it off) |
| Image cleanup | Untagged images older than 30 days are deleted (`image_retention_days`); every image Pipewright pushes is tagged |
| Optional: CI | `github = { repository = "org/repo" }`: a Workload Identity pool and provider for that repository, a CI service account among the operators (`ci.tf`) |
| Optional: online features | `tenants.<team>.online_features`: a Feature Store online store per team, with its feature views (`online_features.tf`) |
| Optional: other online stores | `online_store.yaml` (copy `online_store.yaml.example`): Cloud SQL for PostgreSQL with a private network, sync jobs and lookup identities, and/or a BigQuery BI Engine reservation (`online_stores.tf`, FR-104) |
| Optional: serving | `serving.yaml` (copy `serving.yaml.example`): the use cases' endpoints in Terraform, public or private (Private Service Connect, private DNS), and shared pools for co-hosting (`serving.tf`, 1.4.2) |
| Optional: A/B tests | `tenants.<team>.ab_test = {}`: the exposure log sink into the team's dataset, the gateway's identity, the scheduled analysis in the team's job; `feed = true` adds a Pub/Sub topic for the team's own tools (`ab_tests.tf`, Pipewright FR-57) |
| Optional: AI build assistance | `tenants.<team>.agent_identity = true`: an agent service account per team with metadata-only roles, impersonated by the team's members, named in the manifest for `pipewright mcp` (`ai.tf`, Pipewright 1.3.0); `tenants.<team>.feature_datasets`: the feature tables' datasets the team may read (read-only for the runner, schemas only for the agent) |

## Before you start

- A Google Cloud project with billing enabled, and permission to create the resources above (Owner is simplest).
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.9 or later, the
  [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud auth application-default login`), Docker
  (to copy the launcher image into your registry) and Python 3.11 (for the `pipewright` command).
- This repository:

```bash
git clone https://github.com/fluxorsoft/pipewright-starter.git
```

You do not need a Pipewright checkout: the CLI comes from PyPI and the launcher image from GitHub Container
Registry. Clone [Pipewright](https://github.com/fluxorsoft/pipewright) next to this one only if you want to build
the launcher from source (`scripts/publish_launcher.sh <repository> --build`, which also needs
[uv](https://docs.astral.sh/uv/)).

## Build the environment

Two applies: the images repository has to exist before the launcher image can be pushed to it.

```bash
cd pipewright-starter
cp terraform.tfvars.example terraform.tfvars        # set project_id, your teams, operators and approvers
terraform init
terraform plan -out=env.tfplan                       # review, then:
terraform apply env.tfplan

scripts/publish_launcher.sh "$(terraform output -raw images_repository)"     # copies the released 1.4.2 launcher
# prints .../pipewright-launcher@sha256:...  -> set launcher_image in terraform.tfvars

terraform plan -out=env.tfplan && terraform apply env.tfplan
terraform output -raw environment_file               # save as environments/dev.yaml in your MLOps repository
```

The script copies the 1.4.2 launcher image (`ghcr.io/fluxorsoft/pipewright-launcher`, public) into your images
repository by digest, and fails unless the stored digest equals the released one. For another release, pass
`--from ghcr.io/fluxorsoft/pipewright-launcher@sha256:<digest from its release notes>`.

Behind a TLS-inspecting proxy, run Terraform in Docker with the bundle mounted (`SSL_CERT_FILE`); when building the
launcher with `--build`, also set `PIP_CA=<ca-bundle.pem>`.

## Your first use case

In a new folder for your team's MLOps repository, with `environments/dev.yaml` from the output above:

```bash
python3.11 -m venv .venv && . .venv/bin/activate
pip install "pipewright-mlops[gcp]==1.4.2"          # the pipewright command, from PyPI
curl -sSLO https://raw.githubusercontent.com/fluxorsoft/pipewright/v1.4.2/examples/churn/data/sample_customers.csv
gcloud storage cp sample_customers.csv \
  "gs://$(terraform -chdir=../pipewright-starter output -raw landing_bucket)/samples/demo/customers.csv"

git init
pipewright new-usecase --name churn --tenant demo --owner my-team
pipewright validate --env dev
pipewright doctor --env dev
pipewright tables sync --env dev
git add -A && git commit -m "churn: first release"
pipewright release --env dev

# Start training by dropping a file under the team's landing prefix:
gcloud storage cp sample_customers.csv "gs://<landing bucket>/incoming/demo/customers.csv"
```

The run appears in the Google Cloud console under Agent Platform, Pipelines. When it has finished, make the trained
model the champion with `pipewright model approve --env dev --usecase churn --version 1 --approve`, then score new
data:

```bash
pipewright run --env dev --usecase churn --pipeline inference \
  --source-uri gs://<landing bucket>/samples/demo/customers.csv
```

The [Pipewright README](https://github.com/fluxorsoft/pipewright) and its `docs/ONBOARDING.md` cover the rest:
schedules, alerts, retrain decisions, serving and CI.

## CI with GitHub Actions

Set `github = { repository = "your-org/your-repo" }` and apply: the repository's workflows can then act as
`pw-github-ci@<project>`, which is an operator, through Workload Identity Federation (no keys). Put the
`github_variables` output in the repository's GitHub environment for this environment, and generate the workflows
with `pipewright ci init --environments dev,prod`. In an environment that production promotes from, list
production's CI account in `promotion_readers`: `pipewright promote` reads this environment's images, release
contracts and models.

## Online features

A team whose model looks its features up at serving time (`model.serving.features: online`) needs an online store.
Give the team `online_features` in `terraform.tfvars`:

```hcl
tenants = {
  retail = {
    online_serving = true
    online_features = {
      views = { customer = { feature_groups = { customer_activity = ["orders_90d", "spend_90d"] } } }
    }
  }
}
```

The store is Bigtable: it costs money for as long as it exists, so remove `online_features` when you stop using
it. The feature groups must exist before the view does (the data team registers them over its BigQuery tables). A
view's first sync starts when the view is created and can fail for a minute while the Agent Platform service
agent's new read access on the team's dataset takes effect (`bigtable.tables.mutateRows` denied); sync it again,
and `pipewright doctor` warns of a view whose sync has not finished.

### Cheaper online stores: Cloud SQL and BigQuery

Bigtable costs about $781 a month per node. For modest traffic, copy `online_store.yaml.example` to
`online_store.yaml` and turn on what your teams need. Every key is listed there with its default and its cost.

```yaml
cloudsql:
  tier: db-custom-1-3840        # about $61 a month; checked against the machine types Cloud SQL offers
  availability: zonal           # regional: high availability, about twice the compute
  tenants: [retail]             # each gets a sync job (its runner) and a lookup identity
bigquery:
  bi_engine_gib: 1              # about $38 a month per GiB
lookup:
  defaults: { min_instances: 0, cpu_boost: true, billing: request }
  limits:   { max_instances: 10, min_min_instances: 0 }   # set the floor to 1 in production
```

Apply, then run the setup job once. It creates the database and each team's grants as the admin identity, with no
password user:

```bash
gcloud run jobs execute pw-online-setup --region <region> --wait
```

Teams then set `model.serving.online_store` in their use case and add a schedule with `pipeline: online_sync`;
`pipewright deploy-model` creates their lookup service. Grants this adds:

| Who | Grant | Why |
|---|---|---|
| `pw-online-admin` | IAM database user with `cloudsqlsuperuser`; `cloudsql.client`, `cloudsql.instanceUser`; read on the manifest | the one-time setup |
| each listed team's runner | IAM database user; `cloudsql.client`, `cloudsql.instanceUser`; with `isolate_tenant_artifacts`, write on `online-export/<team>/` and `online-sync/<team>/` | runs the sync |
| `pw-pwl-<team>` | IAM database user; `cloudsql.client`, `cloudsql.instanceUser` | runs the team's lookup services |
| the launcher | `run.admin`; act as the lookup identities and runners; `cloudsql.viewer`; create under `online-sync/`; `bigquery.jobs.listAll` (with BI Engine) | starts syncs, creates lookup services pinned to the database's CA, alerts on billed lookups |
| each `export_readers` identity | `storage.objectViewer` on `online-export/<team>/` only (listing by prefix) | a team's own store loads the Parquet export |

Also in `online_store.yaml` (1.4.2, each off or harmless by default):

- `lookup.gateway: true` grants each team's lookup identity predict on Agent Platform endpoints (a predict-only custom
  role), which the lookup gateway needs; with `serving.yaml` it is granted already.
- `lookup.egress: ALL_TRAFFIC` sends the lookup services' traffic through the network, so the gateway can reach a
  team's own store on Cloud Run with internal ingress (the default, `PRIVATE_RANGES_ONLY`, reaches it at its public
  address, which internal ingress refuses).
- `export_readers` (per team): who may read the team's Parquet export, for a store the team builds; the team then gets
  a sync job, so an `online_sync` schedule publishes the export. A team behind the gateway also needs a Cloud SQL
  tenancy (`cloudsql.tenants`): its network and lookup identity come from there.

`pipewright deploy-model --undeploy` removes a use case's lookup service through the launcher (1.4.2), which also
lets the online network go at teardown once Cloud Run releases its address (a few hours after the last service).

### Endpoints in Terraform, private endpoints and shared pools (1.4.2)

Copy `serving.yaml.example` to `serving.yaml` to create the use cases' endpoints in Terraform, public or private
(Private Service Connect, with a private DNS zone that `deploy-model` writes the address into), and shared pools that
several models deploy on (`model.serving.pool`). `id_salt` changes the endpoints' IDs for a rebuild soon after a
teardown (a deleted endpoint's ID stays reserved for a while). Every key is in the example with its cost; the guide is
Pipewright's [docs/SERVING.md](https://github.com/fluxorsoft/pipewright/blob/main/docs/SERVING.md).

The full guide (costs, performance, the sync, building your own store from the Parquet export) is Pipewright's
[docs/ONLINE_STORES.md](https://github.com/fluxorsoft/pipewright/blob/main/docs/ONLINE_STORES.md).

## A/B tests

Give the team `ab_test` in `terraform.tfvars` to test a candidate model against the champion on live traffic or in
batch scoring (`pipewright ab`):

```hcl
tenants = {
  churn = {
    ab_test = {}                        # the exposure sink, the gateway's identity, the scheduled analysis
    # ab_test = { feed = true, feed_subscribers = ["serviceAccount:tools@example.com"] }
  }
}
```

The gateway writes an exposure line per unit and call; a log sink copies them into the team's dataset (table
`pipewright_ab_exposure`) and the analysis reads them there. `feed = true` gives the team a topic with the tests'
events for its own tools; `feed_exposures = true` (with `feed`) also copies exposure lines with a keyed hash of the
unit, never the unit (the key is in Secret Manager, read only by the gateway). Where the use case's endpoint is in
`serving.yaml`, add `<usecase>-ab` beside it (same tenant and privacy): the treatment is deployed there. Log routing
is free; the exposures cost BigQuery storage (cents a month per million lines). The guide is Pipewright's
[docs/AB_TESTING.md](https://github.com/fluxorsoft/pipewright/blob/main/docs/AB_TESTING.md).

## Ray steps

Ray stays out of the starter. A team that wants Ray steps on a starter environment grants, by hand: a custom role
with `aiplatform.persistentResources.create`, `delete`, `get` and `list` to the launcher's service account, and to
each team's runner `roles/iam.serviceAccountUser` and `roles/iam.serviceAccountOpenIdTokenCreator` on itself.

## What runs is what was approved

From Pipewright 1.4.0, an approval records what it approved: the evaluation record, every
model file and the serving image, by fingerprint, and the rules of the release that trained the version. `deploy-model`
and `promote` refuse a version that is not the one approved (a changed file, a moved image tag, a default nobody
approved here). Three settings, all optional:

- `policies.integrity.mode = "warn"` says what it found and goes on, for an environment that needs it.
- `policies.integrity.lock = { days = 30 }` keeps the approved model files and release contracts from being destroyed (and a changed live copy is refused at deploy). Set
  it before the first apply and the artifacts bucket is created with object retention: each approved file is retained
  for `days`. Cloud Storage cannot add retention to an existing bucket (and Terraform leaves the bucket as it is), so
  on an environment built earlier the lock is a temporary hold on each approved file instead. `mode = "locked"`
  (retention nobody can shorten or remove, including owners) needs a bucket created with retention: use it for
  production only.
- `policies.integrity.inference = "warn"` (or `"refuse"`) checks, before a scoring run, that its default version was
  approved; the launcher then reads the event log.

`deploy-model` and `promote` also cross-check each approval with Cloud Audit Logs: whoever deploys or promotes
needs `roles/logging.viewer` for it (without it the check is a note). In a test environment that a closed retrain
loop trains in, `tenants.<team>.loop_production_project` names the production project whose tables it may read.

New in 1.4.1 (all in `integrity.tf` and `features.tf`, each off or harmless by default):

- `policies.integrity.pin` (on): scoring runs and KServe load exactly the approved file generations.
- `policies.integrity.watch = "on"` (and `watch_every`): the launcher re-checks every default and serving version and
  records `model.integrity` when a result changes; `platform_alert_emails` turns on the environment's alerts (a change,
  a released hold, renewal not healthy, an override in force, the watch's heartbeat missing).
- `policies.integrity.lock.renew` with `renewer = true`: a separate renewer identity (a Cloud Run job, `pipewright
  integrity renew`) keeps approved files locked while they serve. `renewer_schedule = true` runs it daily: turn it on
  after running the job once by hand (`gcloud run jobs execute <prefix>-renewer`) and reading its `model.lock.reconciliation`.
- `policies.integrity.until` and `reason`: a time-boxed `warn`, recorded and alerted, back to refuse after `until`.
- `data_write_logs = true`: Cloud Storage DATA_WRITE audit logs (who wrote a file), with an exclusion that keeps only
  approved folders and contracts; `audit_retention_days` routes audit entries to a log bucket kept that long
  (`audit_log_bucket_locked`, true by default, makes its retention impossible to shorten).
- `policies.integrity.features = { check = "on" }`: feature definitions checked against each use case's feature
  contract (`pipewright features contract`). `built_tables = true` adds a custom role with only
  `bigquery.jobs.listAll` and `bigquery.transfers.get` (job SQL is visible to it); `record_reads`, `fingerprint_rows`
  and `snapshot_days` record what scoring read (snapshots add a role with only `bigquery.tables.deleteSnapshot` on the
  tenant datasets).

`isolate_tenant_artifacts = true` lets each team's runner write only under its own pipeline root, so one team's runs
cannot overwrite another team's models or evaluation records.

## Notes

- **First run in a brand-new project:** Google creates Agent Platform's service agent when the first pipeline runs.
  If that first run fails with *"Vertex AI Service Agent ... does not have permission to access Artifact Registry
  repository"*, its permissions had not taken effect yet: run it again a few minutes later.
- **Costs:** the launcher scales to zero; storage, BigQuery and Pub/Sub cost little at this size. Pipeline runs and
  online endpoints are the main costs. Undeploy endpoints you are not using.
- **State:** this example keeps Terraform state locally. For a shared environment, add a `backend "gcs"` block with
  a versioned bucket.
- **Clean up:** `terraform destroy`. With `force_destroy = true` (the default here) buckets and datasets go with
  their contents. APIs stay enabled.

## Questions, help and production environments

Want help setting up Pipewright, or an environment with private networking, customer-managed keys and guardrails?
Email [hello@fluxorsoft.com](mailto:hello@fluxorsoft.com), or see
[Fluxor Software](https://www.fluxorsoft.com/pipewright.html). Questions and ideas are welcome in the Pipewright
repository's GitHub Discussions.

## License

Copyright 2026 Fluxor Software Limited. Licensed under the [Apache License, Version 2.0](LICENSE).
