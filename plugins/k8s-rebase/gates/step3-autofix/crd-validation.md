Find CRD YAMLs anywhere in the repo (not just helm/*/crds/):
  find . -name '*.yaml' -not -path '*/vendor/*' -exec grep -l 'kind: CustomResourceDefinition' {} \;

If CRDs are found:

1. Compare each CRD to the base branch version. Detect the
   base branch with:
   `git merge-base HEAD main 2>/dev/null || git merge-base HEAD master`
   then use `git show <base>:path` to check the original.
   Flag any validation constraint removed or weakened vs the
   base: deleted pattern, format, minimum/maximum, enum, or
   required entries, or relaxed values (wider range, looser
   regex).

2. Check for schema inconsistencies: integer fields where the
   format doesn't match the range (e.g., format: int32 with a
   maximum exceeding 2^31-1, which needs format: int64).

Report counts of lost validations and schema inconsistencies.

If no CRDs found in the repo, report 0 for both.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-crd-validation.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
