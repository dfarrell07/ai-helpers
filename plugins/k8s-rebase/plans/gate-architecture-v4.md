# Gate Architecture v4: Scripts That Make Gate Subagents Better

Supersedes gate-architecture-v3.md. v3 was correct on the design but accumulated
~1400 lines of court-measurement scaffolding that doesn't belong in a skill plan.
v4 keeps the actual improvements: five Phase-0 bug fixes, the evidence transport
redesign, and companion scripts for gates that benefit most.

---

## North star

Companion scripts make gate **subagents** more robust — by handing them deterministic
facts they'd otherwise guess, and by removing the provably-clean case from their plate.
**The subagent remains the judge.** A script informs; it never overrides.

The spine is **evidence-in**: a script computes ground truth, the orchestrator delivers
it to the subagent, and the subagent decides. A script writes a verdict autonomously
only as a fixture-proven exception.

---

## Why not script-as-authority

v2's `.post.sh` override and the first v3 draft's `deterministic`-writes-FAIL shape
both import the worst failure mode: a script that false-FAILs a good rebase, or —
worse, silently — false-PASSes a real regression. Four live code facts anchor the
rejection:

1. **`cmd_gates` runs in one place** — `step4-verification.md:58`. Steps 1-3 launch
   one subagent per gate `.md`; only step 4 uses `cmd_gates`. So a `cmd_gates`-wired
   override is invisible to steps 1-3, and `cmd_advance` has no post-hook at all.

2. **A promoted script false-FAILs good rebases.** `version-consistency.sh:26`
   flags every `k8s.io/*` whose version lacks the target substring; its feed loop
   (`grep 'k8s.io/'`) also matches `sigs.k8s.io/` — so `klog/v2`, `kube-openapi`,
   and all `sigs.k8s.io/*` get flagged though none track the k8s minor. It is latent
   only because `finish_gate` defers to the AI. Promoting it to write FAIL is a
   regression.

3. **Override checked a proxy, not the risk.** `type-conversions` judges whether
   struct fields are *silently dropped at runtime*; a post-script counting fields
   confirms arithmetic, not mapping. A benign count mismatch flips a good PASS to
   FAIL. And `write-gate-report.sh` truncates on rewrite, destroying the AI reasoning
   the override claimed to preserve.

4. **A crash must write no verdict.** `_gate_trap` today writes `VERDICT: FAIL` on
   any nonzero exit — a crashed script masquerades as a real gate failure. Phase 0
   fixes this.

---

## Shapes

A gate's shape is which lib function its companion script calls. Three form a 2×2 over
*(clean action) × (dirty action)*:

- **evidence** (`finish_evidence`) — always defers. Computes facts, lets the subagent
  decide. Cannot false-anything. **Primary mode for all judgment gates.**
- **filter** (`finish_filter`) — evidence + fixture-proven clean predicate: clean →
  autonomous PASS; dirty → evidence + defer. Structurally cannot false-FAIL.
  Use only where "clean" is provable (`go build` exits 0).
- **verdict** (`finish_deterministic`) — writes PASS/FAIL autonomously. Uniquely
  capable of false-FAIL. Permitted only after a fixture test. Not a starting shape.
- **info** (`finish_info`) — always PASS, non-blocking. For inherently non-computable
  gates (`maintainer-review`) or computable-but-policy-nonblocking ones (`dep-cve-check`).

`filter ⊂ verdict` in capability; the split draws the can/cannot-false-FAIL line.

### Library API (`gate-script-lib.sh`)

```bash
inc() {                       # safe counter (0→1 transition is rc=1 under set -e)
  local var="${1:-NEW_ISSUES}"
  printf -v "$var" '%d' "$(( ${!var:-0} + 1 ))"
}

_gate_trap() {                # nonzero exit → .crash breadcrumb, NO verdict
  local exit_code=$?
  [[ $exit_code -eq 0 ]] && return 0
  if [[ -n "${REPO:-}" && -n "${GATE_NAME:-}" ]]; then
    mkdir -p "$REPO/.rebase-tmp/gates"
    printf 'CRASH: exit %s at %s\n' "$exit_code" "${BASH_SOURCE[1]:-unknown}" \
      > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"
  fi
  echo "CRASH: ${GATE_NAME:-?} (exit $exit_code) — no report; deferring to subagent"
}

_head_sha() { git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown; }

_write_evidence() {
  local summary="$1"; shift
  mkdir -p "$REPO/.rebase-tmp/gates"
  local ev="$REPO/.rebase-tmp/gates/${GATE_NAME}.evidence"
  { echo "HEAD: $(_head_sha)"; echo "SUMMARY: $summary"; printf '%s\n' "$@"; } \
    | tee "$ev.tmp"
  mv "$ev.tmp" "$ev"
  echo "PENDING: $GATE_NAME"; echo "EVIDENCE: $ev"
}

finish_evidence()     { local s="${1:-}"; shift 2>/dev/null||true; _write_evidence "$s" "$@"; trap - EXIT; exit 0; }
finish_filter()       { local n="${1:?}" s="${2:-}"; shift 2 2>/dev/null||shift "$#"; if [[ "$n" -eq 0 ]]; then bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$s" "$@"; echo "RESOLVED: $GATE_NAME PASS"; else _write_evidence "$s" "$@"; fi; trap - EXIT; exit 0; }
finish_deterministic(){ local n="${1:?}" s="${2:-}"; shift 2 2>/dev/null||shift "$#"; local v=PASS; [[ "$n" -gt 0 ]] && v=FAIL; bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" "$v" "$n" "$s" "$@"; echo "RESOLVED: $GATE_NAME $v"; trap - EXIT; exit 0; }
finish_info()         { local s="${1:-}"; shift 2>/dev/null||true; bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$s" "$@"; echo "RESOLVED: $GATE_NAME PASS (informational)"; trap - EXIT; exit 0; }
```

Each `finish_*` MUST end with `trap - EXIT; exit 0` — the `_gate_trap` guard is
nonzero-only, so a `finish_*` that falls off the end with rc=1 self-reports a phantom
crash.

---

## Execution model

**The problem.** Today two broken transports coexist:

- *Step-4 path:* `cmd_gates` runs the companion, but that output never reaches the
  gate subagent. The subagent prompt is only "repo path + module safety rule + Read
  gate file" — it never sees the companion output.
- *Steps-1-3 path:* the `.md` MANDATORY block tells the subagent to run the `.sh`
  itself and read its stdout. This doubles the work and re-opens HEAD-drift.

Neither works reliably. The companion output is either discarded (step 4) or re-run
(steps 1-3), not delivered.

**The fix.** Make the orchestrator the single runner across all steps. Companions run
once in the orchestrator; their output lands in an `.evidence` file; subagents read that
file by convention (the gate `.md` names the path literally). One transport, one run.

**Verbatim evidence-block template** — paste into every converted gate `.md`,
substituting only the literal `<prefix>-<gate>` path:

```markdown
EVIDENCE (read before judging): if `.rebase-tmp/gates/<prefix>-<gate>.evidence` exists,
run `git rev-parse HEAD` and compare it to the file's `HEAD:` line.
- Match: Read the file first and treat its `SUMMARY:`/facts as ground truth for this gate.
- Differ or file absent: evidence is stale/missing — judge from scratch using the checks
  below. Do NOT PASS on the strength of absent or stale evidence.
```

**Orchestrator snippet** (replaces the dead `NEW_ISSUES=0` grep at `:204`):

```bash
# 1. Cache hit — fresh verdict already on disk.
if [[ -f "$rpt" ]] && report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then
  echo "EXISTING: $gate_name $(grep '^VERDICT:' "$rpt" | awk '{print $2}')"; ((resolved++)) || true; continue
fi

# 2. Run companion exactly once. Capture rc for crash detection.
rc=0
crash="$repo/.rebase-tmp/gates/${sd%-*}-${gate_name}.crash"
[[ -x "$companion" ]] && { timeout "${GATE_OUTER_TIMEOUT:-900}" bash "$companion" "$repo" 2>&1 || rc=$?; }
(( rc >= 124 )) && printf 'CRASH: exit %s (orchestrator-detected kill)\n' "$rc" > "$crash"

# 3. Companion wrote a fresh verdict (filter/verdict clean path)?
if report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then
  echo "RESOLVED: $gate_name $(grep '^VERDICT:' "$rpt" | awk '{print $2}')"; ((resolved++)) || true; continue
fi

# 4. Evidence file is on disk; subagent reads it by convention.
echo "PENDING: $gate_name"; ((pending++)) || true
```

`((resolved++))`/`((pending++))` carry `|| true` — under `set -euo pipefail`,
`((x++))` returns 1 on the 0→1 transition.

---

## Gate map (33 today)

6 companion `.sh` files exist: `build-vet`, `version-consistency`, `crd-validation`,
`major-version-imports`, `patterns-completeness`, `go-version-check`.

- **evidence:** `version-consistency`, `feature-gates`, `crd-validation`,
  `patterns-completeness`, `rebase-completeness`, `type-conversions`, `fix-correctness`,
  `correctness`, `deprecated-calls`, `deprecated-api-remnants`, `deprecated-imports`,
  `gomod-diff-analysis`, `ci-prediction`, `k8s-changelog`, `logical-consistency`,
  `autofix-diff-review`, `version-completeness`, `e2e-infra`, `dep-release-notes`
- **filter (today runs as evidence until Phase-4 fixture):** `build-vet` only —
  "`go build`/`go vet` exits 0" is the sole provably-sound clean predicate today.
- **info:** `dep-cve-check`, `maintainer-review`, `skill-improvement`, `commit-messages`
- **verdict candidates (fixture-gated):** `major-version-imports`, `go-version-check`
- **Dropped/folded (Phase 5):** `logical-completeness` → `logical-consistency`;
  `ci-readiness` → `ci-prediction`

---

## Migration

Bump `plugin.json` + `make lint && make update` once per landed PR.

---

### Phase 0 — Ship first (independent of everything below)

Five concrete bug fixes in two PRs. Phase 0 is the only phase that cannot wait — it
fixes live bugs that affect every rebase today.

**(b) `_gate_trap` crash-semantics fix** — co-land with the companion `.md`
crash-safe fallbacks in one PR (P0a):

The trap currently writes `VERDICT: FAIL` on any nonzero exit, so a crashed companion
blocks a good rebase. Replace: write a `.crash` breadcrumb and NO report, so the gate
falls through to the normal PENDING → subagent path.

The orchestrator must capture the companion's exit code (the current `if output=$(...)` form
discards it) so timeout/signal crashes are also visible:

```bash
rc=0; output=$(timeout "$GATE_OUTER_TIMEOUT" bash "$companion" "$repo" 2>&1) || rc=$?
(( rc >= 124 )) && printf 'CRASH: exit %s\n' "$rc" > "$crash"
```

Co-land the companion `.md` crash-safe fallbacks in the same PR — otherwise a crash
after the `_gate_trap` rewrite routes to a subagent whose MANDATORY block re-runs the
crashing companion and finds no matching rule, improvising PASS:

- **Group (i) — widen trigger** in `build-vet.md:17`, `version-consistency.md:17`,
  `major-version-imports.md:16`, `go-version-check.md:16`: from "if the companion
  script is not found" → "if the companion script is not found, **crashes, or emits
  no `NEW_ISSUES` line**"
- **Group (ii) — add new crash branch** to `crd-validation.md` and
  `patterns-completeness.md` (neither has a companion-script fallback today). For
  `crd-validation` the branch must be self-contained — "for each CRD schema file in
  the repository, compare `git show $BASE:<path>` against the working copy and flag
  any newly removed/weakened validation constraint; if `$BASE` is empty, defer without
  a self-comparison."

**(d) `build-vet.sh` inner-tool timeout capture** — live false-PASS today:

`build-vet.sh:23-24` wraps each `go build`/`go vet` as `timeout ... || true`,
swallowing a killed tool to exit 0 → zero error lines → `finish_gate 0` → autonomous
PASS for a build that never completed.

```bash
build_rc=0; build_out=$(timeout "${GATE_TIMEOUT:-300}" go build ./... 2>&1) || build_rc=$?
if (( build_rc >= 124 )); then
  mkdir -p "$REPO/.rebase-tmp/gates"
  printf 'CRASH: exit %s (inner-tool kill)\n' "$build_rc" > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"
  trap - EXIT; exit 0    # defer — NO verdict written
fi
```

**(e) Tier the outer timeout** (P0b — separate PR):

`build-vet.sh:14` loops per module (`find . -name go.mod -not -path '*/vendor/*'`).
With 3 modules and `GATE_TIMEOUT=300`, the inner sum reaches 1800s — the fixed 300s
outer SIGTERMs a healthy companion, forging a spurious crash.

```bash
local _mods; _mods=$(find "$repo" -name go.mod -not -path '*/vendor/*' 2>/dev/null | wc -l)
(( _mods < 1 )) && _mods=1
local GATE_OUTER_TIMEOUT=$(( 2 * ${GATE_TIMEOUT:-300} * _mods ))
```

**(c) `cmd_init` stale-state cleanup** (co-land with P0a):

- `.advance-attempts-step*` and `INCOMPLETE` → clean on FRESH branch only (a stale
  counter surviving re-init triggers premature force-advance at attempts≥3)
- `*.crash` → clean on **both** FRESH and RESUME branches (no HEAD stamp, so
  freshness can't invalidate a stale one)

---

### Phase 1 — Validate before committing to Phase 2

Run `make test` on the core repos before shipping Phase 2. Look at pass rates; if the
skill is already reliable enough, stop here. If it still has correctness gaps, proceed.

No formal measurement gate. The test harness already surfaces pass/fail counts via
`make results`. A human decision suffices for a WIP draft-PR skill.

---

### Phase 2 — Unify execution + wire the single transport

Only if the Phase-1 baseline shows reliability gaps worth closing.

**First:** install `finish_evidence` (add to `gate-script-lib.sh` alongside `finish_gate`
in the same PR that converts the first companion — API-only PR would be dead code).

**Per companion gate, one atomic edit:**

1. Convert companion `finish_gate` → `finish_evidence`. For `crd-validation`/
   `patterns-completeness` (which source no lib today), guard the diff operation:
   `crd-validation.sh:39`'s `crd_diff=$(diff ...)` aborts under the imported `-e`
   when CRD differs (`diff` exits 1). Add `|| true`.

2. Paste the verbatim evidence-block template into the gate `.md` (substituting the
   literal `<prefix>-<gate>` path), keeping the FIRST STEP block for now.

3. Remove the RULE-1 / `NEW_ISSUES=0` fast-path prose — it tells the subagent not to
   judge in exactly the gates being reclassified to keep the judge.

4. Drop the FIRST STEP block. For the 3 companion gates that also carry a base-filter
   block, delete only the FIRST STEP block surgically. For `patterns-completeness`:
   also rewrite the surviving checks header at `:18` from
   `--- Checks (PATH B only — skip entirely if PATH A applies) ---`
   to `--- Checks ---` (same atomic edit — omitting this leaves a dangling conditional
   that tells subagents to skip the checks).

**Per-step wiring** (last companion-conversion PR for that step):

5. **(5a)** Prepend `orchestrator gates <step>` to the step `.md`; **(5b)** replace
   the unconditional "launch all N" instruction with "Launch subagents only for PENDING
   gates." Both must land together — 5a is inert without 5b.
   Designate the "last" companion: `version-consistency` for step 2,
   `patterns-completeness` for step 3.

6. Update the step's gate-fix re-run loop to re-invoke `orchestrator gates <step>`
   before deleting the old report and re-launching — otherwise re-launch judges with
   stale evidence.

7. **(One-time)** Pin the three evidence-path producers: `GATE_NAME` (grep prefix),
   `${sd%-*}` (orchestrator suffix-strip), and the literal path in each `.md`. Add a
   harness assertion that they agree for every step dir with an exact-count check on
   the `EVIDENCE (read before judging):` marker.

**Step 1 is out of scope for per-step wiring** — `rebase-completeness` is the only
step-1 gate and has no companion; its wiring lands in Phase 3 with its companion.

---

### Phase 3 — Evidence content for companion-less gates

Author companion scripts for the judgment gates that would benefit most from
deterministic facts:

- `rebase-completeness.sh` — its five existing counts; must co-land step-1 wiring
  (5a/5b/6 applied to `step1-rebase.md`)
- `feature-gates.sh` — greps `KUBE_FEATURE_`/`SetFromMap` refs + vendor symbol
  presence (zero go.mod logic — different from `version-consistency`)

`fix-correctness` stays pure-judgment — no script can compute "is this fix semantically
correct?" soundly.

For `type-conversions`: the changed conversion sites + vendor struct field list are
deterministic. Add a companion if the gate is frequently wrong; skip if it's already
reliable.

Remove remaining "set PASS immediately / Do NOT run the checks below" rubber-stamp
instructions from any gate that grew one.

---

### Phase 4 — Fixture test → promote `build-vet` to `filter`

Build a fixture harness across the `.repos` corpus (the same repos already cloned for
matrix testing), asserting **zero false-FAIL AND zero false-PASS** on known
pre-existing/cross-file breakage. Required fixtures before any promotion:

- **(a)** Killed-tool case for `build-vet`: SIGKILL a `go build` mid-run → must defer,
  not PASS and not FAIL.
- **(b)** No-base repo for `major-version-imports`/`go-version-check` (empty `BASE`) →
  must degrade to `finish_evidence` and defer.
- **(c)** Multi-module repo with pre-existing inconsistent go directives for
  `go-version-check` → must defer/PASS, not FAIL.

Only after the fixture proves the predicate generalizes does `build-vet` adopt
`finish_filter` and `major-version-imports`/`go-version-check` adopt
`finish_deterministic`. Add `finish_filter`/`finish_deterministic` to the lib in the
same PR as the first promotion (not before — keep the lib free of uncalled functions).

---

### Phase 5 — Consolidation

Re-audit live state. Drop `logical-completeness`; fold `ci-readiness` → `ci-prediction`;
decide `commit-messages` → `maintainer-review` merge. `EXPECTED_GATES` is dynamic
(`test-skill.sh:139`); `INFO_GATES` (`:21`, 4 gates) is hardcoded — update it in the
same commit if the info set changes. Two hardcoded launch lists also drift:
`step3-autofix.md:79` and `step4-verification.md:65-69`. After each drop/fold,
`grep -rn` the name across `skills/` + `gates/`.

---

## Production backstop (lightweight, step 5)

The court is test-time-only. In production, two cheap additions to the step-5 PR body:

1. A **semantic-risk manifest** listing the AI-judged gates (every `evidence` gate +
   any `filter`/`verdict` gate that took its dirty branch) so the human reviewer is
   aimed at the unverified surface. Derive programmatically, not by hardcoding.

2. One **adversarial juror** as a pre-PR gate (a single `claude -p` call with
   git show/diff/Read) — the real backstop, trivial against a plan whose premise is
   spending AI calls on quality.

---

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Evidence file unconsumed (draft's core bug) | High | Single-runner transport; gate `.md` names its own path; freshness-stamped |
| `filter` false-PASS on unsound predicate | High | Phase-4 fixture proof required before any promotion |
| Crash masquerades as FAIL | Medium | Phase-0 `.crash` breadcrumb; no report written |
| Dropping FIRST STEP block strands a companion gate | Medium | Phase-2 atomic edit: `finish_evidence` conversion lands in the same commit |
| Evidence-in amplifies satisficing | Medium | Neutral `SUMMARY:`; remove rubber-stamp instructions; judgment prose stays |
| HEAD drift during step-4's concurrent lint commits | Medium | Consumer freshness-checks the evidence at read time; stale → judge from scratch |
| `evidence` shape raises wall-clock | Low-Med | Accepted; per-gate scripts are fast; build-vet timeout tiering bounds the worst case |

## Success criteria

- Gate subagents are measurably more reliable: higher pass rate on the test matrix.
- The evidence path is wired end to end — every `.evidence` file is read by the
  subagent that judges the gate; no write-only artifacts.
- No script writes a blocking verdict except a `filter`/`verdict` gate that passed
  the fixture test. A crash writes no report and is surfaced as infra.
- Zero false-FAIL regressions vs the current pass rate.

<!-- ~450 lines -->
