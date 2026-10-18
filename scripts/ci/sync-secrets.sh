#!/usr/bin/env bash
# Copies the GitHub Environment's secrets into that environment's GCP Secret Manager.
#
# For each mapping below: if the GitHub secret is set and differs from the secret's latest
# version, add a new version and destroy the older ones (keeps us inside the 6 free versions).
# Unset GitHub secrets are skipped, so the existing value stays. Values are never printed.
set -euo pipefail
PROJECT="${GCP_PROJECT:?GCP_PROJECT not set}"

sync() {
  local secret="$1" value="$2"
  if [ -z "$value" ]; then
    echo "skip      $secret (no GitHub secret)"
    return
  fi
  if ! gcloud secrets describe "$secret" --project="$PROJECT" >/dev/null 2>&1; then
    gcloud secrets create "$secret" --project="$PROJECT" --replication-policy=automatic >/dev/null
  fi

  local current
  current="$(gcloud secrets versions access latest --secret="$secret" --project="$PROJECT" 2>/dev/null || true)"
  if [ "$current" == "$value" ]; then
    echo "unchanged $secret"
    return
  fi

  local file new v
  file="$(mktemp)"
  printf '%s' "$value" > "$file"   # no trailing newline
  new="$(gcloud secrets versions add "$secret" --project="$PROJECT" --data-file="$file" --format='value(name.basename())')"
  rm -f "$file"
  echo "updated   $secret -> version $new"

  for v in $(gcloud secrets versions list "$secret" --project="$PROJECT" --filter='state=ENABLED' --format='value(name.basename())'); do
    if [ "$v" != "$new" ]; then
      gcloud secrets versions destroy "$v" --secret="$secret" --project="$PROJECT" --quiet >/dev/null
      echo "          destroyed old version $v"
    fi
  done
}

# Secret Manager name    GitHub Environment secret (same names in every environment)
sync db-password            "${CPH_DB_PASSWORD:-}"
sync credit-db-password     "${CREDIT_DB_PASSWORD:-}"
sync pdfworker-db-password  "${PDF_WORKER_DB_PASSWORD:-}"
sync jwt-secret           "${JWT_SECRET:-}"
sync encryption-key       "${ENCRYPTION_KEY:-}"
sync internal-api-key     "${INTERNAL_API_KEY:-}"
sync google-client-secret "${GOOGLE_CLIENT_SECRET:-}"
sync r2-access-key        "${R2_ACCESS_KEY:-}"
sync r2-secret-key        "${R2_SECRET_KEY:-}"
sync credit-api-key       "${CREDIT_API_KEY:-}"
sync mail-password        "${MAIL_PASSWORD:-}"
sync redis-password       "${REDIS_PASSWORD:-}"
