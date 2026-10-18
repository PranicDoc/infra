variable "project_id" {
  type = string
}

variable "project_number" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "billing_account_id" {
  type = string
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
  description = "Non-secret, non-private env for cph (URLs, ports, flags). Committed in uat.tfvars."
  type        = map(string)
  default     = {}
}

variable "uat_db" {
  description = "Neon UAT Postgres. Written by scripts/configure-neon-uat.ps1 into neon.auto.tfvars (gitignored). Passwords are in Secret Manager, never here."
  type = object({
    pooled_host     = string # ep-xxx-pooler.<region>.aws.neon.tech — cph app traffic
    direct_host     = string # ep-xxx.<region>.aws.neon.tech — Flyway + creditService
    port            = optional(number, 5432)
    username        = string
    cph_database    = string
    credit_database = string
  })
  default = null
}

variable "cph_env_private" {
  description = "Private-but-not-secret env for cph (DB host, usernames, OAuth client id). Kept in the gitignored private.auto.tfvars; CI writes it from the TOFU_PRIVATE_TFVARS secret."
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
  description = "Non-private env for creditService. Committed in uat.tfvars."
  type        = map(string)
  default     = {}
}

variable "creditservice_env_private" {
  description = "Private env for creditService (DB host, username). private.auto.tfvars."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "creditservice_secret_env" {
  description = "ENV_VAR => Secret Manager secret name."
  type        = map(string)
  default     = {}
}
