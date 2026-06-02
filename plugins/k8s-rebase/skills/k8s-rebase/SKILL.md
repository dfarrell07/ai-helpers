---
name: k8s-rebase
description: Rebase a Go project to a new Kubernetes version by bumping all k8s.io/* dependencies, running codegen, updating version references, and fixing build breakage with antagonistic review.
argument-hint: "<version> (e.g., 1.36.0)"
user-invocable: true
allowed-tools: Bash, Read
---

# Kubernetes Rebase

Automates the k8s dependency rebase for Go projects that consume
`k8s.io/*` packages. Phases 0-3 (mechanical) and known fix
patterns run via scripts. The agent handles compilation errors
and any issues the scripts can't fix automatically.

**Arguments:** $ARGUMENTS

---

## Phase 0-3: Mechanical Rebase

```bash
#!/bin/bash
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$REPO_ROOT" ] && echo "ERROR: Not in a git repo" && exit 1
SCRIPT=$(find "$HOME/.claude" -name "k8s-rebase.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -z "$SCRIPT" ] && echo "ERROR: k8s-rebase.sh not found" && exit 1
exec bash "$SCRIPT" $ARGUMENTS
```

Exit 0: already at target. Exit 1: error. Exit 2: proceed to Phase 4.

---

## Phase 4: Build Validation and Fixups

### Step 1: Validate and fix compilation errors

```bash
SCRIPT=$(find "$HOME/.claude" -name "k8s-rebase-validate.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -n "$SCRIPT" ] && bash "$SCRIPT" || make 2>&1 | tee /tmp/rebase-build.log
```

Exit 0: no errors. Exit 1: errors found in `.rebase-tmp/summary.txt`.

```bash
[ -f .rebase-tmp/summary.txt ] && cat .rebase-tmp/summary.txt
```

If summary contains `## CODEGEN FAILURE`, fix the codegen script
(e.g. remove dropped flags), re-run codegen, commit, re-validate.

Fix compilation errors from ALL modules — not just go-controller.
When converting types, read the FULL struct definition and map
ALL fields. Create separate `--signoff` commits per fix category.

### Step 2: Run autofix script

```bash
SCRIPT=$(find "$HOME/.claude" -name "k8s-rebase-autofix.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -n "$SCRIPT" ] && bash "$SCRIPT"
```

The script applies all known fix patterns (x/exp→stdlib,
reflect.Ptr→Pointer, conformance renames, AddToScheme→Install,
feature gates, format strings, docs version, etc.) and runs
a verification block. It outputs RESULT: PASS or FAIL.

If **PASS**: proceed to Step 3.

If **FAIL**: the script lists exactly what remains with file:line
details. Fix those items, then re-run the script until PASS.
For unfamiliar patterns, read the patterns doc:
```bash
PATTERNS=$(find "$HOME/.claude" -name "k8s-rebase-patterns.md" -path "*/k8s-rebase/docs/*" 2>/dev/null | head -1)
[ -n "$PATTERNS" ] && cat "$PATTERNS"
```

### Step 3: Re-validate

Re-run validation to catch any remaining lint or vet issues:

```bash
SCRIPT=$(find "$HOME/.claude" -name "k8s-rebase-validate.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -n "$SCRIPT" ] && bash "$SCRIPT"
```

Exit 0: proceed to Step 4. Exit 1: fix errors, commit, re-run.

### Step 4: Antagonistic review

```bash
REVIEW=$(find "$HOME/.claude" -name "k8s-rebase-review.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
if [ -n "$REVIEW" ]; then
  COMMIT=$(git rev-parse HEAD)
  bash "$REVIEW" "$COMMIT" "k8s rebase"
fi
```

If REJECT: revert, retry with feedback. After 2 cycles, flag
for human review.

### Step 5: Done

```bash
rm -rf .rebase-tmp/
```
