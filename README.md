# PranicDoc infra

One codebase for every environment. **UAT** is GCP Cloud Run (scale to zero, Neon Postgres). **Prod** is
the VM (`213.199.38.16`, docker-compose). Everything runs from GitHub Actions.

| Layer | Folder | Runs when | Touches |
|---|---|---|---|
| Provisioning | `tofu/` + `tofu.yml` | PR / merge → plan (`uat`); **Run workflow** (`environment`, `apply`) → secret sync + apply | Cloud Run, Secret Manager, Artifact Registry, Cloud Scheduler, WIF, budget |
| Configuration (prod VM) | `ansible/` + `ansible.yml` | PR / merge → lint; **Run workflow** → provision (dry run by default) | packages, Docker log rotation, image prune cron (`provision.yml`) |
| Deployment | `deploy-cloudrun.yml`, `deploy-vm.yml` | called by app repos after a build; **every deploy waits for an approval comment** (`approval.yml`) | Cloud Run image swap with auto-rollback · VM: Ansible `deploy.yml` (pull, restart, health check) |

## How environments work
An environment is three things with the same name, here `uat`:
1. **The GitHub Environment** `uat` (Settings → Environments). It holds the values, with the **same variable
   and secret names in every environment**. Each service has its own full database set; repeat the
   values when services share a server.
2. **`tofu/envs/uat.tfvars`**: only sizing and feature flags, committed.
3. **A GCP project**, prepared once with `scripts/bootstrap-gcp.sh <project> <billing-account>`.

The workflow takes `environment` as input and reads only that environment's values. To add a new
environment, create those three things and add its name to the `environment` options in `tofu.yml`.

Applies are manual (**Run workflow**) because the org is on GitHub Free, where private-repo
Environments can't require a reviewer.

## Variables and secrets (same names in every environment)

**Environment variables**

| Name | Meaning |
|---|---|
| `GCP_PROJECT_ID`, `GCP_PROJECT_NUMBER`, `GCP_REGION`, `GCP_BILLING_ACCOUNT`, `TF_STATE_BUCKET`, `GCP_WORKLOAD_IDENTITY_PROVIDER`, `TOFU_SERVICE_ACCOUNT` | printed by `bootstrap-gcp.sh` |
| `CPH_DB_HOST`, `CPH_DB_NAME`, `CPH_DB_USERNAME` | cph's database (direct host) |
| `CREDIT_DB_HOST`, `CREDIT_DB_NAME`, `CREDIT_DB_USERNAME` | creditService's database. It must differ from cph's: each service runs its own Flyway. |
| `PDF_WORKER_DB_HOST`, `PDF_WORKER_DB_NAME`, `PDF_WORKER_DB_USERNAME` | pdfWorker's database: **the same values as `CPH_DB_*`**, because pdfWorker polls cph's `pdf_job` table |
| `<SERVICE>_DB_PORT`, `<SERVICE>_DB_POOLER_HOST` | optional, per service: port (default 5432); PgBouncer host for app traffic (Flyway stays direct) |
| `GOOGLE_CLIENT_ID`, `R2_ENDPOINT`, `MAIL_USERNAME`, `REDIS_HOST`, `WHATSAPP_PHONE_NUMBER_ID` | app settings |

**Environment secrets**: copied into that project's Secret Manager by the apply job. Unset secrets
keep their current value.

| GitHub secret | Secret Manager |
|---|---|
| `CPH_DB_PASSWORD`, `CREDIT_DB_PASSWORD`, `PDF_WORKER_DB_PASSWORD` | `db-password`, `credit-db-password`, `pdfworker-db-password` |
| `JWT_SECRET`, `ENCRYPTION_KEY`, `INTERNAL_API_KEY` | `jwt-secret`, `encryption-key`, `internal-api-key`. **Each environment gets its own values.** |
| `GOOGLE_CLIENT_SECRET`, `R2_ACCESS_KEY`, `R2_SECRET_KEY`, `CREDIT_API_KEY`, `MAIL_PASSWORD`, `REDIS_PASSWORD` | same names, kebab-case |

**Prod VM access:** `VM_HOST`, `VM_USER`, and `VM_SSH_KEY` (preferred) or `VM_PASSWORD`. App repos pass
their repo secrets to `deploy-vm.yml`; this repo's `prod` environment holds them for `ansible.yml`. Everything
that touches the VM is Ansible (`.github/actions/ansible-vm`), so the tooling is the same everywhere.

## First run of an environment
1. **Cloud Shell** (console.cloud.google.com → **>_**): run
   `bash bootstrap-gcp.sh <project-id> <billing-account-id>`. Put the 7 variables it prints into the GitHub
   Environment.
2. Fill in the remaining variables and secrets above.
3. **Actions → OpenTofu → Run workflow:** pick the environment, run once without **apply** to see the plan,
   then again with **apply**.
4. Then:
   - set `enable_outbox_sweep = true` in `envs/<env>.tfvars` and apply again;
   - add `<cph URL>/cph/login/oauth2/code/google` as an OAuth redirect URI.

## UAT specifics
| | Prod (VM) | UAT (Cloud Run) |
|---|---|---|
| cph / creditService | ✅ | ✅ scale to zero |
| pdfWorker | ✅ (polls DB every 1 s) | ❌ PDFs stay DRAFT |
| Outbox send / sweep | async · in-process `@Scheduled` | inline · Cloud Scheduler every 30 min |
| Database | Aiven (+ PgBouncer container) | Neon, direct connections |
| R2 bucket | `pranicdoc-pdfs` | `pranicdoc-pdfs-uat` |

If the project moves into a Cloud Identity org, override `iam.allowedPolicyMemberDomains` on it.
Otherwise the `allUsers` invoker on cph and creditService is blocked.

## Releasing and deploying
Every app repo (cph, pdfWorker, credit-service) has the same three workflows; the logic lives here.

| Workflow (app repo) | When | What it does |
|---|---|---|
| **CI** | every push to the default branch and every PR (automatic) | `ci-gradle.yml` / `ci-node.yml`: build + tests. Pushes nothing. |
| **Release** | you run it | `release.yml`: needs green CI on HEAD; tags it with the next `vX.Y.Z` (patch / minor / major) and publishes a GitHub Release. |
| **Deploy** | you run it | `resolve-release.yml` → `build-image.yml` → `deploy-vm.yml` / `deploy-cloudrun.yml`. |

Deploy inputs: **tag** (`vX.Y.Z`, or empty = the default branch's latest commit), **target** (`vm` | `cloudrun`),
**environment** (`prod` | `uat`; for now `vm` must be `prod` and `cloudrun` must be `uat`), and in cph
**components** (`backend` | `ui` | `both`). It builds `<image>:<version>` at deploy time (an existing version
is reused, never rebuilt), then:
- **prod** waits for an `approve` comment on the issue it opens; `uat` doesn't.
- **VM:** `ansible/playbooks/deploy.yml` pins the services in `/opt/pranicdoc/docker-compose.override.yml`
  (written from `deployed-versions.yml`; other services keep their pins), pulls with the run's own token
  in a throwaway Docker config, restarts only those services and waits for health. If one stays
  unhealthy it puts back the previous images and still fails. One deploy at a time (`.deploy.lock`;
  if a killed run left it behind, remove that directory on the VM).
- **Cloud Run:** swaps the image and rolls traffic back if the health check fails (needs the GCP bootstrap).

**Rollback** = run Deploy with an older tag. Not across a Flyway migration: older cph code refuses a newer
schema, so a backend rollback only works between releases that didn't add a migration.

Cloud Run needs, in each app repo, a GitHub Environment `uat` with `GCP_PROJECT_ID`, `GCP_REGION`,
`GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_SERVICE_ACCOUNT` (`github-deployer@<project>.iam.gserviceaccount.com`).

## Day-2
| Want | Do |
|---|---|
| Rotate a password | update the Environment secret → **Run workflow** with `secrets_only` → redeploy the service |
| Change a DB host/name/user | update the Environment variable → **Run workflow** with `apply` |
| No cold starts | `envs/<env>.tfvars`: `cph.min_instances = 1` (about ₹1,300/mo) |
| PDFs on Cloud Run | pdfWorker needs the poller-removal change first; then `enable_pdfworker` + `enable_cloud_tasks` |
| Rebuild prod VM | fresh Ubuntu → copy `.env` → run the Ansible workflow |