If the autofix bumped ecosystem dependencies (check git log for
version changes in kind-common.sh, install-kind.sh, hack/lint.sh),
read release notes between the old and new versions for each.

Sources by dep:
- KIND: gh api repos/kubernetes-sigs/kind/releases --paginate (has
  explicit "Breaking Changes" headings in .body)
- MetalLB: curl the in-repo release notes at
  raw.githubusercontent.com/metallb/metallb/main/website/content/release-notes/_index.md
- KubeVirt: gh api repos/kubevirt/kubevirt/releases --paginate
  (tagged by SIG — focus on SIG-network, Deprecation, API change)
- golangci-lint: curl CHANGELOG.md from the repo
  raw.githubusercontent.com/golangci/golangci-lint/main/CHANGELOG.md
- controller-runtime: gh api repos/kubernetes-sigs/controller-runtime/releases
  --paginate (focus on Breaking Changes in .0 minor releases; also
  check deprecations and removed APIs — e.g. webhook builder changes)

Also check for other non-k8s ecosystem deps that were bumped
by more than a minor version (check go.mod diff). For any such
dep, search for its release notes or changelog on GitHub.

For each dep, extract entries between the old and new versions.
Focus on: breaking changes, deprecations, removed features,
default behavioral changes. Ignore: patch-level bug fixes,
documentation changes, features behind alpha gates.

For each concern found, check whether:
1. The autofix already addresses it (check the diff)
2. The repo actually uses the affected feature (grep source
   AND grep CI scripts like kind-common.sh for flags/defaults)

Report format per dep:
  [dep] old → new: BREAKING / DEPRECATION / none found

If release notes are unavailable (API failure, empty body),
note it and move on — do not block.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite specific
release note entries for any concerns.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step3-dep-release-notes PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
