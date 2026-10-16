# PranicDoc infra

Prod on GCP (asia-south1), UAT on the VM. Three layers, one repo:

| Layer | Folder | Runs when | Touches |
|---|---|---|---|
| Provisioning | `tofu/` | PR → plan; merge to `main` → apply (reviewer-gated) | Cloud Run services, Secret Manager containers + IAM, Artifact Registry, Cloud Tasks, WIF, budget |
| Configuration | `ansible/` | merge to `main` → provision UAT VM | packages, Docker log rotation, `/opt/pranicdoc/bin/deploy.sh`, image prune cron |
| Deployment | `.github/workflows/deploy-*.yml` | called by app repos after a build | swaps the image on Cloud Run (auto-rollback) or runs `deploy.sh` on the VM |

**Ownership rule:** tofu owns service *config*; CI owns the *image*. Never change Cloud Run settings in the console — change `tofu/` and merge.

**Secrets:** tofu creates the secret entries and who may read them, never the values. Add or rotate a value with `gcloud secrets versions add <name> --data-file=<file>`, then destroy the old version (6 live versions are free).

## Status (2026-10-16)

- Nothing applied yet. A local read-only plan against the live project: 13 imports, 40 adds, 0 destroys.
- Prod still points at the VM URLs and Aiven; switching is a later step (`prod.tfvars`).
- pdfWorker / creditService / Cloud Tasks are behind `enable_*` flags, all `false`.
- The UAT database split is undecided.

## First-time setup

1. `cp tofu/private.auto.tfvars.example tofu/private.auto.tfvars` and fill it in (values are in `cph/deploy/.env.deploy`).
2. `pwsh -File scripts/bootstrap.ps1`: creates the state bucket, inits, and plans. Review the plan, then rerun with `-Apply`.
3. Create the GitHub repo `PranicDoc/infra` (private), then push.
4. In the infra repo:
   - Variables: `GCP_WORKLOAD_IDENTITY_PROVIDER`, `TOFU_SERVICE_ACCOUNT` (from `tofu output`)
   - Secret: `TOFU_PRIVATE_TFVARS` (content of `private.auto.tfvars`)
   - Environments: `infra-prod` and `uat`, each with you as required reviewer
   - Settings → Actions → General → Access: *accessible from repositories in the organization* (lets app repos call the reusable workflows)
5. Org-level secrets for UAT: `UAT_HOST`, `UAT_SSH_USER`, `UAT_SSH_KEY`. This is an SSH **key**; the old workflows use `VM_PASSWORD`. Add the public key to `~/.ssh/authorized_keys` on the VM.
6. In cph, pdfWorker and credit-service, set `GCP_SERVICE_ACCOUNT` to the `deployer_service_account` output and `GCP_WORKLOAD_IDENTITY_PROVIDER` to the provider. Their build workflows already push to Artifact Registry once these exist.

## Wiring app repos (at cutover)

Add a job after `build` in each app repo:

```yaml
deploy-prod:
  needs: build
  permissions: { contents: read, id-token: write }
  uses: PranicDoc/infra/.github/workflows/deploy-cloudrun.yml@main
  with:
    service: cph
    image: asia-south1-docker.pkg.dev/project-62583e23-5e4b-48e7-b00/all-in-one/cph:sha-${{ github.sha }}  # match the build's tag format
    health_path: /cph/actuator/health
    workload_identity_provider: ${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER }}
    service_account: ${{ vars.GCP_SERVICE_ACCOUNT }}

deploy-uat:
  needs: build
  uses: PranicDoc/infra/.github/workflows/deploy-uat.yml@main
  with: { services: cph }
  secrets: inherit
```

## Common changes

| Want | Do |
|---|---|
| Keep cph warm (no cold starts) | `prod.tfvars`: `cph.min_instances = 1` (about ₹1,300/mo) |
| Move pdfWorker to Cloud Run | fill `pdfworker_*` in private tfvars, set `enable_pdfworker` and `enable_cloud_tasks` to `true` |
| Change budget | `budget_amount_inr` |
| Rebuild UAT VM | fresh Ubuntu → copy `.env` → run the Ansible workflow |
