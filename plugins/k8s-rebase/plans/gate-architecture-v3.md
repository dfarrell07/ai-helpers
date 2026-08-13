# Gate Architecture v3: Evidence-In, Declared Shapes

**STATUS: PLANNED.** Supersedes gate-architecture-v2.md. v2 was adversarially
reviewed and empirically verified against the running code; the review found its
core mechanism aimed at a code path that barely runs and verified proxies instead
of risks. v3 was then adversarially reviewed **twice** (5 agents per round +
line-level re-verification against bash 5.2 and the live orchestrator/lib/gate/
step files). This document is the post-review design.

The honest scope, stated up front so the phase list can't overstate it:

- **Phase 0 is the whole patch.** Three mechanical fixes remove the
  crash→false-FAIL class and a wasted subagent *today*, with no new gate scripts
  and no taxonomy. If nothing else ships, Phase 0 is still a net win.
- **Phase 1 is a decision gate.** It fixes the test-time court and measures
  whether gate soundness is still the binding constraint after the Stop-hook fix.
  Everything from Phase 3 on is *conditional on that measurement* — it is a
  refactor we do only if the data says it's worth it, not a foregone conclusion.
- Phase 2 (a small, low-risk deterministic subset) and Phases 3-6 (declared
  shapes, unified execution, narrow evidence-in, consolidation) are the
  conditional refactor. Do not read the six phases as "a five-phase
  re-architecture is happening"; read them as "here is the patch, here is how we'd
  decide, and here is the ordered refactor *if* we decide yes."

Evidence-in survives only as a narrow tool (two gates), not the centerpiece.

## What the verification found (v2's defects — all re-confirmed)

1. **`cmd_gates` is step-4-only.** `orchestrator.sh gates` is invoked in exactly
   one production location: `step4-verification.md:58`. Steps 1-3 launch one
   subagent per gate `.md`; the **6** gates that have a companion `.sh` self-run it
   via a "MANDATORY FIRST STEP" block (`build-vet`, `version-consistency`,
   `crd-validation`, `major-version-imports`, `patterns-completeness`,
   `go-version-check` — verified by `find gates -name '*.sh'`). So v2's whole
   mechanism (`finish_gate_final`, `.post.sh` override wired into `cmd_gates`)
   reaches only step 4, and `cmd_advance` (report-driven, `orchestrator.sh:226-329`)
   has no post hook at all.

2. **The "fewer subagents" benefit is illusory as specified.** `cmd_gates`
   fast-paths only on `grep 'NEW_ISSUES=0'` (`:204`), but `finish_gate` emits
   `RESOLVED:`/`PENDING`, never `NEW_ISSUES=0` (`gate-script-lib.sh:56-77`).
   Reproduced: a clean deterministic PASS is labeled PENDING on the first `gates`
   call, so `step4:60` ("launch subagents only for PENDING gates") spawns a
   redundant subagent. It self-heals on the *next* call via the disk pre-check at
   `:192`, so the cost is one wasted subagent per gate per run, not a correctness
   bug. v2's "Orchestrator change: None needed" is still wrong.

3. **Half the proposed `full-sh` gates would false-FAIL good rebases.**
   `version-consistency.sh:26-32` flags *every* `k8s.io/*` require not containing
   the target — including `k8s.io/utils` (`v0.0.0-…`), `klog/v2`, `kube-openapi`,
   and `sigs.k8s.io/*` (the `grep 'k8s.io/'` matches the `sigs.` prefix as a
   substring), none of which track the k8s minor. Simulated on a real `go.mod`:
   most independent modules over-flag (8/11 on one sample, 6/11 on another —
   repo-specific, so cite it as "most independent modules," not a fixed count).
   The target file *is* written (step 1, `k8s-rebase.sh:1046`), so the risk is not
   moot — only latent today because `version-consistency` uses `finish_gate`,
   which defers to the AI on issues rather than writing FAIL. Promoting it to
   script-writes-FAIL is a real regression. `build-vet.sh:25-39` has no
   base-branch filter. `dep-cve-check` is "always PASS." `feature-gates` needs
   featuregate-lifecycle knowledge — the "fragile parser" `future-ideas.md`
   already deferred.

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

## What the two self-review rounds corrected in v3 itself

Recorded so they are not re-litigated. Each was traced or tested.

- **A crash must not write *any* verdict — not FAIL, and not a new ERROR verdict.**
  `_gate_trap` (`gate-script-lib.sh:18-27`) writes `VERDICT: FAIL` on any nonzero
  exit, so a crashing pre-script can masquerade as a real gate failure. The
  *first* v3 draft "fixed" this by having the trap write `VERDICT: ERROR` and
  holding ERROR gates in `cmd_gates`. **That design was broken** and is abandoned:
  `report_has_verdict` (`:117-120`) matches only `PASS|FAIL|SKIP`, so the ERROR
  branch was dead code; `cmd_advance` (`:251`) bucketed ERROR as `missing` and
  **force-advanced after 3 attempts** (`:293`), and `cmd_status` showed it as
  MISSING — the opposite of "held." Widening `report_has_verdict` to include ERROR
  just routes it to the `failing` bucket → crash-as-FAIL, the exact bug we were
  removing. **The correct fix is simpler: the trap writes no report at all** (an
  inert `.crash` breadcrumb + a stdout line for observability). No report → the
  existing "no verdict → PENDING → AI subagent judges the gate fresh" path takes
  over. A crash therefore degrades to the same handling as any pure-judgment gate
  — a path that already exists and is already tested — instead of inventing a
  disk state three orchestrator functions would have to learn. See Phase 0.
- **Base-filter reality is the *inverse* of the first draft's claim.**
  `crd-validation.sh` and `patterns-completeness.sh` *already* compute `BASE` and
  filter to changed/new items (`git show $BASE:` / `git diff $BASE..HEAD` —
  verified by grep). The gates that lack a base filter are `build-vet.sh` and
  `version-consistency.sh`. The taxonomy below reflects the verified reality.
- **"Convert" hid new authoring.** Of the deterministic candidates, only
  `major-version-imports` and `go-version-check` have a companion `.sh` to convert.
  `cleanliness`, `diff-scope`, `test-compilation`, and `build-vet-recheck` have
  **no companion today** — those are new scripts to author, roughly 2× the effort
  "convert" implied. `autofix-result` carries a judgment tail ("zero fix commits
  but build passes = PASS with a note") that is not a clean deterministic
  predicate — it stays judgment/filter, not deterministic.
- **The shape linter does not exist yet.** `make lint` runs skillsaw against
  `.claude-plugin`/`commands`/`skills`; gate `.md` files live under `gates/`, have
  no frontmatter today, and are outside skillsaw's schema. The plugin's own
  Makefile has no `lint` target. Declared shapes require *building* a linter
  (Phase 3), and even then lint can only check that the declared shape matches the
  `finish_*` the companion calls — it **cannot** verify a predicate is sound. So
  the safety claim is narrowed: a wrong *declaration* fails lint; an *unsound
  predicate* is caught only by a fixture test (Phase 3), never by lint.
- **`finish_evidence` was orphaned.** A judgment gate with a pre-script that
  fast-paths clean and defers flagged items *is* the `filter` shape. Pure judgment
  has no companion. There is no third case, so `finish_evidence` is dropped;
  `_write_evidence` survives as `finish_filter`'s helper.
- **`inc` is unsafe under `set -u`** for an uninitialized custom counter
  (`${!var}` on an unbound name aborts). Guard with `${!var:-0}`. (It is a
  bashism; companions are bash, so that is acceptable — note it, don't fix it.)
- **Two shapes lose the deterministic fast-path** for hybrid gates. v3 keeps a
  `filter` shape (PASS-on-clean with no subagent; defer only flagged items).
- **Evidence-in does not stop satisficing** — only hallucination. Narrowed to the
  ~2 gates where a script can inject a fact the AI would otherwise guess.
- **The court runs only in the test harness** (`test/test-skill.sh` + its Makefile
  target + `config-1.35.yaml`; zero references in `skills/`, `scripts/`, `gates/`,
  `hooks/`). It is a *test-time* quality measurement, not a production runtime
  guard. The production backstop is human + CI review at the PR boundary — by
  design (pr-feedback-resolution.md). **This backstop does not catch semantic
  satisficing** (e.g. a silently dropped struct field that still compiles and
  passes unit tests); say so plainly rather than implying coverage.

## Design principles

1. **A script may write a verdict only where its predicate is mechanically sound**
   — near-zero false-FAIL on real repos. "Can compute the inputs" ≠ "can decide."
   Everything else defers to the AI.

2. **A crash is never a verdict.** Infra failure writes no report; the gate falls
   through to the AI-judgment path (PENDING), exactly as if it had no companion. A
   `.crash` breadcrumb makes it observable to the test harness. This is what makes
   principle 1 enforceable rather than aspirational, and it reuses the existing
   no-report path instead of a bespoke verdict state.

3. **Evidence flows into the prompt; the AI's judgment is checked by review, not
   by a proxy re-count.** A pre-script hands the AI ground-truth facts it would
   otherwise guess (module classifications, vendor symbol presence). This closes
   *hallucination*. It does **not** close *satisficing* — the same model writes
   the per-item report and can fabricate N citations as cheaply as one.
   Satisficing is caught at test time by the court; in production it is *not*
   directly caught (human + CI miss semantic drops). Be honest about which layer
   catches what.

4. **Shape is declared, and declaration is linted for label↔function agreement —
   not for soundness.** Each gate declares one of four shapes; `make lint` (once
   built) checks the companion calls the `finish_*` its declaration implies.
   Predicate soundness is a *separate* guarantee, established by a fixture test
   (zero false-FAIL on a repo with known pre-existing breakage), not by lint.

5. **One execution path for all steps.** `orchestrator.sh gates <step>` is the
   single entry point for every step's gate phase. Deterministic and clean-filter
   gates resolve with no subagent everywhere; judgment gates get a subagent, with
   pre-computed evidence where a pre-script exists.

## Target architecture

### Four declared shapes

Declared in the gate `.md` frontmatter (`shape: deterministic|filter|judgment|info`),
lint-enforced once the linter exists (Phase 3):

- **deterministic** — companion fully decides PASS/FAIL and writes the report. No
  subagent. Only where the predicate is sound and base-filtered.
  `finish_deterministic`.
- **filter** — companion fast-paths PASS on the clean case (writes a report, no
  subagent) and, on flagged items, writes an **evidence file** deferring only
  those items to the AI. `finish_filter`. Preserves the fast-path that
  two-shapes threw away.
- **judgment** — an AI subagent decides; **no companion**. (A judgment gate that
  wants pre-computed evidence *is* a `filter` gate.)
- **info** — always PASS; findings recorded for follow-up, never block.
  `finish_info`. Note the distinction lint can't see: some info gates are
  *inherently* non-computable (`maintainer-review`), while others are *computable
  but non-blocking by policy* (`dep-cve-check`). Both are `info`, but the second
  is a deliberate policy choice, not a capability limit — record that in the
  gate's `.md` so a future maintainer doesn't "promote" it to deterministic and
  start blocking rebases on CVE noise.

The orchestrator reacts to disk, not to the declaration: fresh verdict report →
resolved; evidence file → PENDING with the evidence path; nothing → PENDING (AI).
There is no ERROR disk state.

### Library API (`gate-script-lib.sh`)

```bash
inc() {                       # safe counter — never returns nonzero, safe under set -u
  local var="${1:-NEW_ISSUES}"                          # bashism (companions are bash)
  printf -v "$var" '%d' "$(( ${!var:-0} + 1 ))"
}

_gate_trap() {                # a crash writes NO report — it degrades to the AI path
  local exit_code=$?
  [[ $exit_code -eq 0 ]] && return 0
  if [[ -n "${REPO:-}" && -n "${GATE_NAME:-}" ]]; then
    mkdir -p "$REPO/.rebase-tmp/gates"
    printf 'exit %s at %s\n' "$exit_code" "${BASH_SOURCE[1]:-unknown}" \
      > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"     # inert breadcrumb, never read as a verdict
  fi
  echo "CRASH: ${GATE_NAME:-?} (exit $exit_code) — no report written, deferring to AI"
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
  local ev="$REPO/.rebase-tmp/gates/${GATE_NAME}.evidence"   # GATE_NAME is already prefixed
  { echo "SUMMARY: $summary"; printf '%s\n' "$@"; } > "$ev.tmp" && mv "$ev.tmp" "$ev"
  echo "PENDING: $GATE_NAME"; echo "EVIDENCE: $ev"
}

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

`inc` fixes the `((n++))`-returns-1-at-0 footgun. `_gate_trap` no longer touches
`write-gate-report.sh`, so its verdict allow-list is unchanged (no ERROR).
`finish_gate` is kept during migration, then removed once callers move over.

### Orchestrator change

Replace the stdout grep (finding 2) with a disk re-check plus an `evidence_path()`
helper that mirrors `report_path()`'s prefix handling. No ERROR branch — a
missing report simply falls through to PENDING:

```bash
evidence_path() { local r="$1" sd="$2" g="$3"; echo "$r/.rebase-tmp/gates/${sd%-*}-${g}.evidence"; }

# In cmd_gates, after the top-of-loop fresh-report short-circuit:
[[ -x "$companion" ]] && timeout "${GATE_TIMEOUT:-300}" bash "$companion" "$repo" 2>&1 || true
if report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then
  verdict=$(grep '^VERDICT:' "$rpt" | awk '{print $2}')
  echo "RESOLVED: $gate_name $verdict"; ((resolved++)) || true; continue
fi
ev=$(evidence_path "$repo" "$sd" "$gate_name")
[[ -f "$ev" ]] && echo "EVIDENCE: $ev"
echo "PENDING: $gate_name"; ((pending++)) || true
```

A crashed companion writes no report, so it lands here as PENDING; the step file
then launches an AI subagent for it, and if that too can't resolve it, the
existing 3-attempt force-advance path applies (INCOMPLETE marker → `--draft` PR) —
the accepted backstop for any stuck gate. A crash can therefore never fabricate a
FAIL, and it never silently succeeds: the `.crash` breadcrumb + the `CRASH:`
stdout line surface it, and the test harness flags any `.crash` file as an infra
bug.

**Prefix-derivation consistency (latent bug to avoid):** `evidence_path` derives
the step prefix with `${sd%-*}`; `init_gate` derives `GATE_NAME`'s prefix with
`grep -oE '^step[0-9]+'`. These agree for every current step dir
(`step2-compilation` → `step2` both ways) but diverge if a step dir's suffix ever
contains a hyphen. Standardize both on `${step_dir%-*}` (what `report_path`
already uses) when touching this code.

## Gate taxonomy (33 → 31, subject to Phase 6 reconciliation)

Shape is **declared per gate**; this table is the intended declaration. Counts and
base-filter status below are verified against the live tree.

**deterministic (candidates, gated on a base filter + fixture test)** —
`major-version-imports` (has `.sh`), `go-version-check` (has `.sh`), `cleanliness`
(author new), `diff-scope` (author new). †`build-vet`, †`build-vet-recheck`,
†`test-compilation` need a base-branch pre-existing filter authored *before* they
may write FAIL (`build-vet.sh` has none; `build-vet-recheck`/`test-compilation`
have no companion at all). `autofix-result` is **not** here — its "zero fix
commits but build passes = PASS-with-note" judgment tail keeps it `filter`.

**filter (already base-filtered — safe to defer today)** — `crd-validation`,
`patterns-completeness` (both compute `BASE` and defer only changed items;
converting them to `finish_filter` is close to a rename). Plus `autofix-result`
once its build-count core is split from its judgment tail.

**info / always-PASS** — `dep-cve-check` (computable, non-blocking *by policy*),
`dep-release-notes`, `maintainer-review` (non-computable), `skill-improvement`,
`commit-messages`.

**judgment (AI decides; no companion)** — `rebase-completeness`,
`version-consistency`⚠, `type-conversions`, `fix-correctness`, `deprecated-calls`,
`feature-gates`⚠, `e2e-infra`, `autofix-diff-review`, `deprecated-api-remnants`,
`deprecated-imports`, `version-completeness`, `gomod-diff-analysis`, `correctness`,
`ci-prediction`, `k8s-changelog`, `logical-consistency`. (⚠ = the only two where
evidence-in is implementable, which makes them `filter` gates — see Phase 5.)

**Dropped/folded:** `logical-completeness` → subset of `logical-consistency`;
`ci-readiness` → folds into `ci-prediction`. **Contested, do not hardcode:**
`autofix-patterns-redesign.md` (already marked IMPLEMENTED, plugin at 0.3.0) also
merges `commit-messages` → `maintainer-review` (its target is 30). Re-audit live
state and reconcile the final count in Phase 6 rather than asserting 31 here.

## Migration sequence

Each phase ships independently. **Bump `plugin.json` and run `make lint && make
update` once per landed PR, not once per phase** — if several phases land on one
branch, the intermediate bumps are dead weight (only the final version reaches
`marketplace.json`). If phases land as separate PRs, bump per PR.

**Phase 0 — Mechanical patch (ship first; this is the whole patch).**
(a) `inc` with the `${!var:-0}` guard. (b) `_gate_trap` writes a `.crash`
breadcrumb + `CRASH:` line instead of a FAIL report — this removes the
crash→false-FAIL class *today*, before any new script exists, and touches nothing
outside `gate-script-lib.sh`. (c) `cmd_gates` disk re-check + `evidence_path()`.
This is **not** "zero behavior change": (b) means a crashing companion now
defers to AI instead of FAILing (louder-in-production trade recorded in Risks),
and (c) drops the redundant first-wave step-4 subagent from finding 2 — attribute
that reduction here, not to Phase 4.

**Phase 1 — Fix the court, then measure (decision gate for Phases 3-6).**
Two *separable* pieces; do not couple them:
- *Instrumentation (the real prerequisite).* Decide the subagent-count metric.
  Note the constraint: subagents are spawned by in-session `Agent()` calls in the
  step files, which neither the orchestrator nor the harness observes, so a true
  count needs new telemetry; the only free proxy is the existing PENDING count.
  And `results.tsv` is positional (6 tab columns, parsed at
  `test-skill.sh:1299/1578/1635/1735`) — any new column touches every reader.
  **Build it or drop the criterion; do not assert it unmeasured.**
- *Court juror tool use (a research task, not a 5-line edit).* Jurors are
  *already* granted the tools (`test-skill.sh:1215`) and *already* prompted to
  verify (`:1224-1241`), yet 0/15 call one (step-isolation §6). Forcing an LLM to
  invoke a tool is prompt engineering with uncertain yield — budget it as
  research, and gate the measurement on the *post-`pr-feedback-resolution`
  stripping* baseline so jurors aren't reading leaked patterns.

Then answer empirically: after the Stop-hook fix (91% step adherence), is gate
satisficing/flakiness still the binding constraint? **If not, stop here** —
Phases 3-6 are speculative. Only the instrumentation outcome gates the next
phase; the juror fix is test-harness quality work that can proceed independently.

**Phase 2 — Safe deterministic subset (low-risk; worth doing regardless).**
Add `finish_deterministic`/`finish_info`/`finish_filter` + `_write_evidence` to
the lib (no frontmatter/lint yet — that's Phase 3). Then:
- *Convert* (has `.sh`): `major-version-imports`, `go-version-check`.
- *Author new* `.sh`: `cleanliness`, `diff-scope`.
- *Author base filter first, then author `.sh`*: `test-compilation`,
  `build-vet-recheck`; *add base filter, then convert*: `build-vet`.
- *Mark info*: the 5 info gates.
- *Leave as filter*: `crd-validation`, `patterns-completeness` (rename to
  `finish_filter`), `autofix-result` (after splitting its judgment tail).
**Coupling to respect:** a gate that starts emitting `RESOLVED:` must have its
`.md` MANDATORY block (which greps `NEW_ISSUES=0`) updated in the *same commit*.
Do **not** touch `version-consistency`/`feature-gates` here (Phase 5).

**Phase 3 — Declared shapes + lint (only if Phase 1 justifies the taxonomy).**
Add `shape:` frontmatter to every gate `.md`. **Build the shape linter** — it does
not exist; wire a new check into the plugin's Makefile (skillsaw won't do it).
Lint verifies label↔`finish_*` agreement only. Add the real soundness gate: a
**fixture test** that runs each deterministic gate against a repo with known
pre-existing breakage and asserts zero false-FAIL. Drop any "cannot produce a
false verdict" language — lint can't promise that; the fixture test is what does.

**Phase 4 — Unify execution (only if Phase 1 justifies it).**
Steps 1-3 call `orchestrator.sh gates <step>` first, mirroring step 4. This is
~20 files: **15 gate `.md` files carry a MANDATORY block** (verified) and the
step files use *inconsistent* spawn conventions (step 4 already calls the
orchestrator; step 2 hand-builds "all 6 in a single message"; steps 1/3 differ).
**Atomic ordering per gate:** add the `gates` call *while keeping* the idempotent
MANDATORY block → verify `cmd_gates` output lines up with what the step tells the
agent to launch → only then drop that gate's block, and only after its companion
is confirmed to write a report/evidence. Deterministic/clean-filter gates now
resolve with zero subagents across all steps — the real reduction lands here.

**Phase 5 — Evidence-in, narrow (as `filter` gates).**
Only where a script can inject a fact the AI would otherwise guess wrong:
`version-consistency` (classify each `k8s.io/*` as staging/lockstep vs
independent) and `feature-gates` (list refs + vendor symbol presence). **Derive
the module classification at runtime** from `k8s.io/kubernetes`'s `go.mod`
`replace` directives at the target tag — a hardcoded staging-module list rots as
k8s adds/removes staging modules across releases. Put that derivation in one
sourced shell helper consumed by both the gate `.sh` and any `k8s-rebase.sh` site
that needs it (this replaces, not adds to, the duplicated logic in
`next-work.md:14-17` and `:23-28` — name the single home explicitly when doing
the work). Prefer promoting these to **deterministic** if the derived predicate is
sound; fall back to `filter` otherwise. Optional **bounded override**, applicable
*only* here and flagged as the one sanctioned script-writes-FAIL path outside a
deterministic gate: write FAIL when the AI's explicit machine-parseable claimed
count contradicts the script-injected ground-truth count (near-zero false-FAIL
because it compares like-for-like; brittle because it depends on the AI emitting a
parseable count — keep it optional). Leave `type-conversions`, `k8s-changelog`,
`ci-prediction`, `logical-consistency` as **pure judgment** — bash cannot soundly
enumerate struct fields (embedding/aliases/generics) or interpret a changelog.

**Phase 6 — Consolidation.**
Re-audit the live state first: `autofix-patterns-redesign.md` is marked
IMPLEMENTED, so some consolidation may already be done or diverged. Reconcile the
target count across it and `next-work.md`. Drop `logical-completeness`; fold
`ci-readiness` → `ci-prediction`; decide the contested `commit-messages` →
`maintainer-review` merge; narrow `deprecated-api-remnants` to web-search
discovery (step-isolation §8). Keep the harness in lockstep: `EXPECTED_GATES` is
computed dynamically (`test-skill.sh:139`, `find … | wc -l`) so a count drop
auto-adjusts, but `INFO_GATES` (`:21`, currently 4 gates) is hardcoded — update it
in the same commit if the info set changes (e.g. adding `dep-release-notes`).

## What v3 rejects from v2, and why

| v2 element | Rejected because |
|------------|------------------|
| `.post.sh` override | Verifies proxies not risks (finding 4); barely runs (finding 1); lossy + non-idempotent (finding 5); can false-FAIL. Replaced by evidence-in (hallucination) + court/human review (satisficing). |
| `init_post_gate`/`post_check`/`finish_post_gate` | Machinery for the rejected override. A Phase-5 bounded override keeps the one sound catch. |
| "Orchestrator change: None needed" | Wrong (finding 2). The disk re-check IS the required change. |
| `version-consistency`/`feature-gates`/`dep-cve-check` → full-sh | False-FAIL good rebases / are always-PASS (finding 3). |
| Grep `NEW_ISSUES=0` fast-path | Never matched `finish_gate` output. Replaced by disk re-check. |

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Crash now defers to AI instead of FAILing → less loud in production | Low-Med | `.crash` breadcrumb + `CRASH:` stdout line; test harness flags any `.crash` as an infra bug so it's caught before release. The AI/force-advance path (INCOMPLETE → draft PR) prevents a silent green. |
| Base-filter bugs in newly-deterministic gates | Medium | Convert only after the fixture test (Phase 3) shows zero false-FAIL on a known-broken repo. Until then the gate stays `filter` (may defer, never FAIL). |
| Shape linter must be built from scratch | Medium | Scoped explicitly in Phase 3; until it exists, a mis-declared shape is caught by nothing — so soundness rests on the fixture test, not lint. |
| Phase 4 `.md`/step-file rewrite mis-ordered across 15 MANDATORY blocks | Medium | Atomic per-gate ordering: add `gates` call with block intact → verify → drop block only after the companion writes report/evidence. |
| Evidence pre-script crashes | Low | Crash trap (Phase 0) → breadcrumb + PENDING, never FAIL. Independent of shape. |
| Phase-5 pre-scripts re-run every `gates` call (cost) | Low-Med | Only 2 gates get pre-scripts; keep them cheap (no `go build`). Gate on evidence freshness if it proves costly. |
| Cross-plan collision (consolidation count; module-class helper; test-skill.sh regions) | Medium | Re-audit live state (Phase 6); single sourced classification helper (Phase 5); Phase 1 court edit is a different region than pr-feedback's stripping edit but must run against the post-stripping baseline. |
| Migration half-done leaves mixed conventions | Low | `cmd_gates` disk re-check handles `finish_gate`, all new `finish_*`, and no-report simultaneously — old and new coexist. |

## Success criteria

- No gate can write `VERDICT: FAIL` except a **deterministic** gate on its own
  sound, base-filtered predicate (validated by the Phase-3 fixture test), or a
  Phase-5 bounded override on a claim-vs-injected-truth mismatch. A crash writes
  no report at all.
- Zero false-FAIL regressions vs the current pass rate. **Baseline caveat:** the
  spec=all baseline is being changed by `pr-feedback-resolution.md`'s stripping
  rewrite — establish the post-rewrite baseline before gating on it.
- Deterministic/clean-filter gates spawn zero subagents in **all** steps —
  *measurable only if Phase 1 builds the instrumentation.* If it doesn't, drop
  this criterion rather than asserting it unmeasured; the PENDING-count proxy is
  the fallback.
- Court jurors use their tools (git show/diff/Read) on every test run — the
  test-time semantic backstop post-verification could never soundly provide.
  (Tracked as a research outcome, not a guaranteed edit.)

## Relation to other plans

- **gate-architecture-v2.md:** superseded; kept as the record of the rejected
  design.
- **step-isolation-and-generality.md:** v3 collapses the three-tier model (§4.4)
  to four declared shapes and adopts the §6 juror tool-use fix as Phase 1.
- **future-ideas.md:** vindicates the feature-gate "fragile parser" deferral —
  `feature-gates` stays judgment; evidence-in only lists refs + vendor presence.
- **pr-feedback-resolution.md:** moves the spec=all baseline (success criteria)
  and shares `test-skill.sh`; sequence Phase 1's measurement after it lands.
- **autofix-patterns-redesign.md / next-work.md:** own the contested
  consolidation count (already partly IMPLEMENTED) and the duplicated
  module-classification logic; reconcile in Phases 5-6.

<!-- Budget: ~400 lines (raised to record two review rounds' corrections). -->
