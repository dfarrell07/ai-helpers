Check whether the autofix produced meaningful results by
examining the commit history after the initial rebase.

1. Determine the base:
   `BASE=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master)`

2. List post-rebase commits:
   `git log --oneline $BASE..HEAD`
   Count total commits. Identify which are rebase infrastructure
   (go.mod/vendor changes) vs fix commits (code changes).

3. Check for autofix markers:
   - Commits with "Applied:" in the body: `git log --grep='Applied:' --oneline $BASE..HEAD`
   - Commits with "Assisted-by:" trailer: `git log --grep='Assisted-by:' --oneline $BASE..HEAD`

4. If zero fix commits exist, verify the repo doesn't need any:
   - `go build ./...` — does it compile?
   - `go vet ./...` — any warnings?
   If both pass, the repo may genuinely need no fixes beyond
   the dependency bump itself. Report PASS with note.
   If either fails, report FAIL — fixes were needed but not
   applied.

Ignore stale vendor in gitignored directories
(`git check-ignore -q <dir>/vendor`) — these are expected and
not maintained by the rebase. Do NOT escalate gitignored vendor
staleness as a blocker.

Report total issues.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-autofix-result.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
