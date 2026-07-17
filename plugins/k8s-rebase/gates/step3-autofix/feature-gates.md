If test files use feature gates (SetFromMap or KUBE_FEATURE_
env vars): find `k8s-rebase-autofix.sh` and read the GATE_DEPS
map near the top. For each gate, first check if it exists in
vendor/k8s.io/ (grep for the quoted name). Skip gates not in
vendor — the script also skips them. Count files missing any
active gate. Verify
gates match between SetFromMap calls, os.Setenv/t.Setenv
calls, and hack/test-go.sh exports. Report count of files
with missing gates.

Also check hack/*.sh and Makefile for KUBE_FEATURE_ exports
that reference gates no longer present in vendor/k8s.io/.

If the repo has no test files with SetFromMap or KUBE_FEATURE_
and no KUBE_FEATURE_ references in hack/ or Makefile,
report SKIP — do not report PASS for work you did not do.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-feature-gates.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
