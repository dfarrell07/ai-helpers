# Workflow design

A Kubernetes rebase can compile and still be wrong: a type conversion may
drop fields, generated CRDs may lose validation, or tests may hang behind a
new feature gate. The workflow therefore separates doing the work from
deciding whether it is complete.

The central pattern is a **state machine at the top level**, outside the
agent doing each step. This limits a form of reward hacking: optimizing for
the visible finish line (a PR command or a green summary) by skipping the
checks that make the result useful. Normal advancement requires recorded
evidence, and unresolved work stays visible even when the workflow moves on.

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
Ordinary work can run inline when workers are unavailable. Independent
review has a separate context requirement.

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

| Signal | Meaning |
| --- | --- |
| `gates`: PENDING | A judgment is still needed; normal pending output exits 1 |
| `gates`: EXISTING or RESOLVED | A fresh verdict exists; it may be FAIL or INCONCLUSIVE |
| `gates` exit 0 | No judgments pending; does not establish that gates passed |
| Fresh PASS or justified SKIP | Accepted by normal advancement; preserve SKIP and its reason |
| Missing, malformed, stale, FAIL, or INCONCLUSIVE report | Blocks normal advancement |
| `advance` exit 2 with FORCE_ADVANCE | State already moved with unresolved checks; read the warning and `status` |
| `advance` exit 2 with ERROR | Hard error; stop |
| DONE | Traversal complete; neither all checks passed nor Step 5 completed |

Repair iterations and blocked advancement attempts are different counters.
The skill shares a three-iteration repair budget across parent and workers.
The script force-advances on the third blocked `advance` call. The skill
permits this after exhausted repairs in Steps 2–4, while Step 1 structural
failures stop without advancement. That Step 1 restriction is an instruction,
not a special case in the script. Use `status` for polling: `advance` mutates
state and consumes attempts.

Force-advance bounds unproductive loops; it does not convert failures into
success. `.rebase-tmp/status/INCOMPLETE` records only the latest forced
transition. Final reporting must inventory **every expected gate**, including
missing reports, through `reports`, and preserve unresolved findings from
earlier steps. `status` groups SKIP under PASS; `reports` keeps them distinct.

## Separate evidence, judgment, and repair

Eight companion scripts collect facts into `.evidence` files; they currently
leave verdicts to the gate reviewer. Run them through `gates`, which caches
fresh reports and defers crashed companions to review. A crash, empty output,
or missing tool is not evidence of a successful check.

Evidence and reports carry `HEAD:`. After a fix commit, refresh **all
current-step** reports, including previous PASS results. Preserve prior-step
reports as historical evidence, not claims of retesting the final commit.
HEAD stamps cannot detect uncommitted edits: use one writer, commit before
review, and keep source mutations separate from parallel evidence collection.

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
not Step 5 completion. Some gate rubrics are informational or allow degraded
checks. Read report details as well as verdicts. The
[compatibility record](../plans/claude-codex-compatibility.md) documents
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

When extending this design, put a repeatable measurement in a companion,
its interpretation in a gate prompt, and source repair in the implementing
step. Keep reusable breakage knowledge in the bounded
[pattern guide](k8s-rebase-patterns.md). Every `.md` in a gate directory is
an expected gate: explanatory documentation belongs here, outside `gates/`.
