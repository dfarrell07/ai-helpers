# Plan: k8s-rebase Next Iteration

## What this is

Automates k8s.io/* dependency rebases for Go projects. Works on
6 repos × 3 k8s versions. 299 test runs: 191 PASS (64%), 108 FAIL.

Pass rate by day tells the real story:
- Jul 29-31: 40-61% (early testing, many harness bugs)
- Aug 1-7: 50-100% (fixes landing, peaking at 100% on Aug 7)
- Aug 8: 72% (large batch, mostly good)
- Aug 9: 47% (regression — ovnk "missing gates" cluster)
- Aug 10: 100% (10/10, recovery)
- Aug 11: 53% raw, **81% excluding stale-branch batch**

Aug 11's drop is one batch run (06:00-10:30) that hit the branch
deletion ordering bug 14 times. Excluding it: 22/27 = 81%.

Failure breakdown (108 total):
- 44 gate failures (AI gates flaking — 1-10 per run)
- 38 missing gates (agent stopped mid-pipeline, especially ovnk)
- 20 stale branch (test harness branch cleanup bug)
- 6 other

ovn-org/ovn-kubernetes is the outlier: 42% pass rate, 24 of 42
failures are "missing 26 gates" = agent stopped after step2. All
other repos are 63-73%. The "missing gates" problem is
non-deterministic — same repo passes and fails on the same day.

## Fix

### Quick wins

**GPG signing** — Set `GIT_CONFIG_COUNT` with `commit.gpgsign=false`
EARLY in `k8s-rebase.sh` and autofix (before the container check,
so it works for both host and container paths). 2 lines per script.

**HEAD SHA** — Add `echo "HEAD: $(git rev-parse HEAD)"` to
`write-gate-report.sh`. Enables stale detection (currently
silently disabled).

**Force-advance counter** — Clear `.advance-attempts-step*` on
fresh `cmd_init`. On resume with version mismatch, delete
`.rebase-tmp/` entirely and start fresh.

**Auto-PASS style gates** — `maintainer-review` and
`commit-messages` are style-only, always PASS. Auto-write reports
in orchestrator, skip agent calls.

**Hook session guards** — All 3 markdown hooks (block-module-ops,
block-push, block-vendor-edit) lack session guards. They block
`go mod tidy`, `git push`, and vendor edits in ALL repos during
ANY Claude Code session — not just during rebases. Add
`.rebase-tmp/.session-active` check to each. If absent, ALLOW.

### Other fixes

**Resume version mismatch** — Error if stored version differs
from argument. Include cleanup command in error message
(`rm -rf .rebase-tmp`).

**Force-advance: surface, don't suppress** — The INCOMPLETE file
is dead (nothing reads it). The advance counter tracks `advance`
calls, not gate retries — can fire accidentally. Fix: (1) have
step5 read `.rebase-tmp/status/INCOMPLETE` and add a WARNING
section to the PR body listing skipped gates, (2) count gate
re-evaluation cycles not advance calls, (3) suggest `--draft`
PR when gates were skipped. A draft PR with documented skips is
better than no PR.

**Pre-push hook cleanup** — Script backs up existing hook but
never restores. Hook persists indefinitely after rebase. Add
restore to step5 cleanup and ERR trap. Stop-hook should also
clean up `.session-active` on orchestrator crash (currently
blocks exit if orchestrator dies).

### Test harness (do alongside quick wins)

**Stale-branch detection** — 20/108 failures (19%). Root cause:
`cmd_run` deletes branches BEFORE `reset_to_default`, so
`git branch -D` silently fails. Fix: 2-line reorder.

**Court juror enforcement** — Add ~2 lines to reject output
missing VERIFIED: line. Impacts 10 of 12 matrix cells.

## Build

### Companion script
`cleanliness.sh` (git status + find). Brings deterministic
gates to 7/33. Migrate `crd-validation.sh` to `gate-script-lib.sh`.

### README safety guarantees
Add "never pushes to remote, all work on a new branch, you review
before merging."
