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

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-cleanliness PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
