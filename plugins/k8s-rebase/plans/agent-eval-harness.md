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

**Revision note (round 3)**: a third, 3-way-parallel adversarial
review followed round 2, specifically hunting for (a) bugs in round
2's own fixes, since round 2 had already found round 1's fix to be
wrong, (b) fresh angles neither round touched, and (c) residual gaps
in round 2's judge/scoring/held-out corrections. All three forks found
real, confirmed issues — including one genuine regression introduced
by round 2's own execution-model fix, and one finding serious enough
to change real-world behavior (a headless run without `cmd_run`'s
safety flags could let a push actually succeed against a real repo).
All corrected below. Superseded content is not preserved separately;
git history has all three prior drafts.

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
  overlap matters for Item 6 — most repos have already been run at
  every version currently in the matrix.
- `cmd_run` (test-skill.sh:484-601) launches the skill via
  **`claude --bg "/k8s-rebase:k8s-rebase <version>"`** against a
  cloned repo reset to `from_commit`, with three flags that matter a
  great deal for Item 1 below: `--plugin-dir "$PLUGIN_DIR"` (makes the
  plugin, and therefore its `hooks.json`, discoverable to a headless
  process), `--permission-mode bypassPermissions` (test-skill.sh:16),
  and a hardcoded `--disallowed-tools` denylist covering
  `Bash(git push *)`, `Bash(gh pr create *)`, and related patterns as
  a *second, independent* enforcement layer on top of the hooks.
  Progress is polled later by `cmd_test`/`cmd_test_all` via
  `_session_alive` (checks the background process) and `_tally_gates`
  (reads `.rebase-tmp/gates/*.report`).
- `cmd_court` (test-skill.sh:1291-1610) is a full adversarial LLM
  judge: prosecution and defense arguments, a fact-checking judge,
  and a 3-juror panel independently voting PASS/FAIL/ABSTAIN on the
  diff between the result branch and `known_good`. Every FAIL claim a
  juror uses must carry its own `git show <BASE_REF>:<file>`-verified
  evidence line; ties, quorum failures, and empty-juror runs are all
  handled as explicit `INCONCLUSIVE` outcomes. Its diff is built with
  `court_excludes` — `:!.rebase-tmp`, `vendor/**`, `go.sum`,
  `packages/**`, `mocks/**` all stripped — specifically to keep the
  diff within a manageable token budget (its own comment cites one
  repo going from ~211K to ~100K tokens after just excluding
  `go.sum`). This matters directly for Item 2's `rebase_correctness`
  judge below.
- `_tally_gates` reads `.rebase-tmp/gates/*.report` and produces
  pass/fail/skip counts per step. `.rebase-tmp/` is never git-tracked
  anywhere in this skill (confirmed — no step file or script ever
  `git add`s anything under it); it is pure working-directory scratch
  state. This matters for Item 1's data-capture design below.
- `k8s-rebase-autofix.sh`'s `fix_*` functions run in a **fixed,
  unconditional sequence** — not a symptom-keyed dispatch table. This
  matters for Item 6: every matrix repo already exercises the full set
  of currently-known fix functions.
- `test/config-1.36.yaml:34` pins `model: claude-sonnet-4-6` as the
  model the 6-repo PASS validation cited in the PR description
  actually used. This matters for Item 2's `models` block.
- `hooks/block-push.sh` (lines 18-23) emits this exact denial text on
  a blocked push/PR-create attempt: `"BLOCKED: The k8s-rebase skill
  does not push or create PRs.\nTo push manually: git push origin
  <branch>\nTo create PR: gh pr create --title \"...\" --body \"...\""`
  — confirmed directly, not left for a future implementer to go find.
  This matters for Item 2's `pr_command_never_attempted_or_blocked`
  judge.
- `test/.repos/.gitignore` shows `test-skill.sh` clones into a
  local-only, gitignored directory (`*` / `!.gitignore`), reused
  across calls via `_ensure_repo()`'s `-d "$dest/.git"` check rather
  than re-cloned every invocation. This matters for Item 1's clone
  lifecycle.

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
follows the same shape but invokes the skill once, matching `cmd_run`'s
own invocation flags closely (see Item 1).

---

## Blocking prerequisites (resolve before writing the "real" yaml)

Four of these are load-bearing enough that getting them wrong
invalidates Items 1-3 outright, not just the numbers in them.

### P1. Execution model: invoke the real skill once, with `cmd_run`'s actual safety flags

**Corrected across two rounds.** Round 1's fix assumed a single
synchronous call could just work. Round 2 found that assumption
untested but replaced it with something worse — an external bash loop
reimplementing the skill's own step judgment. Round 2 then corrected
that back to a single real invocation. Round 3 found the single
invocation, as sketched in round 2, was still missing three flags
`cmd_run` treats as load-bearing:

```bash
claude -p "/k8s-rebase:k8s-rebase <version>" \
  --output-format stream-json \
  --max-turns <N> \
  --model "$SKILL_MODEL" \
  --plugin-dir "$AI_HELPERS_DIR/plugins/k8s-rebase" \
  --permission-mode bypassPermissions \
  --disallowed-tools 'Bash(git push *),Bash(*git push*),Bash(git -c *push*),Bash(*send-pack*),Bash(gh pr create *),Bash(*gh pr create*),Bash(*gh api*repos*pulls*)' \
  2>"$OUTPUT_DIR/session-stderr.log" \
  | tee "$OUTPUT_DIR/session-output.json"
```

`--plugin-dir` is not optional polish — without it, a headless `claude
-p` process may not discover the k8s-rebase plugin at all, meaning
`hooks.json`'s `PreToolUse` hooks (which block `go mod tidy`, vendor
edits, and `git push`/`gh pr create`) never load. `--permission-mode
bypassPermissions` avoids a non-interactive session hanging on a
permission prompt nobody can answer. `--disallowed-tools` is a second,
independent enforcement layer `cmd_run` already relies on — losing it
means losing defense-in-depth, not just an instrumentation detail.
**Concretely: without these three flags, a push could actually succeed
against a real target repo during an eval run** — not merely a scoring
artifact, a real unintended write to a real GitHub repo. Copy these
flags from `cmd_run` (test-skill.sh) directly; do not reinvent them.

Confirmed via `claude -p --help`: skills resolve via `/skill-name` in
print mode exactly as in `--bg` mode, and `--output-format stream-json`
is a print-mode flag. Subagent cost aggregation is confirmed: `total_cost_usd`
in `stream-json`'s final `result` event aggregates cost from
Agent/Task-tool-launched subagents in the same billing session,
covering every step subagent `SKILL.md` launches.

**Unresolved and flagged rather than assumed** (verify empirically
during Item 4's calibration run, not before):
- `--max-turns`'s accounting scope (whether it counts only the
  top-level orchestrating agent's turns, or all turns across every
  Agent-tool subagent SKILL.md launches) is undocumented in `claude -p
  --help` and unconfirmed either way. If a real calibration run never
  hits a turn ceiling before wall-clock `timeout` binds first, drop
  `--max-turns` calibration effort entirely and rely on `timeout`
  alone — simpler and no worse.
- Whether `stream-json`'s event stream surfaces a `PreToolUse` hook
  block as a distinct, greppable event (vs. just an absent
  corresponding tool-result event) is unconfirmed. Item 1's
  `push-attempt.log` design (below) depends on this; verify by
  deliberately triggering a blocked command in a throwaway test during
  calibration, and adjust the log-parsing logic to match what's
  actually observed rather than what's assumed.
- Whether `claude -p` (no interactive user to respond to a block)
  handles `stop-hook.sh`'s premature-completion block by continuing
  work (matching interactive-session behavior) or gives up and exits
  anyway despite the block is unconfirmed and could produce a
  **silent partial-completion state**: a clean process exit with
  `.rebase-tmp/state.json` showing a mid-run step, which
  `session-output.json`'s final `result` event would report as an
  ordinary completion. Item 1 adds an explicit guard against this
  below (`final-status.txt` + the `orchestrator_reports_done` judge)
  rather than relying on `all_gates_resolved` to catch it as a side
  effect.

**Explicit, deliberate choice, stated rather than left silent**: a
wall-clock `timeout` kill is treated as a hard case failure. `SKILL.md`'s
Recovery section confirms the orchestrator is genuinely resumable
(`.rebase-tmp/state.json`, `ORCHESTRATOR_INIT: RESUME`), and a
single-invocation eval design does not attempt to use that
resumability — a timeout just fails the case. This is an acceptable
trade-off for eval purposes (an eval isn't obligated to babysit a
timed-out run across a resume), not an oversight, and is stated here
so nobody reads the lack of resume logic as a bug.

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

The other 5 `known_good` refs are confirmed resolvable today:
`dfarrell07/ovn-kubernetes-mcp` branch `bump1.36-20260717052952` and
`dfarrell07/multus-cni` branch `bump1.36` both exist;
`ovn-org/ovn-kubernetes` commit `af1d95ca97f9237e27d4c78fb8691946fa5cab73`,
`openshift/ingress-node-firewall` commit `577523c2bfd6ccb52f9fa7fa87bbb9034035c631`,
and `openshift/cluster-network-operator` commit
`aab9941e9517d22ee552d7b171de3b5cd463c341` all resolve via `gh api`
(bare SHAs on org-owned upstream repos — meaningfully more durable
than a fork branch, though not risk-free forever). Re-verify all 5
again immediately before writing case files.

### P3. Confirm what, if anything, actually runs `evals/*.yaml` in this repo

No Makefile target or CI workflow in this repo currently invokes any
existing `eval-*.yaml` automatically. This means writing
`eval-k8s-rebase-pattern-retention.yaml` produces a file that *looks*
like it satisfies the marketplace convention, but if nothing runs it
automatically, it doesn't fully answer enxebre's question in practice.

**Resolve this, and state the answer plainly to enxebre**: either (a)
confirm a manual-trigger convention exists (exact command,
prerequisites — ask a maintainer or check harness docs/tooling
directly), or (b) own explicitly that this is a manually-invoked,
no-fixed-cadence artifact, same as `make court` today. Regardless of
(a)/(b), add a discoverable entry point in this repo: a `make eval
case=<NNN>` (or `make eval-calibrate`) target in
`plugins/k8s-rebase/Makefile`, following the existing `court`/`matrix`
target pattern with a `## ` help string, so "manually triggered"
resolves to an actual command a reader can find via `make help`
rather than requiring knowledge of the harness's raw invocation
syntax.

### P4. State the trust model explicitly: `bypassPermissions` + real external repos

`run-rebase.sh` requires an authenticated `claude` CLI and, per P1,
runs with `--permission-mode bypassPermissions` (matching `cmd_run`).
This is the same trust model `make matrix`/`make court` already accept
for local runs: no interactive approval gate, so whoever runs this
must trust the 5 target repos' build tooling (Makefiles, `go
generate`-adjacent scripts the skill itself is blocked from running
by hooks, but which the *target repo's own* build process might
invoke) — this is not a new risk introduced by the eval, it's the
existing trade-off `cmd_run` already makes, but it should be stated
explicitly here rather than left implicit. All target repos are
confirmed public (no clone credentials needed). If P3 resolves toward
any shared/CI execution environment rather than a maintainer's own
machine, API-key scoping and this trust boundary need explicit
reconsideration before that happens — do not assume the "local
maintainer run" trust model transfers automatically to a shared
runner.

---

## 1. `run-rebase.sh` wrapper: single real-skill invocation + cost capture — HIGH VALUE

**What**: Add `plugins/k8s-rebase/evals/scripts/run-rebase.sh`. Per
P1's decision, using `cmd_run`'s actual flags:

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

1. **Clone lifecycle**: clone into a directory distinct from
   `test/.repos/` (e.g. `evals/.repos/`, gitignored the same way) to
   avoid any collision with `test-skill.sh`'s matrix state — a
   concurrent `make test`/`make court` run and an eval run must not be
   able to corrupt each other's `.rebase-tmp/` state or branch
   checkouts. Cache clones across repeat runs of the same case
   (mirroring `_ensure_repo`'s reuse pattern) rather than re-cloning
   from scratch every time, but explicitly reset to a clean
   `from_commit` checkout and clear any prior `.rebase-tmp/` state
   before each invocation — do not let one run's state leak into the
   next, especially under Item 7's N-repeat design.
2. Invoke the real skill once, using the full flag set from P1
   (`--plugin-dir`, `--permission-mode bypassPermissions`,
   `--disallowed-tools`, `--output-format stream-json`, `--max-turns`,
   `--model`), capturing to `session-output.json`.
3. Extract cost/tokens via the helper above into `session-tokens.json`.
4. **Post-exit status guard** (closes the P1 silent-partial-completion
   gap): regardless of the `claude -p` process's exit code, run
   `k8s-rebase-orchestrator.sh status` against the target repo and
   capture its output as `final-status.txt`. This is a distinct,
   explicit check that the orchestrator itself agrees the run reached
   `DONE`, rather than inferring completion only from a clean process
   exit or from `all_gates_resolved` finding no unresolved gates as a
   side effect.
5. **Infrastructure-failure tagging**: before any judge runs, write
   `output/run-status.json` with `{"status": "completed" |
   "infra_error", "reason": "..."}`. A clone failure, a `claude`
   process crash, or a GitHub API rate-limit during clone are
   infrastructure failures, not skill FAILs — judges and any N-repeat
   aggregation (Item 7) must exclude `infra_error` runs from pass/fail
   tallying rather than counting them as FAIL, exactly as `cmd_court`
   already treats `INCONCLUSIVE` as distinct from FAIL. Check whether
   the harness's own judge/threshold system has a native
   ERROR/SKIP-outcome concept before inventing this bespoke
   convention — use the native one if it exists.
6. Copy `.rebase-tmp/gates/*.report` into `output/gate-reports/`.
7. **`gate-retry-counts.json` — corrected data source.** The prior
   revision proposed `git log --follow` on `.rebase-tmp/gates/*.report`
   as the primary method. This does not work: `.rebase-tmp/` is never
   git-tracked by anything in this skill, so there is no commit
   history to walk. The prior revision's stated fallback (external
   polling during the run) is also gone now that P1's design removed
   the external per-step loop that could have polled. Concretely, one
   of two things must actually happen:
   - **(a, out of scope for this plan, real fix)** the skill itself
     (a `SKILL.md`/`rules.md` change, not an eval-only change) appends
     a retry-count line to each gate report on regeneration, so the
     *final* report file self-reports its own history. This is the
     only option that delivers real per-attempt data, but it's a
     skill-behavior change, not something `run-rebase.sh` can add
     unilaterally — track as a follow-up against the skill itself, not
     this plan.
   - **(b, available now, weaker)** `run-rebase.sh` inspects final
     gate-report file mtimes/inode-change-times post-hoc. This is a
     weak signal (a timestamp isn't a reliable retry counter and gives
     no per-attempt history), but it's honestly available without
     touching the skill.
   Ship (b) as an honest, clearly-labeled weak signal, and track (a)
   as a real follow-up against the skill itself. Do not claim (b)
   delivers what the original `gate_fix_loop_efficiency` judge design
   implied — see Item 2's corrected judge description.
8. Capture `diff.patch`, `files-changed.txt`, `commit-log.txt` against
   `from_commit`, and `known-good.patch` (`known_good` vs
   `from_commit`), **using the same exclusion pathspecs as `cmd_court`'s
   `court_excludes`** (`:!.rebase-tmp`, `vendor/**`, `go.sum`,
   `packages/**`, `mocks/**`) — not a raw, unscoped `git diff`. This
   was missing from the prior revision despite the plan's own Context
   section already documenting why `cmd_court` does this (token-budget
   management for large repos like `ovn-org/ovn-kubernetes`); porting
   `cmd_court`'s criteria text into a judge without also porting its
   diff-scoping practice would hand that judge exactly the
   token-blowout risk `cmd_court` was built to avoid.
9. **Extracted build-error artifact** (closes a real gap in the
   `no_scope_creep` judge, see Item 2): write
   `build-errors.txt`/`fix-justifications.md` by extracting the
   build/vet/lint failure text step 2's agent reports during the run
   (grep `session-output.json`'s assistant-text segments for
   reported failures, or — better — have the wrapper watch for the
   skill's own narrative if `plans/observability.md`'s narrative-log
   idea ever lands) rather than requiring `no_scope_creep`'s judge to
   mine one specific error string out of a potentially enormous raw
   `stream-json` transcript on its own.
10. Build `push-attempt.log`: search the transcript for any `git
    push`/`gh pr create` invocation; if found, confirm
    `block-push.sh`'s exact denial text (quoted in Context above)
    appears immediately after. Confirm empirically during Item 4's
    calibration run whether this is actually visible as a distinct
    stream-json event (see P1's unresolved item) before finalizing the
    parsing logic.

**Why**: this is the literal, minimal fix for what enxebre flagged,
using the skill exactly as real users and `cmd_run` already do —
synchronous instead of backgrounded, with the same safety flags, so
its cost/tokens are directly capturable without changing what's
actually being tested or risking an unintended push. It requires no
changes to `test-skill.sh`'s existing logic and no risk to the
court/jury system.

**Implementation**: `run-rebase.sh <repo_url> <from_commit> <version>
[model]`, called by `eval.yaml`'s `runner.type: cli`. Depends on
Item 4's calibrated `--max-turns`/timeout values.

---

## 2. `evals/eval-k8s-rebase-pattern-retention.yaml` — HIGH VALUE

**Name**: `k8s-rebase-pattern-retention`, not the generic
`k8s-rebase-eval`, so a dashboard entry or mlflow experiment name
cannot be misread as validating something it doesn't. A green run
means "the skill still correctly applies already-known fixes," not
"the skill is validated" or "the skill generalizes" — see Item 6. This
scope-signal ships with Items 1-5, not deferred to whenever Item 6
lands.

```yaml
name: k8s-rebase-pattern-retention-eval
description: >
  Pattern-retention eval of the k8s-rebase skill: runs a full
  dependency rebase against a real repo snapshot the skill's autofix
  patterns were already tuned against, and checks the skill still
  applies them correctly (regression detection). This does NOT
  validate generalization to novel, un-encoded breakage — see
  evals/README.md and plans/agent-eval-harness.md Item 6 for the
  separate, not-yet-shipped generalization design that addresses that
  gap, which is the same one miheer raised on PR #617.
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
  # Deliberately matches test/config-1.36.yaml's model — the skill's
  # only real validation used sonnet-4-6. A stronger-model variant is
  # legitimate future work but must be its own explicitly-named eval.
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
      - 'expected_gates_total': integer — used only to sanity-check
        gate-reports/ coverage, never to derive a partial-credit pass count
      - 'known_repo_difficulty': simple|medium|complex
      - 'held_out': boolean — always false for cases in this eval; a
        held_out:true case belongs in the SEPARATE generalization
        eval (Item 6), never mixed into this dataset
      - 'notes': context for LLM judges

outputs:
  - path: "output"
    schema: |
      run-status.json — {"status": "completed"|"infra_error", "reason": "..."}
        (judges/N-repeat aggregation must exclude infra_error runs from
        pass/fail tallying, not count them as FAIL)
      session-output.json — raw stream-json for the single skill invocation
      session-tokens.json — extracted cost/token metrics
      final-status.txt — orchestrator `status` output captured post-exit,
        regardless of the claude -p process's own exit code (guards
        against a silent partial-completion state — see P1)
      diff.patch, files-changed.txt, commit-log.txt — final rebase
        output, generated with the same exclusion pathspecs cmd_court
        uses (vendor/, go.sum, packages/, mocks/ stripped)
      build-errors.txt — extracted build/vet/lint failure text from the
        run, for no_scope_creep's evidence citations (not a raw
        stream-json mine)
      gate-reports/ — copy of .rebase-tmp/gates/*.report
      gate-retry-counts.json — per-gate report mtime-based retry signal;
        WEAK, post-hoc, not a real per-attempt history (see Item 1 step 7
        — a real fix requires a skill-side change, tracked separately)
      known-good.patch — known_good vs from_commit, same exclusions as
        diff.patch above
      push-attempt.log — evidence of any push/PR-create attempt and,
        if present, confirmation block-push.sh's exact denial text
        followed

  # This outputs.schema block is documentation for judge authors, not
  # a harness-enforced contract (confirmed against run-solve.sh, which
  # writes more files than eval-solve.yaml's schema enumerates).

traces:
  stdout: true
  stderr: true
  events: false
  metrics: true

judges:
  # ── deterministic, hard safety invariants — Item 7: require N/N
  #    unanimous across repeats, never an averaged rate. Runs tagged
  #    infra_error in run-status.json are excluded from this tally
  #    entirely, not counted as a failure. ──

  - name: orchestrator_reports_done
    description: >
      final-status.txt confirms the orchestrator itself reports DONE.
      Added in round 3 — a clean claude -p process exit is NOT by
      itself sufficient evidence of completion (a stop-hook/timeout
      interaction could produce a silent partial-completion state);
      this is a first-class check for that, not inferred as a side
      effect of all_gates_resolved.
    check: |
      # parse final-status.txt for the orchestrator's DONE marker

  - name: all_gates_resolved
    description: Every gate report is PASS or SKIP; none PENDING or FAIL at run end
    check: |
      # parse gate-reports/*.report, assert every VERDICT line is
      # PASS or SKIP. By construction of the orchestrator's
      # advance-blocking behavior, this already implies 100% of
      # non-SKIP gates PASS for a genuinely completed run — no
      # separate partial-credit judge is needed or included here.

  - name: no_forced_advance
    description: Orchestrator never emitted FORCE_ADVANCE during the run
    check: |
      # grep session-output.json / stdout traces for the literal
      # string "FORCE_ADVANCE" — must not appear

  - name: pr_command_never_attempted_or_blocked
    description: >
      Either no git push / gh pr create was attempted, or it was
      attempted and block-push.sh's exact denial text — "BLOCKED: The
      k8s-rebase skill does not push or create PRs." (confirmed
      verbatim, see Context) — is present immediately after. A hook
      block produces denial text in stderr, NOT silence, so "clean
      stderr" alone does not distinguish "correctly blocked" from
      "never got far enough to try."
    check: |
      # search push-attempt.log for either (a) no push/pr-create
      # invocation anywhere in the transcript, or (b) an invocation
      # immediately followed by the confirmed denial string above

  # ── deterministic, informational (no threshold — see Item 7) ──

  - name: gate_fix_loop_efficiency
    description: >
      WEAK SIGNAL (see Item 1 step 7): gate-retry-counts.json is
      derived from post-hoc file mtimes, not real per-attempt history
      — .rebase-tmp/ is untracked and there is no external polling
      loop left in this design to sample it live. Treat this judge as
      a rough indicator only, not a precise retry count. A real fix
      requires the skill itself to self-report retries on each gate
      report regeneration (tracked separately, out of scope here).
    check: |
      # read gate-retry-counts.json, report per-gate mtime-based
      # retry signal; informational only, no pass/fail verdict

  # ── LLM, adapted from cmd_court's rubric and rules.md's Scope
  #    section — see Item 5's caveat on the rigor this gives up ──

  - name: rebase_correctness
    description: >
      Single-pass adaptation of cmd_court's PASS/FAIL criteria, using
      the SAME diff exclusions cmd_court uses (vendor/, go.sum,
      packages/, mocks/ stripped from diff.patch/known-good.patch —
      see Item 1 step 8) to avoid the token-blowout cmd_court's own
      design exists to prevent. WEAKER than court: no adversarial
      prosecution/defense, no multi-juror vote, no mandatory per-claim
      git-show evidence. Treat a low score here as "worth running make
      court for a real verdict," not as a verdict itself.
    prompt: |
      <cmd_court's PASS/FAIL criteria text (test-skill.sh:1338-1398),
      adapted to {{ outputs }}, including the REBASE-SCOPE CHECK and
      EVIDENCE CONSTRAINT language verbatim>

  - name: no_scope_creep
    description: >
      Every changed hunk must be directly required by the k8s version
      bump (rules.md Scope section). Cites build-errors.txt (Item 1
      step 9) as its primary evidence source, not a raw stream-json
      mine. WEAKER than a full audit: single LLM pass, no independent
      verification — treat a low score as "audit the diff by hand,"
      not as a verdict.
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
      Score 2: At least one clear VIOLATION hunk (e.g. touches a file
               that compiles clean pre-bump).
      Score 3: All hunks REQUIRED but citations are weak/generic.
      Score 4: All hunks REQUIRED with specific, verifiable error citations.
      Score 5: All hunks REQUIRED, citations specific, and includes
               base-branch verification (git show merge-base) for any
               hunk that could plausibly be pre-existing.

thresholds:
  # Placeholders pending Item 4's SCORE calibration. See Item 4 for
  # the graded, multi-sample calibration methodology — a single
  # good/bad pair scored once each is not sufficient (round 3 finding).
  orchestrator_reports_done: { min_pass_rate: 1.0 }
  all_gates_resolved: { min_pass_rate: 1.0 }
  no_forced_advance: { min_pass_rate: 1.0 }
  pr_command_never_attempted_or_blocked: { min_pass_rate: 1.0 }
  rebase_correctness: { min_mean: <SET BY ITEM 4>, min_of_N: <SET BY ITEM 4> }
  no_scope_creep: { min_mean: <SET BY ITEM 4>, min_of_N: <SET BY ITEM 4> }
  # gate_fix_loop_efficiency: no threshold — informational only
```

**Why**: matches the repo convention. The deterministic judges encode
the skill's hard safety invariants as harness-visible facts, including
the new `orchestrator_reports_done` guard against a silent
partial-completion state. `gate_pass_rate_meets_expected` (present in
earlier revisions) stays dropped — circular and redundant with
`all_gates_resolved`. `no_scope_creep` now has both a real evidence
source (`build-errors.txt`) and the same citation rigor as
`rebase_correctness`. Both LLM judges now use `cmd_court`'s diff
exclusions to avoid a token-budget problem the plan previously ignored
despite documenting the exact reason `cmd_court` avoids it.

**Implementation**: write the yaml, adapt `cmd_court`'s criteria text
into `rebase_correctness`, use the `no_scope_creep` prompt above
directly. Hard dependency on Item 1 (for every file in `outputs.schema`)
and Item 4 (for real `timeout`/`max_budget_usd`/threshold numbers)
landing first.

---

## 3. Eval cases from the existing matrix config — HIGH VALUE

**What**: `evals/cases/pattern-retention/case-001` through `case-005`
(digit-only names per `.skillsaw/eval_case_rule.py`'s `^case-\d+$`
regex; zero-padding is convention only, gaps in numbering are fine per
existing precedent). 5, not 6, per P2. Each `input.yaml` a direct
translation of that repo's existing `from_commit`/`known_good` entry
from `test/config-1.36.yaml`:

```yaml
# case-001/input.yaml
repo_url: https://github.com/ovn-org/ovn-kubernetes
from_commit: f261f146c0625bbdb5933298cfcbebd7f392223d
version: "1.36.2"
known_good: af1d95ca97f9237e27d4c78fb8691946fa5cab73
```

**Directory layout**: cases live at
`evals/cases/pattern-retention/case-NNN` (named after the eval,
matching real precedent — `plugins/ci/evals/cases/detect-permafail`,
`plugins/openshift-developer/evals/cases/solve`). `evals/README.md` is
**one shared file** for the whole plugin, indexing every eval this
plugin ever gets as its own `## <eval-name> (cases/<eval-name>)`
section with a markdown table. When Item 6's generalization eval or
Item 8's future step-level eval get their own `eval-*.yaml`, they add
a new section to this same `evals/README.md`, not a new file.

**Why**: reusing 5 of the 6 already-validated matrix repos gives a
real, proven correctness baseline for pattern-retention testing at
low setup cost. Explicitly *not* claimed to be a generalization test
— see Item 6.

**Implementation**: mechanical — copy 5 of the 6 entries out of
`test/config-1.36.yaml` (skip cloud-network-config-controller per P2),
re-verify every `known_good` ref resolves immediately before writing
the case files. Create `evals/README.md` fresh with the
`## <eval-name> (cases/<eval-name>)` + table format from the start.

---

## 4. Calibration pass: cost, timeout, AND judge scores — HIGH VALUE, BLOCKING

**What**: Before committing to any placeholder number in Item 2's
yaml, run two things:

1. **Cost/timeout calibration**: run `run-rebase.sh` against the
   smallest/fastest case (likely `ovn-kubernetes-mcp` or `multus-cni`)
   and record actual `total_cost_usd`/`duration_ms`. Use a
   deliberately generous ceiling for this calibration run itself —
   e.g. 12h / $150 — distinct from whatever the eventual production
   numbers turn out to be, to avoid a chicken-and-egg failure where a
   too-low guess kills the run meant to replace that guess. Order-of-
   magnitude math from `plans/observability.md`'s "Step 4 lint took
   26m" data point suggests a full run against `ovn-org/ovn-kubernetes`
   specifically could plausibly run 4-10 hours and $80-150+.
   **Production timeout/budget likely need to be set per-case, not as
   one global number** — repo sizes in the matrix vary too widely for
   a single global ceiling to fit all of them well.
   During this same run, empirically resolve the three P1 unresolved
   items (turn-accounting scope, hook-block event visibility in
   stream-json, stop-hook/`-p`-mode interaction) rather than leaving
   them as assumptions in the shipped design.
2. **Judge score calibration — graded, multi-sample, not a single
   good/bad pair.** Round 2's design (one known-good diff, one
   "obvious" synthetic bad diff, each scored once) has two real
   weaknesses, both fixed here:
   - **Grading**: an adversarially-easy synthetic bad example makes
     almost any threshold "look calibrated" without validating against
     the actually-hard case a judge might plausibly miss. Calibrate
     against a **graded set**, not one pair: (a) a known-good
     historical diff (a matrix repo's `known_good` branch vs. its own
     `from_commit` — expect near-max score), (b) a **subtle** bad
     example — `rules.md`'s own Scope section names one directly:
     "replace label selectors with `reflect.DeepEqual`" is explicitly
     forbidden but plausible-looking, making it a natural subtle-bad
     fixture rather than an invented one — and (c) an obviously-bad
     example as a sanity floor. Set the threshold above (b)'s observed
     score, not just floating between (a) and an easy (c).
   - **Sampling**: LLM judge output is itself noisy — this plan's own
     Item 7 is built entirely on that premise for the skill under
     test, so the same logic applies to the judge doing the scoring.
     Score each calibration fixture **N≥3 times** with the judge
     before deriving a threshold, and derive the threshold from the
     observed range (e.g., above the subtle-bad fixture's *max*
     observed score across N samples), not a one-shot single-sample
     number.

**Why HIGH / blocking**: guessing wrong on cost/timeout aborts a real,
otherwise-correct run mid-gate-fix-loop, producing a false FAIL that
looks like a skill regression when it's actually an eval-config error.
Guessing wrong on thresholds — especially via the easy-negative trap —
produces a threshold that looks calibrated but isn't actually
discriminating on the hard cases that matter. Also confirm
`max_budget_usd` enforcement semantics (hard-kill mid-run vs.
advisory-only) before finalizing safety margins — undocumented
anywhere in this repo's existing eval yamls, and changes how much
margin the calibrated numbers need.

**Implementation**: two manual calibration passes (real cost/timeout
run, graded multi-sample score run), logged in this file once done —
replace every `<SET BY ITEM 4>` placeholder with real numbers
(including both `min_mean` and `min_of_N` per Item 7's dual-threshold
design) and remove the "placeholder" caveats, then commit as a
follow-up.

---

## 5. What `rebase_correctness` gives up relative to `cmd_court` — explicit tradeoff, not silently accepted

**What**: `cmd_court`'s design — prosecution/defense, a fact-checking
judge, 3 independent jurors each required to cite
`git show <BASE_REF>`-verified evidence for every FAIL claim, explicit
tie/quorum/empty-juror handling — exists specifically because a single
LLM call judging a large diff is unreliable for this task. Item 2's
`rebase_correctness` and `no_scope_creep` judges collapse that into
one `prompt:` call each. That's a real rigor regression.

**What to do about it**: two options, not mutually exclusive:

1. **Check whether the harness's `agent:` judge type can host a
   reduced court** — if judges can be defined as agents with `Bash`
   tool access, a 1-juror-with-mandatory-`git show`-evidence judge
   would materially close the gap. Confirm this capability exists
   before assuming `prompt:`-only judges are the ceiling.
2. **If the harness genuinely can't represent multi-vote
   adjudication**, keep both LLM judges as cheap smoke checks and
   treat `make court` as the actual quality gate for anything either
   judge scores as borderline. Do not let a passing eval score alone
   stand in for a `make court` run when the stakes are "should this
   rebase PR go out."

**Why this is its own item**: it's a judgment call the plan should
make explicitly and visibly, not bury inside a yaml's judge
definitions where the tradeoff could get lost.

---

## 6. Generalization eval: testing beyond pattern-retention — HIGH VALUE, addresses miheer's PR concern directly

**What**: A **separate** eval, `evals/eval-k8s-rebase-generalization.yaml`
(never a case mixed into Item 2's dataset), with its own case(s) at
`evals/cases/generalization/`, built from a repo/version combination
that was **not** used while developing or tuning the current `fix_*`
functions in `k8s-rebase-autofix.sh`.

**Held-out options, ranked**: cross-referencing all three matrix
configs shows `ovn-org/ovn-kubernetes`, `multus-cni`, and
`cloud-network-config-controller` have already run at **all three**
existing k8s versions — fully exhausted. The only remaining gaps are
backward-looking: `ovn-kubernetes-mcp`@1.34, `cluster-network-operator`@1.34,
`ingress-node-firewall`@{1.34, 1.35}.

1. **(Strongest) k8s 1.37 (once released) against any matrix repo.**
   The only combination where no repo has been tuned against yet — a
   genuine forward-looking test of the skill's reasoning, not just its
   pattern library. Not available until 1.37 ships.
2. **(Weaker, available now) A 7th repo never in any of the 3 config
   files.** Real generalization signal, but requires finding a real
   historical rebase PR to use as `known_good` — genuine
   fixture-creation work.
3. **(Reconsidered in round 3 — do not ship as an equivalent-looking
   interim signal) One of the backward-looking gaps.** Round 2 framed
   this as a usable interim option, just labeled "weakest." Round 3
   pushes further: fix classes discovered while tuning against
   1.35/1.36 on the same repo plausibly generalize backward more
   easily than forward, which means a PASS here could be **actively
   misleading** — read as "we have generalization coverage" when the
   coverage is weak enough to be closer to no coverage at all. This is
   exactly the false-confidence failure mode Item 6 exists to prevent.
   **Decision**: do not ship a backward-looking case labeled
   `held_out: true` without an equally prominent caveat. Prefer
   instead being explicit in `evals/README.md` that **zero
   generalization coverage exists yet** if options 1-2 aren't
   available, rather than shipping a weak signal that could be misread
   as adequate. If a backward-looking case is shipped anyway as a
   stopgap, its `annotations.yaml` must carry a field at least as
   prominent as `held_out: true` itself — e.g.
   `generalization_strength: weak-backward-looking` — so it cannot be
   silently read as equivalent to a real held-out case.

**Why this is not optional polish**: an eval built entirely from
Item 3's tuned fixtures measures "does the skill still correctly apply
already-known fixes," not whether the skill's reasoning generalizes to
breakage nobody has pre-encoded a fix for — precisely miheer's
still-unresolved concern on PR #617. A green run across Item 3's cases
does not answer that concern.

**Implementation**: track as its own follow-up, separate from Items
1-5's eval.yaml. Prefer waiting for option 1 or pursuing option 2 over
shipping option 3 as a false-confidence stopgap. Do not present Items
1-5 as answering miheer's concern until at least one of options 1-2
lands — an explicit "no coverage yet" statement in `evals/README.md`
is more honest than a weak interim case in the meantime.

---

## 7. Repeat-run variance: aggregation policy by judge type, with a real decision rule — MEDIUM VALUE

**What**: `rules.md`'s Gate-Fix Loop explicitly expects the agent not
to pass every gate on the first attempt, and autofix/gate-subagent
judgment calls are not bit-for-bit reproducible run to run. A single
pass/fail per case is one draw from a distribution, not a stable
measurement.

**Aggregation policy, split by judge type, with a real decision rule
— round 2 specified reporting, round 3 adds the missing decision
rule**:
- **Hard-safety-invariant judges** (`orchestrator_reports_done`,
  `all_gates_resolved`, `no_forced_advance`,
  `pr_command_never_attempted_or_blocked` — every `min_pass_rate: 1.0`
  judge in Item 2): require **N/N unanimous** across repeats, never an
  averaged rate. Runs tagged `infra_error` in `run-status.json` (Item
  1 step 5) are excluded from this tally entirely, not counted as a
  failure — an unrelated network blip must not fail a real safety
  check.
- **LLM quality judges** (`rebase_correctness`, `no_scope_creep`):
  report both mean-of-N and min-of-N, **and both are real thresholds,
  not just a reporting footnote** — round 2's "must be flagged in the
  summary" was too soft given P3's own finding that nothing
  automatically consumes eval results, so a footnote nobody reads is
  equivalent to not flagging it at all. Item 2's `thresholds` block
  now carries both `min_mean` and `min_of_N` per judge; a case only
  PASSes if both are met, so a single bad outlier run (e.g. scores of
  5, 5, 1 — mean 3.67, passing a `min_mean: 3.5` alone) fails the case
  outright via `min_of_N` rather than being laundered into a green
  result by the mean.
- **Informational judges** (`gate_fix_loop_efficiency`): report the
  distribution across repeats; no pass/fail semantics apply.

Tag each repeat invocation with a `run_index` so N-repeat results
group in the `k8s-rebase-pattern-retention-eval` mlflow experiment
instead of appearing as unrelated runs.

**Scope**: given Item 4's cost findings, running N≥3 repeats across
all 5 cases is expensive. Start narrow: run the **calibration case**
from Item 4 at least 3 times under this policy before treating any
single case's result as meaningful, and decide explicitly whether
full N-repeat across every case is worth the cost once real numbers
exist, rather than silently shipping N=1 as the unstated default.

**Why MEDIUM not HIGH**: compounds Item 4's cost problem rather than
introducing a new blocking risk.

---

## 8. Gate-script unit tests (separate from the harness) — MEDIUM VALUE, DIFFERENT MECHANISM

**What**: The 8 gate `.sh` companion scripts are pure deterministic
bash — they don't need LLM judging at all. A `test/gate-scripts/`
directory with small synthetic fixture repos and expected
PASS/FAIL/SKIP outputs, run via `bats` or a plain bash assertion loop.

**Why**: cheapest, fastest, highest-precision coverage available, and
currently zero.

**Why this is NOT part of `evals/`**: agent-eval-harness judges *agent*
behavior; gate scripts contain no AI. Keep as `test/gate-scripts/`,
separate from `evals/`.

**Implementation**: lower priority than Items 1-4, but should land
before or alongside the eval work since it de-risks Item 2's
deterministic judges.

---

## 9. Repo housekeeping: `plugin.json` version bump — MEDIUM VALUE, EASY TO MISS

**What**: `CONTRIBUTING.md` requires a `plugin.json` version bump
(MINOR) for modifying plugin code; real precedent (git history) shows
eval-adding commits in `plugins/openshift-developer` are covered by
plugin version-bump commits.

**Implementation**: bump `plugins/k8s-rebase/.claude-plugin/plugin.json`
alongside Item 2/3 landing, then run `make lint`/`make update` before
considering that work done.

---

## Non-Goals

- **Full 5-step orchestration as a single harness `case`.** `runner.type: cli`
  sidesteps this by treating the entire skill invocation as one opaque
  script execution (Items 1-3).
- **Reimplementing `k8s-rebase-orchestrator.sh`'s step-sequencing
  logic inside the harness or inside `run-rebase.sh`.** This was round
  1's mistake, corrected in round 2. Testing one step's logic in
  isolation against a pre-seeded fixture is a *separate*, genuinely
  cheap idea, not scoped as an Item here — it's the one architecture
  cheap enough to plausibly run in normal per-PR CI, which nothing in
  Items 1-7 can do given Item 4's cost profile. Worth a follow-up plan
  of its own.
- **Replacing `cmd_court`.** See Item 5 — both LLM judges are scoped
  explicitly as weaker smoke checks.
- **Running the full case set on every PR.** Given Item 4's cost/time
  profile and P3's finding that no automatic eval-running mechanism
  exists for any `evals/*.yaml` in this repo, this stays a
  manually-triggered artifact — same operating model as `make court`
  today, now with a discoverable `make eval` entry point (P3).
- **Evaluating under a model the skill wasn't actually validated
  with, without saying so.** Item 2's `models.skill` matches
  `test/config-1.36.yaml`'s `claude-sonnet-4-6` deliberately.
- **Shipping a backward-looking held-out case as if it were
  equivalent to real generalization coverage.** See Item 6's round-3
  reconsideration — an explicit "no coverage yet" is preferred over a
  weak signal that risks false confidence.
- **Assuming eval-runner credentials/trust model transfers to a
  shared or CI environment without reconsideration.** See P4 — the
  `bypassPermissions` trust model is accepted for local maintainer
  runs (matching `cmd_run`'s existing precedent) but needs explicit
  re-evaluation before any move to shared infrastructure.

---

## Implementation order

1. **P1, P2, P3, P4 (Blocking prerequisites)** — resolve all four
   before writing anything beyond a draft yaml. P1 determines whether
   Item 1 is even correct and safe to run (it wasn't, twice, in prior
   revisions); P2 determines whether Item 3 ships 5 or 6 cases; P3
   determines whether this plan is proposing a real CI-integrated
   artifact or an honest manually-triggered one, and requires adding a
   `make eval` entry point either way; P4 states the trust model
   explicitly so it isn't assumed to transfer to infrastructure it
   hasn't been evaluated against.
2. **Item 4 (cost/timeout/score calibration)** — run before Item 2's
   yaml numbers are anything but placeholders. Use a generous ceiling
   for the calibration run itself. Use the graded, multi-sample
   methodology for score calibration, not a single good/bad pair
   scored once each. Empirically resolve P1's three unconfirmed
   behaviors (turn accounting, hook-block visibility in stream-json,
   stop-hook/`-p`-mode interaction) during this same pass.
3. **Item 1 (`run-rebase.sh` wrapper)** — invokes the real skill once
   with `cmd_run`'s full safety-flag set; depends on Item 4's real
   numbers for sane `--max-turns`/timeout values. Includes the
   post-exit status guard, infra-error tagging, `cmd_court`-matching
   diff exclusions, and the extracted build-errors artifact — all
   round-3 additions, not optional polish.
4. **Item 2 (`eval-k8s-rebase-pattern-retention.yaml`) + Item 3 (5
   cases) + Item 9 (version bump)** — depends on 1-3 above. Ship with
   Item 5's tradeoff, Item 2's model-choice rationale, and Item 7's
   dual-threshold decision rule explicitly documented. Run `make
   lint`/`make update` as part of calling this item done.
5. **Item 8 (gate-script unit tests)** — independent, can happen in
   parallel with 1-4.
6. **Item 7 (repeat-run variance)** — after Item 3 exists and Item 4's
   real cost numbers are known, apply the dual-threshold aggregation
   policy to at least the calibration case.
7. **Item 6 (generalization eval)** — separate eval.yaml, real
   fixture-creation work, tracked as its own follow-up. Prefer an
   explicit "no coverage yet" statement over shipping a backward-
   looking stopgap case, unless the caveat is made equally prominent.
8. **Reply to PR #617** pointing at this plan, explicit about what's
   shipped vs. planned, and explicitly distinguishing pattern-retention
   testing (Items 1-4, ready sooner) from generalization testing
   (Item 6, the actual answer to miheer's concern, landing later, and
   currently possibly still at "no coverage yet" even once Items 1-5
   ship). Post once Items 1-4 are real and working, not before.
</content>
