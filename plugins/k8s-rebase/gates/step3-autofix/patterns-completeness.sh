#!/bin/bash
# Gate companion: patterns-completeness — build check + k8s import change summary.
# Usage: bash patterns-completeness.sh <repo-path>

source "$(dirname "$0")/../../scripts/gate-script-lib.sh"
init_gate "$@"

details=()
NEW_ISSUES=0

# Build check — runs regardless of BASE availability
for mod_dir in $(find . -name "go.mod" -not -path "*/vendor/*" -not -path "*/.claude/*" \
    -exec dirname {} \; | sort); do
  if [[ -d "$mod_dir/vendor" ]] && git check-ignore -q "$mod_dir/vendor" 2>/dev/null; then
    details+=("SKIP $mod_dir (vendor is gitignored)")
    continue
  fi
  build_rc=0
  result=$(cd "$mod_dir" && go build ./... 2>&1) || build_rc=$?
  errors=$(echo "$result" | grep -c '^.*\.go:' || true)
  if [[ "$errors" -gt 0 ]]; then
    details+=("BUILD-FAIL $mod_dir: $errors errors")
    NEW_ISSUES=$(( NEW_ISSUES + errors ))
  elif [[ "$build_rc" -ne 0 ]]; then
    # Non-zero exit with no file:line lines = linker error, permission, or toolchain issue
    details+=("BUILD-FAIL $mod_dir: non-file-line error (exit $build_rc)")
    NEW_ISSUES=$(( NEW_ISSUES + 1 ))
  else
    details+=("BUILD-OK $mod_dir")
  fi
done

# Comparison checks — require BASE
if [[ -n "$BASE" ]]; then
  changed_imports=$(git diff "$BASE"..HEAD -- '*.go' ':(exclude,glob)**/vendor/**' 2>/dev/null \
    | grep '^[+-].*"' | grep -v '^\+\+\+\|^---' \
    | grep -cE 'k8s\.io/|sigs\.k8s\.io/' || true)
  details+=("Changed k8s imports: $changed_imports")

  changed_go=$(git diff --name-only "$BASE"..HEAD \
    -- '*.go' ':(exclude,glob)**/vendor/**' 2>/dev/null | wc -l)
  details+=("Go files changed (non-vendor): $changed_go")
  [[ "$changed_go" -eq 0 ]] && details+=("No Go source changes — build-only rebase")
fi

details+=("NEW_ISSUES=$NEW_ISSUES")
finish_evidence "$NEW_ISSUES build/pattern issues" "${details[@]}"
