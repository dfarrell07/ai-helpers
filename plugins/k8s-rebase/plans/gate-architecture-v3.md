# Gate Architecture v3: Scripts That Make Gate Subagents Better

**STATUS: PLANNED.** Supersedes gate-architecture-v2.md.

## Design intent (the north star)

Companion scripts exist to make the gate **subagents** more **robust, reliable,
correct, and general** — by handing them deterministic *evidence* (facts they'd
otherwise guess) and by removing the provably-clean case from their plate. **The
subagent remains the judge.** A script's job is to ground and sharpen the AI's
verdict, not to replace it.

This is the lesson from two prior rounds of adversarial review. v2 tried to make
scripts *the authority* (a `.post.sh` that overrode the AI's verdict); the first
v3 draft leaned the same way (a `deterministic` shape whose script writes FAIL).
Both invert the intent, and both import the one failure mode a rebase can least
afford: a script that **false-FAILs a good rebase** (or, worse, **false-PASSes a
real regression** it wasn't sound enough to see). When the script instead *feeds*
the subagent, that risk moves back to the judge that can actually reason about it.

So the spine of v3 is **evidence-in**: scripts compute ground truth and inject it;
the subagent decides. Scripts write a verdict on their own only as a narrow,
fixture-proven exception — never by default.

## What the verification found (v2's defects — all re-confirmed against the code)

Empirical checks (bash 5.2) and line-level tracing of the live orchestrator, lib,
gate `.md`/`.sh`, and step files.

1. **`cmd_gates` is step-4-only.** `orchestrator.sh gates` is invoked in exactly
   one place: `step4-verification.md:58`. Steps 1-3 launch one subagent per gate
   `.md`; the **6** gates with a companion `.sh` (`build-vet`,
   `version-consistency`, `crd-validation`, `major-version-imports`,
   `patterns-completeness`, `go-version-check`) self-run it via a "MANDATORY FIRST
   STEP" block. So v2's `cmd_gates`-wired `.post.sh` override reached only step 4,
   and `cmd_advance` (`:226-329`) has no post hook at all.

2. **The "fewer subagents" benefit was illusory.** `cmd_gates` fast-paths only on
   `grep 'NEW_ISSUES=0'` (`:204`), but `finish_gate` emits `RESOLVED:`/`PENDING`,
   never that literal (`gate-script-lib.sh:56-77`). Reproduced: a clean PASS is
   labeled PENDING on the first `gates` call, so `step4:59` ("launch subagents only
   for PENDING") spawns a redundant subagent; it self-heals next call via the disk
   pre-check (`:192`). v2's "Orchestrator change: None needed" was wrong.

3. **A script-as-authority false-FAILs good rebases.** `version-consistency.sh:26`
   flags every `k8s.io/*` require whose version lacks the target substring, and its
   feed loop (`:31`, `grep 'k8s.io/'`) matches `sigs.k8s.io/` as a substring — so
   `k8s.io/utils`, `klog/v2`, `kube-openapi`, and all `sigs.k8s.io/*` get flagged
   though none track the k8s minor. It is only latent today because the script ends
   in `finish_gate` (`:44`), which *defers* to the AI instead of writing FAIL.
   Promoting it to write FAIL is a regression. This is the canonical argument for
   evidence-in over script-verdicts.

4. **Post-verification checks a proxy, not the risk.** `type-conversions`
   (`type-conversions.md:13-23`) judges whether struct fields are *silently
   dropped at runtime*; a post-script counting fields confirms arithmetic, not
   mapping, and a benign count mismatch flips a good PASS to FAIL.

5. **v2's override path was lossy** — `write-gate-report.sh` truncates on rewrite
   (`:25-36`), destroying the AI's reasoning it claimed to preserve.

6. **Refuted:** v2's SIGTERM→exit-143→false-FAIL claim doesn't reproduce (the EXIT
   trap sees `exit_code=0` on SIGTERM). The real trap risk is narrower: an
   unguarded `((n++))`/empty `grep` under `set -e` aborts (exit 1) → trap → false
   report.

## Corrections carried in from the v3 self-reviews (don't re-litigate)

- **A crash must write no verdict — not FAIL, not a bespoke ERROR.** `_gate_trap`
  (`gate-script-lib.sh:18-27`) writes `VERDICT: FAIL` on any nonzero exit, so a
  crashing script masquerades as a real failure. A rejected earlier draft had the
  trap write `VERDICT: ERROR` and hold it in `cmd_gates`; that was **broken** —
  `report_has_verdict` (`:117-120`) matches only `PASS|FAIL|SKIP`, so the branch
  was dead code, and `cmd_advance` (`:251`) bucketed ERROR as `missing` and
  force-advanced after 3 attempts (`:293`). **The fix is simpler: the trap writes
  no report**, so the gate falls through to the normal no-report → PENDING →
  subagent path. See Phase 0 for the observability that must ship *with* it.
- **Base-filter reality:** `crd-validation.sh`/`patterns-completeness.sh` already
  compute and *use* a base filter (`git show $BASE:` / `git diff $BASE..HEAD`);
  `build-vet.sh`/`version-consistency.sh` compute `BASE` via `init_gate` but never
  filter with it. (verified)
- **Convention over declaration.** step-isolation §4.4 already chose to *defer*
  YAML frontmatter and discover behavior by convention. v3 keeps that: a gate's
  shape is simply **which lib function its script calls** — no `shape:` frontmatter
  and no bespoke linter to police it. A 3-line grep test can assert "every
  companion calls exactly one `finish_*`" if we want a guard at all.
- **inc** is unsafe under `set -u` for an uninitialized counter (`${!var}` on an
  unbound name aborts); guard `${!var:-0}` (a bashism — companions are bash, fine).

## Design principles

1. **Scripts serve the subagent.** The default script output is *evidence* +
   `PENDING` (defer to the subagent), or a fast-path *PASS* when — and only when —
   the script can soundly prove the clean case. The subagent judges everything
   else, grounded in the script's facts.
2. **A script writes a blocking verdict only as a fixture-proven exception.** Not
   by default. It must pass a fixture test showing **zero false-FAIL AND zero
   false-PASS** on a repo with known pre-existing/cross-file breakage, and the
   predicate must generalize across repos and k8s versions. Today, zero gates
   qualify without that test.
3. **A crash is never a verdict.** Infra failure writes no report → the gate
   degrades to the subagent path, exactly like a companion-less gate. It is made
   observable (Phase 0), never silent.
4. **Evidence must be fresh or it grounds the subagent in lies.** Every evidence
   artifact is HEAD-stamped, freshness-checked, and cleaned on init — the same
   discipline reports already get. Stale evidence is worse than none: it turns a
   grounding fact into a confident hallucination.
5. **Generality beats cleverness.** Derive facts at runtime (e.g. staging-module
   classification from `k8s.io/kubernetes`'s `go.mod` `replace` set at the target
   tag) rather than hardcoding lists or extension allow-lists that rot or
   false-flag legitimate files. Prefer evidence the subagent can reason over to a
   brittle predicate the script commits to.
6. **Be honest about what each layer catches.** Evidence-in closes *hallucination*
   (the AI guessing a fact). It does **not** close *satisficing* (the AI not
   looking). Satisficing is caught at test time by the court; in production it is
   currently *not* directly caught (human + CI miss silent semantic drops). See
   "Production backstop" for the open decision.

## Shapes (by convention — which `finish_*` the script calls)

- **evidence** (`finish_evidence`) — **the primary, general mode.** The script
  computes ground-truth facts and writes an evidence file; it *always* defers to
  the subagent (even when it flagged nothing), because it has no sound clean
  predicate. Use when the script can *inform* but not *decide* — e.g.
  `version-consistency` (classify each module; the subagent judges independent-
  module drift the script can't soundly call).
- **filter** (`finish_filter`) — evidence **plus** a sound clean predicate, so it
  may fast-path PASS with no subagent on the provably-clean case; the dirty case
  writes evidence and defers. A cost optimization layered on `evidence`. Use only
  where "script sees zero" genuinely means clean (e.g. `crd-validation`,
  `patterns-completeness`, which already base-filter to changed items).
- **info** (`finish_info`) — always PASS, non-blocking; findings recorded for
  follow-up. Note a distinction no linter can see and that a maintainer must not
  "promote": some info gates are *inherently* non-computable (`maintainer-review`);
  others are *computable but non-blocking by policy* (`dep-cve-check` — CVE noise
  must never block a rebase). Record which, and why, in the gate `.md`.
- **verdict** (`finish_deterministic`) — the narrow exception of principle 2: the
  script writes PASS/FAIL and skips the subagent. Permitted **only** after the
  Phase-3 fixture test proves it for that specific gate. Not a starting shape.

### Library API (`gate-script-lib.sh`)

```bash
inc() {                       # safe counter — never returns nonzero, safe under set -u
  local var="${1:-NEW_ISSUES}"                          # bashism (companions are bash)
  printf -v "$var" '%d' "$(( ${!var:-0} + 1 ))"
}

_gate_trap() {                # a crash writes NO report — it degrades to the subagent path
  local exit_code=$?
  [[ $exit_code -eq 0 ]] && return 0
  if [[ -n "${REPO:-}" && -n "${GATE_NAME:-}" ]]; then
    mkdir -p "$REPO/.rebase-tmp/gates"
    printf 'CRASH: exit %s at %s\n' "$exit_code" "${BASH_SOURCE[1]:-unknown}" \
      > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"     # observable breadcrumb (Phase 0 wires a reader)
  fi
  echo "CRASH: ${GATE_NAME:-?} (exit $exit_code) — no report; deferring to subagent"
}

_head_sha() { git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown; }

_write_evidence() {           # atomic + HEAD-stamped so it can be freshness-checked
  local summary="$1"; shift
  mkdir -p "$REPO/.rebase-tmp/gates"
  local ev="$REPO/.rebase-tmp/gates/${GATE_NAME}.evidence"   # GATE_NAME is already step-prefixed
  { echo "HEAD: $(_head_sha)"; echo "SUMMARY: $summary"; printf '%s\n' "$@"; } \
    > "$ev.tmp" && mv "$ev.tmp" "$ev"
  echo "PENDING: $GATE_NAME"; echo "EVIDENCE: $ev"
}

finish_evidence() {           # primary mode: inject facts, ALWAYS defer to the subagent
  local summary="${1:-}"; shift 2>/dev/null || true
  _write_evidence "$summary" "$@"; trap - EXIT; exit 0
}

finish_filter() {             # evidence + sound clean predicate: clean → PASS (no subagent)
  local issues="${1:?}" summary="${2:-}"; shift 2 2>/dev/null || true
  if [[ "$issues" -eq 0 ]]; then
    bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$summary" "$@"
    echo "RESOLVED: $GATE_NAME PASS"
  else
    _write_evidence "$summary" "$@"
  fi
  trap - EXIT; exit 0
}

finish_info() {               # always PASS; findings recorded, never block
  local summary="${1:-}"; shift 2>/dev/null || true
  bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$summary" "$@"
  echo "RESOLVED: $GATE_NAME PASS (informational)"; trap - EXIT; exit 0
}

finish_deterministic() {      # EXCEPTION (principle 2): only for a fixture-proven gate
  local issues="${1:?}" summary="${2:-}"; shift 2 2>/dev/null || true
  local verdict=PASS; [[ "$issues" -gt 0 ]] && verdict=FAIL
  bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" "$verdict" "$issues" "$summary" "$@"
  echo "RESOLVED: $GATE_NAME $verdict"; trap - EXIT; exit 0
}
```

`inc` fixes the `((n++))`-returns-1-at-0 footgun. `_gate_trap` no longer touches
`write-gate-report.sh`, so its allow-list (`:21`) is unchanged. `finish_gate` is
kept during migration, then removed once callers move to `finish_evidence`/
`finish_filter`.

### Orchestrator change

Replace the stdout grep (finding 2) with a disk re-check; add `evidence_path()`
mirroring `report_path()`, and **freshness-gate the evidence** so a stale file is
ignored, not injected:

```bash
evidence_path() { local r="$1" sd="$2" g="$3"; echo "$r/.rebase-tmp/gates/${sd%-*}-${g}.evidence"; }

# In cmd_gates, after the top-of-loop fresh-report short-circuit:
[[ -x "$companion" ]] && timeout "${GATE_TIMEOUT:-300}" bash "$companion" "$repo" 2>&1 || true
if report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then
  local verdict; verdict=$(grep '^VERDICT:' "$rpt" | awk '{print $2}')
  echo "RESOLVED: $gate_name $verdict"; ((resolved++)) || true; continue
fi
ev=$(evidence_path "$repo" "$sd" "$gate_name")
if [[ -f "$ev" ]] && report_is_fresh "$ev" "$repo"; then echo "EVIDENCE: $ev"; fi
echo "PENDING: $gate_name"; ((pending++)) || true
```

`report_is_fresh` (`:122-133`) already parses a `HEAD:` line, so it works on the
now-stamped evidence file unchanged. **`cmd_init` must also clean `*.evidence` and
`*.crash`**, not just `*.report` (`:151`) — otherwise a stale evidence file from a
prior HEAD survives a re-init and grounds the subagent in old facts.

A crashed companion writes no report, lands here as PENDING, and the step launches
a subagent for it — the same path a companion-less gate takes. It can never
fabricate a FAIL, and it is visible via the `.crash` breadcrumb (Phase 0 wires the
harness to read it) and the `CRASH:` stdout line. If the subagent also can't
resolve it, the existing 3-attempt force-advance (→ INCOMPLETE marker → `--draft`
PR) applies — the accepted backstop for any stuck gate.

## Gate map (33 today; → 31, subject to Phase 5 reconciliation)

Shape below is the *target convention*, not a declaration. Verified: 33 gate
`.md`, 6 companions, 15 `.md` carry a MANDATORY block.

- **evidence (inject facts, always defer):** `version-consistency` (runtime module
  classification), `feature-gates` (refs + vendor symbol presence),
  `rebase-completeness`, `type-conversions`, `fix-correctness`, `correctness`,
  `deprecated-calls`, `deprecated-api-remnants`, `deprecated-imports`,
  `gomod-diff-analysis`, `ci-prediction`, `k8s-changelog`, `logical-consistency`,
  `autofix-diff-review`, `version-completeness`, `e2e-infra`. These are where "make
  the subagent more correct/general" pays off; several currently have no companion
  and would gain a small evidence pre-script.
- **filter (evidence + sound clean-PASS fast-path):** `crd-validation`,
  `patterns-completeness` (already base-filter), `build-vet`, `build-vet-recheck`,
  `test-compilation`, `autofix-result` — where a clean compile/diff genuinely means
  clean. Note the base filter here is *evidence the subagent weighs*: an unmodified
  file that now fails to compile because a k8s API changed is a real regression,
  and only the subagent (not a file-modified heuristic) can call that — so these
  stay filter/evidence, never `deterministic`, unless a fixture test proves the
  predicate sound for cross-file breakage.
- **info (always PASS, non-blocking):** `dep-cve-check` (computable, policy
  non-block), `dep-release-notes`, `maintainer-review` (non-computable),
  `skill-improvement`, `commit-messages`.
- **verdict candidates (only if Phase 3 fixture-proves them):** `major-version-imports`,
  `go-version-check`. Everything else that a script *could* mechanize —
  `diff-scope` (extension allow-list false-FAILs legit `.txt`/`.json`/`.proto`
  testdata), `cleanliness` (`find -user root` is environment-dependent; its `.md`
  says "run on the host, not a container") — is **evidence/filter**, because the
  predicate isn't general.
- **Dropped/folded:** `logical-completeness` → `logical-consistency`;
  `ci-readiness` → `ci-prediction`.

**Consolidation state (corrected — this was wrong before):** the gate merge is
**0% done**. All 33 gates are live; all three merge targets
(`logical-completeness`, `ci-readiness`, `commit-messages`) still exist.
`autofix-patterns-redesign.md`'s "COMPLETE" refers to the *autofix* refactor; its
gate consolidation (33→30) is filed under "Opportunities identified (future
work)." v3 (→31) and that plan (→30) differ only on the contested
`commit-messages` → `maintainer-review` merge. Reconcile in Phase 5; do not
hardcode a count.

## Migration sequence

Bump `plugin.json` + run `make lint && make update` once per landed PR (not per
phase — intermediate bumps are dead weight on a single branch).

**Phase 0 — Mechanical patch (ship first; this is the whole patch).**
(a) `inc` with the `${!var:-0}` guard. (b) `_gate_trap` writes a `.crash`
breadcrumb + `CRASH:` line instead of a FAIL report — removes the
crash→false-FAIL class today. (c) `cmd_gates` disk re-check + freshness-gated
`evidence_path()`; `cmd_init` cleans `*.evidence`/`*.crash`. (d) **A ~5-line
harness reader**: `test-skill.sh`'s tally must surface any `*.crash` as an infra
error distinct from "missing gate" — otherwise dropping crash→FAIL trades a named
signal (`gfail>0`, "failed [name]") for an anonymous "missing N," and an infra
crash becomes invisible. (d) ships in the same PR as (b); without it the crash is
silent, which is worse than today.

**Phase 1 — Fix the court, then measure the RIGHT thing (decision gate).**
Two *separable* pieces:
- *The decision metric.* The go/no-go for Phases 2-5's evidence rollout is **court
  verdict / false-FAIL rate on the post-`pr-feedback-resolution` stripping
  baseline**, computed from `results.tsv` (which the harness already writes) — NOT
  subagent count. Subagent count measures cost, not the subagent-reliability the
  whole plan is about; wiring the decision to it would answer the wrong question.
- *Court juror tool use (research, not a 5-line edit).* Jurors are already granted
  tools and prompted to verify, yet 0/15 call one (step-isolation §6). Forcing an
  LLM to use a tool is prompt engineering with uncertain yield; budget it as
  research. It improves the *measurement's* trustworthiness but does not gate the
  next phase.
Decision: after the Stop-hook fix (91% step adherence) and the stripping rewrite,
does subagent verdict *reliability* still bind? Note the mixed baseline — spec=none
(production) is 100% (3/3, tiny sample), overnight 24/24, spec=all 95% (20/21), but
per-version 1.35.3 = 12% is a live blocker. So "mostly healthy with a
version-specific hole," not "solved." If it no longer binds, stop after Phase 0.

**Phase 2 — Evidence-in rollout (the actual value; only if Phase 1 says it binds).**
Make scripts feed subagents. First adopt the lib in the 6 gates that already have
companions: `crd-validation`/`patterns-completeness` → `finish_filter` (they must
first `source gate-script-lib.sh`; they currently roll their own BASE + report
writing, so this is more than a rename); `build-vet` → `finish_filter`;
`version-consistency`/`feature-gates` → `finish_evidence` with **runtime-derived**
module classification (from `k8s.io/kubernetes`'s `go.mod` `replace` set at the
target tag — one sourced helper, replacing the duplicated logic in
`next-work.md:14-28`, not a hardcoded list). Then author small evidence
pre-scripts for the highest-value judgment gates (`type-conversions`,
`fix-correctness`, `rebase-completeness`). Coupling: any gate whose companion
starts emitting `RESOLVED:`/`EVIDENCE:` must have its `.md` MANDATORY block updated
in the *same commit*, and its `.md` must **retain full judgment prose** (the
subagent still reads it — for a crash fallback and for the dirty path).

**Phase 3 — Fixture test + narrow verdict exceptions.**
Build the fixture harness (reusing the `.repos` clone scaffolding; today only
end-to-end + court exist, so this is a new target): run a single gate against a
repo with **known pre-existing and cross-file breakage** and assert **zero
false-FAIL and zero false-PASS**. Only a gate that passes may move to
`finish_deterministic`. Expect this to admit very few (likely just
`major-version-imports`, `go-version-check`) — and only if their base filters
survive the cross-file case. If a gate can't prove it, it stays evidence/filter.
This is the *unconditional* safety gate for any script-written FAIL.

**Phase 4 — Unify execution.**
Steps 1-3 call `orchestrator.sh gates <step>` first, mirroring step 4, so evidence
surfacing (`EVIDENCE:`) works for the step-2/3 gates too (today `cmd_gates` runs
only in step 4, so the Phase-0 evidence machinery is inert for `version-consistency`
/`feature-gates` until this lands). ~20 files: 15 MANDATORY blocks + inconsistent
step spawn conventions. Atomic per gate: add the `gates` call while keeping the
idempotent MANDATORY block → verify `cmd_gates` output matches what the step tells
the agent to launch → drop the block only after the companion is confirmed to write
a report/evidence.

**Phase 5 — Consolidation.**
Re-audit live state (it is 0% done). Reconcile the count across
`autofix-patterns-redesign.md` and `next-work.md`. Drop `logical-completeness`;
fold `ci-readiness` → `ci-prediction`; decide the contested `commit-messages` →
`maintainer-review` merge; narrow `deprecated-api-remnants` to web-search discovery
(step-isolation §8). Keep the harness in lockstep: `EXPECTED_GATES` is dynamic
(`test-skill.sh:139`) so a count drop auto-adjusts, but `INFO_GATES` (`:21`,
currently 4 gates) is hardcoded — update it in the same commit if the info set
changes (e.g. adding `dep-release-notes`).

## Production backstop (open decision)

Evidence-in closes hallucination but not satisficing, and the court is
**test-time only** (`test-skill.sh` + its Makefile target + `config-1.35.yaml`;
zero references in `skills/`/`scripts/`/`gates/`/`hooks/`). Human + CI at the PR
boundary *do not* catch a silent semantic drop (a removed struct field that still
compiles and passes unit tests). Being honest about the hole is not a plan for it.
Two cheap options, to decide before shipping the evidence rollout:
- **Promote one adversarial juror to a pre-PR production gate** — a single AI call
  with tool use (git show/diff/Read) run once before the PR command. Trivial
  against a plan whose premise is spending AI calls on quality.
- **Emit a semantic-risk manifest in the draft-PR body** — list the gates that
  were AI-judged-not-machine-verified (`type-conversions`, `k8s-changelog`,
  `logical-consistency`) so the human reviewer is *directed* at the unverified
  surface instead of trusting a green run.

## What v3 rejects from v2, and why

| v2 element | Rejected because |
|------------|------------------|
| `.post.sh` override | Verifies proxies not risks (finding 4); barely runs (finding 1); lossy (finding 5); can false-FAIL. Replaced by evidence-in (subagent stays judge). |
| `init_post_gate`/`post_check`/`finish_post_gate` | Machinery for the rejected override. |
| "Orchestrator change: None needed" | Wrong (finding 2). The disk re-check IS the change. |
| `version-consistency`/`feature-gates`/`dep-cve-check` → full-sh (script writes FAIL) | False-FAILs good rebases / is always-PASS (finding 3). They become evidence/info. |
| Grep `NEW_ISSUES=0` fast-path | Never matched `finish_gate` output. Replaced by disk re-check. |

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Dropping crash→FAIL hides infra crashes | Medium | Phase 0(d) ships the `.crash` harness reader in the same PR as the trap change; a crash is surfaced as a distinct infra error, and the subagent/force-advance path prevents a silent green. |
| Stale evidence injected as ground truth | Medium | HEAD-stamp + `report_is_fresh` gate on evidence; `cmd_init` cleans `*.evidence`/`*.crash`. |
| A `verdict`-shape gate false-FAILs or false-PASSes | High if unguarded | Phase 3 fixture test (zero false-FAIL AND zero false-PASS on cross-file breakage) is the unconditional precondition for `finish_deterministic`. Default is evidence/filter, which can't false-FAIL. |
| Evidence-in doesn't stop satisficing | Medium | Acknowledged; court at test time; "Production backstop" decision for the field. |
| Phase 4 `.md`/step rewrite mis-ordered (15 MANDATORY blocks) | Medium | Atomic per-gate: add `gates` call with block intact → verify → drop block after companion writes report/evidence; retain judgment prose. |
| Cross-plan collision (count; module-class helper; test-skill.sh regions) | Medium | Reconcile in Phase 5 against *live* state; one sourced classification helper; Phase 1 court edit is a different region than pr-feedback's stripping edit but must run against the post-stripping baseline. |

## Success criteria

- Gate **subagents** are measurably more reliable: lower court false-FAIL /
  higher semantic-catch rate on the post-stripping baseline (the Phase-1 metric),
  not a subagent count.
- No script writes a blocking FAIL except a `verdict`-shape gate that passed the
  Phase-3 fixture test. A crash writes no report and is surfaced as infra.
- Evidence files are always fresh (HEAD-stamped, freshness-gated, cleaned on init).
- Zero false-FAIL regressions vs the current pass rate; establish the
  post-`pr-feedback-resolution` baseline before gating on it.
- A production satisficing backstop exists (pre-PR juror or risk-manifest) or is
  explicitly, visibly deferred — not silently absent.

## Relation to other plans

- **gate-architecture-v2.md:** superseded; kept as the record of the rejected
  script-as-authority design.
- **step-isolation-and-generality.md:** v3 keeps §4.4's convention-over-frontmatter
  choice and adopts the §6 juror tool-use fix as Phase 1.
- **future-ideas.md:** vindicates the feature-gate "fragile parser" deferral —
  `feature-gates` is evidence (refs + vendor presence), never a script verdict.
- **pr-feedback-resolution.md:** moves the spec=all baseline (success criteria) and
  shares `test-skill.sh`; sequence Phase 1's measurement after it lands.
- **autofix-patterns-redesign.md / next-work.md:** own the (0%-done) consolidation
  count and the duplicated module-classification logic; reconcile in Phases 2/5.

<!-- Budget: ~400 lines. -->
