EVIDENCE (read before judging): if `.rebase-tmp/gates/step3-crd-validation.evidence` exists,
run `git rev-parse HEAD` and compare it to the file's `HEAD:` line.
- Match: Read the file first and treat its `SUMMARY:`/facts as ground truth for this gate.
- Differ or file absent: evidence is stale/missing — judge from scratch using the checks
  below. Do NOT PASS on the strength of absent or stale evidence.

Read the evidence. When NEW_ISSUES > 0: you MUST skip
CRDs the evidence marked "IDENTICAL" or "NO-VALIDATION-CHANGES".
Only analyze CRDs the evidence marked "CHANGED-VALIDATION" or
"ALL-NEW". Do NOT open, read, or analyze any file marked IDENTICAL.

If evidence is stale or absent, run the manual checks below for
each CRD schema file in the repository.
Find CRD files: `find . -name '*.yaml' -not -path '*/vendor/*' | xargs grep -l 'kind: CustomResourceDefinition' 2>/dev/null`
For each CRD, compare `git show $BASE:<path>` against the working copy and
flag any newly removed or weakened validation constraint (deleted pattern,
format, minimum/maximum, enum, or required entries, or relaxed values).
If $BASE is empty, do not compare — defer without a self-comparison; never
PASS on a self-comparison. Never PASS on unexamined output.

For each CRD the evidence marked "CHANGED-VALIDATION" or "ALL-NEW"
(or found manually when evidence is absent):

1. Compare each CRD to the base branch version. Use
   `git show $BASE:<path>` to check the original.
   Flag any validation constraint removed or weakened vs the
   base: deleted pattern, format, minimum/maximum, enum, or
   required entries, or relaxed values.

2. Check for schema inconsistencies: integer fields where the
   format doesn't match the range (e.g., format: int32 with a
   maximum exceeding 2^31-1, which needs format: int64).

VERDICT: FAIL if any NEW issue found (not in the PRE-EXISTING
output). PASS if all issues are pre-existing or no CRDs exist.
SKIP if no CRDs in repo.

Count ONLY new issues in your ISSUES field. Pre-existing issues
go in DETAILS as "INFO (pre-existing):" entries.

NEVER run `go mod tidy`, `go get`, `go mod vendor`, or any
command that modifies go.mod/go.sum/vendor. Allowed: `go build`,
`go vet`, `go test` (with `-mod=vendor` if vendor/ exists),
`go mod verify`, `go doc`, `go install <tool>@<version>`,
`go clean -cache`. Fix-hint commands in report text are fine.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step3-crd-validation PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
