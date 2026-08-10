# k8s-rebase: Step Isolation + Version-Agnostic Generality

## Executive Summary

The k8s-rebase skill automates Kubernetes dependency rebases for Go projects.
It works reliably for 5 smaller repos (90%+ pass rate) but fails on the
largest target, ovn-kubernetes (1,358 Go files, 482K LOC, 3 go.mod files).
After correcting for a test measurement bug, the true ovnk pass rate is
~27% (13/49 genuine passes). Two interacting causes produce 35 "missing
gates" failures:

- **Autofix FAIL trigger** (mechanism): The autofix script prints
  `RESULT: FAIL` with `exit 1`. The agent treats this as terminal and
  skips Steps 3-5. Every N≥26 failure is spec=all (autofix neutered →
  always reports FAIL). 11 of 35 failures.

- **Context pressure** (trigger): Under high context usage, the agent
  stops at step boundaries even without the FAIL signal. N=15 failures
  appear in both spec=all and spec=none. 7 of 35 failures.

21 of 35 missing-gate failures (60%) land exactly on step boundaries
(N=26, N=15, N=32). This is behavioral — the agent finishes a step and
stops — not random context exhaustion.

The fix is a **graduated ladder** where both levels address distinct
failure populations:

1. **Autofix + hooks fix (hours):** Fix the FAIL signal + add Stop hook.
   Targets the N=26 cluster (11 failures). Estimated fix rate: 75-85%.

2. **Workflow orchestration (days, if needed):** Deterministic step
   sequencing + fresh context per step. Targets the N=15 cluster and
   scattered failures. Needed at scale for 100s of repos.

## Key Concepts

- **Gate:** A `.md` file under `gates/step{N}-*/` defining one quality check.
  A subagent reads it, runs the check, writes a PASS/FAIL `.report` to disk.
  33 gates across Steps 1-4.
- **Step subagent:** A fresh Claude agent that executes an entire rebase
  phase. Gets its own 1M context window. Launched by the Workflow script.
- **spec=all / spec=none:** Test modes. `spec=all` disables autofix + patterns
  (blind mode). `spec=none` runs full skill (production mode).
- **Compaction:** At ~83.5% context usage, Claude Code re-injects each skill
  with a hard ~5,000-token cap. Steps 3-5 start at ~5K tokens — right at
  the cap. (Inferred from failure distributions, not verified against source.)
- **`CLAUDE_PLUGIN_ROOT`:** Text-substitution token resolved by Claude Code
  in plugin-registered files (SKILL.md, commands, hooks) only. NOT a shell
  environment variable. Does NOT resolve in files read via the Read tool.

## Problem Statement

### Problem 1: Agent Skips Steps (Two Interacting Causes)

The "missing N of 33 gates" failures have TWO causes that interact:

**Cause A — Autofix FAIL trigger (N=26 cluster, 11 of 35 failures):**
The autofix script prints `RESULT: FAIL` with `exit 1`. The agent
rationally interprets these as "stop" signals, ignoring three explicit
anti-skip instructions in SKILL.md. Session `fdf1e3a9` confirms: the
agent completes Step 2 gates, receives autofix FAIL, then jumps to
Step 5 without running Steps 3-4. Every N≥26 failure is spec=all
(autofix neutered → always reports FAIL).

**Cause B — Context pressure (N=15 cluster, 7 of 35 failures):**
Under high context usage, the agent stops at step boundaries even
without the FAIL signal. N=15 failures appear in both spec=all and
spec=none. OVNK is 6x more susceptible (37% skip rate vs 6% for
other repos) — larger repo = more context consumed = agent more
likely to stop after a hard step. A phase transition around Aug 3
shifted failures from N=15 to N=26 after commits consumed more
context budget.

**Key evidence:**
- 21 of 35 missing-gate failures (60%) land exactly on step
  boundaries (N=26, N=15, N=32). This is behavioral, not random.
- The remaining 40% have scattered N values (mid-step stops),
  consistent with context pressure or infrastructure issues.
- N=32 pair on Aug 8 (CNO + CNCC within 7 minutes) suggests
  an environment issue, not agent behavior.
- Zero compaction events found in 1,455 sessions — but the agent
  can stop under context pressure without hitting actual compaction.
  (Note: absence of logged events doesn't prove absence of compaction —
  compaction by design removes evidence of itself from the transcript.)
- "missing 15" occurs with spec=NONE on ovnk (3 runs, July 30-31).
  Autofix is NOT neutered in spec=none, so the FAIL trigger cannot
  explain these. Context pressure alone causes N=15 skips for large
  repos — confirming Cause B is real and independent of Cause A.
- The "Robustness" commit (Aug 8, 9e52ec68) caused a 7x rate increase
  in missing-26+ failures (2.5% → 17.8%). Changes to gate context
  reduction and SKILL.md top-loading may have altered what the agent
  retains under pressure.

**Earlier hypothesis was partially wrong:** ~180 agents attributed
ALL failures to context exhaustion/compaction. Transcript inspection
showed the N=26 cluster is behavioral (autofix FAIL trigger). But
the N=15 cluster and OVNK's elevated rate confirm context pressure
IS a real factor — just not through the compaction mechanism.

**Why both fixes are needed at scale (100s of repos):**
- The autofix + hooks fix targets Cause A (the FAIL signal)
- Workflow orchestration targets Cause B (fresh context per step +
  deterministic sequencing eliminates both causes structurally)

### Problem 2: Test Measurement Bug (`--from-commit` mode only)

SKILL.md says "Run from the default branch (master/main)" but the test
harness overrides this for historical replay tests. 42% of ovnk spec=all
"passes" (11/26) have 6,000+ code hunks (wrong starting point). Fix:
change SKILL.md to "Run from the current branch."

### Problem 3: Version-Specific Recipes Rot

The autofix script (1,678 lines) and patterns doc (591 lines, 53.8% stale)
contain k8s 1.34-1.36-specific recipes. The rebase script is fully general.
`spec=all` tests show the AI discovers 74% of fixes independently.

### Problem 4: `find` Calls Break at Marketplace Install Depth

All 50 file-discovery calls use `find "$HOME" -maxdepth 7`. The marketplace
install path exceeds this depth.

## Architecture

### Current (monolithic, 981-line SKILL.md)

```
claude --bg session (single 1M context)
└── SKILL.md orchestrates Steps 1-5 sequentially (AI-interpreted prose)
    ├── Step 2: fix loop (250-350K tokens)
    ├── Step 3: autofix + 11 gates               ← SKIPPED (agent stops early)
    ├── Step 4: lint/test/review + 15 gates       ← SKIPPED (agent stops early)
    └── Step 5: generate PR command               ← JUMPED TO prematurely
```

### Proposed (Workflow + step subagents)

```
claude --bg session
├── SKILL.md (~50 lines): parse args, invoke Workflow
└── workflows/k8s-rebase.js (~150-200 lines): deterministic orchestration
    ├── Step 1: agent() — run script + 1 gate
    ├── Step 2: agent() — fresh 1M, fix loop + 6 gates
    ├── Step 3: agent() — fresh 1M, autofix/discovery + 11 gates
    ├── Step 4: agent() — fresh 1M, lint/test/review + 15 gates
    ├── Mandatory checkpoint (JS: count .report files on disk)
    └── Step 5: agent() — generate PR command, return to workflow
```

**Why a Workflow instead of SKILL.md prose:** The orchestration layer
(step sequencing, gate counting, dirty-tree checks, fast-fail logic) is
a state machine with zero judgment calls — just integer/set comparisons
and if-statements. Making an AI interpret this from prose is solving a
deterministic problem with a non-deterministic tool. A Workflow script
makes these guarantees actual guarantees. The existing `k8s-rebase-gates-wf`
file in this project demonstrates the pattern.

Nesting: main (0) → step agent (1) → gate agent (2) = 3 levels.

### End-State Directory Layout

```
plugins/k8s-rebase/
├── .claude-plugin/plugin.json
├── skills/k8s-rebase/SKILL.md     # Thin entry point (~50 lines)
├── workflows/k8s-rebase.js        # NEW — deterministic orchestrator
├── steps/                          # NEW — step subagent instructions
│   ├── rules.md                   # Shared rules
│   ├── step1-rebase.md            # Script launch + 1 gate
│   ├── step2-compilation.md       # Fix loop + 6 gates
│   ├── step3-autofix.md           # Autofix/discovery + 11 gates
│   ├── step4-verification.md      # Lint/test/review + 15 gates
│   └── step5-submit.md            # PR command + report
├── gates/                          # Keep existing find patterns
├── scripts/                        # UNCHANGED
├── docs/k8s-rebase-patterns.md    # Restructured in PR-C
├── hooks/block-push.md            # UNCHANGED
├── plans/                          # This document
└── test/                           # Minor cleanup
```

### Token Budget (estimated)

The main agent runs SKILL.md (~50 lines, ~1.5K tokens) and invokes the
Workflow. Each step agent gets a fresh 1M context:

| Step Agent | Estimated Usage | Headroom |
|------------|----------------|----------|
| Step 1 | ~30K (3%) | 970K |
| Step 2 | ~304-359K (30-36%) | 641K+ |
| Step 3 | ~155-235K (16-24%) | 765K+ |
| Step 4 | ~119-411K (12-41%) | 589K+ |
| Step 5 | ~47K (5%) | 953K |

All steps have comfortable margin within 1M. Step 4 is the widest range
due to variable test output.

### Recovery: 3 Checks, Not a State Machine

Within-run retry of step subagents is counterproductive — fresh context
+ same instructions = same decisions. The test harness already retries
whole runs effectively. The Workflow script implements 3 validation
checks, not a retry loop:

```javascript
for (const step of [1, 2, 3, 4, 5]) {
  // Check 1: dirty-tree guard
  const dirty = await agent('Run: git status --porcelain');
  if (dirty.includes('M ')) throw new Error('Dirty tree before step ' + step);

  // Launch step
  const result = await agent(buildStepPrompt(step), {
    label: 'step-' + step,
    schema: STEP_RESULT_SCHEMA
  });

  // Check 2: Step 2 fast-fail
  if (step === 2 && result.verdict === 'FAILED') {
    const head = await agent('Run: git rev-parse HEAD');
    if (head === mergeBase) throw new Error('Step 2 structural failure');
  }

  // Check 3: gate count verification
  const reports = countGateReports(step);
  if (reports.missing > 0) log('Step ' + step + ': ' + reports.missing + ' gates missing');
  if (reports.fails > 0) log('Step ' + step + ': ' + reports.fails + ' gates failed');
}

// Mandatory checkpoint
const total = countAllGateReports();
if (total.actual < total.expected) throw new Error('Missing gates: ' + (total.expected - total.actual));
```

If a step fails, the run fails. The test harness retries the whole repo.
This is simpler and more effective than within-run retry.

**Inter-step communication:** Step subagents write
`.rebase-tmp/deferred.txt` (one issue per line) for items deliberately
skipped. Subsequent steps discover prior work via `git log`, not
AI-generated summaries.

## Implementation: Graduated Ladder

### Step 0: Verify diagnosis (1-2 hours)

Examine 3-5 failed session transcripts from different repos (ovnk, CNO,
CNCC) to confirm the step-skipping mechanism is consistent. If any
transcript shows compaction or a different failure mode, the ladder
needs adjustment.

### Step 1: Branch fix (2 min, ship immediately)

- Fix SKILL.md line 87: "Run from the default branch" → "Run from the
  current branch"
- Fix SKILL.md line 94: remove master checkout from recovery instruction
- Version bump (patch), `make update`

### Step 2: Autofix + hooks fix (2-4 hours, the primary fix)

The agent stops because autofix sends contradictory signals: `exit 1` +
`RESULT: FAIL` say "stop" while SKILL.md prose says "continue." Make
all signals consistent:

**In `k8s-rebase-autofix.sh`:**
- Line 1677: change `exit 1` → `exit 0` (the script succeeded at its
  job; remaining items are for the agent, not evidence of failure)
- Line 324: change `RESULT: FAIL (N checks non-zero)` →
  `RESULT: ITEMS_REMAINING (N checks for gates to verify)`
- Add after the remaining-issues block:
  `ACTION REQUIRED: Run all 11 Step 3 gate subagents now.`

**In SKILL.md Step 3 (lines 428-475):**
- Move the "FAIL is normal, proceed to gates" instruction from mid-
  paragraph (line 443) to BEFORE the autofix bash block. The agent
  reads top-down; put the instruction before the moment it decides.
- Add: `**Regardless of autofix exit code or output, proceed to the
  gate block below. The gates verify the result, not the autofix.**`

**New hooks (defense in depth):**
- `hooks/autofix-proceed.md` (PostToolUse): detects autofix output
  with "ITEMS_REMAINING" and injects "Proceed to Step 3 gates now"
- `hooks/gate-completeness.md` (Stop): blocks session ending if
  fewer than 33 gate reports exist in `.rebase-tmp/gates/`

**Validation:** 5 ovnk spec=all runs on 1.36.2. If zero "missing 26+"
failures, the fix works. If still >20% skip rate, escalate to Step 3.

**Estimated fix rate:** 75-85%. Eliminates the two strongest stop
signals (exit code + FAIL text). Hooks provide backup enforcement.

### Step 3: Workflow orchestration (3-5 days, only if Step 2 insufficient)

If the signal-consistency fix and hooks are not sufficient, build
deterministic orchestration:

- Create `workflows/k8s-rebase.js` (~150-200 lines)
- Create `steps/`: rules.md + 5 step files
- Rewrite SKILL.md to ~50-line entry point
- Workflow for-loop runs each step — cannot be skipped by AI judgment
- Gate counting in JS — deterministic, not AI-interpreted

**Before investing:** Do a 2-hour spike on CNCC to validate depth-2
gate nesting works correctly.

### Step 4: Discovery procedures + cleanup (1-2 days, independent of Steps 2-3)

- Replace version-specific recipes with discovery procedures in step files
- Feature gate discovery: parse 2-3 files (client-go `known_features.go`
  + kubernetes `kube_features.go` + dependency map)
- kubeadm discovery: indirect paths (version correlation, file inspection,
  extraArgs format detection) — kubeadm is NOT vendored
- Restructure patterns doc (591 → ~208 lines), update `TAG_TO_PATTERN`
- Rename 3 gates for process-agnosticism
- Remove completed autofix functions (only after all repos past target)

**Validation:** Within 5pp of PR-1 rate. At least 1 zero-recipe success.

**Rollback:** `git revert`. Verify TAG_TO_PATTERN consistency.

## Autofix Function Disposition

26 functions (fix_lint_version counted once, fix_uncommitted excluded):

| Category | Count | Functions | Action |
|----------|-------|-----------|--------|
| **Evergreen** | 6 | fix_feature_gates, fix_kind_image, fix_kind_version, fix_lint_version, fix_imports, fix_relaxed_svc_name | Keep |
| **Permanent** | 4 | fix_reflect_ptr (no AI signal), fix_crd_int64_validation, fix_crd_name_validation, fix_addtoscheme | Keep |
| **Accelerator** | 2 | fix_xexp, fix_fieldsv1 | Keep (self-gating) |
| **Ovnk-specific** | 4 | fix_metallb_version, fix_kubevirt_version, fix_mocks, fix_docs_version | Keep |
| **One-time done** | 7 | fix_bounding_dirs, 4 NPA v0.2 fns, fix_kubeadm_v1beta4, fix_lint v1→v2 block | Remove when done |
| **Redundant** | 2 | fix_version_refs, fix_go_version (after GOVERSION port) | Remove |
| **Compiler-driven** | 2 | fix_klog_v2, fix_eventf | Keep |

12-14 of 26 only trigger on ovnk. Autofix stays default for production.
spec=all validates AI independence but is not the shipping criterion.
Don't remove working self-gating functions to optimize for a test mode.

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| **Model-version coupling** | Critical | The system is prompt engineering tuned to the current model. When Anthropic ships updates, pass rates silently drift. No mitigation exists beyond continuous regression testing. Acknowledge as inherent. |
| Step subagent fails to construct gate prompts | High | Spike validates on CNCC first. Pattern proven across 33 existing gates. |
| PLUGIN_ROOT not a shell env var | High | Gates keep `find`. Step files receive literal paths from Workflow. |
| Gate verdict drift at depth 2 | Medium | Spike compares depth-1 vs depth-2 verdicts on same repo state. |
| Diagnosis unverified | Medium | Inspect 1 failed ovnk transcript before implementing. |
| Orchestrator crosses 5K compaction cap | Medium | Moot — SKILL.md is ~50 lines with Workflow approach. |
| Step file extraction loses guidance | Medium | Diff extracted content against original to verify coverage. |
| Discovery procedures unreliable | High | Autofix stays default. Discovery is additive alongside autofix, not a replacement. |
| Non-deterministic gate coverage | Medium | Workflow script lists gates deterministically from `fs.readdirSync()`. |
| Wall-clock regression (+10-25 min) | Low | Net time per SUCCESS decreases (fewer wasted runs). |

## Success Criteria

- **PR-1:** spec=none: zero "missing 15+" failures. spec=all: "missing 26+"
  rate under 5%. Per-version floor 55%. Non-ovnk: no drop >15pp.
  SKILL.md under 200 tokens (thin entry point). `make lint` passes.
- **PR-2:** Within 5pp of PR-1 rate. One zero-recipe-coverage success.
- **PRs revertible in reverse order** (PR-2 first, then PR-1 if needed).

## Epistemic Caveats

This plan was produced and reviewed by ~180 AI agents. Known biases:

- **Convergence bias (proven):** ~180 agents decided "context exhaustion
  is the root cause." Transcript inspection showed the agent explicitly
  choosing to skip: *"Given the significant amount of work remaining...
  let me proceed directly to Step 5."* Even tiny repos (INF) skip —
  context exhaustion is physically impossible there. Zero compaction
  events in automated test sessions (4 found, ALL in dev sessions).
- **The root cause is dual, not singular.** The N=26 cluster (11
  failures) is triggered by autofix `RESULT: FAIL` + `exit 1`. The
  N=15 cluster (7 failures) occurs even with spec=none (autofix
  succeeds), driven by context pressure on large repos. Both are
  behavioral — the agent stops at step boundaries — but with
  different triggers.
- **Contaminated data:** The 66% and 27% figures include 42% false
  positives from the branch bug. Recompute after the branch fix.
- **The Robustness commit (Aug 8) caused a 7x rate increase** in
  missing-26+ failures (2.5% → 17.8%). Gate context reduction and
  SKILL.md restructuring may have inadvertently altered what the
  agent retains under pressure.
- **Workflow availability is uncertain.** The Workflow tool may not be
  present in all Claude Code environments. The Stop hook (~55 lines)
  is universally available and addresses both hypotheses. Use Stop
  hook as primary fix, Workflow as escalation if available.

## Not In Scope

- Multi-repo coordinator (sequencing library-go → ovnk → CNO)
- Gate consolidation (33 → ~28 gates)
- CI integration (pushing draft PRs for Prow feedback)
- Cross-repo dependency awareness (pre-flight checks)
- Operator runbook / new maintainer guide (needed before production use)
