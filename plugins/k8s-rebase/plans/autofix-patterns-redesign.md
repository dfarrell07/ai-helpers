# Plan: Autofix & Patterns Redesign

Goal: make k8s-rebase-autofix.sh and k8s-rebase-patterns.md
permanently general — useful for ALL Go+k8s repos across ALL
future k8s versions. Remove version-specific bloat, repo-specific
recipes, and anything the agent already discovers on its own via
build/vet/lint failures.

## Key Evidence

**spec=all (blind mode) works.** 75% pass rate (176/234) across
all repos without the autofix or patterns doc. When the agent
completes, all 10 court verdicts are PASS — quality is fine,
the risk is "failing to finish," not "wrong results."

Per-repo spec=all pass rates (latest versions):
- cluster-network-operator: 92-100%
- ovn-kubernetes-mcp: 92-94%
- multus-cni: 67-92%
- cloud-network-config-controller: 58-92%
- ingress-node-firewall: 80-83%
- ovn-org/ovn-kubernetes: 37-60% (hardest — context exhaustion)

The agent CAN discover and fix most breakage independently.
The autofix saves time but is not essential for correctness.

## Principles

1. **If build/vet/lint catches it, the agent will fix it.** Don't
   automate what the compiler already flags.
2. **If it only applies to one repo, it doesn't belong in the
   script.** Repo-specific knowledge goes in the repo, not the
   skill.
3. **If it's version-specific, it rots.** Prefer runtime detection
   over hardcoded version recipes.
4. **Self-gating is necessary but not sufficient.** A function that
   returns early on 8/9 repos still adds complexity and LOC.
5. **Silent failures need automation; loud failures don't.** If
   the failure is a compiler error, the agent finds it. If the
   failure is "tests hang silently," the agent can't diagnose it.

## Autofix Functions — Disposition (27 functions)

### KEEP — Generic, version-independent (17 functions)

These fire on any Go+k8s repo with the matching pattern. All are
self-gating (return early when pattern absent). Ordered by value:

| # | Function | Why keep |
|---|----------|---------|
| 1 | fix_feature_gates | **Most valuable.** Tests hang silently without it. Agent can't diagnose informer timeouts → feature gate connection. GATE_DEPS map is 2 lines, extensible. |
| 2 | fix_kubeadm_v1beta4 | **Silent failure.** k8s 1.36 ignores v1beta3 extraArgs without error. Controller-manager flags not applied. Impossible to diagnose. |
| 3 | fix_xexp | Build breaks but the fix is tricky: `maps.Keys()` → `slices.Collect(maps.Keys())` (iterator API change), `maps.Clear()` → `clear()`. Non-obvious transforms. |
| 4 | fix_lint_version | golangci-lint v1→v2 migration is extremely non-obvious. Agent can't diagnose "v1 can't parse Go 1.26 syntax." |
| 5 | fix_kind_image | Checks Docker Hub for image availability. Network-aware version selection the agent wouldn't do. |
| 6 | fix_crd_int64_validation | Silent CRD rejection at runtime in k8s 1.36+. Two-part fix (Go markers + YAML patch). |
| 7 | fix_crd_name_validation | Silent regression — codegen strips hand-edited metadata.name patterns. Base-branch comparison is clever. |
| 8 | fix_go_version | CI fails remotely, not during local build. Updates Makefiles, Dockerfiles, workflows. |
| 9 | fix_version_refs | CI fails remotely. Updates stale v1.OLD refs across CI/scripts/docs. |
| 10 | fix_kind_version | Bumps KIND binary to latest. CI fails if KIND can't create new-version clusters. |
| 11 | fix_imports | Runs goimports + gci with project-specific lint config. Needed after x/exp migration. |
| 12 | fix_addtoscheme | Vendor-aware: only renames if AddToScheme truly removed AND Install exists. |
| 13 | fix_klog_v2 | Trivial sed, harmless. Build error guides agent but autofix is faster. |
| 14 | fix_reflect_ptr | Trivial sed, harmless. |
| 15 | fix_fieldsv1 | Version-gated (k8s ≥ 1.36). Two fix patterns: read vs construct. |
| 16 | fix_eventf | go vet catches it but fix pattern (replacing .Error() with "%v") is non-obvious. |
| 17 | fix_bounding_dirs | Removes deprecated codegen flag. Trivial safety net. |

### REMOVE — Repo-specific (4 functions)

These only fire for ovnk or ovnk-adjacent repos:

| # | Function | Why remove |
|---|----------|-----------|
| 1 | fix_metallb_version | Pure CI dep bump for ovnk's kind-common. Not a build fix. |
| 2 | fix_kubevirt_version | Pure CI dep bump for ovnk's kind-common. Not a build fix. |
| 3 | fix_docs_version | Only ovnk has `docs/features/requirements.md`. |
| 4 | fix_mocks | Only repos with `.mockery.yaml` (ovnk). Agent discovers missing mocks from build errors. |

### CONVERT — Move from script to agent knowledge (6 functions)

These serve 1-2 repos. The agent discovers the issue from
compile errors. Convert to guidance in step instructions or
gate prompts rather than blind sed:

| # | Function | Why convert |
|---|----------|-----------|
| 1 | fix_conformance_renames | Compile error guides fix. Only NPA conformance repos. |
| 2 | fix_banp_egresspeer | Compile error guides fix. Only NPA repos. |
| 3 | fix_obsgen | Subtle (no build failure), but only 1-2 repos. Move to agent knowledge doc. |
| 4 | fix_network_policy_api_crds | Conformance tests fail but root cause is non-obvious. Move to agent knowledge. |
| 5 | fix_relaxed_service_name_validation | Specific feature gate lifecycle management. Agent can handle with knowledge. |
| 6 | fix_kubeadm_v1beta4 | WAIT — reconsidered. KEEP because of silent failure mode. |

**Revised: 18 KEEP, 4 REMOVE, 5 CONVERT.**

## run_checks() — Disposition (18 checks)

### KEEP — Generic (11 checks)

x/exp imports, reflect.Ptr, FieldsV1.Raw, stale major-version
imports, bare Eventf, CRD format:int32, CRD missing name
validation, gates in test-go.sh, gates in env var files, gates
in SetFromMap files, uncommitted.

### REMOVE — Repo-specific (5 checks)

Conformance old names, AddToScheme in factory, AddToScheme in
conformance, BANP wrong EgressPeer, ObsGen incomplete/missing.

All 5 are NPA-ecosystem checks with hardcoded paths. They return
0 on repos without those files, so they're harmless but add 50+
lines of complexity.

### REMOVE — Repo-specific detection-only (2 checks)

Stale docs ver (ovnk-only file), E2e test fixes missing
(ovnk-only kubevirt.go check with no fix function).

## Patterns Doc — Disposition

_Awaiting detailed pattern-by-pattern analysis from agents._

Key question: 4 gates reference the patterns doc (autofix-diff-
review, ci-readiness, maintainer-review, patterns-completeness).
Need to determine if each reference is REQUIRED or OPTIONAL.

Preliminary assessment: the Pattern Table at the top is the most
generic part. The Version-Specific Patterns section is the most
bloated (500+ lines of recipes for specific k8s versions and
repo-specific workarounds).

## Impact Summary

| Category | Current | After redesign |
|----------|---------|---------------|
| autofix.sh functions | 27 | 18 |
| autofix.sh LOC | ~1679 | ~1100-1200 (est) |
| run_checks entries | 18 | 11 |
| patterns.md LOC | ~591 | ~200-300 (est) |

Estimated reduction: ~30-40% of autofix LOC, ~50-60% of patterns
doc LOC. All removed code is repo-specific or version-specific.

## Implementation Plan

### Phase 1: Remove clearly repo-specific code

1. Remove fix_metallb_version, fix_kubevirt_version,
   fix_docs_version, fix_mocks from autofix.sh
2. Remove their run_checks entries
3. Remove their FIX_DESC entries and main execution calls
4. Remove corresponding patterns doc sections

### Phase 2: Remove NPA-ecosystem code

1. Remove fix_conformance_renames, fix_banp_egresspeer,
   fix_obsgen, fix_network_policy_api_crds
2. Remove their run_checks entries (5 NPA checks)
3. Optionally: move key guidance to step2-compilation.md
   hints (so agent knows about NPA type renames from
   compile errors)

### Phase 3: Trim patterns doc

1. Keep Pattern Table (top-level summary)
2. Keep Feature Gates section (recurring, generic)
3. Keep Cross-repo dependency ordering (recurring, generic)
4. Remove version-specific one-time recipes
5. Remove repo-specific workarounds (KubeVirt IPv6, hybrid-
   overlay, OTE module, etc.)
6. Convert remaining ecosystem patterns to short hints

### Phase 4: Update gate references

1. Update gates that reference patterns doc to work without
   version-specific recipes
2. Verify autofix-diff-review gate still functions
3. Verify patterns-completeness gate still functions

## Open Questions

1. Should fix_relaxed_service_name_validation be KEEP or
   CONVERT? It manages a feature gate lifecycle across k8s
   versions (add in <1.36, remove in >=1.36). This pattern
   will recur for other gates.
2. How many lines does Phase 1-3 actually save? Awaiting LOC
   analysis from agent.
3. Do any gates REQUIRE the patterns doc sections we'd remove?
   Awaiting gate reference analysis.

---

_Iteration 1 — synthesized from 3 completed research agents.
8 more agents still running. Will update with their findings._
