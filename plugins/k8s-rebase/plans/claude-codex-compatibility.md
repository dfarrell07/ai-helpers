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
end-to-end qualified.** Template preparation, host-branch selection, checked
Codex preparation, and gate-summary closeout are complete at the scopes below.

Shared-workflow audit and installed-package status:

- `63a0a2e6` separately changed the backend to accept fresh PASS **or SKIP**.
  Offline probes confirm both advance without spending retries; FAIL,
  INCONCLUSIVE, missing reports, and stale SKIP still block. Its status table
  counts SKIP in the PASS column, so it is not an exact-verdict summary.
- The same commit changed Step 1 OpenShift/kube-openapi selection. The old
  dependency failure is historical evidence, not proof this candidate fails
  identically. Its broken OpenShift metadata parsing and unchecked fallback
  are now corrected with focused offline tests; a full Step 1 rebase remains
  unqualified. See the separate shared-workflow corrections below.
- The installed Codex package was refreshed through the existing local
  marketplace to frozen `8ecfc04e` for the final preparation-status fixtures.
  All 121 package files and executable bits match that Git snapshot. Its
  helpers, hooks, and manifest are unchanged from `adda641c`; the earlier
  installed `258dfab8` evidence is historical. The current Step 1 and Step 4
  corrections are not in that installed snapshot.
  Freeze and refresh again before qualifying the updated candidate.
- Lint discovery fixes are committed in `90b15604`, with 46 repository tests
  passing. They are separate from the compatibility implementation; the
  nested-checkout errors were not suppressed by relaxing validation criteria.

Audit through `905c86fc`: all 15 then-existing compatibility tests, seven
supplemental shell tests, eight evidence/template pairs, and strict site build
passed. The template false approvals reproduced before closeout item 1 below;
those supplemental tests detected the bugs, not certified their repair. Six backend
verdict/freshness probes and an isolated stash probe confirm the findings below.
The re-audit also reproduced the metadata-format and gate-error cases below.
Those audits launched no new live runtime qualification or real rebase.
The later routing fixtures below used Codex 0.154.0 and Claude 2.1.272;
earlier live evidence used Claude 2.1.270. Do not silently transfer results
to new code or a different runtime version. Earlier validation remains under
provenance.

Next: freeze/reinstall the corrected candidate and finish the focused agent
fixtures before the bounded qualification pair. The shared-workflow
prerequisites below pass focused checks, not a complete rebase.

### Closeout status — complete before further qualification

1. **Done — Codex template failures fail closed.**
   `scripts/k8s-rebase-review.sh` now requires a readable regular template in
   print-only mode and errors if it disappears during collection. Previously,
   a readable directory passed `-r`, and either case reached Claude's legacy
   `APPROVE: template not found, skipping` fallback. Both new regressions
   failed before the fix and pass afterward: exit 1, empty stdout, an error on
   stderr, and no reviewer invocation. The disappearance fixture moves only
   its private template during `git show`; installed sources are untouched.
   That closeout brought `test/test_compatibility.py` to 19 passing tests, including both modes
   for missing/directory/disappearing templates and Claude rendering, absent
   CLI, timeout, nonzero, and missing-verdict behavior. Baseline comparisons of
   the working-tree helper against `69ff8893` also pass. Eight evidence/template
   pairs, Bash syntax, and warning-level ShellCheck pass. No review rubric,
   Claude failure policy, installed package, or other closeout item changed.
2. **Done — Exclusive host review and checked Codex preparation.** `d0184fd5`
   selects the current parent's host branch and carries it into workers;
   cross-agent resumes use the new host. Claude retains its default nested
   helpers and infrastructure fallback; Codex requires checked preparation and
   fresh-context native review. No host flag, configuration, persisted field,
   helper, or rubric changed. The eight original routing cases establish branch
   selection, not every status-handling or delegation invariant.
   A Step 5 success wrapper still hid exit status after the prose clarification
   in `29d10807`. `8ecfc04e` makes both Codex shell examples print completion
   status while preserving the exit code. Offline execution covers both examples
   under errexit; live Step 5 success/failure exposes status 0/1 even through
   stdout-only wrappers. Failure stops before review, PR generation, and cleanup.
   The read-only worker fixture combined preparation and review in one fresh
   worker: it proves routing, not independence after worker implementation.
   Discovery and actual reviewer-absence checks remain in final qualification.
3. **Done — Exact gate/PR outcomes (`62fc6969`, `fc159768`).** Shared rules
   accept fresh justified SKIP without calling it PASS, adopting the existing
   backend policy. Step 5 inventories expected reports, retains exact verdicts,
   and discloses missing/malformed reports and stale final-step evidence.
   Prior-step PASS is historical evidence, not a final-HEAD retest. DONE,
   force-advancement, aggregate counts, and source-review approval do not upgrade
   a gate. Reports and INCOMPLETE remain untouched.
   The first Claude recheck omitted an absent earlier report; `fc159768` adds
   the short read-only inventory loop that corrected this in both hosts' PR
   commands. The fixtures include prior-step INCONCLUSIVE, absent/malformed
   reports, final-step FAIL/stale PASS, justified SKIP, and an INCOMPLETE record
   mentioning only Step 4. Both hosts disclose those outcomes without fabricating
   reports or claiming real builds. See provenance for the source revisions.
   All 25 compatibility tests pass, including verdict acceptance/freshness and
   execution of the inventory and preparation examples. The new SKIP acceptance
   regression also fails against the pre-`63a0a2e6` backend as expected.
   CI-readiness's obsolete `find` wording and README readiness claims are fixed.
   The backend, report format, gate criteria, and retry thresholds are unchanged.

Keep these corrections within existing helpers, instructions, and focused
tests. Do not add provider configuration, persistent review state, or a new
reporting framework. Re-run the smallest failing cases before escalating to
the real-rebase qualification below.

### Shared-workflow prerequisites — separate bugfix scope

These are defects in changes that landed after the compatibility candidate,
not reasons to expand the Codex interface or port the eval harness. Keep their
fixes separate and test the existing functions/instructions before a live run.

1. **Done — Step 1 OpenShift selection correction, offline scope.**
   The old minor parser extracted `0` from matching v0.35/v0.36 versions,
   missed single-line requirements, and aborted on spaced JSON. Fetch failures
   could certify unread metadata; library-go also had an unchecked fallback
   despite its [direct Kubernetes requirements](https://github.com/openshift/library-go/blob/f7fdf34b126f776c4bada841dad2d29fadbe1b9a/go.mod).
   The existing functions now parse JSON with Perl's core
   [JSON::PP](https://perldoc.perl.org/JSON%3A%3APP) (Perl is already required)
   and module requirements with
   [Go's read-only `mod edit -json`](https://go.dev/ref/mod#go-mod-edit),
   using stdin and the local toolchain without editing the target or downloading
   modules. They check api/apimachinery/client-go requirements for all four
   existing OpenShift selections, including library-go and build-machinery-go.
   Failed fetches/parses and mismatching or non-release core versions leave
   the selection unresolved; absence of direct core requirements is distinct.
   JSON::PP 4.16 drops `\u0030`; proxy metadata containing that escape is
   explicitly rejected, never silently decoded to a different version.
   Optional lookup failures remain nonfatal. If a module actually requires an
   unresolved package, command derivation stops before that module's updates;
   it does not use an unversioned fallback or claim tidy preserves an old pin.
   A 2026-09-16 audit found that this new stop bypassed the non-inherited ERR
   trap in `rebase_module`, leaving the temporary pre-push guard installed.
   The caller now handles derivation failure explicitly through the existing
   `die` helper. Four lifecycle subcases fail at `3190f558` and pass with the
   correction: unresolved versions and parser errors, each with/without a saved
   user hook. They exercise the actual caller, trap, and cleanup from a nested
   module, checking hook contents/mode, exit 1, and no dependency updates.
   Actual require entries distinguish dependencies from the module's own name,
   comments, replacements, and similarly prefixed paths. Warnings match behavior.
   `make test-version-selection` runs 12 offline tests against the actual
   functions, assignments, and module caller under `set -euo pipefail`, with
   real parsers and a stubbed proxy. Matching/mixed/wrong minors, both require
   forms, JSON whitespace, invalid/failed metadata, all four packages, and
   caller stopping are covered; module files stay unchanged. Every case rejects
   any jq invocation, covering the automatic Go image's existing tool set.
   Independent review caught a draft jq prerequisite on comment-only matches;
   the correction removes that new dependency entirely. The actual functions
   also pass in cached Go image `02e4acc4db98` (Go 1.26.7, JSON::PP 4.16), with
   jq absent, network disabled, and a read-only filesystem. This is a metadata
   smoke check, not a rebase. The earlier independent metadata-selection review
   passed all 12 tests and nine supplemental cases, including escaped-zero rejection and failing
   Go/Perl commands that emit partial or valid-looking output; logs and the
   source hash are under `.work/claude-codex-compatibility/independent-zero-recheck.Y327fO/`.
   The initial nine tests produced 32 failed subcases against the old source and passed after
   the correction. Non-OpenShift command derivation remains unchanged without
   optional metadata. This is not transitive-graph or full-rebase qualification:
   existing staging alignment and gate checks remain unchanged and must inspect
   the actual resulting versions during qualification. No new resolver,
   workflow instruction, hook, or installed package was introduced.
2. **Done — Step 4 lint scope correction, focused scope.**
   `d9f938a9` added an undefined `from_commit` and a stash/lint/pop example
   that never checks out the baseline. With a clean tree and an existing
   stash, the example pops unrelated saved work; an isolated fixture confirms
   both defects. An unchanged line also can fail against changed dependencies.
   Step 4 now uses the existing merge-base convention and a disposable clone
   only when baseline execution is needed. It checks dependency/toolchain
   context instead of treating unchanged lines as proof; failed/incomparable
   baseline runs remain inconclusive. Scope exclusions leave findings visible,
   never converting failures to PASS/SKIP. Lint and gate fixes share the existing
   three-iteration budget and blocked/force-advance protocol, with no second
   fix loop. The container-failure retry also stops rather than looping.
   A follow-up audit narrows that stop to infrastructure still preventing lint
   from completing: a completed retry with code findings returns to triage,
   not an infrastructure diagnosis based solely on nonzero exit status.
   Three added compatibility tests execute the actual shell example: main/master
   baselines, clean/dirty tracked files with a pre-existing stash, paths with
   spaces, missing baseline, and clone/checkout failures. Source files, index,
   stash/ref logs, hooks, and active reports remain byte-for-byte unchanged;
   the clone is detached at the baseline with its own Git directory.
   A fresh-context synthetic triage exercise distinguishes a dependency-induced
   failure, a reproduced pre-existing finding, and an unavailable baseline;
   it retains all three through 1/3 versus 3/3-budget handoffs without edits.
   Raw fixture: `.work/claude-codex-compatibility/step4-forward.ZjhKfO/`.
   All 28 compatibility tests, 12 Step 1 selection tests, and eight
   evidence/template pairs pass, as do repository lint, example ShellCheck,
   and strict site build. This changes existing Step 4 instructions and focused
   tests only: no new lint framework, style cleanup, gate/backend policy,
   Claude/Codex review routing, or installed-package change. The fixture does
   not qualify either installed runtime or a real rebase.

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

**Gate-summary/status closeout, 2026-09-15:** Codex CLI 0.154.0 /
`gpt-5.6-sol` (medium), Claude CLI 2.1.272 / `claude-sonnet-4-6`.
The mixed-outcome pair passed at frozen `fc159768`; the final Codex
status-success/failure pair passed at frozen `8ecfc04e`. The latter changes
only Codex preparation examples, their test, and the plan; the shared summary
instructions, helpers, and Claude review path are unchanged. All 121 current
package files and executable bits in the frozen copy, existing marketplace,
and installed Codex cache were independently checked against Git objects.
Installation used the existing CLI route, without manifest/version changes or
persistent hook trust. Claude loaded its frozen package with `--plugin-dir`.

Each case used a separate no-remote clone at `3313d47b`, local main `d619d9e2`,
target 1.36.0, tools=false, and synthetic completed state. Of 32 expected gates,
31 reports were retained: 27 PASS (including stale Step 4 cleanliness), one
justified SKIP, one INCONCLUSIVE, one FAIL, and one malformed verdict. The
Step 2 test-compilation report was absent; prior-step reports used `5983cfc`.
INCOMPLETE mentioned only Step 4. Both hosts' printed PR bodies retained the
non-PASS findings, missing/malformed reports, SKIP reason, and stale final-step
PASS without claiming real builds or turning source approval into gate approval.
Claude's command appeared before cleanup in its assistant stream, not in the
terminal result field; the actual printed body was inspected.

Claude used its default nested helper and received a real approval. Codex used
`--print-prompt` followed by a `fork_turns: none` reviewer. At `8ecfc04e`, the
model-visible tool results contain completion status 0 before the review spawn
and status 1 on failed Git evidence collection, even with stdout-only wrappers.
The failed case has no review spawn, PR command, or cleanup. Public CLI command
events can omit stdout, so the audit also correlates actual tool results by
call ID; it does not rely on the agent's final claim. All cases preserved HEAD,
state, reports, and INCOMPLETE. Healthy cleanup removed only the session marker;
the failure shim created its own fixture-local marker. Codex's broad cleanup
command was rejected in the inventory run before an exact marker deletion;
these cases do not qualify general cleanup or hook restoration.

The initial `62fc6969` Claude run omitted the missing report and selected the
byte-identical working-tree package instead of its supplied frozen copy; it is
not an installed-package pass. The `fc159768` Codex success run still hid status,
prompting the final printed-status correction. Initial `62fc6969` inputs and
traces remain under
`.work/claude-codex-compatibility/finalization-closeout-20260915.sorE67/`.
The `fc159768` inventory/status evidence is under `finalization-inventory-20260915.d2xTkx/`;
final status evidence is under `preparation-status-20260915.hM8gDP/`, each within
the same compatibility work directory, with setup/run/audit scripts and logs.
All eight bounded runs ended within five minutes; Claude parent sessions had
a $3 cap. Exact-path fixtures do not qualify discovery, unavailable reviewers,
ordinary-worker review independence, or a full rebase. Those limits remain below.

**Routing closeout, 2026-09-15:** frozen `d0184fd5`, Codex CLI 0.154.0 /
`gpt-5.6-sol` (medium), Claude CLI 2.1.272 / `claude-sonnet-4-6`. The existing
marketplace's k8s-rebase source and installed Codex cache match all 121 frozen
package files; Claude loaded the same snapshot through `--plugin-dir`.
No manifest/version change or persistent hook-trust grant was needed. Exact
hook sources were inspected before invocation-only Codex trust. The prior
marketplace package is retained locally, not deleted.

Separate no-remote clones reused the recorded review fixture, HEAD `3313d47b`
and local main `d619d9e2`; Step 5 used synthetic completed state and a retained
INCONCLUSIVE report. Both hosts selected their own Step 4/5 review path and
returned real approvals. Explicit step-worker handoffs retained that choice;
Claude's worker ran the default helper. Codex's direct review spawns used
`fork_turns: none`; preparation ran without a filtering pipeline. The Step 4
direct/failure cases checked exit status, but the Step 5 wrapper hid it by
returning only stdout; that case does not verify checked status handling.
Codex's read-only step worker prepared and reviewed evidence itself, so it
does not test a separate review after ordinary worker implementation.
With HEAD also on local main, Codex stopped on preparation
error without spawning a reviewer. A test-only timeout shim confirmed Claude's
documented fallback, clearly reported as infrastructure fallback, not real review.
Fixture code, commits, state, retained reports, and INCOMPLETE were preserved.
Each run had a five-minute cap; Claude parent runs had a $3 cap. All ended.

These are routing checks, not a new end-to-end or discovery qualification.
The initial Codex Step 4 probe selected a nearby archived package and is excluded;
rechecks supplied the exact verified installed skill path. An initial Step 5
probe was superseded by the same explicit-path setup. The attempted unavailable-
reviewer probe is also excluded: native spawn remained available despite the
CLI feature-disabling flags. Verify actual absence, not configuration intent,
when completing that existing qualification case. Do not count these fixtures
as full cleanup, gate-summary, build, or rebase qualification.

Inputs, frozen hashes, run metadata, raw traces, and invariant checks are under
`.work/claude-codex-compatibility/host-routing-20260915.uHrjlF/` (`setup.py`,
`run.py`, `audit.py`, and per-case logs). The eight counted cases are the two
`claude-step[45]` runs, two `codex-step[45]-verified-path` runs, both
`step4-worker-handoff` runs, `codex-preparation-failure`, and `claude-fallback`.
Ordinary default-helper parity against `69ff8893` also passes. The generic skill
validator still rejects the unchanged Claude frontmatter keys; repository lint
and actual runtime loading are the relevant checks, as documented above.

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
Likewise, the old shell template probe expects the false approval now fixed;
use the tracked regression tests for that case. `review-working-tree-parity.py`
reuses its Claude baseline comparisons against the working-tree helper.
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
