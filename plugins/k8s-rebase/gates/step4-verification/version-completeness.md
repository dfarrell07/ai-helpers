Determine the previous k8s version: read go.mod on the base
branch (`git show $(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main):go.mod`)
and extract the k8s.io/api version. If unavailable, derive from
the target version (if target is 1.NN, previous is 1.NN-1).

Count stale version refs from the PREVIOUS k8s version only.
Check yml/yaml/sh/Makefile/Dockerfile files (go.mod and .go
files are covered by go-version-check and compilation gates).
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

MANDATORY pre-existing check — run for EVERY stale reference:

```bash
BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)
# For each finding at <file> with <version-string>:
base_has=$(git show "$BASE:<file>" 2>/dev/null | grep -c '<version-string>')
# If base_has > 0, the stale ref is PRE-EXISTING — do NOT count it
```

If the stale version reference exists on the base branch and is
not in a file modified by the rebase, it is pre-existing — report
as "INFO (pre-existing)" but do NOT include in the ISSUES count.
Only stale references that the rebase should have updated (files
it touched or version variables it is responsible for bumping)
are NEW. If ALL findings are pre-existing, verdict MUST be PASS.

For each stale reference, report the file:line and what the
correct value should be (the target k8s minor version).
This enables the gate-fix loop to sed-replace them.

Report count of NEW genuinely stale previous-version references
plus count of un-bumped Makefile version variables.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-version-completeness PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
