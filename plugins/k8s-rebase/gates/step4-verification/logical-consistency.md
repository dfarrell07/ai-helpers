Read fix commits (autofix + agent). For each function modified,
read the full function and trace data flow. If more than 20
functions were modified, prioritize the 10 with the most complex
changes (struct conversions, error handling, multi-path logic)
and note which were skipped.

Flag:
- Struct copies that drop fields (FAIL)
- Error values checked in one path but ignored in another (FAIL)
- Fields set but never read (FAIL)
- Fields compared in one code path but not another (FAIL)
- Variables assigned but never used (WARN — compiler catches these)

The autofix applies documented patterns (see the patterns doc)
that are intentionally targeted changes. Only flag
inconsistencies WITHIN a modified function — not missing
changes in unrelated functions or callers. Code removed in the
diff may reflect upstream changes merged before the rebase —
check the current file, not just the diff.

List each function you checked and your finding. Do not just
say "no issues" — show what you traced.

For each data flow or consistency finding, check the base branch:
  `BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)`
  `git show $BASE:<file> 2>/dev/null | grep -c '<pattern>'`
If the same issue exists on the base branch, it is pre-existing --
report it as INFO but do NOT count it toward the FAIL threshold.
Only issues introduced by the rebase trigger FAIL.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. For each data flow issue, state the specific fix needed. Cite file:line
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
