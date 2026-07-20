MANDATORY FIRST STEP — run this script to identify pre-existing
CRD issues. ONLY issues NOT in this output are new findings:

```bash
BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)
echo "=== Pre-existing CRD issues on base branch ==="
for crd in $(find . -name '*.yaml' -not -path '*/vendor/*' -exec grep -l 'kind: CustomResourceDefinition' {} \;); do
  git show "$BASE:$crd" 2>/dev/null | grep -n 'format: int32' | while read line; do
    linenum=$(echo "$line" | cut -d: -f1)
    next=$(git show "$BASE:$crd" 2>/dev/null | sed -n "$((linenum+1))p")
    [[ "$next" == *"maximum: 4294967295"* ]] && echo "PRE-EXISTING: $crd:$linenum int32+max>2^31"
  done
done
```

Run that script. Any issue it prints as "PRE-EXISTING" MUST NOT
be counted in your ISSUES total or affect your verdict.

Then check:

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
