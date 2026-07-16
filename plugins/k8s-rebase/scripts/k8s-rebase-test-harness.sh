#!/bin/bash
# Requires bash 4+ (associative arrays), Linux coreutils (sort -V, free, timeout).
# k8s-rebase-test-harness.sh — Launch, monitor, and validate skill runs
#
# Launches standalone Claude Code sessions (claude --bg) to run the
# k8s-rebase skill on target repos. Each session runs the full skill
# pipeline: scripts, subagents, gates, autofix, review.
#
# Usage: k8s-rebase-test-harness.sh <command> [options] [args...]
#
# Testing model:
#   run       — launch background Claude sessions, each running the full
#               k8s-rebase skill (deps, autofix, gates, review) in a worktree
#   status    — show progress: commits, autofix count (commits with "Applied:"
#               trailers marking which autofix function produced them)
#   compare   — diff two rebase branches to detect regressions between runs
#   gate-check — revert one autofix commit, re-run its gate, verify the gate
#               catches the regression (gate sensitivity/quality test)
#   stop/clean — tear down sessions (processes) and worktrees (git artifacts)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HARNESS_HOME="$(cd "$PLUGIN_DIR/../.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$HARNESS_HOME/.work/test-harness}"
# bypassPermissions required — the skill runs bash scripts, go build, git ops.
# This means .claude/ configs in target repos execute with full access.
# Only run against trusted repos.
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
BUILD=false
VERBOSE=false
MIN_AVAILABLE_MB=2048       # warn if less available before launching
STALE_SESSION_MINS=1440     # 24h — hide idle sessions older than this in status
MAX_SESSION_LOG=20          # trim sessions.jsonl to this many entries during clean
GATE_CHECK_TIMEOUT=300       # 5min — max time for a gate check in gate-check tests

DEFAULT_REPOS=(
  "$HOME/ovnk/ovn-org/ovn-kubernetes"
  "$HOME/ovnk/ovn-kubernetes/ovn-kubernetes-mcp"
  "$HOME/ovnk/openshift/multus-cni"
  "$HOME/ovnk/openshift/ingress-node-firewall"
  "$HOME/ovnk/openshift/cloud-network-config-controller"
  "$HOME/ovnk/openshift/cluster-network-operator"
)

# Maps autofix functions to the gate that should detect their absence.
# Used by `gate-check` to verify each gate catches regressions.
declare -A AUTOFIX_TO_GATE=(
  [fix_crd_int64_validation]="step3-autofix/crd-validation.md"
  [fix_crd_name_validation]="step3-autofix/crd-validation.md"
  [fix_feature_gates]="step3-autofix/feature-gates.md"
  [fix_xexp]="step3-autofix/deprecated-api-remnants.md"
  [fix_reflect_ptr]="step3-autofix/deprecated-api-remnants.md"
  [fix_fieldsv1]="step3-autofix/deprecated-api-remnants.md"
  [fix_klog_v2]="step3-autofix/deprecated-api-remnants.md"
  [fix_kind_image]="step4-verification/ci-prediction.md"
  [fix_lint_version]="step4-verification/ci-prediction.md"
  [fix_obsgen]="step3-autofix/patterns-completeness.md"
  [fix_conformance_renames]="step3-autofix/patterns-completeness.md"
)

info()  { echo ":: $*"; }
warn()  { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }

repo_short() { local p="${1%/}"; echo "${p/#$HOME\/ovnk\//}"; }

# Restore repo to its original branch on interrupt
cleanup_repo=""
trap_cleanup() {
  if [[ -n "$cleanup_repo" ]]; then
    warn "Interrupted — repo $(basename "$cleanup_repo") may need manual cleanup"
    warn "Check: git stash list, git worktree list, git status"
  fi
}
trap trap_cleanup EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options] [args...]

Commands:
  run       <version> [repo...]            Launch skill runs
  status    [repo...]                      Sessions + branch progress
  stop      [repo...|--all|--stuck]        Kill sessions (processes + registry)
  clean     [repo...]                      Remove leftover worktrees (git artifacts)
  compare   [--last] <repo>                Diff last two rebase branches
            <branch1> <branch2> <repo>     Diff specific branches
  gate-check <autofix-fn> <repo>            Revert one fix, verify gate catches it

Options:
  --build              Run go build/vet in status (off by default)
  -v, --verbose        Show commit subjects in status
  --plugin-dir D       Plugin path (default: auto-detected)
  --permission-mode M  Permission mode (default: bypassPermissions)
  --results-dir D      Results directory (default: .work/test-harness/)
  -h, --help           Show this help

Examples:
  $(basename "$0") run 1.36                    # All repos, auto-resolves to latest patch
  $(basename "$0") run 1.36.2 ~/ovnk/ovn-org/ovn-kubernetes
  $(basename "$0") status                      # Quick overview of all repos
  $(basename "$0") --build status              # Same but with go build/vet checks
  $(basename "$0") -v status                   # Show commit subjects
  $(basename "$0") stop --all                  # Kill all harness sessions
  $(basename "$0") stop cluster-network-operator
  $(basename "$0") compare --last ~/ovnk/openshift/ingress-node-firewall
  $(basename "$0") gate-check fix_xexp ~/ovnk/ovn-org/ovn-kubernetes

Sensitivity functions:
$(for fn in "${!AUTOFIX_TO_GATE[@]}"; do echo "  $fn → ${AUTOFIX_TO_GATE[$fn]}"; done | sort)
EOF
  exit 0
}

# ── Helpers ──────────────────────────────────────────────────────────

check_prerequisites() {
  command -v claude &>/dev/null || die "claude CLI not found in PATH"
  command -v python3 &>/dev/null || die "python3 not found in PATH"
  command -v git &>/dev/null || die "git not found in PATH"
  command -v curl &>/dev/null || die "curl not found in PATH"
  command -v timeout &>/dev/null || die "timeout not found in PATH (install coreutils)"

  local avail_mb
  avail_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $7}')
  if [[ -n "$avail_mb" && "$avail_mb" -lt "$MIN_AVAILABLE_MB" ]]; then
    warn "Low memory: ${avail_mb}MB available. Each session uses ~500MB + subagents."
    warn "Consider stopping other sessions first: $0 stop --all"
  fi
}

resolve_latest_patch() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "$version"; return; }
  local latest
  latest=$(curl -sf --retry 2 --connect-timeout 5 \
    "https://api.github.com/repos/kubernetes/kubernetes/releases" 2>/dev/null \
    | grep -oE '"tag_name": "v'"$version"'\.[0-9]+"' \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  if [[ -z "$latest" ]]; then
    warn "Could not resolve latest patch for $version (API rate limit?), using ${version}.0"
    echo "${version}.0"
  else
    echo "$latest"
  fi
}

default_branch() {
  local b
  b=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  [[ -z "$b" ]] && b="main"
  git rev-parse --verify "$b" &>/dev/null || b="master"
  echo "$b"
}

list_bump_branches() {
  LC_ALL=C git branch --no-color | grep 'bump' | sed 's/^[* +]*//' | tr -d ' ' | sort -V
}

find_newest_branch() {
  local repo="$1"
  cd "$repo" 2>/dev/null || return 1
  # Active worktrees take priority
  local wt_line
  wt_line=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1)
  if [[ -n "$wt_line" ]]; then
    local wt_branch
    wt_branch=$(echo "$wt_line" | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')
    [[ -n "$wt_branch" ]] && { echo "$wt_branch"; return 0; }
  fi
  # Fall back to bump branches (includes preserved worktree branches
  # that were renamed to bump* by the skill)
  list_bump_branches | tail -1
}

work_dir_for() {
  local repo="$1" branch="$2"
  cd "$repo" 2>/dev/null || return 1
  local wt
  wt=$(git worktree list 2>/dev/null | grep -F "$branch" | awk '{print $1}')
  echo "${wt:-$repo}"
}

primary_gomod() {
  local dir="$1" gomod
  dir=$(cd "$dir" 2>/dev/null && pwd) || return 1
  gomod=$(find "$dir" -maxdepth 3 -name 'go.mod' -not -path '*/vendor/*' -not -path '*/test/*' 2>/dev/null | head -1)
  [[ -z "$gomod" ]] && gomod=$(find "$dir" -maxdepth 3 -name 'go.mod' -not -path '*/vendor/*' 2>/dev/null | head -1)
  echo "$gomod"
}

reset_to_default() {
  local repo="$1"
  cleanup_repo="$repo"
  cd "$repo" || die "Cannot cd to $repo"

  if [[ -f "$repo/.git/MERGE_HEAD" ]]; then
    die "Merge in progress in $repo — resolve or abort (git merge --abort) first"
  fi
  if [[ -d "$repo/.git/rebase-merge" || -d "$repo/.git/rebase-apply" ]]; then
    die "Rebase in progress in $repo — resolve or abort (git rebase --abort) first"
  fi

  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    local stash_name="harness-$(date +%s)"
    if git stash push -u -m "$stash_name" 2>/dev/null; then
      warn "Stashed uncommitted changes as '$stash_name' — use 'git stash list' to recover"
    else
      die "Cannot stash uncommitted changes in $repo (git lock held?)"
    fi
  fi

  local default_br
  default_br=$(default_branch)
  git checkout "$default_br" 2>/dev/null || die "Cannot checkout $default_br in $repo"

  if ! git pull --ff-only 2>/dev/null; then
    warn "git pull --ff-only failed in $(basename "$repo") — running against local $default_br"
  fi

  info "$(basename "$repo") → $default_br @ $(git rev-parse --short HEAD)"
  cleanup_repo=""
}

remove_worktrees() {
  local repo="$1"
  cd "$repo" 2>/dev/null || return 1
  local wt_lines
  wt_lines=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' || true)
  [[ -z "$wt_lines" ]] && return 0
  while IFS= read -r line; do
    local wt_path wt_branch
    wt_path=$(echo "$line" | awk '{print $1}')
    wt_branch=$(echo "$line" | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')

    # Check if worktree has commits worth preserving
    local default_br commit_count=0
    default_br=$(default_branch)
    if [[ -n "$wt_branch" ]]; then
      commit_count=$(git log "$default_br".."$wt_branch" --oneline 2>/dev/null | wc -l)
    fi

    git worktree unlock "$wt_path" 2>/dev/null || true
    # Check for uncommitted work before force-removing
    if [[ -d "$wt_path" ]] && [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
      warn "Worktree $wt_path has uncommitted changes — skipping (use git worktree remove --force manually)"
      continue
    fi
    git worktree remove "$wt_path" 2>/dev/null \
      || git worktree remove "$wt_path" --force 2>/dev/null \
      || { warn "Could not remove worktree: $wt_path"; continue; }

    if [[ "$commit_count" -gt 0 ]]; then
      info "Removed worktree: $(basename "$wt_path") (branch $wt_branch preserved, $commit_count commits)"
    else
      # No commits — also delete the branch
      [[ -n "$wt_branch" ]] && git branch -D "$wt_branch" 2>/dev/null || true
      info "Removed worktree: $(basename "$wt_path") (empty branch deleted)"
    fi
  done <<< "$wt_lines"
}

_session_cache=""
build_session_cache() {
  _session_cache=$(timeout 10 claude agents --json 2>/dev/null | python3 -c "
import json, sys, time
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list):
        sys.exit(0)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)
now = time.time() * 1000
for s in data:
    cwd = s.get('cwd', '')
    st = s.get('status', '?')
    pid = s.get('pid') or ''
    full_sid = s.get('sessionId', '?')
    sid = full_sid[:12]
    wf = s.get('waitingFor', '')
    started = s.get('startedAt', 0)
    elapsed = int((now - started) / 60000) if started else 0
    tag = st + ('[' + wf[:6] + ']' if wf else '')
    print(f'{cwd}\t{tag}\t{elapsed}\t{pid}\t{sid}\t{full_sid}')
" 2>/dev/null || true)
}

session_for_repo() {
  local repo="$1" short
  short=$(repo_short "$repo")
  # Match on /short or /short/ to avoid ovn-kubernetes matching ovn-kubernetes-mcp
  echo "$_session_cache" | grep -F "/$short" | head -1
}

write_session_json() {
  printf '{"repo":"%s","version":"%s","sid":"%s","time":"%s","base":"%s"}\n' \
    "$1" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$4" \
    >> "$RESULTS_DIR/sessions.jsonl"
}

# ── run ──────────────────────────────────────────────────────────────

cmd_run() {
  check_prerequisites
  local version="$1"; shift
  local resolved
  resolved=$(resolve_latest_patch "$version")
  [[ "$resolved" != "$version" ]] && info "Resolved $version → $resolved"
  version="$resolved"

  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")
  mkdir -p "$RESULTS_DIR" || die "Cannot create $RESULTS_DIR"

  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || { error "Not found: $repo"; continue; }
    local short
    short=$(repo_short "$repo")
    local existing
    existing=$(cd "$repo" && list_bump_branches | wc -l)
    info "── $short ($existing prior runs) ──"

    # Check for active sessions on this repo to prevent races
    build_session_cache
    local active
    active=$(echo "$_session_cache" | grep -F "$short" | grep -v 'idle' | head -1 || true)
    if [[ -n "$active" ]]; then
      warn "Active session found for $short — stop it first or wait"
      continue
    fi

    remove_worktrees "$repo"
    reset_to_default "$repo"

    local base default_br
    default_br=$(default_branch)
    base=$(git rev-parse --short HEAD)
    info "Base: $default_br @ $base → k8s $version"

    local session_output session_id
    session_output=$(claude --bg \
      --plugin-dir "$PLUGIN_DIR" \
      --permission-mode "$PERMISSION_MODE" \
      "/k8s-rebase:k8s-rebase $version" 2>&1)
    session_id=$(echo "$session_output" | grep 'backgrounded' | grep -oE '[a-f0-9]{8,}' | head -1)
    : "${session_id:=unknown}"

    if [[ "$session_id" == "unknown" ]]; then
      error "Failed to launch session for $short"
      error "claude --bg output: $session_output"
      warn "Check 'claude agents' for orphaned sessions"
      continue
    fi

    write_session_json "$short" "$version" "$session_id" "$base"
    info "Launched $session_id"
    echo ""
  done
}

# ── status ───────────────────────────────────────────────────────────

cmd_status() {
  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")

  uptime | grep -oE 'load average:.*'
  free -h | grep Mem | awk '{printf "Memory: %s used, %s available\n", $3, $7}'
  echo ""

  build_session_cache

  printf "%-45s %7s %7s %18s %5s %5s %s\n" "REPO" "COMMITS" "APPLIED" "SESSION" "BUILD" "VET" "K8S"
  printf "%-45s %7s %7s %18s %5s %5s %s\n" "----" "-------" "-------" "-------" "-----" "---" "---"

  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || continue
    local short branch wdir default_br
    short=$(repo_short "$repo")
    branch=$(find_newest_branch "$repo")

    if [[ -z "$branch" ]]; then
      printf "%-40s %s\n" "$short" "(no branch)"
      continue
    fi

    cd "$repo" || continue
    wdir=$(work_dir_for "$repo" "$branch")
    default_br=$(default_branch)

    local commits applied
    commits=$(git log "$default_br".."$branch" --oneline 2>/dev/null | wc -l)
    applied=$(git log "$default_br".."$branch" --format='%b' 2>/dev/null | grep -c 'Applied:' || true)

    local session_state="—"
    local session_info
    session_info=$(session_for_repo "$repo")
    if [[ -n "$session_info" ]]; then
      local tag mins
      tag=$(echo "$session_info" | cut -f2)
      mins=$(echo "$session_info" | cut -f3)
      if [[ "$mins" =~ ^[0-9]+$ ]] && { [[ "$tag" != *"idle"* ]] || [[ "$mins" -lt "$STALE_SESSION_MINS" ]]; }; then
        session_state="$tag ${mins}m"
      fi
    fi

    local gomod k8s_ver="?" build_ok="—" vet_ok="—"
    gomod=$(primary_gomod "$wdir")
    if [[ -n "$gomod" ]]; then
      k8s_ver=$(grep 'k8s.io/api ' "$gomod" 2>/dev/null | grep -v '=>' | head -1 | awk '{print $2}')
      : "${k8s_ver:=?}"
    fi

    if $BUILD && [[ -n "$gomod" ]]; then
      local gomod_dir build_err
      gomod_dir=$(dirname "$gomod")
      # Verify we're testing the rebase branch, not main (worktree may have been cleaned)
      local actual_branch
      actual_branch=$(git -C "$gomod_dir" branch --show-current 2>/dev/null)
      if [[ -n "$actual_branch" && "$actual_branch" != "$branch" ]]; then
        warn "Build check skipped for $short — worktree gone, would test $actual_branch not $branch"
        build_ok="SKIP"; vet_ok="SKIP"
      else
        build_err=$(cd "$gomod_dir" && GOTOOLCHAIN=auto go build ./... 2>&1) && build_ok="PASS" || { build_ok="FAIL"; echo "$build_err" | tail -5 | sed 's/^/      /' >&2; }
        build_err=$(cd "$gomod_dir" && GOTOOLCHAIN=auto go vet ./... 2>&1) && vet_ok="PASS" || { vet_ok="FAIL"; echo "$build_err" | tail -5 | sed 's/^/      /' >&2; }
      fi
    fi

    printf "%-45s %7s %7s %18s %5s %5s %s\n" \
      "$short" "$commits" "$applied" "$session_state" "$build_ok" "$vet_ok" "$k8s_ver"

    if $VERBOSE; then
      git log "$default_br".."$branch" --oneline 2>/dev/null | sed 's/^/    /'
    fi
  done
}

# ── stop ─────────────────────────────────────────────────────────────

cmd_stop() {
  local targets=("$@")
  local stop_all=false stop_stuck=false

  if [[ ${#targets[@]} -eq 0 ]]; then
    die "Usage: $0 stop [repo...|--all|--stuck]"
  fi

  case "${targets[0]}" in
    --all)   stop_all=true; targets=() ;;
    --stuck) stop_stuck=true; targets=() ;;
  esac

  build_session_cache
  [[ -z "$_session_cache" ]] && { info "No active sessions"; return 0; }

  # Build a set of PIDs in our own process tree to avoid self-kill.
  # This protects the claude session running the harness.
  local my_pid=$$
  local my_ancestors=""
  local _pid="$my_pid"
  while [[ -n "$_pid" && "$_pid" != "1" && "$_pid" != "0" ]]; do
    my_ancestors="$my_ancestors $_pid"
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
  done

  local killed=0
  while IFS=$'\t' read -r cwd tag _elapsed pid sid full_sid; do
    [[ -z "$pid" ]] && continue
    # Skip any PID in our own ancestor chain
    if echo "$my_ancestors" | grep -qw "$pid"; then
      info "Skipping $sid — in our process tree"
      continue
    fi
    local should_stop=false

    if $stop_all; then
      should_stop=true
    elif $stop_stuck; then
      [[ "$tag" == *"waiting"* ]] && should_stop=true
    else
      for t in "${targets[@]}"; do
        if [[ "$sid" == "$t"* ]] || [[ "$cwd" == *"/$t" ]] || [[ "$cwd" == *"/$t/"* ]]; then
          should_stop=true; break
        fi
      done
    fi

    if $should_stop; then
      local ppid
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      # SIGTERM first, then SIGKILL after brief grace
      if [[ -n "$ppid" && "$ppid" != "1" ]] && ! echo "$my_ancestors" | grep -qw "$ppid"; then
        kill "$ppid" 2>/dev/null; sleep 1; kill -9 "$ppid" 2>/dev/null || true
      fi
      kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null || true
      claude rm "${full_sid:-$sid}" 2>/dev/null || true
      info "Killed $sid ($tag) — $cwd"
      killed=$((killed + 1))
    fi
  done <<< "$_session_cache"

  [[ "$killed" -eq 0 ]] && info "No matching sessions found"
}

# ── clean ────────────────────────────────────────────────────────────

cmd_clean() {
  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")

  local cleaned=0
  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || continue
    cd "$repo" || continue
    git worktree prune 2>/dev/null || true
    local before after
    before=$(git worktree list 2>/dev/null | grep -c '\.claude/worktrees' || true)
    remove_worktrees "$repo"
    after=$(git worktree list 2>/dev/null | grep -c '\.claude/worktrees' || true)
    cleaned=$((cleaned + before - after))
  done

  if [[ -f "$RESULTS_DIR/sessions.jsonl" ]]; then
    local count
    count=$(wc -l < "$RESULTS_DIR/sessions.jsonl")
    if [[ "$count" -gt "$MAX_SESSION_LOG" ]]; then
      tail -"$MAX_SESSION_LOG" "$RESULTS_DIR/sessions.jsonl" > "$RESULTS_DIR/sessions.jsonl.tmp"
      mv "$RESULTS_DIR/sessions.jsonl.tmp" "$RESULTS_DIR/sessions.jsonl"
      info "Trimmed session log to last 20 entries"
    fi
  fi

  [[ "$cleaned" -eq 0 ]] && info "Nothing to clean"
}

# ── compare ──────────────────────────────────────────────────────────

cmd_compare() {
  local branch_a branch_b repo

  if [[ "$1" == "--last" ]]; then
    [[ $# -lt 2 ]] && die "Usage: compare --last <repo>"
    repo="$2"
    cd "$repo" || die "Cannot cd to $repo"
    local branches
    branches=$(list_bump_branches | tail -2)
    branch_a=$(echo "$branches" | head -1)
    branch_b=$(echo "$branches" | tail -1)
    [[ -z "$branch_a" || -z "$branch_b" || "$branch_a" == "$branch_b" ]] && die "Need at least 2 bump branches in $repo (run the skill twice first)"
  else
    [[ $# -lt 3 ]] && die "Usage: compare <branch1> <branch2> <repo>"
    branch_a="$1" branch_b="$2" repo="$3"
    cd "$repo" || die "Cannot cd to $repo"
  fi

  local default_br
  default_br=$(default_branch)

  info "── $(repo_short "$repo"): $branch_a vs $branch_b ──"
  echo ""

  printf "%-42s %6s %7s %s\n" "BRANCH" "COMMITS" "APPLIED" "K8S"
  printf "%-42s %6s %7s %s\n" "------" "-------" "-------" "---"
  for b in "$branch_a" "$branch_b"; do
    local commits applied k8s_ver
    commits=$(git log "$default_br".."$b" --oneline 2>/dev/null | wc -l)
    applied=$(git log "$default_br".."$b" --format='%b' 2>/dev/null | grep -c 'Applied:' || true)
    k8s_ver=$(git show "$b":go.mod 2>/dev/null | grep 'k8s.io/api ' | grep -v '=>' | head -1 | awk '{print $2}')
    [[ -z "$k8s_ver" ]] && k8s_ver=$(git show "$b":go-controller/go.mod 2>/dev/null | grep 'k8s.io/api ' | grep -v '=>' | head -1 | awk '{print $2}')
    printf "%-42s %6s %7s %s\n" "$b" "$commits" "$applied" "${k8s_ver:-?}"
  done

  echo ""
  echo "Diff:"
  git diff "$branch_a".."$branch_b" --stat 2>/dev/null | tail -3
  echo ""
  echo "Only in $branch_b:"
  git log "$branch_a".."$branch_b" --oneline 2>/dev/null | head -10
  echo ""
  echo "Only in $branch_a:"
  git log "$branch_b".."$branch_a" --oneline 2>/dev/null | head -10
}

# ── gate-check ────────────────────────────────────────────────────────

cmd_gate_check() {
  check_prerequisites
  local fix_func="$1" repo="$2"
  [[ -z "${AUTOFIX_TO_GATE[$fix_func]+x}" ]] && die "Unknown sensitivity function: $fix_func (run --help to list available)"

  local gate_file="$PLUGIN_DIR/gates/${AUTOFIX_TO_GATE[$fix_func]}"
  [[ -f "$gate_file" ]] || die "Gate not found: $gate_file"

  cd "$repo" || die "Cannot cd to $repo"
  local short branch
  short=$(repo_short "$repo")
  branch=$(git branch --show-current 2>/dev/null)

  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && die "Dirty worktree in $repo — commit or stash first"
  [[ "$branch" =~ ^(main|master)$ ]] && die "On $branch — checkout a rebase branch first"

  info "── Sensitivity: $fix_func on $short ($branch) ──"

  # Use --fixed-strings so function names aren't interpreted as regex
  local commit
  commit=$(git log --format='%H' --fixed-strings --grep="Applied: $fix_func" | head -1)
  [[ -z "$commit" ]] && commit=$(git log --format='%H' --fixed-strings --grep="$fix_func" | head -1)
  [[ -z "$commit" ]] && { info "SKIP: no commit for $fix_func (autofix may not have fired on this repo)"; return 0; }

  info "Reverting $(git log --oneline -1 "$commit")"
  if ! git revert --no-commit "$commit" 2>/dev/null; then
    info "SKIP: revert conflicts (later commits modified the same files)"
    git revert --abort 2>/dev/null || git checkout -- . 2>/dev/null
    return 0
  fi

  info "Running gate: ${AUTOFIX_TO_GATE[$fix_func]}"
  mkdir -p "$RESULTS_DIR/gate-check"
  local outfile="$RESULTS_DIR/gate-check/${fix_func}-$(basename "$repo")-$(date +%s).txt"

  # Read gate content up front so failures are caught before claude runs
  local gate_content
  gate_content=$(cat "$gate_file") || {
    git reset --hard HEAD 2>/dev/null
    die "Cannot read gate file: $gate_file"
  }

  # Request a structured verdict line instead of parsing free-form prose.
  # The old approach used a regex on LLM output (e.g. matching "3 issues",
  # "FAIL", or "file.go:42") which produced false PASS on incidental matches
  # and false FAIL when the LLM rephrased its findings.
  local prompt
  prompt=$(printf 'Repo: %s\n\n%s\n\n%s' \
    "$repo" "$gate_content" \
    "After your analysis, end with exactly one of these on its own line:
VERDICT: ISSUES_FOUND
VERDICT: CLEAN")

  local output exit_code=0
  output=$(printf '%s' "$prompt" \
    | timeout "$GATE_CHECK_TIMEOUT" claude -p --output-format text 2>/dev/null) \
    || exit_code=$?

  # Always restore the working tree after the gate check
  git reset --hard HEAD 2>/dev/null || warn "git reset failed — repo may be dirty"

  if [[ "$exit_code" -eq 124 ]]; then
    error "TIMEOUT: gate exceeded ${GATE_CHECK_TIMEOUT}s (output: $outfile)"
    echo "TIMEOUT after ${GATE_CHECK_TIMEOUT}s" > "$outfile"
    return 1
  fi
  if [[ -z "$output" ]]; then
    error "EMPTY: claude -p returned no output (output: $outfile)"
    echo "EMPTY OUTPUT" > "$outfile"
    return 1
  fi

  echo "$output" > "$outfile"
  echo "$output" | tail -15
  echo ""

  # Match the structured verdict instead of guessing from prose
  local verdict
  verdict=$(echo "$output" | grep -oE '^VERDICT: (ISSUES_FOUND|CLEAN)$' | tail -1)

  case "$verdict" in
    "VERDICT: ISSUES_FOUND")
      info "PASS: gate caught $fix_func (output: $outfile)" ;;
    "VERDICT: CLEAN")
      error "FAIL: gate missed $fix_func (output: $outfile)"; return 1 ;;
    *)
      error "INCONCLUSIVE: no VERDICT line in output (output: $outfile)"
      error "Manual review required"; return 1 ;;
  esac
}

# ── Main ─────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)           BUILD=true; shift ;;
    -v|--verbose)      VERBOSE=true; shift ;;
    --plugin-dir)      PLUGIN_DIR="$2"; shift 2 ;;
    --permission-mode) PERMISSION_MODE="$2"; shift 2 ;;
    --results-dir)     RESULTS_DIR="$2"; shift 2 ;;
    -h|--help)         usage ;;
    -*)                die "Unknown option: $1" ;;
    *)                 break ;;
  esac
done

[[ $# -eq 0 ]] && usage

COMMAND="$1"; shift
case "$COMMAND" in
  run)       [[ $# -lt 1 ]] && die "Usage: $0 run <version> [repo...]"
             cmd_run "$1" "${@:2}" ;;
  status)    cmd_status "$@" ;;
  stop)      cmd_stop "$@" ;;
  clean)     cmd_clean "$@" ;;
  compare)   [[ $# -lt 1 ]] && die "Usage: $0 compare [--last] <repo> or <b1> <b2> <repo>"
             cmd_compare "$@" ;;
  gate-check) [[ $# -lt 2 ]] && die "Usage: $0 gate-check <autofix-fn> <repo>"
             cmd_gate_check "$1" "$2" ;;
  *)         die "Unknown command: $COMMAND" ;;
esac
