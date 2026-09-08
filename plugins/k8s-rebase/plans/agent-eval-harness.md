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
the more rigorous test system k8s-rebase already has.

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
- `cmd_run` launches a real `claude --bg` session against a cloned
  repo reset to `from_commit`, driving the full 5-step orchestrated
  workflow to completion.
- `cmd_court` is a full adversarial LLM judge: prosecution and defense
  arguments, a fact-checking judge, and a 3-juror panel voting
  PASS/FAIL/ABSTAIN on the diff between the result branch and
  `known_good`, with a rubric that explicitly excludes non-regressions
  (style, non-k8s dep drift, MVS-forced version splits) and requires
  every FAIL claim to be verified with `git show` against the
  pre-rebase base branch.
- `_tally_gates` reads `.rebase-tmp/gates/*.report` and produces
  pass/fail/skip counts per step.

**What's missing**: cost (`total_cost_usd`), token counts, wall-clock
duration, model identity — captured nowhere. And none of this is
discoverable as `evals/` by anyone scanning the repo for eval coverage,
which is exactly what triggered the PR feedback.

**Why not just rewrite test-skill.sh as eval.yaml**: the agent-eval-harness
`case` execution mode is built for single-shot, sub-few-minutes agent
invocations judged against one output artifact. A full k8s-rebase run is
a multi-hour, multi-invocation state machine driving a real git repo
through 32 gates with hooks blocking `go mod`/`git push`. Forcing that
into a single `case` invocation doesn't fit the model and would fight
the harness's assumptions (see Non-Goals). The harness's `runner.type: cli`
mode, however, is designed exactly for this: it shells out to an
arbitrary script and just consumes whatever output/metrics files that
script produces. `plugins/openshift-developer/evals/eval-solve.yaml` +
`scripts/run-solve.sh` already prove this pattern works for a
multi-phase, real-repo, real-git-commit agentic pipeline.

---

## 1. Cost/token capture wrapper around the existing matrix run — HIGH VALUE

**What**: Add `plugins/k8s-rebase/evals/scripts/run-rebase.sh`, modeled
directly on `run-solve.sh`. It does NOT reimplement `cmd_run` — it
drives the skill the same way `cmd_run` does (a `claude` invocation
with `--output-format stream-json`) but adds the `jq` extraction
`run-solve.sh` already has:

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

Because k8s-rebase runs as a **background session across many
`claude` invocations** (one per orchestrator step, per
`SKILL.md`'s "Execute Current Step" loop — bootstrap, then a fresh
Agent per step, then `advance`), a single `stream-json` capture isn't
enough. The wrapper must:

1. Launch the skill via `claude -p "/k8s-rebase:k8s-rebase <version>"`
   with `--output-format stream-json`, capturing the outer
   orchestrating session's cost.
2. Because each step is itself launched via `Agent`, and step
   subagents are the ones doing the expensive work (compilation
   fixes, autofix judgment, gate subagents), the outer session's
   `total_cost_usd` in the final `result` event is already the
   aggregate — Claude Code sums subagent cost into the parent
   session's reported total. Verify this assumption against a real
   run before relying on it (see Open Questions).
3. Write `.rebase-tmp/eval-metrics.json` with the aggregate, plus
   `.rebase-tmp/gates/*.report` verdicts already emitted by the
   orchestrator (no new capture needed there — `_tally_gates` in
   test-skill.sh already parses this format).

**Why**: this is the literal, minimal fix for what enxebre flagged.
It requires no changes to `test-skill.sh`'s existing logic, no new
fixtures, and no risk to the court/jury system — it only adds
instrumentation around the outside of a run that already happens in
CI-adjacent matrix testing.

**Implementation**: `run-rebase.sh <repo_url> <from_commit> <version> [model]`,
called by `eval.yaml`'s `runner.type: cli`. Reuses
`k8s-rebase-orchestrator.sh status` (already scriptable, see rules.md)
as a proxy for "did the run actually complete all steps" rather than
re-deriving that from stream-json text.

---

## 2. `evals/eval-k8s-rebase.yaml` — HIGH VALUE

**What**: The harness-visible entry point, structured like
`eval-solve.yaml`:

```yaml
name: k8s-rebase-eval
description: >
  End-to-end eval of the k8s-rebase skill. Runs a full dependency
  rebase against a real repo snapshot, judges gate pass rate and
  diff correctness against a human-reviewed known-good rebase.
skill: k8s-rebase:k8s-rebase

execution:
  mode: case
  arguments: "{repo_url} {from_commit} {version}"
  timeout: 14400          # 4h — real rebases run long; see Open Questions
  max_budget_usd: 40.0    # placeholder, needs calibration — see #4
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
      - 'notes': context for LLM judges (known tricky patterns for this repo/version)

outputs:
  - path: "output"
    schema: |
      diff.patch, files-changed.txt, commit-log.txt — final rebase output
      gate-reports/ — copy of .rebase-tmp/gates/*.report
      known-good.patch — known_good vs from_commit, for judge comparison
      eval-metrics.json — total_cost_usd, duration_ms, num_turns, model

traces:
  stdout: true
  stderr: true
  events: false
  metrics: true

judges:
  # deterministic
  - name: all_gates_resolved
    ...   # parses gate-reports/, checks every gate is PASS or SKIP, none PENDING/FAIL
  - name: gate_pass_rate_meets_expected
    ...   # compares against annotations.expected_gates_pass
  - name: no_forced_advance
    ...   # orchestrator status must show no FORCE_ADVANCE was used
  - name: pr_command_never_run
    ...   # commit-log.txt / stderr must show no git push or gh pr create executed

  # LLM, ported from cmd_court's existing rubric
  - name: rebase_correctness
    prompt: |
      <cmd_court's PASS/FAIL criteria text, adapted to {{ outputs }}>
  - name: no_scope_creep
    prompt: |
      <rules.md's "every change must be directly required by the
      version bump" rule, turned into a judge>

thresholds:
  all_gates_resolved: { min_pass_rate: 1.0 }
  no_forced_advance: { min_pass_rate: 1.0 }
  pr_command_never_run: { min_pass_rate: 1.0 }
  gate_pass_rate_meets_expected: { min_pass_rate: 0.9 }
  rebase_correctness: { min_mean: 3.5 }
  no_scope_creep: { min_mean: 4.0 }
```

**Why**: matches the repo convention exactly, so `enxebre` (and anyone
else scanning for eval coverage) finds it in the expected place. The
`no_forced_advance` and `pr_command_never_run` judges encode the two
hard safety invariants (`hooks.json`'s block-push, and the orchestrator
never silently degrading gate rigor) as harness-visible, CI-checkable
facts instead of only living in prose rules.

**Implementation**: write the yaml, port `cmd_court`'s existing
criteria text into the `rebase_correctness` prompt almost verbatim
(it's already been tuned through real runs — don't rewrite it from
scratch), and write the 4 deterministic judges as straightforward
Python `check:` functions parsing files already produced by the
existing gate/report machinery.

---

## 3. Eval cases from the existing matrix config — HIGH VALUE

**What**: `evals/cases/k8s-rebase/case-001` through `case-006`
(skillsaw requires digit-only names — case identity must not leak
which repo/version is under test), one per repo currently in
`test/config-1.36.yaml`. Each `input.yaml` is a direct translation of
that repo's existing `from_commit`/`known_good` entry:

```yaml
# case-001/input.yaml
repo_url: https://github.com/ovn-org/ovn-kubernetes
from_commit: f261f146c0625bbdb5933298cfcbebd7f392223d
version: "1.36.2"
known_good: af1d95ca97f9237e27d4c78fb8691946fa5cab73
```

Register all 6 in `evals/README.md`'s case index (skillsaw
`eval-case-registered` rule).

**Why**: zero new fixture design — these are real, already-validated
rebases (the PR description cites all 6 as tested and PASS). Reusing
them means the eval's correctness baseline is proven, not speculative.

**Implementation**: mechanical — copy the 6 entries out of
`test/config-1.36.yaml`, verify each `known_good` ref is still
resolvable (some point at forks under `dfarrell07`, confirm those
branches are still live before case-001 becomes case-materal that
silently 404s).

---

## 4. Cost/time calibration pass — MEDIUM VALUE

**What**: Before committing to `max_budget_usd` and `timeout` values
in the yaml, run `run-rebase.sh` once against the smallest/fastest
case (likely `ovn-kubernetes-mcp` or `multus-cni` — smaller repos,
fewer gates touch large vendor trees) and record actual
`total_cost_usd`/`duration_ms`. Set placeholders 1.5-2x observed
values, not guesses.

**Why**: a full rebase against `ovn-org/ovn-kubernetes` involves
large vendor diffs, multiple gate-fix loops, and up to 3 gate-retry
iterations per `rules.md`'s Gate-Fix Loop — this is not a
few-cents-and-90-seconds eval like `detect-permafail`. Setting
`max_budget_usd`/`timeout` too low would abort real runs mid-gate and
produce false negatives that look like skill bugs.

**Implementation**: one manual run, logged in this file's Open
Questions section once done, then commit the calibrated numbers.

---

## 5. Gate-script unit tests (separate from the harness) — MEDIUM VALUE, DIFFERENT MECHANISM

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

**Implementation**: lowest priority relative to 1-3 (doesn't answer
enxebre's actual question), but should land before or alongside the
eval work since it de-risks the deterministic judges in item 2, which
depend on gate-report format staying correct.

---

## Non-Goals

- **Full 5-step orchestration as a single harness `case`.** The
  harness's `case` execution model assumes a single subprocess
  invocation scored against one output snapshot; k8s-rebase is a
  stateful multi-invocation workflow spanning hours with hooks
  enforcing safety invariants across the whole run. `runner.type: cli`
  sidesteps this by treating the entire orchestrated run as one
  opaque script execution (item 1-3 above), which is the correct fit
  — but do not attempt to decompose the rebase into multiple harness
  `case`s that each represent one orchestrator step. The orchestrator
  already gates step transitions; re-implementing that as harness
  case sequencing would duplicate `k8s-rebase-orchestrator.sh` in a
  second, harness-specific state machine.
- **Replacing `cmd_court`.** Its prosecution/defense/judge/jury
  design is more rigorous than a single `prompt:` judge (majority
  vote across 3 independent jurors, each required to cite
  `git show`-verified evidence). Port its rubric text into the
  `rebase_correctness` judge (item 2) rather than discarding the
  court system — the harness's single-prompt judge functions as a
  cheaper, faster smoke check; keep `make court` as the
  higher-confidence manual/CI-gate check for anything the eval
  judge flags as borderline.
- **Running real 6-repo, multi-hour evals on every PR.** Given the
  cost/time profile (item 4), these are not suited to per-PR CI the
  way `eval-detect-permafail` might be. Treat them like `make court`
  today: manually triggered, or gated to a slower/less-frequent CI
  lane if one exists for `evals/` (check whether `openshift/release`
  or Prow already has a slow-lane pattern for `trt-agentic-solve`,
  which has the same real-repo/real-cost profile).

---

## Open Questions

1. **Does the outer session's `total_cost_usd` actually aggregate
   Agent-launched subagent cost?** k8s-rebase's SKILL.md launches a
   fresh Agent per step — need to confirm in a real run that the
   top-level `stream-json` `result` event's cost/token fields include
   subagent spend, not just the orchestrating session's own tool
   calls. If not, `run-rebase.sh` needs to sum per-subagent
   `stream-json` output instead (more invasive — would need each step
   Agent launch to also emit stream-json, which SKILL.md doesn't
   currently request).
2. **Are the `dfarrell07`-fork `known_good` branches in
   `test/config-1.36.yaml` durable enough to cite as eval fixtures?**
   Forked branches under a personal account are less permanent than
   upstream refs. Consider mirroring `known_good` as tags/branches
   under an org-controlled location, or at minimum documenting the
   risk if a case silently loses its comparison baseline.
3. **What actually invokes `evals/` in this repo?** Per initial
   research, no Makefile/CI target currently runs any existing
   `eval-*.yaml` automatically — CONTRIBUTING.md only notes `evals/`
   is a protected directory. Confirm whether there's a manual/Gangway
   trigger convention (mirroring `evals/trt-agentic-solve`'s Prow
   step-registry approach) before assuming this eval will be
   discovered and run by anyone without being told to.

---

## Implementation order

1. **Cost/time calibration pass (item 4)** — do this first, informally,
   with a throwaway script, before writing the "real" yaml — you need
   real numbers before the budget/timeout values in item 2 are
   anything but guesses.
2. **`run-rebase.sh` wrapper (item 1)** — the actual instrumentation;
   depends on resolving Open Question 1.
3. **`eval-k8s-rebase.yaml` + cases (items 2-3)** — the harness-visible
   artifact enxebre asked about; depends on 1-2 existing and working.
4. **Gate-script unit tests (item 5)** — independent, can happen in
   parallel with 1-3, and de-risks the deterministic judges in item 2.
5. Reply to PR #617 pointing at this plan and, once item 3 lands, at
   the working `evals/eval-k8s-rebase.yaml` itself.
</content>
