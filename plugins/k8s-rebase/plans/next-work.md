# Next Work

## Where we are

spec=all (blind, no autofix): 24/24 PASS post-.rebase-tmp fix.
spec=none (production, with autofix): ~49% pass rate historically.
Real users run spec=none. The autofix may be hurting by consuming
context window. A controlled A/B test is needed.

## Fix: Real bugs that will bite users

### go-mod-tidy contradiction
rules.md bans `go mod tidy`. step2/step3 instruct it. The hook
blocks it. The agent will freeze when a step2 dep error requires
`go get && go mod tidy` — the hook intercepts at harness level.
Hasn't hit yet (no test repo triggered that path), but will.
**Fix:** Wrap dep-fix operations in a script the hook allows,
or add exception to hook for step-instructed operations.

### Silent go get failures
`go get` failures are swallowed with WARNING (line 464). No
final assertion that all k8s.io deps reached target version.
Partial rebases can be committed. Mitigated by skew-alignment
retry (lines 502-523) but retries also swallowed.
**Fix:** After go-get loop and skew alignment, assert all
k8s.io deps are at API_VERSION. Die if any are wrong.

### sigs.k8s.io in derive_go_gets Rule 1
Rule 1 (line 390) assumes version-locked deps. sigs.k8s.io has
independent versioning. Pins to nonexistent versions, silently
swallowed. controller-runtime handled separately in Rule 2.
**Fix:** Remove `sigs\.k8s\.io/` from Rule 1 grep. Rule 3
already catches them as fallback.

### Pre-push hook orphaned on early exit
Hook installed at line 54. 12 of 13 early exits between there
and branch creation use `die`/`exit` which do NOT trigger the
ERR trap. Only the idempotency exit (line 232) cleans up.
**Fix:** Change trap to EXIT (fires on every exit), not just
ERR INT TERM. Or: move hook installation to right before
branch creation (~line 368).

### CRD check scope mismatch
run_checks searches `helm/*/crds/*.yaml` only. The fix function
searches 6 broader paths. CNO's bindata/ and manifests/ CRDs
are missed. ovnk's _output/ CRDs missed.
**Fix:** Broaden run_checks to match fix function's 6 paths.

### Dead rebase-report.md pipeline
rules.md line 86 says write checkpoints. No step file does.
step5 reads the nonexistent file. Result: incomplete final
report, agent wastes cycles looking for it.
**Fix:** Remove checkpoint instructions from rules.md, or add
writes to each step file. Former is simpler.

### Hook crash-to-allow
jq missing = hook crashes = fail-open. jq is not a Claude Code
dependency, not in RHEL minimal install. Gates catch drift
downstream, so not catastrophic.
**Fix:** One line per hook: output block JSON if jq missing.

## Investigate: autofix impact on pass rate

spec=none ~49% vs spec=all ~77%. The autofix + patterns doc
may consume more context than they save. Temporal confound:
spec=none stopped Aug 4, tool improved after. But same-day
comparison (Jul 30) showed 54% vs 77%.

**Next step:** Run controlled A/B test — spec=none on 3 repos
with the current code (post-.rebase-tmp fix, post-redesign).
Compare to spec=all results. If spec=none is still significantly
worse, the autofix is counterproductive and should be further
trimmed or made opt-in.

## Cleanup (do when convenient)

- 33 slow PLUGIN_ROOT finds per run (each gate subagent repeats
  find $HOME -maxdepth 7). Cache in .rebase-tmp or pass in prompt.
- Companion script migration (crd-validation.sh, patterns-
  completeness.sh to gate-script-lib.sh)
- Gate consolidation 33 → 31 (safe within-step merges)
- Static inline category lists already stale — accept or lint

## Dropped from previous plan (wrong or not real)

- AtomicFIFO restoration — patterns doc is right, doesn't
  affect fake clientsets. Only WatchListClient matters.
- ovnk rename — false, repo still at ovn-org/ovn-kubernetes
- step4 gates wasted — step4 says concurrent, not before.
  Reports never discarded (no HEAD line = always "fresh").
- Backtick breakout in review prompt — 0 matches in repos
- Write/Edit in allowed-tools — step subagents get full tools
