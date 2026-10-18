#!/usr/bin/env bash
# Builds tofu/ci.auto.tfvars.json from the GitHub Environment's variables (non-secret settings).
# Same variable names in every environment (uat, prod, ...); only the values differ.
# Passwords never go here — sync-secrets.sh puts them straight into Secret Manager.
#
# One full set per service, no fallbacks — repeat values where services share a server:
#   CPH_DB_HOST         CREDIT_DB_HOST         PDF_WORKER_DB_HOST         direct host
#   CPH_DB_PORT         CREDIT_DB_PORT         PDF_WORKER_DB_PORT         default 5432
#   CPH_DB_NAME         CREDIT_DB_NAME         PDF_WORKER_DB_NAME
#   CPH_DB_USERNAME     CREDIT_DB_USERNAME     PDF_WORKER_DB_USERNAME
#   CPH_DB_POOLER_HOST  CREDIT_DB_POOLER_HOST  PDF_WORKER_DB_POOLER_HOST  optional PgBouncer host
# HOST, NAME and USERNAME go together; a service with no HOST gets no database settings.
# Plus: GOOGLE_CLIENT_ID, R2_ENDPOINT, MAIL_USERNAME, WHATSAPP_PHONE_NUMBER_ID, REDIS_HOST
set -euo pipefail
out="${1:-tofu/ci.auto.tfvars.json}"

for p in CPH_DB CREDIT_DB PDF_WORKER_DB; do
  host_var="${p}_HOST"
  if [ -n "${!host_var:-}" ]; then
    for v in "${p}_NAME" "${p}_USERNAME"; do
      [ -n "${!v:-}" ] || { echo "::error::$v must be set when $host_var is set"; exit 1; }
    done
  else
    echo "::notice::$host_var not set — no database settings for that service"
  fi
done

# cph and creditService each run their own Flyway, so they can't share a database.
if [ -n "${CPH_DB_HOST:-}" ] && [ "${CPH_DB_HOST:-}" = "${CREDIT_DB_HOST:-}" ] \
   && [ "${CPH_DB_NAME:-}" = "${CREDIT_DB_NAME:-}" ]; then
  echo "::error::CREDIT_DB_NAME must differ from CPH_DB_NAME on the same host — each service runs its own Flyway"
  exit 1
fi
# pdfWorker reads cph's pdf_job table; a different database is almost certainly a mistake.
if [ -n "${PDF_WORKER_DB_HOST:-}" ] && [ -n "${CPH_DB_HOST:-}" ] \
   && { [ "${PDF_WORKER_DB_HOST}" != "${CPH_DB_HOST}" ] || [ "${PDF_WORKER_DB_NAME:-}" != "${CPH_DB_NAME:-}" ]; }; then
  echo "::warning::PDF_WORKER_DB_* points at a different database than CPH_DB_* — pdfWorker polls cph's pdf_job table"
fi

jq -n '
  def blank_to_null: if . == null or . == "" then null else . end;
  def db($p):
    (env[$p + "_HOST"] | blank_to_null) as $host
    | if $host == null then null else {
        host: $host,
        port: ((env[$p + "_PORT"] | blank_to_null) // "5432" | tonumber),
        name: env[$p + "_NAME"],
        username: env[$p + "_USERNAME"],
        pooler_host: (env[$p + "_POOLER_HOST"] | blank_to_null)
      } end;
  {
    databases: ({
      cph: db("CPH_DB"),
      creditservice: db("CREDIT_DB"),
      pdfworker: db("PDF_WORKER_DB")
    } | with_entries(select(.value != null))),
    cph_env_private: ({
      GOOGLE_CLIENT_ID: env.GOOGLE_CLIENT_ID,
      R2_ENDPOINT: env.R2_ENDPOINT,
      MAIL_USERNAME: env.MAIL_USERNAME,
      WHATSAPP_PHONE_NUMBER_ID: env.WHATSAPP_PHONE_NUMBER_ID,
      SPRING_DATA_REDIS_HOST: env.REDIS_HOST
    } | with_entries(select((.value | blank_to_null) != null)))
  }
' > "$out"

echo "Wrote $out:"
jq '.databases' "$out"
