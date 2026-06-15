If e2e infrastructure was modified (kind-common.sh, kind.yaml.j2,
e2e-kind.sh), verify each change:

- MetalLB: version bumped to v0.16.0+? METALLB_UPSTREAM_FRR_IMAGE
  variable added? install_metallb references updated?
- KubeVirt: KUBEVIRT_VERSION set to "nightly"?
- kubeadm: ALL extraArgs and kubeletExtraArgs in v1beta4 list
  format (- name: / value:)? ALL Configuration kinds have
  apiVersion: kubeadm.k8s.io/v1beta4?
- RelaxedServiceNameValidation: probe function in e2e-kind.sh?
  featureGates in kind.yaml.j2?

List each item checked and whether it passes. Report issues.

If the repo has no e2e infrastructure files, skip this check.

Rules: you are read-only — do not edit files. Cite file:line
for any issues.
