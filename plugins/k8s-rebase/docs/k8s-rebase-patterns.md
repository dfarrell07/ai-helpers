# Kubernetes Rebase Breakage Patterns

Common breakage categories from the 1.33-1.36 rebases. These are
starting points for recognition — each k8s release brings new changes.

Update this file after each rebase with new patterns discovered.

## Fix Priority

Always try fixes in this order. Disabling or skipping is the last resort.

1. **Fix the code** — API changes, type mismatches, resource leaks.
   The goal is to keep all tests running and passing.
2. **Fix test infrastructure** — update fakes, fix setup/teardown,
   use newer client APIs that support new features.
3. **Configure test environment** — only when the failure is caused
   by an upstream limitation with no available fix. Must include
   a tracking comment (upstream issue URL + TODO to re-enable).

## Pattern Table

| Category | What breaks | Fix type | How to fix |
| ------------------------------ | ------------------------------- | -------- | --------------------------------- |
| Function renamed | `undefined: <OldName>` | Code | Search-replace + import update |
| Function signature changed | `too many/few arguments` | Code | Add missing parameter (often logger) |
| Type divergence | `cannot use X as Y` | Code | Convert field-by-field |
| Resource leak in tests | Tests hang in sequence | Code | Add cleanup (Shutdown/Close) in teardown |
| Validation message changed | Test assertion mismatch | Code | Update expected error strings |
| go vet format string | `non-constant format string` | Code | Wrap in `"%s", msg` or use `%v` |
| Admission API migrated | SA1019 on old webhook API | Code | Switch to new generics-based API |
| Utility moved to stdlib | SA1019 on `k8s.io/utils/...` | Code | Replace with stdlib equivalent |
| Fake client deprecated | SA1019 on `NewSimpleClientset` | Infra | Check for `NewClientset`, else lint exclude |
| Feature gate breaks fakes | Tests hang or panic | Env | Investigate first (see below), then disable |

## Concrete Examples

### WatchListClient (k8s 1.35)

K8s 1.35 enabled `WatchListClient` by default. Fake clientsets from
third-party libraries don't support WatchList semantics, causing
informers to hang waiting for bookmark events.

**Detection:** Tests hang indefinitely or `make test` times out.

**Fix (2 parts):**

In `go-controller/hack/test-go.sh`:
```bash
export KUBE_FEATURE_WatchListClient=false
```

In each `*_suite_test.go` that imports `k8s.io/kubernetes/pkg/features`:
```go
utilfeature.DefaultMutableFeatureGate.SetFromMap(map[string]bool{
    "WatchListClient": false,
})
```

Affected 5 files (test-go.sh + 4 suite_test.go files).
See commit `5238d48f7` for the full change.

### WaitForServiceEndpointsNum renamed (k8s 1.35)

**Detection:** `undefined: framework.WaitForServiceEndpointsNum`

**Fix:** Replace with `e2eendpointslice.WaitForEndpointCount`.
The new function takes fewer arguments (no interval/timeout params).
Add import: `e2eendpointslice "k8s.io/kubernetes/test/e2e/framework/endpointslice"`

See commit `88885c3a0` for the full change.

### WithConditions type change (k8s 1.36 / network-policy-api v0.2.0)

**Detection:** `cannot use newCondition (metav1.Condition) as
*ConditionApplyConfiguration`

**Fix:** Convert `metav1.Condition` to `*ConditionApplyConfiguration`
using the builder pattern:
```go
import metaapplyv1 "k8s.io/client-go/applyconfigurations/meta/v1"

condApply := metaapplyv1.Condition().
    WithType(c.Type).WithStatus(c.Status).
    WithReason(c.Reason).WithMessage(c.Message).
    WithLastTransitionTime(c.LastTransitionTime)
```

### Peer type divergence (k8s 1.36 / network-policy-api v0.2.0)

**Detection:** `cannot use peer (BaselineAdminNetworkPolicyEgressPeer)
as AdminNetworkPolicyEgressPeer`

**Fix:** These were aliased before but are now separate types with
identical fields. Convert field-by-field:
```go
anpapi.AdminNetworkPolicyEgressPeer{
    Namespaces: peer.Namespaces,
    Pods:       peer.Pods,
    Nodes:      peer.Nodes,
    Networks:   peer.Networks,
}
```
Also check test files — `go vet` catches type mismatches in test
struct literals that `go build` misses.

### New feature gate causing test hangs (recurring pattern)

Each k8s release may enable new feature gates that break fake
clientsets. This happened with WatchListClient (1.35) and
AtomicFIFO (1.36).

**Detection:** Unit tests hang or timeout. `make test` never
completes. Individual tests may pass but the full suite hangs.

**Investigation (do this BEFORE disabling):**

1. Run individual test packages to isolate which ones hang
2. Check if the hang is a resource leak (goroutine dump, test
   cleanup not calling Shutdown/Close) — if so, fix the leak
3. Check if a newer fake clientset API supports the feature
   (e.g., `fake.NewClientset()` vs `fake.NewSimpleClientset()`)
4. Check upstream k8s issues for the gate name — is there a
   recommended fix other than disabling?
5. If the root cause is "fake clientset doesn't implement the
   feature's API" — disabling is correct, but document it

**If disable is necessary (last resort, 3 parts):**

1. Add env var to `hack/test-go.sh`:
```bash
# TODO(rebase): re-enable when upstream fake clientset supports <GateName>
# See: https://github.com/kubernetes/kubernetes/issues/<ISSUE>
export KUBE_FEATURE_<GateName>=false
```

2. Add to ALL `*_suite_test.go` files that use
`utilfeature.DefaultMutableFeatureGate.SetFromMap`. If the
gate has dependents (check the error message for "depends on
features that are disabled"), disable dependents FIRST in a
separate `SetFromMap` call, then disable the gate itself.

3. Some test packages may lack `suite_test.go` entirely. Create
one with `TestMain` that sets the env vars.

**Finding new feature gates:** Check
`vendor/k8s.io/client-go/features/known_features.go` for gates
with `Default: true` at the target k8s version. The rebase
script writes detected gates to `/tmp/rebase-new-gates.txt`.

### WatchFactory leak in tests (k8s 1.36)

**Detection:** Test that passes individually but hangs when run
after a large test suite. Goroutine/resource exhaustion.

**Fix:** Ensure test cleanup calls `watchFactory.Shutdown()` not
just `libovsdbCleanup.Cleanup()`. Store the WatchFactory in the
test controller struct and shut it down in `close()`.

### go vet format string errors (Go 1.26)

**Detection:** `non-constant format string in call to Eventf` or
`fmt.Sprintf format %q has arg of wrong type`.

**Fix:** For `Eventf`: wrap the message in `"%s", msg` format.
For `%q` with non-string types: use `%v` instead.
