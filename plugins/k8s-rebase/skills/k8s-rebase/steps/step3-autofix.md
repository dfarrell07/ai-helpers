# Step 3: Apply autofix patterns

PROGRESS: 60% complete

Read `${PLUGIN_ROOT}/skills/k8s-rebase/steps/rules.md` first.

## Run the autofix script

The autofix applies known fix patterns for the target version and commits
each group. It can auto-containerize and runs go vet internally; allow at
least 10 minutes and wait for actual completion as in rules.md.

```bash
bash "${PLUGIN_ROOT}/scripts/k8s-rebase-autofix.sh"
```

It ends with `RESULT: PASS` or `RESULT: FAIL` and does not write
`summary.txt`. FAIL means checks remain that it could not fix (for example,
complex test refactors). Both results require the gates below. If the output
is empty or has no RESULT, investigate the execution failure before
proceeding. PASS with no commits is normal when no pattern applied.

If any autofix groups were committed, do not rerun it: that duplicates them
as new commits. Fix the remaining items manually, using the patterns doc
for unfamiliar ones:

```bash
cat "${PLUGIN_ROOT}/docs/k8s-rebase-patterns.md"
```

For remaining feature-gate issues, read the `GATE_DEPS` map near the top of
the autofix script. Each gate needs three layers, following each file's
existing format: (1) `export KUBE_FEATURE_<gate>=false` in hack/test-go.sh,
(2) `os.Setenv`/`t.Setenv` in test files that already reference
`KUBE_FEATURE_` variables, and (3) a key in test-suite `SetFromMap` calls.
Add only gates present in the vendored k8s.io/ code.

For KIND reference warnings, trace the effective image through scripts,
Makefiles, and CI environment overrides. The helper only rewrites direct
references and identifiable variable consumers; indirect consumers need
review. A correct script default can still be overridden by an unavailable
CI tag. Use a verified patch in the target minor, retain intentional upgrade
source versions, and verify replacement digests or private-registry images
separately. A registry lookup failure is unresolved verification.

## Gates

Run the orchestrator to collect companion evidence and discover gate state:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
bash "${PLUGIN_ROOT}/scripts/k8s-rebase-orchestrator.sh" gates "$REPO_ROOT" 3
```

Follow the gate procedure in rules.md. Delegate PENDING gates in a parallel
wave when workers are available, or review inline. Supply the absolute repo
and plugin paths, version, module safety and verdict rules, and gate prompt path.
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

Follow rules.md's shared loop and three-iteration budget. After each fix
commit, re-run `bash "$PLUGIN_ROOT/scripts/k8s-rebase-validate.sh" --quick`
before refreshing all current-step evidence and reviews.
The gates also discover deprecated-but-compiling patterns beyond the autofix.

## Before advancing

Return gate outcomes, remaining issues, and consumed repair iterations to
the parent. Only the parent advances, using SKILL.md's protocol. Do NOT stop
or declare the rebase done: Steps 4 and 5 are mandatory.
