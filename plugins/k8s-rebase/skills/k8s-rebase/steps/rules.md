<!-- markdownlint-disable MD013 -->
# Rebase Rules

Read this file at the start of every step.

## Runtime context

Use the absolute plugin root derived from the loaded skill, target repo root,
requested version, and tools flag supplied by the caller. Bind the variables
needed by each shell example in that command call; prior exports and cwd
changes are not a contract. Run repo-level commands at `REPO_ROOT`, and
module-local operations in their module. Keep the session itself rooted at
the checkout so the existing hook guards remain active.

## Scope

Every change must be required by the requested rebase: dependency alignment, codegen,
version references, or a compatibility/build/vet/lint/test fix caused by the
bump. A compile-clean file can still need a behavioral or CI fix. Broader
tooling updates require `--bump-tools`. Do not refactor, add features, or fix
unrelated debt. Keep each repair at the cited issue and location.

Preserve behavior: never replace label selectors with
`reflect.DeepEqual`, never change security flag defaults.
Preserve nil semantics: `*int32` nil means "server default",
`int32` zero means "set to 0" — use `ptr.To[int32](val)`.
Adapt type signatures without altering surrounding logic.
Verify the issue against base, including its dependencies and configuration;
unchanged source alone does not establish that a failure is pre-existing:
`git show $(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main):<file>`

Do not add struct tags (like omitempty), merge functions, rename
interfaces, or restructure packages.

## Module Safety

NEVER run `go mod tidy`, `go get`, `go mod vendor`, `go mod edit`,
`go generate`, or `go run` directly: they can move Kubernetes pins through
MVS. Allowed: `go build`, `go vet`, `go test` (with `-mod=vendor` if vendor/
exists), `go mod verify`, `go doc`, `go install <tool>@<version>`,
`go clean -cache`.

Module repairs use `scripts/k8s-rebase-depfix.sh` in each affected module:
`<module>@<version>` bumps one dependency; `--sync` tidies (and vendors, when
vendor/ exists) after you add a `replace`. Both modes synchronize the module,
so do not repeat it. Verify Kubernetes pins afterward; the helper does not.

Prepend this rule to every gate subagent prompt. Suggested fix commands in
a gate report do not expand these permissions. The module-operation hook
enforces the direct-command ban; never disguise a command to bypass it.

## Never Push

NEVER run `git push` or `gh pr create`. Only print commands for
the user to copy-paste.

## Verdicts

Each gate report carries exactly one verdict:

| Verdict | Meaning | Normal advancement |
| --- | --- | --- |
| PASS | The check ran to completion and found no new issues | Accepted when fresh |
| SKIP | The check does not apply to this repo; the summary says why | Accepted when fresh |
| FAIL | The check found new issues | Blocks |
| INCONCLUSIVE | The check applies but could not be completed or attributed | Blocks |

A check that did not run is INCONCLUSIVE, never PASS or SKIP: missing
coverage is not a zero count. Pre-existing findings are INFO, not FAIL.
The informational commit-messages and skill-improvement gates always PASS
and carry their findings in DETAILS. Never relabel a SKIP as PASS.
Include this section in every gate reviewer's context.

## Gate-Fix Loop

1. Run `bash "$PLUGIN_ROOT/scripts/k8s-rebase-orchestrator.sh" gates "$REPO_ROOT" <step>`.
   It executes companions and identifies PENDING reviews. Exit 1 with normal
   PENDING output means judgments remain; unexpected errors stop the caller.
   Exit 0 means none pending, not all passed: inspect EXISTING and RESOLVED
   verdicts too. Read exact reports; the status table counts SKIP under PASS.
2. Read each pending prompt and its evidence. Check evidence HEAD against
   the current commit; missing/stale evidence after a companion crash is not
   usable. Gather fresh read-only evidence as that prompt permits, or report
   inability to judge. Use a native gate worker when available, otherwise
   review inline under the same read-only constraints.
3. Write reports through `scripts/write-gate-report.sh` at the known plugin
   root. Confirm HEAD has not changed during review before it stamps the
   report. Choose one actual verdict; `PASS|FAIL` is notation, not a
   shell pipeline. A missing helper is an error, not grounds to fabricate
   an unstamped report.
4. Triage findings against base under Scope, fix in-scope issues, and commit
   before refreshing evidence. Re-validate as the step requires (`--quick` in 2–3,
   `--no-test` in 4), then run `gates` again. Every current-step report at the
   old HEAD is stale, including PASS reports: complete all newly pending
   reviews, not just the previously failing ones.
5. If a cached report needs deliberate invalidation at the **same HEAD**,
   remove only that current-step report **before** rerunning `gates`.
   Never delete a newly regenerated companion report or prior-step reports.

Use each gate's rubric for its verdict and issue count. Preserve out-of-scope
findings in report details; deciding not to fix them does not itself make a
failed check pass.

Repeat fixes/reviews up to 3 iterations, sharing this budget across workers
and parent; do not nest another retry loop at handoff. Preserve the step's
stop condition (Step 1 structural failure stops). The parent alone calls
`advance` and handles its retry/force-advance output as in SKILL.md. Workers
return verdicts, unresolved issues, and attempts already used. Never call a
gate passed until a fresh report says PASS or spend advances as status polls.
For Steps 2–4 only, if the fix budget is exhausted, the parent may retry a
BLOCKED handoff to reach the existing force-advance threshold. Step 1
structural failures must not call `advance`, even to record the failure.
Do not add another fix loop, overwrite non-PASS findings, or retry after
state has already advanced.

## Never Add Test Skips

If a test fails, fix the root cause. Adding `t.Skip()` hides
real issues. If pre-existing, note in the commit message but
do not skip it.

## Commits and Git

- Body lines <= 72 chars.
- Each commit gets exactly one `Signed-off-by` and one
  `Assisted-by: Claude Code <noreply@anthropic.com>` trailer
  (scripts add automatically).

- Do not amend — create new commits on top.
- No `org/repo#N` in commit messages.
- If adding a `replace` directive, add a TODO comment.
- One commit per distinct fix. Don't bundle unrelated changes.
- Each commit should compile independently (`go build ./...`).
- Read CONTRIBUTING.md for the project's commit prefix convention.
  Use specific sub-component names matching the code you changed
  (e.g., `e2e:`, `hybrid-overlay:`).

## Container Commands

Prefer `podman` with `--userns=keep-id --security-opt label=disable`.
Tell subagents to use `podman run --userns=keep-id` with the
golang container if they need Go tools.

## Feature Gates

SetFromMap validates parent-dep consistency. ALL gates must go in
SetFromMap AND env vars. The autofix script handles this; do not
remove gates from its SetFromMap.

## Execution and reviewer roles

- Report specific counts, not just "looks good."
- Judgment agents must cite the specific file:line or diff hunk
  for each concern — "no issues found" requires listing what was
  actually checked.

- Gate subagents are read-only — they must NOT edit repo files.
  Their sole permitted write is their gate report file under
  `.rebase-tmp/gates/`. The main agent applies fixes.

- If ANY judgment agent flags a concern, the main agent MUST
  investigate and either fix it or explain why it's not an issue.

- Use native workers when available; ordinary steps, investigations, tests,
  type-conversion checks, and gates can run inline otherwise. The parent may
  read gate prompts. Independent review in Steps 4–5 is different: Codex
  needs a fresh-context read-only reviewer with rubric/evidence, not the
  parent's reasoning history. Stop at that boundary if none is available.
- **Companion gate scripts:** Let `gates` run the adjacent `.sh` files;
  do not launch them directly. Current collectors write evidence, not
  verdicts. A successful collector exit still requires gate review.

- **Long-running commands:** Use the runtime's supported process/session
  mechanism and wait for actual completion before dependent work. Preserve
  logs and recovery information; a single "still running" check or an early
  result file does not establish completion. Do not launch the same work twice.
  Keep the user informed while work runs; stop and report genuine blockers.

## OCP Version Mapping

k8s 1.N maps to OCP as follows:

- k8s <= 1.35: OCP 4.(N-13) — e.g., 1.34 -> 4.21, 1.35 -> 4.22
- k8s >= 1.36: OCP 5.(N-36) — e.g., 1.36 -> 5.0, 1.37 -> 5.1

Use `release-5.X` branches and `openshift-5.X` in CI image refs
for k8s >= 1.36. Do NOT escalate to a newer release branch to fix
dependency conflicts — find newer commits on the CORRECT branch.
Read the OCP version from `.ci-operator.yaml` or Dockerfiles to
confirm (`grep -rn 'openshift-[0-9]' .`).
