#!/bin/bash
# k8s-rebase-validate.sh — Phase 4: collect and categorize errors
#
# Runs build, lint, and test for all modules. Captures output to logs.
# Parses logs to extract actionable errors. Writes categorized summary.
#
# Usage: k8s-rebase-validate.sh [--quick|--full]
#   --quick  Build + vet only (~1 min)
#   --full   All checks + privileged tests as root (~25 min)
#   default  All checks except privileged tests (~15 min)
#
# Exit codes: 0 = all validation passes (no errors)
#             1 = errors found (see $REBASE_TMP/summary.txt)

set -uo pipefail

MODE="default"
[[ "${1:-}" == "--quick" ]] && MODE="quick"
[[ "${1:-}" == "--full" ]] && MODE="full"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: Not in a git repository" >&2; exit 1; }
REBASE_TMP="$REPO_ROOT/.rebase-tmp"
mkdir -p "$REBASE_TMP"
grep -qF '.rebase-tmp' "$REPO_ROOT/.git/info/exclude" 2>/dev/null || echo '.rebase-tmp/' >> "$REPO_ROOT/.git/info/exclude"

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
      USERNS_FLAG=""
      [[ "$CONTAINER_RT" == "podman" ]] && [[ "$MODE" != "full" ]] && USERNS_FLAG="--userns=keep-id"
      MODE_FLAG=""
      [[ "$MODE" != "default" ]] && MODE_FLAG="--$MODE"
      exec $CONTAINER_RT run --rm \
        --security-opt label=disable \
        --privileged \
        $USERNS_FLAG \
        -v "$REPO_ROOT:$REPO_ROOT" \
        -v "$(dirname "$SCRIPT_PATH"):$(dirname "$SCRIPT_PATH"):ro" \
        -w "$REPO_ROOT" \
        -e K8S_REBASE_IN_CONTAINER=1 \
        "$GO_IMAGE" \
        bash "$SCRIPT_PATH" $MODE_FLAG
    fi
  fi
fi

cleanup() { rm -rf "$REBASE_TMP"; }

SUMMARY="$REBASE_TMP/summary.txt"
ERRORS_FOUND=0
VALIDATION_TIMEOUT="${VALIDATION_TIMEOUT:-25m}"
LINT_TIMEOUT="${LINT_TIMEOUT:-30m}"

: > "$SUMMARY"

# Container setup: install missing tools needed by CI checks
if [[ "${K8S_REBASE_IN_CONTAINER:-}" == "1" ]]; then
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=safe.directory
  export GIT_CONFIG_VALUE_0="$REPO_ROOT"
  # Sudo shim: when running as root, test scripts that invoke sudo
  # work transparently without installing the sudo package
  if [[ "$(id -u)" == "0" ]] && ! command -v sudo &>/dev/null; then
    printf '#!/bin/sh\nwhile [ "${1#-}" != "$1" ]; do shift; done\nexec "$@"\n' > /usr/local/bin/sudo
    chmod +x /usr/local/bin/sudo
  fi
  # jq: needed by verify-third-party-licenses
  if ! command -v jq &>/dev/null; then
    curl -sL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o /tmp/jq 2>/dev/null && chmod +x /tmp/jq && export PATH="/tmp:$PATH"
  fi
fi

run_validation() {
  local name="$1"
  local logfile="$REBASE_TMP/${name}.log"
  shift

  local step_timeout="$VALIDATION_TIMEOUT"
  [[ "$name" == *-lint ]] && step_timeout="$LINT_TIMEOUT"

  echo ":: Running: $name (timeout: $step_timeout)"
  local rc=0
  timeout "$step_timeout" bash -c "$*" > "$logfile" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "  PASS"
    return 0
  elif [[ "$rc" -eq 124 ]]; then
    echo "  TIMEOUT after $step_timeout (see $logfile)"
    echo "" >> "$logfile"
    echo "TIMEOUT: command did not complete within $step_timeout" >> "$logfile"
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

  local build_errors lint_errors vet_errors test_failures
  build_errors=$(grep -E ":[0-9]+:[0-9]+: (undefined|too many arguments|too few arguments|cannot use|not enough arguments)" "$logfile" 2>/dev/null || true)
  lint_errors=$(grep -E "\.go:[0-9]+:[0-9]+:.*(SA[0-9]+|staticcheck|lostcancel|gci|inline:|nilness:)" "$logfile" 2>/dev/null | grep -v "^#" || true)
  vet_errors=$(grep -E ":[0-9]+:[0-9]+:.*(non-constant format string|format %|has arguments but no formatting directives|deprecated|call needs [0-9]+ args but has)" "$logfile" 2>/dev/null | grep -v "^#" || true)
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

  if [[ -n "$vet_errors" ]]; then
    echo "## VET ERRORS ($category)" >> "$SUMMARY"
    echo "$vet_errors" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    ERRORS_FOUND=1
  fi

  if [[ -n "$test_failures" ]]; then
    local priv_errors
    priv_errors=$(grep -cE "permission denied|operation not permitted" "$logfile" 2>/dev/null || true)
    if [[ "$priv_errors" -gt 0 ]]; then
      echo "## TEST FAILURES ($category) — ${priv_errors} privilege errors detected" >> "$SUMMARY"
      echo "$test_failures" >> "$SUMMARY"
      echo "Some failures may need CAP_NET_ADMIN. Compare with default branch to confirm pre-existing." >> "$SUMMARY"
    else
      echo "## TEST FAILURES ($category)" >> "$SUMMARY"
      echo "$test_failures" >> "$SUMMARY"
    fi
    echo "" >> "$SUMMARY"
    ERRORS_FOUND=1
  fi

  local timeout_errors
  timeout_errors=$(grep -E "^TIMEOUT:" "$logfile" 2>/dev/null || true)
  if [[ -n "$timeout_errors" ]]; then
    echo "## TIMEOUT ($category)" >> "$SUMMARY"
    echo "$timeout_errors" >> "$SUMMARY"
    echo "Possible causes: feature gate causing test hang, resource exhaustion, resource leak" >> "$SUMMARY"
    echo "If tests hang, check GATE_DEPS in k8s-rebase-autofix.sh — a new gate may need adding" >> "$SUMMARY"
    echo "" >> "$SUMMARY"
    ERRORS_FOUND=1
  fi

  if [[ "$step_failed" -eq 1 ]] && [[ -z "$build_errors" ]] && [[ -z "$lint_errors" ]] && [[ -z "$vet_errors" ]] && [[ -z "$test_failures" ]] && [[ -z "$timeout_errors" ]]; then
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
    lint_target=""
    grep -q "^lint:" "$REPO_ROOT/$mod_dir/Makefile" 2>/dev/null && lint_target="lint"
    [[ -z "$lint_target" ]] && grep -q "^golangci-lint:" "$REPO_ROOT/$mod_dir/Makefile" 2>/dev/null && lint_target="golangci-lint"
    if [[ "$MODE" != "quick" ]] && [[ -n "$lint_target" ]]; then
      if [[ "${K8S_REBASE_IN_CONTAINER:-}" == "1" ]]; then
        # Inside a container — make lint often needs nested containers
        # (e.g., hack/lint.sh runs golangci-lint in its own container).
        # Run golangci-lint directly instead.
        command -v golangci-lint &>/dev/null || go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest 2>/dev/null
        if command -v golangci-lint &>/dev/null; then
          vendor_flag=""
          [[ -d "$REPO_ROOT/$mod_dir/vendor" ]] && vendor_flag="--modules-download-mode=vendor"
          run_validation "${mod_name}-lint" "cd $mod_dir && golangci-lint run --verbose $vendor_flag --timeout=15m0s" || step_failed=1
        else
          echo "  WARNING: golangci-lint not available — skipping lint"
        fi
      else
        run_validation "${mod_name}-lint" "make -C $mod_dir $lint_target" || {
          if grep -qE "Go language version.*lower than the targeted|failed to install golangci-lint" "$REBASE_TMP/${mod_name}-lint.log" 2>/dev/null; then
            echo "  NOTE: lint version incompatible, installing latest via go install..."
            go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest 2>/dev/null
            if command -v golangci-lint &>/dev/null; then
              vendor_flag=""
              [[ -d "$REPO_ROOT/$mod_dir/vendor" ]] && vendor_flag="--modules-download-mode=vendor"
              run_validation "${mod_name}-lint" "cd $mod_dir && golangci-lint run --verbose $vendor_flag --timeout=15m0s" || step_failed=1
            else
              step_failed=1
            fi
          else
            step_failed=1
          fi
        }
      fi
      categorize_errors "$REBASE_TMP/${mod_name}-lint.log" "$mod_name lint" "$step_failed"
    fi

    step_failed=0
    test_target=""
    for _tt in test test-unit check; do
      grep -q "^${_tt}:" "$REPO_ROOT/$mod_dir/Makefile" 2>/dev/null && test_target="$_tt" && break
    done
    if [[ "$MODE" != "quick" ]] && [[ -n "$test_target" ]]; then
      # Try make test first; if it needs sudo (common for network namespace tests),
      # fall back to go test without -race for non-privileged packages.
      # Source feature gate env vars from test-go.sh so fake clientsets work.
      run_validation "${mod_name}-test" "make -C $mod_dir $test_target" || {
        if grep -q "sudo" "$REBASE_TMP/${mod_name}-test.log" 2>/dev/null; then
          echo "  NOTE: make test needs sudo/privileged container for some packages"
          GATE_EXPORTS=""
          TEST_GO_SH=$(find "$REPO_ROOT" -name "test-go.sh" -path "*/hack/*" -not -path "*/vendor/*" | head -1)
          if [[ -n "$TEST_GO_SH" ]]; then
            GATE_EXPORTS=$(grep "^export KUBE_FEATURE_" "$TEST_GO_SH" | tr '\n' '; ')
          fi
          # Find privileged packages from test-go.sh root_pkgs array
          ROOT_PKGS=""
          if [[ -n "$TEST_GO_SH" ]]; then
            ROOT_PKGS=$(sed -n '/root_pkgs=(/,/)/p' "$TEST_GO_SH" | grep -oE 'pkg/[^"]+' | sort -u | tr '\n' '|')
          fi
          # When vendor/ changed (k8s rebase), test ALL non-privileged
          # packages — vendored dep changes affect all consumers, not
          # just packages with source changes.
          MERGE_BASE=$(git -C "$REPO_ROOT" merge-base HEAD master 2>/dev/null || git -C "$REPO_ROOT" merge-base HEAD main 2>/dev/null || echo "HEAD~20")
          VENDOR_CHANGED=$(git -C "$REPO_ROOT" diff --name-only "$MERGE_BASE"..HEAD -- "${mod_dir}/vendor/" | head -1)
          TEST_PKGS=""
          if [[ -n "$VENDOR_CHANGED" ]]; then
            echo "  Vendor changed — testing all non-privileged packages..."
            while IFS= read -r pkg; do
              [[ -z "$pkg" ]] && continue
              if [[ -n "$ROOT_PKGS" ]] && echo "$pkg" | grep -qE "^(${ROOT_PKGS%|})"; then
                echo "  Skipping privileged: $pkg"
                continue
              fi
              TEST_PKGS+=" ./${pkg}/..."
            done < <(cd "$REPO_ROOT/$mod_dir" && find . -name "*_test.go" -not -path "*/vendor/*" -exec dirname {} \; | sed 's|^\./||' | sort -u)
          else
            echo "  Testing changed non-privileged packages only..."
            CHANGED_PKGS=$(git -C "$REPO_ROOT" diff --name-only "$MERGE_BASE"..HEAD -- "${mod_dir}/" | grep '\.go$' | grep -v vendor | grep -v "_test.go" | sed "s|${mod_dir}/||;s|/[^/]*$||" | sort -u)
            for pkg in $CHANGED_PKGS; do
              if [[ -n "$ROOT_PKGS" ]] && echo "$pkg" | grep -qE "^(${ROOT_PKGS%|})$"; then
                echo "  Skipping privileged: $pkg"
                continue
              fi
              if find "$REPO_ROOT/$mod_dir/$pkg" -name "*_test.go" -maxdepth 1 2>/dev/null | grep -q .; then
                TEST_PKGS+=" ./${pkg}/..."
              fi
            done
          fi
          if [[ -n "$TEST_PKGS" ]]; then
            echo "  Testing:$TEST_PKGS"
            run_validation "${mod_name}-test" "${GATE_EXPORTS} cd $mod_dir && go test -mod vendor -timeout ${VALIDATION_TIMEOUT} ${TEST_PKGS} -count=1" || step_failed=1
          else
            echo "  No non-privileged test packages found"
          fi
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

if [[ "$MODE" != "quick" ]]; then
# ── CI parity checks ────────────────────────────────────────────────
# Run the same checks CI runs beyond build/lint/vet/test.
# These are quick and catch issues the per-module checks miss.

echo ""
echo "━━━━ CI Parity Checks ━━━━"
echo ""

# Find the primary module (the one with a Makefile and these targets)
for gomod in $(find . -name "go.mod" -not -path "*/vendor/*" | sort); do
  ci_dir=$(dirname "$gomod" | sed 's|^\./||')
  [[ -f "$REPO_ROOT/$ci_dir/Makefile" ]] || continue

  if grep -q "^gofmt:" "$REPO_ROOT/$ci_dir/Makefile" 2>/dev/null; then
    step_failed=0
    run_validation "${ci_dir##*/}-gofmt" "make -C $ci_dir gofmt" || step_failed=1
    if [[ "$step_failed" -eq 1 ]]; then
      echo "## GOFMT ERRORS ($ci_dir)" >> "$SUMMARY"
      tail -10 "$REBASE_TMP/${ci_dir##*/}-gofmt.log" >> "$SUMMARY"
      echo "" >> "$SUMMARY"
      ERRORS_FOUND=1
    fi
  fi

  if grep -q "^verify-go-mod-vendor:" "$REPO_ROOT/$ci_dir/Makefile" 2>/dev/null; then
    step_failed=0
    run_validation "${ci_dir##*/}-vendor" "make -C $ci_dir verify-go-mod-vendor" || step_failed=1
    if [[ "$step_failed" -eq 1 ]]; then
      echo "## VENDOR VERIFICATION ERRORS ($ci_dir)" >> "$SUMMARY"
      tail -10 "$REBASE_TMP/${ci_dir##*/}-vendor.log" >> "$SUMMARY"
      echo "" >> "$SUMMARY"
      ERRORS_FOUND=1
    fi
  fi

  if grep -q "^windows:" "$REPO_ROOT/$ci_dir/Makefile" 2>/dev/null; then
    step_failed=0
    run_validation "${ci_dir##*/}-windows" "make -C $ci_dir windows" || step_failed=1
    if [[ "$step_failed" -eq 1 ]]; then
      echo "## WINDOWS BUILD ERRORS ($ci_dir)" >> "$SUMMARY"
      tail -10 "$REBASE_TMP/${ci_dir##*/}-windows.log" >> "$SUMMARY"
      echo "" >> "$SUMMARY"
      ERRORS_FOUND=1
    fi
  fi

  if grep -q "^verify-third-party-licenses:" "$REPO_ROOT/$ci_dir/Makefile" 2>/dev/null; then
    step_failed=0
    run_validation "${ci_dir##*/}-licenses" "make -C $ci_dir verify-third-party-licenses" || step_failed=1
    if [[ "$step_failed" -eq 1 ]]; then
      echo "## LICENSE VERIFICATION ERRORS ($ci_dir)" >> "$SUMMARY"
      tail -10 "$REBASE_TMP/${ci_dir##*/}-licenses.log" >> "$SUMMARY"
      echo "" >> "$SUMMARY"
      ERRORS_FOUND=1
    fi
  fi
done

fi # end MODE != quick

# ── Privileged tests (--full only) ──────────────────────────────────
if [[ "$MODE" == "full" ]]; then
  echo ""
  echo "━━━━ Privileged Tests ━━━━"
  echo ""

  for gomod in $(find . -name "go.mod" -not -path "*/vendor/*" | sort); do
    mod_dir=$(dirname "$gomod" | sed 's|^\./||')
    TEST_GO_SH=$(find "$REPO_ROOT/$mod_dir" -name "test-go.sh" -path "*/hack/*" -not -path "*/vendor/*" | head -1)
    [[ -n "$TEST_GO_SH" ]] || continue

    GATE_EXPORTS=$(grep "^export KUBE_FEATURE_" "$TEST_GO_SH" | tr '\n' '; ')
    PRIV_PKGS=$(sed -n '/root_pkgs=(/,/)/p' "$TEST_GO_SH" | grep -oE 'pkg/[^"]+' | sort -u)
    [[ -z "$PRIV_PKGS" ]] && continue

    # In --full mode, the container runs as root (no --userns=keep-id)
    if [[ "$(id -u)" != "0" ]]; then
      echo "  NOTE: Privileged tests need root — run with --full flag"
      echo "  (--full disables --userns=keep-id so the container runs as root)"
    else
      # We ARE root — run privileged tests directly
      if ! command -v sudo &>/dev/null; then
        printf '#!/bin/sh\nwhile [ "${1#-}" != "$1" ]; do shift; done\nexec "$@"\n' > /usr/local/bin/sudo
        chmod +x /usr/local/bin/sudo
      fi
      for pkg in $PRIV_PKGS; do
        # Skip packages whose directories no longer exist (stale root_pkgs entries)
        if [[ ! -d "$REPO_ROOT/$mod_dir/$pkg" ]]; then
          echo "  Skipping stale: $pkg (directory does not exist)"
          continue
        fi
        step_failed=0
        run_validation "priv-${pkg##*/}" "${GATE_EXPORTS} cd $mod_dir && go test -mod vendor -count=1 -timeout 5m ./$pkg/..." || step_failed=1
        if [[ "$step_failed" -eq 1 ]]; then
          echo "## PRIVILEGED TEST FAILURE ($pkg)" >> "$SUMMARY"
          tail -10 "$REBASE_TMP/priv-${pkg##*/}.log" >> "$SUMMARY"
          echo "" >> "$SUMMARY"
          ERRORS_FOUND=1
        fi
      done
    fi
  done
fi

echo ""
if [[ "$ERRORS_FOUND" -eq 0 ]]; then
  echo "All validation passes. No Phase 4 fixups needed."
  cleanup
  exit 0
else
  echo "Errors found. Summary: $SUMMARY"
  echo ""
  cat "$SUMMARY"
  exit 1
fi
