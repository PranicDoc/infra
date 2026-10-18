# UAT: Cloud Run, scale to zero. Prod runs on the VM — see ansible/.
#
# Only sizing and feature flags live here. Project, region, billing account, state bucket and
# databases come from the GitHub Environment `uat` (same variable names in every environment).
# A new environment = a new envs/<name>.tfvars + a GitHub Environment <name> + bootstrap-gcp.sh.

environment = "uat"

# This project had cph, its runtime SA, Artifact Registry and a budget before tofu managed it.
adopt_existing     = true
existing_budget_id = "cb22e9a9-612f-4a47-aa08-a620c86dd598"

budget_amount_inr = 2000

cph = {
  min_instances = 0 # cold starts accepted for UAT
  max_instances = 2
  cpu           = "1"
  memory        = "1Gi"
  concurrency   = 80
}

cph_env = {
  SPRING_PROFILES_ACTIVE = "prod"
  JAVA_TOOL_OPTIONS      = "-XX:+UseContainerSupport -XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC -XX:TieredStopAtLevel=1 -Dfile.encoding=UTF-8"
  # UI links in invite / feedback messages. TODO: set once the UAT UI has a URL.
  APP_BASE_URL     = "https://uat.healingark.in/"
  APP_FEEDBACK_URL = "https://uat.healingark.in/feedback"
  APP_INVITE_URL   = "https://uat.healingark.in/accept-invite"
  # Keep UAT files out of the prod bucket (create it in Cloudflare R2 first).
  STORAGE_BUCKET                  = "pranicdoc-pdfs-uat"
  MAIL_HOST                       = "smtp.hostinger.com"
  MAIL_PORT                       = "587"
  MANAGEMENT_HEALTH_REDIS_ENABLED = "true"
  SPRING_DATA_REDIS_PORT          = "6379"
  SPRING_DATA_REDIS_SSL_ENABLED   = "true"
}

enable_creditservice = true

creditservice_env = {
  SPRING_PROFILES_ACTIVE = "prod"
  JAVA_TOOL_OPTIONS      = "-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:TieredStopAtLevel=1"
}

creditservice_secret_env = {
  CREDIT_DB_PASSWORD = "credit-db-password"
  SERVICE_API_KEY    = "credit-api-key"
}

# Turn on after `gcloud secrets versions add internal-api-key ...`.
enable_outbox_sweep = false

# No PDF generation in UAT for now (pdfWorker still polls the DB every second).
enable_pdfworker   = false
enable_cloud_tasks = false
