# ─── Which environment, and where it lives ──────────────────────────────────
# Same code for every environment. The GitHub Environment of the same name supplies the values
# below as TF_VAR_* (see .github/workflows/tofu.yml); envs/<environment>.tfvars holds sizing/flags.

variable "environment" {
  description = "uat, prod, ... — matches the GitHub Environment and tofu/envs/<environment>.tfvars."
  type        = string
}

variable "project_id" {
  description = "GitHub Environment variable GCP_PROJECT_ID."
  type        = string
}

variable "project_number" {
  description = "GitHub Environment variable GCP_PROJECT_NUMBER."
  type        = string
}

variable "region" {
  description = "GitHub Environment variable GCP_REGION."
  type        = string
  default     = "asia-south1"
}

variable "billing_account_id" {
  description = "GitHub Environment variable GCP_BILLING_ACCOUNT."
  type        = string
}

variable "state_bucket" {
  description = "GitHub Environment variable TF_STATE_BUCKET (created by scripts/bootstrap-gcp.sh)."
  type        = string
}

variable "adopt_existing" {
  description = "Import resources that were created by hand before tofu managed this project (cph service, its runtime SA, Artifact Registry repo)."
  type        = bool
  default     = false
}

variable "existing_budget_id" {
  description = "Import this already-existing billing budget instead of creating one."
  type        = string
  default     = null
}

# ─── Databases ───────────────────────────────────────────────────────────────

variable "databases" {
  description = "Per service (keys: cph, creditservice). Built in CI from <SERVICE>_DB_* GitHub Environment variables by scripts/ci/write-tfvars.sh. Passwords live in Secret Manager, never here."
  type = map(object({
    host     = string # direct host: Flyway (advisory locks need a real session) and, by default, app traffic
    port     = optional(number, 5432)
    name     = string
    username = string
    # Optional PgBouncer (transaction mode) host for app traffic; server-side prepared statements
    # are then turned off (prepareThreshold=0). Flyway always uses `host`.
    pooler_host = optional(string)
  }))
  default = {}
}

variable "github_owner" {
  description = "GitHub org whose repos may authenticate to GCP via Workload Identity Federation."
  type        = string
  default     = "PranicDoc"
}

variable "deploy_repos" {
  description = "App repos (name only) allowed to impersonate the deployer service account."
  type        = list(string)
  default     = ["cph", "pdfWorker", "credit-service"]
}

variable "infra_repo" {
  type    = string
  default = "infra"
}

variable "artifact_repo" {
  type    = string
  default = "all-in-one"
}

variable "budget_amount_inr" {
  type    = number
  default = 2000
}

# ─── cph ─────────────────────────────────────────────────────────────────────

variable "cph" {
  description = "Sizing for the cph Cloud Run service."
  type = object({
    min_instances = number
    max_instances = number
    cpu           = string
    memory        = string
    concurrency   = number
  })
  default = {
    min_instances = 0
    max_instances = 3
    cpu           = "1"
    memory        = "1Gi"
    concurrency   = 80
  }
}

variable "cph_env" {
  description = "Non-secret, non-private env for cph (URLs, ports, flags). Committed in envs/<environment>.tfvars."
  type        = map(string)
  default     = {}
}

variable "cph_env_private" {
  description = "Private-but-not-secret env for cph (OAuth client id, R2 endpoint, mail user, Redis host), built in CI from repo variables (scripts/ci/write-tfvars.sh)."
  type        = map(string)
  default     = {}
  sensitive   = true
}

# ─── Optional services ───────────────────────────────────────────────────────

variable "enable_pdfworker" {
  type    = bool
  default = false
}

variable "enable_creditservice" {
  type    = bool
  default = false
}

variable "enable_outbox_sweep" {
  description = "Cloud Scheduler job that calls cph's outbox sweep every 30 min. Needs a value in the internal-api-key secret first."
  type        = bool
  default     = false
}

variable "enable_cloud_tasks" {
  description = "Creates the pdf-jobs queue. Turn on together with the pdfWorker poller-removal code change."
  type        = bool
  default     = false
}

variable "pdfworker_env" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "pdfworker_secret_env" {
  description = "ENV_VAR => Secret Manager secret name."
  type        = map(string)
  default     = {}
}

variable "creditservice_env" {
  description = "Non-private env for creditService. Committed in envs/<environment>.tfvars."
  type        = map(string)
  default     = {}
}

variable "creditservice_env_private" {
  description = "Extra private env for creditService (DB settings come from var.databases)."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "creditservice_secret_env" {
  description = "ENV_VAR => Secret Manager secret name."
  type        = map(string)
  default     = {}
}
