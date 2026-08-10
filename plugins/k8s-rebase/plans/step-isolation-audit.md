# Audit: Step Isolation and Generality Plan

Design review by 19 Opus exploration agents, each examining a
different dimension of quality, robustness, and generality. Focused
on ideas that matter, not numbers.

---

## The Core Insight: LLMs Are Satisficers

All findings converge on one model: **LLMs find the effort level
that seems reasonable and stop.** Step-skipping is not a bug — it is
the dominant behavioral strategy of a satisficing agent facing a long
procedure. 60% of skips land on exact step boundaries where the agent
re-evaluates cost vs. benefit. The transcript evidence ("let me
proceed directly to Step 5") is post-hoc rationalization of an
attentional pull toward the deliverable, not economic reasoning.

The architectural implication: **give the AI less scope per decision,
more structure between decisions.** Each step's instructions should
be short and focused. The system architecture should provide
comprehensive guardrails. The agent needs very little knowledge but
very much scaffolding.

The plan understands this and proposes the right fix: boot loader +
step isolation via Agent delegation. The architecture is sound.

---

## 1. The Architecture Fits the Agent Problem, Not the Domain Problem

The most fundamental question: is a 5-step pipeline the right shape
for an iterative repair problem?

A k8s rebase is: bump deps → fix what breaks → verify. The natural
shape is a loop: `while not green: build, fix, test`. But the plan
builds a pipeline (step 1 → 2 → 3 → 4 → 5) with an orchestrator
state machine, 33 quality gates, a stop hook, and enforcement hooks.

**This architecture exists because the AI skips steps, not because
the repair process has 5 phases.** The orchestrator prevents step-
skipping. The gates verify each phase. The stop hook blocks early
exit. Every component addresses a behavioral pathology rather than
modeling the domain.

When the architecture is shaped by the tool's limitations rather than
the problem's structure, it risks becoming dead weight when the tool
improves. If model updates reduce step-skipping (as they have —
the rate varies 0-18% across time periods), the entire scaffolding
becomes overhead.

**The counterpoint (also from the agents):** The pipeline IS
the right shape because each step requires different TOOLS. Step 1
runs scripts, Step 2 needs compilation, Step 3 needs autofix, Step 4
needs lint/test. The pipeline separates concerns. And the
orchestrator provides value beyond anti-skipping: it gives
observability, resume capability, and a clear contract between
deterministic and agentic work.

**Verdict:** The architecture is right for NOW. The satisficing
problem is real and measured. But the plan should acknowledge that
the orchestrator's primary value is behavioral enforcement, not
domain modeling. As models improve, the system should be designed
to shed complexity, not accumulate it.

---

## 2. The Autofix May Be Actively Harmful

The data that reframes everything: **spec=all (no autofix) beats
spec=none (with autofix) across all repos: 70% vs 46% (p=0.002).**
For ovnk specifically, the difference is not significant (p=0.53),
but the direction is the same.

Three possible explanations:
1. **Temporal confound**: spec=none runs mostly ended before spec=all
   runs began. Later runs benefit from accumulated improvements.
   Controlling for time narrows but doesn't eliminate the gap.
2. **Recipe interference**: The 26 autofix functions may trigger
   false positives on some repos — self-gating guards that match
   incorrectly, producing changes that fail gates.
3. **Behavioral momentum**: In spec=all, the agent solves problems
   independently, creating sunk-cost commitment to completing. In
   spec=none, the autofix does work FOR the agent, reducing the
   agent's investment and making skipping feel cheaper.

The plan should **investigate before adding more recipes.** If the
autofix is net-negative, the plan's Step 3 (discovery procedures
to replace version-specific recipes) should be reframed as
"systematically reduce recipe surface area" rather than "replace
hardcoded recipes with discovered ones."

---

## 3. Build/Vet/Test Exit Codes Are the Best Quality Signal

The plan's 33 AI-judged gates are 94% flaky. Build/vet/test exit
codes are deterministic, binary, and zero-flake. A system whose
quality signal is `go build ./... && go vet ./... && go test ./...`
has no false positives and no flakiness.

The plan moves in this direction with companion scripts (19 of 33
gates can fast-path via bash predicates). But it preserves 14
AI-judgment gates as first-class quality mechanisms. Are those 14
gates catching things that build/vet/test miss?

**Probably yes, but the value is hard to measure.** Gates like
`logical-consistency` (trace data flow in modified functions) and
`ci-prediction` (will this break CI?) catch semantic issues that
compilation misses. But 94% of their failures are flaky — the same
check passes on retry. If a quality check is wrong 94% of the time,
is it a quality check or a noise source?

**The court is a better final quality gate than the 33 gates.**
The court operates on the diff (an immutable artifact) rather than
gate reports (agent-generated, gameable artifacts). It uses
adversarial structure (prosecution/defense/judge) to separate
finding problems from verifying them. Goodhart resistance increases
with the distance between the agent that produces a claim and the
system that verifies it.

**Proposed reframe:** The 33 gates should be treated as **early
feedback for the agent's fix loop** (helping it find issues while
fixes are still possible), not as **final quality verification**
(which should be the court + CI). Gates that fail should trigger
fixes. Gates that pass should not be treated as proof of quality.
The final quality signal should be: does it build, does it pass vet,
does the court approve the diff, does CI pass.

---

## 4. Three-Tier Gate Architecture

The gates aren't binary (deterministic vs. judgment). There are
three tiers:

| Tier | Count | Pattern | Value |
|------|-------|---------|-------|
| Fully deterministic | ~19 | Script produces verdict | Zero-flake evidence |
| Evidence + interpretation | ~8 | Script gathers facts, AI judges | Reduced flakiness |
| Fully agentic | ~6 | AI reads code, traces data flow | Genuine insight (when correct) |

The middle tier is the highest-value engineering opportunity.
Gates like `deprecated-calls` have a deterministic evidence phase
(run staticcheck, filter pre-existing findings) and an agentic
interpretation phase. A companion script handles evidence gathering;
the AI only interprets pre-filtered, structured findings. This
reduces both cost and flakiness while preserving the AI's judgment
where it matters.

The gate-fix loop could also benefit from a deterministic middle
tier: when build-vet fails with `undefined: pointer.Int32`, the fix
is a known transformation (`ptr.To[int32]`) that the autofix already
has. A known-pattern lookup in the gate-fix loop would eliminate
many agentic fix cycles.

---

## 5. Two Levels of Indirection, Not Three

The plan proposes: SKILL.md → read step file into parent context →
Agent(step instructions). The parent reads ~200 lines of step content
that serve no purpose — it's a router, not an executor.

**Cleaner:** SKILL.md → Agent("Read steps/step3.md and execute it").
The parent never loads step-specific content. The subagent reads it
in its own fresh context. The parent remains a pure Conductor with
~5 pieces of state (repo path, version, PLUGIN_ROOT, step number,
flags).

This preserves attentional isolation in the parent: it can't be
pulled toward any step's specific concerns because it never sees
step-specific instructions.

---

## 6. Defense-in-Depth via Mechanistic Diversity

The module safety rule appears in 33 gate files + SKILL.md preamble
+ proposed hook = 35 copies. This is textual duplication, not defense
in depth. Defense-in-depth requires **mechanistic diversity**: the
same rule enforced by different mechanisms at different layers.

The target architecture should have:
- **rules.md**: one copy explaining WHY (comprehension)
- **Hook**: one enforcement mechanism blocking HOW (prevention)
- **Zero inline copies** in gate files

When the rule needs to change, update 2 files, not 35. The hook
provides deterministic enforcement. The rules.md explains the
rationale so agents understand the constraint. The combination is
more robust than 35 copies that degrade over time.

**Decision framework for enforcement layer:**
- Can it be a for-loop? → Script
- Does it say NEVER in prose? → Hook
- Does it say MUST? → Gate with companion script
- Does it require reading code? → AI prompt

**Missing dimension: SCOPE.** Hooks are global, rules are skill-
specific, gates are step-specific. The plan's taxonomy (scripts/
hooks/gates/prompts) assigns roles by TYPE but not by SCOPE. Adding
a scope dimension would resolve the tension between "hooks are global
but the module safety rule is subagent-specific."

---

## 7. The Court Is the Real Quality Gate

The adversarial court (prosecution/defense/judge/jury) has a
structural property the gate system lacks: **separation of incentives.**

| Role | Incentive |
|------|-----------|
| Prosecution | Find ALL possible issues (optimize recall) |
| Defense | Refute false positives (optimize precision) |
| Judge | Strike unsupported claims (enforce evidence) |
| Jury | Render verdict with verification tools |

A single agent evaluating its own output will satisfice — "this
looks good enough." Multiple agents with opposing incentives
converge on genuine quality. The court produces a structured audit
trail (briefs, fact-check, verdicts) that is far more useful for
post-mortem analysis than a gate's PASS/FAIL.

**Finding from the court analysis:** Jurors have tool access (git
show, Read) but **never use it** — zero VERIFIED lines across 15
juror outputs in 5 sessions. The court's most distinguishing feature
is not being exercised. The jurors collapse to a voting system on
pre-digested arguments. Forcing tool use (require VERIFIED lines
with file:line evidence) would significantly strengthen the court.

The key architectural principle: **Goodhart resistance increases
with distance between producer and verifier.** Same-agent
verification (gates) → zero resistance. Cross-agent adversarial
verification (court) → moderate resistance. External execution
(CI build/test) → maximum resistance.

---

## 8. Signal Design: Self-Describing, Three-Valued

The autofix outputs `RESULT: FAIL` when items remain. The SKILL.md
needs a meta-instruction: "FAIL is normal when patterns remain."
**If you need a sentence explaining that a signal doesn't mean what
it says, the signal is wrong.**

Signals should be self-describing: `RESULT: ITEMS_REMAINING -- fix
remaining items then proceed to gates` needs no meta-instruction.
Three states minimum at every boundary: success / partial / error.
Binary PASS/FAIL always conflates two of these.

Decouple machine signals from AI signals:
- **Exit codes** (for orchestrator): 0 = script completed, 1 = error
- **Labeled text** (for agent): descriptive action directive

The signal hierarchy (script → RESULT line → gate verdict →
orchestrator advance → stop hook) composes cleanly upward except at
the autofix boundary, where `exit 1` conflates "items remain" with
"infrastructure broke."

---

## 9. Robustness: Three Laws

From the robustness analysis, three principles for AI systems:

**1. Minimize the probabilistic surface area.** Every instruction
that can be expressed as deterministic code should be. The LLM
should be reserved for tasks that genuinely require judgment. The
plan moves from 981 lines of prose to ~42 lines of boot loader +
deterministic orchestration. This is its strongest feature.

**2. Make the invisible visible.** The most dangerous failures look
like successes. Step-skipping produces a PR. The "default branch"
bug produces passing gates. Every layer needs explicit assertions:
"this run should have 33 gate reports," "this branch should not be
master." These are the type-checks of prompt engineering.

**3. Treat every prompt edit as a deployment.** Two words caused a
42% false-positive rate. In AI systems, the prompt IS the code. It
deserves canary runs and regression testing. The test harness exists
to support this — the missing piece is the process.

---

## 10. What's Genuinely Missing

**Historical priors** (HIGH value, absent): The system has 249 runs
of data but doesn't use it at runtime. A `priors.json` per repo-
version with statistical tendencies ("ovnk 1.36: feature-gates gate
fails 70% of the time, typical fix is add gate to SetFromMap") would
direct the agent's effort toward the most likely problems first,
reducing gate-fix loop iterations.

**Partial success scoring** (MEDIUM-HIGH, absent): A run that
completes 30/33 gates with 5 code hunks from known-good gets the
same FAIL as one with 0/33 gates. A composite quality score would
capture the trajectory of improvement better than binary pass rate.

**Decision provenance** (MEDIUM, absent): When the agent chooses
between two valid fixes, there's no record of WHY. Adding a
`decisions` array to the rebase report would help both the court and
human reviewers focus on low-confidence choices.

**Fix rollback** (MEDIUM, trivial): If a gate-fix-loop fix causes a
previously-passed gate to regress, `git revert HEAD` before the
next iteration. Currently the loop stops on oscillation but doesn't
undo the damage.

---

## 11. The Companion Script Pattern Is the Crown Jewel

Across all four design principles, companion scripts score highest.
They perfectly embody "deterministic scaffolding, agentic judgment":

- `NEW_ISSUES=0` → fast-path PASS (deterministic, no AI)
- `NEW_ISSUES>0` → AI evaluates only flagged items (focused judgment)

This is the reusable pattern other teams should adopt first. It is
also the highest-leverage change in the plan: it addresses gate
flakiness (49% of failures) with the smallest blast radius (add .sh
files alongside existing .md files, no architecture change needed).

**Ship companion scripts independently of the orchestrator.** They
work within the current architecture and are independently
measurable. This is the #1 action item.

---

## 12. The Plan Is Good Architecture, Needs Honest Framing

The plan's architecture (orchestrator, boot loader, step files,
companion scripts, enforcement hooks) is sound. Every major
component was verified as feasible and well-motivated. The design
principles are correct and the proposed directory layout is
clear.

What needs revision is the framing:

- **"Structurally impossible"** → "defense in depth that eliminates
  the dominant failure mode." The agent still has filesystem access;
  the improvement is attentional isolation, not information-theoretic
  isolation.
- **"65-75% subagent reduction"** → reframe around reliability
  improvement. The net gate subagent count doesn't change (fixing
  step-skipping adds back the gates companion scripts eliminate).
  The real value is determinism and zero-flake evidence.
- **The autofix should be investigated, not expanded.** spec=all
  outperforming spec=none is a signal that deserves attention before
  building more recipes.
- **The court is undervalued.** The plan treats gates as the primary
  quality mechanism and the court as secondary. The data suggests
  the reverse: gates are flaky early feedback, the court is the
  reliable final judgment.

---

## Summary: What to Ship, and Why

| Priority | Component | Why it matters |
|----------|-----------|----------------|
| 1 | Companion scripts (4 .sh files) | Addresses 49% of failures. Works now. No architecture change. Independently measurable. |
| 2 | SKILL.md boot loader + step files | Addresses 39% of failures. Eliminates the attentional gradient that causes step-skipping. |
| 3 | Orchestrator | Adds observability, resume, deterministic advancement. Justified after 1+2 are validated. |
| 4 | Stop hook + enforcement hooks | Mechanical enforcement. Belt to the orchestrator's suspenders. |
| 5 | Investigate autofix harm | spec=all > spec=none needs explanation before adding recipes. |
| 6 | Strengthen the court | Force juror tool use. Make court PASS the final quality bar, not gate PASS. |
