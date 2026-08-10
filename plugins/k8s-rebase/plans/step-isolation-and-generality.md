# k8s-rebase: Step Isolation + Version-Agnostic Generality

## Executive Summary

The k8s-rebase skill automates Kubernetes dependency rebases for Go projects.
It works reliably for 5 smaller repos (90%+ pass rate) but fails on the largest
target, ovn-kubernetes (1,358 Go files, 482K LOC, 3 go.mod files). A test
measurement bug inflates the reported 45% pass rate — the true rate is well
below that (roughly 1 in 5 runs produces a correct result from the right
starting point).

This plan fixes four problems in three incremental PRs:

1. **PR1 (mechanical):** Replace 56 broken `find` calls with
   `${CLAUDE_PLUGIN_ROOT}` and fix a SKILL.md/test-harness conflict that
   causes over half of ovnk "passes" to start from the wrong git commit.

2. **PR2 (architectural):** Delegate Steps 2-4 to subagents with fresh 1M
   context each, eliminating the context exhaustion that causes 81% of ovnk
   failures ("missing 26 of 33 gates").

3. **PR3 (behavioral):** Replace version-specific fix recipes with general
   discovery procedures that read vendored source code, making the skill work
   for k8s 1.37+ with zero updates.

## Problem Statement

### Problem 1: Context Exhaustion

The skill runs in a single Claude Code session with a 1M-token context window.
For ovn-kubernetes, Step 2's compilation fix loop consumes 250-350K tokens of
build output, error investigation, and fix iterations. When compaction triggers,
SKILL.md is truncated to its first ~5K tokens. Steps 3-5 instructions (starting
at ~8K tokens) are lost. The agent never launches Steps 3-4's 26 gates.

Evidence: 81% of ovnk failures report "missing 26 of 33 gates" — exactly
Steps 1+2 gates (7) completed, Steps 3+4 gates (26) never started.

### Problem 2: Test Measurement Bug (--from-commit mode only)

SKILL.md Step 1 says "Run from the default branch (master/main)." The test
harness overrides this with "Do NOT switch to master/main" when running
historical replay tests (`--from-commit` mode). The AI non-deterministically
follows one or the other. When it follows SKILL.md and checks out master, it
rebases the wrong codebase. The resulting diff against the known-good reference
is 6,000-8,000+ hunks (vs 130-370 for correct runs).

Evidence: Over half of ovnk spec=all "passes" for k8s 1.34 and 1.35 have
6,000+ code hunks, matching the master-vs-known-good diff size exactly.
Normal production use (running from the default branch) is unaffected.

Fix: Change SKILL.md to "Run from the current branch" — which is what the
rebase script (`k8s-rebase.sh`) already does. The script works from any
starting branch; it warns when not on the default branch but does not abort.

### Problem 3: Version-Specific Recipes Rot

The autofix script (1,678 lines, 27 functions) and patterns doc (591 lines)
contain k8s 1.34-1.36-specific recipes. 53.8% of the patterns doc is already
stale. Each new k8s version requires manual updates. The main rebase script
(`k8s-rebase.sh`) is fully general — zero version-specific logic, all
parameterized from the version argument — but the autofix and patterns layers
are not.

Evidence: `spec=all` tests (autofix + patterns disabled) show the AI
independently discovers 74% of fixes from compiler errors and vendored source.
The remaining 26% need general discovery strategies, not version-pinned recipes.

### Problem 4: `find` Calls Break at Marketplace Install Depth

All 56 file-discovery calls use `find "$HOME" -maxdepth 7`. The marketplace
install path exceeds this depth. The skill silently fails to find its own
scripts and gate files when installed from the marketplace.

## Architecture: Current vs Proposed

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
claude --bg session (main agent, ~80K tokens, never compacts)
├── Step 1: inline (1 gate, trivial, ~500 tokens of work)
├── Step 2 subagent (fresh 1M) → reads steps/step2-compilation.md
│   └── fix loop + 6 gate subagents (nesting: main→step→gate)
├── Step 3 subagent (fresh 1M) → reads steps/step3-autofix.md
│   └── discovery checklist + 11 gate subagents
├── Step 4 subagent (fresh 1M) → reads steps/step4-verification.md
│   └── lint/test/review + 15 gate subagents
├── Mandatory checkpoint (inline, counts gate reports on disk)
└── Step 5: inline (PR command, ~20K tokens)
```

Nesting depth: main (0) → step subagent (1) → gate subagent (2) = 3 levels.
Default limit is 3. Verified working with local tests of the full chain.

### End-State Directory Layout

```
plugins/k8s-rebase/
├── skills/k8s-rebase/SKILL.md     # Orchestrator (~350 lines, down from 981)
├── steps/                          # NEW — step subagent instructions
│   ├── rules.md                   # Shared rules, single source of truth
│   ├── step2-compilation.md       # Matches gates/step2-compilation/
│   ├── step3-autofix.md           # Matches gates/step3-autofix/
│   └── step4-verification.md      # Matches gates/step4-verification/
├── gates/                          # UNCHANGED logic (find→PLUGIN_ROOT only)
│   ├── step1-rebase/              # 1 gate
│   ├── step2-compilation/         # 6 gates
│   ├── step3-autofix/             # 11 gates (3 renamed for process-agnosticism)
│   └── step4-verification/        # 15 gates
├── scripts/                        # UNCHANGED
├── docs/k8s-rebase-patterns.md    # Restructured in PR3 (591→~208 lines)
├── hooks/block-push.md            # UNCHANGED
├── plans/                          # This document
└── test/                           # Minor: remove 2 sed lines from mutate_plugin
```

### Token Budget (verified for ovnk worst case)

| Component | Main Agent | Step 2 | Step 3 | Step 4 | Step 5 |
|-----------|-----------|--------|--------|--------|--------|
| System + tools | 25K | 25K | 25K | 25K | 25K |
| SKILL.md / step file | 10K | 7K | 7K | 9K | 5K |
| Work output | 20K | 250-300K | 200-250K | 400-450K | 20K |
| Subagent returns / gate summaries | 10K | 6K | 11K | 15K | — |
| Overhead (conversation, tool calls) | 15K | 50K | 50K | 50K | 10K |
| **Total** | **~80K** | **~338-388K** | **~293-343K** | **~499-549K** | **~60K** |
| **% of 1M** | **8%** | **34-39%** | **29-34%** | **50-55%** | **6%** |

The main agent never approaches compaction. Each step subagent has comfortable
margin within 1M. Step 4 is the tightest at ~55% but has 450K+ headroom.

### Step Subagent Prompt Template

The orchestrator constructs this prompt for each delegated step:

```
You are executing Step {N} ({name}) of a k8s dependency rebase.

Repo: {REPO_ROOT}
Target k8s version: {VERSION}

CRITICAL RULES:
- NEVER run go mod tidy, go get, go mod vendor, go mod edit, go generate, go run
- NEVER run git push or gh pr create
- All commits: git commit --signoff
- Every change must be directly required by the k8s version bump
- Do NOT launch subagents that launch their own subagents

Plugin root: {CLAUDE_PLUGIN_ROOT}
Read `{CLAUDE_PLUGIN_ROOT}/steps/{step_file}` and follow ALL its instructions.
Also read `{CLAUDE_PLUGIN_ROOT}/steps/rules.md` for shared rules.
Gate directory: {CLAUDE_PLUGIN_ROOT}/gates/{gate_dir}/
Gate report helper: {CLAUDE_PLUGIN_ROOT}/scripts/write-gate-report.sh

When done, report:
STEP_VERDICT: COMPLETE|PARTIAL|FAILED
GATES_PASSED: X/{expected}
GATES_FAILED: Y
COMMITS: N
ISSUES: [any unresolved items]
```

Variables are resolved in the orchestrator's bash block before the prompt is
passed to the Agent tool. The step subagent receives literal paths, not
variable references.

## Key Design Decisions

### Why Steps 1 and 5 stay inline

Step 1 runs one script (via nohup, context-cheap) and one gate. Delegating it
adds 30 seconds of overhead for ~500 tokens of context savings. The exit-code
routing (0=stop, 1=error, 2=proceed) is 5 lines of orchestrator logic.

Step 5 generates the PR command — the user-facing deliverable. If it runs in a
subagent, the main agent must relay the output. A file-based handoff
(`.rebase-tmp/pr-command.txt`) works but adds complexity for a step that uses
~20K tokens and has zero context pressure.

### Why `${CLAUDE_PLUGIN_ROOT}` instead of `find`

The `find "$HOME" -maxdepth 7` pattern has four problems: (1) breaks when the
plugin is installed deeper than 7 levels from `$HOME`, (2) scans 1.3M files
taking 44 seconds across 56 calls, (3) can match stale plugin copies in
`~/.claude/jobs/*/tmp/`, (4) `mutate_plugin` must patch 2 of 56 calls with
fragile sed. `CLAUDE_PLUGIN_ROOT` is set by `--plugin-dir` (which the test
harness already passes), resolves instantly, and the mutated-copy case works
automatically. 10+ other plugins in this marketplace use this pattern.

### Why autofix stays as default, spec=all for testing

The autofix script handles 27 fix patterns in ~8 seconds. The AI reasoning to
discover the same fixes takes 10-20 minutes and misses 26% of patterns —
specifically the ones with no compiler signal: feature gates that cause silent
runtime hangs, CRD validation that causes silent API server rejection, kubeadm
config that is silently ignored. For production, autofix runs first, AI fills
gaps. `spec=all` (autofix disabled) validates that the AI CAN work
independently — the target for future-proofing.

### Why not split the autofix into multiple files

The 1,678-line script is well-organized with clear section markers and a header
catalog. `source`-based splitting creates invisible variable coupling
(`GATE_DEPS` is an associative array that cannot be exported). `mutate_plugin`
would need to search 3 files instead of 1. Section comments marking permanent
vs migration functions provide the same organizational benefit without the
coupling risk.

### Why discovery procedures instead of recipes

The 6-step discovery procedure for Step 2 reads vendored `// Deprecated:`
comments to find replacements. This is self-correcting — it reads the actual
vendored code that was just bumped, not a stale recipe. The procedure works
for any k8s version because the vendored source IS the migration guide.

For the 6 patterns the AI can't discover from compilation errors alone, the
step files encode general strategies that check vendored code state rather
than hardcoded version numbers:

1. **Feature gates** (runtime hang, no compile error) → parse
   `vendor/k8s.io/client-go/features/known_features.go` for Default:true gates
2. **kubeadm v1beta4** (silent config ignore) → check vendored kubeadm API
   version, convert extraArgs format if needed
3. **CRD int64 validation** (API server rejection) → check for
   `format: int32` preceding `maximum: 4294967295`
4. **CRD name validation** (codegen strips hand-edits) → diff CRD metadata
   blocks against base branch
5. **ObservedGeneration** (conformance assertion) → check if status condition
   updates set the field
6. **RelaxedServiceNameValidation** (version-dependent gate) → check if gate
   exists in vendored code and whether it is default-on

## Autofix Function Disposition

From per-function analysis of all 27 functions across 6 repos and 3 versions:

| Category | Count | Functions | Action |
|----------|-------|-----------|--------|
| **Evergreen** | 5 | fix_feature_gates, fix_kind_image, fix_kind_version, fix_lint_version (bump), fix_imports | Keep permanently |
| **Permanent** | 4 | fix_reflect_ptr (AI has no signal), fix_crd_int64_validation, fix_crd_name_validation, fix_addtoscheme (recurring, k8s migrates incrementally) | Keep permanently |
| **Accelerator** | 2 | fix_xexp, fix_fieldsv1 | Keep (self-gating, AI discovers but slower) |
| **Ovnk-specific** | 3 | fix_metallb_version, fix_kubevirt_version, fix_mocks | Keep (harmless no-op on other repos; metallb has a FRR sed bug, mocks has a trigger bug) |
| **One-time done** | 8 | fix_bounding_dirs, fix_lint v1→v2, fix_relaxed_svc_name, 4 NPA v0.2 functions, fix_kubeadm_v1beta4 | Remove when all repos past target version |
| **Redundant** | 3 | fix_version_refs, fix_go_version, fix_docs_version | Remove (rebase script Phase 3 does same work) |
| **Compiler-driven** | 2 | fix_klog_v2, fix_eventf | Keep as accelerators |

Key finding: **19 of 27 functions only trigger on ovn-kubernetes.** The autofix
is essentially an ovnk-specific accelerator with 8 universal functions mixed in.

**run_checks() disposition** (the 18 diagnostic checks that run before/after fixes):
- 12 are PERMANENT diagnostics (feature gates 3 layers, x/exp, reflect.Ptr,
  FieldsV1, major-version imports, bare Eventf, CRD format, CRD name,
  uncommitted changes)
- 4 are STALE/repo-specific (conformance old names, conformance addtoscheme,
  stale docs ver, e2e test fixes missing) — all ovnk-specific one-time checks
- 2 are NPA-ecosystem-specific (ObsGen, AddToScheme in factory)

## Patterns Doc Disposition

| Category | Count | % | Action |
|----------|-------|---|--------|
| Permanent-recurring | 5 | 19% | Keep (cross-repo deps, feature gates, vendor, lint, ST1005) |
| Permanent-conditional | 7 | 27% | Keep (CRDs, KubeVirt, operator-sdk, OTE, controller-gen) |
| One-time done | 3 | 12% | Remove (AddToScheme, x/exp, KubeVirt IPv6) |
| Version-specific stale | 11 | 42% | Remove (9 are k8s 1.36-specific, 2 are k8s 1.35) |

Restructure from 591 → ~208 lines. Organize by pattern class (Go API Breakage,
Feature Gates, CRD Validation, CI Infrastructure) instead of by k8s version.
Caveat: test harness `TAG_TO_PATTERN` has hardcoded `### heading` names —
must update in the same commit.

## Implementation: 3 PRs Ordered by Risk

### PR1: `CLAUDE_PLUGIN_ROOT` + branch fix (mechanical, low risk)

- Replace 56 `find` calls with `${CLAUDE_PLUGIN_ROOT}` paths in SKILL.md +
  33 gate files
- Fix SKILL.md line 87: "Run from the default branch" → "Run from the current
  branch" (fixes the test measurement bug for `--from-commit` tests)
- Remove `mutate_plugin`'s 2 `sed` commands (PLUGIN_ROOT handles it)
- Port 2 `GOVERSION` sed patterns from fix_go_version to k8s-rebase.sh Phase 3
- Add section comments to autofix marking permanent vs migration functions
- Version bump to 0.3.0, `make update`

**Validation:** `make lint`, then `make matrix version=1.36 spec=all`. The
`find` replacement is a behavioral no-op for development paths. The branch fix
should eliminate all 6,000+ hunk passes.

### PR2: Step delegation (architectural, medium risk)

- Create `steps/` directory: rules.md, step2-compilation.md,
  step3-autofix.md, step4-verification.md
- Rewrite SKILL.md to ~350-line orchestrator (Steps 1+5 inline, 2-4 delegated)
- Post-step gate verification uses `find`-based counting (zsh-compatible)
- Robustness improvements:
  - Oscillation detection: stop if a previously-passed gate regresses after
    fixing a different gate
  - Dirty-tree check: `git status --porcelain` at start of each gate-fix loop
  - Gate wave splitting: Step 4 launches 15 gates first, then test agents
    (stays under 20 concurrent subagent limit)
  - Tighten checkpoint: detect "not PASS" instead of just "is FAIL" (catches
    malformed reports)
  - Normalize Step 3 gate-fix loop: add `validate.sh --quick` between fix and
    gate re-run (Steps 2 and 4 already do this)
  - Broaden go.mod check: SKILL.md line 104 currently only accepts root-level
    go.mod — use `find`

**Validation:** `make matrix` for all 3 versions. Target: ovnk pass rate
above 80% across 10+ runs. Non-ovnk repos must maintain current ~100% rate.

### PR3: Discovery procedures + cleanup (behavioral, highest risk)

- Replace version-specific recipes in step files with discovery procedures
- Restructure patterns doc (591 → ~208 lines), update TAG_TO_PATTERN
- Remove 3 redundant + 2 completed autofix functions
- Rename 3 gates for spec=all compatibility (autofix-result → fix-verification,
  autofix-diff-review → fix-diff-review, update dep-release-notes)
- Generalize fix_feature_gates toward self-discovering GATE_DEPS (env var
  layers can be fully self-discovering; SetFromMap layer needs a minimal
  curated list or a two-file awk pass to resolve gate dependencies)

**Validation:** `make matrix spec=all` for all 3 versions. This tests the AI's
independent capability without autofix or patterns doc.

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Step subagent fails to construct 6-15 gate prompts correctly | High | Test on CNCC first (6 gates, fast feedback). The gate file indirection pattern is proven (33 gates already work this way). The step subagent just needs to iterate .md files in the gate dir and launch one Agent per file. |
| Step 2 subagent also exhausts 1M context for ovnk | Medium | Budget is ~340K/1M (34%). Even with worst-case gate-fix loops at 2x, 680K is within 1M. Checkpoint protocol lets subagent write state to disk before reporting PARTIAL. |
| Cross-repo dependency ordering not addressed | Medium | This plan operates on one repo at a time. library-go must merge its k8s bump before CNO can compile. The SKILL.md already documents this ("check for active upstream rebase PR, add replace directive"). A multi-repo coordinator is a future improvement, not a blocker for single-repo reliability. |
| `CLAUDE_PLUGIN_ROOT` not inherited by gate subagents | Low | Verified locally: subagents at depth 2 resolve `$HOME` and env vars correctly. Gate .md files resolve the variable in bash blocks before use. |
| First run reveals prompt construction bugs | Medium | Most likely: subagent trying to literally read `{CLAUDE_PLUGIN_ROOT}` as a path instead of the resolved value. Fix: ensure variable substitution happens in orchestrator bash block, not in prompt text. |
| Discovery procedures unreliable for novel k8s changes | High | Keep autofix as default for production. Discovery procedures are for `spec=all` testing only. Gate companion `.sh` scripts provide mechanical verification regardless of who did the fixing. |
| Feature gate self-discovery has a SetFromMap dependency trap | Medium | Disabling an irrelevant gate via env var is a no-op. But SetFromMap validates parent-dependent gates — disabling a parent without its deps causes an error that fails the entire call. Need two-file awk pass (known_features.go + kube_features.go) or keep a minimal curated list for SetFromMap only. |
| Patterns doc restructure breaks TAG_TO_PATTERN | Medium | Must update test harness `TAG_TO_PATTERN` in the same commit. Heading renames are a known coupling point. |
| This plan is over-engineered (100 agents, 0 lines of code) | Valid concern | PR1 is a mechanical find-and-replace. Ship it in hours, validate immediately. PR2 and PR3 are separable — if PR1 alone improves rates, defer the rest. |

## Success Criteria

- **PR1:** Zero 6,000+ hunk passes in 10 ovnk runs (branch fix works).
  All non-ovnk repos continue passing.
- **PR2:** ovnk spec=all pass rate ≥80% across 10+ runs (context fix works).
  Non-ovnk repos maintain ~100% recent rate.
- **PR3:** ovnk spec=all pass rate maintained across k8s 1.34, 1.35, 1.36
  with discovery procedures (version-agnosticism works).
- **All PRs:** `make lint` passes. `make matrix` shows no regressions.

## Not In Scope

- Multi-repo coordinator (sequencing library-go → ovnk → CNO)
- Gate consolidation (33 → ~28 gates)
- Informational gate naming convention (`info-` prefix)
- "step" → "stage" terminology rename
- go.sum integrity gate, replace directive audit gate
