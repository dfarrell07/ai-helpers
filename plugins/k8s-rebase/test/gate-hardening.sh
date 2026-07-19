#!/bin/bash
# gate-hardening.sh — Test skill self-sufficiency by removing knowledge
# (patterns, autofix functions) and comparing the result to a known-good branch.
#
# Usage:
#   gate-hardening.sh --without <spec...> <repo>      Run skill with knowledge removed
#   gate-hardening.sh --compare <result> <known-good> <repo>  AI court: judge differences
#   gate-hardening.sh --auto-record                   Batch-record all completed runs
#   gate-hardening.sh --list                          Show removable knowledge
#
# Examples:
#   gate-hardening.sh --without fn:xexp ~/ovnk/openshift/multus-cni
#   gate-hardening.sh --without all --version 1.36.2 ~/ovnk/openshift/multus-cni
#   gate-hardening.sh --auto-record                   # record all finished, skip running
#   gate-hardening.sh --compare bump-blind-20260717 bump1.36 ~/ovnk/openshift/multus-cni

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$PLUGIN_DIR/../.." 2>/dev/null && pwd || echo /tmp)/.work/test-harness}"
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"

info()  { echo ":: $*" >&2; }
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
  [addtoscheme]="AddToScheme"
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
  for key in $(printf '%s\n' "${!TAG_TO_PATTERN[@]}" | sort); do
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
  mkdir -p "$RESULTS_DIR" 2>/dev/null || true
  cp -r "$PLUGIN_DIR" "$dest" || die "Cannot copy plugin to $dest"

  # Expand "all" into components, suppress individual specs made redundant by bulk
  local has_all_patterns=false has_all_fns=false
  local -A seen_specs=() seen_headings=()
  local raw_specs=()
  for spec in "$@"; do
    if [[ "$spec" == "all" ]]; then
      has_all_patterns=true; has_all_fns=true
      for s in all-patterns all-fns; do
        [[ -n "${seen_specs[$s]+x}" ]] && continue
        seen_specs[$s]=1; raw_specs+=("$s")
      done
    elif [[ "$spec" == "all-patterns" ]]; then
      has_all_patterns=true
      [[ -n "${seen_specs[$spec]+x}" ]] && continue
      seen_specs[$spec]=1; raw_specs+=("$spec")
    elif [[ "$spec" == "all-fns" ]]; then
      has_all_fns=true
      [[ -n "${seen_specs[$spec]+x}" ]] && continue
      seen_specs[$spec]=1; raw_specs+=("$spec")
    else
      [[ -n "${seen_specs[$spec]+x}" ]] && continue
      seen_specs[$spec]=1; raw_specs+=("$spec")
    fi
  done
  # Filter out individual specs made redundant by bulk operations
  local specs=()
  for spec in "${raw_specs[@]}"; do
    case "$spec" in
      pattern:*) $has_all_patterns && continue ;;
      fn:*) $has_all_fns && continue ;;
    esac
    if [[ "$spec" == pattern:* ]]; then
      local key="${spec#pattern:}"
      local heading="${TAG_TO_PATTERN[$key]:-}"
      if [[ -n "$heading" && -n "${seen_headings[$heading]+x}" ]]; then
        continue
      fi
      [[ -n "$heading" ]] && seen_headings[$heading]=1
    fi
    specs+=("$spec")
  done

  for spec in "${specs[@]}"; do
    case "$spec" in
      pattern:*)
        local key="${spec#pattern:}"
        local heading="${TAG_TO_PATTERN[$key]:-}"
        [[ -z "$heading" ]] && { rm -rf "$dest"; die "Unknown pattern key: $key (run --list to see available)"; }
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
        local ftag="${spec#fn:}"
        local afile="$dest/scripts/k8s-rebase-autofix.sh"
        if ! grep -q "^fix_${ftag}()" "$afile" 2>/dev/null; then
          rm -rf "$dest"; die "Function fix_${ftag}() not found in autofix.sh (run --list to see available)"
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
        sed -i '/^### /,$ { /^## /!d }' "$dest/docs/k8s-rebase-patterns.md"
        info "Removed all pattern sections"
        ;;
      all-fns)
        local afile="$dest/scripts/k8s-rebase-autofix.sh"
        awk '
          /^fix_[a-z0-9_]+\(\)/ && !/fix_uncommitted/ { print $0; print "  return 0"; skip=1; next }
          skip && /^\}/ { print; skip=0; next }
          skip { next }
          { print }
        ' "$afile" > "$afile.tmp" && mv "$afile.tmp" "$afile"
        info "Neutered all fix functions"
        ;;
      *) rm -rf "$dest"; die "Unknown spec: $spec (use pattern:<key>, fn:<tag>, all-patterns, all-fns, all)" ;;
    esac
  done

  # Patch SKILL.md find commands to use the mutated plugin directory
  local skillfile="$dest/skills/k8s-rebase/SKILL.md"
  if [[ -f "$skillfile" ]]; then
    sed -i "s|find \"\$HOME/.claude\" \"\$HOME\" -maxdepth 7 -name \"k8s-rebase-autofix.sh\"[^)]*)|echo \"$dest/scripts/k8s-rebase-autofix.sh\")|" "$skillfile"
    sed -i "s|find \"\$HOME/.claude\" \"\$HOME\" -maxdepth 7 -name \"k8s-rebase-patterns.md\"[^)]*)|echo \"$dest/docs/k8s-rebase-patterns.md\")|" "$skillfile"
  fi

  bash -n "$dest/scripts/k8s-rebase-autofix.sh" \
    || { rm -rf "$dest"; die "Mutation produced invalid bash in autofix.sh"; }

  echo "$dest"
}

# ── --without ───────────────────────────────────────────────────────

cmd_without() {
  local version="1.36.2" specs=() repo="" args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --version) i=$((i + 1)); version="${args[$i]:-}"; [[ -z "$version" ]] && die "--version requires a value" ;;
      pattern:*|fn:*|all-patterns|all-fns|all) specs+=("${args[$i]}") ;;
      *) repo="${args[$i]}" ;;
    esac
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

  # Rename stale worktree branches to avoid collisions with new sessions
  # Preserves history (branches renamed, not deleted)
  (cd "$repo" && git worktree prune 2>/dev/null || true
   for wt_branch in $(git branch | grep 'worktree-k8s-rebase' | grep -v '^archived-' | tr -d ' *'); do
     _ts=$(date +%Y%m%d%H%M%S)
     git branch -m "$wt_branch" "archived-${wt_branch}-${_ts}" 2>/dev/null \
       && echo ":: Archived stale branch: $wt_branch -> archived-${wt_branch}-${_ts}"
   done)

  info "Launching skill run..."
  PLUGIN_DIR="$mutated" RESULTS_DIR="$RESULTS_DIR" PERMISSION_MODE="$PERMISSION_MODE" \
    bash "$harness" run "$version" "$repo"

  echo ""
  info "Mutated plugin at: $mutated"
  info "Next: $(basename "$0") --compare <result-branch> <known-good-branch> $repo --context '${specs[*]}'"
}

# ── --compare (adversarial court) ───────────────────────────────────

cmd_compare() {
  [[ $# -lt 3 ]] && die "Usage: $(basename "$0") --compare <result-branch> <known-good-branch> <repo> [--context 'what was removed']"
  local result_branch="$1" known_good="$2" repo="$3" mutation_context="${4:-}"
  # Strip --context flag if present
  [[ "$mutation_context" == "--context" ]] && mutation_context="${5:-}" || mutation_context=""
  # Check if --context appears anywhere in args
  local i=4
  while [[ $i -le $# ]]; do
    if [[ "${!i}" == "--context" ]]; then
      local next=$((i + 1))
      mutation_context="${!next:-}"
    fi
    i=$((i + 1))
  done

  cd "$repo" || die "Cannot cd to $repo"
  git rev-parse --verify "$result_branch" &>/dev/null || die "Branch not found: $result_branch"
  git rev-parse --verify "$known_good" &>/dev/null || die "Branch not found: $known_good"
  [[ "$result_branch" == "$known_good" ]] && die "Both branches are the same: $result_branch"

  info "── Compare: $result_branch vs $known_good on $(repo_short "$repo") ──"

  local diff_output diff_nonvendor
  diff_output=$(git diff "$result_branch" "$known_good" -- . ':!.rebase-tmp' 2>/dev/null)
  diff_nonvendor=$(git diff "$result_branch" "$known_good" -- . ':!.rebase-tmp' ':!vendor' 2>/dev/null)

  if [[ -z "$diff_output" ]]; then
    info "PASS: branches are identical (excluding .rebase-tmp)"
    return 0
  fi

  if [[ -z "$diff_nonvendor" ]]; then
    info "PASS: branches differ only in vendor/ (mechanical go mod tidy differences)"
    return 0
  fi

  local hunk_count diff_stat vendor_hunks
  hunk_count=$(echo "$diff_nonvendor" | grep -c '^@@' || true)
  vendor_hunks=$(echo "$diff_output" | grep -c '^@@' || true)
  vendor_hunks=$((vendor_hunks - hunk_count))
  diff_stat=$(git diff --stat "$result_branch" "$known_good" -- . ':!.rebase-tmp' ':!vendor' 2>/dev/null)
  [[ "$vendor_hunks" -gt 0 ]] && info "Note: $vendor_hunks vendor-only hunks excluded from analysis"
  info "Diff: $hunk_count hunks"
  echo "$diff_stat"
  echo ""

  local merge_base result_log known_log
  merge_base=$(git merge-base "$result_branch" "$known_good" 2>/dev/null || echo "$known_good")
  result_log=$(git log --oneline "${merge_base}".."$result_branch" 2>/dev/null | head -20)
  known_log=$(git log --oneline "${merge_base}".."$known_good" 2>/dev/null | head -20)

  mkdir -p "$RESULTS_DIR/comparisons" 2>/dev/null

  if [[ "$hunk_count" -lt 5 ]]; then
    info "Small diff ($hunk_count hunks) — single classifier"
    local classifier_output
    local fast_context="Diff between result branch ($result_branch) and known-good branch ($known_good):"
    [[ -n "$mutation_context" ]] && fast_context="$fast_context
MUTATION: The result branch was produced with this knowledge REMOVED: $mutation_context
Any difference caused by the missing knowledge is a REGRESSION."
    classifier_output=$(printf '%s' "$fast_context

$diff_output

Classify each difference as REGRESSION (result is worse), EQUIVALENT (different but ok), or IMPROVEMENT (result is better).
End with: VERDICT: PASS (no regressions) or VERDICT: FAIL (regressions found)" \
      | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true
    echo "$classifier_output" | tail -20
    echo ""
    echo "$classifier_output" > "$RESULTS_DIR/comparisons/$(date +%s)-fast.txt" 2>/dev/null
    local verdict
    verdict=$(echo "$classifier_output" | grep -oE 'VERDICT: (PASS|FAIL)' | tail -1)
    case "$verdict" in
      "VERDICT: PASS") info "PASS: no regressions found" ;;
      "VERDICT: FAIL") error "FAIL: regressions detected"; return 1 ;;
      *) error "INCONCLUSIVE: could not determine verdict"; return 1 ;;
    esac
    return 0
  fi

  # Full adversarial court
  info "Large diff ($hunk_count hunks) — adversarial court"
  local court_dir="$RESULTS_DIR/comparisons/$(date +%s)-court"
  mkdir -p "$court_dir"

  local mutation_note=""
  [[ -n "$mutation_context" ]] && mutation_note="
MUTATION: The result branch was produced with this knowledge REMOVED:
$mutation_context
Any difference caused by the missing knowledge is a REGRESSION, not an equivalent alternative.
"
  local context="Diff between result branch ($result_branch) and known-good branch ($known_good):
${mutation_note}

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
  if [[ -z "$prosecution" || -z "$defense" ]]; then
    error "Prosecution or defense produced empty output — claude -p may have failed"
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
    jv=$(echo "$juror_output" | grep -oE 'VERDICT: (PASS|FAIL)' | tail -1)
    case "$jv" in
      "VERDICT: PASS") pass_votes=$((pass_votes + 1)); info "  Juror $j: PASS" ;;
      "VERDICT: FAIL") fail_votes=$((fail_votes + 1)); info "  Juror $j: FAIL" ;;
      *) info "  Juror $j: ABSTAIN" ;;
    esac
  done

  echo ""
  info "Jury: $pass_votes PASS, $fail_votes FAIL"
  info "Court record: $court_dir"

  local total_votes=$((pass_votes + fail_votes))
  if [[ "$total_votes" -eq 0 ]]; then
    error "INCONCLUSIVE: all jurors abstained (claude -p may have failed)"
    return 1
  elif [[ "$total_votes" -lt 3 ]]; then
    error "INCONCLUSIVE: only $total_votes of 5 jurors voted (no quorum)"
    return 1
  elif [[ "$pass_votes" -eq "$fail_votes" ]]; then
    error "INCONCLUSIVE: jury tied $pass_votes-$fail_votes"
    return 1
  elif [[ "$pass_votes" -gt "$fail_votes" ]]; then
    info "VERDICT: PASS ($pass_votes-$fail_votes)"
    return 0
  else
    error "VERDICT: FAIL ($fail_votes-$pass_votes)"
    return 1
  fi
}

# ── --analyze (deep gate report analysis) ──────────────────────────

cmd_analyze() {
  [[ $# -lt 1 ]] && die "Usage: $(basename "$0") --analyze <repo> [--context 'what was removed']"
  local repo="$1" mutation_context=""
  local i=2
  while [[ $i -le $# ]]; do
    if [[ "${!i}" == "--context" ]]; then
      local next=$((i + 1))
      mutation_context="${!next:-}"
    fi
    i=$((i + 1))
  done

  cd "$repo" || die "Cannot cd to $repo"
  local short
  short=$(repo_short "$repo")

  # Find gate reports in the worktree
  local wt_path
  wt_path=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1 | awk '{print $1}')
  local gate_dir="$wt_path/.rebase-tmp/gates"

  if [[ ! -d "$gate_dir" ]]; then
    # Try the repo root
    gate_dir="$repo/.rebase-tmp/gates"
  fi
  [[ -d "$gate_dir" ]] || die "No gate reports found in $repo"

  # Build structured summary of all gate reports
  local total=0 pass=0 fail=0 no_verdict=0
  local report_summary=""
  for f in "$gate_dir"/*.report; do
    [[ -f "$f" ]] || continue
    total=$((total + 1))
    local name verdict issues summary details
    name=$(basename "$f" .report)
    verdict=$(grep -iE '^(VERDICT|STATUS|RESULT):' "$f" 2>/dev/null | head -1)
    issues=$(grep '^ISSUES:' "$f" 2>/dev/null | head -1)
    summary=$(grep '^SUMMARY:' "$f" 2>/dev/null | head -1)
    details=$(sed -n '/^DETAILS:/,$ p' "$f" 2>/dev/null | tail -n +2)

    if [[ "$verdict" == *"PASS"* ]]; then
      pass=$((pass + 1))
    elif [[ "$verdict" == *"FAIL"* ]]; then
      fail=$((fail + 1))
      report_summary+="FAILED GATE: $name
$verdict
$issues
$summary
$details

"
    else
      no_verdict=$((no_verdict + 1))
      report_summary+="NO VERDICT: $name ($(wc -c < "$f") bytes)
"
    fi
  done

  info "── Analysis: $short ──"
  info "Gates: $pass PASS, $fail FAIL, $no_verdict NO VERDICT (of $total)"

  if [[ "$fail" -eq 0 && "$no_verdict" -eq 0 && -z "$mutation_context" ]]; then
    info "All gates passed (no mutation context). Skipping deep analysis."
    return 0
  fi

  if [[ "$fail" -eq 0 && "$no_verdict" -eq 0 ]]; then
    info "All gates passed — analyzing for false negatives (mutation: $mutation_context)"
  fi

  # Collect gate prompts for failed/no-verdict gates (full text, not truncated)
  local gate_prompts=""
  for f in "$gate_dir"/*.report; do
    [[ -f "$f" ]] || continue
    local name verdict
    name=$(basename "$f" .report)
    verdict=$(grep -iE '^(VERDICT|STATUS|RESULT):' "$f" 2>/dev/null | head -1)
    if [[ "$verdict" != *"PASS"* ]]; then
      local prompt_file gate_basename
      gate_basename="${name#step[0-9]*-}"
      prompt_file=$(find "$PLUGIN_DIR/gates" -name "${gate_basename}.md" 2>/dev/null | head -1)
      [[ -z "$prompt_file" ]] && prompt_file=$(find "$PLUGIN_DIR/gates" -name "${name}.md" 2>/dev/null | head -1)
      if [[ -f "$prompt_file" ]]; then
        gate_prompts+="GATE PROMPT FOR $name ($(basename "$prompt_file")):
$(cat "$prompt_file")
---
"
      else
        gate_prompts+="GATE PROMPT FOR $name: [not found — searched gates/ for ${gate_basename}.md]
---
"
      fi
    fi
  done

  # Also gather branch info
  local branch
  branch=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1 | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')
  local default_br
  default_br=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)
  local commits="" gomod_diff="" rebase_report=""
  if [[ -n "$branch" ]]; then
    commits=$(git log "${default_br}..${branch}" --oneline 2>/dev/null)
    gomod_diff=$(git diff "${default_br}..${branch}" -- go.mod 2>/dev/null | head -80)
  fi
  # Include rebase report checkpoints if available
  local rr_file="${wt_path:+$wt_path/.rebase-tmp/rebase-report.md}"
  [[ -f "$rr_file" ]] || rr_file="$repo/.rebase-tmp/rebase-report.md"
  [[ -f "$rr_file" ]] && rebase_report=$(cat "$rr_file")

  # Launch analyst agent
  info "Launching deep analysis..."
  local analysis_prompt="You are analyzing gate results from a k8s-rebase skill run on $short.
"
  [[ -n "$mutation_context" ]] && analysis_prompt+="
MUTATION CONTEXT: This run was produced with the following knowledge
REMOVED from the skill: $mutation_context
Failures caused by the missing knowledge are EXPECTED — the question is
whether the gates caught them and whether the agent could have recovered
without the knowledge.
"
  analysis_prompt+="
GATE RESULTS ($pass pass, $fail fail, $no_verdict no verdict out of $total):

$report_summary

GATE PROMPTS (full text for failed/no-verdict gates):
${gate_prompts:-None collected — gate prompt files not found}

GO.MOD CHANGES:
${gomod_diff:-No go.mod diff available}

COMMITS ON THE REBASE BRANCH:
$commits

REBASE REPORT (agent's step-by-step notes):
${rebase_report:-No rebase report available}

ANALYSIS TASKS — complete all six, in order:

1. FAILURE ATTRIBUTION: For each FAILED gate, answer:
   a) Quote the gate prompt instruction that the rebase violated.
   b) Was this failure caused by the removed knowledge, or would it
      fail on a normal (unmutated) run too? Evidence required.
   c) Did the gate report cite specific file:line evidence, or is
      the failure vague? Vague failures suggest a weak gate prompt.

2. NO-VERDICT TRIAGE: For each gate with no VERDICT line:
   a) Is the report file empty, truncated, or malformed?
   b) Is the gate prompt too complex for a single agent pass?
      (Count the distinct checks it asks for — more than 4 is a
      splitting candidate.)
   c) Propose: split, simplify, or add a timeout/fallback instruction.

3. FALSE NEGATIVE HUNT: Review each PASSING gate against the mutation:
   a) Read the passing gate's name and the mutation context.
   b) Should this gate have caught something related to the removed
      knowledge? If yes, explain what it missed and why.
   c) Check the go.mod diff: are there dependency changes that no
      gate (passing or failing) validates?

4. GATE PROMPT IMPROVEMENTS: For each gate prompt that is problematic
   (caused a false negative, produced no verdict, or gave vague output):
   a) Quote the current wording (exact lines).
   b) Explain what is wrong (ambiguous, missing check, too broad).
   c) Write a concrete replacement paragraph.

5. REPORT FORMAT QUALITY: Do all reports follow the VERDICT/ISSUES/
   SUMMARY/DETAILS structure? Flag any that are missing fields or
   have inconsistent formatting (e.g., ISSUES count does not match
   the number of findings in DETAILS).

6. SELF-SUFFICIENCY (this repo only): Based on this single repo's
   results, classify the removed knowledge as:
   - ESSENTIAL: the agent failed to handle the issue and gates caught it
   - COMPENSATED: the agent failed but no gate caught it (dangerous)
   - DISCOVERABLE: the agent handled it without the knowledge
   - INSUFFICIENT_DATA: cannot determine from this run alone

OUTPUT FORMAT (use these exact headers):

FAILURE_ATTRIBUTION:
<numbered list, one per failed gate, with a/b/c sub-answers>

FALSE_NEGATIVES:
<numbered list of passing gates that should have failed, or 'None found'>

GATE_IMPROVEMENTS:
<numbered list: gate name, quoted current text, proposed replacement>

SELF_SUFFICIENCY: <ESSENTIAL | COMPENSATED | DISCOVERABLE | INSUFFICIENT_DATA>
EVIDENCE: <one paragraph justifying the classification>"

  local analysis_output
  analysis_output=$(printf '%s' "$analysis_prompt" \
    | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true

  if [[ -z "$analysis_output" ]]; then
    error "Analysis agent produced no output"
    return 1
  fi

  echo "$analysis_output"
  echo ""

  # Save analysis
  mkdir -p "$RESULTS_DIR/analyses" 2>/dev/null
  local analysis_file="$RESULTS_DIR/analyses/$(echo "$short" | tr '/' '-')-$(date +%s).txt"
  echo "$analysis_output" > "$analysis_file" 2>/dev/null
  info "Analysis saved: $analysis_file"

  # Adversarial reviewer — gets raw data so it can independently verify claims
  info "Launching adversarial review..."
  local adversarial_output
  adversarial_output=$(printf '%s' "You are a skeptical reviewer. Your job is to find errors in this
gate analysis. You have the RAW DATA — verify every claim yourself.

ANALYST OUTPUT:
$analysis_output

RAW GATE RESULTS:
$report_summary

GATE PROMPTS (same set the analyst saw):
${gate_prompts:-None collected}

GO.MOD CHANGES:
${gomod_diff:-No go.mod diff available}

Check each of these:
1. FAILURE ATTRIBUTION: Did the analyst correctly identify whether
   each failure was caused by the mutation or is a pre-existing issue?
   Cross-check against the gate prompt text and report details.
2. FALSE NEGATIVES: Did the analyst miss any passing gate that should
   have failed? Read each gate prompt's check instructions against the
   mutation context — would the removed knowledge affect what it checks?
3. GATE IMPROVEMENTS: Are the proposed prompt replacements actually
   better? Do they risk false positives (flagging correct code as
   broken)? Would they catch the issue they claim to fix?
4. SELF-SUFFICIENCY: Is the classification justified by the evidence?
   Does the analyst conflate 'gate caught it' with 'agent could not
   handle it'? A gate failure does not always mean the knowledge is
   essential — the agent might have fixed the issue but a gate was
   overly strict.

RULES: Quote specific claims from the analyst and rebut with evidence
from the raw data. Do not agree with the analyst unless you verified
the claim independently." \
    | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true

  if [[ -n "$adversarial_output" ]]; then
    echo ""
    info "── Adversarial Review ──"
    echo "$adversarial_output"
    echo "$adversarial_output" >> "$analysis_file" 2>/dev/null
  else
    warn "Adversarial reviewer produced no output — analysis is single-perspective only"
  fi

  # Extract gate improvements if any
  local improvements
  improvements=$(echo "$analysis_output" | sed -n '/GATE_IMPROVEMENTS:/,/SELF_SUFFICIENCY:/p' | head -30)
  if [[ -n "$improvements" && "$improvements" != *"none"* && "$improvements" != *"None"* ]]; then
    info "Gate improvements suggested — review above"
    echo "$improvements" >> "$RESULTS_DIR/analyses/improvements.log" 2>/dev/null
  fi
}

# ── --record (capture result from --without run) ─────────────────────

cmd_record() {
  [[ $# -lt 1 ]] && die "Usage: $(basename "$0") --record <repo>"
  local repo="$1"
  [[ -d "$repo" ]] || die "Not found: $repo"
  local short state_dir repo_key
  short=$(repo_short "$repo")
  state_dir="$PLUGIN_DIR/test/.matrix-state"
  repo_key=$(echo "$short" | tr '/' '_')

  local running_file="$state_dir/running/$repo_key"
  [[ -f "$running_file" ]] || die "No running entry for $repo_key — was --without run?"
  local spec
  spec=$(cat "$running_file")
  [[ -z "$spec" ]] && die "Empty running entry: $running_file"

  cd "$repo" || die "Cannot cd to $repo"

  # Find latest bump/worktree branch
  local result_branch
  local wt_line
  wt_line=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1)
  if [[ -n "$wt_line" ]]; then
    result_branch=$(echo "$wt_line" | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')
  fi
  if [[ -z "$result_branch" ]]; then
    result_branch=$(LC_ALL=C git branch --no-color | grep 'bump' | sed 's/^[* +]*//' | sort -V | tail -1)
  fi
  [[ -z "$result_branch" ]] && die "No bump/worktree branch in $repo"

  # Mechanical diff stats
  local default_br
  default_br=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  : "${default_br:=main}"
  git rev-parse --verify "$default_br" &>/dev/null \
    || git rev-parse --verify "origin/$default_br" &>/dev/null \
    || default_br="master"

  local commits files hunks
  commits=$(git rev-list --count "$default_br".."$result_branch" 2>/dev/null || echo 0)
  files=$(git diff --name-only "$default_br".."$result_branch" -- . ':!.rebase-tmp' 2>/dev/null | wc -l)
  hunks=$(git diff "$default_br".."$result_branch" -- . ':!.rebase-tmp' 2>/dev/null | grep -c '^@@' || true)
  local diff_details="${commits}c/${files}f/${hunks}h"

  # Check gate reports
  local verdict="DONE" gate_summary="no-gates"
  local wt_path
  wt_path=$(echo "$wt_line" | awk '{print $1}')
  local gate_dir="${wt_path:+$wt_path/.rebase-tmp/gates}"
  [[ -d "$gate_dir" ]] || gate_dir="$repo/.rebase-tmp/gates"

  if [[ -d "$gate_dir" ]]; then
    local total=0 gpass=0 gfail=0 noverdict=0
    for f in "$gate_dir"/*.report; do
      [[ -f "$f" ]] || continue
      total=$((total + 1))
      local gv
      gv=$(grep -iE '^(VERDICT|STATUS|RESULT):' "$f" 2>/dev/null | head -1)
      if [[ "$gv" == *"PASS"* ]]; then gpass=$((gpass + 1))
      elif [[ "$gv" == *"FAIL"* ]]; then gfail=$((gfail + 1))
      else noverdict=$((noverdict + 1)); fi
    done
    gate_summary="gates:${gpass}/${total}"
    [[ "$gfail" -gt 0 || "$noverdict" -gt 0 ]] && verdict="FAIL"
  fi

  # Write results.tsv entry
  local ts detail
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  detail="$diff_details $gate_summary"
  mkdir -p "$state_dir/done"
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$spec" "$short" "$verdict" "$detail" \
    >> "$state_dir/results.tsv"

  # Move running -> done
  local done_key="${spec//[:\/]/_}_$repo_key"
  echo "$ts	$spec	$short	$verdict	$detail" > "$state_dir/done/$done_key"
  rm -f "$running_file"

  info "Recorded: $spec on $short -> $verdict ($detail)"
}

# ── --auto-record helpers ──────────────────────────────────────────

# Map repo_key (org_repo with _ separator) back to filesystem path.
# Works because org names in this project never contain underscores.
_repo_from_key() {
  local key="$1"
  local org="${key%%_*}"
  local name="${key#*_}"
  local path="$HOME/ovnk/$org/$name"
  [[ -d "$path" ]] && { echo "$path"; return 0; }
  return 1
}

# Build a lightweight session cache (cwd + state + pid, one call to claude agents).
_build_session_cache() {
  timeout 10 claude agents --json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): sys.exit(0)
except: sys.exit(0)
for s in data:
    cwd = s.get('cwd', '')
    st = s.get('state') or s.get('status') or '?'
    pid = s.get('pid', '')
    print(f'{cwd}\t{st}\t{pid}')
" 2>/dev/null || true
}

# Check whether a session for repo $short is still active in the cache.
_is_session_active() {
  local short="$1" cache="$2"
  [[ -z "$cache" ]] && return 1
  while IFS=$'\t' read -r cwd state pid; do
    if [[ "$cwd" == *"/$short" || "$cwd" == *"/$short/"* ]]; then
      [[ "$state" != "done" && "$state" != "?" && -n "$pid" && "$pid" != "0" ]] && return 0
    fi
  done <<< "$cache"
  return 1
}

# Record a single completed run. Uses git -C to avoid cd side effects.
# Outputs a formatted summary line on success, error message on failure.
_do_record_one() {
  local repo="$1" repo_key="$2" spec="$3" state_dir="$4"
  local short
  short=$(repo_short "$repo")

  # Find result branch (worktree first, then local bump branches)
  local result_branch="" wt_line="" wt_path=""
  wt_line=$(git -C "$repo" worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1)
  if [[ -n "$wt_line" ]]; then
    result_branch=$(echo "$wt_line" | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')
    wt_path=$(echo "$wt_line" | awk '{print $1}')
  fi
  [[ -z "$result_branch" ]] && \
    result_branch=$(LC_ALL=C git -C "$repo" branch --no-color | grep 'bump' | sed 's/^[* +]*//' | sort -V | tail -1)

  if [[ -z "$result_branch" ]]; then
    echo "no bump/worktree branch found"
    return 1
  fi

  # Resolve default branch
  local default_br
  default_br=$(git -C "$repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  : "${default_br:=main}"
  git -C "$repo" rev-parse --verify "$default_br" &>/dev/null \
    || git -C "$repo" rev-parse --verify "origin/$default_br" &>/dev/null \
    || default_br="master"

  # Diff stats vs default branch
  local commits files hunks
  commits=$(git -C "$repo" rev-list --count "$default_br".."$result_branch" 2>/dev/null || echo 0)
  files=$(git -C "$repo" diff --name-only "$default_br".."$result_branch" -- . ':!.rebase-tmp' 2>/dev/null | wc -l)
  hunks=$(git -C "$repo" diff "$default_br".."$result_branch" -- . ':!.rebase-tmp' 2>/dev/null | grep -c '^@@' || true)

  # Gate report tally
  local verdict="DONE" gate_summary="no-gates"
  local gate_dir="${wt_path:+$wt_path/.rebase-tmp/gates}"
  [[ -d "$gate_dir" ]] || gate_dir="$repo/.rebase-tmp/gates"

  if [[ -d "$gate_dir" ]]; then
    local gtotal=0 gpass=0 gfail=0 gskip=0
    for f in "$gate_dir"/*.report; do
      [[ -f "$f" ]] || continue
      gtotal=$((gtotal + 1))
      local gv
      gv=$(grep -iE '^(VERDICT|STATUS|RESULT):' "$f" 2>/dev/null | head -1)
      if [[ "$gv" == *"PASS"* || "$gv" == *"pass"* ]]; then gpass=$((gpass + 1))
      elif [[ "$gv" == *"FAIL"* || "$gv" == *"fail"* ]]; then gfail=$((gfail + 1))
      elif [[ "$gv" == *"SKIP"* || "$gv" == *"skip"* ]]; then gskip=$((gskip + 1))
      fi
    done
    if [[ "$gtotal" -gt 0 ]]; then
      local active=$((gtotal - gskip))
      gate_summary="gates:${gpass}/${active}"
      [[ "$gskip" -gt 0 ]] && gate_summary="${gate_summary}(${gskip}skip)"
      if [[ "$gfail" -gt 0 ]]; then
        verdict="FAIL"
      elif [[ "$active" -lt 5 ]]; then
        verdict="DONE"
        gate_summary="${gate_summary}(incomplete)"
      else
        verdict="PASS"
      fi
    fi
  fi

  # Known-good comparison (mechanical diff, not adversarial court)
  local kg_note=""
  local kg_file="$state_dir/known_good_$repo_key"
  if [[ -f "$kg_file" ]]; then
    local kg_branch
    kg_branch=$(cat "$kg_file")
    if git -C "$repo" rev-parse --verify "$kg_branch" &>/dev/null; then
      local kg_diff
      kg_diff=$(git -C "$repo" diff "$result_branch" "$kg_branch" -- . ':!.rebase-tmp' 2>/dev/null)
      if [[ -z "$kg_diff" ]]; then
        kg_note="identical-to-known-good"
      else
        local kg_hunks
        kg_hunks=$(echo "$kg_diff" | grep -c '^@@' || true)
        kg_note="diff-vs-known-good:${kg_hunks}h"
      fi
    fi
  fi

  # Override verdict: identical output = correct code, regardless of gate noise
  [[ "$kg_note" == "identical-to-known-good" ]] && verdict="PASS"

  # Assemble detail string — prioritize known-good diff when available
  local detail
  if [[ "$kg_note" == "identical-to-known-good" ]]; then
    detail="${commits}c/0diff $gate_summary identical-to-known-good"
  elif [[ -n "$kg_note" ]]; then
    detail="${commits}c $gate_summary $kg_note"
  else
    detail="${commits}c/${files}f/${hunks}h $gate_summary"
  fi

  local ts done_key
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  done_key="${spec//[:\/]/_}_$repo_key"
  mkdir -p "$state_dir/done"
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$spec" "$short" "$verdict" "$detail" \
    >> "$state_dir/results.tsv"
  # Preserve gate details in done file for learning
  {
    echo "$ts	$spec	$short	$verdict	$detail"
    if [[ -d "$gate_dir" && "$gfail" -gt 0 ]]; then
      echo "---FAILED-GATES---"
      for f in "$gate_dir"/*.report; do
        [[ -f "$f" ]] || continue
        local _gv
        _gv=$(grep -iE '^(VERDICT|STATUS|RESULT):' "$f" 2>/dev/null | head -1)
        if [[ "$_gv" == *"FAIL"* || "$_gv" == *"fail"* ]]; then
          echo "=== $(basename "$f" .report) ==="
          cat "$f"
          echo ""
        fi
      done
    fi
    # Preserve rebase report if it exists
    local _rr="${wt_path:+$wt_path/.rebase-tmp/rebase-report.json}"
    [[ -f "$_rr" ]] || _rr="$repo/.rebase-tmp/rebase-report.json"
    if [[ -f "$_rr" ]]; then
      echo "---REBASE-REPORT---"
      cat "$_rr"
    fi
  } > "$state_dir/done/$done_key"
  rm -f "$state_dir/running/$repo_key"

  # Return formatted line for summary table
  printf '%-20s %-42s %-8s %s' "$spec" "$short" "$verdict" "$detail"
}

# ── --auto-record (batch-record all completed runs) ───────────────

cmd_auto_record() {
  local state_dir="$PLUGIN_DIR/test/.matrix-state"
  local running_dir="$state_dir/running"

  if [[ ! -d "$running_dir" ]] || [[ -z "$(ls -A "$running_dir" 2>/dev/null)" ]]; then
    info "No running entries to process."
    return 0
  fi

  info "Checking session states..."
  local _ar_cache
  _ar_cache=$(_build_session_cache)

  local recorded=0 skipped_active=0 skipped_done=0 errored=0
  local -a summary=()

  for running_file in "$running_dir"/*; do
    [[ -f "$running_file" ]] || continue
    local repo_key spec repo short
    repo_key=$(basename "$running_file")
    spec=$(cat "$running_file")

    # Guard: empty entry
    if [[ -z "$spec" ]]; then
      warn "Empty running entry: $repo_key — removing"
      rm -f "$running_file"
      continue
    fi

    # Resolve path
    repo=$(_repo_from_key "$repo_key") || true
    if [[ -z "$repo" || ! -d "$repo" ]]; then
      warn "Cannot resolve repo for key: $repo_key — skipping"
      continue
    fi
    short=$(repo_short "$repo")

    # Idempotency: already recorded?
    local done_key="${spec//[:\/]/_}_$repo_key"
    if [[ -f "$state_dir/done/$done_key" ]]; then
      rm -f "$running_file"
      skipped_done=$((skipped_done + 1))
      info "SKIP (recorded): $spec on $short"
      continue
    fi

    # Still running?
    if _is_session_active "$short" "$_ar_cache"; then
      skipped_active=$((skipped_active + 1))
      info "SKIP (active): $spec on $short"
      continue
    fi

    # Record
    local result
    if result=$(_do_record_one "$repo" "$repo_key" "$spec" "$state_dir"); then
      recorded=$((recorded + 1))
      summary+=("$result")
      info "Recorded: $spec on $short"
    else
      errored=$((errored + 1))
      warn "Failed: $spec on $short — $result"
    fi
  done

  # Print summary
  echo ""
  info "── Auto-Record Summary ──"
  info "Recorded: $recorded | Active: $skipped_active | Already done: $skipped_done | Errors: $errored"

  if [[ ${#summary[@]} -gt 0 ]]; then
    echo ""
    printf "  %-20s %-42s %-8s %s\n" "SPEC" "REPO" "VERDICT" "DETAILS"
    printf "  %-20s %-42s %-8s %s\n" "----" "----" "-------" "-------"
    for line in "${summary[@]}"; do
      echo "  $line"
    done
  fi
}

# ── --matrix-status (show matrix progress) ─────────────────────────

cmd_matrix_status() {
  local state_dir="$PLUGIN_DIR/test/.matrix-state"
  [[ -d "$state_dir" ]] || die "No matrix state found. Run --without first."

  local done_count
  done_count=$(ls "$state_dir/done" 2>/dev/null | wc -l)
  local running_count
  running_count=$(ls "$state_dir/running" 2>/dev/null | wc -l)

  info "── Matrix Progress ──"
  info "Done: $done_count, Running: $running_count"
  echo ""

  if [[ -f "$state_dir/results.tsv" ]]; then
    echo "Recent results:"
    printf "  %-20s %-40s %-15s %s\n" "SPEC" "REPO" "VERDICT" "DETAILS"
    printf "  %-20s %-40s %-15s %s\n" "----" "----" "-------" "-------"
    tail -10 "$state_dir/results.tsv" 2>/dev/null | while IFS=$'\t' read -r ts spec repo verdict detail; do
      printf "  %-20s %-40s %-15s %s\n" "$spec" "$repo" "$verdict" "$detail"
    done
  fi

  if [[ -f "$state_dir/gate-findings.log" ]]; then
    echo ""
    echo "Gate findings requiring investigation:"
    cat "$state_dir/gate-findings.log"
  fi
}

# ── --cross-analyze (patterns across runs) ─────────────────────────

cmd_cross_analyze() {
  local state_dir="$PLUGIN_DIR/test/.matrix-state"
  local tsv="$state_dir/results.tsv"
  [[ -f "$tsv" ]] || die "No results.tsv found. Run --without first."

  local -A spec_pass spec_fail spec_total spec_done
  local -A repo_pass repo_fail repo_total repo_done
  local -A matrix detail_map
  local specs=() repos=()
  local -A seen_spec seen_repo

  while IFS=$'\t' read -r _ts spec repo verdict detail; do
    [[ -z "$spec" ]] && continue
    local v="UNKNOWN"
    case "$verdict" in
      *PASS*) v="PASS" ;; *FAIL*) v="FAIL" ;; *SKIP*) v="SKIP" ;;
      *DONE*) v="DONE" ;; *) v="?" ;;
    esac
    if [[ -z "${seen_spec[$spec]+x}" ]]; then seen_spec[$spec]=1; specs+=("$spec"); fi
    if [[ -z "${seen_repo[$repo]+x}" ]]; then seen_repo[$repo]=1; repos+=("$repo"); fi
    # On retry (same spec|repo seen again), undo the old verdict's count
    local key="$spec|$repo"
    if [[ -n "${matrix[$key]+x}" ]]; then
      local old_v="${matrix[$key]}"
      spec_total[$spec]=$(( ${spec_total[$spec]:-0} - 1 ))
      repo_total[$repo]=$(( ${repo_total[$repo]:-0} - 1 ))
      case "$old_v" in
        PASS) spec_pass[$spec]=$(( ${spec_pass[$spec]:-0} - 1 ))
               repo_pass[$repo]=$(( ${repo_pass[$repo]:-0} - 1 )) ;;
        DONE) spec_done[$spec]=$(( ${spec_done[$spec]:-0} - 1 ))
               repo_done[$repo]=$(( ${repo_done[$repo]:-0} - 1 )) ;;
        FAIL) spec_fail[$spec]=$(( ${spec_fail[$spec]:-0} - 1 ))
               repo_fail[$repo]=$(( ${repo_fail[$repo]:-0} - 1 )) ;;
      esac
    fi
    spec_total[$spec]=$(( ${spec_total[$spec]:-0} + 1 ))
    repo_total[$repo]=$(( ${repo_total[$repo]:-0} + 1 ))
    case "$v" in
      PASS) spec_pass[$spec]=$(( ${spec_pass[$spec]:-0} + 1 ))
             repo_pass[$repo]=$(( ${repo_pass[$repo]:-0} + 1 )) ;;
      DONE) spec_done[$spec]=$(( ${spec_done[$spec]:-0} + 1 ))
             repo_done[$repo]=$(( ${repo_done[$repo]:-0} + 1 )) ;;
      FAIL) spec_fail[$spec]=$(( ${spec_fail[$spec]:-0} + 1 ))
             repo_fail[$repo]=$(( ${repo_fail[$repo]:-0} + 1 )) ;;
    esac
    matrix["$key"]="$v"
  done < "$tsv"

  info "── Cross-Analysis: ${#specs[@]} specs x ${#repos[@]} repos ──"
  echo ""

  # ── Matrix table ──
  printf "%-22s" "SPEC"
  for r in "${repos[@]}"; do printf " %-6s" "${r##*/}"; done
  printf "  %s\n" "CLASS"
  printf '%0.s-' {1..100}; echo ""

  for s in "${specs[@]}"; do
    printf "%-22s" "$s"
    local p=${spec_pass[$s]:-0} f=${spec_fail[$s]:-0}
    for r in "${repos[@]}"; do
      printf " %-6s" "${matrix["$s|$r"]:-·}"
    done
    local class="NO-DATA"
    if [[ $f -eq 0 && $p -gt 0 ]]; then class="REDUNDANT"
    elif [[ $p -eq 0 && $f -gt 0 ]]; then class="ESSENTIAL"
    elif [[ $f -gt 0 && $p -gt 0 ]]; then class="MIXED"
    fi
    printf "  %s\n" "$class"
  done

  # ── Repo difficulty ranking ──
  echo ""
  info "Repo difficulty ranking (most failures first):"
  local repo_rankings=()
  for r in "${repos[@]}"; do
    local p=${repo_pass[$r]:-0} f=${repo_fail[$r]:-0} t=${repo_total[$r]:-0}
    local score=0
    [[ $t -gt 0 ]] && score=$(( (f * 100) / t ))
    repo_rankings+=("$score	$f	$p	$t	$r")
  done
  printf "  %-40s %-8s %-8s %-8s %-8s %s\n" "REPO" "FAIL" "PASS" "TOTAL" "FAIL%" "SELF-SUFFICIENCY"
  printf "  %-40s %-8s %-8s %-8s %-8s %s\n" "----" "----" "----" "-----" "-----" "----------------"
  printf '%s\n' "${repo_rankings[@]}" | sort -rn -t$'\t' -k1 | while IFS=$'\t' read -r score f p t r; do
    local ss_label="UNKNOWN"
    if [[ $t -lt 2 ]]; then ss_label="INSUFFICIENT-DATA"
    elif [[ $score -eq 0 ]]; then ss_label="HIGH"
    elif [[ $score -le 25 ]]; then ss_label="MODERATE"
    elif [[ $score -le 50 ]]; then ss_label="LOW"
    else ss_label="VERY-LOW"
    fi
    printf "  %-40s %-8d %-8d %-8d %-7d%% %s\n" "$r" "$f" "$p" "$t" "$score" "$ss_label"
  done

  # ── Coverage gap detection ──
  echo ""
  info "Coverage gaps (untested spec x repo combinations):"
  local gap_count=0
  local gap_lines=""
  for s in "${specs[@]}"; do
    for r in "${repos[@]}"; do
      if [[ -z "${matrix["$s|$r"]+x}" ]]; then
        gap_count=$((gap_count + 1))
        gap_lines+="  $s  x  ${r##*/}"$'\n'
      fi
    done
  done
  local total_cells=$(( ${#specs[@]} * ${#repos[@]} ))
  local tested_cells=$(( total_cells - gap_count ))
  info "Coverage: $tested_cells / $total_cells cells tested ($gap_count gaps)"
  if [[ $gap_count -gt 0 && $gap_count -le 30 ]]; then
    echo "$gap_lines"
  elif [[ $gap_count -gt 30 ]]; then
    echo "$gap_lines" | head -15
    info "  ... and $((gap_count - 15)) more gaps"
  fi

  # ── Recommended next tests ──
  echo ""
  info "Recommended next tests (priority order):"
  local rec_count=0
  # Priority 1: MIXED specs on untested repos (validate whether essential)
  for s in "${specs[@]}"; do
    local f=${spec_fail[$s]:-0} p=${spec_pass[$s]:-0}
    [[ $f -gt 0 && $p -gt 0 ]] || continue
    for r in "${repos[@]}"; do
      [[ -n "${matrix["$s|$r"]+x}" ]] && continue
      rec_count=$((rec_count + 1))
      [[ $rec_count -le 10 ]] && printf "  %d. %-20s on %-30s (MIXED spec — need tiebreaker)\n" "$rec_count" "$s" "${r##*/}"
    done
  done
  # Priority 2: ESSENTIAL specs on untested repos (confirm essential)
  for s in "${specs[@]}"; do
    local f=${spec_fail[$s]:-0} p=${spec_pass[$s]:-0}
    [[ $p -eq 0 && $f -gt 0 ]] || continue
    for r in "${repos[@]}"; do
      [[ -n "${matrix["$s|$r"]+x}" ]] && continue
      rec_count=$((rec_count + 1))
      [[ $rec_count -le 10 ]] && printf "  %d. %-20s on %-30s (ESSENTIAL — confirm universality)\n" "$rec_count" "$s" "${r##*/}"
    done
  done
  # Priority 3: REDUNDANT specs on high-failure repos (stress test)
  for s in "${specs[@]}"; do
    local f=${spec_fail[$s]:-0} p=${spec_pass[$s]:-0}
    [[ $f -eq 0 && $p -gt 0 ]] || continue
    for r in "${repos[@]}"; do
      [[ -n "${matrix["$s|$r"]+x}" ]] && continue
      local rf=${repo_fail[$r]:-0}
      [[ $rf -gt 0 ]] || continue
      rec_count=$((rec_count + 1))
      [[ $rec_count -le 10 ]] && printf "  %d. %-20s on %-30s (REDUNDANT spec + hard repo — stress test)\n" "$rec_count" "$s" "${r##*/}"
    done
  done
  [[ $rec_count -eq 0 ]] && info "  No gaps to fill — matrix is complete."

  # ── Machine-readable summary ──
  local summary_file="$state_dir/cross-analysis.json"
  {
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"matrix_size\": { \"specs\": ${#specs[@]}, \"repos\": ${#repos[@]}, \"cells_tested\": $tested_cells, \"cells_total\": $total_cells },"
    echo "  \"specs\": {"
    local first_spec=true
    for s in "${specs[@]}"; do
      $first_spec || echo ","
      first_spec=false
      local p=${spec_pass[$s]:-0} f=${spec_fail[$s]:-0} d=${spec_done[$s]:-0}
      local class="NO-DATA"
      if [[ $f -eq 0 && $p -gt 0 ]]; then class="REDUNDANT"
      elif [[ $p -eq 0 && $f -gt 0 ]]; then class="ESSENTIAL"
      elif [[ $f -gt 0 && $p -gt 0 ]]; then class="MIXED"
      fi
      printf '    "%s": { "pass": %d, "fail": %d, "done": %d, "class": "%s" }' "$s" "$p" "$f" "$d" "$class"
    done
    echo ""
    echo "  },"
    echo "  \"repos\": {"
    local first_repo=true
    for r in "${repos[@]}"; do
      $first_repo || echo ","
      first_repo=false
      local p=${repo_pass[$r]:-0} f=${repo_fail[$r]:-0} t=${repo_total[$r]:-0}
      local score=0
      [[ $t -gt 0 ]] && score=$(( (f * 100) / t ))
      printf '    "%s": { "pass": %d, "fail": %d, "total": %d, "fail_pct": %d }' "$r" "$p" "$f" "$t" "$score"
    done
    echo ""
    echo "  },"
    echo "  \"gap_count\": $gap_count"
    echo "}"
  } > "$summary_file"
  info "Machine-readable summary: $summary_file"

  # ── AI pattern analysis ──
  echo ""
  info "Launching AI pattern analysis..."

  # Build detail context for the subagent
  local detail_block=""
  while IFS=$'\t' read -r ts spec repo verdict detail; do
    [[ -z "$spec" ]] && continue
    detail_block+="$spec | $repo | $verdict | $detail"$'\n'
  done < "$tsv"

  local analysis_prompt="Analyze this k8s-rebase gate-hardening matrix (under 400 words).

MATRIX DATA (spec | repo | verdict | detail):
$detail_block

CLASSIFICATION RULES:
- ESSENTIAL: spec fails on ALL tested repos (knowledge is required)
- REDUNDANT: spec passes on ALL tested repos (agent discovers it independently)
- MIXED: spec fails on some, passes on others (repo-dependent)

ANALYSIS TASKS:
1. PATTERN DETECTION: Why do MIXED specs fail on some repos but not others?
   Look at the detail column for clues (e.g., 'agent discovered independently',
   'klog-v1-persisted'). What repo characteristics predict failure?

2. REPO DIFFICULTY: Which repos are hardest? Why? Look for patterns like
   'repo has older dependencies' or 'repo has more complex code patterns'.

3. ESSENTIAL KNOWLEDGE: For specs classified ESSENTIAL, is the knowledge truly
   undiscoverable, or did the agent just not try hard enough on those repos?

4. IMPROVEMENT TARGETS: Based on failure details, which autofix functions
   should be improved to make the agent MORE self-sufficient? Which pattern
   docs are genuinely teaching vs just hand-holding?

5. NEXT ACTIONS: What 3 specific test runs would yield the most information?

Format:
PATTERNS: <findings>
HARDEST_REPOS: <ranked with reasons>
ESSENTIAL_VERDICT: <which specs are truly essential>
IMPROVEMENTS: <numbered list>
NEXT_TESTS: <3 specific --without commands to run>"

  local ai_output
  ai_output=$(printf '%s' "$analysis_prompt" \
    | claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true

  if [[ -n "$ai_output" ]]; then
    echo ""
    info "── AI Analysis ──"
    echo "$ai_output"
    echo ""
    # Save analysis alongside summary
    echo "$ai_output" > "$state_dir/cross-analysis-ai.txt"
    info "AI analysis saved: $state_dir/cross-analysis-ai.txt"
  else
    warn "AI analysis failed (claude -p returned empty) — showing mechanical results only"
  fi
}

# ── --summary (generate markdown report from results.tsv) ────────

cmd_summary() {
  local state_dir="$PLUGIN_DIR/test/.matrix-state"
  local tsv="$state_dir/results.tsv"
  [[ -f "$tsv" ]] || die "No results.tsv found. Run tests first."

  # ── Parse results.tsv with last-entry-wins dedup ──
  local -A matrix detail_map
  local -A spec_pass spec_fail spec_done spec_total
  local -A repo_pass repo_fail repo_done repo_total
  local specs=() repos=()
  local -A seen_spec seen_repo

  while IFS=$'\t' read -r _ts spec repo verdict detail; do
    [[ -z "$spec" ]] && continue
    local v="?"
    case "$verdict" in
      *PASS*) v="PASS" ;; *FAIL*) v="FAIL" ;; *DONE*) v="DONE" ;; *SKIP*) v="SKIP" ;;
    esac
    if [[ -z "${seen_spec[$spec]+x}" ]]; then seen_spec[$spec]=1; specs+=("$spec"); fi
    if [[ -z "${seen_repo[$repo]+x}" ]]; then seen_repo[$repo]=1; repos+=("$repo"); fi

    # Undo previous entry for same spec|repo (retry dedup)
    local key="$spec|$repo"
    if [[ -n "${matrix[$key]+x}" ]]; then
      local old_v="${matrix[$key]}"
      spec_total[$spec]=$(( ${spec_total[$spec]:-0} - 1 ))
      repo_total[$repo]=$(( ${repo_total[$repo]:-0} - 1 ))
      case "$old_v" in
        PASS) spec_pass[$spec]=$(( ${spec_pass[$spec]:-0} - 1 )); repo_pass[$repo]=$(( ${repo_pass[$repo]:-0} - 1 )) ;;
        DONE) spec_done[$spec]=$(( ${spec_done[$spec]:-0} - 1 )); repo_done[$repo]=$(( ${repo_done[$repo]:-0} - 1 )) ;;
        FAIL) spec_fail[$spec]=$(( ${spec_fail[$spec]:-0} - 1 )); repo_fail[$repo]=$(( ${repo_fail[$repo]:-0} - 1 )) ;;
      esac
    fi

    spec_total[$spec]=$(( ${spec_total[$spec]:-0} + 1 ))
    repo_total[$repo]=$(( ${repo_total[$repo]:-0} + 1 ))
    case "$v" in
      PASS) spec_pass[$spec]=$(( ${spec_pass[$spec]:-0} + 1 )); repo_pass[$repo]=$(( ${repo_pass[$repo]:-0} + 1 )) ;;
      DONE) spec_done[$spec]=$(( ${spec_done[$spec]:-0} + 1 )); repo_done[$repo]=$(( ${repo_done[$repo]:-0} + 1 )) ;;
      FAIL) spec_fail[$spec]=$(( ${spec_fail[$spec]:-0} + 1 )); repo_fail[$repo]=$(( ${repo_fail[$repo]:-0} + 1 )) ;;
    esac
    matrix["$key"]="$v"
    detail_map["$key"]="$detail"
  done < "$tsv"

  # ── Derived stats ──
  local total_repos=${#repos[@]}
  local total_specs=${#specs[@]}
  local total_cells=$(( total_specs * total_repos ))
  local tested_cells=0
  for s in "${specs[@]}"; do
    for r in "${repos[@]}"; do
      [[ -n "${matrix["$s|$r"]+x}" ]] && tested_cells=$((tested_cells + 1))
    done
  done

  # Count repos with full-blind (all) test result
  local blind_repos=0 blind_pass=0
  for r in "${repos[@]}"; do
    [[ -n "${matrix["all|$r"]+x}" ]] || continue
    blind_repos=$((blind_repos + 1))
    [[ "${matrix["all|$r"]}" == "PASS" ]] && blind_pass=$((blind_pass + 1))
  done
  local blind_pct=0
  [[ $blind_repos -gt 0 ]] && blind_pct=$(( (blind_pass * 100) / blind_repos ))

  # Classify specs
  local -A spec_class
  local redundant_count=0 essential_count=0 mixed_count=0
  for s in "${specs[@]}"; do
    local p=${spec_pass[$s]:-0} f=${spec_fail[$s]:-0}
    if [[ $f -eq 0 && $p -gt 0 ]]; then
      spec_class[$s]="REDUNDANT"; redundant_count=$((redundant_count + 1))
    elif [[ $p -eq 0 && $f -gt 0 ]]; then
      spec_class[$s]="ESSENTIAL"; essential_count=$((essential_count + 1))
    elif [[ $f -gt 0 && $p -gt 0 ]]; then
      spec_class[$s]="MIXED"; mixed_count=$((mixed_count + 1))
    else
      spec_class[$s]="NO-DATA"
    fi
  done

  # ── Generate markdown ──
  cat <<HEADER
# K8s Rebase Skill: Gate-Hardening Matrix Report

## Executive Summary

**${total_repos} repos tested** across **${total_specs} knowledge specs**, producing **${tested_cells}/${total_cells} matrix cells**.

HEADER

  if [[ $blind_repos -gt 0 ]]; then
    cat <<BLIND
- **Full-blind self-sufficiency: ${blind_pass}/${blind_repos} repos (${blind_pct}%)** passed with all skill knowledge removed
BLIND
  fi

  cat <<STATS
- **${redundant_count} redundant** specs (agent always discovers independently)
- **${essential_count} essential** specs (agent always fails without them)
- **${mixed_count} mixed** specs (repo-dependent -- the interesting ones)

---

STATS

  # ── Section 2: Full-blind baseline ──
  echo "## Full-Blind Baseline (\`--without all\`)"
  echo ""
  echo "Each repo run with **all** patterns and autofix functions removed."
  echo ""
  echo "| Repo | Result | Detail |"
  echo "|------|--------|--------|"
  for r in "${repos[@]}"; do
    local short="${r##*/}"
    local v="${matrix["all|$r"]:-not tested}"
    local d="${detail_map["all|$r"]:-}"
    local icon="--"
    case "$v" in
      PASS) icon="PASS" ;; FAIL) icon="FAIL" ;; DONE) icon="DONE" ;;
      "not tested") icon="--" ;;
    esac
    echo "| \`$short\` | $icon | $d |"
  done
  echo ""

  # ── Section 3: Per-repo analysis ──
  echo "## Per-Repo Analysis"
  echo ""
  for r in "${repos[@]}"; do
    local short="${r##*/}"
    local rp=${repo_pass[$r]:-0} rf=${repo_fail[$r]:-0} rt=${repo_total[$r]:-0}
    local rpct=0
    [[ $rt -gt 0 ]] && rpct=$(( (rp * 100) / rt ))
    echo "### \`$short\`"
    echo ""
    echo "**${rp}/${rt} specs passed** (${rpct}% self-sufficient)"
    echo ""

    # What knowledge is needed (FAIL entries)
    local needed="" redundant_list=""
    for s in "${specs[@]}"; do
      local sv="${matrix["$s|$r"]:-}"
      local sd="${detail_map["$s|$r"]:-}"
      case "$sv" in
        FAIL) needed+="- \`$s\`: $sd"$'\n' ;;
        PASS) redundant_list+="- \`$s\`: $sd"$'\n' ;;
      esac
    done

    if [[ -n "$needed" ]]; then
      echo "**Knowledge needed** (failed without):"
      echo "$needed"
    fi
    if [[ -n "$redundant_list" ]]; then
      echo "<details><summary>Redundant knowledge (${rp} specs -- agent discovers independently)</summary>"
      echo ""
      echo "$redundant_list"
      echo "</details>"
      echo ""
    fi
  done

  # ── Section 4: Gate effectiveness ──
  echo "## Gate Effectiveness"
  echo ""
  echo "How each knowledge spec performed across all repos:"
  echo ""
  echo "| Spec | Class | Pass | Fail | Repos Tested | Notes |"
  echo "|------|-------|------|------|--------------|-------|"

  # Sort: ESSENTIAL first, then MIXED, then REDUNDANT
  local sorted_specs=()
  for s in "${specs[@]}"; do [[ "${spec_class[$s]}" == "ESSENTIAL" ]] && sorted_specs+=("$s"); done
  for s in "${specs[@]}"; do [[ "${spec_class[$s]}" == "MIXED" ]] && sorted_specs+=("$s"); done
  for s in "${specs[@]}"; do [[ "${spec_class[$s]}" == "REDUNDANT" ]] && sorted_specs+=("$s"); done
  for s in "${specs[@]}"; do [[ "${spec_class[$s]}" == "NO-DATA" ]] && sorted_specs+=("$s"); done

  for s in "${sorted_specs[@]}"; do
    local p=${spec_pass[$s]:-0} f=${spec_fail[$s]:-0} t=${spec_total[$s]:-0}
    # Collect detail notes for fail cases
    local notes=""
    for r in "${repos[@]}"; do
      local sv="${matrix["$s|$r"]:-}"
      if [[ "$sv" == "FAIL" ]]; then
        local sd="${detail_map["$s|$r"]:-}"
        # Extract short note (first word cluster after verdict info)
        local short_note
        short_note=$(echo "$sd" | grep -oE '[a-z][-a-z0-9_]*' | head -2 | tr '\n' ' ')
        [[ -n "$short_note" ]] && notes+="${r##*/}: ${short_note}; "
      fi
    done
    notes="${notes%; }"
    echo "| \`$s\` | ${spec_class[$s]} | $p | $f | $t | $notes |"
  done
  echo ""

  # ── Section 4b: Gates that always pass ──
  echo "### Always-Pass Gates (Simplification Candidates)"
  echo ""
  local always_pass_found=false
  for s in "${sorted_specs[@]}"; do
    if [[ "${spec_class[$s]}" == "REDUNDANT" && ${spec_total[$s]:-0} -ge 2 ]]; then
      always_pass_found=true
      local detail_samples=""
      for r in "${repos[@]}"; do
        [[ "${matrix["$s|$r"]:-}" == "PASS" ]] || continue
        local sd="${detail_map["$s|$r"]:-}"
        [[ -n "$sd" ]] && detail_samples+="  - \`${r##*/}\`: $sd"$'\n'
      done
      echo "- **\`$s\`** (${spec_total[$s]} repos, all PASS)"
      [[ -n "$detail_samples" ]] && echo "$detail_samples"
    fi
  done
  $always_pass_found || echo "None found with sufficient data (need 2+ repos tested)."
  echo ""

  # ── Section 4c: Gates that caught real issues ──
  echo "### Gates That Caught Real Issues"
  echo ""
  local caught_found=false
  for s in "${sorted_specs[@]}"; do
    local f=${spec_fail[$s]:-0}
    [[ $f -gt 0 ]] || continue
    caught_found=true
    echo "- **\`$s\`** (${spec_class[$s]}, failed on $f repo(s)):"
    for r in "${repos[@]}"; do
      [[ "${matrix["$s|$r"]:-}" == "FAIL" ]] || continue
      echo "  - \`${r##*/}\`: ${detail_map["$s|$r"]:-no detail}"
    done
  done
  $caught_found || echo "No failures recorded."
  echo ""

  # ── Section 5: Recommendations ──
  echo "## Recommendations"
  echo ""

  # 5a: Simplification candidates
  echo "### Simplification Candidates"
  echo ""
  echo "These autofix functions and patterns can potentially be removed or simplified"
  echo "because the agent consistently discovers them independently:"
  echo ""
  local rec_num=0
  for s in "${sorted_specs[@]}"; do
    [[ "${spec_class[$s]}" == "REDUNDANT" && ${spec_total[$s]:-0} -ge 2 ]] || continue
    rec_num=$((rec_num + 1))
    echo "${rec_num}. **\`$s\`** -- Passed on all ${spec_total[$s]} tested repos. The agent discovers this migration pattern without guidance."
  done
  [[ $rec_num -eq 0 ]] && echo "Insufficient data to make simplification recommendations."
  echo ""

  # 5b: Essential knowledge to preserve
  echo "### Essential Knowledge to Preserve"
  echo ""
  local ess_num=0
  for s in "${sorted_specs[@]}"; do
    [[ "${spec_class[$s]}" == "ESSENTIAL" ]] || continue
    ess_num=$((ess_num + 1))
    echo "${ess_num}. **\`$s\`** -- Failed on all ${spec_total[$s]} tested repos. This knowledge is required."
  done
  [[ $ess_num -eq 0 ]] && echo "No universally essential specs identified (all have at least one repo where the agent succeeds)."
  echo ""

  # 5c: Mixed specs requiring investigation
  echo "### Requiring Investigation (Mixed Results)"
  echo ""
  local mix_num=0
  for s in "${sorted_specs[@]}"; do
    [[ "${spec_class[$s]}" == "MIXED" ]] || continue
    mix_num=$((mix_num + 1))
    local p=${spec_pass[$s]:-0} f=${spec_fail[$s]:-0}
    echo "${mix_num}. **\`$s\`** -- Passed on $p, failed on $f repos. Investigate what repo characteristics cause failure."
    for r in "${repos[@]}"; do
      local sv="${matrix["$s|$r"]:-}"
      [[ "$sv" == "FAIL" ]] && echo "   - FAIL on \`${r##*/}\`: ${detail_map["$s|$r"]:-}"
    done
  done
  [[ $mix_num -eq 0 ]] && echo "No mixed results found."
  echo ""

  # 5d: Coverage gaps
  local gap_count=0
  for s in "${specs[@]}"; do
    for r in "${repos[@]}"; do
      [[ -z "${matrix["$s|$r"]+x}" ]] && gap_count=$((gap_count + 1))
    done
  done
  if [[ $gap_count -gt 0 ]]; then
    echo "### Coverage Gaps"
    echo ""
    echo "$gap_count of $total_cells matrix cells remain untested."
    echo ""
  fi

  # ── Full matrix (compact) ──
  echo "## Full Matrix"
  echo ""
  # Build header
  local hdr="| Spec |"
  local sep="|------|"
  for r in "${repos[@]}"; do
    local short="${r##*/}"
    # Abbreviate long names
    case "$short" in
      cloud-network-config-controller) short="cncc" ;;
      cluster-network-operator) short="cno" ;;
      ingress-node-firewall) short="inf" ;;
      ovn-kubernetes-mcp) short="mcp" ;;
      ovn-kubernetes) short="ovnk" ;;
      multus-cni) short="multus" ;;
    esac
    hdr+=" $short |"
    sep+="------|"
  done
  echo "$hdr"
  echo "$sep"

  for s in "${sorted_specs[@]}"; do
    local row="| \`$s\` |"
    for r in "${repos[@]}"; do
      local v="${matrix["$s|$r"]:-}"
      local cell="--"
      case "$v" in
        PASS) cell="PASS" ;; FAIL) cell="FAIL" ;; DONE) cell="DONE" ;;
      esac
      row+=" $cell |"
    done
    echo "$row"
  done
  echo ""

  echo "---"
  echo "*Generated by \`gate-hardening.sh --summary\` on $(date -u +%Y-%m-%dT%H:%M:%SZ)*"
}

# ── Main ──

usage() {
  echo "Usage: $(basename "$0") --without <spec...> <repo>      Run skill with knowledge removed"
  echo "       $(basename "$0") --compare <result> <known-good> <repo>  AI court: judge differences"
  echo "       $(basename "$0") --analyze <repo> [--context '...']     Deep gate report analysis"
  echo "       $(basename "$0") --cross-analyze                        Patterns across all runs"
  echo "       $(basename "$0") --summary                              Markdown report from results"
  echo "       $(basename "$0") --matrix-status                        Show matrix test progress"
  echo "       $(basename "$0") --record <repo>                         Record --without result"
  echo "       $(basename "$0") --auto-record                          Batch-record all completed runs"
  echo "       $(basename "$0") --list                                 Show removable knowledge"
}

case "${1:-}" in
  --list|-l)          cmd_list ;;
  --without)          shift; cmd_without "$@" ;;
  --compare)          shift; cmd_compare "$@" ;;
  --analyze)          shift; cmd_analyze "$@" ;;
  --cross-analyze)    cmd_cross_analyze ;;
  --summary)          cmd_summary ;;
  --record)           shift; cmd_record "$@" ;;
  --auto-record)      cmd_auto_record ;;
  --matrix-status)    cmd_matrix_status ;;
  --help|-h)          usage; exit 0 ;;
  *)                  usage; exit 1 ;;
esac
