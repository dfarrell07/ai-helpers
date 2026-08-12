# Plan: k8s-rebase Next Iteration

## Where we are

Gate flakes: 29→15→0. Non-ovnk repos: ~89%. ovnk: ~21% (3/14)
with multiple failure modes. Two harness bugs dominate: stale
.rebase-tmp/ and stale branch detection. Fix both and run clean
batch. Expect non-ovnk to stay ~89%+; ovnk likely stays ~25-35%
(context exhaustion on large repo, not harness bugs).

## 1. Fix harness, run clean batch

**Clean .rebase-tmp/** — Change line 446 of test-skill.sh from
`rm -rf "$repo/.rebase-tmp/gates"` to `rm -rf "$repo/.rebase-tmp"`.
Also add to `cmd_clean`.

**Run clean batch** — `make matrix` to get honest baseline.

## 2. Fix bugs that break users

**Pre-push hook cleanup** — Hook persists after rebase, blocks
`git push`. Confirmed in all 6 test repos. Use deterministic
backup name (`pre-push.bak.k8s-rebase` not `pre-push.bak.$$`),
add restore to step5 cleanup.

**GPG signing** — Add `-c commit.gpgsign=false` to each
`git commit` call (8 total: 7 in k8s-rebase.sh, 1 in autofix).

**major-version-imports.sh** — Swap args in `base_file_has`
(lines 25, 51). Zero observed test impact but wrong.

## 3. Gate work

### Fix companion script bugs
- `crd-validation.sh`, `patterns-completeness.sh`: dead `$pre`
- Both need migration to `gate-script-lib.sh`

### Script the 9 Tier 1 gates
Won't help ovnk (fails before reaching gates) but prevents
future flakes and reduces agent calls for other repos.

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
  deprecated-imports (confirmed). Keep only web-search discovery.
- `logical-completeness`/`logical-consistency` — merge step3's
  unique checks into step4.

### Tier 2 evidence scripts
1. `deprecated-calls` — staticcheck + pre-existing filter
2. `autofix-result` — commit counting + build pass/fail
3. `gomod-diff-analysis` — parse go.mod diff
