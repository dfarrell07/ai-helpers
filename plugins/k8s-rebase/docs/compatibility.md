# Runtime compatibility

Claude Code and Codex share one plugin, skill, orchestrator, and report
format. The [skill](../skills/k8s-rebase/SKILL.md) defines the execution
contract; the [design guide](design.md) explains its boundaries.

## Review and hook requirements

Ordinary step work and gates can run inline or use native workers. The
independent reviews in [Step 4](../skills/k8s-rebase/steps/step4-verification.md)
and [Step 5](../skills/k8s-rebase/steps/step5-pr.md) have different host routes:

| Host | Review route | Infrastructure failure |
| --- | --- | --- |
| Claude Code | Helpers invoke a separate `claude` process | Existing fallback permits continuation; this is not completed independent review |
| Codex | Helpers prepare a prompt with `--print-prompt`; a fresh-context native reviewer reads it | Failed preparation, unavailable reviewer, or missing/malformed verdict stops the path |

Use the parent session's host, including after a handoff. A model vendor or
installed CLI does not select the route. Approval applies only to the
reviewed revision and scope; it does not change gate verdicts.

Hooks activate through `.rebase-tmp/.session-active` relative to the
session cwd. Start at the target checkout root, use separate clones for
concurrent rebases, and retain the marker until cleanup succeeds.
Codex requires review and trust of the installed hook definitions through
`/hooks`; see the [hook documentation](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).
Installation alone is not proof that hooks are active.

## Qualification status

The 2026-09-17 compatibility audit recorded passing offline checks and
installed review/finalization fixtures on both hosts. Its package snapshot
was SHA-256 `f1312236c0bb2d9d32f64e717c2e8fb4b6eb163f34dddedb1f87a37980b32ced`,
using Codex CLI 0.154.0 and Claude CLI 2.1.274. Those focused fixtures did
not perform a full rebase. They do not qualify the shared workflow end to
end on both hosts or replace the separate Claude repo/version coverage.
Claude fixtures still showed inaccurate final prose and incomplete failure
handling during cleanup despite correct artifacts on the successful path.

To extend qualification, test the installed candidate in disposable clones
and retain the source revision, loaded package, runtime/model, raw reports,
and actual tool outcomes. An agent declining an action is not a hook denial.
Remaining cases include:

- Hook activation from the session cwd, quoted paths, invalid arguments,
  and actual denials through each host's tools.
- Interruption after Step 1's early result marker, missing/malformed state,
  and committed handoffs without duplicate work or reset retry budgets.
- Both review scopes: rejection followed by repair, large payloads,
  missing verdicts, and unavailable native reviewers.
- Final claims checked against every expected report; cleanup failures
  must preserve the session marker and original hook restoration data.

Use the existing `openshift/multus-cni` baseline in
[config-1.36.yaml](../test/config-1.36.yaml) for a full comparison on both
hosts, with the same installed source and environment. Include a resume at
a committed boundary. Require applicable gates to pass, justified SKIPs,
actual independent reviews, accurate final reporting, and restored hooks.
Force-advancement or a review fallback does not satisfy that qualification.

## Known limits

- The module-operation hook blocks direct tidy/vendor even where the
  shared rules allow a repair exception. Report the conflict; do not bypass it.
- HEAD stamps cover commits, not uncommitted edits. Hooks are heuristic,
  and Stop observes orchestrator DONE rather than Step 5 completion.
- Some rubrics allow informational or degraded PASS results. A build/vet
  timeout can escape error-text counting, and `go mod verify` checks the
  module cache, not vendor contents. Read the command outcomes and details.
- Feature-gate evidence and manual review can disagree on PASS versus SKIP
  when no wiring applies. Preserve the actual verdict and its explanation.
- Review diffs are filtered and size-limited; selected-commit review's
  root-vendor exclusion is imperfect. Preserve scope and truncation warnings.

Run the [offline checks](../evals/README.md#choose-the-check) for shared
interfaces and follow the repository's [contribution rules](../../../CONTRIBUTING.md)
for lint, documentation builds, and versioning. Installed-runtime evidence
is still required when changing host behavior.
