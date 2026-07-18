Read ALL fix commits (autofix + agent). For each function
modified, read the full function and trace data flow. Flag:
- Fields set but never read
- Fields compared in one code path but not another
- Struct copies that drop fields
- Variables assigned but never used
- Error values checked in one path but ignored in another

The autofix applies documented patterns (see the patterns doc)
that are intentionally targeted changes. Only flag
inconsistencies WITHIN a modified function — not missing
changes in unrelated functions or callers. Code removed in the
diff may reflect upstream changes merged before the rebase —
check the current file, not just the diff.

List each function you checked and your finding. Do not just
say "no issues" — show what you traced.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line
for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-logical-consistency PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
