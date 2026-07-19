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
  misses these. Find deprecated declarations in vendor:
  `grep -rn -B2 '// Deprecated:\|// DEPRECATED' vendor/ --include='*.go' 2>/dev/null | grep -E '^\s*func |^\s*type |^\s*var |^\s*const ' | grep -oP '(?:func|type|var|const)\s+\K\w+' | sort -u | head -50`
  This looks at the lines ABOVE the deprecation comment to find
  the actual declaration name. For each deprecated symbol, check
  non-vendor usage:
  `grep -rn '<symbol>' --include='*.go' . | grep -v vendor/ | grep -v .cache/`

Step 3 — Fallback (if staticcheck unavailable and no vendor):
  Use `go vet ./...` as a minimal check. It won't catch
  deprecated APIs but will catch format string issues and
  other vet-detectable problems.

Find module directories:
  `find . -name go.mod -not -path '*/vendor/*' -exec dirname {} \;`

Run the check in each module directory.

Report each deprecated call with file:line and what to replace
it with (if the deprecation comment says). FAIL if any NEW
deprecated calls exist. PASS if clean or only pre-existing.
SKIP if neither staticcheck nor Go is available.

For each staticcheck finding or deprecated symbol usage, check the base branch:
  `BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)`
  `git show $BASE:<file> 2>/dev/null | grep -c '<pattern>'`
If the same deprecated call exists on the base branch, it is pre-existing --
report it as INFO but do NOT count it toward the FAIL threshold.
Only deprecated calls introduced by the rebase trigger FAIL.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step3-deprecated-calls PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
