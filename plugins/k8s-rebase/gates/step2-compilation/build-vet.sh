#!/bin/bash
# Gate companion: build-vet — deterministic go build + go vet check.
# Wired to step2/build-vet only. step4/build-vet-recheck has no companion — its .md
# inlines its own build/vet loop with a base-branch pre-existing-error exclusion.
# Fast-path PASS when zero errors. Issues found → AI subagent evaluates.
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

  local build_rc=0
  build_out=$(timeout "${GATE_TIMEOUT:-300}" go build ./... 2>&1) || build_rc=$?
  if (( build_rc >= 124 )); then
    # Timeout or signal-kill: tool never completed. Write crash and defer —
    # never FAIL (a build that would compile must not be called broken).
    mkdir -p "$REPO/.rebase-tmp/gates"
    printf 'CRASH: exit %s (inner go build kill)\n' "$build_rc" \
      > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"
    trap - EXIT; exit 0
  fi

  local vet_rc=0
  vet_out=$(timeout "${GATE_TIMEOUT:-300}" go vet ./... 2>&1) || vet_rc=$?
  if (( vet_rc >= 124 )); then
    mkdir -p "$REPO/.rebase-tmp/gates"
    printf 'CRASH: exit %s (inner go vet kill)\n' "$vet_rc" \
      > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"
    trap - EXIT; exit 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == "# "* ]] && continue
    echo "  BUILD: $line"
    details+=("BUILD $mod_dir: $line")
    ((NEW_ISSUES++)) || true
  done <<< "$build_out"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == "# "* ]] && continue
    echo "  VET: $line"
    details+=("VET $mod_dir: $line")
    ((NEW_ISSUES++)) || true
  done <<< "$vet_out"

  popd >/dev/null
done

finish_gate "$NEW_ISSUES" "$NEW_ISSUES build/vet errors" "${details[@]}"
