# k8s-rebase: Step Isolation and Version-Agnostic Generality

## 1. Executive Summary

The k8s-rebase skill automates Kubernetes dependency rebases for Go
projects across 100s of OpenShift ecosystem repos. It works reliably
for 5 smaller repos (90%+ pass rate) but fails on ovn-kubernetes (true
pass rate ~33-44% depending on false-positive filtering). Behavioral
step-skipping produces "missing gates" failures (35 of 89 total) in
two clusters: the agent makes a rational cost-benefit decision to skip
Steps 3-4 at the step boundary (11 failures); and effort avoidance
before Step 4 (the largest step) causes the agent to stop (7 failures).
Separately, 44 "gate(s) failed" failures (49%) need different treatment.

| Step | What | Effort | Targets |
|------|------|--------|---------|
| 0 | Branch fix (current-branch semantics) | Minutes | Test measurement bug (42% false positives) |
| 1 | Stop hook + preamble reframe + signal cleanup | Hours | N=26 cluster (11 failures, step-boundary skipping) |
| 1b | Gate companion scripts (parallel with 1) | Hours | 44 "gate failed" failures (49%, flaky AI judgment) |
| 2 | Agent-based step delegation | Days | N=15 cluster (7 failures, effort avoidance) + scale |
| 3 | Discovery procedures + recipe cleanup | Days | Version-specific recipe rot (~18-36% stale) |

### Glossary

- **spec=all**: Test mode that disables autofix script + patterns doc.
  The AI must solve everything independently. Tests version-agnosticism.
- **spec=none**: Test mode that enables all recipes. Simulates production.
- **Gates**: 33 `.md` files under `gates/step{1-4}*/` — each is a quality
  check run as a subagent that produces a `.report` file (PASS/FAIL +
  rationale) via `write-gate-report.sh`.
- **N=X**: X gates missing (e.g., N=26 means 26 of 33 gates have no
  `.report` file — the agent stopped after completing only 7 gates).
- **Step boundaries**: step1 has 1 gate, step2 has 6, step3 has 11,
  step4 has 15. Cumulative: 1, 7, 18, 33. N=26 = stopped after step2.

## 2. Problem Statement

### Dual-cause step skipping

The agent skips Steps 3-4 and jumps prematurely to Step 5. Two independent behavioral triggers:

**Cause A — Rational skip at step boundary (N=26, 11 of 35 failures):**
The agent reaches the Step 2→3 boundary, sees autofix output with
non-zero checks, and makes a cost-benefit decision to skip to Step 5.
The preamble ("Steps 1-4 are preparation, Step 5 is the deliverable")
provides rational justification: preparation failed, skip to the
deliverable. Session transcripts confirm: *"Given the significant
amount of work remaining... let me proceed directly to Step 5."*
Every N≥26 failure is spec=all. Sessions used 14-50% of 1M context —
no resource constraint. The agent is not keyword-matching on "FAIL" —
it is reasoning about whether continuing is worth the effort.

**Cause B — Effort avoidance at step boundary (N=15, 7 of 35 failures):**
After completing Steps 1-3 (18 gates), the agent faces Step 4 — the
largest step (15 gates, lint/test/review on a large codebase). It
decides the remaining work isn't worth it and stops. Both spec modes
appear (3 none, 4 all), ruling out autofix signals. 6 of 7 are ovnk.
Not resource exhaustion — task-remaining estimation.

18 of these 35 failures are in the two major clusters (N=26 and N=15).
The remaining 17 break into three tiers: 11 near-complete (N=1-7,
dropped a few tail gates), 3 mid-range (N=12, N=28, N=30, partial
step-skipping variants), and 3 startup crashes (N=32, infrastructure).
The Stop hook addresses 32 of 35 (91%) — only the 3 infrastructure
crashes need different intervention. 60% of all "missing" failures
land on exact step boundaries — behavioral, not random.

### Other failure modes

- **Gate failures are the majority but mostly flaky.** Of 89 total
  failures: 44 "gate(s) failed" (49%), 35 "missing gates" (39%), 8
  other. The Stop hook addresses "missing" but not "gate failed."
  However, 94% of gate failures are flaky — the same repo+version
  passes in other runs. 31 of 33 gates are pure AI judgment (no
  companion script), making single-shot evaluation inherently
  non-deterministic. **Gate names are not logged to results.tsv** —
  add them to identify chronic offenders. Step 1b addresses this
  with companion scripts for 4 high-value gates.
- **spec=none vs spec=all: no real difference.** Raw rates (33% vs
  46%) are not statistically significant (p=0.53, n=12 vs n=50).
  However, across ALL repos combined, spec=all significantly
  outperforms spec=none (70% vs 46%, p=0.002). ovnk is the only
  repo where spec mode doesn't matter. Recompute after Step 0.

### Measurement and technical debt

- **Test measurement bug:** SKILL.md says "default branch" but test
  harness overrides → 42% false positive passes. Fix: "current branch."
- **Recipe rot:** Autofix (1,678 lines) + patterns (591 lines, ~18-36%
  version-specific) contain k8s 1.34-1.36 recipes. Rebase script is
  fully general.
- **find depth:** 50 `find "$HOME" -maxdepth 7` calls break at
  marketplace install depth. Fix: `${CLAUDE_PLUGIN_ROOT}`.

## 3. Design Principles

This skill is production infrastructure and a learning resource for
developers building Claude Code automation. Four target-state
principles (current state partially implements 1 and 2):

1. **Deterministic scaffolding, agentic judgment.** Split every workflow
   into two layers: deterministic (scripts, hooks, gate counting) and
   agentic (step files, gate evaluations, fix decisions). The test: can
   it be a for-loop? Deterministic. Does it require reading code and
   making a judgment? Agentic. Four roles: scripts = what always happens,
   hooks = what must never happen, gates = what must be verified, AI
   prompts = what requires thinking. If it says NEVER in prose, it
   should be a hook in code.

2. **Clarity over cleverness.** A new developer should understand the
   architecture from the directory layout. Each file has one purpose.

3. **Modern Claude Code patterns.** Use `${CLAUDE_PLUGIN_ROOT}` (not
   `find`), hooks for enforcement (not prose the AI may ignore), and
   Agent-based delegation for step isolation.

4. **Teachability.** The code should read as a tutorial for "how to
   build a multi-step AI automation skill with quality gates."

## 4. Architecture

### Current (monolithic)

```
claude --bg session (single 1M context)
└── SKILL.md (981 lines) orchestrates Steps 1-5 via prose
    ├── Step 2: fix loop
    ├── Step 3: autofix + 11 gates           ← SKIPPED (agent stops)
    ├── Step 4: lint/test/review + 15 gates  ← SKIPPED
    └── Step 5: PR command                   ← JUMPED TO prematurely
```

### Step 1 fix: signal consistency + hooks (no architectural change)

Keep monolithic SKILL.md. Fix the stop signals. Add a Stop hook that
blocks session ending without 33 gate reports. The Stop hook is
cause-agnostic — it addresses both Cause A (N=26) and Cause B (N=15)
plus 14 of 17 other "missing" failures (91% of all 35 total).

### Step 2 fix: Agent-based step delegation

SKILL.md becomes a ~100-line entry point that delegates each step to
a fresh Agent. Each step agent gets its own 1M context. Gate counting
happens in the orchestrating agent after each step returns.

```
claude --bg session
└── SKILL.md (~100 lines): parse args, delegate via Agent tool
    ├── Agent(step1-rebase.md)        — fresh 1M, script + 1 gate
    ├── Agent(step2-compilation.md)   — fresh 1M, fix loop + 6 gates
    ├── Agent(step3-autofix.md)       — fresh 1M, autofix + 11 gates
    ├── Agent(step4-verification.md)  — fresh 1M, lint/test + 15 gates
    ├── Gate count check (deterministic, in SKILL.md)
    └── Agent(step5-submit.md)        — PR command
```

Nesting: main (0) → step (1) → gate (2) = 3 levels. All steps fit
within 1M with comfortable margin (Step 2 worst case: ~36%).

### End-state directory layout

```
plugins/k8s-rebase/
  # Runtime (executed during rebase):
├── skills/k8s-rebase/SKILL.md     # Entry point (~100 lines)
├── steps/                          # Step agent instructions
│   ├── rules.md, step{1-5}*.md
├── gates/                          # 33 gate files (unchanged)
├── scripts/                        # Deterministic shell scripts
├── hooks/
│   ├── block-push.md              # Existing (prompt-based)
│   └── hooks.json + stop-hook.sh  # NEW: gate-completeness (command)
  # Development-only (not executed):
├── docs/k8s-rebase-patterns.md    # Recipe reference
├── plans/                          # Design documents
└── test/                           # Test harness + results
```

## 5. Implementation: Graduated Ladder

### Step 0: Branch fix (minutes)

- SKILL.md line 87: "default branch" → "current branch"
- SKILL.md line 94: remove `git checkout master && git branch -D`
  recovery instruction (delete the sentence entirely — recovery
  should not switch branches)

### Step 1: Stop hook + preamble reframe + autofix signal (hours)

Three interventions, ranked by impact:

**1. Stop hook (infrastructure-level enforcement, highest impact):**
Significantly stronger than prose. When a Stop hook returns
`{"decision": "block"}`, the CLI hard-prevents session termination
and feeds the reason back as a new prompt. Three prose anti-skip
instructions already exist in SKILL.md (lines 420, 537, 832) and all
are ignored — a hook is qualitatively different because the agent
gets another turn whether it wants one or not. Caveats: the agent
controls what work it does during forced continuation, "silent tool
stops" may bypass hooks in some model versions, and the max-block
escape means this is enforcement with a timeout, not absolute.
See Stop hook design details below.

**2. SKILL.md preamble reframe (removes rational justification):**
- Line 16-17: change "Steps 1-4 are preparation. Step 5 is the
  deliverable" to "Steps 3-4 are where you add unique value — the
  quality gates that prevent CI rejection. A rebase that skips them
  will fail CI." The current framing makes skipping RATIONAL — if
  preparation failed, skip to the deliverable. The reframe makes
  skipping IRRATIONAL — skipping the value-add produces a bad PR.
- Add progress markers at each step heading ("PROGRESS: 40% complete"
  at Step 3, "60%" at Step 4) to counter "I've done enough" bias.

**3. Autofix signal cleanup (cosmetic, lowest impact):**
The agent is not keyword-matching on "FAIL" — it reads the output and
reasons about cost-benefit. This rename is cheap but unlikely to
change behavior alone.
- Line 324: `RESULT: FAIL` → `RESULT: ITEMS_REMAINING`
- Line 1677: `exit 1` → `exit 0`
- Move "FAIL is normal" instruction to BEFORE the autofix bash block
- Add: `**Regardless of autofix output, proceed to gates below.**`
- Line 520: fix "cat the gate file" → "let the subagent Read the
  gate file" (contradicts 4 other locations that say "Do NOT cat")

**Robustness improvements (also in Step 1):**
- Oscillation detection: stop gate-fix loop if a previously-passed
  gate regresses after fixing a different gate
- Dirty-tree check: `git status --porcelain` at start of each
  gate-fix loop iteration
- go.mod broadening: use `find` for go.mod instead of assuming
  root-level only (catches multi-module repos)
- Checkpoint tightening: detect "not PASS" instead of "is FAIL"
  (catches malformed/empty reports)

#### Stop Hook Design

~80-120 lines across hooks.json + script.
Command-type hook (not prompt-based) that counts `.report` files in
`.rebase-tmp/gates/`, compares against dynamically-counted expected
gates (`find gates/ -name '*.md' | wc -l`). Based on the production
pattern in `plugins/agentic-docs/hooks/stop-hook.sh`. Key design:
- **Activation guard:** Only enforce when `.rebase-tmp/` exists (skip
  for non-rebase sessions, early exits before Step 1).
- **Provenance validation (not just format):** Each `.report` must
  contain a verdict line (PASS or FAIL), minimum 50 bytes, AND
  evidence that prescribed commands ran (exit codes, output line
  counts, or file:line citations). Fabricating realistic tool output
  is harder than running the tool. For AI-judgment gates (no companion
  script), file:line citations in the report satisfy the evidence
  criterion. The stop hook regex must be permissive enough for both
  scripted evidence (exit codes) and AI evidence (citations).
- **Dynamic gate count:** Derived from `gates/` directory, not hardcoded
  33. Survives future gate additions/removals.
- **Multi-hook safety:** Check `stop_hook_active` (stdin JSON boolean)
  first — if true, exit 0 immediately. Prevents conflicts if users
  have other Stop hooks installed.
- **Own iteration counter:** Maintain block count in `.rebase-tmp/`
  state file. After 3 own blocks, write INCOMPLETE marker to
  `.rebase-tmp/status/INCOMPLETE` (gates expected/completed/missing
  list, last step attempted) and allow exit. CLI also enforces a hard
  8-block cap (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`).
- **INCOMPLETE handling:** Test harness records as third verdict
  (distinct from PASS/FAIL). Production: Step 5 degrades to `--draft`
  PR with WARNING listing missing gates. Court skipped for INCOMPLETE.
- **Worktree awareness (CRITICAL):** Sessions run in git worktrees
  under `<repo>/.claude/worktrees/<branch>/`, not the repo root.
  The hook's working directory is the repo root, so bare paths like
  `.rebase-tmp/` will miss the worktree. Extract `cwd` from the
  stdin JSON (`jq -r '.cwd'`) and use it as the base path for ALL
  file checks. Gate counting derives plugin root from `$0`:
  `PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"` — no argument
  passing needed (no existing hook does this).
- **Activation sentinel:** Check `$CWD/.rebase-tmp/.session-active`
  (not just directory existence) to avoid stale-state false
  activation. SKILL.md creates it at rebase start, removes it in
  Step 5 after clean completion.
- **Actionable reason message:** The block reason becomes the agent's
  next prompt. Must include: which step's gates are missing (not just
  count), the gate directory path, and the list of missing gate
  filenames so the agent can construct subagent prompts. "You have 15
  missing gates" is insufficient — the agent needs "Run these gates:
  gates/step3-autofix/fix-verification.md, gates/step4-verification/
  lint-clean.md, ..." to know where to resume.
- **Hook type:** block-push stays prompt-based (PreToolUse). Stop hook
  is command-based (hooks.json). Different mechanisms, no coordination
  needed.

**Validation:** 15+ ovnk spec=all runs (5 per version). At a ~24% base
rate, 5 runs cannot distinguish improvement from luck (25% false-pass
probability). 15 runs give p<0.05 confidence.

**Rollback checkpoint:** After 15 validation runs, record pass rates.
If any per-version rate drops >10pp vs baseline, revert and investigate
before proceeding. Steps 0-2 are the plan — phased for rollback safety,
not as independent options. Step 3 is genuinely optional (independent
concern, independent success criteria).

### Step 1b: Gate companion scripts (parallel with Step 1)

Addresses the "gate(s) failed" majority (44/89 = 49%) that the Stop
hook cannot fix. Also mitigates Goodhart's Law — companion scripts
make satisficing harder than doing real work. Independent of Step 1
(orthogonal failure categories), so implement in parallel.

Add companion `.sh` scripts to 4 high-value gates (prioritized):
1. **build-vet.sh** (shared by step2/build-vet + step4/build-vet-
   recheck) — `go build ./... && go vet ./...`, diff errors vs base
   branch. Fast-path PASS on `NEW_ISSUES=0`.
2. **version-consistency.sh** — parse go.mod files, check k8s.io/*
   versions match target. Pure grep and string comparison.
3. **go-version-check.sh** — compare `go` directive across go.mod,
   Makefiles, Dockerfiles. Every check is already a grep command.
4. **major-version-imports.sh** — grep for bare `k8s.io/klog` (should
   be `/v2`). The gate .md already starts with "run these greps."

Pattern: `MANDATORY FIRST STEP` block in the gate .md runs the
companion script. RULE 1: `NEW_ISSUES=0` → fast-path PASS (no AI).
RULE 2: AI only evaluates items the script flagged. Follows the
existing crd-validation/patterns-completeness pattern.

**Timing decision:** Implement in parallel with Step 1 (companion
scripts have independent value for gate flakiness regardless of
Stop hook), OR gate on Step 1 validation data (measure the balloon
squeeze before investing). The graduated approach says measure first;
the Goodhart risk says don't ship the Stop hook without deterministic
evidence in high-value gates. User decision.

### Step 2: Orchestrator + Agent delegation (days)

Implement the unified orchestrator (Section 10) and rewrite SKILL.md
as a ~42-line boot loader. The orchestrator enforces step ordering
deterministically; Agent delegation provides context isolation.

- Create `scripts/k8s-rebase-orchestrator.sh` (~250-350 lines) with
  init, gates, advance, status subcommands
- Create `steps/`: rules.md + 5 step files extracted from SKILL.md
- Rewrite SKILL.md to boot loader: run orchestrator status, read
  matching step file via Read tool, work, advance, repeat
- For true context isolation: SKILL.md spawns step-specific subagent
  with only that step file + rules.md in its prompt
- Orchestrator's `gates` subcommand runs companion scripts first,
  outputs PENDING list — agent launches subagents only for those
- Depth-2 nesting (main→step→gate) within Claude Code's default
  spawn depth limit of 3 (shipped v2.1.172, test on CNCC first)
- Stop hook simplifies to ~5 lines: orchestrator status ≠ done → BLOCK
- Test harness: `mutate_plugin` needs updating for step files

### Step 3: Discovery procedures + cleanup (days, independent)

- Replace version-specific recipes with discovery procedures
- Feature gates: parse known_features.go + kube_features.go
- kubeadm: indirect discovery (not vendored)
- Restructure patterns doc (591 → ~208 lines)
- Remove completed autofix functions (see `plans/autofix-disposition.md`)

## 6. Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Model-version coupling | Critical | Log exact model ID per run. The 10x rate increase Aug 7-9 may reflect a model update, not just skill changes. Continuous regression testing. |
| Stop hook block loop | Medium | Max 3 blocks, then exit with INCOMPLETE marker. Activation guard skips non-rebase sessions. |
| Goodhart's Law on Stop hook | High | Agent may write plausible PASS reports instead of doing real work. Content validation (50B + verdict) is trivially satisfiable by an LLM. Step 1b's companion scripts on 4 gates (build-vet, version-consistency, go-version-check, major-version-imports) capture deterministic evidence that makes satisficing harder than doing the actual work. |
| Step agent fails gate prompts | High | Spike validates on CNCC first. |
| PLUGIN_ROOT not a shell env var | High | Gates keep `find`. Steps get literal paths. |
| Discovery procedures unreliable | High | Autofix stays default. Discovery is additive. |
| Unbounded runtime | Medium | `claude --bg` has no default timeout. Stop hook's forced continuation could run indefinitely. Set `--max-turns` and/or `--max-budget-usd` as safety rails in test harness invocations. |
| Silent tool stops bypass hook | Medium | Known in some model versions. Step 2 (agent delegation) is the backup if hooks prove porous. |
| Diagnosis partially wrong | Medium | Verify with 3-5 more transcripts before Step 1. |

## 7. Success Criteria

**Step 0-1:** spec=none: zero "missing 15+" failures. spec=all:
"missing 26+" under 5%. Per-version floor 55%. Non-ovnk: no drop >15pp.

**Step 1b:** Companion-scripted gates flaky rate under 10% (vs ~94%
for AI-only). Overall "gate(s) failed" rate drops ≥15pp. No regression
in "missing gates" metrics from Step 1.

**Step 2:** All Step 1 criteria maintained. Zero step-skipping failures
regardless of repo size.

**Step 3:** Within 5pp of Step 1 rate. One zero-recipe success.

### Expected ovnk pass rate progression

| Step | Rate (pessimistic) | Rate (optimistic) | Assumption |
|------|--------------------|--------------------|------------|
| True baseline (Step 0) | 26% | 26% | 16 genuine passes / 62 total runs |
| After Step 1 alone | 45% (30% eff.) | 65% (90% eff.) | "missing" converts to pass, not "gate failed" |
| After Step 1 + 1b | 51% | 73% | companion scripts fix 2-4 of 10 gate failures |
| After Step 2 | 61% | 82% | fixes remaining missing + gate-fail compound |
| Ceiling | 84%+ | 84%+ | all missing fixed + companion scripts reduce flaky gates |

**Key caveat:** "missing → pass" is the weakest assumption. Some agents
forced to continue will produce failing gates, not passing ones. The
70% point estimate is a midpoint, not a guarantee. Step 1b (companion
scripts) addresses the "balloon squeeze" — without it, fixing step-
skipping just converts "missing" into "gate failed."

Validation: ~2 days compute, $250-900 API cost for 15 ovnk runs.
Cannot parallelize same repo (harness uses single repo clone).

Steps revertible in reverse order. `make lint` passes at every step.
Gate PASS is the minimum bar; court PASS (adversarial trial against
known-good reference, where available) is the quality confirmation.

## 8. Observability (universal, all steps)

Current visibility is minimal: results.tsv has 6 columns, gate names
aren't logged, no timing/model/diff data. Two additions:

**results.tsv: 4 new columns (positions 7-10):**
- `model` (exact model ID), `gates_tally` (pass/fail counts),
  `duration_s` (wall clock), `diff_hunks` (non-vendor code hunks).
  All values already computed in `_do_record_one` but not persisted.
  Backward-compatible (old `awk` on `$1-$6` unaffected).

**telemetry.jsonl: deterministic event log:**
- Single `_telem()` bash function (~3 lines) emits JSON events at
  step-start, step-end, gate-verdict, autofix-result boundaries.
- ~20 instrumentation points across scripts + SKILL.md bash blocks.
- Deterministic (timestamps, exit codes, counts) — no AI judgment.
- Aggregatable via `make telemetry` (`jq` over worktree files).

**progress.json: machine-readable session state:**
- Updated by orchestrator after each gate wave. Contains per-step
  status, gate counts, timing, model ID, target version.
- Three consumers: Stop hook (actionable block messages with step
  context), test harness (WHERE failures occur), Step 5 rebase report.

**Gate companion script scope (broader than Step 1b's 4):**
- 18 of 33 gates (55%) could have deterministic fast-path scripts
- 6 more are hybrid (script narrows scope, AI judges findings)
- 9 are pure judgment (no script value)
- Step 1b starts with 4 highest-value; expand based on post-Step-1
  diagnostic data showing which gates fail most under forced continuation

## 9. Caveats

- Pass rates include 42% false positives. Recompute after Step 0.
- Per-version corrected rates: 1.34.1=37%, 1.35.3=12%, 1.36.2=35%.
  **1.35.3 is the blocker** — 7/10 passes were false positives, and
  it uniquely has 50/50 gate-failed vs missing (others are ~85% missing).
- 112 "no-token" sessions: 76% are test harness artifacts, true
  infrastructure failure rate is ~7%.

## 10. Architecture Vision: Unified Orchestrator

The "deterministic scaffolding, agentic judgment" principle taken to
its logical conclusion. One script replaces the checkpoint, Stop hook
gate counting, gate runner, and state tracking.

### `k8s-rebase-orchestrator.sh` (~250-350 lines)

Unified bash script with 4 subcommands:

**`init <repo> <version>`** — create `.rebase-tmp/state.json` (current
step, timestamps), create gates directory, clear stale reports.

**`gates <step>`** — iterate gate .md files for this step. For gates
WITH companion `.sh` scripts: run the script. If PASS (`NEW_ISSUES=0`),
call `write-gate-report.sh` directly — no subagent needed. Output two
lists: RESOLVED (fast-path PASS) and PENDING (need subagents). The
agent launches subagents ONLY for PENDING gates. Expected **65-75%
subagent reduction** (~13 fewer per run, ~26 min saved, ~650K tokens).

**`advance`** — check all gate reports for current step. Every report
must exist, contain PASS verdict, and be newer than the latest commit
(stale-report detection). If satisfied: bump step, update timestamps.
If not: exit 1 with specific missing/failing gate names. After 3
failed advances: force-advance with warning. This replaces the
checkpoint, makes skip-to-Step-5 structurally impossible.

**`status`** — compact per-step table (gates expected/actual, PASS/
FAIL/SKIP breakdown, elapsed time per step). Consumed by: the Stop
hook (actionable block messages), the test harness (WHERE failures
occur), and `cmd_watch` (real-time display).

### SKILL.md as boot loader (~42 lines)

SKILL.md is loaded statically (full text at invocation — no conditional
rendering). It becomes a boot loader: run `orchestrator.sh status`,
read the returned state, use the Read tool to load the matching step
file (`steps/step2-compilation.md`). Other step files never enter
context. After completing a step: `orchestrator.sh advance`, then read
the next step file.

For TRUE context isolation (agent literally can't see other steps),
combine with Agent delegation: SKILL.md spawns a subagent with only
the current step file. The orchestrator decides WHICH step agent to
spawn. State machine and Agent delegation compose — they enforce
different invariants (ordering vs isolation).

### Stop hook simplification

With the orchestrator, the Stop hook becomes 5 lines: read `cwd` from
stdin, run `orchestrator.sh status`, if state ≠ done → BLOCK with the
status output as the reason message. All the current Stop hook
complexity (gate counting, content validation, iteration counter)
moves into the orchestrator.

### Failure taxonomy (7 codes, 3 layers)

Classify every failure by independently-addressable layer:
- **Infra** (9%): INFRA-STALE, INFRA-CRASH, INFRA-NOGATE → retry
- **Agent** (39%): SKIP-BOUNDARY, SKIP-EFFORT, SKIP-PARTIAL → orchestrator
- **Quality** (49%): GATE-FLAKE, COURT-FAIL → companion scripts

The "onion": 64% → 66% (infra) → 78% (no skip) → 94% (no flake) →
99% (only real quality issues). Add `fail_code` to results.tsv.

### Gate classification (19 + 12 + 8 = 33)

- **19 deterministic** — machine-checkable predicates (build exit
  code, grep patterns, version comparison). Orchestrator fast-paths.
- **12 judgment** — require AI (semantic review, data flow tracing,
  release note analysis). Always launch subagents.
- **8 informational** — always PASS by design. Orchestrator writes
  PASS directly, zero subagent cost. (4 currently, 4 more candidates.)

### Self-improving skill loop

Each run's skill-improvement gate produces structured suggestions.
Harvest into `suggestions.jsonl` during `auto_record()` (~5 lines).
`make suggestions` aggregates — count≥3 flagged as automation
candidates. `make improve` templates autofix functions. No LLM in
the improvement loop.

### Observable pipeline

8 event types in `events.jsonl` (step-enter, gate-verdict, fix-commit,
script-done). Enhanced `cmd_watch` shows current activity. Post-mortem:
`jq 'select(.verdict=="FAIL")' events.jsonl`.

### Additional hooks and conventions

- **Module safety hook:** PreToolUse blocking `go mod tidy/get/vendor/
  edit/generate/run`. #1 most-violated, most destructive.
- **Vendor hook:** PreToolUse on Edit/Write blocking `/vendor/` paths.
- **Gate YAML frontmatter:** `type: blocking|informational`,
  `script: <companion>.sh`, `report-name: step3-crd-validation`.
- **gate-script-lib.sh:** Shared boilerplate for companion scripts.

## 11. Not In Scope

- Multi-repo coordinator (library-go → ovnk → CNO sequencing)
- 2-of-3 voting for AI-judgment gates (rejected: up to 9 invocations
  per flaky gate when combined with 3-retry fix loop; too expensive)
- Additional gate companion scripts beyond the initial 4 (18 total
  candidates identified; expand based on Step 1 diagnostic data)
- Gate consolidation (33 → ~28)
- Fix maintainer-review.md contradiction (line 27 "FAIL if scope
  creep" vs line 55 "always use PASS" — potential gate flakiness source)
- CI integration (draft PRs for Prow feedback)
- Operator runbook / new maintainer guide
- Test harness infrastructure reliability (crash recovery, rate limits)
- Starter template for other teams (future: `plugins/skill-template/`)
