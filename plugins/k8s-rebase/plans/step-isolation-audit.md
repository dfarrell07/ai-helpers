# Audit: Step Isolation and Generality Plan

Design review by 20 Opus exploration agents + 20 Opus adversarial
agents. The adversarial pass corrected 6 findings and sharpened 4
others. Final review confirmed the updated plan integrates the
audit's strongest findings. Focused on ideas that impact quality,
robustness, and generality.

---

## The Core Insight: LLMs Are Satisficers

Step-skipping is the dominant behavioral strategy of a satisficing
agent facing a long procedure. 60% of skips land on exact step
boundaries. The transcript evidence is post-hoc rationalization of
an attentional pull, not economic reasoning.

Architectural implication: **give the AI less scope per decision,
more structure between decisions.** The plan's boot loader + step
isolation via Agent delegation is the right fix.

---

## 1. The Pipeline Is Both Domain Model and Behavioral Fix

A k8s rebase genuinely has phases: compilation (go build), codegen
(make generate), and verification (go test) require different tools,
different error patterns, and different retry strategies. A flat
`while not green` loop would need to handle multi-module ordering,
codegen dependencies, and oscillation detection — at which point it
is a pipeline in disguise.

The pipeline also solves step-skipping. These two functions reinforce
rather than conflict: the agent skips at phase boundaries because
the phases are genuinely different cognitive tasks. Step isolation
gives each task a fresh context and focused scope.

**The orchestrator's value is permanent.** Deterministic enforcement
of step ordering is permanently valuable for the same reason TCP
checksums persist — the failure modes change shape but never fully
disappear. The system should migrate complexity from probabilistic
components (AI judgment) to deterministic ones (scripts, hooks,
orchestrator), not plan to shed deterministic infrastructure.

---

## 2. Investigate the Autofix Before Building on It

spec=all (no autofix) shows 70% vs spec=none's 46% across all repos
(p=0.002). For ovnk specifically, no significant difference (p=0.53).
Time-controlled: p=0.087 (the plan now notes this).

**This does NOT prove the autofix is harmful.** The temporal confound
is massive — 96% of spec=none runs ended by July 31, while spec=all
continued through August 10. The skill improved during this period.
CNCC shows 83% spec=none vs 70% spec=all (reversed). The data is
suggestive, not conclusive.

**But it demands investigation before expanding.** The plan now lists
an autofix A/B test in Not In Scope (line 407). Consider promoting
it to a pre-commit-1 action: companion scripts (commit 1) interact
with autofix output, so understanding autofix impact first would
inform whether companion script fast-paths need autofix-awareness.
That said, companion scripts work regardless of autofix disposition
— they evaluate the CODE state, not the autofix output. Shipping
commit 1 without the A/B test is acceptable if acknowledged as a
known risk.

---

## 3. Quality Signals: Gates for Prevention, Court for Review, CI for Truth

Neither the 33 gates nor the court should be elevated as "the real
quality gate." Each has structural limitations:

**Gates** catch issues when fixes are still possible (prevention).
But 94% of gate failures are flaky (same check passes on retry).
Companion scripts fix this for deterministic gates. The 14 judgment
gates remain inherently non-deterministic.

**The court** provides adversarial review on the diff. But it
requires a known-good reference (not universal), goes INCONCLUSIVE
on large diffs (ovnk), and passes 97% of runs in a system with 26%
true quality. Jurors never use their tool access (zero VERIFIED lines
in 15 outputs). The plan now acknowledges this (Section 6, lines
365-367) and proposes forcing tool use — a ~5-line prompt change.

**CI** (go build + go vet + go test + Prow) is the only zero-flake
quality signal. It is currently Not In Scope.

**The right architecture:** gates for iterative feedback (fix while
you can), companion scripts for deterministic evidence (zero-flake),
court as optional second opinion (when known-good exists), CI as
ground truth (when available).

---

## 4. Three-Tier Gate Architecture

| Tier | Count | Pattern |
|------|-------|---------|
| Fully deterministic | ~19 | Companion script produces verdict |
| Evidence + interpretation | ~8 | Script gathers, AI judges flagged items |
| Fully agentic | ~6 | AI reads code, traces data flow |

The plan now integrates this (Section 4.4, lines 284-294).

**Terminology note:** The plan says "8 informational gates" (line
286) but only 4 are explicitly always-PASS in the gate files. The
other 4 are fast-path SKIP gates (zero subagent cost when their
domain is empty). Clearer: "8 zero-cost gates (4 always-PASS + 4
fast-path SKIP)."

The middle tier (evidence + interpretation) is the highest-value
target for expanding companion scripts after the initial 4. Gates
like `deprecated-calls` (run staticcheck, filter pre-existing) and
`correctness` (format string grep) have deterministic evidence
phases that could be scripted.

---

## 5. Defense-in-Depth: Add Layers, Don't Remove Them

The plan correctly keeps inline rule copies in gate files (line
296-297) as defense-in-depth until depth-2 hook behavior is
empirically verified. This addresses the audit's strongest
adversarial finding: if hooks don't fire at depth 2 AND inline
copies are removed, gates have NO enforcement at the exact layer
where it matters most.

**block-module-ops.md is safe** because PreToolUse hooks see the
Bash tool's `tool_input` string (what the AI typed), not commands
inside subprocess scripts. All legitimate `go mod tidy` operations
flow through scripts invoked as `bash /path/to/script.sh`. The plan
should document this mechanism: "Safe because hooks see the
tool_input, not commands nested inside called scripts."

Enforcement hooks should check `.session-active` sentinel to avoid
interfering with non-rebase sessions (the plan specifies this for
the stop hook but not for block-module-ops and block-vendor-edit).

---

## 6. Signal Cleanup: Good Hygiene, Not Architecture

Renaming `RESULT: FAIL` to `RESULT: ITEMS_REMAINING` is good code
hygiene. The plan already proposes this (lines 231-234). The data
shows the FAIL signal is NOT the cause of step-skipping — the N=26
cluster occurs in spec=all where the autofix never runs.

---

## 7. What's Genuinely Missing

Three previously-proposed ideas were eliminated by adversarial
review (each contradicted the audit's own analysis):

- ~~Historical priors~~ — the autofix in JSON form; same dynamics
- ~~Partial success scoring~~ — creates a Goodhart/satisficing target
- ~~Fix rollback~~ — oscillation detection is already correct

The plan now lists two of the surviving ideas in Not In Scope
(lines 404-406): decision provenance and blocked dependency
detection. The third (forced juror tool use) is in Section 6
(lines 365-367). All three are correctly scoped as follow-ups.

---

## 8. Plan Review: Architecture Is Sound

The updated plan (commits `a1bf48a4` through `622f376d`) integrates
the audit's strongest findings:

| Audit finding | Plan response | Status |
|---|---|---|
| "Structurally impossible" overclaims | → "defense in depth" (line 91) | **Addressed** |
| Three-tier gate architecture | Integrated (lines 284-294) | **Addressed** |
| Companion script value is reliability | Reframed (line 251) | **Addressed** |
| Keep inline rule copies | Preserved (lines 296-297) | **Addressed** |
| Court juror tool use | Acknowledged + fix proposed (lines 365-367) | **Addressed** |
| Commit sequence needed | Added as Section 5 (lines 343-354) | **Addressed** |
| Temporal confound in spec data | p=0.087 noted (line 389) | **Addressed** |
| Autofix A/B test needed | Added to Not In Scope (line 407) | **Partially** |
| Decision provenance | Added to Not In Scope (line 404) | **Partially** |
| Blocked dependency detection | Added to Not In Scope (line 405-406) | **Partially** |

**5 minor refinements remaining:**

1. **"8 informational"** (line 286) → "8 zero-cost (4 always-PASS +
   4 fast-path SKIP)" to match what the gate files actually say.

2. **Onion percentages** (line 19) are correct under the balloon-
   squeeze model but will confuse readers who compute naively. Add
   "(balloon-squeeze adjusted)" annotation.

3. **block-module-ops.md safety** (lines 315-317) — document WHY
   it is safe: hooks see `bash /path/to/script.sh`, not the nested
   `go mod tidy` inside the script.

4. **Force-advance** (line 154) — add `force_reason: stale|FAIL`
   to the INCOMPLETE marker for forensics. The current design
   (force-advance on any block type) is correct; the adversarial
   review confirmed that distinguishing stale from FAIL in the
   counter would create unbounded retry.

5. **Enforcement hook sentinel** — block-module-ops.md and
   block-vendor-edit.md should check `.session-active` like the
   stop hook does, to avoid interfering with non-rebase sessions.

**The plan is ready to execute.** Ship commit 1 (companion scripts)
first — lowest risk, highest signal, zero architecture change.

---

## Summary: What to Do

| Priority | Action | Rationale |
|----------|--------|-----------|
| 1 | Companion scripts (4 .sh files) | Addresses gate flakiness. Zero architecture change. Ship now. |
| 2 | Boot loader + step files | Addresses step-skipping via attentional isolation. |
| 3 | Orchestrator | Deterministic advancement, resume, observability. |
| 4 | Stop hook + enforcement hooks | Mechanical enforcement. |
| 5 | Investigate autofix (A/B test) | p=0.002 signal needs controlled experiment. |
| 6 | Strengthen the court | Force juror tool use. ~5 lines. |

Note: the audit previously had autofix investigation at #1. This
was revised after the adversarial review showed companion scripts
work regardless of autofix disposition (they evaluate code state,
not autofix output) and can ship independently. The A/B test is
important but not blocking for commit 1.
