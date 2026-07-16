Read each fix commit's diff (commits after the mechanical rebase,
before the autofix). Count files that are not Go source (.go),
tests (_test.go), module files (go.mod, go.sum), docs (.md),
CI configs (.yml/.yaml), or build files (Makefile, Dockerfile,
.sh, .j2). Changes in generated/managed directories are also
expected: vendor/, LICENSES/, _output/, third_party/.
Unexpected file types suggest a fix leaked beyond its intended
scope.

Report count of unexpected files changed.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step2-diff-scope.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
