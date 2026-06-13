# Kubernetes Rebase Breakage Patterns

Common breakage from k8s 1.33-1.36 rebases. Update after each
rebase with new patterns discovered.

## Extending for a New k8s Version

When rebasing to k8s 1.37+, update these files:

1. **This file** — add a `### New Pattern (k8s 1.XX)` section
   under Version-Specific Patterns with the fix recipe.
2. **`scripts/k8s-rebase-autofix.sh`** — if the fix is
   deterministic (sed/grep), add a `fix_*` function in the
   version-specific section. Add a matching check to
   `run_checks()`. For new gate dependents, add one line to
   the `GATE_DEPS` map at the top of the script.
3. **`scripts/k8s-rebase.sh`** — only if the mechanical rebase
   needs changes (unlikely — it's version-generic).

## Pattern Table

| Category | What breaks | How to fix |
| --- | --- | --- |
| Function renamed | `undefined: <OldName>` | Search-replace + import update |
| Signature changed | `too many/few arguments` | Add missing param (often logger) |
| Type divergence | `cannot use X as Y` | Convert ALL fields (check struct def) |
| go vet format string | `non-constant format string` | `"%s", msg` or `%v` |
| go vet format type | `%q has arg of wrong type` | Use `%v` for non-string types |
| Deprecated API | `SA1019: X is deprecated` | Check vendored `// Deprecated:` comment |
| x/exp migration | `inline: cannot inline` | Migrate to stdlib `maps` (NOT disable linter) |
| Nilness dead code | `nilness: impossible condition` | Remove dead `if err != nil` blocks |
| Codegen flag removed | `unknown flag: --bounding-dirs` | Remove flag from script, re-run codegen |
| Codegen field removed | `unknown field X in struct literal` | Remove field from Go code, re-run codegen |
| Feature gate (existing) | Tests hang (gate files exist) | Add new gate + dependents to existing setup |
| Feature gate (missing) | Tests hang (no gate setup) | Add `t.Setenv` for all gates to suite file |
| golangci-lint version | `Go language version...lower` | Bump VERSION in lint.sh AND test.yml |
| golangci-lint v1/v2 | v2 config rejected by v1 binary | Makefile may use v1 import path while lint.sh uses v2 container — update both if migrating |
| golangci-lint v1 + Go 1.26 | container image can't parse Go 1.26 | Replace Makefile no-op else with `go install @$(VERSION) && golangci-lint run` |
| CI builder image | `not found` for `golang-X.Y-openshift-Z.W` | New Go versions may only exist for newer OCP streams (e.g., 1.26 → openshift-5.0, not 4.22) |
| KIND binary version | e2e cluster creation fails | Bump KIND URL in install-kind.sh to latest |
| MetalLB CRD validation | `Maximum boundary value must be of type integer` | Bump MetalLB version in kind-common.sh (check patch compat) |
| library-go interface | `does not implement SharedIndexInformer` | Bump library-go — upstream must add new interface methods first |
| Transitive dep compat | `too many/few arguments` in `/go/pkg/mod/` path | Bump the dependency (`go get pkg@latest`), then `go mod tidy` |
| k8s.io/kubernetes staging | `unknown revision v0.0.0` for k8s.io/* | Script auto-resolves; if manual: `go get k8s.io/<pkg>@v0.XX.0` |
| e2e framework API | `undefined` in test/e2e | Fix like go-controller: rename, add params |

## Feature Gates (recurring)

Each k8s release may enable gates that break fake clientsets.
Add gate AND ALL dependents to ALL three mechanisms:
1. `hack/test-go.sh` env var exports
2. `os.Setenv`/`t.Setenv` in test files
3. `SetFromMap` in test files

**Missing gate packages:** Some test packages use fake clientsets
but have NO gate setup. These work until a new gate enables
informer behavior (like WatchList) that fake clientsets don't
support. Symptoms: tests hang or timeout on informer cache sync.
Fix: add `t.Setenv("KUBE_FEATURE_<gate>", "false")` to the
suite's `TestX` function. The autofix warns about these packages
but doesn't auto-fix (not all fake clientset tests need gates).

SetFromMap validates parent-dep consistency — disabling a parent
without its deps causes a validation error. All gates must be in
SetFromMap, but only add gates that exist in vendored k8s code
(removed gates cause "unrecognized feature gate" errors).

**Known problematic gates:**
- **WatchListClient** (k8s 1.35)
- **AtomicFIFO** (k8s 1.36). Dependents:
  `StaleControllerConsistency{Job,ReplicaSet,StatefulSet,DaemonSet}`.
  SetFromMap (all gates — parents + deps):
```go
if err := utilfeature.DefaultMutableFeatureGate.SetFromMap(map[string]bool{
    "WatchListClient":                      false,
    "AtomicFIFO":                           false,
    "StaleControllerConsistencyJob":         false,
    "StaleControllerConsistencyReplicaSet":  false,
    "StaleControllerConsistencyStatefulSet": false,
    "StaleControllerConsistencyDaemonSet":   false,
}); err != nil {
    t.Fatalf("Failed to disable feature gates: %v", err)
}
```

**Gates that do NOT need disabling (k8s 1.36):**
`UnlockWhileProcessingFIFO`, `ClientsAllowCARotation`,
`ClientsAllowTLSCacheGC`, `InOrderInformers`.

## Version-Specific Patterns

### WithConditions (network-policy-api v0.2.0)

`WithConditions` now takes `*ConditionApplyConfiguration`. Convert
with builder, mapping ALL 6 fields:
```go
metaapplyv1.Condition().
    WithType(c.Type).
    WithStatus(c.Status).
    WithObservedGeneration(c.ObservedGeneration).  // DO NOT OMIT
    WithLastTransitionTime(c.LastTransitionTime).
    WithReason(c.Reason).
    WithMessage(c.Message)
```

### EgressPeer type divergence (network-policy-api v0.2.0)

**Only EgressPeer diverged.** IngressPeer remains compatible.
Convert field-by-field. Check `_test.go` files too.

### Conformance suite rename (network-policy-api v0.2.0)

| Old | New |
|---|---|
| `SupportAdminNetworkPolicy` | `SupportClusterNetworkPolicy` |
| `SupportBaselineAdminNetworkPolicy` | (removed) |
| `ConformanceProfileName` type cast | `CNPConformanceProfileName` |

The v0.2.0 conformance suite also expects `ClusterNetworkPolicy`
resources in `v1alpha2` API version. If the project only installs
`v1alpha1` CRDs, conformance tests fail with:
```
no matches for kind "ClusterNetworkPolicy" in version "policy.networking.k8s.io/v1alpha2"
```
Fix depends on which network-policy-api version the conformance
module uses:
- **v0.1.x or pre-release** (e.g. `v0.1.9-0.2026...`): uses
  v1alpha1 `AdminNetworkPolicy` fixtures. No CRD changes needed.
  The existing CRD URLs work. Do NOT bump the conformance module
  to v0.2.0 — that brings v1alpha2 `ClusterNetworkPolicy` fixtures
  that the controller can't enforce (policy timeout failures).
- **v0.2.0+**: uses v1alpha2 `ClusterNetworkPolicy` fixtures. ADD
  the `clusternetworkpolicies.yaml` CRD URL alongside existing
  ones. Do NOT remove old CRDs — the controller still needs them.

Do NOT force-bump the conformance module to match go-controller's
version. The conformance module has its own version that may
intentionally lag behind. The conformance test only runs on
non-ipv6 CI jobs (`ipfamily != ipv6`).

### AddToScheme → Install (SA1019)

Vendored packages may fix misspelled `Depreciated` → `Deprecated`
annotations, newly surfacing SA1019. Check vendored source; if
`Install` exists, use it. Project-internal CRD register.go is
NOT deprecated.

### deepcopy-gen --bounding-dirs removed (k8s 1.36)

Remove flag from `hack/update-codegen.sh`, re-run codegen.
`k8s-rebase.sh` handles this automatically (auto-retry + mockery).

### golang.org/x/exp → stdlib

- `maps.Keys(m)` → `slices.Collect(maps.Keys(m))`
- `maps.Values(m)` → `slices.Collect(maps.Values(m))`
- `maps.Copy/Clone` → same, change import
- `maps.Clear(m)` → `clear(m)`
- `constraints.Ordered` → `cmp.Ordered`
- `reflect.Ptr` → `reflect.Pointer`
- `FieldsV1.Raw` → `GetRawBytes()` (returns `[]byte`, no error)

**Import placement:** `"maps"`, `"slices"`, `"cmp"` are stdlib —
merge them alphabetically into the stdlib import group. Do NOT
leave them in the blank-line-separated group where `x/exp/maps`
was (that was the third-party section).

After migration: `go mod tidy && go mod vendor` to remove x/exp.
Use `--userns=keep-id` with podman.

**Map iteration ordering:** `x/exp/maps.Keys()` returned `[]T`
directly. Stdlib `maps.Keys()` returns `iter.Seq[T]` which
`slices.Collect` materializes. Both produce unspecified order,
but the concrete order may differ. Tests that depend on specific
map iteration order (e.g., IP allocation determined by pod
processing order from `maps.Keys`) may flake after migration.
These are pre-existing test fragilities, not rebase bugs — verify
by re-running the failing test individually.

### MetalLB CRD validation (k8s 1.36)

k8s 1.36 enforces stricter CRD validation: `format: int32` is
now required on integer fields. MetalLB v0.15.3's `BGPPeer` CRD
has `spec.myASN` and `spec.peerASN` fields without this
annotation, causing cluster setup to fail:
```
BGPPeer.metallb.io "peer-1" is invalid: Maximum boundary value must be of type integer with format int32 in spec.myASN
```
Fix: bump `metallb_version` in `kind-common.sh` to v0.16.0+.
MetalLB versions ship different FRR images — add a separate
`METALLB_UPSTREAM_FRR_IMAGE` variable and update the
`replace_in_file_or_exit` calls in `install_metallb` to use it
instead of `FRR_K8S_UPSTREAM_FRR_IMAGE`. The autofix script
handles the version bump and FRR image variable automatically.

### KubeVirt version incompatibility (recurring)

Each k8s bump typically breaks the pinned stable KubeVirt version
because KubeVirt CRDs lag behind k8s API changes. Symptom: VMs
never reach readiness, 300s timeouts in kv-live-migration tests.
Fix: change `KUBEVIRT_VERSION` in `kind-common.sh` from the pinned
stable version (e.g. `v1.6.2`) to `nightly`. Revert to stable once
KubeVirt releases a k8s-compatible version. The autofix script
handles this automatically.

### RelaxedServiceNameValidation (k8s 1.36)

Beta feature gate, default true in k8s 1.36, but custom KIND node
images built with `kind build node-image` start kube-apiserver with
`--feature-gates=""` (empty), so beta defaults are not applied.
Symptom: conformance test fails creating Service named `1kubernetes`:
```
Service "1kubernetes" is invalid: metadata.name: Invalid value
```
Fix: add a probe function to `e2e-kind.sh` that creates a
digit-prefixed Service to test if the API server accepts it. If
not, skip only the exact DNS test that exercises this gate. Also
add `featureGates: RelaxedServiceNameValidation: true` to
`kind.yaml.j2` as a best-effort (may not work for custom images).
The autofix script injects both the probe and the skip.

### kubeadm v1beta4 format (k8s 1.36, not CI-blocking)

kubeadm v1beta3 still works in k8s 1.36 but v1beta4 changes
`extraArgs` from a map format to a list-of-name-value format:
```yaml
# v1beta3 (old)
apiServer:
  extraArgs:
    "v": "5"
# v1beta4 (new)
apiServer:
  extraArgs:
    - name: "v"
      value: "5"
```
Add `apiVersion: kubeadm.k8s.io/v1beta4` to ClusterConfiguration,
InitConfiguration, JoinConfiguration in `kind.yaml.j2`. This is
proactive cleanup — not currently blocking CI.

### Transitive dependency compatibility

When controller-runtime or another k8s ecosystem package bumps,
other direct dependencies that consume it may break. Build errors
appear in `/go/pkg/mod/` paths (not in the project's own code).

Fix: `go get <broken-dep>@latest` then `go mod tidy`. The latest
version of the dependency will be compatible with the bumped
controller-runtime.

Example: `cert-controller v0.10` uses `controller.NewUnmanaged`
with an old signature. Bumping to v0.16 fixes the incompatibility
with controller-runtime v0.24.

### E2e framework changes (k8s 1.35)

| Old | New |
|---|---|
| `framework.WaitForServiceEndpointsNum(...)` | `e2eendpointslice.WaitForEndpointCount(...)` |
| `e2enode.IsNodeReady(node)` | `e2enode.IsNodeReady(logger, node)` |
