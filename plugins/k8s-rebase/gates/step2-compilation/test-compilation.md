Verify that test files compile. `go build ./...` only compiles
non-test packages — tests can have their own import errors,
type mismatches, and missing symbols that build alone misses.

Find module directories:
  `find . -name go.mod -not -path '*/vendor/*' -not -path '*/.cache/*' -exec dirname {} \;`

For each module, compile tests without executing them:
  `go test -run='^$' -count=0 ./... 2>&1`
  (add `-mod=vendor` if vendor/ exists in the module)

The flags `-run='^$' -count=0` match zero tests and skip
execution — this only verifies compilation. Any compilation
error in a _test.go file is a finding.

Skip modules whose vendor/ directory is gitignored:
  `git check-ignore -q <dir>/vendor 2>/dev/null`
  Gitignored vendor dirs are not maintained by the rebase.

If Go is unavailable or wrong version, note as SKIPPED.

Report total test compilation errors.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step2-test-compilation.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total error count>
SUMMARY: <one-line: N test compilation errors across K modules>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
