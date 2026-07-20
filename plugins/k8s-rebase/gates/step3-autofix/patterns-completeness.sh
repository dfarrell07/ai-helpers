#!/bin/bash
# Gate script: patterns-completeness pre-existing filter
# Run BEFORE the gate subagent. Identifies which incomplete
# patterns are pre-existing vs introduced by the rebase.
# Usage: bash patterns-completeness.sh <repo-path>

set -uo pipefail
repo="${1:-.}"
cd "$repo" || exit 1

BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main 2>/dev/null)
if [[ -z "$BASE" ]]; then
  echo "NO_BASE: cannot determine pre-existing issues"
  exit 0
fi

new=0 pre=0

echo "=== Build check ==="
# Find module directories
for mod_dir in $(find . -name "go.mod" -not -path "*/vendor/*" -not -path "*/.claude/*" -exec dirname {} \; | sort); do
  if [[ -d "$mod_dir/vendor" ]] && git check-ignore -q "$mod_dir/vendor" 2>/dev/null; then
    echo "SKIP $mod_dir (vendor is gitignored)"
    continue
  fi
  result=$(cd "$mod_dir" && go build ./... 2>&1) || true
  errors=$(echo "$result" | grep -c '^.*\.go:' || true)
  if [[ "$errors" -gt 0 ]]; then
    echo "BUILD-FAIL $mod_dir: $errors errors"
    new=$((new + errors))
  else
    echo "BUILD-OK $mod_dir"
  fi
done

echo ""
echo "=== Import consistency ==="
# Check for stale imports (old version when new exists)
changed_imports=$(git diff "$BASE"..HEAD -- '*.go' ':!vendor/' 2>/dev/null \
  | grep '^[+-].*"' | grep -v '^\+\+\+\|^---' | grep -cE 'k8s\.io/|sigs\.k8s\.io/' || true)
echo "Changed k8s imports: $changed_imports"

echo ""
echo "=== Pre-existing check for non-build findings ==="
# For each Go file changed in the rebase, check if issues exist on base
for f in $(git diff --name-only "$BASE"..HEAD -- '*.go' ':!vendor/' 2>/dev/null); do
  [[ -f "$f" ]] || continue
  base_content=$(git show "$BASE:$f" 2>/dev/null) || continue
  # Check for deprecated AddToScheme/Install mixing
  curr_addto=$(grep -c '\.AddToScheme\b' "$f" 2>/dev/null || true)
  base_addto=$(echo "$base_content" | grep -c '\.AddToScheme\b' || true)
  if [[ "$curr_addto" -gt 0 && "$curr_addto" -le "$base_addto" ]]; then
    echo "$f PRE-EXISTING AddToScheme ($curr_addto current, $base_addto on base)"
    pre=$((pre + 1))
  elif [[ "$curr_addto" -gt "$base_addto" ]]; then
    echo "$f NEW AddToScheme ($curr_addto current, $base_addto on base)"
    new=$((new + 1))
  fi
done

echo ""
echo "NEW_ISSUES=$new"
echo "PRE_EXISTING=$pre"
