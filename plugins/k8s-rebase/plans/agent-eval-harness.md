# Agent Eval Harness Integration — k8s-rebase Skill

**Start here**: read Goal, then P1-P4, then Items 1-4 in order — that's
the critical path to a working eval. Item 5 is a real design decision
(don't let the eval oversell itself), not filler. The "round N
found/fixed X" notes throughout are provenance (why the design looks
this way, and what NOT to re-break), not instructions — skip them on a
first read and come back if something looks surprising.

**Scope note (round 6)**: this plan answers exactly one question — PR
#617 reviewer enxebre's "does this have any kind of eval, cost
estimation or specific model measurement?" It does not attempt to
address miheer's separate generalization-testing concern on the same
PR thread, which is already handled elsewhere and is out of scope
here. Earlier drafts of this plan included a generalization eval
(Item 6), a repeat-run statistical framework (Item 7), gate-script
unit tests unrelated to `evals/` (Item 8), a standalone version-bump
item (Item 9), and an ownership/staleness governance system (Item 10)
— all cut in this revision as scope creep beyond what was actually
asked. A single PR comment does not need a 10-item program to answer
it. What remains (P1-P4, Items 1-5) is the minimum that produces a
correct, honest, harness-visible eval. Cut content is not preserved
separately; git history has the fuller drafts if any of it is wanted
later as separate, deliberately-scoped follow-up work.

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

---

## Context: what already exists

`test/test-skill.sh` (2378 lines) is a hand-rolled eval system, built
before this repo's `evals/` convention existed:

- `test/config-1.36.yaml` — a real matrix of 6 repos (ovn-kubernetes,
  ovn-kubernetes-mcp, multus-cni, ingress-node-firewall,
  cloud-network-config-controller, cluster-network-operator), each
  pinned to a `from_commit` and a `known_good` branch/SHA.
- `cmd_run` (test-skill.sh:484-601) launches the skill via `claude --bg
  "/k8s-rebase:k8s-rebase <version>"` with three flags that matter for
  Item 1: `--plugin-dir "$PLUGIN_DIR"`, `--permission-mode
  bypassPermissions` (test-skill.sh:16), and (test-skill.sh:587,
  re-confirmed via direct `grep` across two review rounds — re-`grep`
  fresh at implementation time, not trusted from this plan) this exact
  `--disallowed-tools` value:
  ```
  'Bash(git push *),Bash(*git push*),Bash(git -c *push*),Bash(*send-pack*),Bash(gh pr create *),Bash(*gh pr create*),Bash(*gh api*repos*pulls*),Bash(sleep *)'
  ```
- `cmd_court` (test-skill.sh:1291-1610) is a full adversarial LLM
  judge with explicit `INCONCLUSIVE` handling for ties, quorum
  failures, and empty jurors. Its diff is built with `court_excludes`
  — `:!.rebase-tmp`, `vendor/**`, `go.sum`, `packages/**`, `mocks/**`
  all stripped. This matters for Item 2's `rebase_correctness` judge.
- `_tally_gates` reads `.rebase-tmp/gates/*.report`. `.rebase-tmp/` is
  never git-tracked anywhere in this skill.
- `test/config-1.36.yaml:34` pins `model: claude-sonnet-4-6`.
- `hooks/block-push.sh` (lines 18-23) emits this exact denial text on
  a blocked push/PR-create attempt: `"BLOCKED: The k8s-rebase skill
  does not push or create PRs.\nTo push manually: git push origin
  <branch>\nTo create PR: gh pr create --title \"...\" --body \"...\""`.
- `test/.repos/.gitignore` shows `test-skill.sh` clones into a
  local-only, gitignored directory, reused across calls.
- **Gate count: 32 `.md` gate files, 8 with companion `.sh` scripts**
  (re-verified directly via `find plugins/k8s-rebase/gates -name
  '*.md'/'*.sh' | wc -l` — an earlier review pass mis-derived this
  count from a `git log --all` scan that walked unrelated local refs;
  scope any future recount to the actual checked-out branch).
- `plugins/k8s-rebase/OWNERS` lists a single approver (`dfarrell07`).

**What's missing**: cost (`total_cost_usd`), token counts, wall-clock
duration, model identity — captured nowhere. And none of this is
discoverable as `evals/` by anyone scanning the repo for eval
coverage, which is exactly what triggered the PR feedback.

**Why not just rewrite test-skill.sh as eval.yaml**: the agent-eval-harness
`case` execution mode is built for single-shot, sub-few-minutes agent
invocations judged against one output artifact. A full k8s-rebase run
is a multi-hour, multi-invocation state machine driving a real git
repo through 32 gates with hooks blocking `go mod`/`git push`. The
harness's `runner.type: cli` mode fits this instead. `run-solve.sh`
(`plugins/openshift-developer/evals/scripts/`) proves this pattern
works for a multi-phase, real-repo, real-git-commit agentic pipeline;
k8s-rebase's wrapper follows the same shape but invokes the skill
once, matching `cmd_run`'s own invocation flags exactly (see Item 1).

---

## Blocking prerequisites (resolve before writing the "real" yaml)

### P1. Execution model: invoke the real skill once, with `cmd_run`'s actual safety flags

```bash
claude -p "/k8s-rebase:k8s-rebase <version>" \
  --output-format stream-json \
  --max-turns <N> \
  --model "$SKILL_MODEL" \
  --plugin-dir "$AI_HELPERS_DIR/plugins/k8s-rebase" \
  --permission-mode bypassPermissions \
  --disallowed-tools 'Bash(git push *),Bash(*git push*),Bash(git -c *push*),Bash(*send-pack*),Bash(gh pr create *),Bash(*gh pr create*),Bash(*gh api*repos*pulls*),Bash(sleep *)' \
  2>"$OUTPUT_DIR/session-stderr.log" \
  | tee "$OUTPUT_DIR/session-output.json"
```

`--plugin-dir` is not optional polish — without it, `hooks.json`'s
`PreToolUse` hooks may never load in a headless process.
`--permission-mode bypassPermissions` avoids hanging on an unanswerable
prompt. `--disallowed-tools` is a second, independent enforcement
layer. Without these flags, a push could actually succeed against a
real target repo. Copy these flags via a fresh `grep` of `cmd_run` at
implementation time, not from this plan.

Confirmed: skills resolve via `/skill-name` in print mode exactly as
in `--bg` mode. Subagent cost aggregation is confirmed: `total_cost_usd`
in `stream-json`'s final `result` event aggregates cost from
Agent/Task-tool-launched subagents in the same billing session.

**Unresolved and flagged rather than assumed** (verify empirically
during Item 4, not before):
- `--max-turns`'s accounting scope (top-level agent only, or all
  subagent turns) is undocumented. If a real calibration run never
  hits a turn ceiling before `timeout` binds first, drop `--max-turns`
  calibration effort entirely.
- Whether `stream-json` surfaces a `PreToolUse` hook block as a
  distinct, greppable event, or only as an absent tool-result, is
  unconfirmed — verify by deliberately triggering a blocked command
  during calibration. Given how many of this plan's checks
  (`no_forced_advance`, `push-attempt.log`, `orchestrator_reports_done`)
  rely on distinguishing real signals from incidental text, set
  `traces.events: true` (Item 2) rather than `false` — the structured
  per-tool-call event stream this produces is what lets these checks
  match a specific *event* instead of a *substring anywhere in free
  text*. The storage/mlflow overhead is minor relative to this eval's
  already multi-hour, real-cost profile.
- Whether `claude -p` handles `stop-hook.sh`'s premature-completion
  block by continuing work or exits anyway is unconfirmed, and could
  produce a silent partial-completion state. Item 1 guards against this
  (`final-status.txt` + `orchestrator_reports_done`).

**Explicit, deliberate choice**: a wall-clock `timeout` kill is treated
as a hard case failure; this design does not attempt to use the
orchestrator's real resumability (`SKILL.md`'s Recovery section). An
acceptable trade-off, stated so it isn't read as an oversight.

### P2. Verify fixture branches before writing case files

`test/config-1.36.yaml`'s 6 `known_good` refs must all resolve at
implementation time. One (`dfarrell07/cloud-network-config-controller`
branch `bump1.36`) has flipped between 404 and live across review
passes — it sits among ~30 scratch timestamped branches on the same
personal fork, so don't trust a single check. Re-verify all 6 refs
immediately before writing `evals/cases/pattern-retention/*/input.yaml`;
ship whichever subset actually resolves at that moment (5 or 6 cases),
don't block on a repo that may be temporarily unavailable.

### P3. Confirm what, if anything, actually runs `evals/*.yaml` in this repo

No Makefile target or CI workflow in this repo currently invokes any
existing `eval-*.yaml` automatically. **Resolve this, and state the
answer plainly to enxebre**: either (a) confirm a manual-trigger
convention exists, or (b) own explicitly that this is a
manually-invoked, no-fixed-cadence artifact, same as `make court`
today. Regardless: add a `make eval case=<NNN>` (or `make
eval-calibrate`) target in `plugins/k8s-rebase/Makefile`, following
the existing `court`/`matrix` target pattern with a `## ` help string.

### P4. State the trust model explicitly: `bypassPermissions` + real external repos

`run-rebase.sh` requires an authenticated `claude` CLI and, per P1,
runs with `--permission-mode bypassPermissions` (matching `cmd_run`) —
the same trust model `make matrix`/`make court` already accept for
local runs. Not a new risk, but stated explicitly. All target repos
confirmed public. If P3 resolves toward any shared/CI execution
environment, API-key scoping and this trust boundary need explicit
reconsideration.

Get this plan's design reviewed by `plugins/k8s-rebase/OWNERS` before
running Item 4's first real (non-free) calibration pass — a single run
can plausibly cost tens to low hundreds of dollars against a
single-owner plugin, and that's worth a human look before an agent
spends it autonomously.

---

## 1. `run-rebase.sh` wrapper: single real-skill invocation + cost capture — HIGH VALUE

**What**: Add `plugins/k8s-rebase/evals/scripts/run-rebase.sh`.

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

0. **Crash-safety status write, SIGKILL-safe.** Write
   `output/run-status.json`, defaulting to `{"status": "infra_error",
   "reason": "..."}`, as the **literal first filesystem operation of
   the script** — synchronously, before the clone step, before
   installing any trap. A bare `trap ... ERR EXIT` handler cannot fire
   on `SIGKILL` (unconditional POSIX semantics), which is a plausible
   way a harness enforces `execution.timeout`; if the status file is
   only written from inside a trap, the single most likely
   infra-failure scenario (a timeout) would leave no signal behind at
   all. Also install a `trap ... ERR EXIT` handler as defense-in-depth
   for the failure modes it does catch (command errors, `SIGTERM`).
   Only the success path (after step 6 below) overwrites the file to
   `{"status": "completed", ...}`.
1. **Reset-and-clean ordering.** Clone into a directory distinct from
   `test/.repos/` (e.g. `evals/.repos/`, gitignored the same way).
   Cache clones across repeat runs, but **reset-and-clean must run as
   the literal first action of the run** (immediately after step 0,
   strictly before invoking `claude -p`) — never as end-of-run
   cleanup, which would race with or precede that same run's own
   output capture (steps 6-9 below) and could silently wipe the data
   those steps need to read. Concretely: `git reset --hard
   <from_commit> && git clean -fdx`.
2. Invoke the real skill once, using the full, exact flag set from P1
   (re-`grep`ped from `test-skill.sh` at implementation time), capturing
   to `session-output.json`.
3. Extract cost/tokens via the helper above into `session-tokens.json`.
4. **Post-exit status guard**: regardless of the `claude -p` process's
   exit code, run `k8s-rebase-orchestrator.sh status` and capture its
   output as `final-status.txt`. Grep for the literal line `DONE:
   true` (confirmed by reading the orchestrator script: this is a
   single top-level line, not repeated in any per-gate/per-step table
   that could collide).
5. **Infrastructure-failure tagging**: `run-status.json` is written
   twice — synchronously defaulted in step 0, overwritten to
   `completed` here on success. Judges must exclude `infra_error` runs
   from pass/fail tallying entirely, not count them as a skill FAIL.
6. Copy `.rebase-tmp/gates/*.report` into `output/gate-reports/`.
7. Capture `diff.patch`, `files-changed.txt`, `commit-log.txt`, and
   `known-good.patch`, **using the same exclusion pathspecs as
   `cmd_court`'s `court_excludes`** (`:!.rebase-tmp`, `vendor/**`,
   `go.sum`, `packages/**`, `mocks/**`).
8. **Extracted build-error artifact**: write `build-errors.txt` by
   extracting build/vet/lint failure text step 2's agent reports, so
   `no_scope_creep`'s judge has a real evidence source instead of
   mining a raw `stream-json` transcript.
9. Build `push-attempt.log`: search the transcript for any push/PR-create
   invocation; confirm `block-push.sh`'s exact denial text follows.
   Prefer parsing the structured event stream (per P1's `events: true`)
   over raw text grep once its shape is confirmed.

**Why**: the literal, minimal fix for what enxebre flagged, using the
skill exactly as real users and `cmd_run` already do, so its
cost/tokens are directly capturable without risking an unintended push
or silently mis-tagging an infrastructure failure as a skill
regression.

**Implementation**: `run-rebase.sh <repo_url> <from_commit> <version>
[model]`, called by `eval.yaml`'s `runner.type: cli`. Item 4 needs
`run-rebase.sh` to exist to calibrate against; Item 1's final
`--max-turns`/timeout values need Item 4's calibration data to be
sane. Write a first draft with generous, uncalibrated internal
defaults, run Item 4 against that draft, then refine.

---

## 2. `evals/eval-k8s-rebase-pattern-retention.yaml` — HIGH VALUE

**Name**: `k8s-rebase-pattern-retention`, not the generic
`k8s-rebase-eval`, so a dashboard entry cannot be misread as
validating more than it does — see Item 5.

```yaml
name: k8s-rebase-pattern-retention-eval
description: >
  Pattern-retention eval of the k8s-rebase skill: runs a full
  dependency rebase against a real repo snapshot and checks the skill
  produces a correct rebase, matching a human-reviewed known-good
  reference. Answers PR #617's ask for eval/cost/model-measurement
  coverage. See Item 5 (this plan) for how this eval's LLM judges
  relate to the existing make court system.
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
  # Matches test/config-1.36.yaml's model — the skill's only real
  # validation used sonnet-4-6.
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
      - 'expected_gates_total': integer (32 — recount at implementation
        time) — used only to sanity-check gate-reports/ coverage,
        never a partial-credit pass count
      - 'notes': context for LLM judges, informational only

outputs:
  - path: "output"
    schema: |
      run-status.json — {"status": "completed"|"infra_error", "reason": "..."}
        written synchronously as the literal first filesystem operation
        (SIGKILL-safe, not trap-only — see Item 1 step 0). Judges must
        exclude infra_error runs from pass/fail tallying.
      session-output.json — raw stream-json for the single skill invocation
      session-tokens.json — extracted cost/token metrics
      final-status.txt — orchestrator `status` output captured post-exit
      diff.patch, files-changed.txt, commit-log.txt — final rebase
        output, generated with the same exclusion pathspecs cmd_court uses
      build-errors.txt — extracted build/vet/lint failure text
      gate-reports/ — copy of .rebase-tmp/gates/*.report
      known-good.patch — known_good vs from_commit, same exclusions
      push-attempt.log — evidence of any push/PR-create attempt and,
        if present, confirmation of the exact denial text

  # This outputs.schema block is documentation for judge authors, not
  # a harness-enforced contract.

traces:
  stdout: true
  stderr: true
  events: true
  metrics: true

judges:
  # ── deterministic, hard safety invariants ──

  - name: orchestrator_reports_done
    description: >
      final-status.txt confirms the orchestrator itself reports
      "DONE: true" (the literal line). A clean claude -p process exit
      is NOT by itself sufficient evidence of completion.
    check: |
      # parse final-status.txt for the literal line "DONE: true"

  - name: all_gates_resolved
    description: Every gate report is PASS or SKIP; none PENDING or FAIL at run end
    check: |
      # parse gate-reports/*.report, assert every VERDICT line is
      # PASS or SKIP.

  - name: no_forced_advance
    description: >
      Orchestrator never emitted FORCE_ADVANCE during the run. Do NOT
      grep the bare word FORCE_ADVANCE anywhere in output — SKILL.md's
      own instructions literally contain that text as guidance to the
      agent ("Exit 2 with FORCE_ADVANCE in output"), so an agent
      narrating its own reasoning could cause a false positive on a
      run that never actually force-advanced.
    check: |
      # With traces.events: true, match the orchestrator's own advance
      # command's tool_result content specifically (not
      # assistant-authored text events) for its exact printed marker —
      # grep k8s-rebase-orchestrator.sh's actual FORCE_ADVANCE output
      # string at implementation time. If events:true data isn't
      # usable, at minimum anchor to the orchestrator's exact line
      # format in tool-result blocks tied to `advance` invocations,
      # not a bare substring anywhere.

  - name: pr_command_never_attempted_or_blocked
    description: >
      Either no git push / gh pr create was attempted, or it was
      attempted and block-push.sh's exact denial text is present
      immediately after — a hook block produces denial text, not
      silence, so "clean output" alone doesn't distinguish "correctly
      blocked" from "never got far enough to try."
    check: |
      # search push-attempt.log for either (a) no push/pr-create
      # invocation anywhere in the transcript, or (b) an invocation
      # immediately followed by the confirmed denial string

  # ── LLM, adapted from cmd_court's rubric and rules.md's Scope
  #    section — see Item 5 for what these give up relative to
  #    cmd_court ──

  - name: rebase_correctness
    description: >
      Single-pass adaptation of cmd_court's PASS/FAIL criteria, using
      the SAME diff exclusions cmd_court uses. WEAKER than court: no
      adversarial prosecution/defense, no multi-juror vote, no
      mandatory per-claim git-show evidence. Treat a low score as
      "worth running make court for a real verdict," not a verdict
      itself.
    prompt: |
      <cmd_court's PASS/FAIL criteria text (test-skill.sh:1338-1398),
      adapted to {{ outputs }}, including the REBASE-SCOPE CHECK and
      EVIDENCE CONSTRAINT language verbatim>

  - name: no_scope_creep
    description: >
      Every changed hunk must be directly required by the k8s version
      bump (rules.md Scope section — re-diff against the current file
      at implementation time). Cites build-errors.txt as its primary
      evidence source.
    prompt: |
      You are checking a k8s dependency rebase diff for scope creep,
      per this project's rule: "Every change must be directly required
      by the k8s version bump. Does build, vet, or lint fail without
      it? If not, do not make the change."

      For "diff.patch" in {{ outputs }}, examine each changed hunk.
      For EVERY hunk, cite the file:line and state one of:
      - REQUIRED: <specific build/vet/lint error this fixes, quoted
        from "build-errors.txt" — use session-output.json only if
        build-errors.txt doesn't cover this hunk>
      - VIOLATION: <what forbidden category — refactor, struct-tag
        addition, interface rename, package restructuring, unnecessary
        DeepEqual/selector swap, or unrelated file touched while
        compiling clean>
      Do not summarize without listing hunks. "Looks fine" without a
      per-hunk citation is not acceptable output.

      {{ annotations }}

      Score 1: Multiple VIOLATION hunks, no build/vet justification cited.
      Score 2: At least one clear VIOLATION hunk.
      Score 3: All hunks REQUIRED but citations are weak/generic.
      Score 4: All hunks REQUIRED with specific, verifiable error citations.
      Score 5: All hunks REQUIRED, citations specific, and includes
               base-branch verification for any hunk that could
               plausibly be pre-existing.

thresholds:
  # Placeholders pending Item 4's score calibration.
  orchestrator_reports_done: { min_pass_rate: 1.0 }
  all_gates_resolved: { min_pass_rate: 1.0 }
  no_forced_advance: { min_pass_rate: 1.0 }
  pr_command_never_attempted_or_blocked: { min_pass_rate: 1.0 }
  rebase_correctness: { min_mean: <SET BY ITEM 4> }
  no_scope_creep: { min_mean: <SET BY ITEM 4> }
```

**Why**: matches the repo convention. `events: true` gives the checks
a structured signal to match against instead of grepping raw text,
which closes `no_forced_advance`'s false-positive risk.

**Implementation**: hard dependency on Item 1 and Item 4 landing
first.

---

## 3. Eval cases from the existing matrix config — HIGH VALUE

**What**: `evals/cases/pattern-retention/case-001` onward (5 or 6,
per P2). Digit-only names per `.skillsaw/eval_case_rule.py`'s
`^case-\d+$` regex. Each `input.yaml` a direct translation of that
repo's existing `from_commit`/`known_good` entry from
`test/config-1.36.yaml`:

```yaml
# case-001/input.yaml
repo_url: https://github.com/ovn-org/ovn-kubernetes
from_commit: f261f146c0625bbdb5933298cfcbebd7f392223d
version: "1.36.2"
known_good: af1d95ca97f9237e27d4c78fb8691946fa5cab73
```

**Directory layout**: cases live at
`evals/cases/pattern-retention/case-NNN` (named after the eval).
`evals/README.md` is one file registering these cases, per the
skillsaw `eval-case-registered` rule.

**Why**: reusing the already-validated matrix repos gives a real,
proven correctness baseline at low setup cost.

**Implementation**: mechanical — copy entries out of
`test/config-1.36.yaml`, re-verify every `known_good` ref resolves
immediately before writing the case files (P2). Create
`evals/README.md` with the `## <eval-name> (cases/<eval-name>)` +
table format matching real precedent (`plugins/ci/evals/README.md`).

---

## 4. Calibration: wrapper self-test, then cost/timeout/score — HIGH VALUE, BLOCKING

**Split into two sub-steps** — validating the wrapper script's own
correctness is cheap and should happen before spending hours/dollars
on real calibration data that a wrapper bug could silently poison.

### 4a. Wrapper self-test — cheap, synthetic, blocking, run first

Sanity-check `run-rebase.sh`'s own `extract_tokens()` jq expression
and diff-exclusion pathspec construction against a small synthetic
`stream-json` fixture with known values. Seconds, not hours; costs
nothing. Do not proceed to 4b until this passes.

### 4b. Real calibration — cost, timeout, and judge scores

1. **Cost/timeout calibration**: run `run-rebase.sh` against the
   smallest/fastest case and record actual `total_cost_usd`/`duration_ms`.
   `eval.yaml` doesn't exist yet at this point, so this run's own
   ceiling is enforced outside the harness — a shell-level `timeout
   12h ./run-rebase.sh ...` wrapper for wall-clock, and a manual check
   of the observed dollar figure, deliberately generous (e.g. 12h/$150)
   so a too-low guess doesn't kill the run meant to replace that
   guess. A full run against `ovn-org/ovn-kubernetes` (the largest
   matrix repo) could plausibly run 4-10 hours and $80-150+.
   Production timeout/budget likely need to be set per-case, not one
   global number. During this same run, empirically resolve P1's
   remaining unconfirmed items.
2. **Judge score calibration — graded, multi-sample, with a
   separation check**:
   - Calibrate against: (a) a known-good historical diff (expect
     near-max score), (b) a **subtle** bad example — hand-edit a copy
     of one real, correctly-preserved label-selector comparison in a
     `known_good` diff to swap it for `reflect.DeepEqual` instead
     (`rules.md`'s explicitly-forbidden-but-plausible pattern), and
     (c) an obviously-bad example as a sanity floor.
   - Score each fixture **N≥3 times** before deriving any threshold —
     LLM judge output is itself noisy.
   - **Separation check**: verify `min(fixture_a_scores) >
     max(fixture_b_scores)` with an explicit minimum margin (e.g.
     ≥1.0 point) before trusting either fixture as calibration data.
     If the distributions overlap, that's a finding the judge prompt
     needs revision, not a threshold to paper over. With only N=3
     samples this separation check reduces but doesn't eliminate the
     risk of a threshold based on too few samples — treat the result
     as provisional, to be refined once real production runs exist.
   - Set the final threshold in the confirmed gap between (a)'s
     minimum and (b)'s maximum.

**Why HIGH / blocking**: guessing wrong on cost/timeout aborts a real,
otherwise-correct run. Guessing wrong on thresholds produces a
threshold that looks calibrated but isn't trustworthy. Also confirm
`max_budget_usd` enforcement semantics (hard-kill vs. advisory) before
finalizing safety margins.

**Implementation**: 4a first (cheap, blocking), then 4b (expensive,
real), logged in this file once done — replace every placeholder with
real numbers, then commit as a follow-up.

---

## 5. What `rebase_correctness` gives up relative to `cmd_court` — explicit tradeoff, not silently accepted

**What**: `cmd_court`'s design — prosecution/defense, a fact-checking
judge, 3 independent jurors each required to cite `git show
<BASE_REF>`-verified evidence for every FAIL claim — exists because a
single LLM call judging a large diff is unreliable for this task.
Item 2's `rebase_correctness` and `no_scope_creep` judges collapse
that into one `prompt:` call each. That's a real rigor regression, and
this plan should not present it as a like-for-like replacement.

**What to do about it**:

1. Check whether the harness's `agent:` judge type can host a reduced
   court — a 1-juror-with-mandatory-`git show`-evidence judge would
   materially close the gap without reimplementing all 3 jurors.
2. If not, keep both LLM judges as cheap smoke checks and treat `make
   court` as the actual quality gate for anything either judge scores
   as borderline. Do not let a passing eval score alone stand in for a
   `make court` run when the stakes are real.

This also means: if a legitimate future skill improvement shifts diff
shape or gate-retry behavior without introducing a regression, this
eval could score it lower purely as an artifact of Item 4's
calibration being pinned to a point in time. When this eval and `make
court` disagree, treat a red eval as a signal to re-check calibration,
not automatic proof the skill change is wrong.

**Why this is its own item**: it's a judgment call the plan should
make explicitly and visibly, not bury inside a yaml's judge
definitions where the tradeoff could get lost — without it, a green
run risks being read as "the skill is fully validated," which it
isn't.

---

## Non-Goals

- **Full 5-step orchestration as a single harness `case`.** `runner.type: cli`
  sidesteps this (Items 1-3).
- **Reimplementing `k8s-rebase-orchestrator.sh`'s step-sequencing
  logic inside the harness or inside `run-rebase.sh`.** Testing one
  step's logic in isolation is separate follow-on work, not scoped
  here.
- **Replacing `cmd_court`.** See Item 5.
- **Running the full case set on every PR.** Manually-triggered, with
  a discoverable `make eval` entry point (P3).
- **Evaluating under a model the skill wasn't actually validated
  with, without saying so.** See Item 2's `models.skill`.
- **Testing generalization to novel, un-encoded breakage.** This
  eval's cases reuse repos the skill's autofix patterns were already
  tuned against — it measures pattern-retention, not generalization.
  That distinction is real, but addressing it (a held-out
  generalization eval) is explicitly out of scope for this plan:
  miheer's related PR #617 concern is already being handled
  separately. Don't reintroduce that work here.
- **Ownership/staleness governance, repeat-run statistical frameworks,
  gate-script unit tests, or any other process/tooling not directly
  needed to answer enxebre's question.** These may be worthwhile
  ideas, but each is its own scoped project with its own tradeoffs —
  bundling them into "the eval plan" was scope creep in earlier drafts
  of this document, cut in this revision. If wanted later, propose
  them separately so they get evaluated on their own merits and cost,
  not smuggled in under an unrelated PR comment.

---

## Implementation order

1. **P1, P2, P3, P4 (Blocking prerequisites)** — resolve all four
   before writing anything beyond a draft yaml. Re-`grep` `cmd_run`'s
   exact safety flags fresh. Get P4's human sign-off before Item 4b.
2. **Item 4a (wrapper self-test)** — cheap, synthetic, blocking, before
   any real spend.
3. **Item 1 (`run-rebase.sh` wrapper), first draft** — with generous,
   uncalibrated internal defaults; the crash-safety write must be
   SIGKILL-safe; the reset-and-clean step must run first, never as
   end-of-run cleanup.
4. **Item 4b (real cost/timeout/score calibration)** — against Item 1's
   first draft. Feeds back into refining Item 1's final defaults.
5. **Item 1, finalized** — with Item 4b's real numbers.
6. **Item 2 (`eval-k8s-rebase-pattern-retention.yaml`) + Item 3
   (cases) + a `plugin.json` version bump** — depends on 1-5 above.
   Ship with Item 5's tradeoff documented in the judge descriptions.
   Bump `plugins/k8s-rebase/.claude-plugin/plugin.json` per
   `CONTRIBUTING.md`'s versioning policy and run `make lint`/`make
   update` as part of calling this item done — a normal, one-line
   step at PR time, not its own plan item.
7. **Reply to PR #617** — pointing at the working eval, being explicit
   about cost/model measurement now being answered, and that
   generalization testing (miheer's separate concern) is intentionally
   out of scope for this specific change.
</content>
