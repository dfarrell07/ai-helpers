# Plan: k8s-rebase Next Iteration

## Context

Orchestrator architecture is complete and matrix-tested. Aug 11:
22 PASS / 19 FAIL. Zero gate-quality, zero step-skipping, zero court
failures. All failures are infrastructure — 12 stale-branch, 3
missing-gates, 2 no-branch-found, 1 near-miss, 1 CNCC missing-14.

34 adversarial Opus agents (14 verification + 20 challenge) reviewed
every claim. Key corrections: rules.md "contradiction" is actually
correct design (hook allows scripts), robustness section 6 already
implemented or theoretical, companion scripts "9 EASY" reduced to 2
truly deterministic, stale detection needs redesign not just reordering.

## Phase 1: Unblock testing (do first — 63% of failures)

### 1a. Fix stale-branch detection (redesign, not just reorder)

**Root cause (verified by 4 agents):** Two failure modes:
1. Branch forked from old HEAD — `k8s-rebase.sh` creates `bump1.35`
   from `main`, tip commit is months old, detection says "stale"
2. Branch deletion fails — `cmd_run()` deletes branches BEFORE
   `reset_to_default`, git refuses to delete checked-out branch

**Detection redesign:** Replace commit-timestamp check (line ~903)
with reflog-based branch creation time. Reflog records when
`git switch -c` actually ran, not the age of the forked commit.

```bash
# Before (broken): compares commit author time vs launch time
branch_tip_epoch=$(git log -1 --format='%ct' "$result_branch")

# After: compares branch creation time vs launch time
branch_created_epoch=$(git -C "$repo" reflog show "$result_branch" \
  --date=raw 2>/dev/null | tail -1 | awk '{print $NF}' | tr -dc '0-9')
```

**Ordering fix:** Move `reset_to_default "$repo"` BEFORE branch
deletion in `cmd_run()`. Handle dirty-worktree case (use
`git checkout -f` like the `from_commit` path does).

**Also:** Add bump-branch cleanup to `cmd_clean()` (currently only
cleans `_test-from-*` branches).

**File:** `test/test-skill.sh`

### 1b. Add fail_code column to results.tsv

3 codes (per observability skeptic — 7 is too many):

| Code | Covers |
|------|--------|
| `INFRA` | stale branch, crash, no branch, no gates, session died |
| `GATE` | missing gates, gate failures, gate flakes |
| `COURT` | court verdict FAIL |

Append as column 7 — verified safe (no consumers check NF).
Auto-classify in `_do_record_one` with a simple case statement
matching existing detail strings.

Drop duration_s and diff_hunks (no actionable decisions from them).

**File:** `test/test-skill.sh`

## Phase 2: Fix confirmed bugs (user-visible + crash-causing)

### 2a. Orchestrator: empty array + set -u portability
Lines 266, 319-321, 325 iterate empty arrays under `set -euo pipefail`.
Use `"${arr[@]:+"${arr[@]}"}"` (colon form — treats empty same as
unset). The no-colon form `+` doesn't guard empty arrays.
**File:** `scripts/k8s-rebase-orchestrator.sh`

### 2b. step3-autofix.md: Add advance bash block
Line 130 has prose only — user-visible bug (rebase hangs after
autofix, relies on SKILL.md fallback). Add `## Advance` section
matching step1/step2 pattern.
**File:** `skills/k8s-rebase/steps/step3-autofix.md`

### 2c. Autofix signal cleanup
`k8s-rebase-autofix.sh` line 324: `RESULT: FAIL` → `RESULT:
ITEMS_REMAINING`. Line 325: `return "$F"` already handles exit
code. Step3 already uses ITEMS_REMAINING language (verified) —
only the script itself needs changing.
**File:** `scripts/k8s-rebase-autofix.sh`

### 2d. write-gate-report.sh: Add HEAD SHA
Stale detection in orchestrator is dead code — `report_is_fresh()`
always returns "fresh" because no HEAD line exists.
Add: `echo "HEAD: $(cd "$REPO" && git rev-parse HEAD)"`
**File:** `scripts/write-gate-report.sh`

### 2e. Orchestrator: remove count_reports dead code
Lines 93-98 defined but never called. Delete.
**File:** `scripts/k8s-rebase-orchestrator.sh`

### 2f. maintainer-review.md: Fix FAIL/PASS contradiction
Line 27 says "FAIL if scope creep" but line 55 says "always PASS."
Informational gate — fix line 27 to say always PASS.
**File:** `gates/step4-verification/maintainer-review.md`

## Phase 3: Fix newly discovered gaps

### 3a. Step5 / stop-hook race condition (critical)
After step4 advances, orchestrator returns `DONE: true`. Stop hook
allows exit. But SKILL.md says "after DONE, read step5-pr.md." If
the agent stops between DONE and step5 execution, the entire rebase
completes with no PR command. Fix: step5 must complete before DONE.

### 3b. Force-advance counter persists across sessions
`.advance-attempts-stepN` files survive crashes. A session that
crashes twice at step 2 will force-advance on the third session's
first attempt. Fix: clear advance-attempt files on `cmd_init`.

### 3c. Resume ignores version mismatch
`cmd_init` on resume uses stored version, ignores the argument.
User re-invokes with different version — no warning. Fix: compare
stored vs argument, warn if different.

### 3d. step5-pr.md: Inline JSON schema for rebase-report
~45-line schema from original SKILL.md lost during decomposition.
Agents produce inconsistent report structures without it.
**File:** `skills/k8s-rebase/steps/step5-pr.md`

### 3e. Court juror VERIFIED: enforcement
Juror prompt requires VERIFIED: line with tool use, but parsing
only checks VERDICT:. Add grep check, treat missing as ABSTAIN.
**File:** `test/test-skill.sh`

## Phase 4: Companion scripts (2 only — verified deterministic)

### 4a. cleanliness.sh
Truly deterministic (verified by adversarial review): git status +
find + git ls-files. Zero judgment needed.

### 4b. diff-scope.sh
Classify changed files by extension. Count unexpected file types.

**Template:** Use gate-script-lib.sh init_gate/finish_gate — NOT
build-vet.sh's line-counting heuristic (doesn't generalize).

**Security:** Double-quote all `$REPO` expansions. Validate repo
paths against `[a-zA-Z0-9_./-]` in init_gate.

### 4c. Migrate crd-validation.sh to gate-script-lib.sh
Predates the library. Uses inline set -uo pipefail, manual BASE.

## Phase 5: Quality polish (if time permits)

### 5a. Standardize advance commands across step files
Currently 3 different patterns ($REPO_ROOT, $(pwd), git rev-parse).
Standardize on step2 pattern (derive REPO_ROOT inline).

### 5b. Expand rules.md container section
Currently 5 lines. Add podman examples, container-vs-host guidance.

## Verification

- `shellcheck scripts/*.sh test/test-skill.sh` after each phase
- `make lint` after each phase
- Phase 1: run 3+ repos, confirm zero stale-branch failures
- Phase 2-3: targeted 1 repo × 1 version per fix
- Phase 4: verify companion scripts produce correct PASS/FAIL
- Final: full matrix pass, grep fail_code distribution

## Not yet (defer to future iteration)

- Remaining companion scripts (7 Tier 2 candidates)
- events.jsonl telemetry (_telem(), enhanced cmd_watch)
- Self-improving loop (suggestions.jsonl)
- Discovery procedures (replacing version-specific recipes)
- Blocked dependency detection
- Three-tier gate classification annotation
- Gate consolidation (33 → ~28)
- Close the CI loop (draft PRs)
- CONTRIBUTING.md / glossary / architecture docs
- SKIP verdict handling in reconstruct_step
- Empty VERSION validation in SKILL.md bootstrap
