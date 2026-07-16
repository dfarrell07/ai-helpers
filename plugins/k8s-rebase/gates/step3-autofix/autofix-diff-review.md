Read the autofix commit's diff. For each code change, verify it
is a correct transformation.

Read the patterns doc (find k8s-rebase-patterns.md in the plugin
directory) for the full list of known transformations. Common
categories: API migrations (x/exp→stdlib, AddToScheme→Install,
FieldsV1), format string fixes, feature gates, CRD validation,
e2e infrastructure, and version reference updates.

Only flag a change as incorrect if the transformation itself is
WRONG (e.g., wrong format verb, missing field, wrong import
section), not because it's unfamiliar. If a change matches a
documented pattern, it's expected. K8S_VERSION patch-level
differences (e.g., v1.36.2 in go.mod vs v1.36.1 for KIND) are
expected — the autofix picks the latest available kindest/node
tag. Do not flag this as a concern.

List each transformation category you checked and your finding.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line
for any issues.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step3-autofix-diff-review.report" << 'REPORT'
VERDICT: <PASS or FAIL>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
