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

**GPG signing** — Increment `GIT_CONFIG_COUNT` to 3, add
`commit.gpgsign=false` + `tag.gpgsign=false`. `k8s-rebase.sh`
and autofix.

**GOTOOLCHAIN=local** — Add alongside `GOWORK=off` in all scripts.

**HEAD SHA** — Add `echo "HEAD: $(git rev-parse HEAD)"` to
`write-gate-report.sh`. Without it, `report_is_fresh()` always
returns fresh — stale detection silently disabled.

**Force-advance counter** — Clear `.advance-attempts-step*` on
fresh `cmd_init` and on resume with version mismatch.

**Empty array crash** — Line 325, use
`"${arr[@]:+"${arr[@]}"}"`. Bash <4.4 compatibility.

**Auto-PASS info gates** — `dep-cve-check`, `maintainer-review`,
`skill-improvement`, `commit-messages` always PASS. Auto-write
reports in orchestrator, skip agent calls.

### Other fixes

**Force-advance visibility** — Surface INCOMPLETE in PR description.
Add `K8S_REBASE_NO_FORCE_ADVANCE=1` env var.

**Resume version mismatch** — Warn if stored version differs from
argument on resume.

**Pre-push hook cleanup** — Script overwrites `hooks/pre-push`
but never restores. Add cleanup to step5 and ERR trap.

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

### Feature gate auto-discovery
Replace hardcoded `GATE_DEPS` with runtime parsing of
`known_features.go`. Discovers Default:true, filters LockToDefault.
Handle non-vendored repos via `$GOMODCACHE`. **Riskiest item —
build with fallback to hardcoded map if parsing fails.**

### README improvements
Add safety guarantees (never pushes, new branch, you review) and
known limitations section (`go.work`, indirect-only k8s deps,
library-go blockers, custom builds, operator-sdk bundles).
