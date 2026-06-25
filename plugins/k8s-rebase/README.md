# k8s-rebase

Automate Kubernetes dependency rebases for Go projects that consume
`k8s.io/*` packages.

## Usage

```text
/k8s-rebase:k8s-rebase <version>
```

Run from the root of any Go repo with `k8s.io/*` dependencies.
Example: `/k8s-rebase:k8s-rebase 1.36.0`

The skill creates a branch with separate commits for each phase:
dependency bumps, codegen, version references, and code fixes.
No files need to be installed in the target repo — everything
runs from the plugin.

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

## Contents

| File | Purpose |
|------|---------|
| `skills/k8s-rebase/SKILL.md` | Skill entry point and validation guide |
| `scripts/k8s-rebase.sh` | Mechanical rebase orchestrator |
| `scripts/k8s-rebase-autofix.sh` | Applies known fix patterns with PASS/FAIL verification |
| `scripts/k8s-rebase-validate.sh` | Build/lint/vet/test across all modules |
| `scripts/k8s-rebase-review.sh` | Antagonistic review via `claude -p` |
| `scripts/k8s-rebase-review-prompt.md` | Review agent prompt template |
| `gates/step{2,3,4}-*/*.md` | Subagent verification prompts (21 files) |
| `docs/k8s-rebase-patterns.md` | Breakage patterns for k8s 1.33-1.36 |

## Tested against

| Repo | Modules | Features exercised |
|------|---------|--------------------|
| ovn-org/ovn-kubernetes | 3 | Codegen, vendor, conformance tests, feature gates |
| openshift/multus-cni | 1 | Vendor, Eventf vet errors, gate insertion |
| openshift/api | 1 | Vendor, codegen field removal, golangci-lint format |
| metallb/frr-k8s | 2 | No vendor, codegen, 3-version jump, transitive deps |
| kubernetes-sigs/network-policy-api | 2 | No vendor, codegen, multi-module |
| ovn-kubernetes/ovn-kubernetes-mcp | 1 | Vendor, no test-go.sh |
| openshift/ingress-node-firewall | 1 | Vendor, 4-version jump, staging deps, controller-gen, golangci-lint v1/v2 |
| openshift/cloud-network-config-controller | 1 | Vendor, library-go blocker |
| openshift/cluster-network-operator | 1 | Vendor, library-go blocker |
