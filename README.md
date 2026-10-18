# PranicDoc infra

**Prod is the VM** (`213.199.38.16`, docker-compose). **UAT is GCP Cloud Run** (asia-south1, scale to zero,
Neon free Postgres). Three layers, one repo:

| Layer | Folder | Runs when | Touches |
|---|---|---|---|
| Provisioning (UAT) | `tofu/` | PR → plan; merge to `main` → apply (`infra-uat` reviewer) | Cloud Run cph + creditService, Secret Manager containers + IAM, Artifact Registry, Cloud Scheduler, WIF, budget |
| Configuration (prod VM) | `ansible/` | merge to `main` → provision (`vm-prod` reviewer) | packages, Docker log rotation, `/opt/pranicdoc/bin/deploy.sh`, image prune cron |
| Deployment | `.github/workflows/deploy-*.yml` | called by app repos after a build | `deploy-cloudrun.yml`: UAT image swap with auto-rollback · `deploy-vm.yml`: prod `deploy.sh` |

**Ownership rules**
- **Config vs image.** Tofu owns Cloud Run *config*; CI owns the *image*. Don't change Cloud Run settings in the console.
- **Secret values.** Tofu creates secret entries and who may read them, never the values. Set a value with
  `gcloud secrets versions add <name> --data-file=<file>`, then destroy the old version (6 live versions are free).

## What runs where

| | Prod (VM) | UAT (Cloud Run) |
|---|---|---|
| cph | ✅ | ✅ `min_instances=0` |
| creditService | ✅ | ✅ scale to zero |
| pdfWorker | ✅ (polls DB every 1 s) | ❌ PDFs stay DRAFT in UAT |
| Outbox send | async after commit | inline after commit (`APP_NOTIFICATIONS_DISPATCH=sync`) |
| Outbox sweep (30 min) | in-process `@Scheduled` | Cloud Scheduler → `POST /cph/api/v1/internal/notifications/sweep` |
| Database | Aiven | Neon free (`pranic_doc`, `credit_service`) |
| R2 bucket | `pranicdoc-pdfs` | `pranicdoc-pdfs-uat` |

## Status (2026-10-18)
Nothing applied yet. A local read-only plan against the live project shows 13 imports, 52 adds, 1 change (cph env), 0 destroys.

## UAT setup, in order
1. **Neon:** in the project, create a second database `credit_service` next to the cph one. Then run:
   ```powershell
   pwsh -File scripts/configure-neon-uat.ps1            # prompts for the connection string (hidden)
   # or: -ConnectionString 'postgresql://...' [-CreditDatabase credit_service] [-DestroyOldVersions]
   ```
   The script:
   - writes `tofu/neon.auto.tfvars` (hosts, user, database names; gitignored)
   - stores the password in `db-password` and `credit-db-password`
   - checks that Neon is reachable

   Re-run it once the first apply has created `credit-db-password`.
2. **R2:** create the bucket `pranicdoc-pdfs-uat`.
3. **Secret values.** UAT must not share prod's values: give it its own jwt / encryption keys so a UAT token
   never works on prod.
   ```powershell
   # new values for UAT
   # (db-password / credit-db-password are set by configure-neon-uat.ps1)
   gcloud secrets versions add jwt-secret --data-file=uat-jwt.txt
   gcloud secrets versions add encryption-key --data-file=uat-enc.txt
   # created by tofu in step 5; add the value right after
   gcloud secrets versions add internal-api-key --data-file=internal-key.txt
   ```
   Then destroy the old versions.
4. `cp tofu/private.auto.tfvars.example tofu/private.auto.tfvars` and fill it in (OAuth client id, R2, mail, Redis).
5. `pwsh -File scripts/bootstrap.ps1` (state bucket + plan), then `-Apply`.
   - If the first apply fails on `credit-db-password` / `internal-api-key` having no version, add the values
     (step 3) and apply again.
6. Set `enable_outbox_sweep = true` in `uat.tfvars` and apply again.
7. **Google OAuth:** add the cph Cloud Run URL's `/cph/login/oauth2/code/google` as an authorised redirect URI.
8. Create the GitHub repo `PranicDoc/infra` (private) and push. Then configure:
   - **Variables:** `GCP_WORKLOAD_IDENTITY_PROVIDER`, `TOFU_SERVICE_ACCOUNT` (from `tofu output`)
   - **Secrets:** `TOFU_PRIVATE_TFVARS` (content of `private.auto.tfvars`), `TOFU_NEON_TFVARS` (content of
     `neon.auto.tfvars`); org-level `VM_HOST`, `VM_SSH_USER`,
     `VM_SSH_KEY`. This is an SSH **key**; the old workflows use `VM_PASSWORD`.
   - **Environments:** `infra-uat`, `cloudrun-uat` and `vm-prod`, each with you as required reviewer
   - **Settings → Actions → Access:** "accessible from repositories in the organization"
9. In cph and credit-service, set `GCP_SERVICE_ACCOUNT` to the `deployer_service_account` output.

**After moving the project into a Cloud Identity organization:** new orgs enforce *Domain restricted sharing*,
which blocks the `allUsers` invoker that cph / creditService need. Override
`iam.allowedPolicyMemberDomains` on this project.

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

## Common changes

| Want | Do |
|---|---|
| No cold starts on UAT | `uat.tfvars`: `cph.min_instances = 1` (about ₹1,300/mo) |
| PDFs in UAT | pdfWorker needs the poller-removal change first; then set `enable_pdfworker` and `enable_cloud_tasks` |
| Change budget | `budget_amount_inr` |
| Rebuild prod VM | fresh Ubuntu → copy `.env` → run the Ansible workflow |
