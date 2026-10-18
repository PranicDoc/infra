# Adopt what exists outside tofu: resources created by hand in Jul/Aug 2026 and on 2026-10-16, plus
# everything scripts/bootstrap-gcp.sh creates. Import blocks are no-ops once the resource is in
# state, so they can stay.

import {
  to = google_service_account.cph_runtime
  id = "projects/${var.project_id}/serviceAccounts/cph-cloudrun-runtime@${var.project_id}.iam.gserviceaccount.com"
}

import {
  to = google_artifact_registry_repository.images
  id = "projects/${var.project_id}/locations/${var.region}/repositories/${var.artifact_repo}"
}

# All app secrets: the original nine, plus the two bootstrap-gcp.sh creates (empty).
import {
  for_each = local.secret_names
  to       = google_secret_manager_secret.app[each.value]
  id       = "projects/${var.project_id}/secrets/${each.value}"
}

import {
  to = module.cph.google_cloud_run_v2_service.this
  id = "projects/${var.project_id}/locations/${var.region}/services/cph"
}

import {
  to = google_billing_budget.monthly
  id = "billingAccounts/${var.billing_account_id}/budgets/cb22e9a9-612f-4a47-aa08-a620c86dd598"
}

# ─── Created by scripts/bootstrap-gcp.sh ─────────────────────────────────────

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
