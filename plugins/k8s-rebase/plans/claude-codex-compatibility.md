# Claude/Codex Compatibility Plan

## Goal

Make the existing `k8s-rebase` skill usable by both agents without duplicating
the workflow or redesigning rebases. Keep one plugin package, one
`SKILL.md`, and the shared scripts, step files, gates, and reports.

Changes are limited to invocation/instruction compatibility, independent-review
handoff, existing hook input formats, documentation, and focused validation.
Only one session may mutate a rebase at a time. Use separate clones for
concurrent checks: worktrees share Git hooks, so they are not fully isolated.

## Verified starting point

The compatibility review on 2026-09-14 established:

- The repository already documents Codex installation through its existing
  marketplace in [getting-started.md](../../../site/docs/getting-started.md).
  Both container definitions use that same marketplace.
- Codex CLI 0.154.0 lists `k8s-rebase@ai-helpers` and reads its existing
  Claude plugin manifest. Its plugin-details response discovers
  `k8s-rebase:k8s-rebase`, the existing skill frontmatter, and all five hooks.
- Codex supports the existing hook file location and Claude-compatible
  plugin-root variables for hooks. Hook execution requires trust; discovery
  is not proof of enforcement. See the
  [official hook documentation](https://learn.chatgpt.com/docs/hooks#plugin-bundled-hooks).
- Isolated checks reproduced two interface concerns: `gates` can exit 0
  with a cached FAIL, and the vendor-edit hook ignores Codex patch payloads.
  A FORCE_ADVANCE result already moves state to the next step.

These checks establish the implementation baseline, not completed installation,
live hook enforcement, or end-to-end rebase compatibility. Record the runtime
versions actually tested; do not infer support for every Codex version or client.

## Implementation

### Implementation status — 2026-09-14

Shared instructions, gate handoffs, review preparation, and vendor-patch input
support are implemented. Step 5's existing rubric was extracted into the small
`scripts/k8s-rebase-pr-review.sh` helper; no orchestrator, migration, manifest,
gate-policy, or attribution changes were needed. This plugin is new relative
to `origin/main`, so its initial version remains 0.0.1.

Verified: 15 offline tests (`python3 test/test_compatibility.py`), all eight
evidence/template pairs, shell syntax/ShellCheck, and strict site build.
Independent fixture testing covered invocation, resume, process completion,
inline gates, and exhausted-budget/force-advance handoffs. Codex CLI 0.154.0
installed the existing package and exercised all five hooks in a disposable
repo using invocation-only trust after inspecting the loaded definitions.
The generic skill validator rejects existing Claude metadata that the actual
Codex loader accepts; it is intentionally retained.

End-to-end qualification remains blocked. Bounded Codex 0.154.0 and Claude
2.1.270 probes of pinned ovn-kubernetes-mcp to 1.35.3 both failed in the unchanged
Step 1 dependency selection: API modules drifted to v0.36.2 while kubectl stayed
at v0.35.3. Commit `258dfab8` clarified the existing Step 1 stop rule after
Claude incorrectly attempted advancement; fresh-session recovery checks then
stopped correctly in both agents without changing files or retry counts.
Steps 2–5 and their real independent reviews remain unqualified.

Repository lint still reports 77 unrelated errors under
`.claude/worktrees/purrfect-beaming-haven/`. The pre-existing root-vendor
exclusion defect in the Step 4 review diff is also outside this change.

### 1. Reuse the existing package and document invocation

Use the repository's existing installation route:

```bash
codex plugin marketplace add openshift-eng/ai-helpers
codex plugin add k8s-rebase@ai-helpers
```

For local development, add the checkout as a local marketplace using the same
layout. Verify installation and skill discovery from a separate target repo.
Document the repo-root session, hook trust, and fresh-reviewer prerequisites,
plus both namespaced invocations, in the plugin README:

```text
Claude: /k8s-rebase:k8s-rebase [--bump-tools] <version>
Codex:  $k8s-rebase:k8s-rebase [--bump-tools] <version>
```

Keep the existing manifest and skill frontmatter, including Claude metadata.
The actual Codex loader accepts it; it must not be treated as granting tools
or permissions. Do not add another manifest, marketplace, skill copy, or
provider entry point. Follow repository version-bump and marketplace-sync
rules when implementation changes require them, not a separate cachebuster scheme.

### 2. Normalize shared instructions

Apply these conventions to `SKILL.md`, `steps/rules.md`, all five step files,
and all gate prompts. Keep migration guidance and gate criteria unchanged.

#### Invocation and paths

- Derive the installed plugin root from the actual loaded skill path, resolving
  runtime aliases/symlinks. `skills/k8s-rebase/SKILL.md` is inside that root.
  Verify the orchestrator and skill directory exist there. Replace home-directory
  searches with this known root; do not select an arbitrary installed copy.
- Derive the target repo root separately with `git rev-parse --show-toplevel`.
  Before `init`, verify the session cwd is that checkout/worktree root (compare
  resolved paths). Otherwise stop and ask for a session started at the root.
  Existing hooks look for `.rebase-tmp/.session-active` under the session cwd;
  a shell `cd` or per-command workdir override does not change Codex's hook cwd.
  Keep those guards unchanged. See the
  [hook session-cwd contract](https://learn.chatgpt.com/docs/hooks#common-input-fields).
  Run repo-level commands at the root and module-local operations in the
  affected module; neither changes the session-root prerequisite.
- Pass absolute paths and invocation arguments to workers. Set needed shell
  variables in each command call; do not assume prior exports or cwd survive.
  Existing self-locating scripts remain unchanged.
- Take the version and optional `--bump-tools` from the user's invocation.
  Do not depend on Claude's `$ARGUMENTS` substitution or a shell variable of
  that name. Pass quoted argv to existing scripts, without `eval`; stop on
  missing/invalid arguments before initialization. Preserve the flag through
  Step 1 and Step 4d, including delegated work.
- On resume, read existing state before `init` and reconcile the requested
  version with it; `init` currently ignores a new version when state exists.
  Recover the unrecorded tools flag from context or ask if unknown. If state
  is missing but interrupted artifacts remain, report the recovery ambiguity:
  `status` reconstruction is advisory and does not restore `state.json`.
  Do not fresh-initialize over those artifacts or add provider state.

There is no manifest-injected runtime value. Use short agent-specific
instructions only for actual differences, not CLI-presence detection or a
provider environment-variable protocol. Hook-root variables are scoped to
hooks; the shared shell workflow must not assume they are available.
Keep unrelated `.claude/` exclusions in target-repo file scans.

#### Execution capabilities

Describe file reading, editing, delegation, and process waiting by capability,
not mandatory Claude tool names or tool arguments.

Use native subagents when available; otherwise run ordinary step work,
investigation, tests, and gates inline. Remove unconditional instructions
forbidding the parent from reading gate prompts. Preserve read-only reviewer
roles and the existing report-only write allowance for gate reviewers; the
parent applies fixes. Independent review has the stricter requirement below.

Use the runtime's supported long-running process/session mechanism and wait
for actual completion before dependent work. Preserve Step 1's exit meanings:
0 means no work needed, 2 means success, and 1 means error. Its result marker
is written before optional tooling finishes and must not substitute for process
completion. Do not introduce a polling service or monitoring framework.
Keep Claude's `/loop` suggestion conditional; do not create Codex automation.

#### Gate and step protocol

Correct the shared caller instructions to match the existing orchestrator:

1. Use the returned `STEP_FILE` relative to `skills/k8s-rebase/`; it already
   includes `steps/` and `.md`. Check completion on resume before resolving
   a step file. Step 5 runs after gated completion and is never advanced.
2. Run `gates` to execute companions and discover pending work. Exit 1 means
   pending work, not an infrastructure failure. Exit 0 means no pending work,
   not that all verdicts passed. Inspect EXISTING/RESOLVED verdicts too:
   FAIL, SKIP, and INCONCLUSIVE are not PASS.
3. Read pending prompts and their evidence, checking evidence HEAD freshness.
   Write the existing report format through `write-gate-report.sh`.
   Ensure the report describes the HEAD actually reviewed; do not stamp old
   analysis as fresh after concurrent changes.
4. After fixes, commit and re-validate as the step requires. Re-run `gates`
   and complete all stale/pending current-step reviews, not just previously
   failing gates. A new commit invalidates current-step reports at the old HEAD.
   If deliberately invalidating a cached report at the same HEAD, do so before
   refreshing it; never delete a newly regenerated companion report. Preserve
   prior-step reports.
5. Give the parent sole ownership of `advance`; step workers return results.
   Preserve existing retry/force-advance policy and step-specific stop conditions.
   Do not multiply retries through nested parent/worker fix loops.
   Never call `advance` as a status poll or repeat it after a handoff has
   already advanced state. In Steps 2–4, if the fix budget is exhausted while
   advancement is BLOCKED, submit the remaining blocked attempts to the
   existing force-advance policy without adding another fix loop. Step 1
   structural failures stop without calling `advance`, even to record failure.
   On FORCE_ADVANCE, report the warning and INCOMPLETE record, then use
   `status` to find the current step or completion. An ERROR is a hard stop.
   DONE does not mean all gates passed: retain unresolved findings in the
   final summary. INCOMPLETE records only the latest force-advance, so keep
   the reports as well.

Do not change the orchestrator, gate names, verdict meanings, report schema,
freshness checks, or retry thresholds to implement these caller corrections.

### 3. Adapt independent reviews and existing hook inputs

#### Independent review

Keep Claude's current nested review path and its existing verdict format.
For Codex, use a fresh-context, read-only native reviewer, supplied with the
review rubric and evidence rather than the parent's reasoning history.
A parent self-check is not an independent review. If no independent reviewer
is available, stop at the review boundary and report the missing capability.

Keep the two existing review scopes distinct:

- **Step 4:** Add a `--print-prompt` mode to
  `scripts/k8s-rebase-review.sh`, reusing its evidence preparation and
  `k8s-rebase-review-prompt.md`. It must emit the populated prompt without
  invoking Claude, and fail if required inputs, the template, or rendering
  are unavailable rather than returning approval. Optional context remains
  optional. Preserve the default Claude invocation path.
- **Step 5:** Reuse its existing full-rebase diff preparation and pre-PR
  rubric, not the Step 4 template. Keep one source for this rubric across
  both agents; separate prompt preparation from the Claude invocation.
  Include the target version and commit list required by the rubric; preserve
  diff filters and disclose truncation.

Both Codex preparation paths must validate commit/base references and check
required Git/evidence-command exit statuses before truncation and rendering.
A failed collection is an error, not an empty diff to approve. A successfully
collected but empty filtered diff is valid evidence, not automatic approval.
Do not rely on the exit status of `head`, rendering, or the final command to
prove collection succeeded. Keep these checks scoped to the Codex preparation
paths; do not change Claude's existing failure policy.

The Codex parent must receive an explicit `APPROVE: <reason>` or
`REJECT: <reason>` from the reviewer. Investigate rejection before proceeding;
missing/malformed verdicts or infrastructure failure do not authorize
continuation. Successful prompt preparation is not approval. On resume, repeat
review if a decision for the reviewed SHA/scope is unavailable. Keep evidence
as data, not instructions; do not reuse approval for subsequent changes.
Do not add an `INDEPENDENT_REVIEW` marker, review state machine, or CLI
provider-dispatch framework. Existing Claude fail-open behavior is not
redesigned here; Codex must not inherit those infrastructure-as-approval paths.

#### Hooks

Reuse `hooks/hooks.json` and the existing scripts. Document Codex hook trust
and verify effective loading/execution in the supported runtime.
Do not disable the hooks or assume they are Claude-only.

Adapt `block-vendor-edit.sh` to recognize both Claude `file_path` input and
Codex `apply_patch` input in `tool_input.command`, checking all affected
paths, including move destinations. Preserve the session guard and existing
block response. The
[Codex hook input contract](https://learn.chatgpt.com/docs/hooks#pretooluse)
defines the payload difference. Test other existing hooks against each
runtime's actual inputs; change only demonstrated format incompatibilities,
not their policies.

### 4. Validate both agents without porting the eval framework

Validate from small to large: static checks, one focused fixture, the full
offline suite, installed-agent interface fixtures, then a bounded rebase pair.
Reuse matching recorded evidence; stop escalation on a new failure and fix
the smallest reproducer before retrying. Do not launch full rebases to debug
a local interface defect.

Freeze the source revision and installed contents; record CLI/model versions
and hook trust mode. Keep logs, reviewed SHAs/scopes, reports, and outcomes in
`.work/claude-codex-compatibility/`, outside installed packages and target branches.
Give agents the skill and raw fixture state, not the expected answer.

Keep tests targeted at the changed interfaces:

- Verify existing-package installation and invocation in a disposable target
  repo outside the plugin checkout. Check two separate command calls resolve
  the same plugin root without home-directory searches; cover argument
  forwarding, missing/invalid/extra arguments, question-only requests,
  quoted paths, and `--bump-tools`.
  Verify a subdirectory-started session stops before `init`, even when a
  command's workdir is overridden to the repo root; a root-started session
  must retain hook activation during module-local commands.
- Exercise ordinary inline fallback, long-running command completion, resume
  (including version mismatch and completed state), cached non-PASS verdicts,
  stale reports after a commit, and FORCE_ADVANCE handoff. Assert no duplicate
  advancement or deletion of prior-step reports. Cover sequential cross-agent
  handoffs in fixtures and Step 1 stopping without advancement.
- Test both review preparations, APPROVE/REJECT/missing-verdict outcomes,
  and stopping when no independent reviewer is available.
  Cover invalid commit/base references, failed evidence commands, and valid
  empty filtered diffs; failed collection must never yield successful Codex
  preparation or reach the reviewer as if evidence were complete.
  Prove the Codex path never invokes Claude and the Claude path still does;
  verify Step 5 retains its separate rubric.
- Test hook payloads for both agents with active and inactive session guards.
  Verify trusted-hook behavior in Codex, including vendor edits, module
  commands, push/PR blocking, prior-step report deletion, and the Stop hook.
  Use harmless stubs without publishing access and require actual hook denial,
  not just an agent declining the command. Do not push or publish anything.
- Scan the shared skill, all steps, and all gate prompts for remaining
  Claude-only execution assumptions. Explicit Claude review branches and
  compatible hook-root references are intentional exceptions, not scan failures.

Run `git diff --check`, Bash syntax/ShellCheck for changed scripts,
`make -C plugins/k8s-rebase test-compatibility`, and
`make -C plugins/k8s-rebase assert-evidence-paths`. Run repository `make lint`
and `make site-build` for documentation changes. Record known unrelated lint
failures separately; new failures block escalation. Do not introduce a new
evaluation framework.

For the remaining qualification pair, use the existing `openshift/multus-cni`
case in [config-1.36.yaml](../test/config-1.36.yaml): baseline
`b4ec7d8239ce4bd3ed949bce9816a013377b44c7`, target 1.36.2, tools flag false.
Use separate clean clones, matching Go/tooling environments, and the same
installed candidate. Start detached at the baseline, as the eval harness does;
also pin the local default branch there for review-base discovery. Starting on
the default branch allows the script to fast-forward away from the baseline.

Run Codex first, then Claude after it passes; a targeted diagnostic comparison
is an exception. Set a wall-time/cost cap before starting and preserve blocked
runs without switching repositories to seek a pass. Use the installed skill
through all four gated steps and Step 5, with real companions and independent
reviews. Pause at a safe committed boundary with no child process running,
then resume in a new session. Verify no duplicated work or lost reports.

Qualification requires both agents to reach Step 5 with applicable gates
passing and independent reviews completed, without compatibility-related
manual rescue. Different valid fixes are acceptable. Verify existing trailers,
printed-only push/PR commands, retained reports, and pre-push-hook restoration.
Force-advanced completion proves traversal, not an all-gates-passing rebase;
missing reviewers, prerequisites, or remaining workflow coverage mean unqualified.

The full multi-repository Claude harness/matrix is not a prerequisite for
this compatibility change. A metadata check or single passing gate is also
not evidence that the complete workflow works.

## Scope boundaries and existing limitations

Do not change Kubernetes/OCP migration logic, fix patterns, gate criteria,
force-advance policy, or commit attribution. Do not add package duplication,
provider persistence/configuration, new monitoring, or another hook system.

Preserve module-safety rules and their documented exceptions. There is an
existing conflict: `rules.md` permits tidy/vendor after certain replace or
dependency updates, while the module-operation hook blocks direct calls.
Record that separately; do not silently erase exceptions, conceal commands
in prose, or invent repair wrappers in this work. If it blocks a smoke run,
report the blocker rather than relaxing policy to obtain a pass.
