# Remaining Work — k8s-rebase Skill

Two genuine improvements remain. Everything else is done, deferred with clear
rationale, or fluff. This replaces the historical gate-architecture audit docs
and the completed next-work.md.

---

## 1. Production adversarial juror (step 5) — HIGH

**What**: Add a single `claude -p` call to `step5-pr.md` that reviews the final
diff before `gh pr create`. This is the only adversarial check that runs in
production — the court runs only in test mode.

**Why it matters**: Currently zero adversarial review of a production rebase before
the PR is opened. A single juror reading the diff with the same criteria as the
court catches obvious errors cheaply.

**Implementation**: ~20-30 lines in `skills/k8s-rebase/steps/step5-pr.md`.
`k8s-rebase-review.sh` exists but is scoped to per-fix-commit review during lint
iteration (takes a specific commit + error context). For the pre-PR gate, a broader
prompt is needed: "review the entire rebase diff — does it look correct?" Either
adapt the script with a whole-diff mode or add an inline `claude -p` call with a
new prompt. The APPROVE:/REJECT: output parsing logic can be reused.

**Effort**: Small-medium. Core machinery exists; needs a new/adapted prompt template.

---

## 2. Phase 5 gate consolidation — MEDIUM

**What**: Fold two redundant gates to reduce API calls and cognitive load.

- `step3-autofix/logical-completeness.md` → fold into `step4-verification/logical-consistency.md`
  (step4 is strictly more comprehensive: covers the same checks plus tier-based depth
  and full-module grep; no coverage loss)

After: gate count drops from 33 to 32. `EXPECTED_GATES` auto-adjusts (dynamic).
`INFO_GATES` at `test-skill.sh:21` and the hardcoded gate list in step3-autofix.md
need manual update in the same commit.

**Do NOT fold:**
- `ci-readiness` into `ci-prediction` — genuinely different. ci-readiness checks
  version strings in CI config files (KIND image tags, KUBERNETES_VERSION refs);
  ci-prediction checks whether code changes will cause CI test failures. Distinct.
- `commit-messages` into `maintainer-review` — format vs scope/suppression. Distinct.

**Effort**: Medium. Each fold is one commit: read both gates, merge content,
delete the redundant one, grep for all references, update counts.

---

## What was explicitly deferred (not TODO)

- **Phase 4 fixture harness / build-vet → finish_filter**: evidence gate works
  reliably. Efficiency gain (one saved API call) doesn't justify fixture complexity.
- **fix_feature_gates Layer 3b (SetFromMap autofix)**: too broad — would inject into
  43 files when only 4 need it. Surfaced as INFO via `SUITE_NO_SETFROMMAP` gate
  check instead; subagent uses known-good to identify the right files.
- **type-conversions.sh companion**: gate has no wrong verdicts in matrix runs.
  Add only if it starts producing false results.

---

## What is done (not reopening)

All gate-architecture-v4 Phases 0, 2, 3 are complete. 289 simplification commits
across 23 waves. All next-work.md items verified fixed. The plan docs in plans/
that cover historical audit rounds (gate-architecture-v3-audit-round*.md) and
superseded designs (v2, v3) are historical reference only — do not act on them.
