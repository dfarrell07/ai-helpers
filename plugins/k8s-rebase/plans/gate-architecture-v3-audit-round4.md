# Gate Architecture v3 — Audit Round 4

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `1568ee84`
**Prior audits:** Rounds 1-3 (7+10+14 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — one HIGH (live bug needs P0a; plan describes fix correctly),
four MEDIUM plan-text defects; two LOW. Architecture is sound. Phase 0 ships immediately
after two small plan-text fixes (R2, R4 correction). Phase 1 needs R3 added as a deliverable.

## Methodology

22-agent ultracode workflow: 8 dimension auditors, adversarial challenge of all 13 HIGH/MEDIUM
findings (default-to-refuted), then synthesis. 953K tokens, 212 tool calls. 6/13 survived.

**Dimensions:** awk script + court-history schema · check-phase1-baseline correctness ·
Phase 1 court enforcement flags · Phase 2 step 4 fallback retargeting · court-history
gitignore + write sites · Phase 2 step 7 minimum-count · live code claim verification ·
overall convergence

---

## Survived Findings

### R1 — HIGH: Orchestrator discards companion exit code — live false-PASS for timed-out `go build`

**Location:** `k8s-rebase-orchestrator.sh:203`, `build-vet.sh:23-24`

**What is actually true:** `orchestrator.sh:203` runs the companion as
`if output=$(timeout ... bash "$companion" ...); then`, discarding the child exit code.
`build-vet.sh:23-24` wraps each inner tool as `timeout ... go build ./... 2>&1) || true`, so a
timed-out `go build` (exit 124) is forced to exit 0 by `|| true`. Empty `build_out` → 0 counted
error lines → `finish_gate 0` → autonomous PASS written to disk. The next `cmd_gates` invocation
finds the PASS report fresh and counts the gate RESOLVED. A repo whose `go build` never
completed ships with an autonomous gate PASS and unverified compilation. **Confirmed against
live code; the adversary confirmed the full false-PASS chain.** This is a live issue today.

**Note on plan status:** The plan correctly identifies and describes this bug at principle 4
and Phase 0(d). The fix code is spelled out verbatim at lines 593-599. This finding is HIGH
because the bug is live today — it is not a plan gap, but a reminder that P0a must land before
Phase 4 promotes `build-vet` to `filter`, and ideally before the first production use of
this codebase after any plan changes.

**Action:** Implement Phase 0(d) in P0a: capture `build_rc` before `|| true` in build-vet.sh;
on `>= 124`, write the `.crash` breadcrumb keyed on `$GATE_NAME` and `trap - EXIT; exit 0`
with no verdict written. Simultaneously restructure orchestrator.sh:203 to capture `rc` from
the outer companion timeout and write `.crash` on `rc >= 124`. Implement from the plan's
verbatim snippet at lines 593-599 — do not re-implement from memory.

---

### R2 — MEDIUM: Gitignore instruction is factually wrong and actively harmful if followed

**Location:** Plan line 824 (Phase 1 court-history paragraph)

**Plan claims:** "put it one level up under test/ (add an explicit `test/.gitignore` negation,
or a top-level allow, so it is tracked)" — implying `test/court-history.tsv` would be gitignored
without an explicit negation.

**What is actually true:** `git check-ignore -v plugins/k8s-rebase/test/court-history.tsv`
exits 1 — the file is **not ignored**. `test/` has no `.gitignore`; only
`test/.matrix-state/.gitignore` and `test/.repos/.gitignore` exist, each scoped to their own
subdirectory with `* !.gitignore`. An implementer following the primary instruction and creating
`test/.gitignore` must write `* !.gitignore !court-history.tsv` to make the negation effective,
which creates a catch-all `*` that silently ignores every future addition to `test/` — including
`test/assert-evidence-paths.sh` and `test/metrics/court-baseline.tsv` that the plan itself
specifies. Adversary **confirmed from `git check-ignore`**.

**Action:** Delete the parenthetical at line 824. Replace with: "place it directly at
`test/court-history.tsv` — that path is not covered by any `.gitignore` and is immediately
trackable. **Do not add a `test/.gitignore`.**" One-line plan-text fix.

---

### R3 — MEDIUM: `bypassPermissions` fix has prose-only verification — can silently be a no-op

**Location:** Plan lines 707-713 (Phase 1, parts a+b); `test/test-skill.sh:17, 1229-1230`

**Plan claims:** "verify empirically that a juror's `git checkout` is denied after the change."
This is prose embedded in the plan with no test script, no Makefile target, no harness assertion.

**What is actually true:** `test-skill.sh:17` sets `PERMISSION_MODE=bypassPermissions` globally.
Lines 1188, 1194, 1209 (pros/def/judge) and 1229 (jurors) all inherit it via
`--permission-mode "$PERMISSION_MODE"`. The `--allowedTools` at line 1230 is a documented no-op
under `bypassPermissions`. A developer who edits only `--allowedTools` (confirmed no-op), or
substitutes another still-bypassing mode, ships an ineffective fix. The court baseline
measurement then measures the broken court. `check-phase1-baseline` measures aggregate
false-FAIL rates — an indirect signal that cannot distinguish "fix not applied" from
"fix applied but court still noisy." Adversary **confirmed from live code**. (The camelCase
`--disallowedTools` flag in the plan is valid; Claude CLI accepts both forms as aliases —
adversary verified.)

**Action:** Add a concrete harness check as a Phase 1 deliverable: `test/assert-court-permissions.sh`
(or a `cmd_assert_court_permissions` in `test-skill.sh`) that launches a minimal court role with
the new permission flags and asserts that a `git checkout` attempt exits nonzero. Wire it to a
k8s-rebase Makefile target and add it to the pre-Phase-2 checklist alongside
`check-phase1-baseline`. The verification step cannot remain prose-only for the fix that repairs
the verified false-FAIL vector.

---

### R4 — MEDIUM: `check-phase1-baseline` overclaims — catches only single-file inconsistency, not coordinated fabrication

**Location:** Plan line 876 (check-phase1-baseline, point iii)

**Plan claims:** check-phase1-baseline "(iii) the target **recomputes** the rates from
`court-baseline.tsv` and asserts the recorded decision is consistent… and that the recorded
rates match the recomputed ones (catches a stale, hand-edited baseline)."

**What is actually true:** `court-baseline.tsv` is the committed output of `cmd_court_metrics`
(the awk on `court-history.tsv`). "Recomputing from `court-baseline.tsv`" means re-parsing the
committed TSV to extract rates, then checking against `phase1-decision.txt`. If someone edits
BOTH `court-baseline.tsv` and `phase1-decision.txt` consistently to fabricate numbers (e.g.,
3% instead of 18%), the check finds matching values and exits 0. Detecting a fabricated
`court-baseline.tsv` requires re-running `cmd_court_metrics` from `court-history.tsv` and
diffing its output — a step the plan does not specify. Adversary **confirmed** (neither
`cmd_check_phase1_baseline` nor `test/metrics/` exist yet in the codebase — purely a spec defect).

**Action:** Amend the check-phase1-baseline spec to add step (iv): re-run `cmd_court_metrics`
from `court-history.tsv` and assert its output matches `court-baseline.tsv` byte-for-byte
(modulo timestamp). Change line 876 from "recomputes the rates from `court-baseline.tsv`" to
"recomputes the rates from `court-history.tsv` via `cmd_court_metrics` and asserts the output
matches `court-baseline.tsv`." The awk invocation is already specified; the diff step is a
one-liner addition.

---

### R5 — MEDIUM: Forgotten N-bump on conversion PR creates a permanent blind spot in the minimum-count guard

**Location:** Plan lines 1080-1088 (Phase 2 step 7)

**Plan claims:** "a converted companion that forgot its block then drops the count below N and
fails the build."

**What is actually true:** This protection only applies if N was already bumped in the conversion
PR. If a developer adds the EVIDENCE block (count goes N→N+1) but forgets to bump N, the
assertion sees N+1 ≥ N and passes. Later, if the block is accidentally removed (count back to N),
N ≥ N still passes — no signal. The plan's comment "bump as each conversion lands" is a
documented manual convention with no enforcement. Any conversion PR that skips the N-bump creates
a permanent blind spot. Adversary **confirmed** (assert-evidence-paths.sh does not exist yet —
purely plan-level; arithmetic confirmed correct).

**Action:** Use an exact-count form: assert `count == N` (not `count >= N`) so a conversion PR
that adds the block without bumping N produces `count=N+1 != N` and fails the build. This turns
a forgotten N-bump from a silent success into a red build. Alternatively, add a CI step that
prints `` `grep -c 'EVIDENCE (read before judging)' gates/**/*.md` `` in the PR diff so
reviewer and author see the actual count against the expected N.

---

### R6 — MEDIUM: Phase 2 step 4 locks in permanent redundancy the plan itself calls unnecessary

**Location:** Plan lines 1023-1026 (Phase 2 step 4); Execution model verbatim template
(lines 301-308)

**Plan claims:** Phase 2 step 2 adds the verbatim template (stale/missing branch: "judge from
scratch"). Phase 2 step 4 retargets the fallback to the same condition. The plan at lines
1023-1026 explicitly states: "This is the same condition the verbatim template's stale/missing
branch already states, so the fallback and the read-evidence block now describe one behavior."
Then keeps both anyway.

**What is actually true:** Two separate prose blocks in each converted `.md` file describe
identical behavior in slightly different words. Future edits to either block can drift
independently. The mitigation ("bundle with the atomic conversion so no PR leaves the two out
of sync") covers only the initial conversion — not post-landing edits. The plan's own
"do not re-word the template per file" principle is violated by its own retargeted fallback.
Adversary **confirmed** (the plan's own text acknowledges the redundancy without acting on it).

**Action:** At step 4, after retargeting the fallback, add a consolidation instruction: merge the
retargeted fallback into the verbatim template's stale/missing branch by extending it to name the
manual check list explicitly, then delete the standalone fallback paragraph. The template's
"ignore it and judge from scratch using the checks below" already provides the fallback trigger;
making "the checks below" name the actual check steps eliminates the need for a separate fallback
block. This is a 2-3 line edit to the per-companion atomic conversion procedure.

---

## Refuted / Downgraded Findings

| Finding | Disposition |
|---------|-------------|
| `--disallowedTools` camelCase vs kebab-case | **Refuted:** Claude CLI accepts both forms as documented aliases (`--allowedTools, --allowed-tools`) — auditor confirmed from `claude --help` |
| `$context` for prosecution includes git SHAs requiring tool use | **Refuted:** plan says prosecution needs no git *tools*, not that the prompt contains no SHA text; the verified failure required live `git show` of a stale file, not just SHA presence |
| Phase 2 step 4 retargeting instruction buried as "Also..." — easy to miss | **Refuted:** live companion .md files (build-vet.md:17, etc.) already say "If the companion script is not found" — not the widened "crashes or no NEW_ISSUES" form; the retargeting applies to P0a's future edits, and the plan's four-step structure labels step 4 clearly |
| P0a crash-branch placement for group-(ii) gates is unspecified — may vanish in Phase 2 | **Refuted:** the crash branch in crd-validation.md / patterns-completeness.md is structurally outside the MANDATORY FIRST STEP block (which is a self-contained bash snippet), so Phase 2 step 4's "drop only the FIRST STEP block" does not remove the crash branch |
| `_results_one` spec recovery uses "latest row" without spec alignment | **Refuted:** `_results_one` is called for a specific `(repo, spec, branch)` context in the interactive `make results --court` path; "latest row" for a given `(VERSION, short)` in its context always corresponds to the run being courted |
| Path-extraction spec for drift detection is absent — no greppable anchor | **Refuted:** the verbatim template always places the evidence path in backticks after `` if ` `` with `.rebase-tmp/gates/` prefix and `.evidence` suffix — a deterministic extraction point; the plan also cites the marker `EVIDENCE (read before judging):` which the step-7 lint greps for |
| Live `gate-script-lib.sh` has no canonical `.crash` path — plan references proposed code as live | **Refuted:** the plan at line 591 says "the canonical path from Phase 0(b)" — explicitly referencing Phase 0(b) as the future source, not the current lib; the `.crash` path is described prospectively throughout |
| `col-6 detail` not pre-extracted from `latest_line` at :1337-1339 | **Confirmed LOW** (not challenged): `$verdict` is pre-extracted at :1339 but `$spec` and `$detail` require `echo "$latest_line" | cut -f3` and `cut -f6` respectively — "in scope" is accurate but "append directly there" is misleading. An implementer who assumes `$spec` and `$detail` are ready variables gets empty string in the court-history row, breaking the infra-exclusion filter. Note the concrete impact, not just clarity. |
| `_append_court_history` helper location unspecified | LOW — no correctness risk; location is inferable from context (~line 1092) and a missing function causes immediate syntax error |
| Pre-Phase-2-PR checklist has no artifact (no CHECKLIST.md, no PR template) | LOW — plan is honest that this is a "discipline gate"; creating the Makefile target and documenting it is the actionable step |
| Empirical juror tool-denial verification has no harness mechanism | LOW — covered by R3's action (add `assert-court-permissions.sh`) |
| Retry loop also writes to court-history via `cmd_court_all` but not listed as append site | LOW — correct behavior (latest row by ts handles duplicates); documentation gap only |
| Plan concludes redundancy but does not act on it (retarget keeps block the plan calls unnecessary) | Confirmed as MEDIUM (R6) |

---

## Pre-Implementation Checklist (Round 4)

**Before P0a PR opens:**

- [ ] **R1 (implement — already in plan):** Ship Phase 0(d): `build_rc` capture + `.crash` write
  in build-vet.sh; orchestrator rc capture. Use verbatim snippet at plan lines 593-599.

**Plan-text fixes before Phase 1 implementation:**

- [ ] **R2 (MUST — harmful if followed):** Delete line 824 gitignore parenthetical. Replace with:
  "place directly at `test/court-history.tsv` — not covered by any `.gitignore`. Do not add
  `test/.gitignore`."
- [ ] **R4 (MUST — overclaims protection):** Change check-phase1-baseline spec at line 876 to
  add step (iv): re-run `cmd_court_metrics` from `court-history.tsv` and diff against
  `court-baseline.tsv`. Update "recomputes from `court-baseline.tsv`" to "recomputes from
  `court-history.tsv` via `cmd_court_metrics`."

**Before Phase 1 implementation:**

- [ ] **R3 (MUST — fix can be a no-op):** Add `test/assert-court-permissions.sh` as a Phase 1
  deliverable. Wire to Makefile. Add to pre-Phase-2 checklist alongside `check-phase1-baseline`.
  The verification step cannot remain prose-only.

**Before Phase 2 implementation:**

- [ ] **R5 (MUST — silent blind spot):** Change minimum-count assertion from `>= N` to `== N`
  so a forgotten N-bump fails the build. Or add a CI step printing the actual count.
- [ ] **R6 (should — redundancy the plan acknowledges):** Add consolidation instruction to
  Phase 2 step 4: after retargeting, merge the fallback into the verbatim template's
  stale/missing branch and delete the standalone fallback paragraph.
