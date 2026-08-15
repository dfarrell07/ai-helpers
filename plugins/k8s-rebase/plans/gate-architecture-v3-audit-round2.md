# Gate Architecture v3 — Audit Round 2

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `44ed43e2`
**Prior audit:** `gate-architecture-v3-audit.md` — all 7 prior findings addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — one HIGH live-correctness bug in the plan; five MEDIUM
implementation gaps; four LOW issues. Architecture remains sound; no rethink needed.

## Methodology

36-agent ultracode workflow: 9 independent auditors across all major plan dimensions,
adversarial challenge of all 25 HIGH/MEDIUM findings (default-to-refuted), then synthesis.
1.63M tokens, 389 tool calls. All agents read live code with tools; no finding accepted
without file:line verification.

**Dimensions audited:** Phase 1 court fix enforcement design · Phase 0 window fix
fallback-widening · Phase 1 court-history file persistence · Phase 2 atomicity and
ordering · Evidence transport completeness · Gate map correctness · Library API bash
correctness · Phase 0(e) timeout tiering · Overall design coherence · Implementation gaps

34 total findings. 25 HIGH/MEDIUM challenged. 10 survived. 9 LOW not challenged.

---

## Survived Findings — Ranked

### R1 — HIGH: `patterns-completeness.md:42` is a patterns-doc fallback, not a companion-script crash branch — widening it fixes the wrong clause

**Location:** Phase 0(b) window-hazard fix, line ~487

**Plan claims:** "`(ii) patterns-completeness.md:42` phrases it differently (`'If not found,
rely on steps 1-3 above'`) — widen that same clause."

**What is actually true:** Line 42 sits inside step 4 of PATH-B manual checks, which
reads: *"4. If a patterns doc exists, cross-reference: `find … -name 'k8s-rebase-patterns.md'` …
If found, read it … sibling gates. If not found, rely on steps 1-3 above."* The `'If not found'`
refers to `k8s-rebase-patterns.md` (the patterns documentation file), not to the companion
script `patterns-completeness.sh`. `patterns-completeness.md` has no companion-script crash
fallback anywhere — it is structurally identical to `crd-validation.md`, which the plan
correctly identifies as needing a **new crash branch added** rather than an existing clause
widened.

**Consequence:** After Phase 0(b) lands the `_gate_trap` rewrite, a crash of
`patterns-completeness.sh` routes the subagent to a `.md` that offers only PATH-A (requires
`NEW_ISSUES=0 AND BUILD-OK` from the script) and PATH-B (requires `BUILD-FAIL` or
`NEW_ISSUES > 0` from the script). Neither matches a crashed script — the subagent
improvises and likely produces a blind PASS on a broken tree. This is a live production gate
(step 3 of every rebase across 100+ repos) and the plan's claim that the crash-semantics
window is "bounded to a single PR" is **incorrect for this gate**.

**Required fix:** In Phase 0(b), change the `patterns-completeness.md` instruction from
"widen line 42" to "add a new crash branch," applying the same pattern already prescribed
for `crd-validation.md` (group iii): insert a PATH-C block that fires when the companion
script crashes or emits no `NEW_ISSUES` line, instructs the subagent to run all manual
checks, and never allows a blind PASS from an undetected crash.

---

### R2 — MEDIUM: P0a bullet list omits companion `.md` fallback-widening

**Location:** Phase 0 "Landing order within Phase 0" section — P0a bullet

**Plan claims:** Phase 0(b) narrative states the companion `.md` fallback-widening "must
co-land" with the `_gate_trap` rewrite to prevent crash→blind PASS. The (b) PR is P0a.

**What is actually true:** The P0a bullet lists five items: `_gate_trap` rewrite (b),
orchestrator rc-capture + `.crash` write (b), `build-vet` inner-tool capture (d), `cmd_init`
cleanup (c), and harness `.crash` reader (b). The six companion `.md` fallback-widenings are
absent from the checklist. The Risks table mentions co-landing in the mitigation column, but
the two warnings are separated across the document. An implementer following P0a as a todo
list ships the `_gate_trap` semantic change without the consumer fix.

**Consequence:** A crashed companion routes to a subagent whose fallback trigger fires only
on "script not found." RULE 1 needs `NEW_ISSUES=0`, RULE 2 needs a flagged-issues line —
neither fires on a crash. The subagent improvises, likely blind PASS.

**Required fix:** Add the companion `.md` fallback-widening as an explicit bullet in the
P0a checklist, after applying R1's correction to `patterns-completeness.md`. Enumerate all
six files and note which get widening (`build-vet.md`, `version-consistency.md`,
`major-version-imports.md`) versus a new crash branch (`crd-validation.md`,
`patterns-completeness.md`, `go-version-check.md`).

---

### R3 — MEDIUM: Phase 2 step 5 says "Add" orchestrator launch but doesn't say to remove the existing unconditional "launch all N gates" instruction

**Location:** Phase 2, numbered sub-step 5; also `step2-compilation.md:148-166` and
`step3-autofix.md:58-81`

**What is actually true:** `step2-compilation.md:148-166` says "launch all 6 in a single
message" and `step3-autofix.md:58-81` says "launch all 11 in a single message — Do not skip,
batch, or defer any gate." Neither of these unconditional launch instructions is mentioned for
removal anywhere in Phase 2. Additionally, the plan's citation stops at
`step4-verification.md:58` (the bash closing fence); the critical "Launch subagents only for
PENDING gates" restriction is at line 60 and is outside the cited range.

**Consequence:** If the orchestrator call is prepended without removing the unconditional
launch, subagents fire for every gate regardless of orchestrator PASS resolution — defeating
the fast-path purpose entirely and reintroducing HEAD-drift risk for already-resolved gates.

**Required fix:** Revise sub-step 5 to say: (a) add the orchestrator launch call, (b)
replace the unconditional "launch all N" instruction with "Launch subagents only for PENDING
gates" mirroring `step4-verification.md:60` (cite line 60, not 58), and (c) remove the "Do
not skip, batch, or defer any gate" text.

---

### R4 — MEDIUM: Step 1 has no companion scripts; the "last companion-conversion PR" rule provides no landing vehicle for `step1-rebase.md` wiring

**Location:** Phase 2 "Per-step wiring" section (sub-steps 5 and 6)

**What is actually true:** `ls gates/step1-rebase/*.sh` returns nothing — one gate
(`rebase-completeness.md`), zero companion scripts. No companion-conversion PR for step 1
can ever exist. Yet sub-step 6 explicitly lists `step1-rebase.md:96-99` as needing the
fix-loop update, and sub-step 5 implies adding an `orchestrator gates 1` call. The plan
provides a parenthetical exception for step 4 ("Step 4 already has the launch") but no
analogous exception or alternative landing vehicle for step 1.

**Consequence:** The two changes to `step1-rebase.md` are unscheduled — either orphaned
into an ad-hoc PR or silently skipped.

**Required fix:** Add an explicit parenthetical for step 1: since step 1 has no companion
scripts, the orchestrator launch and fix-loop update for `step1-rebase.md` land in a
standalone PR at the start of Phase 2 (before any step 2/3 companion-conversion PRs), or as
part of P0a if step `.md` files are already being touched. Name a concrete landing PR.

---

### R5 — MEDIUM: Court history-file path, gitignore status, and committed-metrics-file path are all unspecified

**Location:** Phase 1 metric section, lines ~691-698

**What is actually true:** The plan specifies the TSV row format for the append-only
court-history file but never names its path. `.matrix-state/.gitignore` contains `*\n!.gitignore`
— every file inside is unconditionally gitignored. Any history file placed alongside existing
court files inside `.matrix-state/court/` is silently gitignored, making "commit the baseline
snapshot from that history file" impossible without restructuring. The plan says "test/.matrix-state/
is gitignored, so these are provisional" but leaves both the history-file path and the
committed-metrics-file path undefined.

**Consequence:** Two implementers produce incompatible locations. If the history file is
gitignored (consistent with `.matrix-state/`), the "commit the baseline" requirement is
impossible. The go/no-go boundary (`false-FAIL rate ≤ 5%`) cannot be evaluated.

**Required fix:** Specify two concrete paths: (a) the append-only history file (e.g.,
`test/court-history.tsv`, outside `.matrix-state/`, or add a `.gitignore` negation), and (b)
the committed metrics file (e.g., `test/metrics/court-baseline.tsv`). Specify whether
`make results` or a new make target generates (b) from (a).

---

### R6 — MEDIUM: No tooling specified to join `court-history.tsv` with `results.tsv` or compute the false-FAIL rate

**Location:** Phase 1 metric section — the go/no-go boundary depends on this analyzer

**What is actually true:** The plan introduces `court-history.tsv` to fix the self-erasing
verdict problem, then immediately relies on it for the Phase 1 go/no-go boundary. It says
"that join is unbuildable against live code and is a required first sub-step (code, before
any measurement)." No function in `test-skill.sh` joins court-history with `results.tsv`,
computes a false-FAIL rate, or generates a committed snapshot. The data-availability half is
addressed by adding the history file; the analyzer half is left entirely implicit. The go/no-go
boundary (`false-FAIL rate ≤ 5% aggregate AND ≤ 10% per-repo, confirmed across ≥ 2 re-runs`)
is uncomputable without the analyzer.

**Required fix:** Add a numbered Phase 1 deliverable specifying the analyzer: a function or
`make` target that (a) joins `court-history.tsv` with `results.tsv` on `(version, repo)`, (b)
filters for rows where court said PASS but a blocking non-info gate FAILed, (c) computes
aggregate and per-repo false-FAIL rates, and (d) emits a summary table. Sketch the
implementation (20 lines of `awk` suffice) or reference a target by name.

---

### R7 — LOW: Conversion order for companions in steps 2 and 3 is undefined under out-of-order merges

**Location:** Phase 2 "Per-step wiring" sub-steps 5 and 6

Step 2 has two companions, step 3 has three. No conversion ordering is specified. If PRs
merge out of order, the per-step wiring can land before all sibling MANDATORY FIRST STEP
blocks are gone, causing double execution. For `build-vet` across 3 modules, ~30 extra
minutes of `go build`/`go vet` per fix-loop cycle. The adversary confirms HEAD-drift is not
worsened (the window is already open throughout Phase 2), but the waste is real.

**Fix:** Name a specific companion as "last" for each step (e.g., `version-consistency.sh`
for step 2, `patterns-completeness.sh` for step 3) and add a suggested pre-merge check
(`grep -l 'MANDATORY FIRST STEP' gates/stepN-*/` to confirm all blocks are removed).

---

### R8 — LOW: `GATE_OUTER_TIMEOUT` snippet uses "EXACTLY" but omits `build-vet.sh`'s gitignored-vendor skip

**Location:** Phase 0(e), lines ~588-603

`build-vet.sh:15-18` skips modules where `vendor/` is gitignored (`git check-ignore -q`).
The plan's snippet has no corresponding skip, so `GATE_OUTER_TIMEOUT` is computed from a
count ≥ the actual build-vet iteration count. Overcounting is in the safe direction (outer
timeout fires late, never prematurely), but the "EXACTLY" characterization is wrong and
misleads an implementer trying to tighten the bound.

**Fix:** Remove "EXACTLY" from the Phase 0(e) prose; add a parenthetical noting the snippet
is a conservative upper bound and documenting the gitignored-vendor skip that the precise
count would require.

---

### R9 — LOW: Phase 2 evidence-path consistency fix is in prose but has no numbered action step

**Location:** Execution model section, lines ~297-308; Phase 2 migration sequence

The plan identifies that three independent producers of the `<prefix>-<gate>` evidence path
must agree and says "Phase 2 must either route all three through one sourced helper
(`gate_artifact_prefix`) or add a test asserting the three agree." `gate_artifact_prefix`
does not exist in live code. Neither the helper nor the test appears in Phase 2's numbered
sub-step list. The "must" lives only in prose. The practical risk is low for the 4 existing
`stepN-singleword` dirs (both derivation methods agree), but the consistency check is not
a deliverable.

**Fix:** Add a brief numbered Phase 2 step that resolves the choice (recommend the test
approach: a `make lint` assertion that all three producers produce the same prefix for every
step dir) and names the test file location.

---

### R10 — LOW: Phase 1 `from_commit` threading does not specify the new `cmd_court` signature or the `_results_one` call-site update

**Location:** Phase 1, part (c)

`cmd_court`'s current signature is `result_branch known_good repo`. `cmd_court_all` calls it
at line 1364 and `_results_one` calls it at line 1577, both without `from_commit`. The plan
says to pass `from_commit` into `cmd_court` but specifies neither the new signature nor that
`_results_one:1577` also needs updating. An untouched `_results_one` degrades to the plan's
stated merge-base fallback (not ambient-HEAD failure), so the consequence is bounded.

**Fix:** Add a one-line spec for the new `cmd_court` signature and add `_results_one:1577` to
the list of call sites requiring update.

---

## Refuted Findings

| Finding | Refutation |
|---------|-----------|
| `--is-ancestor` guard on `known_good` causes false-INCONCLUSIVE | The guard checks the BASE_REF ancestor relationship, not known_good; the plan's wording is precise once traced |
| Tool-disabling mechanism for prosecution/defense/judge needs a claude CLI flag specified | Refuted: disabling Bash/Read from the allowed-tools list is the established mechanism; no new flag needed |
| Fallback-widening fix inapplicable to all 6 .md files (grouped finding absorbed by R1) | Partially refuted; the real issue is R1 (wrong clause in patterns-completeness.md), not a blanket inapplicability |
| Court fix: `from_commit` not resolvable in `cmd_court_all` config loop | Refuted: per-repo config loop at :1332-1364 already has from_commit via `_config_val` |
| `finish_info` shown in Library API but never added — implementer confusion | Refuted as HIGH: the plan explicitly says "finish_info is omitted entirely" — inconsistency is real but LOW consequence |
| `finish_filter`'s `$@` contains wrong args after `shift 2` | Refuted: shift 2 correctly leaves detail lines in `$@`; the function is correct |
| `(( expr )) && cmd` in Phase 0(e) snippet unsafe under set -e | Refuted as HIGH: bash &&-exemption is well-established; risk is LOW and codebase-consistent fix noted |
| `_write_evidence` `tee`-to-stdout transport dead in Phase 2 orchestrator path | Refuted as issue: design intent is that stdout transport serves Phase 0→2 migration overlap; by Phase 2 final state, file transport is primary |
| Concurrent appends to `court-history.tsv` risk corruption | Refuted: POSIX atomicity covers short 4-column rows; no corruption possible |
| Evidence-path three-producer risk acute in Phase 2 | Refuted: both derivation methods agree for all 4 existing `stepN-singleword` dirs; risk is theoretical for undefined future dirs |
| Phase 1: `from_commit` not in `cmd_court_all` config context | Refuted: already available via `_config_val` at the per-repo loop |
| Phase 2 evidence-path consistency fix blocks Phase 2 | Refuted: coincidental agreement of the three producers holds for all current step dirs |
| `CI exercises the new functions immediately` overstates — `make lint` doesn't run bash | Confirmed as LOW (not HIGH): make lint validates structure, not function semantics; implementer should not rely on CI for bash correctness validation |
| `*.evidence.tmp` accumulates and is never cleaned | Confirmed as LOW: disk clutter only; correctness unaffected (only `$ev` without `.tmp` is consumed) |
| Phase 0 and Execution model snippets "same restructure" but differ on `$output` capture | Confirmed as LOW: plan separately and explicitly says to keep `$output` for Phase 0; the "same restructure" claim is imprecise but the guard exists |

---

## Pre-Implementation Checklist (Round 2)

Before starting Phase 0 implementation:

- [ ] **R1 (MUST):** Correct Phase 0(b) `patterns-completeness.md` instruction from "widen
  line 42" to "add new crash branch (PATH-C)" — identical treatment as `crd-validation.md`.
- [ ] **R2 (MUST):** Add companion `.md` fallback-widening as an explicit bullet in the P0a
  checklist with all 6 files named and the widening-vs-new-branch distinction noted.

Before starting Phase 1 implementation:

- [ ] **R5 (MUST):** Specify concrete paths for the append-only court-history file (outside
  `.matrix-state/` or with `.gitignore` negation) and the committed metrics file.
- [ ] **R6 (MUST):** Add a numbered Phase 1 deliverable for the court-history/results.tsv
  join and false-FAIL rate computation (or reference a make target by name).

Before starting Phase 2 implementation:

- [ ] **R3 (MUST):** Revise sub-step 5 to explicitly remove the unconditional "launch all N"
  instruction and cite `step4-verification.md:60` (PENDING-only), not just `:56-58`.
- [ ] **R4 (MUST):** Add a parenthetical for step 1 (no companions) naming which PR carries
  the `step1-rebase.md` orchestrator launch and fix-loop update.

Lower-priority (can land with their respective phases):

- [ ] **R7:** Name the "last" companion per step; add pre-merge check suggestion.
- [ ] **R8:** Remove "EXACTLY" from Phase 0(e) prose; note the snippet is a conservative
  upper bound.
- [ ] **R9:** Add a numbered Phase 2 step for the evidence-path consistency test.
- [ ] **R10:** Specify new `cmd_court` signature and add `_results_one:1577` to call-site list.
