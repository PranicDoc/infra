#!/usr/bin/env bash
# One-time GCP bootstrap so GitHub Actions can run everything else.
#
# GitHub can't authenticate to GCP until GCP trusts it, so this part needs a human once.
# Run it in Cloud Shell (console.cloud.google.com -> the >_ icon) as a project owner and
# billing admin. Nothing to install. It's idempotent: re-running only fills gaps.
#
#   bash bootstrap-gcp.sh            # paste the file into Cloud Shell, or upload it
#
# Creates: required APIs, the OpenTofu state bucket, the GitHub OIDC trust (WIF pool + provider),
# the github-tofu service account and its roles, and the (empty) app secret containers.
# The tofu workflow then adopts all of it (tofu/imports.tf) and manages it from there.
set -euo pipefail

PROJECT="project-62583e23-5e4b-48e7-b00"
PROJECT_NUMBER="567095892493"
BILLING_ACCOUNT="01DE97-95AA80-8044CD"   # update when the company billing account replaces it
REGION="asia-south1"
GITHUB_OWNER="PranicDoc"
INFRA_REPO="infra"
BUCKET="pranicdoc-tfstate-${PROJECT_NUMBER}"
TOFU_SA="github-tofu@${PROJECT}.iam.gserviceaccount.com"
POOL="github"
PROVIDER="github-oidc"
SECRETS=(credit-api-key credit-db-password db-password encryption-key google-client-secret
         internal-api-key jwt-secret mail-password r2-access-key r2-secret-key redis-password)

gcloud config set project "$PROJECT" >/dev/null

echo "==> APIs"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com serviceusage.googleapis.com storage.googleapis.com \
  secretmanager.googleapis.com billingbudgets.googleapis.com cloudbilling.googleapis.com

echo "==> State bucket gs://${BUCKET}"
if ! gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${BUCKET}" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
gcloud storage buckets update "gs://${BUCKET}" --versioning >/dev/null

echo "==> Service account ${TOFU_SA}"
if ! gcloud iam service-accounts describe "$TOFU_SA" >/dev/null 2>&1; then
  gcloud iam service-accounts create github-tofu --display-name="GitHub Actions - OpenTofu"
fi
# Keep in sync with google_project_iam_member.tofu in tofu/iam.tf.
for role in roles/editor roles/iam.securityAdmin roles/iam.workloadIdentityPoolAdmin roles/run.admin \
            roles/secretmanager.admin roles/artifactregistry.admin roles/cloudtasks.admin \
            roles/cloudscheduler.admin roles/serviceusage.serviceUsageAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:${TOFU_SA}" \
    --role="$role" --condition=None >/dev/null
done
gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT" \
  --member="serviceAccount:${TOFU_SA}" --role=roles/billing.costsManager >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${TOFU_SA}" --role=roles/storage.objectAdmin >/dev/null

echo "==> GitHub OIDC trust"
if ! gcloud iam workload-identity-pools describe "$POOL" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$POOL" --location=global --display-name="GitHub Actions"
fi
if ! gcloud iam workload-identity-pools providers describe "$PROVIDER" --location=global \
       --workload-identity-pool="$POOL" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" --location=global \
    --workload-identity-pool="$POOL" --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository_owner == '${GITHUB_OWNER}'"
fi
gcloud iam service-accounts add-iam-policy-binding "$TOFU_SA" --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${GITHUB_OWNER}/${INFRA_REPO}" >/dev/null

echo "==> Secret containers (values come from GitHub via the workflow)"
for s in "${SECRETS[@]}"; do
  gcloud secrets describe "$s" >/dev/null 2>&1 || gcloud secrets create "$s" --replication-policy=automatic >/dev/null
done

cat <<EOF

Done. In GitHub -> PranicDoc/infra -> Settings -> Secrets and variables -> Actions -> Variables:
  GCP_WORKLOAD_IDENTITY_PROVIDER = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}
  TOFU_SERVICE_ACCOUNT           = ${TOFU_SA}
EOF
