Review type conversions in the fix commits. Identify commits:
  `git log --oneline $(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)..HEAD`
Only review commits that modify struct conversions or type
assertions. If no fix commits involve type conversions, SKIP.

For each struct conversion found, read the FULL struct
definition in vendor and list ALL fields. Compare against the
conversion code. Are any fields silently dropped? Could any
conversion lose data at runtime?

List each struct you checked and your finding. Do not just say
"no issues" — show your work.

VERDICT criteria: FAIL if any struct conversion silently drops
fields or could lose data at runtime. SKIP if no fix commits
involve type conversions. PASS if all conversions are complete.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line
for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step2-type-conversions PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
