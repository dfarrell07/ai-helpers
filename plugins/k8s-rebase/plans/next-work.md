# Next Work

Production infrastructure for 100+ OpenShift repos. Quality
means: never silently produce wrong output, handle every edge
case, teach good patterns.

## Where we are

Both modes work with current code:
- spec=all (blind): 95% (20/21)
- spec=none (production): **100% (3/3)** — CNCC, multus, ovnk
- overnight spec=all: **24/24 PASS**
- The old 45% was stale-branch and orchestrator bugs

## Correctness: bugs that produce wrong output

### Silent go get failures
Failures swallowed with WARNING (line 464). Partial rebases can
be committed. Mitigated by skew-alignment retry AND step2's
version-consistency gate — but no in-script assertion.
**Fix:** Add warn-and-continue assertion after skew alignment
(line ~523). Check all k8s.io deps (excluding kube-openapi,
utils, klog, gengo) match API_VERSION. Non-fatal — the gate
is the authoritative check.

### CRD check/fix scope mismatch
run_checks verifies `helm/*/crds/*.yaml` only. Fix function
patches 6 paths. CNO's bindata/ and manifests/ CRDs missed.
**Fix:** Broaden run_checks to 6 paths + 3 exclusions (vendor,
.claude, testdata) matching fix_crd_int64_validation.

### sigs.k8s.io in derive_go_gets Rule 1
Rule 1 (line 390) pins sigs.k8s.io deps to k8s minor versions.
They have independent versioning — none use v0.{MINOR}.{PATCH}.
Would try `sigs.k8s.io/yaml@v1.36.2` (wrong). Rule 3 handles
them correctly via bare `go get`.
**Fix:** Remove `sigs\.k8s\.io/` from Rule 1 grep. No regression
— strictly a correctness improvement.

## Trust: bugs that hurt on first use

### go-mod-tidy hook contradiction
rules.md bans `go mod tidy`. step2 instructs `go get && go mod
tidy`. The hook blocks it at harness level. Adding exceptions
turns the hook into swiss cheese.
**Fix:** Remove block-module-ops hook entirely. Gates verify
version pins post-hoc — that's the correct enforcement point.
Keep rules.md instruction for gate subagents (read-only).

### Pre-push hook on early exit
Previous analysis conflicted on whether ERR trap fires on
die(). EXIT trap is wrong (removes safety guard on success).
**Fix:** Test empirically: add `echo "TRAP FIRED" >&2` to
cleanup_hook, run the script with a bad version, check if it
fires. If ERR already catches die(), no fix needed. If not,
add cleanup_hook call inside die().

### Dead rebase-report.md
rules.md lines 85-88 instruct checkpoints no step writes.
step5 reads nothing but handles missing file gracefully.
**Fix:** Remove lines 85-88 from rules.md. Leave step5 as-is.

### Hook jq dependency
All 4 hooks depend on jq. Missing jq = crash = fail-open.
**Fix:** Replace jq with grep/sed. The JSON is simple enough
(flat fields, one-level nesting). Eliminates dependency entirely
— no guard logic needed.

## Performance

- 33 PLUGIN_ROOT finds per run
- Companion script migration to gate-script-lib.sh
- Gate consolidation 33 → 31

## Dropped (verified wrong)

- AtomicFIFO — doesn't affect fake clientsets
- ovnk rename — false
- step4 gates wasted — concurrent, not discarded
- Backtick breakout — 0 matches
- "autofix is counterproductive" — disproven, 3/3 spec=none PASS
- EXIT trap for pre-push — removes safety guard on success
