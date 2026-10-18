#!/usr/bin/env bash
# Builds tofu/ci.auto.tfvars.json from GitHub Actions variables (non-secret settings).
# Passwords never go here — they're synced straight into Secret Manager by sync-secrets.sh.
#
# Inputs (env, from repo Variables):
#   NEON_HOST             Neon host, direct or pooled (either works)        required for a DB
#   NEON_PORT             default 5432
#   NEON_DATABASE         cph database, e.g. cph-uat
#   NEON_USERNAME         role, e.g. cph-uat_owner
#   NEON_CREDIT_DATABASE  default credit_service
#   NEON_CREDIT_USERNAME  default NEON_USERNAME
#   NEON_USE_POOLER       "true" -> cph app traffic via Neon's pooler (default: direct)
#   GOOGLE_CLIENT_ID, R2_ENDPOINT, MAIL_USERNAME, WHATSAPP_PHONE_NUMBER_ID, REDIS_HOST
set -euo pipefail
out="${1:-tofu/ci.auto.tfvars.json}"

if [ -n "${NEON_HOST:-}" ]; then
  for v in NEON_DATABASE NEON_USERNAME; do
    [ -n "${!v:-}" ] || { echo "::error::$v must be set when NEON_HOST is set"; exit 1; }
  done
  [ "${NEON_CREDIT_DATABASE:-credit_service}" != "$NEON_DATABASE" ] || {
    echo "::error::NEON_CREDIT_DATABASE must differ from NEON_DATABASE (each service runs its own Flyway)"; exit 1; }
else
  echo "::warning::NEON_HOST not set — UAT will be planned without database settings"
fi

jq -n \
  --arg host "${NEON_HOST:-}" \
  --arg port "${NEON_PORT:-5432}" \
  --arg db "${NEON_DATABASE:-}" \
  --arg user "${NEON_USERNAME:-}" \
  --arg cdb "${NEON_CREDIT_DATABASE:-credit_service}" \
  --arg cuser "${NEON_CREDIT_USERNAME:-${NEON_USERNAME:-}}" \
  --arg pooler "${NEON_USE_POOLER:-false}" \
  --arg gcid "${GOOGLE_CLIENT_ID:-}" \
  --arg r2 "${R2_ENDPOINT:-}" \
  --arg mailu "${MAIL_USERNAME:-}" \
  --arg wa "${WHATSAPP_PHONE_NUMBER_ID:-}" \
  --arg redis "${REDIS_HOST:-}" '
  # Neon pooled endpoint = compute endpoint id + "-pooler"
  def direct: sub("^(?<ep>ep-[^.]+?)-pooler\\."; "\(.ep).");
  def pooled: direct | sub("^(?<ep>ep-[^.]+?)\\."; "\(.ep)-pooler.");
  def nonempty: with_entries(select(.value != ""));
  {
    cph_env_private: ({
      GOOGLE_CLIENT_ID: $gcid,
      R2_ENDPOINT: $r2,
      MAIL_USERNAME: $mailu,
      WHATSAPP_PHONE_NUMBER_ID: $wa,
      SPRING_DATA_REDIS_HOST: $redis
    } | nonempty)
  }
  + (if $host == "" then {} else {
      uat_db: {
        pooled_host: (if $pooler == "true" then ($host | pooled) else ($host | direct) end),
        direct_host: ($host | direct),
        port: ($port | tonumber),
        username: $user,
        cph_database: $db,
        credit_username: $cuser,
        credit_database: $cdb
      }
    } end)
' > "$out"

echo "Wrote $out:"
jq '.uat_db // "no uat_db"' "$out"
