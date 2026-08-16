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

This is the **single authoritative template** — paste it verbatim into each converted gate
`.md` (Phase 2 step 2, Phase 3 for companion-less gates), substituting only the literal
`<prefix>-<gate>` for that gate; do not re-word it per file, or the freshness phrasing and
fallback drift across the 6+ gates that carry it:

```markdown
EVIDENCE (read before judging): if `.rebase-tmp/gates/<prefix>-<gate>.evidence` exists,
run `git rev-parse HEAD` and compare it to the file's `HEAD:` line.
- Match: Read the file first and treat its `SUMMARY:`/facts as ground truth for this gate.
- Differ (HEAD drifted since it was written) or file absent: the evidence is stale/missing —
  ignore it and judge this gate from scratch using the checks below. Do NOT PASS on the
  strength of absent or stale evidence.
```

The step-7 lint (below) additionally greps each converted `.md` for the literal marker
`EVIDENCE (read before judging):` so a file where the block was accidentally omitted fails
the build, not just one whose path drifted.

One hazard the convention introduces: the `<prefix>-<gate>` string now has **three
independent producers** that must agree byte-for-byte — the writer (`GATE_NAME`, built
in `init_gate` via `grep -oE '^step[0-9]+'`, `gate-script-lib.sh:37`), the orchestrator
locator (`evidence_path`/`report_path` via `${sd%-*}`, `:108`), and the literal path
written into each `.md`. These derive the prefix *differently* (a `grep` vs a suffix
strip); they happen to agree for today's `stepN-name` dirs, but that is a coincidence,
not a guarantee — so this plan does **not** claim they are "identical." Phase 2 must
either route all three through **one sourced helper** (`gate_artifact_prefix`) or add a
test asserting the three agree for every step dir. And the read-evidence instruction
must **degrade safely** on a miss: if the `.md`'s named path does not exist, the subagent
judges from scratch (no verdict is fabricated — the always-safe default). The failure this
guards against — a silent `<prefix>-<gate>` drift so the subagent reads a path the
orchestrator never wrote — is caught at **build time** by the Phase-2 step-7 lint assertion
(which proves the three producers agree for every step dir), not by a runtime breadcrumb: the
lint makes a drift a red build before it can ship, so no `EVIDENCE_MISSING` runtime artifact
(with its own path/writer/reader to specify and keep consistent) is added. The only other
miss cause — a companion crash, or a not-yet-authored companion — is already surfaced by the
`.crash` breadcrumb or is the expected companion-less PENDING path, both of which correctly
route to judge-from-scratch.

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
and judges (defer-not-fail). Treat these as load-bearing, not cosmetic. **Window hazard —
close it atomically in the same PR as (b):** during the Phase 0→Phase 2 interval the
companion `.md` FIRST STEP blocks are still live, so a post-(b) crash routes to a subagent
that re-runs the still-crashing companion via its MANDATORY block, then finds **no matching
rule** — RULE 1 needs `NEW_ISSUES=0`, RULE 2 needs flagged issues, and the fallback fires
only "if the companion script is **not found**" (a crash is neither) — so it improvises,
likely **PASS**, inverting today's crash→FAIL→block (`_gate_trap` today writes a FAIL
report, `gate-script-lib.sh:21-25`). This regression opens the moment (b) lands: the
`_gate_trap` rewrite is shared code, so it drops the crash→FAIL backstop for every
in-subagent companion run (steps 1-3) at once, and the orchestrator `.crash` change drops
it for the already-orchestrated step 4 — both in (b). Fix in the (b) PR: give **every**
companion `.md` a crash-safe fallback so a crash routes to manual checks (real judgment from
the diff), never a blind PASS. This is **not** a uniform substitution — the six companion
`.md` files fall into two shapes, so the (b) PR must touch each accordingly: **(i) widen an
existing companion-script trigger** in the four that carry one — `build-vet.md:17`,
`version-consistency.md:17`, `major-version-imports.md:16`, `go-version-check.md:16` — from
"if the companion script is not found" to "if the companion script is not found, **crashes,
or emits no `NEW_ISSUES` line**"; **(ii) add a new crash branch** to the two that have **no
companion-script fallback at all** — `crd-validation.md` (MANDATORY → RULE 1 → RULE 2 →
checks) *and* `patterns-completeness.md` (MANDATORY → PATH A → PATH B → checks). Note
`patterns-completeness.md:42`'s "If not found, rely on steps 1-3 above" is **not** a
companion-script fallback — its "If not found" refers to the optional patterns *doc*
`k8s-rebase-patterns.md` located at `:40`, not the companion script; widening it would fix
the wrong clause. Both group-(ii) files need an explicit new branch: "if the companion
script is not found, crashes, or emits no `NEW_ISSUES` line, run the manual checks and judge
from the diff — never PASS on unexamined output." **For `crd-validation.md` that branch must
author a *self-contained* from-scratch check body — it cannot just point at the existing checks
1-2, whose only scope is RULE 2's "For each CRD the script marked `CHANGED-VALIDATION`/`ALL-NEW`"
lead-in (`crd-validation.md:19`), a selector that does not exist when the script has crashed.**
So P0a authors, in that branch, a script-marking-independent scope: "**for each CRD schema file
in the repository, compare `git show $BASE:<path>` against the working copy** and flag any newly
removed/weakened validation constraint" — a body that stands on its own once the crash fires,
not one gated on script output. **That authored body must carry the same empty-`BASE` guard the
scripts do (principle 6, `:454-470`): when `$BASE` is empty, `git show $BASE:<path>` degrades to
`git show :<path>`, which resolves to the *git index* (≈ the working copy in a rebase-result
tree) and would compare each file to itself — finding nothing and PASSing silently, the worst
outcome. So the branch must instruct: if `$BASE` is empty (no merge-base), do not diff against
the base at all; judge every CRD's validation surface unfiltered and defer — never PASS on a
self-comparison.** These three clauses — the trigger ("not found, crashes, or emits no"), the
from-scratch scope ("for each CRD schema file in the repository"), and the empty-BASE guard
("never PASS on a self-comparison") — are the **verbatim sentinels** `check-phase1-baseline`
condition (v) greps for, so author them literally, not paraphrased — as **plain, contiguous prose
with no inline markdown** (`**`, backticks) *inside* the sentinel span. Condition (v) flattens
hard-wrapped lines before matching (so the wrapping in *this plan's* rendering of the phrases is
harmless), but it greps raw text: emphasis or a backticked token embedded *within* a sentinel — as
the group-(i) widen at `:510-511` bolds "crashes, or emits no" — would defeat the match, so keep
the group-(ii) sentinels unadorned. (`patterns-completeness.md`'s checks 1-4 are *already*
self-contained — check 1 finds modules and runs `go build`, checks 2-4 use `git
diff`/`merge-base`, none reads script output — so its new branch may point at "run checks 1-4"
with no rewrite; **only `crd-validation` needs the authored from-scratch scope.**) This is the
body Phase 2 step 4 later promotes to "the checks below"; authoring it here (not implying it in
step 4) is what keeps that promotion pointing at real prose. Landing both shapes in the (b) PR
keeps the semantic change and its consumer-side handling together, so no interval opens.
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
tool's exit code *before* `|| true` — errexit-safe, with the `.crash` write spelled out
(the canonical path from Phase 0(b), keyed off `$GATE_NAME`), not pseudocode:

```bash
build_rc=0; build_out=$(timeout "${GATE_TIMEOUT:-300}" go build ./... 2>&1) || build_rc=$?
if (( build_rc >= 124 )); then
  mkdir -p "$REPO/.rebase-tmp/gates"
  printf 'CRASH: exit %s (inner-tool kill)\n' "$build_rc" > "$REPO/.rebase-tmp/gates/${GATE_NAME}.crash"
  trap - EXIT; exit 0                       # defer — NO report written
fi
```

(defer, **never FAIL** — a FAIL from a
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
spurious `.crash`/defer. The outer bound must exceed the sum of the inner bounds: give the orchestrator its own
`GATE_OUTER_TIMEOUT` computed as `2 × GATE_TIMEOUT × module-count`, not a fixed default —
a fixed `900` is only a single-module floor. Count modules with the **same `find` as
`build-vet.sh:14`** (`find . -name go.mod -not -path '*/vendor/*'`), so the bound tracks
whatever build-vet will loop over (e.g. a repo with a `.claude/` worktree present exposes
more `go.mod` than the 3 canonical ones). This raw `find` count is a deliberate
**conservative upper bound**, not build-vet's exact inner-loop count: `build-vet.sh:15-18`
*skips* (via `continue`) any module whose `vendor/` is gitignored, so its real inner-tool
invocations are ≤ this count. Overcounting only makes the outer `timeout` fire later — the
safe direction (it never SIGTERMs a healthy companion); a precise bound would replicate the
`git check-ignore` skip, not worth the coupling. Apply the bound uniformly — a non-build-vet
companion doesn't loop per module, so `2 × GATE_TIMEOUT × N` is simply a harmless-larger
ceiling for it; no per-companion detection needed. Concretely,
in `cmd_gates`, before the `timeout … bash "$companion"` call:

```bash
# Outer bound must exceed build-vet's inner sum (2 tools × GATE_TIMEOUT × modules).
# Count modules the SAME way build-vet.sh:14 does, so the bound tracks its real loop.
local _mods; _mods=$(find "$repo" -name go.mod -not -path '*/vendor/*' 2>/dev/null | wc -l)
(( _mods < 1 )) && _mods=1
local GATE_OUTER_TIMEOUT=$(( 2 * ${GATE_TIMEOUT:-300} * _mods ))
rc=0; output=$(timeout "$GATE_OUTER_TIMEOUT" bash "$companion" "$repo" 2>&1) || rc=$?
(( rc >= 124 )) && printf 'CRASH: exit %s\n' "$rc" > "$crash"
```

Small change, but it prevents the whole crash/defer machinery from firing on
slow-but-fine multi-module repos.

*Landing order within Phase 0 (two crash-detection PRs plus optional housekeeping):*
**P0a** — crash detection: the `_gate_trap` rewrite (b), orchestrator rc-capture + `.crash`
write (b), the **companion `.md` crash-safe fallbacks** (b) — this is the *consumer* half of
the `_gate_trap` change and MUST co-land in the same PR (see the window-hazard fix above):
widen the trigger in `build-vet.md`/`version-consistency.md`/`major-version-imports.md`/
`go-version-check.md`, and add a new crash branch to `crd-validation.md`/
`patterns-completeness.md` (which have none) — `build-vet` inner-tool capture (d), `cmd_init`
cleanup (c), and the **test-only** harness `.crash` reader (b) (`test-skill.sh`; no
production impact, separately testable).
**P0b** — timeout tiering (e). The `inc` guard (a) is defensive housekeeping (currently
unreached) — fold it into P0a or defer it; it fixes no live bug. `bash -n` the lib and
re-run the 4 lib companions after any lib edit to confirm zero regression. P0a's
`_gate_trap` rewrite MUST be in place before Phase 2's first `finish_evidence` conversion
(so converted gates inherit the `.crash`-not-FAIL semantics). Separate PRs beat one
reviewer-hostile bundle.

**Phase 1 — Fix the court, then measure (decision gate).** Three separable pieces.

**Required implementation sequence for Phase 1** (mirrors "Landing order within Phase 0"; the
ordering constraints below are load-bearing, not stylistic — the prose that follows states them
only as subordinate clauses, so they are collected here as a checklist):
1. Implement the court fix, all four parts — (a) disable tools for prosecution/defense/judge,
   (b) bind the jurors' allow-list, (c) anchor `BASE_REF` to `from_commit`, (d) thread the ref
   into every prompt + the prose. (Part (c) is the load-bearing fix — land it first within this
   step; the base-anchoring subsection below marks it "do first.")
2. Ship `assert-court-permissions.sh` and confirm it writes `PASS` to
   `test/metrics/assert-court-permissions-result.txt`. **Must precede step 4** — a baseline
   measured against a still-wide-open court is meaningless. If the durable streak counter reaches
   3 consecutive `INCONCLUSIVE` runs the probe writes `PROBE-BROKEN` to that file (per its spec
   above) — **stop and debug the probe** (creds / transcript / prompt) rather than proceed. Any
   non-`PASS` value blocks; never proceed on an unresolved result, and never hand-edit the file to
   `PASS`.
3. Drop the `cmd_court_all:1340` PASS-only filter (so gate-FAIL rows are courted and the
   false-FAIL numerator is non-empty) and make the per-spec court-history writes + the analyzer.
   **Must precede step 4** — courts run before the filter drop produce a structural 0% history
   that `check-phase1-baseline`'s consistency math still passes, silently.
4. Run the courts (the matrix), populating `test/court-history.tsv`.
5. `make court-metrics`, then `make commit-court-baseline` to commit the raw log +
   `test/metrics/court-baseline.tsv` together. Then snapshot the **frozen** regression anchor once
   here with `make freeze-court-anchor` (a guarded `cmd_freeze_court_anchor` — **not** a manual
   `cp`): it refuses to freeze a baseline that contains any `INCON` repo (which would be permanently
   unmonitored) or to overwrite an existing anchor, then copies this Phase-1 `court-baseline.tsv` to
   `test/metrics/court-baseline-phase1.tsv` and commits it. Later phases compare against this fixed
   file and `commit-court-baseline` never rewrites it. **Freeze here, before any Phase-2 matrix run
   — a late freeze would capture Phase-2-polluted data; the roll-forward guard in
   `commit-court-baseline` (step (2) above) mechanically enforces this by refusing to advance the
   baseline while the anchor is still absent.**
6. Record and commit `test/metrics/phase1-decision.txt` (chosen branch + measured rates).
7. Run `make check-phase1-baseline` — the mechanical gate over steps 2/5/6 (conditions i–vi).

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
tools disabled so an arguer can only cite the provided diff and can no longer manufacture a
phantom `@f261f146c` file-read for the jury to follow. **Exact substitution** (do not leave
"tools disabled" as prose — `PERMISSION_MODE` is a *global* at `:17`, so each role must pass a
literal, not inherit it): replace `--permission-mode "$PERMISSION_MODE"` on the prosecution
(`:1188`), defense (`:1194`), and judge (`:1209`) invocations with `--permission-mode default
--disallowedTools 'Bash,Read,Edit,Write,Glob,Grep,WebFetch,WebSearch'` — under
`--permission-mode default` (not bypass) an explicit disallow blocks the tool outright, and a
headless `-p` run has no prompt to fall back to. (Removing `--allowedTools` alone would be a
no-op, and merely omitting `--permission-mode` still inherits nothing safe; name the flags.)
**(b) Bind the jurors' tools:** jurors *do* need git to verify, but their `--allowedTools`
allow-list (`:1230`) is a **no-op under `bypassPermissions`** — replace the juror's
`--permission-mode "$PERMISSION_MODE"` (`:1229`) with the literal `--permission-mode default`
so the existing read-only `--allowedTools` (`git show/diff/log`, `Read`) actually binds and
`git checkout/reset/commit/push` is impossible. A developer who only edits `--allowedTools`,
or substitutes another still-bypassing mode, ships a no-op — and because the fix is invisible
to the aggregate false-FAIL metric (a still-bypassing court just reads noisier, which
`check-phase1-baseline` cannot distinguish from "fix not applied"), the verification cannot
remain prose. **Ship a concrete harness assertion as a Phase-1 deliverable:**
`test/assert-court-permissions.sh` (or a `cmd_assert_court_permissions` in `test-skill.sh`)
that launches a minimal role with the *new* flags and asserts the role's `git checkout`/write
attempt is **blocked by the permission layer** while a `git show` in the same role *is* allowed.
Assert on the **permission decision, not the git command's exit code**: a bare `git checkout`
exits nonzero for many non-permission reasons (not a repo, missing ref, dirty tree, nothing to
check out), so an exit-code test would green-pass a wide-open court whenever the checkout happens
to fail for an ordinary reason — exactly masking the regression the probe exists to catch. The
**primary and sufficient** assertion is a **two-part check on a `--output-format stream-json
--verbose` transcript: the denied op was *attempted* (a `Bash(git checkout …)` `tool_use` event
is present) AND it was *denied* (its paired `tool_result` is `is_error` carrying the
permission-denial text — not executed).** Both parts are load-bearing: "attempted" alone can't
distinguish denial from success, and "denied" without "attempted" passes vacuously when the model
never tried. **Name the format precisely:** plain `--output-format json` emits only a *single
result object* (no per-tool events — `claude --help`: `"json (single result)"`), so the probe
must use `stream-json --verbose`, which streams the `tool_use`/`tool_result` pair; denial surfaces
there as an errored `tool_result` on the git `tool_use`, **not** a dedicated boolean, so parse for
that errored pairing, not for a "denied" flag. **The probe must also run under the *fixed* role
flags, never the harness default:** `PERMISSION_MODE` is `bypassPermissions` at `:17`, and under
bypass the permission layer denies nothing — so the probe launches its role with a literal
`--permission-mode default --disallowedTools 'Bash,…'` (the same substitution (a) makes) and must
not inherit `$PERMISSION_MODE`, or it green-passes a wide-open court and can *never* emit a denied
event. **Do NOT rely on an unmutated-repo fallback as the
decision** — it carries the *same* exit-code ambiguity this spec already rejects: `git checkout
-b <name>` that the permission layer *blocks* leaves the repo unmutated, but so does a `git
checkout <nonexistent-ref>` that *executed* and merely failed — the two are indistinguishable by
repo state. "No new branch created" is at most a secondary sanity arm, never the assertion.
**Specify the probe concretely so "attempted" is unambiguous:** instruct the role to run `git
checkout -b <name>` — a mutating op. But read "executed vs denied" from the `tool_result`
(errored-with-permission-text = denied; success = executed), **not** from whether the branch
exists: a name collision on a persistent scratch repo fails benignly (branch already exists,
nonzero, no mutation) and would masquerade as "not executed." Two guards keep the signal clean —
create the probe's scratch repo **fresh per invocation** (`mktemp -d`; `git init`; one throwaway
commit) so `git checkout -b` can never collide, and take the verdict from the paired
`tool_result`. A *present-and-denied* `tool_result` is the only clean signal, and a
*present-and-executed* one is an unambiguous FAIL (permissions not enforced). Caveat — this is a **live-model
integration check, not a unit test**: it spawns a real `claude -p` session (Vertex creds,
network, latency) against a scratch git repo and must reliably *induce* the role to attempt the
denied op to get a signal. **Distinguish "denied" from "the session never got that far":** a
result is only conclusive if the `git checkout -b` `tool_use` event is **present** in the
stream-json transcript — an empty tool record (auth failure, network timeout, no Vertex creds, or
the model declining in plain text without calling Bash) means the probe never exercised the
permission layer and MUST read as **INCONCLUSIVE (re-run required), never PASS**; only a
*present-and-denied* event is a PASS. **Bound the re-run loop so it cannot spin forever:** the
script keeps a **durable streak counter** `test/.matrix-state/probe-inconclusive-streak.txt`
(local bookkeeping — that path is gitignored, so the counter persists on disk across invocations
without being committed; only the result file's verdict is the committed cross-session signal) —
incremented on every `INCONCLUSIVE` run, reset to `0` on any conclusive `PASS`/`FAIL`, and **read as
`0` whenever the file is absent** (`count=$(cat "$streak_file" 2>/dev/null || echo 0)`, or the
`${x:-0}` idiom) — so a fresh clone, a deliberate deletion, or the first run on any machine starts
at `0` and never mis-fires `PROBE-BROKEN` before a probe has run. The counter thus survives across
separate invocations at this Phase-1 boundary instead of living only in the operator's memory. INCONCLUSIVE stays blocking and is *never* auto-converted to PASS,
but once the streak reaches **3 or more** the script stops treating it as transient and writes a
distinct fourth verdict, **`PROBE-BROKEN`**, to the result file (not another `INCONCLUSIVE`) — the
counter keeps climbing past 3 and the verdict stays `PROBE-BROKEN`, never flapping back to
`INCONCLUSIVE` — and emits a
diagnostic directing the operator to (1) check Vertex creds / network reachability, (2) inspect the
stream-json transcript to tell a prose-decline (the model never emitted the `git checkout -b`
`tool_use` at all) apart from an auth/transport abort, and (3) adjust the probe prompt if the model
keeps declining without attempting the op. The exit
criterion is **fix the probe, not lower the bar** — and *only* a conclusive `PASS` advances:
Phase 1 does not proceed until the probe returns `PASS`. A conclusive `FAIL` is **not** an exit —
it means court permission enforcement is genuinely broken (the court fix is unproven), so Phase 1
stays blocked per condition (vi) until the **court** is fixed, exactly as INCONCLUSIVE / `PROBE-BROKEN`
block until the **probe** is fixed. Condition (vi) enforces this mechanically — it reads *exactly*
`PASS` — so a `FAIL` can never be mistaken for an exit. This is a heavier deliverable than the pure-bash
`check-phase1-baseline`. **Persist its verdict** to a committed
`test/metrics/assert-court-permissions-result.txt` (`PASS`/`FAIL`/`INCONCLUSIVE`/`PROBE-BROKEN`) —
that file is what `check-phase1-baseline` condition (vi) reads, so any value other than `PASS`
(`FAIL`, `INCONCLUSIVE`, `PROBE-BROKEN`, or absent) mechanically blocks baseline measurement, not
just a checklist reminder. The `PROBE-BROKEN` value is what makes a *systematically* broken probe
distinguishable, hours later, from a single transient `INCONCLUSIVE`: a reviewer (or condition
(vi)) reading the committed file sees "debug the probe" versus "just re-run" without needing the
operator's live count. Wire it to a k8s-rebase
Makefile target and add it to the same pre-Phase-2 checklist
as `check-phase1-baseline`, so the court fix is proven effective *before* any baseline is
measured against it.
**(c) Anchor the base authoritatively:** the result branch is *definitionally* built from
config `from_commit` (`cmd_run --from-commit`, `:480`), so `from_commit` — **not**
`merge-base` — is the result's true pre-rebase base; pass it into `cmd_court` as a new
optional trailing arg: `cmd_court <result_branch> <known_good> <repo> [base_ref]`, where a
supplied `base_ref` wins and an empty one falls back to `merge-base(known_good,result)`
inside `cmd_court`. Update **both** call sites: `cmd_court_all:1364` passes it — but note `from_commit` is **not**
a standing variable in that loop (the loop resolves `short`/`kg`/`branch`, not `from_commit`),
so a developer must first add `local _fc=$(_config_val "$(repo_short "$repo")" "from_commit")`
inside the per-repo loop (the exact `_config_val` extraction pattern already at `:830`/`:882`)
and pass `"$_fc"` as the trailing arg; passing an undeclared `$from_commit` would silently send
empty string and degrade to the merge-base fallback. `_results_one:1577` (the `make
results --court` path) likewise resolves `from_commit` from `CONFIG_FILE` and passes it or
passes empty — an untouched `_results_one` degrades to the `merge-base` fallback (still
checkout-independent, **not** ambient-HEAD), so the consequence there is bounded. `merge-base`
remains the fallback for a manual `make court` with no config. Guard with `git merge-base
--is-ancestor "$base_ref" "$result_branch"` **only** → INCONCLUSIVE on failure: this is the
definitional relationship (the result was built via `cmd_run --from-commit base_ref`, so
`base_ref` *is* an ancestor of `result_branch`), and it deterministically rejects a
parked/misconfigured base (`f261` is *not* an ancestor of `bump1.34`) instead of silently
judging against a future tree. **Do NOT also require `base_ref` to be an ancestor of
`known_good`.** `known_good` is the human's independently-rebased branch; the plan already
states human and AI legitimately rebase from *different* bases, so `base_ref` need not lie on
`known_good`'s history at all — ANDing `--is-ancestor "$base_ref" "$known_good"` would
false-INCONCLUSIVE exactly the divergent-base runs where coverage matters most. The court
compares `result` vs `known_good` by two-way diff (`:1111`), which needs no shared ancestry;
pre-existence is tested via `git show BASE_REF:<path>`, which needs only `base_ref` on
`result`'s history — the check above. Likewise do **not** gate on `merge-base == from_commit`
equality (same divergent-base reason). INCONCLUSIVE here is a genuine misconfiguration
signal, so it is **excluded from the false-FAIL denominator** (like the other infra states)
rather than degraded — a base that is not an ancestor of its own result cannot be measured
against, and silently falling back to `merge-base(known_good, result)` would resurrect the
ambient-base ambiguity this fix removes. **(d) Thread the ref into every prompt AND the prose:** inject `BASE_REF`/
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
(`test-skill.sh:1013/1079`). The court runs **on demand, on a path separate from record**:
`cmd_court_all` writes the fresh verdict at `:1374` and `_results_one` (the `make results
--court` display path) writes it at `:1586`, each into a single point-in-time file
`court/${VERSION}_${repo_key}`. So the committed metrics snapshot needs the court verdict
paired with the courted run's gate verdict per repo/version/spec — **but that pairing is
unbuildable against live code and is a required first sub-step (code, before any
measurement):** that point-in-time file is a *cache*, not a
journal — `_do_record_one` `rm`s it at `:1016` (and the Phase-3 retry loop `rm`s it at
`:1792`/`:1808`) to invalidate it before the next run/court-retry — and the court verdict
of the run just recorded **does not exist at record time** (the court hasn't run yet), so
persisting "in `record()` before the rm" would capture only a stale prior verdict or
nothing. `_results_for_version` reads that same live cache (`:1615`) and shows `-`/`pending`
for any run whose on-demand court hasn't (re)run — the verdict is never journaled.

**Court the FAILs, not just the PASSes — the numerator lives in the gate-FAIL rows.** The
false-FAIL definition below is *court=PASS but a blocking gate FAILed*, so the numerator rows
are exactly the **gate-FAIL** runs. But `cmd_court_all:1340` (`[[ "$verdict" != "PASS" ]] &&
continue`) skips every gate-FAIL row before the court invocation at `:1364` — it courts only
gate-**PASS** results (historically, to double-check successes for false-*PASS*). So the
automated path structurally **cannot produce a single false-FAIL row**, and `make court-all`
would always report 0% — a vacuous signal. Fix: drop that `:1340` PASS-only filter so
`cmd_court_all` courts **every** resolvable row (both PASS and FAIL); this makes the
false-FAIL numerator *and* the false-PASS signal computable from one pass. The extra court
cost scales with the FAIL rate (gate-FAIL rows are now courted too): ≈1.4× the AI calls at the
spec=all baseline (~71% pass), up to ≈2× at spec=none (~51% pass). That cost is **inherent** to measuring
false-FAIL — there is no way to measure it without courting the FAILs. (Alternatively, keep
`:1340` and require a manual `make results repo=X --court` loop over each gate-FAIL repo — the
`_results_one:1577` path has no PASS filter and *does* court a FAIL repo — but name the exact
per-repo invocation as a required Phase-1 sub-step so the developer populates the history
correctly. The drop-the-filter option is preferred: it is automated and leaves no manual
step to skip.)

**Court per-`(version, repo, spec)`, and record the spec + gate verdict in the row.** A
single `(version, repo)` pair has **multiple** `results.tsv` rows — one per spec (col-3,
`:1013`) — and `cmd_court_all:1337` (`$3~/^all/ || $3=="none"`, `tail -1`) collapses them to
the single latest across *both* specs. A later spec-blind `(version, repo)` join would then
pair a spec=all court verdict with a spec=none results row from a different run, manufacturing
a spurious entry (the baseline's 71% spec=all vs 51% spec=none gap makes cross-spec
contamination common). Two coupled changes remove the join hazard at the source: (i) court
per-spec — include spec in both the court-cache key (`:1335`, today `${VERSION}_$_rk`) and the
latest-row selection (`:1337`), so each spec run is courted and cached independently; (ii)
have the court **record what it courted** — do not reconstruct it later. Fix at the **write**
sites, not the record path: at both `cmd_court_all:1374` and `_results_one:1586`, in addition
to the point-in-time write, **append** a row to an append-only **court-history file** at
`test/court-history.tsv`, carrying the courted run's own spec, gate verdict, **and detail**:
`${version}\t${repo}\t${spec}\t${gate_verdict}\t${detail}\t${court_verdict}\t${ts}`. The two
sites differ in what is in scope. `cmd_court_all` already has the courted run's `latest_line`
in scope (`:1337`), but note only `verdict` is pre-extracted into a variable (`cut -f5`,
`:1339`) — the append must additionally pull `spec=$(echo "$latest_line" | cut -f3)` and
`detail=$(echo "$latest_line" | cut -f6)` before writing the row, or those columns land empty
and the infra-exclusion filter breaks. With those two `cut`s added, append directly there.
`_results_one`, however, does **not**: at `:1586` the court write precedes the `:1594` display
loop, whose `spec`/`verdict`/`detail` are loop-locals bound *after* the write and iterated over
the last-5 rows across *all* specs — there is no single courted-run spec/verdict/detail in scope
at `:1586`. So the `_results_one` append must first recover them by reading back the latest
`results.tsv` row for its own `(VERSION, short)` (the same `awk -F'\t' … tail -1` shape as
`cmd_court_all:1337`) immediately before the append. (Factor both appends through one
`_append_court_history version repo spec gate_verdict detail court_verdict` helper so the row
format lives in one place; each caller passes what it has resolved. **`court_verdict` must record all
three court outcomes — `PASS`, `FAIL`, and `INCONCLUSIVE`** (cmd_court exit 0/1/2 respectively): the
history is a journal, not the point-in-time *cache*, so it does **not** reuse the cache's drop-on-
INCONCLUSIVE guard (`_results_one:1584`'s `[[ -n "$_court_verdict" ]]`, which leaves an INCONCLUSIVE
row unwritten). Recording `INCONCLUSIVE` is load-bearing for the analyzer's unmeasurable-draw detection
below — an unrecorded INCONCLUSIVE would let the repo's stale prior row stand as its latest and mask
the "unmeasurable this run" signal. `cmd_court_all:1365-1370` already resolves the verdict including
`INCONCLUSIVE`; `_results_one` must capture it the same way (map cmd_court exit 2 → `INCONCLUSIVE`)
for its append rather than skipping. The same `INCONCLUSIVE` must also be written to the point-in-time
**cache** — `_results_one:1585-1588` today guards the cache write with the same `-n` filter and so
leaves a *stale conclusive* verdict there. This matters because `cmd_court_all` writes `INCONCLUSIVE`
to the cache at `:1370-1374` and re-courts a repo (`:1336`) only when its cache reads `INCONCLUSIVE`
or is absent: a journal that says `INCONCLUSIVE` while the cache still reads a stale `PASS` would
strand the repo as `INCON` in the metric with **no path back to a fresh court** through the matrix
flow. Record `INCONCLUSIVE` to **both** the journal and the cache, exactly as `cmd_court_all` does.
(Only a true infra error where *no* verdict is producible is
excluded — those cases are already filtered upstream before courting, `:1341-1348`.) **Correct the
now-contradicting comment in the same edit:** `_results_one:1581` today reads `# exit 1 = FAIL
verdict; exit 2+ = infrastructure error (don't record)` — factually wrong once this fix records
exit 2 as `INCONCLUSIVE` (and wrong on its own terms: `cmd_court` exit 2 is `INCONCLUSIVE`, not an
infra error — genuine infra errors are filtered before the court protocol runs, `:1341-1348`).
Rewrite it to `# exit 1 = FAIL; exit 2 = INCONCLUSIVE (record to BOTH cache and journal so
cmd_court_all re-courts (:1336) instead of reading a stale verdict)` so a future reader does not see
"don't record" above code that now records and revert the fix. The helper must emit each row
as a **single atomic `printf '…\n' … >> file`** — one write syscall — because `cmd_court_all`
courts in concurrent background subshells (`) &` at `:1375`, throttled to
`MAX_COURT_CONCURRENT`) that each append: a lone `printf >>` under the row's ~sub-512-byte size
stays within Linux `O_APPEND` single-write atomicity on a local filesystem, so rows do not
interleave; do **not** build the row with multiple `>>` calls, and add `flock` if a row could
ever exceed that bound or the log could live on NFS.) The
**detail** column is load-bearing for the infra exclusion below: the recorded gate verdict is
only `PASS`/`FAIL` (`:944/:958`), so a `missing-gates`/`session-ended` infra fail is a `FAIL`
distinguishable from a real gate FAIL *only* by its detail string — without the detail the
analyzer would miscount infra fails whose diff the court happens to PASS as false-FAILs.
(`cmd_court_all` already skips the no-branch/unresolvable/no-known-good infra cases before
courting at `:1341-1348`, so those never reach the history; the detail column catches the
residual infra FAILs that *do* get courted.) The
path is deliberate: everything under `test/.matrix-state/` is unconditionally gitignored
(`.matrix-state/.gitignore` is `*` plus `!.gitignore`), so a history file placed there could
never be committed — put it one level up, **directly at `test/court-history.tsv`**. That path
is **not** covered by any `.gitignore` (verified: `git check-ignore test/court-history.tsv`
exits 1; the only `.gitignore`s under `test/` are scoped to `test/.matrix-state/` and
`test/.repos/`), so it is immediately trackable. **Do NOT add a `test/.gitignore`** — a
`test/.gitignore` would need a `*`+negation catch-all to work, which would silently ignore
every *other* file the plan places under `test/` (`test/metrics/court-baseline.tsv`,
`test/assert-evidence-paths.sh`, `test/assert-court-permissions.sh`). Same for the pinned
snapshot at `test/metrics/court-baseline.tsv` (also `git check-ignore` rc=1). Leave the
point-in-time file and its `rm`s alone (they are the cache). The history file is additive, breaking no existing `results.tsv`
reader — the same rationale that makes Phase 0 prefer a parallel `.crash` scan over
re-arity-ing `_tally_gates`.

**Analyzer + snapshot (the second half of this sub-step — data alone is not the metric):**
add a `make court-metrics` target (a `cmd_court_metrics` in `test-skill.sh`, ~20 lines of
`awk`) that reads `court-history.tsv` **directly** — no fragile join with `results.tsv`,
because each row already carries the spec and gate verdict of the run it courted. Keyed on
`(version, repo, spec)` it takes the latest row per key by `ts`, filters to rows where
`court_verdict==PASS && gate_verdict==FAIL` **and** the gate FAIL is not infra (stale /
no-branch / no-commits / missing-gates / session-ended, classified from the detail captured
at court time — the same exclusions as the false-FAIL definition below, and matched against
the harness's *literal* detail strings, e.g. `missing N of M gates` at `:993`, not the
substring `missing gate`), and emits aggregate and per-repo
false-FAIL rates plus a summary table. The go/no-go measurement filters to **spec=all** rows
(the primary metric); it MAY additionally print the per-spec rate. Concretely:

```awk
# court-history.tsv: version \t repo \t spec \t gate_verdict \t detail \t court_verdict \t ts
# court_verdict is one of PASS / FAIL / INCONCLUSIVE (cmd_court_all:1365-1370 records all three;
# exit 2+ from cmd_court -> INCONCLUSIVE). false-FAIL = court PASS but gate FAIL (non-infra).
awk -F'\t' '
  $3 ~ /^all/ {                                   # spec=all only for the go/no-go metric
    k=$1 SUBSEP $2 SUBSEP $3
    # latest row per (version,repo,spec) by ts. NOTE: latest-row-wins means a gate-infra row (below)
    # permanently shadows any earlier valid court row for the same key — a repo whose most recent
    # spec=all draw was a gate-infra flake reads as MISSING even if a prior draw measured it. The
    # two-sample wrapper absorbs this: an isolated infra draw becomes a per-repo MISSING (WARN, or
    # BLOCK if the other run flags a REGRESSION), never a silent rate drop.
    if ($7 >= ts[k]) { ts[k]=$7; gv[k]=$4; det[k]=$5; cv[k]=$6; repo[k]=$2 } }
  END { for (k in gv) {
          # infra, not a gate FAIL — match the literal detail strings the harness emits:
          # "stale branch" (:937), "no branch found" (:931), "no commits (no-op)" (:941),
          # "missing N of M gates" (:993), "session ended without result" (:1077).
          is_infra = (gv[k]=="FAIL" && det[k] ~ /stale branch|no branch|no commits|missing [0-9]+ of|session ended/)
          # measurability COVERAGE: a latest spec=all row that is NOT a gate-infra exclusion means
          # this snapshot actually MEASURED the repo — whether the gate PASSed (a rebase fix, the
          # success path) or conclusively FAILed. This is the signal that tells an all-infra run
          # (nothing measured) apart from an all-repos-fixed run (every repo PASSes -> no false-FAIL
          # rate line, yet fully measured). The regression gate consumes the MEASURED count below.
          if (!is_infra) meas[repo[k]]=1
          if (gv[k]!="FAIL") continue
          if (is_infra) continue
          tot[repo[k]]++                                                           # every courted gate-FAIL version
          if (cv[k]=="PASS")              { ff[repo[k]]++; conc[repo[k]]++ }       # court says good -> false-FAIL (conclusive)
          else if (cv[k]=="FAIL")         conc[repo[k]]++                          # court agrees FAIL (conclusive, not a false-FAIL)
          else if (cv[k]=="INCONCLUSIVE") inc[repo[k]]++ }                         # court could not decide -> NOT a measurement
        # The denominator is the CONCLUSIVE court count (PASS+FAIL), never the raw row count: an
        # INCONCLUSIVE court is a non-measurement, excluded from BOTH numerator and denominator.
        # Leaving it in the denominator would DILUTE the rate and let a mostly-inconclusive draw
        # silently refute a real regression (an inconclusive court is NOT evidence of a low false-FAIL
        # rate). Measurability is a COVERAGE test, not a sample-size test — the right axis for a
        # rate-over-versions metric: a repo that gate-FAILed on 2 versions, both conclusively courted,
        # is FULLY measured (n is small but coverage is 100%), while 2 conclusive of 10 is poorly
        # measured. A repo is measurable when its conclusive courts are NOT a strict minority
        # (conc >= inc — at least half the courts decided); only when inconclusive courts strictly
        # OUTNUMBER conclusive ones (conc < inc, including the all-inconclusive extreme conc==0) is the
        # rate untrustworthy — emit a distinct INCON marker (dropped from AGGREGATE; the regression gate
        # consumes it exactly like MISSING). A THIRD untrustworthy case, conc==0 AND inc==0 with tot>0
        # (rows counted but no recognized verdict — corrupt/empty court_verdict), is guarded explicitly
        # in the emit loop below (a bare `conc < inc` would misread 0<0 as a valid 0/0 rate). NOTE the
        # boundary is `<`, not `<=`: an exactly-even split
        # (conc==inc) stays measured, so a genuine regression at 50% coverage still FLAGS rather than
        # being silently downgraded to a WARN. A repo that is inconclusive-majority across BOTH full
        # re-court passes is itself a court-health signal (investigate the court), not a phase blocker.
        num=0; den=0
        for (r in tot) {
          # conc==0 AND inc==0 with tot>0: rows were counted but NO court_verdict was recognized as
          # PASS/FAIL/INCONCLUSIVE (empty field, partial write, corrupt value). A bare `conc < inc`
          # guard reads 0<0 as false and would emit a bogus MEASURED 0/0 rate (a silent "0% false-FAIL"
          # blind spot); route it to INCON with a distinct detail so the corruption is visible and the
          # regression gate treats it as unmeasurable, not as a clean rate.
          if (conc[r] + inc[r] == 0) { printf "INCON\t%s\t0 conclusive of %d (unrecognized verdict values)\n", r, tot[r]; continue }
          if (conc[r] < inc[r]) { printf "INCON\t%s\t%d conclusive of %d\n", r, conc[r], tot[r]; continue }
          printf "%s\t%d/%d\n", r, ff[r], conc[r]; num+=ff[r]; den+=conc[r] }
        printf "AGGREGATE\t%d/%d\n", num, den
        # MEASURED = repos with >=1 non-infra latest spec=all row this snapshot (PASS or non-infra FAIL).
        # 0 => the whole run was gate-infra failures; the regression gate treats a zero-MEASURED fresh
        # snapshot as a HARD ERROR, NOT an all-repos-fixed success (which has MEASURED > 0). See (v).
        nm=0; for (r in meas) nm++
        printf "MEASURED\t%d\n", nm }' "${1:-test/court-history.tsv}" \
  | LC_ALL=C sort
```

`cmd_court_metrics` takes its input path as `$1`, defaulting to the working-tree
`test/court-history.tsv` for a live `make court-metrics`. Step (iv) below feeds it the
**committed** log instead (`cmd_court_metrics <(git show HEAD:test/court-history.tsv)`), so the
anti-fabrication re-derivation is committed-to-committed and does not drift as later court runs
append to the working tree — see (iv).

**Emit a canonical (sorted) order — the re-derivation check in (iv) below depends on it.**
`for (r in d)` iterates awk associative-array keys in *unspecified* order (hash order; varies
by awk build, version, and key-insertion history), so two runs of the raw awk on the *same*
`court-history.tsv` can print the per-repo lines in different orders. A byte-for-byte
comparison of two such runs would then fail *spuriously* on an honest, unchanged log. Piping
through `LC_ALL=C sort` (locale pinned so ordering is stable across machines) gives one
deterministic order; `cmd_court_metrics` always ends with that pipe, so the committed snapshot
*is* the sorted form and step (iv)'s exact comparison is order-stable. (The counts themselves
are already deterministic — pure `%d` integers, no timestamps/floats/locale grouping — so only
the *line order* needed pinning. The `AGGREGATE` and `MEASURED` summary lines sort among the repo
lines under `LC_ALL=C`; every consumer locates them by key (`$1=="AGGREGATE"` / `$1=="MEASURED"`),
not by position, so their placement does not matter — and every per-repo rate scan below must skip
both summary keys (and `INCON` lines) so a summary line is never misread as a `repo\tff/den` rate.)

Commit its output to `test/metrics/court-baseline.tsv` (tracked): that pinned snapshot, not
the live gitignored state, is the go/no-go input. All three — the `:1340`-filter drop,
the per-spec court-history writes, and the analyzer — are the "required first sub-step (code,
before any measurement)"; without them the ≤5%/≤10% boundary below is uncomputable or reads
a structural 0%. **Make the Phase-1→Phase-2 boundary check the *decision*, not just the
artifacts.** "Only if Phase 1 binds" (Phase 2's opening) is unenforceable text today — nothing
stops an implementer skipping the court fix, measuring with the broken court, and proceeding.
Add a `make check-phase1-baseline` target (a `cmd_check_phase1_baseline`) that exits non-zero
with a descriptive error unless: (i) **both** the raw `test/court-history.tsv` **and** its
derived snapshot `test/metrics/court-baseline.tsv` exist and are committed (committing the raw
log, not just the summary, is what makes step (iv) reproducible in review); (ii) a committed
`test/metrics/phase1-decision.txt` records the chosen branch (`stop-after-phase0` or
`proceed-to-phase2`) together with the measured aggregate and worst per-repo false-FAIL rates;
(iii) — split into **two independent code paths, both required** (they are separate greps, not one
check; an implementer who writes only the rate comparison silently omits the INCON scan, so they are
enumerated as distinct deliverables rather than a parenthetical): **(iii-a) rate-boundary
consistency** — the recorded decision is *consistent with the ≤5%/≤10% rule*: `proceed-to-phase2`
only when the rate still exceeds the boundary, `stop-after-phase0` when it does not (the
worst-per-repo scan reads only `repo\tff/den` rate lines — it must skip the `AGGREGATE`, `MEASURED`,
and `INCON` keys, which are not per-repo rates, using the same skip pattern as `cmd_court_regression`
and condition (iv): `awk -F'\t' '$1=="AGGREGATE"||$1=="MEASURED"||$1=="INCON"{next} {split($2,p,"/");
if (p[2]>0 && p[1]/p[2] > worst) worst=p[1]/p[2]} END{...}'` — the `AGGREGATE` skip is load-bearing,
since its `ff/den` value is format-indistinguishable from a per-repo rate and a naive scan would
compare the *pooled* rate against the per-repo boundary and reach the wrong proceed/stop verdict).
**(iii-b) INCON-absent** — **any `INCON` marker in
the derived snapshot is a hard FAIL of this condition** (`flat=$(cmd_court_metrics <(git show
HEAD:test/court-history.tsv)); grep -q '^INCON' <<<"$flat" && return 1` — `return 1`, not `exit 1`,
so `cmd_check_phase1_baseline` composes safely with any future wrapper, matching the `return`
convention of every other `cmd_*` block), **not a skip**: a repo that
is `INCON` at the Phase-1 baseline has no frozen anchor rate, and because `cmd_court_regression`
iterates anchor keys only (`for (r in b)`) such a repo would be *permanently unmonitored* for later
regression — a silent blind spot precisely on the repos hardest to court. An incomplete baseline is a
configuration fault, so the operator must either re-court the `INCON` repo to a conclusive rate or
explicitly and visibly remove it from the test set, then re-freeze the anchor — a baseline containing
any `INCON` repo must never be frozen. This is the **second** enforcement of the INCON-absent
invariant: `make freeze-court-anchor` (step 5) refuses to *create* an INCON anchor, and (iii-b)
re-verifies at the boundary that the frozen anchor is clean — defense in depth, since nothing forces
the discipline-gate `check-phase1-baseline` to run before the freeze. (iv) the
target **re-derives the snapshot from the *committed* raw log** — re-runs `cmd_court_metrics
<(git show HEAD:test/court-history.tsv)` (the committed log, **not** the working-tree
`test/court-history.tsv`) and asserts its output equals the committed `court-baseline.tsv`
exactly (a valid equality only because `cmd_court_metrics` emits the canonical `LC_ALL=C sort`
order above — without that pin the check would flake on nondeterministic line ordering), then
reads the rates *from that re-derived output* (not from the committed file) for the (iii) check;
**(v)** P0a's crash-safe fallback is present in **both** group-(ii) gates
(`gates/step3-autofix/crd-validation.md`, `gates/step3-autofix/patterns-completeness.md` — the two
with *no* other fallback, so their absence is the silent-false-PASS hole Phase 2 step 4 opens if
it deletes RULE 2 / PATH-B with no P0a body behind it) — but the two need **different** checks,
because trigger-presence is a proxy for crash-branch completeness only where the check body
*pre-exists*. Because `grep` is line-oriented but the crash-body sentinels are hard-wrapped human prose (the
gate `.md` files wrap at ~65 columns), condition (v) matches every sentinel against a
**whitespace-flattened** copy of the file — `flat() { tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '; }`
— so a sentinel split across a wrap boundary or an indented continuation still matches
(`flat <file> | grep -q '…'`). For **`patterns-completeness.md`** a single flattened grep for the
trigger suffices (`grep -q 'not found, crashes, or emits no'`) — its checks 1-4 are already
self-contained (`go build` / `git diff` / `merge-base` / a static patterns-doc lookup, none reads
script output), so the trigger is the only new prose. For **`crd-validation.md`** the trigger is
**not** a proxy for body presence — P0a must additionally author a from-scratch check body *and*
its empty-BASE guard, neither of which a trigger grep detects — so condition (v) is a **three-part
flattened check there, all required:** (a) the trigger `grep -q 'not found, crashes, or emits no'`;
(b) the from-scratch scope `grep -q 'for each CRD schema file in the repository'`; and (c) the
empty-BASE guard `grep -q 'PASS on a self-comparison'` (a strict substring of the required
"never PASS on a self-comparison" phrase — long enough that an incidental comment mentioning
"self-comparison" cannot satisfy it, unlike the bare 15-character token). A
developer who writes only the five-word trigger passes a naive single-grep but leaves
`crd-validation.md` — once Phase 2 step 4 deletes its FIRST STEP block — with *nothing* behind
the evidence template's judge-from-scratch branch: a silent false-PASS on a repo with real CRD
regressions, and an unenforced empty-BASE self-compare on top of it. P0a therefore authors those
three phrases **verbatim** (they double as the human-readable crash body and as condition-(v)
sentinels — see the P0a spec above). Finally, **(vi)**
a committed `test/metrics/assert-court-permissions-result.txt` reads exactly `PASS` (the court
permission fix was proven effective *before* the baseline was measured against it — an
`INCONCLUSIVE`, `PROBE-BROKEN`, `FAIL`, or absent result must block, since a measurement taken
against a still-wide-open or unverified court is meaningless; a `PROBE-BROKEN` value additionally
tells the reviewer the probe is *systematically* failing and needs debugging, not another re-run). Note (vi) is, unlike (i)-(iv), a **pure file-content check with no
re-derivation** — it trusts that the probe (a live-model integration check, un-recomputable in
pure bash) was run honestly, so it is a discipline arm consistent with the whole
`check-phase1-baseline` target's status as a reviewer-run gate, not a corpus-forgery barrier. Two temporal caveats: check (v) is a **pre-Phase-2 precondition**, and the whole
`check-phase1-baseline` target (conditions i–vi) runs **once**, at the Phase-1→Phase-2 boundary —
*before* Phase 2 step 4 legitimately deletes that trigger sentence. It is **not** re-invoked at
later boundaries; the later-phase *regression* is a standalone `cmd_court_metrics` rate comparison
(the baseline-update protocol below), so (v) is never re-grepped after step 4 removes its target.
And step (iv) reads `git show HEAD:` so the one-time check is reproducible in review
(committed-to-committed), independent of the working-tree log.
Recomputing from the *committed snapshot* alone (an earlier draft of this
spec) would be circular: a fabricated `court-baseline.tsv` + a matching `phase1-decision.txt`
would pass. Re-deriving from `court-history.tsv` means faking the decision requires forging the
entire per-run log consistently — far harder than editing two summary numbers. (It is not
tamper-*proof* — a determined editor could rewrite the log too — but it raises the bar from
"edit two numbers" to "forge the corpus," which is the realistic threat for an honest-mistake /
stale-snapshot slip.) Checking that the
recorded decision obeys the rule is the point; merely asserting the analyzer function is
defined (`declare -F cmd_court_metrics`) is near-tautological (analyzer and checker land in the
same `test-skill.sh`) and is at most a cheap sanity arm, not the gate. **Enforcement hook —
be honest about where it runs.** Root `make lint` (ai-helpers `Makefile:38`) is the *structural
plugin linter*; it validates `plugin.json`/marketplace registration and never sources or runs
`test/test-skill.sh`, and the k8s-rebase Makefile has no `lint` target at all — so
`check-phase1-baseline` cannot be "wired into `make lint`." It lives with the harness: add it
as a target in the **k8s-rebase Makefile** (alongside `test`/`court`/`results`) and make it a
**required, documented pre-Phase-2-PR checklist item** enforced in review. No existing CI job
runs the harness, so until one is added this is a discipline gate (a self-checking target a
reviewer runs), not an automated red build; if/when a harness CI job exists, gate there. That
is still a real improvement over prose — the target mechanically rejects an inconsistent or
absent decision — but the plan must not claim a Phase-2 PR "cannot bypass" it when no
automated hook yet runs it. Define false-FAIL
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
solved. **Concrete decision boundary (record before measuring, so the same numbers can't
be read two ways):** on the committed post-stripping baseline, over the fixed
repo/version set, **stop after Phase 0 if the court false-FAIL rate is ≤ 5% aggregate AND
no single repo exceeds 10%, confirmed across ≥ 2 re-runs** (the variance control below);
otherwise subagent reliability still binds and Phases 2–5 proceed. The 5%/10% figures are
the initial team-settable boundary — adjust with the maintainers, but the values must be
written down here before the baseline is measured, or the gate provides no decision
discipline. **If it no longer binds, stop after Phase 0.**

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

*(baseline-update protocol — how the regression gate advances across phases)* "Against the
committed baseline" needs a concrete mechanism, or the checkpoint is unrunnable after Phase 1:
step (iv)'s equality check is committed-to-committed and would break the moment a later matrix
run grows the log unless the committed pair advances with it. Two artifacts with **opposite**
update rules resolve this cleanly — do not overload one file for both jobs: (A) the *consistency*
baseline `test/metrics/court-baseline.tsv` is **rolling** — it must always equal `cmd_court_metrics`
over the current committed log, so step (iv) stays reproducible as the log grows; (B) a **frozen**
regression anchor `test/metrics/court-baseline-phase1.tsv`, committed **once** at the Phase-1
boundary and never rewritten, is what every later phase's rate-regression compares against. The
rolling one advances by one target: add `make commit-court-baseline` (a
`cmd_commit_court_baseline`) that (0) **rejects a pre-staged index up front** —
`git diff --cached --quiet || { echo 'ERROR: index has pre-staged changes; stash or commit them
first'; return 1; }` — so the commit contains *exactly* the two court files and nothing a prior
`git add` left staged; (1) **computes** the fresh `test/metrics/court-baseline.tsv` from the current
working-tree `test/court-history.tsv` via `cmd_court_metrics` into a temporary file — **not yet
overwriting the committed one**; (2) **refuses to roll the baseline forward while the frozen anchor
is still absent** — if `HEAD:test/metrics/court-baseline.tsv` is already committed *and* the
freshly-computed snapshot differs from it *and* `test/metrics/court-baseline-phase1.tsv` does
**not** exist, it aborts (`return 1`, leaving the working tree untouched) with an error directing
the operator to `make freeze-court-anchor` first; and (3) installs the temp over
`court-baseline.tsv`, then stages **and commits** the log and the re-derived `court-baseline.tsv`
together in one commit (never one without the other, so step (iv) stays consistent — the target
*commits*, matching its name and Implementation-Sequence step 5, it does not merely `git add`) —
staging **only those two explicit paths** (`git add <log> <baseline>`, never `git commit -a`/`-am`). The `-a`/`-am` exclusion alone stops only working-tree
auto-staging; the step-(0) index guard closes the other vector — a plain `git commit` after a
target's `git add` would otherwise commit *anything already in the index*, including a
developer's pre-staged work-in-progress or even a pre-staged `court-baseline-phase1.tsv`. Between
the two, nothing but the two court files enters the roll, and the target **never** rewrites the
frozen anchor.

**Why the roll-forward guard (step 2) matters — and why a Phase-1 sentinel would not.** The frozen
anchor's whole job is cross-phase regression detection, so it must capture *Phase-1-only* court
data. Nothing in `court-history.tsv` tags a row with its phase, so **no purely-data check can tell
a Phase-1 court from a Phase-2 one**. Without step (2) an operator who skips the Phase-1 freeze,
runs Phase-2 courts, rolls the baseline forward, and only *then* runs `make freeze-court-anchor`
would silently freeze a Phase-1+Phase-2 baseline — every later `make court-regression` would then
compare against a polluted denominator and mask exactly the Phase-2 regressions the anchor exists
to catch (a silent defeat of the entire cross-phase regression mechanism). Step (2) closes that
window *at its source*: the only route to a polluted anchor is to roll the baseline forward while
the anchor is still absent, and that roll is now refused. A sentinel written by
`commit-court-baseline` "at Phase-1 time" — the natural first instinct — **cannot** work:
`commit-court-baseline` runs at *every* phase boundary and has no phase-awareness to know which run
is Phase 1, and a timestamp/count sentinel merely relocates the same trust to another
operator-timed action. Gating the roll on **anchor-presence** needs no phase-awareness and has no
false-block on the documented single-matrix flow: the first *establishing* commit is allowed
because `HEAD` carries no committed baseline yet, and every legitimate *later* roll is allowed
because the anchor exists by then; only rolling the baseline forward *between* the first commit and
the freeze is refused — the exact pollution precondition. (An operator still accumulating Phase-1
courts should keep them in the working-tree log and run `commit-court-baseline` once at the Phase-1
boundary, then freeze — not commit the baseline mid-accumulation.)

The frozen anchor is created by a **separate one-time target**, `make freeze-court-anchor` (a
`cmd_freeze_court_anchor`) — **not** a manual `cp`, so the freeze cannot skip its guards:

```bash
cmd_freeze_court_anchor() {                     # one-time Phase-1 freeze; exit 0 = frozen, 1 = refused
  local roll="test/metrics/court-baseline.tsv"
  local anchor="test/metrics/court-baseline-phase1.tsv"
  git diff --cached --quiet || { echo 'ERROR: index has pre-staged changes; stash or commit them first'; return 1; }
  [[ -f "$anchor" ]] && { echo "ERROR: $anchor already exists — the freeze is once-only; never silently re-baseline"; return 1; }
  [[ -s "$roll" ]]   || { echo "ERROR: $roll missing/empty — run 'make commit-court-baseline' first"; return 1; }
  # INCON guard lives HERE, at the one-time freeze — NOT in cmd_commit_court_baseline. The anchor must
  # carry a comparable rate for EVERY repo: an INCON repo has no rate, and cmd_court_regression iterates
  # anchor keys only (for (r in b)), so an INCON repo frozen into the anchor is PERMANENTLY unmonitored.
  # Refuse the freeze; the operator re-courts the INCON repo to a conclusive rate (or visibly removes it
  # from the test set) and re-runs commit-court-baseline before freezing.
  grep -q '^INCON' "$roll" && { echo "ERROR: $roll contains INCON repos — re-court or remove them before freezing the anchor"; return 1; }
  cp "$roll" "$anchor"
  git add "$anchor"                             # explicit path only, never -a/-am (step-(0) guard already ran)
  git commit -s -m "Freeze Phase-1 court regression anchor"   # -s: this repo enforces DCO sign-off on every commit
}
```

**Why the INCON guard is at the freeze and *never* inside `cmd_commit_court_baseline`:** that target
rolls the *consistency* baseline, which **legitimately carries `INCON` lines in later phases** — a
repo can become inconclusive-majority as more draws accumulate, and `court-baseline.tsv` must mirror
`cmd_court_metrics` **exactly** (INCON lines included) or step (iv)'s committed-to-committed equality
breaks. An INCON-abort inside `cmd_commit_court_baseline` would therefore wrongly fail every later
`make commit-court-baseline` roll. The INCON-must-not-be-frozen invariant belongs only to the *frozen
anchor*, whose creation is this single guarded target; `check-phase1-baseline` (iii-b) re-verifies it
at the boundary as defense in depth. The
per-phase flow is: after Phase 2 (and again after Phase 3) **re-run the matrix** — appending its
courts to the working-tree log — then run a **standalone** `cmd_court_metrics` comparison (a
`make court-regression`, *not* a re-invocation of `check-phase1-baseline`): compare the **fresh**
`cmd_court_metrics` output (working tree) against the **frozen** `court-baseline-phase1.tsv` and
require no pass-rate regression and no new false-FAIL (confirm-by-rerun, per-repo). Anchoring to
the frozen Phase-1 file — not the immediately-prior phase — is deliberate: a rolling anchor
re-baselines each hop, so a real-but-sub-noise decay spread across Phase 2 → Phase 3 (each hop
inside the confirm-by-rerun band) would never accumulate against a fixed reference and would ship
undetected. *Only if that comparison passes* does the phase land: run `make commit-court-baseline`
to roll the **consistency** pair (log + `court-baseline.tsv`) forward to include the new rows; the
frozen `court-baseline-phase1.tsv` stays put. A failing comparison blocks the phase and nothing is
re-committed. **Do not re-run the full `check-phase1-baseline` target at later boundaries** — its
conditions (i)–(vi) are a *one-time* Phase-1→Phase-2 gate: (v) greps for the crash-fallback
trigger that Phase 2 step 4 deliberately deletes, so re-running the whole target after Phase 2
would fail (v) permanently. Later-phase regression is the standalone rate comparison above, which
touches neither (v) nor the step-(iv) equality. This keeps **one** comparison logic reused at
every boundary — not a `check-phase2-baseline`/`check-phase3-baseline` family.

That comparison needs the same concrete contract as `cmd_court_metrics`, not just prose intent.
`cmd_court_regression` diffs the frozen anchor against a fresh snapshot and exits nonzero on a
per-repo regression:

```bash
cmd_court_regression() {                       # exit 0 = clean, 1 = regression, 2 = error
  local base="test/metrics/court-baseline-phase1.tsv"
  [[ -s "$base" ]] || { echo "ERROR: frozen anchor $base missing or empty"; return 2; }
  # -s (not -f): a 0-byte anchor would pass -f but then FNR==NR stays true across the whole
  # fresh file, folding the fresh snapshot into b[] and reporting every repo backwards as MISSING.
  # fresh snapshot = cmd_court_metrics over the current (matrix-appended) working-tree log,
  # emitted in the same canonical LC_ALL=C order, so both sides key on the repo column.
  awk -F'\t' '
    FNR==NR { if ($1=="AGGREGATE" || $1=="INCON" || $1=="MEASURED") next; b[$1]=$2; next }   # frozen anchor: repo -> ff/den, PER-REPO ONLY.
                                                              # AGGREGATE/MEASURED are summary keys, never compared as rates;
                                                              # AGGREGATE is deliberately NOT compared across time (see below);
                                                              # an INCON anchor line = no Phase-1 rate to compare -> skip (the
                                                              # freeze rejects INCON, so this is defensive).
    { if ($1=="AGGREGATE") next
      if ($1=="MEASURED") { fmeas=$2; next }                              # fresh coverage: repos measured this run
      if ($1=="INCON") { finc[$2]=1; ninc++; next }                       # fresh: INCON apart, counted
      f[$1]=$2; nf++ }                                                    # fresh per-repo rate, counted
    END {
      # A non-empty but degenerate anchor (only AGGREGATE / only INCON lines, no per-repo rate) would
      # leave b[] empty, and `for (r in b)` would iterate nothing -> a silent rc=0 PASS that monitors
      # NOTHING. Since AGGREGATE is no longer a compared key, assert at least one per-repo rate exists;
      # exit 2 with no MISSING/INCON line so the wrapper hard-error guard blocks it as a config fault.
      if (length(b) == 0) { print "ERROR: frozen anchor has no per-repo rate lines to compare"; exit 2 }
      # An ALL-INFRA fresh run (every latest spec=all row is a gate-infra exclusion) produces zero
      # per-repo rate lines, zero INCON lines, and MEASURED 0 -> without this guard every anchor repo
      # reads as MISSING (rc=2 WITH MISSING lines), the wrapper hard-error guard is bypassed, and the
      # phase LANDS with no regression measurement at all. Distinguish it from the all-repos-FIXED
      # success case (also zero rate lines, but MEASURED > 0 because the gate PASSes are non-infra rows)
      # by MEASURED: only when nothing was measured is this a HARD ERROR. Emit no MISSING/INCON line so
      # cmd_court_regression_confirmed`s hard-error guard fires and BLOCKS. (Counting nf/ninc as plain
      # scalars, never length(f)/length(finc): length() on an as-yet-unassigned name would fix its type
      # to scalar and the later `r in finc`/`r in f` would then fatal with a scalar-as-array error.)
      if (nf+0==0 && ninc+0==0 && fmeas+0==0) {
        print "ERROR: fresh snapshot measured zero repos (all courts were gate-infra failures)"; exit 2 }
      rc=0
      for (r in b) {
        # fresh run was ALL-inconclusive for r: unmeasurable, not a clean refutation — flag INCON, not
        # MISSING, so the wrapper distinguishes "court could not decide" from "absent / now passes".
        if (r in finc) { printf "INCON\t%s\t(in anchor, fresh unmeasurable)\n", r; rc=2; continue }
        if (!(r in f)) { printf "MISSING\t%s\t(in anchor, absent fresh)\n", r; rc=2; continue }
        split(b[r], bp, "/"); split(f[r], fp, "/")            # [1]=false-FAILs, [2]=denominator
        if (bp[2]+0 == 0) {                                   # anchor rate undefined (0 denominator):
          if (fp[1]+0 > 0) {                                  # a bare cross-multiply would mask it as 0>0
            printf "REGRESSION\t%s\tanchor=%s fresh=%s (anchor denom 0)\n", r, b[r], f[r]; if (rc < 1) rc = 1 }
          continue }
        # false-FAIL rate rose iff  fp_ff/fp_den > bp_ff/bp_den  — cross-multiply, integer-safe,
        # denominator-independent (fresh and anchor need not share a court count)
        if (fp[1]*bp[2] > bp[1]*fp[2]) {
          printf "REGRESSION\t%s\tanchor=%s fresh=%s\n", r, b[r], f[r]; if (rc < 1) rc = 1 }
      }
      exit rc
    }' "$base" <(cmd_court_metrics) | LC_ALL=C sort
  return "${PIPESTATUS[0]}"                     # awk's exit status, not sort's
}
```

The `AGGREGATE` row is deliberately **not** compared across time. Regression detection is strictly
**per-repo**, which catches every *genuine* false-FAIL increase (a real rise always shows up as some
individual repo's rate climbing). A pooled `AGGREGATE` rate, by contrast, can climb across time with
**no** per-repo rate rising at all — Simpson's paradox: it is a ratio of sums (Σff/Σconc), so merely
*reweighting* the denominators (a repo's conclusive-court count shrinking, or a low-rate repo dropping
to `INCON` and leaving the pool) shifts the pooled number while every per-repo rate stays flat. Those
cross-time aggregate climbs are reweighting artifacts, not regressions, so comparing `AGGREGATE`
across time would manufacture **false** blocks from an unchanged corpus while adding no true signal
the per-repo scan lacks. The point-in-time aggregate go/no-go (≤5%/≤10%) still belongs to
`check-phase1-baseline` (a single-snapshot read, where the paradox does not bite); cross-time both
reads skip it. A repo absent from the anchor (a newly-added target) is out-of-scope and simply not
iterated. **`confirm-by-rerun` is the wrapping `make court-regression`
contract, not the awk:** because a single matrix run carries the ~50-point AI variance the
no-regression gate has to absorb, the target runs *matrix + `cmd_court_regression`* **twice** and
applies the confirm rule **per repo**. The two flag kinds are *not* symmetric, because they mean
different things:

- A **`REGRESSION`** (present in both anchor and fresh, higher false-FAIL rate) is the signal the
  gate exists to catch. It is cleared as AI variance *only* when the **other** run **cleanly
  measured that repo and did not flag it** — a genuine "second opinion." A run in which the repo is
  **unmeasurable** — `MISSING` (no rate at all) or `INCON` (a rate the courts could not decide) — is
  **not** a clean measurement, so it can neither confirm nor refute: a `REGRESSION` paired with a
  `MISSING` *or* an `INCON` in the other run is *unconfirmable* and **blocks**. A `REGRESSION` in
  both runs blocks (confirmed). A `REGRESSION` in one run and a clean no-flag measurement in the
  other lands (refuted as variance). This closes the cross-kind gap — a real regression can no
  longer hide behind a one-run infra flake *or* an inconclusive-majority court draw in its confirming
  sample.

- **`MISSING`** (present in the anchor, absent from the fresh snapshot) is **never**, on its own,
  a block — it is not a false-FAIL rate *increase*. `cmd_court_metrics` counts only latest
  spec=all rows whose gate verdict is a non-infra `FAIL`, so a repo drops out of the fresh snapshot
  for exactly two reasons, **both benign to this gate**: (1) the gate now **passes cleanly** — the
  success path of a rebase fix, the outcome we *want*; or (2) a **gate-level** infra flake in that
  run (`session ended`, `stale branch`, …) excludes the row. Note what `MISSING` is **not**: a
  court **FAIL** verdict keeps the repo *present* (it still writes a gate-`FAIL` row with `cv=FAIL`,
  counted in the denominator as not-a-false-FAIL, not dropped); and an **intentional removal** is
  *invisible* here — the append-only log with latest-row-per-key means the repo's stale anchor-era
  row persists as its latest, so it stays present and never reports `MISSING`. Dropped coverage must
  therefore be caught with a config diff, not this gate.

- **`INCON`** (present in the anchor; in the fresh snapshot the courts could not conclusively measure
  the repo — inconclusive courts *outnumber* conclusive ones) is the *other* unmeasurable kind.
  `cmd_court_metrics` excludes inconclusive courts from the denominator entirely (they are non-
  measurements, not low-rate evidence), so the rate reflects only conclusive courts; a repo whose
  conclusive courts do not outnumber its inconclusive ones (including the all-inconclusive extreme,
  `conc==0`) has no trustworthy rate and is emitted as a distinct `INCON` marker rather than a diluted
  `ff/den`. Without this, a mostly-inconclusive draw would land as an artificially low rate — present,
  no increase — and silently **refute** a genuine `REGRESSION` seen in the other sample. `INCON`
  repos are dropped from `AGGREGATE`, and the regression gate treats `INCON` exactly like `MISSING`.

`MISSING` or `INCON` with no `REGRESSION` in either run is emitted as a **`WARN`** (so an
unmeasurable repo is never silent) and lands — including the all-repos-**fixed** success case, where
every gate now PASSes, no false-FAIL rate line is emitted, and every anchor repo reads `MISSING`
(that outcome must land, not block; it is the goal). The hard errors — which exit 2 with *no*
per-repo `MISSING`/`INCON` line and block immediately on either run as configuration faults, not
variance — are two kinds: (1) a **defective frozen anchor** — missing or empty (`[[ -s ]]`), *or*
non-empty but with no per-repo rate line to compare (the awk `length(b)==0` guard, e.g. an anchor of
only `AGGREGATE`/`MEASURED` lines); and (2) an **all-infra fresh run** where the fresh snapshot
measured **zero** repos (`MEASURED 0`, no rate and no `INCON` lines). Case
(2) must be told apart from the success case above — both have zero rate lines — by the `MEASURED`
coverage count: `MEASURED 0` means the whole matrix run was gate-infra failures (nothing was
courted), so "phase may land" would be a false green over no measurement, whereas the success case
has `MEASURED > 0` (the gate PASSes are non-infra rows) and lands correctly. (A naive "fresh has no
per-repo rate lines → block" check would conflate the two and wrongly block a total success — hence
the `MEASURED` distinguisher rather than a bare emptiness test.) The exit-code contract is stated
exactly as `check-phase1-baseline`'s: nonzero blocks the phase, and nothing is re-committed on a block.

The intersection itself needs the same concrete shape as the single-run diff, not just prose —
`make court-regression` maps to the wrapper `cmd_court_regression_confirmed`, which takes two
independent samples and applies the block rule mechanically:

```bash
cmd_court_regression_confirmed() {             # `make court-regression`; exit 0 = phase may land, 1 = block
  local reg1 reg2 rc1 rc2
  # Two GENUINELY independent samples. cmd_court_all skips re-courting any repo whose court cache is
  # already conclusive (test-skill.sh:1336 — a non-INCONCLUSIVE cache short-circuits the re-court),
  # and cmd_matrix never clears that cache, so WITHOUT the clears below a conclusive repo is courted
  # once and both samples re-read the SAME cached verdict — one draw wearing two hats, not two, which
  # would defeat confirm-by-rerun (a one-off flake reappears identically and false-blocks; the
  # REGRESSION-in-one/INCON-in-other case never arises). Clear ONLY the point-in-time court cache
  # before each matrix run (the durable signal is the appended court-history.tsv journal, untouched)
  # so each sample re-courts and appends fresh rows, and the two cmd_court_metrics reads land on
  # genuinely distinct draws (latest-row-per-key by ts).
  rm -rf "$PLUGIN_DIR/test/.matrix-state/court"/* 2>/dev/null   # sample 1: force a fresh court draw
  cmd_matrix all
  reg1="$(cmd_court_regression)"; rc1=$?
  rm -rf "$PLUGIN_DIR/test/.matrix-state/court"/* 2>/dev/null   # sample 2: force an INDEPENDENT court draw
  cmd_matrix all
  reg2="$(cmd_court_regression)"; rc2=$?
  # A hard error (missing/empty frozen anchor, or an all-infra fresh run that measured zero repos)
  # exits 2 but emits NO per-repo MISSING/INCON line — block now, it is a configuration fault, not
  # variance (an all-infra run with MISSING lines would otherwise land as a false green over no data):
  if { (( rc1 == 2 )) && ! grep -qE '^(MISSING|INCON)' <<<"$reg1"; } ||
     { (( rc2 == 2 )) && ! grep -qE '^(MISSING|INCON)' <<<"$reg2"; }; then
    printf '%s\n%s\nBLOCK: court-regression hard error (see above)\n' "$reg1" "$reg2"; return 1
  fi
  # Per-repo confirm-by-rerun. A REGRESSION is cleared as AI variance ONLY when the other run cleanly
  # measured that repo and left it unflagged. A run where the repo is UNMEASURABLE — MISSING (no rate)
  # or INCON (inconclusive courts outnumber conclusive) — is not a clean measurement, so it can neither confirm nor
  # refute; a REGRESSION paired with either in the other run blocks. MISSING/INCON with no REGRESSION
  # either run is a WARN, not a block (a fixed repo, an infra flake, or an inconclusive court draw —
  # none is a rate increase; an intentional removal is invisible here, use a config diff).
  awk -F'\t' '
    FNR==NR { if ($1=="REGRESSION") r1[$2]=1
              else if ($1=="MISSING") u1[$2]="MISSING"
              else if ($1=="INCON")   u1[$2]="INCON"; next }        # u* = unmeasurable, with the reason
            { if ($1=="REGRESSION") r2[$2]=1
              else if ($1=="MISSING") u2[$2]="MISSING"
              else if ($1=="INCON")   u2[$2]="INCON" }
    END {
      block=0
      for (x in r1) reg[x]=1; for (x in r2) reg[x]=1     # every repo regressed in either run
      for (x in reg) {
        in1=(x in r1); in2=(x in r2)
        if (in1 && in2) { printf "BLOCK: %s regression confirmed in both runs\n", x; block=1; continue }
        if (in1) other = (x in u2) ? u2[x] : ""          # regressed in exactly one run; is the OTHER
        else     other = (x in u1) ? u1[x] : ""          # run a clean measurement, or unmeasurable?
        if (other != "") { printf "BLOCK: %s regressed one run, unmeasurable (%s) in the other\n", x, other; block=1 }
        else             { printf "INFO: %s regressed one run only, clean in the other -> variance\n", x }
      }
      for (x in u1) if (!(x in r1) && !(x in r2)) warn[x]=u1[x]
      for (x in u2) if (!(x in r1) && !(x in r2)) warn[x]=u2[x]
      for (x in warn) printf "WARN: %s unmeasurable in a run (%s) — not a rate increase\n", x, warn[x]
      exit block                                          # 0 = phase may land, 1 = block
    }' <(printf '%s\n' "$reg1") <(printf '%s\n' "$reg2")  # awk's exit is the function's return
}
```

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
Step 4's own gate-fix loop does **not** currently re-invoke the orchestrator (verified
against live code): its "Gate-fix loop" section — after the *initial* `orchestrator gates
4` launch at `step4-verification.md:56-58` — says only "triage (check base branch), fix +
commit, delete old report, re-validate with `--no-test`, re-run gate." The sole
orchestrator call is the initial launch, not the fix loop. So step 4 carries the **same**
stale-evidence bug as steps 1-3: after a fix commit it re-launches the gate subagent
without regenerating evidence at the new HEAD. Apply the identical requirement — the
step-4 fix loop must re-invoke `orchestrator gates 4` before re-launching — and treat it
as a **correctness** fix, not a value/consistency touch: the fix loop is where evidence
freshness matters most, because it decides whether a developer's fix actually cleared a
FAIL.

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
2. Add the `.md`'s read-your-evidence-file instruction by pasting the **verbatim template**
   from "Execution model" (substituting only this gate's literal `<prefix>-<gate>` path)
   *while keeping* the FIRST STEP block; verify the deferred subagent receives identical facts
   via the file. Do not re-word the template per gate. (The per-**step** `orchestrator gates
   <step>` launch is *not* added here — it is a cross-gate change; see "Per-step wiring"
   below.)
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
   base-filter block (`major-version-imports.md:42-47`, `patterns-completeness.md:48`,
   `go-version-check.md:43`), delete the FIRST STEP block surgically and preserve the
   base-filter. (For `major-version-imports.md` the base-filter is the "For each finding,
   check the base branch … report as INFO but do NOT count toward FAIL" block at `:42-47` —
   **not** the "MANDATORY first action" klog grep at `:22`, which is a flag-*everything* rule,
   the opposite of a pre-existing filter; do not mistake `:22` for the filter to keep.) **Also remove the P0a crash-safe fallback *trigger* in the *same* edit —
   do not retarget it to a second copy of the evidence-miss condition.** P0a widened four
   companion `.md` triggers to "if the companion script is not found, crashes, or emits no
   `NEW_ISSUES` line" and added an equivalent branch to `crd-validation`/`patterns-completeness`
   — but once the FIRST STEP block is gone the subagent no longer runs the companion, so
   "crashes / no `NEW_ISSUES` line" is vacuously true on every invocation and the wording
   misleads. The naive fix — rewrite the trigger to *"if `<prefix>-<gate>.evidence` is missing
   or its `HEAD:` line does not match `git rev-parse HEAD` …"* — would restate the **exact
   condition the verbatim template's stale/missing branch already owns**, creating two prose
   blocks that describe one behavior and can drift independently on any later edit (the
   "bundle with the atomic conversion" mitigation only covers the initial conversion, not
   post-landing edits — and it violates this plan's own "do not re-word the template per file"
   principle). Consolidate instead: **delete the standalone fallback trigger sentence
   entirely**; the template's stale/missing branch ("…the evidence is stale/missing — ignore
   it and judge this gate from scratch using the checks below") is the single trigger. What
   stays is the gate-specific **manual-check body** that trigger used to gate (e.g. build-vet's
   `go build`/`go vet` module loop, `build-vet.md:20-44`): those become "the checks below" the
   template points to — keep them, just drop the now-redundant "if the companion script is not
   found, fall back to …" lead-in. One trigger (shared, verbatim), one per-gate check body, no
   duplicated condition to drift. Bundle the deletion with this file's atomic conversion.
   **This clean "delete the lead-in, keep the body" shape holds only for the 3 gates whose
   manual body is self-contained from-scratch prose** — `build-vet` (`:20-44`),
   `version-consistency` (`:19-37`), `go-version-check` (`:18-56`). The other two need more than
   a sentence deletion, because their check bodies are *gated on companion-script output* that
   no longer exists once the FIRST STEP block is gone: `crd-validation.md`'s checks select "CRDs
   the script marked CHANGED-VALIDATION or ALL-NEW" (RULE 2, `:13-19`) and
   `patterns-completeness.md`'s run under `PATH B — Script says BUILD-FAIL or NEW_ISSUES>0`
   (`:14-18`). For these two, "the checks below" the template's judge-from-scratch branch points
   to must be the **from-scratch variant P0a already added** (the new crash branch that runs the
   manual checks against `git show $BASE:` without any script marking — Phase 0(b) group (ii)),
   and the script-marking selectors (`crd-validation` RULE 2; `patterns-completeness`
   PATH A/B lead-ins) are dropped together with the FIRST STEP block, not preserved as "the body."
   For `crd-validation` specifically, that P0a body supplies the replacement **"for each CRD
   schema file in the repository"** scope that RULE 2's deleted lead-in used to provide — so
   "Compare each CRD to the base branch version" (`crd-validation.md:21`) is not left with a
   dangling "each CRD" antecedent. Removing RULE 2 is therefore a *swap* (script-marked scope →
   from-scratch scope), not a bare deletion; do not drop the lead-in without landing the P0a body.
   So step 4 is a two-shape operation: a lead-in deletion for the 3 self-contained gates, and a
   selector-plus-lead-in removal for `crd-validation`/`patterns-completeness`. Those two are not
   symmetric under the swap: `crd-validation` *promotes the authored P0a from-scratch body* (it
   supplies the replacement "for each CRD schema file in the repository" scope), whereas
   `patterns-completeness` has **no** authored from-scratch body — dropping its PATH A/B selectors
   simply exposes checks 1-4, which are already self-contained, so nothing is promoted, only
   uncovered. **For `patterns-completeness` this step is two labeled edits — do both in the one
   atomic edit (per the "in one edit" contract above) or neither:**
   - **(4a)** Drop `patterns-completeness`'s PATH A/B selectors, exposing checks 1-4 (the
     3 self-contained gates' lead-in deletion is the separate shape described above).
   - **(4b) — MANDATORY, same atomic edit:** rewrite the surviving checks header at
     `patterns-completeness.md:18`, whose verbatim text is `--- Checks (PATH B only — skip entirely
     if PATH A applies) ---` (with `---` decorators on both sides), to an unconditional
     `--- Checks ---`. This is pulled out of a parenthetical into an explicit labeled sub-step (for
     the same reason as fix-loop item 6 below) because it is easily missed: skip 4b and checks 1-4
     read as conditionally-skipped once PATH A/B are gone — the same dangling-reference hazard the
     `crd-validation` "each CRD" swap avoids, and a silent false-PASS on a broken rebase.

**Per-step wiring (lands ONCE per step, in the LAST companion-conversion PR for that
step — NOT per gate).** Two step-level edits must not land until every companion in that
step has had its FIRST STEP block removed (steps 1-4 above):
5. **Wire the step `.md` to the orchestrator fast-path** (mirroring
   `step4-verification.md:56-60`, which is the *complete* reference). Two coupled edits, not
   one: **(5a)** prepend the `orchestrator gates <step>` launch (as at `:56-58`), and
   **(5b)** replace that step's *unconditional* launch instruction — `step2-compilation.md:150-151`
   ("Do not skip, batch, or defer any gate — launch all 6 in a single message") and
   `step3-autofix.md:65` ("launch all 11 in a single message") — with "Launch subagents only
   for PENDING gates" (verbatim from `step4-verification.md:60`). Replace **only** that
   clause: `step2-compilation.md:150` co-locates "Do NOT cat the gate files yourself." on the
   same line, which must survive — don't blind-replace the whole `:150-151` range. Without 5b the subagents
   fire for every gate regardless of the orchestrator's PASS resolution, so the fast-path
   saves nothing and re-opens HEAD-drift on already-resolved gates — 5a is inert without 5b.
   This is a cross-gate change: `step2-compilation` has **two** companions (`build-vet`,
   `version-consistency`) and `step3-autofix` has **three** (`crd-validation`,
   `major-version-imports`, `patterns-completeness`). If the pair lands with the *first*
   companion's PR while a sibling's FIRST STEP block is still live, the orchestrator runs
   that sibling (→ PENDING) *and* the spawned subagent re-runs it via its MANDATORY block —
   double execution (for `build-vet` across 3 modules on a dirty tree, up to ~30 min of extra
   `go build`/`go vet` per cycle). So the pair lands in the **last** companion-conversion PR
   for the step, after all that step's FIRST STEP blocks are gone. To make "last" concrete
   and merge-order-independent, **designate** it — `version-consistency` for step 2,
   `patterns-completeness` for step 3 — and gate the wiring PR on a pre-merge check that all
   siblings are already converted: `grep -rl 'MANDATORY FIRST STEP' gates/step2-compilation/`
   (resp. `step3-autofix/`) must return **empty** before 5a/5b merge. If companion PRs merge
   out of order, this check simply blocks the wiring PR until the last block is gone, rather
   than assuming a merge order. (Step 4 already has both 5a and 5b, so only its fix loop,
   item 6, needs touching. Step 1 has no companions and is out of scope here — see the step-1
   note below.)
6. **Update the step's gate-fix re-run loop** (`step2-compilation.md:177-180`,
   `step3-autofix.md:102-108`, **and** `step4-verification.md`'s "Gate-fix loop" — see the
   F3 correction above) to re-invoke `orchestrator gates <step>` *before* deleting the old
   report and re-launching the subagent. With the in-subagent companion run removed, a bare
   re-launch judges with **stale** evidence; regenerating it at the fixed HEAD is a
   **correctness** requirement, not optional polish. This is the same requirement stated in
   the prose above, promoted here to an explicit numbered sub-step so it is not missed by a
   developer following only the list.
7. **One-time (not per-gate): pin the three evidence-path producers together.** The
   `<prefix>-<gate>` string is derived three ways that only *coincidentally* agree today (the
   writer's `GATE_NAME` grep, the orchestrator's `${sd%-*}` suffix-strip, and the literal
   path in each `.md` — see "Execution model"). Resolve the prose "either a sourced helper or
   a test" into a concrete deliverable: **add a k8s-rebase harness assertion** (recommended
   over the `gate_artifact_prefix` helper, which doesn't exist and would touch three call
   sites) that, for every `gates/step*/` dir, the writer-derived and orchestrator-derived
   prefixes are byte-identical and match every `.md`'s named evidence path — landing it as a
   test script under `test/` (e.g. `test/assert-evidence-paths.sh`) wired to a k8s-rebase
   Makefile target and the same pre-Phase-2 checklist/CI hook as `check-phase1-baseline`.
   (Note: the root `make lint` is the skillsaw structural plugin linter — a fixed container
   image over `plugin.json`/skill structure — and cannot run a custom harness script, so this
   assertion is *not* a `make lint` rule; see the enforcement-hook note under Phase 1.) This
   lands once in Phase 2, independent of the per-gate conversions, and turns a silent prefix
   drift into a red build wherever that harness check runs. **Two guards against a vacuous pass:** (i) at Phase-2 landing **zero**
   `.md` files yet carry a named evidence path, so a bare "check every named path" assertion
   passes by checking nothing — add an **exact-count** assertion: the script must find the
   `EVIDENCE (read before judging):` marker (and its named path) in *exactly N* `.md` files,
   where *N* is the number of gate `.md` files that carry the template so far — **not** the count
   of companions (which caps at 6). It is 2 after step 2 lands, 6 after all Phase-2 companion
   conversions, then **> 6** in Phase 3 as the same verbatim template is pasted into each
   companion-*less* gate (`type-conversions`, `rebase-completeness`, `feature-gates` — see
   "Per companion-less gate" in Phase 3, which adds the marker too). Defining *N* as "companions"
   would make `== N` red-build every valid Phase-3 companion-less conversion (marker count
   `7 != 6`); count every `.md` carrying the marker, and bump *N* on companion-*less* additions
   too. Record the expected *N* in the script. Use `== N`,
   **not `>= N`**: with `>= N`, a conversion PR that adds the block but forgets to bump *N*
   still passes (count `N+1 >= N`), and a later accidental removal back to *N* also passes
   (`N >= N`) — a permanent silent blind spot. With `== N`, the forgotten-bump PR produces
   `count = N+1 != N` and fails the build immediately, forcing the *N*-bump into the same PR as
   the block; a later removal then fails against the now-current expected count. (Optionally
   also print `grep -c 'EVIDENCE (read before judging)' gates/**/*.md` in the PR diff so author
   and reviewer see the actual count against the expected *N*.) (ii) The prefix-agreement check must run per converted
   `.md`, not only where a path happens to exist, so a file with the marker but a *drifted*
   path still fails.

**Step 1 is out of scope for this per-step wiring.** `gates/step1-rebase/` holds a single
gate (`rebase-completeness.md`) and **zero companion scripts**, so there is no
companion-conversion PR to carry the wiring, `orchestrator gates 1` would resolve nothing to
PASS (no fast-path to gain), and step 1's fix loop (`step1-rebase.md:91-99`) consumes no
orchestrator-produced evidence — so the item-6 re-invoke requirement is vacuous for it (an
earlier draft wrongly listed `step1-rebase.md:96-99` here). Leave step 1's launch and fix
loop untouched in Phase 2. Only if `rebase-completeness` later gains a companion script or an
evidence shape (a Phase 3 decision) does its wiring land — in that same conversion PR.

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
each also needs its `.md`'s read-your-evidence + HEAD-freshness block (paste the verbatim
template from "Execution model"; the subagent judges from scratch on a miss) **and**
registration in that step's spawn + fix-loop wiring, or the orchestrator never runs it. **Each
such PR pastes the `EVIDENCE (read before judging):` marker into one more `.md`, so it MUST also
bump *N* in `assert-evidence-paths.sh` and run `make assert-evidence-paths` before landing** —
Phase 2 step 7's `== N` guard (which counts *every* marker-carrying `.md`, companion-less
included) turns a forgotten bump into a red build only if the target actually runs, and since no
CI runs the harness yet this is a required per-PR checklist step, not an automatic one. Omitting
it lets the marker count drift silently past the expected *N*. **For
`rebase-completeness` this means adding step-1 wiring that Phase 2 deliberately left out** (see
"Step 1 is out of scope" — step 1 has no companion today, so Phase 2 wired nothing for it). Do
not read the Phase-2 wiring as already covering step 1: authoring `rebase-completeness.sh` in
this phase must, **in the same PR**, apply the step-2/3 items 5a/5b/6 to step 1 — (5a) prepend
`orchestrator gates 1` to `step1-rebase.md` (it has no such call today), (5b) replace its
unconditional gate launch with "Launch subagents only for PENDING gates," and (6) re-invoke
`orchestrator gates 1` in the `step1-rebase.md:91-99` fix loop before re-launching — plus the
Phase-2 step-7 evidence-path lint already covers `step1-rebase/` since it globs every
`gates/step*/` dir. Omit these and the companion exists but the orchestrator never runs it,
with no error signal. And the facts differ per gate: `rebase-completeness` → its five existing
counts; `type-conversions` → the changed conversion sites + the vendor struct's field list
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
| Crash-semantics regression window (Phase 0(b) drops crash→FAIL before consumers handle crash→judge) | Medium | Bounded to a **single PR, not the Phase 0→Phase 2 interval**: the (b) `_gate_trap` rewrite and the per-file companion `.md` crash-safe fallbacks (widen the 4 that have a companion-script trigger; **add** a new crash branch to the 2 that have none — `crd-validation` and `patterns-completeness`) land together, so no interval opens where a crash routes to a subagent whose rules only cover successful runs. Without the co-landing a crash would flip from today's blocking FAIL to a likely blind PASS. See Phase 0(b). |
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
