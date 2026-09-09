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

### Calibration (required before thresholds are real)

`timeout`, `max_budget_usd`, and LLM judge `min_mean` are all uncalibrated
placeholders. Before trusting any eval results:

1. Run once against the cheapest case (`make eval case=002` or `case=003`).
   Record actual cost and duration.
2. Score one known-good diff and one obviously-bad diff through both LLM judge
   prompts; set `min_mean` in the gap between those two scores.
3. Confirm `known-good.patch` is non-empty for the calibration case before
   trusting any judge that uses it.

`ovn-org/ovn-kubernetes` (case-001) is the largest repo and may need a per-case
timeout/budget override rather than one global number.

## Convention alignment (verified against all other plugins)

- **Runner type**: `cli` (same as `openshift-developer/eval-solve.yaml`)
- **`metrics.json`**: written in the CLI runner contract format (`token_usage`, `cost_usd`, `num_turns`, `model`)
- **`session-output.json`**: deleted at end of run (matches `run-solve.sh`'s pattern — prevents large JSONL from loading into harness outputs)
- **Jinja2 loops**: multi-line `{% for path, content in outputs.files.items() if path.endswith('...') %}` — matches the exact form used by every peer eval; `outputs.modified_files` is not available in prompt template context (only in Python check blocks)
- **`--disallowed-tools`**: blocks `git push`/`gh pr create` AND `go mod tidy/get/vendor/edit`, `go get`, `go generate`, `go run` (all forbidden by SKILL.md)
- **`events`**: omitted (equivalent to `false`)
- **`permissions` block**: not needed (`cli` runner evals don't use it; only `claude-code` runner evals do)

## Potential follow-on (not blocking)

- **`go mod`/`go run`/`go get` blocks in `--disallowed-tools`** should be verified during calibration — confirm the skill doesn't try to call them. A block returns a tool error to the agent (not a process exit), so it won't cause `infra_error` — but repeated blocks could confuse the skill's step loop.
- **`rebase_correctness` / `no_scope_creep` are weaker than `make court`** — single LLM pass, no adversarial jury. A legitimate skill improvement that scores lower here without regressing should trigger recalibration, not a revert.
- **Step 5 `gh pr create` command**: eval verifies the command was not *executed*, but doesn't verify it was *printed* for the user. A skill that skipped step5-pr.md entirely and reported DONE would still pass all judges.
