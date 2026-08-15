# Gate Architecture v3 — Audit Round 9

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `18566e53`
**Prior audits:** Rounds 1-8 (7+10+14+6+10+5+6+3 = 61 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — one HIGH finding in the core regression gate logic; one LOW
(accepted as-is). Fix is bounded and well-defined: ~10 lines added to `cmd_court_metrics` and
`cmd_court_regression_confirmed`.

## Methodology

15-agent ultracode workflow: 6 dimension auditors, adversarial challenge of all 8 HIGH/MEDIUM
findings (default-to-refuted), synthesis. 751K tokens, 103 tool calls. 2/8 survived; the
surviving LOW was adversarially confirmed but accepted by the synthesizer as within acceptable
risk for the gate's threat model.

---

## Confirmed Correct (major new code)

| Claim | Status |
|-------|--------|
| `awk exit block` in `cmd_court_regression_confirmed` — bash propagates as function exit status | **Confirmed correct:** awk is last command in function; bash returns its exit code |
| Hard-error check `rc==2 && ! grep -q '^MISSING'` — correctly separates anchor-missing from per-repo MISSING | **Confirmed correct:** anchor-absent exits before awk (no MISSING lines emitted); per-repo MISSINGs emit lines |
| MISSING-in-sample-1 + REGRESSION-in-sample-2 → BLOCK, not WARN | **Confirmed correct:** `!(x in r2)` is false so WARN loop skips it; `reg` union includes it → BLOCK via `other_missing` |
| Intentional-removal-invisible claim | **Confirmed correct:** append-only log keeps old rows; latest-row-wins includes the stale entry; removed repo never shows MISSING |
| `patterns-completeness.md:18` exact verbatim text matches plan quote | **Confirmed:** byte-for-byte match including `---` decorators |
| `cmd_court_regression` and `cmd_court_regression_confirmed` are separate functions with correct return mechanics | **Confirmed:** inner uses `PIPESTATUS[0]`; outer uses `exit block` in awk END block |
| MISSING from cleanly-passing repo → WARN (not BLOCK) | **Confirmed correct:** gv!="FAIL" rows excluded from cmd_court_metrics; repo absent from fresh snapshot; WARN emitted |

---

## Survived Findings

### R1 — HIGH: INCONCLUSIVE court verdicts in sample 2 silently clear a REGRESSION as AI variance

**Location:** Plan lines 1237-1244 (cross-kind gap prose); lines 1286-1303 (awk in `cmd_court_regression_confirmed`)

**What is actually true:** The plan's cross-kind gap fix (lines 1239-1244) closes the
REGRESSION+MISSING case but leaves REGRESSION+INCONCLUSIVE-dominated open. The data flow is
confirmed end-to-end:

1. `cmd_court_metrics` (line 1004): counts only `cv=="PASS"` as false-FAILs. INCONCLUSIVE courts
   do not satisfy this, so they contribute 0 to the numerator but N to the denominator. The repo
   appears in the fresh snapshot as `repo_name\t0/N` — **it is PRESENT, not MISSING**.

2. `cmd_court_regression` (line 1220): cross-multiply `0*M > X*N` → false. No REGRESSION emitted
   for this repo in sample 2. The repo is also not MISSING — it IS in sample 2 as 0/N.

3. `cmd_court_regression_confirmed` awk: r1 has the repo (REGRESSION in sample 1); r2 and m2 do
   not. `other_missing = (x in m2) = 0`. The awk takes the else branch: "INFO: regressed one run
   only, clean in the other → variance" — **no block**.

A genuine gate false-FAIL regression flagged in sample 1 is silently dismissed as AI variance when
sample 2 produces all-INCONCLUSIVE court verdicts (tied votes, no quorum, empty jurors). The
plan's prose at line 1241 says "the other run cleanly measured that repo and did not flag it" —
but a 0/N rate from all-INCONCLUSIVE courts is not a clean measurement; it is indistinguishable
from a legitimately improved repo. Adversary confirmed end-to-end.

**Impact:** A real gate false-FAIL regression passes the regression gate and advances the phase.
The degraded gate ships to production — the silent-bad-rebase failure mode the plan exists to
prevent.

**Action:** Add INCONCLUSIVE-dominated tracking to `cmd_court_metrics`: count INCONCLUSIVE court
verdicts per repo alongside `ff[]` and `d[]`. When `ff[r]==0` and `inc[r]==d[r]` (all trials
INCONCLUSIVE), emit a separate marker (e.g., `INCON\trepo_name\t0/N`) alongside or in place of
the normal rate row. Update `cmd_court_regression` to emit an `INCON` flag for such repos rather
than a normal rate comparison. Update the awk in `cmd_court_regression_confirmed` to populate an
`ic1[]`/`ic2[]` array from `INCON` lines, and treat INCON in the other sample identically to
MISSING in the `other_missing` check (unconfirmable → BLOCK). This closes the
REGRESSION+INCONCLUSIVE-dominated gap symmetrically with the existing REGRESSION+MISSING gap.

---

### R2 — LOW (accepted as-is): `cmd_court_metrics` latest-row-wins can mask a regression behind concurrent gate-infra flakes

**Location:** Plan lines 990-1007 (`cmd_court_metrics` awk)

When the most recent matrix run produced a gate-infra failure (detail matching the infra filter),
that row is the latest row and is excluded. Prior valid court rows are overwritten in the awk's
associative array and never consulted. Two concurrent gate-infra runs (one per sample) convert a
measured repo to MISSING in both samples, producing a WARN rather than a BLOCK.

**Why accepted:** The two-sample design partially mitigates this: REGRESSION+MISSING still BLOCKs
(each sample independently), so masking a regression requires simultaneous independent infra
failures in both samples AND a regression signal in neither sample — a low-probability conjunction.
Even when it occurs, the output is visible WARNs on all affected repos, not silent false-PASS.
The adversary confirmed this assessment. The plan should add a comment in `cmd_court_metrics`
acknowledging that a gate-infra row permanently replaces prior valid rows for that key, and that
concurrent infra failure across both samples downgrades a potential BLOCK to WARN.

---

## Refuted Findings

| Finding | Refutation |
|---------|-----------|
| "Claim 3 is false when the gate run itself was a gate-infra failure" (transient court failure → PRESENT) | **Refuted:** "session ended" writes to `results.tsv`, not `court-history.tsv`; `court-history.tsv` is Phase 1 infrastructure not yet implemented; the plan correctly distinguishes gate-infra (→ MISSING) from transient court failure (→ PRESENT as 0/den) |
| `"or neither"` readable as permission to permanently skip 4a/4b | **Refuted:** 4b is labeled MANDATORY with explicit false-PASS consequence named at line 1444; the surrounding "do both... or neither" applies atomically |
| Deleting `.matrix-state/` allows single INCONCLUSIVE to silently overwrite PROBE-BROKEN | **Refuted:** `make clean` deletes only repo-keyed files and session markers, not `.matrix-state/probe-inconclusive-streak.txt` (confirmed by `cmd_clean` trace) |
| "Transient court failure → PRESENT (0/den)" claim is false when latest row is infra-excluded | **Refuted:** The plan correctly distinguishes the two paths; the claim describes a gate-infra failure routing through results.tsv exclusion (→ MISSING), not a transient court failure which stays in the fresh snapshot |
| REGRESSION+MISSING=BLOCK gives no diagnostic resolution path | **Refuted:** The plan's two-way taxonomy (gate passes cleanly OR gate-infra flake) gives a concrete diagnostic: if the repo passes cleanly, it's progress; if it's a gate-infra flake, re-run |
| Phase 2 step 4 `crd-validation` swap lacks explicit labeled atomicity signal | **Refuted:** Lines 1428-1429 contain explicit atomicity warning ("not a bare deletion; do not drop the lead-in without landing the P0a body"); intentional asymmetry with patterns-completeness is explained |
| `"${x:-0}"` as the idiomatic alternative to the cat pattern | LOW (not challenged) — the complete `cat` pattern is shown first and is canonical; the idiom is offered as an alternative and is ambiguous without context, but the primary pattern is clear |

---

## Pre-Implementation Checklist (Round 9)

**Must fix before Phase 1 implementation:**

- [ ] **R1 (HIGH):** Track INCONCLUSIVE-dominated repos as a third signal category in
  `cmd_court_metrics` (an `INCON` row when all N trials are INCONCLUSIVE). Update
  `cmd_court_regression` to emit an `INCON` flag and `cmd_court_regression_confirmed`
  to treat INCON in the other sample identically to MISSING (BLOCK). This is the only
  remaining blocker.

**Acknowledge (no code change needed):**

- [ ] **R2 (LOW):** Add a comment to `cmd_court_metrics` acknowledging that latest-row-wins
  means a gate-infra row permanently replaces prior valid rows, and that concurrent infra
  failure in both samples downgrades a BLOCK to WARN. No code change required.
