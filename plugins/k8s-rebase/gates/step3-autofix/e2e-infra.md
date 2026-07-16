If e2e infrastructure was modified (kind-common.sh, kind.yaml.j2,
e2e-kind.sh), read the patterns doc (find k8s-rebase-patterns.md
in the plugin directory) for the expected state of each component.
Verify each modified file matches what the patterns doc prescribes.

Common e2e components to check:
- MetalLB: version and FRR image consistent with patterns doc?
- KubeVirt: bumped to latest stable release? (not nightly)
- kubeadm: extraArgs format matches required kubeadm API version?
- KIND: version and feature gates match patterns doc?
- Test skips: any conditional skips added for version compatibility?

List each item checked and whether it passes. Report issues.

If the repo has no e2e infrastructure files, skip this check.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line
for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-e2e-infra.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
