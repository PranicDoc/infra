# cph enqueues one task per PDF job; Cloud Tasks pushes it to pdfWorker over
# HTTPS with an OIDC token minted for cph's runtime SA. Replaces the 1-second
# DB poll, so pdfWorker can scale to zero. Free under 1M operations/month.

resource "google_cloud_tasks_queue" "pdf_jobs" {
  count = var.enable_cloud_tasks ? 1 : 0

  name     = "pdf-jobs"
  location = var.region

  rate_limits {
    max_dispatches_per_second = 2
    max_concurrent_dispatches = 4
  }

  retry_config {
    max_attempts  = 5
    min_backoff   = "10s"
    max_backoff   = "300s"
    max_doublings = 4
  }

  depends_on = [google_project_service.this]
}

resource "google_cloud_tasks_queue_iam_member" "cph_enqueue" {
  count = var.enable_cloud_tasks ? 1 : 0

  name     = google_cloud_tasks_queue.pdf_jobs[0].name
  location = var.region
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${google_service_account.cph_runtime.email}"
}

# Creating a task with an OIDC token for SA X requires actAs on X.
resource "google_service_account_iam_member" "cph_actas_self" {
  count = var.enable_cloud_tasks ? 1 : 0

  service_account_id = google_service_account.cph_runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cph_runtime.email}"
}

resource "google_cloud_run_v2_service_iam_member" "pdfworker_invoker" {
  count = var.enable_cloud_tasks && var.enable_pdfworker ? 1 : 0

  name     = module.pdfworker[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.cph_runtime.email}"
}
