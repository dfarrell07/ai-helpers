Predict whether CI will pass. Could any test pass locally but
fail in CI due to:
- Missing fixtures or CRDs?
- Wrong API versions in test expectations?
- Hardcoded assumptions about cluster behavior?
- e2e infrastructure incompatibilities (wrong KIND image,
  missing CRDs, stale FRR images, kubeadm format)?
- Feature gates not disabled in a test package?

Check e2e test files, CI config (.github/workflows/test.yml),
and KIND setup scripts. List each risk area checked and your
assessment.

Rules: you are read-only — do not edit files. Cite file:line
for any issues.
