# Plan: k8s-rebase Next Iteration

## Where we are

Gate flakes: 29→15→0. Non-ovnk repos: 88%. ovnk: 0/7 due to
one harness bug (stale .rebase-tmp/). Fix that and run a clean
matrix to see the real pass rate.

## What moves the pass rate

**Clean .rebase-tmp/ in test harness** — Change line 446 of
test-skill.sh from `rm -rf "$repo/.rebase-tmp/gates"` to
`rm -rf "$repo/.rebase-tmp"`. The orchestrator creates state.json
in the main repo during init (before entering a worktree), and
it persists across runs. Old state.json causes the orchestrator
to resume a dead run instead of starting fresh. Also add the
same cleanup to `cmd_clean`.

## Production hardening

**GPG signing** — Add `-c commit.gpgsign=false` to each
`git commit` call (16 total: 14 in k8s-rebase.sh, 2 in autofix).
Not GIT_CONFIG_COUNT — that doesn't survive container exec and
would override host signing config for non-commit operations.

**Force-advance counter** — Clear on fresh `cmd_init`.

**Resume version mismatch** — Error if stored version differs.

## Gate work

### Fix companion script bugs
- `major-version-imports.sh` lines 25, 51: args swapped in
  `base_file_has` — pre-existing detection always fails, inflates
  NEW_ISSUES. Inert today (AI gate re-analyzes anyway) but wrong.
- `crd-validation.sh` line 27, `patterns-completeness.sh` line 17:
  dead `$pre` — PRE_EXISTING always 0. Also inert (nothing reads
  PRE_EXISTING) but wrong.
- Both also need migration to `gate-script-lib.sh`.

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
