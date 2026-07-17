Count stale version refs from the PREVIOUS k8s version only
(e.g., if rebasing to 1.36, look for leftover 1.35 refs).
Check yml/yaml/sh/Makefile/Dockerfile files. Exclude:
- K8S_VERSION if the kindest/node image isn't published yet
- Historical/documentation references ("introduced in k8s 1.X",
  comments explaining old behavior, changelogs)
- References inside vendor/ directories
- Ancient versions (1.16, 1.20, etc.) — those are pre-existing
  documentation debt, not rebase issues

Also check Makefile variable assignments (VAR ?=, VAR :=, VAR =)
for version-bearing variables: K8S_VERSION, GOLANG_VERSION,
GOLANGCI_LINT_VERSION, KIND_VERSION, KUSTOMIZE_VERSION. Flag any
that still reference the previous k8s minor version or a Go
version that does not match the target release's Go toolchain.

Report count of genuinely stale previous-version references
plus count of un-bumped Makefile version variables.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step4-version-completeness.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
