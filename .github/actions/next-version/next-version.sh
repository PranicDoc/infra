#!/usr/bin/env bash
# next-version.sh <latest-tag-or-empty> <patch|minor|major>
# Prints the next SemVer tag. No previous tag counts as v0.0.0. Exits 2 on bad input.
set -euo pipefail

latest="${1-}"
bump="${2-}"

if [ -z "$latest" ]; then
  latest="v0.0.0"
fi
if ! [[ "$latest" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "latest tag must look like vX.Y.Z, got '$latest'" >&2
  exit 2
fi
major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"

case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "bump must be patch, minor or major, got '$bump'" >&2; exit 2 ;;
esac

echo "v${major}.${minor}.${patch}"
