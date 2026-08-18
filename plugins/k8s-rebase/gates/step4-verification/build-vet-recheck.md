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

VERDICT IS ABSOLUTE — a completed rebase must deliver zero go vet errors:

For each vet error, determine origin by checking the SOURCE FILE on base
(not the vendor — vet errors reflect source patterns, not removed vendor symbols):
  `BASE=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master)`
  `git show "$BASE:<file>" 2>/dev/null | grep -c '<error-pattern-from-source>'`

Then check if the rebase touched the file:
  `was_modified=$(git diff --name-only "$BASE"..HEAD -- "<file>" | wc -l)`

Verdict by case:
- base_count==0 (NEW error): FAIL — rebase introduced it
- base_count>0, was_modified>0 (PRE-EXISTING, file touched): FAIL — rebase
  touched this file and should have fixed it; label "PRE-EXISTING (must fix)"
- base_count>0, was_modified==0 (PRE-EXISTING, file untouched): INFO — out of
  scope for this rebase, but note it with a fix suggestion

Exception: vet errors in auto-generated code (zz_generated.*.go, *_generated.go,
*.pb.go, mock_*.go) — document with file:line and the correct fix (e.g., re-run
codegen), mark as FAIL with explanation rather than asking the subagent to edit
generated files directly.

NEVER run `go mod tidy`, `go get`, `go mod vendor`, or any
command that modifies go.mod/go.sum/vendor. Allowed: `go build`,
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
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-build-vet-recheck PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
