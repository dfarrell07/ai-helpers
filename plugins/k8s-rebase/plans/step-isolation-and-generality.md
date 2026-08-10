# k8s-rebase: Step Isolation + Version-Agnostic Generality

## Executive Summary

The k8s-rebase skill automates Kubernetes dependency rebases for Go projects.
It works reliably for 5 smaller repos (90%+ pass rate) but fails on the
largest target, ovn-kubernetes (1,358 Go files, 482K LOC, 3 go.mod files).
After correcting for a test measurement bug, the true ovnk pass rate is
~27% (13/49 genuine passes). A critical correlation: every "missing 26 of
33 gates" failure is a `spec=all` run — autofix-disabled tests consume far
more context in Step 2, triggering compaction earlier and losing Steps 3-5.

The fix: delegate Steps 2-4 to subagents with fresh 1M context each,
orchestrated by a **deterministic Workflow script** (not AI-interpreted
prose). This eliminates both the context exhaustion problem and the
non-determinism of having an AI manage a state machine.

**Before investing days: do a 2-hour spike.** Validate the fundamentals
(depth-2 gates, step file reading) on the smallest repo before writing
the full implementation.

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
    ├── Step 3: autofix + 11 gates               ← LOST after compaction
    ├── Step 4: lint/test/review + 15 gates       ← LOST after compaction
    └── Step 5: generate PR command               ← LOST after compaction
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

## Implementation

### Before Starting: 2-Hour Spike

Validate the two biggest risks before investing days:

1. Write minimal `step2-compilation.md` (extract Step 2 from SKILL.md)
2. Write bare-bones Workflow that launches Step 2 as a single agent
3. Run once on CNCC (smallest repo, fastest cycle)
4. Verify: step subagent reads file, gate subagents at depth 2 produce
   correct verdicts, gate reports land in `.rebase-tmp/gates/`
5. Compare gate verdicts at depth 2 vs depth 1 (current architecture)

If the spike works, proceed. If depth-2 gates produce different verdicts,
investigate before investing further.

### PR-1: Delegation + branch fix + PLUGIN_ROOT (3-5 days)

Fold the branch fix and PLUGIN_ROOT migration into the delegation PR.
Writing step files with `find` patterns then replacing with PLUGIN_ROOT
is writing them twice — use PLUGIN_ROOT from the start in SKILL.md,
pass literal paths to step subagents.

- Fix SKILL.md lines 87 and 94 (branch wording)
- Create `workflows/k8s-rebase.js` (~150-200 lines)
- Create `steps/`: rules.md + 5 step files
- Rewrite SKILL.md to ~50-line entry point
- SKILL.md uses `${CLAUDE_PLUGIN_ROOT}`, resolves paths, invokes Workflow
- Gate `.md` files keep existing `find` patterns (PLUGIN_ROOT is NOT
  a shell env var)
- Step files receive literal paths from Workflow agent prompts
- Port 2 `GOVERSION` sed patterns + grep alternation to k8s-rebase.sh
- Add section comments to autofix (permanent vs migration)
- Version bump, `make update`

**The hardest part:** Extracting 981 lines into 5 self-contained step
files without losing any guidance. Each step file must include every
rule, warning, and edge case that applies to that step — the step
subagent has never seen SKILL.md.

**Validation (phased, 15-25 runs total):**
- Phase 0: Shell unit tests for Workflow logic (gate counting, path
  validation) — zero API cost
- Phase 1: 3 ovnk spec=all 1.36.2 — if all 3 produce Steps 3-4 gate
  reports, delegation works
- Phase 2: 3 spec=none per version — verify zero "missing 15+"
- Phase 3: 1 per non-ovnk repo — regression check

**Primary success metric:** spec=none (production mode). Target: zero
"missing 15+ of 33 gates" failures. spec=all is a diagnostic signal,
not the shipping criterion.

**Rollback:** `git revert`. Orphaned `steps/` and `workflows/` are harmless.

### PR-2: Discovery procedures + cleanup (1-2 days)

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
