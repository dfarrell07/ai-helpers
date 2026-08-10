# Audit: Remaining Gaps in the Revised Plan

Post-revision audit. The implementing agent incorporated 27 of 33
findings from the original 61-agent audit. This document covers
only the items that were missed or partially addressed.

## 1. CRITICAL: Regression Diagnosis Missing (audit 2.2)

The plan contains no discussion of the Aug 8-9 regression or its
operational remediation. This was rated CRITICAL because the test
infrastructure is currently degraded — validation runs against the
revised plan will produce misleading results if the regression
factors are not addressed first.

**What happened:** Commit `9e52ec68` (Aug 8) bundled 7 changes. Two
independently contributed to a pass-rate crash:

1. **`model: opus` added to ovnk test configs.** Opus generates more
   verbose output, filling context faster. v1.36.2 went from ~33% to
   0% pass rate. v1.35.3 improved slightly (50% vs 41%), so opus is
   not uniformly harmful — it interacts with task difficulty.

2. **Gate-launch pattern changed** from "cat file contents into the
   subagent prompt" to "tell the subagent to Read the file by path."
   This requires the gate subagent to execute a Read tool call before
   it knows what to do. If it fails to execute the Read, zero gates
   run. Non-ovnk repos (no opus) showed the same "missing gates"
   pattern on Aug 8-9, implicating this change independently.

**Evidence this is multi-factor, not opus alone:**
- Non-ovnk repos (INF, multus) showed "missing gates" without opus
- v1.35.3 actually improved with opus (50% vs 41%)
- Pre-commit failures appeared on Aug 8 at 13:17 and 15:25 (3.5 and
  1.3 hours before the commit), though these were on the hardest
  versions where context exhaustion is expected even without opus

**Recommended actions (before PR-A validation begins):**
- Remove `model: opus` from all 3 test config files. Expected
  recovery: pre-opus overall was 48.8%, recent was 72.2%, so expect
  ~55-70% after removal.
- Evaluate the gate-launch pattern change (cat vs Read). If non-ovnk
  repos still show elevated "missing gates" after removing opus,
  revert to the cat-inline pattern.
- These are config/code changes, not plan changes — but the plan
  should note them as prerequisites for valid PR-A measurement.

## 2. MEDIUM: Wall-Time Success Criterion Missing

The plan acknowledges wall-time as a risk (line 331: "+10-25 min,
7-17% overhead") but sets no pass/fail threshold in the success
criteria section.

**Why it matters:** Step delegation could theoretically achieve the
gate-completion targets while taking 8 hours per run (e.g., due to
subagent launch failures and retries). A wall-time guard prevents
declaring success on a system too slow for practical use.

**Recommended addition to PR-A success criteria:**
- Median ovnk run wall time under 4 hours
- 95th percentile under 6 hours

## 3. LOW: Find-Call Timing Not Stated

The old plan claimed "44 seconds across 56 calls." The revised plan
removed this incorrect claim but did not add the measured value
(4.1 seconds per call, ~200 seconds total for 50 calls). This is
informational only — the `find` pattern works and is being retained
for gates regardless.

## 4. LOW: fix_go_version Classification

The plan labels fix_go_version as "Redundant (after PR-B ports
GOVERSION)" which captures the temporal dependency. The audit
recommended labeling it "Not yet redundant" to be more precise.
This is a cosmetic naming difference with no implementation impact.

## 5. MEDIUM: Validation Sample Size

The plan uses "20+ runs per version" (line 264). The audit
recommended 30+ (10 per version x 3 versions). With 20 runs, the
95% confidence interval for an observed 80% rate is [56%, 94%] —
wide enough that a 60% true rate could produce 16/20 passes by
chance (p=0.06). 30 runs narrows this meaningfully.

The plan's 20+ is a significant improvement over the original 10+
and may be a practical compromise given run times of 2-4 hours each.

## Summary

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | Regression diagnosis + config fix | CRITICAL | Add prerequisite note to plan; remove opus and evaluate gate-launch before PR-A validation |
| 2 | Wall-time success criterion | MEDIUM | Add median <4h / p95 <6h to PR-A criteria |
| 3 | Find timing not stated | LOW | Informational; no action needed |
| 4 | fix_go_version label | LOW | Cosmetic; no action needed |
| 5 | Sample size 20 vs 30 | MEDIUM | Consider increasing to 30; acceptable at 20 |
