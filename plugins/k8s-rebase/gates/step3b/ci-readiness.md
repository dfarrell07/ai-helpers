Read the patterns doc (find k8s-rebase-patterns.md in the plugin
directory). For EACH version-specific pattern (e.g., kubeadm
v1beta4, MetalLB CRD, KubeVirt version, CRD int64), check if
this repo has the relevant files AND whether the fix was applied.

Also check: does any e2e test reference a hardcoded k8s version,
CRD URL, or container image that needs updating? Are there test
skips that should be added or removed for this k8s version?

Flag gaps that would cause CI failures. List each pattern checked
and your finding.

Rules: you are read-only — do not edit files. Cite file:line
for any issues.
