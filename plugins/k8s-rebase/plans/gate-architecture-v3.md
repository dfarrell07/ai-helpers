# Gate Architecture v3: Evidence-In, Declared Shapes

**STATUS: PLANNED.** Supersedes gate-architecture-v2.md. v2 was adversarially
reviewed and empirically verified against the running code; the review found
its core mechanism aimed at a code path that barely runs and verified proxies
instead of risks. v3 was **then adversarially reviewed itself** (5 agents +
line-level re-verification). This document is the post-review design: it keeps
v2's sound instinct (migrate probabilistic → deterministic where sound), keeps
the two mechanical fixes both reviews endorse, and discards the parts of *both*
plans that don't survive contact with the runtime.

The honest headline from the v3 self-review: **the findings justify a patch and
a court fix, not a five-phase re-architecture.** The plan below is scoped to
that. Evidence-in survives only as a narrow tool, not the centerpiece.

## What the verification found (v2's defects — all re-confirmed)

Empirical checks (bash 5.2, the target platform) and line-level tracing of the
actual orchestrator, lib, gate `.md`/`.sh`, and step files. Every claim below
was independently re-verified in the v3 self-review.

1. **`cmd_gates` is step-4-only.** `orchestrator.sh gates` is invoked in exactly
   one production location: `step4-verification.md:58`. Steps 1-3 launch one
   subagent per gate `.md`; the ~5 gates that *have* a companion `.sh` self-run
   it via a "MANDATORY FIRST STEP" block (most gates have no companion). So v2's
   whole mechanism — `finish_gate_final`, `.post.sh` override wired into
   `cmd_gates` — reaches only step 4, and `cmd_advance` (report-driven,
   `orchestrator.sh:226-329`) has no post hook at all.

2. **The "fewer subagents" benefit is illusory as specified.** `cmd_gates`
   fast-paths only on `grep 'NEW_ISSUES=0'` (`orchestrator.sh:204`), but
   `finish_gate` emits `RESOLVED:`/`PENDING`, never `NEW_ISSUES=0`
   (`gate-script-lib.sh:56-77`). Reproduced: a clean deterministic PASS is
   labeled PENDING on the first `gates` call, and `step4:60` ("launch subagents
   only for PENDING gates") therefore spawns a redundant subagent. (It self-heals
   on the *next* call via the disk pre-check at `orchestrator.sh:192`, so the cost
   is one wasted subagent per gate per run, not a correctness bug.) v2's
   "Orchestrator change: None needed" is still wrong.

3. **Half the proposed `full-sh` gates would false-FAIL good rebases.**
   `version-consistency.sh:26-32` flags *every* `k8s.io/*` require not containing
   the target — including `k8s.io/utils` (`v0.0.0-…`), `klog/v2`, `kube-openapi`,
   and `sigs.k8s.io/*` (the `grep 'k8s.io/'` matches the `sigs.` prefix as a
   substring), none of which track the k8s minor. Simulated on a real `go.mod`:
   **8 of 11 modules over-flagged.** The target file *is* written (step 1,
   `k8s-rebase.sh:1046`), so the risk is not moot — it is only latent today
   because `version-consistency` uses `finish_gate`, which *defers* to the AI on
   issues rather than writing FAIL. Promoting it to script-writes-FAIL is a real
   regression. `build-vet.sh:25-39` has no base-branch filter. `dep-cve-check`
   is "always PASS." `feature-gates` needs featuregate-lifecycle knowledge — the
   "fragile parser" `future-ideas.md` already deferred.

4. **Post-verification verifies a proxy, not the risk.** `type-conversions`
   judges whether struct fields are *silently dropped at runtime*
   (`type-conversions.md:13-23`); a post-script checking field *counts* confirms
   arithmetic, not the mapping — and a benign count mismatch flips a good PASS to
   FAIL.

5. **The override path is lossy and non-idempotent.** `write-gate-report.sh` does
   a truncating rewrite (`:25-36`); `finish_post_gate` appends POST_ lines then
   calls it on override, destroying both the POST_ section and the AI's reasoning
   — contradicting v2's own preservation rationale.

6. **Refuted:** v2's scariest claim (timeout → SIGTERM → exit 143 → false FAIL)
   does not reproduce; the EXIT trap sees `exit_code=0` on SIGTERM across three
   variants. The real trap risk is narrower: an unguarded `((n++))`/empty `grep`
   under `set -e` aborts (exit 1) → trap → false report.

## What the v3 self-review corrected in v3 itself

These are recorded so they are not re-litigated. Each was traced or tested.

- **The crash trap writes a content FAIL.** `_gate_trap` (`gate-script-lib.sh:18-27`)
  writes `VERDICT: FAIL` on *any* nonzero exit. Adding crash-prone pre-scripts
  (parse vendor, `go build`) to judgment gates would let a script crash
  masquerade as a real gate failure — violating this plan's own "no script may
  write FAIL except a sound deterministic predicate." **Fix: the trap writes
  `VERDICT: ERROR`, never FAIL** (see below). This is the load-bearing safety
  change and it is independent of any gate's declared shape.
- **Evidence filename prefix mismatch.** `init_gate` prefixes `GATE_NAME`
  (`step2-version-consistency`), but `cmd_gates` uses the bare basename
  (`version-consistency`). Reports work only because `report_path()` re-adds the
  prefix; an evidence lookup must use a matching `evidence_path()` helper, or the
  hand-off silently no-ops.
- **`inc` is unsafe under `set -u`** for an uninitialized custom counter
  (`${!var}` on an unbound name aborts). Guard with `${!var:-0}`.
- **Two shapes lose the deterministic fast-path** for hybrid gates (a mechanical
  core + a judgment tail, e.g. `deprecated-calls`/SA1019). v3 adds a third
  **filter** shape (PASS-on-clean with no subagent; defer only flagged items).
- **"Type is emergent" is a teachability regression** — invisible from `tree`,
  not lintable, and it forces a prose table the runtime can silently contradict.
  v3 **declares** the shape and lints it; runtime safety comes from the ERROR
  trap, so a mis-declaration is a lint failure, never a false FAIL.
- **Evidence-in does not stop satisficing** — only hallucination. It is narrowed
  to the ~2 gates where a script can inject a fact the AI would otherwise guess.
- **The court runs only in the test harness** (`test/test-skill.sh`; zero
  references in `skills/`, `scripts/`, `gates/`, `hooks/`). It is a *test-time*
  quality measurement, not a production runtime guard. The production backstop is
  the human + CI review at the PR boundary — by design (pr-feedback-resolution.md).

## Design principles

1. **A script may write a verdict only where its predicate is mechanically sound**
   — near-zero false-FAIL on real repos. "Can compute the inputs" ≠ "can decide."
   Everything else defers to the AI.

2. **A crash is never a content verdict.** Infra failure → `VERDICT: ERROR` →
   the step holds (subagent investigates); it never becomes PASS or FAIL. This is
   what makes principle 1 enforceable rather than aspirational.

3. **Evidence flows into the prompt; the AI's judgment is checked by review, not
   by a proxy re-count.** A pre-script hands the AI ground-truth facts it would
   otherwise guess (module classifications, vendor symbol presence). This closes
   *hallucination*. It does **not** close *satisficing* ("AI never looked") — the
   same model writes the per-item report and can fabricate N citations as cheaply
   as one. Satisficing is caught at test time by the court, and in production by
   human + CI review. Be honest about which layer catches what.

4. **Shape is declared and lintable.** Each gate declares one of four shapes.
   `make lint` checks the companion matches the declaration. The orchestrator's
   runtime behavior is driven by what lands on disk (report / evidence / ERROR),
   so a wrong declaration fails lint but cannot produce a false verdict.

5. **One execution path for all steps.** `orchestrator.sh gates <step>` is the
   single entry point for every step's gate phase. Deterministic and clean-filter
   gates resolve with no subagent everywhere; judgment gates get a subagent with
   pre-computed evidence.

## Target architecture

### Four declared shapes

Declared in the gate `.md` frontmatter (`shape: deterministic|filter|judgment|info`)
and enforced by `make lint`:

- **deterministic** — companion fully decides PASS/FAIL and writes the report. No
  subagent. Only where the predicate is sound. `finish_deterministic`.
- **filter** — companion fast-paths PASS on the clean case (writes a report, no
  subagent) and, on flagged items, writes an **evidence file** deferring only
  those items to the AI. `finish_filter`. This preserves the fast-path that the
  current `finish_gate` gives and two-shapes threw away.
- **judgment** — an AI subagent decides. Companion is optional; when present it
  writes an evidence file (never a report). `finish_evidence`. No companion = pure
  AI gate.
- **info** — always PASS; findings recorded for follow-up, never block.
  `finish_info`.

The orchestrator reacts to disk, not to the declaration: fresh verdict report →
resolved; `VERDICT: ERROR` → held for investigation; evidence file → PENDING with
the evidence path; nothing → PENDING (pure AI).

### Library API (`gate-script-lib.sh`)

```bash
inc() {                       # safe counter — never nonzero, safe under set -u
  local var="${1:-NEW_ISSUES}"
  printf -v "$var" '%d' "$(( ${!var:-0} + 1 ))"
}

_gate_trap() {                # a crash is ERROR (infra), NEVER FAIL (content)
  local exit_code=$?
  if [[ $exit_code -ne 0 && -n "${REPO:-}" && -n "${GATE_NAME:-}" ]]; then
    bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" ERROR 1 \
      "Companion crashed (exit $exit_code)" "Script: ${BASH_SOURCE[1]:-unknown}"
  fi
}

finish_deterministic() {      # script decides PASS/FAIL, writes report
  local issues="${1:?}" summary="${2:-}"; shift 2 2>/dev/null || true
  local verdict=PASS; [[ "$issues" -gt 0 ]] && verdict=FAIL
  bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" "$verdict" "$issues" "$summary" "$@"
  echo "RESOLVED: $GATE_NAME $verdict"; trap - EXIT; exit 0
}

finish_info() {               # always PASS; findings recorded, never block
  local summary="${1:-}"; shift 2>/dev/null || true
  bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$summary" "$@"
  echo "RESOLVED: $GATE_NAME PASS (informational)"; trap - EXIT; exit 0
}

_write_evidence() {           # atomic; mkdir -p (write-gate-report has it, we didn't)
  local summary="$1"; shift
  mkdir -p "$REPO/.rebase-tmp/gates"
  local ev="$REPO/.rebase-tmp/gates/${GATE_NAME}.evidence"   # GATE_NAME is prefixed
  { echo "SUMMARY: $summary"; printf '%s\n' "$@"; } > "$ev.tmp" && mv "$ev.tmp" "$ev"
  echo "PENDING: $GATE_NAME"; echo "EVIDENCE: $ev"
}

finish_evidence() { _write_evidence "$@"; trap - EXIT; exit 0; }   # judgment gate

finish_filter() {             # clean → PASS report (no subagent); dirty → evidence
  local issues="${1:?}" summary="${2:-}"; shift 2 2>/dev/null || true
  if [[ "$issues" -eq 0 ]]; then
    bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$summary" "$@"
    echo "RESOLVED: $GATE_NAME PASS"
  else
    _write_evidence "$summary" "$@"
  fi
  trap - EXIT; exit 0
}
```

`write-gate-report.sh` gains `ERROR` to its verdict allow-list (`:21`). `inc`
fixes the `((n++))`-returns-1-at-0 footgun; `finish_gate` is kept during
migration, then removed once callers move over.

### Orchestrator change

Replace the stdout grep with a disk re-check plus an `evidence_path()` helper
that mirrors `report_path()`'s prefix handling:

```bash
evidence_path() { local r="$1" sd="$2" g="$3"; echo "$r/.rebase-tmp/gates/${sd%-*}-${g}.evidence"; }

# In cmd_gates, after the top-of-loop fresh-report short-circuit:
[[ -x "$companion" ]] && timeout "${GATE_TIMEOUT:-300}" bash "$companion" "$repo" 2>&1 || true
if report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then
  verdict=$(grep '^VERDICT:' "$rpt" | awk '{print $2}')
  if [[ "$verdict" == "ERROR" ]]; then
    echo "ERROR: $gate_name (companion crashed — held for investigation)"
    ((pending++)) || true; continue          # never resolve, never FAIL, never advance
  fi
  echo "RESOLVED: $gate_name $verdict"; ((resolved++)) || true; continue
fi
ev=$(evidence_path "$repo" "$sd" "$gate_name")
[[ -f "$ev" ]] && echo "EVIDENCE: $ev"
echo "PENDING: $gate_name"; ((pending++)) || true
```

An ERROR gate is surfaced and held (a subagent investigates) — it is neither
resolved nor failed, so a crash can never advance a step or fabricate a FAIL.

## Gate taxonomy (33 → 31)

Shape is now **declared per gate**; this table is the intended declaration, and
`make lint` enforces it against each companion.

**deterministic (8)** — sound predicate, script writes verdict: `build-vet`†,
`test-compilation`†, `autofix-result`, `major-version-imports`,
`build-vet-recheck`†, `cleanliness`, `go-version-check`, `diff-scope`.
(† = add a base-branch pre-existing filter *before* the script may write FAIL.)

**filter (2)** — script fast-paths clean, defers flagged items: `crd-validation`,
`patterns-completeness` (both count build/CRD issues with no base filter today —
so they may only *defer*, never write FAIL, until filtered).

**info / always-PASS (5)** — record findings, never block: `dep-cve-check`,
`dep-release-notes`, `maintainer-review`, `skill-improvement`, `commit-messages`.

**judgment (16)** — AI decides; a pre-script may inject evidence but never a
verdict: `rebase-completeness`, `version-consistency`⚠, `type-conversions`,
`fix-correctness`, `deprecated-calls`, `feature-gates`⚠, `e2e-infra`,
`autofix-diff-review`, `deprecated-api-remnants`, `deprecated-imports`,
`version-completeness`, `gomod-diff-analysis`, `correctness`, `ci-prediction`,
`k8s-changelog`, `logical-consistency`.  (⚠ = the only two where evidence-in is
implementable — see Phase 4.)

**Dropped/folded (2):** `logical-completeness` → subset of `logical-consistency`;
`ci-readiness` → folds into `ci-prediction`. **Open, do not hardcode:**
`autofix-patterns-redesign.md` also merges `commit-messages` → `maintainer-review`
(target 30); reconcile the final count with that plan before Phase 5.

## Migration sequence

Ordered by risk and by dependency. Each phase ships independently, bumps
`plugin.json` `version`, and runs `make lint && make update` (repo requirement —
every phase edits skill/gate/lib files). Phases 0-1 are the highest-value,
lowest-risk wins.

**Phase 0 — Mechanical fixes (ship first).**
(a) `inc` with the `${!var:-0}` guard. (b) The `_gate_trap` ERROR change +
`write-gate-report.sh` ERROR allow-list — this removes the crash→false-FAIL class
*today*, before any new script exists. (c) `cmd_gates` disk re-check +
`evidence_path()`. Note: this is **not** "zero behavior change" — it drops the
redundant first-wave step-4 subagent from finding 2; attribute that reduction
here, not to Phase 3.

**Phase 1 — Declared shapes + the safe deterministic subset.**
Add `shape:` frontmatter + the lint check; add `finish_deterministic`/
`finish_info`/`finish_filter`/`finish_evidence`. Convert only sound gates:
`major-version-imports`, `cleanliness`, `autofix-result`, `go-version-check`,
`diff-scope`. Add base filters to `build-vet`/`build-vet-recheck`/
`test-compilation`, *then* convert. Mark the 5 info gates. **Coupling to respect:**
a gate converted to `finish_deterministic` must have its `.md` MANDATORY block
(which greps `NEW_ISSUES=0`) updated in the *same commit* — the new output is
`RESOLVED:`, not `NEW_ISSUES=0`. Do **not** touch `version-consistency`/
`feature-gates`/`crd-validation`/`patterns-completeness` here.

**Phase 2 — Fix the court, then measure (gate the rest of the plan on this).**
The court is the test-time backstop and currently its jurors use tools 0/15
(step-isolation §6). Force juror tool use (~5 lines in `test-skill.sh`). Build
the subagent-count instrumentation (`results.tsv` column / `events.jsonl`;
PLANNED-not-built per step-isolation §4.7) **or drop that success criterion** —
today it is un-evaluable. Then answer empirically: after the Stop-hook fix (91%
step adherence), is gate satisficing/flakiness still the binding constraint? If
not, stop here — Phases 3-4 are speculative.

**Phase 3 — Unify execution (only if Phase 2 justifies it).**
Steps 1-3 call `orchestrator.sh gates <step>` first, mirroring step 4.
**Atomic ordering:** change each step file to call `gates` *while keeping* the
idempotent `.md` MANDATORY blocks; verify; then drop each block only after that
gate's companion is confirmed to write a report/evidence. Deterministic and
clean-filter gates now resolve with zero subagents across all steps — the real
reduction lands here.

**Phase 4 — Evidence-in, narrow.**
Only where a script can inject a fact the AI would otherwise guess wrong:
`version-consistency` (classify each `k8s.io/*` as staging/lockstep vs
independent) and `feature-gates` (list refs + vendor symbol presence). Prefer
promoting these to **deterministic** with a **single shared module-classification
table** (dedupe the copies in `next-work.md:14-17` and `:23-28`); fall back to
`filter` if the predicate isn't fully sound. Optional **bounded override**,
applicable *only* here: write FAIL when the AI's explicit claimed count
contradicts the script-injected ground-truth count (near-zero false-FAIL because
it compares like-for-like). Leave `type-conversions`, `k8s-changelog`,
`ci-prediction`, `logical-consistency` as **pure judgment** — bash cannot soundly
enumerate full struct field lists (embedding/aliases/generics) or interpret a
changelog, so evidence-in buys nothing there.

**Phase 5 — Consolidation.**
Reconcile the target count with `autofix-patterns-redesign.md` and `next-work.md`
*first*. Drop `logical-completeness`; fold `ci-readiness` → `ci-prediction`;
decide the contested `commit-messages` → `maintainer-review` merge; narrow
`deprecated-api-remnants` to web-search discovery (step-isolation §8).

## What v3 rejects from v2, and why

| v2 element | Rejected because |
|------------|------------------|
| `.post.sh` override | Verifies proxies not risks (finding 4); barely runs (finding 1); lossy + non-idempotent (finding 5); can false-FAIL. Replaced by evidence-in (hallucination) + court/human review (satisficing). |
| `init_post_gate`/`post_check`/`finish_post_gate` | Machinery for the rejected override. `finish_evidence` replaces the useful half; a bounded override (Phase 4) keeps the one sound catch. |
| "Orchestrator change: None needed" | Wrong (finding 2). The disk re-check IS the required change. |
| `version-consistency`/`feature-gates`/`dep-cve-check` → full-sh | False-FAIL good rebases / are always-PASS (finding 3). |
| Grep `NEW_ISSUES=0` fast-path | Never matched `finish_gate` output. Replaced by disk re-check. |

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Base-filter bugs in newly-deterministic gates | Medium | Convert only after the filter is tested against a repo with known pre-existing breakage. Until then the gate stays `filter` (may defer, never FAIL). |
| Phase 3 `.md`/step-file rewrite mis-ordered | Medium | Atomic ordering above: add `gates` call with blocks intact → verify → drop blocks per-gate. Never drop a block before its companion writes report/evidence. |
| Evidence pre-script crashes | Low | ERROR trap (Phase 0) → held, never FAIL. Independent of shape. |
| Judgment pre-scripts re-run every `gates` call (cost) | Low-Med | Only 2 gates get pre-scripts (Phase 4); keep them cheap (no `go build`). Gate on evidence freshness if it proves costly. |
| Cross-plan collision (consolidation count, module-class list, rules.md/step2 edits) | Medium | Reconcile before Phase 4/5; single shared classification table; coordinate rules.md edits with next-work.md. |
| Migration half-done leaves mixed conventions | Low | `cmd_gates` disk re-check handles `finish_gate`, all new `finish_*`, and ERROR simultaneously — old and new coexist. |

## Success criteria

- No gate can write `VERDICT: FAIL` except a **deterministic** gate on its own
  sound, base-filtered predicate (or a Phase-4 bounded override on a
  claim-vs-injected-truth mismatch). A crash yields ERROR, never FAIL.
- Zero false-FAIL regressions vs the current pass rate. **Note:** the spec=all
  baseline (~95%) is being changed by `pr-feedback-resolution.md`'s stripping
  rewrite — establish the post-rewrite baseline before gating on it.
- Deterministic/clean-filter gates spawn zero subagents in **all** steps —
  *measurable only after Phase 2 builds the instrumentation.* If instrumentation
  is dropped, drop this criterion rather than asserting it unmeasured.
- Court jurors use their tools (git show/diff/Read) on every test run — the
  test-time semantic backstop post-verification could never soundly provide.

## Relation to other plans

- **gate-architecture-v2.md:** superseded; kept as the record of the rejected
  design.
- **step-isolation-and-generality.md:** v3 collapses the three-tier model (§4.4)
  to four declared shapes and adopts the §6 juror tool-use fix as Phase 2.
- **future-ideas.md:** vindicates the feature-gate "fragile parser" deferral —
  `feature-gates` stays judgment; evidence-in only lists refs + vendor presence.
- **pr-feedback-resolution.md:** moves the spec=all baseline (success criteria)
  and shares edits to `test-skill.sh`; sequence Phase 2 after it lands.
- **autofix-patterns-redesign.md / next-work.md:** own the contested
  consolidation count and the duplicated module-classification list; reconcile in
  Phases 4-5.

<!-- Budget: ~360 lines (raised from 300 to record the self-review corrections). -->
