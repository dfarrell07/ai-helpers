Count go.mod files where k8s.io/* dependency versions are
inconsistent (different minor versions across k8s.io packages
within the same go.mod). For each module with a vendor/ directory, verify
vendor is in sync with go.mod (check vendor/modules.txt).
Report inconsistency count.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step2-version-consistency.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
