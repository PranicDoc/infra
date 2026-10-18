# Adopt resources that exist before tofu runs. Import blocks are no-ops once the resource is in
# state, so they can stay.

# ─── Always: created by scripts/bootstrap-gcp.sh in every environment ────────

import {
  to = google_service_account.tofu
  id = "projects/${var.project_id}/serviceAccounts/github-tofu@${var.project_id}.iam.gserviceaccount.com"
}

import {
  to = google_iam_workload_identity_pool.github
  id = "projects/${var.project_id}/locations/global/workloadIdentityPools/github"
}

import {
  to = google_iam_workload_identity_pool_provider.github
  id = "projects/${var.project_id}/locations/global/workloadIdentityPools/github/providers/github-oidc"
}

import {
  for_each = local.secret_names
  to       = google_secret_manager_secret.app[each.value]
  id       = "projects/${var.project_id}/secrets/${each.value}"
}

# ─── Only where things were built by hand first (adopt_existing = true) ──────

import {
  for_each = var.adopt_existing ? toset(["cph-cloudrun-runtime"]) : toset([])
  to       = google_service_account.cph_runtime
  id       = "projects/${var.project_id}/serviceAccounts/${each.value}@${var.project_id}.iam.gserviceaccount.com"
}

import {
  for_each = var.adopt_existing ? toset([var.artifact_repo]) : toset([])
  to       = google_artifact_registry_repository.images
  id       = "projects/${var.project_id}/locations/${var.region}/repositories/${each.value}"
}

import {
  for_each = var.adopt_existing ? toset(["cph"]) : toset([])
  to       = module.cph.google_cloud_run_v2_service.this
  id       = "projects/${var.project_id}/locations/${var.region}/services/${each.value}"
}

import {
  for_each = var.existing_budget_id == null ? toset([]) : toset([var.existing_budget_id])
  to       = google_billing_budget.monthly
  id       = "billingAccounts/${var.billing_account_id}/budgets/${each.value}"
}
