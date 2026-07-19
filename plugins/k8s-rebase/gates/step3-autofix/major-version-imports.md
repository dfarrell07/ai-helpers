Check for stale major-version Go module imports. These are
entire module path changes where v1 is abandoned in favor of
v2+ — NOT deprecated symbols (those are caught by other gates).

Step 1 — Discover major-version modules from go.mod:
  `grep -E '/v[0-9]+' go.mod | grep -v '^//' | sed 's|.*\([a-z].*\/v[0-9]*\).*|\1|' | sort -u`
  For each versioned module path (e.g., k8s.io/klog/v2), check
  if non-vendor code still imports the unversioned path:
  `grep -rn '"k8s.io/klog"' --include='*.go' . | grep -v vendor/ | grep -v .cache/ | grep -v '/v2'`

Step 2 — Check common major-version migrations:
  These module path changes recur across k8s ecosystem repos:
  - grep for bare `"k8s.io/klog"` (should be `k8s.io/klog/v2`)
  - If vendor has `sigs.k8s.io/controller-runtime/v2`, grep
    for bare `"sigs.k8s.io/controller-runtime"` without /v2
  For each: if the old path is used AND the new version exists
  in vendor/ or go.mod, this is a FAIL.

Step 3 — Check go.mod require lines:
  `grep -E 'require' go.mod`
  Look for any direct dependency that uses a pre-v2 path when
  a v2+ version is available. Cross-reference with vendor/:
  `find vendor/ -type d -regex '.*/v[0-9]+$' | sort`

Report each stale import with file:line AND the correct
versioned path (e.g., k8s.io/klog -> k8s.io/klog/v2).
FAIL if any NEW stale imports remain. PASS if clean or
only pre-existing. If no major-version deps, PASS.

Rules: report specific counts, not "looks good." You are
read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step3-major-version-imports PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
