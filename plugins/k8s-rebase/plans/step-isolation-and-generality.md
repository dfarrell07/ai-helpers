# k8s-rebase: Step Isolation + Version-Agnostic Generality

## Executive Summary

The k8s-rebase skill automates Kubernetes dependency rebases for Go projects.
It works reliably for 5 smaller repos (90%+ pass rate) but fails on the
largest target, ovn-kubernetes (1,358 Go files, 482K LOC, 3 go.mod files).
After correcting for a test measurement bug, the true ovnk pass rate is
~27% (13/49 genuine passes). A critical correlation: every "missing 26 of
33 gates" failure is a `spec=all` run — when autofix is disabled, it reports
`RESULT: FAIL` with `exit 1`, and the agent misinterprets this as terminal,
skipping Steps 3-5 entirely.

The root cause is specific: the autofix script prints `RESULT: FAIL` with
`exit 1`, and the agent rationally interprets these as "stop" signals,
ignoring prose instructions to continue. The fix is a **graduated ladder**:

1. **Level 2 fix (2-4 hours, try first):** Change autofix to `exit 0` +
   rename output from FAIL to ITEMS_REMAINING + restructure SKILL.md to
   put "proceed" instruction before (not after) the autofix bash block +
   add PostToolUse and Stop hooks. Estimated fix rate: 75-85%.

2. **Level 3 (3-5 days, only if Level 2 insufficient):** Deterministic
   Workflow script orchestrating step subagents. The AI can't skip steps
   because a JavaScript for-loop runs each step regardless.

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

### Problem 1: Agent Skips Steps 3-5 (NOT Context Exhaustion)

**Root cause (verified from session transcripts):** The agent misinterprets
the autofix FAIL result as terminal and jumps directly to Step 5, skipping
Steps 3-4 entirely. The context window is intact — the agent CHOOSES to
stop, ignoring three explicit anti-skip instructions in SKILL.md.

Evidence: Session `fdf1e3a9` (Aug 8, "missing 26 of 33 gates") shows
the agent completing Step 2 gates, receiving autofix FAIL ("9 categories
it couldn't auto-fix"), then immediately generating the PR command without
running Steps 3-4. Zero compaction events were found in 1,455 rebase
sessions across all repos.

**Why spec=all is worse:** In spec=all, autofix functions are neutered and
always report FAIL. The agent treats this FAIL as "nothing more to do."
In spec=none, autofix actually fixes things and reports meaningful results,
so the agent continues.

**Why non-ovnk repos also fail:** CNO, CNCC, and INF show "missing 26/32
gates" on Aug 8-9. These repos would never exhaust 1M context. Same
mechanism: the agent stops early regardless of repo size.

**Earlier hypothesis was wrong:** ~180 agents converged on "context
exhaustion causes missing gates" based on circumstantial evidence (failure
patterns matching the compaction boundary). Actual transcript inspection
disproved this — the real cause is behavioral (agent skips steps), not
resource-based (context runs out).

**Why step delegation still helps:** A Workflow script deterministically
sequences steps. The AI can't "choose" to skip Steps 3-5 because the
JavaScript for-loop runs each step regardless of the previous step's
verdict. Gate counting happens in deterministic code. This is structural
enforcement of the workflow, not a compaction workaround.

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
  is the root cause." The diagnosis agent examined actual session
  transcripts and found zero compaction events — the agent was CHOOSING
  to skip steps, not running out of context. The entire compaction model
  (5K cap, 83.5% trigger, token budgets) was wrong. This is the strongest
  evidence that AI-reviewing-AI work has systematic blind spots.
- **The architecture is right for the WRONG reason.** Step delegation was
  designed to prevent compaction. It actually prevents step-skipping —
  a Workflow for-loop runs each step regardless of the AI's decision to
  stop. The fix works; the justification was backwards.
- **Contaminated data:** The 66% and 27% figures are computed from data
  that includes 42% false positives. After the branch fix, recompute.
- **Simpler alternatives exist:** Before the full Workflow, a bash-enforced
  gate count check after Step 2 might be sufficient to prevent premature
  step-skipping. This is a 10-line fix vs a multi-day restructure.

## Not In Scope

- Multi-repo coordinator (sequencing library-go → ovnk → CNO)
- Gate consolidation (33 → ~28 gates)
- CI integration (pushing draft PRs for Prow feedback)
- Cross-repo dependency awareness (pre-flight checks)
- Operator runbook / new maintainer guide (needed before production use)
