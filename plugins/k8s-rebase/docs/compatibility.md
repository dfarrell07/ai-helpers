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

The [offline tests](../test/test_compatibility.py) exercise the shared review,
hook, state, and cleanup contracts. Full repo/version runs use Claude Code.
Focused installed-runtime fixtures on both hosts have covered review routing
and finalization; Codex has not run a full rebase.

To qualify both hosts, run the existing `openshift/multus-cni` baseline in
[config-1.36.yaml](../test/config-1.36.yaml) on each, in disposable clones
with the same installed source and environment, including a resume at a
committed boundary. Require applicable gates to pass, justified SKIPs, actual
independent reviews, accurate final reporting, and a restored hook;
force-advancement or a review fallback does not qualify. Retain the source
revision, runtime and model, raw reports, and actual tool outcomes: an agent
declining an action is not a hook denial. Cover these cases on each host:

- Hook denials through each host's tools, with quoted paths and bad arguments.
- Interruption after Step 1's early result marker, missing or malformed state,
  and handoffs that must not duplicate work or reset retry budgets.
- Review rejection followed by repair, large payloads, missing verdicts, and
  an unavailable native reviewer.
- Cleanup failures, which must preserve the session marker and hook backup.

## Known limits

- HEAD stamps cover commits, not uncommitted edits. Hooks are heuristic,
  and Stop observes orchestrator DONE rather than Step 5 completion.
- Two informational gates always PASS; read their details. Build/vet
  evidence can contain a timeout alongside a zero error count; review command
  completion and module coverage before judging it. `go mod verify` checks
  the module cache, not vendor contents.
- Review diffs are filtered and size-limited; selected-commit review's
  root-vendor exclusion is imperfect. Preserve scope and truncation warnings.
- Commits carry a Claude Code `Assisted-by` trailer on both hosts; review
  attribution before publishing Codex-assisted work.

Run the [offline checks](../evals/README.md#choose-the-check) for shared
interfaces and follow the repository's [contribution rules](../../../CONTRIBUTING.md)
for lint, documentation builds, and versioning. Installed-runtime evidence
is still required when changing host behavior.
