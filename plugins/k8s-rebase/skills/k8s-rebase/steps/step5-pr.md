# Step 5: PR and Cleanup

**PROGRESS: 95% complete**

Read `${PLUGIN_ROOT}/skills/k8s-rebase/steps/rules.md` first.

**CRITICAL: NEVER run `git push` or `gh pr create` yourself.**
Only print commands for the user to copy-paste.

## 5a. Gather data and detect downstream

```bash
PRIMARY_GOMOD=$(find . -name go.mod -not -path '*/vendor/*' -not -path '*/.claude/*' -exec grep -l 'k8s.io/' {} \; 2>/dev/null | head -1)
K8S_VER=$(grep 'k8s.io/api ' "$PRIMARY_GOMOD" 2>/dev/null | grep -oE 'v[0-9.]+' | head -1)
GO_VER=$(grep '^go ' "$PRIMARY_GOMOD" 2>/dev/null | awk '{print $2}')
IS_DOWNSTREAM=$(git remote -v 2>/dev/null | grep -q 'openshift/' && echo true || echo false)
BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)
```

**OCP version mapping** (see rules.md for the full table):
k8s 1.N → OCP 4.(N-13) for k8s ≤1.35. k8s 1.N → OCP 5.(N-36) for k8s ≥1.36.

If `IS_DOWNSTREAM` is true, the PR title needs a Jira ticket key.
If interactive, ask. If background mode, use `REPLACE-WITH-JIRA-KEY:`.

## 5b. Adversarial pre-PR review

Before generating the PR command, review the full rebase, not just the
last fix. The shared preparation and existing four-check rubric live in
`scripts/k8s-rebase-pr-review.sh`.

Select **only** the branch for the parent's host runtime from SKILL.md.
Delegating this step does not change that choice.

### Claude Code only

Preserve the nested reviewer and its existing failure policy. Do not use
`--print-prompt` or substitute a native review agent:

```bash
BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main)
VERDICT=$(bash "$PLUGIN_ROOT/scripts/k8s-rebase-pr-review.sh" "$BASE" "$VERSION")
echo ":: Pre-PR review: $VERDICT"
```

Investigate `REJECT:` before proceeding. For Claude, `APPROVE:` or a missing
verdict from infrastructure failure retains the existing continuation policy.

### Codex only

Collect checked evidence without invoking Claude. Run preparation directly
and check its exit status; do not pipe it through `head` or another filter
that can hide failure or discard prompt content:

```bash
BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main) || exit 1
bash "$PLUGIN_ROOT/scripts/k8s-rebase-pr-review.sh" --print-prompt "$BASE" "$VERSION" || exit 1
```

Only after successful preparation, give the prompt, repo path, base, and HEAD
to a fresh-context read-only native reviewer. Require an explicit
`APPROVE: <reason>` or `REJECT: <reason>`. Missing/malformed verdicts, failed
preparation, or no independent reviewer stop this path; do not substitute
parent self-review. Investigate rejection before proceeding. On resume,
repeat review if its decision for this SHA/scope is unavailable. Do not
reuse approval after changes; refresh affected gates and review the final tip.

## 5c. Generate `gh pr create` command

**Do NOT execute this.** Print for user to copy-paste.

Run `git log --oneline $BASE..HEAD` for the commit list. PR body:

- One-line summary: k8s version, Go version
- What changed: fix categories from commit subjects
- Commit table: git log output, note mechanical vs manual
- Verification: what passed locally, plus unresolved/force-advanced gates
  from retained reports and `.rebase-tmp/status/INCOMPLETE` (the latter
  records only the latest force-advance). DONE does not mean all gates passed.
- Footer: "All commits carry `Assisted-by: Claude Code <noreply@anthropic.com>` trailers."

Output `gh pr create --title "..." --body "..."` using a heredoc.

## 5d. Suggest CI monitoring

For Claude when `/loop` is available, suggest:
`/loop 5m check CI on the PR, explore any failures max carefully`.
Otherwise suggest asking the agent to check CI after the user creates the PR;
do not configure automation.

## 5e. Clean up

```bash
rm -rf .rebase-tmp/step*.log .rebase-tmp/step*.pid .rebase-tmp/*.log \
       .rebase-tmp/*.txt .rebase-tmp/*.pid \
       .rebase-tmp/crd-pre-codegen/
rm -f .rebase-tmp/.session-active

# Remove the pre-push hook installed by k8s-rebase.sh (restore backup if exists)
HOOK_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/hooks"
if [[ -f "$HOOK_DIR/pre-push" ]] && grep -q 'k8s-rebase' "$HOOK_DIR/pre-push" 2>/dev/null; then
  rm -f "$HOOK_DIR/pre-push"
  [[ -f "$HOOK_DIR/pre-push.bak.k8s-rebase" ]] && mv "$HOOK_DIR/pre-push.bak.k8s-rebase" "$HOOK_DIR/pre-push"
fi
```

Do NOT delete `.rebase-tmp/gates/`.

---

Step 5 is the final step — the rebase is complete after PR
generation. Do NOT run orchestrator advance (step 5 is not in the
orchestrator's step list).
