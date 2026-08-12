# Plan: Autofix & Patterns Redesign

Goal: make k8s-rebase-autofix.sh and k8s-rebase-patterns.md
permanently general — useful for ALL Go+k8s repos across ALL
future k8s versions. Remove version-specific bloat, repo-specific
recipes, and anything the agent already discovers on its own.

## Key Evidence

**spec=all (blind mode) works.** 75% pass rate (176/234) across
all repos without the autofix or patterns doc. When the agent
completes, all 10 court verdicts are PASS — quality is fine.

Per-repo spec=all pass rates (latest versions):
- cluster-network-operator: 92-100%
- ovn-kubernetes-mcp: 92-94%
- multus-cni: 67-92%
- cloud-network-config-controller: 58-92%
- ingress-node-firewall: 80-83%
- ovn-org/ovn-kubernetes: 37-60% (context exhaustion)

**No gate requires the patterns doc.** All 6 gates that reference
it have explicit fallbacks or use it as optional context. The
step3-autofix.md `cat` command is the only place where full
recipes genuinely matter (for ITEMS_REMAINING manual work).

**NPA functions are dead code.** 3 of 4 NPA functions guard on
network-policy-api v0.2.0+. No test repo has v0.2.0. These are
speculative fixes for an unreleased API transition. All 4 only
fire for 1 of 6 repos (ovn-org/ovn-kubernetes).

## Principles

1. **If build/vet/lint catches it, the agent will fix it.**
2. **If it only applies to one repo, it doesn't belong here.**
3. **If it's version-specific, it rots.**
4. **Silent failures need automation; loud failures don't.**
5. **Self-gating doesn't justify complexity.** 138 lines of NPA
   code that returns early on 5/6 repos is still 138 lines.

## LOC Analysis (hard numbers)

**autofix.sh: 1678 lines total**

| Category | Functions | LOC | % |
|----------|-----------|-----|---|
| Generic Go | 5 (xexp, reflect_ptr, klog_v2, fieldsv1, eventf) | 93 | 6% |
| Generic Import/Codegen | 4 (imports, bounding_dirs, mocks, addtoscheme) | 124 | 7% |
| Generic Version | 4 (go_version, lint_version, version_refs, docs_version) | 162 | 10% |
| CRD (generic) | 2 (crd_int64, crd_name) | 102 | 6% |
| Feature gates | 1 | 118 | 7% |
| NPA ecosystem | 4 | 138 | 8% |
| KIND ecosystem | 4 | 208 | 12% |
| Repo-specific | 2 (metallb, kubevirt) | 63 | 4% |
| Infrastructure | run_checks, run_vet, main exec, etc. | 670 | 40% |

**patterns.md: 591 lines total**

| Category | Sections | LOC | % |
|----------|----------|-----|---|
| Pre-section (table, gates, extending) | 3 | 119 | 20% |
| Generic | 16 | 304 | 51% |
| NPA ecosystem | 3 | 54 | 9% |
| KIND ecosystem | 2 | 35 | 6% |
| Repo-specific | 5 | 79 | 13% |

## Autofix Functions — Disposition (27 functions)

### KEEP — Generic (15 functions, ~830 LOC)

| # | Function | LOC | Why keep |
|---|----------|-----|---------|
| 1 | fix_feature_gates | 118 | Tests hang silently. Only defense. SIMPLIFY: fix InOrderInformers contradiction with patterns doc. |
| 2 | fix_lint_version | 85 | v1→v2 migration impossible to diagnose. Phase 3 defers this. |
| 3 | fix_kubeadm_v1beta4 | 76 | **Silent failure** — k8s ignores v1beta3 without error. One-time but guard makes it no-op after. |
| 4 | fix_kind_image | 70 | Docker Hub availability check. Not redundant with Phase 3. |
| 5 | fix_imports | 62 | goimports + gci with project lint config. |
| 6 | fix_crd_int64_validation | 56 | Silent CRD rejection at runtime. |
| 7 | fix_crd_name_validation | 46 | Silent regression — codegen strips hand-edits. |
| 8 | fix_go_version | 45 | CI fails remotely. Defense-in-depth for Phase 3. |
| 9 | fix_xexp | 33 | `maps.Keys()` → `slices.Collect(maps.Keys())` is non-obvious. |
| 10 | fix_addtoscheme | 30 | Vendor-aware rename. |
| 11 | fix_kind_version | 28 | KIND binary bump. No Phase 3 overlap. |
| 12 | fix_eventf | 23 | go vet catches it but fix pattern is non-obvious. |
| 13 | fix_version_refs | 20 | Defense-in-depth for Phase 3. |
| 14 | fix_fieldsv1 | 15 | Version-gated. Two fix patterns. |
| 15 | fix_klog_v2 | 13 | Trivial, harmless. |

### KEEP — Trivial safety nets (2 functions, ~22 LOC)

| # | Function | LOC | Why keep |
|---|----------|-----|---------|
| 1 | fix_reflect_ptr | 9 | 9 lines. Harmless. |
| 2 | fix_bounding_dirs | 13 | 13 lines. Harmless. |

### REMOVE — NPA ecosystem (4 functions, 138 LOC)

All fire for exactly 1 of 6 repos. 3 of 4 are dead code (NPA
< v0.2.0). Speculative fixes for an unreleased API.

| # | Function | LOC | Agent discovers from |
|---|----------|-----|---------------------|
| 1 | fix_obsgen | 56 | Conformance test failure (subtle) |
| 2 | fix_network_policy_api_crds | 37 | Conformance test failure |
| 3 | fix_conformance_renames | 28 | Compile error |
| 4 | fix_banp_egresspeer | 17 | Compile error |

### REMOVE — Repo-specific (4 functions, 106 LOC)

| # | Function | LOC | Agent discovers from |
|---|----------|-----|---------------------|
| 1 | fix_metallb_version | 42 | CI failure |
| 2 | fix_relaxed_service_name_validation | 34 | KIND cluster creation error |
| 3 | fix_kubevirt_version | 21 | CI timeout |
| 4 | fix_docs_version | 12 | Not caught (cosmetic) |

### REMOVE — Redundant (1 function, 19 LOC)

| # | Function | LOC | Why remove |
|---|----------|-----|-----------|
| 1 | fix_mocks | 19 | k8s-rebase.sh Phase 2 already runs mockery. Agent discovers from build errors. |

**Total: 17 KEEP + 10 REMOVE**
**LOC removed: 263 lines of fix functions + ~97 supporting code
(run_checks entries, FIX_DESC, main exec calls, case blocks)
= ~360 lines (21% of script)**

## run_checks() — Disposition (18 checks)

### KEEP (11 checks)

x/exp imports, reflect.Ptr, FieldsV1.Raw, stale major-version
imports, bare Eventf, CRD format:int32, CRD missing name
validation, gates in test-go.sh, gates in env var files, gates
in SetFromMap files, uncommitted.

### REMOVE (7 checks, ~65 LOC)

- Conformance old names (NPA)
- AddToScheme in factory (NPA)
- AddToScheme in conformance (NPA)
- BANP wrong EgressPeer (NPA)
- ObsGen incomplete/missing (NPA)
- Stale docs ver (ovnk-only file)
- E2e test fixes missing (ovnk kubevirt.go, no fix fn)

## Patterns Doc — Disposition (26 sections, 591 LOC)

### KEEP (12 sections, ~310 LOC)

Pre-section content (Pattern Table, Feature Gates, Extending
for a New Version) plus generic/recurring sections:

- Pattern Table (universal reference)
- Feature Gates (recurring, generic)
- Extending for a New k8s Version (process guidance)
- Cross-repo dependency ordering (recurring, critical — 40 LOC)
- ST1005 error string casing (recurring, silent failure)
- Snyk vendor scan failures (recurring)
- Vendor verification false positives (recurring)
- golangci-lint v1→v2 config migration (recurring)
- golang.org/x/exp → stdlib (generic)
- Deprecated stdlib/apimachinery symbols (recurring)
- Transitive dependency compatibility (generic)
- AddToScheme → Install (generic)

### REMOVE (14 sections, ~280 LOC)

Version-specific one-time patterns, NPA ecosystem, and
repo-specific workarounds:

- WithConditions + ObservedGeneration (NPA v0.2.0)
- EgressPeer type divergence (NPA v0.2.0)
- Conformance suite rename (NPA v0.2.0)
- Project CRD int64 validation (k8s 1.36 + ovnk)
- CRD metadata.name validation lost (ovnk — autofix handles)
- MetalLB CRD validation (k8s 1.36)
- KubeVirt version incompatibility (ovnk)
- RelaxedServiceNameValidation (k8s 1.36)
- KubeVirt secondary interface IPv6 (k8s 1.36, ovnk)
- kubeadm v1beta4 format (k8s 1.36 — autofix handles)
- deepcopy-gen --bounding-dirs (k8s 1.36 — autofix handles)
- Hybrid-overlay informer coalescing (ovnk)
- E2e framework changes (k8s 1.35)
- OTE downstream module (ovnk)

### KEEP BUT TRIM (2 sections)

- controller-gen version annotation (keep concept, trim recipe)
- Webhook builder API change (keep concept, trim recipe)
- Operator Framework repos (keep concept, trim recipe)

## Gate References to Patterns Doc

**No gate breaks if patterns doc is trimmed.** All references
are optional:

| Gate | How it uses patterns doc | Inline replacement |
|------|------------------------|-------------------|
| autofix-diff-review | "Use as reference" for expected transforms | One-line category list |
| patterns-completeness | Cross-reference, check 4/4 | Explicit fallback exists |
| ci-readiness | Check for manual-fix items | Short bullet list |
| maintainer-review | Identify expected vs scope-creep changes | One-line category list |
| correctness | Catch-all for valid change types | Inline list already covers 90% |
| skill-improvement | Dedup against known patterns | List of autofix function names |
| step3-autofix.md | Full recipes for ITEMS_REMAINING | Only place needing full recipes |

**Action:** After trimming the patterns doc, add a one-line
category list to autofix-diff-review.md and maintainer-review.md
so they don't need to find/read the doc at all.

## Phase 3 ↔ Autofix Overlap

| Function | Phase 3 overlap | Verdict |
|----------|----------------|---------|
| fix_kind_image | Partial (Phase 3 blindly sets tag) | Keep autofix (validates availability) |
| fix_go_version | Near-complete | Keep as defense-in-depth (12 lines of sed) |
| fix_lint_version | Partial (Phase 3 does simple bump) | Keep autofix (does v1→v2 migration) |
| fix_version_refs | Near-complete | Keep as defense-in-depth |

No action needed — the overlap is intentional and documented.

## Feature Gate Deep-Dive

fix_feature_gates has a **cold-start problem**: Layers 1-3
only extend existing gate infrastructure. On first encounter
(repo has no KUBE_FEATURE_ setup), only Layer 4 (warning)
fires. The function is a maintenance tool, not a bootstrapper.

**Action items:**
1. Fix InOrderInformers contradiction (GATE_DEPS includes it
   but patterns doc says it doesn't need disabling)
2. Consider adding bootstrap capability in Layer 4 (convert
   warning to `t.Setenv` insertion for suites using fake
   clientsets) — this is a future improvement, not blocking

## Impact Summary

| Metric | Current | After | Change |
|--------|---------|-------|--------|
| autofix.sh LOC | 1678 | ~1315 | -22% |
| autofix functions | 27 | 17 | -37% |
| run_checks entries | 18 | 11 | -39% |
| patterns.md LOC | 591 | ~310 | -48% |
| patterns.md sections | 26 | 14 | -46% |
| **Combined** | **2269** | **~1625** | **-28%** |

## Implementation Plan

### Commit 1: Remove repo-specific autofix code

- Remove fix_metallb_version (42 LOC)
- Remove fix_kubevirt_version (21 LOC)
- Remove fix_docs_version (12 LOC)
- Remove fix_mocks (19 LOC)
- Remove fix_relaxed_service_name_validation (34 LOC)
- Remove FIX_DESC entries, main exec calls, case blocks
- Remove E2e test fixes and stale docs ver from run_checks

### Commit 2: Remove NPA ecosystem autofix code

- Remove fix_conformance_renames (28 LOC)
- Remove fix_banp_egresspeer (17 LOC)
- Remove fix_obsgen (56 LOC)
- Remove fix_network_policy_api_crds (37 LOC)
- Remove 5 NPA run_checks entries
- Remove NPA case blocks from remaining-issues section

### Commit 3: Trim patterns doc

- Remove 14 version/repo-specific sections (~280 LOC)
- Keep Pattern Table + 11 generic/recurring sections
- Trim 2 "keep but trim" sections

### Commit 4: Update gate references

- Add inline category lists to autofix-diff-review.md and
  maintainer-review.md so they don't need the patterns doc
- Verify patterns-completeness.md fallback path works

### Commit 5: Fix feature gate inconsistency

- Remove InOrderInformers from GATE_DEPS (contradicts doc)
  OR update patterns doc to include it. Research needed.

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| NPA v0.2.0 rebase breaks later | Low | Agent discovers from compile errors. 3/4 fns are dead code anyway. |
| MetalLB/KubeVirt CI breaks | Low | Agent can bump when CI fails. |
| Gates produce noisier reports | Low | Add inline category lists. |
| fix_mocks removal breaks codegen | Low | k8s-rebase.sh Phase 2 handles mockery. Agent discovers from build. |

## Open Questions

1. InOrderInformers: GATE_DEPS has it, patterns doc says it
   doesn't need disabling. Which is correct?
2. Should fix_kubeadm_v1beta4 be kept (silent failure) even
   though only 1 repo (ovnk) has kind.yaml.j2? It's a one-
   time transition with a no-op guard after.
3. Should we also remove the remaining Phase 3 defense-in-
   depth functions (fix_go_version, fix_version_refs) given
   Phase 3 already handles them? Trade-off: ~65 LOC saved
   vs losing the safety net.

---

_Iteration 2 — synthesized from 11 completed research agents.
All agents complete. LOC numbers are exact. Ready for review._
