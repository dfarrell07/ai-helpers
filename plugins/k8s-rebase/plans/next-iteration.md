# Plan: k8s-rebase Next Iteration

## Where we are

Gate flakes: 29→15→0. Non-ovnk repos: 88%. ovnk: 0/7 due to
one harness bug (stale .rebase-tmp/). Fix that and run a clean
matrix to see the real pass rate.

## What moves the pass rate

**Clean .rebase-tmp/ in test harness** — Root cause of ALL ovnk
failures in the current matrix run: stale state.json in the main
repo causes the orchestrator to resume an old run instead of
starting fresh. The harness cleans worktrees and branches but
not .rebase-tmp/. One-line fix: `rm -rf "$repo/.rebase-tmp/"`
in `cmd_run`. Without this, non-ovnk repos pass at 88% but
ovnk is 0/7.

## Production hardening

**Pre-push hook cleanup** — Hook persists after rebase, blocks
`git push`. Add restore to step5 and ERR trap.

**Hook session guards** — The 3 markdown hooks block `go mod tidy`,
`git push`, vendor edits in ALL repos, not just during rebases.
Add `.session-active` check.

**GPG signing** — Set `commit.gpgsign=false` via `GIT_CONFIG_COUNT`
early in scripts.

**Force-advance counter** — Clear on fresh `cmd_init`.

**Resume version mismatch** — Error if stored version differs.

## Gate work

### Fix companion script bugs
- `major-version-imports.sh`: args swapped in `base_file_has` —
  pre-existing detection broken
- `crd-validation.sh`, `patterns-completeness.sh`: dead `$pre` —
  PRE_EXISTING always 0
- Both also need migration to `gate-script-lib.sh`

### Script the 8 Tier 1 gates
Reduces agent calls 27% (33→25). Steps 2/3 need "launch only
PENDING" pattern like step 4.

| Gate | Script does |
|------|-------------|
| build-vet-recheck | same logic as build-vet.sh |
| cleanliness | git status + find + git ls-files |
| diff-scope | changed files × extension whitelist |
| test-compilation | `go test -run='^$' -count=0` |
| feature-gates | grep KUBE_FEATURE_ vs vendor |
| rebase-completeness | result file + git log + go.mod |
| deprecated-imports | grep x/ imports (hardcoded table) |
| dep-cve-check | diff go.sum, curl OSV.dev |

`version-completeness` is Tier 2 (needs prose-vs-code judgment).

### Consolidate gates
- Drop `logical-completeness` (step3) — step4's
  `logical-consistency` is a strict superset
- Narrow `deprecated-api-remnants` — duplicates build-vet,
  deprecated-imports, and deprecated-calls. Keep only its
  web-search discovery

### Tier 2 evidence scripts (after Tier 1)
1. `deprecated-calls` — staticcheck + pre-existing filter
2. `autofix-result` — commit counting + build pass/fail
3. `gomod-diff-analysis` — parse go.mod diff

3 "Tier 3" gates actually have scriptable evidence phases
(ci-prediction, maintainer-review, skill-improvement). True
Tier 3 is 7 gates.
