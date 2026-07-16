Check the autofix results by examining git log for the autofix
commits. Look for commits matching patterns like "Migrate x/exp
imports", "Disable new default-true feature gates", "Update KIND
image", "Update version references and lint". Count how many
autofix commits were created. If zero, the autofix may not have
run. Ignore stale vendor in gitignored directories
(`git check-ignore -q <dir>/vendor`) — these are expected and
not maintained by the rebase. Do NOT escalate gitignored vendor
staleness as a blocker.

Report total issues.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-autofix-result.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
