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

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step4-logical-consistency.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
