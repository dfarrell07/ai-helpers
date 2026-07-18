Review the full branch diff as a maintainer would. Does every
change serve the k8s version bump, or are there unrelated
cleanups, style changes, or logic alterations? Would a
maintainer approve this diff as-is?

Check:
- Are commits well-scoped (one concern per commit)?
- Are commit messages accurate?
- Is there any scope creep (changes beyond what the rebase needs)?

Note: the autofix script applies known rebase patterns that ARE
required — these are NOT scope creep. Read the patterns doc
(find k8s-rebase-patterns.md in the plugin directory) for the
full list. Any change that matches a documented pattern is
expected, even if it touches e2e infrastructure, version
references, or test configuration. K8S_VERSION patch-level
differences between go.mod and CI tooling (KIND, lint, etc.)
are expected — the autofix picks the latest available versions.
Do not flag minor version mismatches as a concern.

List your findings with specific commit SHAs and file:line refs.
Do not just say "would approve" — explain what you checked.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line
for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-maintainer-review PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
