#!/bin/bash
# Gate companion: go-version-check — verify Go version consistency.
# Usage: bash go-version-check.sh <repo-path>

source "$(dirname "$0")/../../scripts/gate-script-lib.sh"
init_gate "$@"

NEW_ISSUES=0
details=()

go_versions=()
for gomod in $(find . -name "go.mod" -not -path "*/vendor/*" | sort); do
  ver=$(grep '^go ' "$gomod" | awk '{print $2}' | head -1)
  [[ -n "$ver" ]] && go_versions+=("$gomod:$ver")
done

if [[ ${#go_versions[@]} -gt 1 ]]; then
  unique=$(printf '%s\n' "${go_versions[@]}" | cut -d: -f2 | sort -u | wc -l)
  if [[ "$unique" -gt 1 ]]; then
    echo "INCONSISTENT go.mod go directives:"
    printf '  %s\n' "${go_versions[@]}"
    details+=("Inconsistent go directives: $(printf '%s ' "${go_versions[@]}")")
    ((NEW_ISSUES++)) || true
  fi
fi

expected_go=""
if [[ ${#go_versions[@]} -gt 0 ]]; then
  expected_go=$(printf '%s\n' "${go_versions[@]}" | head -1 | cut -d: -f2)
fi

_check_branch_modified_refs() {
  # Only flag matches in files touched by this branch; skip pre-existing ones.
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    file=$(echo "$match" | cut -d: -f1)
    if [[ -n "$BASE" ]]; then
      modified=$(git diff --name-only "$BASE"..HEAD -- "$file" | wc -l)
      if [[ "$modified" -eq 0 ]]; then
        echo "  PRE-EXISTING: $match (file not modified by this branch)"
        continue
      fi
    fi
    echo "  NEW: $match"
    details+=("$match")
    ((NEW_ISSUES++)) || true
  done
}

if [[ -n "$expected_go" ]]; then
  _check_branch_modified_refs < <(grep -rn '\bGO_VERSION\b\|\bGOLANG_VERSION\b' --include='Makefile*' . 2>/dev/null | grep -v vendor | grep -v 'GINKGO_VERSION\|HUGO_VERSION\|CARGO_VERSION\|CARGO_GO\|PROTO_GO\|MOCKGEN_GO\|OPERATOR_GO' || true)
  _check_branch_modified_refs < <(grep -rn 'golang:' --include='Dockerfile*' . 2>/dev/null | grep -v vendor || true)
fi

finish_evidence "$NEW_ISSUES Go version issues" "${details[@]}"
