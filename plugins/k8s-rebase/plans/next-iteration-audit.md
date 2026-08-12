# Audit: next-iteration.md

Deep audit of the draft plan against the actual codebase.
Focus: issues that impact skill results and reliability.

*Updated after plan was revised on Aug 11. Old "81%/5 failures"
framing removed from plan. New framing: "non-ovnk 88%, ovnk
0/7 due to stale .rebase-tmp/."*

---

## 1. "Where we are" — Fact Check

### "Non-ovnk repos: ~89%. ovnk: 0/7"

**Non-ovnk ~89%: VERIFIED.** Aug 11 non-ovnk excluding stale
branch: 22/25 = 88%. The tilde accounts for counting variance.

**ovnk 0/7: NOT VERIFIED.** Aug 11 ovnk has 3 PASS and 11
FAIL (3/14). ovnk CAN pass — the "0/7" is either from a
different batch or a filtered view. The failures are real but
ovnk isn't completely blocked.

### Historical context (299 entries total)

| Category | Count | % |
|----------|-------|---|
| Gate(s) failed | 44 | 41% |
| Missing gates (step boundary) | 24 | 22% |
| Stale branch | 20 | 19% |
| Missing gates (other) | 14 | 13% |
| Court FAIL | 2 | 2% |
| Other | 4 | 4% |

Step-boundary failures (agent stopped at exact step boundaries)
are concentrated: 79% on ovnk, 88% on spec=all (blind mode).

### Two root causes — plan's and audit's

The plan identifies **stale .rebase-tmp/** as the root cause.
The audit identified **stale branch detection** separately.
Both are real and verified on disk:

**1. Stale .rebase-tmp/ (plan's diagnosis):** Confirmed.
All 3 checked main repos have stale `state.json` and
`.session-active` from prior runs. The plan claims state.json
is created "in the main repo during init (before entering a
worktree)" — this is imprecise. For current worktree-based
runs, state.json goes into the worktree. The stale state in
the main repo is from prior non-worktree runs or crashed
sessions. Regardless: `rm -rf .rebase-tmp/` before launch
is the correct fix. The `.session-active` sentinel also makes
the stop hook fire for all sessions on that repo.

Fix: `rm -rf "$repo/.rebase-tmp/"` in the harness before
launching. This removes state.json, .session-active, gate
reports, and advance counters in one command.

**2. Stale branch detection (audit's diagnosis):** Confirmed.
`ovn-org/ovn-kubernetes` main repo is checked out on `bump1.34`.
`git branch -D bump1.34` fails (can't delete current branch).
8 stale `bump1.35-*` branches persist. When `_do_record_one`
can't find a worktree, its fallback finds the old `bump1.34`
→ stale epoch → "stale branch."

Fix: checkout default branch before deleting bump branches.
Also filter fallback branches by tip age.

**Relationship:** The `.rebase-tmp/` fix is more comprehensive
(one command handles state, session sentinel, gate reports,
and counters). But it doesn't fix the branch detection issue —
old bump branches in the main repo will still confuse
`_do_record_one` even after `.rebase-tmp/` is cleaned. **Both
fixes are needed.**

---

## 2. "What moves the pass rate" — Analysis

### "Clean .rebase-tmp/ in test harness"

**CORRECT — this is the highest-impact fix.** The plan
correctly identifies stale .rebase-tmp/ as the root cause of
ovnk failures. Verified: all 3 checked main repos have stale
state.json and .session-active.

The plan's one-line fix (`rm -rf "$repo/.rebase-tmp/"`) also
resolves several production-hardening items at once:
- Force-advance counter (stale `.advance-attempts-*` files)
- Stale .session-active (stop hook fires incorrectly)
- Old gate reports (interfere with recording)

**The plan should also add the branch cleanup fix** (checkout
default branch before deleting bump branches) because stale
branches cause `_do_record_one` to find old branches even
after .rebase-tmp/ is cleaned.

### Step-skipping after .rebase-tmp/ fix

Once stale state is cleaned, the remaining step-skipping
failures will either disappear (they were caused by stale
resume) or persist (genuinely caused by context exhaustion or
satisficing). The distribution suggests both:

- `missing 26` (step2→3): 11 times, ALL spec=all — likely
  context exhaustion on ovnk without autofix help
- `missing 15` (step3→4): 7 times, 4 spec=all + 3 spec=none
  — the 3 spec=none cases may be satisficing
- `missing 32` (step1→2): 4 times — could be stale resume

**After cleaning .rebase-tmp/, run a batch and count residual
step-skipping.** If it drops to near-zero, stale state was
the dominant cause. If step2→3 skips persist on ovnk+spec=all,
context exhaustion is real and needs transcript investigation.

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

### Plan now correctly prioritizes the harness fix

The updated plan puts "Clean .rebase-tmp/" first, which is
correct. This one fix may resolve both stale-branch AND
step-skipping failures (if step-skipping was caused by stale
orchestrator resume rather than context exhaustion).

The plan should also add the branch cleanup fix (checkout
default branch before deleting bump branches). Even after
cleaning .rebase-tmp/, old bump branches in the main repo
will confuse `_do_record_one`'s fallback branch detection.

### Pre-push hook cleanup dropped from plan

The previous plan version included "Pre-push hook cleanup —
Hook persists after rebase, blocks `git push`." The updated
plan removed it. The bug is confirmed: all 6 test repos have
stale `pre-push` hooks from prior runs (verified on disk).
In production, this silently blocks `git push` after every
rebase until the user manually removes the hook. Should be
re-added to "Production hardening."

### Hook session guards dropped from plan

The previous plan included "Hook session guards — The 3
markdown hooks block `go mod tidy`, `git push`, vendor edits
in ALL repos, not just during rebases." The updated plan
removed it. The bug is confirmed: the `.md` hooks have no
`.session-active` check and fire unconditionally when the
plugin is installed. Should be re-added.

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

### Plan's priorities are now correct

After the update, the plan correctly puts the harness fix
first. The three failure buckets:

1. **Stale state + stale branch (58 failures, 54%)** — plan's
   `.rebase-tmp/` cleanup + audit's branch cleanup fix this.
2. **Gate failures (44 failures, 41%)** — companion scripts
   address flaky subset. Correct as second priority.
3. **Other (6 failures, 5%)** — court FAIL, no branch, etc.

The key question is how much of bucket #1 survives after the
cleanup fix. A clean batch will answer this.

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

### Harness bugs (two root causes, both verified)

| Issue | Scale | Root cause | Fix |
|-------|-------|-----------|-----|
| Stale .rebase-tmp/ | Unknown (plan says ALL ovnk) | Stale state.json causes orchestrator resume; stale .session-active triggers stop hook | `rm -rf .rebase-tmp/` before launch |
| Stale branch detection | 20 failures (19%) | Main repo stuck on bump branch, `_do_record_one` fallback finds old branch | Checkout default before cleanup; filter branches by age |

### Unknown until after cleanup fix

| Issue | Scale | What we'll learn | First step |
|-------|-------|-----------------|------------|
| Residual step-skipping | TBD after cleanup | Whether step-skipping was stale resume or context exhaustion | Run clean batch. If still failing, add transcript capture. |

### Lower-priority improvements

| Issue | Impact | When |
|-------|--------|------|
| New companion scripts (8) | Reduces gate flakiness | After step-skip root cause found |
| Steps 2/3 PENDING pattern | Saves agent calls | After scripts shipped |
| Gate consolidation | Marginal | After measuring |

---

## 10. Recommended Ship Order

1. **Clean .rebase-tmp/ + stale branches in harness** — the
   plan's `rm -rf .rebase-tmp/` fix plus the audit's branch
   cleanup (checkout default before `git branch -D bump*`).
   Also: manually clean the 6 test repos now (unlock
   worktrees, prune, delete stale branches, checkout default).

2. **Run a clean batch** — this reveals the REAL pass rate
   once stale state is eliminated. Many of the 58 "stale
   state + step-skipping" failures may disappear.

3. **Fix hook session guards + imports.sh args + pre-push
   cleanup** — trivial bug fixes, independent of batch results.

4. **Fix GPG signing** — test `GIT_CONFIG_COUNT` stacking.

5. **Assess residual step-skipping** — if step-boundary
   failures persist after cleanup, add transcript capture and
   investigate context exhaustion vs satisficing.

6. **Then**: companion scripts, gate polish, PENDING pattern.
