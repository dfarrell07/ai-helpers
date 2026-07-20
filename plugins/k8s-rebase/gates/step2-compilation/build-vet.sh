#!/bin/bash
# Gate script: build-vet mechanical check
# Run BEFORE the gate subagent. Provides concrete build/vet
# error counts that the subagent reads for its verdict.
# Usage: bash build-vet.sh <repo-path>
#
# Output: module-by-module build/vet results with error counts.
# The subagent reads this for its verdict instead of running
# build/vet itself (which may timeout on large repos).

set -uo pipefail
repo="${1:-.}"
cd "$repo" || exit 1

total_build_errors=0
total_vet_errors=0

for mod_dir in $(find . -name "go.mod" -not -path "*/vendor/*" -not -path "*/.claude/*" -exec dirname {} \; | sort); do
  # Skip modules with gitignored vendor
  if [[ -d "$mod_dir/vendor" ]] && git check-ignore -q "$mod_dir/vendor" 2>/dev/null; then
    echo "SKIP $mod_dir (vendor is gitignored)"
    continue
  fi

  echo "CHECK $mod_dir"

  # Build
  build_out=$(cd "$mod_dir" && go build ./... 2>&1) || true
  build_errors=$(echo "$build_out" | grep -c '\.go:' || true)
  if [[ "$build_errors" -gt 0 ]]; then
    echo "BUILD-FAIL $mod_dir: $build_errors errors"
    echo "$build_out" | grep '\.go:' | head -10
    total_build_errors=$((total_build_errors + build_errors))
  else
    echo "BUILD-OK $mod_dir"
  fi

  # Vet
  vet_out=$(cd "$mod_dir" && go vet ./... 2>&1) || true
  vet_errors=$(echo "$vet_out" | grep -c '\.go:' || true)
  if [[ "$vet_errors" -gt 0 ]]; then
    echo "VET-FAIL $mod_dir: $vet_errors errors"
    echo "$vet_out" | grep '\.go:' | head -10
    total_vet_errors=$((total_vet_errors + vet_errors))
  else
    echo "VET-OK $mod_dir"
  fi
done

echo ""
echo "TOTAL_BUILD_ERRORS=$total_build_errors"
echo "TOTAL_VET_ERRORS=$total_vet_errors"
