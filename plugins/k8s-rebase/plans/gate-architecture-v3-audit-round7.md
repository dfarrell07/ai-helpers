# Gate Architecture v3 — Audit Round 7

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `47de33fd`
**Prior audits:** Rounds 1-6 (7+10+14+6+10+5 = 52 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — one HIGH and four MEDIUM findings, plus one LOW.
The plan is nearly ready; all six fixes are surgical additions to existing sections.

## Methodology

19-agent ultracode workflow: 6 dimension auditors, adversarial challenge of all 11
HIGH/MEDIUM findings (default-to-refuted), synthesis. 801K tokens, 194 tool calls.
7 survived (including two from independent auditors converging on the same gap).

---

## Survived Findings

### R1 — HIGH: `make court-regression` has no algorithm, threshold, or exit-code contract

**Location:** Plan lines 1155-1158; confirmed by two independent auditors

**What is actually true:** `make court-regression` is named as the sole gating mechanism
for Phase 2 and Phase 3 landings — "run before each phase lands, require no pass-rate
regression and no new false-FAIL (confirm-by-rerun, per-repo)." But it receives only prose
intent. Compare to every other target in the plan: `cmd_court_metrics` gets a full 18-line
awk block (lines 976-993) and `check-phase1-baseline` gets six explicit conditions with
literal grep strings. `make court-regression` is missing: the comparison algorithm (awk join
on repo column, parse N/M fraction, compare rates); what numeric delta constitutes "no
regression" (strict equality vs tolerance); the exit-code contract (nonzero on detected
regression); and treatment of repos absent from the baseline. Confirmed: zero occurrences
of `court_regression` or `cmd_court_regression` in `test-skill.sh`. Two adversary agents
both failed to refute this finding.

**Action:** Add a concrete awk/bash block to the plan analogous to the `cmd_court_metrics`
block. Specify: (1) parse `court-baseline-phase1.tsv` and fresh `cmd_court_metrics` output
into per-repo rate pairs; (2) flag any repo whose false-FAIL rate increased (strictly greater,
even by one point over the same denominator); (3) treat repos present in baseline but absent
in working-tree output as an error; (4) treat repos absent from baseline as out-of-scope
(skip); (5) exit nonzero with a per-repo diff table on any regression; (6) "confirm-by-rerun"
= regression must appear on two successive runs before blocking — state this explicitly. The
exit-code contract must be stated the same way `check-phase1-baseline` states it.

---

### R2 — MEDIUM: Pre-staged index changes are swept into the court-baseline commit; plan's safety guarantee is incomplete

**Location:** Plan lines 1148-1152

**What is actually true:** Lines 1148-1152 claim that using explicit `git add <log> <baseline>`
and never `git commit -a/-am` means "a concurrently-edited frozen anchor or unrelated
worktree change can never be swept into the roll." The `-a/-am` exclusion is correct for
tracked-but-unstaged working-tree files, but plain `git commit` without `-a` commits
everything currently in the index, including files staged by a prior `git add` before the
target ran. A developer who staged unrelated work-in-progress before invoking
`make commit-court-baseline` gets those changes committed silently alongside the two court
files. The frozen-anchor protection claim is also incomplete: if a developer staged
`court-baseline-phase1.tsv` before invoking the target, it would be swept in too.
The plan contains no mention of an index-clean guard. Adversary confirmed.

**Action:** Add `git diff --cached --quiet || { echo 'ERROR: index has pre-staged changes;
stash or commit them first'; exit 1; }` as the first operation in `cmd_commit_court_baseline`,
before any `git add` calls. Update lines 1148-1152 to replace "can never be swept" with
"cannot be swept by working-tree auto-staging; the target additionally rejects a dirty index."

---

### R3 — MEDIUM: `probe-broken` state is console-only; committed file stays `INCONCLUSIVE` and is indistinguishable from a one-time transient

**Location:** Plan lines 806-832

**What is actually true:** After 3 consecutive `INCONCLUSIVE` results the plan emits a
"probe-broken diagnostic" (line 815, "emit"), but the plan defines exactly three file values
— PASS/FAIL/INCONCLUSIVE — and `probe-broken` is not a fourth value written to
`assert-court-permissions-result.txt`. A reviewer running `make check-phase1-baseline` hours
after the probe ran sees `INCONCLUSIVE` in the file and has no way to distinguish "one
transient hiccup, just re-run" from "probe ran 3 times and is systematically broken, debug
the probe." The plan's intended operator response is completely different in each case, but
the committed artifact is identical. The plan also specifies no mechanism for persisting the
consecutive-INCONCLUSIVE count between process invocations (no count file, no log), though
the adversary correctly notes the counter is intended to be tracked manually by the operator
— the gap is the file ambiguity, not the automation. Adversary confirmed.

**Action:** Either (a) add `PROBE-BROKEN` as a fourth permitted value written to
`assert-court-permissions-result.txt` after the third consecutive `INCONCLUSIVE`, with
condition (vi) updated to treat `PROBE-BROKEN` as blocking with distinct prose distinguishing
it from plain `INCONCLUSIVE`; or (b) add a durable `test/metrics/probe-inconclusive-streak.txt`
file that is incremented on each `INCONCLUSIVE` run and reset to 0 on any conclusive result,
giving a later reviewer a durable signal. Specify option (a) or (b) explicitly in the plan so
the implementer knows which to build.

---

### R4 — MEDIUM: Phase 2 step 4 header-rewrite is a trailing parenthetical, not a numbered sub-step

**Location:** Plan lines 1301-1304 (Phase 2 step 4)

**What is actually true:** The plan requires that dropping the PATH A/B selectors in
Phase 2 step 4 also rewrites `patterns-completeness.md:18` from
`--- Checks (PATH B only — skip entirely if PATH A applies) ---` to an unconditional
header. This is stated only as a trailing parenthetical in the dense step 4 prose, not as
a numbered sub-step. The plan's own rationale at lines 1341-1343 explicitly states that
item 6 was "promoted here to an explicit numbered sub-step so it is not missed by a
developer following only the list" — the header-rewrite carries identical miss-risk but
was not promoted. If missed, the dangling "PATH B only — skip entirely if PATH A applies"
header remains after PATH A/B definitions are gone, causing subagent confusion about
whether to skip checks 1-4. Adversary confirmed; downgraded from HIGH to MEDIUM (an LLM
subagent finding no PATH A definition would most naturally run the checks rather than skip
them, but the confusion risk is real).

**Action:** Promote the header-rewrite to a numbered sub-step in Phase 2 step 4's list,
positioned after the PATH A/B deletion steps. Also correct the quoted header text: the
actual `patterns-completeness.md:18` reads `--- Checks (PATH B only — skip entirely if
PATH A applies) ---` (with `---` on both sides), not the plan's quoted form which omits
the decorators. See also R6.

---

### R5 — MEDIUM: Condition (v-c) grep sentinel `'self-comparison'` is 15 characters and is shorter than the plan's own specification

**Location:** Plan line 1052

**What is actually true:** The plan defines the empty-BASE guard sentinel at lines 531-534
as the full phrase "never PASS on a self-comparison" — explicitly calling these "the verbatim
sentinels `check-phase1-baseline` condition (v) greps for." But line 1052 implements the
actual grep as `grep -q 'self-comparison'` — only the 15-character suffix. A comment such
as "# prevents self-comparison scenarios" or any incidental use of the word in
`crd-validation.md` satisfies the 15-character grep while the actual guard body is absent
or incomplete. The current `crd-validation.md` contains zero occurrences (confirmed by grep),
so post-P0a the phrase appears exactly once in the guard — but no mechanism enforces
uniqueness or position. The plan is self-inconsistent: the spec names the longer phrase;
the check uses the shorter suffix. Adversary confirmed.

**Action:** Change `grep -q 'self-comparison'` to `grep -q 'PASS on a self-comparison'`
at line 1052 and in any surrounding prose. This is a strict substring of the required guard
phrase from lines 531-534, would not match typical incidental prose, and is consistent with
the plan's own specification of the verbatim sentinel.

---

### R6 — LOW: Plan quotes `patterns-completeness.md:18` without its `---` decorators

**Location:** Plan line 1302 vs `gates/step3-autofix/patterns-completeness.md:18`

The actual text at `patterns-completeness.md:18` is
`--- Checks (PATH B only — skip entirely if PATH A applies) ---` (with `---` on both sides).
The plan's quoted target at line 1302 omits both decorators. An Edit operation using the
plan's quoted string as `old_string` would produce a "not found" error (not silent corruption)
because the substring does match with standard tools. The explicit `:18` cite means a careful
implementer will look up the exact text — but the plan's quoted string is factually wrong and
will waste implementation time.

**Action:** Update the quoted text at line 1302 to include the `---` decorators:
`--- Checks (PATH B only — skip entirely if PATH A applies) ---`. Also specify the
replacement target (e.g., `--- Checks ---` or just `Checks`) to make the plan's edit
self-contained and pasteable.

---

## Refuted Findings

| Finding | Refutation |
|---------|-----------|
| Sentinel markdown constraint has no pre-Phase-1 detection mechanism | **Refuted:** The plan acknowledges check-phase1-baseline is a discipline gate, not an automated lint check. The flat()+grep runs at the Phase-1→Phase-2 boundary and catches malformatted sentinels then. |
| Consecutive-INCONCLUSIVE counter needs automated persistence | **Refuted:** The counter is explicitly described as operator-tracked ("3× running") — the plan instructs the operator to count, not a script. Counter persistence is not a plan gap. |
| Phase 4 killed-tool fixture infrastructure not specified | **Refuted:** Plan lines 1448-1450 explicitly name the mechanism (SIGKILL/timeout a `go build` mid-run); `build-vet.sh` lines 23-24 expose `GATE_TIMEOUT` directly. |
| Conditions (i)-(vi) have no specified evaluation order | **Refuted:** Numbered list implies sequential evaluation in English; git-show condition (iv) is positioned after file-existence condition (i), which guards it. Plan wording is unambiguous. |

---

## Pre-Implementation Checklist (Round 7)

**Must fix before any implementation begins:**

- [ ] **R1 (HIGH):** Add awk/bash block specifying `make court-regression`: comparison
  algorithm, numeric threshold (strict per-repo rate increase), exit-code contract (nonzero
  on regression), treatment of baseline-absent repos, and confirm-by-rerun operationalization.

**Must fix before Phase 1 implementation:**

- [ ] **R2 (MEDIUM):** Add `git diff --cached --quiet` guard as the first operation in
  `cmd_commit_court_baseline`. Update lines 1148-1152 to correct the safety claim.
- [ ] **R3 (MEDIUM):** Specify whether `probe-broken` writes a fourth value to
  `assert-court-permissions-result.txt` or uses a separate streak-count file.
- [ ] **R5 (MEDIUM):** Change `grep -q 'self-comparison'` to `grep -q 'PASS on a self-comparison'`
  at line 1052 and all surrounding prose references.

**Must fix before Phase 2 implementation:**

- [ ] **R4 (MEDIUM):** Promote patterns-completeness.md:18 header-rewrite to a numbered
  sub-step in Phase 2 step 4 (not a parenthetical).

**Low priority (bundle with the MEDIUM fixes):**

- [ ] **R6 (LOW):** Update quoted `patterns-completeness.md:18` text at plan line 1302 to
  include `---` decorators on both sides and specify the replacement target text.
