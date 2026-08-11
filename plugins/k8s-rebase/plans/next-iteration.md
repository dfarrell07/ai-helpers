# Plan: k8s-rebase Next Iteration

## Context

Orchestrator architecture is complete and matrix-tested. Aug 11 results:
22 PASS / 19 FAIL. Zero gate-quality failures, zero step-skipping, zero
court failures. All failures are infrastructure — 12 stale-branch (root
cause found: ordering bug), 3 missing-gates, 2 no-branch-found, 1
near-miss, 1 CNCC missing-14.

14 adversarial Opus agents verified every claim. 13 confirmed, 1
partially refuted (companion script count), 1 refuted (loop var leak —
no actual bug). Cross-reference against original plan found 6 additional
gaps not previously captured.

## 1. Fix stale-branch root cause (highest impact — 63% of failures)

**Root cause (verified by 2 independent agents):** In test-skill.sh
`cmd_run()`, branch deletion (line ~438) runs BEFORE `reset_to_default`
(line ~471). If the repo is checked out on `bump1.35`, `git branch -D
bump1.35` silently fails because git refuses to delete the current
branch. The old branch persists, k8s-rebase.sh creates
`bump1.35-TIMESTAMP` (or crashes before committing), and
`_do_record_one` finds the old branch with pre-launch timestamps →
"stale branch."

**Fix:** Move `reset_to_default "$repo"` (or `git checkout` to default
branch) BEFORE the branch deletion block. Also add bump-branch cleanup
to `cmd_clean()`.

**File:** `test/test-skill.sh`

## 2. Fix confirmed bugs (8 items, all verified by agents)

### 2a. write-gate-report.sh: Add HEAD SHA for stale detection
Orchestrator's `report_is_fresh()` greps for `^HEAD: ` but
write-gate-report.sh never writes it — stale detection is dead code.
Add after line 27: `echo "HEAD: $(cd "$REPO" && git rev-parse HEAD)"`
**File:** `scripts/write-gate-report.sh`

### 2b. step3-autofix.md: Add advance bash block
Line 130 has prose only — no executable bash block. Other steps have
`## Advance` sections. Replace with proper section matching step1/step2.
**File:** `skills/k8s-rebase/steps/step3-autofix.md`

### 2c. step5-pr.md: Inline JSON schema for rebase-report
~45-line JSON schema from original SKILL.md was lost during
decomposition. Step5 has prose only. Add schema inline at step 5d.
**File:** `skills/k8s-rebase/steps/step5-pr.md`

### 2d. maintainer-review.md: Fix FAIL/PASS contradiction
Line 27 says "FAIL if scope creep" but line 55 says "always PASS."
This is informational — fix line 27 to match.
**File:** `gates/step4-verification/maintainer-review.md`

### 2e. Court juror VERIFIED: enforcement
Juror prompt requires VERIFIED: line with tool use, but parsing only
checks VERDICT:. Add `grep -qiE '^VERIFIED:'` check, treat missing
as ABSTAIN. Compatible with existing quorum logic (verified).
**File:** `test/test-skill.sh`

### 2f. Orchestrator: empty array + set -u portability
Line 325 iterates empty arrays under `set -euo pipefail` — crashes
bash < 4.4. Use `"${arr[@]+"${arr[@]}"}"` syntax or guard with length
check. Line 266 has the same issue (`${#missing[@]}` crashes first).
**File:** `scripts/k8s-rebase-orchestrator.sh`

### 2g. Orchestrator: remove count_reports dead code
Lines 93-98 define `count_reports` but it's never called. Delete.
**File:** `scripts/k8s-rebase-orchestrator.sh`

### 2h. rules.md: Fix go-mod contradiction + scope ban
Line 25 globally bans `go mod tidy/get/vendor` but step2 and step3
instruct direct use. The ban targets gate subagents but reads as
absolute. Scope it: "NEVER run go mod tidy/get/vendor directly —
these are run only through step instructions or rebase scripts."
**File:** `skills/k8s-rebase/steps/rules.md`

## 3. Autofix signal cleanup (from original plan section 4.3)

Not captured in previous iteration plan. Three items:
- `k8s-rebase-autofix.sh`: Change `RESULT: FAIL` → `RESULT:
  ITEMS_REMAINING` (FAIL is misleading — items remaining is normal)
- Change `exit 1` → `exit 0` (non-zero exit triggers crash trap)
- Move "FAIL is normal" message before the bash block in step3

**File:** `scripts/k8s-rebase-autofix.sh`, `steps/step3-autofix.md`

## 4. Step file quality improvements

### 4a. Standardize advance commands
Step files use 3 different patterns (`$REPO_ROOT`, `$(pwd)`,
`$(git rev-parse --show-toplevel)`). Advance also happens in SKILL.md
(redundant but harmless — orchestrator is idempotent). Standardize
all step files on the step2 pattern (derive REPO_ROOT inline).

### 4b. Expand rules.md container section
Currently 5 lines. Add: podman test-split example, when to use
containers vs host, volume mount patterns.

### 4c. Migrate crd-validation.sh to gate-script-lib.sh
Predates the library — uses inline set -uo pipefail, manual BASE
computation, prints NEW_ISSUES= instead of calling finish_gate.
Migrate to source/init_gate/finish_gate pattern.

## 5. Companion scripts (revised from "9 EASY" → tiered approach)

Adversarial review showed only **cleanliness** is truly fully
deterministic of the 5 "EASY" gates checked. Others have judgment
edges (commit-to-module matching, stdlib name derivation, prose vs
assignment distinction).

**Revised approach — Tier 2 scripts (evidence + AI judgment):**
Script gathers deterministic evidence, outputs NEW_ISSUES count
for the easy parts. AI judges only the flagged edge cases.

**Truly deterministic (Tier 1):**
- `cleanliness.sh` — git status + find + git ls-files (verified)
- `build-vet-recheck.sh` — go build/vet per module (step4 re-run)
- `test-compilation.sh` — go test -run='^$' (core is deterministic)
- `diff-scope.sh` — classify changed files by extension

**Evidence-gathering (Tier 2):**
- `rebase-completeness.sh` — core checks only, skip commit matching
- `version-completeness.sh` — grep for stale versions, skip prose
- `deprecated-imports.sh` — hardcoded table only, skip arbitrary x/
- `autofix-result.sh` — git log + go build exit code
- `deprecated-calls.sh` — staticcheck output, AI judges context

Pattern: source gate-script-lib.sh, init_gate, run checks,
finish_gate. Template: build-vet.sh.

## 6. Robustness (from original plan, not previously captured)

### 6a. Oscillation detection
Stop gate-fix loop when a fix causes regression (gate that was
passing now fails). Not implemented anywhere.

### 6b. Dirty-tree check
`git status --porcelain` at gate-fix loop start. Prevents running
on repos with uncommitted changes.

### 6c. Centralize timeout in gate-script-lib.sh
Currently inline in each script (`timeout "${GATE_TIMEOUT:-300}"`).
Move to `init_gate` or provide a `run_with_timeout` wrapper.

## 7. Observability (results.tsv + failure taxonomy)

### Current: 6 columns (ts, version, spec, repo, verdict, detail)
No header row. Append-only.

### New columns (append — verified safe, no consumers break)
| Column | Source | Notes |
|--------|--------|-------|
| `duration_s` | `$(date +%s) - launch_epoch` | Both already tracked |
| `diff_hunks` | `kg_hunks` | Already computed at line ~935 |
| `fail_code` | Auto-classified | See taxonomy below |

### Failure taxonomy
| Code | Detection |
|------|-----------|
| `INFRA-STALE` | detail contains "stale branch" |
| `INFRA-CRASH` | session-died path (multiple detail strings) |
| `INFRA-NOGATE` | gtotal == 0 |
| `INFRA-NOBRANCH` | detail contains "no branch found" |
| `SKIP-BOUNDARY` | detail contains "missing N of M gates" |
| `GATE-FLAKE` | gate failed after previous pass |
| `COURT-FAIL` | court verdict FAIL |

Note: INFRA-CRASH needs a catch-all — any result from the
`$_session_dead` path that doesn't match other patterns.

**File:** `test/test-skill.sh` (_do_record_one, session-died path)

## Verification

After each section:
- `make lint` passes
- Targeted test: 1 repo × 1 version confirms fix
- After all: full matrix pass
- Stale-branch count should drop to near-zero (was 12/19)
- Compare fail_code distribution before/after

## Not yet (defer to future iteration)

- events.jsonl telemetry (`_telem()`, enhanced cmd_watch)
- Self-improving loop (suggestions.jsonl)
- Discovery procedures (replacing version-specific recipes)
- Blocked dependency detection
- Three-tier gate classification annotation in gate files
- OCP version mapping hoisting
- Close the CI loop (draft PRs)
- Gate consolidation (33 → ~28)
