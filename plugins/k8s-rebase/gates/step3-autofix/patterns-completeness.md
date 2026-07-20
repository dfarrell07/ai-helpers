MANDATORY FIRST STEP — run the companion gate script:

```bash
GATE_DIR=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -path "*/k8s-rebase/gates/step3-autofix" -type d 2>/dev/null | head -1)
bash "$GATE_DIR/patterns-completeness.sh" "$(pwd)"
```

Read the output. If NEW_ISSUES=0 and BUILD-OK for all modules,
set verdict=PASS immediately. Only proceed with detailed analysis
if the script reports BUILD-FAIL or NEW issues.

Check whether all issues introduced by the dependency bump were
addressed. Use concrete checks — do not just skim the diff.

1. Build verification (primary check):
   Find modules: `find . -name go.mod -not -path '*/vendor/*' -exec dirname {} \;`
   In each: `go build ./... 2>&1` (add `-mod=vendor` if vendor/ exists)
   Any build error means an incomplete transformation. Report
   each error with file:line.

2. Import consistency:
   `git diff $(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master)..HEAD -- '*.go' ':!vendor/' | grep '^[+-].*"' | grep -v '^\+\+\+\|^---'`
   Check if any import was added that has a newer version in
   vendor/ (e.g., importing v1 when vendor has v2).

3. Struct field completeness:
   For each non-vendor Go file changed in the diff, check if
   it constructs structs from vendor/k8s.io/ types. If a struct
   literal has fields that were renamed or removed in vendor,
   the build check (step 1) catches it. Focus on fields that
   were ADDED in vendor but not populated in the constructor
   (these compile fine but may be semantically wrong).

4. If a patterns doc exists, cross-reference:
   `find "$HOME/.claude" -maxdepth 7 -name "k8s-rebase-patterns.md" -path "*/k8s-rebase/docs/*" 2>/dev/null | head -1`
   If found, read it and check any pattern not covered by
   sibling gates. If not found, rely on steps 1-3 above.

CRITICAL: If `go build` returns ANY error, the verdict is FAIL.
Never attribute build failures to caching — run `go clean -cache`
first if you suspect stale cache. Build errors are real regressions.

MANDATORY pre-existing check for non-build findings. Run this
BEFORE reporting any import or struct gap finding:

```bash
BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)
# For each finding at <file>:<line>, check base branch:
base_count=$(git show "$BASE:<file>" 2>/dev/null | grep -c '<pattern>')
curr_count=$(grep -c '<pattern>' "<file>")
# NEW only if curr_count > base_count
```

If the finding exists on the base branch (base_count > 0 and
base_count >= curr_count), it is PRE-EXISTING — report as
"INFO (pre-existing)" and do NOT count in ISSUES. Only findings
where curr_count > base_count (or file doesn't exist on base)
are NEW and count toward FAIL.

Report: FAIL if any build error or rebase-introduced issue
exists. PASS if build succeeds and no NEW issues found.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step3-patterns-completeness PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
