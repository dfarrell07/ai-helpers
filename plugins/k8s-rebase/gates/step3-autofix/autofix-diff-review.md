Read the autofix commit's diff. For each code change, verify it
is a correct transformation.

Read the patterns doc (find k8s-rebase-patterns.md in the plugin
directory) for the full list of known transformations for this
version. Use it as a reference — do not assume specific patterns.

Only flag a change as incorrect if the transformation itself is
WRONG (e.g., wrong format verb, missing field, wrong import
section), not because it's unfamiliar. If a change matches a
documented pattern, it's expected. K8S_VERSION patch-level
differences between go.mod and KIND/CI tooling are expected —
the autofix picks the latest available versions. Do not flag
minor version mismatches as a concern.

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
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
