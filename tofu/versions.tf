terraform {
  required_version = ">= 1.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Configured per environment at init time (CI):
  #   tofu init -backend-config="bucket=<TF_STATE_BUCKET>" -backend-config="prefix=<environment>"
  # The bucket is created by scripts/bootstrap-gcp.sh.
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Billing Budgets API rejects user credentials without a quota project.
  billing_project       = var.project_id
  user_project_override = true
}
