# Next Work: Post-Redesign

Findings from 60 adversarial Opus agents + 20 fact-checkers.
Organized by what matters most, with fact-checked severity.

## Key Insight: Autofix May Be Counterproductive

spec=none (with autofix): **49.1%** pass rate (26/53)
spec=all (without autofix): **77.0%** pass rate (194/252)
Same-day A/B (July 30): 53.8% vs 76.9%

The autofix + patterns doc may hurt pass rates by consuming
context window. This reframes all restoration decisions: even
if a function catches a real issue, adding it back may lower
the overall pass rate. A controlled re-test is needed before
restoring anything.

**Caveat:** temporal confounding — spec=none runs stopped Aug 4
while tool improved. The gap may be smaller than it looks.

## Priority 1: Restore Incorrectly Removed Items

### 1a. Restore AtomicFIFO to GATE_DEPS

Generic client-go gate (beta/default-on in k8s 1.36) with 4
StaleController* dependencies. Was thrown out with the NPA
cleanup because the old code had hardcoded go-controller/ paths.
The gate itself is generic and needed for k8s 1.37.

```bash
GATE_DEPS[AtomicFIFO]="StaleControllerConsistencyJob \
  StaleControllerConsistencyReplicaSet \
  StaleControllerConsistencyStatefulSet \
  StaleControllerConsistencyDaemonSet"
```

### 1b. Decide on NPA function restoration

NPA v0.2.0 shipped April 21, 2026 — the "dead code" claim was
false. fix_banp_egresspeer was proven needed (manual fix
e34d4742 on rebase branch). fix_obsgen catches a silent
semantic issue (ObservedGeneration=0 compiles but is wrong).

**However:** given spec=none underperforms spec=all, restoring
functions may hurt pass rates. Options:
- (a) Restore fix_banp_egresspeer + fix_obsgen (correctness)
  but accept potential pass-rate cost
- (b) Don't restore — agent handles compile errors (banp) and
  the ObsGen gap is dormant until conformance bumps to v0.2.0
- (c) Run a controlled A/B test first: spec=none with just
  these 2 functions restored vs spec=all

| Function | Silent failure? | Proven needed? | Restore? |
|----------|----------------|----------------|----------|
| fix_banp_egresspeer | No (compile error) | Yes (e34d4742) | Agent handles from error |
| fix_obsgen | Yes (ObsGen=0 compiles) | Not yet tested | Strongest restore candidate |
| fix_conformance_renames | No (compile error) | Dormant | Wait |
| fix_network_policy_api_crds | Sort of (test failure) | Dormant | Wait |

## Priority 2: Fix Bugs Found by Adversarial Review

All are pre-existing bugs, zero observed failures in 337 runs.
Theoretical severity is high but practical impact is low.

### 2a. go-mod-tidy three-way contradiction

rules.md bans go mod tidy. step2/step3 instruct it. The hook
blocks it. Fix: create `scripts/k8s-rebase-modfix.sh` wrapper.
Step files call the wrapper. Rules.md stays unchanged. Hook
allows .sh scripts.

**Correction:** The wrapper invocation with a `<dir>` argument
won't match the script bypass regex (`\s*$` requires no args).
Either drop the arg (use cwd) or fix the regex.

### 2b. Hook crash-to-allow when jq missing

All 4 hooks depend on jq. Missing jq = crash = fail-open.
Fix: grep-based session check as fallback (see P1 item 3 in
earlier plan version). stop-hook.sh should fail-open since
trapping users in broken sessions is worse.

### 2c. Hook installation timing

Pre-push hook installed at line 42, before validation. 12 of
15 early exits orphan the hook. Fix: move installation to
right before branch creation (~line 368).

### 2d. Review prompt issues

- Backtick breakout: $DIFF in triple-backtick fence can break
  if diff contains ```. Fix: use 5+ backtick fence.
- Default-APPROVE on all failures defeats the review's purpose.
  Fix: default to REJECT or distinct exit code.
- Both are theoretical (zero observed incidents in 337 runs).

### 2e. k8s-rebase.sh Phase 1 robustness

- Silent go get failures: swallowed with WARNING, wrong
  versions can be committed. Fix: verify core k8s.io deps
  are at API_VERSION after the go get loop.
- Re-pin tidy: `break` instead of `die` when exhausted.
- Re-tidy loop: no re-vendor after tidy for vendored modules.
- All 3 are mitigated by post-correction stages. Zero observed
  wrong-version failures in 337 runs.

### 2f. Dead rebase-report.md pipeline

rules.md says write checkpoints. No step file does. step5
reads nonexistent file. Fix: remove the checkpoint instructions
or add writes to each step file.

### 2g. step4 gates wasted before lint

step4 says "launch ALL gates immediately" but orchestrator
discards reports after lint commits change HEAD. Fix: launch
gates after lint iteration completes.

### 2h. CRD check scope

run_checks searches `helm/*/crds/*.yaml` but fix searches 6
paths. Also update diagnostic output at lines ~1271/1277.
Add .claude and testdata exclusions.

## Priority 3: Maintenance & Cleanup

### 3a. derive_go_gets sigs.k8s.io in Rule 1

Remove `sigs\.k8s\.io/` from Rule 1's grep. sigs.k8s.io deps
have independent versioning. Currently no practical impact but
semantically wrong.

### 3b. PLUGIN_ROOT find is slow

33 slow finds per rebase (1 per gate subagent). Options:
narrow to $HOME/.claude first, cache in .rebase-tmp, or pass
in subagent prompt.

### 3c. 300-line budget enforcement

Budget is a dead letter — 3 lines headroom, zero enforcement.
Either raise to 350 or add Makefile check:
```bash
lines=$(wc -l < docs/k8s-rebase-patterns.md)
[ "$lines" -gt 350 ] && echo "ERROR: budget exceeded" && exit 1
```

### 3d. Generality labeling

9/18 functions truly general. 4 are ovnk-specific in practice
(feature_gates, docs_version, mocks, crd_int64 verify path).
Header mislabels 3 as "Generic." Relabel honestly.

### 3e. ovn-org/ovn-kubernetes renamed

Repo transferred to ovn-kubernetes/ovn-kubernetes. All test
configs and README reference old org. GitHub redirects will
eventually expire.

### 3f. README "Tested against" gaps

3 repos listed but have no test configs (openshift/api,
metallb/frr-k8s, kubernetes-sigs/network-policy-api).

### 3g. Write/Edit in allowed-tools

Probably unnecessary — step subagents get full tools. The
orchestrator never directly edits files. Add for defense-in-
depth if desired, note why in comment.

### 3h. Static inline category lists

Already stale ("third-party licenses" not a FIX_DESC key).
Will go stale again when functions are added. Accept
maintenance burden or add lint check.

### 3i. Step 5 enforcement

No orchestrator enforcement. Agent can skip PR generation.
Accept — step5 instructions are clear in SKILL.md.

## Priority 4: Future Improvements

- Gate consolidation 33 → 31 (safe within-step merges)
- --bump-tools extraction (88 LOC for 1 repo)
- golangci-lint bump consolidation
- Companion script migration (crd-validation.sh, patterns-
  completeness.sh to gate-script-lib.sh)
- validate.sh container bugs (silent fallthrough, root files)
- Regression testing (`make test` on 2-3 repos)

## What the Fact-Checkers Taught Us

1. **"Dead code" claims need verification.** The NPA v0.2.0
   release date was checkable but wasn't checked. One web
   search would have prevented the premature removal.

2. **Autofix provides correctness, not just speed.** 3 of 5
   kept functions catch silent failures an agent cannot
   discover. Removed functions addressing silent failures
   (fix_obsgen) leave real gaps.

3. **spec=none vs spec=all comparison was missing.** The plan
   argued "75% without help is good enough" without showing
   that WITH help is only 49%. The autofix may consume more
   context than it saves.

4. **Severity ratings need evidence.** All CRITICAL/SERIOUS
   items have zero observed failures in 337 runs. Theoretical
   risks with existing mitigations. Calibrate accordingly.

5. **Plans drift from implementation.** 40% of changes were
   undocumented. Adversarial reviews found bugs the plan
   didn't anticipate. Plans should be updated post-facto or
   kept lightweight.
