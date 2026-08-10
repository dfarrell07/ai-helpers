# k8s-rebase: Step Isolation + Version-Agnostic Generality

## Executive Summary

The k8s-rebase skill automates Kubernetes dependency rebases for Go projects.
It works reliably for 5 smaller repos (90%+ pass rate) but fails on the
largest target, ovn-kubernetes (1,358 Go files, 482K LOC, 3 go.mod files).
After correcting for a test measurement bug, the true ovnk pass rate is
~27% (13/49 genuine passes). A critical correlation: every "missing 26 of
33 gates" failure is a `spec=all` run — autofix-disabled tests consume far
more context in Step 2, triggering compaction earlier and losing Steps 3-5.

This plan fixes four problems across four incremental PRs:

1. **PR-0 (2 min):** Fix SKILL.md lines 87 and 94 — change "Run from the
   default branch" to "Run from the current branch." Eliminates 42% false
   positive test passes.

2. **PR-A (1-2 days):** Delegate Steps 2-4 to subagents with fresh 1M
   context each. Uses existing battle-tested `find` patterns. Eliminates
   the context exhaustion that causes 66% of ovnk failures.

3. **PR-B (0.5 day):** Migrate `find` calls to `${CLAUDE_PLUGIN_ROOT}` in
   SKILL.md and step files only (NOT in gate files — gates receive literal
   paths from step prompts). Fixes the marketplace install depth bug.

4. **PR-C (1-2 days):** Replace version-specific recipes with general
   discovery procedures. Restructure patterns doc (591 → ~208 lines).

## Key Concepts

- **Gate:** A `.md` file under `gates/step{N}-*/` defining one quality check.
  A subagent reads it, runs the check, writes a PASS/FAIL `.report` to disk.
  There are 33 gates across Steps 1-4.
- **Step subagent:** A fresh Claude agent that executes an entire rebase phase
  (e.g., all compilation fixes). Gets its own 1M context window.
- **Gate subagent:** A smaller agent launched by the step subagent to evaluate
  one specific gate. Also gets fresh context.
- **spec=all / spec=none:** Test modes. `spec=all` disables the autofix script
  and strips the patterns doc, forcing the AI to discover fixes independently.
  `spec=none` runs the full skill as-is (production mode).
- **Compaction:** At ~83.5% context usage, Claude Code summarizes the
  conversation and re-injects each skill with a hard 5,000-token cap. Content
  beyond 5K tokens is lost. Steps 3-5 start at ~5,147 tokens in the current
  SKILL.md — just past the cap.
- **`CLAUDE_PLUGIN_ROOT`:** A text-substitution token resolved by Claude Code
  in plugin-registered files (SKILL.md, commands, hooks). NOT available as a
  shell environment variable. Does NOT resolve in arbitrary files read via
  the Read tool (including gate `.md` files).

## Problem Statement

### Problem 1: Context Exhaustion

The skill runs in a single session with a 1M-token context window. For
ovn-kubernetes, Step 2's compilation fix loop consumes 250-350K tokens.
When compaction triggers (~835K), SKILL.md is re-injected with a hard
5,000-token cap. Steps 3-5 instructions (starting at ~5,147 tokens) are
lost. The agent never launches Steps 3-4's 26 gates.

Evidence: 66% of all ovnk failures (80% of recent failures) report "missing
N of 33 gates." The distribution peaks at N=26 (Steps 1+2 completed, 3+4
never started) and N=15 (Steps 1-3 completed, Step 4 never started).

**Critical correlation:** Every "missing 26 of 33 gates" failure is a
`spec=all` run. Zero `spec=none` runs exhibit this pattern. Without autofix,
Step 2 performs 10-20 minutes of exploratory discovery, consuming far more
context and triggering compaction before Steps 3-5 can start.

### Problem 2: Test Measurement Bug (`--from-commit` mode only)

SKILL.md Step 1 says "Run from the default branch (master/main)." The test
harness overrides this for historical replay tests. The AI non-deterministically
follows one or the other, producing 6,000-8,000+ hunk diffs against known-good
when it starts from master instead of the test branch.

Evidence: 42% of ovnk spec=all "passes" (11/26) have 6,000+ code hunks.
Normal production use is unaffected. Fix: change SKILL.md to "Run from the
current branch" — which is what `k8s-rebase.sh` already does.

### Problem 3: Version-Specific Recipes Rot

The autofix script (1,678 lines) and patterns doc (591 lines, 53.8% stale)
contain k8s 1.34-1.36-specific recipes. The main rebase script
(`k8s-rebase.sh`) is fully general — zero version-specific logic. `spec=all`
tests show the AI independently discovers 74% of fixes; the remaining 26%
need general discovery strategies, not version-pinned recipes.

### Problem 4: `find` Calls Break at Marketplace Install Depth

All 50 file-discovery calls use `find "$HOME" -maxdepth 7`. The marketplace
install path exceeds this depth. The skill silently fails when installed
from the marketplace.

## Architecture

### Current (monolithic, 981-line SKILL.md)

```
claude --bg session (single 1M context)
└── SKILL.md orchestrates Steps 1-5 sequentially
    ├── Step 1: run script, 1 gate subagent
    ├── Step 2: fix loop (250-350K tokens for ovnk), 6 gate subagents
    ├── Step 3: run autofix, 11 gate subagents          ← LOST after compaction
    ├── Step 4: lint/test/review, 15 gate subagents     ← LOST after compaction
    └── Step 5: generate PR command                     ← LOST after compaction
```

### Proposed (orchestrator + step subagents)

```
claude --bg session (main agent, ~54K tokens, never compacts)
├── Step 1: inline (1 gate, trivial)
├── Step 2 subagent (fresh 1M) → reads steps/step2-compilation.md
│   └── fix loop + 6 gate subagents (nesting: main→step→gate)
├── Step 3 subagent (fresh 1M) → reads steps/step3-autofix.md
│   └── discovery checklist + 11 gate subagents
├── Step 4 subagent (fresh 1M) → reads steps/step4-verification.md
│   └── lint/test/review + 15 gate subagents
├── Mandatory checkpoint (inline, counts gate reports on disk)
└── Step 5: inline (PR command)
```

Nesting: main (0) → step (1) → gate (2) = 3 levels, within default limit.

### End-State Directory Layout (after all 4 PRs)

```
plugins/k8s-rebase/
├── .claude-plugin/plugin.json     # Version bumped
├── skills/k8s-rebase/SKILL.md     # Orchestrator (~350 lines, down from 981)
├── steps/                          # NEW — step subagent instructions
│   ├── rules.md                   # Shared rules, single source of truth
│   ├── step2-compilation.md       # Matches gates/step2-compilation/
│   ├── step3-autofix.md           # Matches gates/step3-autofix/
│   └── step4-verification.md      # Matches gates/step4-verification/
├── gates/                          # Keep existing find patterns (NOT PLUGIN_ROOT)
│   ├── step1-rebase/              # 1 gate
│   ├── step2-compilation/         # 6 gates
│   ├── step3-autofix/             # 11 gates (3 renamed in PR-C)
│   └── step4-verification/        # 15 gates
├── scripts/                        # UNCHANGED
├── docs/k8s-rebase-patterns.md    # Restructured in PR-C (591→~208 lines)
├── hooks/block-push.md            # UNCHANGED
├── plans/                          # This document
└── test/                           # Minor cleanup in mutate_plugin
```

### Token Budget (estimated for ovnk worst case)

| Component | Main Agent | Step 2 | Step 3 | Step 4 |
|-----------|-----------|--------|--------|--------|
| System + tools | 25K | 25K | 25K | 25K |
| Instructions | 10K | 7K | 7K | 9K |
| Work + gates + overhead | 19K | 272-327K | 123-203K | 85-377K |
| **Total** | **~54K** | **~304-359K** | **~155-235K** | **~119-411K** |
| **% of 1M** | **5%** | **30-36%** | **16-24%** | **12-41%** |

Step 5 runs inline in the main agent (~47K additional). All steps have
comfortable margin. Step 4 is the widest range due to variable test output.

### Step Subagent Prompt Template

```
You are executing Step {N} ({name}) of a k8s dependency rebase.

Repo: {REPO_ROOT}
Target k8s version: {VERSION}
Arguments: {ARGUMENTS}

Run `git log --oneline $(git merge-base HEAD master 2>/dev/null ||
git merge-base HEAD main)..HEAD` to understand what previous steps did.

CRITICAL RULES:
- NEVER run go mod tidy, go get, go mod vendor, go mod edit,
  go generate, go run
- NEVER run git push or gh pr create
- All commits: git commit --signoff
- Every change must be directly required by the k8s version bump
- Your subagents (gates, investigation helpers) must NOT launch
  their own subagents — nesting limit is 3 (main → step → your subagent)

Read `{STEPS_DIR}/rules.md` FIRST for shared rules.
Then read `{STEPS_DIR}/{step_file}` and follow ALL its instructions.
Gate directory: {GATE_DIR}
Gate report helper: {GATE_REPORT_SCRIPT}

Write your status to `.rebase-tmp/step{N}-status.json` when done.
If you defer any issues, list them in `.rebase-tmp/deferred.txt`
(one per line).
```

Variables are resolved in the orchestrator's bash block before passing
to the Agent tool. Step and gate files receive literal paths, not
variable references. `${CLAUDE_PLUGIN_ROOT}` resolves only in SKILL.md
(text substitution); step/gate files use the literal paths from the prompt.

### Recovery Protocol

```
MAX_ATTEMPTS = 2  # per step (initial + one retry)

for step in [2, 3, 4]:
    check: git status --porcelain (abort if dirty)
    passed_before = set(gate_names_with_pass_report(step))

    for attempt in 1..MAX_ATTEMPTS:
        persist attempt count to .rebase-tmp/step{N}-attempts
        verdict = launch_step_subagent(step, skip_gates=passed_before)

        passed_after = set(gate_names_with_pass_report(step))
        regression = passed_before - passed_after

        if regression:
            log("Gate regression: " + regression); break
        if verdict == COMPLETE and all gates pass:
            break
        if step == 2 and verdict == FAILED and HEAD unchanged:
            abort("Step 2 structural failure")
        if made_progress and attempt < MAX_ATTEMPTS:
            passed_before = passed_after; continue
        log_unresolved(step); break

run_mandatory_checkpoint()
```

Disk is the source of truth. The step subagent writes
`.rebase-tmp/step{N}-status.json` (machine-readable gate counts).
The orchestrator reads this file, not the subagent's text response.

## Implementation: 4 PRs Ordered by Risk

### PR-0: Branch fix (2 min, ship immediately)

- Fix SKILL.md line 87: "Run from the default branch" → "Run from the
  current branch"
- Fix SKILL.md line 94: remove master checkout from recovery instruction
- Version bump (patch)

**Validation:** 10 ovnk `--from-commit` runs. Every PASS must have <500
code hunks. Verify starting SHA matches `--from-commit` value.

### PR-A: Step delegation (1-2 days, high impact)

Step files use existing `find` patterns (battle-tested, not PLUGIN_ROOT).

- Create `steps/`: rules.md, step2-compilation.md, step3-autofix.md,
  step4-verification.md
- Rewrite SKILL.md to ~350-line orchestrator (Steps 1+5 inline, 2-4
  delegated). Keep orchestrator under 4,500 tokens (5K compaction cap
  minus margin).
- Recovery protocol with disk-based iteration counters, oscillation
  detection (gate name sets, not counts), dirty-tree checks
- Step subagent writes `.rebase-tmp/step{N}-status.json`
- Step subagent reads `.rebase-tmp/deferred.txt` from prior steps
- Gate wave splitting: Step 4 launches 15 gates first, then test agents
- Step 4 gate-fix re-validation uses `--quick` (not `--no-test`)
- Tighten mandatory checkpoint: detect "not PASS" (catches malformed)
- Pass `$ARGUMENTS` through step prompt (Step 4d needs `--bump-tools`)
- Pre-launch variable validation before each Agent call
- Remove dead `mutate_plugin` sed lines from test harness

**Validation:** 20+ runs per version. Zero "missing 15+ of 33 gates"
failures in `spec=none`. "missing 26+" rate drops below 5% in `spec=all`.
Per-version floor: no version below 55%. Non-ovnk repos: no drop >15pp.
Runs spread across 5+ calendar days.

**Rollback:** `git revert`. Orphaned `steps/` is harmless.

### PR-B: PLUGIN_ROOT migration (0.5 day)

- Replace 12 `find` calls in SKILL.md with `${CLAUDE_PLUGIN_ROOT}`
- Step files use literal paths received from the orchestrator prompt
  (PLUGIN_ROOT resolves only in SKILL.md, not in files read via Read tool)
- Gate `.md` files keep existing `find` patterns (PLUGIN_ROOT is NOT a
  shell env var — it does not resolve in gate bash blocks)
- Port 2 `GOVERSION` sed patterns to k8s-rebase.sh Phase 3

**Validation:** Within 5pp of PR-A rate. Verify PLUGIN_ROOT resolves
in SKILL.md. Verify gates still find companion `.sh` scripts.

**Rollback:** `git revert`. Step files revert to `find`.

### PR-C: Discovery procedures + cleanup (1-2 days)

- Replace version-specific recipes with discovery procedures in step files
- Feature gate discovery: parse 2-3 files (client-go `known_features.go` +
  kubernetes `kube_features.go` + dependency map)
- kubeadm discovery: indirect paths (version correlation, file inspection,
  extraArgs format detection) — NOT "check vendored kubeadm" (it's not vendored)
- Restructure patterns doc (591 → ~208 lines), update `TAG_TO_PATTERN`
- Rename 3 gates for process-agnosticism
- Remove completed autofix functions after verifying all repos past target

**Validation:** Within 5pp of PR-A rate. At least 1 successful zero-recipe run.
Gate renames + TAG_TO_PATTERN in one squashable commit.

**Rollback:** `git revert`. Verify TAG_TO_PATTERN consistency.

## Autofix Function Disposition

26 functions (fix_lint_version counted once, fix_uncommitted excluded as
a commit helper):

| Category | Count | Functions | Action |
|----------|-------|-----------|--------|
| **Evergreen** | 6 | fix_feature_gates, fix_kind_image, fix_kind_version, fix_lint_version, fix_imports, fix_relaxed_svc_name (bidirectional version guard) | Keep permanently |
| **Permanent** | 4 | fix_reflect_ptr (AI has no signal), fix_crd_int64_validation, fix_crd_name_validation, fix_addtoscheme | Keep permanently |
| **Accelerator** | 2 | fix_xexp, fix_fieldsv1 | Keep (self-gating) |
| **Ovnk-specific** | 4 | fix_metallb_version, fix_kubevirt_version, fix_mocks, fix_docs_version | Keep (harmless no-op elsewhere) |
| **One-time done** | 7 | fix_bounding_dirs, 4 NPA v0.2 fns, fix_kubeadm_v1beta4, fix_lint v1→v2 block | Remove when all repos past target |
| **Redundant** | 2 | fix_version_refs, fix_go_version (after PR-B ports GOVERSION) | Remove |
| **Compiler-driven** | 2 | fix_klog_v2, fix_eventf | Keep as accelerators |

12-14 of 26 functions only trigger on ovn-kubernetes. The autofix is
primarily an ovnk-specific accelerator with ~12 universal functions.

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Step subagent fails to construct gate prompts | High | Test on CNCC first. Gate indirection pattern proven across 33 gates. |
| Gate verdict drift at depth 2 | Medium | Run 5 gates in both configs (depth 1 vs 2), compare verdicts. Focus on judgment gates. |
| Non-deterministic gate coverage | Medium | Make step files prescriptive about exact gate-listing bash. Minimize AI discretion in mechanical parts. |
| PLUGIN_ROOT not a shell env var | High | Gates keep `find` patterns (PR-B). Step files receive literal paths from orchestrator prompt. |
| Orchestrator crosses 5K compaction cap | Medium | Lint rule: fail above 4,500 tokens. Add 5-line fallback in CLAUDE.md. |
| Shared skill budget (25K across all plugins) | Low | Other skills rarely invoked in rebase sessions. |
| Cost multiplication (~2-3x per run) | Medium | Expected: $30-60 → $60-150/run. Offset by fewer wasted runs. |
| Wall-clock regression (+10-25 min) | Low | 7-17% overhead. Net time per SUCCESS decreases (fewer wasted runs). |
| Discovery procedures unreliable for novel changes | High | Autofix stays default for production. spec=all for testing only. |
| This plan is over-engineered | Valid | PR-0 ships in minutes. PR-A is separable. Each PR is independently revertible. |

## Success Criteria

- **PR-0:** Zero 6,000+ hunk passes. Starting SHA matches --from-commit.
- **PR-A:** Zero "missing 15+" failures (spec=none, 20+ runs). "missing 26+"
  rate under 5% (spec=all). Per-version floor 55%. Non-ovnk no drop >15pp.
  Orchestrator SKILL.md under 4,500 tokens.
- **PR-B:** Within 5pp of PR-A rate. Zero PLUGIN_ROOT references in gate files.
- **PR-C:** Within 5pp of PR-A rate. One zero-recipe-coverage success.
- **All PRs:** `make lint` passes. Each PR independently revertible.

## Not In Scope

- Multi-repo coordinator (sequencing library-go → ovnk → CNO)
- Gate consolidation (33 → ~28 gates)
- Informational gate naming convention (`info-` prefix)
- "step" → "stage" terminology rename
- go.sum integrity gate, replace directive audit gate
