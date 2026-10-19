# Release and Deploy: Design

Date: 2026-10-19 · Status: ready for approval (builder check done) · Owner: user-lee-005

## Why

Today every merge to the default branch in cph, pdfWorker and credit-service builds an image, pushes `:latest`, and opens a deploy-approval issue for the prod VM. The cph UI only builds and never deploys. So deploys get proposed whether or not anyone wants to ship. "What is live" has no version name, only `:latest` (moved on every merge). Rollback depends on a `vm-rollback` retag. On 2026-10-19 a deploy also failed because the VM's saved ghcr.io login had expired (`error from registry: denied`), and nothing in the deploy refreshes it.

The user wants shipping to be an explicit act: first cut a versioned release, then deploy that release to a chosen target, one service at a time.

## Goals

1. **Merging never deploys and never pushes an image.** A push or merge to the default branch runs CI only: compile plus the test suite.
2. **"Create Release" workflow** (run first, per repo): finds the latest release, bumps the version by the part the user picks (`patch` | `minor` | `major`), creates the git tag and publishes a GitHub Release with that version.
3. **"Deploy" workflow** (run after a release exists, per repo), started manually with inputs:
   - **tag**: a release tag `vX.Y.Z`, e.g. `v1.4.0`. Empty means the latest commit on the default branch. **No branch or arbitrary-ref deploys**: anything other than a `vX.Y.Z` tag or empty is rejected.
   - **target**: `vm` or `cloudrun`. **This decides where it goes.**
   - **environment**: `uat` or `prod`. It does not choose the destination yet; it is shown in the run name, approval issue and step summary, and Cloud Run uses it to load that GitHub Environment's GCP settings. For now the pair must match: `vm` requires `prod`, `cloudrun` requires `uat`, and any other combination is rejected *(my call: prevents a "uat"-labelled run from hitting the prod VM; Cloud Run has no `prod` environment yet)*.
   - **components** (cph only): `backend`, `ui` or both.
4. **The image is built at deploy time.** Deploy checks out the chosen tag/commit, builds and pushes the image tagged with that version (`v1.4.0`, or `sha-<short>` for an untagged commit), then deploys exactly that image. If an image for that tag already exists in the target's registry, it is reused instead of rebuilt.
5. **Deploying to prod waits for an "approve" comment** (existing `approval.yml`). UAT does not. *(My call: approval is keyed on `environment == prod`. With the matching rule above, that is exactly every VM deploy today, and it keeps holding if prod moves to Cloud Run later.)*
6. **Every deploy logs Docker in to the registry itself**, using a token from GitHub secrets, so an expired login on the VM can't break deploys.
7. **Rollback = run Deploy with an older tag.** No `:latest`/`vm-rollback` retag dance. *(Documented limitation, my call: rolling the backend back past a release that added a Flyway migration is not supported, because the older code fails Flyway validation against the newer schema. Deploy does not undo migrations.)*
8. **Automatic rollback on a failed VM deploy.** Before pinning the new version, the playbook records the version currently running for each service being deployed. If a service doesn't become healthy, its `rescue:` redeploys the recorded version, waits for health, and still fails the run so the failure is visible.
9. **Green CI required.** Create Release refuses to tag a commit whose CI run did not succeed. Deploy refuses to build or deploy a commit (the tag's commit, or the default-branch HEAD) whose CI did not succeed.
10. **The shared logic lives once in `PranicDoc/infra`**: reusable workflows, the version-bump script, and the Ansible deploy playbook. Each app repo has thin `release.yml` and `deploy.yml` wrappers, so each service can be released and deployed on its own.

## Non-goals (for now)

- Choosing the destination by environment. That comes later, once UAT and prod are both real. Later still, prod may move to Cloud Run. The workflow inputs should make that switch a small change.
- Changing what runs where. The VM stays prod; Cloud Run stays UAT (cph + creditService only today).
- Release notes beyond GitHub's auto-generated notes.
- Deploying several repos in one run.

## Anti-goals (would make this a failure even if it "works")

- Any path where a merge alone ships to the VM or Cloud Run.
- The VM running something other than the exact version the user picked (e.g. a deploy that pulls `:latest`).
- Deploy silently building from a different commit than the tag points to.

## Decisions (as decided by the user)

| Topic | Decision |
|---|---|
| Where workflows live | Thin wrappers in each app repo; shared reusable workflows, scripts and the Ansible playbook in infra |
| Destination | Chosen by `target` (vm / cloudrun); `environment` is logged only, for now |
| Tag input | Optional; empty = latest commit on the default branch |
| Image build | Only at deploy time; CI on push/merge builds and tests but pushes nothing |
| CI on push/merge | Must keep building and **running the tests** |
| Versioning | SemVer, user picks patch / minor / major per release |
| Version scope | Separate versions per repo; cph backend + UI share one version |
| Approval | Prod deploys need "approve" (existing gate); UAT doesn't |
| Green CI | Release and Deploy both require CI success for the exact commit |
| Failed VM deploy | Auto-rollback to the previously running version |
| Branch deploys | Dropped: tags only (plus empty = default-branch HEAD) |
| Backfill job | Dropped from deploys (`backfill-practitioner-role.yml` no longer chained after backend deploys) |
| Registry login | Done by every deploy |

## Facts about the current state (verified 2026-10-19)

- Repos and default branches: `cph` → `main`, `pdfWorker` → `main`, `credit-service` → **`master`**. No repo has any tags or releases yet.
- cph workflows: `build-and-push.yml` (backend build + VM deploy on push), `build-ui.yml` (UI build only, no deploy), `deploy-branch.yml` (manual branch deploy; inline SSH with `VM_PASSWORD`, retags `:latest`/`:vm-rollback`), `rollback-cph.yml`, `backfill-practitioner-role.yml`. pdfWorker and credit-service: `build-and-push.yml` each (build + VM deploy on push).
- infra reusable pieces: `build-image.yml` (pushes to ghcr.io as `sha-<short>` + `latest`, optionally to Artifact Registry via `gar_environment`), `approval.yml`, `deploy-vm.yml` (approval → `ansible/playbooks/deploy.yml`), `deploy-cloudrun.yml` (approval → swap image on a Cloud Run service, image from Artifact Registry, takes `environment`, `service`, `image_name`, `image_tag`), composite action `.github/actions/ansible-vm` (SSH key or password).
- `deploy.yml` runs `docker compose pull <svcs>` + `up -d --no-deps <svcs>` + waits for health. The VM's compose file references `ghcr.io/pranicdoc/<image>:latest` (services `cph`, `ui`, `pdfworker`, `creditservice`). Ansible does not manage the compose file today (`compose_managed` off).
- The cph Dockerfile builds with `gradle bootJar -x test`, so **no CI runs the tests today**. Running cph's suite gives 933 tests / 19 failures on `main`: 9 Spring-context tests (Flyway runs Postgres migrations on H2 → `TIMESTAMPTZ` unknown), 5 RBAC/role-assignment audit tests (audit payload is `null`, which may be a real bug), 3 CaseService PDF tests and 2 SessionService tests (outdated mocks/expectations).
- Cloud Run (UAT) can't be deployed to yet: the GCP Workload Identity bootstrap hasn't been run (see `infra/PROGRESS.md`, local only). Artifact Registry pushes need that too.
- Image names: ghcr `cph`, `cph-ui`, `pdfworker`, `creditservice`. Cloud Run services: `cph`, `creditservice` (UAT).

## Shape of the solution

### Per app repo
- `ci.yml`: on push/merge to the default branch and on PRs: compile and run tests (backend: Gradle `test`; UI: `tsc -b` + `vitest run`). No image push. PRs may also do a no-push Docker build to catch Dockerfile breakage (builder's call).
- `release.yml`: `workflow_dispatch` with input `bump` (patch/minor/major). Calls infra's reusable release workflow.
- `deploy.yml`: `workflow_dispatch` with inputs `tag`, `target`, `environment` (+ `components` in cph). Calls infra's reusable build-and-deploy workflow(s).
- Remove the deploy-on-push jobs, the `latest` push on merge, and in cph `deploy-branch.yml` + `rollback-cph.yml` (superseded by Deploy with a tag, plus auto-rollback). The backfill is no longer chained to deploys; `backfill-practitioner-role.yml` itself may stay as a standalone manual workflow.

### In infra
- `release.yml` (reusable) + a script: check CI passed for the default-branch HEAD, read the latest `vX.Y.Z` tag (none yet means start from `v0.0.0`), bump, tag that HEAD, publish a GitHub Release with auto-generated notes.
- A shared "CI passed for this SHA" check, used by both release and deploy.
- Build step: reuse `build-image.yml` with a `ref` (tag or commit) and an explicit image tag (`v1.4.0` / `sha-<short>`), **never** tagging `latest` from a deploy, plus an "already exists? skip" check.
- `deploy-vm.yml` / `deploy.yml` playbook: deploy **the given version**, not `:latest`; `docker login ghcr.io` with a token secret before pulling; record the previous version and auto-roll back on failed health (Goal 8).
- `deploy-cloudrun.yml`: already takes an explicit tag; needs the image in Artifact Registry.
- `environment` is passed everywhere for display: run name, approval issue title, step summary.

## Left to the builder

- Exact mechanism for pinning the VM to a version (e.g. Ansible writes a compose override / `.env` image-tag variables vs. editing the compose file), as long as the VM runs exactly the chosen tag and the next deploy of a different service doesn't disturb it.
- How "image already exists" is checked per registry.
- Naming of workflows, inputs and the bump script's language (bash vs. a small action).
- PR-time Docker build (yes/no).
- Order of rollout across repos; migrating each repo can be its own PR.

## Prerequisites / related work

1. **Fix cph's 19 failing tests first.** Because Release and Deploy require green CI, cph can't be released until its suite passes. Separate task; the 5 audit tests need a real look. pdfWorker and credit-service test health is unknown and must be checked. *(My call: `ci.yml` is added to each repo straight away but is not a required merge check until its suite is green.)*
2. **Refresh the VM's registry access**: a token with `read:packages` as a GitHub secret, used by the deploy login (Goal 6).
3. Cloud Run target needs the GCP bootstrap (`scripts/bootstrap-gcp.sh`) and the first OpenTofu apply. Until then, `target: cloudrun` should fail with a clear message.
