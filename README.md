# PranicDoc infra

**Prod is the VM** (`213.199.38.16`, docker-compose). **UAT is GCP Cloud Run** (asia-south1, scale to zero,
Neon free Postgres). Everything runs from GitHub Actions; nothing is run on a laptop.

| Layer | Folder | Runs when | Touches |
|---|---|---|---|
| Provisioning (UAT) | `tofu/` + `tofu.yml` | PR → plan; merge to `main` → secret sync + apply (`infra-uat` approval) | Cloud Run cph + creditService, Secret Manager, Artifact Registry, Cloud Scheduler, WIF, budget |
| Configuration (prod VM) | `ansible/` + `ansible.yml` | merge to `main` → provision (`vm-prod` approval) | packages, Docker log rotation, `/opt/pranicdoc/bin/deploy.sh`, image prune cron |
| Deployment | `deploy-cloudrun.yml`, `deploy-vm.yml` | called by app repos after a build | UAT image swap with auto-rollback · prod `deploy.sh` |

**Ownership rules**
- **Settings and secrets live in GitHub.** Repo variables hold settings; Environment secrets hold passwords.
  CI turns the variables into tfvars and copies the secrets into Secret Manager.
- **Config vs image.** Tofu owns Cloud Run *config*; CI owns the *image*. Never change Cloud Run in the console.

## What runs where

| | Prod (VM) | UAT (Cloud Run) |
|---|---|---|
| cph | ✅ | ✅ `min_instances=0` |
| creditService | ✅ | ✅ scale to zero |
| pdfWorker | ✅ (polls DB every 1 s) | ❌ PDFs stay DRAFT in UAT |
| Outbox send | async after commit | inline after commit (`APP_NOTIFICATIONS_DISPATCH=sync`) |
| Outbox sweep (30 min) | in-process `@Scheduled` | Cloud Scheduler → `POST /cph/api/v1/internal/notifications/sweep` |
| Database | Aiven (+ PgBouncer container) | Neon free, **direct** connections (no pooler needed) |
| R2 bucket | `pranicdoc-pdfs` | `pranicdoc-pdfs-uat` |

## One-time setup

### 1. GCP trust (Cloud Shell, about 2 minutes)
GitHub can't log into GCP until GCP trusts it, so this step needs a human once. Open
console.cloud.google.com, click **>_** (Cloud Shell), upload `scripts/bootstrap-gcp.sh` and run
`bash bootstrap-gcp.sh`. It's idempotent.

It creates the state bucket, the GitHub OIDC trust, the `github-tofu` account and the empty secret
containers. It prints two values for step 3.

### 2. Neon and R2
- **Neon:** a project with two databases, e.g. `cph-uat` (cph) and `credit_service` (creditService). Both
  services run Flyway, so they can't share one.
- **R2:** create the bucket `pranicdoc-pdfs-uat`.

### 3. GitHub → `PranicDoc/infra` → Settings
**Secrets and variables → Actions → Variables** (repository):

| Variable | Example |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | printed by bootstrap |
| `TOFU_SERVICE_ACCOUNT` | `github-tofu@project-62583e23-5e4b-48e7-b00.iam.gserviceaccount.com` |
| `NEON_HOST` | `ep-muddy-boat-a1acgpgt.ap-southeast-1.aws.neon.tech` (with or without `-pooler`) |
| `NEON_DATABASE` / `NEON_USERNAME` | `cph-uat` / `cph-uat_owner` |
| `NEON_CREDIT_DATABASE` | `credit_service` (default) |
| `NEON_CREDIT_USERNAME`, `NEON_PORT`, `NEON_USE_POOLER` | optional: same user, `5432`, `false` |
| `GOOGLE_CLIENT_ID`, `R2_ENDPOINT`, `MAIL_USERNAME`, `REDIS_HOST`, `WHATSAPP_PHONE_NUMBER_ID` | |

**Environments → `infra-uat`** (add yourself as required reviewer), then its **secrets**:

| Secret | Goes to Secret Manager |
|---|---|
| `NEON_PASSWORD` | `db-password` (and `credit-db-password` unless `NEON_CREDIT_PASSWORD` is set) |
| `UAT_JWT_SECRET`, `UAT_ENCRYPTION_KEY` | `jwt-secret`, `encryption-key`. **New values; don't reuse prod's.** |
| `UAT_INTERNAL_API_KEY` | `internal-api-key` (any long random string) |
| `GOOGLE_CLIENT_SECRET`, `R2_ACCESS_KEY`, `R2_SECRET_KEY`, `CREDIT_API_KEY`, `MAIL_PASSWORD`, `REDIS_PASSWORD` | same names, kebab-case |

Unset secrets are skipped, so the current value stays.

Also:
- **Environments:** create `cloudrun-uat` and `vm-prod`, each with you as required reviewer.
- **Settings → Actions → General → Access:** *accessible from repositories in the organization*.
- **Org-level secrets:** `VM_HOST`, `VM_SSH_USER`, `VM_SSH_KEY` (an SSH **key**; the old workflows use `VM_PASSWORD`).

### 4. Run it
**Actions → OpenTofu — GCP UAT → Run workflow** (or merge a change to `tofu/`). Approve the `infra-uat`
deployment. The job syncs secrets, then applies the plan it showed you.

### 5. Afterwards
- **Outbox sweep:** set `enable_outbox_sweep = true` in `tofu/uat.tfvars` and merge.
- **Google OAuth:** add `<cph Cloud Run URL>/cph/login/oauth2/code/google` as a redirect URI.
- **App repos:** in cph and credit-service, set `GCP_SERVICE_ACCOUNT` to `github-deployer@...` and
  `GCP_WORKLOAD_IDENTITY_PROVIDER`.
- **After moving the project into a Cloud Identity org:** override `iam.allowedPolicyMemberDomains` on this
  project, or the `allUsers` invoker on cph and creditService is blocked.

## Day-2

| Want | Do |
|---|---|
| Rotate a password | update the GitHub secret → **Run workflow** with `secrets_only` → redeploy the service |
| Change Neon host/db/user | update the `NEON_*` variable → **Run workflow** |
| No cold starts on UAT | `uat.tfvars`: `cph.min_instances = 1` (about ₹1,300/mo) |
| More DB connections | `NEON_USE_POOLER = true` (cph via Neon's PgBouncer; Flyway stays direct) |
| PDFs in UAT | pdfWorker needs the poller-removal change first; then `enable_pdfworker` + `enable_cloud_tasks` |
| Rebuild prod VM | fresh Ubuntu → copy `.env` → run the Ansible workflow |

## Wiring app repos

```yaml
deploy-uat:                       # after build pushes to Artifact Registry
  needs: build
  permissions: { contents: read, id-token: write }
  uses: PranicDoc/infra/.github/workflows/deploy-cloudrun.yml@main
  with:
    service: cph                  # creditservice: health_path /credits/actuator/health
    image: asia-south1-docker.pkg.dev/project-62583e23-5e4b-48e7-b00/all-in-one/cph:sha-<short sha from build>
    health_path: /cph/actuator/health
    workload_identity_provider: ${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER }}
    service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}

deploy-prod:
  needs: build
  uses: PranicDoc/infra/.github/workflows/deploy-vm.yml@main
  with: { services: cph }
  secrets: inherit
```
