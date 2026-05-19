---
name: k8s-rebase
description: Rebase a Go project to a new Kubernetes version by bumping all k8s.io/* dependencies, running codegen, updating version references, and fixing build breakage with antagonistic review.
argument-hint: "<version> (e.g., 1.36.0)"
user-invocable: true
allowed-tools: Bash, Read
---

# Kubernetes Rebase

Automates the k8s dependency rebase for Go projects that consume
`k8s.io/*` packages. Works for any repo with k8s.io dependencies
(ovn-kubernetes, multus-cni, cluster-network-operator, etc.).

Phases 0-3 (mechanical) run via script. Phase 4 (build validation
and fixups) is agent-guided with antagonistic review.

**Usage:** `/k8s-rebase:k8s-rebase 1.36.0`

**Arguments:** $ARGUMENTS

---

## Phase 0-3: Mechanical Rebase

Run the orchestrator script. It handles prerequisite checks,
3-rule go.mod derivation (97% coverage), module dependency updates,
code generation (if present), and version reference updates.

```bash
#!/bin/bash
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  echo "ERROR: Not in a git repository"
  exit 1
fi
SCRIPT=$(find "$HOME/.claude" -name "k8s-rebase.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
if [ -z "$SCRIPT" ]; then
  echo "ERROR: k8s-rebase.sh not found in ~/.claude/plugins/"
  echo "Install: enable the k8s-rebase plugin from ai-helpers marketplace"
  echo "Or run directly: bash /path/to/ai-helpers/plugins/k8s-rebase/scripts/k8s-rebase.sh $ARGUMENTS"
  exit 1
fi
exec bash "$SCRIPT" $ARGUMENTS
```

Exit 0: already at target version, done.
Exit 1: error — diagnose from the output.
Exit 2: mechanical steps done, proceed to Phase 4.

---

## Phase 4: Build Validation and Fixups

### Step 1-2: Collect and categorize errors

```bash
SCRIPT=$(find "$HOME/.claude" -name "k8s-rebase-validate.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
if [ -n "$SCRIPT" ]; then
  bash "$SCRIPT"
else
  echo "Validate script not found, running make manually"
  make 2>&1 | tee /tmp/rebase-build.log
fi
```

If exit 0: all validation passes, done.
If exit 1: read `/tmp/rebase-summary.txt` for categorized errors.

### Step 3: Fix errors

Read the error summary and the breakage patterns reference:

```bash
cat /tmp/rebase-summary.txt
PATTERNS=$(find "$HOME/.claude" -name "k8s-rebase-patterns.md" -path "*/k8s-rebase/docs/*" 2>/dev/null | head -1)
[ -n "$PATTERNS" ] && cat "$PATTERNS"
```

For each error category in the summary:

1. Read the extracted error lines (file paths and symbols)
2. Check if a pattern from the patterns file matches
3. Read the affected source files
4. Apply the fix — the minimal change that addresses the error
5. Commit with `--signoff` and a descriptive message
   (e.g., `"Fix e2e tests failure"`, `"Fix lint issues"`)

Each fix category gets its own independently revertable commit.

### Step 4: Re-validate

After each fix batch, re-run the validation script. Only proceed
to review once the failing step passes.

### Step 5: Antagonistic review

After each fix commit passes validation, run the review script:

```bash
REVIEW=$(find "$HOME/.claude" -name "k8s-rebase-review.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
if [ -n "$REVIEW" ]; then
  COMMIT=$(git rev-parse HEAD)
  bash "$REVIEW" "$COMMIT" "ORIGINAL_ERROR_HERE"
fi
```

If REJECT: revert the commit, retry with the review feedback.
Bound: if the same error has been fixed and reverted 2 times,
flag for human review instead of looping.

### Done

When all validation passes and all fixes are approved, the rebase
branch is ready for PR submission.
