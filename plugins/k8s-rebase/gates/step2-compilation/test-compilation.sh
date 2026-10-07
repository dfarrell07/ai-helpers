#!/bin/bash
# Gate companion: test-compilation — verify test files compile.
# Checks that test modules have consistent go.mod and that test files compile.
# Runs `go test -run='^$' -count=0` to compile tests without executing them.
# Also validates go.mod consistency to catch "updates to go.mod needed" errors.
# Usage: bash test-compilation.sh <repo-path>

source "$(dirname "$0")/../../scripts/gate-script-lib.sh"
init_gate "$@"

details=()

while IFS= read -r mod_dir; do
  # Skip modules with gitignored vendor directories
  if [[ -d "$mod_dir/vendor" ]] && git check-ignore -q "$mod_dir/vendor" 2>/dev/null; then
    details+=("SKIP $mod_dir (vendor is gitignored)")
    echo "SKIP $mod_dir (vendor is gitignored)"
    continue
  fi

  echo "CHECK $mod_dir"
  details+=("CHECK $mod_dir")
  pushd "$mod_dir" >/dev/null || exit

  # Determine test flags
  test_flags="-run='^$' -count=0"
  if [[ -d "vendor" ]]; then
    test_flags+=" -mod=vendor"
  fi

  # First, validate go.mod consistency with go mod download
  # This catches "updates to go.mod needed" errors before test compilation
  download_rc=0
  download_out=$(timeout "${GATE_TIMEOUT:-300}" go mod download 2>&1) || download_rc=$?

  if (( download_rc >= 124 )); then
    mkdir -p "$REPO/.rebase-tmp/gates"
    printf 'CRASH: exit %s (go mod download timeout in %s)\n' "$download_rc" "$mod_dir" \
      > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"
    echo "CRASH: ${GATE_NAME} — go mod download killed in $mod_dir (exit ${download_rc})"
    trap - EXIT; exit 0
  fi

  if (( download_rc != 0 )); then
    echo "  DOWNLOAD_ERROR in $mod_dir"
    details+=("DOWNLOAD_ERROR $mod_dir: go mod download failed (exit $download_rc)")
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "    $line"
      details+=("  $line")
    done <<< "$download_out"
    inc NEW_ISSUES
  fi

  # Compile tests without running them
  # This catches both test compilation errors AND go.mod inconsistencies
  test_rc=0
  test_out=$(timeout "${GATE_TIMEOUT:-300}" go test $test_flags ./... 2>&1) || test_rc=$?

  if (( test_rc >= 124 )); then
    mkdir -p "$REPO/.rebase-tmp/gates"
    printf 'CRASH: exit %s (test compile timeout in %s)\n' "$test_rc" "$mod_dir" \
      > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"
    echo "CRASH: ${GATE_NAME} — test compile killed in $mod_dir (exit ${test_rc})"
    trap - EXIT; exit 0
  fi

  if (( test_rc != 0 )); then
    # Check for the specific "updates to go.mod needed" error
    if echo "$test_out" | grep -q "updates to go.mod needed"; then
      echo "  GOMOD_INCONSISTENT in $mod_dir: go.mod/go.sum needs updating"
      details+=("GOMOD_INCONSISTENT $mod_dir: go.mod/go.sum is inconsistent")
      details+=("  Fix: cd $mod_dir && go mod tidy")
      inc NEW_ISSUES
    fi

    # Report test compilation errors
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" == "# "* ]] && continue
      [[ "$line" == "PASS" ]] && continue
      [[ "$line" == "ok  "* ]] && continue
      echo "  TEST: $line"
      details+=("TEST $mod_dir: $line")
      inc NEW_ISSUES
    done <<< "$test_out"
  fi

  popd >/dev/null || exit
done < <(find . -name "go.mod" -not -path "*/vendor/*" -not -path "*/.cache/*" -exec dirname {} \; | sort)

finish_evidence "$NEW_ISSUES test compilation errors" "${details[@]}"
