#!/bin/bash
# Utility: check if a finding exists on the base branch
# Usage: bash check-pre-existing.sh <repo-path> <file> <pattern>
# Output: PRE-EXISTING or NEW
#
# Used by gate scripts and the main agent to determine if a
# finding was introduced by the rebase or already existed.

set -uo pipefail
repo="${1:-.}"
file="${2:?Usage: check-pre-existing.sh <repo> <file> <pattern>}"
pattern="${3:?Usage: check-pre-existing.sh <repo> <file> <pattern>}"

cd "$repo" || exit 1

BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main 2>/dev/null)
if [[ -z "$BASE" ]]; then
  echo "NEW (no base branch found)"
  exit 0
fi

base_count=$(git show "$BASE:$file" 2>/dev/null | grep -c "$pattern" || true)
curr_count=$(grep -c "$pattern" "$file" 2>/dev/null || true)

if [[ "$base_count" -eq 0 && "$curr_count" -gt 0 ]]; then
  echo "NEW ($curr_count occurrences, 0 on base)"
elif [[ "$curr_count" -gt "$base_count" ]]; then
  echo "NEW ($curr_count current, $base_count on base — $((curr_count - base_count)) new)"
elif [[ "$base_count" -gt 0 ]]; then
  echo "PRE-EXISTING ($base_count on base, $curr_count current)"
else
  echo "CLEAN (not found in current or base)"
fi
