Read the full diff against the base branch. Count REMAINING
problems in the final code (not what was changed — what's wrong
NOW):
1. Changes not required by the rebase. Valid changes include:
   version bumps, type conversions, API renames, format string
   fixes, import reordering, codegen output, feature gates,
   deprecated API migrations, dead code removal from stricter
   linters, and any pattern documented in the patterns doc
   (find k8s-rebase-patterns.md). Anything else is suspect.
2. Format strings with wrong verbs (e.g., %d for a string)
   in the CURRENT code, not in the diff of what was fixed.
3. Eventf calls missing format directives (bare .Error() args)
   in the CURRENT code.

Report all three counts. Count 0 means no remaining issues.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step4-correctness.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
