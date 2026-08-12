# Next Work

Production infrastructure for 100+ OpenShift repos.

## Where we are

Both modes work:
- spec=all (blind): 95% (20/21)
- spec=none (production): **100% (3/3)**
- overnight: **24/24 PASS**

## Correctness

### Silent go get failures
Failures swallowed with WARNING. Step2 gate catches mismatches
post-hoc but no in-script early warning.
**Fix:** Warn-and-continue assertion after skew alignment
(~line 523). Non-fatal — gate is authoritative.

### CRD check/fix scope mismatch
run_checks verifies 1 path, fix patches 6. CNO bindata/ missed.
**Fix:** Broaden run_checks to 6 paths + 3 exclusions matching
fix_crd_int64_validation.

### sigs.k8s.io in derive_go_gets Rule 1
Pins sigs.k8s.io to k8s minor versions — they version
independently. Would try `sigs.k8s.io/yaml@v1.36.2` (wrong).
**Fix:** Remove `sigs\.k8s\.io/` from Rule 1 grep. Rule 3
catches them correctly. No regression.

## Trust

### go-mod-tidy hook vs step2
Step2 tells agent to run `go get <module>@latest && go mod tidy`
directly. Hook blocks direct `go get`. Hook correctly exempts
bash script invocations. The hook is RIGHT — scripts are
trusted, ad-hoc agent commands aren't.
**Fix:** Create `scripts/k8s-rebase-depfix.sh <module>` wrapper.
Change step2 line 107 to call wrapper. Hook stays.

### Pre-push hook orphaned on die()
ERR trap does NOT fire on die() — confirmed empirically. 12
die() calls between hook install and branch creation orphan it.
EXIT trap is wrong (removes guard on successful exit).
**Fix:** Add `cleanup_hook` call inside die() function.

### Dead rebase-report.md
rules.md lines 85-88 instruct checkpoints no step writes.
step5 handles missing file gracefully.
**Fix:** Remove lines 85-88 from rules.md.

### Hook jq dependency
jq missing = fail-open. grep/sed replacement is unsafe (breaks
on escaped quotes in JSON). jq is justified.
**Fix:** Add jq-missing guard per hook that fails closed:
`command -v jq >/dev/null || { printf '{"decision":"block",
"reason":"jq required"}'; exit 0; }`

## Performance

- 33 PLUGIN_ROOT finds per run
- Companion script migration to gate-script-lib.sh
- Gate consolidation 33 → 31

## Dropped (verified wrong)

- Remove block-module-ops hook — wrong, hook is correct
- EXIT trap for pre-push — removes safety guard on success
- Replace jq with grep/sed — breaks on escaped quotes
- AtomicFIFO restoration — doesn't affect fake clientsets
- ovnk rename — false
- "autofix counterproductive" — disproven, 3/3 PASS
