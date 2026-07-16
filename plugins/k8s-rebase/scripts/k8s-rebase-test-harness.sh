#!/bin/bash
# k8s-rebase-test-harness.sh — Launch, monitor, and validate skill runs
#
# Launches standalone Claude Code sessions (claude --bg) to run the
# k8s-rebase skill on target repos. Each session runs the full skill
# pipeline: scripts, subagents, gates, autofix, review.
#
# Usage: k8s-rebase-test-harness.sh <command> [options] [args...]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HARNESS_HOME="$(cd "$PLUGIN_DIR/../.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$HARNESS_HOME/.work/test-harness}"
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
BUILD=false
VERBOSE=false

DEFAULT_REPOS=(
  "$HOME/ovnk/ovn-org/ovn-kubernetes"
  "$HOME/ovnk/ovn-kubernetes/ovn-kubernetes-mcp"
  "$HOME/ovnk/openshift/multus-cni"
  "$HOME/ovnk/openshift/ingress-node-firewall"
  "$HOME/ovnk/openshift/cloud-network-config-controller"
  "$HOME/ovnk/openshift/cluster-network-operator"
)

declare -A SENSITIVITY_MAP=(
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
error() { echo "ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }

repo_short() { echo "${1/#$HOME\/ovnk\//}"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options] [args...]

Commands:
  run       <version> [repo...]            Launch skill runs
  status    [repo...]                      Sessions + branch progress
  stop      [repo...|--all|--stuck]        Kill sessions
  clean     [repo...]                      Remove leftover worktrees
  compare   <branch1> <branch2> <repo>     Diff two rebase branches
  sensitive <autofix-fn> <repo>            Revert one fix, verify gate catches it

Options:
  --build              Run go build/vet in status (off by default)
  -v, --verbose        Show commit subjects in status
  --plugin-dir D       Plugin path (default: auto-detected)
  --permission-mode M  Permission mode (default: bypassPermissions)
  --results-dir D      Results directory (default: .work/test-harness/)
  -h, --help           Show this help

Sensitivity functions:
$(for fn in "${!SENSITIVITY_MAP[@]}"; do echo "  $fn → ${SENSITIVITY_MAP[$fn]}"; done | sort)
EOF
  exit 0
}

# ── Helpers ──────────────────────────────────────────────────────────

resolve_latest_patch() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "$version"; return; }
  local latest
  latest=$(curl -sf --retry 2 --connect-timeout 5 \
    "https://api.github.com/repos/kubernetes/kubernetes/releases" 2>/dev/null \
    | grep -oE '"tag_name": "v'"$version"'\.[0-9]+"' \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  echo "${latest:-$version}"
}

default_branch() {
  local b
  b=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  [[ -z "$b" ]] && b="main"
  git rev-parse --verify "$b" &>/dev/null || b="master"
  echo "$b"
}

find_latest_branch() {
  local repo="$1"
  cd "$repo" 2>/dev/null || return 1
  local wt_line
  wt_line=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1)
  if [[ -n "$wt_line" ]]; then
    local wt_branch
    wt_branch=$(echo "$wt_line" | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')
    [[ -n "$wt_branch" ]] && { echo "$wt_branch"; return 0; }
  fi
  git branch | grep 'bump' | sed 's/^[* ]*//' | sort -t- -k3 | tail -1
}

work_dir_for() {
  local repo="$1" branch="$2"
  cd "$repo" 2>/dev/null || return 1
  local wt
  wt=$(git worktree list 2>/dev/null | grep "$branch" | awk '{print $1}')
  echo "${wt:-$repo}"
}

primary_gomod() {
  local dir="$1"
  find "$dir" -maxdepth 3 -name 'go.mod' -not -path '*/vendor/*' -not -path '*/test/*' 2>/dev/null | head -1 \
    || find "$dir" -maxdepth 3 -name 'go.mod' -not -path '*/vendor/*' 2>/dev/null | head -1
}

reset_to_main() {
  local repo="$1"
  cd "$repo" || die "Cannot cd to $repo"
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && {
    git stash push -u -m "harness-$(date +%s)" 2>/dev/null || true
  }
  local db
  db=$(default_branch)
  git checkout "$db" 2>/dev/null || die "Cannot checkout $db"
  git pull --ff-only 2>/dev/null || true
  info "$(basename "$repo") → $db @ $(git rev-parse --short HEAD)"
}

# Build a session lookup from claude agents (called once, reused)
_session_cache=""
build_session_cache() {
  _session_cache=$(claude agents --json 2>/dev/null | python3 -c "
import json, sys, time
now = time.time() * 1000
for s in json.load(sys.stdin):
    cwd = s.get('cwd', '')
    st = s.get('status', '?')
    pid = s.get('pid', '')
    full_sid = s.get('sessionId', '?')
    sid = full_sid[:12]
    wf = s.get('waitingFor', '')
    started = s.get('startedAt', 0)
    elapsed = int((now - started) / 60000) if started else 0
    tag = st + ('[' + wf[:6] + ']' if wf else '')
    print(f'{cwd}\t{tag}\t{elapsed}m\t{pid}\t{sid}\t{full_sid}')
" 2>/dev/null || true)
}

session_for_repo() {
  local repo="$1"
  local short
  short=$(repo_short "$repo")
  echo "$_session_cache" | grep -F "$short" | head -1
}

# ── run ──────────────────────────────────────────────────────────────

cmd_run() {
  local version="$1"; shift
  local resolved
  resolved=$(resolve_latest_patch "$version")
  [[ "$resolved" != "$version" ]] && info "Resolved $version → $resolved"
  version="$resolved"

  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")
  mkdir -p "$RESULTS_DIR"

  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || { error "Not found: $repo"; continue; }
    local short
    short=$(repo_short "$repo")
    local existing
    existing=$(cd "$repo" && git branch | grep -c 'bump' || true)
    info "── $short ($existing prior runs) ──"

    reset_to_main "$repo"

    local session_output session_id base
    base=$(git rev-parse --short HEAD)
    session_output=$(claude --bg \
      --plugin-dir "$PLUGIN_DIR" \
      --permission-mode "$PERMISSION_MODE" \
      "/k8s-rebase:k8s-rebase $version" 2>&1)
    session_id=$(echo "$session_output" | grep 'backgrounded' | grep -oE '[a-f0-9]{8,}' | head -1)
    : "${session_id:=unknown}"

    printf '{"repo":"%s","version":"%s","sid":"%s","time":"%s","base":"%s"}\n' \
      "$short" "$version" "$session_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base" \
      >> "$RESULTS_DIR/sessions.jsonl"

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

  printf "%-40s %4s %4s %15s %5s %5s %s\n" "REPO" "CMT" "AUTO" "SESSION" "BUILD" "VET" "K8S"
  printf "%-40s %4s %4s %15s %5s %5s %s\n" "----" "---" "----" "-------" "-----" "---" "---"

  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || continue
    local short branch wdir db
    short=$(repo_short "$repo")
    branch=$(find_latest_branch "$repo")

    if [[ -z "$branch" ]]; then
      printf "%-40s %s\n" "$short" "(no branch)"
      continue
    fi

    cd "$repo" || continue
    wdir=$(work_dir_for "$repo" "$branch")
    db=$(default_branch)

    local commits applied
    commits=$(git log "$db".."$branch" --oneline 2>/dev/null | wc -l | tr -d ' ')
    applied=$(git log "$db".."$branch" --format='%b' 2>/dev/null | grep -c 'Applied:' || true)

    local session_info session_state="—"
    session_info=$(session_for_repo "$repo")
    [[ -n "$session_info" ]] && {
      local tag elapsed
      tag=$(echo "$session_info" | cut -f2)
      elapsed=$(echo "$session_info" | cut -f3)
      session_state="$tag $elapsed"
    }

    local gomod k8s_ver="?" build_ok="—" vet_ok="—"
    gomod=$(primary_gomod "$wdir")
    [[ -n "$gomod" ]] && k8s_ver=$(grep 'k8s.io/api ' "$gomod" 2>/dev/null | awk '{print $2}')
    : "${k8s_ver:=?}"

    if $BUILD && [[ -n "$gomod" ]]; then
      local gdir
      gdir=$(dirname "$gomod")
      (cd "$gdir" && GOTOOLCHAIN=auto go build ./... 2>/dev/null) && build_ok="PASS" || build_ok="FAIL"
      (cd "$gdir" && GOTOOLCHAIN=auto go vet ./... 2>/dev/null) && vet_ok="PASS" || vet_ok="FAIL"
    fi

    printf "%-40s %4s %4s %15s %5s %5s %s\n" \
      "$short" "$commits" "$applied" "$session_state" "$build_ok" "$vet_ok" "$k8s_ver"

    if $VERBOSE; then
      git log "$db".."$branch" --oneline 2>/dev/null | while read -r line; do
        echo "    $line"
      done
    fi
  done
}

# ── stop ─────────────────────────────────────────────────────────────

cmd_stop() {
  local targets=("$@")
  local stop_all=false stop_stuck=false

  case "${targets[0]:-}" in
    --all)   stop_all=true; targets=() ;;
    --stuck) stop_stuck=true; targets=() ;;
  esac

  build_session_cache

  echo "$_session_cache" | while IFS=$'\t' read -r cwd tag elapsed pid sid full_sid; do
    [[ -z "$pid" ]] && continue
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
      # Kill the process tree, then remove from agent registry
      if [[ -n "$pid" ]]; then
        local ppid
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -n "$ppid" && "$ppid" != "1" ]] && kill -9 "$ppid" 2>/dev/null || true
        kill -9 "$pid" 2>/dev/null || true
      fi
      claude rm "${full_sid:-$sid}" 2>/dev/null || true
      info "Killed $sid ($tag) — $cwd"
    fi
  done
}

# ── clean ────────────────────────────────────────────────────────────

cmd_clean() {
  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")

  for repo in "${repos[@]}"; do
    [[ -d "$repo" ]] || continue
    cd "$repo" || continue
    local short
    short=$(repo_short "$repo")

    local wt_lines
    wt_lines=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' || true)
    [[ -z "$wt_lines" ]] && continue

    while IFS= read -r line; do
      local wt_path
      wt_path=$(echo "$line" | awk '{print $1}')
      git worktree unlock "$wt_path" 2>/dev/null || true
      git worktree remove "$wt_path" --force 2>/dev/null \
        && info "Removed: $short/$(basename "$wt_path")" \
        || error "Failed: $wt_path"
    done <<< "$wt_lines"
  done

  # Clean stale session log
  if [[ -f "$RESULTS_DIR/sessions.jsonl" ]]; then
    local count
    count=$(wc -l < "$RESULTS_DIR/sessions.jsonl")
    if [[ "$count" -gt 20 ]]; then
      tail -20 "$RESULTS_DIR/sessions.jsonl" > "$RESULTS_DIR/sessions.jsonl.tmp"
      mv "$RESULTS_DIR/sessions.jsonl.tmp" "$RESULTS_DIR/sessions.jsonl"
      info "Trimmed session log to last 20 entries"
    fi
  fi
}

# ── compare ──────────────────────────────────────────────────────────

cmd_compare() {
  local b1="$1" b2="$2" repo="$3"
  cd "$repo" || die "Cannot cd to $repo"
  local db
  db=$(default_branch)

  info "── $(repo_short "$repo"): $b1 vs $b2 ──"
  echo ""

  printf "%-42s %6s %6s %s\n" "BRANCH" "COMITS" "AUTOFIX" "K8S"
  printf "%-42s %6s %6s %s\n" "------" "------" "-------" "---"
  for b in "$b1" "$b2"; do
    local c a v
    c=$(git log "$db".."$b" --oneline 2>/dev/null | wc -l | tr -d ' ')
    a=$(git log "$db".."$b" --format='%b' 2>/dev/null | grep -c 'Applied:' || true)
    v=$(git show "$b":go.mod 2>/dev/null | grep 'k8s.io/api ' | awk '{print $2}')
    [[ -z "$v" ]] && v=$(git show "$b":go-controller/go.mod 2>/dev/null | grep 'k8s.io/api ' | awk '{print $2}')
    printf "%-42s %6s %6s %s\n" "$b" "$c" "$a" "${v:-?}"
  done

  echo ""
  echo "Diff:"
  git diff "$b1".."$b2" --stat 2>/dev/null | tail -3
  echo ""
  echo "Only in $b2:"
  git log "$b1".."$b2" --oneline 2>/dev/null | head -10
  echo ""
  echo "Only in $b1:"
  git log "$b2".."$b1" --oneline 2>/dev/null | head -10
}

# ── sensitive ────────────────────────────────────────────────────────

cmd_sensitive() {
  local fn="$1" repo="$2"
  [[ -z "${SENSITIVITY_MAP[$fn]+x}" ]] && die "Unknown: $fn (run --help)"

  local gate_file="$PLUGIN_DIR/gates/${SENSITIVITY_MAP[$fn]}"
  [[ -f "$gate_file" ]] || die "Gate not found: $gate_file"

  cd "$repo" || die "Cannot cd to $repo"
  local short branch
  short=$(repo_short "$repo")
  branch=$(git branch --show-current 2>/dev/null)

  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && die "Dirty worktree"
  [[ "$branch" =~ ^(main|master)$ ]] && die "On $branch — switch to a rebase branch"

  info "── Sensitivity: $fn on $short ($branch) ──"

  local commit
  commit=$(git log --format='%H %b' | grep -B1 "Applied:.*$fn" | head -1 | awk '{print $1}')
  [[ -z "$commit" ]] && commit=$(git log --format='%H %s%n%b' | grep -B1 "$fn" | head -1 | awk '{print $1}')
  [[ -z "$commit" ]] && { info "SKIP: no commit for $fn"; return 0; }

  info "Reverting $(git log --oneline -1 "$commit")"
  if ! git revert --no-commit "$commit" 2>/dev/null; then
    info "SKIP: revert conflicts"
    git checkout -- . 2>/dev/null
    return 0
  fi

  info "Running gate: ${SENSITIVITY_MAP[$fn]}"
  mkdir -p "$RESULTS_DIR/sensitive"
  local outfile="$RESULTS_DIR/sensitive/${fn}-$(basename "$repo")-$(date +%s).txt"
  local output
  output=$(printf "Repo: %s\n\n%s" "$repo" "$(cat "$gate_file")" \
    | claude -p --output-format text 2>/dev/null || echo "ERROR: claude -p failed")

  git checkout -- . 2>/dev/null
  git clean -fd 2>/dev/null

  echo "$output" > "$outfile"
  echo "$output" | tail -15
  echo ""

  # Gate found issues if it reports non-zero counts or specific findings
  if echo "$output" | grep -qiE '[1-9][0-9]* (issue|finding|error|mismatch|missing|file)|found [1-9]|FAIL|file:'; then
    info "PASS: gate caught $fn (output: $outfile)"
  else
    error "FAIL: gate missed $fn (output: $outfile)"
    return 1
  fi
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
  compare)   [[ $# -lt 3 ]] && die "Usage: $0 compare <branch1> <branch2> <repo>"
             cmd_compare "$1" "$2" "$3" ;;
  sensitive) [[ $# -lt 2 ]] && die "Usage: $0 sensitive <autofix-fn> <repo>"
             cmd_sensitive "$1" "$2" ;;
  *)         die "Unknown command: $COMMAND" ;;
esac
