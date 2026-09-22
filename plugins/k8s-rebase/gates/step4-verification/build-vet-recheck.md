Run `go build ./...` and `go vet ./...` in each module directory.
Use this exact loop to find modules and skip gitignored vendors:

```bash
for mod_dir in $(find . -name "go.mod" -not -path "*/vendor/*" -exec dirname {} \; | sort); do
  if [[ -d "$mod_dir/vendor" ]] && git check-ignore -q "$mod_dir/vendor" 2>/dev/null; then
    echo "SKIP $mod_dir (vendor is gitignored)"
    continue
  fi
  echo "CHECK $mod_dir"
  build_rc=0
  (cd "$mod_dir" && go build ./... 2>&1) || build_rc=$?
  vet_rc=0
  (cd "$mod_dir" && go vet ./... 2>&1) || vet_rc=$?
  printf 'RESULT %s: build=%s vet=%s\n' "$mod_dir" "$build_rc" "$vet_rc"
done
```

Do NOT run build/vet on modules you skipped — their vendor is
stale and will produce false errors. This is a re-run after lint
fixes — it catches issues introduced since Step 1. Use
`podman run --userns=keep-id` with the golang container if the
local Go version is too old. Report total error count from
non-skipped modules only.

Account for every module: checked or explicitly excluded. A timeout, crash,
or unfinished check leaves coverage incomplete; report INCONCLUSIVE if it
cannot be completed. Missing coverage is not a zero error count.

Analyze build and vet diagnostics against the base's source, dependency APIs,
and configuration. Identical source lines do not prove an error was
pre-existing: the dependency they call may have changed. If attribution
cannot be established, report INCONCLUSIVE.

For established pre-existing errors, use the branch diff from the merge base
to determine whether the rebase touched the affected file. Apply these rules
to both handwritten and generated files:

- NEW error: FAIL.
- PRE-EXISTING, file touched: FAIL; label "PRE-EXISTING (must fix)".
- PRE-EXISTING, file untouched: INFO; note the error and a fix suggestion.

For generated-code errors, recommend fixing the generator inputs or version
and regenerating rather than hand-editing generated output.

NEVER run `go mod tidy`, `go get`, `go mod vendor`, `go generate`,
`go run`, or any command that modifies go.mod/go.sum/vendor. Allowed: `go build`,
`go vet`, `go test` (with `-mod=vendor` if vendor/ exists),
`go mod verify`, `go doc`, `go install <tool>@<version>`,
`go clean -cache`. Fix-hint commands in report text are fine.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

VERDICT: FAIL if any NEW or PRE-EXISTING-touched errors exist.
PASS only when all non-skipped modules build and vet cleanly (zero FAIL-tier errors).
INFO items (pre-existing, file untouched) do not block — note them for follow-up.

After your analysis, write your report using the helper script.
Bind PLUGIN_ROOT to the verified absolute plugin path from your reviewer
context in this shell call. Confirm HEAD still matches the code reviewed;
then write through the helper (stop if it is unavailable):

```bash
REPO="<the absolute repo path from reviewer context>"
bash "${PLUGIN_ROOT}/scripts/write-gate-report.sh" \
  "$REPO" step4-build-vet-recheck PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Choose the verdict from this gate's criteria. Replace the example verdict,
issue count, summary, and details with your actual findings.
