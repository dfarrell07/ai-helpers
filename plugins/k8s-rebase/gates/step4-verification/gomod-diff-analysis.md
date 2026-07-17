Scan the go.mod diff (all modules, excluding vendor) between
the branch and its merge-base. Classify each changed dependency:

1. Direct deps with minor-version jumps:
   - k8s.io/* and sigs.k8s.io/*: label "expected rebase" (skip)
   - Third-party (everything else): flag for review
2. Deps that moved from a released version to a pseudo-version
   (e.g., vX.Y.Z → vX.Y.Z-0.2026...): flag as "pinned to
   unreleased commit"
3. Deps added or removed entirely — especially direct deps
   removed (may indicate stdlib promotion or API consolidation)
4. Pre-release direct deps (alpha, beta, rc, v0.0.0-timestamp)
   that have a newer stable release available
5. The `go` directive change (e.g., 1.25 → 1.26): note stdlib
   and language implications

Report findings for all categories above. Count third-party
minor-version jumps, pseudo-version pins, added/removed deps,
and pre-release direct deps separately.

VERDICT criteria: FAIL if any non-k8s direct dependency has an
unexpected major-version jump, or if a direct dep moved to a
pseudo-version without explanation. PASS otherwise — flagged
items in categories 3-5 are informational, not blockers.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite the specific
go.mod line for any flagged dependency.

After your analysis, write your report. The repo path is the
first line of your prompt — use it as an absolute path:

```bash
REPO="<the repo path from the first line of your prompt>"
mkdir -p "$REPO/.rebase-tmp/gates"
cat > "$REPO/.rebase-tmp/gates/step4-gomod-diff-analysis.report" << 'REPORT'
VERDICT: <PASS, FAIL, or SKIP>
ISSUES: <total issue count>
SUMMARY: <one-line description of what you checked and found>
DETAILS:
<one finding per line, with file:line references>
REPORT
```
