#!/usr/bin/env bash
# Tests .github/actions/env-vars/parse-env-vars.sh: "KEY=value;KEY2=value2" -> JSON object.
# Run: bash scripts/release/test-parse-env-vars.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PARSE="$ROOT/.github/actions/env-vars/parse-env-vars.sh"
fails=0

expect() { # name, input, expected JSON (compact, sorted keys)
  local got
  got=$(bash "$PARSE" "$2" 2>/dev/null | jq -cS .) || got="<failed>"
  if [ "$got" = "$3" ]; then echo "ok:   $1"; else echo "FAIL: $1: got $got, want $3"; fails=$((fails + 1)); fi
}
reject() { # name, input
  if bash "$PARSE" "$2" >/dev/null 2>&1; then echo "FAIL: $1: accepted '$2'"; fails=$((fails + 1)); else echo "ok:   $1"; fi
}

expect "empty input is no variables"          ""                              '{}'
expect "one pair"                             "A=1"                           '{"A":"1"}'
expect "pairs split on ;"                     "A=1;B_2=two"                   '{"A":"1","B_2":"two"}'
expect "spaces around pairs and keys trimmed" " A = 1 ; B=2 ;"                '{"A":"1","B":"2"}'
expect "value keeps = and spaces inside"      "URL=https://x.io/a?b=c;MSG=hi there" '{"MSG":"hi there","URL":"https://x.io/a?b=c"}'
expect "empty value allowed"                  "EMPTY="                        '{"EMPTY":""}'
expect "later duplicate wins"                 "A=1;A=2"                       '{"A":"2"}'
expect "only separators is nothing"           ";;"                            '{}'
reject "pair without ="                       "A=1;B"
reject "key with a dash"                      "MY-KEY=1"
reject "key starting with a digit"            "1A=1"
reject "empty key"                            "=1"
reject "single quote in value"                "A=it's"
reject "newline in value"                     "A=1
B=2"

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
