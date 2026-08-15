# Gate Architecture v3 — Audit Record

**Audit date:** 2026-08-15  
**Plan audited:** `gate-architecture-v3.md` at commit `0e7e47de`  
**Verdict:** NEEDS_FIXES_FIRST — architecture is sound; 6 plan-accuracy gaps must be fixed
before implementation starts; 1 HIGH gap requires a test-skill.sh code change before Phase 1.

## Methodology

23-agent ultracode workflow: 8 independent auditors on different architectural dimensions,
adversarial challenge of every HIGH/MEDIUM finding (default-to-refuted), then synthesis.
1.17M tokens, 198 tool calls. Agents read live code directly; no claims accepted without
file:line verification.

**Dimensions audited:**
- Phase 0 crash-semantics change (behavioral impact before and after)
- NEW_ISSUES=0 dead code / wasted-subagent claim
- Phase 2 evidence transport model soundness
- Phase 1 decision gate — metric definition and executability
- Phase 3 value — companion-less gate scripts
- Migration safety — can Phase 2 be executed without breaking active rebases
- build-vet-as-filter promotion path
- Production gap — what the plan leaves unfixed

14 HIGH/MEDIUM findings raised. 7 survived adversarial challenge. 7 refuted.

---

## Survived Findings

### F1 — HIGH: Phase 1 metrics requirement is unbuildable

**Plan claims:** "The committed metrics snapshot must join the results.tsv row with the
court verdict per repo/version" and "pin to a committed metrics file before they gate
the decision."

**What is actually true:** `test-skill.sh:1016` deletes court verdict files inside
`record()` — before they can be captured. `results.tsv` has exactly 6 columns (ts,
version, spec, repo-short, gate-completion-verdict, detail); court verdict is not one
of them. `_results_for_version` reads the live court file (`:1615-1617`), which returns
`-` for any completed run because the file was already deleted. The JOIN the plan requires
is impossible without first persisting the court verdict at record time.

**Consequence:** Phase 1 cannot execute as written. The go/no-go gate is vacuous.

**Required fix (test-skill.sh code change, not a plan-text fix):** Modify `record()` to
persist the court verdict before the `rm -f` — write a court-verdict column to
`results.tsv` or a parallel file. Document this as an explicit Phase 1 sub-step. This
must land before Phase 1 runs.

---

### F2 — MEDIUM: Phase 0→Phase 2 window: crashed companions may silently PASS

**Plan claims:** "A crashed companion writes no report and no evidence → PENDING →
subagent (which judges from scratch), same as a companion-less gate."

**What is actually true:** Only true after Phase 2 removes MANDATORY FIRST STEP blocks.
During the Phase 0→Phase 2 window, gate `.md` files still contain MANDATORY FIRST STEP
blocks. The chain: companion crashes → `.crash` (no FAIL report) → PENDING → subagent
dispatched → MANDATORY re-runs companion → crashes again → RULE 1 (needs `NEW_ISSUES=0`),
RULE 2 (needs NEW-marked issues), fallback (needs script not found) — none apply to crash
output → undefined subagent behavior → likely PASS. Currently a crash writes a clearly
labeled FAIL that blocks `cmd_advance`. After Phase 0, the same crash silently passes.

**Consequence:** A companion crash that today produces an explicit blocking signal instead
routes to a judgment subagent that follows rule logic designed for successful runs.

**Required fix (plan text):** Add an entry to the Risks table acknowledging this
time-bounded regression window. Either: (a) accept it as bounded to the Phase 0→Phase 2
landing interval and require prioritizing Phase 2, or (b) restructure Phase 0 to make
each unit atomic: per-companion, remove the MANDATORY block in the same PR that rewrites
`_gate_trap`.

---

### F3 — MEDIUM: Plan falsely claims step-4 fix loop "already routes through orchestrator gates 4"

**Plan claims:** "Step 4's own gate-fix loop (`step4-verification.md:71-76`) already routes
through `orchestrator gates 4` (it is the reference the steps-1-3 wiring mirrors), so its
correctness is already protected by the consumer freshness check; add a one-line note…
a value/consistency touch, not a correctness fix."

**What is actually true:** `step4-verification.md:71-76` says "delete old report,
re-validate `--no-test`, re-run gate" — no orchestrator invocation anywhere in the fix
loop. The sole orchestrator call is at line 58, the initial gates launch, not the
subsequent fix loop. A Phase 2 implementer reading "already protected" will not update the
step-4 fix loop, leaving it with the identical stale-evidence problem the plan correctly
mandates fixing for steps 1-3. The fix loop is where evidence freshness matters most: it
determines whether a developer's fix actually resolved a gate FAIL.

**Required fix (plan text):** Correct the false claim. State that step 4's fix loop does
NOT currently invoke the orchestrator. Apply the same mandatory requirement: re-invoke
`orchestrator gates 4` before re-launching the subagent. Remove "value/consistency touch,
not a correctness fix" — that characterization is wrong at Phase 2 landing.

---

### F4 — MEDIUM: Phase 2 fix-loop update requirement lives in prose, not numbered sub-steps

**Plan claims:** Phase 2 names "Also in scope: the step-1-3 gate-fix re-run loops" in a
prose paragraph within the phase description.

**What is actually true:** The six numbered Phase 2 per-gate sub-steps contain no item for
"update fix-loop instructions in step1/2/3.md (and step4)." A developer following only the
numbered steps completes all six gate conversions with un-updated fix loops.

**Consequence:** Every production fix-loop re-evaluation runs with no evidence after Phase 2
lands — the path that determines whether a developer's fix resolved a FAIL.

**Required fix (plan text):** Add a numbered sub-step (or explicit per-step checklist item):
"Update `step1-rebase.md:96-99`, `step2-compilation.md:177-180`, `step3-autofix.md:102-108`
fix-loop instructions to call `orchestrator gates <step>` before deleting the old report and
re-launching the subagent. Also update `step4-verification.md:71-76` (see F3)."

---

### F5 — MEDIUM: GATE_OUTER_TIMEOUT dynamic computation has no implementation path

**Plan claims:** Phase 0(e): "give the orchestrator its own `GATE_OUTER_TIMEOUT` computed
as `2 × GATE_TIMEOUT × (module-count)` (count non-vendor `go.mod` at spawn time)." The
Execution model snippet references `${GATE_OUTER_TIMEOUT:-900}`.

**What is actually true:** `GATE_OUTER_TIMEOUT` does not exist anywhere in live code (grep
of `scripts/` and `gates/` returns nothing). The code snippet uses a static 900s fallback.
The dynamic computation requires: (a) detecting that the companion about to run is
`build-vet` (the only companion with per-module inner loops), (b) counting non-vendor
`go.mod` files in the repo, and (c) computing the value before spawning. None of these
appear in any code snippet in the plan.

**Consequence:** Implementers will ship Phase 0(e) with a static 900s default that
SIGTERMs healthy slow companions on multi-module repos — the exact problem Phase 0(e)
exists to prevent.

**Required fix (plan text):** Add a concrete code snippet showing the three-step
computation in `cmd_gates`: detect companion is `build-vet` by filename, count non-vendor
`go.mod` files with `find`, set `GATE_OUTER_TIMEOUT = 2 × GATE_TIMEOUT × N` before the
`timeout` call.

---

### F6 — MEDIUM: Phase 1 go/no-go threshold is undefined

**Plan claims:** "the go/no-go for the rollout is court verdict / false-FAIL rate" and
"If it no longer binds, stop after Phase 0."

**What is actually true:** The plan provides baseline numbers (95% recent 21-run window,
44% low-water for ovn-org/ovn-kubernetes, 91% excluding infra-fails) and the qualitative
label "Mixed, not solved" but never states what measured rate constitutes "no longer
binding." Two engineers reading the same numbers can reach opposite verdicts.

**Required fix (plan text):** Define a concrete decision boundary before Phase 1 runs.
Example form: "If false-FAIL rate on the post-stripping baseline falls below X% across at
least two confirm-by-rerun samples on the fixed repo/version set, stop after Phase 0." The
threshold values are for the team to choose, but they must be written down before measuring
— or the gate provides no decision discipline.

---

### F7 — MEDIUM: No rule governs when the step .md orchestrator call lands during Phase 2 rollout

**Plan claims:** Phase 2 sub-step 2 says "Add the `gates` call" as part of each companion's
individual PR.

**What is actually true:** Adding `orchestrator gates <step>` to a step `.md` is a
cross-gate change covering all companions in that step. `step2-compilation.md` covers both
`build-vet` and `version-consistency`. If the step `.md` update lands with the first
companion conversion PR, the second companion's MANDATORY block is still live. Result: the
orchestrator runs the second companion, marks it PENDING, then the subagent re-runs it via
MANDATORY — doubling execution. For `build-vet` across 3 modules on a dirty path: up to
30 extra minutes of `go build`/`go vet` per evaluation cycle.

**Required fix (plan text):** Add an explicit ordering rule: add `orchestrator gates <step>`
to the step `.md` in the LAST companion conversion PR for that step, not the first. This
ensures the cross-gate call lands only after all MANDATORY blocks in that step are removed.

---

## Refuted Findings

The following findings were raised and refuted with code evidence. Recorded here to prevent
re-raising in future audits.

| Finding | Refutation summary |
|---------|-------------------|
| "Crash FAIL masquerades as a real failure — the plan's justification is wrong" | FAIL report clearly says "Companion script crashed (exit N)" in SUMMARY — identifiable as infra, not a real finding |
| "Weak court (0/15 jurors call tools) introduces directional bias into false-FAIL metric" | Plan fixes the primary source of court false-FAILs (base-branch diff stripping) before measuring; directional bias from tool-use absence is secondary and already documented |
| "Phase 3 targets satisficing-mode gates despite principle 7 stating evidence-in closes only hallucination" | Plan explicitly acknowledges evidence-in closes hallucination not satisficing; providing deterministic counts/field-lists still closes the hallucination sub-class even if satisficing dominates |
| "crd-validation.sh:39 unguarded diff crashes under lib's set -e when sourced for Phase 2" | Plan already documents this exact hazard (Phase 2 step 1) and prescribes the `\|\| true` guard on the diff — the finding describes what the plan already says to fix |
| "Phase-4(a) killed-tool fixture has no implementation path and cannot reuse .repos scaffolding" | Plan correctly defers fixture implementation details to Phase 4 where they belong; "reuse the .repos scaffolding; a new target" is adequate direction for a deferred phase |
| "Corpus fixture test 'zero false-FAIL AND zero false-PASS' is vacuous for build-vet false-PASS detection" | False: the corpus contains repos with known pre-existing breakage; a known-bad-input that produces PASS is detectable — the corpus-run does test the false-PASS class |
| "Production backstop success criterion is vacuously satisfiable — never gates a phase" | By design: "explicitly, visibly deferred" is the correct and intended outcome; the criterion was written to prevent silent absence, not to mandate the backstop before Phase 5 |

---

## Pre-Implementation Checklist

Before starting any phase implementation, verify:

- [ ] **F1 (must precede Phase 1):** `record()` in `test-skill.sh` persists court verdict
  before `rm -f`; `results.tsv` has a court-verdict column; a committed baseline file exists.
- [ ] **F2:** Risks table documents the Phase 0→Phase 2 crash-semantics window; operator
  priority for Phase 2 is explicit.
- [ ] **F3:** Plan text corrects "already routes through orchestrator gates 4" claim; step-4
  fix loop update listed as mandatory (same as steps 1-3).
- [ ] **F4:** Phase 2 numbered sub-steps include the fix-loop update for step1/2/3/4.md as
  a numbered item, not only prose.
- [ ] **F5:** Phase 0(e) includes a concrete code snippet for dynamic
  `GATE_OUTER_TIMEOUT` computation.
- [ ] **F6:** Phase 1 section states a quantitative false-FAIL threshold for the go/no-go
  decision.
- [ ] **F7:** Phase 2 section states that `orchestrator gates <step>` addition to step `.md`
  lands in the LAST companion conversion PR, not the first.
