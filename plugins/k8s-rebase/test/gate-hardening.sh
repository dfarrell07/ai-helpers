#!/bin/bash
# gate-hardening.sh — Test skill self-sufficiency by removing knowledge
# (patterns, autofix functions) and comparing the result to a known-good branch.
#
# Usage:
#   gate-hardening.sh --without <spec...> <repo>      Run skill with knowledge removed
#   gate-hardening.sh --compare <a> <b> <repo>        AI court: judge branch differences
#   gate-hardening.sh --list                          Show removable knowledge
#
# Examples:
#   gate-hardening.sh --without fn:xexp multus
#   gate-hardening.sh --without all --version 1.36.2 multus
#   gate-hardening.sh --compare bump-blind-20260717 bump1.36 ~/ovnk/openshift/multus-cni

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$PLUGIN_DIR/../.." && pwd)/.work/test-harness}"
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"

info()  { echo ":: $*"; }
warn()  { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }
repo_short() { local p="${1%/}"; echo "${p/#$HOME\/ovnk\//}"; }

# Maps tags to their ### heading in patterns.md
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

# Load FIX_DESC from autofix.sh (parse, don't source)
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
  echo "Knowledge that can be removed with --without:"
  echo ""
  echo "Patterns (--without pattern:<key>):"
  printf "  %-30s %s\n" "KEY" "HEADING IN PATTERNS.MD"
  for key in $(printf '%s\n' "${!TAG_TO_PATTERN[@]}" | sort -u); do
    printf "  %-30s %s\n" "$key" "${TAG_TO_PATTERN[$key]}"
  done
  echo ""
  echo "Functions (--without fn:<tag>):"
  printf "  %-30s %s\n" "TAG" "DESCRIPTION"
  for tag in $(printf '%s\n' "${!FIX_DESC[@]}" | sort); do
    printf "  %-30s %s\n" "$tag" "${FIX_DESC[$tag]}"
  done
  echo ""
  echo "Bulk: --without all-patterns | all-fns | all"
}

# ── mutate_plugin ───────────────────────────────────────────────────

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
        if ! grep -qF "### $heading" "$pfile" 2>/dev/null; then
          rm -rf "$dest"; die "Pattern heading '$heading' not found in patterns.md"
        fi
        # Use awk with exact heading match (index on "### <heading>")
        local full_hdr="### $heading"
        awk -v hdr="$full_hdr" '
          /^### / && index($0, hdr) == 1 { skip=1; next }
          /^### / && skip { skip=0 }
          skip { next }
          { print }
        ' "$pfile" > "$pfile.tmp" && mv "$pfile.tmp" "$pfile"
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
        sed -i '/^### /,$ { /^## /!d }' "$dest/docs/k8s-rebase-patterns.md"
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
        sed -i '/^### /,$ { /^## /!d }' "$dest/docs/k8s-rebase-patterns.md"
        local afile="$dest/scripts/k8s-rebase-autofix.sh"
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

  bash -n "$dest/scripts/k8s-rebase-autofix.sh" 2>/dev/null \
    || { rm -rf "$dest"; die "Mutation produced invalid bash in autofix.sh"; }

  echo "$dest"
}

# ── --without ───────────────────────────────────────────────────────

cmd_without() {
  local version="1.36.2" specs=() repo="" skip_next=false

  for arg in "$@"; do
    if $skip_next; then skip_next=false; continue; fi
    case "$arg" in
      --version) skip_next=true ;;
      pattern:*|fn:*|all-patterns|all-fns|all) specs+=("$arg") ;;
      *) repo="$arg" ;;
    esac
  done
  # Extract --version value
  local i=1
  while [[ $i -le $# ]]; do
    if [[ "${!i}" == "--version" ]]; then
      local next=$((i + 1))
      version="${!next}"
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

  local harness="$PLUGIN_DIR/scripts/k8s-rebase-test-harness.sh"
  [[ -f "$harness" ]] || die "Harness not found: $harness"

  info "Launching skill run..."
  PLUGIN_DIR="$mutated" bash "$harness" run "$version" "$repo"

  echo ""
  info "Mutated plugin at: $mutated"
  info "Next: $(basename "$0") --compare <result-branch> <known-good-branch> $repo"
}

# ── --compare (adversarial court) ───────────────────────────────────

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

  local merge_base result_log known_log diff_stat
  merge_base=$(git merge-base "$result_branch" "$known_good" 2>/dev/null || echo "$known_good")
  result_log=$(git log --oneline "${merge_base}".."$result_branch" 2>/dev/null | head -20)
  known_log=$(git log --oneline "${merge_base}".."$known_good" 2>/dev/null | head -20)
  diff_stat=$(git diff --stat "$result_branch" "$known_good" -- . ':!.rebase-tmp' 2>/dev/null)

  mkdir -p "$RESULTS_DIR/comparisons" 2>/dev/null

  if [[ "$hunk_count" -lt 5 ]]; then
    info "Small diff ($hunk_count hunks) — single classifier"
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
  info "Large diff ($hunk_count hunks) — adversarial court"
  local court_dir="$RESULTS_DIR/comparisons/$(date +%s)-court"
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
  printf '%s\n\n%s' "$context" \
    "You are the PROSECUTION. Argue that these differences are REGRESSIONS. Find every way the result branch is worse. Cite files and line numbers from the diff." \
    | claude -p --permission-mode "$PERMISSION_MODE" --output-format text \
    > "$court_dir/prosecution.txt" 2>/dev/null &
  local pid_pros=$!

  printf '%s\n\n%s' "$context" \
    "You are the DEFENSE. Argue that these differences are EQUIVALENT or IMPROVEMENTS. Explain why each difference is acceptable. Cite files and line numbers." \
    | claude -p --permission-mode "$PERMISSION_MODE" --output-format text \
    > "$court_dir/defense.txt" 2>/dev/null &
  local pid_def=$!

  wait "$pid_pros" "$pid_def" 2>/dev/null || true
  local prosecution defense
  prosecution=$(cat "$court_dir/prosecution.txt" 2>/dev/null)
  defense=$(cat "$court_dir/defense.txt" 2>/dev/null)
  if [[ -z "$prosecution" && -z "$defense" ]]; then
    error "Both prosecution and defense produced empty output — claude -p may have failed"
    return 1
  fi

  # Phase B: Judge (fact-check only)
  info "Phase B: Judge (fact-checking)..."
  local judge_report
  judge_report=$(printf 'PROSECUTION ARGUMENT:\n%s\n\nDEFENSE ARGUMENT:\n%s\n\nRAW DIFF:\n%s\n\n%s' \
    "$prosecution" "$defense" "$diff_output" \
    "You are the JUDGE. Fact-check only. Verify each claim against the actual diff. Strike claims not supported by evidence. Flag overreach (prosecution inventing regressions not in the diff) and handwaving (defense dismissing changes without justification). Produce a combined factual record — no opinion on the verdict. That is the jury's job." \
    | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true
  echo "$judge_report" > "$court_dir/judge.txt"

  # Phase C: Jury (5 votes, all data)
  info "Phase C: Jury (5 votes)..."
  local jury_prompt
  jury_prompt=$(printf 'RAW DIFF:\n%s\n\nPROSECUTION:\n%s\n\nDEFENSE:\n%s\n\nJUDGE FACTUAL RECORD:\n%s\n\n%s' \
    "$diff_output" "$prosecution" "$defense" "$judge_report" \
    "You are a JUROR. You have all the evidence: the raw diff, prosecution arguments, defense arguments, and the judge's factual record. Vote: VERDICT: PASS (no regressions) or VERDICT: FAIL (regressions found). Give one sentence of reasoning.")

  local pass_votes=0 fail_votes=0
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
  done

  echo ""
  info "Jury: $pass_votes PASS, $fail_votes FAIL"
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

case "${1:-}" in
  --list|-l)    cmd_list ;;
  --without)    shift; cmd_without "$@" ;;
  --compare)    shift; cmd_compare "$@" ;;
  --help|-h)
    echo "Usage: $(basename "$0") --without <spec...> <repo>      Run skill with knowledge removed"
    echo "       $(basename "$0") --compare <a> <b> <repo>        AI court: judge differences"
    echo "       $(basename "$0") --list                          Show removable knowledge"
    exit 0 ;;
  *)
    echo "Usage: $(basename "$0") --without <spec...> <repo>      Run skill with knowledge removed"
    echo "       $(basename "$0") --compare <a> <b> <repo>        AI court: judge differences"
    echo "       $(basename "$0") --list                          Show removable knowledge"
    exit 1 ;;
esac
