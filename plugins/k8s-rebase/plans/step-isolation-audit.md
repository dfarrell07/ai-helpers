# Audit: Step Isolation and Generality Plan (Revised)

Review of the rewritten plan (`step-isolation-and-generality.md`,
commits `a5138602` through `da515fda`). Phase 1: read the revised
plan. Phase 2: 12 agents verified every component — orchestrator
design, boot loader, companion scripts, enforcement hooks,
observability, stale detection, skip-impossible claim, gate YAML
frontmatter, size estimates, plan coherence, step extraction, and
audit findings addressed. All numbers cross-checked against
`results.tsv` (249 entries) and 33 gate .md files.

---

## 1. CRITICAL: Numerical Errors

### 1a. Onion percentages are wrong

The failure counts (35+44+8+2=89) are correct. The percentages are
not computed from them. With 249 total runs (160 PASS, 89 FAIL):

| Layer removed | Computed % | Plan claims | Error |
|---|---|---|---|
| Raw | 64.3% | 64% | OK |
| -8 infra | 67.2% | 66% | +1.2pp |
| -35 skip | 81.4% | 78% | +3.4pp |
| -44 gate flake | 99.2% | 94% | **+5.2pp** |
| -2 court | 100% | 99% | +1pp |

Every intermediate percentage is wrong. The 94% → 99.2% gap is the
most misleading — it understates the impact of fixing gate flakiness.

### 1b. "19 deterministic gates" is overstated

The plan claims 33 = 19 deterministic + 14 judgment, with the 19
comprising "8 informational + 11 blocking." Verified against all 33
gate .md files:

| Category | Plan claims | Actual |
|---|---|---|
| Informational (always PASS) | 8 | **4** |
| Fully deterministic blocking | 11 | **10** |
| Mostly deterministic blocking | (included) | **3** |
| **Total "deterministic"** | **19** | **14-17** |

Only 4 gates are explicitly informational (commit-messages, dep-cve-
check, maintainer-review, skill-improvement). The plan doubles this
without basis in the gate files. If 4 additional gates are intended
to become informational, the plan must say so explicitly.

### 1c. Three-way contradiction on subagent reduction

Line 135-136 claims "65-75% subagent reduction (~13 fewer per run)."
These three numbers are mutually inconsistent:

| Calculation | Result |
|---|---|
| From gate split (19/33) | 57.6% |
| From "~13 fewer" (13/33) | 39.4% |
| Plan claims | 65-75% |

The "~13 fewer" is internally consistent with "~26 min saved" and
"~650K tokens saved." The 65-75% headline is unsupported. For ovnk
specifically (high issue density), many "deterministic" gates will
find real issues and NOT fast-path — realistic ovnk reduction is
~27-33% (~9-11 fewer).

### 1d. Pessimistic/optimistic table baseline ambiguous

The pessimistic "45%" after orchestrator+hooks is below the current
64% all-repo raw rate. If measured against the 26% ovnk-true
baseline, 45% = +19pp (defensible). If against 64% all-repo-raw,
it implies the orchestrator makes things worse. The table does not
specify which baseline it uses.

---

## 2. HIGH: Design Issues

### 2a. "Structurally impossible" is inaccurate

The plan claims "Skip-to-Step-5 is structurally impossible." Seven
attack vectors were tested — all realistic to varying degrees:

1. Agent can `ls steps/` and `Read steps/step5-pr.md` (trivial)
2. Agent can write 33 fake PASS reports via write-gate-report.sh
3. Agent can skip calling `orchestrator.sh advance` entirely
4. Force-advance after 3 failures is a designed bypass pathway
5. Agent can go idle (stop hook only fires on session termination)

The architecture converts a behavioral problem into a higher-friction
behavioral problem. The agent is still the top-level controller; the
orchestrator is a tool it calls, not a container it runs inside.

**Recommended language:** "The dominant failure mode (agent reads
Step 5 from the monolithic prompt) is eliminated. Skipping now
requires bypassing multiple independent controls (orchestrator state,
gate reports, stop hook, fresh subagent context), making it
significantly harder but not impossible."

### 2b. block-module-ops.md would break the workflow

PreToolUse hooks are global — they fire for ALL Bash calls regardless
of agent depth. The main agent is REQUIRED to run `go mod tidy`,
`go mod vendor` in Steps 2, 3, and 4d. A blanket hook blocking
these commands would prevent legitimate operations. There is no
mechanism to scope PreToolUse hooks to subagents only.

The existing approach (duplicating the rule in all 33 gate prompts
+ SKILL.md preamble) is actually correct for a role-specific
prohibition. **Do not implement block-module-ops.md as designed.**

block-vendor-edit.md is correctly scoped (targets Edit/Write tools,
not Bash — so `go mod vendor` via Bash passes through).

### 2c. Force-advance must distinguish stale from genuine FAIL

The orchestrator's "force-advance after 3 failed attempts" would
bypass genuinely failing gates (e.g., real build errors), cascading
broken code through subsequent steps. The 3-attempt counter must
only count stale-report-related blocks, never genuine FAIL verdicts.

### 2d. Cross-run report contamination

`status` reconstruction and `init` resume would pick up gate reports
from prior runs unless reports are tagged with session/version info.
The SHA staleness check is necessary but insufficient — a different
rebase run on the same repo could have matching SHAs from a
rebased branch. Reports should include the target k8s version.

### 2e. Step 0 not treated as immediate

The branch fix ("default branch" → "current branch") is folded into
the full SKILL.md rewrite (Section 4.2) instead of being a
standalone immediate action. It takes minutes, unblocks all
measurement, and should be implemented NOW — not gated on the
orchestrator build. Step 0 should have been implemented already.

---

## 3. Verified: Architecture Is Sound

### 3a. Orchestrator design is feasible

The 4-subcommand design (init, gates, advance, status) is well-
motivated. Inter-step state is almost entirely filesystem-based (git
commits, `.rebase-tmp/` files, arguments). The orchestrator is a
natural consolidation point. SHA-based stale detection is a clear
improvement over mod-time. Size estimate of 250-350 lines is tight
but achievable at 300-400 without telemetry.

Exit code conflict: `k8s-rebase.sh` uses exit 2 for "success with
work done" while the orchestrator proposes exit 2 for "usage error."
Not a code-path conflict today but should be documented.

### 3b. Boot loader pattern is correct

Current SKILL.md at 6,619 words exceeds the documented 5,000-word
skill limit (ideal: 1,500-2,000). The boot loader pattern directly
addresses this. `${CLAUDE_PLUGIN_ROOT}` works in SKILL.md bash
blocks (proven by 2 other skills in the repo). 42 lines is
aspirational — 55-70 is realistic. Key constraint: step files loaded
via Read do NOT get text-substitution. The boot loader must pass the
resolved PLUGIN_ROOT in the Agent prompt.

### 3c. Step extraction is feasible

Complete line-by-line mapping verified. All steps are self-contained
— no step agent needs to read another step's instructions. Cross-
step state flows through `.rebase-tmp/` files. Step 4 is the
exception at ~240 lines (breaks the 200-line ceiling). Fix: extract
4d (`--bump-tools`) to a separate conditional step file + move test-
splitting RAM examples to docs. Five additional extraction challenges
found beyond the plan's three (none are blockers).

### 3d. Companion scripts are well-targeted

The 4 named priority scripts (build-vet, version-consistency, go-
version-check, major-version-imports) are all overwhelmingly
mechanical — verified by reading every gate .md file. The
`gate-script-lib.sh` shared boilerplate (~40-50 lines) is
straightforward. The crd-validation/patterns-completeness pattern
(MANDATORY FIRST STEP + NEW_ISSUES=0 fast-path) is proven.

### 3e. Audit findings mostly addressed

Of 11 findings from the prior audit: 6 fully addressed, 3 partially
addressed (Step 0 not immediate, only 4 of 19 scripts named,
validation criteria not two-tiered), 2 not addressed (mutate_plugin
breakage, maintainer-review contradiction).

---

## 4. MEDIUM: Simplification Opportunities

### 4a. Gate YAML frontmatter — use convention instead

All three proposed frontmatter fields are inferable:
- `type`: `INFO_GATES` list (already maintained in test-skill.sh)
- `script`: check if `${md_file%.md}.sh` exists alongside the .md
- `report-name`: derive as `step{N}-{filename}` (consistent across
  all 33 gates)

Frontmatter creates two sources of truth that can diverge silently,
requires YAML parsing in bash, and adds 33 maintenance points. Use
convention-based inference in the orchestrator (~10 lines).

### 4b. Observability — cut events.jsonl and self-improving loop

**Keep** (HIGH value): `model`, `duration_s`, `fail_code` columns in
results.tsv — ~20 lines of harness change total.

**Cut**: events.jsonl (8 types, 20 instrumentation points) is
overengineered — the orchestrator's `status` subcommand provides
sufficient observability. The self-improving loop is not realistic
without LLM for free-text deduplication, contradicting its own "no
LLM in the improvement loop" constraint.

### 4c. Structured return format — use filesystem

The Agent tool has no schema enforcement. Drop the structured return
format (STEP_VERDICT, GATES_PASSED, COMMITS) from the prompt
template. Use `orchestrator.sh advance` reading .report files as the
decision mechanism. The agent's text return is for logging only.

### 4d. mutate_plugin migration not addressed

The test harness's spec=all/none mechanism relies on sed patterns
targeting SKILL.md find calls. The step-file architecture breaks
this with no migration plan. The plan should specify how mutate_
plugin's sed patterns move to step files or adopt a different spec
injection mechanism.

---

## 5. Additional Findings

### 5a. 1.35.3 has no version-specific strategy

1.35.3 has a 12% true pass rate (the blocker) and is gate-flake-
dominated (7 of 14 failures). The plan's "per-version floor 55%"
requires 4.6x improvement on this version with no specific plan.
The stop hook addresses at most 4 of 14 1.35.3 failures. Companion
scripts are the primary lever but the plan doesn't prioritize them
for 1.35.3's specific failure gates.

### 5b. Depth-2 hook behavior unverified

The plan correctly identifies this uncertainty (line 193-195) but
designs two new hooks (block-module-ops, block-vendor-edit) that
depend on it. Test hook behavior at depth 2 BEFORE building hooks
that require it. block-module-ops.md has the additional fundamental
problem of blocking legitimate operations (2b above).

### 5c. Boot loader retry budget unspecified

The step agent gets 3 gate-fix iterations per gate. The boot loader
should get 1-2 retries of the entire step agent if advance still
fails. This split retry budget (3 per gate + 1-2 per step) is not
discussed in the plan.

---

## Summary Table

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1a | Onion percentages all wrong (94% should be 99%) | CRITICAL | Recompute from failure counts |
| 1b | 19 deterministic gates is actually 14-17 | CRITICAL | Fix count; specify which 4 additional become informational |
| 1c | 65-75% subagent reduction unsupported by any consistent math | CRITICAL | Use ~39% (13/33) or compute from actual counts |
| 1d | Pessimistic/optimistic table baseline ambiguous | CRITICAL | Specify ovnk-true or all-repo-raw |
| 2a | "Structurally impossible" is inaccurate | HIGH | Reword to "defense in depth through friction" |
| 2b | block-module-ops.md breaks Steps 2/3/4d | HIGH | Do not implement; keep prompt-based rule |
| 2c | Force-advance bypasses genuine FAILs | HIGH | Only count stale blocks, never FAIL blocks |
| 2d | Cross-run report contamination | HIGH | Add session/version tag to reports |
| 2e | Step 0 not treated as immediate action | HIGH | Implement independently of orchestrator |
| 3a-e | Orchestrator, boot loader, extraction, companion scripts, audit findings | Verified | Architecture is sound |
| 4a | Gate YAML frontmatter → use convention | MEDIUM | Saves 33 maintenance points |
| 4b | events.jsonl + self-improving loop → cut | MEDIUM | Keep 3 TSV columns only |
| 4c | Structured returns → use filesystem | MEDIUM | orchestrator.sh advance is the decision mechanism |
| 4d | mutate_plugin migration missing | MEDIUM | Specify sed pattern migration |
| 5a | 1.35.3 has no version-specific strategy | MEDIUM | Prioritize companion scripts for 1.35.3 gates |
| 5b | Depth-2 hook behavior unverified | MEDIUM | Test before building hooks |
| 5c | Boot loader retry budget unspecified | MEDIUM | Add 1-2 step-level retries |
