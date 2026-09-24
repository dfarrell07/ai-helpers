# Step 5: PR and Cleanup

PROGRESS: 95% complete

Read `${PLUGIN_ROOT}/skills/k8s-rebase/steps/rules.md` first.

**CRITICAL: NEVER run `git push` or `gh pr create` yourself.**
Only print commands for the user to copy-paste.

## 5a. Gather data and detect downstream

```bash
PRIMARY_GOMOD=$(find . -name go.mod -not -path '*/vendor/*' -not -path '*/.claude/*' -exec grep -l 'k8s.io/' {} \; 2>/dev/null | head -1)
K8S_VER=$(grep 'k8s.io/api ' "$PRIMARY_GOMOD" 2>/dev/null | grep -oE 'v[0-9.]+' | head -1)
GO_VER=$(grep '^go ' "$PRIMARY_GOMOD" 2>/dev/null | awk '{print $2}')
IS_DOWNSTREAM=$(git remote -v 2>/dev/null | grep -q 'openshift/' && echo true || echo false)
BASE=$(bash "$PLUGIN_ROOT/scripts/resolve-rebase-base.sh" "$(git rev-parse --show-toplevel)")
```

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
BASE=$(bash "$PLUGIN_ROOT/scripts/resolve-rebase-base.sh" "$(git rev-parse --show-toplevel)")
VERDICT=$(bash "$PLUGIN_ROOT/scripts/k8s-rebase-pr-review.sh" "$BASE" "$VERSION")
echo ":: Pre-PR review: $VERDICT"
```

Investigate `REJECT:` before proceeding. For Claude, `APPROVE:` or a missing
verdict from infrastructure failure retains the existing continuation policy;
report a missing verdict as review not performed.

### Codex only

Collect checked evidence without invoking Claude. Capture the complete prompt
in a unique scratch file, preserving it beyond tool-output limits. Check the
completed status; preparation success is not approval:

```bash
BASE=$(bash "$PLUGIN_ROOT/scripts/resolve-rebase-base.sh" "$(git rev-parse --show-toplevel)") || exit 1
REVIEW_PROMPT=$(mktemp "$REPO_ROOT/.rebase-tmp/step5-review-XXXXXX") || exit 1
prep_rc=0
bash "$PLUGIN_ROOT/scripts/k8s-rebase-pr-review.sh" --print-prompt "$BASE" "$VERSION" > "$REVIEW_PROMPT" || prep_rc=$?
printf '\nPreparation exit status: %s\n' "$prep_rc"
if [[ "$prep_rc" -eq 0 ]]; then
  printf 'Review prompt file: %s\n' "$REVIEW_PROMPT"
fi
exit "$prep_rc"
```

Only after successful preparation, give that invocation's prompt-file path,
repo path, base, and HEAD to a fresh-context read-only native reviewer. Require
it to read the complete file, using bounded chunks if needed, including the
scope and any helper truncation warning. Do not substitute a tool preview or
a prior prompt file. Require an explicit
`APPROVE: <reason>` or `REJECT: <reason>`. Missing/malformed verdicts, failed
preparation, or no independent reviewer stop this path; do not substitute
parent self-review. Investigate rejection before proceeding. On resume,
repeat review if its decision for this SHA/scope is unavailable. Do not
reuse approval after changes; refresh affected gates and review the final tip.

## 5c. Generate `gh pr create` command

**Do NOT execute this.** Print for user to copy-paste.

Before drafting verification claims, run this inventory from the expected
gate prompts, not just the reports that happen to exist:

```bash
# Bind PLUGIN_ROOT and REPO_ROOT to the verified paths in this call.
bash "$PLUGIN_ROOT/scripts/k8s-rebase-orchestrator.sh" reports "$REPO_ROOT"
```

Nonzero exit stops reporting; a successful inventory is not passing
validation. Copy its verdict totals and freshness warnings rather than
hand-counting. Copy the generated Markdown gate table into the PR body
verbatim: keep every exact gate name, verdict, reviewed HEAD, and freshness
label. Do not reconstruct names from memory, rename gates as test suites,
combine rows into "additional gates", or add rows for checks absent from
the inventory. Read each report's HEAD, exact VERDICT, and findings, and
`.rebase-tmp/status/INCOMPLETE` if present; quote its force-advance wording
and do not describe advance attempts as repairs or tests. INCOMPLETE records
only the latest force-advance, so list every unresolved or unverified check
from the inventory, including prior steps. Missing, unreadable, or malformed
reports are unverified, not PASS.

In the PR body, keep PASS, justified SKIP (with its reason), and unresolved
FAIL/INCONCLUSIVE distinct. A prior-step PASS is evidence at its recorded
SHA, not a retest of the final tip, and a stale final-step report does not
verify final HEAD. Never manufacture or relabel reports to fill gaps: DONE,
force-advancement, aggregate counts, and independent review approval change
no gate's verdict.

Report executed build, vet, lint, and test commands separately from the gate
table, using their actual outcomes. A PASS from a code-review or CI-prediction
gate does not establish that unit or integration tests passed. A test that
failed during environment setup remains failed/blocked, even when an isolated
base run reproduces that failure. Give the affected package or suite and
reason; mark skipped or unexecuted coverage unverified. Claim test PASS only
when that test command completed successfully at the stated revision.
Derive any package/test counts from complete output; a tail of the log cannot
establish totals. If the full output is unavailable, report the verified
command outcome and scope without inventing counts.
Include nonzero command exits and their failed/blocked scope. A successful
`validate --no-test` wrapper is not lint evidence when its output contains
no linter execution; label an absent lint configuration explicitly.
Do not rule out regressions solely because failing test source is unchanged.

Inspect `git diff "$BASE..HEAD"` and `git log --oneline "$BASE..HEAD"`.
Describe dependency bumps as old → new from removed/added lines, not unchanged
diff context. Confirm both versions in the base and result go.mod files:
moving an existing indirect requirement to the direct block is not adding a
new module. Commit subjects alone do not establish changes. PR body:

- One-line summary: "Rebase to Kubernetes <version> (Go <version>)."
- What changed: categories supported by the diff
- Commit table: git log output, note mechanical vs manual
- Verification: the generated gate table and its totals/freshness warnings,
  followed by actual command outcomes, reasons for SKIP, unresolved findings,
  and unverified coverage identified above.
- Footer: "All commits carry `Assisted-by: Claude Code <noreply@anthropic.com>` trailers."

Output `gh pr create --title "..." --body "..."` using a heredoc, followed by
cleanup status. Keep the verification account in that PR body; do not add a
second recap with new counts or change claims. Expected gates are not executed checks.

## 5d. Suggest CI monitoring

For Claude when `/loop` is available, suggest:
`/loop 5m check CI on the PR, explore any failures max carefully`.
Otherwise suggest asking the agent to check CI after the user creates the PR;
do not configure automation.

## 5e. Clean up

Use host-approved file operations: restore the hook, remove scratch, then
remove the session marker last. Stop on any failure. The Bash block is an
example, not a required execution mechanism; keep its exact targets and order.
When using a shell tool, preserve the explicit Bash wrapper: the host shell
may be zsh, which rejects unmatched globs before `rm` runs. Such an error is
failed cleanup, not an ignorable warning or proof that scratch was removed.

```bash
bash <<'K8S_REBASE_CLEANUP'
# Remove the pre-push hook installed by k8s-rebase.sh (restore backup if exists)
HOOK_DIR="$(git rev-parse --git-common-dir)/hooks" || exit 1
if [[ -f "$HOOK_DIR/pre-push" ]]; then
  HOOK_CONTENT=$(cat "$HOOK_DIR/pre-push") || exit 1
  if [[ "$HOOK_CONTENT" == *k8s-rebase* ]]; then
    if [[ -f "$HOOK_DIR/pre-push.bak.k8s-rebase" ]]; then
      mv "$HOOK_DIR/pre-push.bak.k8s-rebase" "$HOOK_DIR/pre-push" || exit 1
    else
      rm -f "$HOOK_DIR/pre-push" || exit 1
    fi
  fi
fi
rm -rf .rebase-tmp/step*.pid .rebase-tmp/*.pid \
       .rebase-tmp/step[45]-review-* \
       .rebase-tmp/crd-pre-codegen/ || exit 1
rm -f .rebase-tmp/.session-active || exit 1
K8S_REBASE_CLEANUP
```

Preserve `.rebase-tmp/gates/`, `base-commit`, target-version records,
validation summaries, full `*.log` files, and `test-only-*` test output. These
are verification evidence needed to audit the PR's claims, not disposable
process scratch. If cleanup cannot be completed with allowed
tools/access, report incomplete cleanup; do not disable guards or change permissions.
Verify the original hook (including executable mode) and that the listed
scratch targets are gone before claiming cleanup is complete.

---

Step 5 completes after full-rebase review, PR command generation, and
verified cleanup, with unresolved checks retained in the PR body.
Do not call orchestrator `advance`; Step 5 is outside its gated steps.
