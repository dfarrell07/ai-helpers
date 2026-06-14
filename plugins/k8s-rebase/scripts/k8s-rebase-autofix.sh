#!/bin/bash
# k8s-rebase-autofix.sh — Apply known fix patterns after a k8s rebase
#
# Runs the verification block as a diagnostic, applies deterministic
# fixes for every non-zero check, then re-verifies. Outputs PASS/FAIL.
#
# Exit codes: 0 = all checks pass (RESULT: PASS)
#             1 = some checks remain (RESULT: FAIL with details)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: Not in a git repository" >&2; exit 1; }
cd "$REPO_ROOT"
grep -qF '.rebase-tmp' "$REPO_ROOT/.git/info/exclude" 2>/dev/null || echo '.rebase-tmp/' >> "$REPO_ROOT/.git/info/exclude"
grep -qF '.gitconfig' "$REPO_ROOT/.git/info/exclude" 2>/dev/null || echo '.gitconfig' >> "$REPO_ROOT/.git/info/exclude"

# Find primary go.mod with k8s.io deps
PRIMARY_GOMOD=""
for gm in go-controller/go.mod go.mod; do
  [[ -f "$gm" ]] && grep -q "k8s.io/" "$gm" && PRIMARY_GOMOD="$gm" && break
done
[[ -z "$PRIMARY_GOMOD" ]] && PRIMARY_GOMOD=$(find . -name "go.mod" -not -path "*/vendor/*" -exec grep -l "k8s.io/" {} \; | head -1)
MODULE_ROOT="."
[[ -n "$PRIMARY_GOMOD" ]] && MODULE_ROOT=$(dirname "$PRIMARY_GOMOD")

# Auto-containerize if local Go is too old for the repo's go.mod
REQUIRED_GO=""
[[ -n "$PRIMARY_GOMOD" ]] && REQUIRED_GO=$(grep "^go " "$PRIMARY_GOMOD" | awk '{print $2}')
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
      echo ":: Go $CURRENT_GO < $REQUIRED_GO — re-running autofix inside $GO_IMAGE"
      SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
      USERNS_FLAG=""
      [[ "$CONTAINER_RT" == "podman" ]] && USERNS_FLAG="--userns=keep-id"
      exec $CONTAINER_RT run --rm \
        --security-opt label=disable \
        $USERNS_FLAG \
        -v "$REPO_ROOT:$REPO_ROOT" \
        -v "$(dirname "$SCRIPT_PATH"):$(dirname "$SCRIPT_PATH"):ro" \
        -w "$REPO_ROOT" \
        -e GIT_AUTHOR_NAME="$(git config user.name)" \
        -e GIT_AUTHOR_EMAIL="$(git config user.email)" \
        -e GIT_COMMITTER_NAME="$(git config user.name)" \
        -e GIT_COMMITTER_EMAIL="$(git config user.email)" \
        -e K8S_REBASE_IN_CONTAINER=1 \
        "$GO_IMAGE" \
        bash "$SCRIPT_PATH"
    else
      echo ":: WARNING: Go $CURRENT_GO < $REQUIRED_GO and no container runtime — go vet/goimports will be skipped"
    fi
  fi
fi

# Container setup: git safe.directory for mounted volumes.
# Use env vars instead of git config --global which writes a .gitconfig
# file that could end up committed to the repo.
if [[ "${K8S_REBASE_IN_CONTAINER:-}" == "1" ]]; then
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=safe.directory
  export GIT_CONFIG_VALUE_0="$REPO_ROOT"
  # Install jq if missing (needed by verify-third-party-licenses)
  if ! command -v jq &>/dev/null; then
    curl -sL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o /tmp/jq 2>/dev/null && chmod +x /tmp/jq && export PATH="/tmp:$PATH"
  fi
fi

# ── Problematic feature gates (extend for future releases) ────────
# Complete registry of gates that break fake clientsets in tests.
# Each entry: parent gate → space-separated dependents (empty if none).
# Gates are only applied if they exist in the vendored k8s.io code.
# Adding a gate for k8s 1.37+: one line here, everything else automatic.
declare -A GATE_DEPS
GATE_DEPS[WatchListClient]=""
GATE_DEPS[AtomicFIFO]="StaleControllerConsistencyJob StaleControllerConsistencyReplicaSet StaleControllerConsistencyStatefulSet StaleControllerConsistencyDaemonSet"
# k8s 1.37+: add new entries like:
# GATE_DEPS[NewGate]="Dep1 Dep2 Dep3"

# ── Verification block ─────────────────────────────────────────────
# Single source of truth — used for both diagnostic and final check.
# Generic checks work for any k8s rebase. Version-specific checks
# return 0 when their target files don't exist (safe for future bumps).

run_checks() {
  local F=0
  r() { echo "$1: $2"; [ "$2" != "0" ] && F=$((F+1)); }
  # Only check conformance renames if conformance module uses v0.2.0+
  local _conf_npa_minor=0
  local _conf_gomod=$(find . -name "go.mod" -path "*/conformance/*" -not -path "*/vendor/*" | head -1)
  [[ -n "$_conf_gomod" ]] && _conf_npa_minor=$(grep "network-policy-api " "$_conf_gomod" 2>/dev/null | awk '{print $2}' | cut -d. -f2)
  if (( _conf_npa_minor >= 2 )) 2>/dev/null; then
    r "Conformance old names" "$(grep -w 'SupportAdminNetworkPolicy' test/conformance/network_policy_v2_test.go 2>/dev/null | wc -l)"
  else
    r "Conformance old names" "0"
  fi
  r "AddToScheme in factory" "$(grep 'anpapi.AddToScheme' go-controller/pkg/factory/factory.go 2>/dev/null | wc -l)"
  # Only check conformance AddToScheme if conformance module uses v0.2.0+
  if (( _conf_npa_minor >= 2 )) 2>/dev/null; then
    r "AddToScheme in conformance" "$(grep 'AddToScheme' test/conformance/network_policy_v2_test.go 2>/dev/null | wc -l)"
  else
    r "AddToScheme in conformance" "0"
  fi
  # Only flag shared EgressPeer in BANP test if the split type exists in vendor
  if grep -rq "BaselineAdminNetworkPolicyEgressPeer" "$MODULE_ROOT/vendor/sigs.k8s.io/network-policy-api/" 2>/dev/null; then
    r "BANP wrong EgressPeer" "$(grep 'AdminNetworkPolicyEgressPeer' go-controller/pkg/ovn/baseline_admin_network_policy_test.go 2>/dev/null | grep -vc Baseline)"
  else
    r "BANP wrong EgressPeer" "0"
  fi
  # Gate checks — driven by GATE_DEPS map. Only checks gates that
  # exist in the vendored k8s code (safe across k8s versions).
  local _active_gates="" _all_gate_names=""
  for _p in "${!GATE_DEPS[@]}"; do
    if grep -rq "\"$_p\"" $MODULE_ROOT/vendor/k8s.io/ 2>/dev/null; then
      _active_gates="$_active_gates $_p"
      _all_gate_names="$_all_gate_names $_p"
      for _d in ${GATE_DEPS[$_p]}; do
        grep -rq "\"$_d\"" $MODULE_ROOT/vendor/k8s.io/ 2>/dev/null && _all_gate_names="$_all_gate_names $_d"
      done
    fi
  done
  local _gmiss=0
  local _test_go_sh
  _test_go_sh=$(find . -name "test-go.sh" -path "*/hack/*" -not -path "*/vendor/*" 2>/dev/null | head -1)
  if [[ -n "$_test_go_sh" ]]; then
    for _g in $_all_gate_names; do
      grep -q "KUBE_FEATURE_$_g\|\"$_g\"" "$_test_go_sh" 2>/dev/null || _gmiss=$((_gmiss+1))
    done
  fi
  r "Gates in test-go.sh" "$_gmiss"
  # Env var files: check ALL gates (parents + deps).
  # Match on os.Setenv/t.Setenv calls, not just KUBE_FEATURE_ (avoids comments).
  local _genv=0
  for _f in $(grep -rl 'os\.Setenv.*KUBE_FEATURE\|t\.Setenv.*KUBE_FEATURE' --include='*_test.go' --include='*_suite_test.go' $MODULE_ROOT/ 2>/dev/null | grep -v vendor); do
    for _g in $_all_gate_names; do
      grep -q "$_g" "$_f" || _genv=$((_genv+1))
    done
  done
  r "Gates in env var files" "$_genv"
  # SetFromMap files: check ALL gates (parents + deps) that exist in vendor.
  # SetFromMap validates parent-dep consistency and rejects unrecognized gates.
  local _sfm_gates="$_active_gates"
  for _p in "${!GATE_DEPS[@]}"; do
    grep -rq "\"$_p\"" $MODULE_ROOT/vendor/k8s.io/ 2>/dev/null || continue
    for _d in ${GATE_DEPS[$_p]}; do
      grep -rq "\"$_d\"" $MODULE_ROOT/vendor/k8s.io/ 2>/dev/null && _sfm_gates="$_sfm_gates $_d"
    done
  done
  local _gsfm=0
  for _f in $(grep -rl 'SetFromMap' --include='*_test.go' --include='*_suite_test.go' $MODULE_ROOT/ 2>/dev/null | grep -v vendor); do
    for _g in $_sfm_gates; do
      grep -q "\"$_g\"" "$_f" || _gsfm=$((_gsfm+1))
    done
  done
  r "Gates in SetFromMap files" "$_gsfm"
  r "ObsGen missing" "$(grep -L 'WithObservedGeneration\|ObservedGeneration' go-controller/pkg/ovn/controller/admin_network_policy/status.go 2>/dev/null | wc -l)"
  r "x/exp imports" "$(grep -rn 'golang.org/x/exp' --include='*.go' . | grep -v vendor | wc -l)"
  r "reflect.Ptr" "$(grep -rn 'reflect\.Ptr\b' --include='*.go' . | grep -v vendor | wc -l)"
  r "FieldsV1.Raw" "$(grep -rn 'FieldsV1\.Raw\b' --include='*.go' . | grep -v vendor | wc -l)"
  r "Bare Eventf" "$(grep -rn 'Eventf(.*\.Error())' --include='*.go' . | grep -v vendor | grep -v '%s\|%v' | wc -l)"
  local NEW OLD
  NEW=$(grep 'k8s.io/api ' "$PRIMARY_GOMOD" 2>/dev/null | grep -oE 'v0\.[0-9]+' | sed 's/v0\.//')
  if [[ -n "$NEW" ]]; then
    OLD=$((NEW-1))
    r "Stale docs ver" "$(grep "| *1\.${OLD} *|" docs/features/requirements.md 2>/dev/null | wc -l)"
  else
    r "Stale docs ver" "0"
  fi
  r "Uncommitted" "$(git status --short | grep -v '^[?]' | wc -l)"
  echo "---"
  [ "$F" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL ($F checks non-zero)"
  return "$F"
}

# ── Fix functions ──────────────────────────────────────────────────
# Generic fixes (apply to any k8s rebase)

fix_xexp() {
  local files
  files=$(grep -rln 'golang.org/x/exp/' --include='*.go' . | grep -v vendor)
  [[ -z "$files" ]] && return 0
  echo ":: Fixing x/exp imports in $(echo "$files" | wc -l) files"
  for f in $files; do
    # Delete unnamed import lines — goimports will re-add the stdlib
    # equivalents (maps, slices, cmp) in the correct import section.
    # In-place replacement leaves them in the third-party section.
    # Aliased imports (rare) fall back to in-place replacement.
    sed -i '/^[[:space:]]*"golang\.org\/x\/exp\/maps"/d' "$f"
    sed -i '/^[[:space:]]*"golang\.org\/x\/exp\/slices"/d' "$f"
    sed -i '/^[[:space:]]*"golang\.org\/x\/exp\/constraints"/d' "$f"
    sed -i 's|"golang.org/x/exp/maps"|"maps"|g' "$f"
    sed -i 's|"golang.org/x/exp/slices"|"slices"|g' "$f"
    sed -i 's|"golang.org/x/exp/constraints"|"cmp"|g' "$f"
    # Replace API usage
    sed -i 's/constraints\.Ordered/cmp.Ordered/g' "$f"
    # maps.Keys/Values now return iterators — wrap with slices.Collect
    # Only wrap if not already wrapped
    sed -i '/slices\.Collect/!s/\bmaps\.Keys(\([^)]*\))/slices.Collect(maps.Keys(\1))/g' "$f"
    sed -i '/slices\.Collect/!s/\bmaps\.Values(\([^)]*\))/slices.Collect(maps.Values(\1))/g' "$f"
    # maps.Clear → builtin clear
    sed -i 's/\bmaps\.Clear(\([^)]*\))/clear(\1)/g' "$f"
    # Missing imports (maps, slices, cmp) and placement handled by goimports below
  done
  # Remove x/exp from go.mod/vendor — needs Go toolchain
  for gomod_dir in $(find . -name "go.mod" -not -path "*/vendor/*" -exec grep -l 'golang.org/x/exp' {} \; | xargs -I{} dirname {}); do
    echo ":: Running go mod tidy in $gomod_dir"
    (cd "$gomod_dir" && go mod tidy 2>/dev/null && [[ -d vendor ]] && go mod vendor 2>/dev/null) || true
  done
}

fix_reflect_ptr() {
  local files
  files=$(grep -rln 'reflect\.Ptr\b' --include='*.go' . | grep -v vendor)
  [[ -z "$files" ]] && return 0
  echo ":: Fixing reflect.Ptr → reflect.Pointer in $(echo "$files" | wc -l) files"
  for f in $files; do
    sed -i 's/reflect\.Ptr\b/reflect.Pointer/g' "$f"
  done
}

fix_fieldsv1() {
  local files
  files=$(grep -rln 'FieldsV1\.Raw\b' --include='*.go' . | grep -v vendor)
  [[ -z "$files" ]] && return 0
  echo ":: Fixing FieldsV1.Raw → FieldsV1.GetRawBytes() in $(echo "$files" | wc -l) files"
  for f in $files; do
    sed -i 's/\.FieldsV1\.Raw\b/.FieldsV1.GetRawBytes()/g' "$f"
  done
}

fix_eventf() {
  local files
  files=$(grep -rln 'Eventf(.*\.Error())' --include='*.go' . | grep -v vendor | while read f; do
    grep 'Eventf(.*\.Error())' "$f" | grep -qv '%s\|%v' && echo "$f"
  done)
  [[ -z "$files" ]] && return 0
  echo ":: Fixing bare Eventf format strings"
  for f in $files; do
    # Only fix simple case: .Error() is the format string (3 commas before it).
    # Complex case (4+ commas = extra args before .Error()) needs agent judgment.
    while IFS= read -r match; do
      local lineno content commas
      lineno=$(echo "$match" | cut -d: -f1)
      content=$(echo "$match" | cut -d: -f2-)
      commas=$(echo "$content" | sed 's/\.Error().*//' | tr -cd ',' | wc -c)
      if [[ "$commas" -le 3 ]]; then
        sed -i "${lineno}s/,\( *\)\([a-zA-Z_][a-zA-Z_0-9.]*\.Error()\))/,\1\"%s\", \2)/" "$f"
      else
        echo ":: WARNING: Complex Eventf at $f:$lineno (needs manual fix — extra args before .Error())"
      fi
    done < <(grep -n 'Eventf(.*\.Error())' "$f" | grep -v '%s\|%v')
  done
}

fix_docs_version() {
  local NEW OLD
  NEW=$(grep 'k8s.io/api ' "$PRIMARY_GOMOD" 2>/dev/null | grep -oE 'v0\.[0-9]+' | sed 's/v0\.//')
  [[ -z "$NEW" ]] && return 0
  OLD=$((NEW-1))
  local file="docs/features/requirements.md"
  [[ -f "$file" ]] || return 0
  if grep -q "| *1\.${OLD} *|" "$file"; then
    echo ":: Fixing stale docs version 1.${OLD} → 1.${NEW}"
    sed -i "s/| *1\.${OLD} *|/| 1.${NEW} |/g" "$file"
  fi
}

fix_version_refs() {
  # Update stale K8S version references in CI, scripts, and docs.
  # Defense-in-depth for Phase 3 which may fail in some container setups.
  local NEW OLD
  NEW=$(grep 'k8s.io/api ' "$PRIMARY_GOMOD" 2>/dev/null | grep -oE 'v0\.[0-9]+' | sed 's/v0\.//')
  [[ -z "$NEW" ]] && return 0
  OLD=$((NEW-1))
  local changed=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    sed -i -E "s|v1\.${OLD}\.[0-9]+|v1.${NEW}.0|g; s|v1\.${OLD}\b|v1.${NEW}|g" "$f"
    changed=1
  done < <(grep -rln -E "v1\.${OLD}(\.[0-9]+)?\b" \
    --include="*.yml" --include="*.yaml" --include="*.sh" \
    --include="*.md" --include="Makefile*" --include="Dockerfile*" . \
    | grep -v vendor | grep -v '/\.git/' | grep -v go.mod || true)
  [[ "$changed" -eq 1 ]] && echo ":: Fixed stale v1.${OLD} version references → v1.${NEW}"
}

fix_go_version() {
  # Update Go version references in CI, Makefiles, and Dockerfiles.
  # Defense-in-depth for Phase 3's Go version block which may not commit.
  local new_go old_go
  new_go=$(grep "^go " "$PRIMARY_GOMOD" 2>/dev/null | awk '{print $2}' | grep -oE '[0-9]+\.[0-9]+')
  [[ -z "$new_go" ]] && return 0
  # Detect old Go version from CI files (the version BEFORE the rebase)
  old_go=$(grep -oE 'golang[:-][0-9]+\.[0-9]+' .github/workflows/docker.yml 2>/dev/null | head -1 | sed 's/golang[:-]//')
  [[ -z "$old_go" ]] && old_go=$(grep -roE 'GO_VERSION \?= [0-9]+\.[0-9]+' --include="Makefile*" . 2>/dev/null | head -1 | sed 's/.*GO_VERSION ?= //')
  [[ -z "$old_go" ]] && old_go=$(grep -roE 'GO_VERSION: "[0-9]+\.[0-9]+"' --include="*.yml" --include="*.yaml" . 2>/dev/null | grep -v vendor | head -1 | sed 's/.*GO_VERSION: "//;s/"//')
  [[ -z "$old_go" ]] && return 0
  [[ "$old_go" == "$new_go" ]] && return 0
  echo ":: Fixing Go version refs: $old_go → $new_go"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    sed -i "s|golang:${old_go}|golang:${new_go}|g; s|golang-${old_go}|golang-${new_go}|g; s|GO_VERSION ?= ${old_go}|GO_VERSION ?= ${new_go}|g; s|GOLANG_VERSION ?= ${old_go}|GOLANG_VERSION ?= ${new_go}|g; s|go-version: \[${old_go}|go-version: [${new_go}|g; s|go-version: ${old_go}|go-version: ${new_go}|g; s|GO_VERSION: \"${old_go}\"|GO_VERSION: \"${new_go}\"|g" "$f"
  done < <(grep -rlnE "golang[:-]${old_go}|GO_VERSION.{0,5}${old_go}|GOLANG_VERSION.{0,5}${old_go}|go-version:.{0,3}${old_go}" \
    --include="*.yml" --include="*.yaml" --include="Makefile*" --include="Dockerfile*" . \
    | grep -v vendor | grep -v '/\.git/' | grep -v go.mod || true)
}

fix_lint_version() {
  local lint_sh
  lint_sh=$(find . -name "lint.sh" -path "*/hack/*" -not -path "*/vendor/*" | head -1)
  [[ -z "$lint_sh" ]] && return 0
  local lint_ver test_yml
  lint_ver=$(grep -oE 'VERSION=v[0-9.]+' "$lint_sh" | head -1 | sed 's/VERSION=//')

  # Bump lint version if the current one can't parse the target Go version.
  # golangci-lint binaries are built with a specific Go version and can't
  # parse code targeting a newer Go. Fetch latest to get one built with
  # a recent enough Go.
  local required_go
  required_go=$(grep "^go " "$PRIMARY_GOMOD" 2>/dev/null | awk '{print $2}' | cut -d. -f2)
  if [[ -n "$lint_ver" ]] && [[ -n "$required_go" ]] && [[ "$required_go" -ge 26 ]] 2>/dev/null; then
    # v2.5.0 was built with Go 1.25, v2.12+ with Go 1.26
    local lint_minor
    lint_minor=$(echo "$lint_ver" | sed 's/v[0-9]*\.//' | cut -d. -f1)
    if [[ "$lint_ver" == v2.* ]] && (( lint_minor < 12 )) 2>/dev/null; then
      local LATEST_LINT
      LATEST_LINT=$(curl -sf "https://api.github.com/repos/golangci/golangci-lint/releases/latest" 2>/dev/null | grep -oE '"tag_name": "v[^"]+"' | sed 's/"tag_name": "//;s/"//' || true)
      if [[ -n "$LATEST_LINT" ]]; then
        echo ":: Bumping golangci-lint: $lint_ver → $LATEST_LINT (Go 1.${required_go} requires newer build)"
        sed -i "s/VERSION=${lint_ver}/VERSION=${LATEST_LINT}/" "$lint_sh"
        lint_ver="$LATEST_LINT"
      else
        echo ":: WARNING: golangci-lint $lint_ver may not support Go 1.${required_go} — could not fetch latest version"
      fi
    fi
  fi

  test_yml=$(find . -name "test.yml" -path "*/.github/workflows/*" | head -1)
  if [[ -n "$test_yml" ]]; then
    local test_ver
    test_ver=$(grep -oE 'version: v[0-9.]+' "$test_yml" | head -1 | sed 's/version: //')
    if [[ -n "$lint_ver" ]] && [[ -n "$test_ver" ]] && [[ "$lint_ver" != "$test_ver" ]]; then
      echo ":: Syncing lint version: test.yml $test_ver → $lint_ver"
      sed -i "s/version: ${test_ver}/version: ${lint_ver}/g" "$test_yml"
    fi
  fi
  # Fix golangci-lint v1 + newer Go incompatibility.
  # v1 is EOL — the last release was built with Go 1.24 which
  # can't parse Go 1.26+ syntax. The container image fails, but
  # go install builds from source with the local Go and works.
  # Replace the Makefile's no-op else branch with go install.
  if [[ -n "$lint_ver" ]] && [[ "$lint_ver" == v1.* ]]; then
    local required_go
    required_go=$(grep "^go " "$PRIMARY_GOMOD" 2>/dev/null | awk '{print $2}' | cut -d. -f2)
    if [[ -n "$required_go" ]] && [[ "$required_go" -ge 26 ]] 2>/dev/null; then
      if grep -q "can only be run within a container" "$REPO_ROOT/Makefile" 2>/dev/null; then
        echo ":: Fixing Makefile lint fallback for Go 1.${required_go} compatibility"
        if grep -q "GOLANGCI_LINT_VERSION" "$REPO_ROOT/Makefile" 2>/dev/null; then
          sed -i 's|echo "linter can only be run within a container.*|go install github.com/golangci/golangci-lint/cmd/golangci-lint@$$(GOLANGCI_LINT_VERSION) 2>/dev/null \&\& golangci-lint run --verbose --timeout=15m0s|g' "$REPO_ROOT/Makefile"
        else
          sed -i "s|echo \"linter can only be run within a container.*|go install github.com/golangci/golangci-lint/cmd/golangci-lint@${lint_ver} 2>/dev/null \&\& golangci-lint run --verbose --timeout=15m0s|g" "$REPO_ROOT/Makefile"
        fi
      else
        echo ":: WARNING: lint.sh uses golangci-lint $lint_ver (built with Go <1.26)."
        echo "   The container image can't parse Go 1.${required_go} code."
      fi
    fi
  fi
}

fix_kind_image() {
  local NEW
  NEW=$(grep 'k8s.io/api ' "$PRIMARY_GOMOD" 2>/dev/null | grep -oE 'v0\.[0-9]+' | sed 's/v0\.//')
  [[ -z "$NEW" ]] && return 0
  # Check if KIND image exists — try patch versions from highest to .0
  local kind_tag=""
  for patch in 9 8 7 6 5 4 3 2 1 0; do
    local candidate="v1.${NEW}.${patch}"
    local exists=1
    if command -v docker &>/dev/null; then
      docker manifest inspect "kindest/node:${candidate}" &>/dev/null && exists=0
    fi
    if [[ "$exists" -eq 1 ]]; then
      curl -sf "https://hub.docker.com/v2/repositories/kindest/node/tags/${candidate}" > /dev/null 2>&1 && exists=0
    fi
    if [[ "$exists" -eq 0 ]]; then
      kind_tag="$candidate"
      break
    fi
  done
  if [[ -z "$kind_tag" ]]; then
    local OLD=$((NEW-1))
    local new_tag="v1.${NEW}.0"
    local revert_tag="v1.${OLD}.1"
    echo ":: kindest/node:v1.${NEW}.* not available — reverting K8S_VERSION to ${revert_tag}"
    # Revert K8S_VERSION in CI and scripts (but not docs)
    for f in $(grep -rln "K8S_VERSION.*${new_tag}\|kindest/node:${new_tag}" \
      --include="*.yml" --include="*.yaml" --include="*.sh" --include="Makefile*" . \
      | grep -v vendor | grep -v docs/); do
      sed -i "s|${new_tag}|${revert_tag}|g" "$f"
    done
    # Also fix contrib/ scripts
    for f in $(grep -rln "${new_tag}" contrib/ --include="*.sh" --include="*.yaml" 2>/dev/null); do
      sed -i "s|${new_tag}|${revert_tag}|g" "$f"
    done
  else
    # Update K8S_VERSION to the found patch version if different from .0
    local base_tag="v1.${NEW}.0"
    if [[ "$kind_tag" != "$base_tag" ]]; then
      echo ":: Updating K8S_VERSION from ${base_tag} to ${kind_tag}"
      for f in $(grep -rln "${base_tag}" \
        --include="*.yml" --include="*.yaml" --include="*.sh" --include="Makefile*" . \
        | grep -v vendor | grep -v docs/ | grep -v go.mod); do
        sed -i "s|${base_tag}|${kind_tag}|g" "$f"
      done
    else
      echo ":: Using kindest/node:${kind_tag}"
    fi
  fi
}

fix_kind_version() {
  # Bump the KIND binary to the latest release. Newer KIND versions
  # are needed to create clusters with newer kindest/node images.
  local install_script
  install_script=$(find . -name "install-kind.sh" -not -path "*/vendor/*" | head -1)
  [[ -z "$install_script" ]] && return 0
  local current_ver
  current_ver=$(grep -oE 'kind.sigs.k8s.io/dl/v[0-9.]+' "$install_script" | head -1 | sed 's|kind.sigs.k8s.io/dl/||')
  [[ -z "$current_ver" ]] && return 0
  local latest_ver
  latest_ver=$(curl -sf "https://api.github.com/repos/kubernetes-sigs/kind/releases/latest" 2>/dev/null | grep -oE '"tag_name": "[^"]+"' | sed 's/"tag_name": "//;s/"//' || true)
  [[ -z "$latest_ver" ]] && return 0
  if [[ "$current_ver" != "$latest_ver" ]]; then
    echo ":: Bumping KIND binary: $current_ver → $latest_ver"
    sed -i "s|kind.sigs.k8s.io/dl/${current_ver}|kind.sigs.k8s.io/dl/${latest_ver}|g" "$install_script"
  fi
}

fix_metallb_version() {
  local kind_common
  kind_common=$(find . -name "kind-common.sh" -not -path "*/vendor/*" | head -1)
  [[ -z "$kind_common" ]] && return 0
  local current_metallb
  current_metallb=$(grep -oE 'metallb_version=v[0-9.]+' "$kind_common" | head -1 | sed 's/metallb_version=//')
  [[ -z "$current_metallb" ]] && return 0

  local latest_metallb
  latest_metallb=$(curl -sf "https://api.github.com/repos/metallb/metallb/releases" 2>/dev/null | grep -oE '"tag_name": "v[0-9][^"]+"' | head -1 | sed 's/"tag_name": "//;s/"//' || true)
  [[ -z "$latest_metallb" ]] && { echo ":: WARNING: Could not fetch latest MetalLB version"; return 0; }

  if [[ "$current_metallb" != "$latest_metallb" ]]; then
    echo ":: Bumping MetalLB: $current_metallb → $latest_metallb"
    sed -i "s|metallb_version=${current_metallb}|metallb_version=${latest_metallb}|" "$kind_common"

    # MetalLB versions ship different FRR images. Add a separate variable
    # so install_metallb replaces the correct source tag.
    local metallb_frr_tag
    metallb_frr_tag=$(curl -sf "https://raw.githubusercontent.com/metallb/metallb/${latest_metallb}/charts/metallb/values.yaml" 2>/dev/null | awk '/repository.*frrouting\/frr/{getline; if(/tag:/) {gsub(/.*tag: */,""); print; exit}}' || true)
    if [[ -n "$metallb_frr_tag" ]]; then
      local metallb_frr_image="quay.io/frrouting/frr:${metallb_frr_tag}"
      if ! grep -q "METALLB_UPSTREAM_FRR_IMAGE" "$kind_common"; then
        sed -i "/^readonly FRR_K8S_UPSTREAM_FRR_IMAGE=/a readonly METALLB_UPSTREAM_FRR_IMAGE=${metallb_frr_image}" "$kind_common"
        echo ":: Added METALLB_UPSTREAM_FRR_IMAGE=${metallb_frr_image}"
      fi
      # Update replace_in_file_or_exit calls inside install_metallb() to use the new var
      # Handles both ${VAR} and ${VAR##*:} patterns
      sed -i '/^install_metallb()/,/^}/s/FRR_K8S_UPSTREAM_FRR_IMAGE/METALLB_UPSTREAM_FRR_IMAGE/g' "$kind_common"
      if sed -n '/^install_metallb()/,/^}/p' "$kind_common" | grep -q 'FRR_K8S_UPSTREAM_FRR_IMAGE'; then
        echo ":: WARNING: install_metallb still references FRR_K8S_UPSTREAM_FRR_IMAGE — manual update needed"
      else
        echo ":: Updated install_metallb to use METALLB_UPSTREAM_FRR_IMAGE"
      fi
    else
      echo ":: WARNING: Could not detect FRR image for MetalLB $latest_metallb"
      echo "   Verify FRR image tags in install_metallb manually."
    fi
  fi
}

fix_kubevirt_version() {
  local kind_common
  kind_common=$(find . -name "kind-common.sh" -not -path "*/vendor/*" | head -1)
  [[ -z "$kind_common" ]] && return 0
  if grep -q 'KUBEVIRT_VERSION:-"v[0-9]' "$kind_common"; then
    local current
    current=$(grep -oE 'KUBEVIRT_VERSION:-"v[^"]+' "$kind_common" | head -1 | sed 's/.*:-"//' || true)
    sed -i '/^[[:space:]]*#/!s/KUBEVIRT_VERSION=${KUBEVIRT_VERSION:-"v[^"]*"}/KUBEVIRT_VERSION=${KUBEVIRT_VERSION:-"nightly"}/' "$kind_common"
    echo ":: Changed KubeVirt ${current} → nightly (pinned stable may not support this k8s version)"
  fi
}

fix_relaxed_service_name_validation() {
  local e2e_kind
  e2e_kind=$(find . -name "e2e-kind.sh" -path "*/test/scripts/*" | head -1)
  [[ -z "$e2e_kind" ]] && return 0
  grep -q "relaxedServiceNameValidationActive" "$e2e_kind" && return 0

  echo ":: Adding RelaxedServiceNameValidation probe and conditional skip to $(basename "$e2e_kind")"

  # Insert probe function after groomTestList's closing brace
  local insert_after
  insert_after=$(awk '/^groomTestList\(\)/,/^}/ { line=NR } END { print line }' "$e2e_kind")
  [[ -z "$insert_after" || "$insert_after" == "0" ]] && return 0

  local probe_func
  probe_func=$(cat <<'PROBE'

relaxedServiceNameValidationActive() {
  local kubeconfig="${KUBECONFIG:-${HOME}/ovn.conf}"
  local probe_service="1ovn-relaxed-svc-probe"
  kubectl --kubeconfig="${kubeconfig}" -n default delete service "${probe_service}" --ignore-not-found=true >/dev/null 2>&1 || true
  if kubectl --kubeconfig="${kubeconfig}" -n default create service clusterip "${probe_service}" --tcp=80:80 >/dev/null 2>&1; then
    kubectl --kubeconfig="${kubeconfig}" -n default delete service "${probe_service}" --ignore-not-found=true >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}
PROBE
)
  # Use awk to insert after the target line (avoids sed escaping issues)
  awk -v n="$insert_after" -v newfn="$probe_func" 'NR==n { print; print newfn; next } 1' "$e2e_kind" > "${e2e_kind}.tmp" && chmod --reference="$e2e_kind" "${e2e_kind}.tmp" && mv "${e2e_kind}.tmp" "$e2e_kind"

  # Insert skip block before the final groomTestList call
  local groom_line
  groom_line=$(grep -n 'SKIPPED_TESTS=.*groomTestList' "$e2e_kind" | tail -1 | cut -d: -f1)
  [[ -z "$groom_line" ]] && return 0

  local skip_block
  skip_block=$(cat <<'SKIP'
RELAXED_SERVICE_NAME_VALIDATION_DNS_TEST="
\[sig-network\].*DNS.*should work with a service name that starts with a digit.*\[FeatureGate:RelaxedServiceNameValidation\] \[Beta\]
"

if relaxedServiceNameValidationActive; then
	echo "RelaxedServiceNameValidation is active"
else
	echo "RelaxedServiceNameValidation not active; skipping digit-prefixed Service DNS test"
	SKIPPED_TESTS=$SKIPPED_TESTS$RELAXED_SERVICE_NAME_VALIDATION_DNS_TEST
fi

SKIP
)
  export SKIP_BLOCK_TEXT="$skip_block"
  awk -v n="$groom_line" 'NR==n { print ENVIRON["SKIP_BLOCK_TEXT"] } 1' "$e2e_kind" > "${e2e_kind}.tmp" && chmod --reference="$e2e_kind" "${e2e_kind}.tmp" && mv "${e2e_kind}.tmp" "$e2e_kind"
  unset SKIP_BLOCK_TEXT

  # Best-effort: add featureGates to kind.yaml.j2
  local kind_yaml
  kind_yaml=$(find . -name "kind.yaml.j2" -path "*/contrib/*" | head -1)
  if [[ -n "$kind_yaml" ]] && ! grep -q "RelaxedServiceNameValidation" "$kind_yaml"; then
    awk '/^networking:/ { print "featureGates:"; print "  RelaxedServiceNameValidation: true"; print "" } 1' "$kind_yaml" > "${kind_yaml}.tmp" && chmod --reference="$kind_yaml" "${kind_yaml}.tmp" && mv "${kind_yaml}.tmp" "$kind_yaml"
    echo ":: Added RelaxedServiceNameValidation to kind.yaml.j2 (best-effort)"
  fi
}

fix_crd_int64_validation() {
  # k8s 1.36 rejects CRD integer fields where Maximum > int32 max
  # but format is int32 (the default for uint32 Go types).
  # Add +kubebuilder:validation:Format=int64 marker and regenerate.
  local files fixed=0
  files=$(find . -name "*types*.go" -path "*/crd/*" -not -path "*/vendor/*" 2>/dev/null)
  [[ -z "$files" ]] && return 0
  for f in $files; do
    if grep -q "Maximum.*4294967295" "$f" && ! grep -q "Format.*int64\|Format=int64" "$f"; then
      echo ":: Fixing CRD int64 validation in $f"
      # Insert +kubebuilder:validation:Format=int64 after each Maximum marker
      sed -i '/Maximum.*4294967295/a\\t// +kubebuilder:validation:Format=int64' "$f"
      fixed=1
    fi
  done
  if [[ "$fixed" -eq 1 ]]; then
    # Regenerate CRDs. Use make codegen if available (pins controller-gen
    # version, handles helm copy). Fall back to controller-gen directly.
    echo ":: Regenerating CRDs after adding Format=int64 markers"
    local regen_ok=false
    if [[ -f "$MODULE_ROOT/Makefile" ]] && grep -q "^codegen:" "$MODULE_ROOT/Makefile"; then
      echo ":: Running make -C $MODULE_ROOT codegen"
      if make -C "$MODULE_ROOT" codegen 2>&1; then
        regen_ok=true
      else
        echo "  make codegen failed, trying controller-gen directly..."
      fi
    fi
    if [[ "$regen_ok" != "true" ]]; then
      command -v controller-gen &>/dev/null || go install sigs.k8s.io/controller-tools/cmd/controller-gen@latest 2>/dev/null
      if command -v controller-gen &>/dev/null; then
        local output_dir="${MODULE_ROOT}/_output/crds"
        mkdir -p "$output_dir"
        (cd "$MODULE_ROOT" && controller-gen crd:crdVersions="v1" paths=./pkg/crd/... output:crd:dir=_output/crds) 2>&1 || echo "  WARNING: controller-gen failed"
        local helm_crd_dir
        helm_crd_dir=$(find . -path "*/helm/*/crds" -type d -not -path "*/vendor/*" | head -1)
        if [[ -n "$helm_crd_dir" ]] && [[ -d "$output_dir" ]]; then
          cp "$output_dir"/*.yaml "$helm_crd_dir/" 2>/dev/null
          echo ":: Copied CRDs to $helm_crd_dir"
        fi
        regen_ok=true
      fi
    fi
    if [[ "$regen_ok" != "true" ]]; then
      echo "  WARNING: CRD regeneration failed. Run 'make codegen' manually."
    fi
  fi
}

fix_network_policy_api_crds() {
  # The conformance module may use a different network-policy-api version
  # than go-controller. Do NOT force-bump the conformance module to match —
  # the conformance suite's fixtures must match the API version the controller
  # supports. If go-controller uses v0.2.0 (Go types still include
  # AdminNetworkPolicy v1alpha1), the conformance module may use a pre-release
  # that has v1alpha1 fixtures. Bumping to v0.2.0 would bring v1alpha2
  # ClusterNetworkPolicy fixtures that the controller can't enforce.
  #
  # Only add ClusterNetworkPolicy CRD if the conformance module itself
  # uses v0.2.0+ (meaning the conformance tests expect it).
  local conf_gomod
  conf_gomod=$(find . -name "go.mod" -path "*/conformance/*" -not -path "*/vendor/*" | head -1)
  [[ -z "$conf_gomod" ]] && return 0

  local conf_npa
  conf_npa=$(grep "network-policy-api " "$conf_gomod" 2>/dev/null | awk '{print $2}' || true)
  [[ -z "$conf_npa" ]] && return 0

  # Only add CRD if conformance module uses v0.2.0+ (not a pre-release)
  local conf_minor
  conf_minor=$(echo "$conf_npa" | cut -d. -f2)
  # Pre-release versions like v0.1.9-0.20260225... have minor=1
  (( conf_minor < 2 )) 2>/dev/null && return 0

  local kind_helm
  kind_helm=$(find . -name "kind-helm.sh" -not -path "*/vendor/*" | head -1)
  [[ -z "$kind_helm" ]] && kind_helm=$(find . -name "kind.sh" -not -path "*/vendor/*" -not -type l | head -1)
  if [[ -n "$kind_helm" ]] && ! grep -q "clusternetworkpolicies" "$kind_helm"; then
    local anp_line
    anp_line=$(grep -n "adminnetworkpolicies.yaml" "$kind_helm" | head -1 | cut -d: -f1)
    if [[ -n "$anp_line" ]]; then
      echo ":: Adding ClusterNetworkPolicy CRD for conformance (${conf_npa})"
      sed -i "${anp_line}a\\  run_kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/network-policy-api/${conf_npa}/config/crd/experimental/policy.networking.k8s.io_clusternetworkpolicies.yaml" "$kind_helm"
    fi
  fi
}

# Pattern-based fixes (conditional — only run if pattern found)

fix_addtoscheme() {
  # Replace AddToScheme with Install where vendored source confirms Install exists
  local files
  files=$(grep -rln '\.AddToScheme\b' --include='*.go' . | grep -v vendor)
  [[ -z "$files" ]] && return 0
  for f in $files; do
    while IFS= read -r line; do
      local pkg_alias
      pkg_alias=$(echo "$line" | sed 's/\.AddToScheme.*//' | grep -oE '[a-zA-Z0-9_]+$')
      [[ -z "$pkg_alias" ]] && continue
      # Find the import path for this alias
      local import_path
      import_path=$(sed -n '/^import/,/^)/{/'"$pkg_alias"'/{ s/.*"\(.*\)".*/\1/; p; }}' "$f" | head -1)
      [[ -z "$import_path" ]] && continue
      # Check if Install exists in the vendored source
      local vendor_dir
      vendor_dir=$(find . -path "*/vendor/${import_path}" -type d | head -1)
      [[ -z "$vendor_dir" ]] && continue
      if grep -rq 'Install.*=.*AddToScheme\|func Install\b' "$vendor_dir" 2>/dev/null; then
        echo ":: Fixing ${pkg_alias}.AddToScheme → Install in $f"
        sed -i "s/${pkg_alias}\.AddToScheme/${pkg_alias}.Install/g" "$f"
      fi
    done < <(grep '\.AddToScheme\b' "$f")
  done
}

fix_conformance_renames() {
  # SupportAdminNetworkPolicy* → SupportClusterNetworkPolicy* (all variants)
  # SupportBaselineAdminNetworkPolicy* → SupportClusterNetworkPolicy* (merged)
  # Only rename if the conformance module uses v0.2.0+ where these symbols
  # were renamed. Pre-release versions (v0.1.9-0.2026...) still use the old names.
  local conf_gomod
  conf_gomod=$(find . -name "go.mod" -path "*/conformance/*" -not -path "*/vendor/*" | head -1)
  # No conformance module → nothing to rename
  [[ -z "$conf_gomod" ]] && return 0
  local conf_npa_minor
  conf_npa_minor=$(grep "network-policy-api " "$conf_gomod" 2>/dev/null | awk '{print $2}' | cut -d. -f2)
  # Pre-release versions (minor < 2) still use the old symbol names
  (( conf_npa_minor < 2 )) 2>/dev/null && return 0
  local files
  files=$(grep -rln 'SupportAdminNetworkPolicy\|SupportBaselineAdminNetworkPolicy' --include='*.go' . | grep -v vendor)
  [[ -z "$files" ]] && return 0
  echo ":: Fixing conformance suite renames"
  for f in $files; do
    # Replace Baseline variants first (longer prefix), then non-Baseline
    # No \b — must also catch EgressNodePeers, NamedPorts suffixes
    sed -i 's/SupportBaselineAdminNetworkPolicy/SupportClusterNetworkPolicy/g' "$f"
    sed -i 's/SupportAdminNetworkPolicy/SupportClusterNetworkPolicy/g' "$f"
    # ConformanceProfileName type cast → CNPConformanceProfileName
    sed -i 's/ConformanceProfileName(suite\.SupportClusterNetworkPolicy)/CNPConformanceProfileName/g' "$f"
    # Remove duplicate conformance lines after baseline→cluster merge
    awk '!/SupportClusterNetworkPolicy|CNPConformanceProfileName/ || !seen[$0]++' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  done
}

fix_obsgen() {
  # Add WithObservedGeneration to ConditionApplyConfiguration builder chains.
  # Only runs if the agent already converted WithConditions to the builder
  # pattern but omitted ObservedGeneration (agents confuse which struct
  # has this field — it's on ConditionApplyConfiguration, not ANP status).
  local file="go-controller/pkg/ovn/controller/admin_network_policy/status.go"
  [[ -f "$file" ]] || return 0
  # Only fix if builder pattern exists (agent already converted)
  grep -q 'Condition()' "$file" || return 0
  # Skip if ObservedGeneration already present (builder or struct literal)
  grep -q 'WithObservedGeneration\|ObservedGeneration' "$file" && return 0

  echo ":: Fixing ObsGen in $file"
  # Insert WithObservedGeneration after each WithStatus(newCondition line.
  # Process in reverse (tac) so line numbers don't shift.
  # In tac order: BANP appears first (later in file), ANP second.
  local is_first=true
  while IFS= read -r lineno; do
    local gen_var="anp.Generation"
    $is_first && gen_var="banp.Generation" && is_first=false
    sed -i "${lineno}a\\
\\t\\t\\tWithObservedGeneration(${gen_var})." "$file"
  done < <(grep -n 'WithStatus(newCondition' "$file" | tac | cut -d: -f1)
}

fix_banp_egresspeer() {
  local file
  file=$(find . -name "baseline_admin_network_policy_test.go" -not -path "*/vendor/*" | head -1)
  [[ -z "$file" ]] && return 0
  # Only rename if BaselineAdminNetworkPolicyEgressPeer exists in vendored source.
  # In network-policy-api v0.1.x, the type doesn't exist — BANP uses the
  # shared AdminNetworkPolicyEgressPeer. In v0.2.0+ it was split.
  if ! grep -rq "BaselineAdminNetworkPolicyEgressPeer" "$MODULE_ROOT/vendor/sigs.k8s.io/network-policy-api/" 2>/dev/null; then
    return 0
  fi
  local count
  count=$(grep 'AdminNetworkPolicyEgressPeer' "$file" | grep -vc Baseline)
  [[ "$count" -eq 0 ]] && return 0
  echo ":: Fixing BANP EgressPeer type in $file ($count occurrences)"
  sed -i 's/\bAdminNetworkPolicyEgressPeer\b/BaselineAdminNetworkPolicyEgressPeer/g' "$file"
  sed -i 's/BaselineBaselineAdminNetworkPolicyEgressPeer/BaselineAdminNetworkPolicyEgressPeer/g' "$file"
}

fix_feature_gates() {
  # Iterate GATE_DEPS directly — no external file needed.
  # Only process gates that exist in the vendored k8s code.
  local parents=() all_deps=()
  for gate in "${!GATE_DEPS[@]}"; do
    grep -rq "\"$gate\"" $MODULE_ROOT/vendor/k8s.io/ 2>/dev/null || continue
    parents+=("$gate")
    for dep in ${GATE_DEPS[$gate]}; do
      grep -rq "\"$dep\"" $MODULE_ROOT/vendor/k8s.io/ 2>/dev/null && all_deps+=("$dep")
    done
  done
  [[ ${#parents[@]} -eq 0 ]] && return 0

  local all_gates=("${all_deps[@]}" "${parents[@]}")

  # ── Layer 1: test-go.sh exports ──
  local test_go_sh
  test_go_sh=$(find . -name "test-go.sh" -path "*/hack/*" -not -path "*/vendor/*" | head -1)
  if [[ -n "$test_go_sh" ]]; then
    for gate in "${all_gates[@]}"; do
      if ! grep -q "KUBE_FEATURE_${gate}" "$test_go_sh"; then
        echo ":: Adding gate $gate to $test_go_sh"
        local insert_after
        insert_after=$(grep -n "KUBE_FEATURE_" "$test_go_sh" | tail -1 | cut -d: -f1)
        if [[ -n "$insert_after" ]]; then
          sed -i "${insert_after}a export KUBE_FEATURE_${gate}=false" "$test_go_sh"
        else
          sed -i "1a export KUBE_FEATURE_${gate}=false" "$test_go_sh"
        fi
      fi
    done
  fi

  # ── Layer 2: os.Setenv / t.Setenv in test files ──
  local env_files
  env_files=$(grep -rl 'os\.Setenv.*KUBE_FEATURE\|t\.Setenv.*KUBE_FEATURE' --include='*_test.go' --include='*_suite_test.go' $MODULE_ROOT/ 2>/dev/null | grep -v vendor)
  for tf in $env_files; do
    for gate in "${all_gates[@]}"; do
      [[ -z "$gate" ]] && continue
      if grep -q 'os\.Setenv.*KUBE_FEATURE' "$tf" && ! grep -q "os\.Setenv.*${gate}" "$tf"; then
        local setenv_line
        setenv_line=$(grep -n 'os\.Setenv.*KUBE_FEATURE' "$tf" | head -1 | cut -d: -f1)
        sed -i "${setenv_line}i\\
\\tos.Setenv(\"KUBE_FEATURE_${gate}\", \"false\")" "$tf"
      fi
      if grep -q 't\.Setenv.*KUBE_FEATURE' "$tf" && ! grep -q "t\.Setenv.*${gate}" "$tf"; then
        local tsetenv_line
        tsetenv_line=$(grep -n 't\.Setenv.*KUBE_FEATURE' "$tf" | head -1 | cut -d: -f1)
        sed -i "${tsetenv_line}i\\
\\tt.Setenv(\"KUBE_FEATURE_${gate}\", \"false\")" "$tf"
      fi
    done
  done

  # ── Layer 3: SetFromMap in test files ──
  # Add ALL gates (parents + deps) to SetFromMap. SetFromMap validates
  # parent-dep consistency — disabling a parent without its deps errors.
  # Each gate is checked against vendor to avoid adding removed gates.
  local sfm_gates=()
  for gate in "${parents[@]}"; do
    sfm_gates+=("$gate")
  done
  for dep in "${all_deps[@]}"; do
    grep -rq "\"$dep\"" $MODULE_ROOT/vendor/k8s.io/ 2>/dev/null && sfm_gates+=("$dep")
  done

  local sfm_files
  sfm_files=$(grep -rl 'SetFromMap' --include='*_test.go' --include='*_suite_test.go' $MODULE_ROOT/ 2>/dev/null | grep -v vendor)
  for tf in $sfm_files; do
    local missing=false
    for g in "${sfm_gates[@]}"; do
      grep -q "\"$g\"" "$tf" || { missing=true; break; }
    done
    $missing || continue

    echo ":: Adding gates to SetFromMap in $tf"
    for g in "${sfm_gates[@]}"; do
      if ! grep -q "\"$g\"" "$tf"; then
        sed -i "/SetFromMap/s/false}/false, \"${g}\": false}/" "$tf" 2>/dev/null || true
      fi
    done

    # Broaden the unrecognized-gate filter if present (safety net).
    if grep -q 'unrecognized feature gate: WatchListClient' "$tf"; then
      sed -i 's/unrecognized feature gate: WatchListClient/unrecognized feature gate/' "$tf"
    fi
  done

  # ── Layer 4: Warn about test packages that may need gates ──
  # Not all fake clientset packages need gates — only those using
  # informers (list/watch). Too many false positives to auto-fix.
  # Only checks suite files; packages without suites (e.g., pod/)
  # are caught by the validate script's dynamic test selection.
  local _missing_gate_list=""
  for suite in $(find "$MODULE_ROOT"/ -name "*_suite_test.go" -not -path "*/vendor/*" 2>/dev/null); do
    local pkg_dir
    pkg_dir=$(dirname "$suite")
    grep -rq "KUBE_FEATURE_\|SetFromMap" "$pkg_dir"/*.go 2>/dev/null && continue
    grep -rq "fake\.NewClientBuilder\|fake\.NewSimpleClientset\|fake\.NewClientset" "$pkg_dir"/*.go 2>/dev/null || continue
    _missing_gate_list+="   $suite\n"
  done
  if [[ -n "$_missing_gate_list" ]]; then
    echo ":: NOTE: These test suites use fake clientsets without gate env vars:"
    echo -e "$_missing_gate_list"
    echo "   If tests hang with informer timeouts, add KUBE_FEATURE_ env vars."
  fi
}

fix_imports() {
  # Two-step import fix:
  # 1. goimports: adds missing imports (after x/exp lines were deleted)
  # 2. gci: orders imports to match the project's golangci-lint config
  #    (goimports only does 2 groups; gci handles the project-specific
  #    multi-group layout like stdlib/external/k8s.io/local)
  # Find all Go files changed since the rebase started (not just unstaged).
  # Import issues may have been committed by earlier steps.
  local merge_base modified
  merge_base=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo "HEAD~10")
  modified=$(git diff --name-only "$merge_base" -- '*.go' | grep -v vendor | grep -v 'zz_generated')
  [[ -z "$modified" ]] && modified=$(git diff --name-only -- '*.go' | grep -v vendor | grep -v 'zz_generated')
  [[ -z "$modified" ]] && return 0

  # Step 1: goimports adds missing imports
  if ! command -v goimports &>/dev/null; then
    go install golang.org/x/tools/cmd/goimports@latest 2>/dev/null || true
  fi
  if command -v goimports &>/dev/null; then
    echo ":: Running goimports on $(echo "$modified" | wc -l) modified files"
    for f in $modified; do
      [[ -f "$f" ]] && goimports -w "$f"
    done
  fi

  # Step 2: gci fixes import grouping to match project lint config
  if ! command -v gci &>/dev/null; then
    go install github.com/daixiang0/gci@latest 2>/dev/null || true
  fi
  if command -v gci &>/dev/null; then
    # Read gci sections from project's golangci config
    local gci_args=()
    local lint_config
    lint_config=$(find . \( -name ".golangci.yml" -o -name ".golangci.yaml" \) -not -path "*/vendor/*" | head -1)
    if [[ -f "$lint_config" ]] && grep -q 'gci:' "$lint_config"; then
      while IFS= read -r section; do
        [[ -n "$section" ]] && gci_args+=(-s "$section")
      done < <(awk '/^ *gci:/{found=1} found && /sections:/{in_sec=1; next} in_sec && /^ *- /{gsub(/^ *- /,""); print; next} in_sec && !/^ *- / && !/^ *#/{exit}' "$lint_config")
      # Respect custom-order setting (required for multi-prefix sections)
      if grep -A10 'gci:' "$lint_config" | grep -q 'custom-order: true'; then
        gci_args+=(--custom-order)
      fi
    fi
    [[ ${#gci_args[@]} -eq 0 ]] && gci_args=(-s standard -s default)
    # gci localmodule needs to run from a dir with go.mod
    local gci_dir="."
    [[ -n "$PRIMARY_GOMOD" ]] && gci_dir="$(dirname "$PRIMARY_GOMOD")"
    echo ":: Running gci on modified files (${gci_args[*]})"
    for f in $modified; do
      [[ -f "$f" ]] && (cd "$gci_dir" && gci write "${gci_args[@]}" "$REPO_ROOT/$f") 2>/dev/null || true
    done
  else
    echo ":: WARNING: gci not available — import ordering may need manual fix"
  fi
}

fix_mocks() {
  # Regenerate mocks if codegen deleted them. This covers the case where
  # the agent (not k8s-rebase.sh) ran codegen — k8s-rebase.sh has its
  # own mockery step, but it only runs when its auto-retry succeeds.
  local mockery_config
  mockery_config=$(find . -name ".mockery.yaml" -not -path "*/vendor/*" | head -1)
  [[ -z "$mockery_config" ]] && return 0
  local mock_dir
  mock_dir=$(dirname "$mockery_config")
  if ! find "$mock_dir/pkg/crd" -name "mocks" -type d 2>/dev/null | grep -q .; then
    echo ":: Mock directories missing — running mockery..."
    if make -C "$mock_dir" mocksgen 2>/dev/null; then
      echo ":: Mockery regenerated mocks"
    else
      echo ":: WARNING: mockery failed — agent must regenerate mocks"
    fi
  fi
}

run_vet() {
  # Run go vet on all modules to catch semantic errors (format strings,
  # type mismatches) that grep-based checks miss.
  # Skip if local Go is too old — Step 3 re-validation auto-containerizes.
  local required_go
  required_go=$(grep "^go " "$PRIMARY_GOMOD" 2>/dev/null | awk '{print $2}')
  local current_go
  current_go=$(go env GOVERSION 2>/dev/null | sed 's/go//')
  if [[ -n "$required_go" ]] && [[ -n "$current_go" ]]; then
    local req_minor cur_minor
    req_minor=$(echo "$required_go" | cut -d. -f2)
    cur_minor=$(echo "$current_go" | cut -d. -f2)
    if [[ "$cur_minor" -lt "$req_minor" ]] 2>/dev/null; then
      echo ":: Skipping go vet (Go $current_go < $required_go required — Step 3 re-validation will check)"
      return 0
    fi
  fi
  echo ":: Running go vet on all modules"
  local vet_failed=0
  for gomod in $(find . -name "go.mod" -not -path "*/vendor/*" | sort); do
    local mod_dir
    mod_dir=$(dirname "$gomod")
    # Skip modules with gitignored vendor dirs — their vendor may be
    # stale (not updated by the rebase) and produce false vet errors
    if [[ -d "$mod_dir/vendor" ]] && git check-ignore -q "$mod_dir/vendor" 2>/dev/null; then
      echo "  Skipping $mod_dir (vendor is gitignored)"
      continue
    fi
    (cd "$mod_dir" && go vet ./...) 2>&1 || vet_failed=1
  done
  return "$vet_failed"
}

fix_uncommitted() {
  if [[ -n "$(git status --short | grep -v '^[?]')" ]]; then
    echo ":: Committing automated fixes"
    git add -A
    git commit -s -m "Apply automated k8s rebase fixes

Fixes applied by k8s-rebase-autofix.sh for known breakage
patterns. See docs/k8s-rebase-patterns.md for details."
  fi
}

# ── Main ───────────────────────────────────────────────────────────

echo "━━━━ Phase A: Diagnostic ━━━━"
echo ""
DIAG=$(run_checks)
echo "$DIAG"
echo ""

if ! echo "$DIAG" | grep -q "RESULT: PASS"; then
  echo "━━━━ Phase B: Applying fixes ━━━━"
  echo ""

  # Generic fixes — apply to any k8s rebase, any project
  fix_xexp
  fix_reflect_ptr
  fix_fieldsv1
  fix_eventf
  fix_docs_version
  fix_version_refs
  fix_go_version
  fix_kind_image
  fix_kind_version
  fix_feature_gates

  # Version-specific fixes — conditional on finding the pattern.
  # These skip automatically when the pattern doesn't exist (e.g.,
  # already fixed in a prior rebase, or project doesn't use the API).
  # For k8s 1.37+: add new fix functions here.
  fix_addtoscheme
  fix_conformance_renames
  fix_banp_egresspeer
  fix_obsgen
fi

# Always run — not covered by Go code verification checks
fix_lint_version
fix_imports
fix_metallb_version
fix_kubevirt_version
fix_relaxed_service_name_validation
fix_network_policy_api_crds
fix_crd_int64_validation

# Regenerate mocks if codegen deleted them (belt-and-suspenders with k8s-rebase.sh)
fix_mocks

# Regenerate third-party licenses if the target has it (deps changed)
for _makefile in $(find . -name "Makefile" -not -path "*/vendor/*" -maxdepth 3); do
  _mdir=$(dirname "$_makefile")
  if grep -q "^third-party-licenses:" "$_makefile" 2>/dev/null; then
    echo ":: Regenerating third-party licenses in $_mdir"
    make -C "$_mdir" third-party-licenses 2>/dev/null || echo "  WARNING: third-party-licenses failed (may need jq)"
    rm -f "$_mdir"/.third-party-licenses.*.mod "$_mdir"/.third-party-licenses.*.sum 2>/dev/null
  fi
done

# Commit if anything changed
fix_uncommitted

echo ""
echo "━━━━ Phase B.5: Compiler check ━━━━"
echo ""
VET_FAILED=0
run_vet || VET_FAILED=1

# Vet may update go.work.sum or download checksums as a side effect
fix_uncommitted

echo ""
echo "━━━━ Phase C: Re-verification ━━━━"
echo ""
RESULT=$(run_checks)
echo "$RESULT"

CHECKS_PASSED=true
if ! echo "$RESULT" | grep -q "RESULT: PASS"; then
  CHECKS_PASSED=false
fi
if [[ "$VET_FAILED" -eq 1 ]]; then
  CHECKS_PASSED=false
fi

if [[ "$CHECKS_PASSED" == "true" ]]; then
  echo "RESULT: PASS (all checks + go vet clean)"
  exit 0
else
  echo ""
  echo "━━━━ Remaining issues (agent must fix) ━━━━"
  echo ""
  # Show file:line details for remaining non-zero grep checks
  echo "$RESULT" | grep -v ': 0$' | grep -v '^---' | grep -v '^RESULT' | while IFS=: read -r name count; do
    count=$(echo "$count" | tr -d ' ')
    case "$name" in
      *"ObsGen"*)
        echo "  $name: Add .WithObservedGeneration(anp.Generation) to the metav1apply.Condition() builder chain."
        echo "    ObservedGeneration is on ConditionApplyConfiguration (k8s.io/client-go/applyconfigurations/meta/v1),"
        echo "    NOT on the ANP/BANP status struct. File:"
        grep -L 'WithObservedGeneration' go-controller/pkg/ovn/controller/admin_network_policy/status.go 2>/dev/null | sed 's/^/    /'
        ;;
      *"x/exp"*)
        echo "  $name: Migrate these imports to stdlib (maps, slices, cmp):"
        grep -rn 'golang.org/x/exp' --include='*.go' . | grep -v vendor | sed 's/^/    /'
        ;;
      *"Eventf"*)
        echo "  $name: Wrap .Error() with \"%s\" format string:"
        grep -rn 'Eventf(.*\.Error())' --include='*.go' . | grep -v vendor | grep -v '%s\|%v' | sed 's/^/    /'
        ;;
      *"Gates"*)
        echo "  $name: Feature gates missing. Check GATE_DEPS in autofix script."
        ;;
      *)
        echo "  $name: $count remaining (see patterns doc for fix)"
        ;;
    esac
  done
  if [[ "$VET_FAILED" -eq 1 ]]; then
    echo ""
    echo "  go vet errors found above — fix before proceeding"
  fi
  exit 1
fi
