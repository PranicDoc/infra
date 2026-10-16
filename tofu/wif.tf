# Keyless GitHub Actions -> GCP. No service-account JSON keys exist anywhere,
# so there is nothing to rotate or leak.

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
  }

  # Tokens from any other GitHub org are rejected outright.
  attribute_condition = "assertion.repository_owner == '${var.github_owner}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

locals {
  wif_principal_set = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}"
}

resource "google_service_account_iam_member" "deployer_wif" {
  for_each = toset(var.deploy_repos)

  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_principal_set}/attribute.repository/${var.github_owner}/${each.value}"
}

# Plans run on PRs too, so the infra repo as a whole may impersonate; the
# apply job is what's gated (main branch + GitHub Environment reviewer).
resource "google_service_account_iam_member" "tofu_wif" {
  service_account_id = google_service_account.tofu.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "${local.wif_principal_set}/attribute.repository/${var.github_owner}/${var.infra_repo}"
}
