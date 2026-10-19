#!/usr/bin/env bash
# Runs the "Validate inputs" step of .github/workflows/resolve-release.yml against the cases the
# Deploy workflow must accept and reject. Run: bash scripts/release/test-resolve-validate.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for PY in python3 python; do "$PY" -c "import yaml" 2>/dev/null && break; done
STEP=$("$PY" - "$ROOT/.github/workflows/resolve-release.yml" <<'PYCODE'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
print(next(s["run"] for s in wf["jobs"]["resolve"]["steps"] if s.get("name") == "Validate inputs"))
PYCODE
)
fails=0
check() { # check <want: ok|fail> <tag> <target> <environment> [message-substring]
  out=$(TAG="$2" TARGET="$3" ENVIRONMENT="$4" bash -c "$STEP" 2>&1); code=$?
  if [ "$1" = ok ] && [ $code -eq 0 ]; then echo "ok:   accepts '$2' $3/$4"
  elif [ "$1" = fail ] && [ $code -ne 0 ] && [[ "$out" == *"$5"* ]]; then echo "ok:   rejects '$2' $3/$4 ($5)"
  else echo "FAIL: '$2' $3/$4 -> exit $code, output: $out"; fails=$((fails + 1)); fi
}
check ok   ""      vm       prod
check ok   v1.4.0  vm       prod
check ok   v1.4.0  cloudrun uat
check fail bad     vm       prod "tag must be vX.Y.Z"
check fail main    vm       prod "tag must be vX.Y.Z"
check fail v1.4    vm       prod "tag must be vX.Y.Z"
check fail ""      vm       uat  "vm requires prod"
check fail ""      cloudrun prod "cloudrun requires uat"
check fail ""      k8s      prod "target must be vm or cloudrun"
[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
