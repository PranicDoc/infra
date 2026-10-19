# Release and Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merges only run CI. Each repo ships through a manual "Create Release" (SemVer tag + GitHub Release) and a manual "Deploy" (pick tag, target, environment) that builds the image at deploy time and deploys exactly that version, with approval for prod, auto-rollback on the VM, and a CI-green gate.

**Architecture:** Shared pieces live in `PranicDoc/infra`: reusable workflows `ci-*.yml`, `release.yml`, `resolve-release.yml`, the extended `build-image.yml`, `deploy-vm.yml` and `deploy-cloudrun.yml`, plus the version-bump script and the Ansible `deploy.yml` playbook. Each app repo (cph, pdfWorker, credit-service) gets thin `ci.yml`, `release.yml` and `deploy.yml` wrappers, and its old deploy-on-push workflows are removed. The VM is pinned to exact versions through an Ansible-managed `docker-compose.override.yml`.

**Tech Stack:** GitHub Actions (reusable workflows, `gh` CLI), bash, Ansible, Docker Compose, Gradle/JUnit 5 + Mockito (cph backend), Vite/Vitest (cph UI).

**Spec:** `infra/docs/superpowers/specs/2026-10-19-release-and-deploy-design.md`

## Global Constraints

- Merge/push to the default branch: build + tests only; **no image push, no deploy**.
- Tag format `vX.Y.Z` (SemVer); first release from no tags starts at `v0.0.0` + bump. Versions are per repo; cph backend + UI share one.
- Deploy inputs: `tag` (`vX.Y.Z` or empty = default-branch HEAD; anything else rejected), `target` (`vm` | `cloudrun`), `environment` (`uat` | `prod`), cph only `components` (`backend` | `ui` | `both`).
- Pairs allowed for now: `vm`+`prod`, `cloudrun`+`uat`. Others fail before any build.
- Approval (`approval.yml`) required when `environment == prod`.
- Release and Deploy fail unless the `CI` workflow succeeded for the exact commit SHA.
- Image tag = the release tag (`v1.4.0`) or `sha-<7-char short sha>` for an untagged HEAD. Deploy never pushes or deploys `latest`.
- Every VM deploy runs `docker login ghcr.io` before pulling and `docker logout ghcr.io` afterwards.
- Failed health on the VM: redeploy the previously running image, wait for health, then still fail the run.
- Default branches: cph `main`, pdfWorker `main`, credit-service `master`. Use `github.event.repository.default_branch`, never a hard-coded name.
- Rollback across a Flyway migration is unsupported (documented, not handled).
- Windows dev box: run Gradle as `gradlew.bat`.

## Review Focus

1. **Deploying a second service must not disturb the first.** Deploying `ui` after `cph` must leave `cph` on its pinned version: the override keeps every previously pinned service. Test: Task 7, "pins accumulate".
2. **First deploy on a VM with no pins yet.** Rollback has no previous tag, so the playbook must fall back to the running container's repo digest. Test: Task 7, "rollback without previous pin".
3. **A `docker-compose.override.yml` already on the VM that we didn't write.** The playbook must refuse to overwrite it, not silently replace it. Test: Task 7, "foreign override refused".
4. **Re-deploying a tag that is already built** (or deploying it to a second target) must reuse the image, not rebuild it, and must not fail on "tag exists". Test: Task 6, "skip existing image".
5. **Creating a release when HEAD is already tagged** (nothing merged since the last release) must stop with a clear message, not create a duplicate or empty release. Test: Task 5, "HEAD already released".

---

## Phase 0: make cph's test suite green

Work in a cph worktree on branch `fix/green-test-suite` from `origin/main`. Baseline on `main`: 928 tests, 19 failures. Target: 0 failures, with no test deleted.

### Task 1: Spring-context tests start (9 tests)

Root causes (verified):
- `CphApplicationTests` has no `@ActiveProfiles("test")`, so Flyway runs the Postgres migrations on H2 and fails on V0 (`TIMESTAMPTZ`).
- The `test` profile excludes `RedisAutoConfiguration`, but `RedisConfig.redisCacheManager(RedisConnectionFactory, …)` and `CacheConfig.cacheManager(RedisCacheManager)` still need a `RedisConnectionFactory` bean, so `SqlCountAssertionTest` (4), `CreditGateIntegrationTest` (3) and `TenantFilterIntegrationTest` (1) fail with `NoSuchBeanDefinitionException: RedisConnectionFactory`.

**Files:**
- Modify: `app/src/test/java/com/pranicdoc/cph/CphApplicationTests.java` (add `@ActiveProfiles("test")`)
- Create: `app/src/test/java/com/pranicdoc/cph/support/TestRedisConfig.java`: a `@TestConfiguration` that provides `RedisConnectionFactory` as a Mockito mock (`mock(RedisConnectionFactory.class)`), imported by the 4 context test classes via `@Import(TestRedisConfig.class)`. If the mock leads to cache read/write NPEs in those tests, set `spring.cache.type=none` for the test profile instead, but only if `CacheConfig` honours it; otherwise keep the mock and stub `getConnection()`.
- Modify: the 3 other context test classes (add `@Import`)

- [ ] **Step 1:** Run `gradlew.bat test --tests "com.pranicdoc.cph.CphApplicationTests"`. Expected: FAIL, Flyway V0 `TIMESTAMPTZ`.
- [ ] **Step 2:** Add `@ActiveProfiles("test")`, rerun. Expected: the Redis `NoSuchBeanDefinitionException` is now the first failure.
- [ ] **Step 3:** Add `TestRedisConfig` and the `@Import`s.
- [ ] **Step 4:** Run `gradlew.bat test --tests "*CphApplicationTests" --tests "*SqlCountAssertionTest" --tests "*CreditGateIntegrationTest" --tests "*TenantFilterIntegrationTest"`. Expected: 9 pass. If a *different* context error appears next, fix its root cause the same way (missing test property or bean). Never `@Disabled`.
- [ ] **Step 5:** Commit `test: boot the Spring context in the test profile without Redis`.

### Task 2: Audit aspect tests (5 tests)

Root cause (verified for `RbacRoleServiceAuditTest`): the tests mock `Auditable` and never stub `auditPayload()`. That attribute was added later with `default true`, but a Mockito mock returns `false`, so `AuditAspect` skips the payload and `getPayload()` is `null`. Not a production bug; the real annotation defaults to `true`. `RoleAssignmentServiceAuditTest` also asserts an entity id that comes back `null`. Confirm it is the same harness gap (unstubbed attribute or an arg-order change) before changing anything, and if it is a real `AuditAspect` regression, stop and report instead.

**Files:**
- Modify: `app/src/test/java/com/pranicdoc/cph/rbac/**/RbacRoleServiceAuditTest.java`, `.../RoleAssignmentServiceAuditTest.java`

- [ ] **Step 1:** In each class's `@BeforeEach`, add `lenient().when(auditable.auditPayload()).thenReturn(true);` (mirrors the annotation default).
- [ ] **Step 2:** Run both classes. Expected: payload tests pass. For any still failing on entity id, read `AuditAspect` lines 95–102 (first `UUID` arg, else result `getId()`/`id()`) against the test's args and fix the test's setup to match the real service signature. Re-run. Expected: 5 pass.
- [ ] **Step 3:** Commit `test(audit): stub auditPayload like the annotation default`.

### Task 3: Outdated service unit tests (5 tests)

- `CaseServiceTest.postMessageToGeneratePdf_*` (3): the session fixtures have no `healingCase` (NPE in the snapshot mapper, so "Failed to serialize healing case snapshot") and one test has an unused stub (`UnnecessaryStubbingException`).
- `SessionServiceTest.createPreservesSubmittedSessionDateAndEndTime`: uses `completedSession` (no readings), so it hits "Pre-scan is required". Switch it to `completedSessionWithReadings`.
- `SessionServiceTest.createRejectsProtocolColorsWithUnknownColorIds`: expects colour validation that `SessionService.create` no longer performs. Check `git log -S "pranaColorCatalogRepository.existsById"` on `SessionService`. If the colour check was intentionally removed, delete the stale expectation by rewriting the test to assert what create does today with an unknown colour id; if it was lost accidentally, stop and report (that's a product bug).

**Files:**
- Modify: `app/src/test/java/com/pranicdoc/cph/healing/service/CaseServiceTest.java`, `.../SessionServiceTest.java`

- [ ] **Step 1:** Fix the fixtures (set `healingCase` on sessions; remove or `lenient()` the unused stub). Run `*CaseServiceTest`. Expected: pass.
- [ ] **Step 2:** Fix the two SessionService tests as above. Run `*SessionServiceTest`. Expected: pass.
- [ ] **Step 3:** Run the full suite `gradlew.bat test`. Expected: **0 failures**.
- [ ] **Step 4:** Commit `test: update CaseService/SessionService tests to current behaviour`. Push, PR to cph `main`.

### Task 4: pdfWorker and credit-service test health

- [ ] **Step 1:** In each repo run `gradlew.bat test` on the default branch and record pass/fail counts.
- [ ] **Step 2:** Any failures: same treatment as Tasks 1–3 (root cause, fix the test or report a real bug), one PR per repo. Zero failures: nothing to do.

---

## Phase 1: shared pieces in infra

Branch `feat/release-deploy` in infra. Each task is one commit; the PR is merged before Phase 2 starts.

### Task 5: Version bump script + reusable `release.yml`

**Files:**
- Create: `scripts/release/next-version.sh`: `next-version.sh <latest-tag-or-empty> <patch|minor|major>`, prints the next tag. Empty latest gives `v0.0.0` + bump. Exits 2 on a malformed tag or bump.
- Create: `scripts/release/test-next-version.sh`: plain bash asserts, run in CI (`lint` job of infra) and locally.
- Create: `.github/workflows/release.yml` (reusable, `workflow_call`, input `bump`; needs `contents: write`, `actions: read`).
- Create: `.github/actions/require-ci/action.yml`: composite, inputs `sha`, `workflow` (default `ci.yml`). Fails unless `gh run list --workflow <workflow> --commit <sha> --status success --limit 1` returns a run.

- [ ] **Step 1: Write the failing tests** in `test-next-version.sh`:
  - `"" patch` → `v0.0.1`; `"" minor` → `v0.1.0`; `"" major` → `v1.0.0`
  - `v1.4.2 patch` → `v1.4.3`; `v1.4.2 minor` → `v1.5.0`; `v1.4.2 major` → `v2.0.0`
  - `1.4.2 patch` → exit 2; `v1.4.2 hotfix` → exit 2
- [ ] **Step 2:** Run `bash scripts/release/test-next-version.sh`. Expected: FAIL (script missing).
- [ ] **Step 3:** Implement `next-version.sh`.
- [ ] **Step 4:** Rerun. Expected: all PASS.
- [ ] **Step 5:** Implement `release.yml`:
  1. Check out the caller's default branch with full history.
  2. `require-ci` on HEAD.
  3. Latest tag: `git tag --list 'v*' --sort=-v:refname | head -1`.
  4. **Stop with "HEAD is already released as <tag>"** if `git tag --points-at HEAD` contains a `v*` tag (Review Focus 5).
  5. Compute next via the script, then `gh release create <next> --target <sha> --generate-notes --title <next>`.
  6. Write the version and SHA to the step summary.
- [ ] **Step 6:** Commit `feat: reusable release workflow with SemVer bump and CI gate`.

### Task 6: `resolve-release.yml` + `build-image.yml` changes

**Files:**
- Create: `.github/workflows/resolve-release.yml` (reusable). Inputs `tag`, `target`, `environment`. Outputs `sha`, `version` (tag or `sha-<short>`), `ref`. Steps:
  1. Validate `tag` matches `^v[0-9]+\.[0-9]+\.[0-9]+$` or is empty.
  2. Validate the target/environment pair (Global Constraints).
  3. Resolve the SHA: the tag's commit, or the default-branch HEAD.
  4. `require-ci` on that SHA.
  5. Put the environment in the step summary.
- Modify: `.github/workflows/build-image.yml`. New input `image_tag` (string, optional). When set: build `ref`, push **only** `<image>:<image_tag>` (no `sha-`, no `latest`), and first check `docker manifest inspect <image>:<image_tag>` (ghcr; plus Artifact Registry when `gar_environment` is set). If it exists, skip the build and still output `image_tag` (Review Focus 4). Without `image_tag`, behaviour is unchanged until Phase 2 removes the old callers.

- [ ] **Step 1:** Implement `resolve-release.yml`; dry-run it from a scratch caller workflow on a branch with `tag: bad` (expect failure "tag must be vX.Y.Z"), `target: vm, environment: uat` (expect failure "vm requires prod") and a valid empty tag (expect the SHA + `sha-xxxxxxx`).
- [ ] **Step 2:** Implement the `build-image.yml` change; verify by calling it twice with the same `image_tag`. Expected: the second run logs "already exists, skipping build" and outputs the same tag.
- [ ] **Step 3:** Commit `feat: resolve-release gate and versioned, idempotent image builds`.

### Task 7: Ansible deploy pins exact versions, logs in, auto-rolls back

**Files:**
- Modify: `ansible/inventory/group_vars/prod.yml`: add `service_images: {cph: ghcr.io/pranicdoc/cph, ui: ghcr.io/pranicdoc/cph-ui, pdfworker: ghcr.io/pranicdoc/pdfworker, creditservice: ghcr.io/pranicdoc/creditservice}`.
- Modify: `ansible/playbooks/deploy.yml`. New extra vars `version` (required), `registry_user`, `registry_token` (no_log). State lives on the VM:
  - `{{ app_dir }}/deployed-versions.yml`: map service → image ref.
  - `{{ app_dir }}/docker-compose.override.yml`: generated from it. The first line is the marker `# managed by infra ansible deploy.yml`.
- Create: `ansible/roles/app/templates/docker-compose.override.yml.j2`.
- Test: `ansible/tests/deploy-override.yml`, a localhost-only playbook that renders the template for fixtures and asserts on the output (runs in the infra `lint` job).

Playbook order:
1. If an override exists without the marker, fail (Review Focus 3).
2. Read `deployed-versions.yml` (empty if missing).
3. For each service, record the rollback ref: its entry in the versions file, else the running container's `{{index .RepoDigests 0}}` (Review Focus 2).
4. `docker login ghcr.io`.
5. Set each service to `service_images[svc]:version`, write the versions file and the override, pull, and `up -d --no-deps`.
6. Wait for health, as today.
7. `rescue:` write the rollback refs back, `up -d --no-deps` the failed services, wait for health, then `fail`.
8. `always:` `docker logout ghcr.io`.

- [ ] **Step 1: Write the failing tests** in `ansible/tests/deploy-override.yml`:
  - "pins accumulate": versions `{cph: …:v1.0.0}`, deploy `ui` at `v1.0.0`; the rendered override has both `cph` and `ui` images.
  - "rollback without previous pin": empty versions plus a fake digest give a rollback ref equal to that digest.
  - "foreign override refused": an override without the marker fails with a message naming the file.
- [ ] **Step 2:** Run `ansible-playbook ansible/tests/deploy-override.yml`. Expected: FAIL.
- [ ] **Step 3:** Implement the template and the playbook changes.
- [ ] **Step 4:** Rerun. Expected: PASS. Also `ansible-lint` passes.
- [ ] **Step 5:** Modify `.github/workflows/deploy-vm.yml`:
  - inputs `services`, `version`, `environment`;
  - approval only when `environment == 'prod'`;
  - pass `registry_user: ${{ github.actor }}` and `registry_token: ${{ secrets.GITHUB_TOKEN }}` (the caller grants `packages: read`).
  
  **Verify** the caller repo's token can pull its own ghcr package. If ghcr denies it, add a `GHCR_PULL_TOKEN` secret (read:packages) and use it instead.
- [ ] **Step 6:** Modify `.github/workflows/deploy-cloudrun.yml`:
  - approval only when `environment == 'prod'`;
  - fail clearly with "Cloud Run is not set up yet (run bootstrap-gcp.sh)" when `vars.GCP_WORKLOAD_IDENTITY_PROVIDER` is empty for that environment;
  - fail with "<service> has no Cloud Run service" for anything other than `cph` / `creditservice`.
- [ ] **Step 7:** Commit `feat: VM deploys pin exact versions, log in to ghcr, auto-roll back`. Open the infra PR, merge.

### Task 8: Reusable CI workflows

**Files:**
- Create: `.github/workflows/ci-gradle.yml` (reusable). Inputs `working_directory`, `java_version` (default `17`), `use_gpr_key` (bool). Runs `./gradlew test`, with GPR credentials from `GPR_USER`/`GPR_KEY` secrets when `use_gpr_key`, and uploads test reports on failure.
- Create: `.github/workflows/ci-node.yml` (reusable). Input `working_directory`. Runs `npm ci`, `npx tsc -b`, `npx vitest run`.

- [ ] **Step 1:** Implement both. Verify each from a scratch caller on a branch of cph. Expected: green once Phase 0 is merged.
- [ ] **Step 2:** Commit `feat: reusable CI workflows (gradle, node)` (same infra PR as Task 7 if it's still open).

---

## Phase 2: switch each repo (one PR per repo; cph first)

### Task 9: cph

**Files:**
- Create: `.github/workflows/ci.yml` (name **`CI`**). On push to `main`, PRs and `workflow_dispatch`: jobs `backend` (`ci-gradle.yml`, `working_directory: app`, `use_gpr_key: true`) and `ui` (`ci-node.yml`, `working_directory: ui`).
- Create: `.github/workflows/release.yml`: `workflow_dispatch` input `bump` (choice: patch/minor/major), calls `infra/release.yml@main`.
- Create: `.github/workflows/deploy.yml`: `workflow_dispatch` inputs `tag`, `target` (choice), `environment` (choice), `components` (choice: backend/ui/both). Jobs:
  1. `resolve` (`resolve-release.yml`).
  2. `build_backend` / `build_ui` (`build-image.yml` with `ref: <sha>`, `image_tag: <version>`, existing image names, build args and GPR settings; `gar_environment: uat` when target is cloudrun). Each runs only if its component is selected.
  3. Then one of:
     - `deploy_vm` (`deploy-vm.yml`, `services` = `cph` / `ui` / `cph ui`, `version`, `environment`) when `target == vm`;
     - `deploy_cloudrun` (`deploy-cloudrun.yml`, service `cph`) when `target == cloudrun` and the backend is selected. If target is cloudrun and the UI is selected, fail in `resolve` with "ui has no Cloud Run service".
  
  `run-name: Deploy ${{ inputs.components }} ${{ inputs.tag || 'main HEAD' }} → ${{ inputs.target }} (${{ inputs.environment }})`.
- Delete: `build-and-push.yml`, `build-ui.yml`, `deploy-branch.yml`, `rollback-cph.yml`. Keep `backfill-practitioner-role.yml` (standalone, manual).

- [ ] **Step 1:** Add the three workflows, delete the four.
- [ ] **Step 2:** Merge the PR. Expected: the merge runs **CI only**, no build-and-push or approval issue.
- [ ] **Step 3:** Run Release with `patch`. Expected: `v0.0.1` tag + GitHub Release.
- [ ] **Step 4:** Run Deploy with `tag v0.0.1`, `target vm`, `environment prod`, `components both`. Expected: images `cph:v0.0.1` and `cph-ui:v0.0.1` built, one approval issue, then both healthy. On the VM, `docker compose ps` shows the `:v0.0.1` images and the override has the marker.
- [ ] **Step 5:** Re-run the same Deploy. Expected: builds skipped ("already exists"), deploy succeeds (Review Focus 4).

### Task 10: pdfWorker

Same shape as Task 9, backend only: CI `ci-gradle.yml` (`use_gpr_key: true`), release, deploy (VM service `pdfworker`, image `pdfworker`). With `target: cloudrun`, fail in resolve with "pdfworker has no Cloud Run service". Delete `build-and-push.yml`. Verify: merge runs only CI; Release `patch` gives `v0.0.1`; Deploy `vm`/`prod` is healthy and `cph` is still on its pinned version (Review Focus 1).

### Task 11: credit-service

Same shape, default branch `master`. VM service `creditservice`, Cloud Run service `creditservice`, image `creditservice`. Delete `build-and-push.yml`. Verify the same as Task 10.

### Task 12: Docs

- [ ] Update `infra/README.md` ("Releasing and deploying": run Release, then Deploy; rollback = Deploy an older tag; the Flyway limitation; target/environment pairs) and add a line to `infra/PROGRESS.md`. Commit.

---

## Phase 3: one chakra scan sheet per session (pdfWorker)

Tracked in Notion: "PDF: one chakra scan sheet per session instead of overwriting a single sheet". Agreed 2026-10-19. Independent of Phases 1–2; ship it through the new Release → Deploy flow once that exists.

### Task 13: Duplicate the scan sheet per session, with a session label

**Problem:** `CaseSnapshotMapper.mapSessionData` writes every session's PRE/POST readings into the same `SCAN_*` fields on template page index 4, so only the last session's values survive.

**Design (decided):**
- Follow `PdfRendererServiceImpl.duplicateFeedbackPages`. The number of scan sheets equals `sessions.size()`; each sheet holds one session's PRE and POST scan. Add `sessions.size() − 1` clean copies of template page index 4, imported from a fresh template load, inserted directly after the original scan page.
- Session order is the snapshot's session list order (cph sends them sorted by session number). Session *i* (0-based) is drawn on scan page `4 + i`.
- 0 or 1 sessions: no extra pages; output identical to today.
- No cap on sessions.
- Each scan sheet gets a label **`Session <n> – <dd/MM/yyyy>`**: `n` = `sessionNumber()`, or `i + 1` when null (same fallback as the feedback rows); date = `sessionDate()` in the renderer's existing `DATE_FMT`, omitted with its dash when null. Position: top-right, right edge x≈535, y≈812 (free space above the page title at y=792), font 9. Check it visually on a generated PDF and adjust once.
- Insert and draw the scan copies **after** `renderFields` and `renderFeedbackPages`, so the existing feedback page-index shifting is untouched. Later pages simply move back by the number of inserted sheets.

**Files:**
- Modify: `pdfWorker/src/main/java/com/pranicdoc/pdfWorker/template/CaseSnapshotMapper.java`
  - Add `public static Map<PdfTemplateField, String> scanFields(SessionSnapshot session)`: the `SCAN_*` values for one session's PRE/POST readings (reuse the `REGISTRY`/`ChakraPdfKeys` lookup now inline in `mapSessionData`).
  - `mapSessionData` no longer writes `SCAN_*` fields; scan rendering moves to the renderer.
- Modify: `pdfWorker/src/main/java/com/pranicdoc/pdfWorker/service/impl/PdfRendererServiceImpl.java`
  - Add `private void renderScanSheets(PDDocument document, PDFont font, List<SessionSnapshot> sessions, byte[] templateBytes)`: inserts the copies, draws each session's `scanFields` with the existing `renderField`, and draws the label.
  - Call it from `render(...)` after `renderFeedbackPages`.
- Test: `pdfWorker/src/test/java/com/pranicdoc/pdfWorker/template/CaseSnapshotMapperTest.java`, `pdfWorker/src/test/java/com/pranicdoc/pdfWorker/service/impl/PdfRendererServiceImplTest.java` (create if absent; the renderer loads the real `generatePdf/template.pdf`).

- [ ] **Step 1: Write the failing tests**
  - `scanFields_onlyThatSessionsReadings`: two sessions with different Crown readings. `scanFields(session2)` returns session 2's values for `SCAN_CROWN_ENERGY_BEFORE` / `..._AFTER`, and `scanFields(session1)` returns session 1's.
  - `toFieldMap_hasNoScanFields`: `toFieldMap(fullSnapshot())` contains no key starting with `SCAN_`.
  - Renderer `threeSessions_addTwoScanSheets`: page count = template pages + 2. Extracted text of pages 4, 5 and 6 contains `Session 1`, `Session 2` and `Session 3` respectively, and page 7 is the first feedback page (contains the feedback header text).
  - Renderer `oneSession_pageCountUnchanged`: page count = template page count, and page 4 contains `Session 1`.
  - Renderer `sessionWithoutDate_labelHasNoDate`: label text is exactly `Session 1`.
  - Renderer `scansAndFeedbackOverflow_together`: 2 sessions and 6 symptoms. Page count = template + 1 (scan) + 1 (feedback overflow), and the protocol page text is still found on the expected index.
- [ ] **Step 2:** Run `gradlew.bat test --tests "*CaseSnapshotMapperTest" --tests "*PdfRendererServiceImplTest"`. Expected: FAIL.
- [ ] **Step 3:** Implement `scanFields` and remove `SCAN_*` writes from `mapSessionData`.
- [ ] **Step 4:** Implement `renderScanSheets` and call it.
- [ ] **Step 5:** Run the full pdfWorker suite. Expected: 0 failures.
- [ ] **Step 6:** Generate a PDF for a 3-session case locally and check the three scan sheets and the label position by eye (the user tests locally before push).
- [ ] **Step 7:** Commit `feat(pdf): one chakra scan sheet per session, labelled with session number and date`. Open a PR to pdfWorker `main`. CI must be green.
