# Agent Eval Harness Integration — k8s-rebase Skill

## Goal

PR #617 review feedback (enxebre) asks whether k8s-rebase has any eval,
cost estimation, or model measurement, noting other plugins in this
marketplace use the [agent-eval-harness](https://github.com/opendatahub-io/agent-eval-harness).
It currently has none: no `evals/` directory, and `test/test-skill.sh`
(the existing matrix/court test system) captures no cost, token, or
duration data anywhere. This plan gets k8s-rebase onto the same
harness-visible footing as `plugins/ci`, `plugins/code-review`,
`plugins/jira`, and `plugins/openshift-developer` — without discarding
the more rigorous test system k8s-rebase already has, and without
overselling what a green eval run would actually prove.

**Revision note**: this plan was reviewed twice against the real code
(orchestrator, hooks, `cmd_run`, `cmd_court`, `k8s-rebase-autofix.sh`)
and against design-quality concerns. Several parts of the first draft
did not survive: item 1's execution model was wrong (assumed a
synchronous single `claude -p` call; `cmd_run` actually backgrounds
via `claude --bg`), one judge's pass condition was backwards (a
correctly-blocked `git push` attempt produces hook-denial stderr, not
silence), one fixture is already broken (a `known_good` fork branch
404s today), and the fixture-reuse design as originally scoped risked
being tautological — validating "does the skill still do what it was
tuned to do" rather than "does it generalize," which is the same gap
miheer already raised on the PR and this plan had not connected to
that thread. All of this is corrected below; superseded content is
not preserved separately since git history has it.

---

## Context: what already exists

`test/test-skill.sh` (2378 lines) is a hand-rolled eval system, built
before this repo's `evals/` convention existed:

- `test/config-{1.34,1.35,1.36}.yaml` — a real matrix: 6 repos
  (ovn-org/ovn-kubernetes, ovn-kubernetes-mcp, multus-cni,
  ingress-node-firewall, cloud-network-config-controller,
  cluster-network-operator), each pinned to a `from_commit` (the
  broken starting state) and a `known_good` branch/SHA (a real,
  human-reviewed rebase PR to compare against).
- `cmd_run` (test-skill.sh:484-601) launches the skill via
  **`claude --bg`** (backgrounded/detached, not synchronous `-p`)
  against a cloned repo reset to `from_commit`, then returns
  immediately. Progress is polled later by `cmd_test`/`cmd_test_all`
  via `_session_alive` (checks the background process) and
  `_tally_gates` (reads `.rebase-tmp/gates/*.report`).
- `cmd_court` (test-skill.sh:1291-1610) is a full adversarial LLM
  judge: prosecution and defense arguments, a fact-checking judge,
  and a 3-juror panel independently voting PASS/FAIL/ABSTAIN on the
  diff between the result branch and `known_good`. Every FAIL claim a
  juror uses must carry its own `git show <BASE_REF>:<file>`-verified
  evidence line; the rubric explicitly excludes non-regressions
  (style, non-k8s dep drift, MVS-forced version splits); ties,
  quorum failures, and empty-juror runs are all handled as explicit
  `INCONCLUSIVE` outcomes, not silently resolved.
- `_tally_gates` reads `.rebase-tmp/gates/*.report` and produces
  pass/fail/skip counts per step.
- `k8s-rebase-autofix.sh`'s `fix_*` functions run in a **fixed,
  unconditional sequence** (each internally no-ops via its own
  pattern check if it doesn't apply) — not a symptom-keyed dispatch
  table picked by grepping error text. This matters for Item 6 below:
  every one of the 6 matrix repos already exercises the full set of
  currently-known fix functions.

**What's missing**: cost (`total_cost_usd`), token counts, wall-clock
duration, model identity — captured nowhere. And none of this is
discoverable as `evals/` by anyone scanning the repo for eval
coverage, which is exactly what triggered the PR feedback.

**Why not just rewrite test-skill.sh as eval.yaml**: the agent-eval-harness
`case` execution mode is built for single-shot, sub-few-minutes agent
invocations judged against one output artifact. A full k8s-rebase run is
a multi-hour, multi-invocation state machine driving a real git repo
through 32 gates with hooks blocking `go mod`/`git push`. Forcing that
into a single `case` invocation doesn't fit the model. The harness's
`runner.type: cli` mode is designed for exactly this instead: it shells
out to an arbitrary script and just consumes whatever output/metrics
files that script produces. `plugins/openshift-developer/evals/eval-solve.yaml`
+ `scripts/run-solve.sh` prove the pattern works for a multi-phase,
real-repo, real-git-commit agentic pipeline — but note that
`run-solve.sh`'s phases are each a short **synchronous** `claude -p`
call (minutes, not hours per phase); k8s-rebase's per-step work can
run far longer (see Item 4), so the wrapper is modeled on
`run-solve.sh`'s *shape* (per-phase invocation + `jq`-summed cost),
not copied as-is.

---

## Blocking prerequisites (resolve before writing the "real" yaml)

These were Open Questions in the first draft. Two of them are load-bearing
enough that getting them wrong invalidates Items 1-3 outright, not just
the numbers in them — they are sequenced first, not left as footnotes.

### P1. Confirm subagent cost aggregation, and pick a real execution model

Confirmed via research: Claude Code's `total_cost_usd` in a
`stream-json` session's final `result` event aggregates cost from
Agent/Task-tool-launched subagents in the same session, since they
run as part of the same billing session. This holds for k8s-rebase's
step subagents specifically, since `SKILL.md`'s "Execute Current
Step" launches each step via the `Agent` tool (not a nested `claude`
CLI process, which would be a separate untracked billing session).
The gate-subagent fallback path in `rules.md` ("If you cannot launch
subagents, run the gate checks inline") also stays in-session, so it
doesn't break this either.

What does **not** hold is the first draft's assumption that the whole
rebase can be driven by one synchronous `claude -p ... --output-format
stream-json` call. `cmd_run` — the only validated way this skill has
ever been run end-to-end across 6 repos — uses `claude --bg`
(backgrounded), polled via gate-report tallying and session-alive
checks, specifically because a single non-interactive process risks
exceeding turn/context budgets across a multi-hour run with real
compilation breakage and multiple 3-iteration gate-fix loops per gate
(up to 32 gates). `rules.md`'s own "Context budget" and "Stay active"
rules exist because the skill's authors already know single-session
context is scarce over a run this long.

**Decision**: `run-rebase.sh` invokes `claude -p` **once per
orchestrator step** (mirroring `run-solve.sh`'s per-phase pattern,
not one monolithic call), driven by the same `bootstrap -> execute
step -> advance -> repeat` loop `SKILL.md` already documents, and
sums `total_cost_usd`/tokens across all step invocations via `jq -s`
exactly as `run-solve.sh` sums its 3 phases into `total-cost.json`.
This changes the skill's validated execution path from
"one backgrounded session" to "N synchronous per-step sessions
driven by the wrapper script" — that is a real behavioral difference
from `cmd_run`, not just an instrumentation wrapper around it, and
should be explicitly flagged as such when this plan is discussed:
the eval is now exercising a *slightly different* invocation pattern
than the one tested across the 6 repos in the PR description. If
that divergence turns out to matter (e.g. per-step invocation loses
some conversational context `--bg` mode would have kept across
steps — unlikely, since `SKILL.md` already says each step gets "a
fresh agent context" from the orchestrator's boot loader, but not
yet confirmed), fall back to option (b): keep `claude --bg` and
extract cost post-hoc from Claude Code's persisted session
transcript once the background session completes, rather than from
a live stream-json pipe. Try (a) first; only reach for (b) if a real
run shows step-to-step context loss.

### P2. Fix the `dfarrell07/cloud-network-config-controller` fixture now, not later

`https://github.com/dfarrell07/cloud-network-config-controller`
branch `bump1.36` returns 404 today — confirmed directly via `gh api`.
This is a **live blocker**, not a future risk to "consider." Item 3
cannot ship a case for this repo until one of:
- the branch is restored/re-pushed under whatever ref it actually
  lives at now, or
- it's repointed at a different `known_good` commit/branch, or
- it's dropped from the initial case set (5 cases instead of 6) with
  a tracked follow-up to add it back.

Do not let this surface as a silent case failure during a first eval
run — check all 6 `known_good` refs (not just this one) before
writing `evals/cases/k8s-rebase/*/input.yaml`, since fork branches
under a personal account are inherently less durable than upstream
refs. Confirmed still live as of this review: `dfarrell07/ovn-kubernetes-mcp`
branch `bump1.36-20260717052952`, `dfarrell07/multus-cni` branch
`bump1.36`. Re-verify the remaining refs (`ovn-org/ovn-kubernetes`,
`openshift/ingress-node-firewall`, `openshift/cluster-network-operator`
— these use upstream SHAs/branches, not personal forks, so lower risk)
before treating the full 6-case set as ready.

### P3. Confirm what, if anything, actually runs `evals/*.yaml` in this repo

No Makefile target or CI workflow in this repo currently invokes any
existing `eval-*.yaml` automatically — `CONTRIBUTING.md` only notes
`evals/` is a protected directory requiring admin approval to modify.
No cron/schedule mechanism exists in any eval config found in this
repo (checked directly, not assumed). This means writing
`eval-k8s-rebase.yaml` produces a file that *looks* like it satisfies
the marketplace convention, but if nothing runs it, it doesn't
actually answer enxebre's question in substance — it answers it in
form only.

**This must be resolved, and the answer stated plainly to enxebre,
before or alongside proposing Item 2 as complete**: either (a)
confirm a manual-trigger convention exists (how a human runs it —
exact command, prerequisites, expected wait, likely by analogy to
however `eval-solve.yaml` or `trt-agentic-solve` are actually invoked
today — track this down by asking a maintainer or checking harness
docs/tooling directly rather than assuming), or (b) own explicitly
that this is a manually-invoked, no-fixed-cadence artifact, the same
as `make court` is today, and say so rather than imply CI integration
that doesn't exist.

---

## 1. `run-rebase.sh` wrapper: per-step invocation + cost capture — HIGH VALUE

**What**: Add `plugins/k8s-rebase/evals/scripts/run-rebase.sh`. Per
P1's decision, it drives the skill through the same
bootstrap/execute-step/advance loop `SKILL.md` documents, but via
sequential synchronous `claude -p` calls (one per step) instead of
`cmd_run`'s single backgrounded session:

```bash
extract_tokens() {
  grep '"type":"result"' "$1" | head -1 | jq '{
    total_cost_usd: (.total_cost_usd // 0),
    duration_ms: (.duration_ms // 0),
    num_turns: (.num_turns // 0),
    input_tokens: (.usage.input_tokens // 0),
    output_tokens: (.usage.output_tokens // 0),
    model: ((.modelUsage // {} | keys | first) // "unknown")
  }'
}
```

1. Bootstrap: run the orchestrator `init` command directly (shell,
   not an LLM call — matches `SKILL.md`'s Bootstrap section, which is
   pure bash today).
2. Loop: for the current step, launch `claude -p "<step file
   instructions + rules.md + repo context>" --output-format
   stream-json --max-turns <N>`, capture that step's `stream-json`
   output to `step<N>-output.json`, extract tokens/cost via the
   helper above, then run `k8s-rebase-orchestrator.sh advance` exactly
   as `SKILL.md` describes (exit 0 → next step, exit 1 → gate-fix loop
   within the same step's `claude -p` call before re-advancing, exit 2
   with `FORCE_ADVANCE` → record it and continue, exit 2 with `ERROR`
   → abort the case as a hard failure).
3. After `DONE: all steps complete`, run `step5-pr.md`'s instructions
   the same way, capturing its own `stream-json` output.
4. Sum all step-cost JSON files via `jq -s` (matching
   `run-solve.sh`'s `total-cost.json` pattern) into
   `.rebase-tmp/eval-metrics.json`.
5. Copy `.rebase-tmp/gates/*.report` into the harness's expected
   `output/gate-reports/` alongside the diff/commit-log artifacts
   `eval-k8s-rebase.yaml` (Item 2) expects.

**Why**: this is the literal, minimal fix for what enxebre flagged,
while being honest about the fact that it changes the skill's
invocation pattern from backgrounded to per-step-synchronous (see
P1). It requires no changes to `test-skill.sh`'s existing logic and
no risk to the court/jury system — it's a new, parallel driver script,
not a modification of `cmd_run`.

**Implementation**: `run-rebase.sh <repo_url> <from_commit> <version>
[model]`, called by `eval.yaml`'s `runner.type: cli`. Depends on P1
being settled (execution model) before writing this for real.

---

## 2. `evals/eval-k8s-rebase.yaml` — HIGH VALUE

**What**: The harness-visible entry point, structured like
`eval-solve.yaml`:

```yaml
name: k8s-rebase-eval
description: >
  End-to-end eval of the k8s-rebase skill. Runs a full dependency
  rebase against a real repo snapshot, judges gate pass rate,
  gate-fix efficiency, and diff correctness against a human-reviewed
  known-good rebase. Validates pattern-retention (does the skill
  still correctly apply already-encoded fixes), NOT generalization
  to novel, unencoded breakage — see plans/agent-eval-harness.md
  Item 6 for the complementary held-out design that addresses that.
skill: k8s-rebase:k8s-rebase

execution:
  mode: case
  arguments: "{repo_url} {from_commit} {version}"
  timeout: 21600           # 6h — see Item 4; calibrate before trusting this number
  max_budget_usd: 60.0     # placeholder; see Item 4, likely still low
  env:
    AI_HELPERS_DIR: "$PWD"

runner:
  type: cli
  command:
    - "bash"
    - "-c"
    - "exec \"$AI_HELPERS_DIR/plugins/k8s-rebase/evals/scripts/run-rebase.sh\" \"$@\""
    - "--"
    - "{repo_url}"
    - "{from_commit}"
    - "{version}"
    - "{model}"

models:
  skill: claude-opus-4-6
  judge: claude-opus-4-6

mlflow:
  experiment: k8s-rebase-eval

dataset:
  path: cases/k8s-rebase
  schema: |
    Each case directory contains:
    - input.yaml:
      - 'repo_url' — target repo clone URL
      - 'from_commit' — SHA of the pre-rebase base state
      - 'version' — target k8s version (e.g. 1.36.2)
      - 'known_good' — branch/SHA of the human-reviewed reference rebase
    - annotations.yaml:
      - 'expected_gates_pass': integer (e.g. 28)
      - 'expected_gates_total': integer (e.g. 32)
      - 'known_repo_difficulty': simple|medium|complex
      - 'held_out': boolean — true if this case was NOT used to
        develop/tune the autofix patterns (see Item 6); judges and
        report readers should weight held_out cases as the real
        generalization signal, not the tuned-fixture cases
      - 'notes': context for LLM judges (known tricky patterns for
        this repo/version, and — for held_out cases — which specific
        breakage is expected to require novel (not pre-encoded)
        reasoning)

outputs:
  - path: "output"
    schema: |
      Per-step (N = step number):
        step<N>-output.json — raw stream-json for that step's claude -p call
        step<N>-tokens.json — extracted cost/token metrics for that step

      Final state:
        diff.patch, files-changed.txt, commit-log.txt — final rebase output
        gate-reports/ — copy of .rebase-tmp/gates/*.report
        gate-retry-counts.json — per-gate count of report regenerations
          (see gate_fix_loop_efficiency judge below)
        known-good.patch — known_good vs from_commit, for judge comparison
        eval-metrics.json — summed total_cost_usd, duration_ms, num_turns,
          model, across all step invocations
        push-attempt.log — grep of all stderr for push/PR-create hook
          denial or, if absent, explicit confirmation no attempt occurred
          (see pr_command_never_attempted_or_blocked judge below)

traces:
  stdout: true
  stderr: true
  events: false
  metrics: true

judges:
  # ── deterministic ──

  - name: all_gates_resolved
    description: Every gate report is PASS or SKIP; none PENDING or FAIL at run end
    check: |
      # parse outputs["files"]/["modified_files"] for gate-reports/*.report,
      # assert every file's VERDICT line is PASS or SKIP

  - name: gate_pass_rate_meets_expected
    description: Gate pass count meets annotations.expected_gates_pass
    check: |
      # count PASS verdicts across gate-reports/*.report, compare to
      # annotations["expected_gates_pass"]

  - name: no_forced_advance
    description: Orchestrator never emitted FORCE_ADVANCE during the run
    check: |
      # grep all step<N>-output.json / stdout traces for the literal
      # string "FORCE_ADVANCE" — must not appear

  - name: pr_command_never_attempted_or_blocked
    description: >
      Either no git push / gh pr create was attempted, or it was
      attempted and the block-push.sh hook's denial message is present
      immediately after — a hook block produces denial text in stderr,
      NOT silence, so "clean stderr" alone does not distinguish
      "correctly blocked" from "never got far enough to try."
    check: |
      # search push-attempt.log for either (a) no push/pr-create
      # invocation anywhere in the transcript, or (b) an invocation
      # immediately followed by the hook's actual denial string —
      # read hooks/block-push.sh directly to get its exact message
      # text before writing this check, don't guess the string

  - name: gate_fix_loop_efficiency
    description: >
      Surfaces retry cost as a distinct signal from pass/fail — a gate
      that passes clean and a gate that passes after 3 retries on a
      false-positive FAIL look identical to the judges above without
      this. Not a hard gate (no threshold below), reported for
      trend-tracking.
    check: |
      # read gate-retry-counts.json, report per-gate retry counts;
      # no pass/fail verdict, this judge is informational

  # ── LLM, adapted from cmd_court's rubric — see Item 5's caveat
  #    about the rigor this necessarily gives up relative to court's
  #    3-juror + judge + evidence-citation design ──

  - name: rebase_correctness
    description: >
      Single-pass adaptation of cmd_court's PASS/FAIL criteria.
      WEAKER than court: no adversarial prosecution/defense, no
      multi-juror vote, no mandatory per-claim git-show evidence.
      Treat a low score here as "worth running make court to get a
      real verdict," not as a verdict itself.
    prompt: |
      <cmd_court's PASS/FAIL criteria text (test-skill.sh:1338-1398),
      adapted to {{ outputs }}, including the REBASE-SCOPE CHECK and
      EVIDENCE CONSTRAINT language verbatim — those constraints matter
      even in a single-judge context>

  - name: no_scope_creep
    description: Changes are directly required by the version bump
    prompt: |
      <rules.md's Scope section, turned into a judge>

thresholds:
  all_gates_resolved: { min_pass_rate: 1.0 }
  no_forced_advance: { min_pass_rate: 1.0 }
  pr_command_never_attempted_or_blocked: { min_pass_rate: 1.0 }
  gate_pass_rate_meets_expected: { min_pass_rate: 0.9 }
  rebase_correctness: { min_mean: 3.5 }
  no_scope_creep: { min_mean: 4.0 }
  # gate_fix_loop_efficiency: no threshold — informational only
```

**Why**: matches the repo convention exactly. The deterministic
judges encode the skill's hard safety invariants (no forced-advance
degradation, no successful unblocked push) as harness-visible facts.
`gate_fix_loop_efficiency` closes the gap where cost/turns/pass-rate
alone can't distinguish a clean pass from a thrashy one. The
`pr_command_never_attempted_or_blocked` judge's logic is corrected
from the first draft, which had it backwards (see Blocking
Prerequisites intro and the judge's own description).

**Implementation**: write the yaml, adapt (not blindly copy)
`cmd_court`'s criteria text into `rebase_correctness`, and be
explicit in the judge's own `description` field that this is a
deliberately weaker single-pass check, not a like-for-like
replacement — don't let the yaml imply parity with court that
doesn't exist. Write the deterministic judges as Python `check:`
functions against files `run-rebase.sh` (Item 1) actually produces —
this has a hard dependency on Item 1 landing first, since the judges
assume `gate-retry-counts.json` and `push-attempt.log` exist, which
is new capture logic Item 1 must add (not already present in
`_tally_gates`).

---

## 3. Eval cases from the existing matrix config, with one held-out — HIGH VALUE

**What**: `evals/cases/k8s-rebase/case-001` through `case-005` (5,
not 6, per P2 — `cloud-network-config-controller` is blocked until
its fixture is fixed), each `input.yaml` a direct translation of that
repo's existing `from_commit`/`known_good` entry from
`test/config-1.36.yaml`:

```yaml
# case-001/input.yaml
repo_url: https://github.com/ovn-org/ovn-kubernetes
from_commit: f261f146c0625bbdb5933298cfcbebd7f392223d
version: "1.36.2"
known_good: af1d95ca97f9237e27d4c78fb8691946fa5cab73
```

Plus `annotations.yaml`'s `held_out: false` for all 5 (see Item 6 —
the held-out case is a separate, new fixture, not one of these 5).

Register all cases in `evals/README.md`'s case index (skillsaw
`eval-case-registered` rule).

**Why**: reusing 5 of the 6 already-validated matrix repos gives a
real, proven correctness baseline for pattern-retention testing at
low setup cost. This is explicitly *not* claimed to be a
generalization test — see Item 6 for why that distinction matters and
what closes the gap. Framing it as "the eval" without that caveat
would let a green run be misread as answering miheer's original PR
concern about untested-pattern breakage, which it doesn't.

**Implementation**: mechanical — copy 5 of the 6 entries out of
`test/config-1.36.yaml` (skip cloud-network-config-controller per
P2), re-verify every `known_good` ref resolves (not just the
previously-flagged one) immediately before writing the case files, so
a fixture doesn't silently 404 mid-implementation.

---

## 4. Cost/time calibration pass — HIGH VALUE (elevated from Medium)

**What**: Before committing to `max_budget_usd`/`timeout` in the yaml,
run `run-rebase.sh` once against the smallest/fastest case (likely
`ovn-kubernetes-mcp` or `multus-cni`) and record actual
`total_cost_usd`/`duration_ms` per step and summed.

**Why elevated to HIGH / blocking**: the only concrete timing data
point found anywhere in this codebase is `plans/observability.md`'s
narrative mention of "Step 4 lint took 26m" for a *single step* on
one run. Four steps, each potentially with multiple 3-iteration
gate-fix loops across up to 32 gates, plausibly exceeds several
hours for a large repo like `ovn-org/ovn-kubernetes` — the original
draft's 4h/$40 numbers, and even this revision's bumped 6h/$60, are
guesses that existing signals suggest skew low, not high. Guessing
wrong here doesn't just produce cosmetic inaccuracy: a `timeout` or
`max_budget_usd` set too low would abort a real, otherwise-correct
run mid-gate-fix-loop, producing a false FAIL that looks like a skill
regression when it's actually an eval-config error. Given items 1-3
now structurally depend on Item 1's wrapper existing, and Item 2's
budget/timeout fields are load-bearing for whether the eval produces
real results vs. false negatives, this must happen before Item 2's
numbers are treated as anything but placeholders — not merely "do
this informally," but a hard gate before the yaml is proposed as
ready.

**Implementation**: one manual run against the cheapest case, logged
in this file once done (update the placeholder numbers above with
real ones and remove the "placeholder" caveat from the yaml
comments), then commit the calibrated numbers as a follow-up.

---

## 5. What `rebase_correctness` gives up relative to `cmd_court` — explicit tradeoff, not silently accepted

**What**: `cmd_court`'s entire design — prosecution/defense arguments,
a fact-checking judge, 3 independent jurors each required to cite
`git show <BASE_REF>`-verified evidence for every FAIL claim, explicit
tie/quorum/empty-juror handling — exists specifically because a single
LLM call judging a large diff is unreliable for this task. Item 2's
`rebase_correctness` judge collapses that into one `prompt:` call.
That is a real rigor regression, not just a simplification, and the
plan should not present it as a like-for-like port of court's rubric
(the first draft's "ported... almost verbatim" language implied
parity that doesn't exist — corrected in Item 2 above).

**What to do about it**: two options, not mutually exclusive:

1. **Check whether the harness's `agent:` judge type can host a
   reduced court.** If judges can be defined as agents with `Bash`
   tool access (not just single-shot `prompt:` judges), a
   1-juror-with-mandatory-`git show`-evidence judge would materially
   close the gap without reimplementing all 3 jurors. Confirm this
   capability exists before assuming `prompt:`-only judges are the
   ceiling — the first draft never checked this.
2. **If the harness genuinely can't represent multi-vote
   adjudication**, keep `rebase_correctness` as a cheap smoke check
   (as scoped in Item 2, with its description explicitly saying so)
   and treat `make court` as the actual quality gate for anything
   `rebase_correctness` scores as borderline (below ~4/5) or that a
   human wants a real verdict on before trusting. Do not let a
   passing `rebase_correctness` score alone stand in for a `make
   court` run when the stakes are "should this rebase PR go out."

**Why this is its own item and not folded into Item 2**: it's a
judgment call the plan should make explicitly and visibly, not bury
inside a yaml's judge definitions where the tradeoff could get lost.

---

## 6. Held-out case: testing generalization, not just pattern-retention — HIGH VALUE, addresses miheer's PR concern directly

**What**: Add exactly one eval case — `evals/cases/k8s-rebase/case-006`,
`annotations.yaml`'s `held_out: true` — built from a repo/version
combination that was **not** used while developing or tuning the
current `fix_*` functions in `k8s-rebase-autofix.sh`. Concretely,
either: (a) a 7th repo not in `test/config-*.yaml` today, or (b) one
of the existing 5 repos at a k8s version the skill hasn't targeted
yet (e.g. once 1.37 is out, before any 1.37-specific autofix pattern
has been written for it).

**Why this is not optional polish**: the 5 cases in Item 3 all come
from the same matrix used to develop and validate the skill in the
first place — confirmed directly, `k8s-rebase-autofix.sh`'s `fix_*`
functions run in a fixed, unconditional sequence, meaning all 5
repos already exercise the exact fix set the skill was built to
handle. An eval built entirely from these fixtures measures "does the
skill still correctly apply already-known fixes" (regression
detection — genuinely valuable, but not what the PR discussion is
asking about). It does **not** measure whether the skill's reasoning
generalizes to breakage nobody has pre-encoded a fix for. That is
precisely miheer's original, still-unresolved concern on PR #617:
that cluster-level or version-specific breakage the skill hasn't seen
before (their examples: RelaxedServiceNameValidation-adjacent issues,
KubeVirt live-migration failures, MetalLB/FRR image mismatches,
silent kubeadm setting drops) is invisible to a design that only
checks build/vet/lint/unit tests locally and never runs e2e. A green
run across Item 3's 5 tuned-fixture cases does not answer that
concern, and this plan should not be read — by enxebre, by miheer, or
by anyone skimming a future green CI badge — as having answered it
without Item 6 landing.

**Implementation**: this is real fixture-creation work, not a
mechanical config copy like Item 3 — it requires either finding a 7th
real repo with a real historical rebase PR to use as `known_good`, or
waiting for a genuinely new k8s version to land before the skill's
own patterns catch up to it. Track it as its own follow-up rather
than blocking Items 1-4 on it, but do not present Items 1-4 alone as
"the eval is done" — the plan's own judges (`rebase_correctness`
etc.) should report `held_out` cases separately in any summary so a
reader can tell pattern-retention pass rate apart from generalization
signal at a glance, once this case exists.

---

## 7. Repeat-run variance — don't present one sample as a verdict — MEDIUM VALUE

**What**: `rules.md`'s own Gate-Fix Loop explicitly expects the agent
not to pass every gate on the first attempt ("up to 3 iterations"),
and autofix/gate-subagent judgment calls are not bit-for-bit
reproducible run to run. A single pass/fail per case is one draw from
a distribution, not a stable measurement — a flaky skill and a solid
skill can produce the same single-run outcome by chance.

**What to do about it**: given Item 4's cost findings (a single case
run is likely to run several hours and tens of dollars), running
N≥3 repeats across all 5-6 cases is expensive. Scope this narrowly:
run the **calibration case** from Item 4 at least 3 times and report
a pass-rate rather than a boolean before treating any single case's
result as meaningful, and flag in this plan (not silently decide)
whether full N-repeat across every case is judged worth the cost once
real numbers exist. Don't ship N=1 as the unstated default.

**Why MEDIUM not HIGH**: this compounds Item 4's cost problem rather
than introducing a new blocking risk — it's a quality improvement to
make once the cheaper items are working, not a prerequisite for a
first working eval to exist at all.

---

## 8. Gate-script unit tests (separate from the harness) — MEDIUM VALUE, DIFFERENT MECHANISM

**What**: The 8 gate `.sh` companion scripts (`build-vet.sh`,
`feature-gates.sh`, `major-version-imports.sh`, `crd-validation.sh`,
`patterns-completeness.sh`, `rebase-completeness.sh`,
`version-consistency.sh`, `go-version-check.sh`) are pure deterministic
bash — they don't need LLM judging at all. A `test/gate-scripts/`
directory with small synthetic fixture repos (a `go.mod` +
`known_features.go` for `feature-gates.sh`, etc.) and expected
PASS/FAIL/SKIP outputs, run via `bats` or a plain bash assertion loop.

**Why**: these are the cheapest, fastest, highest-precision things to
test, and they currently have zero dedicated test coverage — they're
only exercised indirectly by full matrix runs. A regression in
`feature-gates.sh`'s wiring-discovery logic (e.g. layer 3's
`SetFromMap` parsing) would currently only surface as a mysterious
gate FAIL/PASS flip on the next multi-hour matrix run.

**Why this is NOT part of `evals/`**: agent-eval-harness is for judging
*agent* behavior (LLM reasoning, code quality, correctness of AI
decisions). Gate scripts contain no AI — testing them doesn't need
cost/token/mlflow tracking, judges, or `claude -p` invocations at all.
Bundling them into `evals/` would be scope creep on the harness and
slower than a plain shell test. Keep them as `test/gate-scripts/`,
separate from `evals/`.

**Implementation**: lower priority relative to 1-4 (doesn't answer
enxebre's actual question directly), but should land before or
alongside the eval work since it de-risks the deterministic judges in
Item 2, which depend on gate-report format staying correct.

---

## Non-Goals

- **Full 5-step orchestration as a single harness `case`.** The
  harness's `case` execution model assumes a single subprocess
  invocation scored against one output snapshot; k8s-rebase is a
  stateful multi-invocation workflow spanning hours with hooks
  enforcing safety invariants across the whole run. `runner.type: cli`
  sidesteps this by treating the entire orchestrated run as one
  opaque script execution (Items 1-3 above).
- **Reimplementing `k8s-rebase-orchestrator.sh`'s step-sequencing
  logic inside the harness.** This is narrower than the first draft's
  Non-Goal, which incorrectly also ruled out per-step *testing* — it
  does not. Testing one step's logic in isolation against a
  pre-seeded fixture (a repo checked out at a known Step-2-broken
  state, one `claude -p` call against just that step, judged against
  that step's expected diff) requires zero state-machine
  reimplementation: it's a single invocation against a single
  fixture, structurally identical to `eval-detect-permafail`'s shape.
  This was wrongly rejected in the first draft; it isn't scoped as an
  Item above because it's genuinely separate follow-on work (a
  different eval.yaml entirely, e.g. `eval-k8s-rebase-step2.yaml`),
  but a future contributor should not read this plan as having ruled
  it out — it's the one architecture cheap and fast enough to
  plausibly run in normal per-PR CI, which nothing in Items 1-6 can
  do given Item 4's cost profile. Worth a follow-up plan of its own.
- **Replacing `cmd_court`.** See Item 5 — `rebase_correctness` is
  scoped explicitly as a weaker smoke check, not a replacement.
- **Running the full 5-6-case eval on every PR.** Given the cost/time
  profile (Item 4), and given P3's finding that no automatic
  eval-running mechanism currently exists in this repo for *any*
  `evals/*.yaml`, this stays a manually-triggered artifact for now —
  same operating model as `make court` today. Do not imply CI
  integration in the PR reply that doesn't actually exist (see P3).

---

## Implementation order

1. **P1, P2, P3 (Blocking prerequisites)** — resolve all three before
   writing anything beyond a draft yaml. P1 determines whether Item
   1's wrapper design is even correct; P2 determines whether Item 3
   ships 5 or 6 cases; P3 determines whether this plan is proposing a
   real CI-integrated artifact or an honest manually-triggered one —
   getting P3 wrong risks overselling the deliverable to enxebre.
2. **Item 4 (cost/time calibration)** — run once against the cheapest
   case before Item 2's yaml numbers are anything but placeholders.
3. **Item 1 (`run-rebase.sh` wrapper)** — depends on P1's execution
   model decision and Item 4's real numbers for sane per-step
   `--max-turns`/timeout values.
4. **Item 2 (`eval-k8s-rebase.yaml`) + Item 3 (5 cases)** — depends on
   1-3 above; this is the harness-visible artifact enxebre asked
   about. Ship with Item 5's tradeoff explicitly documented in the
   judge descriptions, not glossed over.
5. **Item 8 (gate-script unit tests)** — independent, can happen in
   parallel with 1-4; de-risks Item 2's deterministic judges.
6. **Item 7 (repeat-run variance)** — after Item 3 exists and Item 4's
   real cost numbers are known, decide and document the repeat-count
   policy rather than silently shipping N=1.
7. **Item 6 (held-out case)** — real fixture-creation work, tracked
   as its own follow-up; do not present Items 1-5 as "the eval is
   done" or as answering miheer's generalization concern without
   this landing.
8. **Reply to PR #617** pointing at this plan, being explicit about
   what's shipped vs. planned, and explicitly distinguishing
   pattern-retention testing (Items 1-4, ready sooner) from
   generalization testing (Item 6, the actual answer to miheer's
   concern, landing later). Owner/timing: whoever picks this plan up
   should post the reply once Items 1-4 are real and working, not
   before — a reply describing yaml that doesn't exist yet would be
   worse than the current silence on the thread.
</content>
