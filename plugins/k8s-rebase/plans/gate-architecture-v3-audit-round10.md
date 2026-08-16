# Gate Architecture v3 — Audit Round 10

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `8e4fbf13`
**Prior audits:** Rounds 1-9 (7+10+14+6+10+5+6+3+1 = 62 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — one HIGH and four MEDIUM findings; all are targeted spec
additions with no architectural rethink needed.

## Methodology

13-agent ultracode workflow: 6 dimension auditors, adversarial challenge of all 6 HIGH/MEDIUM
findings (default-to-refuted), synthesis. 606K tokens, 70 tool calls. 5/6 survived.

---

## Confirmed Correct (major new code)

| Claim | Status |
|-------|--------|
| `rm -rf "...court"/*` without `\|\| true` is a latent fragility | **Confirmed LOW (not current bug):** test-skill.sh uses `set -uo pipefail` WITHOUT `-e`; rm exits 1 on empty directory but execution continues. Adding `\|\| true` is good practice but not urgently needed. |
| `court-history.tsv` is correctly preserved by the `rm` (different path) | **Confirmed correct:** `rm` targets `.matrix-state/court/*` (cache); `court-history.tsv` lives at `test/court-history.tsv` — distinct paths, no collision. |
| Cache-miss detection at test-skill.sh:1336 correctly re-courts all repos after clearing | **Confirmed correct:** after clearing the cache, the file-existence check fails for every repo and all are re-courted from scratch. |
| Simpson's paradox analysis is correct — AGGREGATE exclusion is a sound decision | **Confirmed correct:** concrete example verified — AGGREGATE can rise with zero per-repo rate increases when one repo becomes INCON (excluded from pool). |
| `cmd_court` exit codes: 0=PASS, 1=FAIL, 2=INCONCLUSIVE | **Confirmed correct:** all INCONCLUSIVE cases (diff-too-large, majority failure, tied, no quorum) use `return 2`; true infrastructure errors exit before the court protocol at lines 1098-1100. |
| Infra-error filtering at test-skill.sh:1341-1348 correctly excludes pre-court failures | **Confirmed correct:** all filtered cases `continue` before `cmd_court` is ever called (line 1364). INCONCLUSIVE is a distinct class produced inside `cmd_court`. |
| `cmd_court_regression` works correctly even if AGGREGATE is absent from output | **Confirmed correct:** AGGREGATE skip is purely defensive — both anchor and fresh skips fire vacuously if AGGREGATE is absent. |
| Per-repo detection catches all genuine regressions | **Confirmed correct (refuted):** the plan's claim at line 1291 is about the Simpson's paradox comparison, not a detection-sensitivity guarantee. The adversary correctly noted the plan is contrasting per-repo with pooled-AGGREGATE, not claiming 100% sensitivity at all noise levels. |

---

## Survived Findings

### R1 — HIGH: `commit-court-baseline` has no INCON guard; frozen anchor can silently contain INCON repos

**Location:** Plan lines 1210-1224 (`cmd_commit_court_baseline`); lines 1083-1091 (condition iii); line 1256 (defensive skip)

**What is actually true:** `cmd_commit_court_baseline` performs three steps — pre-staged index
check, re-derive `court-baseline.tsv`, stage+commit — with no INCON scan at any step. The frozen
anchor `court-baseline-phase1.tsv` is created as a manual copy with no INCON check either. The
only barrier is `check-phase1-baseline` condition (iii), which the plan admits is "a reviewer-run
gate, not a corpus-forgery barrier" with "No existing CI job runs the harness." No Makefile
prerequisite relationship enforces it before `commit-court-baseline` runs.

`cmd_court_regression`'s awk at line 1256 silently skips INCON lines from the frozen anchor with
the comment "the baseline freeze rejects INCON, so this is defensive." If a developer runs
`make commit-court-baseline` without first running and passing `make check-phase1-baseline`, an
INCON repo enters `court-baseline-phase1.tsv`. `cmd_court_regression` then iterates `for (r in b)`
and never includes that repo. No WARN fires, no error is emitted, and the oversight is invisible
in all subsequent `make court-regression` output. Adversary confirmed.

**Impact:** A repo that is inconclusive-majority at Phase-1 baseline is permanently unmonitored for
regression — the exact "silent blind spot on the repos hardest to court" the plan warns about.

**Action:** Add an INCON check directly inside `cmd_commit_court_baseline`, between step 1
(re-derive) and step 2 (stage+commit): capture the `cmd_court_metrics` output, grep for
`INCON`-prefixed lines, and abort with a descriptive error if any are found. The check must run
against the re-derived output before any git operations, making the freeze self-enforcing
independent of whether `check-phase1-baseline` was run.

---

### R2 — MEDIUM: `conc[r]=0, inc[r]=0` silently bypasses INCON filter, emitting `0/0` in measured set

**Location:** Plan lines 1025-1028 (`cv[k]` increment logic) and line 1046-1047 (INCON guard)

**What is actually true:** The INCON guard `if (conc[r] < inc[r])` catches only the case where
inconclusive courts outnumber conclusive ones. When `cv[k]` is an unexpected value (empty field,
partial write, whitespace), `tot[repo[k]]++` fires at line 1025 but all three `if/else-if` branches
at lines 1026-1028 are skipped, leaving `conc[r]` and `inc[r]` at awk's default zero. The guard
then evaluates `0 < 0 = false`, the repo bypasses the INCON branch, and falls through to
`printf "%s\t%d/%d\n", r, ff[r], conc[r]` emitting `repo\t0/0`. The plan at line 1038 claims the
boundary covers "the all-inconclusive extreme conc==0" — but that holds only when `inc[r] > 0`.
The `conc=0, inc=0` state is a third, unguarded case. Adversary confirmed.

**Impact:** A repo with corrupt `court_verdict` values appears as a measured `0/0` entry rather
than an INCON marker. The no-regression gate treats it as 0% false-FAIL — a silent blind spot.

**Action:** Add an explicit guard for the `conc=0, inc=0` case in the emit loop:
```awk
if (conc[r] + inc[r] == 0) { printf "INCON\t%s\t0 conclusive of %d (unrecognized verdict values)\n", r, tot[r]; continue }
```
Place this before the existing `if (conc[r] < inc[r])` check. Update the plan's comment at line
1038 to clarify that `conc==0` with `inc==0` (not just `conc==0` from recognized INCONCLUSIVE
verdicts) is also INCON.

---

### R3 — MEDIUM: Plan correctly identifies the `_results_one` cache-write bug but does not specify correcting the contradicting comment

**Location:** `test/test-skill.sh:1581-1587`; plan lines 950-963

**What is actually true:** The plan correctly identifies the bug: `_results_one:1584`'s
`[[ -n "$_court_verdict" ]]` guard skips the cache write when `cmd_court` exits 2 (INCONCLUSIVE),
and correctly scopes the fix to `_results_one` only (since `cmd_court_all` already writes
INCONCLUSIVE at lines 1368-1374). Confirmed by live code: the comment at line 1581 reads "exit
2+ = infrastructure error (don't record)" — directly contradicting `cmd_court_all`'s treatment
of the same exit code as INCONCLUSIVE. A developer adding the INCONCLUSIVE cache-write path to
`_results_one` while leaving the comment in place embeds "don't record" immediately above code
that now records, causing confusion and likely reversion in a future cleanup. Adversary confirmed.

**Impact:** The fix is incomplete without the comment correction — a future reader would see the
contradicting comment and revert the code to match it, re-introducing the strand bug.

**Action:** Add an explicit step to the plan's fix description: the comment at
`test/test-skill.sh:1581` must be updated to read "exit 2 = INCONCLUSIVE (record to both cache
and journal so cmd_court_all re-courts instead of reading a stale verdict)."

---

### R4 — MEDIUM: INCON hard-fail of condition (iii) buried in a parenthetical; omissible from implementation

**Location:** Plan lines 1083-1091 (condition iii)

**What is actually true:** Condition (iii)'s stated subject (lines 1083-1084) is rate-boundary
consistency; the INCON check appears inside a multi-sentence parenthetical beginning "the
worst-per-repo scan reads only..." An implementer writing the rate-boundary check and treating
the parenthetical as explanatory rationale (explaining why INCON rows are excluded from the rate
scan) satisfies condition (iii)'s title while silently omitting the INCON grep — which is a
separate code path from the rate comparison. The 7-step Required Implementation Sequence (lines
698-721) contains no step mentioning INCON detection; step 7 says only "the mechanical gate over
steps 2/5/6 (conditions i-vi)" with no per-condition breakdown. Bold text partially mitigates
but does not resolve the structural gap. Adversary confirmed.

**Impact:** If condition (iii) is implemented as only a rate boundary check, `check-phase1-baseline`
passes on a baseline containing INCON repos, enabling R1's silent freeze.

**Action:** Either: (a) split condition (iii) into explicit sub-conditions (iii-a) rate-boundary
check and (iii-b) INCON-absent check with separate implementation notes; or (b) add "step 7a: scan
re-derived snapshot for INCON-prefixed lines and exit nonzero if any are found" to the 7-step
Implementation Sequence. Either makes the INCON grep a named deliverable, not a parenthetical.

---

### R5 — MEDIUM: All-infra-failure court run produces a false-green regression verdict (exit 0, block=0)

**Location:** Plan lines ~1248 (`cmd_court_regression`) and ~1367 (`cmd_court_regression_confirmed`)

**What is actually true:** When `cmd_court_metrics` receives a `court-history.tsv` containing
only infra-failure rows (stale branch, session ended, etc.), `tot[]` stays empty, the `for (r in tot)` loop iterates nothing, and only `AGGREGATE\t0/0` is emitted. `cmd_court_regression` then finds every anchor repo absent from the fresh snapshot and emits `MISSING\trepo\t...` lines with
rc=2. The hard-error guard fires only when `rc==2 AND NOT grep '^(MISSING|INCON)'` — but MISSING
lines ARE present, so the guard is bypassed. The confirm-by-rerun awk sees no REGRESSION (only
MISSING in `u1`/`u2`), sets `block=0`, and exits 0. An operator receives "phase may land" with
zero genuine court measurements. Adversary traced end-to-end and confirmed.

**Impact:** A matrix run producing only infra-failure rows (which the plan says can happen via
gate-level infra flakes) lets a phase land without any regression measurement.

**Action:** Add a fresh-snapshot guard in `cmd_court_regression`: after computing the fresh snapshot
from `cmd_court_metrics`, check if it contains zero per-repo rate lines (only AGGREGATE or
completely empty). If the frozen anchor has per-repo rates but the fresh snapshot has none, emit
a hard-error line (e.g., `ERROR: fresh snapshot has no per-repo rates — all courts were infra
failures`) and exit 2 with no MISSING/INCON lines, so the existing hard-error guard in
`cmd_court_regression_confirmed` correctly blocks. Update the plan's hard-error definition at
~line 1341 to include this case.

---

## Pre-Implementation Checklist (Round 10)

**Must fix before Phase 1 implementation (blocks correct behavior):**

- [ ] **R1 (HIGH):** Add INCON guard inside `cmd_commit_court_baseline` before `git add`:
  scan the re-derived `court-baseline.tsv` for `INCON`-prefixed lines and `return 1` with a
  descriptive error if any exist.

- [ ] **R5 (MEDIUM):** Add fresh-snapshot guard in `cmd_court_regression`: if anchor has
  per-repo rates but fresh snapshot is empty/AGGREGATE-only, exit 2 with an ERROR line (no
  MISSING/INCON) so the hard-error block fires.

- [ ] **R2 (MEDIUM):** Add `conc[r] + inc[r] == 0` guard in `cmd_court_metrics` emit loop,
  before the existing `conc[r] < inc[r]` check, routing fully-unrecognized-verdict repos to INCON.

- [ ] **R4 (MEDIUM):** Promote INCON check from condition (iii) parenthetical to an explicit
  sub-condition or named step in the 7-step Implementation Sequence.

- [ ] **R3 (MEDIUM):** Specify in the plan that `test/test-skill.sh:1581`'s comment must be
  updated alongside the cache-write fix (not just the code).
