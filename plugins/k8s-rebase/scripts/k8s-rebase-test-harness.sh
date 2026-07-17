#!/bin/bash
# k8s-rebase-test-harness.sh — Launch, monitor, and validate skill runs.
# Requires bash 4+ (associative arrays), Linux coreutils.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$PLUGIN_DIR/../.." 2>/dev/null && pwd || echo /tmp)/.work/test-harness}"
# bypassPermissions required — the skill runs bash scripts, go build, git ops.
# Only run against trusted repos.
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
VERBOSE=false

DEFAULT_REPOS=(
  "$HOME/ovnk/ovn-org/ovn-kubernetes"
  "$HOME/ovnk/ovn-kubernetes/ovn-kubernetes-mcp"
  "$HOME/ovnk/openshift/multus-cni"
  "$HOME/ovnk/openshift/ingress-node-firewall"
  "$HOME/ovnk/openshift/cloud-network-config-controller"
  "$HOME/ovnk/openshift/cluster-network-operator"
)

info()  { echo ":: $*"; }
warn()  { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }

repo_short() { local p="${1%/}"; echo "${p/#$HOME\/ovnk\//}"; }

# Restore repo to its original branch on interrupt
cleanup_repo=""
cleanup_head=""
trap_cleanup() {
  if [[ -n "$cleanup_repo" ]]; then
    warn "Interrupted — restoring $(repo_short "$cleanup_repo")"
    # Use checkout (not reset --hard) to avoid moving the current branch pointer
    # to a commit from a different branch
    git -C "$cleanup_repo" checkout "${cleanup_head:-HEAD}" &>/dev/null || true
    git -C "$cleanup_repo" clean -fd 2>/dev/null || true
  fi
}
trap trap_cleanup EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options] [args...]

Commands:
  run       <version> [repo...]            Launch skill runs
  status    [repo...]                      Sessions + branch progress
  stop      <repo...|--all>                Stop rebase sessions
  clean     [repo...]                      Remove leftover worktrees (git artifacts)
  compare   [--last] <repo>                Diff last two rebase branches
            <branch1> <branch2> <repo>     Diff specific branches

Options:
  -v, --verbose        Show commit subjects in status
  -h, --help           Show this help

Examples:
  $(basename "$0") run 1.36.2                   # All default repos
  $(basename "$0") run 1.36.2 ~/ovnk/ovn-org/ovn-kubernetes
  $(basename "$0") status                      # Quick overview of all repos
  $(basename "$0") -v status                   # Show commit subjects
  $(basename "$0") stop --all                  # Kill all harness sessions
  $(basename "$0") stop cluster-network-operator
  $(basename "$0") compare --last ~/ovnk/openshift/ingress-node-firewall
EOF
  exit 0
}

# ── Helpers ──────────────────────────────────────────────────────────

default_branch() {
  local b
  b=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  [[ -z "$b" ]] && b="main"
  git rev-parse --verify "$b" &>/dev/null || b="master"
  echo "$b"
}

list_bump_branches() {
  LC_ALL=C git branch --no-color | grep 'bump' | sed 's/^[* +]*//' | sort -V || true
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
  wt=$(git worktree list 2>/dev/null | grep -E "\[$branch( locked)?\]" | awk '{print $1}' | head -1)
  echo "${wt:-$repo}"
}

reset_to_default() {
  local repo="$1"
  cd "$repo" || die "Cannot cd to $repo"
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && die "Uncommitted changes in $repo — commit or stash first"

  cleanup_repo="$repo"
  cleanup_head=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse HEAD)
  local default_br
  default_br=$(default_branch)
  git checkout "$default_br" &>/dev/null || die "Cannot checkout $default_br in $repo"

  if ! GIT_TERMINAL_PROMPT=0 git pull --ff-only 2>/dev/null; then
    warn "git pull --ff-only failed in $(repo_short "$repo") — running against local $default_br"
  fi

  info "$(repo_short "$repo") -> $default_br @ $(git rev-parse --short HEAD)"
  cleanup_repo="" cleanup_head=""
}

remove_worktrees() {
  local repo="$1"
  cd "$repo" 2>/dev/null || return 1
  local wt_lines
  wt_lines=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' || true)
  [[ -z "$wt_lines" ]] && return 0
  local default_br
  default_br=$(default_branch)
  while IFS= read -r line; do
    local wt_path wt_branch
    wt_path=$(echo "$line" | awk '{print $1}')
    wt_branch=$(echo "$line" | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')

    local commit_count=0
    if [[ -n "$wt_branch" ]]; then
      commit_count=$(git rev-list --count "$default_br".."$wt_branch" 2>/dev/null || echo 0)
    fi

    git worktree unlock "$wt_path" 2>/dev/null || true
    # Check for uncommitted work before force-removing
    if [[ -d "$wt_path" ]] && [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
      warn "Worktree $wt_path has uncommitted changes — skipping (use git worktree remove --force manually)"
      continue
    fi
    git worktree remove "$wt_path" 2>/dev/null \
      || git worktree remove "$wt_path" --force 2>/dev/null \
      || { warn "Could not remove worktree: $wt_path (use git worktree remove --force manually)"; continue; }

    if [[ "$commit_count" -gt 0 ]]; then
      info "Removed worktree: $(basename "$wt_path") (branch $wt_branch preserved, $commit_count commits)"
    else
      # No commits — also delete the branch
      if [[ -n "$wt_branch" ]]; then
        git branch -D "$wt_branch" 2>/dev/null || true
        info "Removed worktree: $(basename "$wt_path") (empty branch deleted)"
      else
        info "Removed worktree: $(basename "$wt_path")"
      fi
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
    st = s.get('state') or s.get('status') or '?'
    pid = s.get('pid', '')
    full_sid = s.get('sessionId', '?')
    sid = s.get('id') or full_sid[:8]
    started = s.get('startedAt', 0)
    elapsed = max(0, int((now - started) / 60000)) if started else 0
    print(f'{cwd}\t{st}\t{elapsed}\t{pid}\t{sid}\t{full_sid}')
" 2>/dev/null || true)
}

session_for_repo() {
  local repo="$1" short line
  short=$(repo_short "$repo")
  # Match cwd ending with /short (+ tab separator) or containing /short/ (worktree)
  line=$(printf '%s\n' "$_session_cache" | grep -F "/${short}/" | head -1)
  if [[ -z "$line" ]]; then
    line=$(printf '%s\n' "$_session_cache" | grep -F $'/'"${short}"$'\t' | head -1)
  fi
  [[ -n "$line" ]] && echo "$line"
}

# ── run ──────────────────────────────────────────────────────────────

cmd_run() {
  command -v claude &>/dev/null || die "claude CLI not found in PATH"
  local version="$1"; shift
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be X.Y.Z (e.g., 1.36.2), got: $version"

  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")
  mkdir -p "$RESULTS_DIR" || die "Cannot create $RESULTS_DIR"

  local launched=0
  build_session_cache
  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || { warn "Not found: $repo"; continue; }
    local short
    short=$(repo_short "$repo")
    info "── $short ──"

    # Block on ANY session (including done) — it may still own a worktree
    local existing_session
    existing_session=$(session_for_repo "$repo")
    if [[ -n "$existing_session" ]]; then
      warn "Session found for $short — stop it first"
      continue
    fi

    remove_worktrees "$repo"
    reset_to_default "$repo"

    local base default_br
    default_br=$(default_branch)
    base=$(git rev-parse --short HEAD)
    info "Base: $default_br @ $base -> k8s $version"

    local session_output session_id launch_err
    launch_err="$RESULTS_DIR/launch-${short//\//-}.err"
    session_output=$(claude --bg \
      --plugin-dir "$PLUGIN_DIR" \
      --permission-mode "$PERMISSION_MODE" \
      "/k8s-rebase:k8s-rebase $version" 2>"$launch_err")
    session_id=$(echo "$session_output" | grep 'backgrounded' | grep -oE '[a-f0-9]{8,}' | head -1)
    : "${session_id:=unknown}"

    if [[ "$session_id" == "unknown" ]]; then
      error "Failed to launch session for $short"
      error "stdout: $session_output"
      [[ -s "$launch_err" ]] && error "stderr: $(cat "$launch_err")"
      warn "Check 'claude agents' for orphaned sessions"
      continue
    fi

    info "Launched $short -> session $session_id"
    launched=$((launched + 1))
    echo ""
  done

  if [[ "$launched" -gt 0 ]]; then
    echo ""
    info "Monitor progress:  $0 status"
    info "With commit list:  $0 -v status"
    info "Sessions typically complete in 15-45 minutes (idle = done)."
  else
    echo ""
    warn "No sessions launched — check warnings above"
  fi
}

# ── status ───────────────────────────────────────────────────────────

cmd_status() {
  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")

  build_session_cache

  printf "%-45s %7s %7s %18s %5s %s\n" "REPO" "COMMITS" "AUTOFIX" "SESSION" "GATES" "K8S"
  printf "%-45s %7s %7s %18s %5s %s\n" "----" "-------" "-------" "-------" "-----" "---"

  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || { warn "Not found: $repo"; continue; }
    local short branch wdir default_br
    short=$(repo_short "$repo")
    branch=$(find_newest_branch "$repo")

    # Resolve session state early — needed even when no branch exists yet
    local session_state="-"
    local session_info
    session_info=$(session_for_repo "$repo")
    if [[ -n "$session_info" ]]; then
      local tag mins
      tag=$(echo "$session_info" | cut -f2)
      mins=$(echo "$session_info" | cut -f3)
      [[ "$mins" =~ ^[0-9]+$ ]] && session_state="$tag ${mins}m"
    fi

    if [[ -z "$branch" ]]; then
      printf "%-45s %7s %7s %18s %5s %s\n" \
        "$short" "-" "-" "$session_state" "-" "-"
      continue
    fi

    cd "$repo" || continue
    wdir=$(work_dir_for "$repo" "$branch")
    default_br=$(default_branch)

    local commits applied
    commits=$(git rev-list --count "$default_br".."$branch" 2>/dev/null || echo 0)
    applied=$(git log "$default_br".."$branch" --format='%b' 2>/dev/null | grep -c 'Applied:' || true)

    local gates="-"
    local gate_dir="$wdir/.rebase-tmp/gates"
    if [[ -d "$gate_dir" ]]; then
      local gates_total gates_pass
      gates_total=$(find "$gate_dir" -name '*.report' 2>/dev/null | wc -l)
      gates_pass=$(find "$gate_dir" -name '*.report' -exec grep -lE '^(VERDICT|RESULT): PASS$' {} + 2>/dev/null | wc -l)
      [[ "$gates_total" -gt 0 ]] && gates="${gates_pass}/${gates_total}"
    fi

    local k8s_ver="?"
    k8s_ver=$(find "$wdir" -maxdepth 3 -name 'go.mod' -not -path '*/vendor/*' -print0 2>/dev/null \
      | xargs -0 -I{} awk '/k8s\.io\/api / && !/=>/ {print $2; exit}' {} 2>/dev/null | head -1)
    : "${k8s_ver:=?}"

    printf "%-45s %7s %7s %18s %5s %s\n" \
      "$short" "$commits" "$applied" "$session_state" "$gates" "$k8s_ver"

    if $VERBOSE; then
      git log "$default_br".."$branch" --oneline 2>/dev/null | sed 's/^/    /'
    fi
  done
}

# ── stop ─────────────────────────────────────────────────────────────

cmd_stop() {
  local targets=("$@")
  local stop_all=false

  if [[ ${#targets[@]} -eq 0 ]]; then
    die "Usage: $0 stop <repo...|--all>"
  fi

  case "${targets[0]}" in
    --all) stop_all=true; targets=() ;;
  esac

  build_session_cache
  [[ -z "$_session_cache" ]] && { info "No active sessions"; return 0; }

  # Build a set of PIDs in our own process tree to avoid self-kill.
  # This protects the claude session running the harness.
  local my_ancestors=""
  local _pid=$$
  while [[ -n "$_pid" && "$_pid" != "1" && "$_pid" != "0" ]]; do
    my_ancestors="$my_ancestors $_pid"
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
  done

  local killed=0
  while IFS=$'\t' read -r cwd tag elapsed pid sid full_sid; do
    [[ -z "$pid" ]] && continue
    # Skip any PID in our own ancestor chain
    if echo "$my_ancestors" | grep -qw "$pid"; then
      info "Skipping $sid (current harness session)"
      continue
    fi
    local should_stop=false

    if $stop_all; then
      # Only stop sessions whose CWD is under a DEFAULT_REPOS path
      for dr in "${DEFAULT_REPOS[@]}"; do
        local dr_short
        dr_short=$(repo_short "$dr")
        if [[ "$cwd" == *"/$dr_short" ]] || [[ "$cwd" == *"/$dr_short/"* ]]; then
          should_stop=true; break
        fi
      done
    else
      for t in "${targets[@]}"; do
        # Match session ID prefix or exact repo name in cwd path.
        # Use /$t/ or /$t at end — but exclude parent-dir matches by
        # requiring $t to be followed by / .claude or end-of-string
        if [[ "$sid" == "$t"* ]] || [[ "$cwd" == *"/$t" ]] || [[ "$cwd" == *"/$t/.claude"* ]]; then
          should_stop=true; break
        fi
      done
    fi

    if $should_stop; then
      # Use `claude stop` to halt session without destroying its worktree.
      # `claude rm` would delete the worktree — that belongs to `clean`.
      claude stop "${full_sid:-$sid}" 2>/dev/null \
        || { kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null || true; }
      local repo_name
      repo_name=$(echo "$cwd" | sed -e "s|$HOME/ovnk/||" -e 's|/\.claude/.*||')
      info "Stopped ${repo_name:-$cwd} [session $sid]"
      killed=$((killed + 1))
    fi
  done <<< "$_session_cache"

  [[ "$killed" -eq 0 ]] && info "No matching sessions found"
  return 0
}

# ── clean ────────────────────────────────────────────────────────────

cmd_clean() {
  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")

  build_session_cache
  local cleaned=0
  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || { warn "Not found: $repo"; continue; }
    # Block on ANY session (including done) — it may still own a worktree
    local short
    short=$(repo_short "$repo")
    local existing_session
    existing_session=$(session_for_repo "$repo")
    if [[ -n "$existing_session" ]]; then
      warn "Session on $short — skipping clean (stop it first)"
      continue
    fi
    cd "$repo" || continue
    git worktree prune 2>/dev/null || true
    local before after
    before=$(git worktree list 2>/dev/null | grep -c '\.claude/worktrees' || true)
    remove_worktrees "$repo"
    after=$(git worktree list 2>/dev/null | grep -c '\.claude/worktrees' || true)
    cleaned=$((cleaned + before - after))
  done

  [[ "$cleaned" -eq 0 ]] && info "Nothing to clean"
  return 0
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
    git rev-parse --verify "$branch_a" &>/dev/null || die "Branch not found: $branch_a"
    git rev-parse --verify "$branch_b" &>/dev/null || die "Branch not found: $branch_b"
    [[ "$branch_a" == "$branch_b" ]] && die "Both branches are the same: $branch_a"
  fi

  local default_br
  default_br=$(default_branch)

  info "── $(repo_short "$repo"): $branch_a vs $branch_b ──"
  echo ""

  printf "%-42s %7s %7s %s\n" "BRANCH" "COMMITS" "AUTOFIX" "K8S"
  printf "%-42s %7s %7s %s\n" "------" "-------" "-------" "---"
  for b in "$branch_a" "$branch_b"; do
    local commits applied k8s_ver
    commits=$(git rev-list --count "$default_br".."$b" 2>/dev/null || echo 0)
    applied=$(git log "$default_br".."$b" --format='%b' 2>/dev/null | grep -c 'Applied:' || true)
    k8s_ver=$(git show "$b":go.mod 2>/dev/null | awk '/k8s\.io\/api / && !/=>/ {print $2; exit}')
    [[ -z "$k8s_ver" ]] && k8s_ver=$(git show "$b":go-controller/go.mod 2>/dev/null | awk '/k8s\.io\/api / && !/=>/ {print $2; exit}')
    printf "%-42s %7s %7s %s\n" "$b" "$commits" "$applied" "${k8s_ver:-?}"
  done

  echo ""
  echo "File changes ($branch_a -> $branch_b):"
  git diff "$branch_a".."$branch_b" --stat 2>/dev/null | tail -3
  local new_count missing_count
  echo ""
  echo "New in $branch_b (not in $branch_a):"
  git log "$branch_a".."$branch_b" --oneline 2>/dev/null | head -10
  new_count=$(git rev-list --count "$branch_a".."$branch_b" 2>/dev/null || echo 0)
  [[ "$new_count" -gt 10 ]] && echo "  ... and $((new_count - 10)) more"
  echo ""
  echo "Missing from $branch_b (was in $branch_a):"
  git log "$branch_b".."$branch_a" --oneline 2>/dev/null | head -10
  missing_count=$(git rev-list --count "$branch_b".."$branch_a" 2>/dev/null || echo 0)
  [[ "$missing_count" -gt 10 ]] && echo "  ... and $((missing_count - 10)) more"
  return 0
}

# ── Main ─────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)      VERBOSE=true; shift ;;
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
  *)         die "Unknown command: $COMMAND" ;;
esac
