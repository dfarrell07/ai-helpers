# Next Work

Production infrastructure for 100+ OpenShift repos. Quality
means: never silently produce wrong output, handle every edge
case, teach good patterns.

## Where we are

Both modes work:
- spec=all (blind): 95% (20/21 post-.rebase-tmp fix)
- spec=none (production): **100% (3/3 post-fix)** — CNCC,
  multus, ovnk all PASS on 1.36.2
- spec=all overnight: **24/24 PASS** across all repos/versions
- The old 45% spec=none rate was stale-branch and orchestrator
  bugs, not autofix being counterproductive

The skill works. The question is no longer "does it work" but
"what could go wrong on a repo we haven't tested."

## Correctness: bugs that produce wrong output

### Silent go get failures
`go get` failures swallowed with WARNING (line 464). No assertion
that all k8s.io deps reached target version. A partial rebase
can compile, pass gates, generate a PR — CI fails hours later.
**Fix:** Assert all k8s.io deps are at API_VERSION after the
go-get loop + skew alignment. Die if any are wrong.

### CRD check/fix scope mismatch
run_checks verifies `helm/*/crds/*.yaml` only. The fix function
patches 6 broader paths. CNO's bindata/ and manifests/ CRDs
get fixed but the diagnostic says "all clean."
**Fix:** Broaden run_checks to match fix function's 6 paths.

### sigs.k8s.io version pinning
derive_go_gets Rule 1 (line 390) assumes sigs.k8s.io deps track
k8s minor versions. They don't. Pins to nonexistent versions,
silently swallowed.
**Fix:** Remove `sigs\.k8s\.io/` from Rule 1 grep.

## Trust: bugs that hurt on first use

### go-mod-tidy contradiction
rules.md bans `go mod tidy`. step2/step3 instruct it. The hook
blocks it at harness level. When a repo has transitive dep
conflicts, the agent can't fix them.
**Fix:** Add exception in hook for step-instructed operations.

### Pre-push hook orphaned
Hook installed at line 54. 12 of 13 early exits don't trigger
cleanup. User's `git push` is blocked after a failed run.
**Fix:** Use EXIT trap instead of ERR.

### Dead rebase-report.md
rules.md says write checkpoints. No step does. step5 reads
nothing. Agent wastes context.
**Fix:** Remove checkpoint instructions from rules.md.

### Hook crash-to-allow
jq missing = hooks fail open.
**Fix:** Output block JSON if jq missing (one line per hook).

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
