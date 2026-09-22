# Step 3: Apply autofix patterns

Read `${PLUGIN_ROOT}/skills/k8s-rebase/steps/rules.md` first.

## Run the autofix script

Allow at least 10 minutes and wait for actual completion as in rules.md;
the autofix auto-containerizes and runs go vet internally.

The autofix outputs RESULT: PASS or RESULT: FAIL.
FAIL means some checks found issues the autofix could not fix automatically
(e.g., complex test refactors). Inspect those findings in this step's gates;
carry unresolved issues into the parent handoff. Both PASS and FAIL require
the gates below.

```bash
bash "${PLUGIN_ROOT}/scripts/k8s-rebase-autofix.sh"
```

Applies known fix patterns for the target k8s version.
The autofix does not write to summary.txt (that file comes from
the validate script).

If the autofix reports FAIL, the remaining issues will be
caught by the gates below. If remaining issues include feature
gates, read the GATE_DEPS map near the top of the autofix
script to discover which gates need entries. Each gate requires
three layers: (1) `export KUBE_FEATURE_<gate>=false` in
hack/test-go.sh, (2) os.Setenv/t.Setenv calls in test files
that already reference KUBE_FEATURE_ env vars, and (3) a key
in SetFromMap calls in test suite files. Check existing
patterns in each file for the insertion format. Only add gates
that exist in the vendored k8s.io/ code.

## Verify the script actually ran

If the script was not found, the output is empty, or no RESULT was produced,
inspect the execution failure before proceeding. PASS with no commits is
normal when no patterns needed fixing; the gates still check for omissions.

If FAIL, check `git log` for autofix commits -- if any
groups already committed, fix remaining items manually rather than
re-running. Re-running duplicates the committed groups (new
commits, not amends). Read the patterns doc for unfamiliar
patterns:

```bash
cat "${PLUGIN_ROOT}/docs/k8s-rebase-patterns.md"
```

## Gates

Run the orchestrator to collect companion evidence and discover gate state:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
bash "${PLUGIN_ROOT}/scripts/k8s-rebase-orchestrator.sh" gates "$REPO_ROOT" 3
```

Follow the gate procedure in rules.md. Delegate PENDING gates in a parallel
wave when workers are available, or review inline. Supply the absolute repo
and plugin paths, version, module safety rule, and gate prompt path.
Inspect cached non-PASS verdicts as well as pending work.

Gate directory: `${PLUGIN_ROOT}/gates/step3-autofix`

Gate files:

- `autofix-result.md` (count)
- `deprecated-api-remnants.md` (count)
- `feature-gates.md` (count)
- `major-version-imports.md` (count)
- `deprecated-calls.md` (count)
- `autofix-diff-review.md` (judge)
- `crd-validation.md` (count)
- `e2e-infra.md` (judge)
- `dep-release-notes.md` (judge)
- `patterns-completeness.md` (judge)

Use each gate's verdict criteria; report counts and cite evidence.

## Gate-fix loop

Follow rules.md's shared loop and three-iteration budget. Re-validate fixes
with `--quick` before refreshing all current-step evidence and reviews.
The gates also discover deprecated-but-compiling patterns beyond the autofix.

## Before advancing

Return gate outcomes, remaining issues, and consumed repair iterations to
the parent. Only the parent advances, using SKILL.md's protocol. Steps 4–5
remain mandatory after this handoff.
