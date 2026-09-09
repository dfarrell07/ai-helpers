#!/bin/bash
set -euo pipefail

# run-rebase.sh — eval runner for the k8s-rebase skill.
#
# Invokes the skill exactly like test-skill.sh's cmd_run does (same
# --plugin-dir / --permission-mode / --disallowed-tools flags — do not
# drop or modify these, they are what makes the skill's own safety
# hooks load and enforce in a headless session), but synchronously
# (claude -p, not claude --bg) so cost/tokens are directly capturable.
#
# Produces output files for agent-eval-harness judges to evaluate.
# Does NOT push or create PRs — --disallowed-tools blocks it as a
# second, independent layer on top of the skill's own hooks.
#
# Called by the eval harness via runner.type: cli. The harness sets cwd
# to the case workspace, which contains input.yaml and a pre-created
# output/ dir.
#
# Usage:
#   run-rebase.sh <repo_url> <from_commit> <version> [model] [known_good_url] [known_good_ref]
#
# known_good_url/known_good_ref are optional; if omitted, known-good.patch
# is written empty (no known-good comparison). If known_good lives on the
# SAME repo as repo_url (a bare SHA in the case's input.yaml), pass
# repo_url again as known_good_url. If it lives on a fork (input.yaml's
# known_good is a {url, ref} object), pass that fork's url/ref — the
# script fetches from THAT remote, not "origin" (which is repo_url and
# does not have the fork's ref).
#
# Env vars:
#   AI_HELPERS_DIR   — path to ai-helpers checkout (default: auto-detect)
#   EVAL_REPO_DIR    — override the clone location (default: cached under
#                       evals/.repos/, keyed by repo_url)
#   SKILL_MAX_TURNS  — passed to claude -p --max-turns. Default: 200 —
#                       UNCALIBRATED PLACEHOLDER (--max-turns accounting
#                       scope is unconfirmed, per the plan; set for real
#                       during calibration, not chosen deliberately here).

REPO_URL=${1:?"Usage: $0 <repo_url> <from_commit> <version> [model] [known_good_url] [known_good_ref]"}
FROM_COMMIT=${2:?"Usage: $0 <repo_url> <from_commit> <version> [model] [known_good_url] [known_good_ref]"}
VERSION=${3:?"Usage: $0 <repo_url> <from_commit> <version> [model] [known_good_url] [known_good_ref]"}
SKILL_MODEL=${4:-claude-sonnet-4-6}
KNOWN_GOOD_URL=${5:-}
KNOWN_GOOD_REF=${6:-}
AI_HELPERS_DIR=${AI_HELPERS_DIR:-$(cd "$(dirname "$0")/../../../.." && pwd)}
PLUGIN_DIR="$AI_HELPERS_DIR/plugins/k8s-rebase"
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
MAX_TURNS="${SKILL_MAX_TURNS:-200}"

# The harness pre-creates output/ in the workspace (cwd).
WORKSPACE="$(pwd)"
OUTPUT_DIR="${WORKSPACE}/output"
mkdir -p "$OUTPUT_DIR"

repo_key() {
  echo "$1" | sed -E 's#https?://##; s#[^A-Za-z0-9]+#_#g'
}
REPO_DIR="${EVAL_REPO_DIR:-$AI_HELPERS_DIR/plugins/k8s-rebase/evals/.repos/$(repo_key "$REPO_URL")}"

# --- Step 0: crash-safety status write, SIGKILL-safe ---
#
# Write run-status.json defaulting to infra_error as the LITERAL FIRST
# filesystem operation, before cloning, before any trap. A trap alone
# cannot fire on SIGKILL (POSIX signal semantics), which is a plausible
# way a harness enforces execution.timeout — if the status file only
# existed inside a trap, a timeout would leave no signal behind at all.
# Only the success path (end of this script) overwrites it to completed.
write_status() {
  local status="$1" reason="$2"
  jq -n --arg status "$status" --arg reason "$reason" \
    '{status: $status, reason: $reason}' > "$OUTPUT_DIR/run-status.json.tmp"
  mv "$OUTPUT_DIR/run-status.json.tmp" "$OUTPUT_DIR/run-status.json"
}
write_status "infra_error" "run-rebase.sh exited unexpectedly before completion"

# Defense-in-depth for the failure modes SIGKILL doesn't cover
# (command errors under set -e, SIGTERM).
on_err() {
  trap - ERR  # prevent recursive firing if write_status itself fails
  write_status "infra_error" "run-rebase.sh failed (see session-stderr.log / trap)"
}
trap on_err ERR

echo "=== k8s-rebase Eval: $REPO_URL @ $VERSION ==="
echo "from_commit: $FROM_COMMIT"
echo "Model: $SKILL_MODEL"
echo "Workspace: $WORKSPACE"
echo "Repo dir: $REPO_DIR"
echo "ai-helpers: $AI_HELPERS_DIR"

# --- Step 1: clone/reset-and-clean, as the FIRST real action ---
#
# Cache the clone across repeat runs, but always reset-and-clean before
# doing anything else in THIS run — never as end-of-run cleanup, which
# would race with (and could destroy) this run's own output capture
# below before the next run even starts.
if [[ ! -d "$REPO_DIR/.git" ]]; then
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"
git fetch origin "$FROM_COMMIT"
git reset --hard "$FROM_COMMIT"
git clean -fdx
rm -rf "$REPO_DIR/.rebase-tmp"  # not removed by git clean if gitignored
git config user.name "k8s-rebase-eval"
git config user.email "eval@k8s-rebase.local"

# --- Step 2: invoke the real skill once, with cmd_run's exact flags ---
echo ""
echo "--- Running skill ---"
set +e
claude -p "/k8s-rebase:k8s-rebase $VERSION" \
  --output-format stream-json \
  --verbose \
  --max-turns "$MAX_TURNS" \
  --model "$SKILL_MODEL" \
  --plugin-dir "$PLUGIN_DIR" \
  --permission-mode "$PERMISSION_MODE" \
  --disallowed-tools 'Bash(git push *),Bash(*git push*),Bash(git -c *push*),Bash(*send-pack*),Bash(gh pr create *),Bash(*gh pr create*),Bash(*gh api*repos*pulls*),Bash(sleep *),Bash(go mod tidy*),Bash(go mod get*),Bash(go mod vendor*),Bash(go mod edit*),Bash(go generate*),Bash(go run *)' \
  2>"$OUTPUT_DIR/session-stderr.log" \
  | tee "$OUTPUT_DIR/session-output.json"
SKILL_EXIT=${PIPESTATUS[0]}
TEE_EXIT=${PIPESTATUS[1]}
set -e

echo "Skill exit code: $SKILL_EXIT"
if [[ $SKILL_EXIT -ne 0 ]]; then
  write_status "infra_error" "skill exited $SKILL_EXIT"; exit 1
fi
if [[ $TEE_EXIT -ne 0 ]]; then
  write_status "infra_error" "tee failed writing session-output.json (disk full?)"; exit 1
fi

stderr_size=$(wc -c < "$OUTPUT_DIR/session-stderr.log" 2>/dev/null || echo 0)
if [[ $stderr_size -gt 0 ]]; then
  echo "WARNING: session-stderr.log is non-empty ($stderr_size bytes) — review it"
fi

# --- Step 3: extract cost/tokens ---
extract_tokens() {
  grep '"type":"result"' "$1" 2>/dev/null \
    | head -1 \
    | jq '{
        total_cost_usd: (.total_cost_usd // 0),
        duration_ms: (.duration_ms // 0),
        num_turns: (.num_turns // 0),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cache_read_input_tokens: (.usage.cache_read_input_tokens // 0),
        cache_creation_input_tokens: (.usage.cache_creation_input_tokens // 0),
        model: ((.modelUsage // {} | keys | first) // "unknown")
      }' 2>/dev/null \
    || echo '{"total_cost_usd":0,"duration_ms":0,"num_turns":0,"input_tokens":0,"output_tokens":0,"model":"unknown"}'
}
extract_tokens "$OUTPUT_DIR/session-output.json" > "$OUTPUT_DIR/session-tokens.json"
echo "Cost/tokens:"
cat "$OUTPUT_DIR/session-tokens.json"

# Write metrics.json in the CLI runner contract format the harness expects
# (matches run-solve.sh's pattern — token_usage/cost_usd/num_turns/model)
jq '{
  token_usage: {input: .input_tokens, output: .output_tokens},
  cost_usd: .total_cost_usd,
  num_turns: .num_turns,
  model: .model
}' "$OUTPUT_DIR/session-tokens.json" > "$OUTPUT_DIR/metrics.json" 2>/dev/null \
  || echo '{"cost_usd":0,"num_turns":0}' > "$OUTPUT_DIR/metrics.json"

# --- Step 4: post-exit status guard ---
#
# Regardless of claude -p's own exit code, ask the orchestrator directly
# whether it considers the rebase DONE. A clean process exit is not by
# itself sufficient evidence of completion (e.g. a stop-hook interaction
# on a near-timeout run could produce a clean-looking exit mid-rebase).
ORCH="$PLUGIN_DIR/scripts/k8s-rebase-orchestrator.sh"
if [[ -x "$ORCH" ]]; then
  bash "$ORCH" status "$REPO_DIR" > "$OUTPUT_DIR/final-status.txt" 2>&1 || true
else
  echo "ERROR: orchestrator not found at $ORCH" > "$OUTPUT_DIR/final-status.txt"
fi

# The orchestrator writes .rebase-tmp/status/INCOMPLETE unconditionally
# whenever a force-advance happens (k8s-rebase-orchestrator.sh's
# FORCE_ADVANCE_THRESHOLD path) — independent of whether `status` itself
# needs to reconstruct state from disk. `status`'s own output only
# surfaces this file conditionally (when state reconstruction was
# needed), so it is NOT a reliable way to detect a forced advance —
# check the file directly instead.
if [[ -f "$REPO_DIR/.rebase-tmp/status/INCOMPLETE" ]]; then
  cp "$REPO_DIR/.rebase-tmp/status/INCOMPLETE" "$OUTPUT_DIR/force-advance.log"
else
  : > "$OUTPUT_DIR/force-advance.log"
fi

# --- Step 5: gate reports ---
mkdir -p "$OUTPUT_DIR/gate-reports"
if [[ -d "$REPO_DIR/.rebase-tmp/gates" ]]; then
  cp "$REPO_DIR"/.rebase-tmp/gates/*.report "$OUTPUT_DIR/gate-reports/" 2>/dev/null || true
fi

# --- Step 6: diffs, with the same exclusions make court uses ---
#
# Same court_excludes as cmd_court (test-skill.sh) — vendor/go.sum/
# packages/mocks are generated/resolver output that would otherwise
# blow up the diff an LLM judge has to read.
COURT_EXCLUDES=(':!.rebase-tmp' ':(exclude,glob)**/vendor/**' ':(exclude,glob)**/go.sum' ':(exclude,glob)**/packages/**' ':(exclude,glob)**/mocks/**')
git diff "$FROM_COMMIT"..HEAD -- . "${COURT_EXCLUDES[@]}" > "$OUTPUT_DIR/diff.patch" 2>/dev/null || true
git diff "$FROM_COMMIT"..HEAD --name-only > "$OUTPUT_DIR/files-changed.txt" 2>/dev/null || true
git log --oneline "$FROM_COMMIT"..HEAD > "$OUTPUT_DIR/commit-log.txt" 2>/dev/null || true

if [[ -n "$KNOWN_GOOD_REF" ]]; then
  # known_good may live on a different repo (a personal fork hosting the
  # human-reviewed rebase branch) than repo_url — fetch from THAT remote,
  # not "origin" (repo_url), which does not have this ref.
  if [[ -n "$KNOWN_GOOD_URL" && "$KNOWN_GOOD_URL" != "$REPO_URL" ]]; then
    # On a cached clone (evals/.repos/ reuse), a PRIOR run may have added
    # known-good-remote pointing at a DIFFERENT fork's URL. `git remote
    # add` fails silently (`|| true`) when the remote name already
    # exists, which would leave it pointing at the stale URL — always
    # set-url first (falling back to add only if the remote doesn't
    # exist yet) so the remote is current regardless of what a prior
    # run against this same cached clone used.
    git remote set-url known-good-remote "$KNOWN_GOOD_URL" 2>/dev/null \
      || git remote add known-good-remote "$KNOWN_GOOD_URL"
    git fetch known-good-remote "$KNOWN_GOOD_REF"
  else
    git fetch origin "$KNOWN_GOOD_REF"
  fi
  KNOWN_GOOD_SHA=$(git rev-parse FETCH_HEAD)
  git diff "$FROM_COMMIT".."$KNOWN_GOOD_SHA" -- . "${COURT_EXCLUDES[@]}" > "$OUTPUT_DIR/known-good.patch" 2>/dev/null || true
else
  : > "$OUTPUT_DIR/known-good.patch"
fi

# --- Step 7: extracted build-error artifact ---
#
# Give the no_scope_creep judge something concrete to cite instead of
# mining the raw stream-json transcript itself. Build/vet errors surface
# via tool_result content (e.g. `go build` output handed back to the
# agent) — extract only that, not assistant prose (which summarizes
# errors the agent already saw and adds noise, not signal).
jq -r '
  select(.type == "user") | .message.content[]? | select(.type == "tool_result") |
  (.content[]? | select(.type == "text") | .text) // (.content // empty)
' "$OUTPUT_DIR/session-output.json" 2>/dev/null \
  | grep -iE '(error|failed|undefined|cannot use|type mismatch|cannot find|not enough arguments|too many arguments|does not implement|incompatible types|has no field|declared (and not used|but not used))' \
  > "$OUTPUT_DIR/build-errors.txt" || true

# --- Step 8: push-attempt log ---
#
# Scope to tool_use events only — the skill prints a `git push` command
# for the user to copy in Step 5, so a raw transcript grep false-positives
# on that prose. Only an actual tool_use call is a real attempt.
# Write a sentinel token (PUSH_STATUS: NONE / PUSH_STATUS: BLOCKED /
# PUSH_STATUS: ATTEMPTED_UNBLOCKED) so the judge matches on a stable
# token rather than prose that could drift.
if jq -e '[.[] | select(.type=="tool_use") | .input.command // ""] |
    any(test("git\\s+push|gh\\s+pr\\s+create"))' \
    "$OUTPUT_DIR/session-output.json" 2>/dev/null; then
  if grep -q "BLOCKED: The k8s-rebase skill does not push or create PRs" \
      "$OUTPUT_DIR/session-output.json" 2>/dev/null; then
    echo "PUSH_STATUS: BLOCKED" > "$OUTPUT_DIR/push-attempt.log"
    echo "Push/PR-create tool_use found; denial text confirmed." >> "$OUTPUT_DIR/push-attempt.log"
  else
    echo "PUSH_STATUS: ATTEMPTED_UNBLOCKED" > "$OUTPUT_DIR/push-attempt.log"
    echo "WARNING: push/PR-create tool_use found but denial text NOT found." >> "$OUTPUT_DIR/push-attempt.log"
  fi
else
  echo "PUSH_STATUS: NONE" > "$OUTPUT_DIR/push-attempt.log"
fi

# Remove large stream-json file so the harness doesn't load tens of MB
# into outputs["files"] — metrics/tokens are already extracted above.
rm -f "$OUTPUT_DIR/session-output.json"

# --- Success: mark completed ---
trap - ERR
write_status "completed" ""
echo ""
echo "=== Run complete (skill exit $SKILL_EXIT) ==="
