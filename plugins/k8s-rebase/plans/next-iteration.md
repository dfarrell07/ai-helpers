# Plan: k8s-rebase Next Iteration

## What this is

Automates k8s.io/* dependency rebases for Go projects. Works on
9 repos, 54% of test runs hit infra bugs. Goal: any engineer can
rebase any supported repo without help.

**Glossary:** 5-step pipeline: bump deps, fix compilation, autofix
patterns, lint+test+review, generate PR command. *Gate* = pass/fail
check (33 total). *Companion script* = deterministic bash gate
(6 exist). *Orchestrator* = state machine enforcing step ordering.
*Force-advance* = orchestrator gives up after 3 attempts, marks
INCOMPLETE.

## Definition of done

1. Zero infra failures on 10 diverse repos
2. Every successful run produces a PR command
3. Orchestrator rejects stale gate reports (HEAD SHA mismatch)
4. README has safety guarantees + known limitations section
5. **3 end-to-end runs by a non-author, without Slack help**

## Fix

### Quick wins (each under 15 min)

**GPG signing** — Add `-c commit.gpgsign=false` to every
`git commit` call in `k8s-rebase.sh` and autofix. (Not
GIT_CONFIG_COUNT — that block only runs in-container where
~/.gitconfig isn't mounted. The bug is on the HOST path.)

**HEAD SHA** — Add `echo "HEAD: $(git rev-parse HEAD)"` to
`write-gate-report.sh`. Without it, `report_is_fresh()` always
returns fresh — stale detection silently disabled.

**Force-advance counter** — Clear `.advance-attempts-step*` on
fresh `cmd_init` and on resume with version mismatch.

**Auto-PASS style gates** — `maintainer-review` and
`commit-messages` are style-only, always PASS. Auto-write reports
in orchestrator. Keep `dep-cve-check` and `skill-improvement` as
agent calls — they produce genuinely useful diagnostic output.

### Other fixes

**Resume version mismatch** — Error (not warn) if stored version
differs from argument on resume. Warn-and-continue produces
silent corruption.

**Remove force-advance from production** — Default should be stop
on gate failure, not silently advance. Test harness can opt-in to
force-advance via env var. A PR with skipped gates is worse than
no PR.

**Pre-push hook restore** — Script backs up existing hook but
never restores. Add restore to step5 cleanup and ERR trap.

**Dead code** — Delete unused `count_reports` function.

### Test harness (do alongside quick wins)

**Stale-branch detection** — 63% of test failures. Root cause:
compares commit timestamps of old branches. Fix: delete old
bump branches before launching (cleanup-first). Fix branch
deletion ordering. `test/test-skill.sh`.

**Court juror enforcement** — Prompt and tools already exist in
code. Add ~2 lines to reject output missing VERIFIED: line.

## Build

### Companion script
`cleanliness.sh` (git status + find — fully deterministic).
Brings deterministic gates to 7/33. Migrate `crd-validation.sh`
to `gate-script-lib.sh`.

### README improvements
Add explicit safety guarantees ("never pushes to remote, all work
on a new branch, you review before merging") and known limitations
section (`go.work`, indirect-only k8s deps, library-go blockers,
custom builds, operator-sdk bundles).
