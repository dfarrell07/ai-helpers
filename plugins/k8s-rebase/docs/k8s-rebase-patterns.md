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
| library-go interface | `does not implement SharedIndexInformer` | BLOCKER: bump library-go after upstream merges interface PR |
| Snyk vendor scan | `ci/prow/security` fails (often pre-existing) | Fix is in openshift/release, not the repo — exclude vendor from snyk |
| OTE module | downstream `openshift/` module needs separate bump | Run skill on downstream fork, OTE go.mod bumped alongside |
| Transitive dep compat | `too many/few arguments` in `/go/pkg/mod/` path | Bump the dependency (`go get pkg@latest`), then `go mod tidy` |
| k8s.io/kubernetes staging | `unknown revision v0.0.0` for k8s.io/* | Script auto-resolves; if manual: `go get k8s.io/<pkg>@v0.XX.0` |
| CRD name validation lost | `not-default created` (should be rejected) | Re-insert `metadata.name: pattern: ^default$` after codegen |
| CRD codegen annotation | `verify-update-codegen` fails (`git diff`) | Re-run codegen to update `controller-gen.kubebuilder.io/version` |
| Informer coalescing | Hybrid-overlay test timeout (2s) | Increase `Eventually` timeout (2s → 5s) |
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

### controller-gen version annotation mismatch (recurring)

When `sigs.k8s.io/controller-tools` is bumped (e.g. v0.20.1 →
v0.21.0), `controller-gen` writes the new version into CRD YAML
annotations. If codegen isn't re-run and committed, CI's
`verify-update-codegen` (or `make verify`) detects the stale
annotation via `git diff --exit-code`. Repos that build
controller-gen from vendor (like CNO) are affected whenever
controller-tools bumps; repos that pin a version in the codegen
script (like ovnk's `@v0.19.0`) are not.

Fix: `k8s-rebase.sh` Phase 2 runs codegen and commits the output.
If the CRD manifest diff only shows the version annotation, that's
expected and correct.

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
- `.FieldsV1.Raw` → `.FieldsV1.GetRawBytes()` (read access)
- `&metav1.FieldsV1{Raw: []byte(...)}` → `metav1.NewFieldsV1(...)` (construction)

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

### Project CRD int64 validation (k8s 1.36)

k8s 1.36 enforces stricter CRD integer format validation. Any
CRD field with `uint32` type and `Maximum > 2^31-1` (int32 max)
needs `+kubebuilder:validation:Format=int64` or the CRD is
rejected at runtime. Symptom: tests that use the CRD fail with
timeouts because resources aren't properly applied.

Example: NetworkQoS `Rate` and `Burst` fields are `uint32` with
`Maximum:=4294967295`. Fix: add `+kubebuilder:validation:Format=int64`
to both fields in `types.go`, then change `format: int32` to
`format: int64` in the CRD YAML. The autofix handles both — it adds
the kubebuilder marker and patches the YAML directly (no codegen
re-run, which would strip hand-edited metadata blocks).

### CRD metadata.name validation lost during codegen (recurring)

Some CRDs enforce `metadata.name` must be a specific value (e.g.
`"default"`) via a hand-edited `pattern: ^default$` in the CRD
YAML. `controller-gen` doesn't generate metadata constraints, so
re-running codegen strips these validations. Symptom: tests that
create resources with invalid names succeed instead of being
rejected:
```
egressqos.k8s.ovn.org/not-default created
```
but the test expected:
```
Invalid value: "not-default"
```
Fix: after any codegen run, re-insert the `metadata.name` pattern
block into the affected CRD YAMLs (both `_output/crds/` and
`helm/*/crds/`):
```yaml
          metadata:
            type: object
            properties:
              name:
                type: string
                pattern: ^default$
```
Known affected CRDs: `k8s.ovn.org_egressqoses.yaml` and
`k8s.ovn.org_egressfirewalls.yaml`. The autofix script handles
this automatically.

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

### KubeVirt secondary interface IPv6 test fix (recurring)

Secondary KubeVirt interfaces use IPv4-only cloud-init (DHCPv6
not supported). OVN allocates both IPv4 and IPv6, but VMI status
only reports the IPv4 for secondary interfaces. Tests that
validate persistent IPs by reading from VMI status see 1 address
instead of 2 and fail with:
```
Expected <[]string | len:1>: ["10.28.112.4"] to have length 2
```
Fix requires two changes in `test/e2e/kubevirt.go`:

1. Add a `virtLauncherNetworkStatusIPs` function that reads
   allocated IPs from the virt-launcher pod's Multus
   `network-status` annotation instead of VMI status. Place it
   near the existing `podsMultusNetworkIPs` function. It should:
   - Find the running virt-launcher pod for the VMI (label
     `vm.kubevirt.io/name`)
   - Read `podNetworkStatus` with the network predicate
   - Return the IPs from the matching network-status entry
   - Use Eventually with 30s timeout (pod may take time)

2. In the persistent IP test (around `virtualMachineAddressesFromStatus`
   call site), split the expected address count:
   - `expectedAllocatedAddressCount = len(dualCIDRs)` (full dual-stack)
   - `expectedStatusAddressCount` = same for primary, IPv4-only for
     secondary (`td.role != udnv1.NetworkRolePrimary`)
   - Use `virtualMachineAddressesFromStatus` with status count
   - For secondary: also call `virtLauncherNetworkStatusIPs` with
     allocated count to verify the full allocation is preserved
   - Compare static IPs against the allocated addresses, not status

Reuse existing helpers: `podNetworkStatus` and
`podNetworkStatusByNetConfigPredicate` already parse the Multus
annotation. The new function wraps them with an Eventually loop
that finds the running virt-launcher pod by label selector.

This is a test-only change — the OVN allocation is correct.
The autofix does not handle this (too complex for sed/awk).

### kubeadm v1beta4 format (k8s 1.36)

k8s 1.36 silently ignores v1beta3 `extraArgs` map format, causing
controller-manager flags like `-service-lb-controller` to not be
applied. This breaks the disable-forwarding MTU test and any test
depending on custom controller-manager or kubelet flags.
Migrate `kind.yaml.j2` kubeadmConfigPatches to v1beta4 format:
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
InitConfiguration, JoinConfiguration in `kind.yaml.j2`. Both
`extraArgs` and `kubeletExtraArgs` need conversion. The autofix
script handles this automatically.

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

### Hybrid-overlay informer coalescing (k8s 1.36)

k8s 1.36 informer changes may cause flow sync events to coalesce
differently, making hybrid-overlay tests that expect a specific
sequence of flow sync calls flaky. Symptom: test times out at
2 seconds waiting for expected OVS commands that were coalesced
into a single event. Fix: increase the `Eventually` timeout
(e.g., 2s → 5s) and add a comment explaining the coalescing.
This is a test timing issue, not a logic bug.

### E2e framework changes (k8s 1.35)

| Old | New |
|---|---|
| `framework.WaitForServiceEndpointsNum(...)` | `e2eendpointslice.WaitForEndpointCount(...)` |
| `e2enode.IsNodeReady(node)` | `e2enode.IsNodeReady(logger, node)` |

### Snyk vendor scan failures (recurring)

`ci/prow/security` (Snyk) scans vendored code and flags CVEs in
transitive dependencies. This is often pre-existing (fails on
main too), but it blocks rebase PRs. Re-vendoring may also add
new transitive deps that introduce additional findings.

The fix is a CI config change in `openshift/release` (not the
repo): exclude `vendor/` from Snyk scanning. See CORENET-7277
/ `openshift/release#80462` (CNO-specific fix).

This is NOT a rebase bug — don't try to fix it in the repo.
Report it as a known CI blocker.

### Cross-repo dependency ordering (recurring)

Downstream OpenShift repos form a dependency chain:
1. **Plumbing repos first**: `openshift/api`, `openshift/library-go`,
   `openshift/client-go` — these must merge their k8s bump before
   consumers can vendor them.
2. **Consumer repos next**: CNO, CNCC, multus, ovnk — these `go get`
   the bumped plumbing repos.
3. **OTE last**: the downstream `openshift/` module in ovnk has its
   own go.mod and may depend on consumer repo changes.

If `go mod tidy` / `go mod vendor` produces a diff in library-go
files (e.g., `verify-deps` fails with `M vendor/.../library-go/...`),
the plumbing repo hasn't merged yet. This is a BLOCKER — the
rebase is complete but CI won't pass until the dependency chain
catches up. Track via JIRA (e.g., CORENET-7287).

When the skill detects `does not implement` errors against
library-go interfaces, or `verify-deps` fails with library-go
diffs, it should tell the agent this is an upstream blocker
rather than a fixable rebase issue.

### OTE downstream module (recurring)

The downstream ovnk fork (`openshift/ovn-kubernetes`) has an
`openshift/` directory containing OTE (openshift-tests-extension)
code with its own `go.mod`. This module must be bumped alongside
the main `go-controller/` module. The upstream fork does not
have this directory.

The skill finds all `go.mod` files, so running it on the
downstream fork should bump OTE too — but this path has not
been tested. OTE may have its own breakage patterns distinct
from go-controller (e.g., `openshift/origin` test API changes).
OTE is sometimes bumped as a separate PR by a different
engineer (see CORENET-7293).
