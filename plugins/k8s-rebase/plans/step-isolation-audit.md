# Audit: Step Isolation and Generality Plan

Design review by 20 Opus exploration agents + 20 Opus adversarial
agents. The adversarial pass corrected 6 findings and sharpened 4
others. Focused on ideas that impact quality, robustness, and
generality.

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

**This does NOT prove the autofix is harmful.** The temporal confound
is massive — 96% of spec=none runs ended by July 31, while spec=all
continued through August 10. The skill improved during this period.
CNCC shows 83% spec=none vs 70% spec=all (reversed). The data is
suggestive, not conclusive.

**But it demands investigation before expanding.** A proper A/B test
(same time period, same skill version, randomized assignment) would
settle it. Until then, the plan should not add more recipes. The
autofix's value may be reproducibility and review consistency (same
fix pattern every time) rather than pass rate.

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
in 15 outputs). Forcing tool use would significantly strengthen it.

**CI** (go build + go vet + go test + Prow) is the only zero-flake
quality signal. It is currently Not In Scope. Adding draft PR
creation earlier (with CI feedback) would close this gap.

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

The middle tier is the highest-value engineering opportunity. Gates
like `deprecated-calls` have a deterministic evidence phase (run
staticcheck, filter pre-existing) and an agentic interpretation
phase. Companion scripts should handle the evidence tier, reducing
cost and flakiness while preserving judgment where it matters.

---

## 5. Defense-in-Depth: Add Layers, Don't Remove Them

The module safety rule currently exists in 33 gate files + SKILL.md.
The plan proposes adding rules.md + hook.

**Keep all three.** Gate subagents are at depth 2. Whether hooks
fire at depth 2 is unverified (the plan says so). If hooks don't
fire AND inline copies are removed, gates have NO enforcement at the
exact layer where it matters most. Inline copies provide direct
delivery to depth-2 subagents. rules.md provides comprehension. The
hook provides mechanical prevention. Three independent mechanisms
that fail independently — genuine defense-in-depth via mechanistic
diversity.

After depth-2 hook behavior is empirically verified, revisit whether
inline copies can be retired.

**The enforcement taxonomy needs a SCOPE dimension.** Hooks are
global, rules are skill-specific, gates are step-specific. The
plan's `.session-active` sentinel is a pragmatic workaround. A
principled framework: scope matches mechanism.

---

## 6. Signal Cleanup: Good Hygiene, Not a Design Principle

Renaming `RESULT: FAIL` to `RESULT: ITEMS_REMAINING` is good code
hygiene. The plan already proposes this (lines 227-228). The data
shows the FAIL signal is NOT the cause of step-skipping — the N=26
cluster occurs in spec=all where the autofix never runs. Renaming
the signal is a cleanup item, not an architectural fix.

---

## 7. What's Genuinely Missing

The adversarial review eliminated three previously-proposed ideas:

- ~~Historical priors (priors.json)~~ — this IS the autofix in JSON
  form. If encoding patterns as bash functions is potentially
  harmful (Section 2), encoding them as JSON won't be better. The
  agent already has `git log` for history.
- ~~Partial success scoring~~ — contradicts the Goodhart analysis.
  Binary PASS/FAIL is ungameable. The existing gate-count breakdown
  per step already captures trajectory. A composite score would
  create a satisficing target for humans.
- ~~Fix rollback (git revert HEAD)~~ — creates vendor inconsistency,
  wastes one of 3 allowed iterations, and restarts the oscillation
  cycle. The plan's oscillation detection (stop on regression) is
  already the correct response.

What IS genuinely missing:

**Decision provenance** (MEDIUM): Record WHY each fix was chosen,
not just WHAT changed. A `decisions` array in the rebase report
helps both the court and human reviewers.

**Blocked dependency detection** (MEDIUM): Check if upstream
dependencies (library-go, openshift/api) have been rebased before
starting. A failed upstream produces unsolvable compilation errors
that waste an entire run.

**Forced juror tool use** (MEDIUM): Add "REQUIRE: cite at least one
file:line from `git show` or `Read`" to the juror prompt. This is
~5 lines of prompt change that strengthens the court's most
underutilized feature.

---

## 8. Architecture Is Sound, Framing Needs Revision

The plan's components (orchestrator, boot loader, step files,
companion scripts, enforcement hooks) are all feasible and well-
motivated. The design principles are correct. The directory layout
is clear.

What needs revision:

- **"Structurally impossible"** → "defense in depth that eliminates
  the dominant failure mode." The improvement is attentional
  isolation, not information-theoretic isolation.
- **"65-75% subagent reduction"** → reframe around reliability.
  The net gate subagent count doesn't change (fixing step-skipping
  adds back the gates companion scripts eliminate). The real value
  is zero-flake deterministic evidence.
- **The autofix should be investigated, not expanded.** The p=0.002
  signal needs a controlled experiment before building on it.

---

## Summary: What to Do

| Priority | Action | Rationale |
|----------|--------|-----------|
| 1 | Investigate autofix impact | p=0.002 signal. Zero code — just a controlled A/B test. Determines whether Step 3 should exist in current form. |
| 2 | Companion scripts (4 .sh files) | Addresses gate flakiness for deterministic gates. Works within current architecture. No dependencies. |
| 3 | Boot loader + step files | Addresses step-skipping via attentional isolation. Fresh context per step. |
| 4 | Orchestrator | Foundation for deterministic advancement, resume, observability. Validates the architecture. |
| 5 | Stop hook + enforcement hooks | Mechanical enforcement. Belt to the orchestrator's suspenders. |
| 6 | Strengthen the court | Force juror tool use. ~5 lines of prompt change. Independent of everything else. |

This order respects dependencies: investigate before building on
assumptions, ship independent components before dependent ones,
measure after each phase.

### Corrections from adversarial review

The 20 adversarial agents corrected 6 findings from the exploration
pass:
- **Section 1**: Pipeline IS domain modeling, not just behavioral
  enforcement. "Shed complexity" → "migrate to deterministic"
- **Section 5**: Inline copies provide depth-2 enforcement that
  hooks may not. Keep them, add rules.md + hook on top
- **Section 7 (dropped)**: Neither gates nor court should be
  elevated as "the real quality gate." Revised to Section 3.
- **Section 10**: priors.json, partial scoring, and fix rollback
  all dropped — each contradicts the audit's own analysis
- **Section 8/9 (merged)**: Signal rename and three laws demoted
  to cleanup items and heuristics respectively
- **Summary**: Autofix investigation promoted from #5 to #1.
  Dependencies respected in ordering.
