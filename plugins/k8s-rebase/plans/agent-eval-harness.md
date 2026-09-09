# Agent Eval Harness Integration — k8s-rebase Skill

**Start here**: read Goal, then P1-P4, then Items 1-4 in order — that's
the critical path to a working eval. Items 5-10 and Non-Goals are real
design decisions, not filler, but the "round N found/fixed X" notes
throughout are provenance (why the design looks this way, and what NOT
to re-break), not instructions — skip them on a first read and come
back if something looks surprising. This document is long because five
rounds of adversarial review found real bugs at every pass, including
in each other's fixes; the length is the review trail, not padding.

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

**Revision note (round 5)**: a fifth, 4-way-parallel adversarial review
followed round 4, split between re-verifying round 4's own new
additions, hunting fresh angles (human sign-off, PR sequencing,
licensing, plan usability), empirically re-checking every live fact
this plan depends on one more time, and stress-testing remaining judge
mechanics. Most notably: **round 4's own "gate count drifted to
34/plugin.json is at 0.3.0" claim was itself wrong** — a `git log
--all` methodology error that scanned unrelated worktree refs instead
of the actual checked-out branch history. Two independent forks this
round re-derived the correct state (32 gates / 8 companion scripts /
plugin.json `0.0.1`) and cross-validated each other. This is corrected
below, honestly, as an error this review process caught in itself, not
quietly smoothed over. Also found this round: a SIGKILL gap in round
4's crash-safety trap, a real false-positive risk in `no_forced_advance`
identical in kind to a bug already fixed once elsewhere in this plan,
Item 10's core premise being empirically false (150+ gate commits, zero
version bumps — tying re-verification to version bumps would never
fire), k8s 1.37 having actually shipped (flipping Item 6's timeline),
and PR #617 now carrying real merge conflicts and unrelated blocking
labels. All corrected below. Superseded content is not preserved
separately; git history has all five prior drafts.

---

## Context: what already exists

`test/test-skill.sh` (2378 lines) is a hand-rolled eval system, built
before this repo's `evals/` convention existed:

- `test/config-{1.34,1.35,1.36}.yaml` — a real matrix. `config-1.34.yaml`
  has 3 repos (ovn-kubernetes, cloud-network-config-controller,
  multus-cni); `config-1.35.yaml` has 5 (adds ovn-kubernetes-mcp,
  cluster-network-operator); `config-1.36.yaml` has 6 (adds
  ingress-node-firewall). Each entry pins a `from_commit` and a
  `known_good` branch/SHA.
- `cmd_run` (test-skill.sh:484-601) launches the skill via `claude --bg
  "/k8s-rebase:k8s-rebase <version>"` with three flags that matter for
  Item 1: `--plugin-dir "$PLUGIN_DIR"`, `--permission-mode
  bypassPermissions` (test-skill.sh:16), and (test-skill.sh:587,
  re-confirmed via direct `grep` in rounds 4 and 5 — this exact string
  survived two independent re-checks and should still be re-`grep`ped
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
- `k8s-rebase-autofix.sh`'s `fix_*` functions run in a fixed,
  unconditional sequence. This matters for Item 6.
- `test/config-1.36.yaml:34` pins `model: claude-sonnet-4-6`.
- `hooks/block-push.sh` (lines 18-23) emits this exact denial text on
  a blocked push/PR-create attempt: `"BLOCKED: The k8s-rebase skill
  does not push or create PRs.\nTo push manually: git push origin
  <branch>\nTo create PR: gh pr create --title \"...\" --body \"...\""`.
- `test/.repos/.gitignore` shows `test-skill.sh` clones into a
  local-only, gitignored directory, reused across calls.
- **Gate count: 32 `.md` gate files, 8 with companion `.sh` scripts —
  corrected in round 5.** Round 4 claimed 34/9, attributing this to
  gates supposedly added *during* this plan's review. That claim was
  wrong: it came from running `git log --all -- plugins/k8s-rebase/gates/`,
  which walks *every ref in the local object store*, including
  unrelated worktrees, not the actual history of the checked-out
  branch. Scoped correctly (`git log` on `HEAD`, and direct
  `find ... | wc -l` counts), the real state — cross-validated by two
  independent forks in round 5 — is 32/8, matching what round 1
  originally established, with a genuine intermediate blip: one commit
  (`7bc579e2`, message: "fold logical-completeness into
  logical-consistency (33→32 gates)") shows the count really did
  fluctuate at some point in this skill's history, just not during
  this plan's own review window the way round 4 claimed. **Use 32/8
  for `expected_gates_total` guidance; recount at implementation time
  regardless, since the skill's gate directory has a long, active
  commit history independent of this plan.**
- **`plugin.json` is at version `0.0.1`, with exactly one commit in
  its history (the initial plugin add)** — corrected in round 5. Round
  4's claimed "`0.3.0`, 4 bump commits" was part of the same `git log
  --all` methodology error. Item 9's bump target is `0.0.2` or `0.1.0`
  (MINOR, per `CONTRIBUTING.md`'s new-capability rule), not `0.4.0`.
- **`plugins/k8s-rebase/OWNERS` lists a single person**
  (`dfarrell07`). This matters for Item 10.
- **Round 5 finding, load-bearing for Item 10's redesign**: cross-
  referencing `git log --oneline -- plugins/k8s-rebase/.claude-plugin/plugin.json`
  (one commit, ever) against `git log --oneline -- plugins/k8s-rebase/gates/`
  (150+ commits touching gates, spanning many rounds of gate additions,
  removals, and consolidations) shows **zero correlation between gate
  changes and version bumps** — every gate-touching commit in this
  skill's history happened without a version bump. A trigger that ties
  re-verification to "when `plugin.json` gets bumped" would, based on
  this skill's actual observed history, never fire. Item 10 is
  redesigned below to not depend on this premise.
- **k8s 1.37 shipped 2026-08-26** (confirmed via `gh api
  repos/kubernetes/kubernetes/releases`), 13 days before this revision.
  This matters for Item 6 — see the item itself for the corrected
  timeline.
- **All 6 matrix repos are Apache-2.0** (confirmed via `gh api`). No
  licensing concern for reproducing diffs/excerpts from these repos in
  eval outputs/traces — standard CI/test practice, squarely within a
  permissive license's terms. Checked once, in round 5; not revisited
  as an ongoing concern.
- **PR #617's current state** (checked in round 5): `OPEN`, `isDraft:
  true`, `mergeable: CONFLICTING`, `mergeStateStatus: DIRTY`, with four
  blocking labels — `do-not-merge/work-in-progress`,
  `do-not-merge/invalid-owners-file`, `needs-rebase`,
  `needs-ok-to-test`. Three of these four are entirely independent of
  this eval plan and will keep accumulating the longer Items 1-4 take.
  This matters for Item 8 (the reply) — see that item's round-5 update.

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
proves this pattern works for a multi-phase, real-repo, real-git-commit
agentic pipeline; k8s-rebase's wrapper follows the same shape but
invokes the skill once, matching `cmd_run`'s own invocation flags
exactly (see Item 1).

---

## Blocking prerequisites (resolve before writing the "real" yaml)

Four of these are load-bearing enough that getting them wrong
invalidates Items 1-3 outright, not just the numbers in them.

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
during Item 4a/4b, not before):
- `--max-turns`'s accounting scope (top-level agent only, or all
  subagent turns) is undocumented. If a real calibration run never
  hits a turn ceiling before `timeout` binds first, drop `--max-turns`
  calibration effort entirely.
- Whether `stream-json` surfaces a `PreToolUse` hook block as a
  distinct, greppable event, or only as an absent tool-result, is
  unconfirmed — verify by deliberately triggering a blocked command
  during calibration. **Round 5 addition**: given how many of this
  plan's checks (`no_forced_advance`, `push-attempt.log`,
  `orchestrator_reports_done`) currently rely on grepping raw text
  rather than structured events, set `traces.events: true` (Item 2)
  rather than `false` — the structured per-tool-call event stream this
  produces is exactly what would let these checks match a specific
  *event* (e.g. "this Bash call's result was a hook denial") instead
  of a *substring anywhere in free text*, which is more precise and
  directly closes the false-positive risk described in Item 2's
  `no_forced_advance` judge below. The storage/mlflow overhead is real
  but minor relative to this eval's already multi-hour, real-cost
  profile.
- Whether `claude -p` handles `stop-hook.sh`'s premature-completion
  block by continuing work or exits anyway is unconfirmed, and could
  produce a silent partial-completion state. Item 1 guards against this
  (`final-status.txt` + `orchestrator_reports_done`).

**Explicit, deliberate choice**: a wall-clock `timeout` kill is treated
as a hard case failure; this design does not attempt to use the
orchestrator's real resumability (`SKILL.md`'s Recovery section). An
acceptable trade-off, stated so it isn't read as an oversight.

### P2. The `dfarrell07/cloud-network-config-controller` fixture — status changed in round 5, verify durability before trusting

`https://github.com/dfarrell07/cloud-network-config-controller` branch
`bump1.36` returned 404 across rounds 1-4. **In round 5, it now
resolves (200)** — sha `9c9a3f649ec0...`, last commit 2026-07-14. This
is genuinely new/changed information, not a re-confirmation of the old
blocker. However: the repo's branch list is cluttered with roughly 30
timestamped `bump1.36-<timestamp>` branches that look like scratch/WIP
output from repeated automated runs, not committed fixture refs — only
the un-suffixed `bump1.36` (matching what `test/config-1.36.yaml`
already expects) is the one that now resolves.

**Do not treat this as durably resolved without one more check**:
re-verify `bump1.36` resolves again immediately before writing Item 3's
case files (branches on a personal fork with this much surrounding
scratch-branch churn are not guaranteed stable), and if it's still live
at that point, Item 3 can ship the full 6 cases from `test/config-1.36.yaml`
rather than 5. If it 404s again by then, fall back to 5 cases as
originally planned and track cloud-network-config-controller as a
follow-up, same as before.

The other 5 `known_good` refs are re-confirmed resolvable as of round
5 (three separate check rounds now): `dfarrell07/ovn-kubernetes-mcp`
branch `bump1.36-20260717052952`, `dfarrell07/multus-cni` branch
`bump1.36`, and `ovn-org/ovn-kubernetes`, `openshift/ingress-node-firewall`,
`openshift/cluster-network-operator`'s pinned commits.

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

**`claude` CLI drift is an ongoing risk, not a one-time check**: this
eval's flag syntax, `stream-json` schema, and `--max-turns` semantics
are pinned to the CLI's *current* behavior. Re-verify these mechanics
whenever this eval is run after a significant gap.

**Round 5 addition — a human checkpoint before real money is spent**:
`plugins/k8s-rebase/OWNERS` names a real, single person. Item 4b's
first real calibration run can cost up to ~$150, and production case
runs $80-150+ each. Get this plan's design (not just the eventual
final PR) reviewed and signed off by that owner before running Item
4b — the first step that spends real, non-trivial money — not only
before merging the final yaml. An AI agent should not autonomously
decide to spend real money against this plan's still-partly-unverified
numbers without a human checkpoint at that specific point.

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

0. **Crash-safety status write — corrected in round 5 to be SIGKILL-safe,
   not trap-only.** A bare `trap ... ERR EXIT` handler (round 4's
   design) cannot fire on `SIGKILL` — this is unconditional POSIX
   signal semantics, not something to verify empirically. If the
   harness enforces `execution.timeout` via `SIGKILL` (a common,
   reasonable choice, since it guarantees the process actually dies),
   a trap-only design would silently fail to write `run-status.json`
   on the single most likely infra-failure scenario: a timeout. Fix:
   write `output/run-status.json`, defaulting to `{"status":
   "infra_error", "reason": "..."}`, as the **literal first filesystem
   operation of the script**, synchronously, before the clone step,
   before installing any trap, before anything else — not merely
   inside a trap handler. Then *also* install a `trap ... ERR EXIT`
   handler (which correctly catches `set -e` command failures and
   `SIGTERM`, the two other realistic failure modes) as defense in
   depth. Only the success path (after step 6 below completes)
   overwrites the file to `{"status": "completed", ...}`. This doesn't
   make a SIGKILL "handled" in any deep sense — a kill two seconds
   after the initial write still leaves a stale `infra_error` file —
   but that stale file is exactly the *correct*, intended outcome: the
   signal a judge needs to see, reliably present, regardless of how or
   when the process dies.
1. **Reset-and-clean ordering — made explicit in round 5.** Clone into
   a directory distinct from `test/.repos/` (e.g. `evals/.repos/`,
   gitignored the same way). Cache clones across repeat runs, but
   **reset-and-clean must run as the literal first action of the
   run** (immediately after step 0's status write, strictly before
   invoking `claude -p`) — **never as end-of-run cleanup**. A
   plausible-seeming "clean up after myself" design (reset at the end
   of a run) would race with or precede that same run's own output
   capture (steps 6-10 below, which read `.rebase-tmp/gates/*.report`
   and generate diffs), silently wiping the very data those steps need
   to read and producing an empty/corrupt output that Item 2's judges
   would misread as a hard skill FAIL rather than the ordering bug it
   actually is. Concretely: `git reset --hard <from_commit> && git
   clean -fdx` (this also wipes `.rebase-tmp/`, which is correct and
   desired for full isolation — state the actual commands rather than
   leaving "reset to a clean checkout" as prose an implementer has to
   guess the mechanism for).
2. Invoke the real skill once, using the full, exact flag set from P1
   (re-`grep`ped from `test-skill.sh` at implementation time), capturing
   to `session-output.json`.
3. Extract cost/tokens via the helper above into `session-tokens.json`.
4. **Post-exit status guard**: regardless of the `claude -p` process's
   exit code, run `k8s-rebase-orchestrator.sh status` and capture its
   output as `final-status.txt`. Grep for the literal line `DONE:
   true` (confirmed in round 4, re-checked in round 5's mechanics
   fork: this line format is a single top-level line, not repeated in
   any per-gate/per-step table that could collide — safe as specified,
   but re-verify this exact-format dependency whenever
   `k8s-rebase-orchestrator.sh` changes, consistent with Item 10).
   `cmd_status`'s output can also include a `WARNING: state
   reconstructed from disk` line in recovery scenarios; treat as
   correlated with (not identical to) `no_forced_advance`'s check.
5. **Infrastructure-failure tagging**: `run-status.json` is written
   twice — synchronously defaulted in step 0, overwritten to
   `completed` here on success. Judges and Item 7's N-repeat
   aggregation must exclude `infra_error` runs from pass/fail tallying
   entirely.
6. Copy `.rebase-tmp/gates/*.report` into `output/gate-reports/`.
7. **`gate-retry-counts.json` — weak signal, honestly labeled.**
   Post-hoc mtime-based signal only (no per-attempt history); the real
   fix (the skill self-reporting retries) is a separate, out-of-scope
   skill-side follow-up.
8. Capture `diff.patch`, `files-changed.txt`, `commit-log.txt`, and
   `known-good.patch`, **using the same exclusion pathspecs as
   `cmd_court`'s `court_excludes`** (`:!.rebase-tmp`, `vendor/**`,
   `go.sum`, `packages/**`, `mocks/**`).
9. **Extracted build-error artifact**: write `build-errors.txt` by
   extracting build/vet/lint failure text step 2's agent reports, so
   `no_scope_creep`'s judge has a real evidence source.
10. Build `push-attempt.log`: search the transcript for any push/PR-create
    invocation; confirm `block-push.sh`'s exact denial text follows.
    Prefer parsing the structured event stream (per P1's `events: true`
    addition) over raw text grep once available.

**Why**: the literal, minimal fix for what enxebre flagged, using the
skill exactly as real users and `cmd_run` already do, with a status-
tagging design that survives the actual ways this process can die
(command failure, SIGTERM, and now SIGKILL), so its cost/tokens are
directly capturable without risking an unintended push or silently
mis-tagging an infrastructure failure as a skill regression.

**Implementation**: `run-rebase.sh <repo_url> <from_commit> <version>
[model]`, called by `eval.yaml`'s `runner.type: cli`. **Two-pass
dependency with Item 4, made explicit in round 5**: Item 4b needs
`run-rebase.sh` to exist to calibrate against; Item 1's final
`--max-turns`/timeout values need Item 4b's calibration data to be
sane. Resolve this by writing a first draft of `run-rebase.sh` with
generous, not-yet-calibrated internal defaults, run Item 4a (cheap
self-test) and Item 4b (real calibration) against that draft, then
refine Item 1's defaults from the results — not a strict "Item 4 fully
before Item 1" or "Item 1 fully before Item 4" ordering.

---

## 2. `evals/eval-k8s-rebase-pattern-retention.yaml` — HIGH VALUE

**Name**: `k8s-rebase-pattern-retention`, not the generic
`k8s-rebase-eval`, so a dashboard entry cannot be misread as
validating something it doesn't.

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
  timeout: <SET BY ITEM 4b CALIBRATION — placeholder only, do not trust>
  max_budget_usd: <SET BY ITEM 4b CALIBRATION — placeholder only, do not trust>
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
      - 'expected_gates_total': integer (32 as of round 5 — recount at
        implementation time regardless; this skill's gates/ directory
        has a long, active commit history) — used only to sanity-check
        gate-reports/ coverage, never a partial-credit pass count
      - 'known_repo_difficulty': simple|medium|complex — INFORMATIONAL
        ONLY: not mechanically consumed by any judge/threshold today,
        only interpolated into {{ annotations }} as LLM context. See
        the per-case threshold note under thresholds: below.
      - 'held_out': boolean — always false for cases in this eval; a
        held_out:true case belongs in the SEPARATE generalization
        eval (Item 6)
      - 'notes': context for LLM judges, informational only

outputs:
  - path: "output"
    schema: |
      run-status.json — {"status": "completed"|"infra_error", "reason": "..."}
        written synchronously as the literal first filesystem operation
        (SIGKILL-safe, not trap-only — see Item 1 step 0), overwritten
        to completed only on success. Judges/N-repeat aggregation must
        exclude infra_error runs from pass/fail tallying.
      session-output.json — raw stream-json for the single skill invocation
      session-tokens.json — extracted cost/token metrics
      final-status.txt — orchestrator `status` output captured post-exit
      diff.patch, files-changed.txt, commit-log.txt — final rebase
        output, generated with the same exclusion pathspecs cmd_court uses
      build-errors.txt — extracted build/vet/lint failure text
      gate-reports/ — copy of .rebase-tmp/gates/*.report
      gate-retry-counts.json — per-gate mtime-based retry signal; WEAK
      known-good.patch — known_good vs from_commit, same exclusions
      push-attempt.log — evidence of any push/PR-create attempt and,
        if present, confirmation of the exact denial text

  # This outputs.schema block is documentation for judge authors, not
  # a harness-enforced contract.

traces:
  stdout: true
  stderr: true
  events: true   # round 5: flipped from false — see P1's addition;
                  # this plan's own checks lean heavily on distinguishing
                  # structured events from incidental text matches
  metrics: true

judges:
  # ── deterministic, hard safety invariants — Item 7: require N/N
  #    unanimous across repeats, never an averaged rate. Runs tagged
  #    infra_error in run-status.json are excluded entirely. ──

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
      # PASS or SKIP. Confirmed against the orchestrator's actual
      # FORCE_ADVANCE exit-2 path: a forced advance does NOT
      # retroactively mark the blocking gate's report as PASS/SKIP —
      # it stays FAIL/stale, and this judge still correctly catches
      # it. Intentionally redundant with no_forced_advance — defense
      # in depth, not a gap.

  - name: no_forced_advance
    description: >
      Orchestrator never emitted FORCE_ADVANCE during the run.
      ROUND 5 CORRECTION — a bare substring grep is unsafe: SKILL.md's
      own "Execute Current Step" instructions literally contain the
      text "Exit 2 with FORCE_ADVANCE in output" as guidance to the
      agent, and an agent narrating its own reasoning ("checking
      whether advance returned FORCE_ADVANCE...") could cause this
      substring to appear in session-output.json even on a run that
      never actually force-advanced — the same class of bug already
      found and fixed once in this plan for
      pr_command_never_attempted_or_blocked (round 1), left unfixed
      here until now.
    check: |
      # Do NOT grep the bare word FORCE_ADVANCE anywhere in output.
      # Prefer, with traces.events: true, matching the orchestrator's
      # own advance command's tool_result content specifically (not
      # assistant-authored text events) for its exact printed marker
      # — grep k8s-rebase-orchestrator.sh's actual FORCE_ADVANCE
      # output string at implementation time, don't assume "the word
      # appears" is sufficient. If events:true data isn't usable for
      # this, at minimum anchor to the orchestrator's exact line
      # format (not a bare substring) in the tool-result blocks
      # specifically tied to `advance` invocations.

  - name: pr_command_never_attempted_or_blocked
    description: >
      Either no git push / gh pr create was attempted, or it was
      attempted and block-push.sh's exact denial text is present
      immediately after.
    check: |
      # search push-attempt.log for either (a) no push/pr-create
      # invocation anywhere in the transcript, or (b) an invocation
      # immediately followed by the confirmed denial string

  # ── deterministic, informational (no threshold) ──

  - name: gate_fix_loop_efficiency
    description: >
      WEAK SIGNAL: gate-retry-counts.json is derived from post-hoc
      file mtimes, not real per-attempt history.
    check: |
      # read gate-retry-counts.json; informational only

  # ── LLM, adapted from cmd_court's rubric and rules.md's Scope
  #    section — see Item 5's caveat. Judge-CALL failure (distinct
  #    from a genuine low score) is handled per Item 7's concrete
  #    retry-then-mark mechanism, not left as an open question. ──

  - name: rebase_correctness
    description: >
      Single-pass adaptation of cmd_court's PASS/FAIL criteria, using
      the SAME diff exclusions cmd_court uses. WEAKER than court.
      Treat a low score as "worth running make court for a real
      verdict," not a verdict itself. Calibrated against the cheapest
      case (Item 4b) — see the per-case threshold note below.
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
  # Placeholders pending Item 4b's SCORE calibration (graded, N>=3
  # samples per fixture, WITH the separation check). min_of_N is
  # deliberately NOT equal to min_mean — see Item 7.
  #
  # PER-CASE THRESHOLD NOTE: this is a single global block calibrated
  # against ONE case. Item 4 already argues cost/timeout must be
  # per-case for the same reason. Flagged, not fixed, as a known
  # simplification (same treatment as Item 5's court tradeoff) —
  # per-difficulty-tier calibration is real follow-up work.
  orchestrator_reports_done: { min_pass_rate: 1.0 }
  all_gates_resolved: { min_pass_rate: 1.0 }
  no_forced_advance: { min_pass_rate: 1.0 }
  pr_command_never_attempted_or_blocked: { min_pass_rate: 1.0 }
  rebase_correctness: { min_mean: <SET BY ITEM 4b>, min_of_N: <SET BY ITEM 4b, LOWER THAN min_mean> }
  no_scope_creep: { min_mean: <SET BY ITEM 4b>, min_of_N: <SET BY ITEM 4b, LOWER THAN min_mean> }
  # gate_fix_loop_efficiency: no threshold — informational only
```

**Why**: matches the repo convention. `events: true` (round 5) gives
the judges/checks a structured signal to match against instead of
grepping raw text, closing the `no_forced_advance` false-positive risk
directly. `all_gates_resolved`'s redundancy with `no_forced_advance`
is confirmed intentional defense-in-depth, verified against the
orchestrator's actual FORCE_ADVANCE code path.

**Implementation**: hard dependency on Item 1 and Item 4b landing
first.

---

## 3. Eval cases from the existing matrix config — HIGH VALUE

**What**: `evals/cases/pattern-retention/case-001` through `case-005`
(or `case-006` if P2's fixture is confirmed durable at implementation
time — see P2). Digit-only names per `.skillsaw/eval_case_rule.py`'s
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
`evals/README.md` is one shared file for the whole plugin.

**Why**: reusing the already-validated matrix repos gives a real,
proven correctness baseline for pattern-retention testing at low setup
cost. Explicitly *not* claimed to be a generalization test — see Item 6.

**Implementation**: mechanical — copy entries out of
`test/config-1.36.yaml`, re-verify every `known_good` ref resolves
immediately before writing the case files (per P2, including a final
check on `cloud-network-config-controller` specifically). Create
`evals/README.md` fresh with the `## <eval-name> (cases/<eval-name>)`
+ table format from the start.

---

## 4. Calibration: wrapper self-test, THEN cost/timeout/score — HIGH VALUE, BLOCKING

**Split into two sub-steps in round 5** — the prior single "calibration
pass" conflated validating the wrapper script's own correctness with
gathering real, expensive cost/timing/score data, meaning a bug in the
wrapper could silently poison hours and $80-150+ of real-run data
before anyone noticed.

### 4a. Wrapper self-test — cheap, synthetic, blocking, run FIRST

Before any real skill invocation, sanity-check `run-rebase.sh`'s own
`extract_tokens()` jq expression and diff-exclusion pathspec
construction against a small synthetic `stream-json` fixture with
known values. Seconds, not hours; costs nothing. A bug here would
silently poison every downstream calibration number (the sibling
template, `run-solve.sh`, has this exact gap today — don't inherit it
uncritically). Do not proceed to 4b until 4a passes.

### 4b. Real calibration — cost, timeout, and judge scores

1. **Cost/timeout calibration**: run `run-rebase.sh` against the
   smallest/fastest case and record actual `total_cost_usd`/`duration_ms`.
   **Enforcement mechanism, made explicit in round 5**: `eval.yaml`
   doesn't exist yet at this point in the implementation order (it's
   Item 2, which depends on this calibration's output) — so the
   "generous ceiling" for this specific run (e.g. 12h / $150) is
   enforced OUTSIDE the harness entirely: a shell-level `timeout 12h
   ./run-rebase.sh ...` wrapper for wall-clock, and a manual check of
   the observed dollar figure against the intended ceiling, since
   nothing automatically enforces a cost ceiling on an ad-hoc
   direct-CLI invocation. Order-of-magnitude math suggests a full run
   against `ovn-org/ovn-kubernetes` could plausibly run 4-10 hours and
   $80-150+. Production timeout/budget likely need to be set per-case.
   During this same run, empirically resolve P1's remaining
   unconfirmed items.
2. **Judge score calibration — graded, multi-sample, with a separation
   check, treated as provisional given N=3**:
   - **Grading**: (a) a known-good historical diff (expect near-max
     score), (b) a **subtle** bad example — hand-edit a copy of one
     real, correctly-preserved label-selector comparison in a
     `known_good` diff to swap it for `reflect.DeepEqual` instead
     (`rules.md`'s explicitly-forbidden-but-plausible pattern),
     producing a diff otherwise identical to a real correct rebase
     except for this one injected violation — this still needs a
     concrete repo/file choice made at implementation time; this plan
     specifies the method, not the exact fixture. Also score (c) an
     obviously-bad example as a sanity floor.
   - **Sampling**: score each fixture **N≥3 times** before deriving any
     threshold.
   - **Separation check**: verify `min(fixture_a_scores) >
     max(fixture_b_scores)` with an explicit minimum margin (e.g. ≥1.0
     point). If the distributions overlap or the margin is thin,
     that's itself a finding — the judge prompt may not discriminate
     well enough — and blocks committing any threshold until the
     prompt is revised.
   - **Round 5 caveat — N=3 is a real limit on this check's own
     reliability**: with only 3 samples per fixture, an observed
     max/min is a weak estimator of the fixture's true score range — a
     4th or 5th sample could plausibly exceed what 3 samples showed.
     The separation check reduces but does not eliminate the risk of a
     threshold based on too few calibration samples. Treat any
     threshold derived this way as **provisional** until Item 7's real
     production repeat-run data either confirms or contradicts it —
     don't treat a passed separation check at N=3 as final proof the
     threshold is right.
   - Set the final threshold in the confirmed gap between (a)'s
     minimum and (b)'s maximum, not just "above (b)."

**Why HIGH / blocking**: guessing wrong on cost/timeout aborts a real,
otherwise-correct run. Guessing wrong on thresholds — via the
easy-negative trap, an unconfirmed separation, or over-trusting a
thin-sample separation check — produces a threshold that looks
calibrated but isn't trustworthy. Also confirm `max_budget_usd`
enforcement semantics before finalizing safety margins (this matters
more once Item 2's eval.yaml exists and is what's actually enforcing
budgets, versus 4b's own manual/shell-level enforcement).

**Implementation**: 4a first (cheap, blocking), then 4b (expensive,
real), logged in this file once done — replace every placeholder with
real numbers and remove "placeholder" caveats, then commit as a
follow-up.

---

## 5. What `rebase_correctness` gives up relative to `cmd_court` — explicit tradeoff, not silently accepted

**What**: `cmd_court`'s design exists specifically because a single LLM
call judging a large diff is unreliable for this task. Item 2's
`rebase_correctness` and `no_scope_creep` judges collapse that into one
`prompt:` call each. That's a real rigor regression.

**What to do about it**:

1. **Check whether the harness's `agent:` judge type can host a
   reduced court** — a 1-juror-with-mandatory-`git show`-evidence judge
   would materially close the gap.
2. **If not**, keep both LLM judges as cheap smoke checks and treat
   `make court` as the actual quality gate for anything either judge
   scores as borderline.

**This tradeoff extends symmetrically to future skill evolution**: a
legitimate skill improvement could shift diff shape/gate-retry
counts/turn count without introducing a regression, causing this eval
to score it lower purely as an artifact of Item 4b's calibration being
pinned to a point in time. When this eval and `make court` (or real CI
results) disagree, treat a red eval as evidence Item 4b's calibration
needs refreshing, not as evidence the skill change is wrong.

---

## 6. Generalization eval: testing beyond pattern-retention — HIGH VALUE, addresses miheer's PR concern directly

**What**: A **separate** eval, `evals/eval-k8s-rebase-generalization.yaml`
(never a case mixed into Item 2's dataset), built from a repo/version
combination not used while developing or tuning the current `fix_*`
functions.

**Held-out options, ranked — timeline corrected in round 5**:

1. **(Strongest, AVAILABLE NOW — not a future option) k8s 1.37 against
   any matrix repo.** k8s v1.37.0 shipped 2026-08-26. As of this
   revision, `k8s-rebase-autofix.sh` still has no 1.37-specific
   pattern (only a TODO-style comment for future versions) — this
   option has flipped from "wait for the future" to "actionable now,"
   and no matrix repo has an autofix pattern tuned against 1.37 yet.
   This is the genuine forward-looking test this item exists to
   provide.
2. **(Weaker) A 7th repo never in any of the 3 config files.** Real
   generalization signal, but requires finding a real historical
   rebase PR as `known_good`.
3. **(Do not ship as an equivalent-looking interim signal) One of the
   backward-looking gaps** (`ovn-kubernetes-mcp`@1.34,
   `cluster-network-operator`@1.34, `ingress-node-firewall`@{1.34,
   1.35}). A PASS here could be actively misleading. Prefer being
   explicit in `evals/README.md` that zero generalization coverage
   exists rather than shipping a weak signal, unless option 3 is used
   as a genuine stopgap with an equally-prominent
   `generalization_strength: weak-backward-looking` field.

**Why this is not optional polish**: unchanged from prior rounds —
Item 3's cases measure pattern-retention, not generalization to
breakage nobody has pre-encoded a fix for, precisely miheer's concern.

**Implementation**: option 1 is now actionable immediately rather than
blocked on a future release — this changes Implementation order's
sequencing (see below). Building a case against a real k8s 1.37 rebase
of one of the 6 matrix repos is real work (finding/producing a
`known_good` reference, since none of these repos has had a
human-reviewed 1.37 rebase yet either) but no longer has an external
blocker.

---

## 7. Repeat-run variance: aggregation policy by judge type, with a real decision rule — MEDIUM VALUE

**What**: A single pass/fail per case is one draw from a distribution.

**Aggregation policy, split by judge type**:
- **Hard-safety-invariant judges**: require **N/N unanimous** across
  repeats, never an averaged rate. `infra_error`-tagged runs excluded
  entirely.
- **LLM quality judges**: report both mean-of-N and min-of-N, both real
  thresholds. `min_of_N` is **deliberately set lower than `min_mean`**,
  derived from Item 4b's own observed run-to-run spread scoring the
  known-good fixture repeatedly — not assumed calibrated identically
  to `min_mean`, since with N as small as 3, `min(X₁,X₂,X₃)` is itself
  a noisy statistic dominated by tail draws. Median-of-N was considered
  and rejected for N=3 specifically (median of 3 is just one of the
  three draws, equally noisy).
- **Informational judges**: report the distribution; no pass/fail
  semantics.
- **Judge-call failure, distinct from skill-run failure — concrete
  mechanism, not deferred, per round 5**: no native
  error/inconclusive judge outcome exists anywhere in this repo's real
  eval precedents (checked directly — `eval-detect-permafail.yaml`,
  `eval-solve.yaml` show no such mechanism), so this plan specifies its
  own: wrap each LLM judge's invocation in a **retry-once-then-mark**
  pattern — on an LLM API timeout or unparseable response, retry the
  judge call once; if the retry also fails, write a distinct
  `judge-errors.json` entry (e.g. `{"judge": "rebase_correctness",
  "status": "judge_infra_error"}`) that Item 7's aggregation checks
  alongside `run-status.json`, excluding that specific judge's result
  from N-repeat tallying for that run without invalidating the other
  judges' results from the same run.

Tag each repeat invocation with a `run_index` so N-repeat results group
in the mlflow experiment correctly.

**Scope**: given Item 4's cost findings, running N≥3 repeats across all
cases is expensive. Start narrow: run the calibration case at least 3
times under this policy before treating any single case's result as
meaningful. The calibration case will accumulate far more runs and
scrutiny than the others — treat its specific pass/fail history as
informative about the eval process itself, not as more representative
of overall skill quality than the other cases.

**Why MEDIUM not HIGH**: compounds Item 4's cost problem rather than
introducing a new blocking risk.

---

## 8. Gate-script unit tests (separate from the harness) — MEDIUM VALUE, DIFFERENT MECHANISM

**What**: The 8 gate `.sh` companion scripts (corrected count, round
5) are pure deterministic bash — they don't need LLM judging. A
`test/gate-scripts/` directory with small synthetic fixture repos and
expected PASS/FAIL/SKIP outputs, run via `bats` or a plain bash
assertion loop.

**Why**: cheapest, fastest, highest-precision coverage available, and
currently zero.

**Why this is NOT part of `evals/`**: agent-eval-harness judges *agent*
behavior; gate scripts contain no AI.

**Implementation**: lower priority than Items 1-4, but should land
before or alongside the eval work since it de-risks Item 2's
deterministic judges.

---

## 9. Repo housekeeping: `plugin.json` version bump — MEDIUM VALUE, EASY TO MISS

**What**: `CONTRIBUTING.md` requires a `plugin.json` version bump
(MINOR) for modifying plugin code. **Current version is `0.0.1`,
corrected in round 5** (round 4's claimed `0.3.0` was a methodology
error — see Context) — target is `0.0.2` or `0.1.0`.

**Implementation**: bump `plugins/k8s-rebase/.claude-plugin/plugin.json`
alongside Item 2/3 landing, then run `make lint`/`make update`.

---

## 10. Ownership and staleness — HIGH VALUE, REDESIGNED IN ROUND 5

**What**: `plugins/k8s-rebase/OWNERS` lists a single approver
(`dfarrell07`). This plan creates real, ongoing maintenance burden:
recalibration whenever the skill materially changes, fixture branch
liveness checks (P2's fixture has already flipped from 404 to live
once during this plan's own review), and Item 6's ranking needing
updates (k8s 1.37 already flipped it once). Without a named owner and
a trigger that actually fires, this eval risks the same silent-bit-rot
failure mode that motivated writing this plan.

**Round 5 correction — the round 4 trigger design doesn't work**:
round 4 proposed tying re-verification to `plugin.json` version bumps.
Checked directly against this skill's real history: 150+ commits have
touched `gates/` over time, and exactly one commit has ever touched
`plugin.json`. A trigger keyed to version bumps would, based on this
skill's actual observed behavior, never fire — the premise that gate
changes and version bumps correlate is empirically false for this
codebase.

**Redesigned trigger — not dependent on human version-bump
discipline**: since this skill's gate count is directly, mechanically
countable (`find plugins/k8s-rebase/gates -name '*.md' | wc -l`), tie
staleness detection to that count instead of to a human process. Two
concrete options, either sufficient on its own, ideally both:
1. **A lint/CI check**: record the current gate count (32, per this
   revision) in a single tracked location — e.g. a comment in
   `evals/eval-k8s-rebase-pattern-retention.yaml` or a small tracked
   file `evals/GATE_COUNT` — and add a cheap CI or `make lint` step
   that fails if the live `find ... | wc -l` count diverges from the
   recorded value, forcing a human to consciously update both the
   recorded count and (per the checklist below) consider whether
   calibration needs refreshing, rather than relying on anyone
   remembering to check.
2. **A periodic, calendar-based re-check** (e.g. quarterly, or "before
   each new k8s version's matrix entries are added" — a natural,
   already-occurring event per `test/config-*.yaml`'s pattern of
   growing with each new k8s version) as a fallback for drift this
   skill's own gate count wouldn't catch (e.g. `rules.md` wording
   changes, autofix pattern additions that don't add a new gate file).

**Checklist, once a divergence is caught by either trigger**:
- review `expected_gates_total` across all case `annotations.yaml`
  files for accuracy, and
- note explicitly whether Item 4b's calibrated thresholds still apply
  (a judgment call — see Item 5's note on treating a red eval as
  calibration drift, not necessarily a regression).

**Implementation**: add the gate-count lint check as a small,
mechanical addition alongside Item 2/3 (cheap to build, directly
addresses the specific drift this plan has now observed twice in its
own review history), and add the periodic-recheck expectation plus the
checklist to `plugins/k8s-rebase/evals/README.md`.

---

## Non-Goals

- **Full 5-step orchestration as a single harness `case`.** `runner.type: cli`
  sidesteps this (Items 1-3).
- **Reimplementing `k8s-rebase-orchestrator.sh`'s step-sequencing logic
  inside the harness or inside `run-rebase.sh`.** Round 1's mistake,
  corrected in round 2.
- **Replacing `cmd_court`.** See Item 5.
- **Running the full case set on every PR.** Manually-triggered, with
  a discoverable `make eval` entry point (P3).
- **Evaluating under a model the skill wasn't actually validated with,
  without saying so.** See Item 2's `models.skill`.
- **Shipping a backward-looking held-out case as if it were equivalent
  to real generalization coverage.** See Item 6 — now moot in practice
  since option 1 (k8s 1.37) is available immediately.
- **Assuming eval-runner credentials/trust model transfers to a shared
  or CI environment without reconsideration.** See P4.
- **Assuming this plan's calibrated numbers, fixture refs, and gate
  counts stay correct without an owner or a trigger that actually
  fires.** See Item 10 — redesigned in round 5 after the round 4
  version-bump trigger was found to be empirically unworkable.
- **Treating a global score threshold as equally valid across repos of
  declared-different complexity without saying so.** See Item 2.
- **Round 5 addition — trusting a `git log --all` scan as evidence of
  a repository's real history.** This plan's own round 4 made exactly
  this mistake (see Context). Any future re-verification of live facts
  in this repo should scope `git log` to the actual checked-out
  branch/ref, not the full local object store.
- **Round 5 addition — letting an AI agent autonomously spend real
  money against this plan's numbers without a human checkpoint.** See
  P4's new human-sign-off addition.

---

## Implementation order

1. **P1, P2, P3, P4 (Blocking prerequisites)** — resolve all four
   before writing anything beyond a draft yaml. Re-`grep` `cmd_run`'s
   exact safety flags fresh. Get P4's human sign-off before Item 4b.
2. **Item 4a (wrapper self-test)** — cheap, synthetic, blocking, before
   any real spend.
3. **Item 1 (`run-rebase.sh` wrapper), first draft** — with generous,
   uncalibrated internal defaults; the crash-safety write must be
   SIGKILL-safe (synchronous first operation, not trap-only); the
   reset-and-clean step must run first, never as end-of-run cleanup.
4. **Item 4b (real cost/timeout/score calibration)** — against Item 1's
   first draft, using a shell-level (not eval.yaml) enforcement ceiling
   for the calibration run itself. Feeds back into refining Item 1's
   final defaults.
5. **Item 1, finalized** — with Item 4b's real numbers.
6. **Item 2 (`eval-k8s-rebase-pattern-retention.yaml`, with `traces.events:
   true`) + Item 3 (cases — 5 or 6 depending on P2's fixture durability
   check) + Item 9 (version bump to 0.0.2/0.1.0) + Item 10 (gate-count
   lint check + staleness checklist)** — depends on 1-5 above. Run
   `make lint`/`make update` as part of calling this item done.
7. **Item 8 (gate-script unit tests)** — independent, parallelizable.
8. **Item 7 (repeat-run variance, including the retry-then-mark
   judge-failure mechanism)** — after Item 3 exists and Item 4b's real
   numbers are known.
9. **Item 6 (generalization eval)** — now actionable immediately (k8s
   1.37 is out), not blocked on a future release; still real
   fixture-creation work, tracked as its own follow-up.
10. **Reply to PR #617** — pointing at this plan, explicit about what's
    shipped vs. planned, distinguishing pattern-retention (ready
    sooner) from generalization (Item 6, the actual answer to
    miheer's concern). **Round 5 addition**: PR #617 currently carries
    four blocking labels (`do-not-merge/work-in-progress`,
    `do-not-merge/invalid-owners-file`, `needs-rebase`,
    `needs-ok-to-test`) and real merge conflicts — three of these four
    are pre-existing and entirely unrelated to this eval plan. Note
    this explicitly in the reply rather than letting "the PR is still
    blocked" become a reason to also delay a reply that's otherwise
    ready; resolve the unrelated blockers independently, likely before
    or alongside this eval work landing, so the branch isn't
    re-rebased against already-conflicting state on top of new changes.
</content>
