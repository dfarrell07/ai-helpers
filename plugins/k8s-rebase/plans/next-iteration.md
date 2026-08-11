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

### Fix existing companion script bugs
3 bugs in the 6 existing scripts (found by code review):
- `major-version-imports.sh`: args swapped in `base_file_has` —
  pre-existing detection is completely broken
- `crd-validation.sh`, `patterns-completeness.sh`: dead `$pre`
  variable — PRE_EXISTING always reports 0
- `crd-validation.sh`, `patterns-completeness.sh` don't use
  `gate-script-lib.sh` — inconsistent with the other 4

### Deterministic gate expansion
Core principle: deterministic gates can't flake and can't regress
with model updates. Scripting Tier 1 gates also reduces agent
calls by 27% (33→24 per run), which helps with early-stop by
reducing context pressure. Steps 2 and 3 need updating to "launch
only PENDING gates" (like step 4 already does) for savings to
materialize.

Tier 1 gates have NEVER flaked in 299 runs — they always PASS.
Scripting them prevents future risk and reduces agent calls.
~385 lines total, ~5 hours effort.

| Gate | Effort | Script does |
|------|--------|-------------|
| build-vet-recheck | 10 min | symlink/source build-vet.sh |
| cleanliness | 20 min | git status + find + git ls-files |
| diff-scope | 30 min | changed files × extension whitelist |
| test-compilation | 30 min | `go test -run='^$' -count=0` |
| feature-gates | 30 min | grep KUBE_FEATURE_ vs vendor |
| rebase-completeness | 45 min | result file + git log + go.mod |
| deprecated-imports | 45 min | grep x/ imports, go doc each |
| version-completeness | 1 hr | grep stale version strings |
| dep-cve-check | 1 hr | diff go.sum, curl OSV.dev |

### Gate consolidation
- `deprecated-api-remnants` duplicates 3 other gates (build+vet
  from build-vet, x/ imports from deprecated-imports, staticcheck
  from deprecated-calls). Narrow to its unique value: web-search
  discovery of undocumented deprecations.
- `logical-completeness` (step3) and `logical-consistency` (step4)
  overlap significantly (both trace data flow in modified
  functions). Consider merging into one step4 gate.

### Tier 2 evidence scripts (after Tier 1)
Top candidates ranked by how much is scriptable:
1. `deprecated-calls` (90%) — staticcheck + pre-existing filter
2. `autofix-result` (85%) — commit counting + build pass/fail
3. `gomod-diff-analysis` (75%) — parse go.mod diff

### Tier 3 reclassification
3 gates classified as "fully agentic" actually have scriptable
evidence phases: ci-prediction, maintainer-review,
skill-improvement. They should be Tier 2 (script gathers evidence,
AI judges). True Tier 3 is 7 gates, not 10.
