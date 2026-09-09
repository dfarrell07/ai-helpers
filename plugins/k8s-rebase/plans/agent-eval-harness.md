# k8s-rebase Agent Eval

## Status

**Implemented and hardened.** `evals/scripts/run-rebase.sh`,
`evals/eval-k8s-rebase-pattern-retention.yaml`, and 6 cases are shipped and
have been through multiple adversarial review + fix cycles.

## What it does

Wraps the skill in a `claude plugin eval`-compatible harness to answer PR #617's
question: does k8s-rebase have cost/model measurement? It does now. Six cases
(one per repo in `test/config-1.36.yaml`) run the skill against a real repo snapshot,
capture cost/tokens from `claude -p`'s `stream-json` output, and score the result
against a human-reviewed known-good rebase via 5 deterministic + 2 LLM judges.
Lighter-weight smoke check than `make court` (single LLM pass vs. adversarial
3-juror panel) — a passing run means "worth shipping," not "fully validated."

## Open work

### Calibration (required before thresholds are real)

`timeout`, `max_budget_usd`, and LLM judge `min_mean` are all uncalibrated
placeholders. Before trusting any eval results:

1. Run once against the cheapest case (case-002, `ovn-kubernetes-mcp`, or
   case-003, `multus-cni`). Record actual cost and duration.
2. Score one known-good diff and one obviously-bad diff through both LLM judge
   prompts; set `min_mean` in the gap between those two scores.
3. Confirm `known-good.patch` is non-empty for the calibration case before
   trusting any judge that uses it.

`ovn-org/ovn-kubernetes` (case-001) is the largest repo and may need a per-case
timeout/budget override rather than one global number.

### Potential follow-on (not blocking)

- **`{**files, **modified}` merge pattern** is copy-pasted across all 5
  deterministic judge check blocks. If the harness ever adds a shared-helper
  mechanism, factor it out. For now a comment on the first instance documents it.
- **`rebase_correctness` / `no_scope_creep` are weaker than `make court`** —
  single LLM pass, no adversarial jury, no mandatory per-claim citation. If a
  future legitimate skill improvement scores lower here without being a regression,
  recalibrate rather than reverting the skill change.
