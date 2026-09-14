# k8s-rebase Plugin Evals

Index of what each opaque `case-NNN` directory tests.

## Running evals

**On a laptop: run one case at a time.** Each case spawns a full Claude
session (up to 200 turns) plus `go mod vendor` on the target repo. The
harness already runs `-j 1` (sequential), but running all 6 cases in
one command leaves the machine busy for hours and can exhaust RAM on
large repos.

```bash
# Recommended: run individual cases
claude plugin eval --case case-002 plugins/k8s-rebase  # fast, ~30min
claude plugin eval --case case-003 plugins/k8s-rebase  # fast
claude plugin eval --case case-004 plugins/k8s-rebase  # fast
claude plugin eval --case case-005 plugins/k8s-rebase  # medium
claude plugin eval --case case-006 plugins/k8s-rebase  # medium-heavy
claude plugin eval --case case-001 plugins/k8s-rebase  # heaviest; save for last
```

**Case weight order** (lightest → heaviest, by vendor tree size and API
surface):

- **Fastest:** case-002, case-003, case-004 — small repos, narrow API
- **Medium:** case-005, case-006 — larger repos
- **Slowest:** case-001 (ovn-org/ovn-kubernetes) — sub-module layout,
  ~350MB vendor tree, expect 1–3h per run

**Full-suite runs** (`claude plugin eval plugins/k8s-rebase`) are
intended for CI or a dedicated workstation with ≥ 32GB RAM. The
`eval-k8s-rebase-pattern-retention.yaml` timeout is set to 12h to
cover all 6 cases sequentially.

## pattern-retention (`cases/pattern-retention`)

Whether `k8s-rebase:k8s-rebase` still correctly rebases each matrix
repo, matching a human-reviewed known-good reference. Weaker than the
existing `make court` adversarial-jury system (see
`eval-k8s-rebase-pattern-retention.yaml`'s `rebase_correctness` judge)
— a passing eval run is a smoke check, not a substitute for `make
court`. Also does not test generalization to novel, un-encoded
breakage — all 6 cases reuse repos the skill's autofix patterns were
already tuned against.

All 6 cases target **k8s 1.36.2** (`k8s.io/* v0.36.2`). Older-version
cases (1.34.x, 1.35.x) are tracked in `plans/eval-improvements.md`
(Item 6) and require manual git archaeology before they can be added.

| Case | Repo | Version | Weight |
|------|------|---------|--------|
| case-001 | ovn-org/ovn-kubernetes | 1.36.2 | Heavy — sub-module layout |
| case-002 | ovn-kubernetes/ovn-kubernetes-mcp | 1.36.2 | Light — minimal API surface |
| case-003 | openshift/multus-cni | 1.36.2 | Light — narrow API surface |
| case-004 | openshift/ingress-node-firewall | 1.36.2 | Light — narrow API surface |
| case-005 | openshift/cloud-network-config-controller | 1.36.2 | Medium |
| case-006 | openshift/cluster-network-operator | 1.36.2 | Medium-heavy — heavy openshift/api usage |
