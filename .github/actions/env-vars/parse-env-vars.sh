#!/usr/bin/env bash
# Turns deploy-time env vars "KEY=value;KEY2=value2" into a JSON object on stdout.
#   - pairs are separated by ';' (so a value cannot contain ';'); empty pairs are ignored
#   - the key is everything before the first '=', the value everything after it
#   - spaces around pairs, keys and values are trimmed
#   - keys must look like shell variables: letters, digits, '_', not starting with a digit
#   - values may not contain a single quote or a newline (they are written as KEY='value')
#   - a later duplicate key wins
# Exits 1 with a message on stderr for anything else.
set -euo pipefail

input="${1:-}"
case "$input" in
  *$'\n'*|*$'\r'*) echo "env vars: a value contains a line break; separate pairs with ';'" >&2; exit 1 ;;
esac

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

json='{}'
IFS=';' read -r -a pairs <<< "$input"
for raw in "${pairs[@]}"; do
  pair="$(trim "$raw")"
  [ -z "$pair" ] && continue
  if [[ "$pair" != *=* ]]; then
    echo "env vars: '$pair' is not KEY=value" >&2; exit 1
  fi
  key="$(trim "${pair%%=*}")"
  value="$(trim "${pair#*=}")"
  if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "env vars: '$key' is not a valid variable name (letters, digits, _; not starting with a digit)" >&2; exit 1
  fi
  if [[ "$value" == *"'"* ]]; then
    echo "env vars: the value of $key contains a single quote, which is not supported" >&2; exit 1
  fi
  json="$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<< "$json")"
done
printf '%s\n' "$json"
