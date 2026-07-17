Count deprecated API remnants that must be zero after a rebase.
Run these exact greps (excluding vendor and .cache directories):

1. `grep -rn '"golang.org/x/exp' --include='*.go' . | grep -v vendor/ | grep -v .cache/`
2. `grep -rn 'reflect\.Ptr' --include='*.go' . | grep -v vendor/ | grep -v .cache/`
3. `grep -rn 'FieldsV1.Raw\|FieldsV1{Raw:' --include='*.go' . | grep -v vendor/ | grep -v .cache/`
4. `grep -rn '"k8s.io/klog"' --include='*.go' . | grep -v vendor/ | grep -v .cache/ | grep -v '/v2'`

Report each count separately and the total. Any non-zero total
is a FAIL — these patterns must all be migrated during the
rebase, whether by autofix or manually.

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
