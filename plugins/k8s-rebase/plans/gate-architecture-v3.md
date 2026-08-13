# Gate Architecture v3: Scripts That Make Gate Subagents Better

**STATUS: PLANNED.** Supersedes gate-architecture-v2.md.

## Design intent (the north star)

Companion scripts exist to make the gate **subagents** more **robust, reliable,
correct, and general** — by handing them deterministic *evidence* (facts they'd
otherwise guess) and by removing the provably-clean case from their plate. **The
subagent remains the judge.** A script's job is to ground and sharpen the AI's
verdict, not to replace it.

So the spine of v3 is **evidence-in**: a script computes ground truth, the
orchestrator delivers it to the subagent, and the subagent decides. A script
writes a verdict on its own only as a narrow, fixture-proven exception — never by
default.

## Why not script-as-authority

Two prior designs put the *script* in the judge's seat and were rejected. v2 added
a `.post.sh` that overrode the AI's verdict; the first v3 draft added a
`deterministic` shape whose script writes FAIL. Both import the one failure mode a
rebase can least afford: a script that **false-FAILs a good rebase**, or — worse,
because it ships silently — **false-PASSes a real regression** it wasn't sound
enough to see. Four verified facts anchor the rejection (bash 5.2 + line-level
tracing of the live orchestrator, lib, and gate files):

1. **`cmd_gates` runs in one place — `step4-verification.md:58`.** Steps 1-3 launch
   one subagent per gate `.md`; the 6 gates with a companion `.sh` (`build-vet`,
   `version-consistency`, `crd-validation`, `major-version-imports`,
   `patterns-completeness`, `go-version-check`) self-run it via a "MANDATORY FIRST
   STEP" block. So v2's `cmd_gates`-wired override reached only step 4, and
   `cmd_advance` (`:226-329`) has no post hook at all.

2. **A promoted script false-FAILs good rebases.** `version-consistency.sh:26`
   flags every `k8s.io/*` require whose version lacks the target substring, and its
   feed loop (`:31`, `grep 'k8s.io/'`) matches `sigs.k8s.io/` as a substring — so
   `k8s.io/utils`, `klog/v2`, `kube-openapi`, and all `sigs.k8s.io/*` get flagged
   though none track the k8s minor. It is latent only because the script ends in
   `finish_gate` (`:44`), which *defers* to the AI. Making it write FAIL is a
   regression. This is the canonical case for evidence-in.

3. **Override checked a proxy, not the risk, and was lossy.** `type-conversions`
   (`type-conversions.md:13-23`) judges whether struct fields are *silently dropped
   at runtime*; a post-script counting fields confirms arithmetic, not mapping, and
   a benign count mismatch flips a good PASS to FAIL. And `write-gate-report.sh`
   truncates on rewrite (`:25-36`), destroying the AI reasoning the override claimed
   to preserve.

4. **A crash must write no verdict — not FAIL, not a bespoke ERROR.** `_gate_trap`
   (`gate-script-lib.sh:18-27`) writes `VERDICT: FAIL` on any nonzero exit, so a
   crashing script masquerades as a real failure. A rejected variant had the trap
   write `VERDICT: ERROR`; that is dead code — `report_has_verdict` (`:117-120`)
   matches only `PASS|FAIL|SKIP`, so `cmd_advance` (`:251`) buckets ERROR as
   `missing` and force-advances after 3 attempts (`:293`). The fix is simpler: the
   trap writes **no** report, so the gate falls through the normal no-report →
   PENDING → subagent path. But the in-script trap sees only *ordinary* nonzero
   exits: on the common `timeout -s TERM` it sees `exit_code=0` (SIGTERM — verified,
   so timeout does *not* false-FAIL either) and on SIGKILL it does not run at all. So
   the trap closes the non-timeout nonzero-exit class, while *observability* of the
   dominant (timeout/signal) crash must come from the orchestrator — the only layer
   that sees the child's `>128` exit (124 SIGTERM / 137 SIGKILL). See "Execution
   model."

## Design principles

1. **Scripts serve the subagent.** The default script output is *evidence* + defer;
   or a fast-path *verdict* only where the script can soundly prove that outcome.
   The subagent judges everything else, grounded in the script's facts.
2. **Evidence must reach the judge, or it is theater.** The correctness of
   evidence-in depends on a single wired path from script output to the subagent's
   prompt. A file nothing reads is not evidence. (This is the defect the current
   draft's transport had — see "Execution model.")
3. **A script writes an autonomous verdict only as a fixture-proven exception.** Not
   by default. It must pass a fixture test showing **zero false-FAIL AND zero
   false-PASS** on a repo with known pre-existing/cross-file breakage, and the
   predicate must generalize across repos and k8s versions. This binds both a
   `deterministic` FAIL *and* a `filter` clean-PASS — a clean-PASS removes the judge
   exactly as a deterministic PASS does. Today, zero gates qualify without the test.
4. **A crash is never a verdict.** Infra failure writes no report → the gate
   degrades to the subagent path, exactly like a companion-less gate. Made observable
   (Phase 0) — but the in-script trap sees only ordinary nonzero exits; the dominant
   `timeout -s TERM`/SIGKILL crash (exit 0 / no trap) is observable *only* at the
   orchestrator, which writes the breadcrumb on a `>128` child exit. Never silent.
5. **Evidence must be fresh, and consumed at a settled HEAD.** Every artifact is
   HEAD-stamped and freshness-checked (`report_is_fresh:122-133` already does this
   for reports). But note the limit: `step4-verification.md:31-36` runs gates *while
   the main agent commits lint fixes*, so HEAD drifts mid-evaluation and a benign
   commit marks still-valid evidence "stale" → re-run + `stale`-bucket pressure
   (`cmd_advance:256`). Freshness detects drift; it does not create a quiescent
   HEAD. Evidence-in is soundest when a gate's evidence and its verdict share a
   commit — see "Execution model" for how the single-run transport narrows that
   window, and the open question it leaves.
6. **Generality beats cleverness — with a degradation path.** Derive facts at
   runtime (e.g. staging-module classification from `k8s.io/kubernetes`'s `go.mod`
   `replace`-to-`./staging/src/k8s.io/*` set at the target tag — which *includes*
   the v0.MINOR staging modules and *excludes* `k8s.io/utils`, `klog/v2`,
   `kube-openapi`, `sigs.k8s.io/*`, the four the substring grep false-flags) rather
   than hardcoding lists that rot. But `k8s.io/kubernetes` is usually *not* in a
   rebased repo's dep graph, so the fetch can fail (GOPROXY-offline,
   tag-unpublished). Degrade: emit the raw module/version list as evidence with a
   `SUMMARY:` noting classification was unavailable, and defer — never a stale table
   or flag-everything.
7. **Be honest about what each layer catches — evidence-in can *worsen*
   satisficing.** It closes *hallucination* (the AI guessing a fact), not
   *satisficing* (the AI not looking), and a verdict-shaped `SUMMARY:` is an active
   accelerant a lazy judge copies verbatim. Today's blocks institutionalize this:
   `version-consistency.md:10-11` tells the subagent "If NEW_ISSUES=0, set
   verdict=PASS immediately… Do NOT run the checks below" — the script telling the
   judge not to judge. So: (a) evidence states **neutral facts, not a verdict**; (b)
   the rollout **removes the "set PASS immediately / do NOT run the checks below"
   instruction**. Residual satisficing is caught by the court at test time; in
   production it is *not* directly caught — see "Production backstop."

## Shapes (by convention — which `finish_*` the script calls)

A gate's shape is which lib function its script calls — no `shape:` frontmatter, no
bespoke linter (step-isolation §4.4 already chose convention over declaration). The
four shapes are one 2×2 — *(clean action) × (dirty action)* over {write-verdict,
defer} — named for the risk each carries:

- **evidence** (`finish_evidence`) — **the primary, general mode.** Computes facts
  and *always* defers, even when it flagged nothing, because it has no fixture-proven
  clean predicate. Cannot write a verdict, so it cannot false-anything. Use when the
  script can *inform* but not *decide* — `version-consistency`, `feature-gates`,
  and every judgment gate.
- **filter** (`finish_filter`) — evidence **plus** a fixture-proven clean predicate:
  clean → autonomous PASS (subagent skipped); dirty → evidence + defer. Structurally
  cannot false-FAIL, but *can* false-PASS on an unsound predicate — hence bound by
  principle 3. Use only where "clean" is provable ("`go build` exits 0" = the
  modified surface compiles).
- **verdict** (`finish_deterministic`) — writes PASS/FAIL and skips the subagent on
  *both* branches. Uniquely capable of **false-FAIL**, the worst outcome — so the
  highest bar. Permitted only after the fixture test proves it. Not a starting shape.
- **info** (`finish_info`) — always PASS, non-blocking. A distinction no linter
  sees: some info gates are *inherently* non-computable (`maintainer-review`),
  others *computable but non-blocking by policy* (`dep-cve-check` — CVE noise must
  never block a rebase). Record which, and why, in the `.md`; a maintainer must not
  "promote" a policy-info gate to blocking.

`filter ⊂ verdict` in capability (filter = verdict restricted to the PASS branch),
but the split is kept deliberately: it draws the can-false-FAIL / cannot-false-FAIL
line, the single most safety-relevant boundary in the design.

### Library API (`gate-script-lib.sh`)

```bash
inc() {                       # safe counter — never returns nonzero, safe under set -u
  local var="${1:-NEW_ISSUES}"                          # bashism (companions are bash)
  printf -v "$var" '%d' "$(( ${!var:-0} + 1 ))"
}

_gate_trap() {                # ordinary nonzero exit: NO report → subagent (timeout/signal: orchestrator, below)
  local exit_code=$?
  [[ $exit_code -eq 0 ]] && return 0
  if [[ -n "${REPO:-}" && -n "${GATE_NAME:-}" ]]; then
    mkdir -p "$REPO/.rebase-tmp/gates"
    printf 'CRASH: exit %s at %s\n' "$exit_code" "${BASH_SOURCE[1]:-unknown}" \
      > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"     # observable breadcrumb
  fi
  echo "CRASH: ${GATE_NAME:-?} (exit $exit_code) — no report; deferring to subagent"
}

_head_sha() { git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown; }

_write_evidence() {           # atomic, HEAD-stamped, AND echoed to stdout (see transport)
  local summary="$1"; shift
  mkdir -p "$REPO/.rebase-tmp/gates"
  local ev="$REPO/.rebase-tmp/gates/${GATE_NAME}.evidence"   # GATE_NAME is step-prefixed
  { echo "HEAD: $(_head_sha)"; echo "SUMMARY: $summary"; printf '%s\n' "$@"; } \
    | tee "$ev.tmp"                                          # tee: file for orch, stdout for
  mv "$ev.tmp" "$ev"                                         # the in-subagent fallback path
  echo "PENDING: $GATE_NAME"; echo "EVIDENCE: $ev"
}

finish_evidence()     { local s="${1:-}"; shift 2>/dev/null||true; _write_evidence "$s" "$@"; trap - EXIT; exit 0; }
finish_info()         { local s="${1:-}"; shift 2>/dev/null||true; bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$s" "$@"; echo "RESOLVED: $GATE_NAME PASS (informational)"; trap - EXIT; exit 0; }
finish_filter()       { local n="${1:?}" s="${2:-}"; shift 2 2>/dev/null||true; if [[ "$n" -eq 0 ]]; then bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$s" "$@"; echo "RESOLVED: $GATE_NAME PASS"; else _write_evidence "$s" "$@"; fi; trap - EXIT; exit 0; }
finish_deterministic(){ local n="${1:?}" s="${2:-}"; shift 2 2>/dev/null||true; local v=PASS; [[ "$n" -gt 0 ]] && v=FAIL; bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" "$v" "$n" "$s" "$@"; echo "RESOLVED: $GATE_NAME $v"; trap - EXIT; exit 0; }
```

`_write_evidence` writes the file **and** `tee`s to stdout, so evidence survives on
both transports (orchestrator-reads-file and subagent-reads-stdout) during the
migration — closing the "companion-less gate loses its facts" regression.
`finish_gate` stays during migration, then is removed once callers move to
`finish_evidence`/`finish_filter`.

## Execution model (the load-bearing fix)

The current draft built an evidence *file* (`_write_evidence`, `evidence_path`,
freshness-on-evidence, `cmd_init` cleanup, a `cmd_gates` `EVIDENCE:` line) that
**no judge reads**. Two transports coexist and don't compose:

- **Orchestrator path (step 4 only):** `cmd_gates` runs the companion and writes
  `<gate>.evidence`, then prints `EVIDENCE: <path>` to the *main* agent.
- **In-subagent path (steps 1-4):** the `.md` MANDATORY block tells the *subagent*
  to run the `.sh` and read its stdout — this is what the judge actually consumes.

The launched-subagent prompt (`step4-verification.md:60-63`) is *"repo path +
module safety rule + Read `<gate-file>`"* — it is **never** told to read the
`.evidence` file. So the entire orchestrator-path apparatus is write-only, the
freshness discipline (principle 5) guards a file nobody judges from, and the moment
Phase-4-as-drafted drops the MANDATORY block the subagent has *no* evidence at all.
The companion-less judgment gates the rollout most cares about (`type-conversions`,
`fix-correctness`, `rebase-completeness`) are exactly the ones whose evidence would
land in that unread file.

**The fix is to make the orchestrator (`scripts/k8s-rebase-orchestrator.sh`, where
`cmd_gates`/`cmd_advance` live) the single runner and wire its output to the judge**,
so there is one transport and the script runs once:

```bash
# report_path/evidence_path share the ${sd%-*}-${gate} prefix (matches report_path:106-110).
# Preserve the live aggregate contract this branch sits inside: `local resolved=0
# pending=0` (:182), the resolved++/pending++ increments (:196/:206/:212/:215), and
# the trailing summary `RESOLVED: $resolved` / `PENDING: $pending` +
# `[[ "$pending" -gt 0 ]] && return 1` (:220-222) that callers depend on. The branch
# below replaces ONLY the dead `NEW_ISSUES=0` grep (:204 — never matches finish_gate's
# `RESOLVED:`/`PENDING:` output); keep the counters and the summary.

rc=0
[[ -x "$companion" ]] && { timeout "${GATE_TIMEOUT:-300}" bash "$companion" "$repo" 2>&1 || rc=$?; }
(( rc > 128 )) && printf 'CRASH: exit %s (orchestrator-detected kill)\n' "$rc" \
  > "$repo/.rebase-tmp/gates/${gate_name}.crash"                        # SIGTERM(124)/SIGKILL(137): trap can't
if report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then    # RESOLVED: skip subagent
  echo "RESOLVED: $gate_name $(grep '^VERDICT:' "$rpt" | awk '{print $2}')"; ((resolved++)); continue
fi
ev=$(evidence_path "$repo" "$sd" "$gate_name")                          # PENDING: hand path to caller
[[ -f "$ev" ]] && report_is_fresh "$ev" "$repo" && echo "EVIDENCE: $ev"
echo "PENDING: $gate_name"; ((pending++))
```

Then the step files must **launch each PENDING subagent with its evidence**: the
prompt becomes *"repo path + module safety rule + Read `<gate-file>` **and, if an
`EVIDENCE:` path was printed for this gate, Read that file first**."* And the
in-subagent MANDATORY re-run is **removed** — the script has already run in the
orchestrator, so re-running it doubles work and re-opens the HEAD-drift window.

Under this model every artifact is consumed: the report resolves-or-not, the
evidence file is read by the deferred subagent, freshness gates a file that is now
actually judged from, and the fast-path (skip subagent on a proven clean-PASS/verdict)
works in *every* step, not just step 4. It also fixes the redundant-subagent bug
(the old `:204` grep never matched `finish_gate`'s output, so a clean gate was
mislabeled PENDING and spawned a wasted subagent, self-healing only via the disk
pre-check at `:192`).

`cmd_init` must clean `*.evidence`/`*.crash` alongside `*.report` (`:151` cleans
only reports, only on the FRESH branch), **and** the pre-existing stale-state
footguns it misses — `.advance-attempts-step*` (`cmd_advance:286`) and
`status/INCOMPLETE` (`:310`) — since a stale `.advance-attempts-stepN` surviving a
re-init triggers a premature force-advance (`:293` fires at `attempts >= 3`).

A crashed companion writes no report and no evidence → PENDING → subagent (which
judges from scratch), same as a companion-less gate; visible via the `.crash`
breadcrumb and `CRASH:` line; the 3-attempt force-advance (→ INCOMPLETE → `--draft`
PR) remains the backstop for any stuck gate.

## Gate map (33 today; consolidation deferred to Phase 5)

Target convention, not a declaration. Verified: 33 gate `.md`, 6 companions. 15
files contain the word "MANDATORY", but only **6 carry a run-the-companion
"MANDATORY FIRST STEP" block** (== the 6 companions); the other 9 use "MANDATORY"
for an unrelated *base-branch pre-existing filter* (`correctness.md:27`, "MANDATORY
pre-existing check — run for EVERY finding") that Phase 3 keeps — not a block to drop.

- **evidence (inject facts, always defer):** `version-consistency` (runtime module
  classification), `feature-gates` (refs + vendor symbol presence),
  `crd-validation`, `patterns-completeness`, `rebase-completeness`,
  `type-conversions`, `fix-correctness`, `correctness`, `deprecated-calls`,
  `deprecated-api-remnants`, `deprecated-imports`, `gomod-diff-analysis`,
  `ci-prediction`, `k8s-changelog`, `logical-consistency`, `autofix-diff-review`,
  `version-completeness`, `e2e-infra`, `dep-release-notes`. `dep-release-notes` is a
  companion-less **FAIL-capable** judgment gate (`dep-release-notes.md:40` "VERDICT:
  FAIL if any dependency release note documents a breaking change…") — an earlier
  draft misfiled it as `info`; it is evidence, per "every judgment gate."
  `crd-validation`/`patterns-completeness` are
  **already** pure evidence-providers — their `.sh` sources no lib and writes no
  report; it prints `NEW_ISSUES=<n>` to stdout and the subagent writes the report
  (`crd-validation.sh:56`, `patterns-completeness.sh:55`). Their unsoundness is not
  in the script but in the `.md`: `crd-validation.md:10-11` RULE 1 tells the
  subagent to auto-PASS on `NEW_ISSUES=0`, and the count comes from a 6-keyword grep
  (`crd-validation.sh:46`, `pattern:|format:|minimum:|maximum:|enum:|required:`)
  that misses `x-kubernetes-*`, `default:`, `nullable`, and structural edits. Fix =
  remove RULE 1 + widen the predicate (principle 7), not a shape change.
- **filter (evidence + *proven* clean-PASS):** `build-vet`, `build-vet-recheck`,
  `test-compilation`, `autofix-result` — "`go build`/`go vet` exits 0" = the
  modified surface compiles. Even here the base filter is *evidence the subagent
  weighs*: an unmodified file that now fails to compile from a k8s API change is a
  real regression only the subagent can call — so these never become `deterministic`,
  and their clean-PASS must still pass the Phase-4 cross-file fixture test before
  adopting `finish_filter` (until then they run as `evidence`).
- **info (always PASS, non-blocking):** `dep-cve-check` (computable, policy),
  `maintainer-review` (non-computable), `skill-improvement`, `commit-messages` —
  exactly the live `INFO_GATES` (`test-skill.sh:21`, 4 gates). (`dep-release-notes`
  is *not* here — it can FAIL; see the evidence list.)
- **verdict candidates (only if the fixture test proves them):**
  `major-version-imports`, `go-version-check` — both already base-filter (`git show
  $BASE`, `go-version-check.sh:37,51`). Everything a script *could* mechanize but
  can't do soundly — `diff-scope` (extension allow-list false-FAILs legit
  `.txt`/`.json`/`.proto` testdata), `cleanliness` (`find -user root` is
  environment-dependent; its `.md` says "run on the host") — stays `evidence`.
- **Dropped/folded (Phase 5):** `logical-completeness` → `logical-consistency`;
  `ci-readiness` → `ci-prediction`.

**Consolidation is 0% done** — all 33 gates and all merge targets are live.
`autofix-patterns-redesign.md`'s "COMPLETE" refers to the *autofix* refactor; its
gate consolidation is filed under future work. Do not hardcode a target count;
reconcile in Phase 5.

## Migration sequence

Reordered so each phase's precondition is met by the prior one. The old draft built
the evidence transport in Phase 0 and unified execution last — inverted, since the
transport is inert until execution is unified. Bump `plugin.json` + `make lint &&
make update` once per landed PR.

**Phase 0 — Mechanical patch (ship first; independent of everything below).**
(a) `inc` guard — defensive, currently unreached (all 6 companions guard `((n++))`
with `|| true`). (b) `_gate_trap` → `.crash` breadcrumb (ordinary nonzero exits only), no FAIL report;
**and** the orchestrator writes the breadcrumb on a `>128` child exit — the dominant
`timeout -s TERM`(124)/SIGKILL(137) crash is invisible to the in-script trap (SIGTERM
→ exit 0, SIGKILL → no trap). Plus the harness reader, keyed off *both* breadcrumb
sources: `_tally_gates` returns a fixed 4-field string (`test-skill.sh:129`) read at
three sites (`:948/:1450/:1517`), so surfacing crashes "distinct from missing" means
widening that arity (or a parallel `.crash` scan), filtering crashed gates from the
missing-names loop (`:979-992`), and the cross-worktree fan-out reports get
(`_collect_gate_dirs:66-75`) — budget it as a real change, shipped in the same PR as
the trap. (c) `cmd_init` cleans `*.evidence`/`*.crash` +
`.advance-attempts-step*`/`INCOMPLETE`.

**Phase 1 — Fix the court, then measure (decision gate).** Two separable pieces:
*(metric)* the go/no-go for the rollout is **court verdict / false-FAIL rate on the
post-`pr-feedback-resolution` stripping baseline**, from `results.tsv`, plus
per-gate latency (so the cost of adding scripts is visible) — NOT subagent count,
which measures cost not the reliability at issue. *(court juror tool use)* jurors are
granted tools yet 0/15 call one (step-isolation §6); forcing tool use is prompt
research with uncertain yield — it sharpens the *measurement*, it does not gate the
next phase. Decision: after the Stop-hook fix (91% adherence) and the stripping
rewrite, does subagent reliability still bind? Baseline is mixed — spec=none 100%
(3/3), overnight 24/24, spec=all 95% (20/21), but per-version 1.35.3 = 12% is a live
blocker. "Mostly healthy with a version-specific hole," not solved. **If it no
longer binds, stop after Phase 0.**

**Phase 2 — Unify execution + wire the single transport (the foundation).** Only if
Phase 1 binds. Make the orchestrator the single runner (per "Execution model"):
steps 1-3 call `orchestrator gates <step>` first, mirroring step 4; step files launch
PENDING subagents *with* the `EVIDENCE:` path. Scope: the **6 run-companion "MANDATORY
FIRST STEP" blocks** (the 6 companions) + the step-1-3 spawn wiring — *not* the 9
"MANDATORY pre-existing check" base-filter blocks, which stay.

Atomic per companion gate, in one edit so no intermediate state strands it:
1. Convert its companion `finish_gate` → `finish_evidence` (for `crd-validation`/
   `patterns-completeness`, which today only echo `NEW_ISSUES=` to stdout and write
   no file, add the evidence-file writer). Safe here *without* the Phase-4 fixture
   test because `finish_evidence` always defers — writes no verdict, cannot
   false-anything. Without this step Phase 2 would strand the gate: no live companion
   writes a `.evidence` file (`finish_gate`'s dirty path only echoes to stdout,
   `gate-script-lib.sh:68-72`), so the transport's `[[ -f "$ev" ]]` check finds
   nothing and — once the block is gone — the subagent gets no facts.
2. Add the `gates` call + inject the `EVIDENCE:` path *while keeping* the FIRST STEP
   block; verify the deferred subagent receives identical facts via the file.
3. Remove the `NEW_ISSUES`/RULE-1 fast-path prose in the *same* edit
   (`version-consistency.md:10-11`, `crd-validation.md:11-12`) — once the in-subagent
   run is gone, a RULE 1 that reads `NEW_ISSUES` references a value the orchestrator
   no longer surfaces to the subagent. (Pulled forward from Phase 3.)
4. Drop *only* the FIRST STEP block. In the 3 companion gates that also carry a
   base-filter block (`major-version-imports.md:22`, `patterns-completeness.md:48`,
   `go-version-check.md:43`), delete the FIRST STEP block surgically and preserve the
   base-filter.

So Phase 2 carries the baseline `finish_gate`→`finish_evidence` conversion for the 6
companions (not "no new content"), and turns on the fast-path everywhere (fixing the
wasted-subagent bug). The value-add — evidence for the *companion-less* judgment
gates — is Phase 3.

**Phase 3 — Evidence-in content rollout (the value).** Author evidence for the
companion-less judgment gates (`type-conversions`, `fix-correctness`,
`rebase-completeness`) — the point of the plan. Adopt the lib + runtime module
classification (§principle 6) in `version-consistency`/`feature-gates`. Remove any
*remaining* "set PASS immediately / do NOT run the checks below" rubber-stamp
(§principle 7 — the two companion-gate instances are already gone in Phase 2); make
every `SUMMARY:` neutral. Keep full judgment prose in each `.md` (the subagent
still reads it, for the crash fallback and the dirty path).

**Phase 4 — Fixture test → promote proven predicates.** Build the fixture harness
(reuse the `.repos` scaffolding; a new target) — one gate vs a repo with known
pre-existing/cross-file breakage, asserting **zero false-FAIL AND zero false-PASS**.
This is the unconditional precondition for *any* autonomous verdict — a
`deterministic` FAIL/PASS *and* a `filter` clean-PASS. Only now may `build-vet` etc.
adopt `finish_filter`, and `major-version-imports`/`go-version-check` adopt
`finish_deterministic`; expect few to qualify. A gate that can't prove its predicate
stays `evidence`.

**Phase 5 — Consolidation.** Re-audit live state (0% done). Reconcile the count
across `autofix-patterns-redesign.md`/`next-work.md`. Drop `logical-completeness`;
fold `ci-readiness` → `ci-prediction`; decide the contested `commit-messages` →
`maintainer-review` merge; narrow `deprecated-api-remnants` to web-search discovery
(step-isolation §8). `EXPECTED_GATES` is dynamic (`test-skill.sh:139`) so a count
drop auto-adjusts, but `INFO_GATES` (`:21`, 4 gates) is hardcoded — update it in the
same commit if the info set changes.

## Production backstop (recommendation)

Evidence-in closes hallucination but not satisficing, and the court is **test-time
only** (`test-skill.sh` + its Makefile target + `config-1.35.yaml`; zero refs in
`skills/`/`scripts/`/`gates/`/`hooks/`). Human + CI at the PR boundary do not catch
a silent semantic drop (a removed struct field that still compiles and passes unit
tests). **Recommendation: do both, cheaply.** (1) Always emit a *semantic-risk
manifest* in the draft-PR body listing the AI-judged-not-machine-verified gates
(`type-conversions`, `k8s-changelog`, `logical-consistency`) so the human reviewer
is aimed at the unverified surface. (2) Promote one adversarial juror to a *single
pre-PR production gate* (one AI call with git show/diff/Read) — the real backstop,
trivial against a plan whose premise is spending AI calls on quality. The manifest
is free insurance; the juror is the catch. Decide before Phase 3 ships.

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Evidence file unconsumed by the judge (the draft's core bug) | High | Single-runner transport: orchestrator writes report-or-evidence, step files launch PENDING subagents *with* the `EVIDENCE:` path; `_write_evidence` also `tee`s to stdout for the fallback. |
| `filter` clean-PASS / `verdict` false-something on an unsound predicate | High if unguarded | Phase-4 fixture proof (zero false-FAIL AND false-PASS) is the precondition for any autonomous verdict; default `evidence` cannot false-anything. |
| Dropping the FIRST STEP block strands a companion gate (no live companion writes a `.evidence` file) | Medium | Phase 2 converts `finish_gate`→`finish_evidence` (which writes the file) in the *same* per-gate edit that drops the block, after verifying the subagent reads identical facts; the 9 base-filter blocks are preserved. |
| Evidence-in amplifies satisficing (verdict-shaped SUMMARY, "set PASS" instr.) | Medium | Neutral fact-only `SUMMARY:`; Phase 3 removes the rubber-stamp instruction; court measures residual. |
| Freshness oversold — HEAD drifts during step-4's concurrent lint commits | Medium | Single-run transport narrows the window; document evidence-in is soundest at a settled HEAD; consider running the consuming subagent after 4a quiesces. Open. |
| Runtime module-classification fetch fails (k8s.io/kubernetes outside dep graph) | Medium | Degrade to raw module/version evidence + `SUMMARY:` noting unavailable, defer; never a stale table or flag-everything. |
| Crash hides as "missing" | Medium | The in-script trap covers ordinary nonzero exits; the dominant `timeout -s TERM`/SIGKILL crash is invisible to it (exit 0 / no trap), so the *orchestrator* writes the `.crash` breadcrumb on a `>128` child exit. Breadcrumb + harness reader ship together (Phase 0); force-advance prevents a silent green. |
| `evidence` shape raises wall-clock (adds a script, never drops the subagent) | Low-Med | Accepted trade; Phase 1 records per-gate latency so cost is visible. |
| Cross-plan collision (count; module-class helper; test-skill.sh regions) | Medium | Reconcile in Phase 5 against live state; one sourced classification helper; Phase 1 court edit is a different region than pr-feedback's stripping edit but runs against the post-stripping baseline. |

## Success criteria

- Gate **subagents** are measurably more reliable: lower court false-FAIL / higher
  semantic-catch rate on the post-stripping baseline (the Phase-1 metric).
- The evidence path is wired end to end — every `EVIDENCE:` file is read by the
  subagent that judges the gate; no write-only artifacts.
- No script writes a blocking verdict except a `filter`/`verdict` gate that passed
  the fixture test. A crash writes no report and is surfaced as infra.
- Evidence is fresh (HEAD-stamped, freshness-gated, cleaned on init) and consumed at
  a settled HEAD.
- Zero false-FAIL regressions vs the current pass rate.
- A production satisficing backstop exists (manifest + pre-PR juror) or is
  explicitly, visibly deferred — not silently absent.

## Relation to other plans

- **gate-architecture-v2.md:** superseded; the record of the rejected
  script-as-authority design.
- **step-isolation-and-generality.md:** v3 keeps §4.4's convention-over-frontmatter
  choice and adopts the §6 juror tool-use fix in Phase 1.
- **future-ideas.md:** vindicates the feature-gate "fragile parser" deferral —
  `feature-gates` is evidence, never a script verdict.
- **pr-feedback-resolution.md:** owns the spec=all stripping baseline; sequence
  Phase 1's measurement after it lands; shares `test-skill.sh`.
- **autofix-patterns-redesign.md / next-work.md:** own the (0%-done) consolidation
  count and the duplicated module-classification logic in `k8s-rebase.sh` (the live
  code; `next-work.md` only describes it); reconcile in Phases 3/5.

<!-- Budget: ~400 lines. -->
