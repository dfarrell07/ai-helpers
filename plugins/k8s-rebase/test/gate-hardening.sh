#!/bin/bash
# gate-hardening.sh — Test gate sensitivity by reverting autofix commits
# and verifying the corresponding gate catches the regression.
#
# Uses FIX_DESC from autofix.sh as the source of truth for Applied: trailers,
# avoiding the duplication problem of maintaining a separate function→gate map.
#
# Usage: gate-hardening.sh <fix-tag> <repo>
#        gate-hardening.sh --list
#
# Examples:
#   gate-hardening.sh xexp ~/ovnk/ovn-org/ovn-kubernetes
#   gate-hardening.sh feature_gates ~/ovnk/openshift/multus-cni
#   gate-hardening.sh --list

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$PLUGIN_DIR/../.." && pwd)/.work/test-harness}"
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
GATE_CHECK_TIMEOUT="${GATE_CHECK_TIMEOUT:-300}"

info()  { echo ":: $*"; }
warn()  { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }
repo_short() { local p="${1%/}"; echo "${p/#$HOME\/ovnk\//}"; }

_cleanup_head=""
_cleanup_repo=""
trap '
  if [[ -n "$_cleanup_repo" ]]; then
    warn "Interrupted — restoring $(repo_short "$_cleanup_repo")"
    git -C "$_cleanup_repo" reset --hard "${_cleanup_head:-HEAD}" 2>/dev/null || true
    git -C "$_cleanup_repo" clean -fd 2>/dev/null || true
  fi
' EXIT

default_branch() {
  local b
  b=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  [[ -z "$b" ]] && b="main"
  git rev-parse --verify "$b" &>/dev/null || b="master"
  echo "$b"
}

# Maps fix tags (FIX_DESC keys) to the gate that should detect their absence.
# Tags match what autofix.sh writes in Applied: trailers.
declare -A TAG_TO_GATE=(
  [crd_int64_validation]="step3-autofix/crd-validation.md"
  [crd_name_validation]="step3-autofix/crd-validation.md"
  [network_policy_api_crds]="step3-autofix/crd-validation.md"
  [feature_gates]="step3-autofix/feature-gates.md"
  [xexp]="step3-autofix/deprecated-api-remnants.md"
  [reflect_ptr]="step3-autofix/deprecated-api-remnants.md"
  [fieldsv1]="step3-autofix/deprecated-api-remnants.md"
  [klog_v2]="step3-autofix/deprecated-api-remnants.md"
  [eventf]="step3-autofix/deprecated-api-remnants.md"
  [imports]="step3-autofix/deprecated-api-remnants.md"
  [bounding_dirs]="step3-autofix/deprecated-api-remnants.md"
  [obsgen]="step3-autofix/patterns-completeness.md"
  [conformance_renames]="step3-autofix/patterns-completeness.md"
  [banp_egresspeer]="step3-autofix/patterns-completeness.md"
  [addtoscheme]="step3-autofix/patterns-completeness.md"
  [mocks]="step3-autofix/patterns-completeness.md"
  [kind_image]="step4-verification/ci-prediction.md"
  [lint_version]="step4-verification/ci-prediction.md"
  [kind_version]="step4-verification/ci-prediction.md"
  [metallb_version]="step4-verification/ci-prediction.md"
  [kubevirt_version]="step4-verification/ci-prediction.md"
  [relaxed_service_name_validation]="step4-verification/ci-prediction.md"
  [kubeadm_v1beta4]="step4-verification/ci-prediction.md"
  [docs_version]="step4-verification/version-completeness.md"
  [version_refs]="step4-verification/version-completeness.md"
  [go_version]="step4-verification/go-version-check.md"
)

# Load FIX_DESC from autofix.sh to get human-readable trailer descriptions.
# We parse it rather than source it to avoid executing the autofix main body.
declare -A FIX_DESC=()
load_fix_desc() {
  local autofix="$PLUGIN_DIR/scripts/k8s-rebase-autofix.sh"
  [[ -f "$autofix" ]] || die "Cannot find autofix script: $autofix"
  local in_desc=false
  while IFS= read -r line; do
    if [[ "$line" =~ ^declare.*FIX_DESC ]]; then
      in_desc=true; continue
    fi
    if $in_desc; then
      [[ "$line" =~ ^\) ]] && break
      if [[ "$line" =~ \[([a-z0-9_]+)\]=\"(.+)\" ]]; then
        FIX_DESC["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
      fi
    fi
  done < "$autofix"
  [[ ${#FIX_DESC[@]} -eq 0 ]] && die "Failed to parse FIX_DESC from $autofix"
}

cmd_list() {
  load_fix_desc
  printf "%-30s %-50s %s\n" "TAG" "DESCRIPTION" "GATE"
  printf "%-30s %-50s %s\n" "---" "-----------" "----"
  for tag in $(printf '%s\n' "${!TAG_TO_GATE[@]}" | sort); do
    printf "%-30s %-50s %s\n" "$tag" "${FIX_DESC[$tag]:-?}" "${TAG_TO_GATE[$tag]}"
  done
}

cmd_check() {
  command -v claude &>/dev/null || die "claude CLI not found in PATH"
  local tag="$1" repo="$2"

  [[ -z "${TAG_TO_GATE[$tag]+x}" ]] && die "Unknown fix tag: $tag (run --list to see available)"

  load_fix_desc
  local desc="${FIX_DESC[$tag]:-$tag}"
  local gate_file="$PLUGIN_DIR/gates/${TAG_TO_GATE[$tag]}"
  [[ -f "$gate_file" ]] || die "Gate not found: $gate_file"

  cd "$repo" || die "Cannot cd to $repo"
  git rev-parse --git-dir &>/dev/null || die "Not a git repository: $repo"
  local short branch default_br
  short=$(repo_short "$repo")
  branch=$(git branch --show-current 2>/dev/null)

  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && die "Dirty worktree in $repo — commit or stash first"
  [[ -z "$branch" ]] && die "Detached HEAD — checkout a rebase branch first"
  [[ "$branch" =~ ^(main|master)$ ]] && die "On $branch — checkout a rebase branch first"

  default_br=$(default_branch)

  info "── Gate hardening: $tag ($desc) on $short ──"

  # Search for the Applied: trailer using the FIX_DESC description
  local commit
  commit=$( { git log "origin/$default_br".."$branch" --format='%H' --fixed-strings --grep="Applied: $desc" 2>/dev/null \
    || git log "$default_br".."$branch" --format='%H' --fixed-strings --grep="Applied: $desc" 2>/dev/null; } | head -1)
  # Fallback: try the raw tag (autofix uses tag when FIX_DESC is missing)
  [[ -z "$commit" ]] && commit=$( { git log "origin/$default_br".."$branch" --format='%H' --fixed-strings --grep="Applied: $tag" 2>/dev/null \
    || git log "$default_br".."$branch" --format='%H' --fixed-strings --grep="Applied: $tag" 2>/dev/null; } | head -1)
  [[ -z "$commit" ]] && { info "SKIP: no Applied: trailer for '$desc' (autofix may not have fired on this repo)"; return 0; }

  local original_head
  original_head=$(git rev-parse HEAD)
  _cleanup_repo="$repo"
  _cleanup_head="$original_head"
  info "Reverting $(git log --oneline -1 "$commit")"
  if ! git revert --no-commit "$commit" 2>/dev/null; then
    info "SKIP: revert conflicts (later commits modified the same files)"
    git revert --abort 2>/dev/null || git reset --hard "$original_head" 2>/dev/null
    _cleanup_repo="" _cleanup_head=""
    return 0
  fi

  info "Running gate: ${TAG_TO_GATE[$tag]}"
  mkdir -p "$RESULTS_DIR/gate-check" 2>/dev/null
  local outfile="$RESULTS_DIR/gate-check/${tag}-$(basename "$repo")-$(date +%s).txt"

  local gate_content
  gate_content=$(sed '/^After your analysis, write your report\. The repo path/,$d' "$gate_file")
  if [[ -z "$gate_content" ]]; then
    git reset --hard "$original_head" 2>/dev/null
    _cleanup_repo="" _cleanup_head=""
    die "Gate content empty after stripping report section"
  fi

  local prompt
  prompt=$(printf 'Repo: %s\n\n%s\n\n%s' \
    "$repo" "$gate_content" \
    "After your analysis, end with exactly one of these on its own line:
VERDICT: ISSUES_FOUND
VERDICT: CLEAN")

  local output exit_code=0
  output=$(timeout -k 10 "$GATE_CHECK_TIMEOUT" bash -c \
    'printf "%s" "$1" | claude -p --permission-mode "$2" --output-format text 2>/dev/null' \
    _ "$prompt" "$PERMISSION_MODE") || exit_code=$?

  git reset --hard "$original_head" 2>/dev/null || warn "git reset failed — repo may be dirty"
  git clean -fd 2>/dev/null || true
  _cleanup_repo="" _cleanup_head=""

  if [[ "$exit_code" -eq 124 ]]; then
    error "TIMEOUT: gate exceeded ${GATE_CHECK_TIMEOUT}s"
    echo "TIMEOUT after ${GATE_CHECK_TIMEOUT}s" > "$outfile" 2>/dev/null
    return 1
  fi
  if [[ -z "$output" ]]; then
    error "EMPTY: claude -p returned no output"
    echo "EMPTY OUTPUT" > "$outfile" 2>/dev/null
    return 1
  fi

  echo "$output" > "$outfile" 2>/dev/null
  echo "$output" | tail -15
  echo ""

  local verdict
  verdict=$(echo "$output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -oE '^VERDICT: (ISSUES_FOUND|CLEAN)$' | tail -1)

  case "$verdict" in
    "VERDICT: ISSUES_FOUND")
      info "PASS: gate caught '$desc' (output: $outfile)" ;;
    "VERDICT: CLEAN")
      error "FAIL: gate missed '$desc' (output: $outfile)"; return 1 ;;
    *)
      error "INCONCLUSIVE: no VERDICT line (output: $outfile)"; return 1 ;;
  esac
}

# ── Main ──

case "${1:-}" in
  --list|-l) cmd_list ;;
  --help|-h) echo "Usage: $(basename "$0") <fix-tag> <repo>"; echo "       $(basename "$0") --list"; exit 0 ;;
  "") echo "Usage: $(basename "$0") <fix-tag> <repo>"; echo "       $(basename "$0") --list"; exit 1 ;;
  *) [[ $# -lt 2 ]] && die "Usage: $(basename "$0") <fix-tag> <repo>"
     cmd_check "$1" "$2" ;;
esac
