# Plan: k8s-rebase Skill — Step Isolation + Version-Agnostic Generality

## Context

The k8s-rebase skill passes 90%+ for 5 smaller repos but only 45% for ovn-org/ovn-kubernetes. The goal is `spec=all` reliability — the skill should work **without** the autofix script (1678 lines, 27 functions) and patterns doc (591 lines) for any repo, any k8s version, with no per-version updates.

**Two problems to solve:**

1. **Context exhaustion (81% of ovnk failures):** The main agent's 1M context fills during Step 2's fix loop (175-350K tokens for ovnk). SKILL.md is truncated after compaction → Steps 3-5 instructions lost → "missing 26 of 33 gates."

2. **Version-specific recipes rot:** The autofix script and patterns doc contain k8s 1.34-1.36 specific recipes. Each new k8s version requires manual updates. `spec=all` tests prove the AI can do 74% of fixes independently — but needs general discovery strategies for the remaining 26%.

**Two architectural fixes:**

1. **Step delegation** — Steps 2-4 run in subagents with fresh 1M context. Main agent stays at ~96K tokens, never compacts.

2. **Discovery procedures** — Replace version-specific recipes with general techniques that read vendored source code. Works for k8s 1.34 through 1.50+ with zero updates.

## Approach

### Architecture

```
Main Agent (~350-line SKILL.md orchestrator, ~96K tokens, never compacts)
├── Step 1: Rebase — inline (script + 1 gate)
├── Step 2: Compilation — delegate to subagent → reads steps/step2-compilation.md
│   └── Fresh 1M context, discovery procedure for fixes, 6 gate subagents
├── Step 3: Autofix — delegate to subagent → reads steps/step3-autofix.md
│   └── Fresh 1M context, discovery checklist (not autofix.sh), 11 gate subagents
├── Step 4: Verification — delegate to subagent → reads steps/step4-verification.md
│   └── Fresh 1M context, lint/test/review, 15 gate subagents
├── Mandatory checkpoint: inline
└── Step 5: Submit — inline (PR prep)
```

### Three Key Changes

**A. `${CLAUDE_PLUGIN_ROOT}` replaces all 56 `find` calls.** Ship-blocker: marketplace install path is depth 9 (exceeds `maxdepth 7`). `CLAUDE_PLUGIN_ROOT` is the canonical plugin mechanism, used by 10+ other plugins. Bonus: eliminates `mutate_plugin`'s `sed` patching (the test harness's `--plugin-dir` flag sets `CLAUDE_PLUGIN_ROOT` to the mutated directory automatically).

**B. Discovery Procedures replace version-specific recipes.** Step 2 gets a 6-step procedure for finding correct API migrations by reading vendored `// Deprecated:` comments. Step 3 gets a discovery checklist (categories A-G) replacing "run autofix.sh". Both are version-agnostic — they read actual vendored source code.

**C. Process-agnostic gates.** 3 gate renames so they verify rebase QUALITY, not which tool did the work:
- `autofix-result` → `fix-verification` (check build/vet, not autofix markers)
- `autofix-diff-review` → `fix-diff-review` (review all fix commits, not just autofix)
- Update `dep-release-notes` to check git log for version changes (not "what autofix bumped")

## Files to Create

### `plugins/k8s-rebase/steps/rules.md` (~30 lines)
Shared rules — single source of truth for all step subagents:
- Module safety rule (never go mod tidy/get/vendor)
- Commit discipline (--signoff, no amend, Assisted-by trailer)
- Scope preservation (only changes required by k8s bump)
- Gate-fix loop protocol (triage → fix → delete report → re-run, max 3)
- Container commands (podman --userns=keep-id)
- Never push / no PRs
- Nesting cap (do not launch subagents that launch subagents)

### `plugins/k8s-rebase/steps/step2-compilation.md` (~200 lines)
Version-agnostic instructions replacing lines 248-426. Key change: **Discovery Procedure** replaces hardcoded migration recipes:

1. Read the compiler error → identify missing symbol and package
2. `grep 'Deprecated:' vendor/<package>/` → find replacement
3. Browse replacement package source → check full signature
4. For removed types → grep vendor for where it moved
5. For added context params → trace call chain
6. Verify against vendored source (always current after bump)

Keeps: migration direction rule, OpenShift deps guidance, scope discipline, replace_all warning, type conversion review, parallel investigation. Removes: all `pointer.Int32 → ptr.To` style recipes.

### `plugins/k8s-rebase/steps/step3-autofix.md` (~200 lines)
Version-agnostic discovery checklist replacing "run autofix.sh":

**A. Build and vet** (primary — if clean, many categories skip)
**B. Deprecated/removed symbols** (grep vendor for // Deprecated:, use go doc for stdlib promotions)
**C. Feature gates** (parse `vendor/k8s.io/client-go/features/known_features.go` for new default-true gates, disable in ALL 3 layers: test-go.sh, os.Setenv/t.Setenv, SetFromMap)
**D. CI infrastructure** (KIND image/binary, MetalLB, KubeVirt — check GitHub releases)
**E. CRD validation** (diff CRDs vs base branch, check int64 format, restore metadata.name patterns)
**F. Silent config migrations** (check vendored kubeadm API version, convert extraArgs format if needed)
**G. Tooling and docs** (Go version, lint version, import ordering, codegen flags, stale version refs)

### `plugins/k8s-rebase/steps/step4-verification.md` (~250 lines)
Extract from SKILL.md lines 540-834. Same content, adapted for subagent context. Uses `${CLAUDE_PLUGIN_ROOT}` paths.

## Files to Modify

### `plugins/k8s-rebase/skills/k8s-rebase/SKILL.md` (981 → ~350 lines)
- **Preamble** (~80 lines): Unchanged rules, within compaction survival zone
- **Step 1** (~100 lines): Unchanged, inline. Uses `${CLAUDE_PLUGIN_ROOT}` for script paths
- **Path resolution** (~5 lines): `PLUGIN="${CLAUDE_PLUGIN_ROOT}"` then derive all paths
- **Steps 2-4 delegation** (~75 lines): Construct prompt, launch Agent, post-return gate check using `find`-based verification (zsh-compatible)
- **Mandatory checkpoint** (~15 lines): Simplified, uses `find` for gate counting
- **Step 5** (~55 lines): Unchanged, inline

### 33 gate `.md` files (mechanical change)
Replace `find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" ...` with `${CLAUDE_PLUGIN_ROOT}/scripts/write-gate-report.sh` in all gate files. Same for any gate that discovers companion `.sh` scripts.

### 3 gate renames (spec=all compatibility)
- `gates/step3-autofix/autofix-result.md` → `fix-verification.md` (remove autofix marker checks, focus on build/vet)
- `gates/step3-autofix/autofix-diff-review.md` → `fix-diff-review.md` (review all fix commits)
- Update `dep-release-notes.md` to check git log instead of autofix output

### `plugins/k8s-rebase/.claude-plugin/plugin.json`
Bump version to 0.3.0.

### `plugins/k8s-rebase/test/test-skill.sh` (minor simplification)
Remove the 2 `sed` commands in `mutate_plugin` (lines 618-619) that patch `find` calls — no longer needed since `CLAUDE_PLUGIN_ROOT` resolves to the mutated directory automatically via `--plugin-dir`.

## Files NOT Changed
- `scripts/` — all 6 scripts unchanged (they use `BASH_SOURCE` internally)
- `hooks/` — block-push unchanged
- `docs/` — patterns doc unchanged (still available when spec != all)
- Most gate `.md` files — unchanged logic, only the `find` → `CLAUDE_PLUGIN_ROOT` mechanical replacement

## Key Design Decisions

**1. `${CLAUDE_PLUGIN_ROOT}` for all file references.** Fixes depth-9 ship-blocker, eliminates `mutate_plugin` sed patching, removes 44-second filesystem scan (56 find calls × 0.9s each). 10+ other plugins use this pattern.

**2. Discovery Procedures, not recipes.** Step 2 reads vendored `// Deprecated:` comments to find replacements. Step 3 parses `known_features.go` for feature gates. Both are self-correcting — they read the vendored code that was just bumped.

**3. 6 essential strategies for patterns AI can't discover from compilation errors alone:**
   - Feature gates (runtime hang, no compile error) → parse known_features.go
   - kubeadm v1beta4 (silent config ignore) → check vendored kubeadm API version
   - CRD int64 validation (API server rejection) → diff CRDs, fix format
   - CRD name validation (codegen strips hand-edits) → diff against base branch
   - ObservedGeneration (conformance assertion) → set on status conditions
   - RelaxedServiceNameValidation (version-dependent gate) → check k8s version

**4. 100% of gates are already version-agnostic.** 28 fully generic + 5 with SKIP support. Zero need changes for future k8s versions. Only 3 need renaming for process-agnosticism.

**5. Shared `rules.md` as single source of truth.** Step subagents read it via chain indirection (verified working). Avoids 40-line rule duplication across 3 step files.

**6. Step files use gate directory names.** `step2-compilation.md` matches `gates/step2-compilation/` for grep-ability and zero naming confusion.

**7. Autofix remains as DEFAULT for production.** When spec != all (production use), autofix.sh runs first (saves 10-20 min vs AI reasoning), then AI fills gaps. The step3 instructions say "if autofix script exists, run it first; then use discovery checklist for anything it missed." Both paths lead to the same gates. spec=all is for TESTING the AI's independent capability, not production.

**8. Steps 1 and 5 stay inline.** Step 1 has 1 gate, trivial control flow, nohup is context-cheap (~500 tokens). Step 5 IS the deliverable — the PR command must go directly to the user. Delegating these adds ~60 sec overhead for no context benefit.

**9. Don't split autofix into multiple files.** Use section comments to mark permanent vs migration functions. Optionally add a `FIX_LIFECYCLE` metadata array for programmatic removal tracking. The file is well-organized at 1,678 lines. Three files would create `source` coupling issues and break `mutate_plugin`.

## Step Subagent Prompt Template

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

## Implementation Phasing (3 PRs, ordered by risk)

**PR1: `CLAUDE_PLUGIN_ROOT` + branch fix** (mechanical, low risk)
- Replace all 56 `find` calls with `${CLAUDE_PLUGIN_ROOT}` paths
- Fix SKILL.md line 87: "Run from the default branch" → "Run from the current branch"
- Remove `mutate_plugin`'s sed patching (PLUGIN_ROOT handles it)
- Port 2 `GOVERSION` patterns from fix_go_version to k8s-rebase.sh Phase 3
- Add section comments to autofix marking permanent vs migration functions
- Version bump, `make update`

**PR2: Step delegation** (architectural, medium risk)
- Create `steps/` directory with rules.md, step2-compilation.md, step3-autofix.md, step4-verification.md
- Rewrite SKILL.md to ~350-line orchestrator (Steps 1+5 inline, 2-4 delegated)
- Add post-step gate verification (find-based, zsh-compatible)
- Add robustness improvements (oscillation detection, dirty-tree check, etc.)
- Test: `make matrix` for all versions, target 80%+ ovnk pass rate

**PR3: Discovery procedures + cleanup** (behavioral, highest risk)
- Replace version-specific recipes with discovery procedures in step files
- Restructure patterns doc (591 → ~208 lines, update TAG_TO_PATTERN)
- Remove redundant autofix functions (fix_version_refs, fix_go_version, fix_docs_version)
- Remove completed migration functions (fix_bounding_dirs, fix_klog_v2)
- Rename 3 gates for spec=all compatibility
- Generalize fix_feature_gates (self-discovering GATE_DEPS)
- Test: `make matrix spec=all` for all versions

## Verification

1. `make lint` — validate plugin structure
2. Verify `${CLAUDE_PLUGIN_ROOT}` resolves correctly in test harness sessions
3. `make test repo=openshift/cloud-network-config-controller version=1.36 spec=all` — small repo baseline
4. `make test repo=ovn-org/ovn-kubernetes version=1.36 spec=all` — ovnk with new architecture
5. `make matrix version=1.36 spec=all` — full 1.36 matrix
6. Run 3+ ovnk passes per version before declaring success
7. **Success metric:** ovnk spec=all pass rate above 80% across 10+ runs

## Critical Test Bug: 8000-hunk Passes Are From Wrong Starting Point

55% of ovnk spec=all passes (high-hunk cluster: 6000-8242 hunks) are from the AI starting on `master` instead of the configured `from_commit`. SKILL.md Step 1 says "Run from the default branch (master/main)" which conflicts with the test harness override. The AI non-deterministically follows one or the other.

**Fix required**: Change SKILL.md Step 1 from "Run from the default branch (master/main)" to "Run from the current branch (do not switch branches)." Also add recording-time detection in test harness: compare merge-base of result branch against from_commit, mark as FAIL if they differ.

This means the TRUE ovnk pass rate is lower than the 45% reported, making the step delegation architecture even more critical.

## Robustness Improvements (include in this PR)

1. **Normalize Step 3 gate-fix loop**: Add `validate.sh --quick` between fix and gate re-run
2. **Oscillation detection**: Stop if a previously-passed gate regresses after fixing a different gate
3. **Broaden go.mod check**: SKILL.md line 104 currently only accepts root-level go.mod — use `find`
4. **Tighten checkpoint**: Detect "not PASS" instead of just "is FAIL" (catches malformed reports)
5. **Dirty-tree check**: `git status --porcelain` at start of each gate-fix loop
6. **Gate wave splitting**: Step 4 should launch 15 gates first, then test agents (stays under 20 concurrent limit)

## Autofix Function Disposition (from 20+ per-function analyses)

**EVERGREEN (keep, self-discovering, needed every rebase):**
- `fix_feature_gates` — 4-layer mechanism + GATE_DEPS curation. Permanent architecture, needs ~1-3 gate additions per k8s release.
- `fix_kind_image` — Docker Hub query for kindest/node tags. 4 repos affected.
- `fix_kind_version` — GitHub API for latest KIND release. 3 repos.
- `fix_lint_version` (bump+sync) — Go compatibility version check. 7 repos. Needs threshold fix.
- `fix_imports` — goimports + gci with project config. Universal.

**ACCELERATOR (keep, self-gating, non-trivial transformation):**
- `fix_xexp` — x/exp → stdlib migration with slices.Collect() wrapping. 2 repos. Self-gates: no-op when migration done.

**ONE-TIME / DEAD CODE (safe to remove, all self-guarding):**
- `fix_bounding_dirs` — codegen flag removed in k8s 1.36. Already done in all repos.
- `fix_lint_version` (v1→v2 block) — All repos already on v2.
- `fix_relaxed_svc_name` — Gate lifecycle done (alpha→beta→GA). Add branch unreachable since ovnk is at 1.36.
- `fix_conformance_renames` — NPA v0.1→v0.2 symbol rename. Done.
- `fix_banp_egresspeer` — NPA v0.2.0 type split. Done.
- `fix_obsgen` — ObservedGeneration code quality fix. Done.
- `fix_network_policy_api_crds` — ClusterNetworkPolicy CRD install. Done.
- `fix_kubeadm_v1beta4` — v1beta3→v1beta4 config format. Done for ovnk. Keep temporarily for other repos.

**OVNK-SPECIFIC (keep for ovnk CI, harmless for others):**
- `fix_metallb_version` — GitHub API + FRR companion image. Has a bug (FRR sed pattern mismatches actual variable name).
- `fix_kubevirt_version` — Patch-only bump within same minor.
- `fix_mocks` — Regenerate mockery mocks. Has a trigger condition bug (checks pkg/crd but mocks aren't there).

**REDUNDANT (remove, rebase script Phase 3 already handles):**
- `fix_version_refs` — Phase 3 Pass 1 does identical work.
- `fix_go_version` — Phase 3 does same; port 2 `GOVERSION` patterns to Phase 3.
- `fix_docs_version` — Phase 3 Pass 2 covers docs. Also ovnk-specific file.

**run_checks() disposition:**
- 12 of 18 checks are PERMANENT diagnostics (keep)
- 4 are STALE/repo-specific (remove: conformance old names, conformance addtoscheme, stale docs ver, e2e test fixes missing)
- 2 are NPA-ecosystem-specific (keep with scope documentation)

**k8s-rebase.sh: FULLY GENERAL** — zero version-specific logic, all parameterized from version argument.

**Repo × Function Matrix (key finding):**
- 19 of 26 autofix functions are **OVNK-ONLY** (only trigger on ovn-kubernetes)
- 7 are truly universal: fix_xexp, fix_reflect_ptr, fix_klog_v2, fix_fieldsv1, fix_eventf, fix_addtoscheme, fix_imports
- Multus triggers 1 function (fix_klog_v2), CNCC ~0, CNO 2 (fix_crd_int64, maybe fix_addtoscheme)
- The autofix script is essentially an "ovnk-specific accelerator" with universal functions mixed in

**Patterns doc: 53.8% stale.** 11 version-specific patterns (k8s 1.35/1.36), 3 one-time-done. Restructure from 591 → ~208 lines, organized by pattern class (Go API Breakage, Feature Gates, Linting, CRDs, CI Infrastructure) instead of by k8s version. Keep 12 permanent patterns, remove 14 stale ones.

## Future Improvements (not this PR)

- Gate consolidation: merge logical-completeness into logical-consistency, merge 3 deprecated gates, merge ci-prediction + ci-readiness (33 → ~28 gates)
- `info-` prefix for informational gates (dep-cve-check, skill-improvement, commit-messages, maintainer-review)
- YAML frontmatter (`enforcement: informational|blocking`) in gate files, derive INFO_GATES dynamically
- Rename "step" → "stage" across gate dirs, report filenames, test harness (cross-industry alignment)
- Add go.sum integrity gate, replace directive audit gate, vendor/modules.txt freshness gate
