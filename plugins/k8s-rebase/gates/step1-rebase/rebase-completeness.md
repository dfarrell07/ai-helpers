Verify the deterministic rebase script completed correctly.
Report a count for each check:

1. Result file: does `.rebase-tmp/step1-result.txt` exist
   and contain "EXIT 2"? (0 = yes, 1 = missing or wrong)
2. Uncommitted changes: count from `git status --short`
   (exclude untracked files with `?`). Any staged-but-
   uncommitted go.mod, vendor, or generated files indicate
   the script's commit step failed.
3. Rebase commits: check `git log --oneline` on the current
   branch. Count MISSING expected commits:
   - "Rebase" commits (at least 1 per go.mod with k8s.io deps,
     excluding vendor/)
   - Codegen commit (expected if hack/update-codegen.sh or
     Makefile has generate/manifests/codegen targets)
   - Version refs commit
4. Dependency versions: check all go.mod files (excluding
   vendor/) for k8s.io/* deps. All should be at the same
   minor version. Count any at an older minor version.

Report all 4 counts. Count 0 means that check passed.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step1-rebase-completeness.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
