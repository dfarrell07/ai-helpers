# Gate Architecture v3 — Audit Round 3

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `1a2758f7`
**Prior audits:** Round 1 (7 findings), Round 2 (10 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — one HIGH blocker for Phase 1 measurement; nine MEDIUM
implementation gaps; four LOW quality issues. Phase 0 is unaffected and can proceed immediately.

## Methodology

32-agent ultracode workflow: 9 dimension auditors, adversarial challenge of all 22 HIGH/MEDIUM
findings (default-to-refuted), then synthesis. 1.43M tokens, 334 tool calls. All agents read
live code with tools. 14 of 22 survived adversarial challenge.

**Dimensions:** Phase 0(b) crash-safe fallback · Phase 1 court-history + make court-metrics ·
Phase 1 court enforcement (bypassPermissions, from_commit, is-ancestor) · Phase 2 steps 5a/5b/7 ·
Phase 3 rebase-completeness wiring vs step-1 exclusion · Live code claim verification ·
Court-history write timing · Implementation precision · Overall coherence

---

## Survived Findings

### R1 — HIGH: `cmd_court_all` hard-filters gate-FAIL results — false-FAIL metric structurally 0% via automated path

**Location:** `test/test-skill.sh:1337-1340` (`cmd_court_all`), line 1374 (history-append site)

**What is actually true:** `cmd_court_all:1340` contains `[[ "$verdict" != "PASS" ]] && continue`
which skips every gate-FAIL repo before reaching the court invocation at line 1364 and the
history-append at line 1374. Only gate-PASS repos are ever courted and appended to
`court-history.tsv`. The false-FAIL definition requires rows where `court=PASS but a blocking
gate FAILed` — exactly the rows the filter structurally cannot produce. Running `make court-all`
will always report 0% false-FAIL, which is not a meaningful signal. The Phase 1 go/no-go
boundary (≤5%/≤10%) is uncomputable via the automated path without a manual per-repo court
loop over FAIL results that the plan does not specify. Adversary **confirmed from live code**.

**Action:** Fix before Phase 1 measurement begins. Either: (a) add a second loop in
`cmd_court_all` (or a new make target) that courts gate-FAIL repos — these are exactly the
rows needed for the false-FAIL numerator — or (b) explicitly document that false-FAIL
measurement requires running `make results repo=X --court` for each gate-FAIL repo and add
that as a required Phase 1 sub-step with the exact invocation. Option (b) must name the
explicit invocation so the developer produces the correct `court-history.tsv` population.

---

### R2 — MEDIUM: Join on `(version, repo)` ignores spec column — court verdict from spec=all PASS contaminates spec=none FAIL row

**Location:** `test/test-skill.sh:1013` (`results.tsv` schema, col-3 = spec), line 1337

**What is actually true:** `results.tsv` has six columns: ts, version, spec, short, verdict,
detail. A single `(version, repo)` pair has multiple rows — one per spec run. The proposed
`court-history.tsv` has no spec column. `cmd_court_all:1337` picks the latest row across both
spec=all and spec=none, so a spec=all PASS run triggers court, recording `(version, repo, PASS)`
with no spec. The spec-blind awk join pairs that PASS verdict with a spec=none FAIL row from a
different run, manufacturing a spurious false-FAIL entry. The baseline (spec=all 71% vs spec=none
51%) shows cross-spec contamination is common. Adversary **confirmed from live code**.

**Action:** Add a spec column to the `court-history.tsv` schema:
`${version}\t${repo}\t${spec}\t${verdict}\t${ts}`. Update `cmd_court_all` to capture the spec
of the row it selected and record it. Update the awk join key from `(version, repo)` to
`(version, repo, spec)` so spec=all verdicts never pair with spec=none results rows. Resolve
together with R3.

---

### R3 — MEDIUM: `"Latest row per key by ts"` join is underspecified — no spec-handling rule; two developers produce different awk scripts

**Location:** Phase 1 metrics sub-step (`make court-metrics` description)

**What is actually true:** `results.tsv` has three meaningful dimensions: `(version, spec, repo)`.
The plan specifies the join key as `(version, repo)`, collapsing spec. "Latest row by ts" from
`results.tsv` on this collapsed key non-deterministically picks whichever spec ran most recently.
The plan tracks per-spec numbers (71% vs 51%) but the join description omits spec entirely. Two
developers implementing `make court-metrics` from the plan would produce different awk scripts that
disagree on repos with mixed spec run histories. Adversary **confirmed as plausible from live code**.

**Action:** Once spec is added to `court-history.tsv` and the join key is `(version, repo, spec)`,
the "latest row per key" is well-defined. Document whether `make court-metrics` filters to spec=all
only (for the go/no-go measurement) or computes per-spec rates. Add a concrete awk example
including the spec column handling.

---

### R4 — MEDIUM: `--is-ancestor base_ref known_good` fires false-INCONCLUSIVE on valid runs with divergent base lineage

**Location:** Phase 1(c), `test/test-skill.sh:1364`

**What is actually true:** The plan proposes `git merge-base --is-ancestor "$base_ref"
"$known_good"` as a guard. When `from_commit` (the AI's starting commit) post-dates the commit
from which the human built `known_good`, `from_commit` is NOT an ancestor of `known_good` and
the check fires INCONCLUSIVE on a valid rebase. The plan warns "do not gate on merge-base ==
from_commit equality — human and AI legitimately rebase from different bases," then proposes an
ancestor-on-known_good check that collapses for the same asymmetric divergence cases. The
`cmd_court` function at line 1233 does not yet have the guard (it still uses merge-base
unconditionally) — the guard is plan-only. Adversary confirmed the scenario is real; noted that
INCONCLUSIVE may be a correct configuration diagnostic in the asymmetric case, but coverage
erodes on repos where divergence is most likely.

**Action:** Specify a graceful degradation path when the is-ancestor check fails: fall back to
`merge-base(known_good, result)` rather than INCONCLUSIVE, emit a diagnostic warning that
`from_commit` is not an ancestor of `known_good`, and document that the go/no-go metric
excludes INCONCLUSIVE from the denominator. Or define INCONCLUSIVE as a hard-stop requiring
operator attention. Either way, specify the behavior — currently the plan states the check
without a fallback.

---

### R5 — MEDIUM: `bypassPermissions` overrides `--allowedTools`; "drop bypass" for jurors is underspecified — inert implementation possible

**Location:** `test/test-skill.sh:17` (global `PERMISSION_MODE`), lines 1188-1231 (four court roles)

**What is actually true:** `PERMISSION_MODE=bypassPermissions` at line 17 is global. All four
court roles (prosecution:1188, defense:1194, judge:1209, jurors:1229) pass
`--permission-mode "$PERMISSION_MODE"`. Jurors additionally pass `--allowedTools` at line 1230
but this is a confirmed no-op because `bypassPermissions` skips all permission checks. The plan
says "drop bypass for them so the read-only list actually binds" but never specifies what to
substitute: `--permission-mode default`, omit the flag, or a local variable override.
`PERMISSION_MODE` is global so scoping the change to jurors only requires diverging from it. A
developer who only removes `--allowedTools` or substitutes a still-bypassing mode ships a no-op
fix — jurors retain full shell access and can still manufacture phantom file-reads from ambient
HEAD. Adversary **confirmed from live code**.

**Action:** Add an explicit implementation instruction: juror invocations at line 1229 must pass
`--permission-mode default` (or omit `--permission-mode` entirely) instead of inheriting the
global `bypassPermissions`. Prosecution/defense/judge need tools disabled entirely — specify
`--allowedTools ''` or equivalent no-tool mode. Name the exact flag substitution; do not leave
"drop bypass" as prose.

---

### R6 — MEDIUM: Phase 3 step-1/rebase-completeness wiring items never specified — companion silently bypassed

**Location:** Phase 2 step-1 exclusion (lines 908-915) and Phase 3 (`rebase-completeness` entry)

**What is actually true:** Phase 2 explicitly excludes step 1 from per-step wiring items 5a/5b/6.
Phase 3 says each companion-less gate needs "registration in the step-1-3 spawn + fix-loop wiring
(Phase 2)" — but the `(Phase 2)` parenthetical reads as already-done rather than as a call to
apply the same pattern for step 1. Phase 3's `rebase-completeness` entry specifies only content
("its five existing counts") with zero wiring items: no prepend of `orchestrator gates 1` to
`step1-rebase.md`, no PENDING-filter update, no fix-loop re-invoke. `step1-rebase.md` has no
`orchestrator gates 1` call today. A developer adding `rebase-completeness.sh` in Phase 3 could
plausibly omit `step1-rebase.md` entirely — the companion is permanently bypassed with no error
signal. Adversary **confirmed from live code**.

**Action:** Add explicit Phase 3 wiring items for step 1 analogous to Phase 2 items 5a/5b/6
for steps 2-3: (5a) prepend `orchestrator gates 1` to `step1-rebase.md`, (5b) replace the
unconditional gate-launch instruction with "Launch subagents only for PENDING gates," (6) update
`step1-rebase.md`'s fix loop to re-invoke `orchestrator gates 1` before re-launching. Land in the
same PR as `rebase-completeness.sh` authoring so no interval opens where the companion exists but
the orchestrator never runs it.

---

### R7 — MEDIUM: `EVIDENCE_MISSING` breadcrumb has no filename, location, format, writer, or reader specification

**Location:** Lines 306-308 and 938; Phase-0 harness reader spec at lines 549-553

**What is actually true:** `EVIDENCE_MISSING` appears twice in the plan and zero times across all
scripts, gates, and skills. The plan says "the gate drops an EVIDENCE_MISSING breadcrumb (surfaced
by the Phase-0 harness reader)" but specifies no canonical path, content, writer, or reader. The
Phase-0 harness reader is scoped to `*.crash` scanning only — no phase adds an
`EVIDENCE_MISSING` reader. After Phase 2, subagents that find a missing evidence path write
breadcrumbs with no harness reader to surface them. Adversary **confirmed from live code (grep
returns zero hits)**.

**Action:** Either fully specify `EVIDENCE_MISSING` as a deliverable in Phase 2 — canonical path
(e.g., `$REPO/.rebase-tmp/gates/${GATE_NAME}.evidence_missing`), one-line content, written by
the gate subagent on path miss, read by a Phase-2 harness reader extension — OR remove all
references and document that the Phase-2 step-7 lint assertion (build-time detection) is the
only prefix-drift protection. Leaving `EVIDENCE_MISSING` as a concept with no implementation
spec means it is either never built or built inconsistently.

---

### R8 — MEDIUM: Phase 2 step 2 evidence-file instruction has no verbatim template — 6+ gate files authored independently

**Location:** Phase 2 step 2; Execution Model section (~lines 283-294)

**What is actually true:** The read-your-evidence-file instruction exists only as italicized prose
in the Execution Model section. Phase 2 step 2 says "Add the .md's read-your-evidence-file
instruction" with no fenced markdown template. Phase 3 repeats the requirement for companion-less
gates, so the implementation count exceeds 6. No existing gate carries this instruction to inherit
from. Freshness-check phrasing, the EVIDENCE_MISSING fallback, and the HEAD-comparison format
will diverge across files. Phase 2 step 7's lint assertion checks only that the evidence path
string agrees across three producers — not whether the HEAD comparison or fallback are present.
Adversary **confirmed as plausible**.

**Action:** Add a fenced markdown block to the plan containing the exact text to paste into each
gate `.md` — including the `HEAD:` line comparison expression, the "treat as ground truth"
phrasing, the stale-evidence fallback clause, and the EVIDENCE_MISSING breadcrumb behavior.
This template is the single authoritative source. The step-7 lint assertion should additionally
check for a key phrase from the template (e.g., the word `EVIDENCE_MISSING`) to detect files
where the block was accidentally omitted.

---

### R9 — MEDIUM: `EVIDENCE_MISSING` breadcrumb falsely attributed to Phase-0 harness reader

**Location:** Lines 305-308 of the Execution Model section

**What is actually true:** Lines 305-308 say "the gate drops an EVIDENCE_MISSING breadcrumb
(surfaced by the Phase-0 harness reader)." Phase-0's harness reader (lines 619-626) adds only
a parallel `*.crash` scan. `EVIDENCE_MISSING` is a Phase-2+ concept — nothing writes it until
Phase 2 ships. No phase adds an `EVIDENCE_MISSING` reader to the harness. After Phase 2 ships,
breadcrumbs written by subagents on path miss are never read by the harness; the "shows up as a
diagnostic" claim at line 308 is false. Adversary **confirmed from live code**. (Related to R7
— both address the same unspecified artifact; R7 targets the missing spec, R9 targets the
incorrect attribution.)

**Action:** Correct lines 305-308: remove "surfaced by the Phase-0 harness reader." Replace with
"(detectable only via the Phase-2 step-7 lint assertion, which fires at build time rather than
at runtime)" — or, if an EVIDENCE_MISSING runtime reader is added per R7, update the
parenthetical to name the correct phase.

---

### R10 — MEDIUM: Phase 1 sequence enforcement is text-only — court fix and measurement can be decoupled or skipped

**Location:** Lines 774-775 ("Only if Phase 1 binds")

**What is actually true:** The only Phase 2 gate is prose. No harness check, make target, or
committed artifact blocks Phase 2 work if Phase 1 artifacts are absent. `test/metrics/` does not
exist; `court-baseline.tsv` has never been created; `cmd_court_metrics` is unimplemented. An
implementer can skip Phase 1 measurement and proceed to Phase 2 by skipping the court fix —
measuring with the broken court yields an artificially corrupted baseline that could permit
proceeding even when Phase 1 should stop. Adversary **confirmed from live code (grep returns
zero hits for `court-baseline`, `cmd_court_metrics`)**.

**Action:** Add a concrete Phase 1 completion check: a `make check-phase1-baseline` target that
fails with a descriptive error if `test/metrics/court-baseline.tsv` is absent or
`cmd_court_metrics` is not implemented. Document this as a required gate before any Phase 2 PR
is opened. This converts text-only enforcement into a red-build gate.

---

### R11 — LOW: Phase 0(b) crash-safe fallback text becomes misleading after Phase 2 — no update step in the plan

**Location:** Phase 2 steps 3-4 vs. `build-vet.md:17`, `version-consistency.md:17`,
`major-version-imports.md:16`, `go-version-check.md:16`

Phase 0(b) widens the fallback trigger in 4 companion `.md` files to "if companion not found,
crashes, or emits no NEW_ISSUES line." Phase 2 removes the MANDATORY FIRST STEP block (companion
never runs inside the subagent), making that condition vacuously true on every invocation. Phase 2
step 2 adds "treat as ground truth" language that takes priority when evidence is present, so the
paths converge on correct behavior — adversary downgraded from HIGH to LOW. The residual is
misleading text that confuses future developers.

**Action:** Add a Phase 2 step to update the crash-safe fallback trigger in each companion `.md`
from "if companion not found, crashes, or emits no NEW_ISSUES line" to "if the evidence file is
missing or HEAD-stamp does not match." Bundle with that file's Phase 2 atomic conversion PR.

---

### R12 — LOW: `from_commit` not a ready variable in `cmd_court_all` — silent empty-string fallback possible

**Location:** `test/test-skill.sh:1364`, Phase 1(c)

No local variable named `from_commit` exists in the `cmd_court_all` loop. A developer who writes
`cmd_court "$branch" "$kg" "$repo" "$from_commit"` without first calling `_config_val` silently
passes empty string, degrading to the merge-base fallback. Consequence is bounded (merge-base is
checkout-independent, not ambient-HEAD). The `_config_val` extraction pattern appears at lines 830
and 882 as a discoverable template. Adversary confirmed; downgraded from MEDIUM to LOW.

**Action:** Add one line to the Phase 1(c) implementation note:
`local _fc=$(_config_val "$(repo_short "$repo")" "from_commit")` must be added inside the
`cmd_court_all` loop before the `cmd_court` call, passing `"$_fc"` as the trailing arg.

---

### R13 — LOW: Phase 2 step 7 linter assertion passes vacuously with zero evidence paths before any gate is converted

**Location:** Phase 2 step 7 (`test/assert-evidence-paths.sh`)

The assertion checks "every `.md`'s named evidence path." At landing time, zero `.md` files have
a named evidence path, so zero paths are checked and the assertion always passes. After partial
conversions, only converted files are checked. The plan's atomicity constraint (steps 1-4 in one
edit) partially mitigates this, but the lint adds no independent protection for omitted `.md`
updates. Adversary confirmed; consequence is overstated because an undefined `drop` command
fires loud failure before any PASS verdict is written.

**Action:** Add a minimum-count assertion to `test/assert-evidence-paths.sh`: after all Phase 2
conversions land, the script must find evidence paths in at least N `.md` files (where N = total
companions converted). Document the expected count in a comment so it is updated when Phase 3
adds more evidence gates.

---

### R14 — LOW: "drop .crash" is unexpanded pseudocode in the Phase 0(d) code block

**Location:** Phase 0(d) snippet (~line 567)

`(( build_rc >= 124 )) && { drop .crash; trap - EXIT; exit 0; }` — "drop .crash" is not bash.
An undefined `drop` command fails with exit 127 under `set -e`, which fires `_gate_trap`, which
writes the `.crash` breadcrumb correctly anyway — so the failure mode is loud and self-correcting,
not a silent false-PASS. The canonical path is documented in Phase 0(b). Adversary confirmed;
consequence overstated.

**Action:** Replace "drop .crash" with the canonical expansion:
`mkdir -p "$REPO/.rebase-tmp/gates" && printf 'CRASH: exit %s (inner-tool kill)\n' "$build_rc" > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"`.

---

## Refuted / Downgraded Findings

| Finding | Disposition |
|---------|-------------|
| Crash-safe fallback always fires after Phase 2, negating transport (HIGH) | Downgraded to LOW (R11): Phase 2 step 2's "treat as ground truth" takes priority when evidence present; both paths route correctly |
| Prosecution/defense/judge need tools to reason | Refuted: verified they only cite the provided diff — tool-disable costs them nothing |
| `from_commit` ambiguity creates ambient-HEAD risk (MEDIUM) | Downgraded to LOW (R12): merge-base fallback is checkout-independent; template discoverable at lines 830/882 |
| "drop .crash" causes silent false-PASS | Downgraded to LOW (R14): undefined command fires `set -e` → trap → correct breadcrumb written |
| Phase 2 step 7 vacuous pass proves write-only transport | Downgraded to LOW (R13): atomicity constraint prevents companion-without-.md scenario; lint is drift-detection, not instruction-presence check |
| crd-validation.md has "identical" RULE-1 block | Confirmed as LOW: crd-validation:11 says "Do NOT run checks 1-2 below" not "Do NOT run the checks below" — plan's "identical" claim is inaccurate, but removal intent is clear |
| No gitignore negation needed for `test/court-history.tsv` | Refuted: `test/.matrix-state/.gitignore` ignores only `.matrix-state/` contents; `test/` itself has no `.gitignore`; file would be tracked without extra work |
| Phase 2 step 7 linter is not automated CI | Confirmed LOW: `make lint` is manual; plan should note what "CI exercises" means |
| finish_info shown in lib API but never added | Confirmed LOW: plan explicitly says "never added" at lines 509-510 — discrepancy is acknowledged, just not marked in the snippet |
| All live-code claim verifications (claims 1-7) | Claims 2, 3, 4, 6, 7 confirmed accurate. Claim 1 ("discards exit code") is mechanically wrong (the `if` evaluates it, not discards it) — LOW finding noted |

---

## Pre-Implementation Checklist (Round 3)

**Before starting Phase 1 measurement:**

- [ ] **R1 (MUST):** Fix `cmd_court_all:1340` to also court gate-FAIL repos, OR document the
  manual `make results repo=X --court` loop as a required Phase 1 sub-step.
- [ ] **R2 (MUST):** Add spec column to `court-history.tsv` schema; update join key to
  `(version, repo, spec)`.
- [ ] **R3 (MUST, resolves with R2):** Document spec-handling rule in awk join; add a concrete
  awk example showing spec column handling.
- [ ] **R4 (MUST):** Specify graceful degradation for the is-ancestor guard (fallback vs.
  INCONCLUSIVE behavior and denominator handling).
- [ ] **R5 (MUST):** Specify exact flag substitution for juror bypassPermissions removal
  (`--permission-mode default` or omit flag).
- [ ] **R10 (MUST):** Add `make check-phase1-baseline` target as a hard gate before any Phase
  2 PR opens.

**Before starting Phase 2:**

- [ ] **R7 (MUST):** Either fully specify `EVIDENCE_MISSING` as a deliverable OR remove all
  references and document lint as the only protection.
- [ ] **R8 (MUST):** Add a verbatim fenced-markdown template for the read-your-evidence-file
  instruction.
- [ ] **R9 (MUST):** Correct lines 305-308; remove "surfaced by the Phase-0 harness reader."

**Before starting Phase 3:**

- [ ] **R6 (MUST):** Add explicit Phase 3 wiring items for step 1 (orchestrator gates 1 call,
  PENDING-filter, fix-loop re-invoke) in the same PR as `rebase-completeness.sh`.

**Lower priority (bundle with relevant phase PRs):**

- [ ] **R11:** Update crash-safe fallback trigger from "companion not found/crashes/no NEW_ISSUES"
  to "evidence file missing or stale" in each companion `.md` Phase 2 conversion PR.
- [ ] **R12:** Add `local _fc=$(_config_val ...)` to Phase 1(c) implementation note.
- [ ] **R13:** Add minimum-count assertion to `test/assert-evidence-paths.sh`.
- [ ] **R14:** Expand "drop .crash" pseudocode to canonical bash.
