Run `go build ./...` and `go vet ./...` in each module directory
(find go.mod, exclude vendor). Use `podman run --userns=keep-id`
with the golang container if the local Go version is too old.
Report total error count.

Rules: report specific counts, not "looks good." You are
read-only — do not edit files. Cite file:line for any issues.
