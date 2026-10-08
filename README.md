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
| Identities | `pw-launcher` service account; a runner service account per team (`pw-<team>-run`); IAM so each runner reads only its team's landing and samples prefixes |
| Team data | A BigQuery dataset per team (`pw_<team>`) |
| Messaging | Pub/Sub topics `pw-landing`, `pw-run-requests`, `pw-events`, `pw-dead-letters`, and one per approver group |
| Launcher | Cloud Run service `pw-launcher` (IAM authenticated), its push subscriptions, Cloud Scheduler jobs for retrain decisions |
| Manifest | `gs://<project>-pw-artifacts/pipewright/environment.json`: what app teams point their environment file at |

## Before you start

- A Google Cloud project with billing enabled, and permission to create the resources above (Owner is simplest).
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.9 or later, the
  [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) (`gcloud auth application-default login`), Docker
  and [uv](https://docs.astral.sh/uv/).
- A Pipewright checkout next to this one:

```bash
git clone https://github.com/fluxorsoft/pipewright.git
git clone <this repository> pipewright-starter
```

## Build the environment

Two applies: the images repository has to exist before the launcher image can be pushed to it.

```bash
cd pipewright-starter
cp terraform.tfvars.example terraform.tfvars        # set project_id, your teams, operators and approvers
terraform init
terraform plan -out=env.tfplan                       # review, then:
terraform apply env.tfplan

scripts/publish_launcher.sh "$(terraform output -raw images_repository)"
# prints .../pipewright-launcher@sha256:...  -> set launcher_image in terraform.tfvars

terraform plan -out=env.tfplan && terraform apply env.tfplan
terraform output -raw environment_file               # save as environments/dev.yaml in your MLOps repository
```

Behind a TLS-inspecting proxy, set `PIP_CA=<ca-bundle.pem>` for `publish_launcher.sh`, or run Terraform in Docker
with the bundle mounted (`SSL_CERT_FILE`).

## Your first use case

In a new folder for your team's MLOps repository, with `environments/dev.yaml` from the output above:

```bash
python3.11 -m venv .venv && . .venv/bin/activate
pip install "../pipewright[gcp]"                    # the pipewright command
gcloud storage cp ../pipewright/examples/churn/data/sample_customers.csv \
  "gs://$(terraform -chdir=../pipewright-starter output -raw landing_bucket)/samples/demo/customers.csv"

git init
pipewright new-usecase --name churn --tenant demo --owner my-team
pipewright validate --env dev
pipewright doctor --env dev
pipewright tables sync --env dev
git add -A && git commit -m "churn: first release"
pipewright release --env dev

# Start training by dropping a file under the team's landing prefix:
gcloud storage cp ../pipewright/examples/churn/data/sample_customers.csv \
  "gs://<landing bucket>/incoming/demo/customers.csv"
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
