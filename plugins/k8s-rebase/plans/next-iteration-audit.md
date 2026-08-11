# Audit: next-iteration.md

Deep audit of the draft plan against the actual codebase.
Focus: issues that impact skill results and reliability.

---

## 1. "Where we are" — Fact Check

### "81% clean pass rate"

**NOT SUPPORTED BY DATA.** `results.tsv` has 299 entries:
191 PASS, 108 FAIL = **63% overall**. Even excluding
stale-branch failures: 191/279 = **68%**. Best recent window
(Aug 4-6 excl stale): 35/45 = 78%. No window reaches 81%.

### "5 remaining failures: 2 'no branch found', 3 'missing gates'"

**DRASTICALLY UNDERSTATES THE PROBLEM.** The TSV has **108
FAIL entries**, not 5. Breakdown:

| Category | Count | Detail |
|----------|-------|--------|
| Gate(s) failed | 44 | At least 1 gate FAIL verdict |
| Missing gates (step boundary) | 24 | Agent stopped at exact step boundary — orchestrator didn't prevent |
| Stale branch | 20 | Agent never committed to the branch — 14 on Aug 11 alone |
| Missing gates (other) | 14 | Various partial completions |
| Court FAIL | 2 | Real quality issues |
| Other | 4 | "no branch found" (2), "session ended" (1), "no gates ran" (1) |

The "missing 26 of 33 gates" pattern (= stopped at step2→3
boundary) appears **11 times**. "missing 15" (step3→4) appears
**7 times**. "missing 32" (step1→2) appears **4 times**. These
are step-skipping failures the orchestrator was specifically
designed to prevent.

### "Stale-branch fix — Already fixed"

**WRONG — 14 stale-branch failures on Aug 11 (today).**

Root cause found by inspecting the test repos on disk:

1. A prior test run creates a `bump1.34` branch in the worktree.
   When the worktree is cleaned, the branch persists in the main
   repo. If the main repo ends up checked out on `bump1.34`
   (which happens when the harness resets to it after worktree
   removal), `git branch -D bump1.34` fails ("cannot delete
   branch checked out at...").
2. New sessions create timestamped branches (`bump1.34-<ts>`)
   because `bump1.34` already exists.
3. When `auto_record` runs for a dead session whose worktree
   was already cleaned, `_worktree_info` returns nothing. The
   fallback (`git branch | grep bump | sort -V | tail -1`)
   finds the OLD `bump1.34`, not the new timestamped one.
4. `branch_tip_epoch` of the old branch < `launch_epoch` of the
   new session → "stale branch."

**Evidence:** `ovn-org/ovn-kubernetes` main repo is currently
checked out on `bump1.34`. A locked worktree from a dead session
(PID 372312, long gone) persists at `.claude/worktrees/
k8s-rebase-1.34.1`. 8 stale `bump1.35-*` branches also remain.

**Fix:** In `_do_record_one`, the fallback branch detection
should prefer the WORKTREE branch. If the worktree still exists,
use whatever branch it's on. If the worktree is gone, check
`git branch | grep bump | sort -V | tail -1` BUT filter for
branches whose tip is NEWER than launch. Also: in the cleanup
phase, reset the main repo to the default branch before deleting
bump branches (`git checkout main` then `git branch -D bump*`).

**The cleanup code (`remove_worktrees`) already tries unlock +
force-remove but fails when the lock file references a dead PID.
The fix must also handle stale locks from dead sessions.**

---

## 2. "What moves the pass rate" — Analysis

### "Agent early-stop — 3 of 5 remaining failures"

**WRONG SCALE.** The plan says 3 failures. The data shows
**24 step-boundary failures** plus **14 other missing-gates
failures** = 38 total (35% of all failures).

Root cause analysis by examining the failure patterns:

**Step-skipping is concentrated:** 79% on ovn-org/ovn-kubernetes,
88% on spec=all (blind mode, no autofix/patterns). Breakdown:
- `missing 26` (step2→3 boundary): 11 times, ALL spec=all
- `missing 15` (step3→4 boundary): 7 times, 4 spec=all + 3 none
- `missing 32` (step1→2 boundary): 4 times, ALL spec=all

**Most likely cause: context exhaustion.** ovnk is the largest
repo (3 modules, codegen, 18k+ lines of test code). In spec=all
mode, the agent gets no autofix help — it must figure out fixes
from scratch, consuming much more context. The compilation fix
cycle (step 2) involves reading error logs, reading source files,
making fixes, re-validating, and launching 6 gate subagents.
After all this, the session may hit context limits.

**Why the stop hook doesn't help:** When a session hits context
limits or crashes, the stop hook never fires (it's a pre-exit
hook, not a crash handler). The session simply terminates.
`_session_alive` detects the dead session, and `auto_record`
records whatever gates exist → "missing N of 33."

**Why satisficing is the SECONDARY cause:** The 3 spec=none
failures at step3→4 aren't explained by context exhaustion
(spec=none runs are shorter because autofix does the work).
These may be satisficing — the agent decides it's done after
step 3. The stop hook should catch this, but may fail if the
agent's response to the BLOCKED message is to try exiting again.

**Diagnostic procedure needed:**
1. Save session transcripts from the next batch (session IDs
   are in `.matrix-state/running/*` during execution)
2. For a step-boundary failure, check the transcript for:
   - Context compression messages (system auto-summarization)
   - The agent's last tool call before exiting
   - Whether the stop hook BLOCKED message appears
   - Whether the agent attempted advance
3. If context exhaustion is confirmed: reduce context consumption
   per step (run gate subagents with smaller context budgets,
   avoid reading large error logs into main context)
4. If satisficing is confirmed: make the stop hook's BLOCKED
   message include the exact next command to run

---

## 3. "Production hardening" — Item-by-Item

### "Pre-push hook cleanup"

**CONFIRMED BUG.** `k8s-rebase.sh` installs a `pre-push` hook
(lines 35-46) but neither `step5-pr.md` cleanup section nor the
ERR trap removes it. The step5 cleanup (lines 56-59) deletes
logs, PIDs, and summary files but not the hook. After a rebase,
the user's repo permanently blocks `git push` until they
manually `rm .git/hooks/pre-push`.

**Fix location:** Add to `step5-pr.md` cleanup section:
```bash
HOOK_DIR="$(git rev-parse --git-common-dir)/hooks"
[[ -f "$HOOK_DIR/pre-push" ]] && grep -q 'k8s-rebase' "$HOOK_DIR/pre-push" && rm "$HOOK_DIR/pre-push"
[[ -f "$HOOK_DIR/pre-push.bak."* ]] && mv "$HOOK_DIR/pre-push.bak."* "$HOOK_DIR/pre-push" 2>/dev/null
```
Also add to the ERR trap in `k8s-rebase.sh` (currently line 21
only prints a message, doesn't clean up).

**Severity: HIGH** — silently breaks the user's repo after
every rebase.

### "Hook session guards"

**PARTIALLY DONE.** The stop hook (`stop-hook.sh` line 19)
already checks `.session-active`. But the 3 markdown hooks
(`block-module-ops.md`, `block-push.md`, `block-vendor-edit.md`)
do NOT have session guards.

These are model-mediated PreToolUse hooks registered via the
plugin's `hooks/` directory convention. They are loaded for
**every session where the plugin is installed**, not just during
skill invocation. The `hooks.json` only registers the Stop
hook; the `.md` hooks are auto-discovered by Claude Code from
the `hooks/` directory based on their frontmatter.

**Impact:** Any user with the k8s-rebase plugin installed
cannot run `go mod tidy`, `go get`, or edit vendor files in
ANY project — even non-rebase work. The hook descriptions say
"during k8s-rebase skill execution" but that's descriptive
text, not an activation guard. The hook body has no conditional
— it blocks unconditionally.

**Fix:** Add to the top of each markdown hook body:
```
First, check if a rebase session is active:
- If `.rebase-tmp/.session-active` does NOT exist in the
  current working directory, respond with: ALLOW
```

**Severity: HIGH** — plugin installation breaks normal
workflows. This is the highest-priority fix.

### "GPG signing"

**CONFIRMED GAP.** Neither `k8s-rebase.sh` (14 `git commit`
calls) nor `k8s-rebase-autofix.sh` (2 `git commit` calls) set
`commit.gpgsign=false`. Users with GPG signing enabled will get
interactive prompts for every commit. In a `nohup` background
process (step 1), this hangs silently. The autofix runs inside
a subagent (step 3) where the Bash tool would also hang.

Both scripts already use `GIT_CONFIG_COUNT=1` for
`safe.directory` inside their container code paths (lines
302-304 in rebase.sh, 134-136 in autofix.sh). The GPG fix must
stack with this — if both are needed (container + GPG), count
must be 2.

**Fix:** Add to both scripts' preamble (BEFORE the container
check, so it applies to both host and container execution):
```bash
export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-0}"
_idx=$GIT_CONFIG_COUNT
export GIT_CONFIG_COUNT=$((_idx + 1))
export "GIT_CONFIG_KEY_${_idx}=commit.gpgsign"
export "GIT_CONFIG_VALUE_${_idx}=false"
```
Then change the container block from `GIT_CONFIG_COUNT=1` to:
```bash
_idx=$GIT_CONFIG_COUNT
export GIT_CONFIG_COUNT=$((_idx + 1))
export "GIT_CONFIG_KEY_${_idx}=safe.directory"
export "GIT_CONFIG_VALUE_${_idx}=$REPO_ROOT"
```

**Severity: MEDIUM** — only affects users with GPG signing,
but manifests as a silent hang with no error message.

### "Force-advance counter"

**CONFIRMED BUG — more severe than the plan implies.**
`cmd_init` (lines 137-170) clears gate reports on fresh start
(`rm -f .../*.report`) but does NOT clear
`.advance-attempts-step*` files.

**Concrete failure scenario:** A previous run gets stuck at
step 2, calls advance twice (counter = 2), then crashes. User
deletes `state.json` to restart. Fresh init starts at step 1.
Step 1 passes, agent moves to step 2. First time it hits any
gate issue at step 2 and calls advance, the counter file still
has 2 — it increments to 3, hits `>= 3`, and force-advances
immediately. The agent gets **zero retries** at step 2. Gates
that would have passed on retry are skipped.

**Does NOT explain test failures:** The test harness creates
fresh worktrees per run (`git worktree` + prune on cleanup),
so each run gets a fresh `.rebase-tmp/` with no stale counter
files. The bug only affects production use where users retry
rebases in the same directory.

**Fix:** Add to the fresh-start branch of `cmd_init` (after
`rm -f "$repo/.rebase-tmp/gates/"*.report`):
```bash
rm -f "$repo/.rebase-tmp/.advance-attempts-"* 2>/dev/null || true
```

**Severity: MEDIUM for production, NONE for tests.** In
production, causes premature force-advance on retries. Does
not explain the 3 "missing gates" test failures.

### "Resume version mismatch"

**CONFIRMED GAP.** `cmd_init` accepts a version argument and
`write_state` stores it in `state.json`, but on resume (when
`state.json` exists), the stored version is never compared to
the requested version. If a user runs `init repo 1.35.0`, then
later `init repo 1.36.0`, the orchestrator prints "Resuming at
step N" with the old version — the new version is silently
ignored.

**Fix:** In `cmd_init`, after detecting resume:
```bash
local stored_version
stored_version=$(get_version "$repo")
if [[ -n "$version" && "$stored_version" != "$version" ]]; then
  die "Version mismatch: state.json has $stored_version but $version requested. Delete .rebase-tmp/state.json to restart."
fi
```

**Severity: MEDIUM** — silent data corruption if triggered.

---

## 4. "Gate work" — Companion Script Bugs

### "major-version-imports.sh: args swapped in base_file_has"

**CONFIRMED BUG.** Line 25 calls:
```bash
base_file_has "\"$bare\"" "$file"
```
But `gate-script-lib.sh` line 50 defines:
```bash
base_file_has() {
  local file="$1" pattern="$2"
```
The function expects `(file, pattern)` but receives
`(pattern, file)`. `git show "$BASE:\"k8s.io/klog\""` always
fails (not a file path), so `base_file_has` always returns
false. Pre-existing imports are never filtered — every bare
import is counted as NEW.

**Impact on results:** Any repo that had bare `k8s.io/klog`
imports on its base branch will get false FAIL from this gate.
The gate then triggers the gate-fix loop, wasting an agent
iteration on a non-issue. If the agent "fixes" a pre-existing
import, it creates an out-of-scope commit that the court may
reject.

Line 51 has the same bug (second call site).

**Severity: MEDIUM** — directly causes false FAILs and wasted
fix iterations.

### "crd-validation.sh: dead $pre"

**CONFIRMED.** `$pre` is initialized to 0 on line 21 and never
incremented anywhere in the script. `PRE_EXISTING=$pre` on the
output line always prints 0. The script correctly counts `$new`
but never classifies anything as pre-existing — it outputs
`CHANGED-VALIDATION` for everything.

However, this is **by design for this script's structure.** The
script doesn't use the `gate-script-lib.sh` pattern — it's a
standalone script that outputs raw findings for the AI gate to
interpret. The `PRE_EXISTING=0` is inert informational output,
not a logic bug. The AI gate reads `NEW_ISSUES=N` and the
per-CRD annotations (`IDENTICAL`, `CHANGED-VALIDATION`,
`ALL-NEW`) to make its judgment.

**Severity: LOW** — the dead variable is misleading but doesn't
affect verdicts. Migration to `gate-script-lib.sh` would fix
it naturally.

### "patterns-completeness.sh: dead $pre"

**CONFIRMED — same pattern.** `$pre` initialized to 0, never
incremented, output as `PRE_EXISTING=0`. Same assessment as
crd-validation.sh.

### "Both need migration to gate-script-lib.sh"

**CORRECT.** Both scripts use ad-hoc boilerplate instead of
`source gate-script-lib.sh; init_gate "$@"`. Migration would
give them: crash trap, standardized report writing, proper
`BASE` computation, and `finish_gate` with automatic PASS
verdict.

---

## 5. "Script the 8 Tier 1 gates" — Feasibility

### "Reduces agent calls 27% (33→25)"

**The plan conflates "scripted" with "no agent needed."**
Companion scripts produce RESOLVED (fast-path PASS, no agent)
or PENDING (agent still needed for judgment). The reduction
depends on how often scripts produce `NEW_ISSUES=0` — a clean
rebase skips most agents, but a messy one still needs them all.
The actual impact is: fewer FLAKY verdicts, not fewer agents.

### Individual gate script feasibility

| Gate | Plan's description | Assessment |
|------|-------------------|------------|
| build-vet-recheck | "same logic as build-vet.sh" | **Trivial** — `build-vet.sh` exists for step2; reuse via symlink or shared script. |
| cleanliness | "git status + find + git ls-files" | **Trivial** — 3 shell commands, fully deterministic. |
| diff-scope | "changed files × extension whitelist" | **Partially feasible** — file counting is deterministic, but commit scope classification needs judgment. The gate `.md` says "review the remaining commits' diffs." Evidence script valuable, but can't produce verdict alone. |
| test-compilation | "`go test -run='^$' -count=0`" | **Feasible** — the validate script already does `-run='^$' -count=1`. Same effect. |
| feature-gates | "grep KUBE_FEATURE_ vs vendor" | **Feasible** — the autofix `run_checks()` has this exact logic. Extract into a script. Highest-value new script: eliminates the most common false FAIL. |
| rebase-completeness | "result file + git log + go.mod" | **Feasible** — check `step1-result.txt` exists with "EXIT 2", verify go.mod versions match target. |
| deprecated-imports | "grep x/ imports (hardcoded table)" | **Feasible** — simple grep for `golang.org/x/exp`, `k8s.io/klog` (bare), etc. |
| dep-cve-check | "diff go.sum, curl OSV.dev" | **Moderate** — needs JSON parsing of OSV API responses. `jq` dependency. ~50 lines. Network-dependent (API may be slow or down). |

**Priority order for impact:** feature-gates > cleanliness >
build-vet-recheck > rebase-completeness > deprecated-imports >
test-compilation > dep-cve-check > diff-scope.

### "Steps 2/3 need 'launch only PENDING' pattern like step 4"

**CORRECT.** Currently:
- Step 4 (`step4-verification.md` line 60): "Launch subagents
  only for PENDING gates" — runs `orchestrator.sh gates` first.
- Steps 2 and 3 say "launch one subagent per gate file listed
  below. All in a single parallel wave." — no orchestrator
  gates pre-check.

This means steps 2/3 always launch all agents even if companion
scripts already resolved some gates. Adding `orchestrator.sh
gates` before launching would let companion scripts fast-path
PASS, reducing unnecessary agent calls.

---

## 6. "Consolidate gates" — Analysis

### "Drop logical-completeness (step3) — step4's logical-consistency is a strict superset"

**PARTIALLY TRUE.** Comparing the two gates:

**logical-completeness (step3):** "check every Go function
modified... trace every added statement... Check for logical
gaps: a field set but not compared..."

**logical-consistency (step4):** "Read ALL fix commits... For
EVERY function modified... trace data flow. Do not skip or
sample" + explicit FAIL criteria (struct copies dropping fields,
error values ignored, incomplete transformations).

Step 4's gate IS more thorough (explicit FAIL criteria, grep
verification). But step3's gate catches issues BEFORE step4
runs — between autofix and verification. Dropping it means
autofix-introduced bugs aren't caught until step 4. The cost
is one agent call. If the agent is already running step3's
other 10 gates, the marginal cost is low.

**Recommendation:** Keep it but mark it as lower priority —
if step3 is taking too long, this is the first gate to defer.
Don't outright drop it.

### "Narrow deprecated-api-remnants — duplicates build-vet, deprecated-imports, and deprecated-calls"

**PARTIALLY TRUE.** The gate has 3 steps:
1. `go build` + `go vet` — duplicates build-vet
2. Discover deprecated symbols via web search — UNIQUE
3. Check for stale imports — duplicates deprecated-imports

Step 2 (web search discovery) is the unique value — it finds
deprecations that compile fine but are semantically wrong.
The plan's recommendation ("keep only its web-search
discovery") is correct.

**Implementation:** Remove steps 1 and 3 from the gate `.md`,
keep only the web-search discovery step. This makes it a
lighter, faster gate.

---

## 7. "Tier 2 evidence scripts" — Assessment

### "deprecated-calls — staticcheck + pre-existing filter"

**Feasible.** Staticcheck is available as a standalone binary.
The script would run `staticcheck ./...` (or install it first),
filter SA1019 findings, then check each against the base branch.
~30-40 lines. The main risk: staticcheck takes 2-5 minutes on
large repos.

### "autofix-result — commit counting + build pass/fail"

**Trivial.** Count commits since merge-base, check if `go build
./...` passes. ~15 lines.

### "gomod-diff-analysis — parse go.mod diff"

**Moderate complexity.** Diffing go.mod and classifying each
dep change (expected k8s bump, unexpected version, new dep,
removed dep) is 40-60 lines of awk/bash. Judgment is still
needed for pseudo-version pins and replace directives.

### "3 'Tier 3' gates actually have scriptable evidence phases"

**Partially correct.** The plan identifies ci-prediction,
maintainer-review, and skill-improvement. But:

- `maintainer-review` and `skill-improvement` are already in
  `INFO_GATES` (line 21 of `test-skill.sh`), treated as
  always-PASS by the harness. They don't cause failures.
  Scripting them adds no value to pass rates.
- `ci-prediction` has real deterministic checks mixed with
  judgment — scripting the evidence phase is worthwhile.

**Functional impact:** Only `ci-prediction` matters here.
The other two are already harmless. The plan should prioritize
ci-prediction and note the other two are already handled.

---

## 8. Missing from the Plan

### Companion scripts change court baselines

New companion scripts change the commit structure (different
fix ordering, different commit messages). The court compares
the skill's diff to the known-good human rebase. Changed
commit structure → different diff → potential false court
FAILs even when the rebase is functionally correct.

**Impact:** After shipping new companion scripts, known-good
baselines may need regeneration, or the court must be taught
to compare at the file level (not commit level). The plan
doesn't address this.

### No prioritization or ordering

The plan lists 12+ items across 4 sections but doesn't
specify dependencies. This matters because:
- Hook session guards should ship BEFORE anything else (they
  break non-rebase workflows right now — P0)
- Companion script bug fixes (imports.sh arg swap) should
  ship BEFORE measuring gate flake rates (broken pre-existing
  detection inflates FAIL counts, corrupting measurements)
- Force-advance counter fix should ship BEFORE the next test
  batch (stale counters cause premature force-advance, which
  is one possible explanation for the "missing gates" failures
  the plan is trying to diagnose)

### Step-skipping and stale-branch are the two biggest problems

The plan treats step-skipping as solved and stale-branch as
fixed. Neither is true:

**Stale branch (20 failures, 19%):** Harness bug — main repo
gets stuck on a prior run's bump branch, cleanup can't delete
it, `_do_record_one` finds the old branch and reports stale.
This is fixable with a targeted harness change (reset to
default branch before cleanup, or filter branches by age in
the fallback detection).

**Step-skipping (24 step-boundary + 14 other = 38 failures,
35%):** Most likely context exhaustion on ovnk + spec=all.
The orchestrator and stop hook can't prevent session crashes.
Needs transcript capture to confirm cause. Possible mitigation:
reduce context consumption per step.

Together these are 58 of 108 failures (54%). The plan focuses
on the 44 gate-failure cases (41%) which are the THIRD-largest
category. The priorities should be inverted.

### `version-completeness` vs `version-consistency` confusion

The plan says "`version-completeness` is Tier 2 (needs
prose-vs-code judgment)" in the "Script the 8 Tier 1 gates"
section. This is step4's `version-completeness.md` (checks
version strings in CI/docs), NOT step2's
`version-consistency.md` (checks go.mod k8s.io/* versions,
already has a companion script). The plan is correct but the
similarity of names could cause someone to skip it thinking
it's already scripted. Worth a note.

---

## 9. Summary — What Impacts Results

### The plan's priorities are inverted

The plan focuses on companion scripts and gate polish. But
the data shows the dominant failure modes are:

1. **Step-skipping (38 failures, 35%)** — the orchestrator
   isn't preventing it. Root cause unknown.
2. **Stale branch (20 failures, 19%)** — plan says "fixed"
   but 14 failures occurred today.
3. **Gate failures (44 failures, 41%)** — some are real
   quality issues, some are flaky gates.

Companion scripts address #3 (gate flakiness) but don't
touch #1 or #2, which together are 54% of all failures.

### Bugs that directly cause failures

| Issue | How it causes failure | Fix effort |
|-------|----------------------|------------|
| Hook session guards | Blocks `go mod tidy` in all repos, not just rebases | 3 lines per hook |
| major-version-imports.sh args | Swapped args → false FAIL → wasted fix loop → court FAIL | Swap 2 args |
| Pre-push hook not cleaned up | Blocks `git push` after rebase — confirmed in all 6 test repos | ~4 lines in step5 |
| Force-advance counter | Premature force-advance on production retries (not test runs) | 1 line in orchestrator |

### Gaps that cause silent hangs

| Issue | Scenario | Fix effort |
|-------|----------|------------|
| GPG signing | `commit.gpgsign=true` → step 1 hangs in nohup, step 3 hangs in subagent | ~6 lines per script |

### Harness bugs (root causes found)

| Issue | Scale | Root cause | Fix |
|-------|-------|-----------|-----|
| Stale branch | 20 failures (19%) | Main repo stuck on bump branch, cleanup fails, `_do_record_one` fallback finds old branch | Checkout default before cleanup; filter branches by age |

### Investigation needed (root cause partially identified)

| Issue | Scale | Most likely cause | First step |
|-------|-------|------------------|------------|
| Step-skipping | 38 failures (35%) | Context exhaustion on ovnk + spec=all (79% on ovnk, 88% on spec=all) | Add transcript capture. Examine for context compression messages. |

### Lower-priority improvements

| Issue | Impact | When |
|-------|--------|------|
| New companion scripts (8) | Reduces gate flakiness | After step-skip root cause found |
| Steps 2/3 PENDING pattern | Saves agent calls | After scripts shipped |
| Gate consolidation | Marginal | After measuring |

---

## 10. Recommended Ship Order

1. **Fix stale-branch harness bug** — root cause identified:
   main repo stuck on bump branch, `_do_record_one` finds old
   branch. Fix: checkout default branch before cleanup; in the
   fallback, filter branches with tip newer than launch. Also
   clean the 6 test repos now (unlock worktrees, delete stale
   bump branches, checkout default branch). This alone removes
   20 of 108 failures (19%).

2. **Fix hook session guards + imports.sh args + pre-push
   cleanup + force-advance counter** — all trivial bug fixes.

3. **Fix GPG signing** — test `GIT_CONFIG_COUNT` stacking.

4. **Add transcript capture to harness** — save session
   transcripts before cleanup. This is required to diagnose
   the 38 step-skipping failures (context exhaustion vs
   satisficing).

5. **Run a clean batch + examine step-skip transcripts** —
   with stale-branch fixed, the pass rate should jump from
   63% to ~75%. Examine transcripts from "missing 26" failures
   for context compression messages. If confirmed: reduce
   context consumption per step (don't read full error logs
   into main context, use smaller gate report limits).

6. **Then**: companion scripts, gate polish, PENDING pattern
   — these address the 41% gate-failure bucket, which becomes
   the dominant issue once stale-branch and step-skipping
   are addressed.
