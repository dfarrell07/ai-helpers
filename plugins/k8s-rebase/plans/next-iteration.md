# Plan: k8s-rebase Next Iteration

## What this is

Automates k8s.io/* dependency rebases for Go projects (~$35/repo vs
~$400 manual). Works on 9 repos, 54% of test runs hit infra bugs.
Goal: any engineer can rebase any supported repo without help.

**Glossary:** 5-step pipeline: bump deps, fix compilation, autofix
patterns, lint+test+review, generate PR command. *Gate* = pass/fail
check (33 total). *Companion script* = deterministic bash gate
(6 exist). *Orchestrator* = state machine enforcing step ordering.
*Force-advance* = orchestrator gives up after 3 attempts, marks
INCOMPLETE.

## Definition of done

1. Zero infra failures on 10 diverse repos
2. Every successful run produces a PR command
3. Gate stale-detection works (HEAD SHA in reports)
4. `--preflight` validates repo compatibility
5. One-page quickstart published
6. **3 end-to-end runs by a non-author, without Slack help**

## Fix

Quick wins first, test harness last.

### Quick wins (each under 15 min)

**GPG signing** — Increment `GIT_CONFIG_COUNT` to 3, add
`commit.gpgsign=false` + `tag.gpgsign=false`. `k8s-rebase.sh`
and autofix.

**GOTOOLCHAIN=local** — Add alongside `GOWORK=off` in all scripts.
Without it, Go auto-downloads toolchains mid-run.

**Step5 race** — Don't report DONE until
`.rebase-tmp/rebase-report.json` exists. Orchestrator.

**HEAD SHA** — Add `echo "HEAD: $(git rev-parse HEAD)"` to
`write-gate-report.sh`. Enables stale detection.

**Force-advance counter** — Clear `.advance-attempts-step*` on
`cmd_init`. Prevents third-session silent skip.

**Empty array crash** — Line 325, use
`"${arr[@]:+"${arr[@]}"}"`. Bash <4.4 compatibility.

**Auto-PASS info gates** — `dep-cve-check`, `maintainer-review`,
`skill-improvement`, `commit-messages` always PASS. Auto-write
reports in orchestrator, skip agent calls.

### Other fixes

**block-module-ops session guard** — Blocks `go mod tidy` outside
rebases. Add `.session-active` check.

**Force-advance visibility** — Surface INCOMPLETE in PR description.
Add `K8S_REBASE_NO_FORCE_ADVANCE=1` env var.

**Resume version mismatch** — Warn if stored version differs from
argument on resume.

**Housekeeping** — Delete dead `count_reports`. Fix
maintainer-review FAIL/PASS contradiction. Rename autofix
`RESULT: FAIL` to `ITEMS_REMAINING`. Add fail_code to results.tsv.
Add advance bash block to step3. Restore pre-push hook on cleanup.

### Test harness (do alongside quick wins)

**Stale-branch detection** — 63% of test failures. Replace
commit-timestamp check with reflog-based branch creation time.
Fix branch deletion ordering. `test/test-skill.sh`.

**Court juror verification** — Add ~5 lines requiring tool call +
VERIFIED: line before verdict. `test/test-skill.sh`.

## Build

### Companion scripts
`cleanliness.sh` and `diff-scope.sh`. Brings deterministic gates
to 8/33. Migrate `crd-validation.sh` to `gate-script-lib.sh`.

### Feature gate auto-discovery
Replace hardcoded `GATE_DEPS` with runtime parsing of
`known_features.go`. Discovers Default:true, filters LockToDefault.
Handle non-vendored repos via `$GOMODCACHE`. **Riskiest item —
build with fallback to hardcoded map if parsing fails.**

### Go forward-compatibility
Detect `go.work` at repo root (error until supported). Warn when
`replace` directives override freshly-bumped requires.

### Quickstart + known limitations
One page in README. Prerequisites, first run, safety guarantees.
Limitations: `go.work`, indirect-only k8s deps, library-go
blockers, custom builds, operator-sdk bundles.

### Preflight command
`k8s-rebase-preflight.sh` — validates without modifying: go.mod
has k8s.io deps, clean tree, Go/container available, blocked deps,
disk space.

### Human-readable progress
Emit progress to stderr alongside machine-parseable stdout.

### Escape hatches
`skip-gate` (skip one gate without force-advancing step),
`rollback` (clean branch + state), remediation hints in `status`.
