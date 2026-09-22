# Agent eval implementation record

The pattern-retention runner is implemented. It runs the skill on real
repository snapshots, captures cost/tokens from Claude's `stream-json`
output, and produces artifacts for deterministic checks and LLM judges.
See the [eval guide](../evals/README.md) for current commands, the 16-case
coverage table, scoring, and limitations; the
[eval definition](../evals/eval-k8s-rebase-pattern-retention.yaml) is the
executable scoring contract.

## Initial calibration

The 2026-09-13 case-002 run (ovn-kubernetes-mcp) recorded about $12,
50 minutes, and 31 PASS reports. That is historical evidence from one run,
not today's expected gate count or a full-suite qualification. The initial
correctness/scope thresholds were set to 2.5 from good=4/3 and bad=1/1 scores.
No direct module-operation attempts were observed; that does not test hook
denial behavior.

## Follow-on work

The suite now checks for a printed Step 5 PR command and includes a
gap-analysis judge. Broader calibration and negative-case work remain in
the [eval backlog](eval-improvements.md). A low LLM score calls for evidence
review and court comparison; it does not by itself justify reverting a
valid skill improvement.
