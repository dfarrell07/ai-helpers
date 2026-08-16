# Gate Architecture v3 — Audit Round 13

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `4a42f267`
**Prior audits:** Rounds 1-12 (7+10+14+6+10+5+6+3+1+5+4+3 = 74 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — three MEDIUM and four LOW findings, all Phase 1 scope.
**Phase 0 is READY_TO_IMPLEMENT** — no findings touch Phase 0 scope.

## Methodology

7-agent ultracode workflow: 5 dimension auditors, adversarial challenge of the 1 HIGH/MEDIUM
finding raised (refuted), synthesis. 359K tokens, 49 tool calls. 0/1 HIGH/MEDIUM survived.
Synthesizer elevated three LOWs to MEDIUM based on shared anti-fabrication failure mode.

---

## Confirmed Correct (major new code)

| Claim | Status |
|-------|--------|
| Condition (iii-a) two-pass bash: `worst` and `agg` arithmetic | **Confirmed correct:** awk accumulates `worst` via `w+0` default, `agg` via `a+0` default; `p[2]>0` guard handles zero-denominator; `binds` comparison `[[ "$binds" == 1 ]]` uses string comparison on "1"/"0", correct after `$(...)` strips trailing newline |
| Skip pattern in pass 1: AGGREGATE/MEASURED/INCON excluded | **Confirmed correct:** all three summary keys are correctly skipped; AGGREGATE skip is load-bearing since its `ff/den` format is indistinguishable from per-repo rates |
| `binds=$(awk -v a="$agg" -v w="$worst" 'BEGIN{...}')` float comparison | **Confirmed correct:** awk -v passes strings as numeric context; float comparison `a>0.05 || w>0.10` is arithmetically correct |
| Condition (vii) "evaluate first" instruction | **Confirmed correct (refuted):** the plan says "*first*" (italicized) immediately after the (vii) snippet at lines 1219-1222; the instruction is visible and explicit, not buried |
| Phase 0 specification completeness | **Confirmed READY_TO_IMPLEMENT:** _gate_trap code, crash-path convention, build-vet inner-tool capture, timeout tiering, P0a landing order, three-part crd-validation sentinel, one-part patterns-completeness sentinel — all complete and implementation-ready |
| No internal contradictions between round-12 additions and existing text | **Confirmed:** conditions (iii-a)/(iii-b)/vii, two-line phase1-decision.txt format, and discipline-invariant framing are all internally consistent |

---

## Survived Findings

### F1 — MEDIUM: Condition (iii-a) reads `phase1-decision.txt` from working tree, not committed HEAD

**Location:** Plan line 1150

**What is actually true:** The (iii-a) code reads:
```bash
decision=$(head -1 test/metrics/phase1-decision.txt | tr -d '[:space:]')
```
This reads the working-tree file. But the entire anti-fabrication rationale of conditions (i)-(iv)
is committed-to-committed: (i) checks both TSV files are committed; (iv) re-derives from
`git show HEAD:test/court-history.tsv`; (vii) uses `git show HEAD:test/metrics/court-baseline-phase1.tsv`.
An operator can commit `stop-after-phase0`, locally edit the working-tree file to
`proceed-to-phase2`, and condition (iii-a) accepts the edit while condition (i) confirms the
stale committed version exists. The working-tree divergence is exactly the state the `git show HEAD:`
pattern throughout the rest of the spec was chosen to prevent.

**Action:** Change the (iii-a) reader from working-tree to committed:
```bash
decision=$(git show HEAD:test/metrics/phase1-decision.txt | head -1 | tr -d '[:space:]')
```
One-line fix, consistent with (iv)'s `git show HEAD:test/court-history.tsv` and
(vii)'s `git show HEAD:test/metrics/court-baseline-phase1.tsv`.

---

### F2 — MEDIUM: Once-only anchor guard checks disk existence, not committed HEAD — deletion bypasses it

**Location:** Plan line 1366 (`cmd_freeze_court_anchor`, `[[ -f "$anchor" ]]`)

**What is actually true:** `[[ -f "$anchor" ]]` checks working-tree (disk) existence.
If a developer deletes `test/metrics/court-baseline-phase1.tsv` from the working tree after a
successful freeze and re-runs `make freeze-court-anchor`, the disk-based guard evaluates false
and the function proceeds: `cp "$roll" "$anchor"; git add "$anchor"; git commit -s`. This
silently overwrites the committed Phase-1-only anchor with potentially Phase-2-polluted data.
Condition (vii) uses `git show HEAD:` to check committed HEAD existence — so (vii) would still
pass (the original committed file is there), and neither check detects the re-freeze.

The plan calls this guard the "symmetric complement" of condition (vii), but they guard
different state spaces: `[[ -f ]]` is disk-state; `git show HEAD:` is HEAD-state. A plain `rm`
defeats the once-only guarantee.

**Action:** Replace `[[ -f "$anchor" ]] && { echo "ERROR: already exists..."; return 1; }` with:
```bash
git show HEAD:"$anchor" > /dev/null 2>&1 && { echo "ERROR: $anchor already committed — the freeze is once-only; never silently re-baseline"; return 1; }
```
Four-token fix; no design change. Disk presence becomes a secondary consistency arm, not the gate.

---

### F3 — MEDIUM: Condition (iv) equality assertion is prose-only — no code snippet

**Location:** Plan lines 1179-1184

**What is actually true:** Condition (iv) requires re-deriving the snapshot from the committed
log and asserting byte-for-byte equality against the committed `court-baseline.tsv`. This is the
load-bearing anti-fabrication backstop — it raises the forging bar from "edit two numbers" to
"forge the entire per-run log consistently." Every other condition has a concrete code snippet
or bash command: (iii-a) has the two-pass bash block; (iii-b) has `grep -q '^INCON'`; (vi) has
the result-file check; (vii) has `git show HEAD:`. Condition (iv) is prose only. An implementer
reading the code snippets and filling gaps between them would see (iii-a) ending at line 1157,
then prose, then condition (v). The equality assertion is easy to omit, collapsing the
anti-fabrication protection.

**Action:** Add a concrete code block for condition (iv):
```bash
fresh=$(cmd_court_metrics <(git show HEAD:test/court-history.tsv))
committed=$(git show HEAD:test/metrics/court-baseline.tsv)
[[ "$fresh" == "$committed" ]] || { echo "ERROR: re-derived snapshot differs from committed court-baseline.tsv"; return 1; }
```
The LC_ALL=C sort pin makes this comparison deterministic. Note: `$flat` computed in (iii-a) is
identical to `$fresh` here — either reuse the variable or note they can be shared.

---

### F4 — LOW: `git show HEAD:` exits 0 for a zero-byte committed anchor; condition (vii) passes for an empty anchor

**Location:** Plan lines 1219-1221

`git show HEAD:<path>` exits 0 for any committed file including a zero-byte one (it exits 128
for non-existent paths). A manually committed empty `court-baseline-phase1.tsv` bypasses
`cmd_freeze_court_anchor`'s `[[ -s "$roll" ]]` guard (which only fires when running through the
guarded target) and passes condition (vii). `check-phase1-baseline` exits 0; Phase 2 begins.
`cmd_court_regression`'s `[[ -s "$base" ]]` guard catches it — but only after Phase-2 courts
have appended rows, making a clean Phase-1-only re-freeze unrecoverable.

**Action:** Add a size check to condition (vii):
```bash
git show HEAD:test/metrics/court-baseline-phase1.tsv > /dev/null 2>&1 || { echo 'ERROR: anchor not committed'; return 1; }
[[ $(git show HEAD:test/metrics/court-baseline-phase1.tsv | wc -c) -gt 0 ]] || { echo 'ERROR: committed anchor is empty'; return 1; }
```

---

### F5 — LOW: Write command for `phase1-decision.txt` is prose-only

**Location:** Plan line 726-728

The reader is exact (`head -1 | tr -d '[:space:]'`); the writer is prose only ("record and
commit... line 1 = the bare decision token"). The reader is robust enough that most malformed
writes error via the `*` arm rather than silently wrong decisions — but the asymmetry (exact
reader, prose writer) is a maintainability gap.

**Action:** Add a write example to step 6:
```bash
printf '%s\nagg=%.3f worst=%.3f\n' proceed-to-phase2 "$agg" "$worst" > test/metrics/phase1-decision.txt
```

---

### F6 — LOW: Line 2 of `phase1-decision.txt` "never machine-read" constraint is convention-only

**Location:** Plan lines 1122-1124

The constraint that line 2 is informational and the rates must be re-derived from
`court-history.tsv` (not parsed from line 2) is stated in the plan but not enforced in code.
A future maintainer who "optimizes" condition (iii-a) to parse line 2 would silently undermine
the anti-fabrication backstop.

**Action:** Add a comment in the `cmd_check_phase1_baseline` code block adjacent to the line-2
skip: `# line 2 is informational provenance ONLY — do NOT parse it; re-derive rates from court-history.tsv (condition iv) is the anti-fabrication backstop`.

---

### F7 — LOW: `PLUGIN_DIR` in `cmd_court_regression_confirmed` undocumented as a harness global

**Location:** Plan lines 1550, 1553

`$PLUGIN_DIR` is used to construct the court cache path for clearing between matrix runs. It is
defined at `test-skill.sh:10` as a harness global. An implementer relocating the function or
reading the snippet standalone encounters an unbound-variable error under `set -u` with no
diagnostic.

**Action:** Add a comment before the `rm -rf` lines:
`# PLUGIN_DIR is the harness global defined at test-skill.sh:10; this function must live in test-skill.sh`.

---

## Pre-Implementation Checklist (Round 13)

**Phase 0 (P0a + P0b): READY_TO_IMPLEMENT immediately.**

**Before Phase 1 implementation (fix F1-F3 before handing to a developer):**

- [ ] **F1 (MEDIUM):** Change line 1150 from `head -1 test/metrics/phase1-decision.txt`
  to `git show HEAD:test/metrics/phase1-decision.txt | head -1` — committed-to-committed.

- [ ] **F2 (MEDIUM):** Change `[[ -f "$anchor" ]]` anchor guard in `cmd_freeze_court_anchor`
  to `git show HEAD:"$anchor" > /dev/null 2>&1` — HEAD-state guard defeats working-tree deletion.

- [ ] **F3 (MEDIUM):** Add concrete code block for condition (iv) equality assertion
  (`[[ "$fresh" == "$committed" ]]`) — the anti-fabrication backstop must not be prose-only.

**Bundle with the MEDIUM fixes (one-liners):**

- [ ] **F4 (LOW):** Add size check to condition (vii): commit + non-empty, not just commit.
- [ ] **F5 (LOW):** Add `printf` write example to step 6 for `phase1-decision.txt`.
- [ ] **F6 (LOW):** Add code comment naming the "never machine-read line 2" requirement in-place.
- [ ] **F7 (LOW):** Add scoping comment for `PLUGIN_DIR` before the `rm -rf` lines.
