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

  # JDBC settings per service from var.databases. App traffic uses pooler_host when one is given
  # (PgBouncer transaction mode, so prepareThreshold=0), else the direct host. Flyway always connects
  # direct: its advisory locks need a real session.
  cph_db = lookup(var.databases, "cph", null)
  cph_db_env = local.cph_db == null ? {} : {
    SPRING_DATASOURCE_URL = (local.cph_db.pooler_host == null
      ? "jdbc:postgresql://${local.cph_db.host}:${local.cph_db.port}/${local.cph_db.name}?sslmode=require&reWriteBatchedInserts=true"
    : "jdbc:postgresql://${local.cph_db.pooler_host}:${local.cph_db.port}/${local.cph_db.name}?sslmode=require&reWriteBatchedInserts=true&prepareThreshold=0")
    SPRING_DATASOURCE_USERNAME = local.cph_db.username
    SPRING_FLYWAY_URL          = "jdbc:postgresql://${local.cph_db.host}:${local.cph_db.port}/${local.cph_db.name}?sslmode=require"
    DB_HOST                    = local.cph_db.host
    DB_PORT                    = tostring(local.cph_db.port)
    DB_USERNAME                = local.cph_db.username
  }

  credit_db = lookup(var.databases, "creditservice", null)
  credit_db_env = local.credit_db == null ? {} : {
    CREDIT_DB_HOST     = local.credit_db.host
    CREDIT_DB_PORT     = tostring(local.credit_db.port)
    CREDIT_DB_USERNAME = local.credit_db.username
    # creditService's yml hard-codes the database name; this makes it configurable.
    SPRING_DATASOURCE_URL = "jdbc:postgresql://${local.credit_db.host}:${local.credit_db.port}/${local.credit_db.name}?sslmode=require"
  }

  # pdfWorker polls cph's pdf_job table, so PDF_WORKER_DB_* normally holds the same values as CPH_DB_*.
  # Its yml binds spring.datasource.pdf-job.* (database name hard-coded); the env var overrides it.
  pdfworker_db = lookup(var.databases, "pdfworker", null)
  pdfworker_db_env = local.pdfworker_db == null ? {} : {
    SPRING_DATASOURCE_PDFJOB_URL = (local.pdfworker_db.pooler_host == null
      ? "jdbc:postgresql://${local.pdfworker_db.host}:${local.pdfworker_db.port}/${local.pdfworker_db.name}?sslmode=require"
    : "jdbc:postgresql://${local.pdfworker_db.pooler_host}:${local.pdfworker_db.port}/${local.pdfworker_db.name}?sslmode=require&prepareThreshold=0")
    DB_USERNAME = local.pdfworker_db.username
  }
  pdfworker_secret_env = merge(
    var.pdfworker_secret_env,
    local.pdfworker_db == null ? {} : { DB_PASSWORD = "pdfworker-db-password" },
  )
}

module "cph" {
  source = "./modules/cloudrun-service"

  name                  = "cph"
  region                = var.region
  image                 = "${local.image_base}/cph:latest"
  service_account_email = google_service_account.cph_runtime.email
  port                  = 9918
  public                = true # the browser UI calls it directly; JWT protects the API

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
  env                   = merge(var.pdfworker_env, local.pdfworker_db_env)
  secret_env            = local.pdfworker_secret_env

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
