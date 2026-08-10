# Audit: Step Isolation and Generality Plan

Review of the rewritten plan (commits `a5138602` through `da515fda`).
Conducted via 12 verification agents + 20 adversarial self-review
agents. The adversarial pass retracted or corrected over half the
original findings. Every number was independently cross-checked
against `results.tsv` (249 entries) and all 33 gate .md files.

---

## 1. Ship Incrementally (the #1 finding)

The plan proposes ~10 new components simultaneously. This is a
**design document, not a sprint plan.** Building 10 components at once
means you can't isolate what works, can't ship intermediate value,
can't fall back, and can't measure ROI incrementally.

The failure breakdown reveals a natural delivery order:

**Phase 0 (hours):** Fix "default branch" → "current branch" in
SKILL.md (2 lines). Unblocks accurate test measurement. Can fold into
the rewrite, but the fix is trivial and independent.

**Phase 1 (2-3 days):** Companion scripts only. Add 4 `.sh` files
alongside existing gate `.md` files. No orchestrator, no SKILL.md
rewrite, no hooks. Addresses gate flakiness (49% of failures). The
pattern is proven by 2 existing companion scripts. Independently
shippable and measurable.

**Phase 2 (3-4 days):** Step file extraction + Agent delegation. Split
SKILL.md into step files. Rewrite as boot loader. Addresses step-
skipping (39% of failures). Each step agent gets fresh context and
limited instructions.

**Phase 3 (measure, then decide):** Run the matrix. If ovnk hits
50%+, the orchestrator becomes optimization, not necessity. If still
below 40%, build the orchestrator with data to scope it precisely.

Phase 1 + Phase 2 = **Alternative C** in the pragmatic analysis:
addresses 88% of failure categories at 5-7 days cost vs the full
plan's 2-4 weeks. Ships intermediate value at each phase.

---

## 2. Numerical Issues

### 2a. HIGH: Onion percentages are poorly annotated

The plan's "64% → 66% → 78% → 94% → 99%" is **correct under the
balloon squeeze model** — documented at plan line 358 ("Forced
continuation may produce gate failures, not passes"). With squeeze
fractions of ~63%/86%/75%, all five percentages match to within
rounding. The naive additive model (every fixed failure becomes a
pass) gives different numbers (67%/81%/99%/100%).

The presentation is misleading because the onion reads as simple
additive peeling but is actually squeeze-adjusted. Fix: annotate
inline or add a footnote stating the squeeze assumption.

### 2b. HIGH: "65-75% subagent reduction" is misleading

The three numbers (65-75%, ~13 fewer, 19/33) are mutually inconsistent
under any single interpretation. More fundamentally: the plan
simultaneously fixes step-skipping (increasing gates from ~20 to 33)
AND adds companion scripts (reducing 33 to ~20). The net gate
subagent count is approximately unchanged. Plus 5 new step-level
Agent() subagents.

The "65-75%" correctly describes the fast-path rate among
deterministic gates (~13/19). But this is not a "subagent reduction"
— it is a "fast-path success rate for the deterministic subset."

The real value proposition is **determinism and reliability** (gates
that fast-path via bash cannot flake), not subagent count. Reframe
the claim around reliability improvement.

### 2c. MEDIUM: Pessimistic table could use a footnote

The baseline (26% ovnk-true) IS stated 3 lines above the table ("from
26% baseline"). The table is unambiguous in context. Adding "(true
ovnk baseline: 26%)" as a table footnote would improve clarity.

---

## 3. Design Corrections

### 3a. HIGH: "Structurally impossible" overstates the guarantee

The plan claims "Skip-to-Step-5 is structurally impossible" (line 84)
but says "defense-in-depth alongside command hooks" (line 195). These
contradict each other. The architecture genuinely eliminates the
dominant failure mode (agent reads Step 5 from monolithic prompt) —
100% of observed step-skipping in 249 runs was passive non-compliance,
not adversarial bypass. But 5 attack vectors remain viable under
active circumvention (read ahead via filesystem, forge reports, skip
calling advance, force-advance abuse, idle without exiting).

**Recommended language:** "The dominant failure mode is eliminated.
Skipping now requires bypassing multiple independent controls
(orchestrator state, gate reports, stop hook, fresh subagent context),
making it significantly harder but not impossible."

### 3b. MEDIUM: Force-advance design is correct as-is

The original audit recommended force-advance count only stale blocks,
never genuine FAILs. This is **wrong** — it would create unbounded
retry (agent loops forever on a genuinely unfixable gate). The plan's
design (force-advance on any block type + INCOMPLETE markers + draft
PR degradation) provides adequate safety. The gate-fix loop already
gives 3 iterations × 3 advance attempts = 9 chances.

**One improvement:** Log `force_reason: stale|FAIL` in the INCOMPLETE
marker for forensics.

---

## 4. Verified: Architecture Is Sound

### 4a. Orchestrator design is feasible

The 4-subcommand design (init, gates, advance, status) is well-
motivated. Size is tight at 250-350 (realistic: 300-400 without
telemetry). SHA-based stale detection is a clear improvement over
mod-time. One edge case: force-advance applies to both stale and FAIL
blocks — the plan's design is correct (see 3b).

Exit code conflict: `k8s-rebase.sh` uses exit 2 for "success with
work done" while the orchestrator proposes exit 2 for "usage error."
Document the discrepancy.

### 4b. Boot loader pattern is correct

Current SKILL.md at 6,619 words exceeds the 5,000-word skill limit
(ideal: 1,500-2,000). 42 lines is aspirational — 55-70 is realistic.
`${CLAUDE_PLUGIN_ROOT}` works in SKILL.md bash blocks (proven). Key
constraint: step files loaded via Read do NOT get text-substitution —
pass resolved PLUGIN_ROOT in the Agent prompt.

### 4c. Step extraction is feasible

All steps self-contained (verified line-by-line). Step 4 is ~240 lines
(breaks 200-line ceiling). Fix: extract 4d (`--bump-tools`) to a
separate conditional step + move test-splitting examples to docs.

### 4d. Companion scripts are well-targeted

The 4 named scripts are overwhelmingly mechanical. The gate-script-
lib.sh (~40-50 lines) is straightforward. The crd-validation/patterns-
completeness fast-path pattern is proven.

### 4e. block-module-ops.md works correctly

The original audit said this hook would "break the workflow." This was
**wrong**. PreToolUse hooks see the Bash tool's `tool_input` (the
command the AI typed), NOT commands executing inside subprocess scripts.
All legitimate `go mod tidy`/`go get` operations flow through scripts
(invoked as `bash /path/to/script.sh`). The hook naturally blocks only
direct agent invocations — which is the dangerous case.

### 4f. Gate YAML frontmatter is justified

The original audit recommended convention-over-configuration. The
adversarial review demonstrated that convention fails: the 4
informational gates share no naming convention, and shared scripts
like `build-vet.sh` (used by 2 gates in different directories) break
name-matching. Frontmatter provides a single source of truth that
both orchestrator and harness read. Drop `report-name` (convention-
derivable) but keep `type` and `script`.

### 4g. 19 deterministic gates is defensible

The plan counts gates whose bash predicate can produce PASS/SKIP at
zero subagent cost, not gates that are fully deterministic under all
circumstances. Under this interpretation: 12 clearly deterministic +
5 fast-path SKIP/PASS + 4 explicit informational = 21. The plan's 19
is conservative. The "8 informational" = 4 always-PASS + 4 fast-path
SKIP/PASS gates. The terminology is confusing and should be clarified
("zero-cost fast-path" rather than "informational").

### 4h. Cross-run report contamination is handled

Worktrees provide physical isolation (each run's `.rebase-tmp/` is
in a different directory). `init` clears reports on fresh start. SHA
detection catches stale-resume cases. The gap is narrow: only the
resume path with a version change. Fix: add k8s version to state.json
so init detects version changes as fresh starts.

### 4i. mutate_plugin migration is not a gap

`${CLAUDE_PLUGIN_ROOT}` resolves via `--plugin-dir` pointing at the
mutated copy. All references auto-resolve. The ugly sed path-rewriting
(lines 617-620) can be deleted entirely. Autofix neutering and
patterns stripping work unchanged.

### 4j. Observability: keep events.jsonl, cut self-improving loop

events.jsonl (~23 lines: 3-line `_telem()` + ~20 call sites) provides
timeline debugging essential for a system introducing 5+ new
components. The orchestrator's `status` is a snapshot; events are a
timeline. Keep `model`, `duration_s`, `fail_code` TSV columns.

**Cut**: self-improving loop (requires LLM for free-text
deduplication, contradicts "no LLM in the improvement loop"). Defer
`make improve`.

---

## 5. Gaps the Plan Should Address

### 5a. MEDIUM: Design Principles (Section 2) unexercised

The plan defines 4 principles but never tests components against them.
Principle 1 (deterministic scaffolding) supports companion scripts.
Principle 4 (teachability) supports frontmatter over convention. The
plan should briefly state how each major component embodies the
principles.

### 5b. MEDIUM: Transition path unspecified

No build ordering, no rollback mechanism, no statement of which
components can be deployed independently. The incremental delivery
recommendation (Section 1) addresses this, but the plan itself should
specify the phased approach.

### 5c. MEDIUM: Boot loader retry budget unspecified

Step agents get 3 gate-fix iterations per gate. The boot loader should
get 1-2 retries of the entire step agent if advance still fails.

---

## Summary Table

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | Ship incrementally (companion scripts → step extraction → measure → decide on orchestrator) | **CRITICAL** | Decompose into 3-4 phases |
| 2a | Onion percentages: correct under squeeze model but poorly annotated | HIGH | Add squeeze footnote |
| 2b | 65-75% subagent reduction misleading (net count unchanged) | HIGH | Reframe around reliability |
| 3a | "Structurally impossible" overstates; plan contradicts itself (line 84 vs 195) | HIGH | Align with own defense-in-depth language |
| 2c | Table baseline: stated in context, add footnote | MEDIUM | Add "(26% baseline)" to table |
| 3b | Force-advance design is correct; add force_reason to INCOMPLETE marker | MEDIUM | Log stale vs FAIL reason |
| 5a | Design Principles unexercised | MEDIUM | Map components to principles |
| 5b | Transition path unspecified | MEDIUM | Add phased delivery plan |
| 5c | Boot loader retry budget unspecified | MEDIUM | Add 1-2 step-level retries |
| 4a-j | Orchestrator, boot loader, extraction, companion scripts, hooks, frontmatter, gates, contamination, mutate_plugin, observability | **Verified** | Architecture is sound |

### Corrections from adversarial self-review

The 20-agent adversarial pass retracted or corrected 10 findings:
- **Retracted**: block-module-ops breaks workflow (hooks can't see
  inside scripts), force-advance stale-only (creates unbounded retry),
  convention over frontmatter (shared scripts break convention),
  mutate_plugin gap (PLUGIN_ROOT makes it simpler), cross-run
  contamination HIGH (worktrees provide isolation)
- **Reversed**: onion math "ALL wrong" (correct under squeeze model),
  19 deterministic gates "overstated" (defensible at 21 fast-path)
- **Downgraded**: 3 CRITICAL → HIGH (presentation errors not design
  flaws), 2 HIGH → MEDIUM (test measurement not production)
- **Added**: incremental delivery (#1 finding), subagent reduction
  net-zero insight
