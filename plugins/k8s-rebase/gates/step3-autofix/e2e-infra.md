If e2e infrastructure was modified (kind-common.sh, kind.yaml.j2,
e2e-kind.sh, install-kind.sh, CI workflows), verify the changes
are consistent with the target k8s version.

For each modified e2e file, check:
- Do version references (k8s version strings, kindest/node tags)
  match the target version from go.mod?
  `grep -rn 'kindest/node\|K8S_VERSION\|KIND_VERSION' . | grep -v vendor/`
- KIND binary version: search the web for "kind releases" to
  find which KIND version supports the target k8s version.
  Each KIND release supports specific k8s versions — using an
  old KIND with a new k8s will fail. Report the fix command:
  `sed -i 's/KIND_VERSION=v<old>/KIND_VERSION=v<new>/' <file>`
- Are external tool versions consistent across all CI files?
- Do configuration formats (e.g., kubeadm config apiVersion)
  match what the new k8s version requires? Search the web for
  "k8s <version> kubeadm config" if unsure about required format.

List each item checked and whether it passes. Report issues.

If the repo has no e2e infrastructure files, skip this check.

MANDATORY pre-existing check — run for EVERY finding:

```bash
BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)
# For each finding at <file> with <version_string>:
base_has=$(git show "$BASE:<file>" 2>/dev/null | grep -c '<version_string>')
# If base_has > 0, PRE-EXISTING — do NOT count it
```

If a version issue exists on the base branch, report as "INFO
(pre-existing)" and do NOT include in ISSUES. Only issues NOT
on base are NEW. If ALL findings are pre-existing, verdict MUST
be PASS.

VERDICT: FAIL only if NEW e2e infrastructure issues exist (not
on base branch). PASS if all issues are pre-existing or all
e2e infra is consistent.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line
for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step3-e2e-infra PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
