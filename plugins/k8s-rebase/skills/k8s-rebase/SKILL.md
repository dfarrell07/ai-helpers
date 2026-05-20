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
If exit 1: read `.rebase-tmp/summary.txt` for categorized errors.

### Step 3: Fix errors (priority order)

Read the error summary, new feature gates, and breakage patterns:

```bash
cat .rebase-tmp/summary.txt
[ -f .rebase-tmp/new-gates.txt ] && echo "NEW GATES:" && cat .rebase-tmp/new-gates.txt
PATTERNS=$(find "$HOME/.claude" -name "k8s-rebase-patterns.md" -path "*/k8s-rebase/docs/*" 2>/dev/null | head -1)
[ -n "$PATTERNS" ] && cat "$PATTERNS"
```

**Fix priority — always try in this order:**

**Priority 1: Fix the code.** API changes, type mismatches, renamed
functions, resource leaks. Read the error, read the source, apply
the minimal correct fix. This is the goal — keep tests running with
real fixes. Example: WatchFactory leak (add Shutdown() in test
teardown), renamed function (update call site + imports).

When converting between types (e.g., metav1.Condition to a builder
pattern), read the FULL source struct definition and map ALL fields
— not just the ones you see callers set. Zero-valued fields still
need mapping to avoid silent data loss.

**Priority 2: Fix test infrastructure.** If tests hang or timeout,
investigate the root cause before disabling anything. Check:
- Is there a resource leak in test setup/teardown? (Fix it.)
- Is a test creating clients without proper cleanup? (Fix it.)
- Is a newer fake clientset API available that supports the
  feature? (Use it.)
- Is the test actually testing ovnk logic, or k8s internals?

**Priority 3 (last resort): Configure test environment.** Only after
confirming the failure is caused by a k8s infrastructure limitation
(e.g., fake clientset doesn't implement a new API) and no code fix
exists. When disabling a feature gate:
- Add a comment with the upstream issue URL
- Add `TODO(rebase): re-enable when <upstream issue> is resolved`
- Check for gate dependencies (disable dependents first in a
  separate SetFromMap call)
- Commit message must explain WHY disable is necessary, not just
  WHAT was disabled

For each error category, create its own independently revertable
commit with `--signoff` and a descriptive message.

**Handling TIMEOUT errors:** If the summary shows `## TIMEOUT`,
tests are likely hanging due to a feature gate or resource leak.
Check `.rebase-tmp/new-gates.txt` for new gates. Run individual
test packages to isolate which one hangs. Distinguish a hang
(never terminates — feature gate or resource leak) from slowness
(finishes in 15+ minutes — container resource limit, adjust
`VALIDATION_TIMEOUT`). Fix the root cause; disable gates only
as Priority 3 last resort.

### Step 4: Re-validate

After each fix batch, re-run the validation script. Only proceed
to review once the failing step passes.

### Step 5: Antagonistic review

After each fix commit passes validation, run the review script:

```bash
REVIEW=$(find "$HOME/.claude" -name "k8s-rebase-review.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
if [ -n "$REVIEW" ]; then
  COMMIT=$(git rev-parse HEAD)
  # Pass the original error that triggered this fix (from .rebase-tmp/summary.txt)
  bash "$REVIEW" "$COMMIT" "PASTE_THE_ORIGINAL_ERROR_FROM_SUMMARY"
fi
```

If REJECT: revert the commit, retry with the review feedback.
Bound: if the same error has been fixed and reverted 2 times,
flag for human review instead of looping.

### Done

When all validation passes and all fixes are approved, clean up
and report:

```bash
rm -rf .rebase-tmp/
```

The rebase branch is ready for PR submission.
