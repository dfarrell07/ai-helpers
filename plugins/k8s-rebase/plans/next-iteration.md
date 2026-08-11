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

## Deterministic gate expansion

Core principle: deterministic gates can never flake and can't
regress with model updates. Gate flakes went 29→15→0, but 27
gates still rely on AI judgment.

Deep audit of all 33 gates classified them into 3 tiers:

**Tier 1 — Fully deterministic (9 gates, 3 scripted):**
All checks are shell commands with counting rules. No AI needed.

| Gate | Has .sh? | Script does |
|------|----------|-------------|
| rebase-completeness | no | result file + git log + go.mod grep |
| diff-scope | no | changed files × extension whitelist |
| test-compilation | no | `go test -run='^$' -count=0` per module |
| build-vet-recheck | no | reuse build-vet.sh |
| cleanliness | no | git status + find + git ls-files |
| dep-cve-check | no | diff go.sum, curl OSV.dev, grep imports |
| deprecated-imports | no | grep x/ imports, go doc each |
| feature-gates | no | grep KUBE_FEATURE_ vs vendor |
| version-completeness | no | grep stale version strings |

Scripting these 9 would bring Tier 1 coverage to 9/9 (100%).

**Tier 2 — Evidence + judgment (14 gates, 6 scripted):**
Script gathers deterministic evidence, fast-paths PASS when clean.
AI only judges flagged items. All 6 existing .sh scripts are Tier 2.

Unscripted Tier 2 gates that would benefit from evidence scripts:
autofix-result, deprecated-calls, deprecated-api-remnants,
e2e-infra, ci-readiness, correctness, commit-messages,
gomod-diff-analysis.

**Tier 3 — Fully agentic (10 gates, 0 scripted):**
Requires reading code, tracing data flow, or understanding natural
language. Cannot be scripted: fix-correctness, type-conversions,
autofix-diff-review, dep-release-notes, logical-completeness,
ci-prediction, k8s-changelog, logical-consistency,
maintainer-review, skill-improvement.
