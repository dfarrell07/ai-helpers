Check whether all issues introduced by the dependency bump were
addressed. Use concrete checks — do not just skim the diff.

1. Build verification (primary check):
   Find modules: `find . -name go.mod -not -path '*/vendor/*' -exec dirname {} \;`
   In each: `go build ./... 2>&1` (add `-mod=vendor` if vendor/ exists)
   Any build error means an incomplete transformation. Report
   each error with file:line.

2. Import consistency:
   `git diff $(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master)..HEAD -- '*.go' ':!vendor/' | grep '^[+-].*"' | grep -v '^\+\+\+\|^---'`
   Check if any import was added that has a newer version in
   vendor/ (e.g., importing v1 when vendor has v2).

3. Struct field completeness:
   For each non-vendor Go file changed in the diff, check if
   it constructs structs from vendor/k8s.io/ types. If a struct
   literal has fields that were renamed or removed in vendor,
   the build check (step 1) catches it. Focus on fields that
   were ADDED in vendor but not populated in the constructor
   (these compile fine but may be semantically wrong).

4. If a patterns doc exists, cross-reference:
   `find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-patterns.md" -path "*/k8s-rebase/docs/*" 2>/dev/null | head -1`
   If found, read it and check any pattern not covered by
   sibling gates. If not found, rely on steps 1-3 above.

CRITICAL: If `go build` returns ANY error, the verdict is FAIL.
Never attribute build failures to caching — run `go clean -cache`
first if you suspect stale cache. Build errors are real regressions.

Report: FAIL if any build error or unaddressed pattern exists.
PASS if build succeeds and no issues found.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-patterns-completeness.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
