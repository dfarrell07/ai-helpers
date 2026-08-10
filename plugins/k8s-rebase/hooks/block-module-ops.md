---
name: block-module-ops
description: Prevent direct go module operations during k8s-rebase skill execution
event: PreToolUse
tools:
  - Bash
---

Check if the Bash command directly invokes a Go module operation.
These commands corrupt k8s version pins via MVS resolution when run
outside the deterministic rebase scripts. The scripts (k8s-rebase.sh,
k8s-rebase-autofix.sh) run these internally and are NOT blocked —
PreToolUse only sees the top-level command, not subprocess execution.

Block the command if it matches ANY of these patterns:
- `go mod tidy`
- `go mod edit`
- `go mod vendor`
- `go get` (any arguments)
- `go generate`
- `go run` (any arguments)

Do NOT block if the command runs a script that may internally use
these operations:
- `bash *.sh` or `sh *.sh` — these are wrapper scripts
- Commands that do not start with `go `

If the command matches a blocked pattern, respond with:

```
BLOCK: Direct go module operations are forbidden during k8s-rebase.
Module operations (go mod tidy, go get, go mod vendor) are handled
by k8s-rebase.sh and k8s-rebase-autofix.sh. Running them directly
corrupts k8s version pins via MVS resolution.

Allowed: go build, go vet, go test, go mod verify, go doc,
go install <tool>@<version>, go clean -cache.
```

If the command does NOT match any blocked pattern, respond with:

```
ALLOW
```
