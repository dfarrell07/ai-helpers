# Plan: k8s-rebase Next Iteration

## Where we are

Gate flakes: 29→15→0. Non-ovnk repos: ~89%. ovnk: 0/7 with
multiple failure modes (stale .rebase-tmp is one, but "missing
gates" and "no branch found" are separate bugs). Fix .rebase-tmp
first, then investigate remaining ovnk failures.

## What moves the pass rate

**Clean .rebase-tmp/ in test harness** — Change line 446 of
test-skill.sh from `rm -rf "$repo/.rebase-tmp/gates"` to
`rm -rf "$repo/.rebase-tmp"`. The orchestrator creates state.json
in the main repo during init (before entering a worktree), and
it persists across runs. Also add to `cmd_clean`. This also
fixes the force-advance counter persistence bug (counter files
live inside .rebase-tmp/).

## Production hardening

**GPG signing** — Add `-c commit.gpgsign=false` to each
`git commit` call (8 total: 7 in k8s-rebase.sh, 1 in autofix).
Works in both host and container paths, never overrides host
signing for non-commit operations.

**Resume version mismatch** — Error if stored version differs.
Still needed for production users even after .rebase-tmp cleanup
(user could have leftover state from a previous rebase).

## Gate work

### Fix companion script bugs
- `major-version-imports.sh` lines 25, 51: args swapped in
  `base_file_has` — pre-existing detection broken
- `crd-validation.sh` line 27, `patterns-completeness.sh` line 17:
  dead `$pre` — PRE_EXISTING always 0
- Both also need migration to `gate-script-lib.sh`

### Script the 9 Tier 1 gates
Reduces agent calls when steps 2/3 adopt "launch only PENDING"
pattern (step 4 already does this).

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
| version-completeness | grep stale versions, exclude comments |

### Consolidate gates
- Narrow `deprecated-api-remnants` — duplicates build-vet
  (build+vet) and deprecated-imports (x/ checks). Keep only
  its web-search discovery. Does NOT overlap with
  deprecated-calls (different method: web-search vs staticcheck).
- `logical-completeness` (step3) and `logical-consistency` (step4)
  overlap heavily but each has unique checks. Consider merging
  unique step3 checks INTO step4, not dropping step3 outright.

### Tier 2 evidence scripts (after Tier 1)
1. `deprecated-calls` — staticcheck + pre-existing filter
2. `autofix-result` — commit counting + build pass/fail
3. `gomod-diff-analysis` — parse go.mod diff
