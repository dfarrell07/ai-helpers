---
name: k8s-rebase
description: Rebase a Go project to a new Kubernetes version by bumping all k8s.io/* dependencies, running codegen, updating version references, and fixing build breakage with antagonistic review.
argument-hint: "<version> (e.g., 1.36.0)"
user-invocable: true
allowed-tools: Bash, Read, Agent
---

# Kubernetes Rebase

Automates the k8s dependency rebase for Go projects that consume
`k8s.io/*` packages. Phases 0-3 (mechanical) and known fix
patterns run via scripts. The agent handles compilation errors
and any issues the scripts can't fix automatically.

**Arguments:** $ARGUMENTS

**Use subagents freely.** Every step has a Gate that launches
subagents to verify work. Beyond the gates, spawn additional
subagents whenever useful — to investigate errors, review
diffs, run tests, or get a second opinion. Subagents are cheap
and catch mistakes the main agent misses because they see the
code fresh without prior assumptions.

**Container commands:** When running containers, always use
`podman` with `--userns=keep-id`. Never use `docker run` —
it creates root-owned files that break subsequent operations.
```
podman run --rm --security-opt label=disable --userns=keep-id -v "$(pwd):$(pwd)" -w "$(pwd)" docker.io/library/golang:VERSION ...
```

**Feature gates:** SetFromMap validates parent-dep consistency —
disabling a parent without its deps causes a validation error.
ALL gates (parents + deps) must go in SetFromMap AND in env vars
(`os.Setenv`/`t.Setenv`/`export KUBE_FEATURE_*`). The autofix
script handles this; do not remove gates from its SetFromMap
calls.

**Git operations:** Never use negated pathspecs with `git add`
(e.g., `git add -A -- . ':!dir'`). They fail when the path
is gitignored. Use plain `git add -A` instead.

---

## Phase 0-3: Mechanical Rebase

Run from the default branch (master/main). The script creates a
new timestamped branch. Do not reuse branches from prior runs.

```bash
#!/bin/bash
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$REPO_ROOT" ] && echo "ERROR: Not in a git repo" && exit 1
SCRIPT=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -z "$SCRIPT" ] && echo "ERROR: k8s-rebase.sh not found" && exit 1
exec bash "$SCRIPT" $ARGUMENTS
```

Exit 0: already at target. Exit 1: error. **Exit 2: success —
proceed to Phase 4.** The Bash tool displays exit 2 as an error
but it means Phase 0-3 completed. Check `git log` for rebase
commits. Do NOT re-run the script.

If the output says "Could not detect OCP target", check the
repo's CI config in `openshift/release` or compare with an
existing manual rebase PR for the correct `openshift-X.Y`
version in `.ci-operator.yaml` and Dockerfiles.

---

## Phase 4: Build Validation and Fixups

Every step ends with subagent verification. The step is not
complete until all subagents report zero issues. Subagents
must report specific counts, not just "looks good."

Gate subagents need context: give them the repo path and tell
them to use `podman run --userns=keep-id` with the golang
container if they need Go tools (build, vet, lint, test).
If you cannot launch subagents, run the gate checks inline.

### Step 1: Fix compilation errors

```bash
SCRIPT=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-validate.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
if [ -n "$SCRIPT" ]; then
  bash "$SCRIPT" --quick
else
  make 2>&1 | tee /tmp/rebase-build.log
fi
```

Exit 0: no errors. Exit 1: errors in `.rebase-tmp/summary.txt`.
Use `--quick` (~1 min, build + vet only) during fix iterations.
Full validation runs in Step 3.

If summary contains `## CODEGEN FAILURE`, fix the codegen script
(e.g. remove dropped flags), re-run codegen, commit, re-validate.

Fix compilation errors from ALL modules (find all go.mod files).
If errors appear in `/go/pkg/mod/` paths (not the project's own
code), a direct dependency is incompatible with the bumped k8s
packages. Extract the module path (between `/go/pkg/mod/` and
`@`) and fix with `go get <module>@latest && go mod tidy`.
When converting types, read the FULL struct definition and map
ALL fields. Check test files for the same type changes — test
files often use the same types as source files. Create separate
`--signoff` commits per fix category.

Expect multiple validate cycles — vet can only check files that
compile, so fixing build errors reveals new vet errors.

**Parallel investigation:** If summary.txt has multiple error
categories, launch read-only Explore subagents to investigate
each in parallel. Give each subagent the errors and ask it to
read the relevant source AND test files and vendored types,
then report what changed and what the fix should be.
Investigation subagents must NOT edit files — apply fixes
yourself based on their findings.

**Type conversion review:** After each commit that converts
between struct types, launch a subagent: "Read the diff of
this commit. For each struct conversion, read the FULL struct
definition in vendor and list ALL fields. Compare against the
conversion code. Report any fields present in the struct but
missing from the conversion."

**Gate:** Launch 3 count-check subagents in parallel (must all be 0):
1. "Find all go.mod files (excluding vendor). Run `go build ./...` in each module directory. Report the total error count."
2. "Find all go.mod files (excluding vendor). Run `go vet ./...` in each module directory. Report the total error count."
3. "Read each fix commit's diff. Count files that are not Go source, tests, docs, CI configs, or build files. Report the count."

Also launch 2 judgment subagents (can flag concerns, not just counts):
4. "Review the type conversions in the fix commits. For each struct conversion, did the agent map ALL fields from the source struct? Are any fields silently dropped? Could any conversion lose data at runtime?"
5. "Review the fix commits for correctness. Did the agent understand WHY each change was needed, or did it just make the compiler happy? Are there any fixes that compile but would behave incorrectly at runtime?"

All counts must be 0. If judgment subagents flag concerns, investigate before proceeding.

### Step 2: Run autofix script

```bash
SCRIPT=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-autofix.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -n "$SCRIPT" ] && bash "$SCRIPT"
```

Applies known fix patterns and outputs RESULT: PASS or FAIL.
If FAIL, fix remaining items and re-run until PASS. Read the
patterns doc for unfamiliar patterns:
```bash
PATTERNS=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-patterns.md" -path "*/k8s-rebase/docs/*" 2>/dev/null | head -1)
[ -n "$PATTERNS" ] && cat "$PATTERNS"
```

**Gate:** Launch 3 count-check subagents in parallel (must all be 0):
1. "Count files with `golang.org/x/exp` imports (excluding vendor). Count files with `reflect.Ptr` (excluding vendor). Count files with `FieldsV1.Raw` (excluding vendor). Report all three counts."
2. "Read the GATE_DEPS map at the top of the autofix script. For each parent gate and its deps, count test files with SetFromMap or KUBE_FEATURE_ that are missing any of those gates. Report the count."
3. "Run `make lint` in each module that has a `lint:` target in its Makefile. If no module has a lint target, report 0 — lint isn't part of this repo's CI. From the output, count only lines containing `(gci)` and `(nilness)` as separate numbers. Ignore other linter issues — golangci-lint has exclude rules that may show warnings but still exit 0."

Also launch 2 judgment subagents:
4. "Review the feature gate handling across all test files. Could any gate configuration cause tests to hang or crash with fake clientsets? Are all parent AND dependent gates present in both SetFromMap and env vars?"
5. "Read the autofix commit's diff. Verify that x/exp → stdlib replacements are correct (maps.Keys wrapped in slices.Collect, imports in stdlib section). Verify feature gate entries match between SetFromMap, env vars, and test-go.sh. Report any inconsistencies."

gci count must be 0. If nilness count is non-zero, fix them now
(see Step 3 nilness guidance) before proceeding — this avoids
a full validation cycle in Step 3.

### Step 3: Lint and test verification

The lint version bump surfaces pre-existing issues. Fix them
all — they will block CI.

1. Run the validate script without flags (~15 min, full checks)
2. Fix every reported issue — ALL of them, not just the first
3. Commit fixes
4. Re-run validate (use `--quick` for fast iteration, no flags for full)
5. Repeat until exit 0
6. Optional: run with `--full` for privileged test coverage
   (`--full` may show pre-existing test failures — check if
   they also fail on master before investigating)

**Test caching:** Always use `-count=1` when running tests
manually. Go's test cache can return stale passes that hide
real failures (e.g., informer timeouts from missing gates).

**Nilness dead code:** The bumped golangci-lint catches `if err
!= nil` blocks where err is guaranteed nil — either the function
doesn't return an error, or a prior `t.Fatal`/`return` already
handled it. Remove the entire dead block. Do not simplify or
restructure. Check for ALL nilness issues in the lint output.

**Privileged tests:** The validate script automatically skips
tests requiring CAP_NET_ADMIN (netlink, nftables, VRF) in
default mode. Use `--full` to run them as root. If you run
`make test` manually, expect "operation not permitted" for
privileged packages — this is normal in unprivileged containers.

```bash
SCRIPT=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-validate.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -n "$SCRIPT" ] && bash "$SCRIPT"          # full (~15 min)
# For iteration: bash "$SCRIPT" --quick     # build + vet only (~1 min)
```

**Gate:** Launch 3 count-check subagents in parallel (must all be 0):
1. "Run `make lint` in each module that has a `lint:` target in its Makefile. If no module has a lint target, report 0 — lint isn't part of this repo's CI. Report the exit code (0 = pass). Do NOT count raw output lines — golangci-lint has exclude rules that filter issues before the final result."
2. "Find packages modified by the rebase (git diff merge-base..HEAD, excluding vendor). Skip packages listed as root/privileged in hack/test-go.sh. Run unit tests on the remaining changed packages with feature gate env vars exported. Report the number of FAIL results."
3. "Count uncommitted tracked files (`git status --short | grep -v '^[?]' | wc -l`). Count root-owned files outside .git and vendor. Count .rebase-tmp files tracked by git (`git ls-files .rebase-tmp`). Report all three counts."

Also launch 1 judgment subagent:
4. "Read the full rebase diff (excluding vendor). Would this diff pass upstream code review? Are there any changes a maintainer would question — unnecessary refactors, style changes mixed with rebase fixes, or changes that look like they could alter runtime behavior?"

All counts must be 0. Investigate any judgment concerns.

### Step 4: Antagonistic review

Once Step 3 validate passes (exit 0), launch Step 3 gate
subagents AND Step 4 subagents in parallel — no modifications
happen between them so they can verify simultaneously.

```bash
REVIEW=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-review.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
if [ -n "$REVIEW" ]; then
  COMMIT=$(git rev-parse HEAD)
  bash "$REVIEW" "$COMMIT" "k8s rebase"
fi
```

Launch 3 count-check subagents to check the full diff (must all be 0):
1. **Correctness:** "Read the full diff. Count changes that are not required by the rebase. Any change needed to compile, pass vet, pass lint, or pass tests with the new k8s version is valid (version bumps, type conversions, API renames, format string fixes, import reordering, codegen, feature gates, deprecated API migrations, dead code from stricter linters). Count format strings with wrong verbs. Count Eventf calls missing format directives. Report all counts."
2. **Completeness:** "Count stale v1.OLD version refs in yml/sh/md files (exclude K8S_VERSION which may stay at old version if kindest/node image isn't published yet). Count files with SupportBaselineAdminNetworkPolicy. Report all counts."
3. **Gates:** "Read the GATE_DEPS map in the autofix script. Count test files with SetFromMap or KUBE_FEATURE_ that are missing any gate from that map. Count SetFromMap files with more than 1 SetFromMap call. Report all counts."

Also launch 2 judgment subagents:
4. "Read the full diff and evaluate: does every change serve the k8s version bump, or are there unrelated cleanups, style changes, or logic alterations mixed in? Would a maintainer approve this diff as-is?"
5. "Look at the test changes in the diff. Are test expectations still correct for the new k8s version? Could any test pass locally but fail in CI due to missing fixtures, wrong API versions, or hardcoded assumptions?"

All counts should be 0. If any count is non-zero, determine
whether each item is toolchain-forced (acceptable) or truly
unrelated (fix before proceeding). Investigate judgment concerns.

### Step 5: Done

```bash
rm -rf .rebase-tmp/
```
