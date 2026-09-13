# k8s-rebase Agent Eval

## Status

**Implemented and hardened.** `evals/scripts/run-rebase.sh`,
`evals/eval-k8s-rebase-pattern-retention.yaml`, and 6 cases are shipped and
have been through multiple adversarial review + fix cycles including comparison
against all other plugin evals in this repo.

## What it does

Wraps the skill in a `claude plugin eval`-compatible harness to answer PR #617's
question: does k8s-rebase have cost/model measurement? It does now. Six cases
(one per repo in `test/config-1.36.yaml`) run the skill against a real repo snapshot,
capture cost/tokens from `claude -p`'s `stream-json` output, and score the result
against a human-reviewed known-good rebase via 5 deterministic + 2 LLM judges.
Lighter-weight smoke check than `make court` (single LLM pass vs. adversarial
3-juror panel) — a passing run means "worth shipping," not "fully validated."

## How to run

```bash
# via make (manually-triggered, same as make court)
make eval case=002

# directly
bash evals/scripts/run-rebase.sh <repo_url> <from_commit> <version> <model> <known_good_url> <known_good_ref>

# via harness (runs all cases)
claude plugin eval evals/eval-k8s-rebase-pattern-retention.yaml
```

## Open work

### Calibration — case-002 complete (2026-09-13)

Calibration run against case-002 (ovn-kubernetes-mcp) complete. Key results:

- **Actual cost**: ~$12 cumulative (claude-sonnet-4-6, full 4-step rebase)
- **Actual duration**: ~50 minutes (rough lower bound; run was backgrounded)
- **All 31 gates**: PASS. `DONE: true`. No force-advance. No push attempt.
- **diff.patch**: 197 lines. Core k8s bump (api/apimachinery/client-go/kubectl/kubernetes
  all v0.36.2, controller-runtime v0.24.1, K8S_VERSION v1.36.2) matches known-good exactly.
  Acceptable variance: Go toolchain 1.27 vs 1.26 (MVS-driven), go-openapi indirect major
  bumps, golang.org/x/* patch drift, openshift/api timestamp differences.
- **known-good.patch**: 177 lines, non-empty — LLM judges have real reference to compare.

Two bugs found and fixed during calibration:

1. **`Bash(sleep *)` in `--disallowed-tools` broke the eval**: the skill relies on sleep
   to poll for `k8s-rebase.sh` completion. Blocking sleep caused the session to terminate
   early (22 turns) with `DONE: false`. Fixed: removed `sleep` from the block list. Safety
   properties are unaffected (push/PR-create and go mod ops are still blocked).

2. **Metrics extraction used `head -1` instead of `tail -1`**: in multi-turn sessions
   (background-task-woken), the first `"type":"result"` event is a partial-cost snapshot.
   The last event has the true cumulative cost. Fixed: `head -1` → `tail -1`.

**LLM judge thresholds calibrated**: scored case-002 good diff (4/3) and an
obviously-bad diff (1/1) through both judges. Gap is 3 points; `min_mean: 2.5`
set for both. `no_scope_creep` good score is 3 not 4 because `build-errors.txt`
captures skill prose rather than real compiler output — known limitation.

**Timeout/budget**: `timeout: 43200` (12h) is safe for all cases including case-001.
`max_budget_usd: 150.0` covers case-002 ($12) with headroom; case-001 (ovn-kubernetes)
may be significantly more expensive — monitor the first run.

`ovn-org/ovn-kubernetes` (case-001) is the largest repo and may need a per-case
timeout/budget override rather than one global number.

## Convention alignment (verified against all other plugins)

- **Runner type**: `cli` (same as `openshift-developer/eval-solve.yaml`)
- **`metrics.json`**: written in the CLI runner contract format (`token_usage`, `cost_usd`, `num_turns`, `model`)
- **`session-output.json`**: deleted at end of run (matches `run-solve.sh`'s pattern — prevents large JSONL from loading into harness outputs)
- **Jinja2 loops**: multi-line `{% for path, content in outputs.files.items() if path.endswith('...') %}` — matches the exact form used by every peer eval; `outputs.modified_files` is not available in prompt template context (only in Python check blocks)
- **`--disallowed-tools`**: blocks `git push`/`gh pr create` AND `go mod tidy/get/vendor/edit`, `go get`, `go generate`, `go run` (all forbidden by SKILL.md). `sleep` is NOT blocked — step1 needs it to poll for `k8s-rebase.sh` completion (blocking it caused eval failure in calibration).
- **`events: false`**: explicitly set (matches all peer evals — omitting it is equivalent but all peers set it)
- **`dataset.schema`**: present — documents input.yaml and annotations.yaml fields (matches all peer evals)
- **`permissions` block**: not needed (`cli` runner evals don't use it; only `claude-code` runner evals do)

## Potential follow-on (not blocking)

- **`go mod`/`go run`/`go get` blocks in `--disallowed-tools`** should be verified during calibration — confirm the skill doesn't try to call them. A block returns a tool error to the agent (not a process exit), so it won't cause `infra_error` — but repeated blocks could confuse the skill's step loop.
- **`rebase_correctness` / `no_scope_creep` are weaker than `make court`** — single LLM pass, no adversarial jury. A legitimate skill improvement that scores lower here without regressing should trigger recalibration, not a revert.
- **Step 5 `gh pr create` command**: eval verifies the command was not *executed*, but doesn't verify it was *printed* for the user. A skill that skipped step5-pr.md entirely and reported DONE would still pass all judges.
