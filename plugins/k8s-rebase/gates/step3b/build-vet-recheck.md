Run `go build ./...` and `go vet ./...` in each module directory
(find go.mod, exclude vendor). Skip modules whose vendor/
directory is gitignored (`git check-ignore -q <dir>/vendor`).
This is a re-run after lint fixes and agent changes — it catches
issues those later fixes may have introduced since Step 1. Use
`podman run --userns=keep-id` with the golang container if the
local Go version is too old. Report total error count.

Rules: report specific counts, not "looks good." You are
read-only — do not edit files. Cite file:line for any issues.
