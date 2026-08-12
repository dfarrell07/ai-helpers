# Plan: k8s-rebase Next Iteration

## Where we are

Gate flakes: 29→15→0. Non-ovnk repos: ~89%. ovnk: ~21% (3/14)
with multiple failure modes. Two harness bugs dominate: stale
.rebase-tmp/ and stale branch detection. Fix both and run a clean
batch to see the real pass rate.

## 1. Fix harness, run clean batch

**Clean .rebase-tmp/** — Change line 446 of test-skill.sh from
`rm -rf "$repo/.rebase-tmp/gates"` to `rm -rf "$repo/.rebase-tmp"`.
Also add to `cmd_clean`.

**Fix stale branch detection** — Checkout default branch BEFORE
deleting bump branches (currently reversed). Old branches confuse
`_do_record_one` even after .rebase-tmp is cleaned.

**Run clean batch** — Reveals real pass rate once stale state is
eliminated. Many step-skipping failures may disappear.

## 2. Fix bugs that break users

**Hook session guards** — The 3 markdown hooks block `go mod tidy`,
`git push`, vendor edits in ALL repos when plugin is installed.
Add `.session-active` check to each hook body.

**Pre-push hook cleanup** — Hook persists after rebase, blocks
`git push`. Confirmed in all 6 test repos. Add cleanup to step5
(check for k8s-rebase marker, restore backup).

**major-version-imports.sh** — Args swapped in `base_file_has`.
Pre-existing detection broken, causes false FAILs.

**GPG signing** — Add `-c commit.gpgsign=false` to each
`git commit` call (8 total: 7 in k8s-rebase.sh, 1 in autofix).

**Resume version mismatch** — Error if stored version differs.

## 3. Gate work

### Fix remaining companion script bugs
- `crd-validation.sh`, `patterns-completeness.sh`: dead `$pre`
- Both need migration to `gate-script-lib.sh`

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
- Narrow `deprecated-api-remnants` — duplicates build-vet and
  deprecated-imports. Keep only web-search discovery.
- `logical-completeness` (step3) and `logical-consistency` (step4)
  overlap but each has unique checks. Merge step3's unique checks
  into step4, don't drop outright.

### Tier 2 evidence scripts (after Tier 1)
1. `deprecated-calls` — staticcheck + pre-existing filter
2. `autofix-result` — commit counting + build pass/fail
3. `gomod-diff-analysis` — parse go.mod diff
