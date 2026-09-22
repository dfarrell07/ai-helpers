# k8s-rebase

Automate Kubernetes minor-version rebases for Go projects: align dependencies
across modules, regenerate code, update version references, and fix build,
lint, and test breakage. A top-level state machine coordinates scripts and
agent judgment through 32 verification gates.

## Install

Claude Code:

```text
/plugin marketplace add openshift-eng/ai-helpers
/plugin install k8s-rebase@ai-helpers
```

Codex:

```bash
codex plugin marketplace add openshift-eng/ai-helpers
codex plugin add k8s-rebase@ai-helpers
```

See the [marketplace guide](../../site/docs/getting-started.md) for updates
and branch previews, and [runtime compatibility](docs/compatibility.md)
for host requirements and qualification status.

## Run

Start the agent session at the root of a clean target checkout, normally on
its default branch, with `go.mod` or `go-controller/go.mod`. Hooks use the
session cwd; changing a shell command's working directory is not sufficient.

```text
Claude Code: /k8s-rebase:k8s-rebase 1.36.2
Codex:       $k8s-rebase:k8s-rebase 1.36.2
```

Accepts `1.Y` or `1.Y.Z`; `1.Y` means `1.Y.0`. The no-op check compares
Kubernetes minors, so this workflow does not perform patch-only upgrades.

The skill creates a rebase branch and separate commits for dependencies,
codegen, version references, and fixes. Four gated steps lead to final
review and a printed `gh pr create` command; the skill does not publish.
After bounded repairs, Steps 2–4 can advance with unresolved checks.
Those findings remain in the PR body: DONE is not an all-checks-passed claim.

### Optional tooling updates

Add `--bump-tools` before the version to include non-Kubernetes updates in
separate commits. Where present, the script syncs `GINKGO_VERSION` from
go.mod and updates `NODE_VERSION`, `NPM_VERSION`, and `NVM_VERSION`.
Step 4d updates non-k8s direct Go dependencies individually, preserving
Kubernetes pins and skipping replacements and commit-pinned dependencies.
Omit the flag for the core rebase scope.

### Resume

Use one mutating session per checkout and separate clones for concurrent
rebases; worktrees share Git hooks. Resume on the same branch with the same
version and tools flag. Preserve `.rebase-tmp/`: the skill resumes from
`state.json` and retained reports. The tools flag is not stored in that file.
If state is missing or conflicts with the request, preserve the artifacts
and resolve recovery before restarting.

## Prerequisites

- Bash with associative arrays, GNU command-line tools, Git, Make, Go,
  curl, Perl with `JSON::PP`, `jq`, and `envsubst`.
- `podman` (preferred) or `docker` for toolchain/lint containers. The rebase
  auto-containerizes if local Go is too old. Network access is needed for
  dependencies, release metadata, and images; `gh` is used for GitHub lookups.
- Claude Code uses the `claude` CLI for independent reviews. Codex requires
  fresh-context native reviewers in Steps 4–5 and stops if unavailable.
- In Codex, review and trust the installed hooks through `/hooks` before
  starting; changed definitions need renewed trust. See the
  [hook documentation](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).

The module-operation hook currently blocks direct tidy/vendor even in the
shared rules' repair exceptions. Report that conflict rather than bypassing it.

## Development and coverage

The configs cover six repositories across Kubernetes 1.34.1, 1.35.3, and
1.36.2, with 16 cases; two 1.34 combinations are absent. See the
[coverage table](evals/README.md#coverage) for exact cases and references.

| Read | Purpose |
| --- | --- |
| [Workflow design](docs/design.md) | State machine, reward-hacking resistance, evidence, and review boundaries |
| [Skill entry point](skills/k8s-rebase/SKILL.md) | Executable instructions, step routing, and recovery |
| [Breakage patterns](docs/k8s-rebase-patterns.md) | Reusable migration knowledge and extension guidance |
| [Testing and evals](evals/README.md) | Offline checks, mutation tests, court, and scoring limits |

For local installation, register a clean **ai-helpers checkout** as the
marketplace root. Installers may copy scratch data and nested test clones
from a development checkout. Reinstall the package and start a new session
after edits. Follow the repository's [contribution rules](../../CONTRIBUTING.md)
for review checks and versioning.
