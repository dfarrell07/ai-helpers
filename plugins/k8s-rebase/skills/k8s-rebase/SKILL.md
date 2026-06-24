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

**AI disclosure:** All commits must include the trailer
`Assisted-by: Claude Code <noreply@anthropic.com>`.
The scripts add it automatically. For manual commits use:
`git commit -s --trailer "Assisted-by: Claude Code <noreply@anthropic.com>"`
When amending, do NOT re-pass `-s` or `--trailer` — the
existing trailers are preserved. Use `git commit --amend`
without those flags to avoid duplicates.

---

## Phase 0-3: Mechanical Rebase

Run from the default branch (master/main). The script creates a
new timestamped branch. Do not reuse branches from prior runs.

**Important:** This script takes 5-30 minutes (longer if it
auto-containerizes). Launch it as a detached process so it is
not killed by Bash tool timeouts:

**Launch** (returns immediately):
```bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$REPO_ROOT" ] && echo "ERROR: Not in a git repo" && exit 1
if ! [[ -f "$REPO_ROOT/go.mod" || -f "$REPO_ROOT/go-controller/go.mod" ]]; then
  echo "ERROR: $REPO_ROOT has no go.mod — are you in a workspace root instead of the target repo?"
  exit 1
fi
SCRIPT=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -z "$SCRIPT" ] && echo "ERROR: k8s-rebase.sh not found" && exit 1
mkdir -p "$REPO_ROOT/.rebase-tmp"
nohup bash "$SCRIPT" $ARGUMENTS > "$REPO_ROOT/.rebase-tmp/phase03.log" 2>&1 &
echo $! > "$REPO_ROOT/.rebase-tmp/phase03.pid"
echo "Launched PID $(cat "$REPO_ROOT/.rebase-tmp/phase03.pid")"
```

**Check** (run every 3-5 minutes until done):
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
if kill -0 $(cat "$REPO_ROOT/.rebase-tmp/phase03.pid" 2>/dev/null) 2>/dev/null; then
  echo "Still running..."; tail -3 "$REPO_ROOT/.rebase-tmp/phase03.log"
else
  echo "Done"; cat "$REPO_ROOT/.rebase-tmp/phase03-result.txt" 2>/dev/null; tail -10 "$REPO_ROOT/.rebase-tmp/phase03.log"
fi
```

When the check shows "Done", look at the last lines of the log.
**Exit 2 = success** — proceed to Phase 4. Exit 1 = error.
Check `cat .rebase-tmp/phase03-result.txt` — if it says "EXIT 2",
the script completed all phases. Check `git log` for rebase
commits. Do NOT re-run the script. Do NOT run the autofix script
or make manual go.mod changes before Phase 0-3 completes — the
rebase script handles all module bumps, codegen, and version
references. Running autofix early creates duplicate commits.
Do NOT manually update K8S_VERSION or other version references
— the autofix script (Step 2) handles these and will choose the
correct values (e.g., v1.36.1 if v1.36.2 KIND images aren't
published yet).

If the output says "Could not detect OCP target", check the
repo's CI config in `openshift/release` or compare with an
existing manual rebase PR for the correct `openshift-X.Y`
version in `.ci-operator.yaml` and Dockerfiles.

---

## Phase 4: Build Validation and Fixups

Every step ends with subagent verification. The step is not
complete until all subagents report zero issues.

**Subagent rules:**
- Report specific counts, not just "looks good."
- Judgment agents must cite the specific file:line or diff hunk
  for each concern — "no issues found" requires listing what
  was actually checked.
- Gate subagents are read-only — they verify and report, but
  must NOT edit files. The main agent applies fixes.
- If ANY judgment agent flags a concern, the main agent MUST
  investigate and either fix it or explain why it's not an
  issue before proceeding. Do not dismiss judgment concerns.
- Give subagents the repo path and tell them to use
  `podman run --userns=keep-id` with the golang container if
  they need Go tools (build, vet, lint, test).
- If you cannot launch subagents, run the gate checks inline.

### Step 1: Fix compilation errors

Use `timeout: 600000` (10 min) for validation commands, or
`run_in_background: true` if they auto-containerize.

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
**Import deduplication:** If a file imports the same package
twice (bare + aliased, e.g., `"k8s.io/.../errors"` and
`k8serrors "k8s.io/.../errors"`), remove the duplicate and
update references. Do NOT use `replace_all` for this — it
causes double-substitution (e.g., `k8serrors` → `k8sk8serrors`).
Instead, remove the bare import line and update only the
specific references that used the bare name.

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

**Gate:** Find the gate prompt directory, read each file listed
below with `cat`, and launch one subagent per file with the
file's contents as the prompt. Launch all in a single parallel
wave. Prepend the repo path to each prompt so the subagent
knows where to look.
```bash
GATE_DIR=$(find "$HOME/.claude" "$HOME" -maxdepth 7 \
  -path "*/k8s-rebase/gates/step1" -type d 2>/dev/null | head -1)
cat "$GATE_DIR/build-vet.md"  # read this, use as subagent prompt
```
Gate files:
- `build-vet.md` (count)
- `version-consistency.md` (count)
- `diff-scope.md` (count)
- `type-conversions.md` (judge)
- `fix-correctness.md` (judge)

Count gates must report 0. Judge gates must cite evidence.
Investigate all concerns before proceeding. To add a gate:
create a new `.md` file in step1/ and add it to this list.

### Step 2: Run autofix script

Use `timeout: 600000` — the autofix auto-containerizes and
runs go vet internally.

```bash
SCRIPT=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-autofix.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
[ -n "$SCRIPT" ] && bash "$SCRIPT"
```

Applies known fix patterns (code fixes, feature gates, lint
version, CRD validation fixes, AND e2e infra: MetalLB, KubeVirt,
RelaxedServiceNameValidation, kubeadm v1beta4).
Outputs RESULT: PASS or FAIL. **Verify the script actually ran**
— if the output is empty or the script wasn't found, the autofix
was skipped and all its fixes are missing. If FAIL, fix remaining
items and re-run until PASS. Check output for MetalLB FRR image warnings —
if the autofix bumped MetalLB, verify the FRR image variable
matches what the new MetalLB version ships. Read the patterns doc
for unfamiliar patterns:
```bash
PATTERNS=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-patterns.md" -path "*/k8s-rebase/docs/*" 2>/dev/null | head -1)
[ -n "$PATTERNS" ] && cat "$PATTERNS"
```

**Gate:** Find the gate prompt directory, `cat` each file below,
and launch one subagent per file with its contents as the prompt.
All in one parallel wave. Prepend the repo path to each prompt.
```bash
GATE_DIR=$(find "$HOME/.claude" "$HOME" -maxdepth 7 \
  -path "*/k8s-rebase/gates/step2" -type d 2>/dev/null | head -1)
```
Gate files:
- `autofix-result.md` (count)
- `deprecated-api-remnants.md` (count)
- `feature-gates.md` (count)
- `autofix-diff-review.md` (judge)
- `crd-validation.md` (count)
- `logical-completeness.md` (count)
- `e2e-infra.md` (judge)
- `patterns-completeness.md` (judge)

Count gates must report 0. Judge gates must cite evidence.
Investigate all concerns before proceeding.

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
Use ONLY the packages from the discovery snippet above — it
filters out `root_pkgs` which need CAP_NET_ADMIN (network
namespaces) and will always fail with "permission denied" in
unprivileged containers. Do NOT pass `./pkg/...` or `./...`
directly. Each agent uses the validate script's `--test-only`
flag, which handles containerization, feature gate exports,
timeout scaling, and output capture automatically.

Tests can take 10-60 minutes. Use `timeout: 600000` for small
package groups. For the biggest package (>30k lines), use
nohup to avoid the 10-minute timeout:
```bash
SCRIPT=$(find "$HOME/.claude" "$HOME" -maxdepth 7 -name "k8s-rebase-validate.sh" -path "*/k8s-rebase/scripts/*" 2>/dev/null | head -1)
REPO_ROOT=$(git rev-parse --show-toplevel)
nohup bash "$SCRIPT" --test-only ./pkg/ovn > "$REPO_ROOT/.rebase-tmp/test-ovn.log" 2>&1 &
echo $! > "$REPO_ROOT/.rebase-tmp/test-ovn.pid"
```
Check with: `kill -0 $(cat .rebase-tmp/test-ovn.pid) 2>/dev/null && echo running || echo done`

Split packages across agents by test line count (`wc -l
*_test.go`). Each containerized `go test` compilation uses
~5GB RAM. Check available memory (`free -h`) first:

**<=16GB RAM:** run agents sequentially (one at a time, wait
for each to complete before starting the next). Skip the
biggest package (e.g., pkg/ovn root, 56k lines) — it causes
swap thrashing that slows tests 5-6x. Rely on CI for it.
Cap each agent at ~30k test lines. Run 3 sequential agents:
```bash
# Agent 1: ovn sub-packages (~30k lines), timeout: 600000
bash "$SCRIPT" --test-only ./pkg/ovn/controller/... ./pkg/ovn/topology/...
# Agent 2: clustermanager (~33k lines), timeout: 600000
bash "$SCRIPT" --test-only ./pkg/clustermanager/...
# Agent 3: everything else (~42k lines), timeout: 600000
bash "$SCRIPT" --test-only ./pkg/util/... ./pkg/factory/... ./pkg/cni/...
```

**32GB+ RAM:** run 3 agents in parallel, including the biggest
via nohup:
```bash
# Agent 1: biggest package alone (nohup — takes 10-30 min)
nohup bash "$SCRIPT" --test-only ./pkg/ovn > .rebase-tmp/test-ovn.log 2>&1 &
# Agent 2: sub-packages, timeout: 600000
bash "$SCRIPT" --test-only ./pkg/ovn/controller/... ./pkg/ovn/topology/...
# Agent 3: everything else, timeout: 600000
bash "$SCRIPT" --test-only ./pkg/util/... ./pkg/clustermanager/...
```

Results are in `.rebase-tmp/test-only-*.log`. Do NOT run raw
`go test` inside containers — stdout piping across container
boundaries loses output. The `--test-only` flag writes to a log
file on the mounted volume, so results are always readable.

The following gate agents are read-only (no compilation) and
can run alongside test agents without adding memory pressure.
Find the gate prompt directory, `cat` each file below, and
launch one subagent per file with its contents as the prompt.
Prepend the repo path to each prompt.
```bash
GATE_DIR=$(find "$HOME/.claude" "$HOME" -maxdepth 7 \
  -path "*/k8s-rebase/gates/step3b" -type d 2>/dev/null | head -1)
```
Gate files:
- `cleanliness.md` (count)
- `correctness.md` (count)
- `version-completeness.md` (count)
- `maintainer-review.md` (judge)
- `ci-prediction.md` (judge)
- `build-vet-recheck.md` (count)
- `logical-consistency.md` (judge)
- `ci-readiness.md` (judge)

All count-checks must be 0. Investigate judgment concerns.
If any test agent reports failures or timeouts:
- **Timeout** likely means a feature gate issue (informer hang).
  Check that all gates from GATE_DEPS are disabled in the
  failing package's test suite.
- **Flaky failure**: re-run the specific failing test individually
  (`go test -count=1 -run TestName ./pkg/...`). If it passes on
  retry, it's a flake — not a rebase issue. Large test suites
  (pkg/ovn) are prone to flakes in full-suite runs.
- **Container timing flake**: tests with tight timing margins
  (e.g., 1s context timeout racing a 5×200ms retry loop) flake
  in containers but pass on bare metal CI. Check if the test
  code changed in the rebase (`git diff master -- path/to/test.go`).
  If identical on master, it's pre-existing — fix it if it
  blocks you (increase timeout, not relax assertion) but note
  it's pre-existing in the commit message so the maintainer
  can split it out.
- **Pre-existing failure**: if it fails consistently, check if the
  same test file changed in the rebase (`git diff master -- path/to/test.go`).
  If unchanged, it's pre-existing — don't fix. Do NOT checkout
  master — switching branches corrupts later steps.
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
