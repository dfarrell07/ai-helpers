Verify the deterministic rebase script completed correctly.
Report a count for each check:

1. Result file: does `.rebase-tmp/step1-result.txt` exist
   and contain "EXIT 2"? (EXIT 2 = rebase script's success
   code, meaning deps were bumped. EXIT 0 = already at target.)
   (0 = yes, 1 = missing or wrong)
2. Uncommitted changes: count from `git status --short`
   (exclude untracked files with `?`). Any staged-but-
   uncommitted go.mod, vendor, or generated files indicate
   the script's commit step failed.
3. Rebase commits: check `git log --oneline` on the current
   branch. Count MISSING expected commits:
   - "Rebase" commits (at least 1 per go.mod with k8s.io deps,
     excluding vendor/)
   - Codegen commit (expected if hack/update-codegen.sh,
     Makefile generate/manifests/codegen targets, or
     `//go:generate` directives exist in .go files)
   - Version refs commit
4. Dependency versions: check all go.mod files (excluding
   vendor/) for k8s.io/* deps. All should be at the same
   minor version. Count any at an older minor version.

Report all 4 counts. Count 0 means that check passed.

Fix hints for non-zero counts:
- Check 1 (result file): re-run the rebase script
- Check 2 (uncommitted): `git add` and commit, or investigate
  why the script's commit step failed
- Check 3 (missing commits): re-run the rebase for the missing
  module, or check if that module has no k8s.io deps
- Check 4 (version mismatch): run `go get k8s.io/<mod>@v0.<target>.0`
  for each mismatched module

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step1-rebase-completeness PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
