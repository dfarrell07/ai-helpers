# Kubernetes Rebase Breakage Patterns

Common breakage patterns from k8s rebases. Follow the
[shared rules](../skills/k8s-rebase/steps/rules.md) when applying fixes.

<!-- LINE BUDGET: 300. Trim version-specific content before
     adding new patterns. Run: wc -l docs/k8s-rebase-patterns.md -->

## Extending

When a rebase surfaces a new breakage pattern:

1. **Pattern Table** — add a row (category, symptom, fix).
   Most patterns belong here and nowhere else.
2. **Detailed section below the table** — add a `### Title
   (recurring)` section only if the fix needs multi-step
   instructions, code examples, or caveats that cannot fit a
   single table row.
3. **`scripts/k8s-rebase-autofix.sh`** — automate a repeatable,
   safe transformation with detection and post-fix verification.
   Change `k8s-rebase.sh` only for mechanical rebase operations.

The mutation harness removes content from `## Pattern Table` onward and
targets detailed headings through `TAG_TO_PATTERN` in `test/test-skill.sh`.
Map each new `fix_<tag>` to its section there, keep selectors aligned when
reorganizing this guide, and verify the copied plugin actually withholds
the intended guidance.

**Criteria for inclusion:** patterns must be generic — they
apply (or could apply) across Go projects that consume k8s.
If a fix only fires for one or two specific repos, put it in
that repo's `CLAUDE.md` or `AGENTS.md`, not here.

**How to discover patterns:** run the skill on a repo and
observe what breaks. Common sources: renamed/removed API
symbols, stricter `go vet` or lint checks, new default-true
feature gates, KIND/MetalLB/KubeVirt version skew, and
codegen output changes.

## Pattern Table

| Category | What breaks | How to fix |
| --- | --- | --- |
| Function renamed | `undefined: <OldName>` | Search-replace + import update |
| Signature changed | `too many/few arguments` | Add missing param (often logger) |
| Type divergence | `cannot use X as Y` | Convert ALL fields (check struct def) |
| go vet format string | `non-constant format string` | `"%v", err` (prefer `%v` over `"%s", err.Error()`) |
| go vet format type | `%q has arg of wrong type` | Use `%v` for non-string types |
| Deprecated API | `SA1019: X is deprecated` | Check vendored `// Deprecated:` comment |
| FieldsV1.Raw removed | `FieldsV1.Raw undefined` (k8s 1.36+) | Read access: `.GetRawBytes()`; construction: `metav1.NewFieldsV1(...)` |
| NewSimpleClientset | `SA1019` on generated fakes | Replace with `NewClientset` — check vendored source for `// Deprecated:` first (not all fakes deprecate it) |
| x/exp migration | `cannot find package "golang.org/x/exp/..."` | Migrate to stdlib `maps`/`slices`/`cmp` |
| govet inline analyzer | `inline: cannot inline <call>` | Inspect the call and analyzer configuration; fix actionable code findings before considering a narrow configuration change |
| Nilness dead code | `nilness: impossible condition` | Remove dead `if err != nil` blocks |
| Codegen flag removed | `unknown flag: --bounding-dirs` | Remove flag from script, re-run codegen |
| Codegen field removed | `unknown field X in struct literal` | Remove field from Go code, re-run codegen |
| Codegen deleted mocks | `undefined: mock.X` after codegen runs | Run `make mocksgen` (repos with `.mockery.yaml`) |
| Feature gate (existing) | Tests hang (gate files exist) | Add new gate + dependents to existing setup |
| Feature gate (missing) | Tests hang (no gate setup) | Confirm a fake-client protocol mismatch; configure the applicable gates before client/informer startup |
| golangci-lint version | `Go language version...lower` | Bump VERSION in lint.sh AND test.yml |
| golangci-lint v1/v2 | v2 config rejected by v1 binary | Makefile may use v1 import path while lint.sh uses v2 container — update both if migrating |
| ST1005 error string casing | Lowercased error string breaks matching code | Before fixing ST1005, grep for the OLD error string in all Go files — update matches too |
| golangci-lint v1 + Go 1.26 | v1 binaries, built with older Go, can't parse Go 1.26 code | Move to v2 and build it with the local Go: `go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@<version>` |
| CI builder image | `not found` for `golang-X.Y-openshift-Z.W` | Verify the Go/OCP mapping and published image tag on the intended release stream; do not switch streams just to find an image |
| KIND binary version | e2e cluster creation fails | Select a release supporting the target Kubernetes version and update each binary pin |
| KIND kubeadm config | k8s 1.36: controller-manager flags silently not applied | Migrate `kind.yaml.j2` extraArgs from v1beta3 map format to v1beta4 list format |
| KubeVirt version | VM readiness timeouts in kv-live-migration CI | Confirm version skew, then select a compatible stable patch within the same minor |
| MetalLB CRD validation | `Maximum boundary value must be of type integer` | Bump MetalLB version in e2e setup script; update FRR image variable separately |
| library-go interface | `does not implement SharedIndexInformer` | Use a compatible commit on the correct OCP release branch, or a tracked fork replacement (see Cross-repo dependency ordering below) |
| Snyk vendor scan | `ci/prow/security` fails after vendoring | Compare findings against base and inspect the repo's scanning policy; new vendor files may not match per-file exclusions |
| sudo PATH not preserved | `go: command not found` under sudo in CI scripts (often pre-existing) | In bash: `sudo env "PATH=$PATH" <cmd>` to preserve Go toolchain PATH |
| Transitive dep compat | `too many/few arguments` in `/go/pkg/mod/` path | Use `k8s-rebase-depfix.sh <module>@<compatible-version>` in the affected module; verify k8s pins afterward |
| k8s.io/kubernetes staging | `unknown revision v0.0.0` for k8s.io/* | The rebase script resolves staging requirements at the requested target; inspect its tidy log if resolution fails |
| CRD name validation lost | Resource with invalid name accepted (should be rejected) | Re-insert hand-edited `metadata.name` pattern constraints after codegen |
| CRD codegen annotation | `verify-update-codegen` fails (`git diff`) | Re-run codegen to update `controller-gen.kubebuilder.io/version` |
| Webhook builder API | `NewWebhookManagedBy` / `.For()` compile errors | Move object from .For() to constructor arg (now generic) |
| Vendor verify in container | `vendor not in sync` (container-only) | Compare host/container toolchains and rerun the repo's vendor check; container execution alone does not prove a false positive |
| e2e framework API | `undefined` in test/e2e | Rename functions, add params to match new signatures |

## Feature Gates (recurring)

New defaults such as `WatchListClient` can change list/watch behavior that
fake clientsets do not support. Confirm that the failing test uses such a
client before changing its setup. Use the vendored definitions and the
autofix's `GATE_DEPS` map to identify applicable gates and dependents.
Do not add absent gates or attempt to disable gates locked to their default.

Keep parents and dependents consistent across the repo's existing setup:

1. `hack/test-go.sh` env var exports
2. `os.Setenv`/`t.Setenv` in test files
3. `SetFromMap` in test files

The autofix updates existing wiring and warns about selected
`*_suite_test.go` packages with fake clients but no gate setup. It does not
cover every test package or prove a warning needs a fix. For an affected
suite, configure the relevant gates before client/informer startup and
rerun the tests. Check that shell exports reach the test process through
any `sudo` invocation.

Do not infer applicability from an `envtest` import alone; inspect the
failing test's client and server setup. Follow the repo's gate registration
pattern: initialization can override environment settings, and
`SetFromMap` must recognize the gate and its dependencies.

## Recurring Patterns

### AddToScheme → Install (SA1019)

Vendored packages may fix misspelled `Depreciated` → `Deprecated`
annotations, newly surfacing SA1019. Check vendored source; if
`Install` exists, use it. Project-internal CRD register.go is
NOT deprecated.

### controller-gen version annotation mismatch (recurring)

When the controller-gen version used by codegen changes, regenerated CRDs
carry its new version annotation. Commit that output, even if only the
annotation changed, or CI's codegen verification will report a diff.
Check how the repo selects controller-gen: a vendored tool follows its
dependency bump; a separately pinned tool follows that pin.

### golang.org/x/exp → stdlib

- `maps.Keys(m)` → `slices.Collect(maps.Keys(m))` (Go 1.23+)
- `maps.Values(m)` → `slices.Collect(maps.Values(m))` (Go 1.23+)
- `maps.Copy/Clone` → same, change import
- `maps.Clear(m)` → `clear(m)`
- `constraints.Ordered` → `cmp.Ordered`

**Import placement:** `"maps"`, `"slices"`, `"cmp"` are stdlib
but end up in the third-party import group after replacement.
Run `goimports -w` to fix grouping.

### Deprecated stdlib/apimachinery symbols (recurring)

These deprecations often surface during k8s rebases but are
not x/exp-related:

- `reflect.Ptr` → `reflect.Pointer` (Go 1.18+ deprecated alias)
- `.FieldsV1.Raw` → `.FieldsV1.GetRawBytes()` (read access)
- `&metav1.FieldsV1{Raw: []byte(...)}` → `metav1.NewFieldsV1(...)` (construction)

- `"k8s.io/klog"` → `"k8s.io/klog/v2"` (check `klog.V()` boolean
  usage and implicit `init()` flag registration, which changed in v2)

**Map iteration ordering:** `slices.Collect(maps.Keys(m))` does not sort
keys. Tests that assume an order can flake; compare the baseline and the
migration before classifying a failure as pre-existing.

### Transitive dependency compatibility

An ecosystem bump can break another dependency, producing errors
under `/go/pkg/mod/`. Run `k8s-rebase-depfix.sh <module>@<compatible-version>`
in the affected module. It tidies and vendors when vendor/ exists;
verify Kubernetes pins afterward, as the helper does not enforce them.

### Vendor verification differences in containers (recurring)

When the validate script auto-containerizes (Go version mismatch),
`make verify-go-mod-vendor` may differ from the host result.
The validator's NOTE is a diagnostic hint, not a passing check.
Compare toolchain versions, environment, and the actual diff;
rerun the repo's vendor verification with the required Go version.
Retain an unresolved failure if the discrepancy cannot be explained.

### Cross-repo dependency ordering (recurring)

Downstream OpenShift repos form a dependency chain:

1. **Plumbing repos first**: `openshift/api`, `openshift/library-go`,
   `openshift/client-go` — these must merge their k8s bump before
   consumers can vendor them.
2. **Consumer repos next**: CNO, CNCC, multus, ovnk — these consume
   the bumped plumbing repos through the rebase scripts.
3. **OTE last**: the downstream `openshift/` module in ovnk has its
   own go.mod and may depend on consumer repo changes.

If build errors show `does not implement` against library-go,
check whether the required interface change exists on the correct
OCP release branch. A missing upstream fix can block the consumer;
vendor changes alone do not establish that the fix is missing.

**Replace directive workaround:** Add to go.mod:
`replace github.com/openshift/library-go => github.com/FORK/library-go v0.0.0-DATE-HASH`
Add a TODO tracking its removal when the upstream fix merges;
apply it in every affected module (replacements do not propagate), then
run `k8s-rebase-depfix.sh --sync` there.

**Do NOT hand-patch vendor/** — CI runs `go mod vendor` which
regenerates from source, erasing patches.

### Operator Framework repos (recurring)

Repos using operator-sdk have additional version refs:
`CONTROLLER_TOOLS_VERSION`, `OPERATOR_SDK_VERSION`, `VERSION`
in Makefile, plus bundle manifests (`bundle/`, `config/`).
Detect them through `PROJECT` or `operator-sdk` in Makefile. Inspect how
the repo generates and verifies these artifacts; update tool pins only when
the target rebase requires it. A `VERSION` variable may be the operator's own
release version. Regenerate affected bundles through the repo's targets and
review the diff; the presence of operator-sdk alone does not require a bump.

### ST1005 error string casing vs test assertions (recurring)

Before fixing ST1005, search for the old error string in all Go files.
Changing `"Failed to create"` to `"failed to create"` also affects tests
matching the old text and production `strings.Contains` checks.
Lowercase only the initial letter, preserve acronyms, and update dependent
matches. Error text can participate in control flow; preserve that behavior.

### golangci-lint v1→v2 config migration (recurring)

When upgrading golangci-lint from v1 to v2, the config format
changes:

- Add `version: "2"` header
- `linters-settings` → nested under `linters.settings`
- Add `default: standard` under `linters` (replaces v1's
  implicit default set; `enable`/`disable` are additive on top)

Separately, any lint version bump (even within v1 or within v2)
can pull in stricter checks that surface new findings unrelated
to the rebase. `--fix` auto-fix is incomplete for some checks.

The skill's `fix_lint_version` bumps the lint tool version
but does not migrate the `.golangci.yml` config. Config migration
is left to the agent in Step 4 because the changes are project-
specific. When facing config issues: fix the config to match the
new version's expectations rather than suppressing new warnings.

**errcheck exclusions for v2:** golangci-lint v2's errcheck matches
concrete types — `(io.Closer).Close` does NOT cover `(*os.File).Close`.
Grep for unchecked Close/Flush calls before writing exclusions:
`grep -rn '\.Close()\|\.Flush()' --include='*.go' . | grep -v vendor | grep -v 'if.*err'`

### Webhook builder API change (controller-runtime v0.24)

`ctrl.NewWebhookManagedBy` is now generic — the object moves
from `.For()` to a constructor argument, from which Go infers the type:

```go
// Old: ctrl.NewWebhookManagedBy(mgr).For(&MyType{}).WithValidator(v).Complete()
// New: ctrl.NewWebhookManagedBy(mgr, &MyType{}).WithValidator(v).Complete()
```

`.For()` is removed. `WithValidator` now takes generic `admission.Validator[T]`.
