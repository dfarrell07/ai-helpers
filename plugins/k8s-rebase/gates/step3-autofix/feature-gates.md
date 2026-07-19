If test files use feature gates (SetFromMap or KUBE_FEATURE_
env vars): find `k8s-rebase-autofix.sh` and read the GATE_DEPS
map near the top. For each gate, check if it exists in
vendor/k8s.io/ (grep for the quoted name). Skip gates not in
vendor. Verify gates match between SetFromMap calls,
os.Setenv/t.Setenv calls, and shell script exports.

Search the entire repo for KUBE_FEATURE_ exports:
  `grep -rn 'KUBE_FEATURE_' --include='*.sh' --include='Makefile*' . | grep -v vendor/`
Report count of files with missing or stale gates.

If the repo has no SetFromMap or KUBE_FEATURE_ references
at all, report SKIP.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues. For each missing gate, report the gate name and the fix needed.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step3-feature-gates PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
