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

## Incremental reliability

**Cleanliness companion script** — `cleanliness.sh` (git status +
find). Gate hasn't flaked yet but a deterministic script eliminates
the possibility permanently.
