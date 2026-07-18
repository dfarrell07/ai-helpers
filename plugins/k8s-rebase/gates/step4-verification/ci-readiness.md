Step 3 already verified autofix patterns (deprecated APIs, CRD
validation, feature gates, e2e infra). Do NOT re-check those —
focus on CI-specific gaps that only matter at ship time:

1. Does any e2e test or CI config reference a hardcoded k8s
   version, KIND image tag, or container image that needs updating?
   Check ALL workflow files for KIND binary version consistency:
   `grep -rn 'kind.sigs.k8s.io/dl/v\|KIND_VERSION=v' .github/ --include="*.yml" --include="*.yaml" 2>/dev/null`
2. Are there test skips that should be added or removed for this
   k8s version?
3. Are there patterns in the doc that the agent should have fixed
   manually but didn't? Read the patterns doc and check the
   branch diff for each documented manual fix.
4. Would the KIND image tag actually exist? Search the web
   for "kindest/node <version>" or run:
   `skopeo inspect --no-creds docker://docker.io/kindest/node:v<version> 2>/dev/null`
   If the tag doesn't exist yet, note as a warning (not a FAIL).

Flag gaps that would cause CI failures. List each item checked
and your finding.

Rules: you are read-only — do not edit repo files. Your sole
permitted write is your gate report file under .rebase-tmp/gates/.
Do not write anywhere else. Cite file:line
for any issues.

After your analysis, write your report using the helper script.
The repo path is the first line of your prompt:

```bash
REPO="<the repo path from the first line of your prompt>"
bash "$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "write-gate-report.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)" \
  "$REPO" step4-ci-readiness PASS 0 "your one-line summary" \
  "detail line 1" "detail line 2"
```

Use PASS, FAIL, or SKIP as the verdict. Replace the summary and
details with your actual findings.
