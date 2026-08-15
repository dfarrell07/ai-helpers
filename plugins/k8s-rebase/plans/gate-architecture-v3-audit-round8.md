# Gate Architecture v3 — Audit Round 8

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `2e34d673`
**Prior audits:** Rounds 1-7 (7+10+14+6+10+5+6 = 58 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — three MEDIUM findings, combined fix is fewer than 15 lines of
plan text. Architecture is sound; all three are narrow specification gaps.

## Methodology

12-agent ultracode workflow: 6 dimension auditors, adversarial challenge of all 5 HIGH/MEDIUM
findings (default-to-refuted), synthesis. 515K tokens, 110 tool calls. 3/5 survived.

---

## Refuted Findings (confirmed correct)

| Finding | Refutation |
|---------|-----------|
| `cmd_court_regression_confirmed` silently false-PASSes when `cmd_court_all` doesn't write to court-history.tsv | **Refuted:** The plan explicitly addresses the write-path dependency at lines 930-939: court-history.tsv is written by both `cmd_court_all:1374` and `_results_one:1586` as Phase 1 deliverables. The parenthetical in `cmd_court_regression_confirmed` ("Phase 1 wires courting into the run") correctly frames this as Phase 1 work. |
| `cmd_court_regression_confirmed` calls `cmd_matrix all` twice — unacknowledged 8-16h cost | **Refuted:** The plan explicitly acknowledges the cost at line 1147 ("each matrix run is a large AI fan-out") and lines 1231-1233 ("runs *matrix + cmd_court_regression* **twice**"). The 2-run confirm-by-rerun design is intentional and consistent with the plan's existing variance-control model. |

---

## Survived Findings

### R1 — MEDIUM: `rc==2` block-on-either conflates transient infra failure with intentional repo removal

**Location:** Plan lines 1250-1252 (`cmd_court_regression_confirmed`)

**What is actually true:** The guard `if (( rc1 == 2 || rc2 == 2 ))` fires identically for two
structurally distinct causes: (1) a repo intentionally removed from the test set, and (2) a repo
whose courts failed transiently in that matrix run (rate limit, session timeout, network error).
When `cmd_court_all` courts a repo transitorily, it may write a row with an infra-failure detail
string ("session ended without result"). `cmd_court_metrics` excludes that row, making the repo
absent from the fresh snapshot — `cmd_court_regression` reports MISSING with `rc==2`. `rc1` is
captured before sample 2 runs and is permanent; even if sample 2 courts the repo successfully,
`rc1==2` triggers the block. The plan's only rationale for block-on-either ("a dropped repo is not
AI variance") does not distinguish transient infra failure from intentional removal. No
disambiguation or retry logic exists for the `rc==2` path. Adversary confirmed.

**Impact:** A single transient court infra failure in one matrix run blocks the phase, forcing a
full two-matrix restart that the developer must diagnose manually — friction proportional to the
cost of two matrix runs (4-8 hours each).

**Action:** Add a disambiguation note to the `cmd_court_regression_confirmed` spec: "MISSING
(`rc==2`) fires for both intentional repo removal and transient court infra failure; the operator
must re-run `cmd_court_regression_confirmed` as a unit (not just one sample) to distinguish them."
Alternatively, designate `rc==2` as a "soft block with logged reason" that retries the failed
sample once before hard-blocking, mirroring the `INCONCLUSIVE` probe model already in the plan.
Either removes the silent conflation and sets operator expectations correctly.

---

### R2 — MEDIUM: `probe-inconclusive-streak.txt` missing-file initialization never specified

**Location:** Plan lines 812-822 (durable streak counter spec)

**What is actually true:** Lines 812-822 describe the durable streak counter as "incremented on
every `INCONCLUSIVE` run, reset to `0` on any conclusive `PASS`/`FAIL`" — state-transition
language only. The plan never specifies what value to assume when the file is absent (fresh clone,
deliberate deletion, first run on any machine). A developer implementing `assert-court-permissions.sh`
could: (a) use bare `count=$(cat file)` which yields empty string on a missing file, causing
arithmetic failure; or (b) initialize to a large sentinel value, firing `PROBE-BROKEN` before any
real probe has run and blocking Phase 1 on first invocation. The plan is otherwise prescriptive to
the level of exact flag strings and exit-code semantics, making this omission notable against its
own quality bar. `assert-court-permissions.sh` does not yet exist. Adversary confirmed.

**Impact:** An implementer who uses a non-zero initialization default writes `PROBE-BROKEN` to the
result file on the first invocation on any fresh clone, blocking Phase 1 and misdirecting the
operator to "debug the probe" when no probe has ever been run.

**Action:** Add one sentence to the streak counter spec: "When the file is absent, treat the count
as `0` — use `count=$(cat "$streak_file" 2>/dev/null || echo 0)` or the `${:-0}` idiom." One line
closes the implementation trap entirely.

---

### R3 — MEDIUM: `patterns-completeness.md:18` header-rewrite still buried in prose, not a numbered sub-step

**Location:** Plan lines 1393-1399 (Phase 2 step 4)

**What is actually true:** The plan promotes the header-rewrite from a parenthetical with bold
"must also rewrite" language and the label "easily-missed sub-step — promoted here out of a
parenthetical." But the sub-step appears 50 lines into a single numbered item's (~500-word) prose
block at lines 1393-1399 with no 4a/4b label and no MANDATORY tag. The plan's own language ("easily-missed")
accurately describes the structural gap. A developer implementing step 4 from the numbered list
— reading "4. Drop only the FIRST STEP block" — must parse to the end of a multi-paragraph
discussion of crd-validation vs patterns-completeness shapes to find the additional required action.
If missed, the surviving header `--- Checks (PATH B only — skip entirely if PATH A applies) ---`
causes a subagent to read the gate as conditionally-skipping checks 1-4 — the plan's own text at
line 1398 confirms the consequence. Live confirmation: `gates/step3-autofix/patterns-completeness.md:18`
still reads `--- Checks (PATH B only — skip entirely if PATH A applies) ---` with `---` decorators
on both sides (plan's verbatim quote is now correct). Adversary confirmed.

**Impact:** If a developer drops the PATH A/B selector text but omits the line-18 header rewrite,
a subagent receives a gate file with no PATH A/B context yet a header reading "skip entirely if
PATH A applies" — likely skipping checks 1-4 and silently PASSing on a broken rebase.

**Action:** Split numbered step 4 into explicit sub-steps: "**4a.** Drop PATH A/B selectors (and
the FIRST STEP block for self-contained gates)." "**4b.** MANDATORY: rewrite the surviving checks
header at `patterns-completeness.md:18` to `--- Checks ---` in the same atomic edit." This aligns
with the plan's own "atomic per companion gate, in one edit" contract at line 1306 and makes the
header-rewrite impossible to miss in a sequential pass.

---

## Confirmed Correct (live code verification)

| Claim | Status |
|-------|--------|
| `patterns-completeness.md:18` verbatim text: `--- Checks (PATH B only — skip entirely if PATH A applies) ---` | **Confirmed** — byte-for-byte match |
| Checks 1-4 contain no internal PATH A/PATH B references | **Confirmed** — all four are self-contained |
| `awk FNR==NR` semantics with 0-byte anchor file | **Confirmed** — plan's comment about FNR==NR staying true for the empty-anchor case is empirically correct; `[[ -s "$base" ]]` guard is load-bearing |
| `rc1=$?` correctly captures awk's exit code from `cmd_court_regression` subshell | **Confirmed** — `PIPESTATUS[0]` is read before `return`, which evaluates its argument first |
| `split(b[r], bp, "/")` repo-name slash concern | **Confirmed non-issue** — `b[r]` holds `$2` (the N/M ratio), not `$1` (the repo name); no slash collision |
| `'PASS on a self-comparison'` absent from `crd-validation.md` and `patterns-completeness.md` | **Confirmed** — neither file contains this phrase; P0a has not landed |
| Streak counter survives `make clean` | **Confirmed** — `cmd_clean` removes specific markers but not `.matrix-state/probe-inconclusive-streak.txt`; durable by design |
| `cmd_matrix all` courts repos (appending to court-history.tsv) | **Confirmed** — `cmd_matrix` calls `cmd_court_all` (test-skill.sh line 1746); the append is a Phase 1 deliverable |

---

## Pre-Implementation Checklist (Round 8)

**Before any implementation:**

- [ ] **R1 (MEDIUM):** Add disambiguation note to `cmd_court_regression_confirmed` spec: transient
  court infra failures produce `rc==2` via the same path as a dropped repo; document that the
  operator must re-run the full two-sample sequence to disambiguate. Or add a targeted retry for
  the `rc==2` case.

- [ ] **R2 (MEDIUM):** Add one sentence to the streak counter spec (lines 812-822): "When the
  file is absent, treat the count as `0` — use `count=$(cat "$streak_file" 2>/dev/null || echo 0)`."

**Before Phase 2 implementation:**

- [ ] **R3 (MEDIUM):** Split Phase 2 step 4 into explicit sub-steps 4a and 4b, making the
  `--- Checks ---` header rewrite a MANDATORY labeled item in the same atomic edit as dropping
  PATH A/B selectors.
