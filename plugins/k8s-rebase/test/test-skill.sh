#!/bin/bash
# test-skill.sh — Test the k8s-rebase skill by running it blind (without
# patterns doc or autofix functions) and verifying the results are correct.
#
# Usage:
#   test-skill.sh test-all                     Run core suite (6 repos)
#   test-skill.sh test <spec> <repo>           Run specific test
#   test-skill.sh results [repo] [--court]     Show results / deep-dive
#   test-skill.sh set-known-good <repo> <br>   Set reference branch
#   test-skill.sh stop [repo|--all]            Stop running tests
#   test-skill.sh clean [repos...]             Cleanup worktrees

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESULTS_DIR="${RESULTS_DIR:-$(cd "$PLUGIN_DIR/../.." 2>/dev/null && pwd || echo /tmp)/.work/test-harness}"
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
MAX_CONCURRENT=3
IDLE_TIMEOUT_MIN=120

DEFAULT_REPOS=(
  "$HOME/ovnk/ovn-org/ovn-kubernetes"
  "$HOME/ovnk/ovn-kubernetes/ovn-kubernetes-mcp"
  "$HOME/ovnk/openshift/multus-cni"
  "$HOME/ovnk/openshift/ingress-node-firewall"
  "$HOME/ovnk/openshift/cloud-network-config-controller"
  "$HOME/ovnk/openshift/cluster-network-operator"
)

# ── Utilities ──────────────────────────────────────────────────────────

info()  { echo ":: $*" >&2; }
warn()  { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; }
die()   { error "$@"; exit 1; }
repo_short() { local p="${1%/}"; echo "${p/#$HOME\/ovnk\//}"; }

resolve_repo() {
  local r="${1%/}"
  [[ -z "$r" ]] && return 1
  # Prefer $HOME/ovnk/ expansion for short names (avoids CWD-relative false hits)
  [[ -d "$HOME/ovnk/$r" ]] && { echo "$HOME/ovnk/$r"; return 0; }
  [[ -d "$r" ]] && { (cd "$r" && pwd); return 0; }
  return 1
}

default_branch() {
  local b
  b=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  [[ -z "$b" ]] && b="main"
  git rev-parse --verify "$b" &>/dev/null \
    || git rev-parse --verify "origin/$b" &>/dev/null \
    || b="master"
  echo "$b"
}

# ── Session Management ─────────────────────────────────────────────────

_SESSION_CACHE=""
_SESSION_CACHE_OK=false
_SESSION_CACHE_BUILT=false

_SESSION_PARSER=$(cat <<'PYEOF'
import json, sys, time, os
try:
    data = json.load(sys.stdin)
    if not isinstance(data, list): sys.exit(0)
except (json.JSONDecodeError, ValueError): sys.exit(0)
idle_max = int(sys.argv[1]) if len(sys.argv) > 1 else 120
now = time.time() * 1000
for s in data:
    try:
        cwd = s.get('cwd', '')
        raw_state = s.get('state')
        raw_status = s.get('status')
        if raw_state == 'working' and raw_status in ('idle', 'done'):
            st = raw_status
        else:
            st = raw_state or raw_status or '?'
        pid = s.get('pid') or '0'
        full_sid = s.get('sessionId', '?')
        sid = s.get('id') or full_sid[:8]
        started = s.get('startedAt', 0)
        elapsed = max(0, int((now - started) / 60000)) if started else 0
        if st == 'done' and pid and int(pid) > 0 and elapsed < idle_max:
            try:
                os.kill(int(pid), 0)
                st = 'idle'
            except (ProcessLookupError, ValueError): pass
            except PermissionError: st = 'idle'
        print(f'{cwd}\t{st}\t{elapsed}\t{pid}\t{sid}\t{full_sid}')
    except (TypeError, ValueError): pass
PYEOF
)

build_session_cache() {
  if $_SESSION_CACHE_BUILT; then return 0; fi
  _SESSION_CACHE_OK=false
  command -v claude &>/dev/null || { _SESSION_CACHE_BUILT=true; return 0; }
  _SESSION_CACHE=$(timeout -k 1 3 claude agents --json 2>/dev/null \
    | timeout -k 1 3 python3 -c "$_SESSION_PARSER" "$IDLE_TIMEOUT_MIN" 2>/dev/null || true)
  [[ -n "$_SESSION_CACHE" ]] && _SESSION_CACHE_OK=true
  _SESSION_CACHE_BUILT=true
}

require_session_cache() {
  if ! $_SESSION_CACHE_OK; then
    die "Session cache unavailable — refusing destructive operation"
  fi
}

session_for_repo() {
  local repo="$1" short
  short=$(repo_short "$repo")
  local match=""
  while IFS=$'\t' read -r cwd state elapsed pid _rest; do
    [[ -z "$cwd" ]] && continue
    [[ "$cwd" == *"/${short}/"* || "$cwd" == *"/${short}" ]] || continue
    [[ "$state" == "done" ]] && continue
    [[ "$state" == "blocked" && ( -z "$pid" || "$pid" == "0" ) ]] && continue
    [[ -z "$pid" || "$pid" == "0" ]] && continue
    [[ "$state" == "idle" && "${elapsed:-0}" -gt "$IDLE_TIMEOUT_MIN" ]] && continue
    if [[ "$cwd" == *"/.claude/worktrees/"* && ! -d "$cwd" ]]; then
      continue
    fi
    match="$cwd	$state	$elapsed	$pid	$_rest"
  done <<< "$_SESSION_CACHE"
  [[ -n "$match" ]] && echo "$match"
}

# ── Session Commands ───────────────────────────────────────────────────

find_newest_branch() {
  local repo="$1"
  (cd "$repo" 2>/dev/null || return 1
  local wt_line
  wt_line=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1)
  if [[ -n "$wt_line" ]]; then
    local wt_branch
    wt_branch=$(echo "$wt_line" | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')
    [[ -n "$wt_branch" ]] && { echo "$wt_branch"; return 0; }
  fi
  LC_ALL=C git branch --no-color | grep 'bump' | sed 's/^[* +]*//' | sort -V | tail -1 || true)
}

reset_to_default() {
  local repo="$1"
  cd "$repo" || { error "Cannot cd to $repo"; return 1; }
  [[ -n "$(git status --porcelain 2>/dev/null)" ]] && { error "Uncommitted changes in $repo"; return 1; }
  local default_br
  default_br=$(default_branch)
  git checkout "$default_br" &>/dev/null || { error "Cannot checkout $default_br"; return 1; }
  GIT_TERMINAL_PROMPT=0 git pull --ff-only 2>/dev/null || true
  info "$(repo_short "$repo") -> $default_br @ $(git rev-parse --short HEAD)"
}

remove_worktrees() {
  local repo="$1"
  cd "$repo" 2>/dev/null || return 1
  local wt_lines default_br
  wt_lines=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' || true)
  [[ -z "$wt_lines" ]] && return 0
  default_br=$(default_branch)
  while IFS= read -r line; do
    local wt_path wt_branch commit_count=0
    wt_path=$(echo "$line" | awk '{print $1}')
    wt_branch=$(echo "$line" | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')
    [[ -n "$wt_branch" ]] && commit_count=$(git rev-list --count "$default_br".."$wt_branch" 2>/dev/null || echo 0)
    git worktree unlock "$wt_path" 2>/dev/null || true
    if [[ -d "$wt_path" ]] && [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
      warn "Worktree $wt_path has uncommitted changes — skipping"
      continue
    fi
    git worktree remove "$wt_path" 2>/dev/null \
      || git worktree remove "$wt_path" --force 2>/dev/null \
      || { warn "Could not remove worktree: $wt_path"; continue; }
    if [[ "$commit_count" -gt 0 ]]; then
      info "Removed worktree (branch preserved, $commit_count commits)"
    else
      [[ -n "$wt_branch" ]] && git branch -D "$wt_branch" 2>/dev/null || true
      info "Removed worktree (empty branch deleted)"
    fi
  done <<< "$wt_lines"
}

cmd_run() {
  command -v claude &>/dev/null || die "claude CLI not found"
  local version="$1"; shift
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be X.Y.Z"
  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")
  mkdir -p "$RESULTS_DIR" || die "Cannot create $RESULTS_DIR"

  local launched=0
  build_session_cache
  require_session_cache
  for repo in "${repos[@]}"; do
    local repo_input="$repo"
    repo=$(resolve_repo "$repo") || { warn "Not found: $repo_input"; continue; }
    local short existing_session
    short=$(repo_short "$repo")
    existing_session=$(session_for_repo "$repo")
    if [[ -n "$existing_session" ]]; then
      warn "Active session on $short — stop it first"
      continue
    fi
    remove_worktrees "$repo"
    reset_to_default "$repo" || { warn "Skipping $short"; continue; }
    local session_output session_id
    session_output=$(claude --bg \
      --plugin-dir "$PLUGIN_DIR" \
      --permission-mode "$PERMISSION_MODE" \
      --disallowed-tools 'Bash(git push *)' 'Bash(*git push*)' 'Bash(git -c *push*)' 'Bash(*send-pack*)' 'Bash(gh pr create *)' 'Bash(*gh pr create*)' 'Bash(*gh api*repos*pulls*)' \
      "/k8s-rebase:k8s-rebase $version" 2>/dev/null)
    session_id=$(echo "$session_output" | grep 'backgrounded' | grep -oE '[a-f0-9]{8,}' | head -1)
    : "${session_id:=unknown}"
    [[ "$session_id" == "unknown" ]] && { error "Failed to launch $short"; continue; }
    info "Launched $short -> $session_id"
    launched=$((launched + 1))
  done
  [[ "$launched" -gt 0 ]] && info "Monitor: make results" || { warn "No sessions launched"; return 1; }
}

cmd_stop() {
  local targets=("$@")
  [[ ${#targets[@]} -eq 0 ]] && die "Usage: test-skill.sh stop <repo...|--all>"
  local stop_all=false
  [[ "${targets[0]}" == "--all" ]] && { stop_all=true; targets=(); }
  build_session_cache
  [[ -z "$_SESSION_CACHE" ]] && { info "No active sessions"; return 0; }
  local my_ancestors="" _pid=$$
  while [[ -n "$_pid" && "$_pid" != "1" && "$_pid" != "0" ]]; do
    my_ancestors="$my_ancestors $_pid"
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
  done
  local killed=0
  while IFS=$'\t' read -r cwd tag elapsed pid sid full_sid; do
    [[ -z "$pid" ]] && continue
    echo "$my_ancestors" | grep -qw "$pid" && continue
    local should_stop=false
    if $stop_all; then
      for dr in "${DEFAULT_REPOS[@]}"; do
        local dr_short=$(repo_short "$dr")
        [[ "$cwd" == *"/$dr_short" || "$cwd" == *"/$dr_short/"* ]] && { should_stop=true; break; }
      done
    else
      for t in "${targets[@]}"; do
        [[ "$sid" == "$t"* || "$cwd" == *"/$t" || "$cwd" == *"/$t/.claude"* ]] && { should_stop=true; break; }
      done
    fi
    if $should_stop; then
      claude stop "$sid" 2>/dev/null || true
      sleep 2
      info "Stopped $(echo "$cwd" | sed "s|$HOME/ovnk/||;s|/\.claude/.*||")"
      killed=$((killed + 1))
    fi
  done <<< "$_SESSION_CACHE"
  [[ "$killed" -eq 0 ]] && info "No matching sessions"
}

cmd_clean() {
  local repos=("$@")
  [[ ${#repos[@]} -eq 0 ]] && repos=("${DEFAULT_REPOS[@]}")
  build_session_cache
  require_session_cache
  for repo in "${repos[@]}"; do
    repo=$(resolve_repo "$repo") || continue
    local existing=$(session_for_repo "$repo")
    [[ -n "$existing" ]] && { warn "Active session on $(repo_short "$repo") — skipping"; continue; }
    cd "$repo" || continue
    git worktree prune 2>/dev/null || true
    remove_worktrees "$repo"
  done
  if command -v podman &>/dev/null; then
    local pruned=0
    while IFS= read -r cid; do
      [[ -z "$cid" ]] && continue
      podman rm "$cid" &>/dev/null && pruned=$((pruned + 1))
    done < <(podman ps -a --filter status=exited --filter name=k8s-rebase --format '{{.ID}}' 2>/dev/null)
    [[ "$pruned" -gt 0 ]] && info "Pruned $pruned containers"
  fi
  if [[ -d "$RESULTS_DIR" ]]; then
    local old_mutated=$(find "$RESULTS_DIR" -maxdepth 1 -name 'mutated-*' -type d 2>/dev/null | wc -l)
    [[ "$old_mutated" -gt 0 ]] && { rm -rf "$RESULTS_DIR"/mutated-* 2>/dev/null; info "Cleaned $old_mutated mutated dirs"; }
  fi
}

# ── Mutation ───────────────────────────────────────────────────────────

declare -A TAG_TO_PATTERN=(
  [xexp]="golang.org/x/exp" [reflect_ptr]="Deprecated stdlib/apimachinery symbols"
  [fieldsv1]="Deprecated stdlib/apimachinery symbols" [klog_v2]="Deprecated stdlib/apimachinery symbols"
  [eventf]="Deprecated stdlib/apimachinery symbols" [imports]="Deprecated stdlib/apimachinery symbols"
  [bounding_dirs]="deepcopy-gen --bounding-dirs removed" [obsgen]="WithConditions + ObservedGeneration"
  [conformance_renames]="Conformance suite rename" [addtoscheme]="AddToScheme"
  [mocks]="Deprecated stdlib/apimachinery symbols" [crd_int64_validation]="Project CRD int64 validation"
  [crd_name_validation]="CRD metadata.name validation" [feature_gates]="RelaxedServiceNameValidation"
  [kind_image]="E2e framework changes" [kind_version]="E2e framework changes"
  [metallb_version]="MetalLB CRD validation" [kubevirt_version]="KubeVirt version incompatibility"
  [relaxed_service_name_validation]="RelaxedServiceNameValidation" [kubeadm_v1beta4]="kubeadm v1beta4 format"
  [docs_version]="Deprecated stdlib/apimachinery symbols" [version_refs]="Deprecated stdlib/apimachinery symbols"
  [go_version]="E2e framework changes" [lint_version]="golangci-lint"
  [network_policy_api_crds]="MetalLB CRD validation" [banp_egresspeer]="EgressPeer type divergence"
)

mutate_plugin() {
  local label="mutated-$(date +%s)"
  local dest="$RESULTS_DIR/$label"
  mkdir -p "$RESULTS_DIR" 2>/dev/null || true
  cp -r "$PLUGIN_DIR" "$dest" || die "Cannot copy plugin to $dest"

  local has_all_patterns=false has_all_fns=false
  local -A seen_specs=()
  local specs=()
  for spec in "$@"; do
    [[ -n "${seen_specs[$spec]+x}" ]] && continue
    seen_specs[$spec]=1
    case "$spec" in
      all) has_all_patterns=true; has_all_fns=true; specs+=(all-patterns all-fns) ;;
      all-patterns) has_all_patterns=true; specs+=("$spec") ;;
      all-fns) has_all_fns=true; specs+=("$spec") ;;
      pattern:*) $has_all_patterns || specs+=("$spec") ;;
      fn:*) $has_all_fns || specs+=("$spec") ;;
      *) rm -rf "$dest"; die "Unknown spec: $spec" ;;
    esac
  done

  for spec in "${specs[@]}"; do
    case "$spec" in
      pattern:*)
        local key="${spec#pattern:}"
        local heading="${TAG_TO_PATTERN[$key]:-}"
        [[ -z "$heading" ]] && { rm -rf "$dest"; die "Unknown pattern: $key"; }
        local pfile="$dest/docs/k8s-rebase-patterns.md"
        awk -v hdr="### $heading" '/^### / && index($0, hdr) == 1 { skip=1; next } /^### / && skip { skip=0 } skip { next } { print }' \
          "$pfile" > "$pfile.tmp" && mv "$pfile.tmp" "$pfile"
        info "Removed pattern: $heading" ;;
      fn:*)
        local ftag="${spec#fn:}" afile="$dest/scripts/k8s-rebase-autofix.sh"
        grep -q "^fix_${ftag}()" "$afile" 2>/dev/null || { rm -rf "$dest"; die "Function fix_${ftag}() not found"; }
        awk -v fn="fix_${ftag}" '$0 ~ "^"fn"\\(\\)" { print $0; print "  return 0"; skip=1; next } skip && /^\}/ { print; skip=0; next } skip { next } { print }' \
          "$afile" > "$afile.tmp" && mv "$afile.tmp" "$afile"
        info "Neutered: fix_${ftag}()" ;;
      all-patterns)
        sed -i '/^### /,$ { /^## /!d }' "$dest/docs/k8s-rebase-patterns.md"
        info "Removed all patterns" ;;
      all-fns)
        local afile="$dest/scripts/k8s-rebase-autofix.sh"
        awk '/^fix_[a-z0-9_]+\(\)/ && !/fix_uncommitted/ { print $0; print "  return 0"; skip=1; next } skip && /^\}/ { print; skip=0; next } skip { next } { print }' \
          "$afile" > "$afile.tmp" && mv "$afile.tmp" "$afile"
        info "Neutered all functions" ;;
    esac
  done

  local skillfile="$dest/skills/k8s-rebase/SKILL.md"
  [[ -f "$skillfile" ]] && {
    sed -i "s|find \"\$HOME/.claude\" \"\$HOME\" -maxdepth 7 -name \"k8s-rebase-autofix.sh\"[^)]*)|echo \"$dest/scripts/k8s-rebase-autofix.sh\")|" "$skillfile"
    sed -i "s|find \"\$HOME/.claude\" \"\$HOME\" -maxdepth 7 -name \"k8s-rebase-patterns.md\"[^)]*)|echo \"$dest/docs/k8s-rebase-patterns.md\")|" "$skillfile"
  }
  bash -n "$dest/scripts/k8s-rebase-autofix.sh" || { rm -rf "$dest"; die "Mutation produced invalid bash"; }
  echo "$dest"
}

# ── Test Execution ─────────────────────────────────────────────────────

_repo_from_key() {
  local key="$1"
  local org="${key%%_*}" name="${key#*_}"
  local path="$HOME/ovnk/$org/$name"
  [[ -d "$path" ]] && { echo "$path"; return 0; }
  return 1
}

cmd_test() {
  local version="1.36.2" specs=() repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) shift; version="${1:-}"; [[ -z "$version" ]] && die "--version needs value" ;;
      pattern:*|fn:*|all-patterns|all-fns|all) specs+=("$1") ;;
      *) repo="$1" ;;
    esac; shift
  done
  [[ ${#specs[@]} -eq 0 ]] && die "No spec (use: all, fn:<tag>, pattern:<key>)"
  [[ -z "$repo" ]] && die "No repo path"
  local repo_input="$repo"
  repo=$(resolve_repo "$repo") || die "Not found: $repo_input"

  info "── Test: ${specs[*]} on $(repo_short "$repo") ──"
  local mutated
  mutated=$(mutate_plugin "${specs[@]}") || exit 1

  # Clean stale worktree branches
  (cd "$repo" && git worktree prune 2>/dev/null || true
   local _db; _db=$(default_branch)
   for wt_branch in $(git branch | tr -d ' *' | grep 'worktree-k8s-rebase' | grep -v '^archived-'); do
     local _ahead=$(git rev-list --count "$_db".."$wt_branch" 2>/dev/null || echo 0)
     if [[ "$_ahead" -gt 0 ]]; then
       local _ts=$(date +%Y%m%d%H%M%S)
       git branch -m "$wt_branch" "archived-${wt_branch}-${_ts}" 2>/dev/null
     else
       git branch -D "$wt_branch" 2>/dev/null
     fi
   done)

  # Track in running state
  local _state_dir="$PLUGIN_DIR/test/.matrix-state"
  local _repo_key
  _repo_key=$(repo_short "$repo" | tr '/' '_')
  mkdir -p "$_state_dir/running" "$_state_dir/done"
  # Remove old done file so auto_record can re-record this test
  local _done_key="${specs[*]}"
  _done_key="${_done_key//[:\/\ ]/_}_$_repo_key"
  [[ -f "$_state_dir/done/$_done_key" ]] && rm -f "$_state_dir/done/$_done_key"
  local _prev_running=""
  [[ -f "$_state_dir/running/$_repo_key" ]] && _prev_running=$(cat "$_state_dir/running/$_repo_key")
  printf '%s\t%s\n' "${specs[*]}" "$(date +%s)" > "$_state_dir/running/$_repo_key"

  # Launch via session run (subshell to scope PLUGIN_DIR to the mutated copy)
  if ! (PLUGIN_DIR="$mutated" cmd_run "$version" "$repo"); then
    if [[ -n "$_prev_running" ]]; then
      echo "$_prev_running" > "$_state_dir/running/$_repo_key"
    else
      rm -f "$_state_dir/running/$_repo_key"
    fi
    die "Launch failed for $(repo_short "$repo")"
  fi
  info "When done: make results"
}

cmd_test_all() {
  local version="1.36.2"
  [[ "${1:-}" == "--version" ]] && { shift; version="${1:-1.36.2}"; shift; }
  local launched=0 queued=0
  build_session_cache
  for repo in "${DEFAULT_REPOS[@]}"; do
    [[ -d "$repo" ]] || continue
    local existing=$(session_for_repo "$repo")
    if [[ -n "$existing" ]]; then
      info "SKIP $(repo_short "$repo") (active session)"
      continue
    fi
    if [[ "$launched" -ge "$MAX_CONCURRENT" ]]; then
      queued=$((queued + 1))
      info "QUEUED $(repo_short "$repo") (max $MAX_CONCURRENT concurrent)"
      continue
    fi
    cmd_test "all" "$repo" --version "$version" && launched=$((launched + 1))
  done
  info "Launched: $launched | Queued: $queued | Monitor: $(basename "$0") results"
}

# ── Recording ──────────────────────────────────────────────────────────

_do_record_one() {
  local repo="$1" repo_key="$2" spec="$3" state_dir="$4" launch_epoch="${5:-0}"
  local short=$(repo_short "$repo")

  local result_branch="" wt_line="" wt_path=""
  wt_line=$(git -C "$repo" worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1)
  if [[ -n "$wt_line" ]]; then
    result_branch=$(echo "$wt_line" | grep -oE '\[.+\]' | tr -d '[]' | sed 's/ locked//')
    wt_path=$(echo "$wt_line" | awk '{print $1}')
  fi
  [[ -z "$result_branch" ]] && \
    result_branch=$(LC_ALL=C git -C "$repo" branch --no-color | grep 'bump' | sed 's/^[* +]*//' | sort -V | tail -1)
  [[ -z "$result_branch" ]] && { echo "no branch found"; return 1; }

  local default_br
  default_br=$(git -C "$repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  : "${default_br:=main}"
  git -C "$repo" rev-parse --verify "$default_br" &>/dev/null \
    || git -C "$repo" rev-parse --verify "origin/$default_br" &>/dev/null \
    || default_br="master"

  if [[ "$launch_epoch" -gt 0 ]]; then
    local branch_epoch
    branch_epoch=$(git -C "$repo" log --reverse --format='%ct' "${default_br}..${result_branch}" 2>/dev/null | head -1)
    : "${branch_epoch:=0}"
    [[ "$branch_epoch" -gt 0 && "$branch_epoch" -lt "$launch_epoch" ]] && { echo "stale branch"; return 1; }
  fi

  local commits=$(git -C "$repo" rev-list --count "$default_br".."$result_branch" 2>/dev/null || echo 0)
  [[ "$commits" -eq 0 ]] && { echo "no commits (no-op)"; return 1; }

  # Gate tally — every gate must produce a report, all must pass
  local verdict="FAIL"
  local gtotal=0 gfail=0
  local expected_gates=$(find "$PLUGIN_DIR/gates" -name '*.md' 2>/dev/null | wc -l)
  [[ "$expected_gates" -lt 1 ]] && expected_gates=33
  local gate_dir="${wt_path:+$wt_path/.rebase-tmp/gates}"
  if [[ -n "$wt_path" && ! -d "$gate_dir" ]]; then
    gate_dir=""
  elif [[ -z "$wt_path" ]]; then
    gate_dir="$repo/.rebase-tmp/gates"
  fi
  if [[ -d "$gate_dir" ]]; then
    for f in "$gate_dir"/*.report; do
      [[ -f "$f" ]] || continue; gtotal=$((gtotal + 1))
      local gv=$(grep -iE '^(VERDICT|STATUS|RESULT):' "$f" 2>/dev/null | head -1)
      gv="${gv^^}"
      [[ "$gv" == *FAIL* ]] && gfail=$((gfail + 1))
    done
    [[ "$gtotal" -ge "$expected_gates" && "$gfail" -eq 0 ]] && verdict="PASS"
  fi

  # Known-good diff (informational — does not affect verdict)
  local kg_hunks="" kg_vendor=""
  local kg_file="$state_dir/known_good_$repo_key"
  if [[ -f "$kg_file" ]]; then
    local kg_branch=$(cat "$kg_file")
    if git -C "$repo" rev-parse --verify "$kg_branch" &>/dev/null; then
      local kg_diff_all=$(git -C "$repo" diff "$result_branch" "$kg_branch" -- . ':!.rebase-tmp' 2>/dev/null | grep -c '^@@' || true)
      local kg_diff_nv=$(git -C "$repo" diff "$result_branch" "$kg_branch" -- . ':!.rebase-tmp' ':(exclude,glob)**/vendor/**' 2>/dev/null | grep -c '^@@' || true)
      kg_hunks="$kg_diff_nv"
      [[ "$kg_diff_all" -gt "$kg_diff_nv" ]] && kg_vendor="$((kg_diff_all - kg_diff_nv))"
    fi
  fi

  # Build human-readable detail
  local detail=""
  if [[ "$gtotal" -eq 0 ]]; then
    detail="no gates ran (bug)"
  elif [[ "$gfail" -gt 0 ]]; then
    detail="$gfail gate(s) failed"
  elif [[ "$gtotal" -lt "$expected_gates" ]]; then
    detail="missing $((expected_gates - gtotal)) of $expected_gates gates"
  elif [[ -n "$kg_hunks" ]]; then
    if [[ "$kg_hunks" -eq 0 && -z "$kg_vendor" ]]; then
      detail="identical to known-good"
    elif [[ "$kg_hunks" -eq 0 ]]; then
      detail="matches known-good (vendor-only diff)"
    else
      detail="${kg_hunks} code hunks from known-good"
      [[ -n "$kg_vendor" ]] && detail="$detail (+${kg_vendor} vendor)"
    fi
  else
    detail="all gates pass (no known-good set)"
  fi
  local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local done_key="${spec//[:\/\ ]/_}_$repo_key"
  mkdir -p "$state_dir/done"
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$spec" "$short" "$verdict" "$detail" >> "$state_dir/results.tsv"
  {
    echo "$ts	$spec	$short	$verdict	$detail"
    if [[ -d "$gate_dir" && "$gtotal" -gt 0 ]]; then
      echo "---GATE-REPORTS---"
      for f in "$gate_dir"/*.report; do
        [[ -f "$f" ]] || continue
        echo "=== $(basename "$f" .report) ==="
        cat "$f"; echo ""
      done
    fi
  } > "$state_dir/done/$done_key"
  rm -f "$state_dir/running/$repo_key"
  printf '%-20s %-42s %-8s %s' "$spec" "$short" "$verdict" "$detail"
}

auto_record() {
  local state_dir="$PLUGIN_DIR/test/.matrix-state"
  local running_dir="$state_dir/running"
  [[ ! -d "$running_dir" ]] || [[ -z "$(ls -A "$running_dir" 2>/dev/null)" ]] && return 0

  build_session_cache
  $_SESSION_CACHE_OK || return 0

  local recorded=0
  local _expected_gates=$(find "$PLUGIN_DIR/gates" -name '*.md' 2>/dev/null | wc -l)
  [[ "$_expected_gates" -lt 1 ]] && _expected_gates=33

  for running_file in "$running_dir"/*; do
    [[ -f "$running_file" ]] || continue
    local repo_key=$(basename "$running_file")
    local _raw=$(cat "$running_file")
    local spec=$(echo "$_raw" | cut -f1)
    local launch_epoch=$(echo "$_raw" | cut -f2)
    [[ "$launch_epoch" =~ ^[0-9]+$ ]] || launch_epoch=0
    [[ -z "$spec" ]] && { rm -f "$running_file"; continue; }

    local repo
    repo=$(_repo_from_key "$repo_key") || true
    [[ -z "$repo" || ! -d "$repo" ]] && continue
    local short=$(repo_short "$repo")
    local done_key="${spec//[:\/\ ]/_}_$repo_key"
    [[ -f "$state_dir/done/$done_key" ]] && { rm -f "$running_file"; continue; }

    local _session=$(session_for_repo "$repo")
    if [[ -n "$_session" ]]; then
      # Gate-completion override
      local _wt=$(git -C "$repo" worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1 | awk '{print $1}')
      local _gc=0
      [[ -n "$_wt" && -d "$_wt/.rebase-tmp/gates" ]] && _gc=$(ls "$_wt/.rebase-tmp/gates"/*.report 2>/dev/null | wc -l)
      if [[ "$_gc" -ge "$_expected_gates" ]]; then
        info "Gate-complete: $spec on $short ($_gc/$_expected_gates gates)"
      else
        continue
      fi
    fi

    local result
    if result=$(_do_record_one "$repo" "$repo_key" "$spec" "$state_dir" "$launch_epoch"); then
      recorded=$((recorded + 1))
      info "Recorded: $result"
    fi
  done
  [[ "$recorded" -gt 0 ]] && info "$recorded result(s) recorded"
}

# ── Adversarial Court ──────────────────────────────────────────────────

cmd_court() {
  [[ $# -lt 3 ]] && die "Usage: test-skill.sh results <repo> --court  OR  court <result> <known-good> <repo>"
  local result_branch="$1" known_good="$2" repo="$3"
  local mutation_context=""
  local i=4
  while [[ $i -le $# ]]; do
    [[ "${!i}" == "--context" ]] && { local next=$((i+1)); mutation_context="${!next:-}"; }
    i=$((i+1))
  done

  cd "$repo" || die "Cannot cd to $repo"
  git rev-parse --verify "$result_branch" &>/dev/null || die "Branch not found: $result_branch"
  git rev-parse --verify "$known_good" &>/dev/null || die "Branch not found: $known_good"

  local diff_nv=$(git diff "$result_branch" "$known_good" -- . ':!.rebase-tmp' ':(exclude,glob)**/vendor/**' 2>/dev/null)
  [[ -z "$diff_nv" ]] && { info "PASS: identical (non-vendor)"; return 0; }

  local hunks=$(echo "$diff_nv" | grep -c '^@@' || true)
  local diff_stat=$(git diff --stat "$result_branch" "$known_good" -- . ':!.rebase-tmp' ':(exclude,glob)**/vendor/**' 2>/dev/null)
  info "Diff: $hunks non-vendor hunks"

  local direction="DIFF DIRECTION: 'git diff $result_branch $known_good'.
'-' lines are in RESULT but not known-good. '+' lines are in known-good but not result.
'deleted file' = exists in result, not known-good."
  local preexisting="
A difference is a REGRESSION only if the result branch introduced a NEW problem.
Pre-existing issues (on base/main before rebase) that the known-good cleaned up are EQUIVALENT."
  [[ -n "$mutation_context" ]] && preexisting="MUTATION: knowledge removed: $mutation_context
$preexisting"

  if [[ "$hunks" -lt 5 ]]; then
    info "Small diff — single classifier"
    local out=$(printf '%s\n%s\n%s\n\n%s\n\nClassify each difference. End with VERDICT: PASS or FAIL' \
      "$direction" "$preexisting" "$diff_stat" "$diff_nv" \
      | timeout 300 claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true
    local v=$(echo "$out" | grep -oE 'VERDICT: (PASS|FAIL)' | tail -1)
    echo "$out" | tail -10
    case "$v" in "VERDICT: PASS") info "PASS";; "VERDICT: FAIL") error "FAIL"; return 1;; *) error "INCONCLUSIVE"; return 1;; esac
    return 0
  fi

  local logs=$(git log --oneline "$(git merge-base "$result_branch" "$known_good" 2>/dev/null || echo "$known_good")".."$result_branch" 2>/dev/null | head -15)
  local context="$direction
$preexisting

DIFF (non-vendor):
$diff_nv

COMMITS: $logs
FILES: $diff_stat"

  mkdir -p "$RESULTS_DIR/court" 2>/dev/null
  local cdir="$RESULTS_DIR/court/$(date +%s)"
  mkdir -p "$cdir"

  info "Phase A: Prosecution + Defense..."
  printf '%s\n\nYou are the PROSECUTION. Argue these are REGRESSIONS. Cite files and lines.' "$context" \
    | timeout 300 claude -p --permission-mode "$PERMISSION_MODE" --output-format text > "$cdir/pros.txt" 2>/dev/null &
  local p1=$!
  printf '%s\n\nYou are the DEFENSE. Argue these are EQUIVALENT or IMPROVEMENTS. Cite files and lines.' "$context" \
    | timeout 300 claude -p --permission-mode "$PERMISSION_MODE" --output-format text > "$cdir/def.txt" 2>/dev/null &
  local p2=$!
  wait "$p1" "$p2" 2>/dev/null || true
  local pros=$(cat "$cdir/pros.txt") def=$(cat "$cdir/def.txt")
  [[ -z "$pros" || -z "$def" ]] && { error "Prosecution/defense empty"; return 1; }

  info "Phase B: Judge..."
  local judge=$(printf 'PROSECUTION:\n%s\n\nDEFENSE:\n%s\n\nDIFF:\n%s\n\nFact-check only. Strike unsupported claims. No verdict.' \
    "$pros" "$def" "$diff_nv" | timeout 300 claude -p --permission-mode "$PERMISSION_MODE" --output-format text 2>/dev/null) || true
  echo "$judge" > "$cdir/judge.txt"

  info "Phase C: Jury (3 votes, parallel)..."
  local jury_prompt=$(printf 'DIFF:\n%s\n\nPROSECUTION:\n%s\n\nDEFENSE:\n%s\n\nJUDGE:\n%s\n\nVote: VERDICT: PASS or FAIL. One sentence.' \
    "$diff_nv" "$pros" "$def" "$judge")
  for j in 1 2 3; do
    printf '%s' "$jury_prompt" | timeout 300 claude -p --permission-mode "$PERMISSION_MODE" --output-format text > "$cdir/juror-$j.txt" 2>/dev/null &
  done
  wait 2>/dev/null || true

  local pass=0 fail=0
  for j in 1 2 3; do
    local jv=$(grep -oE 'VERDICT: (PASS|FAIL)' "$cdir/juror-$j.txt" 2>/dev/null | tail -1)
    case "$jv" in "VERDICT: PASS") pass=$((pass+1)); info "  Juror $j: PASS";; "VERDICT: FAIL") fail=$((fail+1)); info "  Juror $j: FAIL";; *) info "  Juror $j: ABSTAIN";; esac
  done

  info "Jury: $pass PASS, $fail FAIL"
  local total=$((pass + fail))
  [[ "$total" -lt 2 ]] && { error "INCONCLUSIVE (no quorum)"; return 1; }
  [[ "$pass" -gt "$fail" ]] && { info "VERDICT: PASS ($pass-$fail)"; return 0; }
  error "VERDICT: FAIL ($fail-$pass)"; return 1
}

# ── Results Display ────────────────────────────────────────────────────

cmd_results() {
  local repo="" court=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --court) court=true ;;
      *) repo="$1" ;;
    esac; shift
  done

  # Auto-record completed runs first
  auto_record

  if [[ -n "$repo" ]]; then
    # Single-repo deep-dive
    local repo_input="$repo"
    repo=$(resolve_repo "$repo") || die "Not found: $repo_input"
    local short=$(repo_short "$repo")
    cd "$repo" || die "Cannot cd to $repo"
    local wt=$(git worktree list 2>/dev/null | grep '\.claude/worktrees' | tail -1 | awk '{print $1}')
    local gate_dir="" wt_in_progress=false
    if [[ -n "$wt" ]]; then
      gate_dir="$wt/.rebase-tmp/gates"
      [[ ! -d "$gate_dir" ]] && wt_in_progress=true
    else
      gate_dir="$repo/.rebase-tmp/gates"
    fi

    local expected_gates=$(find "$PLUGIN_DIR/gates" -name '*.md' 2>/dev/null | wc -l)
    [[ "$expected_gates" -lt 1 ]] && expected_gates=33
    echo "── $short ──"
    if $wt_in_progress; then
      echo "Run in progress (worktree exists, gates not yet written)"
    elif [[ -d "$gate_dir" ]]; then
      local total=0 gfail=0
      for f in "$gate_dir"/*.report; do
        [[ -f "$f" ]] || continue; total=$((total+1))
        local v=$(grep -iE '^VERDICT:' "$f" 2>/dev/null | head -1)
        v="${v^^}"
        [[ "$v" == *FAIL* ]] && gfail=$((gfail+1))
      done
      if [[ "$total" -ge "$expected_gates" && "$gfail" -eq 0 ]]; then
        echo "Gates: all $total pass"
      elif [[ "$gfail" -gt 0 ]]; then
        echo "Gates: $gfail FAILED ($total/$expected_gates complete)"
      else
        echo "Gates: $total/$expected_gates complete (in progress)"
      fi
      # Show failed gates inline
      for f in "$gate_dir"/*.report; do
        [[ -f "$f" ]] || continue
        local v=$(grep -iE '^VERDICT:' "$f" 2>/dev/null | head -1)
        v="${v^^}"
        [[ "$v" == *"FAIL"* ]] && {
          echo ""
          echo "FAILED: $(basename "$f" .report)"
          cat "$f"
        }
      done
    else
      echo "Gates: none (no reports found)"
    fi

    # Known-good comparison
    local repo_key=$(echo "$short" | tr '/' '_')
    local kg_file="$PLUGIN_DIR/test/.matrix-state/known_good_$repo_key"
    if [[ -f "$kg_file" ]]; then
      local kg=$(cat "$kg_file")
      local branch=$(find_newest_branch "$repo")
      if [[ -n "$branch" && -n "$kg" ]]; then
        local nv=$(git diff "$branch" "$kg" -- . ':!.rebase-tmp' ':(exclude,glob)**/vendor/**' 2>/dev/null | grep -c '^@@' || true)
        echo ""
        if [[ "$nv" -eq 0 ]]; then
          echo "Diff vs known-good branch $kg: identical (non-vendor)"
        else
          echo "Diff vs known-good branch $kg: $nv code hunks differ"
        fi
        $court && cmd_court "$branch" "$kg" "$repo"
      fi
    fi

    # Recent results for this repo
    echo ""
    echo "Recent results:"
    awk -F'\t' -v r="$short" '$3==r' "$PLUGIN_DIR/test/.matrix-state/results.tsv" 2>/dev/null | tail -5 | while IFS=$'\t' read -r ts spec r verdict detail; do
      printf "  %-22s %-8s %s\n" "$ts" "$verdict" "$detail"
    done
    return 0
  fi

  # Per-repo latest results
  local tsv="$PLUGIN_DIR/test/.matrix-state/results.tsv"
  if [[ -f "$tsv" ]]; then
    printf "%-45s %-8s %s\n" "REPO" "VERDICT" "DETAIL"
    printf "%-45s %-8s %s\n" "----" "-------" "------"
    local all_pass=true
    for repo in "${DEFAULT_REPOS[@]}"; do
      local short=$(repo_short "$repo")
      local latest_line=$(awk -F'\t' -v r="$short" '$3==r && $2~/^all/' "$tsv" | tail -1)
      if [[ -n "$latest_line" ]]; then
        local verdict=$(echo "$latest_line" | cut -f4)
        local detail=$(echo "$latest_line" | cut -f5)
        [[ "$verdict" != "PASS" ]] && all_pass=false
        printf "%-45s %-8s %s\n" "$short" "$verdict" "$detail"
      else
        all_pass=false
        printf "%-45s %-8s %s\n" "$short" "-" "not tested"
      fi
    done

    echo ""
    if $all_pass; then
      echo "OVERALL: PASS"
    else
      echo "OVERALL: FAIL"
    fi
  fi
}

# ── Known-Good Management ──────────────────────────────────────────────

cmd_set_known_good() {
  [[ $# -lt 2 ]] && die "Usage: test-skill.sh set-known-good <repo> <branch>"
  local repo="$1" branch="$2"
  local repo_input="$repo"
  repo=$(resolve_repo "$repo") || die "Not found: $repo_input"
  cd "$repo" || die "Cannot cd to $repo"
  git rev-parse --verify "$branch" &>/dev/null || die "Branch not found: $branch"
  local state_dir="$PLUGIN_DIR/test/.matrix-state"
  local repo_key=$(repo_short "$repo" | tr '/' '_')
  mkdir -p "$state_dir"
  echo "$branch" > "$state_dir/known_good_$repo_key"
  info "Set known-good for $(repo_short "$repo"): $branch"
}

# ── Main Dispatch ──────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args...]

Commands:
  test-all [--version X.Y.Z]        Run core suite (all 6 repos, batches of $MAX_CONCURRENT)
  test <spec> <repo> [--version]    Run specific test case
  results [repo] [--court]          Show results matrix or deep-dive one repo
  set-known-good <repo> <branch>    Set reference branch for comparison
  stop [repo...|--all]              Stop running test sessions
  clean [repos...]                  Cleanup worktrees and containers

Specs: all, all-fns, all-patterns, fn:<tag>, pattern:<key>
Tags: $(echo "${!TAG_TO_PATTERN[@]}" | tr ' ' ', ')

Repos accept full paths or short names (openshift/multus-cni, ovn-org/ovn-kubernetes).

Examples:
  $(basename "$0") test-all
  $(basename "$0") test all openshift/multus-cni
  $(basename "$0") results
  $(basename "$0") results openshift/multus-cni --court
  $(basename "$0") set-known-good openshift/multus-cni bump1.36
EOF
  exit 0
}

[[ $# -eq 0 ]] && usage

COMMAND="$1"; shift
case "$COMMAND" in
  test-all)       cmd_test_all "$@" ;;
  test)           cmd_test "$@" ;;
  results)        cmd_results "$@" ;;
  set-known-good) cmd_set_known_good "$@" ;;
  stop)           cmd_stop "$@" ;;
  clean)          cmd_clean "$@" ;;
  -h|--help|help) usage ;;
  *)              die "Unknown command: $COMMAND (try --help)" ;;
esac
