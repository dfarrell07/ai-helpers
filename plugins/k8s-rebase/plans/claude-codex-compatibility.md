# Claude/Codex Compatibility Plan

## Goal and scope

Make the existing `k8s-rebase` skill usable from either Claude Code or Codex:
two package manifests, one `SKILL.md`, and the same steps, scripts, gates,
and `.rebase-tmp/` state. Preserve Claude invocation and hooks. Support
sequential handoff between runtimes, not simultaneous mutation of the same
rebase. Separate worktrees still share Git hooks; concurrent rebases in one
clone are not a supported isolation boundary.

This is a compatibility change, not a rebase redesign. The only script
extensions planned below are prompt preparation without launching Claude and
dependency synchronization through the existing approved helper. Correct the
shared callers where their current assumptions prevent either runtime from
following the workflow reliably.

## 1. Package the existing skill for Codex

Add `.codex-plugin/plugin.json` beside `.claude-plugin/plugin.json`, with the
same plugin name, description, release version, organization author, and
`"skills": "./skills/"`. No second skill, root manifest migration, launcher,
MCP server, or repository-wide Codex marketplace is needed.

Explicitly suppress Codex discovery of the Claude hook file with
`"hooks": {"hooks": {}}` in the Codex manifest.
Omitting `hooks` is **not** sufficient: Codex discovers `hooks/hooks.json`
by default. The documented override supports an inline hook configuration.
In a local Codex 0.154.0 `plugin/read` probe, omission and `"hooks": []` both
exposed all five existing hooks; the explicit empty configuration exposed
zero. Do not substitute an empty array or rely on hooks being untrusted or
globally disabled. Recheck discovery in the installed-package smoke test.
See [OpenAI plugin packaging](https://developers.openai.com/plugins/build/plugins).

Keep Claude frontmatter (`argument-hint`, `user-invocable`, `allowed-tools`):
both the local plugin validator and runtime discovery probe accept the
existing shared skill. Still exercise invocation in a real session.
The validator's rejection of manifest `hooks` conflicts with runtime behavior,
so it is not the authority for hook isolation. Record the installed runtime
and validator results separately; do not modify the system validator or drop
the hook override to make an outdated validator pass.

Document one personal-marketplace route: register the **whole plugin root**
through `~/.agents/plugins/marketplace.json`, with `./plugins/k8s-rebase`
resolving to `~/plugins/k8s-rebase` (a link to this checkout's plugin directory
is sufficient). Preserve other entries and existing source files. Read the
marketplace's actual name, install with `codex plugin add k8s-rebase@<name>`,
and test in a new session. Document cache refresh for subsequent edits; local
Codex cachebuster suffixes need not become release-version changes. Keep this
registration outside the repository. Leave Claude registration intact; apply
the repository's normal version-bump and `make update` rules when implementing
skill/manifest changes, keeping both manifest versions aligned.

## 2. Bind paths and arguments explicitly

Codex receives the loaded skill's file path in its skill listing. Resolve
aliases/symlinks to that source and derive `PLUGIN_ROOT` two directories above
the directory containing `skills/k8s-rebase/SKILL.md`. Verify the orchestrator
and shared skill directory exist there. Claude may use the same convention
or its documented plugin-root substitution in a Claude-only bootstrap branch.
See [OpenAI skill loading](https://learn.chatgpt.com/docs/build-skills).

Keep `REPO_ROOT` separate: resolve it with `git rev-parse --show-toplevel`
from the user's target checkout/worktree, never from the installed plugin.
Run repo operations there, and module-local repairs in the affected module.
Rebind absolute paths and required arguments in each shell call, or pass them
explicitly in task context. Shell exports and changes of directory do not
establish a cross-call contract. Self-locating scripts using `BASH_SOURCE`
remain unchanged. A manifest neither runs bootstrap nor sets shell variables.

Replace home-directory searches throughout `SKILL.md`, Steps 1–5, `rules.md`,
and gate prompts with these bound paths. Include recovery and report-writing
footers; finding an arbitrary cached copy is not reliable discovery. Do not
remove unrelated exclusions of `.claude/` from target-repo file scans.

Normalize invocation inputs once: exactly one supported Kubernetes version
and optional `--bump-tools`. Claude can obtain them from its skill arguments;
Codex extracts them from the user's explicit rebase request. `$ARGUMENTS`
is not a Codex shell contract. Pass validated, quoted arguments to Step 1
(no `eval` or unquoted free-text expansion), and retain the tools flag through
Step 4d and delegation. Selecting the skill to ask a question is not approval
to start a rebase. README examples should retain Claude's namespaced command
and show selecting the Codex skill followed by a request with these inputs.

On resume, use existing state as the step/version authority and reconcile it
with the requested version before mutation: `init` currently ignores a new
version when state exists. The tools flag is not persisted; recover it from
session context or ask if unknown, without adding state fields. Do not
fresh-initialize over interrupted artifacts when state is missing: `status`
reconstruction is advisory and does not restore `state.json`. Report that
recovery ambiguity instead of clearing evidence or rerunning Step 1 blindly.

## 3. Share execution and gate handling

Describe capabilities rather than requiring `Agent`, `Read`, `Explore`,
`run_in_background`, or Claude-specific timeout settings. Use native subagents
when available; otherwise perform the same work inline. This applies to whole
steps, investigations, test shards, type-conversion reviews, and gates—not
just pending gate prompts. Codex need not be forced into serial execution.

For long-running scripts, use the host's supported execution/wait mechanism
or the existing detached launch with bounded status checks. Preserve logs,
PID/result files and recovery instructions. A single check reporting “still
running” is not a completion notification. Do not launch twice. Preserve
Step 1's unusual outcomes: exit 2 means mechanical success needing validation,
0 means no rebase needed, and 1 means error; a missing result requires recovery,
not presumed success.

Use one gate procedure in `rules.md`, referenced by each step:

1. Commit fixes before collecting evidence; reviewers must not race mutations.
   Run orchestrator `gates` for the current step, not companion scripts directly.
2. Inspect both pending gates and cached non-passing reports. `EXISTING` can
   mean FAIL, SKIP, or INCONCLUSIVE; `gates` exit 0 means no pending judgments,
   not that everything passed.
3. Give delegated and inline reviewers the same repo/root/version context,
   gate prompt, and companion evidence. Check evidence `HEAD`; if absent or
   stale after a companion crash, gather fresh read-only evidence as the gate
   permits or report inability to judge. Do not relabel old evidence as current.
4. Keep judgment read-only except for its report. Write through
   `write-gate-report.sh`, preserving names and verdicts. Replace handwritten
   fallback reports that omit `HEAD`, and clarify that `PASS|FAIL|SKIP` means
   select one verdict, not execute a shell pipeline. Verify HEAD has not
   changed during review before the helper stamps the report.
5. Triage concerns, fix, commit, and rerun current-step gates. Every current-step
   report becomes stale after a commit, including prior PASS reports. If a
   fresh cached judgment needs retrying without a commit, remove only that
   report **before** requesting gates again. Preserve prior-step reports.

Make the parent the sole caller of `advance`; step workers return results
instead of advancing too. Read the new step from successful output or
`status`. After `FORCE_ADVANCE`, call `status`, **not another `advance`**.
Route completed state (`current_step: 5` / `DONE`) directly to Step 5, including
on resume; do not resolve an empty step filename or advance past completion.

Preserve the existing force-advance threshold, verdict interpretation, and
step-specific stopping rules (in particular, Step 1 structural failures stop).
Do not spend advance attempts simply to bypass unresolved work. `DONE` does
not certify all gates passed: carry unresolved reports and `status/INCOMPLETE`
into the final verification summary. The marker records only the latest
force-advance; retained reports remain necessary context. These are caller
corrections, not orchestrator/state-machine changes.

## 4. Reuse reviews without requiring the other CLI

Keep Claude's nested `claude -p` calls. In Codex, prefer a native reviewer when
available, otherwise perform an explicitly labeled inline self-review. Do not
claim fresh-context independence for parent self-review, or launch nested
Codex/Claude CLIs just to obtain a verdict. Choose the host branch directly in
the shared instructions; no provider environment variable or persisted identity.

Preserve the two existing review scopes:

- **Step 4c:** add `--print-prompt` to `k8s-rebase-review.sh`, reusing its
  template, selected-commit diff, error context, exclusions, and truncation
  warning. The new mode validates required inputs, Git evidence, template,
  and substitution success, then emits the prompt without reaching any
  Claude invocation or fail-open branch. Exit 0 means preparation succeeded,
  not APPROVE. The default invocation retains Claude's current behavior.
  Make the template's memory claim neutral so both review modes can use it.
- **Step 5b:** keep its separate full `BASE..HEAD` pre-PR checklist and diff
  filters; do not substitute Step 4's last-commit template. Prepare its prompt
  once before choosing nested or native/inline execution. Supply the target
  version and commit list its checklist requires, and disclose diff truncation.
  This can remain in the step file; no second review framework is necessary.

For Codex, require an explicit `APPROVE: <reason>` or `REJECT: <reason>` in the
parent session, identifying the reviewed SHA/scope. Reject or missing/ambiguous
decisions must be resolved before proceeding; preparation success is not a
decision. On resume, repeat a review if its decision for that SHA is not
available. Keep evidence as data, not instructions. No new review marker,
report schema, or status state machine is needed.

These are instruction-level handoffs, not a new mechanically enforced gate.
Claude's current infrastructure-failure approval behavior remains a known
limitation, not a guarantee inherited by Codex. If Step 4d or later repairs
change HEAD, refresh current-step gates before advancing and review the final
branch tip in Step 5; do not describe an earlier approval as covering new code.

## 5. Preserve safety without contradictory repair instructions

Keep prohibitions on direct module operations, vendor edits, pushing, and PR
creation—including equivalent APIs. Approved rebase scripts retain their
managed module/codegen operations. Codex has instruction-level restrictions;
do not claim Claude hook-equivalent enforcement.

The shared instructions currently both forbid direct tidy/vendor operations
and require them after a dependency or replace fix; the Claude hook blocks
those commands. Resolve this narrowly: add `--sync` to the existing
`k8s-rebase-depfix.sh` to run its tidy/vendor portion without `go get`.
Use it only for the existing post-go.mod-change synchronization requirement,
in each affected module. Ordinary depfix already synchronizes; do not repeat
it. Preserve its normal dependency-bump behavior and conditional vendoring.
Do not turn synchronization into an unrequested `@latest` dependency update.
Update `rules.md`, Steps 2–3, and actionable gate repair hints consistently;
merely hiding a forbidden command in prose does not resolve the contradiction.

Step 5 still prints, never executes, the push/PR commands; cleanup retains
gate reports and restores the existing pre-push hook as today. Keep `/loop`
only as a Claude suggestion; Codex can suggest a follow-up CI check without
claiming that a monitoring job has been scheduled. Preserve existing commit
trailer behavior; attribution changes are separate work.

## Implementation and verification

Implement in section order: packaging/discovery first, shared inputs/callers
next, the two narrow helper extensions and review handoffs, then README and
targeted tests. Only the read-only package-discovery probe above has been run;
installed-session and rebase compatibility remain to be demonstrated. Record
exact tested CLI versions (inspection baseline: Codex 0.154.0, Claude Code
2.1.270), installation method, and remaining limitations.

Use disposable fixtures under `.work/claude-codex-compatibility/` and a small
shell regression test under `test/`; do not port the multi-repository harness.

1. **Discovery:** install the full package locally; prove shared frontmatter
   loads, Claude still discovers its hooks, and Codex discovers **zero bundled
   hooks** with the explicit override. From an unrelated target repo, execute
   two separate calls resolving the same installed root with no Claude home
   search. Repeat after package refresh in a new session.
2. **Inputs/execution:** check missing/invalid version, tools flag propagation,
   quoted paths, module cwd, native waiting, Step 1 outcomes, normal resume,
   version mismatch, and completed-state routing. Exercise an inline step
   without Claude tool names and sequential cross-runtime handoff.
3. **Gates/advancement:** use actual orchestrator/report helpers in a temporary
   Git repo for pending, cached non-PASS, stale reports/evidence, fresh inline
   reports, and force-advance. Verify one advancement owner and preserved
   prior-step reports. Do not call SKIP a pass or DONE a clean bill of health.
4. **Helpers/reviews:** use a stub `go` to check ordinary depfix versus sync-only
   behavior, with/without vendor. Stub `claude` to verify the default review
   path and prove prompt-only mode never calls it, even when it is installed.
   Check preparation failures, both distinct prompt scopes, and explicit
   Codex verdict handling; use an agent session for instruction-level checks.
5. **End-to-end/regression:** run one representative rebase per runtime from
   the same baseline in separate disposable clones, through Step 5, without
   push/PR execution. Include Codex without subagents. Reuse the existing
   Claude single-repo test and evidence-path assertion where applicable;
   a mocked fixture is not proof that the whole rebase works.

Scan shared instructions for leftover Claude root/tool dependencies and
contradictory module commands, distinguishing Claude-only branches and quoted
evidence from actionable instructions. Run `make lint` before commits and
`make site-build` for documentation. Do not require the full matrix, new
evaluation framework, hook port, migration fixes, provider abstraction,
locking scheme, or force-advance policy changes for this compatibility work.
