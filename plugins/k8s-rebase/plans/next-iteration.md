# Plan: k8s-rebase Next Iteration

## What this is

Automates k8s.io/* dependency rebases for Go projects. Works on
9 repos, 54% of test runs hit infra bugs. Goal: any engineer can
rebase any supported repo without help.

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

### Other fixes

**Resume version mismatch** — Error if stored version differs
from argument. Include cleanup command in error message
(`rm -rf .rebase-tmp`).

**Force-advance default** — Default should be stop on gate
failure. Test harness opts into force-advance via env var.
Per-repo opt-in for flaky repos like ovnk.

**Pre-push hook restore** — Script backs up existing hook but
never restores. Add restore to step5 cleanup and ERR trap.

### Test harness (do alongside quick wins)

**Stale-branch detection** — 63% of test failures. Delete old
bump branches before launching (cleanup-first, version-scoped).
Fix branch deletion ordering. `test/test-skill.sh`.

**Court juror enforcement** — Add ~2 lines to reject output
missing VERIFIED: line. Impacts 10 of 12 matrix cells.

## Build

### Companion script
`cleanliness.sh` (git status + find). Brings deterministic
gates to 7/33. Migrate `crd-validation.sh` to `gate-script-lib.sh`.

### README safety guarantees
Add "never pushes to remote, all work on a new branch, you review
before merging." Known limitations belong in SKILL.md/scripts as
validation checks, not README prose.
