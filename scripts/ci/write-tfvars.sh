#!/usr/bin/env bash
# Builds tofu/ci.auto.tfvars.json from the GitHub Environment's variables (non-secret settings).
# Same variable names in every environment. Passwords never go here — sync-secrets.sh puts them
# straight into Secret Manager.
#
# Per service, prefix CPH_ (cph) or CREDIT_ (creditService):
#   <P>_DB_HOST         direct host                                   required to configure that DB
#   <P>_DB_NAME         database name                                 required with HOST
#   <P>_DB_USERNAME     role                                          required with HOST
#   <P>_DB_PORT         default 5432
#   <P>_DB_POOLER_HOST  optional PgBouncer host for app traffic (Flyway stays on HOST)
# Plus: GOOGLE_CLIENT_ID, R2_ENDPOINT, MAIL_USERNAME, WHATSAPP_PHONE_NUMBER_ID, REDIS_HOST
set -euo pipefail
out="${1:-tofu/ci.auto.tfvars.json}"

for p in CPH CREDIT; do
  host_var="${p}_DB_HOST"
  if [ -n "${!host_var:-}" ]; then
    for v in "${p}_DB_NAME" "${p}_DB_USERNAME"; do
      [ -n "${!v:-}" ] || { echo "::error::$v must be set when $host_var is set"; exit 1; }
    done
  else
    echo "::warning::$host_var not set — that service is planned without database settings"
  fi
done

if [ -n "${CPH_DB_HOST:-}" ] && [ "${CPH_DB_HOST:-}" = "${CREDIT_DB_HOST:-}" ] \
   && [ "${CPH_DB_NAME:-}" = "${CREDIT_DB_NAME:-}" ]; then
  echo "::error::cph and creditService point at the same database — each runs its own Flyway, so they need separate databases"
  exit 1
fi

jq -n '
  def blank_to_null: if . == null or . == "" then null else . end;
  def db($p):
    (env[$p + "_DB_HOST"] | blank_to_null) as $host
    | if $host == null then null else {
        host: $host,
        port: ((env[$p + "_DB_PORT"] | blank_to_null) // "5432" | tonumber),
        name: env[$p + "_DB_NAME"],
        username: env[$p + "_DB_USERNAME"],
        pooler_host: (env[$p + "_DB_POOLER_HOST"] | blank_to_null)
      } end;
  {
    databases: ({ cph: db("CPH"), creditservice: db("CREDIT") } | with_entries(select(.value != null))),
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
