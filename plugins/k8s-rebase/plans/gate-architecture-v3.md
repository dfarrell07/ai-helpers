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
   that sees the child's exit code: `124` (timeout — sends SIGTERM, so the in-script
   trap saw exit 0) or `>128` (killed by signal, e.g. `137` SIGKILL — no trap ran).
   `timeout` exits `124`, *not* a value `>128` (that range is external signal-kills).
   See "Execution model."

## Design principles

1. **Scripts serve the subagent.** The default script output is *evidence* + defer;
   or a fast-path *verdict* only where the script can soundly prove that outcome.
   The subagent judges everything else, grounded in the script's facts.
2. **Evidence must reach the judge, or it is theater.** A file nothing reads is not
   evidence: evidence-in is correct only if the subagent actually consumes the
   script's output. v3 delivers it by *convention* — each gate `.md` names its own
   evidence file, so the subagent reads a known path — **not** by relaying that path
   through the main agent's prompt, which an earlier draft did and which fails
   silently the first time the busy main agent forgets it (see "Execution model").
3. **A script writes an autonomous verdict only as a fixture-proven exception.** Not
   by default. It must pass a fixture test showing **zero false-FAIL AND zero
   false-PASS** on a repo with known pre-existing/cross-file breakage, and the
   predicate must generalize across repos and k8s versions. This binds both a
   `verdict`-shape FAIL (`finish_deterministic`) *and* a `filter` clean-PASS — a clean-PASS removes the judge
   exactly as a deterministic PASS does. Today, zero gates qualify without the test.
4. **A crash is never a verdict — and this reaches inside the script to each
   sub-tool.** Infra failure writes no report → the gate degrades to the subagent
   path, exactly like a companion-less gate. Made observable (Phase 0) — but the
   in-script trap sees only ordinary nonzero exits; the dominant `timeout -s
   TERM`/SIGKILL crash (exit 0 / no trap) is observable *only* at the orchestrator,
   which writes the breadcrumb when the child exits `124` (timeout) or `>128`
   (signal-killed). Never silent. **A sub-tool timeout is a third blind spot both
   layers miss:** `build-vet.sh:23-24` wraps each tool as `timeout … go build … ||
   true`, so a killed `go build`/`go vet` is swallowed to exit 0 — the script exits 0
   (in-script trap never fires) *and* the orchestrator's outer `timeout bash
   companion` (`:203`) also exits 0, so a build that never completed counts zero error
   lines → `finish_gate 0` → autonomous **PASS**. This is a live false-PASS today and
   would persist into `build-vet`-as-`filter`. Fix: capture each inner tool's exit
   code *before* `|| true`; on `124`/`>128` write **no** verdict, drop a `.crash`
   breadcrumb, and defer — **never FAIL**, because FAIL from a build that would have
   compiled violates `filter`'s cannot-false-FAIL invariant (the safety boundary
   below), and a timeout is not "`go build` exits 0" so it fails the proven-clean
   predicate (principle 3). (This applies only to `build-vet` — the sole `filter`
   candidate with a companion `.sh` today; see Gate map.)
5. **Evidence must be fresh, and consumed at a settled HEAD.** Every artifact is
   HEAD-stamped and freshness-checked (`report_is_fresh:122-133` already does this
   for reports). But note the limit: `step4-verification.md:31-36` runs gates *while
   the main agent commits lint fixes*, so HEAD drifts mid-evaluation and a benign
   commit marks still-valid evidence "stale" → re-run + `stale`-bucket pressure
   (`cmd_advance:256`). Freshness detects drift; it does not create a quiescent
   HEAD. Evidence-in is soundest when a gate's evidence and its verdict share a
   commit — see "Execution model" for how the single-run transport narrows that
   window, and the Risks table for the step-4 concurrency decision it resolves.
6. **Generality beats cleverness — with a degradation path.** Derive facts at
   runtime (e.g. staging-module classification from `k8s.io/kubernetes`'s `go.mod`
   `replace`-to-`./staging/src/k8s.io/*` set at the target tag — which *includes*
   the v0.MINOR staging modules and *excludes* `k8s.io/utils`, `klog/v2`,
   `kube-openapi`, `sigs.k8s.io/*`, the four the substring grep false-flags) rather
   than hardcoding lists that rot. Fetching its `go.mod` at the target tag is a
   GOPROXY read of go.mod *text* — no dependency-graph membership required (the
   primary target does depend on it directly: `ovn-kubernetes/go-controller/go.mod`
   pins `k8s.io/kubernetes`) — but it can still fail (GOPROXY offline, or the tag not
   yet published). Degrade: emit the raw module/version list as evidence with a
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
bespoke linter (step-isolation §4.4 already chose convention over declaration). Three
of the shapes form a 2×2 over *(clean action) × (dirty action)* in {write-verdict,
defer} — `evidence` = defer/defer, `filter` = write-PASS/defer, `verdict` =
write/write. `filter` occupies the write-on-clean/defer-on-dirty cell; the remaining
cell (defer-on-clean/write-on-dirty) would be a false-FAIL machine and is deliberately
absent. `info` is **not** a cell of that grid — it is an orthogonal *always-PASS,
non-blocking* overlay that ignores the clean/dirty axis entirely. Named for the risk
each carries:

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
finish_filter()       { local n="${1:?}" s="${2:-}"; shift 2 2>/dev/null||shift "$#"; if [[ "$n" -eq 0 ]]; then bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" PASS 0 "$s" "$@"; echo "RESOLVED: $GATE_NAME PASS"; else _write_evidence "$s" "$@"; fi; trap - EXIT; exit 0; }
finish_deterministic(){ local n="${1:?}" s="${2:-}"; shift 2 2>/dev/null||shift "$#"; local v=PASS; [[ "$n" -gt 0 ]] && v=FAIL; bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" "$v" "$n" "$s" "$@"; echo "RESOLVED: $GATE_NAME $v"; trap - EXIT; exit 0; }
```

`_write_evidence` writes the file **and** `tee`s to stdout, so evidence survives on
both transports (orchestrator-reads-file and subagent-reads-stdout) during the
migration — closing the "companion-less gate loses its facts" regression.
`finish_gate` stays during migration, then is removed once callers move to
`finish_evidence`/`finish_filter`.

## Execution model (the load-bearing fix)

An earlier v3 draft built an evidence *file* (`_write_evidence`, `evidence_path`,
freshness-on-evidence, `cmd_init` cleanup, a `cmd_gates` `EVIDENCE:` line) that
**no judge reads** (no such apparatus exists in live code — `grep -rn '_write_evidence\|evidence_path\|EVIDENCE' scripts/ gates/` is empty; this section specifies the transport to build). Two transports coexist and don't compose:

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

# 1. CACHE HIT FIRST: a fresh verdict already on disk from a prior `gates` run → skip
#    and do NOT re-run the companion. This ordering matches live cmd_gates:192 (which
#    `continue`s before ever reaching the companion at :200); running the companion
#    first would re-execute a second `go build`/`go vet` on every fix-loop iteration,
#    breaking the "script runs once" invariant.
if [[ -f "$rpt" ]] && report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then
  echo "EXISTING: $gate_name $(grep '^VERDICT:' "$rpt" | awk '{print $2}')"; ((resolved++)) || true; continue
fi

# 2. No fresh verdict cached → run the companion exactly once.
rc=0
crash="$repo/.rebase-tmp/gates/${sd%-*}-${gate_name}.crash"  # SAME prefix as report_path/evidence_path (:108)
[[ -x "$companion" ]] && { timeout "${GATE_OUTER_TIMEOUT:-900}" bash "$companion" "$repo" 2>&1 || rc=$?; }  # outer > sum of inner GATE_TIMEOUTs (Phase 0(e))
(( rc >= 124 )) && printf 'CRASH: exit %s (orchestrator-detected kill)\n' "$rc" > "$crash"
  # 124 timeout(SIGTERM→trap saw 0); 125-127 timeout-infra; >128 signal-kill(137). Trap can't see these.

# 3. Did the companion just write a fresh verdict (filter/verdict clean path)? → RESOLVED.
if report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then
  echo "RESOLVED: $gate_name $(grep '^VERDICT:' "$rpt" | awk '{print $2}')"; ((resolved++)) || true; continue
fi

# 4. Otherwise PENDING. The orchestrator does NOT relay a path: the subagent finds its
#    own evidence by convention — its .md names the fixed
#    .rebase-tmp/gates/${sd%-*}-${gate_name}.evidence path (evidence_path derives the
#    same). The subagent MUST freshness-check it on read (see below) — the orchestrator
#    just wrote it at this HEAD, but HEAD can drift before the subagent reads it.
echo "PENDING: $gate_name"; ((pending++)) || true
```

`((resolved++))`/`((pending++))` carry `|| true` because under `set -euo pipefail`
(orchestrator `:15`) `((x++))` returns status 1 on the `0 → 1` transition and would
abort the function — this is why the live counters at `:196/:206/:212/:215` are
already guarded; the snippet must preserve that.

Then the subagent must **read its evidence by convention, not by relay** — and
**freshness-check it on read**. The launched-subagent prompt is unchanged (*"repo
path + module safety rule + Read `<gate-file>`"*); the `<gate-file>` itself carries a
fixed instruction — *"If `.rebase-tmp/gates/<prefix>-<gate>.evidence` exists,
compare its `HEAD:` line to `git rev-parse HEAD`; if they match, Read it first and
treat its facts as ground truth; if they differ (HEAD drifted since the orchestrator
wrote it), the evidence is stale — ignore it and judge from scratch"* — naming its
own evidence path literally, exactly as today's MANDATORY block names its own
companion `.sh`. The consumer-side check is load-bearing: the orchestrator writes the
evidence at the current HEAD, but `step4-verification.md:31-36` runs gates *while the
main agent commits lint fixes*, so HEAD can drift between write and read; a HEAD-stamp
comparison at the point of consumption is what makes principle 5's freshness discipline
actually bind on evidence (as `report_is_fresh` already does for reports). That path
is fully determined by repo root + gate name (nothing to look up), so the subagent
needs nothing relayed from the main agent.

One hazard the convention introduces: the `<prefix>-<gate>` string now has **three
independent producers** that must agree byte-for-byte — the writer (`GATE_NAME`, built
in `init_gate` via `grep -oE '^step[0-9]+'`, `gate-script-lib.sh:37`), the orchestrator
locator (`evidence_path`/`report_path` via `${sd%-*}`, `:108`), and the literal path
written into each `.md`. These derive the prefix *differently* (a `grep` vs a suffix
strip); they happen to agree for today's `stepN-name` dirs, but that is a coincidence,
not a guarantee — so this plan does **not** claim they are "identical." Phase 2 must
either route all three through **one sourced helper** (`gate_artifact_prefix`) or add a
test asserting the three agree for every step dir. And the read-evidence instruction
must **fail loud** on a miss: if the `.md`'s named path does not exist, the subagent
judges from scratch *and* the gate drops an `EVIDENCE_MISSING` breadcrumb (surfaced by
the Phase-0 harness reader), so a silent prefix drift shows up as a diagnostic instead
of a facts-free judgment that looks normal.

This is what closes the transport gap **without** the single point of failure the
alternative would create. The alternative — have the main agent paste each PENDING
gate's `EVIDENCE:` path into its subagent prompt — reintroduces the exact write-only
failure this section exists to kill: the main agent launches gates *while it iterates
lint fixes* (`step4-verification.md:31-36`), and the first time it forgets a path (or
launches from stale orchestrator output) that gate silently judges with no facts, with
no error. Convention discovery removes the main agent from the evidence *relay*:
the file is delivered by the same mechanism that already reliably delivers the gate
`.md` — the subagent reading a known file. The orchestrator's `EVIDENCE(log):` line is
a diagnostic, not a handoff.

The in-subagent MANDATORY *re-run* of the companion is **removed** — the script has
already run once in the orchestrator, so re-running it doubles work (a second
`go build`/`go vet` for `build-vet`) and re-opens the HEAD-drift window. The `.md`'s
run-the-companion block is replaced by the read-the-evidence block; the companion is
never invoked twice for one evaluation.

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
re-init triggers a premature force-advance (`:293` fires at `attempts >= 3`). Note
`.crash` has **no HEAD stamp**, so read-time freshness cannot invalidate a stale one
the way it does an `.evidence`/`.report` file — `.crash` must be cleaned explicitly,
on **both** the FRESH and RESUME branches, or a crash from a prior run reads as
current.

A crashed companion writes no report and no evidence → PENDING → subagent (which
judges from scratch), same as a companion-less gate; visible via the `.crash`
breadcrumb and `CRASH:` line.

A stuck gate is *not* silently green today — but the plan must not claim it is
caught either. After 3 attempts `cmd_advance` force-advances: it writes
`status/INCOMPLETE` (`orchestrator.sh:305,310`), bumps state to `STEP_COUNT+1`, and
`cmd_status` then prints `DONE: true` (`:342-346`). Nothing reads `INCOMPLETE`; the
Stop hook (`stop-hook.sh:25`) sees `DONE: true` and lets the session end; and step 5
prints a plain, non-draft `gh pr create` (`step5-pr.md:37`) whose body
(`step5-pr.md:30-35`) never mentions the force-advance. So an incomplete rebase
currently yields a clean-looking PR command — `INCOMPLETE` is a **write-only
breadcrumb no consumer surfaces**. Closing that gap (step 5 reads `INCOMPLETE` and
either draft-flags the PR or annotates its body with the force-advanced gates) is
real work that reaches into step 5 — which is deliberately **un-orchestrated**
(`step5-pr.md:74-75`, "Do NOT run orchestrator advance"; `STEP_DIRS` is steps 1-4
only, `orchestrator.sh:21`). It is therefore filed as an explicit **future-work gap**
(see "Production backstop"), not smuggled into this plan's steps-1-4 scope. The
skill only ever *prints* the PR command (`rules.md:33` forbids `git push`/`gh pr
create`), so any fix changes printed text, never an executed action.

## Gate map (33 today; consolidation deferred to Phase 5)

Target convention, not a declaration. Verified: 33 gate `.md`, 6 companions. 15
files contain the word "MANDATORY", but only **6 carry a run-the-companion
"MANDATORY FIRST STEP" block** (== the 6 companions); the other 9 use "MANDATORY"
for an unrelated *base-branch pre-existing filter* (`correctness.md:27`, "MANDATORY
pre-existing check — run for EVERY finding") that Phase 3 keeps — not a block to drop.
(3 of the 6 companion files carry *both* block types, so base-filter blocks total 12,
not 9 — see Phase 2.)

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
- **filter (evidence + *proven* clean-PASS):** `build-vet` **only** — "`go
  build`/`go vet` exits 0" = the modified surface compiles. It is the **sole**
  *filter-candidate* gate with a companion `.sh` today — and since a gate's shape is
  which `finish_*` its script calls, a gate with no companion cannot be `filter` or
  `verdict` at all: so `filter` has exactly one candidate.
  Even here the clean-PASS is *evidence the subagent weighs* — an unmodified file that
  now fails to compile from a k8s API change is a real regression only the subagent
  can call — so it never becomes `deterministic`, and its clean-PASS must still pass
  the Phase-4 cross-file fixture test before adopting `finish_filter` (until then it
  runs as `evidence`). Three gates an earlier draft filed as `filter` have **no
  companion** on disk, so they are `evidence` today and any `filter` promotion is
  *blocked on first authoring a companion*: `test-compilation` (`go test -run='^$'
  -count=0` — a compile-only predicate, so filter-*eligible in principle* once a
  companion exists) and `build-vet-recheck` (same compile predicate, likewise
  eligible-once-authored — but its companion must preserve the base-branch
  pre-existing-error exclusion its `.md` carries at `build-vet-recheck.md:23-36`,
  which `build-vet.sh` lacks, so **not** a naive symlink of `build-vet.sh`).
  `autofix-result` is **not** filter-eligible at all: its predicate is git-log
  judgment (`autofix-result.md:13`, autofix markers + commit history), **not reducible
  to "`go build` exits 0"** (the `go build`/`vet` fallback at `:16-22` is only a
  tie-breaker for the zero-fix-commit case) — it stays `evidence`/judgment
  permanently.
- **info (always PASS, non-blocking):** `dep-cve-check` (computable, policy),
  `maintainer-review` (non-computable), `skill-improvement`, `commit-messages` —
  exactly the live `INFO_GATES` (`test-skill.sh:21`, 4 gates). (`dep-release-notes`
  is *not* here — it can FAIL; see the evidence list.)
- **verdict candidates (only if the fixture test proves them):**
  `major-version-imports`, `go-version-check` — both base-filter *some* checks (`git
  show $BASE`, `go-version-check.sh:37,51`), **but not all.** `go-version-check.sh:17-25`
  (the cross-module go-directive consistency check) has **no BASE reference** — it flags
  any inter-module go-directive mismatch regardless of whether it pre-dates the rebase.
  Harmless today (`finish_gate` defers), but as an autonomous `finish_deterministic` a
  repo with a *legitimately* inconsistent-but-pre-existing set of go directives
  false-FAILs. So promotion of `go-version-check` **requires base-filtering `:17-25`
  first** (compare the cross-module directive set to the same set on `$BASE`; flag only a
  *newly* introduced inconsistency), in addition to the empty-`BASE` guard below.
  **The promotion also has a required guard: empty `BASE`.** `init_gate:40-45` falls `BASE` back to `""` and keeps running; the `[[ -n
  "$BASE" ]]` guards (`major-version-imports.sh:25,51`, `go-version-check.sh:36,51`)
  then count *every* hit as NEW. Harmless today (both `finish_gate` → defer), but as
  an autonomous `finish_deterministic` it flags-everything → `NEW_ISSUES>0` →
  false-FAIL, the worst outcome. So on empty `BASE` the script must **choose its
  shape at runtime** — call `finish_evidence` (emit the unfiltered hits + a neutral
  `SUMMARY:` "no merge-base available; hits shown unfiltered", then defer) instead of
  `finish_deterministic`. This is principle 6 (degrade to evidence when a required
  fact is missing) applied to the base — the same pattern as the GOPROXY-fetch
  degradation, and fully consistent with "shape = which `finish_*` you call." Note
  the other scripts (`k8s-rebase-review.sh:34`, `-validate.sh:451/594`,
  `-autofix.sh:948`) fall back to `HEAD~N` instead; that divergence is **justified by
  soundness class, not a bug** — those are downstream-reviewed heuristic fix-suggesters
  where an approximate base is tolerable, whereas a judge-skipping verdict needs a
  *sound* base or none. The plan mandates the **invariant** (no autonomous verdict
  when `BASE` is empty), not a uniform fallback. Everything a script *could* mechanize
  but can't do soundly — `diff-scope` (extension allow-list false-FAILs legit
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

**Phase 0 — Foundation patch (ship first; independent of everything below).** Mostly
mechanical, but parts (b)/(c) change crash *semantics*: today a crashed companion's
`_gate_trap` writes a **FAIL report**, which `cmd_gates` then treats as a cached verdict
(`report_has_verdict` accepts `FAIL`) and skips the subagent; after (b) it writes a
**`.crash` breadcrumb and no report**, so `cmd_gates` emits PENDING and the subagent runs
and judges (defer-not-fail). Treat these as load-bearing, not cosmetic.
**The evidence-transport lib API is NOT installed here — each `finish_*` lands with its
first caller.** The transport functions
(`_head_sha`/`_write_evidence`/`finish_evidence`/`finish_filter`/`finish_deterministic`/`finish_info`)
exist nowhere today (`grep -rn
'finish_evidence\|finish_filter\|finish_deterministic\|_write_evidence' scripts/ gates/`
is empty; live `gate-script-lib.sh` defines only
`_gate_trap`/`init_gate`/`base_file_has`/`finish_gate`) and **nothing in Phase 0 calls
them.** Landing them here would be dead code with no caller to review it against — and the
Phase-1 decision gate may legitimately **STOP after Phase 0** (see Phase 1), in which case
the transport never ships at all. So `finish_evidence` is added in **Phase 2** as its
*first* sub-step, together with the first companion it converts (a real add-with-caller);
`finish_filter`/`finish_deterministic` follow in **Phase 4** with their promotions, and
`finish_info` is never added (no `info` gate has a companion to call it). That ordering also
forecloses the hazard that a literal Phase-2 execution would call an undefined
`finish_evidence` → `set -euo pipefail` abort → `_gate_trap` fires → facts-free judge. (The
requirement that each new `finish_*` end with `trap - EXIT; exit 0` travels with each.)
**Phase 0's only lib edits are the `inc` guard (a) and the `_gate_trap` rewrite (b).**
(a) `inc` guard — defensive, currently unreached (the **4 lib-sourcing** companions —
`build-vet`, `version-consistency`, `major-version-imports`, `go-version-check` —
guard `((n++))` with `|| true`; `crd-validation`/`patterns-completeness` source no lib
and increment via `$((new+1))`, so the trap/`inc`/counter guarantees here scope to the
4, not all 6). (b) `_gate_trap` → `.crash` breadcrumb (ordinary nonzero exits only), no FAIL report.
**Canonical `.crash` path — one convention shared by all four writers/readers:**
`$repo/.rebase-tmp/gates/${prefix}-${gate}.crash`, where `${prefix}-${gate}` is
`init_gate`'s step-prefixed `GATE_NAME` (lib:33-38) and is identical to `report_path`'s
`${sd%-*}-${gate_name}` (orchestrator:106-110) — verified equal for all four step dirs.
So the in-script trap (keys off `$GATE_NAME`), the orchestrator (keys off
`${sd%-*}-${gate_name}`), `cmd_init` (globs `*.crash`), and the harness reader (keys off
`${gate}.crash`) all resolve the same file; a mismatch here silently loses crashes or
never cleans them. This identity holds only because every step dir has exactly one hyphen: `init_gate`
already extracts the prefix with `grep -oE '^step[0-9]+'` (lib:37, hyphen-immune), while
the orchestrator's `${sd%-*}` sites (`report_path`:108, `count_reports`:97, and the new
`.crash` writer) strip only the last suffix segment — so on a multi-hyphen dir they would
*diverge* (`step2-compile-vet` → grep `step2` vs `%-*` `step2-compile`), not both break the
same way. Keep step-dir names single-hyphen, or move the orchestrator `${sd%-*}` sites to
the same `grep -oE '^step[0-9]+'` form (`init_gate` needs no change).
Being gate-name-prefixed, a stale crash on gate A cannot mask a real one on gate B; its
only impact is false-positive crash-count noise. **And** the orchestrator writes the
breadcrumb when the child exits `124` (timeout — the dominant crash) or `>128`
(signal-killed, e.g. `137`): on the common `timeout` SIGTERM the in-script EXIT trap *does*
run but observes `$? = 0` (verified empirically — bash runs the EXIT trap on an untrapped
SIGTERM), so the nonzero-guarded trap writes nothing while `timeout` still surfaces `124`
to the orchestrator; only SIGKILL skips the trap entirely (`137`). Either way the in-script
trap records no crash for the timeout/kill class, so the orchestrator must own `>=124`.
(Prefer `timeout --kill-after`/`-s KILL` so a companion that swallows SIGTERM still dies
with a capturable code; confirm the exact code empirically.) The live `cmd_gates` runs the
companion as `if output=$(timeout … bash "$companion" …); then` (`orchestrator.sh:203`),
which **discards** the child exit code — so this patch must restructure that line to
capture it: `rc=0; output=$(timeout "$GATE_OUTER_TIMEOUT" bash "$companion" "$repo" 2>&1)
|| rc=$?; (( rc >= 124 )) && printf 'CRASH: exit %s\n' "$rc" > "$crash"`, **keeping** the
existing `NEW_ISSUES=0` grep branch on `$output` (this is the same restructure the
Execution-model snippet shows; Phase 0 lands only the rc-capture + `.crash` write, not the
evidence transport). Plus the harness reader: prefer a **parallel `*.crash` scan** of
the gate dirs (`_collect_gate_dirs:66-75` already enumerates them, worktree fan-out
included) over widening `_tally_gates`' fixed 4-field return string (`test-skill.sh:129`,
read at three sites `:948/:1451/:1518`) — the scan is purely additive and breaks no
existing reader, whereas re-arity-ing the tally touches all three call sites. Either way,
filter crashed gates from the missing-names loop (`:979-992`) so a crash reads *distinct
from* a plain miss. Ship it in the same PR as the trap. (c) `cmd_init` cleans
`.advance-attempts-step*`/`INCOMPLETE` on the **FRESH branch only** (like `*.report`),
and `*.crash` on **both** the FRESH and RESUME branches — `.crash` has no HEAD stamp,
so read-time freshness can't invalidate a stale one, and cleaning it FRESH-only would
let a prior run's crash read as current (see "Execution model," the `cmd_init`
paragraph). (`*.evidence` cleanup lands with the evidence writer in **Phase 2** — inert
here, since nothing writes `.evidence` until then.) (d) **sub-tool timeout capture — `build-vet.sh` only** (principle
4). `build-vet` is the sole companion that wraps its go tools in an **inner** `timeout`
(`build-vet.sh:23-24`, per module), and that inner `|| true` swallows a timeout-kill
(exit `124`) → empty output → 0 counted error lines → autonomous PASS: a **live**
false-PASS today, acute once build-vet is promoted to `filter`. Fix: capture each inner
tool's exit code *before* `|| true` — errexit-safe: `build_rc=0; build_out=$(timeout
"${GATE_TIMEOUT:-300}" go build ./... 2>&1) || build_rc=$?; (( build_rc >= 124 )) && {
drop .crash; trap - EXIT; exit 0; }` (defer, **never FAIL** — a FAIL from a
would-compile build breaks `filter`'s cannot-false-FAIL invariant), leaving the normal
nonzero+error-line path untouched. **The other two `|| true` go-tool sites do NOT need
this fix.** `grep` finds three swallow sites total — `build-vet.sh:23-24`,
`patterns-completeness.sh:26` (`go build`), `version-consistency.sh:35` (`go mod verify`)
— but **only build-vet's is inside an inner `timeout`.** The other two run their tool with
no inner timeout, so their `|| true` swallows only a *normal* nonzero exit whose evidence
is in the **output** they inspect (a `.go:`-line count; a `FAIL|modified` grep — and
version-consistency's primary check is the go.mod version comparison, independent of `go
mod verify`). The only thing that can *kill* those tools is the orchestrator's **outer**
`timeout` (b), which takes the whole script down before it prints `NEW_ISSUES=` → no
`NEW_ISSUES=0` → PENDING/defer. So there is no killed-tool-masquerades-as-clean path to
close in them; item (b) already covers their kill case.
(`test-compilation`/`build-vet-recheck` have no script.) The normal build-failure path
(nonzero + error lines → `NEW_ISSUES>0` → already defers) is untouched, so there is no
regression. (e) **tier the timeouts.**
The orchestrator's outer `timeout "${GATE_TIMEOUT:-300}" bash "$companion"` wraps a
companion that itself `timeout`s each inner tool at the *same* `GATE_TIMEOUT`
(`build-vet.sh:23-24`) — and `build-vet` loops that pair *per module* (`:14` iterates
every non-vendor `go.mod`), so the true inner sum is `2 × GATE_TIMEOUT × module-count`.
`ovn-kubernetes` has 3 modules → up to `2×300×3 = 1800s`, which blows past any fixed
outer bound and makes the orchestrator SIGTERM a *healthy* companion, forging a
spurious `.crash`/defer. The outer bound must exceed the sum of the inner bounds:
give the orchestrator its own `GATE_OUTER_TIMEOUT` computed as
`2 × GATE_TIMEOUT × (module-count)` (count non-vendor `go.mod` at spawn time), not a
fixed default — a fixed `900` is only a single-module floor. Small change, but it
prevents the whole crash/defer machinery from firing on slow-but-fine multi-module repos.

*Landing order within Phase 0 (two crash-detection PRs plus optional housekeeping):*
**P0a** — crash detection: the `_gate_trap` rewrite (b), orchestrator rc-capture + `.crash`
write (b), `build-vet` inner-tool capture (d), `cmd_init` cleanup (c), and the **test-only**
harness `.crash` reader (b) (`test-skill.sh`; no production impact, separately testable).
**P0b** — timeout tiering (e). The `inc` guard (a) is defensive housekeeping (currently
unreached) — fold it into P0a or defer it; it fixes no live bug. `bash -n` the lib and
re-run the 4 lib companions after any lib edit to confirm zero regression. P0a's
`_gate_trap` rewrite MUST be in place before Phase 2's first `finish_evidence` conversion
(so converted gates inherit the `.crash`-not-FAIL semantics). Separate PRs beat one
reviewer-hostile bundle.

**Phase 1 — Fix the court, then measure (decision gate).** Three separable pieces:
*(base anchoring — the load-bearing court fix, do first)* the court decides "is this a
regression vs the **base**?", but only the **juror** prompt pins the base:
`cmd_court` computes `BASE_REF: $(git merge-base "$known_good" "$result_branch")`
(`test-skill.sh:1233`) — the *correct*, checkout-independent base — yet the
**prosecution/defense/judge** prompts (`:1188-1223`) receive only the two-way diff
(`:1111`) and the `$direction`/`$preexisting` prose (`:1126-1171`), which *name* "the
base branch" (`:1161`) but pin no ref. Those three roles have shell access, so they
default to the repo's ambient `HEAD` — **shared mutable state the court never resets per
version/repo.** Verified false-FAIL (`ovn-org/ovn-kubernetes` 1.34.1, branch `bump1.34`,
96 hunks — the best result ever produced, gate-completion PASS, court FAIL, 2026-08-15):
the repo was parked at `HEAD=f261f146c` (a stale `_test-from-f261f146` checkout, **1546
commits / ~8 months AFTER** the true base and **not an ancestor** of `bump1.34`). Against
that future tree `cni.go` carried an `apierrors` import + a richer `cmdDel` the true base
lacked, so all six roles "confirmed" phantom removals — a nonexistent `undefined:
apierrors` compile break and a DPU-cleanup "regression." Ground truth against the true
base `a32f6388` (= `merge-base(known_good, bump1.34)` = config `from_commit`): `git diff
a32f6388 bump1.34 -- go-controller/pkg/cni/cni.go` is **0 lines** and `go build ./...`
exits 0 — the rebase correctly left the file untouched. The juror `BASE_REF` didn't save
it: the jurors were flooded by the pros/def/judge briefs already anchored on `f261`, and
their required `VERIFIED:` lines cite `@f261f146c`, not `BASE_REF`. Generality: re-diffed
against the true base, **every** flagged count collapses — `cni.go`/`egressip.go`/
`kind-common` are 0-line diffs (pure phantoms), and the only real rebase changes
(`e2e-kind.sh` `v1.33`→`v1.34`, `conformance/go.mod` k8s dep bumps) match the human's or
are minor version skew, never a regression vs base — so a correct anchor repairs the whole
verdict, not just one file. **Fix (enforcement, not instruction — the prior design already
*gave* jurors a correct `BASE_REF` at `:1233` and they were still swayed, so more prose
won't hold).** Four parts. **(a) Cut the HEAD-leak vector at its source:** prosecution/
defense/judge reason purely over the in-prompt diff and need *no* git — today they inherit
`bypassPermissions` (all tools), which is how `f261` entered as "evidence." Run them with
tools disabled (no `Bash`/`Read`) so an arguer can only cite the provided diff and can no
longer manufacture a phantom `@f261f146c` file-read for the jury to follow. **(b) Bind the
jurors' tools:** jurors *do* need git to verify, but their `--allowedTools` allow-list
(`:1230`) is a **no-op under `bypassPermissions`** — drop bypass for them so the read-only
list (`git show/diff/log`, `Read`) actually binds and `git checkout/reset` is impossible.
**(c) Anchor the base authoritatively:** the result branch is *definitionally* built from
config `from_commit` (`cmd_run --from-commit`, `:480`), so `from_commit` — **not**
`merge-base` — is the result's true pre-rebase base; pass it into `cmd_court` (resolved in
`cmd_court_all`'s per-version config context, `:1328-1364`; `merge-base(known_good,result)`
only as the fallback for a manual `make court` with no config). Guard with `git merge-base
--is-ancestor "$base_ref" "$result_branch"` (and `… "$known_good"`) → INCONCLUSIVE on
failure: that single check deterministically rejects a parked/misconfigured base (`f261`
is *not* an ancestor of `bump1.34`) instead of silently judging against a future tree. Do
**not** gate on `merge-base == from_commit` equality — human and AI legitimately rebase
from different bases, and that would false-INCONCLUSIVE good runs, eroding the coverage
metric below. **(d) Thread the ref into every prompt AND the prose:** inject `BASE_REF`/
`RESULT_REF` into the prosecution/defense/judge prompts (which today get neither) *and*
rewire the PASS/FAIL prose (`:1160-1167`) — it still says "the base branch" abstractly —
to read *"base = `BASE_REF`; test pre-existence via `git show BASE_REF:<path>` only."* Drop
the earlier detached-checkout idea: the `running/` marker is version-scoped (`:1341`) so
cross-version courts would race the shared clone, and it would put the *result* tree at
HEAD (the wrong tree for the "did it pre-exist?" question) — part (a) makes it unnecessary.
This is sequenced **first** because a base-misidentified court manufactures false-FAILs,
so measuring reliability before fixing it measures the court's bug, not the subagents'.
*(metric)* the go/no-go for the rollout is **court verdict / false-FAIL rate on the
post-`pr-feedback-resolution` stripping baseline**, plus per-gate latency (so the cost
of adding scripts is visible) — NOT subagent count, which measures cost not the
reliability at issue. **Source precisely:** the court verdict is **not** in
`results.tsv` — that file's col-5 is the *gate-completion* verdict from `_tally_gates`
(`test-skill.sh:1013/1079`); the court verdict is written separately to
`court/${VERSION}_${repo_key}` (`:1585`) and `rm`'d on record (`:1016`). So the
committed metrics snapshot must **join** the `results.tsv` row with the court verdict
(and a recomputed known-good hunk count) per repo/version. Define false-FAIL
concretely: *known-good input (court says good) but a blocking non-`info` gate FAILed*
— explicitly **excluding** infra fails (stale/no-branch, missing gates,
session-ended), which are not reliability signals. *(court juror tool use)* jurors are
granted tools yet 0/15 call one (step-isolation §6); forcing tool use is prompt
research with uncertain yield — it sharpens the *measurement*, it does not gate the
next phase. Decision: after the Stop-hook fix (91% adherence) and the stripping
rewrite, does subagent reliability still bind? Baseline (local `results.tsv`
snapshot 2026-08-13; `test/.matrix-state/` is gitignored, so these are **provisional**
and must be pinned to a committed metrics file before they gate the decision):
aggregate spec=all 221/312 (71%), spec=none 32/63 (51%); the recent window is
healthier — last 21 spec=all 20/21 (95%), last 24 spec=all 23/24. 1.35.3/spec=all is
83/111 (75% all rows, 91% excluding infra-fails — stale/no branch, missing gates,
session-ended — and 9/10 in the last 10 runs), *not* the regression an earlier draft's
"12%" implied (that was the spec=none PASS *count*, 12/24, misread as a percent). The
true low-water slice is `ovn-org/ovn-kubernetes` at 16/36 (44%, all specs). Mixed, not
solved. **If it no longer binds, stop after Phase 0.**

*(checkpoint, not a one-shot)* This same measurement is the **regression gate for
every later phase**, not just the go/no-go. Re-run the matrix after Phase 2 (execution
unified) and again after Phase 3 (evidence content) against the *committed* metrics
baseline, and require **no pass-rate regression and no new false-FAIL** before the
phase is considered landed. Pin the baseline to a committed file first (the snapshot
above is gitignored/provisional). Define rollback concretely: each phase lands as its
own PR (per the "one PR per phase" cadence), so a regression reverts that single PR —
Phase 2's transport rewrite and Phase 3's per-gate evidence are independently
revertible, and the fixture promotions (Phase 4) revert to `evidence` (the always-safe
default) without touching the transport. A phase that regresses the metric does not
advance to the next. **Handle the AI-run variance in the gate itself:** the matrix is
nondeterministic — the numbers above swing run-to-run (`ovn-org/ovn-kubernetes` 16/36
vs a 95% recent window) — so a single sample cannot bound it. Require any **apparent
aggregate regression to be confirmed by a re-run** before it blocks a phase, and
compare **per-repo against a fixed repo/version set**, not one aggregate number. (A
full N-run mean±CI is impractical — each matrix run is a large AI fan-out — so
confirm-by-rerun + per-repo is the right-sized variance control.)

**Phase 2 — Unify execution + wire the single transport (the foundation).** Only if
Phase 1 binds. **First sub-step — install the evidence transport, exercised on landing**
(deferred from Phase 0, where it would be dead code): add `_head_sha`/`_write_evidence`/
`finish_evidence` to `gate-script-lib.sh` alongside the retained `finish_gate`, **in the
same PR that converts the first companion below** — so CI exercises the new functions
immediately. "Atomic" here means API-and-caller *together*: an API-only PR would just
relocate the Phase-0 dead code into Phase 2. Add only what Phase 2 actually calls —
`finish_evidence` — since Phase 2 converts every companion to it; `finish_filter` and
`finish_deterministic` land in **Phase 4** with their first promotion, and `finish_info`
is omitted entirely (no `info` gate has a companion, so it would never be exercised). Same
introduce-with-caller rule, applied per shape. **Each new `finish_*` MUST end with `trap -
EXIT; exit 0`, exactly
as `finish_gate` (lib:75-76).** The `_gate_trap` guard is nonzero-only (`[[ $exit_code -ne
0 ]]`, lib:19-20), so a clean `exit 0` never trips it; the risk is a `finish_*` that
*neither* `exit 0`s *nor* clears the trap and falls off the end with its last command's
status — on the found-issues path a failing `[[ "$issues" -gt 0 ]]` (rc 1) — which, under
Phase 0(b)'s `.crash`-writing trap, self-reports a phantom crash. The explicit `exit 0`
forecloses this on every path; clearing the trap is belt-and-suspenders. Then:
Make the orchestrator the single runner (per "Execution model"):
steps 1-3 call `orchestrator gates <step>` first, mirroring step 4; each gate `.md`
gains a fixed *read-your-evidence-file* instruction (convention discovery — no
main-agent path relay). Scope: the **6 run-companion "MANDATORY FIRST STEP" blocks**
(the 6 companions) + the step-1-3 spawn wiring — *not* the "MANDATORY pre-existing
check" base-filter blocks (9 in non-companion files + the 3 co-located in companion
gates = 12 total), which stay. **Also in scope: the step-1-3 gate-fix re-run loops**
(`step1-rebase.md:96-99`, `step2-compilation.md:177-180`, `step3-autofix.md:102-108`),
which today "rm the report and re-launch the subagent." With the in-subagent
companion run removed, a bare re-launch would judge with **stale** evidence — so the
re-run must re-invoke `orchestrator gates <step>` to regenerate evidence at the fixed
HEAD before re-launching. Miss this and the fix loop silently re-judges old facts.
Step 4's own gate-fix loop (`step4-verification.md:71-76`) already routes through
`orchestrator gates 4` (it is the reference the steps-1-3 wiring mirrors), so its
correctness is already protected by the consumer freshness check; add a one-line note
that after its fix commit it must re-invoke `orchestrator gates 4` too — a
**value/consistency** touch (so the re-judged gate keeps its evidence instead of
degrading to judge-from-scratch), not a correctness fix.

Atomic per companion gate, in one edit so no intermediate state strands it:
1. Convert its companion `finish_gate` → `finish_evidence` (for `crd-validation`/
   `patterns-completeness`, which today only echo `NEW_ISSUES=` to stdout and write
   no file, add the evidence-file writer). Safe here *without* the Phase-4 fixture
   test because `finish_evidence` always defers — writes no verdict, cannot
   false-anything. Without this step Phase 2 would strand the gate: no live companion
   writes a `.evidence` file (`finish_gate`'s dirty path only echoes to stdout,
   `gate-script-lib.sh:68-72`), so the transport's `[[ -f "$ev" ]]` check finds
   nothing and — once the block is gone — the subagent gets no facts. **Hazard for
   `crd-validation`/`patterns-completeness` specifically:** to call `finish_evidence`
   they must `source` the lib, which runs `set -euo pipefail` at its top level
   (`gate-script-lib.sh:13`) *and* installs `trap _gate_trap EXIT` (`:27`) — neither
   is in effect today (both scripts use `set -uo pipefail`, no `-e`, and source no
   lib). Under the imported `-e`, `crd-validation.sh:39`'s unguarded
   `crd_diff=$(diff <(echo "$base_crd") "$crd")` aborts the script on the **common**
   case (`diff` exits 1 whenever the CRD differs from base), firing the EXIT trap →
   spurious `.crash`/defer. So the conversion must guard those operations (`|| true`
   on the `diff` and the `git show` assignments) — or extract `_write_evidence` into a
   form callable without importing lib-level `set -e`. `patterns-completeness.sh`
   already `|| true`s its risky commands, so it is safe once sourced; `crd-validation`
   is not.
2. Add the `gates` call + add the `.md`'s read-your-evidence-file instruction (the
   fixed `.rebase-tmp/gates/<prefix>-<gate>.evidence` path) *while keeping* the FIRST
   STEP block; verify the deferred subagent receives identical facts via the file.
3. Remove the `NEW_ISSUES`/RULE-1 fast-path prose in the *same* edit — once the
   in-subagent run is gone, a RULE 1 that reads `NEW_ISSUES` references a value the
   orchestrator no longer surfaces to the subagent. The identical "set verdict=PASS
   immediately / Do NOT run the checks below" block lives in **all five** companion
   gates with a fast-path (`version-consistency.md:10-11`, `crd-validation.md:10-11`,
   `build-vet.md:10-11`, `major-version-imports.md:10-11`, `go-version-check.md:10-11`
   — grep-verified; `patterns-completeness.md` carries a PATH-A variant), so remove
   every instance here, not just the two. Leaving it in `build-vet`/`major-version-imports`/
   `go-version-check` (all of which run as `evidence` until fixture-proven) tells the
   subagent not to judge in exactly the gates re-classified to keep the judge — the
   principle-7 accelerant. (Pulled forward from Phase 3.)
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
`rebase-completeness`) — the point of the plan (but see the fix-correctness caveat
below). Adopt the lib + runtime module classification (§principle 6) in
`version-consistency` **only** — `feature-gates` needs a *different* companion (it has
zero go.mod/module logic: it greps `KUBE_FEATURE_`/`SetFromMap` refs excluding vendor
and checks `vendor/k8s.io` symbol presence, then `finish_evidence`), so author its
`feature-gates.sh` around that, not module classification. Remove any
*remaining* "set PASS immediately / do NOT run the checks below" rubber-stamp
(§principle 7 — all five companion-gate instances are removed in Phase 2 step 3, so
this catch-all covers only any companion-*less* gate that grew one); make
every `SUMMARY:` neutral. Keep full judgment prose in each `.md` (the subagent
still reads it, for the crash fallback and the dirty path).

Per companion-less gate, authoring evidence is more than dropping a `.sh` in place:
each also needs its `.md`'s read-your-evidence + HEAD-freshness block (with the
`EVIDENCE_MISSING` breadcrumb on a path miss) **and** registration in the step-1-3
spawn + fix-loop wiring (Phase 2), or the orchestrator never runs it. And the facts
differ per gate: `rebase-completeness` → its five existing counts;
`type-conversions` → the changed conversion sites + the vendor struct's field list
(*not* a scalar count — a count is the exact proxy §4 rejected). **`fix-correctness`
is the exception: its predicate ("is each applied fix semantically correct?") has no
sound deterministic value a script can compute, so it stays a pure-judgment
**no-companion** gate — do not author a `fix-correctness.sh` just for symmetry.**

**Phase 4 — Fixture test → promote proven predicates.** Build the fixture harness
(reuse the `.repos` scaffolding; a new target) — each promotion candidate run
**across the `.repos` corpus** (which already spans repos and k8s versions), against
known pre-existing/cross-file breakage, asserting **zero false-FAIL AND zero
false-PASS**. A single-repo fixture proves absence-of-failure on that repo, not the
"generalize across repos and k8s versions" bar principle 3 demands, so the fixture set
must span the corpus, not one repo.
This is the unconditional precondition for *any* autonomous verdict — a
`deterministic` FAIL/PASS *and* a `filter` clean-PASS. Only now may `build-vet` etc.
adopt `finish_filter`, and `major-version-imports`/`go-version-check` adopt
`finish_deterministic` — **adding those two functions to `gate-script-lib.sh` in the same
PR as the first promotion** (deferred from Phase 2 for the same no-dead-code reason:
nothing calls them until a gate is promoted); expect few to qualify. A gate that can't prove its predicate
stays `evidence`. Two fixtures are mandatory for the promotions this phase gates:
(a) a **killed-tool** case for `build-vet` (SIGKILL/timeout a
`go build` mid-run) — the promoted `filter` must **defer, not PASS and not FAIL**
(principle 4); (b) a **no-base** repo for `major-version-imports`/`go-version-check`
(empty `BASE` — no merge-base) — the promoted `finish_deterministic` must degrade to
`finish_evidence` and defer, not flag-everything into an autonomous FAIL (see below);
(c) a **valid-`BASE`, multi-module repo whose go directives are inconsistent but
pre-existing** for `go-version-check` — the promoted verdict must **defer/PASS, not
FAIL** (it must not fire on the un-base-filtered `:17-25` check; this fixture is what
proves the `:17-25` base-filter fix above actually holds).

**Phase 5 — Consolidation.** Re-audit live state (0% done). Reconcile the count
across `autofix-patterns-redesign.md`/`next-work.md`. Drop `logical-completeness`;
fold `ci-readiness` → `ci-prediction`; decide the contested `commit-messages` →
`maintainer-review` merge; narrow `deprecated-api-remnants` to web-search discovery. `EXPECTED_GATES` is dynamic (`test-skill.sh:139`) so a count
drop auto-adjusts, but `INFO_GATES` (`:21`, 4 gates) is hardcoded — update it in the
same commit if the info set changes. Two **hardcoded launch lists** in the step docs
also drift the moment a gate is dropped/folded and must be updated in the *same*
commit as each change: `step3-autofix.md:79` (names `logical-completeness` and a
gate count) and `step4-verification.md:65-69` (a literal "15 gates:" list including
`ci-readiness`/`commit-messages`/`logical-consistency`/`ci-prediction`). After each
drop/fold, `grep -rn` the dropped gate name across `skills/` + `gates/` to catch any
dangling reference before landing.

## Production backstop (recommendation)

Evidence-in closes hallucination but not satisficing, and the court is **test-time
only** (`test-skill.sh` + its Makefile target + `config-1.35.yaml`; zero refs in
`skills/`/`scripts/`/`gates/`/`hooks/`). Human + CI at the PR boundary do not catch
a silent semantic drop (a removed struct field that still compiles and passes unit
tests). **Recommendation: do both, cheaply.** (1) Always emit a *semantic-risk
manifest* in the draft-PR body listing the AI-judged-not-machine-verified gates so
the human reviewer is aimed at the unverified surface. **Derive this list
programmatically, not by hardcoding** — the "unverified surface" is exactly the set
of gates whose final report the *subagent* wrote (every `evidence` gate, plus any
`filter`/`verdict` gate that took its dirty/defer branch); a hardcoded triple
(`type-conversions`, `k8s-changelog`, `logical-consistency`) rots the moment a gate's
shape changes. But deriving it is **not** a free read of existing state:
`write-gate-report.sh` persists only `HEAD`/`VERDICT`/`ISSUES`/`SUMMARY`/`DETAILS`
(no writer field), and the companion (`finish_*`) and the subagent write
**byte-identical** reports — so *who* wrote a report is not recoverable from disk, and
step 5 is un-orchestrated (`orchestrator.sh:21`, `STEP_DIRS` = steps 1-4) so it lacks
the orchestrator's transient runtime knowledge. Keying off `.evidence`-file presence
is **insufficient**: the companion-less judgment gates the manifest most targets
(`type-conversions`, `fix-correctness`, `rebase-completeness`) and crash-fallback
gates write no `.evidence`, so they would be silently dropped. So the manifest
requires **persisting a writer marker** at report-write time (e.g. a `WRITER:
subagent|companion` field) — budget it as real step-5 work, not a free read of
provenance the orchestrator does not durably keep. (2)
Promote one adversarial juror to a *single pre-PR production gate* (one AI call with
git show/diff/Read) — the real backstop, trivial against a plan whose premise is
spending AI calls on quality. The manifest is free insurance; the juror is the catch.

**Home and phasing.** Both live in **step 5** — the same un-orchestrated step that
owns the H1 `INCOMPLETE` surfacing (below) and PR-body generation
(`step5-pr.md:30-35`) — so all three PR-body additions land in one seam. The *decision*
(ship both, one, or explicitly defer) is made before Phase 3 ships; the *build* is a
step-5 work item, deliberately outside this plan's steps-1-4 scope. **Headless
behavior:** the skill only ever prints, never pushes (`rules.md:33`), so in a headless
run (test harness / cron, no human) the manifest is still written into the printed PR
body and the juror still runs as its one AI call — but there is no reviewer to act on
either, so headless runs must treat a juror FAIL as a hard stop (surfaced like any
blocking gate) rather than relying on the human the manifest assumes.

**Deferred gap — force-advanced (incomplete) rebases surface nothing to the human.**
Today `cmd_advance` writes `status/INCOMPLETE` (`orchestrator.sh:305,310`) that no
consumer reads, then `cmd_status` reports `DONE: true` and step 5 prints an ordinary
`gh pr create` (`step5-pr.md:37`) — so a rebase that force-advanced past a stuck gate
produces a clean-looking PR command (see "Execution model"). The right fix lives in
step 5, which this plan deliberately leaves un-orchestrated: when `INCOMPLETE` is
present, step 5 should annotate the printed PR body with the force-advanced
gates (reusing the body it already generates, `step5-pr.md:30-35`) and MAY print
`gh pr create --draft` instead — an explicit, called-out behavior change to what the
human copy-pastes, never an executed push. Sequenced with the manifest above (same
draft-PR body, same "aim the human at unverified surface" goal); scoped as future
work so it does not expand this plan past steps 1-4.

**Out of scope (skill-robustness, not gate architecture).** A session killed before
step 5 strands the push-blocking pre-push hook (`k8s-rebase.sh:47-54`) and
`.session-active` (`orchestrator.sh:157`), which re-arm the push/module-op/Stop guards
for later sessions in that clone. The fix belongs at the **teardown seam** — a
session-scoped trap, or a PID/heartbeat in `.session-active` the hooks treat as stale
when the owner is gone — **not** in `cmd_init`, which cannot distinguish a dead prior
session from a live concurrent one (`.session-active` is PID-less) and would defeat
push protection mid-run. Filed here so it is visibly deferred, not silently absent;
orthogonal to the steps-1-4 gate redesign.

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Evidence file unconsumed by the judge (the draft's core bug) | High | Single-runner transport + **convention-based discovery**: orchestrator writes report-or-evidence once; each gate `.md` names its own `.rebase-tmp/gates/<prefix>-<gate>.evidence` path so the subagent reads it directly (no main-agent path relay to forget); `_write_evidence` also `tee`s to stdout for the migration overlap. |
| Main-agent path relay drops evidence silently (rejected alternative) | High | **Not adopted.** Relaying each `EVIDENCE:` path through the main agent's prompt fails the first time it forgets one while iterating lint fixes — a write-only regression. Convention discovery removes the main-agent *relay*: the subagent reads its evidence by a path it derives itself. |
| `filter` clean-PASS / `verdict` false-something on an unsound predicate | High if unguarded | Phase-4 fixture proof (zero false-FAIL AND false-PASS) is the precondition for any autonomous verdict; default `evidence` cannot false-anything. |
| Dropping the FIRST STEP block strands a companion gate (no live companion writes a `.evidence` file) | Medium | Phase 2 converts `finish_gate`→`finish_evidence` (which writes the file) in the *same* per-gate edit that drops the block, after verifying the subagent reads identical facts; the 3 co-located base-filter blocks in the companion gates are surgically preserved (Phase 2 step 4), and the 9 non-companion base-filter blocks are untouched. |
| Evidence-in amplifies satisficing (verdict-shaped SUMMARY, "set PASS" instr.) | Medium | Neutral fact-only `SUMMARY:`; Phase 3 removes the rubber-stamp instruction; court measures residual. |
| Freshness oversold — HEAD drifts during step-4's concurrent lint commits | Medium | **Decided (not Open):** keep the deliberate 4a‖4b concurrency — drift degrades safely (consumer judges from scratch, and `report_is_fresh:122-133` already forces a re-run so no autonomous verdict is ever stale). Extend the per-iteration evidence regeneration mandated for steps 1-3 (Phase 2) to step 4's fix loop so evidence-in *value* survives re-runs, and gate `filter`/`verdict` **promotions** on a settled HEAD (`--no-test` exit 0). This is churn-avoidance + documentation, not a new correctness backstop; do **not** blanket-serialize step-4 consumption. |
| Runtime module-classification fetch fails (GOPROXY offline / target tag unpublished) | Medium | Degrade to raw module/version evidence + `SUMMARY:` noting unavailable, defer; never a stale table or flag-everything. |
| Crash hides as "missing" | Medium | The in-script trap covers ordinary nonzero exits; the dominant `timeout -s TERM`/SIGKILL crash is invisible to it (exit 0 / no trap), so the *orchestrator* writes the `.crash` breadcrumb when the child exits `124` (timeout) or `>128` (signal). Breadcrumb + harness reader ship together (Phase 0). NB: force-advance does **not** rescue this in production — `INCOMPLETE` is write-only (see "Execution model"); the human-facing surfacing is the deferred gap in "Production backstop". |
| `evidence` shape raises wall-clock (adds a script, never drops the subagent) | Low-Med | Accepted trade; Phase 1 records per-gate latency so cost is visible. |
| Court false-FAIL from base misidentification (corrupts the Phase-1 go/no-go metric) | High | Pros/def/judge prompts pin no base and inherit `bypassPermissions` (all tools) → default to ambient `HEAD` (stale shared checkout, e.g. 1546 commits off). Phase-1 fix is *enforcement*: disable git for pros/def/judge (they only need the in-prompt diff), bind jurors' read-only allow-list by dropping bypass, anchor `BASE_REF` to config `from_commit` (authoritative; merge-base fallback) with an `--is-ancestor` guard → INCONCLUSIVE, and thread `BASE_REF` into all prompts + the PASS/FAIL prose. Verified case: `ovn-org/ovn-kubernetes` 1.34.1 false-FAIL where every flagged file is 0-diff-from-base or minor scope skew. Do before measuring. |
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
