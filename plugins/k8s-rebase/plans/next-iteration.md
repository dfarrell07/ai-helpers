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
gate (6 exist). The *orchestrator* is the state machine that enforces
step ordering. The *court* is the test harness's adversarial AI
review that compares output against a known-good human rebase.
*spec=none* is the production test mode (all automation enabled).

## Definition of done

1. Zero infra failures on 10 diverse repos (vendored + non-vendored,
   with + without codegen, single + multi-module)
2. Every successful run produces a PR command (step5 race fixed)
3. Gate stale-detection works (HEAD SHA in reports)
4. `--preflight` command validates repo compatibility before starting
5. One-page quickstart published
6. **3 end-to-end runs by a non-author — at least 1 on a complex
   repo and 1 on a repo the tester chooses, without Slack help**

## Fix: Ship blockers + bugs

Priority order. Items marked **(now)** are under 15 minutes each.

### Step5 / stop-hook race condition **(now)**
Orchestrator returns `DONE` after step4, but step5 (PR command
generation) runs after DONE. If the agent exits between them, the
rebase completes with no PR command.
**Fix:** Don't report DONE until `.rebase-tmp/rebase-report.json`
exists. ~10 lines in orchestrator.

### Gate report HEAD SHA **(now)**
`report_is_fresh()` is dead code — reports have no HEAD line, so
stale detection always returns "fresh." Users can fix code and the
orchestrator still shows old verdicts.
**Fix:** Add `echo "HEAD: $(git rev-parse HEAD)"` to
`write-gate-report.sh`.

### Force-advance counter persistence **(now)**
`.advance-attempts-stepN` files survive crashes. Third session
force-advances on first attempt.
**Fix:** Clear on `cmd_init`.

### GPG signing in container **(now)**
Users with `commit.gpgsign=true` (common at Red Hat) get silent
commit failures inside the container — no GPG agent forwarded.
Every commit fails, script continues, branch has zero history.
**Fix:** Override via `GIT_CONFIG_COUNT` (pattern already exists
for `safe.directory`). Apply in both `k8s-rebase.sh` and
`k8s-rebase-autofix.sh`.

### Stale-branch detection redesign (test harness)
63% of test failures. Root cause: detection compares commit
timestamps (old commits on new branches look "stale"). Fix: use
reflog-based branch creation time. Also fix branch deletion
ordering (reset to default branch BEFORE deleting bump branch).
**File:** `test/test-skill.sh`. ~1-2 hours.

### Concurrent run protection **(now)**
Two simultaneous runs on the same repo corrupt state (last-writer-
wins on state.json, gate reports overwrite). Use `flock` on
`.rebase-tmp/.lock` in `cmd_init`. Write PID into `.session-active`.

### Orchestrator empty array crash
Line 325 iterates arrays that may be empty under `set -u` in
bash < 4.4. Use `"${arr[@]:+"${arr[@]}"}"`.

### block-module-ops.md session guard
Hook fires unconditionally — blocks `go mod tidy` even when no
rebase is active. Original plan required `.session-active` check.
Add it.

### Resume version mismatch
`cmd_init` on resume ignores the version argument. Warn if stored
version differs from argument.

### Autofix signal cleanup
`RESULT: FAIL` -> `RESULT: ITEMS_REMAINING` (FAIL is misleading —
remaining items are normal).

### Auto-PASS informational gates in orchestrator
4 gates are always-PASS by design (`commit-messages`, `dep-cve-check`,
`maintainer-review`, `skill-improvement`) but still require an AI
agent call each — 4 flaky calls per run for zero value. Add an
`INFO_GATES` list in the orchestrator; auto-write PASS reports
without launching subagents.

### Court juror forced verification (test harness)
Zero of ~15 jurors across 5 court sessions used their tool access
(git show, Read) before voting. The court is rubber-stamping. Add
~5 lines to the juror prompt in `test-skill.sh` requiring at least
one tool call + a VERIFIED: line before verdict. Cheapest high-
impact fix for test quality.

### Small fixes
- `count_reports` (orchestrator lines 93-98) never called. Delete.
- `maintainer-review.md` line 27 says FAIL but it's always-PASS.
- Add fail_code column to results.tsv (INFRA/GATE/COURT) — only
  way to distinguish failure types at scale. Header row too.

### Force-advance visibility
INCOMPLETE file content must appear in the PR description so
reviewers know gates were skipped. Add `K8S_REBASE_NO_FORCE_ADVANCE=1`
env var for production use (test harness force-advances, humans
shouldn't).

### Double-advance cleanup
Step agents and SKILL.md both call `advance` (idempotent, harmless,
but confusing). Pick one owner — recommend step agents own it for
self-containment. Add bash block to step3 matching step1/step2.

## Build: Companion scripts + DX

### 3 new companion scripts
`cleanliness.sh` (git status), `diff-scope.sh` (file extension
classification), `commit-messages.sh` (line length + prefix regex).
All use `gate-script-lib.sh`. Brings total to 9/33 deterministic.
Also: migrate `crd-validation.sh` to `gate-script-lib.sh` (predates
the library).

### Feature gate auto-discovery
Replace hardcoded `GATE_DEPS` map with runtime parsing of
`vendor/k8s.io/client-go/features/known_features.go`. Discovers
Default:true gates, filters LockToDefault:true. Eliminates
per-release maintenance. Most complex item — 1-2 days. Must also
handle non-vendored repos (`$GOMODCACHE` instead of `vendor/`).

### Quickstart guide
One page in the README: prerequisites, first run commands, what
each step does in one sentence, common failures, when to intervene.
Safety guarantees up front: never pushes, all work on a new branch,
you review before pushing.

### Preflight command
`scripts/k8s-rebase-preflight.sh` — validates without modifying:
- go.mod has k8s.io deps, default branch exists, tree is clean
- Go or container runtime available
- Blocked deps (library-go, openshift/api rebased to target?)
- `go.work` detection (warn: not yet supported)
- Disk space (~1GB free needed)

### Human-readable progress
Users stare at opaque key-value output for 30 minutes with no idea
what's happening. Emit human-friendly progress to stderr alongside
machine-parseable output on stdout (test harness parses stdout).
"Step 2/5: Compilation (gate 3/8: go-vet) — 4m elapsed."

### Escape hatches
`skip-gate <repo> <gate>` — mark one gate as SKIP without
force-advancing the entire step. `rollback <repo>` — clean branch
and state files. Translate gate failures into remediation hints in
`status` output ("FAILING: go-vet — run `go vet ./...` locally").

### Known limitations doc
What repo shapes are NOT supported: `go.work` workspaces, repos
without k8s.io deps, library-go blockers, custom build systems,
operator-sdk bundle regeneration (agent handles, no automation).

## Scale (after it works)

### Testing strategy
3 tiers: **Court** (6-10 canary repos with known-goods, full gates
+ adversarial review), **Gates-only** (20-30 repos, no court),
**Smoke** (everything else, steps 1-2 only — bump + build). CI
gate on skill PRs runs Tier 1. Tier 2/3 nightly.

### Batch execution
Default `MAX_CONCURRENT=10`. `flock` on results.tsv writes.
Pre-pull Go container image before batch runs. Cache proxy check
result. `GOMODCACHE` warm-up phase.

### Go forward-compatibility
Set `GOTOOLCHAIN=local` alongside `GOWORK=off`. Detect `go.work`
at repo root (error until supported). Warn when `replace` directives
override freshly-bumped requires (silent wrong resolution otherwise).

### Discovery procedures
Version-specific recipes (e.g., "k8s 1.36 removes --bounding-dirs")
rot every release cycle. Without version-agnostic detection, every
k8s release requires manual skill updates. Build detection via:
vendor probing for deprecated APIs, GitHub API for e2e infra
versions, Go version vs lint version matrix for compatibility.

### Model-version coupling
Log model ID per run. Watch Tier 1 pass rates after model updates.
If regression detected, pin to last-known-good model version.

### Upstream community
Never send unsolicited AI-generated PRs to upstream repos. Require
explicit maintainer opt-in (open an issue first). Some projects
reject AI contributions on principle.

## Not yet

- Multi-repo coordinator (dependency-ordered batch execution,
  `depends_on` in config.yaml — operator's #1 need for 30+ repos)
- Fleet dashboard (blocked/in-progress/pass/fail per repo)
- Draft PR creation + CI monitoring loop
- `--dry-run` mode (preview without modifying)
- Downstream handling (openshift/ovn-kubernetes OTE module)
- License scan gate (`go-licenses` before PR — catches incompatible
  licenses from new transitive deps)
- Feature gate policy (flag for human review vs silently disable —
  upstream needs these breakage reports)
- Builder image validation (check ART image availability before
  updating Dockerfile refs — prevents silent CI breakage)
