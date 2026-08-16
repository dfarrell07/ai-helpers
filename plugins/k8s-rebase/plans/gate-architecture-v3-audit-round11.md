# Gate Architecture v3 — Audit Round 11

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `75caba03`
**Prior audits:** Rounds 1-10 (7+10+14+6+10+5+6+3+1+5 = 67 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — one HIGH (one-character fix) and one MEDIUM, plus two LOWs. All
fixes are narrow; no architectural changes needed. After R1+R2, the plan is implementation-ready.

## Methodology

13-agent ultracode workflow: 6 dimension auditors, adversarial challenge of all 6 HIGH/MEDIUM
findings (default-to-refuted), synthesis. 629K tokens, 79 tool calls. 4/6 survived.

---

## Confirmed Correct (major new code)

| Claim | Status |
|-------|--------|
| MEASURED counter semantics — PASS gate rows set `meas[]` correctly | **Confirmed correct:** `is_infra = (gv=="FAIL" && ...)` is false for PASS rows; `!is_infra` → `meas` set before `gv!="FAIL" continue` fires |
| All-repos-fixed success: MEASURED>0, no rate lines, `nf+ninc+fmeas` guard does NOT fire | **Confirmed correct:** MEASURED>0 makes `fmeas+0==0` false → guard does not fire → all repos MISSING → WARN → exits 0 (phase may land) |
| All-infra guard distinguishes from success via MEASURED=0 | **Confirmed correct:** infra rows excluded from `meas[]`; only non-infra rows set it |
| `(iii-b)` INCON check re-derives from committed log (not frozen anchor) | **Confirmed correct (refuted):** adversary confirmed this is the right target — checking current log state, not the anchor; the plan's "defense in depth" framing is accurate |
| `(iii-b)` prose/code mismatch — vacuous anchor-grep | **Confirmed correct (refuted):** implementation is embedded inline in the same sentence as the description; it is not an anchor-file grep and never was |
| `ninc==0` structurally redundant in all-infra guard | **Confirmed LOW:** `ninc>0` implies `fmeas>0`, so the clause is belt-and-suspenders; behavior is correct |

---

## Survived Findings

### R1 — HIGH: `cmd_freeze_court_anchor` git commit missing `--signoff`

**Location:** Plan line 1285

**What is actually true:** The bash code for `cmd_freeze_court_anchor` specifies:
```bash
git commit -m "Freeze Phase-1 court regression anchor"
```
No `-s` or `--signoff` flag. Every recent commit in this repository carries
`Signed-off-by: Daniel Farrell <dfarrell@redhat.com>` (confirmed across all three recent commits).
The global CLAUDE.md mandates `--signoff` on every commit. Any DCO CI check will reject the
anchor commit at push time, blocking the Phase-1 freeze workflow unexpectedly; absent DCO
enforcement, the commit ships silently non-compliant. Adversary confirmed.

**Action:** Change line 1285 to `git commit -s -m "Freeze Phase-1 court regression anchor"`.
One-character fix, no design change.

---

### R2 — MEDIUM: `freeze-court-anchor` `-s` guard cannot detect Phase-2-polluted rolling baseline

**Location:** Plan line 1276 (`cmd_freeze_court_anchor` spec)

**What is actually true:** The four guards in `cmd_freeze_court_anchor` are: (a) pre-staged index
clean, (b) anchor file absent, (c) rolling baseline non-empty (`[[ -s "$roll" ]]`), (d) no INCON
repos. None check whether the rolling `court-baseline.tsv` was produced from Phase-1-only courts
or from Phase-1+Phase-2 courts.

Exploit path: developer commits Phase-1 courts (`make commit-court-baseline`), skips
`make freeze-court-anchor`, runs Phase-2 courts, commits the baseline again (baseline now contains
Phase-1+Phase-2 data), then runs `make freeze-court-anchor`. All four guards pass silently
(anchor is absent, baseline is non-empty, no INCON) and the anchor is frozen with Phase-2-polluted
data. Every subsequent `make court-regression` compares against the wrong denominator, potentially
masking regressions introduced in Phase 2 — the primary purpose of the frozen anchor.

`check-phase1-baseline` (step 7) does NOT verify that `court-baseline-phase1.tsv` exists and
runs AFTER the freeze. The anchor-exists guard prevents a second freeze but cannot fix the first.
Adversary confirmed with full exploit-path trace.

**Action:** Add a sequencing guard to `cmd_freeze_court_anchor`. Two options: **(a) sentinel
file** — `make commit-court-baseline` writes a sentinel like
`test/metrics/.phase1-courts-only-committed` at Phase-1 time; `freeze-court-anchor` requires
this sentinel to exist and to have been written BEFORE any Phase-2 court rows appear in
`court-history.tsv` (check via timestamp or a git-log count of entries after Phase-1); **(b)
documentation guard** — explicitly state in the plan that `make freeze-court-anchor` must be
the next command immediately after Phase-1 `make commit-court-baseline`, before any Phase-2
courts run, and add a `check-phase1-baseline` condition that verifies the frozen anchor's
timestamp precedes any Phase-2 court appends. Option (a) is preferable because it is
mechanically enforceable rather than procedural.

---

### R3 — LOW: `exit 1` in condition (iii-b) prose pseudocode contradicts `return 1` convention

**Location:** Plan line 1123

The inline prose at line 1123 shows:
```
flat=$(cmd_court_metrics <(git show HEAD:test/court-history.tsv)); grep -q '^INCON' <<<"$flat" && exit 1
```
inside `cmd_check_phase1_baseline`. All three formal bash code blocks for `cmd_*` functions use
`return`: `cmd_freeze_court_anchor` (lines 1274-1282), `cmd_court_regression` (line 1322),
`cmd_court_regression_confirmed` (line 1470). The adversary confirmed the inconsistency is real
but downgraded to LOW since the exit appears only in prose pseudocode (not a formal code block)
and since `cmd_check_phase1_baseline` runs in a subprocess when invoked via `make`. The risk
materializes only if a future implementer copies the pseudocode literally AND the function is
later called from another function in the same process.

**Action:** Change the prose pseudocode at line 1123 from `exit 1` to `return 1` and add a
parenthetical: "(use `return 1`, not `exit 1`, so the function composes safely with any future
wrapper)."

---

### R4 — LOW: `(iii-a)` rate-scan skip requirement is prose-only — no pseudocode showing `AGGREGATE`/`MEASURED`/`INCON` exclusion

**Location:** Plan lines 1117-1121

The plan specifies in prose that the worst-per-repo scan "must skip the `AGGREGATE`, `MEASURED`,
and `INCON` keys, which are not per-repo rates," but provides no concrete pseudocode for condition
(iii-a) itself. `cmd_court_regression` at line 1328 shows the exact awk skip pattern:
`if ($1=="AGGREGATE" || $1=="INCON" || $1=="MEASURED") next`. `AGGREGATE` has a valid `ff/den`
format (e.g., `4/7`) indistinguishable from a per-repo rate; a naive implementation that does
not skip it applies the aggregate false-FAIL rate against the ≤10% per-repo boundary and produces
a wrong proceed/stop decision. Adversary confirmed; downgraded to LOW since the three keys are
explicitly named in prose, reducing the hidden-constraint risk.

**Action:** Add a short awk pseudocode snippet for condition (iii-a) at line 1121, mirroring the
cmd_court_regression pattern:
```awk
awk -F'\t' '$1=="AGGREGATE"||$1=="INCON"||$1=="MEASURED"{next} ...'
```
This eliminates the inconsistency with (iv) and cmd_court_regression, which both show explicit
skip patterns.

---

## Confirmed Correct (other notable verifications)

| Claim | Status |
|-------|--------|
| INCON guard in `freeze-court-anchor` reads working-tree file (not committed) | **Acceptable (LOW):** plan's sequencing (commit immediately before freeze) makes them identical; user-error scenario only |
| `grep -q '^INCON'` could match repo named `INCON-something` | **LOW:** `INCON\t` prefix in INCON marker lines is unambiguous; no real Kubernetes repo name starts with INCON; adding `\t` would be belt-and-suspenders |
| Phase-2-polluted baseline — `check-phase1-baseline` doesn't verify anchor existence | **Part of R2** — the step-5/step-7 sequencing gap is the root issue |
| `ninc==0` in all-infra guard is structurally redundant | **LOW:** Belt-and-suspenders; behavior correct; no bug |
| MEASURED key breaks equality check on old committed baselines | **LOW migration concern:** only affects developers continuing from a partial prior Phase-1 attempt; new Phase-1 runs unaffected |

---

## Pre-Implementation Checklist (Round 11)

**Must fix before Phase 1 implementation:**

- [ ] **R1 (HIGH, one character):** Change line 1285 from `git commit -m "..."` to
  `git commit -s -m "..."`.

- [ ] **R2 (MEDIUM):** Add a sequencing guard to `cmd_freeze_court_anchor` that verifies the
  rolling baseline was produced from Phase-1-only courts (sentinel file approach preferred).

**Low priority (bundle with R1/R2 fixes):**

- [ ] **R3 (LOW):** Change `exit 1` to `return 1` in the condition (iii-b) prose pseudocode at
  line 1123; add parenthetical about composition safety.

- [ ] **R4 (LOW):** Add awk pseudocode snippet to condition (iii-a) showing the
  `AGGREGATE`/`MEASURED`/`INCON` skip pattern.
