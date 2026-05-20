#!/bin/bash
# k8s-rebase-validate.sh — Phase 4 steps 1-2: collect and categorize errors
#
# Runs build, lint, and test for all modules. Captures output to logs.
# Parses logs to extract actionable errors. Writes categorized summary.
#
# Exit codes: 0 = all validation passes (no errors)
#             1 = errors found (see $REBASE_TMP/summary.txt)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: Not in a git repository" >&2; exit 1; }
REBASE_TMP="$REPO_ROOT/.rebase-tmp"
mkdir -p "$REBASE_TMP"

# Auto-containerize if local Go is too old for the repo's go.mod
cd "$REPO_ROOT"
REQUIRED_GO=""
for gm in go-controller/go.mod go.mod; do
  [[ -f "$gm" ]] && REQUIRED_GO=$(grep "^go " "$gm" | awk '{print $2}') && break
done
CURRENT_GO=$(go env GOVERSION 2>/dev/null | sed 's/go//' || echo "0.0")
if [[ -n "$REQUIRED_GO" ]] && [[ "${K8S_REBASE_IN_CONTAINER:-}" != "1" ]]; then
  REQ_MINOR=$(echo "$REQUIRED_GO" | cut -d. -f2)
  CUR_MINOR=$(echo "$CURRENT_GO" | cut -d. -f2)
  if [[ "$CUR_MINOR" -lt "$REQ_MINOR" ]] 2>/dev/null; then
    CONTAINER_RT=""
    command -v podman &>/dev/null && CONTAINER_RT=podman
    [[ -z "$CONTAINER_RT" ]] && command -v docker &>/dev/null && CONTAINER_RT=docker
    if [[ -n "$CONTAINER_RT" ]]; then
      GO_IMAGE="docker.io/library/golang:${REQUIRED_GO}"
      echo ":: Go $CURRENT_GO < $REQUIRED_GO — re-running validate inside $GO_IMAGE"
      SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
      exec $CONTAINER_RT run --rm \
        --security-opt label=disable \
        -v "$REPO_ROOT:$REPO_ROOT" \
        -v "$(dirname "$SCRIPT_PATH"):$(dirname "$SCRIPT_PATH"):ro" \
        -w "$REPO_ROOT" \
        -e K8S_REBASE_IN_CONTAINER=1 \
        "$GO_IMAGE" \
        bash "$SCRIPT_PATH"
    fi
  fi
fi

SUMMARY="$REBASE_TMP/summary.txt"
ERRORS_FOUND=0
VALIDATION_TIMEOUT="${VALIDATION_TIMEOUT:-25m}"

: > "$SUMMARY"

run_validation() {
  local name="$1"
  local logfile="$REBASE_TMP/${name}.log"
  shift

  echo ":: Running: $name (timeout: $VALIDATION_TIMEOUT)"
  local rc=0
  timeout "$VALIDATION_TIMEOUT" bash -c "$*" > "$logfile" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "  PASS"
    return 0
  elif [[ "$rc" -eq 124 ]]; then
    echo "  TIMEOUT after $VALIDATION_TIMEOUT (see $logfile)"
    echo "" >> "$logfile"
    echo "TIMEOUT: command did not complete within $VALIDATION_TIMEOUT" >> "$logfile"
    return 1
  else
    echo "  FAIL (see $logfile)"
    return 1
  fi
}

categorize_errors() {
  local logfile="$1"
  local category="$2"
  local step_failed="${3:-0}"

  local build_errors lint_errors test_failures
  build_errors=$(grep -E ":[0-9]+:[0-9]+: (undefined|too many arguments|too few arguments|cannot use|not enough arguments)" "$logfile" 2>/dev/null || true)
  lint_errors=$(grep -E "\.go:[0-9]+:[0-9]+:.*(SA[0-9]+|staticcheck|lostcancel|gci)" "$logfile" 2>/dev/null | grep -v "^#" || true)
  test_failures=$(grep -E "^--- FAIL:|^FAIL\t" "$logfile" 2>/dev/null || true)

  if [[ -n "$build_errors" ]]; then
    echo "## BUILD ERRORS ($category)" >> "$SUMMARY"
    echo "$build_errors" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    ERRORS_FOUND=1
  fi

  if [[ -n "$lint_errors" ]]; then
    echo "## LINT ERRORS ($category)" >> "$SUMMARY"
    echo "$lint_errors" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    ERRORS_FOUND=1
  fi

  if [[ -n "$test_failures" ]]; then
    echo "## TEST FAILURES ($category)" >> "$SUMMARY"
    echo "$test_failures" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    ERRORS_FOUND=1
  fi

  local timeout_errors
  timeout_errors=$(grep -E "^TIMEOUT:" "$logfile" 2>/dev/null || true)
  if [[ -n "$timeout_errors" ]]; then
    echo "## TIMEOUT ($category)" >> "$SUMMARY"
    echo "$timeout_errors" >> "$SUMMARY"
    echo "Possible causes: feature gate causing test hang, resource exhaustion, resource leak" >> "$SUMMARY"
    echo "Check $REBASE_TMP/new-gates.txt for newly enabled feature gates" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    ERRORS_FOUND=1
  fi

  if [[ "$step_failed" -eq 1 ]] && [[ -z "$build_errors" ]] && [[ -z "$lint_errors" ]] && [[ -z "$test_failures" ]] && [[ -z "$timeout_errors" ]]; then
    echo "## UNCLASSIFIED FAILURE ($category)" >> "$SUMMARY"
    tail -10 "$logfile" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    ERRORS_FOUND=1
  fi
}

cd "$REPO_ROOT"

echo "━━━━ Phase 4: Build Validation ━━━━"
echo ""

step_failed=0

# Auto-detect modules and validate each one
while IFS= read -r gomod; do
  mod_dir=$(dirname "$gomod" | sed 's|^\./||')
  mod_name=$(basename "$mod_dir")
  [[ "$mod_dir" == "." ]] && mod_name="root"

  # Try make first (if Makefile exists), fall back to go build
  step_failed=0
  if [[ -f "$REPO_ROOT/$mod_dir/Makefile" ]]; then
    run_validation "${mod_name}-build" "make -C $mod_dir" || step_failed=1
    categorize_errors "$REBASE_TMP/${mod_name}-build.log" "$mod_name build" "$step_failed"

    step_failed=0
    if grep -q "^lint:" "$REPO_ROOT/$mod_dir/Makefile" 2>/dev/null; then
      run_validation "${mod_name}-lint" "make -C $mod_dir lint" || {
        if grep -qE "Go language version.*lower than the targeted|failed to install golangci-lint" "$REBASE_TMP/${mod_name}-lint.log" 2>/dev/null; then
          echo "  NOTE: lint tool version incompatible, installing latest via go install..."
          go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest 2>/dev/null
          if command -v golangci-lint &>/dev/null; then
            run_validation "${mod_name}-lint" "cd $mod_dir && golangci-lint run --verbose --modules-download-mode=vendor --timeout=15m0s" || step_failed=1
          else
            step_failed=1
          fi
        else
          step_failed=1
        fi
      }
      categorize_errors "$REBASE_TMP/${mod_name}-lint.log" "$mod_name lint" "$step_failed"
    fi

    step_failed=0
    if grep -q "^test:" "$REPO_ROOT/$mod_dir/Makefile" 2>/dev/null; then
      # Try make test first; if it needs sudo (common for network namespace tests),
      # fall back to go test without -race for non-privileged packages
      run_validation "${mod_name}-test" "make -C $mod_dir test" || {
        if grep -q "sudo" "$REBASE_TMP/${mod_name}-test.log" 2>/dev/null; then
          echo "  NOTE: make test needs sudo/privileged container for some packages"
          echo "  Running go test without -race on non-sudo packages..."
          run_validation "${mod_name}-test" "cd $mod_dir && go test -mod vendor -timeout 10m ./... -count=1" || step_failed=1
        else
          step_failed=1
        fi
      }
      categorize_errors "$REBASE_TMP/${mod_name}-test.log" "$mod_name test" "$step_failed"
    fi
  else
    run_validation "${mod_name}-build" "cd $mod_dir && go build ./..." || step_failed=1
    categorize_errors "$REBASE_TMP/${mod_name}-build.log" "$mod_name build" "$step_failed"
  fi

  # Always run go vet — catches type mismatches that go build misses
  step_failed=0
  run_validation "${mod_name}-vet" "cd $mod_dir && go vet ./..." || step_failed=1
  categorize_errors "$REBASE_TMP/${mod_name}-vet.log" "$mod_name vet" "$step_failed"
done < <(find . -name "go.mod" -not -path "*/vendor/*" | sort)

echo ""
if [[ "$ERRORS_FOUND" -eq 0 ]]; then
  echo "All validation passes. No Phase 4 fixups needed."
  exit 0
else
  echo "Errors found. Summary: $SUMMARY"
  echo ""
  cat "$SUMMARY"
  exit 1
fi
