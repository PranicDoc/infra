#!/usr/bin/env bash
# Builds tofu/ci.auto.tfvars.json from the GitHub Environment's variables (non-secret settings).
# Variable names are the same in every environment, and they match the env vars the services
# themselves read. Passwords never go here — sync-secrets.sh puts them straight into Secret Manager.
#
#   DB_HOST, DB_NAME, DB_USERNAME    cph's database                      (required together)
#   DB_PORT                          default 5432
#   DB_POOLER_HOST                   optional PgBouncer host for app traffic (Flyway stays on DB_HOST)
#   CREDIT_DB_NAME                   creditService's database (must differ from DB_NAME)
#   CREDIT_DB_HOST / _PORT / _USERNAME / _POOLER_HOST
#                                    only if creditService uses a different server; default to DB_*
#   GOOGLE_CLIENT_ID, R2_ENDPOINT, MAIL_USERNAME, WHATSAPP_PHONE_NUMBER_ID, REDIS_HOST
set -euo pipefail
out="${1:-tofu/ci.auto.tfvars.json}"

# creditService inherits the shared server settings unless overridden.
export CREDIT_DB_HOST="${CREDIT_DB_HOST:-${DB_HOST:-}}"
export CREDIT_DB_PORT="${CREDIT_DB_PORT:-${DB_PORT:-}}"
export CREDIT_DB_USERNAME="${CREDIT_DB_USERNAME:-${DB_USERNAME:-}}"
export CREDIT_DB_POOLER_HOST="${CREDIT_DB_POOLER_HOST:-${DB_POOLER_HOST:-}}"

if [ -n "${DB_HOST:-}" ]; then
  for v in DB_NAME DB_USERNAME; do
    [ -n "${!v:-}" ] || { echo "::error::$v must be set when DB_HOST is set"; exit 1; }
  done
else
  echo "::warning::DB_HOST not set — cph is planned without database settings"
fi
if [ -n "${CREDIT_DB_HOST:-}" ] && [ -z "${CREDIT_DB_NAME:-}" ]; then
  echo "::warning::CREDIT_DB_NAME not set — creditService is planned without database settings"
  export CREDIT_DB_HOST=""
fi
if [ -n "${CREDIT_DB_NAME:-}" ] && [ "${CREDIT_DB_HOST}" = "${DB_HOST:-}" ] && [ "${CREDIT_DB_NAME}" = "${DB_NAME:-}" ]; then
  echo "::error::CREDIT_DB_NAME must differ from DB_NAME — each service runs its own Flyway"
  exit 1
fi

jq -n '
  def blank_to_null: if . == null or . == "" then null else . end;
  def db($p):
    (env[$p + "HOST"] | blank_to_null) as $host
    | if $host == null then null else {
        host: $host,
        port: ((env[$p + "PORT"] | blank_to_null) // "5432" | tonumber),
        name: env[$p + "NAME"],
        username: env[$p + "USERNAME"],
        pooler_host: (env[$p + "POOLER_HOST"] | blank_to_null)
      } end;
  {
    databases: ({ cph: db("DB_"), creditservice: db("CREDIT_DB_") } | with_entries(select(.value != null))),
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
