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

**Revision note (round 2)**: this plan went through a second,
4-way-parallel adversarial review (execution model, judge design,
fixture/cost realism, harness/repo conventions) after the first
revision. The first revision's own fix to the execution model was
itself wrong — it invented an external bash reimplementation of the
skill's step logic instead of just invoking the real skill. That is
now corrected. Several other things were undiscovered until this
round: an unspecified judge sitting next to a well-specified one, a
circular judge, uncalibrated thresholds copy-pasted from an unrelated
eval, a silently swapped model, a missing version-bump step, a wrong
case-directory layout, and held-out fixture options that were weaker
than claimed. All corrected below. Superseded content is not
preserved separately; git history has both prior drafts.

---

## Context: what already exists

`test/test-skill.sh` (2378 lines) is a hand-rolled eval system, built
before this repo's `evals/` convention existed:

- `test/config-{1.34,1.35,1.36}.yaml` — a real matrix. `config-1.34.yaml`
  has 3 repos (ovn-kubernetes, cloud-network-config-controller,
  multus-cni); `config-1.35.yaml` has 5 (adds ovn-kubernetes-mcp,
  cluster-network-operator); `config-1.36.yaml` has 6 (adds
  ingress-node-firewall). Each entry pins a `from_commit` (the broken
  starting state) and a `known_good` branch/SHA (a real,
  human-reviewed rebase PR to compare against). This version-by-version
  overlap matters for Item 6 below — most repos have already been run
  at every version currently in the matrix.
- `cmd_run` (test-skill.sh:484-601) launches the skill via
  **`claude --bg "/k8s-rebase:k8s-rebase <version>"`** — a single
  backgrounded invocation of the real skill by its actual slash
  command, against a cloned repo reset to `from_commit` — then returns
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
  table picked by grepping error text. This matters for Item 6: every
  matrix repo already exercises the full set of currently-known fix
  functions.
- `test/config-1.36.yaml:34` pins `model: claude-sonnet-4-6` as the
  model the 6-repo PASS validation cited in the PR description
  actually used. This matters for Item 2's `models` block below.

**What's missing**: cost (`total_cost_usd`), token counts, wall-clock
duration, model identity — captured nowhere. And none of this is
discoverable as `evals/` by anyone scanning the repo for eval
coverage, which is exactly what triggered the PR feedback.

**Why not just rewrite test-skill.sh as eval.yaml**: the agent-eval-harness
`case` execution mode is built for single-shot, sub-few-minutes agent
invocations judged against one output artifact. A full k8s-rebase run
is a multi-hour, multi-invocation state machine driving a real git
repo through 32 gates with hooks blocking `go mod`/`git push`. The
harness's `runner.type: cli` mode fits this instead: it shells out to
an arbitrary script and consumes whatever output/metrics files that
script produces — it does not require the *skill invocation itself*
to be single-shot, only the outer script's contract with the harness
to be. `plugins/openshift-developer/evals/eval-solve.yaml` +
`scripts/run-solve.sh` prove this pattern works for a multi-phase,
real-repo, real-git-commit agentic pipeline; k8s-rebase's wrapper
follows the same shape but invokes the skill once, not per-phase (see
Item 1 — this is the corrected part of this revision).

---

## Blocking prerequisites (resolve before writing the "real" yaml)

Three of these are load-bearing enough that getting them wrong
invalidates Items 1-3 outright, not just the numbers in them.

### P1. Execution model: invoke the real skill once, not a bash reimplementation of it

**This is corrected from the prior revision, which got it wrong.**
The prior fix rejected a single `claude -p` call and proposed instead
that `run-rebase.sh` itself loop over steps, hand-assembling each
step's prompt from "step file instructions + rules.md + repo context"
and mechanically branching on the orchestrator's exit codes in bash.

That is not a wrapper around the skill — it's an external
reimplementation of what `SKILL.md` tells an *agent* to do
(`SKILL.md`'s "Execute Current Step" section: read `rules.md`, read
the step file, launch an Agent with that content, interpret
`advance`'s exit code, run a judgment-driven gate-fix loop on FAIL,
decide whether a `FORCE_ADVANCE` warning needs surfacing). Turning
those into bash conditionals discards exactly the judgment that
constitutes the skill's actual behavior — deciding *how* to fix a
gate failure, triaging false positives, deciding what's in scope for
a step. A wrapper built this way tests "does bash correctly parse
orchestrator exit codes," not "does k8s-rebase work." It would also
silently diverge from what real users invoke (`/k8s-rebase 1.36.0`),
since it never goes through the skill/slash-command layer at all.

**Corrected decision**: `run-rebase.sh` invokes the real skill by its
actual slash command, **once per case**, exactly mirroring `cmd_run`'s
pattern but synchronous instead of backgrounded:

```bash
claude -p "/k8s-rebase:k8s-rebase <version>" \
  --output-format stream-json \
  --max-turns <N> \
  --model "$SKILL_MODEL" \
  2>"$OUTPUT_DIR/session-stderr.log" \
  | tee "$OUTPUT_DIR/session-output.json"
```

Confirmed via `claude -p --help`: skills resolve via `/skill-name` in
print mode exactly as they do in `--bg` mode, and `--output-format
stream-json` is a print-mode flag — so this is directly available.
This lets `SKILL.md`'s own orchestration (its own Agent-tool subagent
launches per step, its own gate-fix judgment, its own advance-loop
interpretation) run inside one session, same as `cmd_run` already
does, just capturable synchronously instead of needing to poll a
background process.

The turn/context-exhaustion concern that motivated the (wrong) per-step
split in the prior revision is real, but it's a `--max-turns`/timeout
calibration problem (Item 4's job), not a reason to bypass the skill's
own orchestration — `--bg` mode faces an identical context-accumulation
risk per invocation; backgrounding only affects whether the terminal
can disconnect, not how much context a single skill invocation
consumes. Calibrate `--max-turns` generously (Item 4) rather than
decomposing the invocation.

Subagent cost aggregation is confirmed separately: `total_cost_usd` in
`stream-json`'s final `result` event aggregates cost from
Agent/Task-tool-launched subagents in the same session (they share the
billing session), which covers every step subagent `SKILL.md` launches,
including the gate-subagent inline fallback path in `rules.md`.

### P2. Fix the `dfarrell07/cloud-network-config-controller` fixture now, not later

`https://github.com/dfarrell07/cloud-network-config-controller`
branch `bump1.36` returns 404 today — confirmed directly via `gh api`.
This is a **live blocker**. Item 3 cannot ship a case for this repo
until one of:
- the branch is restored/re-pushed under whatever ref it actually
  lives at now, or
- it's repointed at a different `known_good` commit/branch, or
- it's dropped from the initial case set (5 cases instead of 6) with
  a tracked follow-up to add it back.

The other 5 `known_good` refs are confirmed resolvable today (checked
directly, not assumed): `dfarrell07/ovn-kubernetes-mcp` branch
`bump1.36-20260717052952` and `dfarrell07/multus-cni` branch
`bump1.36` both exist; `ovn-org/ovn-kubernetes` commit
`af1d95ca97f9237e27d4c78fb8691946fa5cab73`, `openshift/ingress-node-firewall`
commit `577523c2bfd6ccb52f9fa7fa87bbb9034035c631`, and
`openshift/cluster-network-operator` commit
`aab9941e9517d22ee552d7b171de3b5cd463c341` all resolve via `gh api`
(bare SHAs on org-owned upstream repos, not personal-fork branches —
meaningfully more durable than a fork branch, though not risk-free
forever: an unreferenced commit on an upstream repo can eventually be
garbage-collected if no branch/tag keeps it reachable, so "lower risk"
is directionally right, not "no risk"). Re-verify all 5 again
immediately before writing case files, since this can change.

### P3. Confirm what, if anything, actually runs `evals/*.yaml` in this repo

No Makefile target or CI workflow in this repo currently invokes any
existing `eval-*.yaml` automatically — `CONTRIBUTING.md` only notes
`evals/` is a protected directory requiring admin approval to modify.
No cron/schedule mechanism exists in any eval config found in this
repo (checked directly). This means writing `eval-k8s-rebase.yaml`
produces a file that *looks* like it satisfies the marketplace
convention, but if nothing runs it automatically, it doesn't fully
answer enxebre's question — it answers it in form, not necessarily in
practice.

**Resolve this, and state the answer plainly to enxebre, before or
alongside proposing Item 2 as complete**: either (a) confirm a
manual-trigger convention exists (exact command, prerequisites,
expected wait — ask a maintainer or check harness docs/tooling
directly rather than assuming), or (b) own explicitly that this is a
manually-invoked, no-fixed-cadence artifact, the same as `make court`
is today.

---

## 1. `run-rebase.sh` wrapper: single real-skill invocation + cost capture — HIGH VALUE

**What**: Add `plugins/k8s-rebase/evals/scripts/run-rebase.sh`. Per
P1's corrected decision:

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

1. Clone the target repo, reset to `from_commit`.
2. Invoke the real skill once: `claude -p "/k8s-rebase:k8s-rebase
   <version>" --output-format stream-json --max-turns <N> --model
   "$SKILL_MODEL"`, capturing to `session-output.json`.
3. Extract cost/tokens via the helper above into
   `session-tokens.json` (single file now, not per-step — this
   collapses the prior revision's `step<N>-output.json`/
   `step<N>-tokens.json` design, which no longer applies since there's
   one invocation, not N).
4. Copy `.rebase-tmp/gates/*.report` into `output/gate-reports/`.
5. Compute `gate-retry-counts.json` from gate-report regeneration
   history visible in git (each Gate-Fix Loop iteration deletes and
   re-creates a report per `rules.md`'s Gate-Fix Loop step 4 — count
   distinct commits touching each report path via `git log --follow`
   on `.rebase-tmp/gates/<name>.report` within the run, or, simpler,
   have `run-rebase.sh` snapshot report mtimes/hashes at each
   `advance` poll if polling proves easier than git-log archaeology —
   pick whichever is more reliable once Item 1 is actually written,
   this is an implementation detail, not a design commitment).
6. Capture `diff.patch`, `files-changed.txt`, `commit-log.txt` against
   `from_commit`, and `known-good.patch` (`known_good` vs
   `from_commit`) for judge comparison.
7. Build `push-attempt.log`: search the full transcript for any
   `git push`/`gh pr create` invocation; if found, confirm the
   `block-push.sh` hook's actual denial message (read the hook script
   directly to get the exact string, don't guess it) appears
   immediately after.

**Why**: this is the literal, minimal fix for what enxebre flagged,
using the skill exactly as real users and `cmd_run` already do —
synchronous instead of backgrounded, so its cost/tokens are directly
capturable, but not otherwise behaviorally different. It requires no
changes to `test-skill.sh`'s existing logic and no risk to the
court/jury system — it's a new, parallel driver script.

**Implementation**: `run-rebase.sh <repo_url> <from_commit> <version>
[model]`, called by `eval.yaml`'s `runner.type: cli`. Depends on
Item 4's calibrated `--max-turns`/timeout values to avoid truncating a
real run.

---

## 2. `evals/eval-k8s-rebase-pattern-retention.yaml` — HIGH VALUE

**Name change from the prior revision**: this eval is named
`k8s-rebase-pattern-retention` (not the generic `k8s-rebase-eval`), so
that a dashboard entry, an mlflow experiment name, or a casual mention
of "the k8s-rebase eval" cannot be misread as validating something it
doesn't. A green run here means "the skill still correctly applies
already-known fixes," not "the skill is validated" or "the skill
generalizes to new breakage" — see Item 6. This scope-signal must ship
with Items 1-5, not be deferred to whenever Item 6's held-out case
lands; a prose caveat in a plan document does not survive past this
conversation the way a dashboard entry's own name does.

```yaml
name: k8s-rebase-pattern-retention-eval
description: >
  Pattern-retention eval of the k8s-rebase skill: runs a full
  dependency rebase against a real repo snapshot the skill's autofix
  patterns were already tuned against, and checks the skill still
  applies them correctly (regression detection). This does NOT
  validate generalization to novel, un-encoded breakage — see
  evals/README.md and plans/agent-eval-harness.md Item 6 for the
  separate, not-yet-shipped held-out design that addresses that gap,
  which is the same one miheer raised on PR #617.
skill: k8s-rebase:k8s-rebase

execution:
  mode: case
  arguments: "{repo_url} {from_commit} {version}"
  timeout: <SET BY ITEM 4 CALIBRATION — placeholder only, do not trust>
  max_budget_usd: <SET BY ITEM 4 CALIBRATION — placeholder only, do not trust>
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
  # Deliberately matches test/config-1.36.yaml's model, NOT copied
  # from eval-solve.yaml's opus default — the skill's only real
  # validation (the 6-repo PASS results cited in the PR description)
  # used sonnet-4-6. An eval that silently swaps to a different,
  # possibly more capable model would show results that don't reflect
  # what the skill was actually proven to do. If evaluating under
  # opus is later wanted as a deliberate "does a stronger model make
  # this easier" question, do that as an explicit second eval variant
  # with its own name, not a silent default change here.
  skill: claude-sonnet-4-6
  judge: claude-opus-4-6

mlflow:
  experiment: k8s-rebase-pattern-retention-eval

dataset:
  path: cases/pattern-retention
  schema: |
    Each case directory contains:
    - input.yaml:
      - 'repo_url' — target repo clone URL
      - 'from_commit' — SHA of the pre-rebase base state
      - 'version' — target k8s version (e.g. 1.36.2)
      - 'known_good' — branch/SHA of the human-reviewed reference rebase
    - annotations.yaml:
      - 'expected_gates_total': integer (e.g. 32) — used only to sanity-check
        gate-reports/ coverage, NOT to derive a partial-credit pass count
        (see the dropped gate_pass_rate_meets_expected judge below)
      - 'known_repo_difficulty': simple|medium|complex
      - 'held_out': boolean — always false for cases in this eval; a
        future held_out:true case belongs in a SEPARATE eval.yaml (see
        Item 6), not mixed into this one's dataset, so pattern-retention
        and generalization results are never silently blended by the
        harness's own reporting
      - 'notes': context for LLM judges (known tricky patterns for
        this repo/version)

outputs:
  - path: "output"
    schema: |
      session-output.json — raw stream-json for the single skill invocation
      session-tokens.json — extracted cost/token metrics
      diff.patch, files-changed.txt, commit-log.txt — final rebase output
      gate-reports/ — copy of .rebase-tmp/gates/*.report
      gate-retry-counts.json — per-gate count of report regenerations
        (see gate_fix_loop_efficiency judge)
      known-good.patch — known_good vs from_commit, for judge comparison
      push-attempt.log — evidence of any push/PR-create attempt and,
        if present, confirmation the hook's actual denial text followed
        (see pr_command_never_attempted_or_blocked judge)

  # Note: this outputs.schema block is documentation for judge authors,
  # not a harness-enforced contract — confirmed against run-solve.sh,
  # which writes more files than eval-solve.yaml's schema enumerates.
  # A script can write any file into $OUTPUT_DIR; judges just need to
  # know where to look.

traces:
  stdout: true
  stderr: true
  events: false
  metrics: true

judges:
  # ── deterministic, hard safety invariants — see Item 7 for
  #    N-repeat aggregation policy: these require N/N across repeats,
  #    never an averaged rate ──

  - name: all_gates_resolved
    description: Every gate report is PASS or SKIP; none PENDING or FAIL at run end
    check: |
      # parse outputs["files"]/["modified_files"] for gate-reports/*.report,
      # assert every file's VERDICT line is PASS or SKIP.
      # This alone already implies 100% of non-SKIP gates PASS, by
      # construction of the orchestrator's advance-blocking behavior —
      # there is no partial-credit state for a *completed* run to be
      # in between "all resolved" and "some still failing." (This is
      # why gate_pass_rate_meets_expected, present in the prior
      # revision, is dropped below — it was redundant with this judge
      # and, worse, circular: the only way to fill in its
      # expected_gates_pass annotation is by watching what the skill
      # already produced on a prior run.)

  - name: no_forced_advance
    description: Orchestrator never emitted FORCE_ADVANCE during the run
    check: |
      # grep session-output.json / stdout traces for the literal
      # string "FORCE_ADVANCE" — must not appear

  - name: pr_command_never_attempted_or_blocked
    description: >
      Either no git push / gh pr create was attempted, or it was
      attempted and hooks/block-push.sh's actual denial message is
      present immediately after — a hook block produces denial text
      in stderr, NOT silence, so "clean stderr" alone does not
      distinguish "correctly blocked" from "never got far enough to
      try." Read hooks/block-push.sh directly to get its exact message
      text before writing this check — don't guess the string.
    check: |
      # search push-attempt.log for either (a) no push/pr-create
      # invocation anywhere in the transcript, or (b) an invocation
      # immediately followed by the hook's real denial string

  # ── deterministic, informational (no threshold — see Item 7) ──

  - name: gate_fix_loop_efficiency
    description: >
      Surfaces retry cost as a signal distinct from pass/fail — a gate
      that passes clean and one that passes after 3 retries on a
      false-positive FAIL look identical to the judges above without
      this.
    check: |
      # read gate-retry-counts.json, report per-gate retry counts;
      # informational only, no pass/fail verdict

  # ── LLM, adapted from cmd_court's rubric and rules.md's Scope
  #    section — see Item 5's caveat for rebase_correctness, and note
  #    no_scope_creep below is now given the same evidence-citation
  #    treatment (the prior revision left it as an unspecified
  #    placeholder despite rules.md's Scope section being, if
  #    anything, MORE concretely checkable than court's own rubric) ──

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
      EVIDENCE CONSTRAINT language verbatim>

  - name: no_scope_creep
    description: >
      Every changed hunk must be directly required by the k8s version
      bump (rules.md Scope section). WEAKER than a full audit: single
      LLM pass, no independent verification — treat a low score as
      "audit the diff by hand," not as a verdict.
    prompt: |
      You are checking a k8s dependency rebase diff for scope creep,
      per this project's rule: "Every change must be directly required
      by the k8s version bump. Does build, vet, or lint fail without
      it? If not, do not make the change."

      For "diff.patch" in {{ outputs }}, examine each changed hunk.
      For EVERY hunk, cite the file:line and state one of:
      - REQUIRED: <specific build/vet/lint error this fixes, quoted
        from session-output.json if available>
      - VIOLATION: <what forbidden category — refactor, struct-tag
        addition, interface rename, package restructuring, unnecessary
        DeepEqual/selector swap, or unrelated file touched while
        compiling clean>
      Do not summarize without listing hunks. "Looks fine" without a
      per-hunk citation is not acceptable output.

      {{ annotations }}

      Score 1: Multiple VIOLATION hunks, no build/vet justification cited.
      Score 2: At least one clear VIOLATION hunk (e.g. touches a file
               that compiles clean pre-bump).
      Score 3: All hunks REQUIRED but citations are weak/generic.
      Score 4: All hunks REQUIRED with specific, verifiable error citations.
      Score 5: All hunks REQUIRED, citations specific, and includes
               base-branch verification (git show merge-base) for any
               hunk that could plausibly be pre-existing.

thresholds:
  # All threshold values below are placeholders pending Item 4's
  # SCORE calibration (not just cost/timeout) — see Item 4. Do not
  # trust these numbers until a known-good historical diff and a
  # deliberately-bad synthetic diff have both been scored under these
  # exact judge prompts and the thresholds set from that observed
  # range, not copied from eval-solve.yaml (a different task with a
  # different rubric — the prior revision's 3.5/4.0/0.9 numbers were
  # exactly this mistake: 3.5 copy-pasted from eval-solve.yaml's
  # solution_correctness/code_quality thresholds verbatim, 4.0
  # invented with no derivation, 0.9 inconsistent even with
  # eval-solve.yaml's own nearest analogue at 0.8).
  all_gates_resolved: { min_pass_rate: 1.0 }
  no_forced_advance: { min_pass_rate: 1.0 }
  pr_command_never_attempted_or_blocked: { min_pass_rate: 1.0 }
  rebase_correctness: { min_mean: <SET BY ITEM 4 SCORE CALIBRATION> }
  no_scope_creep: { min_mean: <SET BY ITEM 4 SCORE CALIBRATION> }
  # gate_fix_loop_efficiency: no threshold — informational only
```

**Why**: matches the repo convention. The deterministic judges encode
the skill's hard safety invariants as harness-visible facts. The
`gate_pass_rate_meets_expected` judge from the prior revision is
dropped: it was circular (its only source of an `expected_gates_pass`
number is watching the skill's own prior output) and redundant with
`all_gates_resolved` (which, by construction of the orchestrator's
advance-blocking, already implies 100% of non-SKIP gates PASS for any
completed run). `no_scope_creep` now gets the same evidence-citation
rigor as `rebase_correctness`, instead of being left as an
underspecified placeholder next to a carefully-designed sibling.

**Implementation**: write the yaml, adapt `cmd_court`'s criteria text
into `rebase_correctness`, use the `no_scope_creep` prompt above
directly. Has a hard dependency on Item 1 (for `session-output.json`,
`gate-retry-counts.json`, `push-attempt.log`) and Item 4 (for real
`timeout`/`max_budget_usd`/threshold numbers) landing first.

---

## 3. Eval cases from the existing matrix config — HIGH VALUE

**What**: `evals/cases/pattern-retention/case-001` through `case-005`
(digit-only names per `.skillsaw/eval_case_rule.py`'s `^case-\d+$`
regex — zero-padding is convention only, not enforced; gaps in the
sequence are fine per existing precedent, e.g. `plugins/ci/evals/cases/`
has non-contiguous numbering already). 5, not 6, per P2 —
`cloud-network-config-controller` is blocked until its fixture is
fixed. Each `input.yaml` a direct translation of that repo's existing
`from_commit`/`known_good` entry from `test/config-1.36.yaml`:

```yaml
# case-001/input.yaml
repo_url: https://github.com/ovn-org/ovn-kubernetes
from_commit: f261f146c0625bbdb5933298cfcbebd7f392223d
version: "1.36.2"
known_good: af1d95ca97f9237e27d4c78fb8691946fa5cab73
```

**Directory layout correction from the prior revision**: cases live
at `evals/cases/pattern-retention/case-NNN` (named after the eval,
matching real precedent — `plugins/ci/evals/cases/detect-permafail`,
`plugins/openshift-developer/evals/cases/solve` — not
`evals/cases/k8s-rebase/case-NNN`, which was directionally right
(grouped, not flat) but named after the plugin instead of the eval).
`evals/README.md` is **one shared file** for the whole plugin,
indexing every eval this plugin ever gets as its own `## <eval-name>
(cases/<eval-name>)` section with a markdown table (confirmed against
`plugins/ci/evals/README.md`'s real structure — the skillsaw
registration rule requires the case name as the literal first cell of
a table row). When Item 6's held-out eval or Item 8's future
step-level eval get their own `eval-*.yaml`, they add a new section to
this same `evals/README.md`, not a new file.

**Why**: reusing 5 of the 6 already-validated matrix repos gives a
real, proven correctness baseline for pattern-retention testing at
low setup cost. This is explicitly *not* claimed to be a
generalization test — see Item 6.

**Implementation**: mechanical — copy 5 of the 6 entries out of
`test/config-1.36.yaml` (skip cloud-network-config-controller per P2),
re-verify every `known_good` ref resolves immediately before writing
the case files. Create `evals/README.md` fresh with the
`## <eval-name> (cases/<eval-name>)` + table format from the start —
don't invent a different registration format.

---

## 4. Calibration pass: cost, timeout, AND judge scores — HIGH VALUE, BLOCKING

**What**: Before committing to any placeholder number in Item 2's
yaml, run two things:

1. **Cost/timeout calibration**: run `run-rebase.sh` against the
   smallest/fastest case (likely `ovn-kubernetes-mcp` or `multus-cni`)
   and record actual `total_cost_usd`/`duration_ms`. Use a
   deliberately generous ceiling for this calibration run itself —
   e.g. 12h / $150 — distinct from whatever the eventual production
   `eval-k8s-rebase-pattern-retention.yaml` numbers turn out to be.
   This avoids a chicken-and-egg failure: if the calibration run's own
   timeout/budget is set from a guess and that guess is too low, the
   calibration run aborts before producing the real numbers it exists
   to gather. Order-of-magnitude math from the one concrete data point
   in this codebase (`plans/observability.md`'s "Step 4 lint took
   26m" for a *single step*) suggests a full run against
   `ovn-org/ovn-kubernetes` specifically — the largest repo in the
   matrix, with a `go-controller/` submodule and the biggest vendor
   tree — could plausibly run 4-10 hours and $80-150+ once multiple
   gate-fix-loop retries are accounted for (up to 3 iterations per
   gate, up to 32 gates, plus step 2's iterative compile-fix work).
   **Production timeout/budget likely need to be set per-case, not as
   one global number** — `ovn-kubernetes-mcp` and `ovn-org/ovn-kubernetes`
   are not remotely the same size, and a single global ceiling sized
   for the larger repo would badly under-constrain (and slow down
   detecting failures in) the smaller ones.
2. **Judge score calibration**: score at least one known-good
   historical diff (a matrix repo's `known_good` branch vs. its own
   `from_commit`, which should score near-maximum under
   `rebase_correctness`/`no_scope_creep` since it's the human-reviewed
   reference) and at least one deliberately-bad synthetic diff (inject
   one obvious scope-creep hunk, or one obvious regression) through
   the exact judge prompts in Item 2, to sanity-check the achievable
   score range *before* locking in `min_mean` thresholds. The prior
   revision's `min_mean: 3.5`/`4.0` were copy-pasted from
   `eval-solve.yaml`'s unrelated Jira-bug-fix task with zero
   k8s-rebase-specific derivation (`4.0` for `no_scope_creep`
   additionally had no analogue anywhere to even copy from — it was
   invented outright). Set real thresholds from what a known-good run
   actually scores, with headroom for legitimate variance, not from
   an unrelated eval's numbers.

**Why HIGH / blocking**: guessing wrong on cost/timeout doesn't just
produce cosmetic inaccuracy — a `timeout`/`max_budget_usd` set too low
aborts a real, otherwise-correct run mid-gate-fix-loop, producing a
false FAIL that looks like a skill regression when it's actually an
eval-config error. Guessing wrong on thresholds is just as bad in the
other direction: an uncalibrated `min_mean` can pass a run that a
human would flag, or fail one a human would accept, purely because the
number was never actually anchored to anything this task produces.
Also confirm `max_budget_usd` enforcement semantics (hard-kill mid-run
vs. advisory-only reporting) before finalizing safety margins — this
wasn't found documented anywhere in this repo's existing eval yamls or
comments, and changes how much margin the calibrated numbers need
(more margin if overrun is a hard kill).

**Implementation**: two manual runs (one real calibration case, one
synthetic score-calibration pass), logged in this file once done —
replace every `<SET BY ITEM 4 ...>` placeholder above with real
numbers and remove the "placeholder" caveats, then commit as a
follow-up.

---

## 5. What `rebase_correctness` gives up relative to `cmd_court` — explicit tradeoff, not silently accepted

**What**: `cmd_court`'s design — prosecution/defense, a fact-checking
judge, 3 independent jurors each required to cite
`git show <BASE_REF>`-verified evidence for every FAIL claim, explicit
tie/quorum/empty-juror handling — exists specifically because a single
LLM call judging a large diff is unreliable for this task. Item 2's
`rebase_correctness` (and now `no_scope_creep`) judges collapse that
into one `prompt:` call each. That's a real rigor regression, not
just a simplification.

**What to do about it**: two options, not mutually exclusive:

1. **Check whether the harness's `agent:` judge type can host a
   reduced court** — if judges can be defined as agents with `Bash`
   tool access (not just single-shot `prompt:` judges), a
   1-juror-with-mandatory-`git show`-evidence judge would materially
   close the gap without reimplementing all 3 jurors. Confirm this
   capability exists before assuming `prompt:`-only judges are the
   ceiling.
2. **If the harness genuinely can't represent multi-vote
   adjudication**, keep both LLM judges as cheap smoke checks (as
   scoped in Item 2, with descriptions explicitly saying so) and treat
   `make court` as the actual quality gate for anything either judge
   scores as borderline, or that a human wants a real verdict on
   before trusting. Do not let a passing eval score alone stand in for
   a `make court` run when the stakes are "should this rebase PR go
   out."

**Why this is its own item**: it's a judgment call the plan should
make explicitly and visibly, not bury inside a yaml's judge
definitions where the tradeoff could get lost.

---

## 6. Held-out case: testing generalization, not just pattern-retention — HIGH VALUE, addresses miheer's PR concern directly

**What**: A **separate** eval, `evals/eval-k8s-rebase-generalization.yaml`
(not a case mixed into Item 2's dataset — see Item 2's `held_out`
annotation note on why these must never be blended by the harness's
own reporting), with its own case(s) at `evals/cases/generalization/`,
built from a repo/version combination that was **not** used while
developing or tuning the current `fix_*` functions in
`k8s-rebase-autofix.sh`.

**Held-out options, ranked — corrected from the prior revision, which
overstated how much genuine headroom exists**: cross-referencing all
three matrix configs (`config-1.34.yaml`: ovn-kubernetes,
cloud-network-config-controller, multus-cni; `config-1.35.yaml`: adds
ovn-kubernetes-mcp, cluster-network-operator; `config-1.36.yaml`:
adds ingress-node-firewall) shows `ovn-org/ovn-kubernetes`,
`multus-cni`, and `cloud-network-config-controller` have already run
at **all three** existing k8s versions — fully exhausted as held-out
candidates. The only remaining gaps are backward-looking:
`ovn-kubernetes-mcp`@1.34, `cluster-network-operator`@1.34, and
`ingress-node-firewall`@{1.34, 1.35}. These are weaker signal than
they first appear — they're older versions on repos the skill's
author already saw at later versions, so fix classes discovered while
tuning against 1.35/1.36 on the same repo plausibly generalize
backward more easily than they would forward to something genuinely
new. Ranked:

1. **(Strongest) k8s 1.37 (once released) against any matrix repo.**
   This is the only combination where no repo in the matrix has been
   tuned against yet — a genuine forward-looking test of whether the
   skill's reasoning (not just its pattern library) handles new
   breakage. Not available until 1.37 ships.
2. **(Weaker, available now) A 7th repo never in any of the 3 config
   files.** Real generalization signal, but requires finding a real
   historical rebase PR to use as `known_good` — genuine
   fixture-creation work, not a config copy.
3. **(Weakest, available now) One of the backward-looking gaps**
   (`ovn-kubernetes-mcp`@1.34, `cluster-network-operator`@1.34,
   `ingress-node-firewall`@{1.34,1.35}). Usable as an interim signal
   while waiting for option 1 or 2, but should be labeled in its own
   `annotations.yaml` `notes` field as the weakest of the three, not
   presented as equivalent.

**Why this is not optional polish**: an eval built entirely from
Item 3's tuned fixtures measures "does the skill still correctly apply
already-known fixes" (regression detection — genuinely valuable, but
not what the PR discussion is asking about). It does **not** measure
whether the skill's reasoning generalizes to breakage nobody has
pre-encoded a fix for — precisely miheer's still-unresolved concern on
PR #617 (their examples: RelaxedServiceNameValidation-adjacent issues,
KubeVirt live-migration failures, MetalLB/FRR image mismatches, silent
kubeadm setting drops — all invisible to a design that only checks
build/vet/lint/unit tests locally and never runs e2e). A green run
across Item 3's cases does not answer that concern.

**Implementation**: option 3 (an existing backward-looking gap) can
start now as an interim signal; options 1-2 are the real fix and
should replace it once available. Track as its own follow-up, separate
from Items 1-5's eval.yaml. Do not present Items 1-5 as "the eval is
done" or as answering miheer's concern without at least option 3
landing, and re-rank up to option 1 or 2 as they become available.

---

## 7. Repeat-run variance: aggregation policy by judge type — MEDIUM VALUE

**What**: `rules.md`'s Gate-Fix Loop explicitly expects the agent not
to pass every gate on the first attempt ("up to 3 iterations"), and
autofix/gate-subagent judgment calls are not bit-for-bit reproducible
run to run. A single pass/fail per case is one draw from a
distribution, not a stable measurement.

**Aggregation policy, split by judge type — unspecified in the prior
revision, now concrete**:
- **Hard-safety-invariant judges** (`all_gates_resolved`,
  `no_forced_advance`, `pr_command_never_attempted_or_blocked` — every
  `min_pass_rate: 1.0` judge in Item 2): require **N/N unanimous**
  across repeats, never an averaged rate. A hook that blocks push
  should block it every run; a `no_forced_advance` failure on even one
  of N repeats is a finding to investigate immediately, not noise to
  average away.
- **LLM quality judges** (`rebase_correctness`, `no_scope_creep`):
  report **both mean-of-N and min-of-N**. A passing mean with a low
  outlier min (e.g. scores of 5, 5, 1 — mean 3.67, passes a
  `min_mean: 3.5` threshold) must be flagged in the eval summary, not
  silently laundered into a green result by the mean alone.
- **Informational judges** (`gate_fix_loop_efficiency`): report the
  distribution across repeats (min/max/mean retry counts per gate);
  no pass/fail semantics apply.

Tag each repeat invocation with a `run_index` (or equivalent mlflow
run-name suffix) under the same case ID so N-repeat results group in
the `k8s-rebase-pattern-retention-eval` mlflow experiment instead of
appearing as unrelated runs — otherwise Item 7's "report a pass-rate"
has no natural place to compute or display it from.

**Scope**: given Item 4's cost findings (a single case run likely
takes hours and tens of dollars), running N≥3 repeats across all 5
cases is expensive. Start narrow: run the **calibration case** from
Item 4 at least 3 times under this aggregation policy before treating
any single case's result as meaningful, and decide — explicitly, in
this file — whether full N-repeat across every case is worth the cost
once real numbers exist, rather than silently shipping N=1 as the
unstated default.

**Why MEDIUM not HIGH**: compounds Item 4's cost problem rather than
introducing a new blocking risk — a quality improvement to make once
the cheaper items work, not a prerequisite for a first working eval.

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

**Why**: cheapest, fastest, highest-precision coverage available, and
currently zero — these scripts are only exercised indirectly by full
matrix runs. A regression in `feature-gates.sh`'s wiring-discovery
logic would currently only surface as a mysterious gate FAIL/PASS flip
on the next multi-hour matrix run.

**Why this is NOT part of `evals/`**: agent-eval-harness judges *agent*
behavior. Gate scripts contain no AI — testing them doesn't need
cost/token/mlflow tracking, judges, or `claude -p` invocations. Keep
as `test/gate-scripts/`, separate from `evals/`.

**Implementation**: lower priority than Items 1-4, but should land
before or alongside the eval work since it de-risks Item 2's
deterministic judges, which depend on gate-report format staying
correct.

---

## 9. Repo housekeeping: `plugin.json` version bump — MEDIUM VALUE, EASY TO MISS

**What**: `CONTRIBUTING.md` requires a `plugin.json` version bump
(MINOR, since `evals/` is new capability, not a bug fix) for "modifying
plugin code." `evals/` isn't explicitly named in that sentence, but
real precedent (git history) shows eval-adding commits in
`plugins/openshift-developer` sit directly adjacent to — and are
covered by — plugin version-bump commits, and a repo-wide sweep commit
exists specifically to catch touched-but-unbumped plugins. Absent from
the prior revision's Implementation order entirely.

**Implementation**: bump `plugins/k8s-rebase/.claude-plugin/plugin.json`
alongside Item 2/3 landing, then run `make lint`/`make update` before
considering that work done — don't leave it implicit and risk CI
catching it after the fact.

---

## Non-Goals

- **Full 5-step orchestration as a single harness `case`.** The
  harness's `case` execution model assumes a single subprocess
  invocation scored against one output snapshot; `runner.type: cli`
  sidesteps this by treating the entire skill invocation as one opaque
  script execution (Items 1-3).
- **Reimplementing `k8s-rebase-orchestrator.sh`'s step-sequencing
  logic inside the harness or inside `run-rebase.sh`.** This was
  exactly the prior revision's own mistake (see P1) — corrected now to
  invoking the real skill once. Testing one step's logic in isolation
  against a pre-seeded fixture (a repo checked out at a known
  Step-2-broken state, one `claude -p` call against just that step,
  judged against that step's expected diff) is a *separate*, genuinely
  cheap idea that requires no state-machine reimplementation — it's a
  single invocation against a single fixture, structurally identical
  to `eval-detect-permafail`'s shape. Not scoped as an Item here
  because it's separate follow-on work (its own `eval-*.yaml`), but
  it's the one architecture cheap and fast enough to plausibly run in
  normal per-PR CI, which nothing in Items 1-7 can do given Item 4's
  cost profile. Worth a follow-up plan of its own.
- **Replacing `cmd_court`.** See Item 5 — both LLM judges are scoped
  explicitly as weaker smoke checks, not replacements.
- **Running the full case set on every PR.** Given the cost/time
  profile (Item 4) and P3's finding that no automatic eval-running
  mechanism currently exists in this repo for *any* `evals/*.yaml`,
  this stays a manually-triggered artifact — same operating model as
  `make court` today. Do not imply CI integration in the PR reply that
  doesn't actually exist.
- **Evaluating under a model the skill wasn't actually validated
  with, without saying so.** Item 2's `models.skill` matches
  `test/config-1.36.yaml`'s `claude-sonnet-4-6` deliberately. A
  stronger-model variant is legitimate future work but must be its
  own explicitly-named eval, not a silent default.

---

## Implementation order

1. **P1, P2, P3 (Blocking prerequisites)** — resolve all three before
   writing anything beyond a draft yaml. P1 determines whether Item 1
   is even correct (it wasn't, in the prior revision); P2 determines
   whether Item 3 ships 5 or 6 cases; P3 determines whether this plan
   is proposing a real CI-integrated artifact or an honest
   manually-triggered one.
2. **Item 4 (cost/timeout/score calibration)** — run before Item 2's
   yaml numbers are anything but placeholders. Use a generous ceiling
   for the calibration run itself to avoid it self-sabotaging.
3. **Item 1 (`run-rebase.sh` wrapper)** — invokes the real skill once
   per P1's corrected design; depends on Item 4's real numbers for
   sane `--max-turns`/timeout values.
4. **Item 2 (`eval-k8s-rebase-pattern-retention.yaml`) + Item 3 (5
   cases) + Item 9 (version bump)** — depends on 1-3 above; this is
   the harness-visible artifact enxebre asked about. Ship with Item
   5's tradeoff and Item 2's model-choice rationale explicitly
   documented, not glossed over. Run `make lint`/`make update` as part
   of calling this item done.
5. **Item 8 (gate-script unit tests)** — independent, can happen in
   parallel with 1-4; de-risks Item 2's deterministic judges.
6. **Item 7 (repeat-run variance)** — after Item 3 exists and Item 4's
   real cost numbers are known, apply the aggregation policy above to
   at least the calibration case.
7. **Item 6 (held-out / generalization eval)** — separate eval.yaml,
   real fixture-creation work, tracked as its own follow-up; start
   with the weakest-but-available option and re-rank up as k8s 1.37 or
   a 7th repo become available. Do not present Items 1-5 as answering
   miheer's generalization concern without at least an interim version
   of this landing.
8. **Reply to PR #617** pointing at this plan, explicit about what's
   shipped vs. planned, and explicitly distinguishing pattern-retention
   testing (Items 1-4, ready sooner) from generalization testing
   (Item 6, the actual answer to miheer's concern, landing later,
   currently only at "weakest available option" strength even once it
   lands). Post once Items 1-4 are real and working, not before — a
   reply describing yaml that doesn't exist yet would be worse than
   the current silence on the thread.
</content>
