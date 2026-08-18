Run `go build ./...` and `go vet ./...` in each module directory.
Use this exact loop to find modules and skip gitignored vendors:

```bash
for mod_dir in $(find . -name "go.mod" -not -path "*/vendor/*" -exec dirname {} \; | sort); do
  if [[ -d "$mod_dir/vendor" ]] && git check-ignore -q "$mod_dir/vendor" 2>/dev/null; then
    echo "SKIP $mod_dir (vendor is gitignored)"
    continue
  fi
  echo "CHECK $mod_dir"
  (cd "$mod_dir" && { go build ./... 2>&1; go vet ./... 2>&1; })
  # Count errors: non-zero exit = build or vet failed
done
```

Do NOT run build/vet on modules you skipped — their vendor is
stale and will produce false errors. This is a re-run after lint
fixes — it catches issues introduced since Step 1. Use
`podman run --userns=keep-id` with the golang container if the
local Go version is too old. Report total error count from
non-skipped modules only.

VERDICT IS ABSOLUTE for errors where CI enforces go vet exit code:

First, confirm the repo's CI actually runs `go vet` (or a linter that
catches the same error class). Check `.github/workflows/` or the CI
config for `go vet`, `golangci-lint`, or the validate script. If CI
does not run `go vet ./...`, fall back to delta-only for this gate.

If CI does run `go vet`: a completed rebase must deliver a build that
CI can vet cleanly. For each vet error, check its origin:
  `BASE=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master)`
  For the failing symbol (function/type) in the error, check if it
  existed in the vendor package on BASE:
    `git show "$BASE:vendor/<pkg>/<file>.go" 2>/dev/null | grep -c '<symbol>'`
  >0: symbol existed before, error is NEW (rebase removed or changed it)
  ==0: error existed before the rebase too (PRE-EXISTING)

Report NEW errors as FAIL. Report PRE-EXISTING errors also as FAIL,
labeled "PRE-EXISTING (must fix)" — CI will reject them regardless.
Exception: if the vet error is in auto-generated code (zz_generated_*,
*.pb.go) or a file where the fix would require a dependency bump outside
the k8s rebase scope, document it with file:line and a specific fix
suggestion, mark as FAIL with explanation.

NEVER run `go mod tidy`, `go get`, `go mod vendor`, or any
command that modifies go.mod/go.sum/vendor. Allowed: `go build`,
`go vet`, `go test` (with `-mod=vendor` if vendor/ exists),
`go mod verify`, `go doc`, `go install <tool>@<version>`,
`go clean -cache`. Fix-hint commands in report text are fine.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

VERDICT: FAIL if `go vet ./...` or `go build ./...` exits nonzero
in ANY non-skipped module, regardless of whether the errors existed
before the rebase. A completed rebase must deliver clean code.
PASS only when all non-skipped modules build and vet cleanly (zero errors).

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-build-vet-recheck PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
