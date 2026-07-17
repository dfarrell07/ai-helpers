Review the fix commits for correctness. Did the agent understand
WHY each change was needed, or did it just make the compiler
happy? Flag fixes that compile but would behave incorrectly at
runtime. Examples: wrong format verb, wrong field mapping,
missing error check, silently swallowed error.

List each fix you reviewed and your assessment. Do not just say
"all correct" — show your reasoning for each.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line
for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step2-fix-correctness.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
