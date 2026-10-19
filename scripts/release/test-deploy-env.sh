#!/usr/bin/env bash
# Runs the "Validate environment" step of deploy-vm.yml and deploy-cloudrun.yml: only prod and uat
# are accepted (approval is skipped only for exactly uat, so anything else must not get through).
# Run: bash scripts/release/test-deploy-env.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for PY in python3 python; do "$PY" -c "import yaml" 2>/dev/null && break; done
fails=0
for wf in deploy-vm deploy-cloudrun; do
  STEP=$("$PY" - "$ROOT/.github/workflows/$wf.yml" <<'PYCODE'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
print(next(s["run"] for s in wf["jobs"]["check"]["steps"] if s.get("name") == "Validate environment"))
PYCODE
  ) || { echo "FAIL: $wf has no check job / Validate environment step"; fails=$((fails + 1)); continue; }
  for env in prod uat; do
    ENVIRONMENT="$env" bash -c "$STEP" >/dev/null 2>&1 \
      && echo "ok:   $wf accepts $env" || { echo "FAIL: $wf rejects $env"; fails=$((fails + 1)); }
  done
  for env in production Prod staging ""; do
    ENVIRONMENT="$env" bash -c "$STEP" >/dev/null 2>&1 \
      && { echo "FAIL: $wf accepts '$env'"; fails=$((fails + 1)); } || echo "ok:   $wf rejects '$env'"
  done
done
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
