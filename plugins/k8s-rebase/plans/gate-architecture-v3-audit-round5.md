# Gate Architecture v3 — Audit Round 5

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `ae7a6dcd`
**Prior audits:** Rounds 1-4 (7+10+14+6 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — four HIGH design defects; four MEDIUM implementation gaps;
two LOW quality issues. All fixes are small (a grep guard, a `git show HEAD:` redirect,
a 3-step protocol, a P0a spec expansion) — no architectural rethink needed.

## Methodology

26-agent ultracode workflow: 8 dimension auditors, adversarial challenge of all 16
HIGH/MEDIUM findings (default-to-refuted), synthesis. 1.16M tokens, 237 tool calls.
15/16 survived adversarial challenge.

**Dimensions:** awk sort + check-phase1-baseline step iv rederivation · assert-court-permissions
implementability · Phase 2 step 4 two-shape deletion · court-history as committed log ·
major-version-imports clarification · Phase 1 new additions coherence · Phase 2 step 4 P0a
dependency sequencing · overall convergence

---

## Survived Findings

### R1 — HIGH: P0a never authors a from-scratch check body for crd-validation; Phase 2 step 4 promotes a body that does not exist

**Location:** Plan lines 517-519 (P0a group-(ii) spec); lines 1100-1106 (Phase 2 step 4);
`gates/step3-autofix/crd-validation.md:19-30`

**What is actually true:** P0a (Phase 0(b) group (ii), lines 517-519) instructs adding
exactly one trigger sentence to `crd-validation.md`: "if the companion script is not found,
crashes, or emits no `NEW_ISSUES` line, run the manual checks and judge from the diff."
It authors no self-contained from-scratch check procedure. The "manual checks" the sentence
points to are checks 1-2 (lines 19-30 of `crd-validation.md`), which are unconditionally
scoped by "For each CRD the script marked `CHANGED-VALIDATION` or `ALL-NEW`" — they require
script output that does not exist when the companion crashes. Phase 2 step 4 (lines 1100-1106)
instructs dropping RULE 2 (the script-marking selector) together with the FIRST STEP block,
while claiming to "promote the P0a from-scratch body." That body was never authored. After
step 4, the evidence template routes the subagent to "judge from scratch using the checks
below," but the checks below either do not exist (deleted with RULE 2) or still reference
script-marked CRDs. Confirmed: `grep` for "crash", "from scratch", "not found, crashes"
in the live `crd-validation.md` returns zero hits.

**Consequence:** A crashed companion on a repo with real CRD validation regressions produces
a silent false PASS. Bad rebase ships with no runtime or build-time signal.

**Action:** Fix P0a's group-(ii) spec to require authoring a self-contained from-scratch check
body for `crd-validation` that does not depend on script marking — e.g., "for each CRD in the
repository, read `git show $BASE:<path>` and compare against the working-copy version."
That body must be authored in P0a, not implied by Phase 2 step 4. Alternatively, fold the
from-scratch authoring explicitly into Phase 2 step 4 and state that it requires new prose, not
just a deletion.

---

### R2 — HIGH: `check-phase1-baseline` step (iv) reads the live working-copy `court-history.tsv`; permanently fails after any subsequent court run

**Location:** Plan line 888 (awk invocation); lines 912-925 (step iv spec)

**What is actually true:** Plan line 888 hardcodes the awk input as `test/court-history.tsv`
— the working-tree file, not `git show HEAD:test/court-history.tsv`. The awk takes the latest
row per `(version, repo, spec)` by timestamp. Every `make court` or `make matrix` invocation
appends new rows; new rows for existing keys displace prior rows as "latest," changing per-repo
counts and the `AGGREGATE` line. Every court run after the baseline is committed produces
re-derived output that differs from the committed `court-baseline.tsv`, and the equality
assertion in step (iv) fails permanently. Neither `cmd_court_metrics` nor
`cmd_check_phase1_baseline` exist yet — this is a spec defect. The plan's own Phase 1 requires
running courts multiple times (variance control), and the regression-gate prose (lines 968-971)
requires re-running courts after Phase 2 and Phase 3 — both guarantee the equality check
breaks before it is needed for later phases.

**Consequence:** The plan's primary Phase-1→Phase-2 enforcement mechanism exits non-zero
after any court run following the initial baseline commit. A gate that always spuriously fails
will be bypassed in practice, eliminating the plan's only mechanical enforcement of the
Phase-1 decision boundary.

**Action:** Fix the awk invocation in step (iv) to read the committed version:
`git show HEAD:test/court-history.tsv | awk '...' | LC_ALL=C sort`. This makes the
re-derivation reproducible regardless of subsequent court runs. Add a note that step (iv) is
a committed-snapshot anti-fabrication check, not a live-data consistency check.

---

### R3 — HIGH: No baseline-update workflow defined for Phase 2 and Phase 3 regression gates

**Location:** Plan lines 968-971 ("the regression gate for every later phase")

**What is actually true:** The plan (lines 968-971) calls `check-phase1-baseline` "the
regression gate for every later phase" and says to "re-run the matrix after Phase 2 and again
after Phase 3 against the committed metrics baseline." But no `make update-baseline` workflow,
no `check-phase2-baseline`, no re-commit instruction, and no statement of what "committed
baseline" means at each phase boundary are defined anywhere in the plan (confirmed: zero
occurrences of "update-baseline", "recommit", "check-phase2-baseline"). If the Phase-1
snapshot is the forever-baseline, step (iv) fails after Phase 2 because `court-history.tsv`
has grown (R2). If the baseline advances each phase, no workflow exists for doing so.

**Consequence:** Implementer cannot use `check-phase1-baseline` as a regression gate for
Phase 2 or Phase 3. The most likely outcome: the check is simply skipped, eliminating the
regression gate entirely — the opposite of the plan's stated goal.

**Action:** Define a concrete baseline-update protocol: specify a `make commit-court-baseline`
(or equivalent) target that commits the updated `court-history.tsv` and re-derived
`court-baseline.tsv`, when to run it at each phase boundary, and that `check-phase1-baseline`
step (iv) always reads `git show HEAD:test/court-history.tsv` (from R2's fix), making the
check committed-to-committed rather than live-to-committed.

---

### R4 — HIGH: `check-phase1-baseline` does not verify P0a's crash branches landed; Phase 2 step 4 can proceed with no check body

**Location:** Plan line 664 (sole P0a constraint); lines 910-942 (`check-phase1-baseline` spec)

**What is actually true:** The sole pre-Phase-2 P0a constraint (line 664) covers only the
`_gate_trap` rewrite in prose. The `check-phase1-baseline` spec defines four exit conditions:
(i) `court-history.tsv` and `court-baseline.tsv` exist and are committed; (ii)
`phase1-decision.txt` records the chosen branch; (iii) the decision is consistent with the
5%/10% rule; (iv) the snapshot re-derives from the raw log. None of the four checks whether
P0a's crash branches were added to `crd-validation.md` or `patterns-completeness.md`. A
developer who passes `check-phase1-baseline` without P0a finds no mechanical block, then
proceeds to Phase 2 step 4, which deletes FIRST STEP block + RULE 1 + RULE 2 from
`crd-validation.md` and leaves the gate with only an evidence template and no check body —
a false-PASS hole with no runtime signal. Adversary confirmed: `check-phase1-baseline`'s four
checks cannot detect absent crash branches.

**Consequence:** Phase 2 step 4 proceeds without P0a. `crd-validation.md` is left with just
the evidence template; "judge from scratch using the checks below" points to nothing. Silent
false PASS on any repo with CRD validation regressions.

**Action:** Add a fifth check to `check-phase1-baseline`:
```bash
grep -qr 'not found, crashes, or emits no' \
  gates/step3-autofix/crd-validation.md \
  gates/step3-autofix/patterns-completeness.md \
  || { echo 'ERROR: P0a crash branches not present — run P0a before Phase 2'; exit 1; }
```
This is a cheap grep that closes the mechanical gap.

---

### R5 — MEDIUM: After Phase 2 step 4, `crd-validation` checks 1-2 reference "each CRD" with no antecedent

**Location:** Plan lines 1102-1103; `crd-validation.md:19`

RULE 2 and its lead-in "For each CRD the script marked `CHANGED-VALIDATION` or `ALL-NEW`:"
(line 19 of `crd-validation.md`) are the only text that defines which CRDs checks 1-2 examine.
Phase 2 step 4 drops RULE 2 together with the FIRST STEP block. After dropping, checks 1-2
begin "Compare each CRD to the base branch version" with "each CRD" having no antecedent. The
plan's parenthetical "without any script marking" implies "all CRDs" but does not state it.
Implementers will write different scope statements; subagents will interpret scope differently;
this gate produces inconsistent verdicts.

**Action:** State explicitly in Phase 2 step 4 that removing RULE 2 requires authoring a
replacement scope statement such as "For each CRD schema file in the repository:" before checks
1-2. This is 5-10 words of new prose but must be specified, not left to implementer inference.

---

### R6 — MEDIUM: `assert-court-permissions.sh` spec leaves three gaps that allow vacuous PASS

**Location:** Plan lines 716-732

Three gaps remain after the plan's round-4 spec expansion:
1. **No inducing prompt specified.** A model that declines the denied op in plain text
   ("I cannot run git commands") without calling Bash leaves the scratch repo unmutated and the
   JSON empty. Both proposed checks (JSON + unmutated-repo) produce PASS regardless of whether
   permissions are enforced.
2. **No model-unavailability detection specified.** A session that aborts before any tool call
   (auth failure, network timeout, no Vertex creds) also leaves the repo unmutated, producing
   PASS instead of INCONCLUSIVE. The plan says INCONCLUSIVE means "re-run required, never PASS"
   but does not specify which exit codes or stderr patterns distinguish abort from completion.
3. **INCONCLUSIVE does not explicitly block baseline measurement.** `check-phase1-baseline`'s
   four exit conditions do not verify that `assert-court-permissions.sh` returned PASS before
   courts were run. A measurement taken before the assertion PASSed sails through
   `check-phase1-baseline`.

`test/assert-court-permissions.sh` does not exist. Adversary confirmed all three gaps.

**Action:** Specify: (a) the inducing prompt — a `git checkout -b <unique-name>` probe where a
denied call leaves no new branch (unambiguous); (b) that the script detects session abort by
requiring a two-part assertion (tool attempted AND tool denied in JSON output — not an
unmutated-repo fallback, which has the same exit-code ambiguity the plan already rejected for
plain exit codes); (c) add a fifth `check-phase1-baseline` check: read a committed
`test/metrics/assert-court-permissions-result.txt` and reject any value other than `PASS`.

---

### R7 — MEDIUM: Phase 1 implementation sequence is never written as an ordered list

**Location:** Plan lines 668-966 (entire Phase 1 section)

The required Phase 1 implementation sequence — (1) implement court fix a/b/c/d, (2)
`assert-court-permissions.sh` PASS, (3) drop `cmd_court_all:1340` PASS-only filter, (4) run
courts, (5) commit `court-history.tsv` + run `court-metrics`, (6) commit `court-baseline.tsv`
+ `phase1-decision.txt`, (7) run `check-phase1-baseline` — is never written as a numbered
list. The critical "step 3 before step 4" and "step 2 before step 4" constraints appear as
subordinate clauses in the middle of prose subsections. `check-phase1-baseline` is a
mathematical consistency check — it passes even if courts ran before the `:1340` filter was
dropped (producing a structural 0% history). Contrast Phase 0, which has an explicit "Landing
order within Phase 0" paragraph.

**Action:** Add a "Required implementation sequence for Phase 1" ordered list (7 steps) at the
top of the Phase 1 section, mirroring the "Landing order within Phase 0" structure. Mark step
3 explicitly as "must precede step 4" and step 2 as "must precede step 4." Documentation fix,
not a redesign.

---

### R8 — MEDIUM: Phase 3 never requires running `assert-evidence-paths.sh` or bumping N for companion-less gate conversion PRs

**Location:** Plan lines 1196-1228 (Phase 3 section); lines 1146-1175 (Phase 2 step 7)

Phase 2 step 7 establishes `assert-evidence-paths.sh` with an exact-count `== N` assertion and
labels itself "One-time (not per-gate)." Phase 3 (lines 1196-1228) describes per-gate
requirements (.sh script, .md template block, step wiring) but never mentions bumping N or
running the assertion. Line 1170 says "bump N on companion-less additions too" inside Phase 2
step 7's prose; Phase 3 never cross-references it. No CI job runs the harness. A Phase 3
developer who adds the verbatim EVIDENCE template but forgets to bump N produces a vacuously
passing assertion if no one runs the target — and the plan never requires running it per Phase
3 PR.

**Action:** Add an explicit checklist item to the Phase 3 section: "After each companion-less
gate conversion PR, bump N in `assert-evidence-paths.sh` and verify `make assert-evidence-paths`
passes." One-line addition that closes the N-drift gap.

---

### R9 — LOW: `assert-court-permissions.sh` unmutated-repo fallback has the same exit-code ambiguity the plan already rejected

**Location:** Plan lines 724-726

The plan proposes two checks: (1) JSON — assert the tool was never executed; (2)
unmutated-repo — check no new branch was created. It states "either cleanly separates
'denied, no effect' from 'executed but failed.'" The unmutated-repo check does NOT cleanly
separate: `git checkout <nonexistent-ref>` executes (permission not blocked), hits a
non-permission error, and leaves the repo unmutated — identical to the denied case. The plan
correctly rejected exit-code checks for this exact reason but proposes the unmutated-repo
alternative with the same failure mode. JSON is the sound primary check.

**Action:** Demote the unmutated-repo check to secondary/sanity status. Specify that the
primary assertion is the JSON two-part check (tool-call attempted + tool-call denied). Design
the probe as `git checkout -b <unique-name>` so the mutation criterion is unambiguous.

---

### R10 — LOW: Concurrent court subshells append to `court-history.tsv` without synchronization specification

**Location:** Plan lines 822-836; `test/test-skill.sh:1362` (background subshells)

`cmd_court_all` launches court runs as background subshells (`) &`). Multiple concurrent
subshells will `>>` append to `court-history.tsv` with no `flock` or serialization. Linux VFS
provides de-facto O_APPEND atomicity for single-syscall writes under 4096 bytes on local
filesystems, making actual row interleaving near-zero in practice — but the plan makes no such
claim and a conforming implementation on NFS or with long detail strings could corrupt rows.

**Action:** Add a note to the `_append_court_history` spec: each row must be a single atomic
`printf '%s\t...\n' ... >> file` call (one write syscall, under 512 bytes) to stay within
Linux VFS O_APPEND atomicity for local filesystems. Use `flock` if rows ever exceed that bound.

---

## Refuted / Downgraded Findings

| Finding | Disposition |
|---------|-------------|
| step (iv) permanently fails after any post-baseline court run (HIGH) | Downgraded to MEDIUM (R2): the ≥2 re-runs happen BEFORE committing the baseline; the immediate check passes; real failure is later-phase regression checks |
| Unmutated-repo check has identical exit-code ambiguity as rejected approach | Downgraded to LOW (R9): JSON is the primary/preferred path; unmutated-repo with branch-creation probe is actually unambiguous; plan's "either" framing is imprecise prose, not a fatal design flaw |
| `--output-format json` doesn't expose machine-readable tool-denial records | Refuted: Claude CLI's `--output-format json` does include structured tool-use fields; the plan's JSON approach is viable |
| major-version-imports.md:42-47 base-filter citation inaccurate | Refuted (confirmed CORRECT): lines 42-47 exactly match the plan's description; :22 is correctly called a flag-everything rule |
| Phase 3 companion-less gate wiring for rebase-completeness missing | Not raised: R6 from round 3 was correctly addressed and not re-raised |
| N counting caps at 6 companions; Phase 3 additions break == N | Partially addressed by R8: the plan says to count all .md files carrying the marker including Phase 3 additions, but enforcement is absent per R8 |

---

## Pre-Implementation Checklist (Round 5)

**Must fix before P0a PR opens:**

- [ ] **R1 (MUST):** Expand P0a group-(ii) spec to require authoring a self-contained
  from-scratch CRD check body in `crd-validation.md` that does not depend on script marking.
  Alternatively, state explicitly in Phase 2 step 4 that new scope prose must be authored.

**Must fix before Phase 1 implementation:**

- [ ] **R2 (MUST):** Change step (iv) awk input from `test/court-history.tsv` to
  `git show HEAD:test/court-history.tsv | awk '...' | LC_ALL=C sort`.
- [ ] **R3 (MUST):** Define a `make commit-court-baseline` workflow and state when to run
  it at each phase boundary. Clarify step (iv) always compares committed-to-committed.
- [ ] **R4 (MUST):** Add a fifth check to `check-phase1-baseline` that greps for P0a's crash
  branch trigger text in `crd-validation.md` and `patterns-completeness.md`.
- [ ] **R6 (MUST):** Specify (a) inducing prompt (`git checkout -b` probe), (b) JSON two-part
  assertion (tool attempted + denied), (c) committed `assert-court-permissions-result.txt` as
  the sixth `check-phase1-baseline` condition.
- [ ] **R7 (SHOULD):** Add "Required implementation sequence for Phase 1" numbered list at the
  top of the Phase 1 section.

**Before Phase 2 implementation:**

- [ ] **R5 (MUST):** State in Phase 2 step 4 that removing RULE 2 from `crd-validation.md`
  requires authoring a replacement scope statement before checks 1-2.

**Before Phase 3 implementation:**

- [ ] **R8 (MUST):** Add a Phase 3 checklist item: bump N in `assert-evidence-paths.sh`
  and run `make assert-evidence-paths` for each companion-less gate conversion PR.

**Lower priority (bundle with Phase 0/1 PRs):**

- [ ] **R9:** Demote unmutated-repo check; clarify JSON + branch-creation probe is primary.
- [ ] **R10:** Add atomicity note to `_append_court_history` spec.
