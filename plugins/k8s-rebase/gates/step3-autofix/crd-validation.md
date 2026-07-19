IMPORTANT — run the pre-existing check FIRST for every finding:
  `BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)`
  `git show $BASE:<path> 2>/dev/null`
If a finding exists identically on the base branch, it is
pre-existing — report as INFO and do NOT count toward FAIL.
Only issues introduced by the rebase trigger FAIL. If `git show`
fails (file doesn't exist on base), the finding IS new.

Find CRD YAMLs anywhere in the repo (not just helm/*/crds/):
  find . -name '*.yaml' -not -path '*/vendor/*' -exec grep -l 'kind: CustomResourceDefinition' {} \;

If CRDs are found:

1. Compare each CRD to the base branch version. Use
   `git show $BASE:<path>` to check the original.
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
Do not write anywhere else. Cite file:line for any issues. For each lost validation, report the original constraint value.

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
