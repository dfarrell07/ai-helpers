Determine the previous k8s version: read the base branch's primary go.mod
(`BASE=$(bash "$PLUGIN_ROOT/scripts/resolve-rebase-base.sh" "$(git rev-parse --show-toplevel)") || exit 1; git show "$BASE:<path>"`),
the first non-vendor go.mod that requires k8s.io/api, which may be nested
(for example `go-controller/go.mod`), and extract the k8s.io/api version.
If unavailable, derive from the target version (if target is 1.NN,
previous is 1.NN-1).

Count stale version refs from the PREVIOUS k8s version only.
Check yml/yaml/sh/Makefile/Dockerfile files (go.mod and .go
files are covered by go-version-check and compilation gates).
Also inspect runnable commands in Markdown/code blocks. For example,
`setup-envtest use 1.x.y` selects Kubernetes test-server binaries, not the
independently versioned setup-envtest tool. Trace the consumer before excluding
an old version as prose or a tool tag.
Exclude:

- K8S_VERSION if the kindest/node image isn't published yet
- Lines where the version appears in prose (comments starting
  with //, #, or lines in README/CHANGELOG files) that are not
  assignments or image tags

- References inside vendor/ directories
- Ancient versions (1.16, 1.20, etc.) — those are pre-existing
  documentation debt, not rebase issues

Also check Makefile variable assignments (VAR ?=, VAR :=, VAR =)
for version-bearing variables: K8S_VERSION, GOLANG_VERSION,
GOLANGCI_LINT_VERSION, KIND_VERSION, KUSTOMIZE_VERSION. Also
grep for any `*_VERSION` or `*_VER` Makefile variable containing
the previous minor version number. Flag any that still reference
the previous k8s minor version or a Go version that does not
match the target release's Go toolchain.

For OpenShift consumers, also inspect `.ci-operator.yaml` and Dockerfiles
for `openshift-X.Y` and `ocp/X.Y:` streams. Compare with the mapped target
release and that repository's `openshift/release` configuration; verify the
replacement images exist. Check this even if Go is unchanged. An unavailable
image or unresolved release configuration is missing verification: report it
as INCONCLUSIVE rather than inventing a tag or calling the check passed.
List every applicable image reference with its base stream, target stream,
replacement verification, and file:line. For example, a Dockerfile still
using OCP 5.0 during a 5.1 rebase is unresolved even if unchanged: use FAIL
when the correct replacement is verified and still missing, or INCONCLUSIVE
when that replacement cannot be verified. This image-specific rule takes
precedence over the general stale-reference count below. Neither case is PASS.

MANDATORY pre-existing check — run for EVERY finding before
counting it. Skip this check and your verdict is WRONG.

```bash
BASE=$(bash "$PLUGIN_ROOT/scripts/resolve-rebase-base.sh" "$(git rev-parse --show-toplevel)") || exit 1
git show "$BASE:<file>"
git show "$BASE:<primary-go.mod-path>"
# Compare whether the reference was valid for the BASE dependencies/config
# and whether the requested target makes it stale now.
```

A reference that was correct for the base but is stale for the requested
target is NEW, including in an unmodified file: omission is a rebase defect.
Count older unrelated debt as INFO. Neither an unchanged file nor the old
version string's presence on base proves the finding was pre-existing.

For each stale reference, report the file:line and what the
correct value should be (the target k8s minor version).
This enables the gate-fix loop to sed-replace them.

Report count of NEW genuinely stale previous-version references
plus count of un-bumped Makefile version variables.

VERDICT: FAIL if either count is nonzero; INCONCLUSIVE if applicable target
or image verification could not complete; otherwise PASS.

NEVER run `go mod tidy`, `go get`, `go mod vendor`, `go generate`,
`go run`, or any command that modifies go.mod/go.sum/vendor. Allowed: `go build`,
`go vet`, `go test` (with `-mod=vendor` if vendor/ exists),
`go mod verify`, `go doc`, `go install <tool>@<version>`,
`go clean -cache`. Fix-hint commands in report text are fine.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report using the helper script.
Bind PLUGIN_ROOT to the verified absolute plugin path from your reviewer
context in this shell call. Confirm HEAD still matches the code reviewed;
then write through the helper (stop if it is unavailable):

```bash
REPO="<the absolute repo path from reviewer context>"
bash "${PLUGIN_ROOT}/scripts/write-gate-report.sh" \
  "$REPO" step4-version-completeness PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Choose the verdict from this gate's criteria. Replace the example verdict,
issue count, summary, and details with your actual findings.
