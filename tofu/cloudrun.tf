locals {
  image_base = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo}"
}

module "cph" {
  source = "./modules/cloudrun-service"

  name                  = "cph"
  region                = var.region
  image                 = "${local.image_base}/cph:latest"
  service_account_email = google_service_account.cph_runtime.email
  port                  = 9918

  cpu           = var.cph.cpu
  memory        = var.cph.memory
  min_instances = var.cph.min_instances
  max_instances = var.cph.max_instances
  concurrency   = var.cph.concurrency

  env        = merge(var.cph_env, var.cph_env_private)
  secret_env = local.cph_secret_env

  depends_on = [google_secret_manager_secret_iam_member.readers]
}

# ─── Off until cutover (enable_* in prod.tfvars) ─────────────────────────────

module "pdfworker" {
  source = "./modules/cloudrun-service"
  count  = var.enable_pdfworker ? 1 : 0

  name                  = "pdfworker"
  region                = var.region
  image                 = "${local.image_base}/pdfworker:latest"
  service_account_email = google_service_account.pdfworker_runtime[0].email
  port                  = 8080
  memory                = "1Gi"
  concurrency           = 2 # PDF rendering is CPU-heavy; Cloud Tasks also caps dispatch rate
  env                   = var.pdfworker_env
  secret_env            = var.pdfworker_secret_env

  depends_on = [google_secret_manager_secret_iam_member.readers]
}

module "creditservice" {
  source = "./modules/cloudrun-service"
  count  = var.enable_creditservice ? 1 : 0

  name                  = "creditservice"
  region                = var.region
  image                 = "${local.image_base}/creditservice:latest"
  service_account_email = google_service_account.creditservice_runtime[0].email
  port                  = 9112
  memory                = "512Mi"
  env                   = var.creditservice_env
  secret_env            = var.creditservice_secret_env

  depends_on = [google_secret_manager_secret_iam_member.readers]
}

# cph is the only caller of creditService.
resource "google_cloud_run_v2_service_iam_member" "creditservice_invoker" {
  count = var.enable_creditservice ? 1 : 0

  name     = module.creditservice[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.cph_runtime.email}"
}
