# Next Work: Post-Redesign Fixes

Design concerns surfaced by 30 adversarial Opus agents. The
autofix/patterns redesign is complete — these are follow-up
items for the next round of work.

## Priority 1: Fix Now (no design decision needed)

### 1. go-mod-tidy three-way contradiction

rules.md says "NEVER run go mod tidy." step2 and step3 say
"run go mod tidy after dep changes." The hook (block-module-
ops.sh) BLOCKS go mod tidy during active sessions.

Changing rules.md text is insufficient — the hook physically
blocks the commands. Fix: create `scripts/k8s-rebase-modfix.sh`
wrapper that runs `go mod tidy && go mod vendor`. Change step
file instructions to call the wrapper. Keep rules.md NEVER
intact. The hook allows .sh script invocations.

```bash
#!/bin/bash
# scripts/k8s-rebase-modfix.sh — controlled go mod tidy+vendor
set -euo pipefail
DIR="${1:-.}"
cd "$DIR"
go mod tidy
[[ -d vendor ]] && go mod vendor
```

Step files change to:
`bash "$PLUGIN_ROOT/scripts/k8s-rebase-modfix.sh" <dir>`

### 2. Write/Edit missing from allowed-tools

SKILL.md `allowed-tools: Bash, Read, Agent` — step2 says
"apply fixes yourself" but the agent can't use Edit/Write.
Fix: add Edit and Write to allowed-tools.

### 3. Hook crash-to-allow

If jq is missing, hooks crash with exit 1. Claude Code treats
exit 1 as "allow." Must NOT use bare `exit 2` at top — that
would block ALL commands globally when jq is missing (skips
the session guard). Fix: add after `INPUT=$(cat)`, before jq:

```bash
if ! command -v jq &>/dev/null; then
  # Best-effort session check without jq
  CWD=$(printf '%s' "$INPUT" | grep -o '"cwd" *: *"[^"]*"' \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  if [[ -n "$CWD" && -f "$CWD/.rebase-tmp/.session-active" ]]; then
    echo "BLOCKED: jq required for k8s-rebase hooks" >&2
    exit 2
  fi
  exit 0  # Not in a session — allow
fi
```

For stop-hook.sh: fail-open (`exit 0`) since trapping a user
in a session with broken tooling is worse than premature exit.

### 4. derive_go_gets sigs.k8s.io in Rule 1

Rule 1 assumes version-locked deps. sigs.k8s.io/ deps have
independent versioning. Fix: remove `sigs\.k8s\.io/` from
Rule 1's grep on line 390 of k8s-rebase.sh.

### 5. Move hook installation after pre-flight validation

k8s-rebase.sh installs the pre-push hook at line 42, before
any validation. 12 of 15 exit points after installation leave
the hook orphaned because die()/exit don't trigger the ERR
trap. Fix: move hook installation to right before branch
creation (~line 368). All pre-flight validation runs first.

### 6. Dead rebase-report.md pipeline

rules.md tells agents to write checkpoints to
`.rebase-tmp/rebase-report.md` after each step. No step file
reinforces this instruction, so agents never write them. step5
then reads a nonexistent file. Fix: either remove the checkpoint
instructions from rules.md and step5, or add checkpoint writes
to each step file.

### 7. CRD check scope narrower than fix scope

BOTH CRD checks in run_checks() search only `helm/*/crds/*.yaml`
but fix_crd_int64_validation searches 6 broader paths. Also the
CRD name validation check has the identical scope problem. Fix:
broaden both checks to match the fix function's search paths:
```bash
find . \( -path "*/crds/*.yaml" -o -path "*/crd/*.yaml" \
  -o -path "*/bindata/*.yaml" -o -path "*/manifests/*.yaml" \
  -o -path "*/config/crd/*.yaml" -o -path "*/_output/*.yaml" \) \
  -not -path "*/vendor/*"
```

## Priority 2: Performance & Design

### 7. PLUGIN_ROOT find is slow (P1 for perf)

`find $HOME -maxdepth 7` timed out in testing (120s+).
CLAUDE_PLUGIN_ROOT is NOT available as env var (confirmed).
The slow find is duplicated in 20+ gate .md files — each
rebase spawns ~33 subagents, each running its own find.
That's 33 slow finds per rebase.

Options:
- (a) Narrow find to `$HOME/.claude` first, fall back to
  `$HOME` only if not found
- (b) Cache result in `.rebase-tmp/plugin-root.txt`
- (c) Pass PLUGIN_ROOT in the subagent prompt (already done
  for step agents, but not for gate subagents)

### 8. Static inline category lists go stale

autofix-diff-review.md and maintainer-review.md have frozen
category lists. Already stale: "third-party licenses" is in
the list but is NOT a FIX_DESC key. Options:
- (a) Lint check comparing lists to FIX_DESC keys
- (b) Revert to dynamic patterns-doc reading
- (c) Accept maintenance burden

### 9. Step 5 enforcement

Step 5 (PR generation) has no orchestrator enforcement. The
stop hook allows exit as soon as step 4 reports DONE. Options:
- (a) Add step5 to STEP_DIRS (but it has no gates)
- (b) Add minimal gate (verify gh pr create in output)
- (c) Accept — step5 instructions are clear in SKILL.md

## Priority 3: Future Improvements

### 10. Gate consolidation 33 → 31

Safe merges (within step4):
- step4/commit-messages → step4/maintainer-review (-50 LOC)
- step4/ci-readiness → step4/ci-prediction (-40 LOC)

Risky merge (crosses step boundary — deferred):
- step3/logical-completeness → step4/logical-consistency
  would delay completeness checking to step4

### 11. --bump-tools extraction

88 LOC serving 1 repo (ovn-kubernetes-mcp). Could extract to
separate optional script or drop entirely.

### 12. golangci-lint bump consolidation

k8s-rebase.sh same-major bump (44 LOC) overlaps with autofix
fix_lint_version. Could move entirely to autofix.

### 13. Companion script migration

crd-validation.sh and patterns-completeness.sh don't source
gate-script-lib.sh. They have reversed merge-base branch
order, no crash trap, and different set flags. Migrate to
shared library for consistency.

### 14. validate.sh container bugs

(a) Silent fallthrough when Go too old + no container runtime —
script continues with wrong Go producing confusing errors.
k8s-rebase.sh correctly dies in this case; validate.sh does not.
(b) --full mode corrupts host GOMODCACHE with root-owned files
because container runs as root with mounted cache.

### 15. Regression testing

Run `make test` on 2-3 repos to verify pass rates:
```
make test repo=ovn-kubernetes/ovn-kubernetes-mcp
make test repo=openshift/cluster-network-operator
make test repo=openshift/multus-cni
```

## Summary

| Priority | Items | Effort |
|----------|-------|--------|
| P1: Fix now | 6 | ~2 hours |
| P2: Design | 3 | Discussion + ~1 hour |
| P3: Future | 5 | Separate PRs |

### 20. Review prompt backtick injection (CRITICAL)

k8s-rebase-review-prompt.md wraps $DIFF in triple-backtick
code fence. If the diff contains triple backticks (Go doc
comments, test fixtures), the fence breaks and injected text
becomes top-level prompt instructions. Fix: use 5+ backtick
fence or escape backticks in DIFF.

### 21. Review default-APPROVE on all failures (CRITICAL)

k8s-rebase-review.sh outputs APPROVE when template missing,
claude CLI missing, or timeout. All 3 failure paths silently
approve unreviewed code. The antagonistic review system is
defeated by any infrastructure issue. Fix: default to REJECT
or exit with distinct code forcing caller to decide.

### 22. k8s-rebase.sh Phase 1: silent go get failures (SERIOUS)

Every go get failure in derive_go_gets is swallowed with a
WARNING. The script commits go.mod with wrong dep versions.
Fix: verify k8s.io/api, client-go, apimachinery are at
API_VERSION after the go get loop before proceeding.

### 23. k8s-rebase.sh re-pin tidy: break instead of die (SERIOUS)

The k8s.io/kubernetes re-pin tidy loop (lines 534-546) uses
break instead of die when exhausted. Falls through to vendor
which crashes with a confusing error. Fix: die instead of break.

### 24. k8s-rebase.sh re-tidy loop: no re-vendor (SERIOUS)

The re-tidy loop for sibling replace directives (lines 608-624)
runs go mod tidy but never go mod vendor. Commits stale vendor.
Fix: add go mod vendor for vendored modules after tidy.

### 25. step4 gates launched before lint (waste)

step4 says "launch ALL gates immediately" but rules.md says
"commit ALL fixes before re-launching ANY gates." Orchestrator
discards all 15 gate reports as stale after first lint commit.
Fix: launch gates after lint iteration completes.

### 26. ovn-org/ovn-kubernetes renamed (HIGH)

The repo was transferred to ovn-kubernetes/ovn-kubernetes.
GitHub redirects work now but will eventually expire. All 3
test configs and the README reference the old org name. Fix:
update all references to ovn-kubernetes/ovn-kubernetes.

### 27. README "Tested against" lists 3 repos with no configs

openshift/api, metallb/frr-k8s, kubernetes-sigs/network-policy-api
are in the README table but have zero test configs. Either add
configs or remove from README.

## CRITICAL CORRECTION: NPA Functions Removal Was Premature

Fact-checker found the "NPA v0.2.0 not released" claim was
**false** — v0.2.0 shipped April 21, 2026, 4 months before
the removal. Evidence:

- go-controller on the k8s 1.36 rebase branch bumped to
  network-policy-api v0.2.0
- Commit e34d4742 manually fixed the exact EgressPeer type
  change that fix_banp_egresspeer would have automated
- fix_obsgen has NO version guard — it fires on any rebase
  where the pattern exists

| Function | Dead code? | Should restore? |
|----------|-----------|-----------------|
| fix_banp_egresspeer | NO — proven needed | YES |
| fix_obsgen | NO — no version guard | CONSIDER |
| fix_conformance_renames | Dormant (conformance still pre-release) | LATER |
| fix_network_policy_api_crds | Dormant | LATER |

Decision needed: restore fix_banp_egresspeer at minimum.

## Fact-Checker Corrections (Wave 6)

### Autofix is CORRECTNESS, not just time

3 of 5 kept functions provide correctness the agent CANNOT
achieve: fix_feature_gates (no error signal — tests hang),
fix_kubeadm_v1beta4 (no error signal — config silently
ignored), fix_kind_image (Docker Hub validation). The plan's
framing of "agent discovers everything" is wrong for silent
failure patterns. The removed functions that address silent
failures (fix_obsgen, fix_crd_name_validation) may have been
wrongly removed.

### 300-line budget is dead letter

Only 3 lines of headroom. Zero enforcement (no Makefile check,
no lint rule, no pre-commit). Projected 320-350 after k8s 1.37.
Either raise to 350 or add the Makefile check the plan proposed
but never implemented.

### NPA dead code claim confirmed wrong (see earlier)

v0.2.0 shipped April 2026. fix_banp_egresspeer proven needed.

### Generality is overstated

9 of 18 kept functions are truly general. 4 are ovnk-specific
in practice (feature_gates, docs_version, mocks, crd_int64
verify path). 5 are KIND ecosystem. The header comment
mislabels fix_docs_version, fix_mocks, and fix_feature_gates
as "Generic" when they only fire for ovnk. Consider relabeling
or documenting the actual scope honestly.

### ObservedGeneration is a full gap

Both fix_obsgen AND the patterns doc warning ("DO NOT OMIT")
were removed. The failure is truly silent: code compiles with
ObservedGeneration=0 but status conditions are semantically
wrong. Controllers checking ObservedGeneration think the object
was never reconciled. Currently dormant (NPA v0.2.0 not yet
vendored by test repos). Will activate when ovnk vendors v0.2.0.

Reinforces NPA restoration decision: fix_obsgen and
fix_banp_egresspeer should both be restored.

### spec=none UNDERPERFORMS spec=all (critical framing gap)

spec=none (with autofix): 49.1% (26/53)
spec=all (without autofix): 77.0% (194/252)

Same-day A/B (July 30): spec=none 53.8% vs spec=all 76.9%.

The autofix provides ZERO measurable benefit and may be
counterproductive by consuming context window. The plan's
argument ("75% without help is good enough") buried the lead.
The real finding: there is no evidence the removed functions
help at all. This reframes the NPA restoration discussion —
even if fix_obsgen catches a real semantic issue, adding
autofix functions back may hurt overall pass rates.

Caveat: temporal confounding (spec=none runs stopped Aug 4,
tool improved since). A controlled re-test is needed.

## Fact-Checker Corrections to P1 Fixes

Item 1 (modfix.sh): wrapper with <dir> arg won't match the
script bypass regex (requires line to end after .sh). Drop
the arg or fix the regex to allow arguments.

Item 2 (Write/Edit): probably unnecessary — step subagents
get full tools. The orchestrator never directly edits files.

Item 7 (CRD scope): also update diagnostic output at lines
~1271/1277 of autofix.sh. Add .claude and testdata exclusions
to match the fix function.
