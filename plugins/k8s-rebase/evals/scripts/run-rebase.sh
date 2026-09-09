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
#   run-rebase.sh <repo_url> <from_commit> <version> [model]
#
# Env vars:
#   AI_HELPERS_DIR   — path to ai-helpers checkout (default: auto-detect)
#   EVAL_REPO_DIR    — override the clone location (default: cached under
#                       evals/.repos/, keyed by repo_url)
#   SKILL_MAX_TURNS  — passed to claude -p --max-turns (default: 200)

REPO_URL=${1:?"Usage: $0 <repo_url> <from_commit> <version> [model]"}
FROM_COMMIT=${2:?"Usage: $0 <repo_url> <from_commit> <version> [model]"}
VERSION=${3:?"Usage: $0 <repo_url> <from_commit> <version> [model]"}
SKILL_MODEL=${4:-claude-sonnet-4-6}
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
git fetch origin "$FROM_COMMIT" 2>/dev/null || true
git reset --hard "$FROM_COMMIT"
git clean -fdx
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
  --disallowed-tools 'Bash(git push *),Bash(*git push*),Bash(git -c *push*),Bash(*send-pack*),Bash(gh pr create *),Bash(*gh pr create*),Bash(*gh api*repos*pulls*),Bash(sleep *)' \
  2>"$OUTPUT_DIR/session-stderr.log" \
  | tee "$OUTPUT_DIR/session-output.json"
SKILL_EXIT=${PIPESTATUS[0]}
set -e
echo "Skill exit code: $SKILL_EXIT"

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

# --- Step 6: gate reports ---
mkdir -p "$OUTPUT_DIR/gate-reports"
if [[ -d "$REPO_DIR/.rebase-tmp/gates" ]]; then
  cp "$REPO_DIR"/.rebase-tmp/gates/*.report "$OUTPUT_DIR/gate-reports/" 2>/dev/null || true
fi

# --- Step 7: diffs, with the same exclusions make court uses ---
#
# Same court_excludes as cmd_court (test-skill.sh) — vendor/go.sum/
# packages/mocks are generated/resolver output that would otherwise
# blow up the diff an LLM judge has to read.
COURT_EXCLUDES=(':!.rebase-tmp' ':(exclude,glob)**/vendor/**' ':(exclude,glob)**/go.sum' ':(exclude,glob)**/packages/**' ':(exclude,glob)**/mocks/**')
git diff "$FROM_COMMIT"..HEAD -- . "${COURT_EXCLUDES[@]}" > "$OUTPUT_DIR/diff.patch" 2>/dev/null || true
git diff "$FROM_COMMIT"..HEAD --name-only > "$OUTPUT_DIR/files-changed.txt" 2>/dev/null || true
git log --oneline "$FROM_COMMIT"..HEAD > "$OUTPUT_DIR/commit-log.txt" 2>/dev/null || true

KNOWN_GOOD="${KNOWN_GOOD_REF:-}"
if [[ -n "$KNOWN_GOOD" ]]; then
  git fetch origin "$KNOWN_GOOD" 2>/dev/null || true
  git diff "$FROM_COMMIT".."$KNOWN_GOOD" -- . "${COURT_EXCLUDES[@]}" > "$OUTPUT_DIR/known-good.patch" 2>/dev/null || true
else
  : > "$OUTPUT_DIR/known-good.patch"
fi

# --- Step 8: extracted build-error artifact ---
#
# Give the no_scope_creep judge something concrete to cite instead of
# mining the raw stream-json transcript itself.
grep -iE '(error|failed|undefined|cannot use|type mismatch)' "$OUTPUT_DIR/session-output.json" 2>/dev/null \
  | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text // empty' 2>/dev/null \
  | grep -iE '(error|failed|undefined|cannot use|type mismatch)' \
  > "$OUTPUT_DIR/build-errors.txt" || true

# --- Step 9: push-attempt log ---
#
# A hook block produces denial text, not silence — record whichever
# happened so the judge can distinguish "never attempted" from
# "attempted and blocked" rather than treating both as "clean output."
if grep -qE '(git\s+push|gh\s+pr\s+create)' "$OUTPUT_DIR/session-output.json" 2>/dev/null; then
  echo "push/PR-create command text found in transcript:" > "$OUTPUT_DIR/push-attempt.log"
  grep -E '(git\s+push|gh\s+pr\s+create)' "$OUTPUT_DIR/session-output.json" >> "$OUTPUT_DIR/push-attempt.log" || true
  echo "---" >> "$OUTPUT_DIR/push-attempt.log"
  if grep -q "BLOCKED: The k8s-rebase skill does not push or create PRs" "$OUTPUT_DIR/session-output.json" 2>/dev/null; then
    echo "Denial text found — attempt was blocked." >> "$OUTPUT_DIR/push-attempt.log"
  else
    echo "WARNING: denial text NOT found for this attempt." >> "$OUTPUT_DIR/push-attempt.log"
  fi
else
  echo "No push/PR-create attempt found in transcript." > "$OUTPUT_DIR/push-attempt.log"
fi

# --- Success: mark completed ---
trap - ERR
write_status "completed" ""
echo ""
echo "=== Run complete (skill exit $SKILL_EXIT) ==="
