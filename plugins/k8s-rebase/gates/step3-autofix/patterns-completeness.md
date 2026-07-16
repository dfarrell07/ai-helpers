Check patterns NOT covered by other gates in this step:

1. If conformance tests exist: are renames complete?
   (SupportAdminNetworkPolicy → SupportClusterNetworkPolicy)
2. If ANP/BANP status code exists: is ObservedGeneration
   propagated in all condition builders?
3. If AddToScheme calls exist: are deprecated ones replaced
   with Install where the vendored source has Install?
4. If EgressPeer types were changed: are ALL field mappings
   complete (check struct definition in vendor)?

Skip patterns already verified by other gates (x/exp,
reflect.Ptr, FieldsV1, feature gates, CRDs, e2e infra).

Report count per pattern checked. Cite file:line for issues.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-patterns-completeness.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
