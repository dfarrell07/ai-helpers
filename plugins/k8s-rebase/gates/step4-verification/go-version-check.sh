#!/bin/bash
# Gate companion: go-version-check — verify Go version consistency.
# Usage: bash go-version-check.sh <repo-path>

source "$(dirname "$0")/../../scripts/gate-script-lib.sh"
init_gate "$@"

details=()

go_versions=()
for gomod in $(find . -name "go.mod" -not -path "*/vendor/*" | sort); do
  ver=$(awk '/^go /{print $2; exit}' "$gomod")
  [[ -n "$ver" ]] && go_versions+=("$gomod:$ver")
done

if [[ ${#go_versions[@]} -gt 1 ]]; then
  unique=$(printf '%s\n' "${go_versions[@]}" | cut -d: -f2 | sort -u | wc -l)
  if [[ "$unique" -gt 1 ]]; then
    echo "INCONSISTENT go.mod go directives:"
    printf '  %s\n' "${go_versions[@]}"
    details+=("Inconsistent go directives: $(printf '%s ' "${go_versions[@]}")")
    inc NEW_ISSUES
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
    # Skip if the version in this line already matches expected_go.
    match_short=$(echo "$match" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | grep -oE '[0-9]+\.[0-9]+')
    exp_short=$(printf '%s' "$expected_go" | grep -oE '[0-9]+\.[0-9]+')
    if [[ -n "$match_short" && -n "$exp_short" && "$match_short" == "$exp_short" ]]; then
      echo "  CORRECT: $match (version matches expected $expected_go)"
      continue
    fi
    echo "  NEW MISMATCH: $match"
    details+=("$match")
    inc NEW_ISSUES
  done
}

if [[ -n "$expected_go" ]]; then
  _check_branch_modified_refs < <(grep -rn '\bGO_VERSION\b\|\bGOLANG_VERSION\b' --include='Makefile*' . 2>/dev/null | grep -v vendor | grep -v 'GINKGO_VERSION\|HUGO_VERSION\|CARGO_VERSION\|CARGO_GO\|PROTO_GO\|MOCKGEN_GO\|OPERATOR_GO' || true)
  _check_branch_modified_refs < <(grep -rn 'golang:' --include='Dockerfile*' . 2>/dev/null | grep -v vendor || true)
fi

# If go.mod was bumped by this branch, flag any Dockerfile with golang:X.Y
# below the new directive even if the Dockerfile itself was not modified.
# The rebase script exact-version first pass misses pre-existing divergence.
if [[ -n "$BASE" ]] && [[ -n "$expected_go" ]]; then
  _new_go_short=$(printf '%s' "$expected_go" | grep -oE '[0-9]+\.[0-9]+')
  _ver_lt() { printf '%s\n%s\n' "$1" "$2" | sort -V | head -1 | grep -qx "$1"; }
  if git diff --name-only "$BASE"..HEAD -- go.mod 2>/dev/null | grep -q go.mod && [[ -n "$_new_go_short" ]]; then
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      file_ver=$(echo "$match" | grep -oE 'golang:[0-9]+\.[0-9]+' | head -1 | cut -d: -f2)
      [[ -z "$file_ver" ]] && continue
      if [[ "$file_ver" != "$_new_go_short" ]] && _ver_lt "$file_ver" "$_new_go_short"; then
        echo "  NEW MISMATCH: $match (golang:$file_ver < go.mod go $expected_go; Dockerfile not updated by rebase)"
        details+=("$match")
        inc NEW_ISSUES
      fi
    done < <(grep -rn 'golang:[0-9]' --include='Dockerfile*' . 2>/dev/null | grep -v vendor || true)
  fi
fi

finish_evidence "$NEW_ISSUES Go version issues" "${details[@]}"
