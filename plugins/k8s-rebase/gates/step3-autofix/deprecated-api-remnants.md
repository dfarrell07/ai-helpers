Count deprecated API remnants the autofix should have fixed:
- `golang.org/x/exp` imports (excluding vendor)
- `reflect.Ptr` usage (excluding vendor)
- `FieldsV1.Raw` or `FieldsV1{Raw:` usage (excluding vendor)
- `"k8s.io/klog"` imports without `/v2` (excluding vendor)
Report each count separately and the total.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-deprecated-api-remnants.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
