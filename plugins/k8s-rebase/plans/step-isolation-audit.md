# Audit: Step Isolation and Generality Plan

Independent audit of `step-isolation-and-generality.md`. Conducted by a
fresh session with zero prior context, using 18 parallel agents for
exploration and 10 for adversarial verification. Every quantitative
claim was checked against raw data in `results.tsv` (249 entries).

## Methodology

Phase 1 (exploration): 8 agents read the full codebase — skill
structure, all 33 gates, test results, upstream/downstream ovnk,
rebasebot, other test repos, and git history. No plan docs read.

Phase 2 (independent analysis): formed hypotheses about root causes
and fixes before reading the plan.

Phase 3 (verification): read all 3 plan docs, then launched 10 agents
to stress-test every major claim — step-skip counts, regression
attribution, spec=none vs spec=all statistics, stop hook feasibility,
step delegation architecture, gate flakiness, false positive rate,
PLUGIN_ROOT semantics, success criteria realism, Workflow viability,
and 10 gap categories.

---

## 1. CRITICAL: Factual Corrections

### 1a. "7x increase" is overstated (audit finding 2.2 superseded)

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
The previous audit's causal framing is misleading.

**Recommended action:** Remove the "7x" claim. Reframe as "the N=26
pattern emerged Aug 3 and intensified Aug 8-9, partially correlated
with commit 9e52ec68 but not caused by it."

### 1b. p-value is wrong

The plan says "p=0.43" for spec=none vs spec=all (ovnk). Fisher's
exact test on the actual contingency table (4/8 vs 23/27) gives
**p=0.53**. Same conclusion (not significant) but the number is
inaccurate. Fix the number.

### 1c. "No real difference" is ovnk-specific, not general

The plan says "spec=none vs spec=all: no real difference" as a
general finding (Section 2). This is **only true for ovnk**. Across
all repos combined:

| Spec | Pass rate | n |
|------|-----------|---|
| none | 45.6% | 57 |
| all | 69.8% | 192 |

Fisher's exact p=0.0015 — highly significant. Even time-controlled
(only runs through Aug 4, when both modes were active): 45.6% vs
65.8%, p=0.032.

Per-repo: CNO goes from 40% (none) to 90% (all). MCP: 40% to 91%.
ovnk is a massive outlier — the only repo where spec mode doesn't
dramatically improve pass rates. The plan incorrectly generalizes
from ovnk.

**Caveat:** Temporal confound — spec=none runs all end by Aug 4,
spec=all continues through Aug 10. Later runs benefit from
accumulated skill improvements.

**Recommended action:** Qualify as "For ovnk specifically, spec mode
shows no significant difference. For other repos, spec=all has a
24pp higher pass rate (p=0.0015)."

### 1d. CLAUDE_PLUGIN_ROOT IS a shell environment variable

The plan says "PLUGIN_ROOT not a shell env var" (risk table, line
359) and a previous audit said "CLAUDE_PLUGIN_ROOT is NOT a shell
environment variable (it is text-substitution in plugin-registered
files only)." **This is wrong.**

The official plugin-dev documentation explicitly states three scopes:
- In manifest JSON (hooks.json, MCP configs): text-substituted
- In component .md files (commands, agents, skills): text-substituted
- **In executed scripts (.sh files): available as environment variable**

Empirical proof: the metrics plugin's `start-collector.sh` uses
`CLAUDE_PLUGIN_ROOT` as a real shell env var, including
`if [[ -z "${CLAUDE_PLUGIN_ROOT}" ]]`.

All 50 runtime `find` calls are in .md files (38 in gates, 12 in
skills). Zero are in .sh scripts. Every one can be replaced with
`${CLAUDE_PLUGIN_ROOT}` via text-substitution.

**Recommended action:** Remove the risk from the risk table. Replace
all 50 `find "$HOME" -maxdepth 7` calls with `${CLAUDE_PLUGIN_ROOT}`
paths. This is a straightforward improvement independent of the
graduated ladder.

### 1e. "46 gate(s) failed" is actually 44

The plan says 46 "gate(s) failed" entries (52% of 89). Actual count
is 44. The plan counts 2 "court: FAIL" entries as gate failures,
which inflates the number. The total of 89 is correct (44 gate-failed
+ 35 missing + 6 stale-branch + 2 court-fail + 1 session-ended +
1 no-gates-ran = 89). Minor, but the "52%" figure should be "49%."

---

## 2. CRITICAL: Measurement Prerequisites

### 2a. Gate-name logging must precede Step 1b

The plan puts gate-name logging in "Not In Scope" (Section 9) and
describes it as a "3-line harness change." This should be a
prerequisite for Step 1b (companion scripts), not deferred.

Without gate-name logging:
- Cannot identify which specific gates are failing
- Cannot verify the 4 companion script targets are the right ones
- Cannot measure companion script effectiveness after deployment
- The "94% flaky" statistic is meaningful at the combo level but
  says nothing about individual gate flakiness

The 94% claim holds (verified: 15/16 version+repo combos with gate
failures also have at least one PASS), but it could reflect either:
(A) gates are genuinely non-deterministic, or (B) gates fail
consistently but the agent sometimes doesn't reach them.

**Recommended action:** Move gate-name logging from "Not In Scope"
to Step 0 (minutes of work, high diagnostic value).

### 2b. Step 0 (branch fix) unblocks all other measurement

The false positive rate is confirmed at 40.7%. The bimodal
distribution is unmistakable — genuine passes have <1,000 code hunks,
false positives have >6,600, with a 7.7x gap and zero overlap.

Per-version false positive rates:
- 1.34.1: 40% (4/10 passes are false)
- 1.35.3: 70% (7/10 passes are false)
- 1.36.2: 0% (from_commit close to current main)

Corrected ovnk pass rates: 1.34.1=33%, 1.35.3=12.5%, 1.36.2=35%.
True overall: ~26% (16/62), not the raw 40%.

The plan correctly identifies this and the fix ("default branch" →
"current branch") is sound. This must land first — every subsequent
measurement depends on accurate pass/fail classification.

---

## 3. HIGH: Verified Claims

### 3a. Step-skip root cause — fully verified

Every quantitative claim in Section 2 checks out exactly:
- 35 of 89 failures are "missing gates" — correct
- N=26 cluster: 11 entries, 100% spec=all — correct
- N=15 cluster: 7 entries, 3 none / 4 all, 6/7 ovnk — correct
- Residual 17 break into 11 near-complete + 3 mid-range + 3 startup
  crashes — correct, counts match exactly

Additional finding: the N=26 pattern affects 3 non-ovnk repos (CNO,
INFW, Multus), confirming the fix must be repo-agnostic. The plan's
Stop hook is repo-agnostic, so this is addressed.

### 3b. Stop hook design — technically sound

All technical claims verified:
- Production pattern exists (agentic-docs, 125-line stop-hook.sh)
- `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` is real (8-block default)
- `stop_hook_active` is a documented stdin JSON field
- Worktree awareness is critical and correctly identified
- hooks.json is auto-discovered (no plugin.json change needed)
- Anti-skip prose at lines 420/537/832 confirmed present and ignored

The "addresses 32 of 35 (91%)" arithmetic is correct, but
"addresses" means the hook fires, not that runs pass.

### 3c. Completion-to-pass conversion rate

Of 37 ovnk runs where all 33 gates executed, **27 passed and 10
failed** — a 73% completion-to-pass rate. This means:

- The Stop hook alone caps ovnk pass rate at ~73%
- The plan's "84%+ ceiling" **requires both Step 1 and Step 1b**
- The plan acknowledges this but the table structure makes it easy
  to miss

### 3d. Per-version failure structure

Versions have structurally different failures:
- **1.36.2**: 9 of 13 failures are step-skipping (N>=15). The Stop
  hook has maximum upside here.
- **1.35.3**: 7 of 14 failures are gate-flake (no missing gates).
  The Stop hook has minimal upside here. This is why 1.35.3 is "the
  blocker" — its problems are orthogonal to step-skipping.
- **1.34.1**: Mixed (4 step-skip, 2 gate-flake, 2 other).

The plan's "per-version floor 55%" criterion will be hardest to meet
for 1.35.3 because its failures are hook-unaddressable.

---

## 4. HIGH: Plan Gaps

### 4a. Multi-module repo handling unspecified

The plan has one line about multi-module repos (line 231: "use find
for go.mod"). ovnk has 3 modules with inter-module dependencies
(test/e2e depends on go-controller). The plan's step delegation
never specifies:
- Whether each step agent handles all 3 modules or one
- Module compilation ordering (go-controller before test/e2e)
- How gate agents handle per-module checks

The SKILL.md handles this (lines 295-300), but when refactored to
step files, this module-order awareness could be lost.

### 4b. GOMODCACHE / ENOSPC not addressed

Zero mentions of GOMODCACHE, ENOSPC, or disk space in the plan,
despite commit 0886cfd7 fixing a production ENOSPC failure. Step
delegation could multiply disk pressure (5 step agents each
downloading modules). Should be in the risk table.

### 4c. Recovery from partial step failures

The plan specifies gate counting after each step returns (line 333)
but doesn't address:
- What happens if a step agent crashes with uncommitted changes
- Whether step agents are idempotent (can Step 2 rerun safely?)
- How the INCOMPLETE marker is consumed on restart
- Resume logic for the ~100-line orchestrating SKILL.md

### 4d. Test harness mutate_plugin breaks with step files

The plan acknowledges this (line 337) but underestimates scope.
`mutate_plugin` uses `sed` patterns targeting SKILL.md `find` calls,
which move to step files. Additionally, the `all-patterns` spec
modifies `docs/k8s-rebase-patterns.md`, and step files using literal
paths would need injection per-file, not just in SKILL.md.

### 4e. Model coupling mitigation is observation-only

Rated Critical in the risk table but mitigated only by "Log exact
model ID per run" and "Continuous regression testing." Missing:
- No fast smoke test for detecting model changes
- No tested fallback model
- No model-version locking (Claude Code model aliases resolve to
  latest; no way to pin a checkpoint)
- No acknowledgment that Step 1 validation is model-version-specific

**Recommended additions:** (a) model ID column in results.tsv,
(b) `make smoke` target running 3 small repos for cheap regression
detection, (c) documentation that validation results are
model-version-specific.

---

## 5. MEDIUM: Statistical and Methodological Issues

### 5a. 20-run validation is wildly underpowered

With a baseline pass rate of ~26-35%, the plan's 20-run validation
can only reliably detect a +42pp improvement (to ~68-77%). It cannot
distinguish a 15pp improvement from noise at p<0.05.

The plan's "zero missing 15+ failures" criterion IS testable with
small samples (observing 0 in 15 runs where null rate is ~37% gives
p=0.0003). Rate-based criteria require 60+ runs per group.

**Recommended action:** Reframe success criteria as binary (zero
step-skipping failures in N runs) rather than rate-based, or
increase to 60+ runs for rate claims.

### 5b. Depth-3 nesting claim unverified

The plan says "Depth-2 nesting (main→step→gate) is within Claude
Code's default spawn depth limit of 3 (verified, shipped v2.1.172)"
(line 334). No documentation confirming this was found in any config,
help output, or settings file. The plan's "2-hour spike on CNCC"
would empirically test this, which is prudent, but the claim should
not be stated as "verified" without a citation.

### 5c. Structured returns have no schema enforcement

The Agent tool returns free-form text. The plan proposes step agents
return structured data (STEP_VERDICT, GATES_PASSED, etc.) but there
is no schema validation. The filesystem (gate report files) is the
reliable source of truth. The plan should explicitly prefer
filesystem-based gate counting over parsing agent text.

---

## 6. MEDIUM: Additional Findings

### 6a. maintainer-review.md has contradictory verdict instructions

Line 27 says "FAIL if scope creep or inaccurate commit messages" but
line 55 says "always use PASS." This ambiguity could itself be a
gate flakiness source. Fix the contradiction.

### 6b. Temporal clustering could invalidate validation runs

The plan lists "Test harness infrastructure reliability" as Not In
Scope (line 423), but the harness has no failure-rate backoff or
temporal clustering detection. If the API has a bad day during a
validation run, all results are recorded as genuine FAILs. A
`make matrix` run takes 4-8 hours — long enough for transient API
issues to contaminate results.

### 6c. Inter-step state is almost entirely filesystem-based

Verified: steps communicate through the branch (git), `.rebase-tmp/`
files, and arguments (version, repo path, flags). No in-memory state
flows between steps. This makes agent delegation architecturally
clean — the orchestrator only forwards ~5 pieces of information.

### 6d. Workflow is correctly rejected

The plan evolved from Workflow (commit 2bda263e) to Agent delegation
(commit 5b294f56). Verified: zero plugins in the repository use
Workflow in skills, availability in `--bg` sessions is uncertain,
and Agent delegation achieves the same benefits (fresh context,
deterministic gate counting) within the plugin paradigm.

---

## 7. LOW: Minor Items

### 7a. find timing

The previous audit said "4.1 seconds per call, ~200 seconds total."
Measured on this system: cold=2.6s, warm=0.87s, 50 calls warm=~44s.
This matches the original plan's "44 seconds." The previous audit's
figure was too high, but this is moot if PLUGIN_ROOT replaces all
find calls (see 1d).

### 7b. Autofix disposition

All 26 functions correctly categorized. ~9 are ovnk-specific, ~17
are ecosystem-generic. Every function is self-gating. The "keep all"
recommendation is sound.

### 7c. "Skipped" gates

"Skipped" is well-defined in the harness: SKIP verdict (gate not
applicable to this repo), INFO_GATES (informational, always PASS),
or stale FAIL (report predates latest commit). Not a gap.

---

## Summary Table

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1a | "7x increase" is 2-4.5x, pattern predates commit | CRITICAL | Fix attribution |
| 1b | p-value is 0.53, not 0.43 | CRITICAL | Fix number |
| 1c | "No real difference" only holds for ovnk | CRITICAL | Qualify scope |
| 1d | PLUGIN_ROOT IS a shell env var | CRITICAL | Remove risk; replace 50 find calls |
| 1e | "46 gate(s) failed" is actually 44 | CRITICAL | Fix count |
| 2a | Gate-name logging must precede Step 1b | CRITICAL | Move to Step 0 |
| 2b | Step 0 unblocks all measurement | CRITICAL | Confirm priority |
| 3a-d | Step-skip root cause, stop hook, conversion rate, per-version structure | HIGH | All verified |
| 4a | Multi-module handling unspecified | HIGH | Add to Step 2 spec |
| 4b | GOMODCACHE/ENOSPC not addressed | HIGH | Add to risk table |
| 4c | No resume logic for delegated steps | HIGH | Add to Step 2 spec |
| 4d | mutate_plugin breaks with step files | HIGH | Expand scope |
| 4e | Model coupling mitigation insufficient | HIGH | Add smoke test, model ID logging |
| 5a | 20-run validation underpowered | MEDIUM | Use binary criteria or 60+ runs |
| 5b | Depth-3 nesting unverified | MEDIUM | Remove "verified" or cite source |
| 5c | Structured returns have no schema | MEDIUM | Prefer filesystem gate counting |
| 6a | maintainer-review.md contradictory | MEDIUM | Fix the gate |
| 6b | Temporal clustering risks | MEDIUM | Consider detection/backoff |
| 6c | Inter-step state is filesystem-based | MEDIUM | Confirmed favorable for delegation |
| 6d | Workflow correctly rejected | MEDIUM | No action |
| 7a-c | find timing, autofix disposition, skipped gates | LOW | Informational |
