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

MANDATORY pre-existing check — run for EVERY finding:

```bash
BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)
# For each finding at <file> with <pattern>:
base_has=$(git show "$BASE:<file>" 2>/dev/null | grep -c '<pattern>')
# If base_has > 0, the issue is PRE-EXISTING — do NOT count it
```

If the issue exists on the base branch, it is pre-existing —
report as "INFO (pre-existing)" but do NOT include in the ISSUES
count. Only issues NOT on the base branch are NEW and count
toward FAIL. If ALL findings are pre-existing, verdict MUST be
PASS.

VERDICT: FAIL if any NEW remaining bug is found in fix commits
(wrong logic, data loss, missing error handling). PASS if all
fix commits are correct or all findings are pre-existing.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. For each wrong format verb, report the correct one. Cite file:line for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-correctness PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
