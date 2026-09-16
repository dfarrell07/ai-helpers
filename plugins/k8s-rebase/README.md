# k8s-rebase

Automate Kubernetes dependency rebases for Go projects that consume
`k8s.io/*` packages.

## Usage

Install the existing package through the shared marketplace; no second
manifest or copy of the skill is needed. See the repository's
[getting started guide](../../site/docs/getting-started.md) for Claude setup.

```bash
codex plugin marketplace add openshift-eng/ai-helpers
codex plugin add k8s-rebase@ai-helpers
```

For local development, add the **ai-helpers checkout** with
`codex plugin marketplace add /absolute/path/to/ai-helpers`, then install
`k8s-rebase@ai-helpers`. Refresh the local marketplace/package after editing
and start a new session to load the changed skill. Use a clean checkout for
installation: the local installer copies the plugin directory, including
untracked test repositories and scratch data if present.

```text
Claude: /k8s-rebase:k8s-rebase [--bump-tools] <version>
Codex:  $k8s-rebase:k8s-rebase [--bump-tools] <version>
```

Start the agent session at the root of the target Go repo with `k8s.io/*`
dependencies. A per-command cwd override is not sufficient: existing hooks
locate the activation marker relative to the session cwd.
Versions may be `1.Y` or `1.Y.Z`; for example,
`$k8s-rebase:k8s-rebase 1.36.0` in Codex.

The skill creates a branch with separate commits for each step:
dependency bumps, codegen, version references, and code fixes.
No files need to be installed in the target repo — everything
runs from the plugin.

Only one session may mutate a rebase at a time. Use separate clones for
concurrent rebases; worktrees share Git hooks. Sequential handoff between
agents uses the existing `.rebase-tmp/state.json` and reports. Keep the
requested version and `--bump-tools` choice with the handoff.

### --bump-tools

Adds non-k8s version bumps on top of the core rebase. Mixing
tooling bumps into a k8s rebase PR is not ideal (harder to
review, harder to bisect), but some communities bundle them.
ovn-kubernetes-mcp in particular expects all versions to be
current when a rebase PR lands. The flag exists to match that
workflow without polluting the default path.

Script (deterministic):

- Syncs `GINKGO_VERSION` in Makefile from go.mod
- Bumps `NODE_VERSION`, `NPM_VERSION` to latest Node.js release
- Bumps `NVM_VERSION` to latest release

Agent (Step 4d, judgment-based):

- Bumps outdated non-k8s direct Go deps one at a time, checking
  that k8s pins survived each bump (reverts if MVS drifted them)

- Re-syncs `GINKGO_VERSION` in Makefile if ginkgo was bumped

All tool bump changes go in separate commits from the k8s
rebase so the rebase is cleanly bisectable.

## What it does

1. Bumps all `k8s.io/*` dependencies across every Go module
2. Runs codegen and mock regeneration
3. Updates version references in CI, scripts, and docs
4. Detects new feature gates that break fake clientsets
5. Fixes build/lint/vet errors with code-first priority
6. Validates all modules and verifies fixes via antagonistic review

## Prerequisites

- Go (any version — auto-containerizes if local Go is too old)
- `podman` (preferred) or `docker`
- `git`
- `jq` for hooks and state inspection; `envsubst` for fix-review prompts
- Claude: `claude` CLI for the existing independent review calls
- Codex: a runtime with fresh-context native reviewers for Steps 4–5
  (ordinary steps and gates can run inline). Without an independent reviewer,
  the skill stops at the review boundary; parent self-review is not equivalent.
- Review and trust the bundled hooks in Codex before starting. Installation
  alone does not activate them. Use `/hooks` to review/trust the current
  definitions; changed definitions need renewed trust. See the
  [official hook documentation](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).
  Preserve the existing safety rules even where tool hooks cannot enforce them.

The module-operation hook also blocks direct tidy/vendor in the exception
cases documented in the skill's rules. If that conflict blocks a repair,
report it rather than bypassing the hook. This compatibility change leaves
module-safety policy and commit trailers unchanged.

Focused offline checks: `python3 test/test_compatibility.py` (no models or
builds), plus `make test-version-selection` for Step 1 selection with a stubbed
proxy and Go's read-only parser.
Installed-package evidence is revision-specific: Codex CLI 0.154.0
enforced all five hooks at `258dfab8` with invocation-only trust. Codex and
Claude CLI 2.1.272 retained mixed gate outcomes in Step 5 fixtures at `fc159768`.
The current installed snapshot is `8ecfc04e`: Codex's preparation-status
success/failure rechecks pass; shared summary instructions and Claude's review
path are unchanged from `fc159768`. See the
[tracked compatibility plan](plans/claude-codex-compatibility.md)
for current candidates, exact coverage, and remaining checks.

End-to-end qualification remains blocked. Historical Codex/Claude rebases
of pinned ovn-kubernetes-mcp to 1.35.3 stopped on Step 1 dependency drift.
The Step 1 selection and Step 4 lint-scope corrections pass focused offline
checks but are not yet installed or rebase-qualified. Next: freeze/reinstall
the updated candidate and finish focused agent fixtures before qualification.
Interface and finalization fixtures do not prove a complete migration.

## Contents

| File | Purpose |
| ------ | --------- |
| `skills/k8s-rebase/SKILL.md` | Skill entry point and boot loader |
| `skills/k8s-rebase/steps/*.md` | Step definitions and shared rules (6 files) |
| `scripts/k8s-rebase-orchestrator.sh` | Step/gate state machine |
| `scripts/k8s-rebase.sh` | Mechanical rebase (deps, codegen, version refs) |
| `scripts/k8s-rebase-autofix.sh` | Applies known fix patterns with PASS/FAIL verification |
| `scripts/k8s-rebase-validate.sh` | Build/lint/vet/test across all modules |
| `scripts/k8s-rebase-review.sh` | Fix-commit review via Claude, or prompt-only preparation for Codex |
| `scripts/k8s-rebase-review-prompt.md` | Prompt template used by the antagonistic review script |
| `scripts/k8s-rebase-pr-review.sh` | Separate full-rebase pre-PR rubric and prompt preparation |
| `scripts/gate-script-lib.sh` | Shared library for gate companion scripts |
| `scripts/write-gate-report.sh` | Structured gate pass/fail report writer |
| `gates/step{1,2,3,4}-*/*.md` | Subagent verification prompts (32 files) |
| `docs/k8s-rebase-patterns.md` | Breakage patterns for k8s rebases |

## Tested against

The existing Claude rebase coverage below is not a Codex compatibility matrix.

| Repo | Modules | Features exercised |
| ------ | --------- | -------------------- |
| ovn-org/ovn-kubernetes | 3 | Codegen, vendor, conformance tests, feature gates |
| openshift/multus-cni | 1 | Vendor, Eventf vet errors, gate insertion |
| openshift/api | 1 | Vendor, codegen field removal, golangci-lint format |
| metallb/frr-k8s | 2 | No vendor, codegen, 3-version jump, transitive deps |
| kubernetes-sigs/network-policy-api | 2 | No vendor, codegen, multi-module |
| ovn-kubernetes/ovn-kubernetes-mcp | 1 | Vendor, no test-go.sh |
| openshift/ingress-node-firewall | 1 | Vendor, 4-version jump, staging deps, controller-gen, golangci-lint v1/v2 |
| openshift/cloud-network-config-controller | 1 | Vendor, library-go blocker |
| openshift/cluster-network-operator | 1 | Vendor, library-go blocker |
