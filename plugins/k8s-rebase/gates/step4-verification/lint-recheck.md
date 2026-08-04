Check if any Makefile in the module directories (same directories
the loop below iterates) has a `lint:` or `golangci-lint:` target.
If no module has either target, verdict is SKIP (repo does not use
golangci-lint).

If a lint target exists, run `golangci-lint run` in each module:

```bash
for mod_dir in $(find . -name "go.mod" -not -path "*/vendor/*" -exec dirname {} \; | sort); do
  if [[ -d "$mod_dir/vendor" ]] && git check-ignore -q "$mod_dir/vendor" 2>/dev/null; then
    echo "SKIP $mod_dir (vendor is gitignored)"
    continue
  fi
  echo "LINT $mod_dir"
  vendor_flag=""
  [[ -d "$mod_dir/vendor" ]] && vendor_flag="--modules-download-mode=vendor"
  (cd "$mod_dir" && golangci-lint run --verbose --max-same-issues 0 $vendor_flag --timeout=15m0s 2>&1)
done
```

Install golangci-lint if not present:
`go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest`

Use `podman run --userns=keep-id` with the golang container if the
local Go version is too old. Report total finding count from
non-skipped modules only.

VERDICT: FAIL if any lint finding exists in non-skipped modules.
PASS if all modules are lint-clean. SKIP if no lint target exists.

The SKILL.md says "fix them all, they will block CI." This gate
verifies that claim — if lint finds anything, the rebase PR will
fail CI lint checks. No pre-existing filtering is needed because
the rebase must produce a lint-clean result.

NEVER run `go mod tidy`, `go get`, `go mod vendor`, or any
command that modifies go.mod/go.sum/vendor. Allowed: `go build`,
`go vet`, `go test` (with `-mod=vendor` if vendor/ exists),
`go mod verify`, `go doc`, `go install <tool>@<version>`,
`go clean -cache`. Fix-hint commands in report text are fine.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-lint-recheck PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
