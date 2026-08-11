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

## Deterministic gate expansion (18% → ?)

The original architecture plan called for 19 of 33 gates to be
fully deterministic (companion .sh scripts). 6 were built. Gate
flakes went 29→15→0 — the orchestrator refactor eliminated flakes
before the scripts could, so urgency dropped. But the principle
holds: a deterministic gate can never flake, and 27 gates still
rely on AI judgment that could regress with model updates.

Remaining Tier 1 gates (straightforward to script):
- `cleanliness` — git status + find + git ls-files
- `rebase-completeness` — file checks, git log, go.mod grep
- `test-compilation` — go test -run='^$' -count=0
- `autofix-result` — git log + go build exit code
- `feature-gates` — grep KUBE_FEATURE_ vs vendor
- `deprecated-imports` — grep for promoted x/ packages
- `version-completeness` — grep for stale version strings

7 scripts would bring coverage to 13/33 (39%). The 4 always-PASS
info gates (commit-messages, dep-cve-check, maintainer-review,
skill-improvement) could auto-PASS if flakes return.
