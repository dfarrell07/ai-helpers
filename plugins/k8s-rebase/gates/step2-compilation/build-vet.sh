#!/bin/bash
# Gate companion: build-vet — deterministic go build + go vet check.
# Shared by step2/build-vet and step4/build-vet-recheck.
# Diffs errors against base branch to identify new vs pre-existing issues.
# Usage: bash build-vet.sh <repo-path>

source "$(dirname "$0")/../../scripts/gate-script-lib.sh"
init_gate "$@"

NEW_ISSUES=0
details=()

for mod_dir in $(find . -name "go.mod" -not -path "*/vendor/*" -exec dirname {} \; | sort); do
  if [[ -d "$mod_dir/vendor" ]] && git check-ignore -q "$mod_dir/vendor" 2>/dev/null; then
    echo "SKIP $mod_dir (vendor is gitignored)"
    continue
  fi

  echo "CHECK $mod_dir"
  pushd "$mod_dir" >/dev/null

  build_errors=$(timeout "${GATE_TIMEOUT:-300}" go build ./... 2>&1) || true
  vet_errors=$(timeout "${GATE_TIMEOUT:-300}" go vet ./... 2>&1) || true

  if [[ -n "$build_errors" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      file=$(echo "$line" | cut -d: -f1)
      if [[ -n "$BASE" ]] && base_has "$line" "$mod_dir/$file"; then
        echo "  PRE-EXISTING: $line"
      else
        echo "  NEW: $line"
        details+=("BUILD $mod_dir: $line")
        ((NEW_ISSUES++)) || true
      fi
    done <<< "$build_errors"
  fi

  if [[ -n "$vet_errors" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" == *"# "* && "$line" != *".go:"* ]] && continue
      file=$(echo "$line" | cut -d: -f1)
      if [[ -n "$BASE" ]] && base_has "$line" "$mod_dir/$file"; then
        echo "  PRE-EXISTING: $line"
      else
        echo "  NEW: $line"
        details+=("VET $mod_dir: $line")
        ((NEW_ISSUES++)) || true
      fi
    done <<< "$vet_errors"
  fi

  popd >/dev/null
done

finish_gate "$NEW_ISSUES" "$NEW_ISSUES new build/vet issues" "${details[@]}"
