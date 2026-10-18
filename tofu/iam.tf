# ─── Runtime identities (what the containers run as) ─────────────────────────

resource "google_service_account" "cph_runtime" {
  account_id   = "cph-cloudrun-runtime"
  display_name = "cph Cloud Run runtime"
}

resource "google_service_account" "pdfworker_runtime" {
  count        = var.enable_pdfworker ? 1 : 0
  account_id   = "pdfworker-runtime"
  display_name = "pdfWorker Cloud Run runtime"
}

resource "google_service_account" "creditservice_runtime" {
  count        = var.enable_creditservice ? 1 : 0
  account_id   = "creditservice-runtime"
  display_name = "creditService Cloud Run runtime"
}

# ─── CI identities (keyless, via wif.tf) ─────────────────────────────────────

# App repos: push images and roll out new revisions. Cannot change service config.
resource "google_service_account" "deployer" {
  account_id   = "github-deployer"
  display_name = "GitHub Actions - build & deploy"
}

resource "google_project_iam_member" "deployer" {
  for_each = toset([
    "roles/run.developer",
    "roles/run.invoker", # post-rollout health check calls the (IAM-only) service
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_artifact_registry_repository_iam_member" "deployer_push" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.deployer.email}"
}

# A revision runs as the runtime SA, so the deployer must be allowed to "act as" it.
resource "google_service_account_iam_member" "deployer_actas" {
  for_each = merge(
    { cph = google_service_account.cph_runtime.name },
    var.enable_pdfworker ? { pdfworker = google_service_account.pdfworker_runtime[0].name } : {},
    var.enable_creditservice ? { creditservice = google_service_account.creditservice_runtime[0].name } : {},
  )

  service_account_id = each.value
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

# Infra repo: runs `tofu apply`. Broad by necessity; WIF limits it to the infra
# repo's main branch (see wif.tf), and the apply job sits behind a GitHub
# Environment with a required reviewer.
resource "google_service_account" "tofu" {
  account_id   = "github-tofu"
  display_name = "GitHub Actions - OpenTofu"
}

resource "google_project_iam_member" "tofu" {
  for_each = toset([
    "roles/editor",
    "roles/iam.securityAdmin",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/artifactregistry.admin",
    "roles/cloudtasks.admin",
    "roles/cloudscheduler.admin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.tofu.email}"
}

resource "google_billing_account_iam_member" "tofu_budgets" {
  billing_account_id = var.billing_account_id
  role               = "roles/billing.costsManager"
  member             = "serviceAccount:${google_service_account.tofu.email}"
}

resource "google_storage_bucket_iam_member" "tofu_state" {
  bucket = var.state_bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.tofu.email}"
}
