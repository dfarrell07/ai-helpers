#!/bin/bash
# k8s-rebase.sh — Automate Kubernetes dependency rebase for Go projects
#
# Usage: k8s-rebase.sh <version>
#   e.g.: k8s-rebase.sh 1.36.0
#
# Run from any Go repo with k8s.io dependencies. The script auto-detects
# go.mod files, codegen scripts, and vendor directories.
#
# Handles Phases 0-3 (deterministic). Phase 4 (build validation and
# fixups) is handled by the companion skill or manually.
#
# Exit codes: 0 = already at target (nothing to do)
#             1 = error
#             2 = mechanical steps done, Phase 4 needed

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: Not in a git repository" >&2; exit 1; }
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ── Helpers ──────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ":: $*"; }
banner() { echo ""; echo "━━━━ $* ━━━━"; echo ""; }

# ── Argument parsing ─────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: $SCRIPT_NAME <k8s-version>"
  echo "  e.g.: $SCRIPT_NAME 1.36.0"
  exit 1
fi

VERSION_INPUT="$1"

# Parse X.Y.Z or X.Y (default Z=0)
if [[ "$VERSION_INPUT" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
  K8S_MAJOR="${BASH_REMATCH[1]}"
  K8S_MINOR="${BASH_REMATCH[2]}"
  K8S_PATCH="${BASH_REMATCH[4]:-0}"
else
  die "Invalid version format: $VERSION_INPUT (expected X.Y or X.Y.Z)"
fi

K8S_FULL="v${K8S_MAJOR}.${K8S_MINOR}.${K8S_PATCH}"
K8S_MAJOR_MINOR="${K8S_MAJOR}.${K8S_MINOR}"
API_VERSION="v0.${K8S_MINOR}.${K8S_PATCH}"

# ── Phase 0: Prerequisites ──────────────────────────────────────────

banner "Phase 0: Prerequisites"

cd "$REPO_ROOT" || die "Cannot cd to $REPO_ROOT"

# Find the primary go.mod (first one with k8s.io deps)
PRIMARY_GOMOD=""
for candidate in go-controller/go.mod go.mod; do
  if [[ -f "$candidate" ]] && grep -qE "k8s\.io/(api|client-go|apimachinery) " "$candidate"; then
    PRIMARY_GOMOD="$candidate"
    break
  fi
done
if [[ -z "$PRIMARY_GOMOD" ]]; then
  PRIMARY_GOMOD=$(find . -name "go.mod" -not -path "*/vendor/*" -exec grep -lE "k8s\.io/(api|client-go|apimachinery) " {} \; | head -1)
fi
[[ -z "$PRIMARY_GOMOD" ]] && die "No go.mod with k8s.io dependencies found in $REPO_ROOT"

# Detect version from k8s.io/api, client-go, or apimachinery (in priority order)
OLD_API_VERSION=""
for pkg in "k8s.io/api " "k8s.io/client-go " "k8s.io/apimachinery "; do
  OLD_API_VERSION=$(grep "$pkg" "$PRIMARY_GOMOD" 2>/dev/null | head -1 | awk '{print $2}' || true)
  [[ -n "$OLD_API_VERSION" ]] && break
done
OLD_MINOR=$(echo "$OLD_API_VERSION" | grep -oP 'v0\.\K[0-9]+')
[[ -z "$OLD_MINOR" ]] && die "Cannot detect current k8s minor from $PRIMARY_GOMOD"
OLD_GO_VERSION=$(grep "^go " "$PRIMARY_GOMOD" | awk '{print $2}')

info "Current: k8s.io/api $OLD_API_VERSION (k8s 1.${OLD_MINOR}), Go $OLD_GO_VERSION"
info "Target:  k8s.io/api $API_VERSION (k8s $K8S_FULL)"

# Idempotency check
if [[ "$OLD_MINOR" == "$K8S_MINOR" ]]; then
  info "Already at k8s 1.${K8S_MINOR} — nothing to do"
  exit 0
fi

# Check required tools
MISSING=()
for tool in go git make curl sed grep; do
  command -v "$tool" &>/dev/null || MISSING+=("$tool")
done
[[ ${#MISSING[@]} -gt 0 ]] && die "Missing required tools: ${MISSING[*]}"

# Verify target version exists on Go module proxy
info "Checking Go module proxy for $API_VERSION..."
if ! curl -sf "https://proxy.golang.org/k8s.io/api/@v/${API_VERSION}.info" > /dev/null 2>&1; then
  die "k8s.io/api@${API_VERSION} not found on Go module proxy. Version may not be released yet."
fi
info "Target version confirmed on proxy"

# Check Go version — if too old, re-exec inside the official Go container
REQUIRED_GO=$(curl -sf "https://raw.githubusercontent.com/kubernetes/kubernetes/v${K8S_MAJOR}.${K8S_MINOR}.${K8S_PATCH}/go.mod" 2>/dev/null | grep "^go " | awk '{print $2}')
CURRENT_GO=$(go env GOVERSION 2>/dev/null | sed 's/go//' || echo "0.0")
GO_OK=1
if [[ -n "$REQUIRED_GO" ]]; then
  REQ_MINOR=$(echo "$REQUIRED_GO" | cut -d. -f2)
  CUR_MINOR=$(echo "$CURRENT_GO" | cut -d. -f2)
  [[ "$CUR_MINOR" -lt "$REQ_MINOR" ]] 2>/dev/null && GO_OK=0
fi

if [[ "$GO_OK" -eq 0 ]] && [[ "${K8S_REBASE_IN_CONTAINER:-}" != "1" ]]; then
  # Detect container runtime (podman or docker)
  CONTAINER_RT=""
  command -v podman &>/dev/null && CONTAINER_RT=podman
  [[ -z "$CONTAINER_RT" ]] && command -v docker &>/dev/null && CONTAINER_RT=docker
  if [[ -z "$CONTAINER_RT" ]]; then
    die "Go $REQUIRED_GO required for k8s $K8S_FULL but running Go $CURRENT_GO. Install Go $REQUIRED_GO, or install podman/docker for automatic containerized execution."
  fi

  GO_IMAGE="docker.io/library/golang:${REQUIRED_GO}"
  info "Go $CURRENT_GO < $REQUIRED_GO required — re-running inside $GO_IMAGE"

  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  exec $CONTAINER_RT run --rm \
    --security-opt label=disable \
    -v "$REPO_ROOT:$REPO_ROOT" \
    -v "$(dirname "$SCRIPT_PATH"):$(dirname "$SCRIPT_PATH"):ro" \
    -w "$REPO_ROOT" \
    -e GIT_AUTHOR_NAME="$(git config user.name)" \
    -e GIT_AUTHOR_EMAIL="$(git config user.email)" \
    -e GIT_COMMITTER_NAME="$(git config user.name)" \
    -e GIT_COMMITTER_EMAIL="$(git config user.email)" \
    -e K8S_REBASE_IN_CONTAINER=1 \
    "$GO_IMAGE" \
    bash "$SCRIPT_PATH" "$VERSION_INPUT"
fi
info "Go version: $CURRENT_GO (>= ${REQUIRED_GO:-any} required)"

# Clean working tree
if [[ -n "$(git status --porcelain)" ]]; then
  die "Working tree is not clean. Commit or stash changes first."
fi

# Discover controller-runtime version — find the latest patch for the computed minor
CR_MINOR=$((K8S_MINOR - 12))
CR_VERSION=""
# Try patch versions from highest to lowest (most repos use .0 or .1)
for patch in 3 2 1 0; do
  candidate="v0.${CR_MINOR}.${patch}"
  if curl -sf "https://proxy.golang.org/sigs.k8s.io/controller-runtime/@v/${candidate}.info" > /dev/null 2>&1; then
    CR_VERSION="$candidate"
    break
  fi
done
if [[ -n "$CR_VERSION" ]]; then
  info "Controller-runtime: $CR_VERSION (formula + latest patch)"
else
  info "Controller-runtime: v0.${CR_MINOR}.x not on proxy, will use latest"
fi

# Create branch
BRANCH_NAME="bump${K8S_MAJOR_MINOR}"
if git rev-parse --verify "$BRANCH_NAME" &>/dev/null; then
  info "Branch $BRANCH_NAME already exists, checking it out"
  git checkout "$BRANCH_NAME"
else
  git checkout -b "$BRANCH_NAME"
  info "Created branch: $BRANCH_NAME"
fi

# ── Derivation function ─────────────────────────────────────────────

derive_go_gets() {
  local gomod="$1"
  local cmds=()

  # Rule 1: version-locked (v{N}.{OLD_MINOR}.* → v{N}.{NEW_MINOR}.*)
  while IFS= read -r line; do
    local pkg ver_prefix
    pkg=$(echo "$line" | awk '{print $1}')
    ver_prefix=$(echo "$line" | grep -oP 'v\K[0-9]+' | head -1)
    cmds+=("go get ${pkg}@v${ver_prefix}.${K8S_MINOR}.${K8S_PATCH}")
  done < <(grep -E "k8s\.io/|sigs\.k8s\.io/" "$gomod" | grep -E "v[0-9]+\.${OLD_MINOR}\." | awk '{print $1, $2}' | sort -u)

  # Rule 2: controller-runtime
  if grep -q "controller-runtime" "$gomod"; then
    if [[ -n "$CR_VERSION" ]]; then
      cmds+=("go get sigs.k8s.io/controller-runtime@${CR_VERSION}")
    else
      cmds+=("go get sigs.k8s.io/controller-runtime")
    fi
  fi

  # Rule 3: everything else in k8s ecosystem
  # Filter out go.mod keywords (module, replace, require, exclude) and
  # the module's own name to avoid self-referencing go gets
  local own_module
  own_module=$(grep "^module " "$gomod" | awk '{print $2}')
  while IFS= read -r pkg; do
    # Skip go.mod keywords, controller-runtime (Rule 2), and self-references
    case "$pkg" in
      module|replace|require|exclude|"$own_module") continue ;;
    esac
    echo "$pkg" | grep -q "controller-runtime" && continue
    cmds+=("go get ${pkg}")
  done < <(grep -E "k8s\.io/|sigs\.k8s\.io/|github\.com/openshift/(api|client-go) " "$gomod" | \
           grep -vE "v[0-9]+\.${OLD_MINOR}\." | \
           awk '{print $1}' | sort -u)

  printf '%s\n' "${cmds[@]}"
}

# ── Phase 1: Module Dependency Updates ───────────────────────────────

rebase_module() {
  local module_dir="$1"
  local module_path="$module_dir"
  [[ "$module_path" == "." ]] && module_path=$(basename "$REPO_ROOT")
  local gomod="${REPO_ROOT}/${module_dir}/go.mod"

  [[ -f "$gomod" ]] || { info "No go.mod at $gomod, skipping"; return 0; }

  banner "Phase 1: Rebase $module_path"

  cd "$REPO_ROOT/$module_dir" || die "Cannot cd to $module_dir"

  local commands
  commands=$(derive_go_gets "$gomod")

  if [[ -z "$commands" ]]; then
    info "No k8s ecosystem packages found in $gomod"
    cd "$REPO_ROOT"
    return 0
  fi

  info "Running $(echo "$commands" | wc -l) go get commands..."
  local cmd_log=""
  while IFS= read -r cmd; do
    info "  $cmd"
    eval "$cmd" || info "  WARNING: $cmd failed (continuing)"
    cmd_log+="$cmd"$'\n'
  done <<< "$commands"

  info "Running go mod tidy..."
  go mod tidy

  if [[ -d "vendor" ]]; then
    info "Running go mod vendor..."
    go mod vendor
    if [[ -x "$REPO_ROOT/go-controller/hack/verify-go-mod-vendor.sh" ]] && [[ "$module_dir" == "go-controller" ]]; then
      info "Verifying vendor..."
      "$REPO_ROOT/go-controller/hack/verify-go-mod-vendor.sh" || info "WARNING: vendor verification failed"
    fi
  fi

  cd "$REPO_ROOT"

  # Commit if there are changes
  if [[ -n "$(git status --porcelain -- "$module_dir")" ]]; then
    git add "$module_dir"
    git commit -s -m "$(cat <<EOF
Rebase ${module_path} to k8s ${K8S_MAJOR_MINOR}

${cmd_log}go mod tidy
EOF
)"
    info "Committed: Rebase ${module_path} to k8s ${K8S_MAJOR_MINOR}"
  else
    info "No changes in $module_path (already up to date)"
  fi
}

banner "Phase 1: Module Dependency Updates"

# Auto-detect all go.mod files with k8s.io deps, rebase non-vendored first
VENDOR_MODULES=()
NONVENDOR_MODULES=()
while IFS= read -r gomod; do
  mod_dir=$(dirname "$gomod")
  [[ "$mod_dir" == "." ]] && mod_dir="."
  if [[ -d "$REPO_ROOT/$mod_dir/vendor" ]]; then
    VENDOR_MODULES+=("$mod_dir")
  else
    NONVENDOR_MODULES+=("$mod_dir")
  fi
done < <(find . -name "go.mod" -not -path "*/vendor/*" -exec grep -l "k8s.io/" {} \; | sed 's|^\./||' | sort)

# Non-vendored modules first (lighter, faster feedback)
for mod in "${NONVENDOR_MODULES[@]}"; do
  rebase_module "$mod"
done
# Vendored modules last (heavier, go mod vendor is slow)
for mod in "${VENDOR_MODULES[@]}"; do
  rebase_module "$mod"
done

# Re-tidy modules that depend on sibling modules via replace directives
for gomod in $(find . -name "go.mod" -not -path "*/vendor/*"); do
  mod_dir=$(dirname "$gomod" | sed 's|^\./||')
  if grep -q '\.\./.*go-controller\|\.\./' "$gomod" 2>/dev/null; then
    banner "Phase 1: Re-tidy $mod_dir (replace directive sync)"
    cd "$REPO_ROOT/$mod_dir" && go mod tidy && cd "$REPO_ROOT"
    if [[ -n "$(git status --porcelain -- "$mod_dir")" ]]; then
      git add "$mod_dir"
      git commit -s -m "Sync ${mod_dir} go.mod after go-controller rebase"
      info "Committed: Sync ${mod_dir} go.mod after go-controller rebase"
    fi
  fi
done

# ── Phase 2: Code Generation ────────────────────────────────────────

# Find codegen script (common locations)
CODEGEN_SCRIPT=""
for candidate in go-controller/hack/update-codegen.sh hack/update-codegen.sh; do
  if [[ -f "$REPO_ROOT/$candidate" ]]; then
    CODEGEN_SCRIPT="$REPO_ROOT/$candidate"
    break
  fi
done

if [[ -n "$CODEGEN_SCRIPT" ]]; then
  banner "Phase 2: Code Generation"

  # Update code-generator version pin
  sed -i "s|code-generator/cmd/%s@v0\.[0-9]*\.[0-9]*|code-generator/cmd/%s@${API_VERSION}|g" "$CODEGEN_SCRIPT"
  info "Updated code-generator version to ${API_VERSION}"

  # Run codegen — try common make targets
  CODEGEN_DIR=$(dirname "$(dirname "$CODEGEN_SCRIPT")")
  CODEGEN_RAN=0
  for target in codegen generate update-codegen; do
    if make -n -C "$CODEGEN_DIR" "$target" &>/dev/null; then
      info "Running make $target in $CODEGEN_DIR..."
      make -C "$CODEGEN_DIR" "$target" || info "WARNING: make $target failed (continuing)"
      CODEGEN_RAN=1
      break
    fi
  done
  if [[ "$CODEGEN_RAN" -eq 0 ]]; then
    info "WARNING: No codegen/generate make target found, running script directly..."
    bash "$CODEGEN_SCRIPT" || info "WARNING: codegen script failed (continuing)"
  fi

  cd "$REPO_ROOT"
  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    git commit -s -m "Update codegen for k8s ${K8S_MAJOR_MINOR}"
    info "Committed: Update codegen for k8s ${K8S_MAJOR_MINOR}"
  fi
else
  info "No codegen script found, skipping Phase 2"
fi

# ── Phase 3: Version Reference Updates ───────────────────────────────

banner "Phase 3: Version Reference Updates"

OLD_K8S_FULL="v${K8S_MAJOR}.${OLD_MINOR}.0"
NEW_K8S_FULL="${K8S_FULL}"
CHANGED_FILES=""

# Pass 1: full version (CI workflows, scripts, Dockerfiles)
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  sed -i "s|${OLD_K8S_FULL}|${NEW_K8S_FULL}|g" "$file"
  CHANGED_FILES+="$file"$'\n'
  info "  Updated: $file"
done < <(grep -rln "${OLD_K8S_FULL}" \
  --include="*.yml" --include="*.yaml" --include="*.sh" \
  --include="*.md" --include="Makefile*" --include="Dockerfile*" . \
  | grep -v vendor | grep -v "/\.git/" | grep -v go.mod || true)

# Pass 2: short version in docs
OLD_SHORT="${K8S_MAJOR}.${OLD_MINOR}"
NEW_SHORT="${K8S_MAJOR_MINOR}"
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  OLD_SHORT_ESC=$(echo "$OLD_SHORT" | sed 's/\./\\./g')
  sed -i -E "s/\b${OLD_SHORT_ESC}\b/${NEW_SHORT}/g" "$file"
  CHANGED_FILES+="$file"$'\n'
  info "  Updated (short): $file"
done < <(grep -rln "\b${OLD_SHORT}\b" --include="*.md" docs/ 2>/dev/null | grep -v vendor || true)

# Go version update (if changed)
NEW_GO_VERSION=$(grep "^go " "$PRIMARY_GOMOD" | awk '{print $2}')
if [[ "$OLD_GO_VERSION" != "$NEW_GO_VERSION" ]]; then
  info "Go version changed: $OLD_GO_VERSION → $NEW_GO_VERSION"
  OLD_GO_SHORT=$(echo "$OLD_GO_VERSION" | grep -oP '[0-9]+\.[0-9]+')
  NEW_GO_SHORT=$(echo "$NEW_GO_VERSION" | grep -oP '[0-9]+\.[0-9]+')

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    sed -i "s|golang[:-]${OLD_GO_SHORT}|golang:${NEW_GO_SHORT}|g; s|GO_VERSION ?= ${OLD_GO_SHORT}|GO_VERSION ?= ${NEW_GO_SHORT}|g; s|go-version: \[${OLD_GO_SHORT}|go-version: [${NEW_GO_SHORT}|g" "$file"
    CHANGED_FILES+="$file"$'\n'
    info "  Updated Go version: $file"
  done < <(grep -rln "${OLD_GO_SHORT}" \
    --include="*.yml" --include="*.yaml" --include="Makefile*" \
    --include="Dockerfile*" . \
    | grep -v vendor | grep -v "/\.git/" | grep -v go.mod || true)
fi

cd "$REPO_ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  git commit -s -m "$(cat <<EOF
Update version references for k8s ${K8S_MAJOR_MINOR}

${CHANGED_FILES}
EOF
)"
  info "Committed: Update version references for k8s ${K8S_MAJOR_MINOR}"
fi

# ── Phase 3b: Detect new feature gates ──────────────────────────────
# Detection only — does NOT auto-disable. Phase 4 agent investigates
# each gate, tries real fixes first, and only disables as last resort.

KNOWN_FEATURES=$(find . -path "*/k8s.io/client-go/features/known_features.go" -not -path "*/.git/*" | head -1)
GATE_REPORT="/tmp/rebase-new-gates.txt"
echo "" > "$GATE_REPORT"

if [[ -n "$KNOWN_FEATURES" ]]; then
  banner "Phase 3b: Feature Gate Detection"

  NEW_GATES=()
  while IFS= read -r gate; do
    [[ -z "$gate" ]] && continue
    NEW_GATES+=("$gate")
  done < <(awk '
    /^\t[A-Z].*Feature = / { gate = $1 }
    /Default: true/ && /MustParse\("1\.'"${K8S_MINOR}"'"\)/ { print gate }
  ' "$KNOWN_FEATURES")

  if [[ ${#NEW_GATES[@]} -gt 0 ]]; then
    info "New default-true feature gates in k8s 1.${K8S_MINOR}: ${NEW_GATES[*]}"
    info "These may cause test failures with fake clientsets."
    info "Phase 4 will investigate each and apply the appropriate fix."
    printf '%s\n' "${NEW_GATES[@]}" > "$GATE_REPORT"
  else
    info "No new default-true feature gates in k8s 1.${K8S_MINOR}"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────

# Count commits on this branch since creation (look for the branch point)
BRANCH_BASE=$(git log --oneline --grep="rebase ${K8S_MAJOR_MINOR}\|codegen\|kubernetes versions" "$BRANCH_NAME" 2>/dev/null | wc -l)
COMMIT_COUNT="${BRANCH_BASE:-?}"

banner "Phases 0-3 Complete"
echo "Branch:    $BRANCH_NAME"
echo "Target:    k8s $K8S_FULL (API $API_VERSION)"
echo "From:      k8s 1.${OLD_MINOR} (API $OLD_API_VERSION)"
echo "Go:        $OLD_GO_VERSION → $NEW_GO_VERSION"
echo "CR:        ${CR_VERSION:-latest}"
echo "Commits:   $COMMIT_COUNT"
if [[ -s "$GATE_REPORT" ]]; then
  echo "New gates: $(tr '\n' ' ' < "$GATE_REPORT")"
  echo "           Phase 4 will investigate and fix (see $GATE_REPORT)"
fi
echo ""
echo "Next: run Phase 4 (build validation and fixups)"
echo "  ./go-controller/hack/k8s-rebase-validate.sh"
exit 2
