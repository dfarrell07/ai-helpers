# k8s-rebase: Step Isolation + Version-Agnostic Generality

## Executive Summary

The k8s-rebase skill automates Kubernetes dependency rebases for Go projects.
It works reliably for 5 smaller repos (90%+ pass rate) but fails ~55% of the
time on the largest target, ovn-kubernetes (1,358 Go files, 482K LOC, 3 go.mod
files). A test measurement bug inflates even that number — the true pass rate
is closer to 30%.

This plan fixes three problems in three incremental PRs:

1. **PR1 (mechanical):** Replace 56 broken `find` calls with
   `${CLAUDE_PLUGIN_ROOT}` and fix a SKILL.md/test-harness conflict that
   causes 55% of ovnk "passes" to start from the wrong git commit.

2. **PR2 (architectural):** Delegate Steps 2-4 to subagents with fresh 1M
   context each, eliminating the context exhaustion that causes 81% of ovnk
   failures ("missing 26 of 33 gates").

3. **PR3 (behavioral):** Replace version-specific fix recipes with general
   discovery procedures that read vendored source code, making the skill work
   for k8s 1.37+ with zero updates.

## Problem Statement

### Problem 1: Context Exhaustion

The skill runs in a single Claude Code session with a 1M-token context window.
For ovn-kubernetes, Step 2's compilation fix loop consumes 250-450K tokens of
build output, error investigation, and fix iterations. When compaction triggers,
SKILL.md is truncated to its first ~5K tokens. Steps 3-5 instructions (starting
at ~8K tokens) are lost. The agent never launches Steps 3-4's 26 gates.

Evidence: 81% of ovnk failures report "missing 26 of 33 gates" — exactly
Steps 1+2 gates (7) completed, Steps 3+4 gates (26) never started.

### Problem 2: Test Measurement Bug

SKILL.md Step 1 says "Run from the default branch (master/main)." The test
harness overrides this with "Do NOT switch to master/main" for historical
replay tests. The AI non-deterministically follows one or the other. When it
follows SKILL.md and checks out master, it rebases the wrong codebase. The
resulting diff against the known-good reference is 6,000-8,000+ hunks (vs
130-370 for correct runs). These bogus passes inflate the reported rate.

Evidence: 55% of ovnk spec=all "passes" have 6,000+ code hunks, matching
the master-vs-known-good diff size exactly. The true pass rate is ~30%.

### Problem 3: Version-Specific Recipes Rot

The autofix script (1,678 lines, 27 functions) and patterns doc (591 lines)
contain k8s 1.34-1.36-specific recipes. 53.8% of the patterns doc is already
stale. Each new k8s version requires manual updates.

Evidence: `spec=all` tests (autofix + patterns disabled) show the AI
independently discovers 74% of fixes from compiler errors and vendored source.
The remaining 26% need general discovery strategies, not version-pinned recipes.

### Problem 4: `find` Calls Break at Marketplace Install Depth

All 56 file-discovery calls use `find "$HOME" -maxdepth 7`. The marketplace
install path (`~/.claude/plugins/cache/ai-helpers/k8s-rebase/...`) is at depth
9. The skill silently fails when installed from the marketplace.

## Architecture: Current vs Proposed

### Current (monolithic, 981-line SKILL.md)

```
claude --bg session (single 1M context)
└── SKILL.md orchestrates Steps 1-5 sequentially
    ├── Step 1: run script, 1 gate subagent
    ├── Step 2: fix loop (250-450K tokens for ovnk), 6 gate subagents
    ├── Step 3: run autofix, 11 gate subagents          ← LOST after compaction
    ├── Step 4: lint/test/review, 15 gate subagents     ← LOST after compaction
    └── Step 5: generate PR command                     ← LOST after compaction
```

### Proposed (orchestrator + step subagents)

```
claude --bg session (main agent, ~96K tokens, never compacts)
├── Step 1: inline (1 gate, trivial, ~500 tokens)
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
├── gates/                          # UNCHANGED logic (56 find→PLUGIN_ROOT only)
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
| Instructions | 10K | 7K | 7K | 9K | 5K |
| Work output | 30K | 250-300K | 200-250K | 400-450K | 20K |
| Gate summaries | 6K | 6K | 11K | 15K | — |
| **Total** | **~71K** | **~288-338K** | **~243-293K** | **~449-499K** | **~50K** |
| **% of 1M** | **7%** | **29-34%** | **24-29%** | **45-50%** | **5%** |

The main agent never approaches compaction. Each step subagent has comfortable
margin within 1M. Step 4 is the tightest at ~50% but has 500K+ headroom.

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

The `find "$HOME" -maxdepth 7` pattern has four problems: (1) breaks at
marketplace install depth 9, (2) scans 1.3M files taking 44 seconds across 56
calls, (3) can match stale plugin copies in `~/.claude/jobs/*/tmp/`, (4)
`mutate_plugin` must patch 2 of 56 calls with fragile sed. `CLAUDE_PLUGIN_ROOT`
is set by `--plugin-dir` (which the test harness already passes), resolves
instantly, and the mutated-copy case works automatically. 10+ other plugins in
this marketplace use this pattern.

### Why autofix stays as default, spec=all for testing

The autofix script handles 27 fix patterns in ~8 seconds. The AI reasoning to
discover the same fixes takes 10-20 minutes and misses 26% of patterns
(feature gates that cause silent runtime hangs, CRD validation that causes
silent API server rejection, kubeadm config that is silently ignored). For
production, autofix runs first, AI fills gaps. `spec=all` (autofix disabled)
validates that the AI CAN work independently — the target for future-proofing.

### Why not split the autofix into multiple files

The 1,678-line script is well-organized with clear section markers and a header
catalog. `source`-based splitting creates invisible variable coupling (`GATE_DEPS`
is an associative array that cannot be exported). `mutate_plugin` would need to
search 3 files instead of 1. Section comments marking permanent vs migration
functions provide the same organizational benefit without the coupling risk.

### Why discovery procedures instead of recipes

The 6-step discovery procedure for Step 2 reads vendored `// Deprecated:`
comments to find replacements. This is self-correcting — it reads the actual
vendored code that was just bumped, not a stale recipe. The procedure works
for any k8s version because the vendored source IS the migration guide.

For the 6 patterns the AI can't discover from compilation errors alone (feature
gates, kubeadm config, CRD validation, CRD name patterns, ObservedGeneration,
RelaxedServiceNameValidation), the step files encode general strategies that
check vendored code state rather than hardcoded version numbers.

## Autofix Function Disposition

From per-function analysis of all 27 functions across 6 repos and 3 versions:

| Category | Count | Functions | Action |
|----------|-------|-----------|--------|
| **Evergreen** | 5 | fix_feature_gates, fix_kind_image, fix_kind_version, fix_lint_version (bump), fix_imports | Keep permanently |
| **Accelerator** | 3 | fix_xexp, fix_addtoscheme, fix_reflect_ptr | Keep (self-gating, zero cost when done) |
| **Ovnk-specific** | 3 | fix_metallb_version, fix_kubevirt_version, fix_mocks | Keep (harmless no-op on other repos) |
| **CRD permanent** | 2 | fix_crd_int64_validation, fix_crd_name_validation | Keep (codegen recurrence) |
| **One-time done** | 8 | fix_bounding_dirs, fix_lint v1→v2, fix_relaxed_svc_name, 4 NPA v0.2 functions, fix_kubeadm_v1beta4 | Remove when all repos past target version |
| **Redundant** | 3 | fix_version_refs, fix_go_version, fix_docs_version | Remove (rebase script Phase 3 does same work) |
| **Compiler-driven** | 3 | fix_fieldsv1, fix_klog_v2, fix_eventf | Keep as accelerators (AI discovers but slower) |

Key finding: **19 of 27 functions only trigger on ovn-kubernetes.** The autofix
is essentially an ovnk-specific accelerator with 8 universal functions mixed in.

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
must update in sync.

## Implementation: 3 PRs Ordered by Risk

### PR1: `CLAUDE_PLUGIN_ROOT` + branch fix (mechanical, low risk)

- Replace 56 `find` calls with `${CLAUDE_PLUGIN_ROOT}` paths in SKILL.md +
  33 gate files
- Fix SKILL.md line 87: "Run from the default branch" → "Run from the current
  branch" (fixes the test measurement bug)
- Remove `mutate_plugin`'s 2 `sed` commands (PLUGIN_ROOT handles it)
- Port 2 `GOVERSION` sed patterns from fix_go_version to k8s-rebase.sh Phase 3
- Add section comments to autofix marking permanent vs migration functions
- Version bump to 0.3.0, `make update`

**Validation:** `make lint`, then `make matrix version=1.36 spec=all`. Expect
identical or better pass rates (the `find` replacement is behavioral no-op
except at depth 9). The branch fix should eliminate all 6,000+ hunk passes.

### PR2: Step delegation (architectural, medium risk)

- Create `steps/` directory: rules.md, step2-compilation.md,
  step3-autofix.md, step4-verification.md
- Rewrite SKILL.md to ~350-line orchestrator (Steps 1+5 inline, 2-4 delegated)
- Post-step gate verification uses `find`-based counting (zsh-compatible)
- Robustness: oscillation detection, dirty-tree checks, gate wave splitting
  (Step 4 launches 15 gates first, then test agents — stays under 20
  concurrent limit)

**Validation:** `make matrix` for all 3 versions. Target: ovnk pass rate
above 80% across 10+ runs (up from ~30% true rate). Non-ovnk repos must
maintain current ~100% recent rate.

### PR3: Discovery procedures + cleanup (behavioral, highest risk)

- Replace version-specific recipes in step files with discovery procedures
- Restructure patterns doc (591 → ~208 lines), update TAG_TO_PATTERN
- Remove 3 redundant + 2 completed autofix functions
- Rename 3 gates for spec=all compatibility (autofix-result → fix-verification,
  autofix-diff-review → fix-diff-review, update dep-release-notes)
- Generalize fix_feature_gates toward self-discovering GATE_DEPS

**Validation:** `make matrix spec=all` for all 3 versions. This tests the AI's
independent capability without autofix or patterns doc.

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Step 2 subagent also exhausts 1M context | Medium | Budget is ~300K/1M (30%). Even doubled, 600K is safe. Checkpoint protocol lets subagent write state to disk before reporting PARTIAL. |
| `CLAUDE_PLUGIN_ROOT` not inherited by gate subagents | Low | Verified locally: subagents at depth 2 resolve `$HOME` and env vars correctly. Gate .md files resolve the variable in bash blocks before use. |
| First run reveals prompt construction bugs | Medium | Test on smallest repo (CNCC, 20 files) first. Expected: subagent trying to literally read `{CLAUDE_PLUGIN_ROOT}` as a path. Fix: ensure variable substitution happens in orchestrator bash block, not in prompt text. |
| Discovery procedures unreliable for novel k8s changes | High | Keep autofix as default for production. Discovery procedures are for `spec=all` testing only. Gate companion `.sh` scripts provide mechanical verification regardless. |
| Feature gate self-discovery adds false positives | Medium | Disabling an irrelevant gate via env var is a no-op. SetFromMap has a dependency trap (AtomicFIFO in 1.36) — need two-file awk pass or keep minimal curated GATE_DEPS for SetFromMap layer only. |
| Patterns doc restructure breaks TAG_TO_PATTERN | Medium | Must update test harness `TAG_TO_PATTERN` in the same commit. Heading renames are a known coupling. |
| This plan over-engineered (100 agents, 0 lines of code) | Valid concern | PR1 is a mechanical find-and-replace. Ship it in hours, validate immediately. PR2 and PR3 are separable and can be deferred if PR1 alone improves rates. |

## Success Criteria

- **PR1:** Zero 6,000+ hunk passes in 10 ovnk runs (branch fix works)
- **PR2:** ovnk spec=all pass rate ≥80% across 10+ runs (context fix works)
- **PR3:** ovnk spec=all pass rate maintained across k8s 1.34, 1.35, 1.36
  with discovery procedures (version-agnosticism works)
- **All PRs:** Non-ovnk repos maintain ~100% recent pass rate (no regressions)
