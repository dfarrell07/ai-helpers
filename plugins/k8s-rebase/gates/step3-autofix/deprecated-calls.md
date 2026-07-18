Detect deprecated function and type usage via static analysis.
This catches deprecated-but-compiling code that go build and
go vet miss — the most common cause of gate failures.

Step 1 — Try staticcheck (most reliable):
  If `staticcheck` is available, run:
  `staticcheck -checks SA1019 ./... 2>&1`
  (add `-mod=vendor` to go flags if vendor/ exists)
  SA1019 detects calls to functions/types marked `// Deprecated:`
  in their source. This is the Go ecosystem's standard
  deprecation checker and catches ALL deprecated API usage
  including cross-module deprecations in vendor.

  If staticcheck is not installed, try:
  `go install honnef.co/go/tools/cmd/staticcheck@latest 2>/dev/null`

Step 2 — Non-standard deprecation scan:
  Some projects (notably OpenShift API) use `// DEPRECATED`
  instead of the Go-standard `// Deprecated:` format. SA1019
  misses these. Scan vendor for both formats:
  `grep -rn '// Deprecated:\|// DEPRECATED' vendor/ --include='*.go' 2>/dev/null | grep -oP 'func \K\w+|type \K\w+|^\s+\K\w+(?:\s*=)' | sort -u | head -30`
  For each deprecated symbol, check non-vendor usage:
  `grep -rn '<symbol>' --include='*.go' . | grep -v vendor/ | grep -v .cache/`

Step 3 — Fallback (if staticcheck unavailable and no vendor):
  Use `go vet ./...` as a minimal check. It won't catch
  deprecated APIs but will catch format string issues and
  other vet-detectable problems.

Find module directories:
  `find . -name go.mod -not -path '*/vendor/*' -exec dirname {} \;`

Run the check in each module directory.

Report each deprecated call with file:line and what to replace
it with (if the deprecation comment says). FAIL if any
deprecated calls exist in non-vendor code. PASS if clean.
SKIP if neither staticcheck nor Go is available.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-deprecated-calls.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
