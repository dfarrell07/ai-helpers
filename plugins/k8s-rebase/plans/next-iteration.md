# Plan: k8s-rebase Next Iteration

## Where we are

81% clean pass rate (22/27 on Aug 11, excluding a stale-branch
batch that ran before that bug was fixed). Gate flakes: 29→15→0
across the 3 eras. The orchestrator refactor worked.

5 remaining failures on Aug 11 (clean):
- 2 "no branch found" — harness bug, stale-branch fix covers it
- 3 "missing gates" — agent stopped early (the unsolved problem)

## What actually moves the pass rate

**Verify stale-branch fix** — The 3-fixes commit (Aug 11 10:19)
already addressed branch deletion ordering. The 14 stale-branch
failures were from a batch that ran BEFORE the fix. Run a clean
batch to confirm the fix works. No new code needed — just a
verification run.

**Agent early-stop** — 3 of 5 remaining failures are the agent
stopping mid-pipeline ("missing 1", "missing 14", "missing 32"
gates). This is the single biggest unsolved problem. The
orchestrator prevents step-skipping but can't prevent the agent
from running out of context or timing out. Investigate: are these
context exhaustion, API timeouts, or agent satisficing? The answer
determines the fix.

## Production hardening (for real users, not pass rate)

**Pre-push hook cleanup** — Script backs up existing hook but
never restores. Hook persists indefinitely after rebase, blocking
`git push` in the target repo. Add restore to step5 cleanup and
ERR trap.

**Hook session guards** — The 3 markdown hooks block `go mod tidy`,
`git push`, and vendor edits in ALL repos during any Claude Code
session. No one has hit this yet (pre-release), but it will be the
first friction point when real users install the plugin. Add
`.session-active` check.

**GPG signing** — Set `GIT_CONFIG_COUNT` with `commit.gpgsign=false`
early in scripts. No observed failures, but common Red Hat config
that would silently break commits. Defensive fix.

**Force-advance counter** — Clear on fresh `cmd_init`. Real bug
but untestable with current harness (worktrees create fresh state).
Matters for production users who crash and retry.

**Resume version mismatch** — Error if stored version differs.
Can't happen in test harness (always starts fresh) but will happen
to production users.

## Gate work

### Fix existing companion script bugs (verified)
All 3 bugs confirmed by per-file code review:
- `major-version-imports.sh` lines 25, 51: args to `base_file_has`
  are swapped (pattern where file should be). Pre-existing
  detection always fails — every issue flagged as NEW.
- `crd-validation.sh` line 27, `patterns-completeness.sh` line 17:
  `$pre` initialized to 0, never incremented. PRE_EXISTING=0 always.
- Both scripts also don't use `gate-script-lib.sh`.

### Deterministic gate expansion (verified per-gate)
Reduces agent calls 27% (33→25). Steps 2/3 need "launch only
PENDING" pattern (step 4 already does this). Never flaked in
299 runs — prevents future risk. ~4 hours for 8 scripts.

| Gate | Effort | Script does | Verified |
|------|--------|-------------|----------|
| build-vet-recheck | 20 min | same logic as build-vet.sh, own file | step4 doesn't reference step2's .sh |
| cleanliness | 20 min | git status + find + git ls-files | ~32 lines not 25 |
| diff-scope | 30 min | changed files × extension whitelist | pure filter, no commit classification |
| test-compilation | 30 min | `go test -run='^$' -count=0` | zero judgment needed |
| feature-gates | 30 min | grep KUBE_FEATURE_ vs vendor | string existence, not semantic |
| rebase-completeness | 45 min | result file + git log + go.mod | all 5 checks mechanical |
| deprecated-imports | 45 min | grep x/ imports (hardcoded table) | go doc is optional, not required |
| dep-cve-check | 1 hr | diff go.sum, curl OSV.dev | always-PASS, all steps deterministic |

Note: `version-completeness` was reclassified from Tier 1 to
Tier 2 — requires prose-vs-code judgment and per-finding ancestry
checks that need AI interpretation.

### Gate consolidation (verified)
- **Drop `logical-completeness` (step3)** — step4's
  `logical-consistency` is a strict superset. Step3 adds nothing
  unique. Reduces gate count 33→32.
- **Narrow `deprecated-api-remnants`** — duplicates build-vet
  (build+vet), deprecated-imports (x/ checks), and partially
  deprecated-calls. Unique value: web-search discovery only.

### Tier 2 evidence scripts (after Tier 1)
Top 3 ranked by scriptable percentage:
1. `deprecated-calls` (90%) — staticcheck + pre-existing filter
2. `autofix-result` (85%) — commit counting + build pass/fail
3. `gomod-diff-analysis` (75%) — parse go.mod diff
Also: `version-completeness` (reclassified from Tier 1)

### Tier reclassification (verified)
3 "Tier 3" gates have scriptable evidence phases: ci-prediction,
maintainer-review, skill-improvement → Tier 2. True Tier 3 = 7.
