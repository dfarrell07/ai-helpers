Final verification that no deprecated imports remain. This runs
AFTER step3 gates AND fix commits, so focus on what survived
the entire fix pipeline.

Promoted x/ packages (primary check for this gate):
  `grep -rn '"golang.org/x/' --include='*.go' . | grep -v vendor/ | grep -v .cache/`

Known promotions (check these first):
- `golang.org/x/exp/slices` -> `slices` (Go 1.21+)
- `golang.org/x/exp/maps` -> `maps` (Go 1.21+)
- `golang.org/x/net/context` -> `context` (Go 1.7+)
- `golang.org/x/sync/errgroup` -> still x/ (NOT promoted)

For each hit, derive the stdlib name and verify with:
  `go doc <stdlib-name> 2>/dev/null`
If available in stdlib, the x/ import is a FAIL finding — the
import must be replaced with the stdlib equivalent.

Ensure local Go matches the `go` directive in go.mod, or use
a container with the correct version. `go doc` results depend
on the local Go toolchain — a mismatch produces wrong verdicts.

Do NOT re-run build, vet, or the vendor deprecated-symbol scan
— build-vet-recheck and step3's deprecated-api-remnants gates
already cover those. This gate focuses solely on x/ promotions.

Report count of x/ imports that have stdlib equivalents.
Cite file:line for each hit. Zero findings means PASS.

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
