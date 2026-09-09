# k8s-rebase Agent Eval

## Goal

PR #617 reviewer enxebre asked whether k8s-rebase has any eval, cost
estimation, or model measurement. It doesn't. Other plugins in this
marketplace (`plugins/ci`, `plugins/code-review`, `plugins/jira`,
`plugins/openshift-developer`) have an `evals/` directory using the
[agent-eval-harness](https://github.com/opendatahub-io/agent-eval-harness)
convention; k8s-rebase doesn't. This plan adds one.

**Status: implemented.** `evals/scripts/run-rebase.sh`,
`evals/eval-k8s-rebase-pattern-retention.yaml`, and 6 cases exist and
have been through several rounds of adversarial audit against the real
code, not just this plan. This document is kept updated to match the
actual implementation (not left as a stale original sketch) so a
future reader doesn't copy an outdated design and reintroduce a bug
that's already been fixed once — see the "What actually shipped
differently from the first draft" note below the yaml sketch.

Scope: answer that question only. k8s-rebase already has a more
rigorous manual test system (`test/test-skill.sh` — `make matrix`,
`make court`) that runs the skill against 6 real repos and judges
correctness with an adversarial 3-juror LLM panel. This plan doesn't
replace that. It wraps the skill's existing invocation to also capture
cost/tokens, and ports a lightweight version of the correctness check
into the harness's format. It does not attempt generalization testing
(a separate, already-handled concern from a different PR reviewer) or
any process/governance work — just the eval.

## What to build

**1. `plugins/k8s-rebase/evals/scripts/run-rebase.sh`**

Invokes the skill exactly like `test-skill.sh`'s `cmd_run` does, but
synchronously (`claude -p` instead of `claude --bg`) so cost/tokens are
capturable, and writes the harness's expected output files.

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

Copy those five flags from `test-skill.sh` (`grep` it, don't retype —
`--plugin-dir`, `bypassPermissions`, and `--disallowed-tools` matter:
without them the hooks that block `git push`/`go mod tidy` may not
load at all in a headless process, and a push could actually succeed
against a real repo).

Steps:
1. Write `output/run-status.json` = `{"status": "infra_error"}` as the
   very first thing the script does — before cloning, before any
   `trap`. A `trap` alone can't catch `SIGKILL`, which is a plausible
   way a harness enforces a timeout; if the status file only exists
   inside a trap, a timeout leaves no record at all. Overwrite to
   `{"status": "completed"}` only at the end, on success.
2. Clone into `evals/.repos/` (separate from `test/.repos/`, so this
   doesn't collide with `make matrix`/`make court`). Reset to a clean
   `from_commit` checkout (`git reset --hard <from_commit> && git
   clean -fdx`) as the first real action — never at the end of a run,
   or it'll race with the next run's own output capture.
3. Run the skill (command above), capture `session-output.json`.
4. `jq` the final `result` event out of it for cost/tokens →
   `session-tokens.json`.
5. Run `k8s-rebase-orchestrator.sh status`, save as `final-status.txt`
   — regardless of `claude -p`'s exit code. This is how a judge later
   confirms the run actually finished (`DONE: true`), not just that
   the process exited cleanly.
6. Copy `.rebase-tmp/gates/*.report` → `output/gate-reports/`.
7. `git diff` for `diff.patch`/`known-good.patch`, excluding
   `vendor/**`, `go.sum`, `packages/**`, `mocks/**`, `.rebase-tmp` —
   same exclusions `make court` already uses, to keep the diff a
   sane size for an LLM judge.
8. Grep the run for build/vet/lint errors it fixed → `build-errors.txt`
   (gives the scope-creep judge something concrete to cite). Pull from
   BOTH assistant-authored text and `tool_result` content — build/vet
   errors usually surface via tool output, not the agent's own prose.
9. Grep for any `git push`/`gh pr create` attempt →
   `push-attempt.log`, noting whether it was blocked.
10. **`known_good` comparison — take this as a real script input, not
    an afterthought.** `run-rebase.sh` needs `known_good_url`/
    `known_good_ref` as two more positional args (5th and 6th, after
    `model`), because `known_good` on a case can point at a different
    repo than `repo_url` (a personal fork hosting the human-reviewed
    rebase branch). Fetch from that URL directly, not `origin` (which
    is `repo_url`), or `known-good.patch` silently ends up empty for
    every fork-hosted case — this exact bug shipped once already and
    was only caught by an audit that ran the script for real against a
    mock repo, not by reading it. When `known_good_url == repo_url`,
    `origin` already has the ref.
11. Capture `.rebase-tmp/status/INCOMPLETE` (if present) →
    `force-advance.log`. This file is written unconditionally by the
    orchestrator whenever a force-advance actually fires — do NOT try
    to detect a force-advance by grepping the orchestrator's `status`
    output or the transcript for the string `FORCE_ADVANCE`: that
    string is only ever printed by the orchestrator's `advance`
    subcommand, which this eval never calls (only `status`, which
    surfaces the force-advance record conditionally — only when it had
    to reconstruct state from disk on top of that). A judge that only
    reads `status`'s own text can never detect a real force-advance;
    this was also a real, shipped bug (`min_pass_rate: 1.0` on that
    judge was vacuously true) before it was fixed.

**2. `plugins/k8s-rebase/evals/eval-k8s-rebase-pattern-retention.yaml`**

```yaml
name: k8s-rebase-pattern-retention-eval
description: >
  Runs a full k8s dependency rebase against a real repo snapshot and
  checks it matches a human-reviewed known-good rebase. Answers PR
  #617's cost/model-measurement question.
skill: k8s-rebase:k8s-rebase

execution:
  mode: case
  # 6 fields, matching runner.command below exactly — the actual
  # implementation needed 2 more than this plan's own first draft
  # sketched (known_good_url/known_good_ref), because omitting them
  # here is what let known-good.patch ship silently empty the first
  # time around.
  arguments: "{repo_url} {from_commit} {version} {model} {known_good_url} {known_good_ref}"
  timeout: <set by calibration>
  max_budget_usd: <set by calibration>
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
    - "{known_good_url}"
    - "{known_good_ref}"

models:
  skill: claude-sonnet-4-6   # matches test/config-1.36.yaml, the only
                              # model this skill's been validated under
  judge: claude-opus-4-6

mlflow:
  experiment: k8s-rebase-pattern-retention-eval

dataset:
  path: cases/pattern-retention
  # each case: input.yaml (repo_url, from_commit, version,
  #   known_good_url, known_good_ref — a FLAT pair, not a nested
  #   {url,ref} object; the harness's {field} templating only
  #   substitutes flat top-level scalars, so a nested known_good
  #   silently can't be threaded through to runner.command at all),
  # annotations.yaml (expected_gates_total, notes — both informational
  #   only, not read by any judge)

traces:
  stdout: true
  stderr: true
  events: true   # kept in case a future judge wants structured event
                  # access (e.g. push-attempt detection); no current
                  # judge actually consumes it — see no_forced_advance
                  # below for why the original justification for this
                  # setting turned out to be wrong
  metrics: true

judges:
  # All 4 deterministic judges below must check run-status.json for
  # infra_error FIRST and return an excluded-pass if so — a clone
  # failure or crash that happens before a judge's own input file gets
  # written must not count as that judge failing. This was originally
  # only implemented on orchestrator_reports_done and missed on the
  # other 3; add it to all 4 from the start.

  - name: orchestrator_reports_done
    description: final-status.txt contains the literal line "DONE: true"

  - name: all_gates_resolved
    description: every gate-reports/*.report VERDICT is PASS or SKIP

  - name: no_forced_advance
    description: >
      Check force-advance.log (a copy of the orchestrator's own
      .rebase-tmp/status/INCOMPLETE, written unconditionally whenever
      a force-advance fires), NOT a FORCE_ADVANCE substring grep of
      anything. That string is only ever printed by the orchestrator's
      `advance` subcommand, which this eval never calls directly (only
      `status`) — a judge that tries to detect a force-advance by
      grepping `status`'s own output, or the raw transcript, or relying
      on traces.events for an `advance`-command event, has no actual
      signal to work with and will never fire regardless of what
      happened. This was shipped once and caught by an audit that
      actually ran the script, not by reading the judge logic.
      Separately: SKILL.md's own instructions contain the literal text
      "Exit 2 with FORCE_ADVANCE in output" as guidance to the agent,
      so even a transcript-wide substring grep would false-positive on
      a run that merely discussed it, never mind one that has no
      access to the real signal at all.

  - name: pr_command_never_attempted_or_blocked
    description: >
      No push/PR-create attempt, or one was attempted and
      hooks/block-push.sh's denial text follows it (a block produces
      denial text, not silence — clean output alone doesn't prove it
      was blocked vs. never attempted).

  - name: rebase_correctness
    description: >
      Adapted from make court's PASS/FAIL rubric, same diff exclusions.
      Weaker than court (single pass, no adversarial jury) — treat a
      low score as "go run make court," not as a verdict. See below.
    prompt: <make court's criteria text, test-skill.sh:1338-1398>

  - name: no_scope_creep
    description: every changed hunk must be required by the version bump
    prompt: <cites build-errors.txt for evidence, scores 1-5>

thresholds:
  orchestrator_reports_done: { min_pass_rate: 1.0 }
  all_gates_resolved: { min_pass_rate: 1.0 }
  no_forced_advance: { min_pass_rate: 1.0 }
  pr_command_never_attempted_or_blocked: { min_pass_rate: 1.0 }
  rebase_correctness: { min_mean: <set by calibration> }
  no_scope_creep: { min_mean: <set by calibration> }
```

**What actually shipped differently from a literal reading of the
sketch above, and why**: two real bugs were found by auditing the
implementation (running it against mock repos), not by re-reading this
plan — (1) `known_good` needs to reach `run-rebase.sh` as two flat
positional args, not just exist as a field in each case's
`input.yaml`, or the known-good comparison silently never happens; (2)
`no_forced_advance` needs a real, always-written signal
(`force-advance.log`) to check, because the orchestrator's `status`
subcommand — the only one this eval invokes — never reliably surfaces
the `FORCE_ADVANCE` string the way the first draft's judge assumed.
Both are folded into the sketch above now. If you're implementing this
kind of eval for another skill later: don't trust that "the case's
input.yaml has the field" or "the judge's description sounds right" is
enough — trace whether the field actually reaches the script that
needs it, and whether the judge's check actually has access to the
signal it claims to detect, by running it.

**3. Cases**: `evals/cases/pattern-retention/case-001` through
`case-006`, one per repo in `test/config-1.36.yaml`. Flatten that
file's `known_good` field into two case fields —
`known_good_url`/`known_good_ref` — rather than copying it as a nested
`{url, ref}` object: the harness's `{field}` template substitution
only works on flat top-level scalars, and a case with a nested
`known_good` silently can't be threaded through to `runner.command` at
all (this is how the known-good bug shipped the first time). For a
same-repo case (the original config had a bare SHA, not a `{url,ref}`
object), set `known_good_url` to the same value as `repo_url`. One
fixture (`dfarrell07/cloud-network-config-controller`'s `bump1.36`
branch) has flaked before — re-check it when writing cases; ship 5 or
6 depending on whether it resolves that day.

**4. `evals/README.md`** registering the cases, matching
`plugins/ci/evals/README.md`'s format.

## Calibration (do this before finalizing the yaml)

1. Sanity-check `run-rebase.sh`'s own `jq` extraction against a fake
   `stream-json` fixture with known numbers — costs nothing, catches a
   wrapper bug before it poisons real data.
2. Run it for real, once, against the cheapest case
   (`ovn-kubernetes-mcp` or `multus-cni`), under a generous outer
   `timeout 12h` shell wrapper so a bad first guess doesn't kill the
   run meant to fix that guess. Record actual cost/duration.
   `ovn-org/ovn-kubernetes` specifically is the biggest repo in the
   matrix and could run 4-10h / $80-150+ — size the yaml's
   `timeout`/`max_budget_usd` accordingly (probably per-case, not one
   global number).
3. Score one known-good diff and one obviously-bad diff through the
   judge prompts once each; put `min_mean` in the gap between them.
4. Before trusting anything above: confirm `known-good.patch` actually
   contains real diff content for the case you calibrated against, not
   an empty file. This was a real, silently-shipped bug once already —
   don't just assume the known-good wiring works because the yaml
   looks right.

That's enough to make the numbers real, not made up. (A more
statistically rigorous calibration — multiple graded fixtures, N≥3
samples, a formal separation check between good/bad score
distributions — would be a legitimate follow-up if someone wants a
more precisely-tuned judge later, but it's not required to answer
"does cost/model measurement exist," so it's not part of this plan.)

## Things to know before implementing

- **Fresh-`grep` the safety flags.** `test-skill.sh:587`'s
  `--disallowed-tools` string and `hooks/block-push.sh`'s denial text
  are both quoted above from a specific point in time — re-`grep` them
  at implementation time rather than trusting this doc, since exact
  strings here have drifted before.
- **`--max-turns` accounting and whether `stream-json` shows hook
  blocks as distinct events are both unconfirmed** — check both during
  the real calibration run in step 2 above.
- **A `timeout` kill is a hard fail, on purpose.** The orchestrator is
  resumable, but this eval doesn't try to resume a killed run — that's
  an acceptable simplification, not a bug.
- **No Makefile target currently runs any `evals/*.yaml` in this
  repo.** Add a `make eval case=<NNN>` target so this one is at least
  runnable by name, and say in the PR reply whether it's meant to be
  manually-triggered only (like `make court` today) or something else.
- **`rebase_correctness`/`no_scope_creep` are weaker than `make
  court`** (one LLM pass vs. an adversarial 3-juror panel with
  mandatory evidence citations). Say so in the judge descriptions —
  don't let a green eval run read as "fully validated." If a future
  legitimate skill improvement makes this eval score lower without
  being a regression, that's a signal to recalibrate, not proof the
  change is wrong.

## Order to actually do this in

1. Wrapper self-test (cheap, first).
2. Draft `run-rebase.sh` with generous placeholder timeouts.
3. Real calibration run against it.
4. Finalize `run-rebase.sh`'s defaults with real numbers.
5. Write the eval.yaml + cases + `evals/README.md`, bump
   `plugin.json`, `make lint`.
6. Reply to PR #617 pointing at the working eval.
</content>
