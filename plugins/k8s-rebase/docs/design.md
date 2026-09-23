# Workflow design

A Kubernetes rebase can compile and still be wrong: a type conversion may
drop fields, generated CRDs may lose validation, or tests may hang behind a
new feature gate. The workflow therefore separates doing the work from
deciding whether it is complete.

The central pattern is a **state machine at the top level**, outside the
agent doing each step. This limits a form of reward hacking: optimizing for
the visible finish line (a PR command or a green summary) by skipping the
checks that make the result useful. A worker returns evidence; the parent
submits the transition; the orchestrator checks the reports. Unresolved work
stays visible even when the workflow moves on.

## Put each responsibility in the right layer

| Layer | Responsibility | Source |
| --- | --- | --- |
| Scripts | Repeatable mutations and measurements: dependency resolution, codegen, autofix, validation | [Rebase](../scripts/k8s-rebase.sh), [autofix](../scripts/k8s-rebase-autofix.sh), [validator](../scripts/k8s-rebase-validate.sh) |
| Hooks | Guard prohibited actions: direct module operations, vendor edits, publishing, deleting prior reports, premature exit | [Hook definitions](../hooks/hooks.json) |
| Gates | Ask a bounded question and record counts, findings, and a verdict | [Gate prompts](../gates), [report writer](../scripts/write-gate-report.sh) |
| Skill and orchestrator | Route work, preserve state, and decide when to advance | [Skill entry point](../skills/k8s-rebase/SKILL.md), [state machine](../scripts/k8s-rebase-orchestrator.sh) |

Move repeatable work into scripts as its rules become understood. Derive
versions and applicable operations from repository and release metadata;
keep unfamiliar API migrations and semantic fixes with the agent. Scripted
work still needs verification: determinism makes a defect reproducible,
not impossible.

Load the shared [rules](../skills/k8s-rebase/steps/rules.md) and current step
on demand. A step worker receives paths, target version, options, and its
scope; it returns findings and retry counts. **Only the parent advances.**
This gives the worker a local task instead of the final PR as its immediate
finish line. Ordinary work can run inline when workers are unavailable;
independent review has a separate context requirement.

## Make advancement an explicit protocol

```text
init / resume
  → 1. Mechanical rebase       [1 gate]
  → 2. Compilation fixes      [6 gates]
  → 3. Autofix and discovery  [10 gates]
  → 4. Validation and review  [15 gates]
  → DONE                     [gated traversal complete]
  → 5. Full-rebase review, PR command, cleanup
```

At each gated step, commit fixes, collect evidence with `gates`, review
pending findings, and submit the handoff with `advance`. State lives in
`.rebase-tmp/state.json`; progress is not inferred from the agent's prose.
Step 5 is outside the orchestrator's four gated steps and never calls
`advance`.

The script checks each expected report for one recognized verdict and a
matching HEAD. It does **not** evaluate the evidence, issue count, or SKIP
justification. Those remain reviewer responsibilities. Parent-only advancement,
the repair budget, and Step 1's stop policy are instruction-level contracts;
the blocked-advance counter and report checks are implemented in the script.

| Signal | Meaning |
| --- | --- |
| `gates`: PENDING | A judgment is still needed; normal pending output exits 1 |
| `gates`: EXISTING or RESOLVED | A fresh verdict exists; it may be FAIL or INCONCLUSIVE |
| `gates` exit 0 | No judgments pending; does not establish that gates passed |
| Fresh PASS or justified SKIP | Accepted by normal advancement; preserve SKIP and its reason |
| Missing report, invalid verdict, missing/mismatched HEAD, FAIL, or INCONCLUSIVE | Blocks normal advancement |
| `advance` exit 2 with FORCE_ADVANCE | State already moved with unresolved checks; read the warning and `status` |
| `advance` exit 2 with ERROR | Hard error; stop |
| DONE | Traversal complete; neither all checks passed nor Step 5 completed |

Repair iterations and blocked advancement attempts are different counters.
The skill shares a three-iteration repair budget across parent and workers.
The script force-advances on the third blocked `advance` call. The skill
permits this after exhausted repairs in Steps 2–4, while Step 1 structural
failures stop without advancement. Use `status` for polling: `advance` mutates
state and consumes attempts. Both repair and advancement counts must survive
a worker handoff; only the latter is persisted by the orchestrator.

Force-advance bounds unproductive loops; it does not convert failures into
success. `.rebase-tmp/status/INCOMPLETE` records only the latest forced
transition. Final reporting must inventory **every expected gate**, including
missing reports, through `reports`, and preserve unresolved findings from
earlier steps. `status` groups SKIP under PASS; `reports` keeps them distinct.

## Separate evidence, judgment, and repair

Eight companion scripts collect facts into `.evidence` files; they currently
leave verdicts to the gate reviewer. Run them through `gates`, which caches
fresh reports and defers crashed companions to review. A crash, empty output,
or missing tool is not evidence of a successful check. Check coverage and
command completion before interpreting a zero issue count.

Evidence and reports carry `HEAD:`. For example, if Step 3 has nine PASS
reports and one FAIL at commit A, a fix at commit B makes **all ten** reports
stale. Collect evidence and review them again before advancement. Step 1–2
reports remain historical evidence at their recorded commits. HEAD stamps
cannot detect uncommitted edits: use one writer, commit before review, and
keep source mutations separate from parallel evidence collection.

Gate reviewers are read-only except for their own report. They cite counts,
file locations, and what they inspected; the implementing agent investigates
findings and applies fixes. Compare with the base to distinguish a rebase
regression from existing debt. Unchanged source can break against a changed
dependency, so an unchanged line alone does not establish a baseline pass.

Independent review receives evidence and a rubric without the implementer's
reasoning history. Step 4 reviews a selected commit; Step 5 reviews the full
branch. Scope and revision matter: approval of one does not approve later
changes or upgrade another gate's verdict. Claude's helpers retain an
infrastructure fallback; Codex requires checked prompt preparation and a
fresh-context reviewer. The exact host contracts remain in the step files.

These are layered safeguards, not proof of correctness. Hooks depend on
runtime activation and use heuristic matching; the Stop hook observes DONE,
not Step 5 completion. Two gates are informational and always PASS.
Read report details as well as verdicts. The
[compatibility note](compatibility.md) documents
specific enforcement and qualification limits.

## Test the workflow, not just its output

The [test harness](../test/test-skill.sh) compares real rebases with known-good
references. Mutation modes remove pattern guidance, autofix functions, or
both from a copied plugin: can the remaining workflow discover and repair
the breakage? These test recovery from withheld help on known cases;
unmodified pattern-retention evals test preservation of learned fixes.
Neither establishes generalization to unseen repositories or releases.

`make court` adds prosecution, defense, a fact-checking judge, and three
jurors. Jurors must check the baseline for claims of introduced regressions;
ties or insufficient votes are INCONCLUSIVE. A different diff can still be
correct. The court and in-run gates answer different questions, so neither
result should erase the other's findings. See the [eval guide](../evals/README.md)
for coverage, commands, and scoring limits.

## Extend without duplicating the contract

The informational [skill-improvement gate](../gates/step4-verification/skill-improvement.md)
closes the learning loop: a manual repair can become a reusable
[pattern](k8s-rebase-patterns.md), then an autofix with detection and
post-fix verification. Validate detection on the pre-fix revision; zero
matches after repair may be the expected result. Mutation runs check whether
the remaining workflow can recover when that learned help is withheld.

Put repeatable measurement in a companion, interpretation in a gate prompt,
and repair in the implementing step. Keep routing in SKILL.md and the shared
repair loop in rules.md; step files supply their work, gates, and exceptions.

Every `.md` in a gate directory becomes an expected gate. Adding one changes
advancement and the final inventory; update the step's gate list and coverage
description together. An executable companion shares its prompt's basename
and writes through [gate-script-lib.sh](../scripts/gate-script-lib.sh). Check the pair
with `make assert-evidence-paths`. Explanatory docs belong outside `gates/`.
