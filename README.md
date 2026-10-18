# PranicDoc infra

One codebase for every environment. **UAT** is GCP Cloud Run (scale to zero, Neon Postgres). **Prod** is
the VM (`213.199.38.16`, docker-compose). Everything runs from GitHub Actions.

| Layer | Folder | Runs when | Touches |
|---|---|---|---|
| Provisioning | `tofu/` + `tofu.yml` | PR / merge → plan (`uat`); **Run workflow** (`environment`, `apply`) → secret sync + apply | Cloud Run, Secret Manager, Artifact Registry, Cloud Scheduler, WIF, budget |
| Configuration (prod VM) | `ansible/` + `ansible.yml` | PR / merge → lint; **Run workflow** → provision (dry run by default) | packages, Docker log rotation, `deploy.sh`, image prune cron |
| Deployment | `deploy-cloudrun.yml`, `deploy-vm.yml` | called by app repos after a build | Cloud Run image swap with auto-rollback · VM `deploy.sh` |

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

**Prod (VM) environment:** `VM_HOST`, `VM_SSH_USER`, `VM_SSH_KEY`. These are for `ansible.yml` and
`deploy-vm.yml`; the key is an SSH **key**.

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

## Wiring app repos
In each app repo, create a GitHub Environment with the same name (`uat`) and the variables
`GCP_PROJECT_ID`, `GCP_REGION`, `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_SERVICE_ACCOUNT`
(`github-deployer@<project>.iam.gserviceaccount.com`). Then:

```yaml
deploy:
  needs: build
  permissions: { contents: read, id-token: write }
  uses: PranicDoc/infra/.github/workflows/deploy-cloudrun.yml@main
  with:
    environment: uat
    service: cph                    # creditservice: health_path /credits/actuator/health
    image_tag: ${{ needs.build.outputs.image-tag }}
    health_path: /cph/actuator/health
```

## Day-2
| Want | Do |
|---|---|
| Rotate a password | update the Environment secret → **Run workflow** with `secrets_only` → redeploy the service |
| Change a DB host/name/user | update the Environment variable → **Run workflow** with `apply` |
| No cold starts | `envs/<env>.tfvars`: `cph.min_instances = 1` (about ₹1,300/mo) |
| PDFs on Cloud Run | pdfWorker needs the poller-removal change first; then `enable_pdfworker` + `enable_cloud_tasks` |
| Rebuild prod VM | fresh Ubuntu → copy `.env` → run the Ansible workflow |