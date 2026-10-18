# Every 30 min, Cloud Scheduler asks cph to retry any outbox rows the eager path missed. On the VM
# the same sweep runs in-process (@Scheduled); here the instance may be scaled to zero, so it has
# to be woken by a request. Free: up to 3 jobs per billing account.

data "google_secret_manager_secret_version" "internal_api_key" {
  count  = var.enable_outbox_sweep ? 1 : 0
  secret = google_secret_manager_secret.app["internal-api-key"].secret_id
}

resource "google_cloud_scheduler_job" "outbox_sweep" {
  count = var.enable_outbox_sweep ? 1 : 0

  name             = "cph-outbox-sweep"
  region           = var.region
  schedule         = "*/30 * * * *"
  time_zone        = "Asia/Kolkata"
  attempt_deadline = "300s" # includes a cold start

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "${module.cph.uri}/cph/api/v1/internal/notifications/sweep"
    headers = {
      "X-Internal-Key" = data.google_secret_manager_secret_version.internal_api_key[0].secret_data
    }
  }

  depends_on = [google_project_service.this]
}
