# Plan: k8s-rebase Next Iteration

## Executive Summary

k8s-rebase automates Kubernetes dependency rebases for Go projects —
a quarterly chore that costs ~$400/repo in engineer time across 100+
OpenShift ecosystem repos ($40,000/quarter). The AI-driven skill
costs ~$35-42/repo ($4,200/quarter), optimizable to ~$20/repo. It
is working today on 9 repos with zero step-skipping and zero gate
quality failures, but 54% of test runs hit infrastructure bugs
(primarily stale-branch detection). This plan takes the skill from
"works on author's repos" to "production-ready for 100+ teams."

## Context

This plan incorporates findings from extensive adversarial review
(44 Opus agents across platform engineering, SRE, AI architecture,
Go ecosystem, testing, DX, security, cost, and completeness
perspectives). Current matrix results: 22 PASS / 19 FAIL. All
failures are infrastructure — zero gate-quality, zero step-skipping,
zero court rejections.

## Success Criteria

| Metric | Target | Current |
|--------|--------|---------|
| spec=none pass rate (all repos) | 90%+ | ~54% (infra-dominated) |
| spec=none pass rate (non-ovnk) | 85%+ | ~70% (stale-branch noise) |
| Infra failure count | 0 stale-branch | 12/19 |
| Step-skipping count | 0 | 0 (achieved) |
| Force-advance rate | <5% of runs | unknown |
| Cost per repo | <$50 | ~$35-42 |
| Wall-clock time | <60 min | ~30 min |
| Non-author can complete rebase | Yes | No |

## Phase 0: Ship blockers (do first — user-visible breakage)

### 0a. Step5 / stop-hook race condition
After step4 advances, orchestrator returns `DONE: true`. Stop hook
allows exit. But SKILL.md says "after DONE, read step5-pr.md." If
the agent exits between DONE and step5, the rebase completes with
no PR command — the entire deliverable is lost. Confirmed real:
`STEP_DIRS` has 4 entries; `step5-pr.md` is outside the state
machine.
**Fix:** Don't report DONE until step5 state marker exists
(`.rebase-tmp/rebase-report.json`). ~10 lines in orchestrator.
**File:** `scripts/k8s-rebase-orchestrator.sh`
**Effort:** 15 min

### 0b. write-gate-report.sh: Add HEAD SHA (promoted from 2c)
Stale detection in orchestrator is dead code — `report_is_fresh()`
always returns "fresh" because no HEAD line exists (confirmed:
lines 127-129). This undermines the entire gate system's correctness:
a user could fix code, re-run, and the orchestrator still shows
old PASS/FAIL verdicts.
Add: `echo "HEAD: $(cd "$REPO" && git rev-parse HEAD)"`
**File:** `scripts/write-gate-report.sh`
**Effort:** 5 min

### 0c. Force-advance counter persists across sessions (promoted)
`.advance-attempts-stepN` files survive crashes. A session that
crashes twice at step 2 will force-advance on the third session's
first attempt — silently skipping all step 2 gates.
**Fix:** Clear advance-attempt files on `cmd_init`.
**File:** `scripts/k8s-rebase-orchestrator.sh`
**Effort:** 5 min

### 0d. GPG signing silently corrupts all commits in container
Users with `commit.gpgsign=true` (common at Red Hat) hit silent
commit failure inside the container — no GPG agent, no keyring,
no socket forwarded. Every `git commit -s` fails silently. The
script catches failures and prints "WARNING: git commit failed"
but CONTINUES. Result: a dirty branch with go.mod changes but
zero commits, and the summary says "uncommitted changes exist."
The user gets a corrupted branch with no history.

**Fix:** Override GPG signing for the session at the top of
`k8s-rebase.sh`. The pattern already exists (lines 301-304 use
`GIT_CONFIG_COUNT` for `safe.directory`). Add:
```bash
export GIT_CONFIG_COUNT=$((${GIT_CONFIG_COUNT:-0} + 2))
export GIT_CONFIG_KEY_$((GIT_CONFIG_COUNT-2))=commit.gpgsign
export GIT_CONFIG_VALUE_$((GIT_CONFIG_COUNT-2))=false
export GIT_CONFIG_KEY_$((GIT_CONFIG_COUNT-1))=tag.gpgsign
export GIT_CONFIG_VALUE_$((GIT_CONFIG_COUNT-1))=false
```
Also apply in `k8s-rebase-autofix.sh` (same container path).
**File:** `scripts/k8s-rebase.sh`, `scripts/k8s-rebase-autofix.sh`
**Effort:** 10 min

### 0e. Concurrent run protection (no lockfile)
Two people running the tool on the same repo simultaneously
causes complete state corruption — `write_state` last-writer-wins,
gate reports overwrite each other, `git checkout -b` fails for
the second user. `.session-active` is a bare `touch` with no PID.

**Fix:** Use `flock` on `.rebase-tmp/.lock` in `cmd_init`. Write
PID into `.session-active`. Check for stale locks (PID no longer
running). Refuse to init if lock is held.
**File:** `scripts/k8s-rebase-orchestrator.sh`
**Effort:** 20 min

### 0f. Resolve double-advance architecture question
Step1 and step2 have `## Advance` bash blocks (step agents call
advance), AND SKILL.md tells the parent to call advance after each
step agent completes. Both fire — potential double-advance.
step3-autofix.md line 130 has prose-only advance (no bash block).
**Decision needed:** Either step agents own advance (remove from
SKILL.md) OR SKILL.md owns advance (remove from step files). Pick
one. Currently, orchestrator's `advance` is idempotent (bumping an
already-bumped step is a no-op), so the double call is harmless but
architecturally confusing.
**Recommendation:** Step agents own advance (consistent with step
file self-containment). SKILL.md becomes: launch agent, check
result, repeat. Add bash block to step3 matching step1/step2.
**File:** Multiple step files + SKILL.md
**Effort:** 30 min

## Phase 1: Unblock testing (63% of failures)

### 1a. Fix stale-branch detection (redesign)

**Root cause (verified by 4 agents):** Two failure modes:
1. Branch forked from old HEAD — `k8s-rebase.sh` creates `bump1.35`
   from `main`, tip commit is months old, detection says "stale"
2. Branch deletion fails — `cmd_run()` deletes branches BEFORE
   `reset_to_default`, git refuses to delete checked-out branch

**Detection redesign:** Replace commit-timestamp check (line ~903)
with reflog-based branch creation time.

```bash
# Before (broken): compares commit author time vs launch time
branch_tip_epoch=$(git log -1 --format='%ct' "$result_branch")

# After: compares branch creation time vs launch time
branch_created_epoch=$(git -C "$repo" reflog show "$result_branch" \
  --date=raw 2>/dev/null | tail -1 | awk '{print $NF}' | tr -dc '0-9')
```

**Edge case:** Shallow clones or freshly-created branches may have
empty reflog. Fallback: if reflog is empty, use the branch tip
timestamp but add 5-minute grace window (branches created in the
last 5 min are always "fresh").

**Ordering fix:** Move `reset_to_default "$repo"` BEFORE branch
deletion in `cmd_run()`.

**Also:** Add bump-branch cleanup to `cmd_clean()`.

**File:** `test/test-skill.sh`
**Effort:** 1-2 hours

### 1b. Add fail_code column to results.tsv

3 codes:

| Code | Covers |
|------|--------|
| `INFRA` | stale branch, crash, no branch, no gates, session died |
| `GATE` | missing gates, gate failures, gate flakes |
| `COURT` | court verdict FAIL |

**File:** `test/test-skill.sh`
**Effort:** 30 min

### 1c. Observability baseline (from original plan 4.7 — NOT DONE)
The original plan specified 4 observability features. None were
implemented. The minimum viable set for debugging at scale:

- **results.tsv header row**: Add column names so the file is
  self-documenting. Currently raw data with no schema.
- **fail_code column** (same as 1b — already planned)
- **model column**: Log which Claude model ran each test. Critical
  for model-version coupling detection (Phase 6a).

events.jsonl, suggestions.jsonl, `make suggestions`, and
`make improve` are deferred — they're Phase 5c prerequisites
but not needed for v1.0.
**File:** `test/test-skill.sh`
**Effort:** 30 min (alongside 1b)

## Phase 2: Fix confirmed bugs

### 2a. Orchestrator: empty array + set -u portability
Line 325 iterates `"${missing[@]}" "${stale[@]}" "${failing[@]}"` —
crashes if any array is empty under `set -u` in bash < 4.4.
(Lines 266, 319-321 use `${#arr[@]}` which is safe.)
Use `"${arr[@]:+"${arr[@]}"}"` (colon form).
**File:** `scripts/k8s-rebase-orchestrator.sh`
**Effort:** 15 min

### 2b. Resume version mismatch (demoted from Phase 0)
`cmd_init` on resume uses stored version, ignores the argument.
Cannot be hit on first run (no state file). User would notice
quickly (branch name reflects wrong version). Still worth fixing.
**Fix:** Compare stored vs argument, warn if different.
**File:** `scripts/k8s-rebase-orchestrator.sh`
**Effort:** 10 min

### 2c. Autofix signal cleanup
`k8s-rebase-autofix.sh` line 324: `RESULT: FAIL` -> `RESULT:
ITEMS_REMAINING`. Cosmetic but reduces confusion.
**File:** `scripts/k8s-rebase-autofix.sh`
**Effort:** 5 min

### 2d. Orchestrator: remove count_reports dead code
Lines 93-98 defined but never called. Delete.
**File:** `scripts/k8s-rebase-orchestrator.sh`
**Effort:** 2 min

### 2e. maintainer-review.md: Fix FAIL/PASS contradiction
Line 27 says "FAIL if scope creep" but line 54 says "always PASS."
Informational gate — fix line 27 to say always PASS.
**File:** `gates/step4-verification/maintainer-review.md`
**Effort:** 2 min

### 2f. block-module-ops.md: Add .session-active guard
Original plan (step-isolation-and-generality.md section 4.6)
explicitly required: "Add `.session-active` check so hook doesn't
interfere with non-rebase sessions." Not implemented — the hook
fires unconditionally whenever the plugin is installed. A developer
who has the plugin installed but is doing non-rebase Go work gets
blocked from running `go mod tidy` in any repo.
**Fix:** Check for `.session-active` in cwd's `.rebase-tmp/`.
If absent, ALLOW. Only block during active rebase sessions.
**File:** `hooks/block-module-ops.md`
**Effort:** 10 min

### 2g. Force-advance blast radius reduction (was 2f)
Force-advance after 3 attempts (line 293) sweeps gate failures
into an INCOMPLETE file that nothing reads. If step2 force-advances
with real build failures, steps 3-5 run against broken code.

**Fixes:**
- INCOMPLETE file content must propagate to step5 PR description
  (step5-pr.md reads `.rebase-tmp/status/INCOMPLETE` if it exists
  and adds WARNING section to PR body — agent-mediated, not
  orchestrator-injected)
- Add `--no-force-advance` flag for production use (test harness
  uses force-advance, humans don't)
- Per-gate skip via `skip-gate` command (Phase 4d) is the human
  escape hatch for individual flaky gates

**Note:** Adding `--no-force-advance` requires extending the
orchestrator's positional arg parser. Keep it simple: env var
`K8S_REBASE_NO_FORCE_ADVANCE=1` instead of CLI flag.

**File:** `scripts/k8s-rebase-orchestrator.sh`, `steps/step5-pr.md`
**Effort:** 2 hours

### 2h. Gate-fix loop robustness (from original plan 4.3)
Two robustness improvements specified in the original plan's step
file section that were not implemented:

- **Oscillation detection:** Stop gate-fix loop when a fix causes
  regression (a gate that previously passed now fails after fixing
  a different gate). Currently the loop retries up to 3 times with
  no regression awareness. Fix: track set of passed gates; if any
  gate regresses, stop and report the oscillation.
- **Dirty-tree check:** `git status --porcelain` at gate-fix loop
  start. Uncommitted changes cause false FAILs in gates that read
  branch state. rules.md says "commit ALL fixes before re-launching
  ANY gates" but nothing enforces it mechanically.

Both are additions to rules.md gate-fix loop protocol + optional
enforcement in orchestrator's `advance` command (refuse to advance
if working tree is dirty).
**File:** `skills/k8s-rebase/steps/rules.md`,
`scripts/k8s-rebase-orchestrator.sh`
**Effort:** 1 hour

## Phase 3: Companion scripts (6 exist, add 3 + feature gate discovery)

6 companion scripts already shipped: `build-vet.sh`,
`version-consistency.sh`, `crd-validation.sh`,
`major-version-imports.sh`, `patterns-completeness.sh`,
`go-version-check.sh`.

### 3a. Ship 3 Tier 1 scripts
Truly deterministic (verified by adversarial review):
- `cleanliness.sh` — git status + find + git ls-files
- `diff-scope.sh` — file extension classification (case statement)
- `commit-messages.sh` — line length + prefix regex (info-only)

**Template:** Use gate-script-lib.sh init_gate/finish_gate.
**Effort:** 2-3 hours total

### 3b. Migrate crd-validation.sh to gate-script-lib.sh
Predates the library. Uses inline set -uo pipefail, manual BASE.
**Effort:** 30 min

### 3c. Feature gate auto-discovery (from gate-extraction plan)
Replace hardcoded GATE_DEPS map with runtime parsing of
`vendor/k8s.io/client-go/features/known_features.go`. Auto-discovers
Default:true, filters LockToDefault:true. Eliminates per-release
maintenance for feature gates.

**Implementation:** New function `discover_gates()` in autofix that
uses awk to parse the known_features.go struct. Output: list of
gate names. Replaces the `declare -A GATE_DEPS` block. Must also
handle non-vendored repos (scan `$GOMODCACHE` instead of `vendor/`).

**File:** `scripts/k8s-rebase-autofix.sh`, companion script
**Effort:** 1-2 days (most complex item in plan)

## Phase 4: Developer experience + onboarding

### 4a. Quickstart guide (1 page)
- Prerequisites (Go, podman/docker, git, claude CLI)
- First run: exact commands and expected output
- What to expect: 5 steps, ~30 min, what each step does
- Common failures and what to do
- When to intervene vs. let it continue
**Effort:** 2 hours

### 4b. `--preflight` command
Validates repo compatibility without modifying anything:
- Has go.mod with k8s.io deps
- Has a default branch (main/master)
- Working tree is clean
- Go version available (or container runtime)
- Blocked deps check (library-go, openshift/api rebased to target?)
- `go.work` detection (warn: not yet supported)
- Disk space check (need ~1GB free for vendor + git objects)
- Builder image existence (check if `golang-X.Y-openshift-N.M`
  exists in the ART image stream — prevents silent CI breakage)

Implement as standalone script `scripts/k8s-rebase-preflight.sh`
(simpler than adding flags to orchestrator's positional arg parser).
SKILL.md calls it during bootstrap.
**File:** `scripts/k8s-rebase-preflight.sh`, `skills/k8s-rebase/SKILL.md`
**Effort:** 1 day

### 4c. Human-readable progress output
Add human-friendly progress ALONGSIDE machine-parseable output
(test harness parses the key-value lines — don't break it).
Emit progress to stderr, keep structured output on stdout.
**File:** `scripts/k8s-rebase-orchestrator.sh`
**Effort:** 1 hour

### 4d. Escape hatches
- `bash "$ORCH" skip-gate <repo> <gate-name>` — mark gate as
  SKIP with reason, proceed without force-advancing entire step
- `bash "$ORCH" rollback <repo>` — clean branch + state files
- Translate gate status into remediation in `status` output
**File:** `scripts/k8s-rebase-orchestrator.sh`
**Effort:** 2 hours

### 4e. Known limitations doc
What repo shapes are NOT supported:
- `go.work` workspace repos
- Repos without k8s.io deps in go.mod
- Repos requiring manual dep coordination (library-go blocker)
- Repos with custom build systems (not Makefile-based)
- Operator-sdk bundle regeneration (agent handles, no automation)
**Effort:** 1 hour

## Phase 5: Scale infrastructure

### 5a. 3-tier testing strategy for scale
Not all 100+ repos need court-level validation:

| Tier | Repos | Validation | Runtime |
|------|-------|------------|---------|
| Court (canary) | 6-10 with known-goods | Full gates + court | ~1hr |
| Gates-only | 20-30 compilable repos | Gates, no court | ~30min |
| Smoke | Everything else | Steps 1-2 only (bump + build) | ~5min |

Baseline: previous successful run, not human-known-good. Regression
= repo that passed last run but fails this run.

**CI gate on PR:** GitHub Actions runs Tier 1 on every skill PR.
Tier 2/3 run nightly.
**Effort:** 2-3 days

### 5b. Concurrency controls for batch execution

**Concrete fixes (from scale stress-test simulation):**

| Fix | Impact | Effort |
|-----|--------|--------|
| Default `MAX_CONCURRENT=10` | Prevents all resource exhaustion | 1 line |
| `flock` on results.tsv writes | Prevents data corruption | 5 lines |
| Pre-pull Go container image | Eliminates Docker Hub rate limit | 3 lines |
| Cache proxy check result | Eliminates 99 redundant proxy calls | 10 lines |
| `GOMODCACHE` warm-up phase | Prevents cache contention | 20 lines |

**File:** `test/test-skill.sh`, `scripts/k8s-rebase.sh`
**Effort:** 1 day

### 5c. Cost optimization
Optimization roadmap:
1. **Companion scripts** eliminate agent calls ($0 per gate)
2. **Haiku tier** for 13 gates (info + script-backed): $0.04 vs
   $0.68 per call. Savings: $832/quarter.
3. **Context compression** between steps: summarize results before
   advancing. Cuts input tokens significantly.
4. **Cost tracking** in events.jsonl (prerequisite: add `_telem()`
   function, ~3 lines, emitting token counts per agent call)

**Optimized target: ~$20/repo, $2,000/quarter at 100 repos.**
**Effort:** Incremental across phases

## Phase 6: Forward-looking robustness

### 6a. Model-version coupling mitigations
Called "existential risk" by 180-agent review. Zero mitigation today.

**Concrete mitigations:**
- Log model ID per run in results.tsv (1 line)
- **Canary gate:** before batch runs, run on 1 known-good repo and
  diff output against golden file. If diff exceeds threshold, halt.
- **model-compat.tsv:** mapping of tested model versions to plugin
  versions. CI checks this.

### 6b. Go ecosystem forward-compatibility
- **`GOTOOLCHAIN=local`**: Set alongside `GOWORK=off` in all scripts
- **`go.work` detection**: Error + suggest manual rebase (until
  supported). Preflight (4b) warns.
- **Toolchain directive**: Note in commit message when auto-updated
- **Replace-override warnings**: Warn when replace overrides bumped
  require

### 6c. Security hardening
- **Hook bypass**: Add `bash -c`, `sh -c`, `env` wrapper detection.
  Or: set `GOPROXY=off` outside sanctioned scripts.
- **Pre-push hook chaining**: Chain instead of replacing. Auto-restore.
- **Container hardening**: `--cap-drop=ALL`, `--network=none` during
  codegen phases.
- **Go image pinning**: Pin by SHA256 digest, not just tag.

### 6d. Discovery procedures
Build version-agnostic detection for: deprecated APIs (vendor
probing), e2e infra versions (GitHub API), lint compatibility
(Go version vs lint version matrix). Replaces version-specific
recipes that rot every release cycle.

**Verification for Phase 6:** Run Tier 1 test suite with
`GOTOOLCHAIN=local` set. Verify no regressions from security
changes. Canary gate dry-run against known-good repo.

## Phase 7: Rollout + adoption

### 7a. Rollout plan
- **Cohort 1** (weeks 1-2): 3 internal repos (ovnk, multus, CNCC)
- **Cohort 2** (weeks 3-4): 10 friendly internal teams with support
- **Cohort 3** (weeks 5-8): General availability (internal)
- **Upstream** (after cohort 3 stabilizes): Only with explicit
  maintainer opt-in. Open an issue first ("would you accept
  AI-assisted rebase PRs?"). Some projects reject AI contributions
  on principle. Never send unsolicited automated PRs to volunteer
  maintainers — this burns goodwill.
- Timeline gates: each cohort must have 0 force-advance and 0
  non-author-needs-help before proceeding to next.
- **`--dry-run` risk:** Cohort 2/3 teams may demand preview mode.
  If adoption stalls, promote from "Not yet" to in-plan.

### 7b. Communication
- Announcement: team Slack + mailing list
- Demo video (3 min max): first run, gate-fix loop, PR output
- One-page "what this does and doesn't do" doc

### 7c. Support model
- Slack channel for triage
- Known-failure runbook: "step X hangs" -> check Y
- Escalation path for blocked deps / skill bugs

### 7d. v1.0 ship criteria
1. Zero INFRA failures on 10 diverse repos (diversity axes: dep
   count, build system, org, go.mod complexity, vendored vs not)
2. Step5 race fixed (0a) — every success produces PR command
3. Stale-branch detection works (1a)
4. Gate stale-detection works (0b) — HEAD SHA in reports
5. Force-advance rate <5% across Tier 1 suite
6. Cost per repo <$50
7. Wall-clock time <60 min per repo
8. `--preflight` command exists and passes on all Tier 1 repos
9. One-page quickstart published
10. Known-limitations section published
11. **3 successful end-to-end runs by a non-author — at least 1 on
    a complex repo (ovnk-scale) and 1 on a repo the tester chooses**
12. **30-day stability gate:** Tier 1 pass rate does not regress >5pp
    in the 30 days after v1.0 declaration

## Effort summary

| Bucket | Items | Effort |
|--------|-------|--------|
| Ready to code now | 0a-0e, 2a-2e, 1b-1c | ~3 hours |
| Needs decision first | 0f (double-advance) | 30 min after decision |
| Moderate implementation | 1a, 2f-2h, 3a-3b, 4a, 4c-4e | ~3 days |
| Needs design | 3c, 4b, 5a-5b | ~1 week |
| Docs/process | 4a, 4e, 7a-d | ~1 day |

**Critical path for v1.0:** Phase 0 (all) -> Phase 1a -> Phase 2a
-> Phase 4a + 4b + 4e -> 3 non-author runs. Phases 3, 5, 6 are
valuable but not on the v1.0 critical path.

## Verification

- `shellcheck scripts/*.sh test/test-skill.sh` after each phase
- `make lint` after each phase
- Phase 0: targeted 1 repo, confirm race/stale-detection/counter
- Phase 1: run 3+ repos, confirm zero stale-branch failures
- Phase 2: targeted 1 repo x 1 version per fix
- Phase 3: verify companion scripts produce correct PASS/FAIL
- Phase 4: non-author walks through quickstart unassisted
- Phase 5: run 20+ repos with concurrency controls
- Phase 6: Tier 1 suite with GOTOOLCHAIN=local, canary dry-run
- Phase 7: Tier 1 full pass before each cohort gate
- Final: full matrix pass, grep fail_code distribution

## Decisions deferred from older plans

| Item | Disposition | Rationale |
|------|------------|-----------|
| Workflow script vs SKILL.md prose | Defer | Current boot-loader works (0 step-skipping). Revisit if step-skipping returns. |
| Gate consolidation 33 -> ~28 | Defer | Companion scripts reduce cost without removing gates. Revisit after Phase 5a provides gate-runtime data. |
| events.jsonl telemetry | In-plan (Phase 5c) | Prerequisite for cost tracking. |
| Self-improving loop | Defer | Research project, not shipping feature. |
| CNCC depth-2 spike | Completed | Depth-2 nesting works (verified in matrix testing). |
| 5-phase migration (gate-extraction) | Phases 3, 6d adopted | Script expansion + discovery. Versioned function removal deferred until discovery proves stable. |
| spec=versioned test mode | Defer | spec=none is the production metric; spec=all is diagnostic. |
| SKIP verdict in reconstruct_step | Defer | Edge case, force-advance covers it. |
| Three-tier gate classification | Implicit | Already reflected in companion script tiers. |
| Operator-sdk/controller-tools | Not yet | Agent handles in step 2/4. Automate after storage team repos join Tier 2 testing. |

## Not yet (future iteration)

- Downstream handling (openshift/ovn-kubernetes Dockerfiles, OTE)
- Multi-repo coordinator (library-go -> ovnk -> CNO sequencing)
  with `depends_on` field in config.yaml and topological sort
- Fleet dashboard (repo status: blocked/in-progress/pass/fail/PR-open)
- Draft PR creation + CI monitoring loop
- Decision provenance in rebase report
- 2-of-3 voting for AI-judgment gates
- `--dry-run` mode (preview without modifying — cohort 2/3 risk)
- Starter template for other teams building similar automation
- SBOM / dependency change manifest (old SHA -> new SHA per module)
- Commit signing (GPG/SSH/gitsign)
- Non-vendored feature gate discovery (scan $GOMODCACHE instead)
- License scan gate (`go-licenses` or `licensee` before PR command —
  catches newly-introduced transitive deps with incompatible licenses)
- Feature gate policy layer: flag newly-defaulted gates as "action
  required" for human review instead of silently disabling — upstream
  needs these breakage reports (per k8s upstream maintainer feedback)
- Builder image stream validation (check ART image availability
  before updating Dockerfile refs — prevents silent CI breakage)
- Per-step checkpoint files for crash recovery within a step
  (currently resume restarts the step from scratch)
- Bad PR response plan for upstream repos (rollback, communication
  template, designated responder)
- `apidiff` integration for API-breaking change detection
- Upstream structured release-notes.json parsing (instead of
  free-form changelog analysis in k8s-changelog gate)
