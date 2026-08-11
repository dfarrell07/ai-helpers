# Plan: k8s-rebase Next Iteration

## What this is

Automates k8s.io/* dependency rebases for Go projects. Costs ~$35/repo
vs ~$400 manual. Works on 9 repos today with zero step-skipping and
zero gate quality failures. 54% of test runs hit infrastructure bugs
(stale-branch detection in the test harness). Goal: any engineer can
rebase any supported repo without help.

**Glossary:** The skill runs a 5-step pipeline: (1) bump deps +
codegen + version refs, (2) fix compilation, (3) apply autofix
patterns, (4) lint + test + adversarial review, (5) generate PR
command. *Gate* = pass/fail check (33 total, run per step).
*Companion script* = deterministic bash gate (6 exist, zero flake).
*Orchestrator* = bash state machine enforcing step ordering.
*Court* = test harness adversarial review (prosecution, defense,
3 jurors, judge) comparing output to a known-good human rebase.
*Force-advance* = orchestrator gives up after 3 attempts, proceeds
with INCOMPLETE marker. *Autofix* = deterministic fix patterns
applied by script before AI gates. *spec=none* = production test
mode (all automation enabled); *spec=all* = diagnostic (autofix
disabled, AI solves independently).

**Policy:** Never send unsolicited AI-generated PRs to upstream repos.
Require explicit maintainer opt-in. Some projects reject AI
contributions on principle.

## Definition of done

1. Zero infra failures on 10 diverse repos (vendored + non-vendored,
   with + without codegen, single + multi-module)
2. Every successful run produces a PR command (step5 race fixed)
3. Gate stale-detection works (HEAD SHA in reports)
4. `--preflight` validates repo compatibility before starting
5. One-page quickstart published (includes known limitations)
6. **3 end-to-end runs by a non-author — at least 1 on a complex
   repo and 1 on a repo the tester chooses, without Slack help**

## Fix: Bugs that break real users

User-facing severity first. Test harness bugs at the end.

### GPG signing in container **(quick)**
Users with `commit.gpgsign=true` (common at Red Hat) get silent
commit failures — no GPG agent in container. Every commit fails,
script continues, branch has zero history.
**Fix:** Increment `GIT_CONFIG_COUNT` (don't overwrite — the script
already sets count=1 for `safe.directory`). Add `commit.gpgsign=false`
and `tag.gpgsign=false` as keys 1 and 2 (count becomes 3). Apply
in `k8s-rebase.sh` and autofix.

### GOTOOLCHAIN=local **(quick)**
Without this, repos targeting a newer Go version auto-download a
toolchain mid-run — fails in air-gapped and container environments.
`GOWORK=off` is already set but `GOTOOLCHAIN=local` is missing.
**Fix:** Add `export GOTOOLCHAIN=local` alongside `GOWORK=off`
in all three scripts.

### Step5 / stop-hook race **(quick)**
Orchestrator returns `DONE` after step4, but step5 runs after.
Agent exits between them = rebase with no PR command.
**Fix:** Don't report DONE until `.rebase-tmp/rebase-report.json`
exists.

### Gate report HEAD SHA **(quick)**
`report_is_fresh()` is dead code — no HEAD line in reports, so
stale detection always returns "fresh." Old verdicts persist after
code changes.
**Fix:** Add `echo "HEAD: $(git rev-parse HEAD)"` to
`write-gate-report.sh`.

### Force-advance counter persistence **(quick)**
`.advance-attempts-stepN` files survive crashes. Third session
force-advances on first attempt.
**Fix:** Clear on `cmd_init`.

### Orchestrator empty array crash **(quick)**
Line 325 iterates arrays that may be empty under `set -u` in
bash < 4.4. Use `"${arr[@]:+"${arr[@]}"}"`.

### Auto-PASS informational gates **(quick)**
`dep-cve-check`, `maintainer-review`, `skill-improvement`,
`commit-messages` are always-PASS but still spawn an AI agent
each. Auto-write PASS reports in the orchestrator.

### block-module-ops.md session guard
Hook blocks `go mod tidy` even when no rebase is active. Add
`.session-active` check.

### Force-advance visibility
INCOMPLETE content must appear in PR description. Add
`K8S_REBASE_NO_FORCE_ADVANCE=1` env var for production use.

### Resume version mismatch
`cmd_init` on resume ignores version argument. Warn if different.

### Housekeeping
- `count_reports` never called — delete.
- `maintainer-review.md` says FAIL but it's always-PASS — fix.
- `RESULT: FAIL` -> `RESULT: ITEMS_REMAINING` in autofix.
- fail_code column in results.tsv (INFRA/GATE/COURT). Header row.
- Double-advance: add bash block to step3 for consistency.
- Pre-push hook cleanup: script overwrites `hooks/pre-push` but
  never restores the original. Add cleanup to step5 and ERR trap.

### Stale-branch detection redesign (test harness — do alongside quick wins)
63% of test failures. Does not affect real users, but without
fixing it the test suite can't verify the other fixes work.
Root cause: detection compares commit timestamps. Fix: use
reflog-based branch creation time (fallback: 5-min grace window).
Fix branch deletion ordering. `test/test-skill.sh`.

### Court juror forced verification (test harness only)
Zero jurors verify claims before voting. Add ~5 lines to juror
prompt requiring tool call + VERIFIED: line. `test/test-skill.sh`.

## Build: Make it reliable and general

### Companion scripts
`cleanliness.sh` (git status + find) and `diff-scope.sh` (file
extension classification). Brings deterministic gates to 8/33.
Also: migrate `crd-validation.sh` to `gate-script-lib.sh`.

### Feature gate auto-discovery
Replace hardcoded `GATE_DEPS` map with runtime parsing of
`vendor/k8s.io/client-go/features/known_features.go`. Discovers
Default:true, filters LockToDefault:true. Eliminates per-release
maintenance. Handle non-vendored repos via `$GOMODCACHE`.
**Risk:** Riskiest item in plan — the file's internal structure
is not a stable API. Parsing bug = silent wrong gate list. Build
with a fallback to the hardcoded map if parsing fails.

### Go forward-compatibility
- Detect `go.work` at repo root (error until supported)
- Warn when `replace` directives override freshly-bumped requires
(`GOTOOLCHAIN=local` moved to Fix — it breaks today in containers)

### Quickstart + known limitations
One page in README. Prerequisites, first run, what each step does,
safety guarantees (never pushes, new branch, you review).
Known limitations: `go.work`, repos with only indirect k8s.io deps,
library-go blockers, custom build systems, operator-sdk bundles.

### Preflight command
`scripts/k8s-rebase-preflight.sh` — validates without modifying:
go.mod has k8s.io deps, default branch exists, tree is clean,
Go or container runtime available, blocked deps check, disk space.

### Human-readable progress
Emit progress to stderr alongside machine-parseable stdout.
"Step 2/5: Compilation (gate 3/8: go-vet) — 4m elapsed."

### Escape hatches
`skip-gate <repo> <gate>` — skip one gate without force-advancing
the step. `rollback <repo>` — clean branch and state files.
Translate gate failures into remediation hints in `status` output.
