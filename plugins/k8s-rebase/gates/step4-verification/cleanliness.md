Run on the host, NOT in a container. Count:
1. Uncommitted tracked files: `git status --short | grep -v '^[?]' | wc -l`
2. Root-owned files outside .git and vendor:
   `find . -type f -not -path './.git/*' -not -path '*/vendor/*' -user root 2>/dev/null | wc -l`
3. .rebase-tmp files tracked by git: `git ls-files .rebase-tmp | wc -l`

Report all three counts.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step4-cleanliness.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
