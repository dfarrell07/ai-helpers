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
# Validate REPO_ROOT is a Go project, not a workspace meta-repo
if ! [[ -f "$REPO_ROOT/go.mod" || -f "$REPO_ROOT/go-controller/go.mod" ]]; then
  echo "ERROR: $REPO_ROOT has no go.mod — are you in a workspace root instead of the target repo?"
  exit 1
fi
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
must report specific counts, not just "looks good." Gate
subagents are read-only — they verify and report, but must
NOT edit files. The main agent applies fixes based on their
findings.

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

**Do NOT bump non-k8s dependencies** in other modules (e.g.,
`test/conformance/`) unless the build actually fails. The
conformance module may intentionally use a different version of
`network-policy-api` than go-controller — bumping it to match
can break CI (v0.2.0 conformance creates ClusterNetworkPolicy
resources that the controller doesn't support yet).
When converting types, read the FULL struct definition and map
ALL fields. Check test files for the same type changes — test
files often use the same types as source files. Create separate
`--signoff` commits per fix category. After fixing type
definitions, re-run `make generate` (if available) and commit
any regenerated files (e.g., `zz_generated.deepcopy.go`).

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

Applies known fix patterns (code fixes, feature gates, lint
version, AND e2e infra: MetalLB, KubeVirt, RelaxedServiceNameValidation).
Outputs RESULT: PASS or FAIL. If FAIL, fix remaining items and
re-run until PASS. Check output for MetalLB FRR image warnings —
if the autofix bumped MetalLB, verify the FRR image variable
matches what the new MetalLB version ships. Read the patterns doc
for unfamiliar patterns:
```bash
PATTERNS=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-patterns.md" -path "*/k8s-rebase/docs/*" 2>/dev/null | head -1)
[ -n "$PATTERNS" ] && cat "$PATTERNS"
```

**Gate:** Launch 2 count-check subagents in parallel (must all be 0):
1. "Count files with `golang.org/x/exp` imports (excluding vendor). Count files with `reflect.Ptr` (excluding vendor). Count files with `FieldsV1.Raw` (excluding vendor). Report all three counts."
2. "Read the GATE_DEPS map at the top of the autofix script. For each parent gate and its deps, count test files with SetFromMap or KUBE_FEATURE_ that are missing any of those gates. Report the count."

Also launch 2 judgment subagents:
3. "Review the feature gate handling across all test files. Could any gate configuration cause tests to hang or crash with fake clientsets? Are all parent AND dependent gates present in both SetFromMap and env vars?"
4. "Read the autofix commit's diff. Verify that x/exp → stdlib replacements are correct (maps.Keys wrapped in slices.Collect, imports in stdlib section). Verify feature gate entries match between SetFromMap, env vars, and test-go.sh. Report any inconsistencies."

All counts must be 0. Investigate judgment concerns.

### Step 3: Lint, test, and review

Fix lint issues first (they're fast to iterate on), then launch
one parallel wave that verifies everything at once.

**3a. Lint iteration:**

```bash
SCRIPT=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-validate.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -n "$SCRIPT" ] && bash "$SCRIPT" --no-test   # build + vet + lint (~5 min)
# For faster build/vet iteration: bash "$SCRIPT" --quick  (~1 min)
```

Fix every reported issue. The lint version bump surfaces
pre-existing issues — fix them all, they will block CI.

**Nilness dead code:** The bumped golangci-lint catches `if err
!= nil` blocks where err is guaranteed nil. Remove the entire
dead block. Do not simplify or restructure.

**Test caching:** Always use `-count=1` when running tests
manually. Go's test cache can return stale passes.

Iterate with `--quick` for build+vet, `--no-test` to include
lint. Repeat until `--no-test` exits 0.

**3b. Parallel verification wave:** Once `--no-test` passes,
launch ALL of the following subagents in one parallel wave.
No modifications happen after this point — everything runs
simultaneously.

First, discover test packages:

```bash
TEST_GO_SH=$(find . -name "test-go.sh" -path "*/hack/*" -not -path "*/vendor/*" | head -1)
ROOT_PKGS=""
[ -n "$TEST_GO_SH" ] && ROOT_PKGS=$(sed -n '/root_pkgs=(/,/)/p' "$TEST_GO_SH" | grep -oE 'pkg/[^"]+' | tr '\n' '|')
GATE_EXPORTS=""
[ -n "$TEST_GO_SH" ] && GATE_EXPORTS=$(grep "^export KUBE_FEATURE_" "$TEST_GO_SH" | tr '\n' '; ')
for mod_dir in $(find . -name "go.mod" -not -path "*/vendor/*" -exec dirname {} \; | sort); do
  echo "=== $mod_dir ==="
  for pkg in $(cd "$mod_dir" && find . -name "*_test.go" -not -path "*/vendor/*" -exec dirname {} \; | sort -u); do
    [ -n "$ROOT_PKGS" ] && echo "$pkg" | grep -qE "^\./(${ROOT_PKGS%|})" && continue
    echo "$pkg"
  done
done
```

**Test agents** (count-check, all must report 0 FAIL):
Split packages across subagents — count test lines per package
(`wc -l *_test.go`), cap ~30k lines per agent, give the biggest
package its own agent. Each agent uses the validate script's
`--test-only` flag, which handles containerization, feature gate
exports, timeout scaling, and output capture automatically:
```bash
SCRIPT=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-validate.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
bash "$SCRIPT" --test-only ./pkg/ovn/... ./pkg/util/...
```
Results are in `.rebase-tmp/test-only-*.log`. Do NOT run raw
`go test` inside containers — stdout piping across container
boundaries loses output. The `--test-only` flag writes to a log
file on the mounted volume, so results are always readable.

**Cleanliness agent** (count-check, all must be 0):
"Run on the host, NOT in a container. Count uncommitted tracked
files (`git status --short | grep -v '^[?]' | wc -l`). Count
root-owned files outside .git and vendor (`find . -not -path
'./.git/*' -not -path '*/vendor/*' -user root 2>/dev/null |
wc -l`). Count .rebase-tmp tracked by git (`git ls-files
.rebase-tmp | wc -l`). Report all three counts."

**Correctness agent** (count-check, all must be 0):
"Read the full diff. Count changes not required by the rebase
(version bumps, type conversions, API renames, format string
fixes, import reordering, codegen, feature gates, deprecated
API migrations, dead code from stricter linters are all valid).
Count format strings with wrong verbs. Count Eventf calls
missing format directives. Report all counts."

**Completeness agent** (count-check, all must be 0):
"Count stale v1.OLD version refs in yml/sh/md files (exclude
K8S_VERSION if kindest/node image isn't published yet). Count
files with SupportBaselineAdminNetworkPolicy. Report counts."

**Gates agent** (count-check, all must be 0):
"Read the GATE_DEPS map in the autofix script. Count test files
with SetFromMap or KUBE_FEATURE_ missing any gate from that map.
Count SetFromMap files with more than 1 SetFromMap call. Report."

**Judgment agents** (flag concerns):
1. "Does every change serve the k8s version bump, or are there
   unrelated cleanups, style changes, or logic alterations?
   Would a maintainer approve this diff as-is?"
2. "Are test expectations correct for the new k8s version? Could
   any test pass locally but fail in CI due to missing fixtures,
   wrong API versions, or hardcoded assumptions?"

All count-checks must be 0. Investigate judgment concerns.
If any test agent reports failures or timeouts:
- **Timeout** likely means a feature gate issue (informer hang).
  Check that all gates from GATE_DEPS are disabled in the
  failing package's test suite.
- **Flaky failure**: re-run the specific failing test individually
  (`go test -count=1 -run TestName ./pkg/...`). If it passes on
  retry, it's a flake — not a rebase issue. Large test suites
  (pkg/ovn) are prone to flakes in full-suite runs.
- **Pre-existing failure**: if it fails consistently, check if it
  also fails on master (`git checkout master && go test ... &&
  git checkout -`). Don't fix pre-existing issues.
- Fix genuine rebase failures and re-run from 3a.

**3c. Independent review:** Once 3b passes, run the antagonistic
review script. This invokes a separate Claude instance with fresh
context for a truly independent second opinion:

```bash
REVIEW=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-review.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
if [ -n "$REVIEW" ]; then
  bash "$REVIEW" "$(git rev-parse HEAD)" "k8s rebase"
fi
```

APPROVE means proceed. REJECT means investigate the stated reason.

### Step 4: Done

```bash
rm -rf .rebase-tmp/
```
