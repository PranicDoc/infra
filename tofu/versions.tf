terraform {
  required_version = ">= 1.8"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Created once by scripts/bootstrap.ps1 (versioned, uniform access, asia-south1).
  backend "gcs" {
    bucket = "pranicdoc-tfstate-567095892493"
    prefix = "prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Billing Budgets API rejects user credentials without a quota project.
  billing_project       = var.project_id
  user_project_override = true
}
