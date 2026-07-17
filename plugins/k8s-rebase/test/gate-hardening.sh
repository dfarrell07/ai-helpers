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

cleanup_head=""
cleanup_repo=""
trap '
  if [[ -n "$cleanup_repo" ]]; then
    warn "Interrupted — restoring $(repo_short "$cleanup_repo")"
    git -C "$cleanup_repo" reset --hard "${cleanup_head:-HEAD}" 2>/dev/null || true
    git -C "$cleanup_repo" clean -fd 2>/dev/null || true
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
  local tag="$1" repo="$2" gate_override="${3:-}"

  [[ -z "${TAG_TO_GATE[$tag]+x}" ]] && die "Unknown fix tag: $tag (run --list to see available)"

  load_fix_desc
  local desc="${FIX_DESC[$tag]:-$tag}"
  local gate_file="${gate_override:-$PLUGIN_DIR/gates/${TAG_TO_GATE[$tag]}}"
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

  # Search for Applied: trailer. Try description first (e.g., "Applied: disable
  # problematic feature gates"), then tag (e.g., "Applied: feature_gates" or within
  # comma-joined "Applied: xexp, reflect_ptr, feature_gates").
  local commit range
  range="origin/${default_br}..${branch}"
  git rev-parse --verify "origin/$default_br" &>/dev/null || range="${default_br}..${branch}"
  commit=$(git log "$range" --format='%H' --fixed-strings --grep="$desc" 2>/dev/null | head -1)
  [[ -z "$commit" ]] && commit=$(git log "$range" --format='%H' --fixed-strings --grep="$tag" 2>/dev/null | head -1)
  [[ -z "$commit" ]] && { info "SKIP: no Applied: trailer for '$tag' ($desc)"; return 0; }

  local original_head
  original_head=$(git rev-parse HEAD)
  cleanup_repo="$repo"
  cleanup_head="$original_head"
  info "Reverting $(git log --oneline -1 "$commit")"
  if ! git revert --no-commit "$commit" 2>/dev/null; then
    info "SKIP: revert conflicts (later commits modified the same files)"
    git revert --abort 2>/dev/null || git reset --hard "$original_head" 2>/dev/null
    cleanup_repo="" cleanup_head=""
    return 0
  fi

  info "Running gate: ${TAG_TO_GATE[$tag]}"
  mkdir -p "$RESULTS_DIR/gate-check" 2>/dev/null
  local outfile
  outfile="$RESULTS_DIR/gate-check/${tag}-$(basename "$repo")-$(date +%s).txt"

  local gate_content
  gate_content=$(sed '/^After your analysis, write your report\. The repo path/,$d' "$gate_file")
  if [[ -z "$gate_content" ]]; then
    git reset --hard "$original_head" 2>/dev/null
    cleanup_repo="" cleanup_head=""
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
  cleanup_repo="" cleanup_head=""

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

cmd_vs() {
  local tag="$1" candidate="$2" repo="$3"
  [[ -f "$candidate" ]] || die "Candidate gate file not found: $candidate"

  local current_gate="$PLUGIN_DIR/gates/${TAG_TO_GATE[$tag]}"
  info "── A/B: $tag on $(repo_short "$repo") ──"
  info "Gate A: ${TAG_TO_GATE[$tag]} (current)"
  info "Gate B: $candidate"
  echo ""

  info "Running Gate A..."
  local result_a
  result_a=$(cmd_check "$tag" "$repo" 2>&1) && rc_a=0 || rc_a=$?
  local verdict_a="INCONCLUSIVE"
  echo "$result_a" | grep -q "PASS:" && verdict_a="PASS"
  echo "$result_a" | grep -q "FAIL:" && verdict_a="FAIL"
  echo "$result_a" | grep -q "SKIP:" && verdict_a="SKIP"

  if [[ "$verdict_a" == "SKIP" ]]; then
    info "SKIP: cannot A/B test — no Applied: trailer for this tag on this repo"
    return 0
  fi

  echo ""
  info "Running Gate B..."
  local result_b
  result_b=$(cmd_check "$tag" "$repo" "$candidate" 2>&1) && rc_b=0 || rc_b=$?
  local verdict_b="INCONCLUSIVE"
  echo "$result_b" | grep -q "PASS:" && verdict_b="PASS"
  echo "$result_b" | grep -q "FAIL:" && verdict_b="FAIL"

  echo ""
  info "── Results ──"
  printf "%-12s %-15s %s\n" "" "VERDICT" "GATE"
  printf "%-12s %-15s %s\n" "Gate A:" "$verdict_a" "${TAG_TO_GATE[$tag]}"
  printf "%-12s %-15s %s\n" "Gate B:" "$verdict_b" "$candidate"

  if [[ "$verdict_a" == "$verdict_b" ]]; then
    info "Both gates agree: $verdict_a"
  elif [[ "$verdict_a" == "PASS" && "$verdict_b" != "PASS" ]]; then
    warn "Gate A caught the regression, Gate B did not — current gate is better"
  elif [[ "$verdict_b" == "PASS" && "$verdict_a" != "PASS" ]]; then
    info "Gate B caught the regression, Gate A did not — candidate is better"
  fi
}

cmd_all() {
  local repo="$1"
  [[ -d "$repo" ]] || die "Not found: $repo"
  cd "$repo" || die "Cannot cd to $repo"
  git rev-parse --git-dir &>/dev/null || die "Not a git repository: $repo"

  local branch default_br range
  branch=$(git branch --show-current 2>/dev/null)
  [[ -z "$branch" ]] && die "Detached HEAD — checkout a rebase branch first"
  [[ "$branch" =~ ^(main|master)$ ]] && die "On $branch — checkout a rebase branch first"
  default_br=$(default_branch)
  range="origin/${default_br}..${branch}"
  git rev-parse --verify "origin/$default_br" &>/dev/null || range="${default_br}..${branch}"

  load_fix_desc
  local pass=0 fail=0 skip=0 total=0

  info "── Sweep: $(repo_short "$repo") ($branch) ──"
  printf "%-30s %-8s %s\n" "TAG" "RESULT" "DETAILS"
  printf "%-30s %-8s %s\n" "---" "------" "-------"

  for tag in $(printf '%s\n' "${!TAG_TO_GATE[@]}" | sort); do
    total=$((total + 1))
    local desc="${FIX_DESC[$tag]:-$tag}"

    # Check if this tag has an Applied: trailer on this branch
    local has_trailer=false
    git log "$range" --format='%b' --fixed-strings --grep="$desc" 2>/dev/null | grep -qF "Applied:" && has_trailer=true
    if ! $has_trailer; then
      git log "$range" --format='%b' --fixed-strings --grep="$tag" 2>/dev/null | grep -qF "Applied:" && has_trailer=true
    fi

    if ! $has_trailer; then
      printf "%-30s %-8s %s\n" "$tag" "SKIP" "no Applied: trailer"
      skip=$((skip + 1))
      continue
    fi

    # Run cmd_check in a subshell so die doesn't kill the sweep
    local result
    result=$( cmd_check "$tag" "$repo" 2>&1 ) && rc=0 || rc=$?
    if echo "$result" | grep -q "PASS:"; then
      printf "%-30s %-8s %s\n" "$tag" "PASS" "gate caught regression"
      pass=$((pass + 1))
    elif echo "$result" | grep -q "FAIL:"; then
      printf "%-30s %-8s %s\n" "$tag" "FAIL" "gate missed regression"
      fail=$((fail + 1))
    elif echo "$result" | grep -q "SKIP:"; then
      printf "%-30s %-8s %s\n" "$tag" "SKIP" "$(echo "$result" | grep "SKIP:" | head -1 | sed 's/.*SKIP: //')"
      skip=$((skip + 1))
    else
      printf "%-30s %-8s %s\n" "$tag" "ERROR" "unexpected output"
      fail=$((fail + 1))
    fi
  done

  echo ""
  info "Summary: $pass PASS, $fail FAIL, $skip SKIP (of $total tags)"
  [[ "$fail" -gt 0 ]] && return 1
  return 0
}

# Maps tags to their ### heading in patterns.md (for --without pattern:)
declare -A TAG_TO_PATTERN=(
  [xexp]="golang.org/x/exp"
  [reflect_ptr]="Deprecated stdlib/apimachinery symbols"
  [fieldsv1]="Deprecated stdlib/apimachinery symbols"
  [klog_v2]="Deprecated stdlib/apimachinery symbols"
  [eventf]="Deprecated stdlib/apimachinery symbols"
  [imports]="Deprecated stdlib/apimachinery symbols"
  [bounding_dirs]="deepcopy-gen --bounding-dirs removed"
  [obsgen]="WithConditions + ObservedGeneration"
  [banp_egresspeer]="EgressPeer type divergence"
  [conformance_renames]="Conformance suite rename"
  [addtoscheme]="Install"
  [mocks]="Deprecated stdlib/apimachinery symbols"
  [crd_int64_validation]="Project CRD int64 validation"
  [crd_name_validation]="CRD metadata.name validation"
  [network_policy_api_crds]="MetalLB CRD validation"
  [feature_gates]="RelaxedServiceNameValidation"
  [kind_image]="E2e framework changes"
  [kind_version]="E2e framework changes"
  [metallb_version]="MetalLB CRD validation"
  [kubevirt_version]="KubeVirt version incompatibility"
  [relaxed_service_name_validation]="RelaxedServiceNameValidation"
  [kubeadm_v1beta4]="kubeadm v1beta4 format"
  [docs_version]="Deprecated stdlib/apimachinery symbols"
  [version_refs]="Deprecated stdlib/apimachinery symbols"
  [go_version]="E2e framework changes"
  [lint_version]="golangci-lint"
)

mutate_plugin() {
  local label="mutated-$(date +%s)"
  local dest="$RESULTS_DIR/$label"
  cp -r "$PLUGIN_DIR" "$dest" || die "Cannot copy plugin to $dest"

  # Dedup specs
  local -A seen_specs=()
  local specs=()
  for spec in "$@"; do
    [[ -n "${seen_specs[$spec]+x}" ]] && continue
    seen_specs[$spec]=1
    specs+=("$spec")
  done

  local has_all=false
  for spec in "${specs[@]}"; do
    [[ "$spec" == "all" ]] && has_all=true
  done

  for spec in "${specs[@]}"; do
    case "$spec" in
      pattern:*)
        $has_all && continue
        local key="${spec#pattern:}"
        local heading="${TAG_TO_PATTERN[$key]:-}"
        [[ -z "$heading" ]] && { rm -rf "$dest"; die "Unknown pattern key: $key"; }
        local pfile="$dest/docs/k8s-rebase-patterns.md"
        if ! grep -q "^### .*$heading" "$pfile" 2>/dev/null; then
          rm -rf "$dest"; die "Pattern heading '$heading' not found in patterns.md"
        fi
        sed -i "/^### .*${heading}/,/^### /{/^### .*${heading}/d; /^### /!d}" "$pfile"
        info "Removed pattern: $heading"
        ;;
      fn:*)
        $has_all && continue
        local ftag="${spec#fn:}"
        local afile="$dest/scripts/k8s-rebase-autofix.sh"
        if ! grep -q "^fix_${ftag}()" "$afile" 2>/dev/null; then
          rm -rf "$dest"; die "Function fix_${ftag}() not found in autofix.sh"
        fi
        awk -v fn="fix_${ftag}" '
          $0 ~ "^"fn"\\(\\)" { print $0; print "  return 0"; skip=1; next }
          skip && /^\}/ { print; skip=0; next }
          skip { next }
          { print }
        ' "$afile" > "$afile.tmp" && mv "$afile.tmp" "$afile"
        info "Neutered function: fix_${ftag}()"
        ;;
      all-patterns)
        $has_all && continue
        local pfile="$dest/docs/k8s-rebase-patterns.md"
        sed -i '/^### /,$ { /^## /!d }' "$pfile"
        info "Removed all pattern sections"
        ;;
      all-fns)
        $has_all && continue
        local afile="$dest/scripts/k8s-rebase-autofix.sh"
        awk '
          /^fix_[a-z0-9_]+\(\)/ && !/fix_uncommitted/ { print $0; print "  return 0"; skip=1; next }
          skip && /^\}/ { print; skip=0; next }
          skip { next }
          { print }
        ' "$afile" > "$afile.tmp" && mv "$afile.tmp" "$afile"
        info "Neutered all fix functions"
        ;;
      all)
        local pfile="$dest/docs/k8s-rebase-patterns.md"
        local afile="$dest/scripts/k8s-rebase-autofix.sh"
        sed -i '/^### /,$ { /^## /!d }' "$pfile"
        awk '
          /^fix_[a-z0-9_]+\(\)/ && !/fix_uncommitted/ { print $0; print "  return 0"; skip=1; next }
          skip && /^\}/ { print; skip=0; next }
          skip { next }
          { print }
        ' "$afile" > "$afile.tmp" && mv "$afile.tmp" "$afile"
        info "Removed all patterns and neutered all fix functions"
        ;;
      *) rm -rf "$dest"; die "Unknown spec: $spec (use pattern:<key>, fn:<tag>, all-patterns, all-fns, all)" ;;
    esac
  done

  # Patch SKILL.md find commands to use the mutated plugin directory
  local skillfile="$dest/skills/k8s-rebase/SKILL.md"
  if [[ -f "$skillfile" ]]; then
    sed -i "s|find \"\$HOME/.claude\" \"\$HOME\" -maxdepth 7 -name \"k8s-rebase-autofix.sh\".*|echo \"$dest/scripts/k8s-rebase-autofix.sh\"|" "$skillfile"
    sed -i "s|find \"\$HOME/.claude\" \"\$HOME\" -maxdepth 7 -name \"k8s-rebase-patterns.md\".*|echo \"$dest/docs/k8s-rebase-patterns.md\"|" "$skillfile"
  fi

  # Validate mutated autofix is still valid bash
  bash -n "$dest/scripts/k8s-rebase-autofix.sh" 2>/dev/null \
    || { rm -rf "$dest"; die "Mutation produced invalid bash in autofix.sh"; }

  echo "$dest"
}

cmd_without() {
  local version="1.36.2" specs=() repo=""

  # Parse args: specs are pattern:*/fn:*/all*, last non-spec arg is repo
  for arg in "$@"; do
    case "$arg" in
      --version) : ;; # handled below
      pattern:*|fn:*|all-patterns|all-fns|all) specs+=("$arg") ;;
      *) repo="$arg" ;;
    esac
  done
  # Handle --version
  local i=0
  for arg in "$@"; do
    if [[ "$arg" == "--version" ]]; then
      version="${@:$((i+2)):1}"
    fi
    i=$((i + 1))
  done

  [[ ${#specs[@]} -eq 0 ]] && die "No specs provided (use pattern:<key>, fn:<tag>, all-patterns, all-fns, all)"
  [[ -z "$repo" ]] && die "No repo provided"
  [[ -d "$repo" ]] || die "Not found: $repo"

  info "── Without: ${specs[*]} on $(repo_short "$repo") ──"
  info "Version: $version"

  local mutated
  mutated=$(mutate_plugin "${specs[@]}") || exit 1
  [[ -d "$mutated" ]] || die "mutate_plugin failed"
  info "Mutated plugin: $mutated"

  # Find the harness
  local harness="$PLUGIN_DIR/scripts/k8s-rebase-test-harness.sh"
  [[ -f "$harness" ]] || die "Harness not found: $harness"

  # Launch via harness with mutated plugin dir
  info "Launching skill run..."
  PLUGIN_DIR="$mutated" bash "$harness" run "$version" "$repo"

  echo ""
  info "Mutated plugin at: $mutated"
  info "Next: $(basename "$0") --compare <result-branch> <known-good-branch> $repo"
}

cmd_compare() {
  [[ $# -lt 3 ]] && die "Usage: $(basename "$0") --compare <result-branch> <known-good-branch> <repo>"
  local result_branch="$1" known_good="$2" repo="$3"

  cd "$repo" || die "Cannot cd to $repo"
  git rev-parse --verify "$result_branch" &>/dev/null || die "Branch not found: $result_branch"
  git rev-parse --verify "$known_good" &>/dev/null || die "Branch not found: $known_good"

  info "── Compare: $result_branch vs $known_good on $(repo_short "$repo") ──"

  local diff_output
  diff_output=$(git diff "$result_branch" "$known_good" -- . ':!.rebase-tmp' 2>/dev/null)

  if [[ -z "$diff_output" ]]; then
    info "PASS: branches are identical (excluding .rebase-tmp)"
    return 0
  fi

  local hunk_count
  hunk_count=$(echo "$diff_output" | grep -c '^@@' || true)
  info "Diff: $hunk_count hunks"
  git diff --stat "$result_branch" "$known_good" -- . ':!.rebase-tmp' 2>/dev/null
  echo ""

  # Capture context for the court
  local result_log known_log
  result_log=$(git log --oneline "$(git merge-base "$result_branch" "$known_good")".."$result_branch" 2>/dev/null | head -20)
  known_log=$(git log --oneline "$(git merge-base "$result_branch" "$known_good")".."$known_good" 2>/dev/null | head -20)
  local diff_stat
  diff_stat=$(git diff --stat "$result_branch" "$known_good" -- . ':!.rebase-tmp' 2>/dev/null)

  mkdir -p "$RESULTS_DIR/comparisons" 2>/dev/null

  if [[ "$hunk_count" -lt 5 ]]; then
    # Fast path: single classifier
    info "Small diff ($hunk_count hunks) — using single classifier"
    local classifier_output
    classifier_output=$(printf '%s' "Diff between result branch ($result_branch) and known-good branch ($known_good):

$diff_output

Classify each difference as REGRESSION (result is worse), EQUIVALENT (different but ok), or IMPROVEMENT (result is better).
End with: VERDICT: PASS (no regressions) or VERDICT: FAIL (regressions found)" \
      | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true
    echo "$classifier_output" | tail -20
    echo ""
    echo "$classifier_output" > "$RESULTS_DIR/comparisons/$(date +%s)-fast.txt" 2>/dev/null
    local verdict
    verdict=$(echo "$classifier_output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -oE '^VERDICT: (PASS|FAIL)$' | tail -1)
    case "$verdict" in
      "VERDICT: PASS") info "PASS: no regressions found" ;;
      "VERDICT: FAIL") error "FAIL: regressions detected"; return 1 ;;
      *) warn "INCONCLUSIVE: could not determine verdict"; return 1 ;;
    esac
    return 0
  fi

  # Full adversarial court
  info "Large diff ($hunk_count hunks) — running adversarial court"
  local ts
  ts=$(date +%s)
  local court_dir="$RESULTS_DIR/comparisons/$ts-court"
  mkdir -p "$court_dir"

  local context="Diff between result branch ($result_branch) and known-good branch ($known_good):

DIFF:
$diff_output

RESULT BRANCH COMMITS:
$result_log

KNOWN-GOOD BRANCH COMMITS:
$known_log

FILE CHANGES:
$diff_stat"

  # Phase A: Prosecution + Defense (parallel)
  info "Phase A: Prosecution + Defense..."
  local prosecution defense
  prosecution=$(printf '%s\n\n%s' "$context" \
    "You are the PROSECUTION. Argue that these differences are REGRESSIONS. Find every way the result branch is worse than the known-good. Be specific — cite files and line numbers from the diff." \
    | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true
  echo "$prosecution" > "$court_dir/prosecution.txt"

  defense=$(printf '%s\n\n%s' "$context" \
    "You are the DEFENSE. Argue that these differences are EQUIVALENT or IMPROVEMENTS. Explain why each difference is acceptable or better than the known-good. Be specific — cite files and line numbers." \
    | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true
  echo "$defense" > "$court_dir/defense.txt"

  # Phase B: Judge (fact-checker)
  info "Phase B: Judge (fact-checking)..."
  local judge_report
  judge_report=$(printf 'PROSECUTION ARGUMENT:\n%s\n\nDEFENSE ARGUMENT:\n%s\n\nRAW DIFF:\n%s\n\n%s' \
    "$prosecution" "$defense" "$diff_output" \
    "You are the JUDGE. Fact-check only. Verify each claim against the actual diff. Strike claims not supported by evidence. Flag overreach (prosecution inventing regressions not in the diff) and handwaving (defense dismissing changes without justification). Produce a combined factual record — no opinion on the verdict. That is the jury's job." \
    | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true
  echo "$judge_report" > "$court_dir/judge.txt"

  # Phase C: Jury (5 independent votes)
  info "Phase C: Jury (5 votes)..."
  local jury_prompt
  jury_prompt=$(printf 'RAW DIFF:\n%s\n\nPROSECUTION:\n%s\n\nDEFENSE:\n%s\n\nJUDGE FACTUAL RECORD:\n%s\n\n%s' \
    "$diff_output" "$prosecution" "$defense" "$judge_report" \
    "You are a JUROR. You have all the evidence: the raw diff, prosecution arguments, defense arguments, and the judge's factual record. Vote: VERDICT: PASS (no regressions) or VERDICT: FAIL (regressions found). Give one sentence of reasoning.")

  local votes=0 pass_votes=0 fail_votes=0
  for j in 1 2 3 4 5; do
    local juror_output
    juror_output=$(printf '%s' "$jury_prompt" \
      | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true
    echo "$juror_output" > "$court_dir/juror-$j.txt"
    local jv
    jv=$(echo "$juror_output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -oE '^VERDICT: (PASS|FAIL)$' | tail -1)
    case "$jv" in
      "VERDICT: PASS") pass_votes=$((pass_votes + 1)); info "  Juror $j: PASS" ;;
      "VERDICT: FAIL") fail_votes=$((fail_votes + 1)); info "  Juror $j: FAIL" ;;
      *) info "  Juror $j: ABSTAIN" ;;
    esac
    votes=$((votes + 1))
  done

  echo ""
  info "Jury: $pass_votes PASS, $fail_votes FAIL (of $votes)"
  info "Court record: $court_dir"

  if [[ "$pass_votes" -gt "$fail_votes" ]]; then
    info "VERDICT: PASS (majority)"
    return 0
  else
    error "VERDICT: FAIL (majority)"
    return 1
  fi
}

# ── Main ──

USAGE_TEXT="Usage: $(basename "$0") <tag> <repo>                    Revert autofix, run gate
       $(basename "$0") --all <repo>                    Sweep all tags
       $(basename "$0") <tag> --vs <file> <repo>        A/B test gate prompts
       $(basename "$0") --without <spec...> <repo>      Blind skill run
       $(basename "$0") --compare <a> <b> <repo>        AI court diff
       $(basename "$0") --list                          Show all tags"

case "${1:-}" in
  --list|-l)    cmd_list ;;
  --all)        [[ $# -lt 2 ]] && die "Usage: $(basename "$0") --all <repo>"
                cmd_all "$2" ;;
  --without)    shift; cmd_without "$@" ;;
  --compare)    shift; cmd_compare "$@" ;;
  --help|-h)    echo "$USAGE_TEXT"; exit 0 ;;
  "")           echo "$USAGE_TEXT"; exit 1 ;;
  *) [[ $# -lt 2 ]] && die "Usage: $(basename "$0") <tag> <repo>"
     if [[ "${2:-}" == "--vs" ]]; then
       [[ $# -lt 4 ]] && die "Usage: $(basename "$0") <tag> --vs <candidate.md> <repo>"
       cmd_vs "$1" "$3" "$4"
     else
       cmd_check "$1" "$2"
     fi ;;
esac
