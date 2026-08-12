# Next Work

This skill is production infrastructure for 100+ OpenShift repos.
Quality means: never silently produce wrong output, handle every
edge case, teach good patterns. Every bug here can cause a wrong
rebase that ships to production or destroy trust on first use.

## Where we are

spec=all (blind): 95% post-fix (20/21). spec=none (production):
unknown — zero runs with current code. All spec=none data is from
before the orchestrator refactor, .rebase-tmp fix, and autofix
redesign. The production pass rate could be 95% or 45%.

## 1. Measure: run spec=none

`make test spec=none` on 3 repos. Until this runs, we don't know
if the production skill works. Everything else is secondary.

## 2. Correctness: bugs that produce wrong output

### Silent go get failures
`go get` failures swallowed with WARNING (line 464). No assertion
that all k8s.io deps reached target version. A partial rebase
compiles, passes gates, generates a PR, user pushes — CI fails
hours later with cryptic version skew. Or worse: compiles and
has runtime incompatibilities.
**Fix:** Assert all k8s.io deps are at API_VERSION after the
go-get loop + skew alignment. Die if any are wrong.

### CRD check/fix scope mismatch
run_checks verifies `helm/*/crds/*.yaml`. The fix function
patches 6 broader paths. CNO's bindata/ and manifests/ CRDs
get fixed but the diagnostic says "all clean" — false confidence.
A CRD regression in bindata/ ships silently.
**Fix:** Broaden run_checks to match fix function's 6 paths.

### sigs.k8s.io version pinning
derive_go_gets Rule 1 (line 390) assumes sigs.k8s.io deps track
k8s minor versions. They don't. Pins to nonexistent versions,
silently swallowed. The dep stays at the old version.
**Fix:** Remove `sigs\.k8s\.io/` from Rule 1 grep.

## 3. Trust: bugs that make users distrust the tool

### go-mod-tidy contradiction
rules.md bans `go mod tidy`. step2/step3 instruct it. The hook
blocks it at harness level. When a repo has transitive dep
conflicts, the agent can't fix them — it freezes or loops. The
user sees a broken branch with no clear explanation.
**Fix:** The rules.md ban targets gate subagents (read-only).
The hook should allow the main step agent to run module ops.
Simplest: add exception in hook for commands that include a
module path argument (not bare `go mod tidy`).

### Pre-push hook orphaned
Hook installed at line 54. 12 of 13 early exits between there
and branch creation don't trigger cleanup. User runs the tool,
it fails during validation, they go back to normal work — every
`git push` is blocked with no explanation. They remove the tool.
**Fix:** Use EXIT trap (fires on every exit) instead of ERR.

### Dead rebase-report.md
rules.md says write checkpoints. No step does. step5 reads
nothing. Agent wastes context cycles looking for a file that
doesn't exist — on a large repo this context waste matters.
**Fix:** Remove checkpoint instructions from rules.md.

### Hook crash-to-allow
jq missing = hooks fail open. Agent can run `go mod tidy`
directly, corrupting k8s version pins. Gates catch drift but
the damage is already committed.
**Fix:** Output block JSON if jq missing (one line per hook).

## 4. Performance

- 33 PLUGIN_ROOT finds per run (seconds each, 33 times)
- Companion script migration (crd-validation.sh, patterns-
  completeness.sh to gate-script-lib.sh for consistency)
- Gate consolidation 33 → 31

## Dropped (verified wrong)

- AtomicFIFO — doesn't affect fake clientsets
- ovnk rename — false
- step4 gates wasted — concurrent, not discarded
- Backtick breakout — 0 matches in repos
- Write/Edit in allowed-tools — subagents get full tools
