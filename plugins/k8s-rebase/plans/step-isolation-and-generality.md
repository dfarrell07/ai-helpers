# k8s-rebase: Step Isolation and Version-Agnostic Generality

## 1. Problem

The k8s-rebase skill works for 5 smaller repos (90%+) but fails on
ovn-kubernetes (26% true pass rate, 16/62). Of 89 total failures:

| Layer | Failures | % | Root cause | Fix |
|-------|----------|---|------------|-----|
| Agent skipping | 35 | 39% | Agent skips Steps 3-4, jumps to Step 5 | Orchestrator enforces step ordering |
| Gate flakiness | 44 | 49% | 31/33 gates are pure AI judgment, 94% flaky | Companion scripts for deterministic fast-path |
| Infrastructure | 8 | 9% | Stale branch, crashes, harness bugs | Retry + harness fixes |
| Court rejection | 2 | 2% | Real quality regressions | Investigate |

The "onion": 64% raw → 66% (infra fixed) → 78% (no skipping) →
94% (no gate flake) → 99% (only real quality issues).

**Step-skipping is behavioral, not resource exhaustion.** Sessions used
14-50% of 1M context. 60% of "missing" failures land on exact step
boundaries. Transcript evidence: *"Given the significant amount of
work remaining... let me proceed directly to Step 5."*

**Gate flakiness is non-deterministic AI judgment.** Same repo+version
passes in other runs for 94% of gate failures. Only 2 of 33 gates
have companion scripts with deterministic checks.

### Glossary

- **spec=all/none**: Test modes. spec=all disables autofix+patterns
  (AI solves independently). spec=none enables all recipes (production).
- **Gates**: 33 `.md` files under `gates/step{1-4}*/` producing
  `.report` files (PASS/FAIL + rationale) via `write-gate-report.sh`.
- **N=X**: X gates missing. N=26 = stopped after step2 (7 of 33 done).

## 2. Design Principles

1. **Deterministic scaffolding, agentic judgment.** Can it be a
   for-loop? Deterministic. Does it require reading code and making a
   judgment? Agentic. Four roles: scripts = what always happens,
   hooks = what must never happen, gates = what must be verified,
   AI prompts = what requires thinking.

2. **Clarity over cleverness.** Architecture readable from `tree`.

3. **Modern Claude Code patterns.** `${CLAUDE_PLUGIN_ROOT}`, hooks
   for enforcement, Agent delegation for step isolation.

4. **Teachability.** Code reads as a tutorial for multi-step AI
   automation with quality gates.

## 3. Architecture

### Current (monolithic, 981-line SKILL.md)

```
claude --bg session (single 1M context)
└── SKILL.md (981 lines) orchestrates Steps 1-5 via prose
    ├── Step 3: autofix + 11 gates           ← SKIPPED
    ├── Step 4: lint/test/review + 15 gates  ← SKIPPED
    └── Step 5: PR command                   ← JUMPED TO
```

### Target (orchestrator + boot loader + step agents)

```
claude --bg session
└── SKILL.md (~42 lines, boot loader)
    ├── orchestrator.sh init
    ├── orchestrator.sh status → current step
    ├── Read steps/<current-step>.md
    ├── Agent(step file + rules.md)  ← fresh context per step
    │   └── orchestrator.sh gates → fast-path PASS or launch subagents
    ├── orchestrator.sh advance → next step or BLOCKED
    └── repeat until done
```

Skip-to-Step-5 is **structurally impossible** — the orchestrator only
advances when all gates for the current step have PASS reports newer
than the latest commit. The agent never sees other steps' instructions.

### Directory layout

```
plugins/k8s-rebase/
  # Runtime:
├── skills/k8s-rebase/SKILL.md        # Boot loader (~42 lines)
├── steps/                             # Step instructions
│   ├── rules.md                       # Shared rules (module safety, etc.)
│   └── step{1-5}*.md                  # One file per step
├── gates/                             # 33 gate files + companion scripts
│   ├── step1-rebase/                  # 1 gate
│   ├── step2-compilation/             # 6 gates
│   ├── step3-autofix/                 # 11 gates (+ 2 existing .sh)
│   └── step4-verification/            # 15 gates
├── scripts/
│   ├── k8s-rebase.sh                  # Deterministic dep bump
│   ├── k8s-rebase-validate.sh         # Build/vet/lint/test runner
│   ├── k8s-rebase-autofix.sh          # Scripted fix patterns
│   ├── k8s-rebase-orchestrator.sh     # NEW: state machine + gate runner
│   ├── write-gate-report.sh           # Gate report writer
│   └── gate-script-lib.sh             # NEW: companion script boilerplate
├── hooks/
│   ├── block-push.md                  # Existing (PreToolUse)
│   ├── block-module-ops.md            # NEW: blocks go mod tidy/get/etc.
│   ├── block-vendor-edit.md           # NEW: blocks /vendor/ edits
│   └── hooks.json + stop-hook.sh      # NEW: orchestrator-based Stop hook
├── docs/k8s-rebase-patterns.md
├── plans/
└── test/
```

## 4. Components to Build

### 4.1 k8s-rebase-orchestrator.sh (~250-350 lines)

Unified bash script. Single source of truth for step ordering, gate
counting, and companion script execution. Replaces the 33-gate
checkpoint, the standalone Stop hook logic, and the gate runner.

**`init <repo> <version>`** — create `.rebase-tmp/state.json` (step
number + timestamps), create gates directory, clear stale reports,
write `.session-active` sentinel.

**`gates <step>`** — iterate gate .md files for this step's directory.
For gates WITH companion `.sh`: run the script. If PASS
(`NEW_ISSUES=0`), call `write-gate-report.sh` directly — no subagent.
Output: RESOLVED list (fast-path PASS) and PENDING list (need
subagents). Expected **65-75% subagent reduction** (~13 fewer per run,
~26 min saved, ~650K tokens saved).

**`advance`** — check all gate reports for current step. Must exist,
contain PASS or FAIL verdict, and be newer than latest commit (stale
detection). If all present: bump step, update timestamps. If not:
exit 1 with specific missing/failing gate names + file paths. After 3
failed advances: force-advance with warning.

**`status`** — compact table: per-step gates expected/actual/PASS/FAIL,
elapsed time. Consumed by Stop hook, test harness, and `cmd_watch`.

**Worktree awareness (CRITICAL):** The orchestrator must accept the
repo path as an argument (from the agent's `cwd`, which is the
worktree). Gate counting uses PLUGIN_ROOT derived from `$0`. Sessions
run in `.claude/worktrees/<branch>/`, not the repo root.

state.json is minimal (step number + timestamps). Gate state lives in
the existing `.report` files on the filesystem — no duplication.

### 4.2 SKILL.md rewrite (~42 lines)

Boot loader pattern. SKILL.md is loaded statically (full text at
invocation), so it must be short — no step-specific instructions.

Content: frontmatter, 1-paragraph purpose, bash block to run
`orchestrator.sh status`, instruction to Read the matching step file
via Read tool, instruction to run `orchestrator.sh advance` after
completing work, recovery instructions (`orchestrator.sh status`
shows where to resume).

Absorbs baseline fixes: "current branch" (not "default branch"),
remove master-checkout recovery, `${CLAUDE_PLUGIN_ROOT}` for paths.

Preamble reframe: "Steps 3-4 are where you add unique value — the
quality gates that prevent CI rejection."

### 4.3 Step files (steps/*.md, ~150-200 lines each)

Extract from current 981-line SKILL.md into 6 files:
- `rules.md` — shared rules (module safety, commit discipline, scope,
  container commands, gate-fix loop protocol, nesting cap)
- `step1-rebase.md` — run rebase script, 1 gate
- `step2-compilation.md` — fix loop with validate.sh, 6 gates
- `step3-autofix.md` — run autofix, discovery checklist, 11 gates
- `step4-verification.md` — lint/test/review, 15 gates
- `step5-pr.md` — PR command generation, cleanup

Each step file starts with "Read rules.md first." Each ends with
"Run orchestrator.sh advance."

Autofix signal cleanup lives in step3:
- autofix.sh: `RESULT: FAIL` → `RESULT: ITEMS_REMAINING`, `exit 1` → `exit 0`
- Move "FAIL is normal" before the bash block
- Add "Regardless of output, proceed to gates"
- Fix line 520 contradiction ("cat" → "let subagent Read")

See `plans/autofix-disposition.md` for the full 26-function catalog
with self-gating guards and keep/remove recommendations.

**Robustness improvements** (in rules.md or step files):
- Oscillation detection: stop gate-fix loop if a previously-passed
  gate regresses after fixing a different gate
- Dirty-tree check: `git status --porcelain` at start of each
  gate-fix loop iteration
- go.mod broadening: use `find` for go.mod (catches multi-module repos)
- Checkpoint tightening: orchestrator's `advance` handles this
  (detects "not PASS" instead of just "is FAIL")

### 4.4 Companion scripts (4 priority + library)

Address gate flakiness (44/89 failures, 49%). The orchestrator's
`gates` subcommand runs these; no separate mechanism needed.

**4 priority scripts** (following crd-validation.sh pattern):
1. `build-vet.sh` — `go build && go vet`, diff vs base branch.
   Shared by step2/build-vet + step4/build-vet-recheck.
2. `version-consistency.sh` — parse go.mod, check k8s.io/* versions.
3. `go-version-check.sh` — compare `go` directive across files.
4. `major-version-imports.sh` — grep for bare `k8s.io/klog`.

**gate-script-lib.sh** — shared boilerplate: BASE merge-base
computation, cd to repo, exit-on-empty, NEW_ISSUES counter.

**Gate classification** (33 total = 19 deterministic + 14 judgment):
- 19 deterministic — fast-path PASS via bash predicate. Includes
  8 informational gates (always PASS, zero subagent cost) + 11
  blocking gates with machine-checkable predicates.
- 14 judgment — require AI (always launch subagent).
  Expand companion scripts post-validation based on diagnostic data.

### 4.5 Stop hook (~10 lines + hooks.json)

Simplified by the orchestrator. The hook reads `cwd` from stdin JSON,
runs `orchestrator.sh status "$CWD"`, and if state ≠ done, outputs
`{"decision": "block", "reason": <status output>}`. The orchestrator
handles all complexity (gate counting, stale detection, iteration
tracking, INCOMPLETE markers).

INCOMPLETE handling: test harness records as third verdict. Production:
Step 5 degrades to `--draft` PR with WARNING. Court skipped.

`stop_hook_active` check: exit 0 if another hook already blocked
(multi-hook safety). PLUGIN_ROOT from `$0` dirname.

### 4.6 Enforcement hooks (2 new .md files)

- **block-module-ops.md** — PreToolUse on Bash. Block `go mod tidy`,
  `go get`, `go mod vendor`, `go mod edit`, `go generate`, `go run`.
  #1 most-violated prohibition, most destructive (MVS corrupts pins).
- **block-vendor-edit.md** — PreToolUse on Edit/Write. Block paths
  containing `/vendor/`. #2 most-violated, wastes hours.

### 4.7 Observability

**results.tsv: 4 new columns** (model, gates_tally, duration_s,
diff_hunks). Already computed in `_do_record_one`, just not persisted.
Also add `fail_code` column for failure taxonomy.

**events.jsonl:** `_telem()` bash function (~3 lines) emits 8 event
types (step-enter, step-end, gate-verdict, fix-commit, script-done,
autofix-result, subagent-spawn, build-result). ~20 instrumentation
points. Enhanced `cmd_watch` shows current activity. Post-mortem:
`jq 'select(.verdict=="FAIL")' events.jsonl`.

**Failure taxonomy** (7 codes, 3 layers):
- INFRA-STALE, INFRA-CRASH, INFRA-NOGATE → retry
- SKIP-BOUNDARY, SKIP-EFFORT, SKIP-PARTIAL → orchestrator
- GATE-FLAKE, COURT-FAIL → companion scripts / investigate

**Self-improving loop:** Harvest skill-improvement gate suggestions
into `suggestions.jsonl` during `auto_record()`. `make suggestions`
aggregates (count≥3 = automation candidate). `make improve` templates
new autofix functions. No LLM in the improvement loop.

## 5. Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Model-version coupling | Critical | Log model ID per run. Continuous regression testing. |
| Goodhart's Law | High | Orchestrator runs companion scripts with deterministic evidence. Provenance validation: reports must contain exit codes or file:line citations. |
| Unbounded runtime | Medium | Set `--max-turns` and/or `--max-budget-usd`. CLI 8-block Stop hook cap. |
| Depth-2 nesting untested | High | Test on CNCC before ovnk. Within documented spawn depth 3. |
| PLUGIN_ROOT not shell env var | High | Gates keep `find`. Steps get literal paths via SKILL.md text-sub. |
| Discovery procedures unreliable | Medium | Autofix stays default. Discovery is additive (Step 3). |

## 6. Success Criteria

**End state:** ovnk spec=all pass rate 60-80%+ (from 26% baseline).
Per-version floor 55%. Non-ovnk repos: no drop >15pp. Zero
step-skipping failures. Companion-scripted gates flaky rate <10%.

**Validation:** 15+ ovnk runs (5 per version), ~2 days compute,
$250-900. Rollback if any per-version rate drops >10pp vs baseline.
Gate PASS is minimum bar; court PASS is quality confirmation.

| Metric | Pessimistic | Optimistic |
|--------|-------------|------------|
| After orchestrator + hooks | 45% | 65% |
| After companion scripts | 55% | 75% |
| Ceiling (all layers addressed) | 84%+ | 94%+ |

## 7. Caveats

- Baseline includes 42% false-positive passes. True rate: 26% (16/62).
- Per-version: 1.34.1=37%, **1.35.3=12%** (blocker), 1.36.2=35%.
- "missing → pass" is the weakest assumption. Forced continuation may
  produce gate failures, not passes (balloon squeeze).
- 112 "no-token" sessions: 76% test harness artifacts, ~7% real.
- SKILL.md is static (loaded in full). True context isolation requires
  Agent delegation, not conditional display.

## 8. Not In Scope

- Discovery procedures replacing version-specific recipes (future)
- Multi-repo coordinator (library-go → ovnk → CNO sequencing)
- 2-of-3 voting for AI-judgment gates (too expensive: 9 invocations)
- Gate consolidation (33 → ~28)
- Fix maintainer-review.md contradiction (FAIL vs always PASS)
- CI integration (draft PRs for Prow feedback)
- Starter template for other teams
