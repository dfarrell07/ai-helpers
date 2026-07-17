#!/bin/bash
# gate-hardening.sh — Test skill self-sufficiency by removing knowledge
# (patterns, autofix functions) and comparing the result to a known-good branch.
#
# Usage:
#   gate-hardening.sh --without <spec...> <repo>      Run skill with knowledge removed
#   gate-hardening.sh --compare <result> <known-good> <repo>  AI court: judge differences
#   gate-hardening.sh --list                          Show removable knowledge
#
# Examples:
#   gate-hardening.sh --without fn:xexp ~/ovnk/openshift/multus-cni
#   gate-hardening.sh --without all --version 1.36.2 ~/ovnk/openshift/multus-cni
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

  local diff_output
  diff_output=$(git diff "$result_branch" "$known_good" -- . ':!.rebase-tmp' 2>/dev/null)

  if [[ -z "$diff_output" ]]; then
    info "PASS: branches are identical (excluding .rebase-tmp)"
    return 0
  fi

  local hunk_count diff_stat
  hunk_count=$(echo "$diff_output" | grep -c '^@@' || true)
  diff_stat=$(git diff --stat "$result_branch" "$known_good" -- . ':!.rebase-tmp' 2>/dev/null)
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
    verdict=$(grep '^VERDICT:' "$f" 2>/dev/null | head -1)
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

  if [[ "$fail" -eq 0 && "$no_verdict" -eq 0 ]]; then
    info "All gates passed. No issues to analyze."
    return 0
  fi

  # Also gather branch info
  local branch
  branch=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1 | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')
  local default_br
  default_br=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo main)
  local commits=""
  if [[ -n "$branch" ]]; then
    commits=$(git log "${default_br}..${branch}" --oneline 2>/dev/null)
  fi

  # Launch analyst agent
  info "Launching deep analysis..."
  local analysis_prompt="You are analyzing gate results from a k8s-rebase skill run on $short.
"
  [[ -n "$mutation_context" ]] && analysis_prompt+="
MUTATION: This run was produced with this knowledge REMOVED: $mutation_context
"
  analysis_prompt+="
GATE RESULTS ($pass pass, $fail fail, $no_verdict no verdict out of $total):

$report_summary

COMMITS ON THE REBASE BRANCH:
$commits

ANALYSIS TASKS:
1. For each FAILED gate: Is the failure caused by the removed knowledge,
   or would it fail regardless? Is the gate prompt detecting the right thing?
2. For each NO VERDICT gate: Why didn't it produce a verdict? Is the gate
   prompt too complex? Did the subagent time out?
3. PATTERN DETECTION: Are multiple gates catching the same underlying issue?
   Is there redundancy? Are there gaps where NO gate catches an issue?
4. GATE IMPROVEMENT SUGGESTIONS: For each failure, suggest a specific
   improvement to the gate prompt that would make it more reliable.
   Be concrete — show the current wording and proposed replacement.
5. SELF-SUFFICIENCY ASSESSMENT: Based on the commits and gate results,
   can the agent handle this rebase without the removed knowledge?
   What specific knowledge is essential vs discoverable?

End with a structured summary:
ESSENTIAL_KNOWLEDGE: <list of fns/patterns the agent CANNOT discover>
DISCOVERABLE: <list of fns/patterns the agent CAN discover>
GATE_IMPROVEMENTS: <list of specific gate prompt changes to make>
VERDICT: SELF_SUFFICIENT or NEEDS_HELP"

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

  # Extract gate improvements if any
  local improvements
  improvements=$(echo "$analysis_output" | sed -n '/GATE_IMPROVEMENTS:/,/VERDICT:/p' | head -20)
  if [[ -n "$improvements" && "$improvements" != *"none"* && "$improvements" != *"None"* ]]; then
    info "Gate improvements suggested — review above"
    echo "$improvements" >> "$RESULTS_DIR/analyses/improvements.log" 2>/dev/null
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

# ── Main ──

usage() {
  echo "Usage: $(basename "$0") --without <spec...> <repo>      Run skill with knowledge removed"
  echo "       $(basename "$0") --compare <result> <known-good> <repo>  AI court: judge differences"
  echo "       $(basename "$0") --analyze <repo> [--context '...']     Deep gate report analysis"
  echo "       $(basename "$0") --matrix-status                        Show matrix test progress"
  echo "       $(basename "$0") --list                                 Show removable knowledge"
}

case "${1:-}" in
  --list|-l)          cmd_list ;;
  --without)          shift; cmd_without "$@" ;;
  --compare)          shift; cmd_compare "$@" ;;
  --analyze)          shift; cmd_analyze "$@" ;;
  --matrix-status)    cmd_matrix_status ;;
  --help|-h)          usage; exit 0 ;;
  *)                  usage; exit 1 ;;
esac
