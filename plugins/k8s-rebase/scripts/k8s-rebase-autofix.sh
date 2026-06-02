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
REBASE_TMP="$REPO_ROOT/.rebase-tmp"

# Auto-containerize if local Go is too old for the repo's go.mod
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
fi

# ── Gate dependents (extend for future releases) ──────────────────
# When a parent gate is disabled, ALL its dependents must also be
# disabled. Add new entries here — the verification block and
# fix_feature_gates both read from this map automatically.
declare -A GATE_DEPS
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
  r "Conformance old names" "$(grep -w 'SupportAdminNetworkPolicy' test/conformance/network_policy_v2_test.go 2>/dev/null | wc -l)"
  r "AddToScheme in factory" "$(grep 'anpapi.AddToScheme' go-controller/pkg/factory/factory.go 2>/dev/null | wc -l)"
  r "AddToScheme in conformance" "$(grep 'AddToScheme' test/conformance/network_policy_v2_test.go 2>/dev/null | wc -l)"
  r "BANP wrong EgressPeer" "$(grep 'AdminNetworkPolicyEgressPeer' go-controller/pkg/ovn/baseline_admin_network_policy_test.go 2>/dev/null | grep -vc Baseline)"
  r "Gates missing" "$(cat "$REBASE_TMP/new-gates.txt" 2>/dev/null | while read g; do grep -q "KUBE_FEATURE_$g" go-controller/hack/test-go.sh 2>/dev/null || echo "$g"; done | wc -l)"
  r "Gate files incomplete" "$(for f in $(grep -rl 'KUBE_FEATURE_' --include='*_test.go' --include='*_suite_test.go' go-controller/ 2>/dev/null | grep -v vendor); do cat "$REBASE_TMP/new-gates.txt" 2>/dev/null | while read g; do grep -q "$g" "$f" || echo "$f:$g"; done; done | wc -l)"
  # Gate dep checks — driven by GATE_DEPS map (add new gates there, not here)
  local _gdsh=0
  for _p in "${!GATE_DEPS[@]}"; do
    if grep -q "$_p" go-controller/hack/test-go.sh 2>/dev/null; then
      for _d in ${GATE_DEPS[$_p]}; do
        grep -q "$_d" go-controller/hack/test-go.sh 2>/dev/null || _gdsh=$((_gdsh+1))
      done
    fi
  done
  r "Gate deps in test-go.sh" "$_gdsh"
  local _gdtf=0
  for _f in $(grep -rl 'KUBE_FEATURE_' --include='*_test.go' --include='*_suite_test.go' go-controller/ 2>/dev/null | grep -v vendor); do
    for _p in "${!GATE_DEPS[@]}"; do
      if grep -q "$_p" "$_f"; then
        for _d in ${GATE_DEPS[$_p]}; do
          grep -q "$_d" "$_f" || _gdtf=$((_gdtf+1))
        done
      fi
    done
  done
  r "Gate deps in test files" "$_gdtf"
  r "ObsGen missing" "$(grep -L 'WithObservedGeneration' go-controller/pkg/ovn/controller/admin_network_policy/status.go 2>/dev/null | wc -l)"
  r "x/exp imports" "$(grep -rn 'golang.org/x/exp' --include='*.go' . | grep -v vendor | wc -l)"
  r "reflect.Ptr" "$(grep -rn 'reflect\.Ptr\b' --include='*.go' . | grep -v vendor | wc -l)"
  r "FieldsV1.Raw" "$(grep -rn 'FieldsV1\.Raw\b' --include='*.go' . | grep -v vendor | wc -l)"
  r "Bare Eventf" "$(grep -rn 'Eventf(.*\.Error())' --include='*.go' . | grep -v vendor | grep -v '%s\|%v' | wc -l)"
  local NEW OLD
  NEW=$(grep 'k8s.io/api ' go-controller/go.mod 2>/dev/null | grep -oP 'v0\.\K[0-9]+')
  if [[ -n "$NEW" ]]; then
    OLD=$((NEW-1))
    r "Stale docs ver" "$(grep "| *1\.${OLD} *|" docs/features/requirements.md 2>/dev/null | wc -l)"
  else
    r "Stale docs ver" "0"
  fi
  r "Uncommitted" "$(git status --short -- . ':!.rebase-tmp' | grep -v '^[?]' | wc -l)"
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
  NEW=$(grep 'k8s.io/api ' go-controller/go.mod 2>/dev/null | grep -oP 'v0\.\K[0-9]+')
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
  NEW=$(grep 'k8s.io/api ' go-controller/go.mod 2>/dev/null | grep -oP 'v0\.\K[0-9]+')
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

fix_lint_version() {
  local lint_sh
  lint_sh=$(find . -name "lint.sh" -path "*/hack/*" -not -path "*/vendor/*" | head -1)
  [[ -z "$lint_sh" ]] && return 0
  local lint_ver test_yml
  lint_ver=$(grep -oP 'VERSION=\Kv[0-9.]+' "$lint_sh" | head -1)
  test_yml=$(find . -name "test.yml" -path "*/.github/workflows/*" | head -1)
  [[ -z "$test_yml" ]] && return 0
  local test_ver
  test_ver=$(grep -oP 'version: \Kv[0-9.]+' "$test_yml" | head -1)
  if [[ -n "$lint_ver" ]] && [[ -n "$test_ver" ]] && [[ "$lint_ver" != "$test_ver" ]]; then
    echo ":: Syncing lint version: test.yml $test_ver → $lint_ver"
    sed -i "s/version: ${test_ver}/version: ${lint_ver}/g" "$test_yml"
  fi
}

fix_kind_image() {
  local NEW
  NEW=$(grep 'k8s.io/api ' go-controller/go.mod 2>/dev/null | grep -oP 'v0\.\K[0-9]+')
  [[ -z "$NEW" ]] && return 0
  local kind_tag="v1.${NEW}.0"
  # Check if KIND image exists — try docker first, fall back to Docker Hub API
  local image_exists=1
  if command -v docker &>/dev/null; then
    docker manifest inspect "kindest/node:${kind_tag}" &>/dev/null && image_exists=0
  else
    curl -sf "https://hub.docker.com/v2/repositories/kindest/node/tags/${kind_tag}" > /dev/null 2>&1 && image_exists=0
  fi
  if [[ "$image_exists" -ne 0 ]]; then
    local OLD=$((NEW-1))
    local old_tag="v1.${OLD}"
    echo ":: kindest/node:${kind_tag} not available — reverting K8S_VERSION to ${old_tag}"
    # Revert K8S_VERSION in CI and scripts (but not docs)
    for f in $(grep -rln "K8S_VERSION.*${kind_tag}\|kindest/node:${kind_tag}" \
      --include="*.yml" --include="*.yaml" --include="*.sh" --include="Makefile*" . \
      | grep -v vendor | grep -v docs/); do
      sed -i "s|${kind_tag}|v1.${OLD}.1|g" "$f"
    done
    # Also fix contrib/ scripts
    for f in $(grep -rln "${kind_tag}" contrib/ --include="*.sh" --include="*.yaml" 2>/dev/null); do
      sed -i "s|${kind_tag}|v1.${OLD}.1|g" "$f"
    done
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
      pkg_alias=$(echo "$line" | grep -oP '[a-zA-Z0-9_]+(?=\.AddToScheme)')
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
  grep -q 'WithObservedGeneration' "$file" && return 0
  # Only fix if builder pattern exists (agent already converted)
  grep -q 'Condition()' "$file" || return 0

  echo ":: Fixing ObsGen in $file"
  # Insert before each applyObj line, detecting ANP vs BANP from context.
  # Process in reverse (tac) so line numbers don't shift.
  while IFS= read -r lineno; do
    local prev=$((lineno - 1))
    # Add trailing dot to last builder call if not present
    sed -i "${prev}s/\([^.]\)$/\1./" "$file"
    # Detect ANP vs BANP from the applyObj line
    local gen_var="anp.Generation"
    sed -n "${lineno}p" "$file" | grep -q 'Baseline' && gen_var="banp.Generation"
    # Insert WithObservedGeneration before applyObj
    sed -i "${lineno}i\\
\\t\\tWithObservedGeneration(${gen_var})" "$file"
  done < <(grep -n '^[[:space:]]*applyObj' "$file" | grep -v 'ApplyStatus' | tac | cut -d: -f1)
}

fix_banp_egresspeer() {
  local file
  file=$(find . -name "baseline_admin_network_policy_test.go" -not -path "*/vendor/*" | head -1)
  [[ -z "$file" ]] && return 0
  local count
  count=$(grep 'AdminNetworkPolicyEgressPeer' "$file" | grep -vc Baseline)
  [[ "$count" -eq 0 ]] && return 0
  echo ":: Fixing BANP EgressPeer type in $file ($count occurrences)"
  # In BANP test files, non-Baseline AdminNetworkPolicyEgressPeer → BaselineAdminNetworkPolicyEgressPeer
  sed -i 's/\bAdminNetworkPolicyEgressPeer\b/BaselineAdminNetworkPolicyEgressPeer/g' "$file"
  # The above also changes BaselineAdminNetworkPolicyEgressPeer to
  # BaselineBaselineAdminNetworkPolicyEgressPeer — fix the double prefix
  sed -i 's/BaselineBaselineAdminNetworkPolicyEgressPeer/BaselineAdminNetworkPolicyEgressPeer/g' "$file"
}

fix_feature_gates() {
  local gate_file="$REBASE_TMP/new-gates.txt"
  [[ -f "$gate_file" ]] || return 0
  [[ -s "$gate_file" ]] || return 0

  local test_go_sh
  test_go_sh=$(find . -name "test-go.sh" -path "*/hack/*" -not -path "*/vendor/*" | head -1)
  [[ -z "$test_go_sh" ]] && return 0

  # GATE_DEPS is defined at the top of this script (global scope).
  # Add new gate dependents there, not here.

  while IFS= read -r gate; do
    [[ -z "$gate" ]] && continue

    # Add gate to test-go.sh if missing
    if ! grep -q "KUBE_FEATURE_${gate}" "$test_go_sh"; then
      echo ":: Adding gate $gate to $test_go_sh"
      # Insert before the last line or after existing KUBE_FEATURE exports
      local insert_after
      insert_after=$(grep -n "KUBE_FEATURE_" "$test_go_sh" | tail -1 | cut -d: -f1)
      if [[ -n "$insert_after" ]]; then
        sed -i "${insert_after}a export KUBE_FEATURE_${gate}=false" "$test_go_sh"
      else
        echo "export KUBE_FEATURE_${gate}=false" >> "$test_go_sh"
      fi
    fi

    # Add dependents if known
    local deps="${GATE_DEPS[$gate]:-}"
    if [[ -n "$deps" ]]; then
      for dep in $deps; do
        if ! grep -q "KUBE_FEATURE_${dep}" "$test_go_sh"; then
          local parent_line
          parent_line=$(grep -n "KUBE_FEATURE_${gate}" "$test_go_sh" | head -1 | cut -d: -f1)
          sed -i "${parent_line}i export KUBE_FEATURE_${dep}=false" "$test_go_sh"
        fi
      done
    fi

    # Add to test files that already disable feature gates
    local test_files
    test_files=$(grep -rl 'KUBE_FEATURE_' --include='*_test.go' --include='*_suite_test.go' go-controller/ 2>/dev/null | grep -v vendor)
    for tf in $test_files; do
      [[ -z "$tf" ]] && continue
      if ! grep -q "$gate" "$tf"; then
        # Detect mechanism and insert after last gate-related line
        if grep -q 'os\.Setenv.*KUBE_FEATURE' "$tf"; then
          local setenv_line
          setenv_line=$(grep -n 'os\.Setenv.*KUBE_FEATURE' "$tf" | head -1 | cut -d: -f1)
          sed -i "${setenv_line}a\\
\\tos.Setenv(\"KUBE_FEATURE_${gate}\", \"false\")" "$tf"
          for dep in $deps; do
            if ! grep -q "$dep" "$tf"; then
              sed -i "${setenv_line}a\\
\\tos.Setenv(\"KUBE_FEATURE_${dep}\", \"false\")" "$tf"
            fi
          done
        elif grep -q 't\.Setenv.*KUBE_FEATURE' "$tf"; then
          local tsetenv_line
          tsetenv_line=$(grep -n 't\.Setenv.*KUBE_FEATURE' "$tf" | head -1 | cut -d: -f1)
          sed -i "${tsetenv_line}a\\
\\tt.Setenv(\"KUBE_FEATURE_${gate}\", \"false\")" "$tf"
          for dep in $deps; do
            if ! grep -q "$dep" "$tf"; then
              sed -i "${tsetenv_line}a\\
\\tt.Setenv(\"KUBE_FEATURE_${dep}\", \"false\")" "$tf"
            fi
          done
        elif grep -q 'SetFromMap' "$tf"; then
          # Insert after the SetFromMap line (inside the map literal)
          local map_line
          map_line=$(grep -n 'SetFromMap' "$tf" | head -1 | cut -d: -f1)
          if [[ -n "$map_line" ]]; then
            sed -i "${map_line}a\\
\\t\\t\"${gate}\": false," "$tf" 2>/dev/null || true
            for dep in $deps; do
              if ! grep -q "$dep" "$tf"; then
                sed -i "${map_line}a\\
\\t\\t\"${dep}\": false," "$tf" 2>/dev/null || true
              fi
            done
          fi
        fi
      fi
    done
  done < "$gate_file"
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
  merge_base=$(git merge-base HEAD master 2>/dev/null || echo "HEAD~10")
  modified=$(git diff --name-only "$merge_base" -- '*.go' | grep -v vendor)
  [[ -z "$modified" ]] && modified=$(git diff --name-only -- '*.go' | grep -v vendor)
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
    lint_config=$(find . -name ".golangci.yml" -not -path "*/vendor/*" | head -1)
    if [[ -f "$lint_config" ]] && grep -q 'gci:' "$lint_config"; then
      while IFS= read -r section; do
        [[ -n "$section" ]] && gci_args+=(-s "$section")
      done < <(awk '/^ *gci:/{found=1} found && /sections:/{in_sec=1} in_sec && /^ *- /{gsub(/^ *- /,""); print} in_sec && /custom-order/{exit}' "$lint_config")
    fi
    [[ ${#gci_args[@]} -eq 0 ]] && gci_args=(-s standard -s default)
    # gci localmodule needs to run from a dir with go.mod
    local gci_dir="."
    [[ -f go-controller/go.mod ]] && gci_dir="go-controller"
    echo ":: Running gci on modified files (${gci_args[*]})"
    for f in $modified; do
      [[ -f "$f" ]] && (cd "$gci_dir" && gci write "${gci_args[@]}" "$REPO_ROOT/$f") 2>/dev/null || true
    done
  else
    echo ":: WARNING: gci not available — import ordering may need manual fix"
  fi
}

run_vet() {
  # Run go vet on all modules to catch semantic errors (format strings,
  # type mismatches) that grep-based checks miss.
  # Skip if local Go is too old — Step 3 re-validation auto-containerizes.
  local required_go
  required_go=$(grep "^go " go-controller/go.mod 2>/dev/null | awk '{print $2}')
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
    (cd "$mod_dir" && go vet ./...) 2>&1 || vet_failed=1
  done
  return "$vet_failed"
}

fix_uncommitted() {
  if [[ -n "$(git status --short -- . ':!.rebase-tmp' | grep -v '^[?]')" ]]; then
    echo ":: Committing automated fixes"
    git add -A -- . ':!.rebase-tmp' ':!.gitconfig'
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
  fix_lint_version
  fix_kind_image
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

# Always run import ordering — not covered by verification checks
fix_imports

# Commit if anything changed
fix_uncommitted

echo ""
echo "━━━━ Phase B.5: Compiler check ━━━━"
echo ""
VET_FAILED=0
run_vet || VET_FAILED=1

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
