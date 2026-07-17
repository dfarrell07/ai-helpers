If e2e infrastructure was modified (kind-common.sh, kind.yaml.j2,
e2e-kind.sh, install-kind.sh, CI workflows), verify the changes
are consistent with the target k8s version.

For each modified e2e file, check:
- Do version references (k8s version strings, kindest/node tags)
  match the target version from go.mod?
  `grep -rn 'kindest/node\|K8S_VERSION\|KIND_VERSION' . | grep -v vendor/`
- Are external tool versions consistent across all CI files?
- Do configuration formats (e.g., kubeadm config apiVersion)
  match what the new k8s version requires? Search the web for
  "k8s <version> kubeadm config" if unsure about required format.

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
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
