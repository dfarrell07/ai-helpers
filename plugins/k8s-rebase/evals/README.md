# k8s-rebase Plugin Evals

Index of what each opaque `case-NNN` directory tests.

## pattern-retention (`cases/pattern-retention`)

Whether `k8s-rebase:k8s-rebase` still correctly rebases each matrix
repo, matching a human-reviewed known-good reference. Weaker than the
existing `make court` adversarial-jury system (see
`eval-k8s-rebase-pattern-retention.yaml`'s `rebase_correctness` judge)
— a passing eval run is a smoke check, not a substitute for `make
court`. Also does not test generalization to novel, un-encoded
breakage — all 6 cases reuse repos the skill's autofix patterns were
already tuned against.

| Case | Repo | Description |
|------|------|-------------|
| case-001 | ovn-org/ovn-kubernetes | Largest, most complex repo; sub-module go-controller/ layout |
| case-002 | ovn-kubernetes/ovn-kubernetes-mcp | Small MCP server; minimal k8s API surface |
| case-003 | openshift/multus-cni | Small CNI meta-plugin; narrow k8s API surface |
| case-004 | openshift/ingress-node-firewall | EgressFirewall node rules; narrow k8s API surface |
| case-005 | openshift/cloud-network-config-controller | EgressIP management (AWS/Azure/GCP) |
| case-006 | openshift/cluster-network-operator | Larger downstream repo; heavy openshift/api usage |
</content>
