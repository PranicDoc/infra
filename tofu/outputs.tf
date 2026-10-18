output "workload_identity_provider" {
  description = "GitHub secret/var GCP_WORKLOAD_IDENTITY_PROVIDER (all repos)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_service_account" {
  description = "GitHub GCP_SERVICE_ACCOUNT in cph / pdfWorker / credit-service."
  value       = google_service_account.deployer.email
}

output "tofu_service_account" {
  description = "GitHub TOFU_SERVICE_ACCOUNT in the infra repo."
  value       = google_service_account.tofu.email
}

output "cph_url" {
  value = module.cph.uri
}

output "creditservice_url" {
  value = var.enable_creditservice ? module.creditservice[0].uri : null
}

output "pdf_jobs_queue" {
  value = var.enable_cloud_tasks ? google_cloud_tasks_queue.pdf_jobs[0].id : null
}
