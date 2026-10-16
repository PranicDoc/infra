# Tofu owns the secret *containers* and who can read them — never the values.
# Add a value with:  gcloud secrets versions add <name> --data-file=<file>

locals {
  secret_names = toset([
    "credit-api-key",
    "db-password",
    "encryption-key",
    "google-client-secret",
    "jwt-secret",
    "mail-password",
    "r2-access-key",
    "r2-secret-key",
    "redis-password",
  ])

  cph_secret_env = {
    SPRING_DATASOURCE_PASSWORD = "db-password"
    DB_PASSWORD                = "db-password"
    JWT_SECRET                 = "jwt-secret"
    ENCRYPTION_KEY             = "encryption-key"
    GOOGLE_CLIENT_SECRET       = "google-client-secret"
    R2_ACCESS_KEY              = "r2-access-key"
    R2_SECRET_KEY              = "r2-secret-key"
    CREDIT_API_KEY             = "credit-api-key"
    MAIL_PASSWORD              = "mail-password"
    SPRING_DATA_REDIS_PASSWORD = "redis-password"
  }

  # runtime SA email => secrets it may read (only the ones its env references)
  secret_readers = merge(
    { for s in distinct(values(local.cph_secret_env)) : "cph/${s}" => { sa = google_service_account.cph_runtime.email, secret = s } },
    var.enable_pdfworker ? { for s in distinct(values(var.pdfworker_secret_env)) : "pdfworker/${s}" => { sa = google_service_account.pdfworker_runtime[0].email, secret = s } } : {},
    var.enable_creditservice ? { for s in distinct(values(var.creditservice_secret_env)) : "creditservice/${s}" => { sa = google_service_account.creditservice_runtime[0].email, secret = s } } : {},
  )
}

resource "google_secret_manager_secret" "app" {
  for_each = local.secret_names

  secret_id = each.value

  # Existing secrets were created with automatic replication; changing it forces
  # a replace (= value loss), so it stays automatic until a planned recreate.
  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this]
}

resource "google_secret_manager_secret_iam_member" "readers" {
  for_each = local.secret_readers

  secret_id = google_secret_manager_secret.app[each.value.secret].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value.sa}"
}
