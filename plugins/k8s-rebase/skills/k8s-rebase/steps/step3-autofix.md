# Step 3: Apply autofix patterns

PROGRESS: 60% complete

Read `${PLUGIN_ROOT}/skills/k8s-rebase/steps/rules.md` first.

## Run the autofix script

Use `timeout: 600000` -- the autofix auto-containerizes and
runs go vet internally.

The autofix outputs RESULT: PASS or RESULT: ITEMS_REMAINING.
ITEMS_REMAINING is normal -- it means the repo has patterns the
autofix documents but cannot fix automatically (e.g., complex
test refactors). The agent handles those in Step 4.
Regardless of output, proceed to gates.

```bash
bash "${PLUGIN_ROOT}/scripts/k8s-rebase-autofix.sh"
```

Applies known fix patterns (code fixes, feature gates, lint
version, CRD validation fixes, kubeadm v1beta4).
The autofix does not write to summary.txt (that file comes from
the validate script).

## If autofix is unavailable or skips a repo

Check these manually (derive the k8s version from go.mod
`k8s.io/api`). Skip any item the autofix already committed
(`git log --oneline` shows autofix commits with "Applied:" in
the message):

- KIND image: `grep -rn 'kindest/node:' . --include='*.sh' --include='*.yaml' --include='*.yml' | grep -v vendor/` -- update to `v<k8s-version>` (e.g., v1.36.1 for k8s 1.36). Check https://hub.docker.com/r/kindest/node/tags for the latest patch.
- kubeadm v1beta4: `grep -rn 'extraArgs:' . --include='*.yaml' --include='*.yml' --include='*.sh' | grep -v vendor/` -- if the format is `extraArgs:\n    key: value` (flat map), convert to `extraArgs:\n- name: key\n  value: "value"` (list-of-objects). Required for k8s >= 1.31.
- CI dependency versions: `grep -rniE '_VERSION\s*=' . --include='*.sh' | grep -v vendor/` -- pinned CI tool versions may need bumping when k8s tightens CRD validation. Get the latest release tag and update.
- Feature gate exports: `grep -rn 'KUBE_FEATURE_' . --include='*.sh' | grep -v vendor/` -- check the rebase script output for new default-true gates. Add `export KUBE_FEATURE_<name>=false` to `hack/test-go.sh` if the repo's tests use fake clientsets with informers.

## Verify the script actually ran

If the output is empty or the script was not found, the autofix
was skipped and all its fixes are missing. If the autofix reports
PASS with no commits, that means there were no patterns to fix --
this is normal for repos with few k8s dependencies.

**You must still run the step3 gates below** -- they discover
issues the autofix does not cover.

If ITEMS_REMAINING, check `git log` for autofix commits -- if any
groups already committed, fix remaining items manually rather than
re-running. Re-running duplicates the committed groups (new
commits, not amends). Read the patterns doc for unfamiliar
patterns:

```bash
cat "${PLUGIN_ROOT}/docs/k8s-rebase-patterns.md"
```

## Gates

Launch one subagent per gate file listed below. All in one
parallel wave. Each subagent prompt: repo path + module safety
rule (from rules.md) + "Read `<GATE_DIR>/<filename>` and follow
its instructions." Do NOT Read the gate files yourself -- let the
subagent Read the gate file.

Do not skip, batch, or defer any gate -- launch all 11 in a
single message. Gate subagents run independently and do not
consume your context window.

Gate directory: `${PLUGIN_ROOT}/gates/step3-autofix`

Gate files:
- `autofix-result.md` (count)
- `deprecated-api-remnants.md` (count)
- `feature-gates.md` (count)
- `major-version-imports.md` (count)
- `deprecated-calls.md` (count)
- `autofix-diff-review.md` (judge)
- `crd-validation.md` (count)
- `logical-completeness.md` (count)
- `e2e-infra.md` (judge)
- `dep-release-notes.md` (judge)
- `patterns-completeness.md` (judge)

Count gates must report 0. Judge gates must cite evidence.

## Gate-fix loop

If ANY gate reports FAIL (count gate with issues > 0, OR judge
gate with verdict FAIL):

1. **Triage**: Read each FAIL gate report (DETAILS with
   file:line). For each finding, check the base branch:
   `BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)`
   `git show $BASE:<file>` -- if the same issue exists on the
   base branch, it is pre-existing. If the file does not exist
   on base (new file), the finding IS new. Skip pre-existing
   findings.

2. **Fix**: For each NEW finding, fix the cited issue and
   commit.

3. **Re-run** (mandatory -- never skip this step): Delete the
   old gate report first (`rm .rebase-tmp/gates/<gate>.report`),
   then re-run the gate (let the subagent Read the gate file and
   follow its instructions). The old report MUST be deleted
   before re-running -- if the agent fixes code but skips
   re-running, stale FAIL reports persist and auto-record will
   report FAIL even though the issue was fixed.

Repeat up to 3 times per gate. If it still fails after 3
attempts, report remaining issues and proceed. This loop
discovers and fixes deprecated-but-compiling patterns without
needing pre-existing autofix knowledge.

## Before advancing

If you modified any go.mod in steps 2-3 (gate-fix loop, manual
dep bumps), re-run `go mod tidy && go mod vendor` in each
affected module directory. Stale vendor causes CI failures.

When all step3 gates pass (or remaining issues are reported after
3 attempts), proceed immediately. Do NOT stop or declare the
rebase "done" -- Steps 4 and 5 are mandatory.

Run `orchestrator.sh advance` to proceed to Step 4.
