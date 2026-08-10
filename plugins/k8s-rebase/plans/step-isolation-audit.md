# Audit: Step Isolation + Version-Agnostic Generality Plan

## Verdict

The plan's core architecture is correct: step delegation with fresh 1M context per step eliminates the context-exhaustion failure mode that causes 66% of ovnk failures. Ship it. However, two critical errors will break the implementation if not fixed first -- CLAUDE_PLUGIN_ROOT does not resolve in gate files (2.1), and the regression root cause is multi-factor, not opus alone (2.2). Beyond those, the plan needs a recovery protocol it never specifies (2.4), a reordered PR sequence that ships delegation before the PLUGIN_ROOT migration (4.3), and statistically valid success criteria replacing the current n=10 targets (5.x). Parts 3, 7, and 8 contain factual corrections that change specific numbers and classifications but do not alter the architectural direction. Total estimated effort for all corrections: 2-3 days.

## Quick Reference: All Actionable Items

| Ref | Severity | Description | Effort |
|-----|----------|-------------|--------|
| 2.1 | CRITICAL | CLAUDE_PLUGIN_ROOT breaks all 33 gates; pass literal paths via step prompt instead | 2h |
| 2.2 | CRITICAL | Regression is multi-factor (opus + gate-launch pattern + difficulty); remove opus, evaluate gate-launch revert | 1h |
| 2.3 | HIGH | Rewrite nesting instruction (line 159) -- current text prohibits the gate launches the architecture requires | 15min |
| 2.4 | HIGH | Add recovery protocol: retry logic, oscillation detection, dirty-tree check, Step 2 terminal-failure rule | 4h |
| 2.5 | HIGH | Pass $ARGUMENTS through step prompt template (Step 4d depends on --bump-tools) | 30min |
| 4.1 | HIGH | Add compaction safeguards: 4,500-token lint rule for orchestrator, shared-budget warning, CLAUDE.md fallback | 2h |
| 4.3 | HIGH | Reorder PRs: PR-0 (branch fix) then PR-A (delegation with find) then PR-B (PLUGIN_ROOT) then PR-C (discovery) | 30min |
| 5.x | HIGH | Replace success criteria: 30+ runs per cell, per-version floors, wall-time targets, per-PR definitions | 1h |
| 2.6 | MEDIUM | Change Step 4 gate-fix re-validation from --no-test to --quick (saves 36 min worst case) | 30min |
| 3.x | MEDIUM | Correct 10 factual errors in plan text (failure percentages, find counts, token offsets, function counts) | 1h |
| 4.2 | MEDIUM | Drop structured checkpoints; use git log + .rebase-tmp/deferred.txt instead | 1h |
| 6.1.2 | MEDIUM | Step subagent writes machine-readable status to .rebase-tmp/stepN-status.json, not free-text verdict | 1h |
| 6.1.3 | MEDIUM | Add pre-launch variable validation bash block before each Agent call | 1h |
| 7.x | MEDIUM | Fix autofix disposition table: 26 functions not 27, 12-14 ovnk-only not 19, 3 misclassifications | 1h |
| 8.x | MEDIUM | Fix discovery procedures: kubeadm uses indirect paths not vendor, feature gates need 2-3 files | 1h |
| 2.7 | LOW | Fix line 94 recovery instruction ("master" to "current branch") alongside PR-0 line 87 fix | 15min |
| 6.5 | LOW | Document rollback strategy for each PR (all independently revertible) | 30min |

## How to Use This Audit

- **Start with the two CRITICAL items (2.1, 2.2).** These will cause immediate breakage or misdiagnosis if not addressed before implementation begins.
- **Read Part 1 only to confirm you agree with the architectural direction** -- it validates the plan, so no action is needed from it. Skip the evidence details unless you need to defend a decision.
- **Part 2 is your primary work list.** Every item requires a concrete change to the plan or code. Part 6 supplements Part 2 with implementation-specific pitfalls (some overlap; cross-references are noted).
- **Parts 3, 7, and 8 are correction tables.** Scan them to update specific numbers and classifications in the plan text. None changes the architecture.
- **Part 4 contains three design-decision reversals (compaction safeguards, checkpoints, PR ordering).** Read the arguments; adopt or reject each explicitly.

## Methodology

This audit was produced by Claude Code using automated AI analysis.
All "agents" referenced are AI subagents, not human reviewers. 41
agents across 3 waves: Wave 1 (5) verified factual claims; Wave 2
(14) deep-dived weak points; Wave 3 (22) ran adversarial challenges
where each agent stress-tested a specific conclusion. One Wave 3
agent (compaction model) corrected an earlier agent's findings.
Findings should be validated before acting on critical items.

## Glossary

- **k8s-rebase skill:** Claude Code plugin that automates Kubernetes
  dependency version bumps in Go projects via a 5-step process.
- **ovnk:** OVN-Kubernetes (`ovn-org/ovn-kubernetes`), the largest
  and most complex target repo (482K LOC, 3 go.mod files).
- **Step (1-5):** Sequential phases: (1) dep bump + codegen, (2) fix
  compilation, (3) autofix patterns, (4) lint + test + verify,
  (5) generate PR command.
- **Gate:** A `.md` file under `gates/step{N}-*/` defining a quality
  check. A subagent reads it, runs the check, writes a `.report`
  with PASS/FAIL. There are 33 gates across Steps 1-4.
- **Step delegation:** The proposed architecture: Steps 2-4 each run
  in a separate subagent with fresh 1M context, preventing the
  context exhaustion that loses later-step instructions.
- **Compaction / 5K cap:** At ~83.5% context usage, Claude Code
  summarizes conversation and re-injects each skill with a hard
  5,000-token limit. Steps 3-5 start at ~5,147 tokens — just past
  the cap — so they are lost.
- **spec=all / spec=none:** Test modes. spec=all neuters all autofix
  functions and strips the patterns doc (blind mode). spec=none
  runs the full skill as-is (production mode).
- **CLAUDE_PLUGIN_ROOT:** A text-substitution token resolved by
  Claude Code only in plugin-registered files (SKILL.md, commands,
  hooks). NOT available as a shell environment variable.
- **CNO, CNCC, multus, INF, MCP:** The 5 smaller target repos
  (Cluster Network Operator, Cloud Network Config Controller,
  multus-cni, ingress-node-firewall, ovn-kubernetes-mcp).
- **False positive:** A test PASS where the agent started from the
  wrong git commit (master instead of the test branch), producing
  6,000+ code hunks vs known-good.

---

## Part 1: What the Plan Gets Right

The plan demonstrates strong analytical rigor: the token budget
analysis, failure mode classification, and architectural reasoning
all survived adversarial challenge from 22 agents. The core design
is well-conceived, not merely acceptable.

### 1.1 Core Diagnosis: Correct

Context exhaustion during Step 2's compilation fix loop is the primary
cause of ovnk failures. The agent consumes 250-350K tokens of build
output, error investigation, and fix iterations. After this, later step
instructions are lost and the agent stops before launching Steps 3-4's
26 gates.

Evidence: 66% of all ovnk failures (80% of recent failures) report
"missing N of 33 gates." The distribution peaks at N=26 (Steps 1+2
completed, Steps 3+4 never started) and N=15 (Steps 1-3 completed,
Step 4 never started).

### 1.2 Core Architecture: Correct

Step delegation with fresh 1M context per step eliminates context
exhaustion. Each step subagent operates independently with full headroom.
The token budget analysis (verified) shows comfortable margins:

| Step | Plan Estimate | Verified Estimate | Headroom |
|------|--------------|-------------------|----------|
| Main agent | ~80K (8%) | ~54K (5%) | 946K |
| Step 2 | ~338-388K (34-39%) | ~304-354K (30-35%) | 650K+ |
| Step 3 | ~293-343K (29-34%) | ~155-235K (16-24%) | 765K+ |
| Step 4 | ~499-549K (50-55%) | ~119-411K (12-41%) | 589K+ |
| Step 5 | ~60K (6%) | ~47K (5%) | 953K |

The plan's estimates are consistently pessimistic (conservative), which
is appropriate for a planning document. No line item is dangerously
underestimated.

### 1.3 Full 3-Step Delegation: Justified

An adversarial agent challenged whether only Step 2 needs delegation.
It found a realistic scenario where "Step 2 only" fails:

- The test data contains 6 "missing 15 of 33 gates" failures, proving
  Step 3 itself can consume enough context to prevent Step 4 from running.
- With Step 2 delegated but Steps 3-4 inline, the SKILL.md remains
  ~760 lines (not the plan's 350). Steps 3+4 combined can consume
  500-900K tokens for ovnk in worst case.
- "Step 2 only" trades ~15-25% residual failure rate for simpler
  engineering. The full plan achieves ~64% SKILL.md reduction (981 to
  350 lines).

The marginal cost of delegating Steps 3-4 is genuinely low: 2 step
files (~500 lines extracted from existing content) and 2 additional
Agent launches in the orchestrator. The infrastructure (recovery
protocol, prompt template, rules file) is identical regardless of
how many steps are delegated.

### 1.4 Other Confirmed-Correct Decisions

| Decision | Verification |
|----------|-------------|
| Steps 1 & 5 stay inline | Low context cost (~10K and ~47K). Delegating them adds overhead with negligible benefit. |
| Autofix stays monolithic | `GATE_DEPS` is an associative array that cannot be exported across `source` boundaries. `mutate_plugin` would need to search multiple files. |
| Nesting depth (main -> step -> gate = 3 levels) | Default limit is 3. Depth reaches 2, leaving 1 level of headroom. `claude -p` (antagonistic review) runs as a separate OS process outside the Agent nesting hierarchy. |
| Gate consolidation deferred | Only ~6.3K token savings (1.2% of 1M). Not worth the risk. |
| spec=none vs spec=all difference is noise | p~0.5 (Fisher's exact test, two-sided; N=12 vs 49). Low power at this sample size; temporal autocorrelation violates independence assumption. Directionally robust despite caveats. |
| Test harness mostly architecture-agnostic | Reads disk artifacts (gate reports, git branches, PIDs). Only change needed: remove 2-5 lines of dead `sed` code from `mutate_plugin`. |
| False positive fix ("current branch") is correct | Production-safe (script already works from any branch). Eliminates the SKILL.md/test-harness instruction conflict. |
| 4/6 discovery procedures feasible from vendored code | CRD int64, CRD name validation, feature gates (expanded to 2-3 files), RelaxedServiceNameValidation all work mechanically. |

---

## Part 2: Required Revisions

7 issues in 3 severity tiers. Read the one-line summaries to triage;
details follow each.

---

### CRITICAL -- must be addressed before implementation

#### 2.1 PLUGIN_ROOT does not resolve in gate files

**The plan proposes replacing 50 `find` calls with `${CLAUDE_PLUGIN_ROOT}`
in gate `.md` files. This will not work because PLUGIN_ROOT is only resolved
via text substitution in plugin-registered files, not in files read by the
Read tool.**

`CLAUDE_PLUGIN_ROOT` is a text substitution token that Claude Code
resolves only in plugin-registered files (SKILL.md, commands, hooks.json).
Gate `.md` files are arbitrary files read via the Read tool -- Claude Code
does NOT perform text substitution in them. When a gate subagent executes
a bash block containing `${CLAUDE_PLUGIN_ROOT}`, the shell resolves it
as an environment variable. It is not set in the shell environment
(verified empirically: `echo "$CLAUDE_PLUGIN_ROOT"` returns empty string).

The metrics plugin confirms this independently: its `start-collector.sh`
(line 40) defensively checks `if [[ -z "${CLAUDE_PLUGIN_ROOT}" ]]`,
proving the variable is not guaranteed to be available in shell contexts.

**Fix:** The step subagent should pass the literal resolved path in each
gate subagent's prompt. Gate files should reference the prompt-provided
path, not an environment variable. The orchestrator resolves
`${CLAUDE_PLUGIN_ROOT}` (via Claude Code text substitution in SKILL.md),
passes the literal string to the step subagent, which passes it to each
gate subagent. Alternatively, gate files can keep using the existing
`find` pattern (which works today) while SKILL.md and step files use
`${CLAUDE_PLUGIN_ROOT}`.

#### 2.2 Regression root cause is multi-factor, not solely `model: opus`

**The plan does not identify the Aug 8-9 regression cause. The audit
found it is multi-factor, not solely `model: opus`.**

Evidence against opus as sole cause:
- Non-ovnk repos (no opus) showed the same "missing gates" pattern
  (INF "missing 26" on Aug 9, multus "missing 15" on Aug 9)
- v1.35.3 actually improved with opus (50% vs 41% pre-opus)
- Pre-commit failures appeared 3.5 hours before the commit (Aug 8
  13:17 and 15:25 UTC, commit at 16:47), though these were on the
  hardest versions (v1.36.2 and v1.35.3) where context exhaustion
  is expected even without opus

The gate-launch pattern change in the same commit (from "cat file
contents into prompt" to "tell subagent to Read the file by path")
is an independent behavioral change. The subagent must now perform a
Read tool call before it knows what to do. If it fails to execute the
Read, zero gates run -- producing exactly the observed "missing gates"
pattern. This affects all repos, all models.

**Likely root cause:** Multi-factor interaction of task difficulty
(v1.36.2 >> v1.35.3 >> v1.34.1), gate-launch pattern change, model
choice (opus for ovnk only), and top-loaded constraint-heavy preamble.

**Recommendation:** Remove `model: opus` from configs (low risk).
Expected recovery: pre-opus overall rate was 48.8%, recent rate was
72.2%, so expect ~55-70% after removal. Also evaluate whether the
gate-launch change (cat vs Read) should be reverted or refined.

---

### HIGH -- architectural gaps that could cause step failures or silent misbehavior

#### 2.3 Anti-nesting instruction would prevent gate launches

**Line 159 of the step subagent prompt template says: "Do NOT launch
subagents that launch their own subagents."**

This was independently flagged by 4 agents across 2 waves. The entire
architecture requires step subagents to launch gate subagents. The
instruction is intended to prevent depth-3 nesting (gate subagents
should not spawn further agents) but is phrased so broadly that an AI
could interpret it as "do not launch subagents at all."

This is the same class of bug as Problem 2 in the plan (the agent
non-deterministically choosing between conflicting instructions).

**Fix:** Replace with: "Your subagents (gates, investigation helpers)
must NOT launch their own subagents -- nesting limit is 3 (main -> step
-> your subagent)." This explicitly permits gate launching while
constraining depth.

#### 2.4 Recovery protocol is mentioned but never specified

The plan mentions `STEP_VERDICT: COMPLETE|PARTIAL|FAILED` but never
specifies what the main agent does for non-COMPLETE outcomes.

**Proposed protocol (from Wave 2 agent, verified by Wave 3):**

```
MAX_ATTEMPTS = 2  # per step (initial + one retry)

for step in [2, 3, 4]:
    expected = set(gate_md_filenames_in("gates/step{N}-*/"))
    for attempt in 1..MAX_ATTEMPTS:
        passed_before = set(gate_names_with_pass_report(step))
        commits_before = git_rev_parse("HEAD")
        check: git status --porcelain (abort if dirty)

        skip_list = passed_before
        verdict = launch_step_subagent(step, skip_gates=skip_list)

        passed_after = set(gate_names_with_pass_report(step))
        made_progress = |passed_after| > |passed_before| or HEAD moved
        regression = passed_before - passed_after  # oscillation check

        if regression:
            log("Gate regression detected: " + regression)
            break
        if verdict == "COMPLETE" and passed_after == expected:
            break
        if step == 2 and verdict == "FAILED" and not made_progress:
            abort("Step 2 structural failure")
        if made_progress and attempt < MAX_ATTEMPTS:
            continue
        log_unresolved(step); break

run_mandatory_checkpoint()
```

Key design decisions:
- **Disk is the source of truth.** The verdict is advisory; the main
  agent always audits gate reports and git log.
- **Oscillation detection uses gate name sets, not counts.** A count
  increase (4 -> 5) can mask a regression if one previously-passed
  gate now fails.
- **Dirty-tree check before retry.** A crashed subagent may leave
  uncommitted changes.
- **Step 2 build-vet FAIL is terminal.** If code does not compile
  after 2 attempts with fresh 1M context, Steps 3-4 cannot run.
- **Disk-based iteration counters.** The step subagent cannot
  accurately count its own gate-fix iterations after compaction.
  Write iteration count to `.rebase-tmp/gates/{gate}.iterations`
  and check it before each cycle. This is the highest-severity
  real risk in the recovery protocol — without it, runaway loops
  can exhaust the step subagent's entire 1M context.

---

### MEDIUM -- incorrect details, easy fixes

#### 2.5 `$ARGUMENTS` not passed through step prompt template

The prompt template passes repo path, target version, plugin root,
and step file reference. It does NOT pass `$ARGUMENTS` (which includes
`--bump-tools`). Step 4d explicitly gates on `--bump-tools`. Without
passing it through, the flag is silently dropped.

#### 2.6 Step 4 re-validation uses `--no-test` instead of `--quick`

Plan line 315 claims "Steps 2 and 4 already do this [use `--quick` for
gate-fix re-validation]." This is wrong: Step 2 uses `--quick` (SKILL.md
line 409) but Step 4 uses `--no-test` (SKILL.md line 737). The
difference: `--no-test` adds lint + test-vet + CI parity checks (4
extra minutes per iteration). With 9 gate-fix iterations (worst case),
that is 36 minutes of unnecessary work.

**Fix:** Change Step 4's gate-fix re-validation to `--quick` (matching
Step 2), with a single final `--no-test` run after all gate-fix loops
complete.

#### 2.7 Recovery section also hardcodes `master` checkout

SKILL.md line 94 says: "To restart: `git checkout master && git branch
-D <branch>` and re-run." This reinforces the master-checkout pattern
that causes the false positive bug. The PR-0 fix (line 87 "default
branch" -> "current branch") should also update line 94.

---

## Part 3: Factual Corrections

| # | Claim in Plan | Verified Value | Impact | Correction |
|---|---------------|----------------|--------|------------|
| 1 | "81% missing 26 of 33 gates" | 66% all-time; 80% recent; "missing 26" is 26% | High -- overstates precision | "66-80% missing gates" |
| 2 | "56 find calls" | 50 calls (12 SKILL.md, 38 gates) | Low -- minor overcount | "50 find calls" |
| 3 | "44s across 56 calls" | 4.1s/call, ~200s total for 50 calls | High -- 10x overstatement | "~200s across 50 calls" |
| 4 | "Steps 3-5 start at ~8K tokens" | Step 3 starts at ~5,147 tokens | Medium -- mechanism correct | "Steps 3-5 start at ~5.1K tokens" |
| 5 | "19 of 27 ovnk-only functions" | 12-14 of 26 (double-count + misclassification) | Medium -- changes disposition | "12-14 of 26 ovnk-only functions" |
| 6 | "true pass rate ~20%" | 26.5% (13/49); trending 13% to 73% over time | Medium -- masks upward trend | "~27%, trending upward" |
| 7 | "fix_go_version is Redundant" | GOVERSION= not yet ported to Phase 3 | Medium -- temporal dependency | "Redundant after PR1 port completes" |
| 8 | "kubeadm from vendored code" | kubeadm NOT in vendor; 3 indirect paths work | Medium -- wrong mechanism | "kubeadm via indirect discovery" |
| 9 | "parse known_features.go" | Needs 2-3 files; some gates in kube_features.go | Medium -- under-scoped | "parse known_features + kube_features" |
| 10 | "55% of passes are false pos" | 42.3% overall; 52.9% for k8s 1.34-1.35; 0% 1.36 | Low -- directionally correct | "~42% false positives overall" |

---

## Part 4: Contested Design Decisions

### 4.1 The Compaction Model

The plan claims: "SKILL.md is truncated to its first ~5K tokens during
compaction." Three adversarial agents challenged this; a fourth agent
then identified the actual mechanism.

**The confirmed mechanism (from the compaction model agent):**
- Auto-compaction triggers at ~83.5% of context window (~835K of 1M)
- SKILL.md is NOT truncated in place -- it is **re-injected with a
  hard 5,000-token cap** per skill after compaction
- All skills share a combined 25K-token budget, filled most-recent-first
- Conversation history is summarized (not truncated or windowed)
- CLAUDE.md is preserved intact (reloaded from disk post-compaction)

**The plan's thesis is well-supported by behavioral evidence.** The
5K re-injection cap (inferred from failure distributions, not verified
against Claude Code source) falls
precisely at the Step 2/Step 3 junction (~5,147 tokens). Steps 1-2
instructions survive; Steps 3-5 are lost. This is a direct mechanical
explanation for "missing 26 of 33 gates."

**The multimodal distribution is explained by compaction timing:**
- "Missing 26" (11 occurrences): compaction fires before Step 3 starts
  (high context consumption in Step 2)
- "Missing 15" (7 occurrences): agent launches Step 3 gates BEFORE
  compaction triggers, then loses Step 4 instructions
- "Missing 28-32" (5 occurrences): compaction fires during Step 2;
  conversation history of launched gates is lost

**Critical correlation:** All 11 observed "missing 26" failures are
spec=all (autofix disabled). Zero of 12 spec=none runs produced
this failure mode. Without autofix, the agent
does 10-20 minutes of exploratory discovery in Step 2, consuming far
more context. This pushes compaction earlier, losing Steps 3-5 before
they can start. With autofix (spec=none), Step 2 finishes faster and
compaction tends to hit during Step 3 instead.

**Three new risks the plan should address:**
1. The orchestrator at ~4K tokens has only ~1K margin before the 5K
   cliff. A token-counting lint rule should fail above 4,500 tokens.
2. The 25K shared skill budget means other skills invoked in the same
   session could eat k8s-rebase's allocation on the next compaction.
3. CLAUDE.md survives compaction (reloaded from disk). Critical
   orchestration metadata could be duplicated there as defense-in-depth.

**Earlier Wave 3 challenges** (token offset agent, razor's edge
challenge) argued the compaction model was wrong based on the
robustness commit making the preamble shorter while pass rates dropped.
This apparent contradiction is explained by the multi-factor regression
(see 2.2): the pass rate drop was caused by `model: opus` and
gate-launch pattern changes, not by the compaction boundary moving.

### 4.2 Checkpoints vs No Checkpoints

The plan proposed 15-line checkpoints. Wave 2 proposed expanding to
40-60 lines. Wave 3 challenged the entire concept.

**The adversarial case for no checkpoints:**
- "Let the repo be the protocol." Each step can read `git log`,
  `git diff`, `go.mod`, and `.rebase-tmp/gates/*.report` to discover
  what previous steps did.
- Gate subagents already work this way -- they discover everything
  independently via repo inspection.
- Checkpoints are AI-generated summaries that add a fragile coupling
  point and a trust-in-AI-summaries dependency.
- If a checkpoint omits a replace directive, the next step has a
  blind spot. The repo itself never lies.

**The case for minimal checkpoints:**
- `git log` shows WHAT was committed but not WHY certain decisions
  were made (e.g., "deferred KubeVirt because no compile signal").
- Without a deferred-issues list, Step 3 may waste 10-20K tokens
  re-investigating items Step 2 deliberately skipped.
- Replace directives with TODO comments need explanation to prevent
  Step 3/4 gates from flagging them as scope creep.

**Recommendation:** No AI-generated checkpoint summaries. The step
subagent must not produce free-text prose describing what it did or
why -- such summaries are the fragile coupling point the adversarial
case correctly identifies. Instead, the protocol uses two categories
of ground-truth artifacts:

1. **Git state** (already exists, zero cost): each step prompt
   includes "Run `git log --oneline $(git merge-base HEAD master
   2>/dev/null || git merge-base HEAD main)..HEAD` to understand what
   previous steps did." This costs 20 tokens and produces verifiable
   history.
2. **Machine-written lists** (minimal, structured): the step subagent
   writes `.rebase-tmp/deferred.txt` (one issue per line, e.g.,
   `KubeVirt: no compile signal`) for items it deliberately skipped.
   This is a structured artifact like `go.mod` or a gate `.report`
   file -- not an AI narrative. Subsequent steps check it the same
   way gate subagents check repo state: by reading a file, not by
   trusting a summary.

### 4.3 PR Ordering

The plan orders: PR1 (PLUGIN_ROOT) -> PR2 (delegation) -> PR3
(discovery). The audit recommends reordering.

**Why delegation should ship first:**
- Step delegation is the high-impact architectural fix (addresses 66%
  of ovnk failures).
- PLUGIN_ROOT is a mechanical optimization that does not affect
  reliability.
- Step files can use the existing `find` pattern. Step 2 has only 2
  `find` calls; Step 3 has 3; Step 4 has 3. These are trivial to
  include in step files.
- PLUGIN_ROOT introduces a NEW risk (env var inheritance at depth 3)
  while `find` is battle-tested across thousands of gate runs.
- The branch fix (line 87) is 1 line and should ship independently.

**Recommended ordering:**
1. **PR-0** (2 min): Fix lines 87 and 94 ("default branch" -> "current
   branch"). Ship immediately.
2. **PR-A** (1-2 days): Full 3-step delegation using `find` patterns.
   Create `steps/` directory, rewrite SKILL.md to ~350 lines, add
   recovery protocol.
3. **PR-B** (0.5 day): PLUGIN_ROOT migration for SKILL.md and step
   files. Gates receive literal paths from step prompts (not env var).
4. **PR-C** (1-2 days): Discovery procedures + patterns doc cleanup.

---

## Part 5: Success Criteria Revision

The plan's current criteria are statistically inadequate.

### Problems with Current Criteria

**"10+ runs" is too few.** The 95% confidence interval for 8/10 is
[44%, 97%]. You cannot distinguish a 50% true rate from a 95% true
rate at any reasonable confidence level. The test data already shows
temporal autocorrelation (7-run failure streaks) that violates the
i.i.d. assumption.

**"~100% for non-ovnk repos" is undefined and wrong.** Actual recent
rates: MCP 90%, CNO 90%, multus 80%, INF 80%, CNCC 60%.

**"80% for ovnk" is the theoretical ceiling, not a comfortable target.**
After correcting for false positives, the genuine pass rate is 26.5%.
Step delegation fixes at most 18 of 27 failures. Best-case: ~82%.
Per-version ceilings: v1.36.2 ~85%, v1.34.1 ~80%, v1.35.3 ~72%
(v1.35.3 has a 22% structural gate quality failure rate that
delegation cannot fix). Realistic aggregate across versions: 65-75%.

### Recommended Criteria

**PR-0 (branch fix):**
- 10 ovnk runs in `--from-commit` mode across v1.34 and v1.35
- Every PASS must have fewer than 500 code hunks
- Verify starting commit SHA in logs matches `--from-commit` value

**PR-A (delegation):**
- spec=none (production): Zero "missing 15+ of 33 gates" failures
  in 30 runs (10 per version). This directly validates that
  delegation eliminates context exhaustion.
- spec=all (stress): "missing 26+ gates" rate drops from 24% to
  under 5%.
- Per-version floor: no version below 55% pass rate.
- Per non-ovnk repo: no repo drops more than 15pp from its
  pre-PR-A baseline.
- Wall time: median ovnk run under 4 hours, p95 under 6 hours.
- Runs spread across 5+ calendar days (mitigates autocorrelation).

**PR-B (PLUGIN_ROOT migration):**
- Zero regressions: within 5pp of PR-A's measured rate per version.
- Verify `${CLAUDE_PLUGIN_ROOT}` resolves correctly in SKILL.md and
  step files (not empty string).
- Verify gate subagents receive literal paths in their prompts.
- `find` call count in SKILL.md + step files drops to zero.

**PR-C (discovery):**
- Within 5pp of PR-A's measured rate per version (non-regression).
- At least 1 successful end-to-end run on a version with zero
  recipe coverage (validates version-agnosticism).

---

## Part 6: Implementation Risks

### 6.1 Top 3 Pitfalls (from Wave 3 implementation agent)

**Pitfall 1: Ambiguous nesting instruction.** Already covered in 2.3
above. The fix is a 1-sentence rewrite.

**Pitfall 2: Unstructured handoff for recovery decisions.** The
recovery protocol requires parsing `STEP_VERDICT` from the step
subagent's text response. AI text is unreliable (format variations,
narrative instead of structured output). Fix: the step subagent writes
a machine-readable status to `.rebase-tmp/step{N}-status.json` with
exact gate counts. The orchestrator reads this file, not the subagent's
text.

**Pitfall 3: No validation before expensive subagent launches.**
Variable resolution failures (`$REPO_ROOT` empty, `$PLUGIN_ROOT` wrong
path, `$VERSION` unparseable) waste 30-60 minutes per failed step.
Fix: add a pre-launch validation bash block that checks all variables
before the Agent call.

### 6.2 Git State Risks

Only 1 of 7 investigated git concerns is a real risk:

| Concern | Verdict |
|---------|---------|
| Uncommitted changes between steps | **Real risk.** Mandatory checkpoint does not check `git status`. Fix: add dirty-tree check before each step launch. |
| Branch state across subagent boundaries | Not a risk. All agents share the same working tree. |
| Git index.lock conflicts | Not a risk. Gate subagents are read-only; step writes are sequential. |
| Merge base drift | Theoretical only. Local refs do not move during a session. |
| Git user config inheritance | Not a risk. Same OS user, same `~/.gitconfig`. |
| Concurrent gate reads | Not a risk. Git handles concurrent reads safely. |
| Root-owned file detection | Not a risk. Cleanliness gate runs on host filesystem. |

### 6.3 Small Repo Regression Risk: Low

All 5 non-ovnk repos have low regression risk from step delegation:

| Repo | Recent Rate | Risk | Reason |
|------|-------------|------|--------|
| MCP | 90% | Low | Already uses 33 gates as subagents. Adding step layer is minimal surface. |
| CNO | 90% | Low | Failures are gate verdicts, not context. Delegation does not change gate logic. |
| multus | 80% | Low | Same pattern. |
| INF | 80% | Low | Same pattern. |
| CNCC | 60% | Low-moderate | Higher failure rate, but failures are genuine gate findings, not architectural. |

The two concrete risks: (1) `rules.md` must thoroughly replicate the
SKILL.md preamble (module safety, commit conventions, scope constraints).
(2) `$ARGUMENTS` must be passed through the step prompt template.

### 6.4 Wall Time Impact: Acceptable

Step delegation adds 10-25 minutes to a 2.5-hour process (7-17%):
- Subagent launch overhead: ~15-20 seconds per step (~1 minute total)
- Context warm-up per step transition: 1-3 minutes each (~6 minutes)
- Handoff discovery (reading `git log`, running validate): 2-5 minutes
  each (~9 minutes)

Go build cache is filesystem-based and shared across all agent depths.
The validate script already mounts host caches into containers. No
cold-start penalty.

The overhead pays for itself: expected total time across 10 runs
DECREASES from ~25 hours to ~19.5 hours because fewer runs are
completely wasted by context exhaustion.

### 6.5 Rollback Strategy (Missing from Plan)

**PR-0:** `git revert`. No dependencies.

**PR-A:** `git revert`. Orphaned `steps/` directory is harmless
(nothing references it without the orchestrator SKILL.md). The
`mutate_plugin` sed lines (if restored by revert) silently no-op
against PLUGIN_ROOT patterns (safe). Clear `results.tsv` to avoid
mixing architecture results.

**PR-B:** `git revert`. Step files revert to `find` patterns (which
work today). Gate files are unaffected (they receive literal paths
from step prompts, never used PLUGIN_ROOT directly).

**PR-C:** `git revert`, but TAG_TO_PATTERN heading renames and gate
renames MUST be in one squashable commit sequence. After reverting,
verify TAG_TO_PATTERN consistency before running tests.

All four PRs are independently revertible.

---

## Part 7: Autofix Function Disposition Corrections

The plan's disposition table has several misclassifications:

| Function | Plan Classification | Corrected | Reason |
|----------|-------------------|-----------|--------|
| fix_lint_version | Listed twice (Evergreen + One-time) | Single function, Evergreen (handles both bump and v1-to-v2) | Double-count error. Actual count is 26 functions, not 27. |
| fix_go_version | Redundant | Not yet redundant | GOVERSION= sed pattern not ported to k8s-rebase.sh Phase 3. Becomes redundant after PR-B ports it. |
| fix_docs_version | Redundant | Ovnk-specific | Only targets `docs/features/requirements.md` which exists only in ovnk. |
| fix_relaxed_svc_name | One-time done | Evergreen/version-adaptive | Has bidirectional version guard: adds gate for k8s < 36, removes for >= 36. |
| fix_fieldsv1 | Accelerator | Correctly classified | Has explicit version guard (k8s >= 36). The `FieldsV1.Raw` removal produces a clear compile error that the AI would find. |

Corrected counts: **12-14 functions are ovnk-only** (not 19).
The autofix is still primarily an ovnk accelerator, but the
universal-function ratio is higher than the plan states.

---

## Part 8: Discovery Procedure Corrections

| # | Procedure | Plan Claim | Verified Status |
|---|-----------|-----------|-----------------|
| 1 | Feature gates | "Parse known_features.go" | Needs 2-3 files: client-go known_features.go + kubernetes kube_features.go + dependency map. Single-file approach is insufficient. |
| 2 | kubeadm v1beta4 | "Check vendored kubeadm API version" | **Cannot work as described.** kubeadm is not vendored. 3 indirect paths work: (a) version correlation from go.mod, (b) file inspection of kind.yaml.j2, (c) extraArgs format detection. The current autofix function IS the correct solution -- it checks file content directly. |
| 3 | CRD int64 | "Check format: int32 + maximum" | Fully feasible. Mechanical grep + awk. |
| 4 | CRD name validation | "Diff metadata against base branch" | Fully feasible. Mechanical git diff. |
| 5 | ObservedGeneration | "Check status condition updates" | Partially feasible. Requires conformance test knowledge to know WHICH functions to check. Two-step grep (find assertions in tests, then find missing assignments in controllers) works but is fragile without domain context. |
| 6 | RelaxedServiceNameValidation | "Check if gate exists in vendored code" | Feasible, but the gate is in kube_features.go (not client-go). Should be unified with procedure #1 as a single multi-file feature gate discovery. |

---

## Part 9: Missing Items (PM Review)

Items the audit should cover but does not, or covers insufficiently.
Each item includes the specific text to add and its target location.

### 9.1 spec=all Correlation Buried

The finding that ALL "missing 26" failures are spec=all (zero are
spec=none) is one of the most actionable insights in the entire audit.
It directly explains WHY autofix-disabled runs fail: without autofix,
Step 2 does 10-20 minutes of exploratory discovery, consuming far more
context, pushing compaction earlier. Yet this finding is buried in
section 4.1 (paragraph 6 of a dense subsection about compaction
internals). It does not appear in Part 1 (Core Diagnosis), the
executive summary, or Part 5 (Success Criteria).

**Add to section 1.1 (Core Diagnosis), after the existing paragraph
ending "Steps 3+4 never started":**

> **Critical correlation:** Every "missing 26 of 33 gates" failure is a
> spec=all (autofix-disabled) run. Zero spec=none runs exhibit this
> pattern. Without autofix, Step 2 performs 10-20 minutes of exploratory
> discovery, consuming far more context and triggering compaction before
> Steps 3-5 can start. This means spec=all is the primary stress
> condition and should be over-represented in validation testing.

**Add to section 5 (PR-A success criteria), after "spec=all (stress)"
bullet:**

> spec=all runs are the sole source of "missing 26" failures. A
> drop from 24% to under 5% in this population directly validates
> that delegation eliminates the worst failure mode.

### 9.2 Expected Improvement from Removing opus Not Quantified

Section 2.2 says "Remove model: opus from configs (low risk, likely
partial improvement)" and appendix entry 3-10 says "expect ~55-70%,
not '~39% restored.'" But the main body never quantifies the expected
recovery or establishes a baseline comparison. The Day 0 revert agent
found: pre-opus baseline was 48.8% overall / 72.2% recent (last 7
days). Expected recovery from removing opus alone: ~55-70%. These
numbers are critical for calibrating expectations before PR-A ships.

**Add to section 2.2, after "Also evaluate whether the gate-launch
change (cat vs Read) should be reverted or refined.":**

> **Expected impact of removing opus:** Pre-opus pass rates were 48.8%
> overall and 72.2% over the most recent 7 days (the system was on an
> upward trajectory). The Day 0 revert agent estimates removing opus
> alone recovers ~55-70% of the pre-regression rate, not a full
> restoration to the ~72% recent peak. This calibration matters:
> removing opus is a quick win that partially restores reliability, but
> step delegation (PR-A) is still required to address the structural
> context exhaustion that causes the remaining ~30-45% of failures.

### 9.3 Disk-Based Iteration Counters: Highest-Severity Recovery Risk

The Wave 3 recovery agent (3-5) identified three real risks:
dirty-tree, oscillation via name sets, and disk-based iteration
counters. Section 2.4 addresses the first two (dirty-tree check at
line 189, oscillation detection at lines 197-199) but the third --
disk-based iteration counters -- is completely absent from the
recovery protocol pseudocode. The `MAX_ATTEMPTS` counter in the
pseudocode (line 183) is an in-memory variable. If the orchestrator
itself undergoes compaction mid-recovery-loop, or if the step subagent
crashes leaving the orchestrator to restart its loop, the in-memory
counter resets and the loop can run indefinitely.

**Add to section 2.4 (Recovery Protocol), after line 209
"run_mandatory_checkpoint()":**

> **Disk-based iteration tracking (from Wave 3 agent 3-5):**
> The `MAX_ATTEMPTS` counter above is in-memory. If the orchestrator
> undergoes compaction during the retry loop, the counter resets and
> the loop may run indefinitely. Fix: persist the attempt count to disk.
>
> ```
> ATTEMPT_FILE=".rebase-tmp/step${step}-attempts"
> attempt=$(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0)
> attempt=$((attempt + 1))
> echo "$attempt" > "$ATTEMPT_FILE"
> if [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
>     log("Max attempts exceeded for step $step (persisted)")
>     break
> fi
> ```
>
> This is the highest-severity real risk identified by the recovery
> agent because it produces unbounded loops (and therefore unbounded
> cost) silently. The dirty-tree and oscillation checks are defense
> against incorrect behavior; the iteration counter is defense against
> infinite behavior.

### 9.4 4K-Token Orchestrator Lint Rule Not in Part 6

Section 4.1 identifies that the orchestrator has only ~1K margin before
the 5K re-injection cliff, and proposes "a token-counting lint rule
should fail above 4,500 tokens." This is listed as a risk in 4.1 but
has no corresponding implementation action in Part 6 (Implementation
Risks). It is also absent from the PR ordering (section 4.3) and
success criteria (Part 5). A lint rule that prevents the orchestrator
from silently crossing the compaction boundary is a prerequisite for
PR-A, not an afterthought.

**Add to section 6.1 (Top 3 Pitfalls), as a new Pitfall 4:**

> **Pitfall 4: Orchestrator SKILL.md crosses the 5K compaction cliff.**
> The compaction model (4.1) shows that SKILL.md content beyond ~5,000
> tokens is silently dropped after compaction. The new orchestrator
> SKILL.md (~350 lines, ~4K tokens) has only ~1K of margin. Without
> enforcement, future edits could push it past 5K, reintroducing the
> exact failure mode step delegation was designed to fix.
>
> Fix: add a lint rule (in `make lint` or a pre-commit hook) that
> counts tokens in the orchestrator SKILL.md and fails above 4,500.
> A simple heuristic (words * 1.3) is sufficient; exact tokenization
> is not needed. This rule should ship with PR-A, not after it.

**Add to section 5 (PR-A success criteria), as a new bullet:**

> - Orchestrator SKILL.md is under 4,500 tokens (measured by lint
>   rule). Lint rule is present and enforced in `make lint`.

### 9.5 PR-B Rollback Strategy: Addressed (verify post-revert check)

Section 6.5 now includes a PR-B rollback entry (lines 604-606).
Verify the existing text includes a post-revert verification step
to check for residual `${CLAUDE_PLUGIN_ROOT}` references in step
files. The current text ("Step files revert to `find` patterns")
is correct but terse -- consider adding:

> After reverting PR-B, run `grep -r 'CLAUDE_PLUGIN_ROOT' steps/`
> to verify no references remain.

### 9.6 PR-B Success Criteria: Addressed (verify gate-file check)

Part 5 now includes PR-B criteria (lines 512-518). Verify it
includes the constraint that gate `.md` files must contain zero
`${CLAUDE_PLUGIN_ROOT}` references (per 2.1 finding). The current
text covers SKILL.md/step-file resolution and `find`-call elimination
but should also explicitly verify the gate-file constraint.

### 9.7 Step Delegation and `--model` Per-Repo Config Interaction

The test harness reads `model:` from config.yaml (e.g., `model: opus`
for ovn-org/ovn-kubernetes in test/config.yaml line 11) and passes it
as `claude --model opus` when launching sessions (test-skill.sh lines
419-423). Step delegation introduces a new layer: when the orchestrator
launches a step subagent via the Agent tool, the Agent tool accepts a
`model` parameter. But neither the plan's prompt template (plan lines
146-173) nor the audit addresses how the per-repo model config
propagates through delegation.

If the harness launches with `--model opus`, the main agent runs on
opus. But the step subagent launched via `Agent(...)` defaults to the
parent model unless `model:` is explicitly passed. If the intent is
for step subagents to inherit the parent model, this works by default
-- but it should be explicitly documented. If the intent is for step
subagents to use a different model (e.g., sonnet for cost savings on
small repos), the orchestrator needs model-selection logic.

**Add to section 6.1, after the existing Pitfall 3 (or after 9.4's
new Pitfall 4):**

> **Pitfall 5: Model inheritance in step subagents.** The test harness
> passes `--model` per repo (config.yaml). The Agent tool inherits
> the parent model by default, so step subagents will use whatever
> model the main agent was launched with. This is correct behavior
> but should be explicitly verified in PR-A testing: run at least one
> ovnk test with `model: opus` configured and verify the step
> subagent logs show the expected model. If future plans include
> per-step model selection (e.g., sonnet for Step 5, opus for Step 2),
> the orchestrator prompt template must be extended with a `model:`
> field in the Agent call.

### 9.8 `$ARGUMENTS` Contains Both `--bump-tools` AND Version Number

Section 2.5 correctly identifies that `$ARGUMENTS` is not passed
through the step prompt template. But it describes `$ARGUMENTS` as
"which includes `--bump-tools`" -- understating the scope. `$ARGUMENTS`
is the raw argument string from the skill invocation (SKILL.md line 19:
`**Arguments:** $ARGUMENTS`). It contains the version number AND any
flags like `--bump-tools`. The plan's template separately extracts
`{VERSION}` (plan line 152), so the version is not currently lost. But
any future flags added to the skill invocation would be silently
dropped because they are not individually extracted.

**Revise section 2.5 to read:**

> ### 2.5 Missing: `$ARGUMENTS` in Step Prompt Template
>
> The prompt template passes repo path, target version, plugin root,
> and step file reference. It does NOT pass `$ARGUMENTS` -- the raw
> argument string from the skill invocation. While the template
> separately extracts `{VERSION}`, it drops all flags. Currently the
> only flag is `--bump-tools` (Step 4d gates on it), but any future
> flags would be silently lost.
>
> **Fix:** Add `Arguments: {ARGUMENTS}` to the prompt template. The
> orchestrator should pass `$ARGUMENTS` verbatim so that step
> subagents receive both the version and all flags. This is
> future-proof: new flags added to the skill invocation automatically
> propagate to all steps without template changes.

### 9.9 CLAUDE.md as Compaction-Resilient Metadata Store

Section 4.1 identifies three new risks from the compaction model. Risk
3 states: "CLAUDE.md survives compaction (reloaded from disk). Critical
orchestration metadata could be duplicated there as defense-in-depth."
This is mentioned as a one-liner risk but has no corresponding
recommendation, implementation guidance, or PR assignment anywhere in
the audit. It is not in Part 6 (Implementation Risks), Part 5 (Success
Criteria), or section 4.3 (PR Ordering).

This is a genuine defense-in-depth opportunity. If the orchestrator
SKILL.md is truncated at the 5K boundary, having the step-delegation
architecture summary in CLAUDE.md means the agent still knows it
should delegate steps even after compaction. However, it requires
careful scoping -- CLAUDE.md is shared across all plugins, so only
minimal metadata belongs there.

**Add to section 6.1, as a new subsection after the pitfalls:**

> **Defense-in-depth: CLAUDE.md metadata.** The compaction model (4.1)
> confirmed that CLAUDE.md is reloaded from disk after compaction,
> surviving intact. A minimal orchestration summary in the repo's
> CLAUDE.md (or the plugin's top-level instructions) provides a
> fallback if SKILL.md is truncated past the 5K boundary. Recommended
> content (max 5 lines):
>
> ```
> # k8s-rebase architecture
> Steps 2, 3, 4 are delegated to subagents (fresh 1M context each).
> Step files: ${CLAUDE_PLUGIN_ROOT}/steps/step{2,3,4}.md
> Rules: ${CLAUDE_PLUGIN_ROOT}/steps/rules.md
> Recovery: read .rebase-tmp/step*-status.json and gate reports.
> ```
>
> This should ship with PR-A. It is NOT a substitute for the
> orchestrator SKILL.md staying under 4,500 tokens -- it is a last
> resort if compaction fires unexpectedly early.

### 9.10 False Positive Risk for Gates at Depth 2

The appendix entry 3-14 says "depth-2 gates: Safe. Same Bash env,
same permissions, atomic writes. Only issue: line 159." This
assessment addresses whether gates CAN RUN at depth 2, not whether
they PRODUCE THE SAME VERDICTS at depth 2. Today, gates run at depth 1
(main -> gate). After step delegation, gates run at depth 2 (main ->
step -> gate). The gate subagent's behavior could differ because:

1. **Prompt context differs.** Today the main agent's accumulated
   context (previous gate results, SKILL.md instructions, build
   output) leaks into gate subagent behavior through the parent's
   prompt construction. At depth 2, the step subagent constructs the
   gate prompt with different surrounding context.
2. **Tool availability at depth 2.** If a gate subagent at depth 2
   cannot launch further subagents (depth-3 limit reached), and any
   gate currently relies on spawning a helper agent, that gate would
   silently fail or produce a different verdict.
3. **Gate pass/fail thresholds.** A gate that passes at depth 1 might
   fail at depth 2 (or vice versa) due to different prompt framing,
   creating false positives or false negatives invisible in aggregate
   pass rate numbers.

**Add to section 6.1, as a new subsection:**

> **Risk: Gate verdict drift at depth 2.** After step delegation,
> gates run at nesting depth 2 instead of depth 1. While agent 3-14
> confirmed that depth-2 execution is mechanically safe (same Bash
> env, same permissions), it did not verify that gate verdicts are
> identical at both depths. The gate subagent receives its prompt from
> the step subagent (not the main agent), which changes the
> surrounding context.
>
> **Validation requirement for PR-A:** Run at least 5 gates in both
> configurations (depth 1 via current architecture, depth 2 via step
> delegation) on the same repo state and compare verdicts. Any
> divergence indicates prompt-sensitivity in gate logic that must be
> addressed before shipping. Focus on gates that make judgment calls
> (scope-review, test-vet) rather than mechanical checks
> (compilation, lint).

---

## Appendix: Agent Roster

41 agents across 3 waves. Every finding is covered in Parts 1-8
above. Wave 1 (5 agents) verified factual claims. Wave 2 (14 agents)
deep-dived weak points. Wave 3 (22 agents) ran adversarial challenges
where one agent (3-22, compaction model) corrected an earlier agent
(3-12, token offsets).

---

## Implementation Checklist

Every concrete change from the audit, organized by PR in the
audit-recommended order (Section 4.3). This is the implementing
agent's TODO list.

### PR-0 (branch fix, ~2 min, ship immediately)

Source: Sections 1.4, 2.7, 4.3

- [ ] SKILL.md line 87: change `Run from the default branch (master/main).` to `Run from the current branch.` (Section 1.4 false-positive fix)
- [ ] SKILL.md line 94: change `git checkout master && git branch -D <branch>` recovery instruction to use current-branch semantics -- remove the master checkout, replace with branch-only cleanup that does not switch away from the working branch (Section 2.7)
- [ ] Version bump plugin.json to next patch version
- [ ] Run `make lint` and `make update`

**Validation (Section 5 PR-0 criteria):**
- [ ] 10 ovnk runs in `--from-commit` mode across v1.34 and v1.35
- [ ] Every PASS must have fewer than 500 code hunks
- [ ] Verify starting commit SHA in logs matches `--from-commit` value

---

### PR-A (step delegation, 1-2 days)

Source: Sections 1.2, 1.3, 2.3, 2.4, 2.5, 2.6, 4.1, 4.2, 6.1, 6.2

#### New files: `steps/` directory

- [ ] Create `plugins/k8s-rebase/steps/` directory
- [ ] Create `steps/rules.md` -- shared rules extracted from SKILL.md preamble (module safety, commit conventions, scope constraints, container commands, feature gates, gate-fix loop protocol, subagent rules, commit discipline). Must thoroughly replicate the SKILL.md preamble so non-ovnk repos do not regress (Section 6.3)
- [ ] Create `steps/step2-compilation.md` -- extract Step 2 content from SKILL.md (lines 248-426), adapted for subagent execution. Keep existing `find` patterns for script/gate discovery (Section 4.3: gates keep `find`, not `PLUGIN_ROOT`)
- [ ] Create `steps/step3-autofix.md` -- extract Step 3 content from SKILL.md (lines 428-538), adapted for subagent execution. Keep existing `find` patterns
- [ ] Create `steps/step4-verification.md` -- extract Step 4 content from SKILL.md (lines 540-833), adapted for subagent execution. Keep existing `find` patterns

#### SKILL.md rewrite to ~350-line orchestrator

- [ ] Keep Step 1 inline (low context cost ~500 tokens, Section 1.4)
- [ ] Keep Step 5 inline (user-facing deliverable, ~20K tokens, Section 1.4)
- [ ] Delegate Steps 2, 3, 4 to subagents with fresh 1M context each
- [ ] Orchestrator constructs step subagent prompt with ALL required variables: repo root, target version, plugin root (literal resolved path), step file path, rules file path, gate directory path, gate report helper path (Section 2.5, 6.1 Pitfall 3)
- [ ] Pass `$ARGUMENTS` through the step prompt template (Section 2.5 -- without this, `--bump-tools` is silently dropped and Step 4d never runs)
- [ ] Add pre-launch validation bash block that checks all variables are non-empty before each Agent call (Section 6.1 Pitfall 3: variable resolution failures waste 30-60 min per failed step)
- [ ] Orchestrator resolves `${CLAUDE_PLUGIN_ROOT}` (via Claude Code text substitution in SKILL.md), passes the literal string to step subagents, which pass it to gate subagents (Section 2.1: gate files must receive literal paths, not env vars)

#### Step subagent prompt template fixes

- [ ] Fix nesting instruction (Section 2.3): replace `Do NOT launch subagents that launch their own subagents` with `Your subagents (gates, investigation helpers) must NOT launch their own subagents -- nesting limit is 3 (main -> step -> your subagent).` This explicitly permits gate launching while constraining depth
- [ ] Add `git log` discovery line to step prompt (Section 4.2): `Run git log --oneline $(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)..HEAD to understand what previous steps did.`

#### Recovery protocol (Section 2.4)

- [ ] Implement MAX_ATTEMPTS = 2 per step (initial + one retry)
- [ ] Step subagent writes machine-readable status to `.rebase-tmp/step{N}-status.json` with exact gate counts (Section 6.1 Pitfall 2: do not parse AI text for verdict)
- [ ] Orchestrator reads status file from disk, not subagent text response
- [ ] Before each step launch: `git status --porcelain` dirty-tree check -- abort if uncommitted changes (Section 2.4, 6.2)
- [ ] After each step: audit gate reports on disk and compare git HEAD (disk is source of truth, verdict is advisory)
- [ ] Oscillation detection: track passed gate names as sets, not counts -- detect if a previously-passed gate regresses (Section 2.4: count increase 4->5 can mask regression)
- [ ] Step 2 build-vet FAIL is terminal after 2 attempts with fresh 1M context (Section 2.4)
- [ ] Write `.rebase-tmp/deferred.txt` for cross-step communication (Section 4.2: one issue per line, subsequent steps check this file)

#### Step 4 `--quick` fix (Section 2.6)

- [ ] In `step4-verification.md`: change gate-fix re-validation from `validate.sh --no-test` to `validate.sh --quick` (matching Step 2)
- [ ] Add a single final `validate.sh --no-test` run after all gate-fix loops complete (saves ~36 min worst case: 9 iterations x 4 min overhead per `--no-test` vs `--quick`)

#### Mandatory checkpoint update

- [ ] Detect "not PASS" instead of just "is FAIL" (catches malformed reports) -- current SKILL.md line 849 only checks `VERDICT: FAIL`
- [ ] Keep the `find`-based gate counting approach (zsh-compatible)

#### No structured checkpoints (Section 4.2)

- [ ] Do NOT implement the 15-line or 40-60 line checkpoint format from the plan or Wave 2
- [ ] Remove or simplify the rebase-report.md checkpoint appends from step instructions (steps discover prior state via `git log` and `.rebase-tmp/deferred.txt`)

#### Token budget guard (Section 4.1)

- [ ] Keep orchestrator SKILL.md under 4,500 tokens (the 5K re-injection cap minus ~500 token margin). The audit found Steps 1-2 at ~5,147 tokens already razor-thin. A shorter orchestrator has more margin
- [ ] Consider a lint rule that fails if SKILL.md exceeds 4,500 tokens (Section 4.1 risk #1)

#### Test harness compatibility (Section 1.4, 6.3)

- [ ] Remove 2 `sed` lines from `mutate_plugin()` in `test/test-skill.sh` (lines 618-619) that patch `find` calls for autofix and patterns -- these become dead code when step files use `find` independently. Note: only remove if the orchestrator SKILL.md no longer contains these specific `find` calls; if it still does, keep them
- [ ] Verify wall time impact is acceptable (10-25 min overhead, 7-17% -- Section 6.4)
- [ ] Clear `results.tsv` before testing PR-A to avoid mixing architecture results (Section 6.5)

#### Version bump

- [ ] Bump plugin.json version
- [ ] Run `make lint` and `make update`

**Validation (Section 5 PR-A criteria):**
- [ ] spec=none (production): Zero "missing 15+ of 33 gates" failures in 30 runs (10 per version)
- [ ] spec=all (stress): "missing 26+ gates" rate drops from 24% to under 5%
- [ ] Per-version floor: no version below 55% pass rate
- [ ] Per non-ovnk repo: no repo drops more than 15pp from its pre-PR-A baseline
- [ ] Wall time: median ovnk run under 4 hours, p95 under 6 hours
- [ ] Runs spread across 5+ calendar days (mitigates autocorrelation)

---

### PR-B (PLUGIN_ROOT migration, 0.5 day)

Source: Sections 2.1, 4.3

- [ ] Replace 12 `find "$HOME/.claude" "$HOME" -maxdepth 7` calls in SKILL.md with `${CLAUDE_PLUGIN_ROOT}` paths (Claude Code resolves this token in SKILL.md via text substitution)
- [ ] Replace `find` calls in step files (`step2-compilation.md`, `step3-autofix.md`, `step4-verification.md`) with literal paths received from the orchestrator prompt -- step files are read via the Read tool, so `${CLAUDE_PLUGIN_ROOT}` does NOT resolve in them; they must use the path variable passed in the step prompt
- [ ] Do NOT replace `find` calls in gate `.md` files (Section 2.1: `CLAUDE_PLUGIN_ROOT` is not a shell env var, gate files are read via Read tool, bash blocks would get empty string). Gates continue using `find` OR receive literal paths from step subagent prompts
- [ ] Remove the 2 `sed` lines from `mutate_plugin()` in `test/test-skill.sh` (lines 618-619) if not already removed in PR-A -- PLUGIN_ROOT handles the mutated-copy case automatically
- [ ] Port 2 `GOVERSION=` sed patterns from `fix_go_version()` to `k8s-rebase.sh` Phase 3 (Section 7 disposition: `fix_go_version` is not yet redundant until this port is done)
- [ ] Version bump plugin.json
- [ ] Run `make lint` and `make update`

**Validation:**
- [ ] `make lint` passes
- [ ] `make matrix` shows no regressions vs PR-A baseline
- [ ] Verify gate subagents still find their companion `.sh` scripts

---

### PR-C (discovery procedures + cleanup, 1-2 days)

Source: Sections 7, 8, plan Section "PR3"

#### Discovery procedure corrections (Section 8)

- [ ] Feature gate discovery (#1): expand from single-file `known_features.go` to 2-3 files: `vendor/k8s.io/client-go/features/known_features.go` + `vendor/k8s.io/kubernetes/pkg/features/kube_features.go` + dependency map (Section 8 #1: single-file approach is insufficient)
- [ ] Unify feature gate discovery (#1) with RelaxedServiceNameValidation discovery (#6) -- both are feature gate lookups across the same files (Section 8 #6)
- [ ] kubeadm discovery (#2): do NOT describe as "check vendored kubeadm API version" -- kubeadm is NOT vendored. Document the 3 indirect paths: (a) version correlation from go.mod, (b) file inspection of kind.yaml.j2, (c) extraArgs format detection. Note that the current autofix function IS the correct solution since it checks file content directly (Section 8 #2)
- [ ] ObservedGeneration discovery (#5): document as two-step grep (find assertions in tests, then find missing assignments in controllers) but note fragility without domain context (Section 8 #5)

#### Autofix function cleanup

- [ ] Remove 3 redundant functions: `fix_version_refs`, `fix_go_version` (only after PR-B ports GOVERSION= pattern), `fix_docs_version` (reclassified as ovnk-specific, not redundant -- keep or mark appropriately per Section 7)
- [ ] Remove completed one-time functions only if ALL repos are past target version: `fix_bounding_dirs`, NPA v0.2 functions, `fix_kubeadm_v1beta4` (Section plan "PR3")
- [ ] Reclassify `fix_relaxed_svc_name` from "one-time done" to "evergreen/version-adaptive" -- it has bidirectional version guard (adds gate for k8s < 36, removes for >= 36) (Section 7)
- [ ] Add section comments to autofix marking permanent vs migration functions (carried from plan PR1)

#### Gate renames for spec=all compatibility

- [ ] Rename `autofix-result.md` to `fix-verification.md` (or equivalent process-agnostic name)
- [ ] Rename `autofix-diff-review.md` to `fix-diff-review.md`
- [ ] Update `dep-release-notes.md` naming
- [ ] Update TAG_TO_PATTERN in `test/test-skill.sh` to match any heading renames -- must be in the same commit as the patterns doc changes (Section plan "Risks": heading renames are a known coupling point)

#### Patterns doc restructure

- [ ] Restructure from 591 to ~208 lines
- [ ] Organize by pattern class (Go API Breakage, Feature Gates, CRD Validation, CI Infrastructure) instead of by k8s version
- [ ] Remove 11 version-specific stale patterns (9 k8s 1.36-specific, 2 k8s 1.35)
- [ ] Remove 3 one-time done patterns (AddToScheme, x/exp, KubeVirt IPv6)
- [ ] Keep 5 permanent-recurring + 7 permanent-conditional patterns
- [ ] Update TAG_TO_PATTERN heading names in `test/test-skill.sh` in the SAME commit as patterns doc heading renames

#### Feature gate self-discovery

- [ ] Generalize `fix_feature_gates` toward self-discovering GATE_DEPS
- [ ] Env var layers: fully self-discovering from vendored code
- [ ] SetFromMap layer: keep minimal curated list OR implement two-file awk pass (`known_features.go` + `kube_features.go`) to resolve gate dependencies (plan "Risks": SetFromMap validates parent-dep consistency, disabling a parent without its deps causes error)

#### Version bump

- [ ] Bump plugin.json version
- [ ] Run `make lint` and `make update`

**Validation (Section 5 PR-C criteria):**
- [ ] Within 5pp of PR-A's measured rate per version (non-regression)
- [ ] At least 1 successful end-to-end run on a version with zero recipe coverage (validates version-agnosticism)
- [ ] PR-C heading renames and TAG_TO_PATTERN updates are in one squashable commit sequence (Section 6.5 rollback requirement)

---

### Plan document corrections (apply to step-isolation-and-generality.md)

Source: Sections 2, 3, 4, 5

#### Factual corrections (Section 3)

- [ ] Fix #1: Change `81% of ovnk failures report "missing 26 of 33 gates"` (line 37, executive summary, problem statement) to `66% missing-any-gates all-time; 80% recent; "missing 26" specifically is 26%`
- [ ] Fix #2: Change `56 find calls` to `50 calls (12 in SKILL.md, 38 in gates, 0 in scripts matching this pattern)`
- [ ] Fix #3: Change `44 seconds across 56 calls` to `~200 seconds across 50 calls (4.1s per call)`
- [ ] Fix #4: Change `starting at ~8K tokens` (line 33-34) to `starting at ~5.1K tokens` -- the 5K re-injection cap falls right at the Step 2/Step 3 boundary, not at ~8K
- [ ] Fix #5: Change `19 of 27 ovnk-only functions` (line 259) to `12-14 of 26 functions` -- fix_lint_version was double-counted; clarify the distinction between "only triggers on ovnk in tests" vs "can only trigger on ovnk by design"
- [ ] Fix #6: Change `true pass rate ~20%` / `roughly 1 in 5` (line 9) to `26.5% (13/49), closer to 1 in 4` -- note the rate is non-stationary (~13% Jul 30 improving to ~73% Aug 4-7, 95% CI [16%, 40%])
- [ ] Fix #7: Change fix_go_version classification from "Redundant" to "Not yet redundant" -- GOVERSION= pattern not ported to k8s-rebase.sh Phase 3 yet. Becomes redundant after PR-B
- [ ] Fix #8: kubeadm discovery -- change "check vendored kubeadm API version" to describe indirect discovery (3 paths: version correlation, file inspection, format detection). Note kubeadm is NOT in ovnk's vendor
- [ ] Fix #9: Feature gate discovery -- change "parse known_features.go" to "parse 2-3 files: client-go known_features.go + kubernetes kube_features.go + dependency map". Note RelaxedServiceNameValidation is in kube_features.go, not client-go. Unify procedures #1 and #6
- [ ] Fix #10: Change `55% of passes are false positives` to `42.3% (11/26) across all versions; 52.9% for k8s 1.34+1.35 specifically; zero for 1.36`

#### Architectural corrections

- [ ] Section "CLAUDE_PLUGIN_ROOT" (lines 191-200): Add caveat that `CLAUDE_PLUGIN_ROOT` is NOT a shell env var and does NOT resolve in gate `.md` files read via the Read tool. Gates must receive literal paths from step prompts, not reference `${CLAUDE_PLUGIN_ROOT}` in bash blocks (Section 2.1)
- [ ] Section "Risks" row 4 (line 344): Change `Verified locally: subagents at depth 2 resolve $HOME and env vars correctly` to note that `CLAUDE_PLUGIN_ROOT` specifically does NOT resolve in bash -- it is a text substitution token, not an env var
- [ ] Prompt template (lines 148-173): Fix line 159 nesting instruction per Section 2.3
- [ ] Prompt template: Add `$ARGUMENTS` passthrough (Section 2.5)
- [ ] Add recovery protocol specification (Section 2.4 pseudocode)
- [ ] Add step subagent writes `.rebase-tmp/step{N}-status.json` (Section 6.1 Pitfall 2)
- [ ] Add pre-launch variable validation (Section 6.1 Pitfall 3)
- [ ] Add dirty-tree check before each step launch (Section 6.2)

#### PR ordering (Section 4.3)

- [ ] Reorder from PR1/PR2/PR3 to PR-0/PR-A/PR-B/PR-C as recommended by the audit
- [ ] Update the "3 PRs" framing to "4 PRs" (branch fix split out as PR-0)

#### Success criteria (Section 5)

- [ ] Replace "10+ runs" with 30+ runs per condition
- [ ] Replace "~100% for non-ovnk repos" with per-repo non-regression floor (no repo drops more than 15pp)
- [ ] Replace "80% for ovnk" with realistic targets: zero "missing 15+" failures (spec=none), under 5% "missing 26+" (spec=all), per-version floor of 55%
- [ ] Add wall-time criterion: median under 4 hours, p95 under 6 hours
- [ ] Add temporal spread: runs across 5+ calendar days
- [ ] Add PR-0 specific criteria (hunk count validation, SHA verification)
- [ ] Add PR-C specific criteria (within 5pp of PR-A, one zero-recipe-coverage run)

#### Autofix disposition table corrections (Section 7)

- [ ] Change `27 functions` to `26 functions` (fix_lint_version double-counted)
- [ ] Reclassify fix_docs_version from "Redundant" to "Ovnk-specific" (only targets `docs/features/requirements.md` which only exists in ovnk)
- [ ] Reclassify fix_relaxed_svc_name from "One-time done" to "Evergreen/version-adaptive" (bidirectional version guard)
- [ ] Change `19 of 27 functions only trigger on ovn-kubernetes` to `12-14 of 26 functions are ovnk-only`

#### Compaction model corrections (Section 4.1)

- [ ] Replace `SKILL.md is truncated to its first ~5K tokens` with the correct mechanism: `SKILL.md is re-injected with a hard 5,000-token cap per skill after compaction`
- [ ] Add the three new risks: (1) orchestrator at ~4K tokens has only ~1K margin before the 5K cliff, (2) 25K shared skill budget means other skills can eat k8s-rebase's allocation, (3) CLAUDE.md survives compaction and could serve as defense-in-depth
- [ ] Add the multimodal distribution explanation: "missing 26" = compaction before Step 3, "missing 15" = compaction during Step 3, "missing 28-32" = compaction during Step 2
- [ ] Add the spec=all correlation: ALL "missing 26" failures are spec=all; autofix (spec=none) finishes Step 2 faster, pushing compaction later

#### Regression root cause (Section 2.2)

- [ ] Add multi-factor regression analysis: the Aug 8-9 regression is NOT solely `model: opus`
- [ ] Document evidence: pre-commit failures, non-ovnk repos affected, v1.34.1 passes 100% with opus, v1.35.3 improved with opus
- [ ] Document the gate-launch pattern change as independent behavioral risk
- [ ] Add recommendation: remove `model: opus` from configs (partial improvement) and evaluate gate-launch change (cat vs Read)

#### Rollback strategy (Section 6.5, missing from plan)

- [ ] Add rollback strategy section: PR-0 git revert (no deps), PR-A git revert (orphaned steps/ harmless), PR-C git revert (TAG_TO_PATTERN headings must be in one squashable commit)
- [ ] Note all PRs are independently revertible

#### Checkpoint design (Section 4.2)

- [ ] Replace structured checkpoint format with `git log` discovery line in step prompt
- [ ] Add `.rebase-tmp/deferred.txt` for cross-step deferred issue communication
- [ ] Remove or note as superseded the 15-line checkpoint concept

#### Step 4 re-validation fix (Section 2.6)

- [ ] Correct claim that "Steps 2 and 4 already do this [use --quick]" -- Step 4 uses `--no-test`, not `--quick` (SKILL.md line 737)
- [ ] Document the fix: Step 4 gate-fix re-validation should use `--quick`, with a single final `--no-test` after all loops complete

---

### Immediate config changes (Section 2.2, apply now)

These are not plan document changes but operational actions
recommended by the audit.

- [ ] Remove `model: opus` from ovnk test configs (low risk, likely partial improvement for the regression)
- [ ] Evaluate whether the gate-launch pattern change (from "cat file contents into prompt" to "tell subagent to Read the file by path") should be reverted or refined -- this is an independent behavioral change that may explain "missing gates" failures across all repos
