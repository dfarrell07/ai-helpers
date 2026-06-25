Read the autofix commit's diff. For each code change, verify it
is a correct transformation. Known autofix patterns:
- x/exp→stdlib: maps.Keys wrapped in slices.Collect? imports
  in the stdlib section (not third-party)?
- FieldsV1: .Raw→.GetRawBytes()? {Raw: []byte(...)}→NewFieldsV1(...)?
- reflect.Ptr→reflect.Pointer
- AddToScheme→Install (openshift/api types only, NOT k8s types)
- Format strings: correct verbs? Eventf has format directive?
- Feature gates: all gates in the right places?
- ObservedGeneration: assignments, comparison, propagation
- CRD validation: int64 format, metadata.name patterns
- e2e infra: MetalLB, KubeVirt, KIND, kubeadm, lint versions
- Version refs: K8S_VERSION, Go version, golangci-lint

All of these are documented in the patterns doc. Only flag a
change as incorrect if the transformation itself is WRONG (e.g.,
wrong format verb, missing field), not because it's unfamiliar.

List each transformation category you checked and your finding.

Rules: you are read-only — do not edit files. Cite file:line
for any issues.
