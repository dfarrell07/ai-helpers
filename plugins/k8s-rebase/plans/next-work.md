# Next Work: Post-Redesign Fixes

Design concerns surfaced by 20 adversarial Opus agents. The
autofix/patterns redesign is complete — these are follow-up
items for the next round of work.

## Priority 1: Fix Now (no design decision needed)

### 1. go-mod-tidy three-way contradiction

rules.md says "NEVER run go mod tidy." step2 and step3 say
"run go mod tidy after dep changes." The hook (block-module-
ops.sh) BLOCKS go mod tidy during active sessions.

**The proposed rules.md softening is WRONG** — the hook would
still block the commands even with softened rules. The right
fix: create `scripts/k8s-rebase-modfix.sh` wrapper that runs
`go mod tidy && go mod vendor` in a controlled way. Change
step file instructions to call the wrapper script. Keep
rules.md's NEVER intact. The hook allows .sh scripts.

```bash
#!/bin/bash
# scripts/k8s-rebase-modfix.sh — controlled go mod tidy+vendor
set -euo pipefail
DIR="${1:-.}"
cd "$DIR"
go mod tidy
[[ -d vendor ]] && go mod vendor
```

Then step files say:
`bash "$PLUGIN_ROOT/scripts/k8s-rebase-modfix.sh" <dir>`

### 2. Write/Edit missing from allowed-tools

SKILL.md `allowed-tools: Bash, Read, Agent` — step2 says
"apply fixes yourself" but the agent can't use Edit/Write.
Fix: add Edit and Write to allowed-tools.

### 3. Hook crash-to-allow

If jq is missing, hooks exit 1 (allow). Security hooks should
fail-closed. Fix: add to top of each hook:
```bash
command -v jq &>/dev/null || exit 2
```

### 4. derive_go_gets sigs.k8s.io in Rule 1

Rule 1 assumes version-locked deps. sigs.k8s.io/ deps have
independent versioning. Fix: remove `sigs\.k8s\.io/` from
Rule 1's grep on line 390 of k8s-rebase.sh.

### 5. Move hook installation after pre-flight validation

k8s-rebase.sh installs the pre-push hook at line 42, before
any validation. 12 of 15 exit points after installation leave
the hook orphaned because die()/exit don't trigger the ERR
trap. Fix: move hook installation to right before branch
creation (line 368). All pre-flight validation runs first.

### 6. CRD check scope narrower than fix scope

run_checks searches `helm/*/crds/*.yaml` but the fix searches
6 paths. Fix: broaden run_checks to match:
```bash
find . \( -path "*/crds/*.yaml" -o -path "*/crd/*.yaml" \
  -o -path "*/bindata/*.yaml" -o -path "*/manifests/*.yaml" \
  -o -path "*/config/crd/*.yaml" -o -path "*/_output/*.yaml" \) \
  -not -path "*/vendor/*"
```

## Priority 2: Needs Decision

### 6. PLUGIN_ROOT find is slow

`find $HOME -maxdepth 7` timed out in adversarial testing
(120s+). Options:
- (a) Check if `CLAUDE_PLUGIN_ROOT` is available as env var
  in bash tool context — if so, use it directly
- (b) Narrow the find to `$HOME/.claude` only (skip `$HOME`)
- (c) Cache the result in `.rebase-tmp/plugin-root.txt`

### 7. Static inline category lists go stale

autofix-diff-review.md and maintainer-review.md have frozen
category lists. New autofix functions won't auto-appear.
Options:
- (a) Lint check comparing inline lists to FIX_DESC keys
- (b) Revert to dynamic patterns-doc reading
- (c) Accept maintenance burden (update list when adding fns)

### 8. Step 5 enforcement

Step 5 (PR generation) has no orchestrator enforcement. The
agent can declare "done" after step 4 without generating the
PR command. Options:
- (a) Add step5 to STEP_DIRS array (but it has no gates)
- (b) Add a minimal gate (verify gh pr create command exists
  in the agent's output)
- (c) Accept — the stop hook checks for DONE state

## Priority 3: Future Improvements

### 9. Gate consolidation 33 → 30

Merge candidates identified by adversarial review:
- step3/logical-completeness → step4/logical-consistency (-55 LOC)
- step4/commit-messages → step4/maintainer-review (-50 LOC)
- step4/ci-readiness → step4/ci-prediction (-40 LOC)

### 10. --bump-tools extraction

88 LOC serving 1 repo (ovn-kubernetes-mcp). Could extract to
a separate optional script or drop entirely. The agent can
bump Node/NVM/Ginkgo versions on request.

### 11. golangci-lint bump consolidation

k8s-rebase.sh same-major bump (44 LOC) overlaps with autofix
fix_lint_version. Could move entirely to autofix, removing
the deferral logic in Phase 3.

### 12. Companion script gaps

Two companion scripts (crd-validation.sh, patterns-completeness.sh)
don't source gate-script-lib.sh. They have:
- Reversed merge-base branch order (master first vs main first)
- No crash trap
- Different set flags (no -e)
Migrate to gate-script-lib.sh for consistency.

### 13. Regression testing

Run `make test` on 2-3 repos to verify pass rates don't
regress after the redesign:
```
make test repo=ovn-kubernetes/ovn-kubernetes-mcp
make test repo=openshift/cluster-network-operator
make test repo=openshift/multus-cni
```

## Summary

| Priority | Items | Effort |
|----------|-------|--------|
| P1: Fix now | 5 | ~1 hour |
| P2: Needs decision | 3 | Discussion |
| P3: Future | 5 | Separate PRs |
