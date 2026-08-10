# Audit: Step Isolation and Generality Plan

Adversarial fact-check of `step-isolation-and-generality.md`. Phase 1
used 8 agents to explore the full codebase before reading any plan
docs. Phase 2 read all 3 plan documents. Phase 3 launched 10 agents
to verify every major claim. Phase 4 launched 20 devil's-advocate
agents to challenge the audit's own findings, producing 7 corrections
(retracted 1d, downgraded 4 severity ratings, corrected the 73%
ceiling, and qualified the methodology claim).

All quantitative claims were checked against raw data in `results.tsv`
(249 entries). Every number was cross-verified by an independent
agent (zero discrepancies found).

**Caveat:** Phase 1 agents read git commit messages that summarize the
plan's conclusions (e.g., "root cause is step-skipping, not
compaction"). The numerical verification in Phases 3-4 is objective
and unaffected, but the root-cause analysis was anchored by these
signals.

---

## 1. Factual Corrections

### 1a. CRITICAL: "7x increase" is overstated

The plan's previous audit claimed commit `9e52ec68` caused a 7x
increase in "missing 26+" failures. Verified against results.tsv:

| Metric | Pre-commit | Post-commit | Multiplier |
|--------|-----------|-------------|------------|
| N>=26 raw count | 4 | 8 | 2.0x |
| N>=26 rate per run | 9.3% | 42.1% | 4.5x |

**Actual multiplier is 2x (raw) or 4.5x (rate), not 7x.**

More importantly, the N=26 pattern **predates the commit by 5 days**.
First occurrence: Aug 3 08:11 UTC (row 116). Two N=26 failures
occurred on Aug 8 itself, 3.5h and 1.3h before the commit. The
commit may have worsened an existing trend but did not introduce it.

**Recommended action:** Reframe as "the N=26 pattern emerged Aug 3
and intensified Aug 8-9, partially correlated with commit 9e52ec68
but not caused by it."

### 1b. HIGH: p-value is wrong

The plan says "p=0.43" for spec=none vs spec=all (ovnk). Fisher's
exact test on the actual contingency table (4/8 vs 23/27) gives
**p=0.53**. Same conclusion (not significant) but the number is
inaccurate.

### 1c. CRITICAL: "No real difference" is ovnk-specific, not general

The plan says "spec=none vs spec=all: no real difference" as a
general finding (Section 2). This is **only true for ovnk**. Across
all repos combined:

| Spec | Pass rate | n |
|------|-----------|---|
| none | 45.6% | 57 |
| all | 69.8% | 192 |

Fisher's exact p=0.0015. Even time-controlled (only runs through
Aug 4, when both modes were active): 45.6% vs 65.8%, p=0.032.
Controlling for skill version (original skill only): 45.6% vs
72.0%, p<0.01. The advantage is real, not a temporal artifact —
but the exact magnitude (15-30pp) has wide uncertainty due to
uneven sample sizes and repo distribution.

Per-repo: CNO goes from 40% (none) to 90% (all). MCP: 40% to 91%.
ovnk is the only repo where spec mode doesn't dramatically improve
pass rates.

**Recommended action:** Qualify as "For ovnk specifically, spec mode
shows no significant difference (p=0.53). For other repos, spec=all
has a significant advantage (p=0.0015)."

### 1d. LOW: "46 gate(s) failed" is actually 44

The plan counts 2 "court: FAIL" entries as gate failures. Actual
gate-failure entries: 44. The total of 89 is correct (44 + 35 + 6 +
2 + 1 + 1). Minor; the "52%" figure should be "49%."

---

## 2. Measurement Prerequisites

### 2a. CRITICAL: Step 0 (branch fix) unblocks all measurement

The false positive rate for ovn-org/ovn-kubernetes is confirmed at
40.7% (11/27 passes). The bimodal distribution is unmistakable —
genuine passes have <1,000 code hunks, false positives have >6,600,
with a 7.7x gap and zero overlap. The high-hunk values match the
master-to-known-good divergence to within 5%, confirming the agent
switched starting points.

Per-version false positive rates:
- 1.34.1: 40% (4/10 passes are false)
- 1.35.3: 70% (7/10 passes are false)
- 1.36.2: 0% (from_commit close to current main)

Corrected ovnk pass rates: 1.34.1=33%, 1.35.3=12.5%, 1.36.2=35%.
True overall: ~26% (16/62).

**Framing note:** The 40.7% figure is ovnk-specific. Cross-repo
false positive rate is 7.0% (11/157). Every suspect result comes
from one repo. The high-hunk results passed all 33 gates — calling
them "false positives" assumes gate insufficiency for detecting
wrong starting points.

The plan correctly identifies this and the fix ("default branch" →
"current branch") is sound. This must land first.

**Step 0 should have been implemented already.** It takes minutes,
unblocks all measurement, and days of planning have occurred
without it.

### 2b. HIGH: Steps 1 and 1b should co-deploy

The plan labels Step 1 (stop hook) and Step 1b (companion scripts)
as "parallel" but describes a sequential validation ("measure the
balloon squeeze before investing"). These should ship as a single
unit for two reasons:

**Goodhart risk:** The stop hook forces continuation but
`write-gate-report.sh` validates almost nothing (verdict is
PASS/FAIL/SKIP, no content check). The agent can satisfy the hook
by writing plausible PASS reports without doing real work. Only 7/33
gates would have companion scripts with deterministic evidence.
Satisficing (run easy greps, skip deep analysis, write plausible
reports) is the dominant rational strategy for a forced agent.

**1.35.3 needs 1b more than 1:** 1.35.3 has a corrected pass rate
of 12.5% and is gate-flake-dominated (7 of 14 failures). The stop
hook addresses at most 4 of 14 failures. The plan's "per-version
floor 55%" is mathematically unreachable for 1.35.3 without Step 1b.

---

## 3. Verified Claims

### 3a. Step-skip root cause — fully verified

Every quantitative claim in Section 2 checks out exactly:
- 35 of 89 failures are "missing gates" — correct
- N=26 cluster: 11 entries, 100% spec=all — correct
- N=15 cluster: 7 entries, 3 none / 4 all, 6/7 ovnk — correct
- Residual 17 break into 11 near-complete + 3 mid-range + 3 startup
  crashes — correct, counts match exactly

Additional findings:
- The N=26 pattern affects 3 non-ovnk repos, confirming the fix
  must be repo-agnostic. The Stop hook is repo-agnostic.
- The N=26 correlation with spec=all is real but confounded.
  spec=all simultaneously disables the autofix (FAIL signal) AND
  removes productive tools (neutered functions + empty patterns doc).
  In spec=none, autofix can also output FAIL but max missing is
  only 15. The discriminating factor is **absence of tools**, not
  the FAIL keyword. The plan correctly ranks signal cleanup as
  "cosmetic, lowest impact."

### 3b. Stop hook design — technically sound

All technical claims verified:
- Production pattern exists (agentic-docs, 125-line stop-hook.sh)
- `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` is real (8-block default)
- `stop_hook_active` is a documented stdin JSON field
- Worktree awareness is critical and correctly identified
- hooks.json is auto-discovered (no plugin.json change needed)
- Anti-skip prose at lines 420/537/832 confirmed present and ignored

### 3c. Completion-to-pass rate — complex picture

Of 37 ovnk runs where all 33 gates executed, 27 passed and 10 failed
— a raw 73% completion-to-pass rate. However, this metric has two
confounds that pull in opposite directions:

**False-positive correction (pulls DOWN):** 11 of the 27 "passes"
are false positives (>6,600 code hunks). After correction: 16/26 =
**62%** true C2P rate. This is the rate the plan should use for
pessimistic projections.

**Temporal improvement (pulls UP):** The C2P rate nearly doubled from
early to late runs (50% first third → 75% middle → 92% last third).
At recent rates, the post-hook ceiling could be 76-80%.

**Arithmetic note:** Even at 73% C2P, the overall pass rate is only
69.4% (not 73%) because infrastructure and gate-fail runs are
unchanged by the hook.

**Bottom line:** The true ceiling is somewhere between 62% (false-
positive-corrected) and 92% (recent-period), depending on which
effects dominate post-Step-0. The plan's "84%+ ceiling" requires
companion scripts (Step 1b) regardless of which C2P estimate is
used.

### 3d. Per-version failure structure — verified with nuance

- **1.36.2**: 9/13 failures are step-skipping. Stop hook has maximum
  upside. 35% true pass rate, zero false positives.
- **1.35.3**: 7/14 failures are gate-flake. Stop hook has minimal
  upside. 12.5% true pass rate. **This is the blocker.**
- **1.34.1**: Mixed. 33% true pass rate.

The plan correctly identifies 1.35.3 as the blocker. The plan's
"per-version floor 55%" will be hardest for 1.35.3 because its
failures are hook-unaddressable.

---

## 4. Plan Gaps

### 4a. HIGH: Test harness mutate_plugin breaks with step files

The plan acknowledges this (line 337) but underestimates scope.
`mutate_plugin`'s sed patterns target SKILL.md find calls, which
move to step files. The `all-patterns` spec modifies the patterns
doc, and step files using literal paths would need injection per-
file, not just in SKILL.md.

### 4b. HIGH: Goodhart mitigation insufficient

The plan correctly identifies the risk but 4 companion scripts cover
only 7/33 gates (21%). The highest-consequence correctness gate
(`logical-consistency`) is unscripted and trivially satisfiable with
plausible prose. `deprecated-calls` (runs staticcheck) and
`correctness` (format string grep) are already described as shell
commands in their gate .md files and should be scripted too.

### 4c. MEDIUM: PLUGIN_ROOT and find calls

`CLAUDE_PLUGIN_ROOT` is text-substituted in plugin-loaded .md files
(SKILL.md, commands) but is **NOT available as a shell environment
variable in Bash tool calls** (empirically verified: returns
NOT_SET). Gate .md files are read by subagents via the Read tool,
not plugin-loaded, so their bash code blocks cannot use PLUGIN_ROOT.

The plan's "Gates keep find, Steps get literal paths" is correct.
The 12 SKILL.md find calls can use `${CLAUDE_PLUGIN_ROOT}` via
text-substitution. The 38 gate find calls must keep the dual-path
find pattern (which currently works at marketplace install depth
due to the `"$HOME/.claude" "$HOME"` search).

### 4d. MEDIUM: Recovery from partial step failures

Zero mid-step crashes in 249 runs. The INCOMPLETE marker (written
after 3 stop-hook blocks) provides sufficient data for manual
resume. Automated resume logic is premature — it adds complexity
for a scenario with no observed occurrences. The SKILL.md's
existing recovery instruction (lines 90-93) is adequate.

### 4e. MEDIUM: Model coupling

No evidence of model-related step-function degradation in the data.
Daily pass rates improved over time. The N=26 pattern is
intermittent (retries succeed hours later). Claude Code supports
model pinning via full version names. The matrix testing already
serves as the regression detector. Recommend: add model ID column
to results.tsv for forensics.

---

## 5. Statistical Issues

### 5a. MEDIUM: Validation sample size

The audit's original "wildly underpowered" assessment was too harsh
and used the wrong test. The correct test is one-sample binomial
against the known baseline (~26%), giving a minimum detectable
effect of +31pp at n=20 (not +42pp as originally claimed).

More importantly, the plan's binary criterion ("zero missing 15+
failures") is extremely well-powered at n=15 (p=0.001 under null).
The rate-based criteria ("per-version floor 55%," "gate-failed
drops >=15pp") cannot be validated at n=20.

**Recommended action:** Restructure Section 7 into two tiers:
(A) binary criteria (hard pass/fail, testable at n=15-20) and
(B) directional rate indicators (informative but not rigorous).
Add sequential monitoring: run 15, if zero missing-15+ then accept,
if >=5 investigate, if 1-4 run 15 more. 60+ runs is impractical
($1,000-3,600 and 8 calendar days).

### 5b. MEDIUM: Depth-3 nesting unverified

No documentation found. The "2-hour spike on CNCC" (line 335)
would test this empirically.

### 5c. LOW: Structured returns have no schema

The filesystem (gate report files) is the reliable source of truth.
The plan should prefer filesystem-based gate counting.

---

## 6. Additional Findings

### 6a. MEDIUM: maintainer-review.md has contradictory instructions

Line 27 says "FAIL if scope creep" but line 55 says "always use
PASS." Could itself be a gate flakiness source.

### 6b. Confirmed: Inter-step state is filesystem-based

Steps communicate through git commits, `.rebase-tmp/` files, and
arguments. No in-memory state. Agent delegation is architecturally
clean.

### 6c. Confirmed: Workflow correctly rejected

Zero plugins use Workflow in skills, availability in `--bg` sessions
is uncertain. Agent delegation achieves the same benefits within
the plugin paradigm.

### 6d. Confirmed: Autofix disposition is sound

All 26 functions correctly categorized. ~9 are ovnk-specific, ~17
are ecosystem-generic. Every function is self-gating.

---

## 7. Audit Blind Spots (self-identified in Phase 4)

The 20 adversarial agents found these gaps in the audit itself:

- **Design Principles (Section 3) not evaluated.** The plan defines
  four principles that are supposed to govern implementation. This
  audit never tests whether the proposed steps embody them.
- **Estimated rates table (Section 7) not arithmetically verified.**
  The plan's baseline is 31% (16/51) vs the audit's 26% (16/62).
  These disagree and the audit didn't flag it. The "90% efficiency"
  optimistic bound is overstated given the C2P data.
- **"Not In Scope" items mostly unevaluated.** 8 of 9 exclusion
  decisions in Section 9 were not assessed (2-of-3 voting, multi-
  repo coordinator, gate consolidation, CI integration, etc.).
- **Multi-module and ENOSPC severity overstated** in the original
  audit. Multi-module ordering lives in bash scripts (not being
  refactored). ENOSPC was fixed in all 3 scripts with zero
  recurrence. Both downgraded to LOW/informational.

---

## Summary Table

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1a | "7x increase" is 2-4.5x, predates commit | CRITICAL | Fix attribution |
| 1c | "No real difference" only holds for ovnk | CRITICAL | Qualify scope |
| 2a | Step 0 unblocks all measurement (not done yet) | CRITICAL | Implement immediately |
| 2b | Steps 1 and 1b must co-deploy (Goodhart risk) | HIGH | Merge into single phase |
| 1b | p-value is 0.53, not 0.43 | HIGH | Fix number |
| 3a | Step-skip root cause fully verified | Verified | — |
| 3b | Stop hook design technically sound | Verified | — |
| 3c | C2P rate is 62-92% depending on correction | Verified | Use range, not point estimate |
| 3d | Per-version failure structure verified | Verified | 1.35.3 is the blocker |
| 4a | mutate_plugin breaks with step files | HIGH | Expand scope |
| 4b | Goodhart mitigation needs more companion scripts | HIGH | Add deprecated-calls, correctness |
| 4c | PLUGIN_ROOT: gates must keep find pattern | MEDIUM | Steps get literal paths |
| 4d | Recovery: INCOMPLETE marker is sufficient | MEDIUM | No automated resume needed |
| 4e | Model coupling: add model ID to results.tsv | MEDIUM | Observation is sufficient |
| 5a | Validation: use binary criteria + sequential monitoring | MEDIUM | Restructure Section 7 |
| 5b | Depth-3 nesting: test empirically (CNCC spike) | MEDIUM | Remove "verified" claim |
| 6a | maintainer-review.md contradictory | MEDIUM | Fix the gate |
| 1d | "46 gate(s) failed" is actually 44 | LOW | Fix count |
