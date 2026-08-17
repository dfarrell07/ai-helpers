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

MANDATORY pre-existing check — run for EVERY build/vet error:

In normal workflow, step 2's build-vet gate already passed with 0 new
errors, meaning the baseline was clean before the autofix ran. Any
error found here was introduced by the autofix or subsequent fix
commits and is NEW — report ALL such errors as FAIL.

Do NOT use "was this file modified by the rebase?" as the pre-existing
test. An unmodified file can still get a new compile error when a
dependency API it calls is changed or removed — that error is NEW
even though the file itself was not touched.

If step 2 did not run cleanly: check the step 2 build-vet gate report
for this same error. If step 2 already reported it as pre-existing,
mark it INFO here too. If step 2 did not report it, it is NEW.

NEVER run `go mod tidy`, `go get`, `go mod vendor`, or any
command that modifies go.mod/go.sum/vendor. Allowed: `go build`,
`go vet`, `go test` (with `-mod=vendor` if vendor/ exists),
`go mod verify`, `go doc`, `go install <tool>@<version>`,
`go clean -cache`. Fix-hint commands in report text are fine.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

VERDICT: FAIL if any NEW (non-pre-existing) build or vet error
exists in non-skipped modules. PASS if all modules build and
pass vet cleanly or if all errors are pre-existing.

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
