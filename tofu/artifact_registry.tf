resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = var.artifact_repo
  format        = "DOCKER"
  description   = "PranicDoc service images (cph, pdfWorker, creditService, ui)"

  cleanup_policy_dry_run = false

  # Per image (cph, pdfworker, creditservice): keep the 3 newest, delete the
  # rest once they're a day old. KEEP wins over DELETE.
  cleanup_policies {
    id     = "keep-3-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }

  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "86400s"
    }
  }

  depends_on = [google_project_service.this]
}
