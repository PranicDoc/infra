project_id         = "project-62583e23-5e4b-48e7-b00"
project_number     = "567095892493"
region             = "asia-south1"
billing_account_id = "01DE97-95AA80-8044CD"

budget_amount_inr = 2000

cph = {
  min_instances = 0 # decide warm vs cold after the poller-removal code change
  max_instances = 3
  cpu           = "1"
  memory        = "1Gi"
  concurrency   = 80
}

# Mirrors what cph/deploy/cloudrun-deploy.sh set on 2026-08-02. The APP_* and
# CREDIT_SERVICE_URL values still point at the VM — switch at cutover.
cph_env = {
  SPRING_PROFILES_ACTIVE          = "prod"
  JAVA_TOOL_OPTIONS               = "-XX:+UseContainerSupport -XX:InitialRAMPercentage=25.0 -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC -Dfile.encoding=UTF-8"
  APP_BASE_URL                    = "https://213.199.38.16/"
  APP_FEEDBACK_URL                = "https://213.199.38.16/"
  APP_INVITE_URL                  = "https://213.199.38.16/"
  CREDIT_SERVICE_URL              = "https://213.199.38.16/credits"
  MAIL_HOST                       = "smtp.hostinger.com"
  MAIL_PORT                       = "587"
  MANAGEMENT_HEALTH_REDIS_ENABLED = "true"
  SPRING_DATA_REDIS_PORT          = "6379"
  SPRING_DATA_REDIS_SSL_ENABLED   = "true"
}

enable_pdfworker     = false
enable_creditservice = false
enable_cloud_tasks   = false
