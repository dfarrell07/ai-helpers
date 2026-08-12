# Next Work

## Where we are

spec=all (blind, no autofix): 95% post-fix (20/21).
spec=none (production, with autofix): 45% historically (26/57)
BUT all spec=none data is from Jul 29 - Aug 4, before the
orchestrator refactor, .rebase-tmp fix, AND autofix redesign
(27→18 functions, patterns doc 589→296 lines). Zero spec=none
runs with current code. The production pass rate is unknown.

## 1. Run spec=none test

`make test spec=none` on 3 repos (multus, CNCC, ovnk). Compare
to spec=all post-fix results. This answers the most important
question: does the production skill actually work?

## 2. Fix bugs

### Quick (no design decision)

**sigs.k8s.io in Rule 1** — Remove `sigs\.k8s\.io/` from
derive_go_gets Rule 1 grep (line 390). Rule 3 catches them.

**CRD check scope** — Broaden run_checks to match fix function's
6 paths (bindata, config/crd, manifests, _output).

**Dead rebase-report.md** — Remove checkpoint instructions from
rules.md (line 86). No step writes it, step5 reads nothing.

**Hook jq guard** — One line per hook: output block JSON if jq
missing (currently fails open).

### Needs decision

**go-mod-tidy contradiction** — rules.md bans it, step2/step3
instruct it, hook blocks it. Options: wrapper script, hook
exception, or clarify rules.md scoping.

**Pre-push hook on early exit** — ERR trap doesn't fire on
die/exit. 12 of 13 early exits orphan the hook. Options: EXIT
trap (fires on every exit), move installation later, or wrap
die() to call cleanup.

**Silent go get failures** — No final assertion all k8s.io deps
reached target. Options: hard die, or add to step1 gate check.

## Cleanup

- 33 slow PLUGIN_ROOT finds per run
- Companion script migration to gate-script-lib.sh
- Gate consolidation 33 → 31
- Stale inline category lists

## Dropped (wrong or not real)

- AtomicFIFO — doesn't affect fake clientsets
- ovnk rename — false
- step4 gates wasted — concurrent, not discarded
- Backtick breakout — 0 matches
- Write/Edit in allowed-tools — subagents get full tools
