# Gate Architecture v3: Evidence-In, Two Shapes

**STATUS: PLANNED.** Supersedes gate-architecture-v2.md. v2's design was
adversarially reviewed (4 agents) and empirically verified against the
running code; the review found the core mechanism aimed at a code path
that barely runs and verified proxies instead of risks. v3 keeps v2's
sound instinct (migrate probabilistic → deterministic) and discards the
parts that don't survive contact with the runtime.

## What the verification found

Empirical checks (bash 5.2, the target platform) and line-level tracing
of the actual orchestrator, lib, gate `.md`/`.sh` files, and step files:

1. **`cmd_gates` is step-4-only.** `orchestrator.sh gates` is invoked in
   exactly one production location: `step4-verification.md:58`. Steps 1-3
   launch one subagent per gate `.md`, and each gate self-runs its
   companion `.sh` via a "MANDATORY FIRST STEP" block. So v2's whole
   mechanism — `finish_gate_final` skipping subagents, `.post.sh` override
   wired into `cmd_gates` — reaches only step 4, and `cmd_advance`
   (report-driven, `orchestrator.sh:226-329`) has no post hook at all.

2. **The "fewer subagents" benefit is illusory as specified.** `cmd_gates`
   fast-paths only on `grep 'NEW_ISSUES=0'` (`orchestrator.sh:204`), but
   `finish_gate` emits `RESOLVED:`/`PENDING`, never `NEW_ISSUES=0`
   (`gate-script-lib.sh:56-77`). Confirmed: `go-version-check.sh` (a clean
   deterministic PASS) is reported PENDING, and `step4:60` says "Launch
   subagents only for PENDING gates" — so every deterministic gate still
   spawns a subagent. v2's "Orchestrator change: None needed" is wrong.

3. **Half the proposed `full-sh` gates would false-FAIL good rebases.**
   `version-consistency.sh:26,31` flags *every* `k8s.io/*` require not
   containing the target version — including `k8s.io/utils` (`v0.0.0-…`),
   `klog/v2`, `kube-openapi`, `sigs.k8s.io/*` — which never track the k8s
   minor. `build-vet.sh:25-39` counts all build/vet lines with no
   base-branch filter. `dep-cve-check.md:49-52` is "always PASS, NEVER
   FAIL." Promoting any of these to a script-writes-FAIL verdict is a
   regression. `feature-gates` needs featuregate-lifecycle knowledge —
   the exact "fragile parser" `future-ideas.md` already deferred.

4. **Post-verification verifies a proxy, not the risk.** `type-conversions`
   judges whether struct fields are *silently dropped at runtime*
   (`type-conversions.md:13-23`); a post-script checking field *counts*
   confirms arithmetic, not the mapping — and a benign count mismatch
   (AI discussing only changed fields) flips a good PASS to FAIL.

5. **The override path is lossy and non-idempotent.** `write-gate-report.sh`
   does a truncating rewrite (`:25-36`); `finish_post_gate` appends POST_
   lines then calls it on override, destroying both the POST_ section and
   the AI's reasoning — contradicting v2's own preservation rationale — and
   dropping the `POST_VERIFIED` guard so the post-script re-runs once.

6. **Refuted:** v2's scariest claim (timeout → SIGTERM → exit 143 → false
   FAIL clobber) does not reproduce. The inherited EXIT trap sees
   `exit_code=0` on SIGTERM across three variants, so no FAIL is written.
   The real trap risk is narrower: an unguarded `((n++))`/empty `grep`
   under `set -e` aborts (exit 1) → trap → false FAIL.

## Design principles

1. **Evidence flows into the prompt, not verification after the AI.**
   The right fix for "AI guesses a count wrong" is to *hand it the count*,
   not to re-check its guess. A pre-script computes ground truth and the
   subagent must reason from it. This deletes the entire `.post.sh`
   override layer and every bug it carried (proxy checks, prose-parsing,
   report clobbering, false overrides, idempotency).

2. **A script may decide only what it can decide soundly.** "Can compute
   the inputs" ≠ "can decide the verdict." A gate is deterministic *only*
   when its predicate is mechanically sound with near-zero false-FAIL rate
   on real repos. Everything else is a judgment gate.

3. **Type is emergent, not declared.** No taxonomy of gate types. The
   orchestrator reacts to what a script *produced*: a report → resolved; an
   evidence file → hand it to a subagent; nothing → pure AI gate. Adding a
   script to a gate changes its behavior with zero orchestrator config.

4. **One execution path for all steps.** `orchestrator.sh gates <step>` is
   the single entry point for every step's gate phase. Deterministic gates
   resolve with no subagent everywhere; judgment gates get a subagent with
   pre-computed evidence. Steps 1-3 stop hand-rolling script execution.

5. **The court is the semantic backstop.** No script verifies AI judgment
   substance — only coverage. Semantic correctness is caught by the
   adversarial court, whose jurors currently use their tools 0/15
   (step-isolation §6). Fixing that dominates any post-verification scheme.

## Target architecture

### Two gate shapes (emergent, not labeled)

**Deterministic gate** — a companion `.sh` fully decides the verdict and
writes the report. No subagent. Used only where the predicate is sound.
Two flavors, both script-authored:
- *decide*: PASS/FAIL from a mechanical predicate (`finish_deterministic`).
- *info*: always PASS, findings recorded for a follow-up (`finish_info`).

**Judgment gate** — an AI subagent decides. A companion `.sh` is *optional*
and, when present, writes an **evidence file** (not a report) via
`finish_evidence`: the enumerated work-items (structs + field lists, fix
commits, changed functions, candidate deprecations) and any ground-truth
numbers. The subagent reads the evidence, reasons from it, and writes a
**structured per-item report** (one verdict line per enumerated item, each
with a `file:line` citation). A gate with no `.sh` is a pure judgment gate.

The orchestrator never needs to know which shape a gate is. After running
the companion it re-checks disk: report present → resolved; evidence
present → PENDING with the evidence path; neither → PENDING (pure AI).

### Anti-satisficing stack (replaces post-verification override)

The genuine risk — "AI writes PASS without checking" — is addressed in
three sound layers, none of which can produce a false FAIL:

1. **Enumerate + inject.** The pre-script lists every item the AI must
   account for and its ground-truth facts, injected into the prompt. The
   AI cannot hallucinate field counts it was handed.
2. **Structured per-item report.** The report contract requires one line
   per enumerated item with a citation. Satisficing on N items now
   requires fabricating N citations, not one blanket "looks good."
3. **Advisory coverage check (optional, later).** A generic script confirms
   the report addresses every enumerated item. On a gap it **WARNs** —
   annotates the report and flags the court juror. It **never overrides**
   a verdict, because a coverage gap can be legitimate.

### Library API (`gate-script-lib.sh`)

```bash
inc() {                       # safe counter — never returns nonzero
  local var="${1:-NEW_ISSUES}"
  printf -v "$var" '%d' "$(( ${!var} + 1 ))"
}

finish_deterministic() {      # script decides PASS/FAIL, writes report
  local issues="${1:?}" summary="${2:-}"; shift 2 2>/dev/null || true
  local verdict=PASS; [[ "$issues" -gt 0 ]] && verdict=FAIL
  bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" "$verdict" "$issues" "$summary" "$@"
  echo "RESOLVED: $GATE_NAME $verdict"
  trap - EXIT; exit 0
}

finish_info() {               # always PASS; findings recorded, never block
  local summary="${1:-}"; shift 2>/dev/null || true
  bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$summary" "$@"
  echo "RESOLVED: $GATE_NAME PASS (informational)"
  trap - EXIT; exit 0
}

finish_evidence() {           # judgment gate: write evidence, defer to AI
  local summary="${1:-}"; shift 2>/dev/null || true
  local ev="$REPO/.rebase-tmp/gates/${GATE_NAME}.evidence"
  { echo "SUMMARY: $summary"; printf '%s\n' "$@"; } > "$ev"
  echo "PENDING: $GATE_NAME"
  echo "EVIDENCE: $ev"
  trap - EXIT; exit 0
}
```

`inc` eliminates the `set -e` + `((n++))` footgun class (assignment never
exits nonzero — the crash-safety EXIT trap stays for genuine crashes). The
existing `finish_gate` is kept during migration, then removed once callers
move to `finish_deterministic`/`finish_evidence`.

### Orchestrator change (the one real fix)

Replace the stdout grep with a disk re-check — robust for every finish
variant and backward-compatible:

```bash
# In cmd_gates, after running the companion:
timeout "${GATE_TIMEOUT:-300}" bash "$companion" "$repo" 2>&1 || true
if report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then
  verdict=$(grep '^VERDICT:' "$rpt" | awk '{print $2}')
  echo "RESOLVED: $gate_name $verdict"; ((resolved++)) || true; continue
fi
# no fresh report → judgment gate; surface evidence path if written
ev="$repo/.rebase-tmp/gates/${gate_name}.evidence"
[[ -f "$ev" ]] && echo "EVIDENCE: $ev"
echo "PENDING: $gate_name"; ((pending++)) || true
```

Then make **every** step file call `orchestrator.sh gates <step>` first and
launch subagents only for PENDING gates (steps 1-3 gain what step 4 has).
Each PENDING subagent prompt includes the `EVIDENCE:` file path. Gate `.md`
files for judgment gates drop their "MANDATORY FIRST STEP" script block and
instead say "Read the evidence file; judge only flagged items; write a
per-item report."

## Gate taxonomy (33 → 32; one dropped)

**Deterministic-decide (8)** — sound predicate, script writes verdict:
`build-vet`†, `test-compilation`†, `autofix-result`, `major-version-imports`,
`patterns-completeness`, `build-vet-recheck`†, `cleanliness`,
`go-version-check`.  († = add a base-branch pre-existing filter before the
script is allowed to write FAIL; without it they false-FAIL on pre-existing
breakage.)

**Deterministic-info / always-PASS (5)** — record findings, never block:
`dep-cve-check`, `dep-release-notes`, `maintainer-review`,
`skill-improvement`, `commit-messages`.  (Commit-message *format* is
mechanically checkable; the sub-component-name judgment is not — keep info.)

**Judgment + evidence (18)** — pre-script enumerates, AI decides from cited
evidence: `rebase-completeness`, `version-consistency`⚠, `diff-scope`,
`type-conversions`, `fix-correctness`, `deprecated-calls`, `feature-gates`⚠,
`crd-validation`, `e2e-infra`, `autofix-diff-review`,
`deprecated-api-remnants`, `deprecated-imports`, `version-completeness`,
`gomod-diff-analysis`, `ci-readiness`, `correctness`, `ci-prediction`,
`k8s-changelog`, `logical-consistency`.  (⚠ = v2 wrongly marked full-sh;
these MUST stay judgment — see findings 3-4. That is 19 names; `ci-readiness`
folds into `ci-prediction` in consolidation, → 18.)

**Dropped (1):** `logical-completeness` — strict subset of
`logical-consistency` (step-isolation §8).

Note: "type is emergent" means this table is documentation, not config. A
gate becomes deterministic the day someone adds a sound `.sh`; nothing else
changes.

## Migration sequence

Ordered by risk. Each phase ships independently and leaves the skill
working. Phases 0-1 are the highest-value, lowest-risk wins.

**Phase 0 — Orchestrator + lib fixes (zero behavior change).**
Disk re-check in `cmd_gates` (finding 2); add `inc`; keep `finish_gate`.
After this, deterministic gates that already exist stop spawning
redundant step-4 subagents. Pure fix, no new scripts.

**Phase 1 — Deterministic-decide, the safe subset.**
Add `finish_deterministic` + `finish_info`. Convert only the sound gates:
`major-version-imports`, `cleanliness`, `autofix-result`, `go-version-check`
(already base-filtered). Add base filters to `build-vet`/`build-vet-recheck`/
`test-compilation`, *then* convert. Mark the 5 informational gates with
`finish_info`. Do **not** touch `version-consistency`/`feature-gates`.

**Phase 2 — Unify execution.**
Steps 1-3 call `orchestrator.sh gates <step>` first, mirroring step 4.
Deterministic gates now resolve with zero subagents across all steps —
this is where the real subagent-count reduction lands.

**Phase 3 — Evidence-in for judgment gates.**
Add `finish_evidence` + the evidence-file convention. Convert judgment
gates highest-value first: `version-consistency` (list every k8s.io module
with its version and whether it is a staging/lockstep module vs
independent), `type-conversions` (enumerate changed structs + full field
lists as a checklist), `feature-gates` (list refs + vendor presence).
Update those gate `.md` files to read evidence and emit per-item reports.

**Phase 4 — Advisory coverage + court fix.**
Formalize the structured report contract. Add one generic coverage check
(WARN-only, flags the court juror; never overrides). Force juror tool use
(step-isolation §6) — the actual semantic backstop.

**Phase 5 — Consolidation.**
Drop `logical-completeness`; fold `ci-readiness` into `ci-prediction`;
narrow `deprecated-api-remnants` to web-search discovery (step-isolation §8).

## What v3 rejects from v2, and why

| v2 element | Rejected because |
|------------|------------------|
| Four gate types | Two independent booleans (has-script? decides-or-defers?). v3 makes type emergent — no labels to memorize. |
| `.post.sh` override | Verifies proxies not risks (finding 4); barely runs (finding 1); lossy + non-idempotent (finding 5); can false-FAIL. Replaced by evidence-in + advisory coverage. |
| `init_post_gate`/`post_check`/`finish_post_gate` | Machinery for the rejected override. `finish_evidence` replaces the useful half. |
| "Orchestrator change: None needed" | Wrong (finding 2). The disk re-check IS the required change. |
| `version-consistency`/`feature-gates`/`dep-cve-check` → full-sh | False-FAIL good rebases / are always-PASS (finding 3). |
| Grep `NEW_ISSUES=0` fast-path | Never matched `finish_gate` output. Replaced by disk re-check. |

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Base-filter bugs in newly-deterministic gates | Medium | Convert only after the filter is tested; run against a repo with known pre-existing breakage before promoting. |
| Evidence file goes stale after a fix commit | Low | Judgment pre-scripts re-run each `gates` call (no report to short-circuit them) → evidence regenerates at current HEAD. Gate on evidence freshness if it proves costly. |
| Step 1-3 unification breaks the fresh-context model | Low | Deterministic gates need no context; judgment gates still get isolated subagents. No change to isolation. |
| Advisory coverage ignored by the agent | Low | It flags the court juror, not just the agent; court is the enforcement point. |
| Migration half-done leaves mixed conventions | Low | `cmd_gates` disk re-check handles `finish_gate`, `finish_deterministic`, and `finish_evidence` simultaneously — old and new coexist. |

## Success criteria

- Deterministic gates spawn zero subagents in **all** steps (measure
  subagent count per run before/after Phase 2).
- Zero false-FAIL regressions on the test matrix vs current pass rate
  (spec=all 95%, spec=none 100% — next-work.md). Any per-repo drop >5pp
  blocks the phase.
- No gate can transition PASS→FAIL by script action except a
  Deterministic-decide gate on its own sound predicate.
- Court jurors use their tools (git show/diff/Read) on every run —
  the semantic check post-verification could never soundly provide.

## Relation to other plans

- **gate-architecture-v2.md:** superseded. Kept as the record of the
  design that adversarial review rejected.
- **step-isolation-and-generality.md:** v3 extends the three-tier model
  (§4.4) but collapses it to two emergent shapes; adopts the §6 juror
  tool-use fix as Phase 4.
- **future-ideas.md:** vindicates the feature-gate "fragile parser"
  deferral — `feature-gates` stays a judgment gate.
- **next-work.md:** subsumes "companion script migration" and "gate
  consolidation 33 → 31."

<!-- Budget: 300 lines. Currently ~300. -->
