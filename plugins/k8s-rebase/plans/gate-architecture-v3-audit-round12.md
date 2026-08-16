# Gate Architecture v3 — Audit Round 12

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `9707ee90`
**Prior audits:** Rounds 1-11 (7+10+14+6+10+5+6+3+1+5+4 = 71 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — one HIGH and two MEDIUM findings, all in the
`check-phase1-baseline` spec. **Phase 0 is fully specified and can begin immediately.** Phase 1
is blocked only by these three plan-text additions (roughly 20-30 lines total).

## Methodology

13-agent ultracode workflow: 5 dimension auditors, adversarial challenge of all 7 HIGH/MEDIUM
findings (default-to-refuted), synthesis. 476K tokens, 93 tool calls. 4/7 survived (one duplicate
collapsed, one confirmed as refuted on closer challenge read).

---

## Confirmed Correct (R2 explanation, R1/R3/R4 fixes)

| Claim | Status |
|-------|--------|
| R2: "No phase column in court-history.tsv schema" — mechanization is impossible | **Confirmed correct:** schema is `version⇥repo⇥spec⇥gate_verdict⇥detail⇥court_verdict⇥ts`, no phase column. The absence is a deliberate design choice but the mechanization conclusion is sound. |
| R2: Sentinel/timestamp alternatives also fail | **Confirmed correct:** a sentinel written by commit-court-baseline "at Phase-1 time" cannot know which invocation is Phase 1; timestamp alternative requires a "Phase-2 start time" artifact that doesn't exist. |
| R2: Three safeguards are genuine but bypassable | **Confirmed correct:** numbered sequence, once-only anchor guard, and (iii-b) INCON check are all real but don't prevent a pre-freeze Phase-2 court run. |
| R1: `git commit -s` added to `cmd_freeze_court_anchor` | **Confirmed correct:** line 1324 now has `-s` with the DCO comment. |
| R3: `return 1` in condition (iii-b) pseudocode | **Confirmed correct:** line 1132 now says `return 1` matching every other `cmd_*` block. |
| R4: awk skip pattern in condition (iii-a) | **Confirmed correct:** skip handles AGGREGATE (load-bearing — format-indistinguishable from per-repo rates), MEASURED, and INCON. |
| test-skill.sh:1581 comment — R3 fix not applied yet | **Correctly not applied:** the plan requires the comment be corrected in the same edit as the code change; since the code change hasn't shipped yet, the comment accurately describes the live code. No gap. |
| R2: "refuse to roll while anchor absent" guard analysis | **Confirmed correct:** both the incomplete and harmful characterizations are accurate; the narrower "refuse if second run" variant also fails (second-run detection requires another operator-timed marker). |

---

## Survived Findings

### R1 — HIGH: `END{...}` in condition (iii-a) awk is a literal placeholder — check-phase1-baseline is unimplementable as written

**Location:** Plan lines 1126-1129

**What is actually true:** The awk snippet for condition (iii-a) terminates with the literal token
`END{...}` — an unexpanded placeholder. The body must:
- **(a)** Compare `worst` (worst per-repo rate) against the 10% threshold
- **(b)** Extract and compare the aggregate rate against 5% — **impossible in the same awk pass**
  since AGGREGATE is explicitly skipped by `$1=="AGGREGATE"...{next}`, so a separate awk
  pass on the re-derived output's AGGREGATE line is required but nowhere specified
- **(c)** Reconcile both results with the decision token in `phase1-decision.txt`

No other location in the plan expands this block. Two independent auditors confirmed; two
separate challenge agents failed to refute the gap.

**Adversary notes** (from the successfully-refuted challenge): the adversary agent at index 6
claimed the surrounding prose at lines 1113-1129 "fully specifies all four steps." But this
describes what condition (iii-a) must DO, not how to implement the END body — specifically, it
doesn't resolve the aggregate-via-a-separate-pass requirement.

**Impact:** An implementer who writes only the per-repo accumulation loop (which the plan gives)
and invents the END body produces a gate that silently passes a court with aggregate false-FAIL
> 5% as long as no single repo exceeds 10%.

**Action:** Replace `END{...}` with a complete, runnable END body. The structure must:
1. Compare `worst` against `0.10` and set a per-repo FAIL flag if exceeded
2. Add a **separate awk pass** on the AGGREGATE line from the re-derived output (since AGGREGATE
   is skipped in the worst-per-repo accumulation): `awk -F'\t' '$1=="AGGREGATE"{split($2,p,"/"); agg=p[1]/p[2]} END{exit (agg>0.05)}'`
3. Extract the decision token from `phase1-decision.txt` with `head -1` and check consistency:
   `proceed-to-phase2` only when at least one boundary is exceeded; `stop-after-phase0` otherwise
4. Specify the two-pass structure explicitly so implementers don't attempt to squeeze both checks
   into one awk pass and silently discard the aggregate check

---

### R2 — MEDIUM: `phase1-decision.txt` file format never formally specified

**Location:** Plan lines 726 and 1117-1118

**What is actually true:** Step 6 says "Record and commit `test/metrics/phase1-decision.txt`
(chosen branch + measured rates)" with no field spec, delimiter, or line layout. Condition (ii)
names the two fields but specifies no encoding.

The challenge agent at index 9 partially refuted this: condition (iv) at line 1149 says "reads
the rates from that re-derived output (not from the committed file)" — meaning rates don't need
to be parsed from `phase1-decision.txt`, only the decision token does. This narrows the gap but
does not eliminate it: the token format (bare string? key=value? with surrounding whitespace?
case-sensitive?), its position in the file (line 1? anywhere?), and what the two legal values are
(`stop-after-phase0`/`proceed-to-phase2` or something else?) remain unspecified. Two implementers
can write incompatible formats, making the writer (step 6) and the condition (iii-a) reader
silently inconsistent. Adversary confirmed at MEDIUM severity.

**Action:** Add a one-line canonical format spec adjacent to step 6 and condition (ii):
"Line 1: exactly one of `stop-after-phase0` or `proceed-to-phase2` (bare token, no trailing
whitespace). Line 2 (informational, not machine-read): `agg=<decimal> worst=<decimal>`
space-delimited. Condition (iii-a) extracts the decision token with
`head -1 test/metrics/phase1-decision.txt | tr -d '[:space:]'` — only two legal values, so a
grep suffices."

---

### R3 — MEDIUM: No condition in `check-phase1-baseline` verifies `court-baseline-phase1.tsv` is committed

**Location:** Plan lines 1113-1189 (conditions i-vi)

**What is actually true:** Conditions (i)-(vi) check `court-history.tsv`, `court-baseline.tsv`,
`phase1-decision.txt`, rate consistency, INCON absence, and the permissions probe — but no
condition checks that `test/metrics/court-baseline-phase1.tsv` exists and is committed. The
implementation sequence places `make freeze-court-anchor` (step 5) before `make check-phase1-baseline`
(step 7) as prose ordering only — no mechanical dependency enforces it.

An operator who skips step 5 passes all six conditions and enters Phase 2 with no anchor. Every
subsequent `make court-regression` call then hard-errors at the anchor-missing guard at line 1361
(`[[ -s "$base" ]] || { echo "ERROR: ..."; return 2; }`), disabling regression enforcement for
Phases 2-5. The plan's claim that (iii-b) provides "defense in depth" for anchor purity is
inaccurate for the anchor-absent case: (iii-b) re-derives from `git show HEAD:court-history.tsv`
and checks for INCON markers, never reading `court-baseline-phase1.tsv`. Adversary confirmed.

**Adversary note:** The consequence is a hard error at court-regression time (not silent), so the
failure is loud rather than masked. But the error fires only after Phase-2 matrix runs have
appended court rows, making a clean Phase-1-only freeze impossible to recover.

**Action:** Add condition (vii) to `check-phase1-baseline`:
```bash
git show HEAD:test/metrics/court-baseline-phase1.tsv > /dev/null 2>&1 || \
  { echo 'ERROR: court-baseline-phase1.tsv not committed — run make freeze-court-anchor'; return 1; }
```
Insert before condition (i) so it fails fast. Also correct the "defense in depth" characterization
at lines 1141-1142: note that (iii-b) detects INCON in an existing anchor but does not detect an
absent one — only condition (vii) catches that case.

---

## Confirmed Correct (convergence assessment)

**Phase 0 is fully specified and implementation-ready.** The P0a crash-branch bodies, `_gate_trap`
rewrite, orchestrator rc-capture, `cmd_init` cleanup, timeout tiering, and the three verbatim
sentinels for condition (v) are all present with exact code. No architectural gaps remain.

**R2 discipline explanation is sound.** The plan correctly identifies that no data-mechanical guard
can enforce Phase-1 purity without schema changes (a phase column or a separate Phase-1 court log).
The three safeguards (numbered sequence, once-only anchor guard, INCON re-verification) are genuine.
The plan is transparent that this is a discipline invariant, not a mechanical barrier.

**No internal contradictions.** The R2 discipline explanation (lines 1277-1304) is consistent with
earlier text. The plan consistently distinguishes mechanized checks from discipline gates.

---

## Confirmed as LOWs (not blocking)

| Finding | Status |
|---------|--------|
| `PLUGIN_DIR` used in `cmd_court_regression_confirmed` but never defined in plan | LOW — presumably set by test environment; plan should add one line noting it must be defined in test-skill.sh |
| `cmd_commit_court_baseline` missing `-s` flag on its `git commit` | LOW — the commit description exists only in prose, not a code block; add `-s` to the prose or show a code block matching `cmd_freeze_court_anchor` |
| Condition (v) permanently fails on post-Phase-2 invocations without a diagnostic | LOW — `make check-phase1-baseline` runs once at Phase-1→Phase-2 boundary; post-Phase-2 operators should not invoke it, but no guard prevents accidental re-invocation |
| "Physically separate Phase-1 court log" understated as equivalent to "schema change" | LOW — a separate file (same schema) requires no column additions; the plan could clarify this distinction |
| Phase-2 courts before freeze are undetectable by all three safeguards | LOW — acknowledged by the plan as the accepted residual risk of the discipline-gate design |

---

## Pre-Implementation Checklist (Round 12)

**Must fix before Phase 1 implementation (condition iii-a/iii-b spec completion):**

- [ ] **R1 (HIGH):** Replace `END{...}` with a complete two-pass implementation:
  - Pass 1 (already shown): accumulate `worst` per-repo rate, skip AGGREGATE/MEASURED/INCON
  - Pass 2 (new): extract AGGREGATE line from re-derived output and compare to 0.05
  - Add decision-token reconciliation with `phase1-decision.txt`
  - Specify the two-pass structure explicitly

- [ ] **R2 (MEDIUM):** Add one-line canonical format spec for `phase1-decision.txt` adjacent to
  step 6 and condition (ii).

- [ ] **R3 (MEDIUM):** Add condition (vii) to `check-phase1-baseline` verifying
  `court-baseline-phase1.tsv` is committed. Correct the "defense in depth" characterization
  at lines 1141-1142.

**Phase 0 is ready — no blockers.**
