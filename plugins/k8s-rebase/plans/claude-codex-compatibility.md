# Claude/Codex Compatibility Plan

## Goal

Make the existing `k8s-rebase` skill usable by both agents without duplicating
the workflow or redesigning rebases. Keep one plugin package, one
`SKILL.md`, and the shared scripts, step files, gates, and reports.

Changes are limited to invocation/instruction compatibility, independent-review
handoff, existing hook input formats, documentation, and focused validation.
Only one session may mutate a rebase at a time. Use separate clones for
concurrent checks: worktrees share Git hooks, so they are not fully isolated.

This is the canonical tracked compatibility plan, including audit findings,
validation results, and remaining work. It supersedes compatibility planning
notes in `.work/claude-codex-compatibility/`; raw logs and disposable fixtures
remain there as local evidence, not prerequisites for understanding this plan.
Unrelated eval and observability plans remain separate.

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

### Implementation status — 2026-09-15

Shared instructions, gate handoffs, review preparation, and vendor-patch input
support are implemented. Step 5's existing rubric was extracted into the small
`scripts/k8s-rebase-pr-review.sh` helper. No new package, provider configuration,
or attribution change is needed. This plugin is new relative to `origin/main`,
so its initial version remains 0.0.1. **Installed and interface-tested, not
end-to-end qualified.** The three behavioral closeout items below remain open.

Current-source review at `35beb078` changes the previous assessment:

- `63a0a2e6` separately changed the backend to accept fresh PASS **or SKIP**.
  Offline probes confirm both advance without spending retries; FAIL,
  INCONCLUSIVE, missing reports, and stale SKIP still block. Its status table
  counts SKIP in the PASS column, so it is not an exact-verdict summary.
- The same commit changed Step 1 OpenShift/kube-openapi selection. The old
  dependency failure is historical evidence, not proof this candidate fails
  identically. However, its new minor parser rejects even matching versions;
  the dependency fix is not complete or requalified. See the separate
  shared-workflow prerequisites below, including the new Step 4 scope rule.
- The installed Codex package still matches `258dfab8`, **not current source**:
  the orchestrator, mechanical rebase script, and Step 4 instructions differ.
  The review helpers, hooks, gate prompts, and compatibility tests are unchanged.
  Refresh a frozen package before any new installed-agent qualification.
- Lint discovery fixes are committed in `90b15604`, with 46 repository tests
  passing. They are separate from the compatibility implementation; the
  nested-checkout errors were not suppressed by relaxing validation criteria.

Rechecked through `905c86fc` (runtime sources unchanged): all 15 offline
compatibility tests, seven supplemental shell tests, eight evidence/template
pairs, and strict site build pass. The template false approvals still reproduce;
those supplemental tests detect the bugs, not certify their repair. Six backend
verdict/freshness probes and an isolated stash probe confirm the findings below.
The re-audit also reproduced the metadata-format and gate-error cases below.
No new live runtime qualification or real rebase was launched.
Codex remains 0.154.0; installed Claude is now 2.1.271, whereas the recorded
live evidence used 2.1.270. Do not silently transfer those results to new code
or a different runtime version. Earlier validation is retained under provenance.

Next: close the small interface defects, resolve the two separately introduced
shared-workflow defects, then freeze/reinstall and run focused agent fixtures
before the bounded qualification pair. Do not start another full rebase to
rediscover the already-reproduced failures.

### Remaining closeout — do before further qualification

1. **P2 — Fail closed on every Codex template failure.** In
   `scripts/k8s-rebase-review.sh`, the early `-r` check accepts a readable
   directory; the later missing-file fallback then returns exit 0 and
   `APPROVE: template not found, skipping` in `--print-prompt` mode. A valid
   template disappearing during evidence collection reaches the same fallback.
   Require a readable regular file and make the later fallback an error for
   print-only mode, preserving default Claude behavior. Add both regression
   cases to `test/test_compatibility.py`: nonzero exit, no approval or populated
   prompt, and no model invocation. The existing initially-missing-file test
   does not cover these cases.
   Run the corresponding default-Claude cases too: its existing fallback
   behavior must remain unchanged. Include baseline comparisons for rendering
   failure, unavailable CLI, and timeout/nonzero/missing-verdict outcomes.

   Reproduce without changing installed sources: create a disposable Git repo
   with an empty `main` commit and a child commit on a fix branch; copy the
   review script into an isolated scripts directory, then create a directory
   named `k8s-rebase-review-prompt.md` beside it. From that repo, run the copy
   with `--print-prompt HEAD context`. For the disappearing-file case, start
   with the real template and use a test-only Git shim to move it aside when
   collecting `git show` evidence. Both currently produce the false approval.
2. **P2 — Make review branches exclusive to the host runtime.** Two live
   Claude sessions followed Step 5's Codex `--print-prompt`/native `Agent`
   branch rather than the prescribed default helper/nested `claude -p` path.
   This repeated with byte-identical sources at a neutral installation path.
   The first also piped preparation through `head -100` without pipefail.
   Make the runtime choice explicit in `SKILL.md` and Step 4/5 instructions;
   carry the parent's host-runtime identity into delegated step instructions.
   Scope the missing-reviewer hard stop to Codex; do not let the bootstrap's
   generic stop wording override Claude's retained infrastructure fallback.
   Do not infer it from the plugin path, model vendor, or installed CLI names.
   Re-run installed-agent fixtures and verify actual tool calls, including
   direct preparation exit-status handling. Default-helper parity tests pass;
   they do not establish that Claude selects that helper path.
3. **Align gate handling and PR claims with retained verdicts.** One Claude
   PR body said
   `Gates passed: dep-release-notes (step 3)` while also listing that gate as
   INCONCLUSIVE. The report stayed INCONCLUSIVE throughout. This is an observed
   output failure, not a proven new deterministic regression. Require each
   claimed PASS in the final body to agree with its retained report; review
   approval, DONE, and force-advancement do not turn another gate into PASS.
   Update `steps/rules.md` to recognize a justified fresh SKIP as accepted,
   without retrying it or calling it PASS. Inspect exact reports, not the
   backend's PASS aggregate; keep FAIL/INCONCLUSIVE unresolved. This adopts
   `63a0a2e6`, not a further gate-policy change.
   Compare reports with the existing gate inventory too: absent/unusable
   prior-step reports are unverified, not PASS. A later force-advance can
   overwrite the only INCOMPLETE record mentioning an earlier missing report.
   Repeat the synthetic finalization fixture with a prior-step INCONCLUSIVE,
   an absent earlier report, a final-step FAIL, a legitimate SKIP, and an
   INCOMPLETE record for only the final step. Assert exact verdicts and missing
   checks in both outputs; do not manufacture replacement reports. Prior-step
   PASS remains evidence at its recorded SHA, not proof of retesting final HEAD.
   Add offline PASS/SKIP acceptance and blocking/freshness regressions to the
   existing suite. In the same documentation pass, correct `ci-readiness.md`'s
   leftover `find` wording without changing its missing-document NOTE/skip
   policy, and refresh README readiness claims to name the tested candidate.

Keep these corrections within existing helpers, instructions, and focused
tests. Do not add provider configuration, persistent review state, or a new
reporting framework. Re-run the smallest failing cases before escalating to
the real-rebase qualification below.

### Shared-workflow prerequisites — separate bugfix scope

These are defects in changes that landed after the compatibility candidate,
not reasons to expand the Codex interface or port the eval harness. Keep their
fixes separate and test the existing functions/instructions before a live run.

1. **Finish the existing Step 1 version-selection correction.**
   `_validate_openshift_k8s_minor` extracts `0` from both `v0.35.3` and
   `v0.36.2`, rejecting a matching release-branch version as a mismatch.
   Stubbed-proxy probes reproduce this for targets 35 and 36. A real matching
   example is openshift/api `v0.0.0-20260904224155-42fb550ea02a` from
   release-4.22: its module requires k8s.io/api v0.35.1.
   Also, the claim that library-go does not pin Kubernetes is false:
   [library-go's module at f7fdf34b126f](https://github.com/openshift/library-go/blob/f7fdf34b126f776c4bada841dad2d29fadbe1b9a/go.mod)
   directly requires api/apimachinery/client-go v0.36.2. Its unvalidated
   upgrade fallback can reintroduce drift. Skipping a direct api/client-go
   update alone does not freeze the transitive graph.
   Correct the parser and the existing unsafe version-selection assumptions,
   including warnings that still say `@latest` when the update is skipped.
   Test the existing assignments under `set -euo pipefail`, using stubbed
   proxy responses and captured Go commands: matching/mismatching minors,
   missing/malformed metadata, and library-go fallback. Include valid JSON
   whitespace and both block/single-line `require` forms: current code exits 1
   on spaced JSON and accepts a wrong-minor single-line requirement. Preserve
   version-only stdout and distinguish parse/fetch failure from no dependency.
   A repo without these OpenShift modules must not acquire a new prerequisite
   on their optional metadata lookups; compare its derived commands unchanged.
   Retain compatible existing dependencies or report inability to resolve;
   do not silently claim an unvalidated version is safe. Verify the resulting
   staging-module minor with existing checks; do not build a new resolver.
2. **Make the new Step 4 lint scope check safe and meaningful.**
   `d9f938a9` added an undefined `from_commit` and a stash/lint/pop example
   that never checks out the baseline. With a clean tree and an existing
   stash, the example pops unrelated saved work; an isolated fixture confirms
   both defects. An unchanged line also can fail against changed dependencies.
   Use the existing merge-base convention; compare baseline diagnostics with
   the relevant lint command/toolchain in a separate disposable clone only
   when needed, preserving the active tree and stash stack. Keep the intended
   ban on unrelated cleanup. Reconcile
   `repeat until --no-test exits 0` with the shared bounded retry policy:
   unresolved/pre-existing failures must be reported, not hidden or fixed
   outside scope. Check pre-existing versus dependency-induced findings and
   stash preservation; no new lint framework or general style cleanup.

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
or permissions. The generic skill validator rejects the Claude-specific fields;
that does not invalidate the actual loader test or justify removing them.
Do not add another manifest, marketplace, skill copy, or
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
2. Run `gates` to execute companions and discover pending work. Exit 1 with
   complete normal PENDING output means reviews remain. Unexpected errors stop the
   caller: an inaccessible repo also returns 1, without gate output. Successful
   exit 0 means no pending work, not all verdicts passed. Inspect cached
   EXISTING/RESOLVED verdicts too.
   Fresh PASS and justified SKIP satisfy advancement; retain SKIP as SKIP,
   not PASS. FAIL and INCONCLUSIVE need triage, not automatic success.
   `status` currently aggregates SKIP under PASS; reports retain the truth.
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

Match the current backend (including `63a0a2e6`); do not change the
orchestrator, gate names, report schema, freshness checks, or retry thresholds
to implement these caller corrections.

### 3. Adapt independent reviews and existing hook inputs

#### Independent review

Keep Claude's current nested review path and its existing verdict format.
Choose exactly one branch by the current host runtime: Claude uses the default
helper/nested CLI; Codex uses print-only preparation and a native reviewer.
For Codex, use a fresh-context, read-only native reviewer, supplied with the
review rubric and evidence rather than the parent's reasoning history.
A parent self-check is not an independent review. Codex stops when that reviewer
is unavailable. Claude retains its existing nested-CLI failure policy; it must
not acquire a requirement for native reviewers or Codex's stricter fallback.

Keep the two existing review scopes distinct:

- **Step 4:** Retain the implemented `--print-prompt` mode in
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
and hook trust mode. Build the local marketplace from tracked files at that
revision, excluding `.work/`, outputs, and nested agent worktrees. Refresh via
the existing install route, verify loaded paths/content against that revision,
and inspect the effective hook definitions before trusting them. Do not edit
the installed cache or test the stale `258dfab8` package as current source.
Keep logs, reviewed SHAs/scopes, reports, and outcomes in
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
- Exercise ordinary inline fallback, long-running command completion, resume,
  cached exact verdicts, stale reports, and FORCE_ADVANCE handoff. Resume cases
  include version mismatch, completed state, and missing/malformed state with
  artifacts: refuse init and preserve reports, evidence, counters, and INCOMPLETE
  in the invalid-state cases. Check gate-command errors separately from PENDING.
  Use a harmless companion to verify same-HEAD invalidation precedes regeneration
  and never deletes its newly generated report. Assert no duplicate advancement
  or deletion of prior-step reports. Cover sequential cross-agent
  handoffs in fixtures at both a blocked Step 1 and a successful committed
  boundary; only the blocked handoffs have been recorded so far. Step 1
  structural failures must stop without advancement.
  Extend the delayed Step 1 stand-in to actual session interruption/resume:
  an early result marker must not trigger dependent work or a second launch.
  Distinguish a surviving child from a terminated/failed one before recovery;
  preserve failure artifacts and check hook lifecycle without a real rebase.
- Test both review preparations and APPROVE/REJECT/missing-verdict outcomes:
  Codex stops without an independent reviewer; Claude keeps its existing
  default-helper outcomes, including infrastructure fallbacks.
  Cover invalid commit/base references, failed evidence commands, and valid
  empty filtered diffs, plus both template failures in the closeout list.
  Failed collection must never yield successful Codex
  preparation or reach the reviewer as if evidence were complete.
  Prove the Codex path never invokes Claude and the Claude path still does,
  including actual agent branch selection, not just direct helper tests.
  Verify Step 5 retains its separate rubric and that every final PR verdict
  claim agrees with the retained report, including unresolved or missing checks
  in prior steps. Require real review approval for qualification even though
  Claude's runtime retains its existing fallback policy.
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
passing, legitimate inapplicable gates recorded as SKIP, and independent
reviews completed, without compatibility-related manual rescue. Different
valid fixes are acceptable. Verify existing trailers,
printed-only push/PR commands, accurate final verdict claims, retained reports,
and pre-push-hook restoration. Keep the two full runs agent-specific;
cross-agent handoff checks can use the focused fixtures above.
Force-advanced completion proves traversal, not an all-gates-passing rebase;
missing reviewers, prerequisites, or remaining workflow coverage mean unqualified.

The full multi-repository Claude harness/matrix is not a prerequisite for
this compatibility change. A metadata check or single passing gate is also
not evidence that the complete workflow works.

## Validation provenance and limits

The 2026-09-14 audit covered `69ff8893` through `38e6f58c`: all 32 gate criteria,
fix guidance, and read-only rules were preserved after path substitutions.
All 32 report examples passed filename/schema checks; stale-HEAD and missing
helper checks passed. Eight companions and three backend/interface scripts
were byte-identical to baseline at that tip. Seven additional shell probes
covered Claude default-path parity, immutable evidence, hook payloads, and
template failure. That backend-parity claim predates `63a0a2e6`.

The earlier `forward-test/` exercise already checked malformed/orphan state,
early-marker waiting, stale evidence, inline gates, and force-advance mechanics.
It used lightweight scripts and agent-led decisions, not both installed hosts
or an actual session interruption. Reuse that evidence at its stated scope;
the targeted fixtures above close the remaining gaps without a second framework.

Recorded compatibility implementations: `a497f9d6` (interfaces), `d21f971c` (shared
workflow), and `258dfab8` (Step 1 stopping). The clean local marketplace and
installed Codex package matched `258dfab8` byte-for-byte, not the later shared
workflow changes. All probes below have ended; none pushed or created a PR.

- **Installed interfaces:** Codex CLI 0.154.0 discovered the existing package,
  skill metadata, and five hooks. Actual tool denials covered vendor edits,
  module commands, push/PR commands, prior-report deletion, and Stop. Trust
  was invocation-only after inspecting exact definitions, not a persisted
  grant. A subdirectory-started session refused before init even though shell
  commands could override their workdir.
- **Real Step 1 probes:** Codex CLI 0.154.0 / `gpt-6-astra` and Claude CLI
  2.1.270 / `claude-sonnet-4-6`, target 1.35.3, tools=false, 20-minute caps,
  GOMAXPROCS=2 and GOFLAGS=-p=2. The first historical-default-branch pair was
  invalidated by an upstream fast-forward. The corrected ovn-kubernetes-mcp
  pair started detached with local main pinned to
  `36ac87c1aec7bc8f62e47ecbe161a1c972945773`; both scripts exited 1 before
  commits after dependency drift and missing `scheduling/v1alpha1`. Module
  edits and FAIL reports were preserved. After the Step 1 clarification,
  same-agent resumes and both cross-agent directions stopped without further
  advancement or file changes. This is blocked recovery, not a successful
  rebase or successful-step handoff.
- **Review-only fixture:** Both agents rejected deletion of diagnostic output
  at `cd2c996e4811c46d476f44cc6fe05be410dbd760`, approved explicit discarding
  of best-effort write results at `3313d47b4b1a303866859296bb80eb8a19b5ac53`,
  and approved the separate full-range source review from
  `d619d9e2f0d53f24a9d3bd59b1d7680b24a70430` to that latter tip, target 1.36.0.
  Codex's three reviewers used actual `fork_turns: none`; Claude's direct
  nested helpers returned real verdicts, not infrastructure fallbacks.
  No builds or rebase initialization were part of this fixture.
- **Finalization fixture:** Separate no-remote clones of that review fixture,
  seeded with synthetic Step 5 state, INCONCLUSIVE/FAIL reports, a Step 4
  force-advance record, and a pre-push-hook backup. Codex used a fresh-context
  native reviewer and completed truthful finalization. Both Claude sessions
  completed cleanup with real source-review approvals, but failed the routing
  check; the neutral-path run also failed PR-summary accuracy. Each run had a
  five-minute cap; Claude had a $3 API-cost cap. Code, commits, state, reports,
  and INCOMPLETE were preserved; temporary logs/PIDs were cleaned and the
  original executable hook restored. Source review did not validate Go 1.23.0
  against the fixture's k8s.io/api v0.36.0 dependency or establish a real build.

Finalization sessions: Codex `01a0a0be-7186-7112-bd35-c5bc3eaf3fbf`;
Claude `107471db-1ae3-4d10-a841-679583c5ab1c` and neutral-path Claude
`d2090060-a645-44b5-82fe-bd6c2422dced`. Models/runtimes match those above.

Local evidence under `.work/claude-codex-compatibility/` includes
`RESULTS.md`, `DEEP-REVIEW.md`, `audit-shell-2/`, `audit-gates-2/`,
`forward-test/`, `hook-smoke.jsonl`, `subdirectory-smoke.jsonl`,
`rebase-*-pinned.jsonl`, `resume-*.jsonl`, `handoff-*.jsonl`,
`native-review.jsonl`, `claude-review-*.log`, and `finalization-*.jsonl`.
The current-backend and stash probes are in `recheck-20260915.py`; the later
missing-report overwrite probe is in `recheck-missing-reports-20260915.py`. The old
`audit-gates-2/audit.py` pins its source comparison to `38e6f58c` and expects
SKIP to block; do not reuse it unchanged as current-candidate qualification.
Earlier root test output and superseded draft plans were archived, not deleted,
under `cleanup-20260914.EzzsOQ/`. Its completed Claude multus 1.35.3 run is
historical coverage, not the planned matched 1.36.2 qualification pair.

## Scope boundaries and existing limitations

Compatibility work must not redesign Kubernetes/OCP migration logic, fix
patterns, gate criteria, force-advance policy, or commit attribution. The
two bounded shared-workflow corrections above belong in separate bugfixes;
they are not permission to expand the updater or validation policies.
Do not add package duplication, provider persistence/configuration, new
monitoring, or another hook system.

Preserve module-safety rules and their documented exceptions. There is an
existing conflict: `rules.md` permits tidy/vendor after certain replace or
dependency updates, while the module-operation hook blocks direct calls.
Record that separately; do not silently erase exceptions, conceal commands
in prose, or invent repair wrappers in this work. If it blocks a smoke run,
report the blocker rather than relaxing policy to obtain a pass.

Other demonstrated existing issues remain separate from compatibility fixes:

- Step 1's version rubric counts all k8s.io modules at the target minor,
  while the mechanical script treats utils/klog/kube-openapi/gengo as
  independently versioned. The recorded Codex report counted those literally;
  an archived Claude report excepted them. Do not silently change this gate's
  criteria to obtain qualification.
- The former SKIP advancement defect is fixed in `63a0a2e6`; preserve that
  behavior. Feature-gate companion/manual paths still differ on whether no
  wiring is PASS or SKIP. Both are now accepted; reconciling those criteria
  is not required to adapt callers or report their actual verdicts.
- A vet timeout can produce fresh `0 build/vet errors` evidence alongside
  VET_TIMEOUT/crash metadata; the unchanged build-vet rubric can mistakenly
  PASS it. A passing evidence-schema test does not validate that judgment.
- Selected-commit review's existing root-vendor exclusion is imperfect.
  The unchanged push-hook regex can also reject harmless reads mentioning
  a hook filename; the finalization fixture reproduced this without disabling
  the guard. Hooks are guardrails, not a complete enforcement boundary.

These findings limit readiness claims, not the scope of authorized fixes.
If they prevent qualification after compatibility closeout, report the blocker
and seek separate direction rather than redesigning migrations or gate policy.
