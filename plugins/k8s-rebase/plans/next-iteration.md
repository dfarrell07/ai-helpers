# Plan: k8s-rebase Next Iteration

## What this is

k8s-rebase automates Kubernetes dependency rebases for Go projects.
Every quarter, 100+ OpenShift repos need k8s.io/* bumps — a chore
that costs ~$400/repo in engineer time ($40,000/quarter). This skill
does it for ~$35/repo ($4,200/quarter), producing a PR-ready branch
with separate commits for deps, codegen, version refs, and code fixes.

It works today on 9 repos with zero step-skipping and zero gate
quality failures. But 54% of test runs hit infrastructure bugs
(primarily stale-branch detection in the test harness). This plan
takes it from "works on author's repos" to "a non-author can
rebase any supported repo without help."

**Glossary:** A *gate* is a pass/fail verification check (33 total).
A *companion script* is a deterministic bash replacement for an AI
gate (6 exist today). The *orchestrator* is the bash state machine
that enforces step ordering — it won't advance until all gates pass.
The *court* is the test harness's adversarial review: prosecution,
defense, 3 jurors, and a judge compare output against a known-good
human rebase. *Force-advance* is when the orchestrator gives up
after 3 failed attempts and proceeds anyway (marks INCOMPLETE).
*spec=none* means the skill runs with all automation enabled
(production mode); *spec=all* disables autofix recipes to test
whether the AI can solve independently (diagnostic mode).

## Definition of done

1. Zero infra failures on 10 diverse repos (vendored + non-vendored,
   with + without codegen, single + multi-module)
2. Every successful run produces a PR command (requires fixing the
   step5/stop-hook race condition)
3. Gate stale-detection works (HEAD SHA in reports)
4. `--preflight` command validates repo compatibility before starting
5. One-page quickstart published
6. **3 end-to-end runs by a non-author — at least 1 on a complex
   repo and 1 on a repo the tester chooses, without Slack help**

## Fix: Ship blockers + bugs

Ordered by impact on pass rate. The **(quick)** tag means under
15 minutes. Stale-branch is first because it alone should move
the pass rate from 54% to ~85%.

### Stale-branch detection redesign (test harness)
63% of test failures — single biggest pass-rate blocker. Root
cause: detection compares commit timestamps (old commits on new
branches look "stale"). Fix: use reflog-based branch creation
time. Fallback for shallow clones: 5-minute grace window. Also
fix branch deletion ordering (reset to default branch BEFORE
deleting bump branch).
**File:** `test/test-skill.sh`

### Step5 / stop-hook race condition **(quick)**
Orchestrator returns `DONE` after step4, but step5 (PR command
generation) runs after DONE. If the agent exits between them,
the rebase completes with no PR command.
**Fix:** Don't report DONE until `.rebase-tmp/rebase-report.json`
exists.

### Gate report HEAD SHA **(quick)**
`report_is_fresh()` is dead code — reports have no HEAD line, so
stale detection always returns "fresh." Users fix code and the
orchestrator still shows old verdicts.
**Fix:** Add `echo "HEAD: $(git rev-parse HEAD)"` to
`write-gate-report.sh`.

### Force-advance counter persistence **(quick)**
`.advance-attempts-stepN` files survive crashes. Third session
force-advances on first attempt.
**Fix:** Clear on `cmd_init`.

### GPG signing in container **(quick)**
Users with `commit.gpgsign=true` (common at Red Hat) get silent
commit failures — no GPG agent in container. Every commit fails,
script continues, branch has zero history.
**Fix:** Override via `GIT_CONFIG_COUNT` (pattern already exists
for `safe.directory`). Apply in `k8s-rebase.sh` and autofix.

### Orchestrator empty array crash **(quick)**
Line 325 iterates arrays that may be empty under `set -u` in
bash < 4.4. Use `"${arr[@]:+"${arr[@]}"}"`.

### Auto-PASS informational gates **(quick)**
4 gates are always-PASS by design (`dep-cve-check`,
`maintainer-review`, `skill-improvement`, `commit-messages`) but
still spawn an AI agent each — 4 flaky calls for zero value.
Auto-write PASS reports in the orchestrator without launching
subagents.

### block-module-ops.md session guard
Hook fires unconditionally — blocks `go mod tidy` even when no
rebase is active. Add `.session-active` check.

### Resume version mismatch
`cmd_init` on resume ignores the version argument. Warn if stored
version differs from argument.

### Force-advance visibility
INCOMPLETE file content must appear in the PR description so
reviewers know gates were skipped. Add `K8S_REBASE_NO_FORCE_ADVANCE=1`
env var for production use.

### Court juror forced verification (test harness)
Zero jurors used their tool access before voting. Add ~5 lines to
the juror prompt requiring at least one tool call + VERIFIED: line.

### Small fixes
- `count_reports` (orchestrator lines 93-98) never called. Delete.
- `maintainer-review.md` line 27 says FAIL but it's always-PASS.
- `RESULT: FAIL` -> `RESULT: ITEMS_REMAINING` in autofix.
- fail_code column in results.tsv (INFRA/GATE/COURT). Header row.
- Double-advance: step agents and SKILL.md both call advance
  (harmless — idempotent — but confusing). Add bash block to
  step3 matching step1/step2 for consistency.

## Build: Companion scripts + DX

### 2 new companion scripts
`cleanliness.sh` (git status + find) and `diff-scope.sh` (file
extension classification). Both use `gate-script-lib.sh`. Brings
total to 8/33 deterministic. Also: migrate `crd-validation.sh` to
`gate-script-lib.sh` (predates the library).

### Feature gate auto-discovery
Replace hardcoded `GATE_DEPS` map with runtime parsing of
`vendor/k8s.io/client-go/features/known_features.go`. Discovers
Default:true gates, filters LockToDefault:true. Eliminates
per-release maintenance. Must also handle non-vendored repos
(`$GOMODCACHE` instead of `vendor/`). Most complex item — 1-2 days.

### Go forward-compatibility
These are prerequisites for working on diverse repos, not scale
polish:
- Set `GOTOOLCHAIN=local` alongside `GOWORK=off` in all scripts
- Detect `go.work` at repo root (error until supported)
- Warn when `replace` directives override freshly-bumped requires

### Quickstart guide
One page in the README: prerequisites, first run commands, what
each step does in one sentence, safety guarantees (never pushes,
new branch, you review before pushing), common failures.

### Preflight command
`scripts/k8s-rebase-preflight.sh` — validates without modifying:
- go.mod has k8s.io deps, default branch exists, tree is clean
- Go or container runtime available
- Blocked deps (library-go, openshift/api already rebased?)
- `go.work` detection (warn: not supported yet)
- Disk space (~1GB free needed)

### Human-readable progress
Users stare at opaque key-value output for 30 minutes. Emit
human-friendly progress to stderr alongside machine-parseable
stdout. "Step 2/5: Compilation (gate 3/8: go-vet) — 4m elapsed."

### Escape hatches
`skip-gate <repo> <gate>` — mark one gate as SKIP without
force-advancing the entire step. `rollback <repo>` — clean branch
and state files. Translate gate failures into remediation hints.

### Known limitations doc
What repo shapes are NOT supported: `go.work` workspaces, repos
without k8s.io deps, library-go blockers, custom build systems,
operator-sdk bundle regeneration (agent handles, no automation).

## Scale (after it works)

### Testing tiers
**Court** (6-10 canary repos, full gates + adversarial review),
**Gates-only** (20-30 repos, no court), **Smoke** (everything
else, steps 1-2 only). CI gate on skill PRs runs Court tier.

### Batch execution
Default `MAX_CONCURRENT=10`. `flock` on results.tsv writes.
Pre-pull Go container image. Cache proxy check. GOMODCACHE warm-up.

### Upstream community
Never send unsolicited AI-generated PRs to upstream repos. Require
explicit maintainer opt-in (open an issue first).
