# One-time, run by a human with owner rights on the project:
#   1. creates the OpenTofu state bucket (versioned, Mumbai, no public access)
#   2. first `tofu apply` locally — this creates the WIF pool and the CI
#      service accounts, after which GitHub Actions takes over.
#
#   pwsh -File scripts/bootstrap.ps1            # bucket + init + plan only
#   pwsh -File scripts/bootstrap.ps1 -Apply     # ...and apply
param([switch]$Apply)
$ErrorActionPreference = 'Stop'

$Project = 'project-62583e23-5e4b-48e7-b00'
$Bucket  = 'pranicdoc-tfstate-567095892493'

gcloud config set project $Project | Out-Null

# Tofu's Google provider authenticates with Application Default Credentials.
gcloud auth application-default print-access-token *> $null
if ($LASTEXITCODE -ne 0) { gcloud auth application-default login }

gcloud storage buckets describe "gs://$Bucket" *> $null
if ($LASTEXITCODE -ne 0) {
  gcloud storage buckets create "gs://$Bucket" --location=asia-south1 `
    --uniform-bucket-level-access --public-access-prevention
  gcloud storage buckets update "gs://$Bucket" --versioning
}

$tofuDir = Join-Path $PSScriptRoot '..\tofu'
if (-not (Test-Path (Join-Path $tofuDir 'private.auto.tfvars'))) {
  throw "Create tofu/private.auto.tfvars from private.auto.tfvars.example first."
}

Push-Location $tofuDir
try {
  tofu init -input=false
  tofu plan -input=false '-var-file=uat.tfvars' -out=tfplan
  if ($Apply) { tofu apply -input=false tfplan; tofu output }
} finally { Pop-Location }
