#!/usr/bin/env bash
# Releases every service from its default branch without running GitHub Actions:
# tags the branch head with the next version and publishes a GitHub Release whose notes list the
# merged PRs since the previous tag. A repo with nothing new is skipped.
#
# Usage: bash scripts/release/release-all.sh [--bump patch|minor|major] [--dry-run] [repo ...]
# Repos default to: PranicDoc/cph PranicDoc/credit-service PranicDoc/pdfWorker
# Needs: gh (authenticated, write access to the repos), jq.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NEXT_VERSION="$HERE/../../.github/actions/next-version/next-version.sh"
bump=patch dry=0 repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bump) bump="${2:?--bump needs patch|minor|major}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) repos+=("$1"); shift ;;
  esac
done
[ ${#repos[@]} -gt 0 ] || repos=(PranicDoc/cph PranicDoc/credit-service PranicDoc/pdfWorker)

for repo in "${repos[@]}"; do
  branch=$(gh api "repos/$repo" --jq .default_branch)
  head=$(gh api "repos/$repo/commits/$branch" --jq .sha)
  latest=$(gh api "repos/$repo/tags?per_page=100" --jq '.[].name' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)
  if [ -n "$latest" ]; then
    tag_sha=$(gh api "repos/$repo/commits/$latest" --jq .sha)
    if [ "$tag_sha" = "$head" ]; then echo "$repo: $latest is already $branch's head, skipped"; continue; fi
    ahead=$(gh api "repos/$repo/compare/$latest...$head" --jq .ahead_by)
    [ "$ahead" -gt 0 ] || { echo "$repo: nothing new since $latest, skipped"; continue; }
  fi
  next=$("$NEXT_VERSION" "$latest" "$bump")
  echo "$repo: ${latest:-none} -> $next (${branch} @ ${head:0:7})"
  [ "$dry" = 1 ] && continue
  args=(--repo "$repo" --target "$head" --title "$next" --generate-notes)
  [ -n "$latest" ] && args+=(--notes-start-tag "$latest")
  gh release create "$next" "${args[@]}"
done
