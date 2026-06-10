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
REBASE_TMP="$REPO_ROOT/.rebase-tmp"
mkdir -p "$REBASE_TMP"
grep -qF '.rebase-tmp' "$REPO_ROOT/.git/info/exclude" 2>/dev/null || echo '.rebase-tmp/' >> "$REPO_ROOT/.git/info/exclude"
grep -qF '.config' "$REPO_ROOT/.git/info/exclude" 2>/dev/null || echo '.config/' >> "$REPO_ROOT/.git/info/exclude"
grep -qF '.cache' "$REPO_ROOT/.git/info/exclude" 2>/dev/null || echo '.cache/' >> "$REPO_ROOT/.git/info/exclude"

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
  PRIMARY_GOMOD=$(find . -name "go.mod" -not -path "*/vendor/*" -exec grep -lE "k8s\.io/(api|client-go|apimachinery) " {} \; | head -1 || true)
fi
[[ -z "$PRIMARY_GOMOD" ]] && die "No go.mod with k8s.io dependencies found in $REPO_ROOT"

# Detect version from k8s.io/api, client-go, or apimachinery (in priority order)
OLD_API_VERSION=""
for pkg in "k8s.io/api " "k8s.io/client-go " "k8s.io/apimachinery "; do
  OLD_API_VERSION=$(grep "$pkg" "$PRIMARY_GOMOD" 2>/dev/null | head -1 | awk '{print $2}' || true)
  [[ -n "$OLD_API_VERSION" ]] && break
done
OLD_MINOR=$(echo "$OLD_API_VERSION" | grep -oE 'v0\.[0-9]+' | sed 's/v0\.//' || true)
[[ -z "$OLD_MINOR" ]] && die "Cannot detect current k8s minor from $PRIMARY_GOMOD"
OLD_GO_VERSION=$(grep "^go " "$PRIMARY_GOMOD" | awk '{print $2}')

info "Current: k8s.io/api $OLD_API_VERSION (k8s 1.${OLD_MINOR}), Go $OLD_GO_VERSION"
info "Target:  k8s.io/api $API_VERSION (k8s $K8S_FULL)"

# Idempotency check
if [[ "$OLD_MINOR" == "$K8S_MINOR" ]]; then
  info "Already at k8s 1.${K8S_MINOR} — nothing to do"
  rm -rf "$REBASE_TMP"
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
REQUIRED_GO=$(curl -sf "https://raw.githubusercontent.com/kubernetes/kubernetes/v${K8S_MAJOR}.${K8S_MINOR}.${K8S_PATCH}/go.mod" 2>/dev/null | grep "^go " | awk '{print $2}' || true)
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
    bash "$SCRIPT_PATH" "$VERSION_INPUT"
fi
info "Go version: $CURRENT_GO (>= ${REQUIRED_GO:-any} required)"

# Container setup: git safe.directory for mounted volumes
if [[ "${K8S_REBASE_IN_CONTAINER:-}" == "1" ]]; then
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=safe.directory
  export GIT_CONFIG_VALUE_0="$REPO_ROOT"
fi

# Clean working tree (ignore dirs created by containerized Go)
if [[ -n "$(git status --porcelain | grep -v "^?? \.rebase-tmp/" | grep -v "^?? \.config/" | grep -v "^?? \.cache/")" ]]; then
  die "Working tree is not clean. Commit or stash changes first."
fi

# Discover controller-runtime version — find the latest patch for the computed minor
CR_MINOR=$((K8S_MINOR - 12))
CR_VERSION=""
# Try patch versions from highest to lowest
for patch in 9 8 7 6 5 4 3 2 1 0; do
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

# Create branch (append timestamp if name taken)
BRANCH_NAME="bump${K8S_MAJOR_MINOR}"
if git rev-parse --verify "$BRANCH_NAME" &>/dev/null; then
  BRANCH_NAME="bump${K8S_MAJOR_MINOR}-$(date +%Y%m%d%H%M%S)"
  info "bump${K8S_MAJOR_MINOR} already exists, using $BRANCH_NAME"
fi
git checkout -b "$BRANCH_NAME"
info "Created branch: $BRANCH_NAME"

# ── Derivation function ─────────────────────────────────────────────

derive_go_gets() {
  local gomod="$1"
  local cmds=()

  # Rule 1: version-locked (v{N}.{OLD_MINOR}.* → v{N}.{NEW_MINOR}.*)
  while IFS= read -r line; do
    local pkg ver_prefix
    pkg=$(echo "$line" | awk '{print $1}')
    ver_prefix=$(echo "$line" | grep -oE 'v[0-9]+' | head -1 | sed 's/v//' || true)
    [[ -z "$ver_prefix" ]] && continue
    cmds+=("go get ${pkg}@v${ver_prefix}.${K8S_MINOR}.${K8S_PATCH}")
  done < <(grep -E "k8s\.io/|sigs\.k8s\.io/" "$gomod" | grep -v "=>" | grep -E "v[0-9]+\.${OLD_MINOR}\." | awk '{print $1, $2}' | sort -u)

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
           grep -v "=>" | \
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
  # k8s.io/kubernetes uses local replace directives for staging repos.
  # When bumped, go mod tidy may fail with "unknown revision v0.0.0"
  # for staging deps not yet in go.mod. Retry by resolving each.
  local tidy_attempts=0
  while ! go mod tidy 2>${REBASE_TMP}/tidy.log; do
    local missing_mod
    missing_mod=$(grep "unknown revision v0.0.0" ${REBASE_TMP}/tidy.log | grep -oE 'k8s\.io/[a-z][-a-z]*' | head -1 || true)
    if [[ -z "$missing_mod" ]] || [[ $tidy_attempts -ge 10 ]]; then
      cat ${REBASE_TMP}/tidy.log >&2
      die "go mod tidy failed in $(basename "$gomod" .mod)"
    fi
    info "  Resolving staging dep: ${missing_mod}@${API_VERSION}"
    go get "${missing_mod}@${API_VERSION}" 2>/dev/null || true
    tidy_attempts=$((tidy_attempts + 1))
  done

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
      git commit -s -m "Sync ${mod_dir} go.mod after dependency rebase"
      info "Committed: Sync ${mod_dir} go.mod after dependency rebase"
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

  # Update code-generator version pin (handles both printf %s and explicit tool names)
  sed -i -E "s|(code-generator/cmd/[^@]+)@v0\.[0-9]+\.[0-9]+|\1@${API_VERSION}|g" "$CODEGEN_SCRIPT"
  info "Updated code-generator version to ${API_VERSION}"
elif grep -qE "^(generate|manifests):" "$REPO_ROOT/Makefile" 2>/dev/null; then
  banner "Phase 2: Code Generation (make)"

  # controller-gen projects use make generate/manifests instead of
  # hack/update-codegen.sh. Run both if available.
  CODEGEN_RAN=0
  CODEGEN_FAILED=0
  CODEGEN_LOG="$REBASE_TMP/codegen.log"
  for target in generate manifests; do
    if grep -q "^${target}:" "$REPO_ROOT/Makefile"; then
      info "Running make $target..."
      if make -C "$REPO_ROOT" "$target" >> "$CODEGEN_LOG" 2>&1; then
        CODEGEN_RAN=1
      else
        info "WARNING: make $target failed — Phase 4 will fix"
        CODEGEN_FAILED=1
      fi
    fi
  done

  cd "$REPO_ROOT"
  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    git commit -s -m "Regenerate code and manifests for k8s ${K8S_MAJOR_MINOR}"
    info "Committed: Regenerate code and manifests for k8s ${K8S_MAJOR_MINOR}"
  fi

  if [[ "$CODEGEN_FAILED" -eq 1 ]]; then
    echo "## CODEGEN FAILURE" >> "$REBASE_TMP/summary.txt"
    tail -5 "$CODEGEN_LOG" >> "$REBASE_TMP/summary.txt"
    echo "" >> "$REBASE_TMP/summary.txt"
  fi

  # Run codegen — try common make targets
  CODEGEN_DIR=$(dirname "$(dirname "$CODEGEN_SCRIPT")")
  CODEGEN_RAN=0
  CODEGEN_FAILED=0
  CODEGEN_LOG="$REBASE_TMP/codegen.log"
  for target in codegen generate update-codegen; do
    if make -n -C "$CODEGEN_DIR" "$target" &>/dev/null; then
      info "Running make $target in $CODEGEN_DIR..."
      if make -C "$CODEGEN_DIR" "$target" > "$CODEGEN_LOG" 2>&1; then
        CODEGEN_RAN=1
      else
        info "WARNING: make $target failed — Phase 4 will fix codegen script"
        CODEGEN_FAILED=1
      fi
      break
    fi
  done
  if [[ "$CODEGEN_RAN" -eq 0 ]] && [[ "$CODEGEN_FAILED" -eq 0 ]]; then
    info "WARNING: No codegen/generate make target found, running script directly..."
    if ! bash "$CODEGEN_SCRIPT" > "$CODEGEN_LOG" 2>&1; then
      info "WARNING: codegen script failed — Phase 4 will fix codegen script"
      CODEGEN_FAILED=1
    fi
  fi

  cd "$REPO_ROOT"
  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    git commit -s -m "Update codegen for k8s ${K8S_MAJOR_MINOR}"
    info "Committed: Update codegen for k8s ${K8S_MAJOR_MINOR}"
  fi

  if [[ "$CODEGEN_FAILED" -eq 1 ]]; then
    # Auto-fix common codegen failures (dropped flags) and retry
    if grep -q 'unknown flag\|flag provided but not defined' "$CODEGEN_LOG" 2>/dev/null; then
      # Extract the unknown flag name and remove it from the codegen script
      bad_flag=$(grep -oE '(unknown flag|flag provided but not defined): --[a-zA-Z0-9_-]+' "$CODEGEN_LOG" | head -1 | sed 's/.*--//' || true)
      if [[ -n "$bad_flag" ]] && grep -q "\-\-${bad_flag}" "$CODEGEN_SCRIPT"; then
        info "Removing dropped flag --${bad_flag} from codegen script and retrying"
        sed -i "/^[[:space:]]*--${bad_flag}/d" "$CODEGEN_SCRIPT"
        git add "$CODEGEN_SCRIPT"
        git commit -s -m "Remove deprecated --${bad_flag} flag from codegen"
        # Retry codegen
        if make -C "$CODEGEN_DIR" "$target" > "$CODEGEN_LOG" 2>&1 || bash "$CODEGEN_SCRIPT" > "$CODEGEN_LOG" 2>&1; then
          info "Codegen succeeded after removing --${bad_flag}"
          CODEGEN_FAILED=0
          cd "$REPO_ROOT"
          if [[ -n "$(git status --porcelain)" ]]; then
            git add -A
            git commit -s -m "Regenerate code after codegen fix for k8s ${K8S_MAJOR_MINOR}"
          fi
        fi
      fi
    fi
    if [[ "$CODEGEN_FAILED" -eq 1 ]]; then
      echo "## CODEGEN FAILURE" >> "$REBASE_TMP/summary.txt"
      tail -5 "$CODEGEN_LOG" >> "$REBASE_TMP/summary.txt"
      echo "Fix the codegen script (e.g. removed flags) and re-run codegen." >> "$REBASE_TMP/summary.txt"
      echo "" >> "$REBASE_TMP/summary.txt"
    fi
  fi

  # Regenerate mocks if codegen deleted them (rm -rf pkg/crd/*/apis
  # removes mocks/ subdirectories). Runs inside this container so
  # file ownership is correct (podman --userns=keep-id).
  if [[ "$CODEGEN_FAILED" -eq 0 ]] && [[ -f "$CODEGEN_DIR/.mockery.yaml" ]]; then
    if ! find "$CODEGEN_DIR/pkg/crd" -name "mocks" -type d 2>/dev/null | grep -q .; then
      info "Codegen deleted mock directories — running mockery..."
      if make -C "$CODEGEN_DIR" mocksgen 2>/dev/null; then
        cd "$REPO_ROOT"
        if [[ -n "$(git status --porcelain)" ]]; then
          git add -A
          git commit -s -m "Regenerate mocks after codegen for k8s ${K8S_MAJOR_MINOR}"
          info "Committed: Regenerate mocks after codegen"
        fi
      else
        info "WARNING: mockery failed — Phase 4 agent will regenerate mocks"
      fi
    fi
  fi
else
  info "No codegen script found, skipping Phase 2"
fi

# ── Phase 3: Version Reference Updates ───────────────────────────────

banner "Phase 3: Version Reference Updates"

NEW_K8S_FULL="${K8S_FULL}"
OLD_SHORT="${K8S_MAJOR}.${OLD_MINOR}"
NEW_SHORT="${K8S_MAJOR_MINOR}"
CHANGED_FILES=""

# Pass 1: v-prefixed versions in CI, scripts, docs (v1.35.0, v1.35)
# Two-stage sed: patch form first (v1.35.X → v1.36.0), then bare (v1.35 → v1.36)
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  sed -i -E "s|v${K8S_MAJOR}\.${OLD_MINOR}\.[0-9]+|${NEW_K8S_FULL}|g; s|v${K8S_MAJOR}\.${OLD_MINOR}\b|v${NEW_SHORT}|g" "$file"
  CHANGED_FILES+="$file"$'\n'
  info "  Updated: $file"
done < <(grep -rln -E "v${K8S_MAJOR}\.${OLD_MINOR}(\.[0-9]+)?\b" \
  --include="*.yml" --include="*.yaml" --include="*.sh" \
  --include="*.md" --include="Makefile*" --include="Dockerfile*" . \
  | grep -v vendor | grep -v "/\.git/" | grep -v go.mod || true)

# Pass 2: bare version in doc prose (1.35 without v-prefix)
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  sed -i -E "s/\b${OLD_SHORT//./\\.}\b/${NEW_SHORT}/g" "$file"
  CHANGED_FILES+="$file"$'\n'
  info "  Updated (short): $file"
done < <(grep -rln "\b${OLD_SHORT}\b" --include="*.md" docs/ 2>/dev/null | grep -v vendor || true)

# Go version update (if changed)
NEW_GO_VERSION=$(grep "^go " "$PRIMARY_GOMOD" | awk '{print $2}')
if [[ "$OLD_GO_VERSION" != "$NEW_GO_VERSION" ]]; then
  info "Go version changed: $OLD_GO_VERSION → $NEW_GO_VERSION"
  OLD_GO_SHORT=$(echo "$OLD_GO_VERSION" | grep -oE '[0-9]+\.[0-9]+')
  NEW_GO_SHORT=$(echo "$NEW_GO_VERSION" | grep -oE '[0-9]+\.[0-9]+')

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    sed -i "s|golang:${OLD_GO_SHORT}|golang:${NEW_GO_SHORT}|g; s|golang-${OLD_GO_SHORT}|golang-${NEW_GO_SHORT}|g; s|GO_VERSION ?= ${OLD_GO_SHORT}|GO_VERSION ?= ${NEW_GO_SHORT}|g; s|GOLANG_VERSION ?= ${OLD_GO_SHORT}|GOLANG_VERSION ?= ${NEW_GO_SHORT}|g; s|go-version: \[${OLD_GO_SHORT}|go-version: [${NEW_GO_SHORT}|g; s|go-version: ${OLD_GO_SHORT}|go-version: ${NEW_GO_SHORT}|g; s|GO_VERSION: \"${OLD_GO_SHORT}\"|GO_VERSION: \"${NEW_GO_SHORT}\"|g" "$file"
    CHANGED_FILES+="$file"$'\n'
    info "  Updated Go version: $file"
  done < <(grep -rlnE "golang[:-]${OLD_GO_SHORT}|GO_VERSION.{0,5}${OLD_GO_SHORT}|GOLANG_VERSION.{0,5}${OLD_GO_SHORT}|go-version:.{0,3}${OLD_GO_SHORT}" \
    --include="*.yml" --include="*.yaml" --include="Makefile*" \
    --include="Dockerfile*" . \
    | grep -v vendor | grep -v "/\.git/" | grep -v go.mod || true)

  # Bump golangci-lint version in lint scripts when Go version changes
  LATEST_LINT=$(curl -sf "https://api.github.com/repos/golangci/golangci-lint/releases/latest" 2>/dev/null | grep -oE '"tag_name": "[^"]+"' | sed 's/"tag_name": "//;s/"//' || true)
  if [[ -n "$LATEST_LINT" ]]; then
    while IFS= read -r lintscript; do
      [[ -z "$lintscript" ]] && continue
      OLD_LINT=$(grep -oE 'VERSION=v[0-9]+\.[0-9]+\.[0-9]+' "$lintscript" | head -1 | sed 's/VERSION=//' || true)
      if [[ -n "$OLD_LINT" ]] && [[ "$OLD_LINT" != "$LATEST_LINT" ]]; then
        sed -i "s|VERSION=${OLD_LINT}|VERSION=${LATEST_LINT}|g" "$lintscript"
        CHANGED_FILES+="$lintscript"$'\n'
        info "  Updated golangci-lint: $OLD_LINT → $LATEST_LINT in $lintscript"
      fi
    done < <(grep -rln "golangci-lint" --include="*.sh" . | grep -v vendor | grep -v "/\.git/" || true)
    # Also bump GOLANGCI_LINT_VERSION in Makefiles.
    # If the Makefile uses the v1 import path, use latest v1 (not v2).
    while IFS= read -r mkfile; do
      [[ -z "$mkfile" ]] && continue
      OLD_MK_LINT=$(grep -oE 'GOLANGCI_LINT_VERSION\s*[:?]?=\s*v[0-9]+\.[0-9]+\.[0-9]+' "$mkfile" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
      [[ -z "$OLD_MK_LINT" ]] && continue
      target_lint="$LATEST_LINT"
      if [[ "$OLD_MK_LINT" == v1.* ]] && [[ "$LATEST_LINT" == v2.* ]]; then
        target_lint=$(curl -sf "https://api.github.com/repos/golangci/golangci-lint/releases?per_page=50" 2>/dev/null | grep -oE '"tag_name": "v1\.[^"]+"' | head -1 | sed 's/"tag_name": "//;s/"//' || true)
        [[ -z "$target_lint" ]] && target_lint="$OLD_MK_LINT"
      fi
      if [[ "$OLD_MK_LINT" != "$target_lint" ]]; then
        sed -i "s|${OLD_MK_LINT}|${target_lint}|g" "$mkfile"
        CHANGED_FILES+="$mkfile"$'\n'
        info "  Updated golangci-lint: $OLD_MK_LINT → $target_lint in $mkfile"
      fi
    done < <(grep -rln "GOLANGCI_LINT_VERSION" --include="Makefile*" . | grep -v vendor | grep -v "/\.git/" || true)
  fi
fi

cd "$REPO_ROOT"
# Add only the files we modified (more precise than git add -A)
if [[ -n "$CHANGED_FILES" ]]; then
  echo "$CHANGED_FILES" | while IFS= read -r f; do
    [[ -n "$f" ]] && git add "$f" 2>/dev/null || true
  done
  if [[ -n "$(git status --porcelain)" ]]; then
    git commit -s -m "$(cat <<EOF
Update version references for k8s ${K8S_MAJOR_MINOR}

${CHANGED_FILES}
EOF
)"
    info "Committed: Update version references for k8s ${K8S_MAJOR_MINOR}"
  fi
fi

# ── Phase 3b: Detect new feature gates (info only) ────────────────
# Scans vendored feature gate definitions for new default-true gates.
# The autofix (Phase 4 Step 2) handles disabling via GATE_DEPS —
# this is informational logging only.

KNOWN_FEATURES=$(find . -path "*/k8s.io/client-go/features/known_features.go" -not -path "*/.git/*" | head -1 || true)
NEW_GATES=()

if [[ -n "$KNOWN_FEATURES" ]]; then
  while IFS= read -r gate; do
    [[ -z "$gate" ]] && continue
    NEW_GATES+=("$gate")
  done < <(awk '
    /^\t[A-Z][a-zA-Z0-9]*Feature = / { gate = $1 }
    /^\t[A-Z][a-zA-Z0-9]*: \{/ { gsub(/:.*/, "", $1); gate = $1 }
    !/\/\// && /Default: true/ && /MustParse\("1\.'"${K8S_MINOR}"'"\)/ { print gate }
  ' "$KNOWN_FEATURES" | sort -u)

  if [[ ${#NEW_GATES[@]} -gt 0 ]]; then
    info "New default-true feature gates in k8s 1.${K8S_MINOR}: ${NEW_GATES[*]}"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────

banner "Phases 0-3 Complete"
echo "Branch:    $BRANCH_NAME"
echo "Target:    k8s $K8S_FULL (API $API_VERSION)"
echo "From:      k8s 1.${OLD_MINOR} (API $OLD_API_VERSION)"
echo "Go:        $OLD_GO_VERSION → $NEW_GO_VERSION"
echo "CR:        ${CR_VERSION:-latest}"
if [[ ${#NEW_GATES[@]} -gt 0 ]]; then
  echo "New gates: ${NEW_GATES[*]}"
fi
echo ""
echo "Next: proceed to Phase 4 (build validation and fixups)"
exit 2
