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

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-deprecated-imports PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
