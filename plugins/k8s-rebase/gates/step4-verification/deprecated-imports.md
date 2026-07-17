Final verification that no deprecated imports remain. This runs
AFTER step3 gates AND fix commits, so focus on what survived
the entire fix pipeline.

1. Promoted x/ packages (primary check for this gate):
   `grep -rn '"golang.org/x/' --include='*.go' . | grep -v vendor/ | grep -v .cache/`
   For each hit, derive the stdlib name (e.g.,
   golang.org/x/exp/slices -> slices) and check:
   `go doc <stdlib-name> 2>/dev/null`
   If available in stdlib, the x/ import should be migrated.

2. Final build (catches anything earlier gates missed):
   Find modules: `find . -name go.mod -not -path '*/vendor/*' -exec dirname {} \;`
   In each: `go build ./... 2>&1` (add `-mod=vendor` if vendor/ exists)
   Any remaining build error is a FAIL.

3. Final vet:
   In each module: `go vet ./... 2>&1` (add `-mod=vendor` if vendor/ exists)
   Any new vet error from the rebase is a finding.

Do NOT re-run the vendor deprecated-symbol scan — step3's
deprecated-api-remnants gate already did that. This gate
verifies that fix commits resolved the step3 findings.

Report count per category. Cite file:line for each hit.
Zero findings means PASS.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for each hit.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step4-deprecated-imports.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
