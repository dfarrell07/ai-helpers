The rebase bumped the Go version. Verify consistency across
the repo and check for implications.

1. go directive: are all go.mod files at the same Go version?
   git diff $(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master)..HEAD -- '*/go.mod' 'go.mod' | grep '^[+-]go '

2. toolchain directive: was it added, removed, or changed?
   git diff $(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master)..HEAD -- '*/go.mod' 'go.mod' | grep '^[+-]toolchain'

3. Makefiles: do all GO_VERSION / GOLANG_VERSION vars match?
   grep -rn 'GO_VERSION.*=\|GOLANG_VERSION.*=' --include='Makefile*' . | grep -v vendor

4. Dockerfiles: do all golang: image tags match?
   grep -rn 'golang:' --include='Dockerfile*' . | grep -v vendor

5. CI workflows: do they use go-version-file (dynamic) or
   hardcoded versions?
   grep -rn 'go-version' --include='*.yml' --include='*.yaml' .github/ | head -10

6. x/ package opportunities: this is checked by the
   deprecated-imports gate — do not duplicate that check here.
   Just note the Go version bump and its implications for
   stdlib additions.

VERDICT criteria: FAIL if go.mod files have inconsistent Go
versions, or Makefiles/Dockerfiles use a Go version that
doesn't match go.mod. Migration opportunities (x/ packages,
CI workflow improvements) are informational — report them
in DETAILS but do not FAIL for them alone.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step4-go-version-check.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
