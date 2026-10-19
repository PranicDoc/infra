#!/usr/bin/env bash
# Tests for .github/actions/next-version/next-version.sh. Run: bash scripts/release/test-next-version.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/.github/actions/next-version/next-version.sh"
fails=0

expect() { # expect <latest> <bump> <expected-output>
  local out
  out=$(bash "$SCRIPT" "$1" "$2" 2>/dev/null); local code=$?
  if [ $code -ne 0 ] || [ "$out" != "$3" ]; then
    echo "FAIL: next-version '$1' $2 -> '$out' (exit $code), want '$3'"; fails=$((fails + 1))
  else
    echo "ok:   next-version '$1' $2 -> $out"
  fi
}

expect_exit2() { # expect_exit2 <latest> <bump>
  bash "$SCRIPT" "$1" "$2" >/dev/null 2>&1; local code=$?
  if [ $code -ne 2 ]; then
    echo "FAIL: next-version '$1' $2 exited $code, want 2"; fails=$((fails + 1))
  else
    echo "ok:   next-version '$1' $2 -> exit 2"
  fi
}

expect "" patch v0.0.1
expect "" minor v0.1.0
expect "" major v1.0.0
expect v1.4.2 patch v1.4.3
expect v1.4.2 minor v1.5.0
expect v1.4.2 major v2.0.0
expect_exit2 1.4.2 patch
expect_exit2 v1.4.2 hotfix

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
