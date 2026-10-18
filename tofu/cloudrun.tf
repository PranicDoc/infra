locals {
  image_base = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo}"

  # First-create image for services CI hasn't deployed yet: Google's sample, which listens on $PORT.
  # After the first `gcloud run deploy`, CI owns the image (ignore_changes in the module).
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello"

  # Scale-to-zero Cloud Run: no in-process timers, send outbox rows inline (see cph spec
  # docs/superpowers/specs/2026-10-18-outbox-eager-dispatch.md).
  cph_cloudrun_env = merge(
    {
      APP_NOTIFICATIONS_DISPATCH                = "sync"
      APP_NOTIFICATIONS_SWEEP_SCHEDULER_ENABLED = "false"
    },
    var.enable_creditservice ? { CREDIT_SERVICE_URL = "${module.creditservice[0].uri}/credits" } : {},
  )

  # JDBC settings built from var.uat_db (Neon). By default everything uses the direct host. If app
  # traffic goes through Neon's built-in pooler (PgBouncer, transaction mode), server-side prepared
  # statements must be off (prepareThreshold=0). Flyway and creditService always connect direct,
  # because advisory locks need a real session.
  db          = var.uat_db
  uses_pooler = local.db == null ? false : strcontains(local.db.pooled_host, "-pooler.")
  cph_db_env = local.db == null ? {} : {
    SPRING_DATASOURCE_URL      = "jdbc:postgresql://${local.db.pooled_host}:${local.db.port}/${local.db.cph_database}?sslmode=require&reWriteBatchedInserts=true${local.uses_pooler ? "&prepareThreshold=0" : ""}"
    SPRING_DATASOURCE_USERNAME = local.db.username
    SPRING_FLYWAY_URL          = "jdbc:postgresql://${local.db.direct_host}:${local.db.port}/${local.db.cph_database}?sslmode=require"
    DB_HOST                    = local.db.direct_host
    DB_PORT                    = tostring(local.db.port)
    DB_USERNAME                = local.db.username
  }
  credit_db_env = local.db == null ? {} : {
    CREDIT_DB_HOST     = local.db.direct_host
    CREDIT_DB_PORT     = tostring(local.db.port)
    CREDIT_DB_USERNAME = coalesce(local.db.credit_username, local.db.username)
    # creditService's yml hard-codes the database name; this lets UAT choose it.
    SPRING_DATASOURCE_URL = "jdbc:postgresql://${local.db.direct_host}:${local.db.port}/${local.db.credit_database}?sslmode=require"
  }
}

module "cph" {
  source = "./modules/cloudrun-service"

  name                  = "cph"
  region                = var.region
  image                 = "${local.image_base}/cph:latest"
  service_account_email = google_service_account.cph_runtime.email
  port                  = 9918
  public                = true # UAT testers use it from the browser; JWT protects the API

  cpu           = var.cph.cpu
  memory        = var.cph.memory
  min_instances = var.cph.min_instances
  max_instances = var.cph.max_instances
  concurrency   = var.cph.concurrency

  env        = merge(var.cph_env, local.cph_cloudrun_env, local.cph_db_env, var.cph_env_private)
  secret_env = local.cph_secret_env

  depends_on = [google_secret_manager_secret_iam_member.readers]
}

module "pdfworker" {
  source = "./modules/cloudrun-service"
  count  = var.enable_pdfworker ? 1 : 0

  name                  = "pdfworker"
  region                = var.region
  image                 = local.placeholder_image
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
  image                 = local.placeholder_image
  service_account_email = google_service_account.creditservice_runtime[0].email
  port                  = 9112
  memory                = "512Mi"
  # cph calls it with SERVICE_API_KEY and no Google identity token, so it has to be invocable.
  public     = true
  env        = merge(var.creditservice_env, local.credit_db_env, var.creditservice_env_private)
  secret_env = var.creditservice_secret_env

  depends_on = [google_secret_manager_secret_iam_member.readers]
}
