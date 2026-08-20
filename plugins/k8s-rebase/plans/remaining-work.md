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

**Implementation**: ~10 lines in `skills/k8s-rebase/steps/step5-pr.md`. Use the
same `k8s-rebase-review.sh` script that already exists. The script already builds
the prompt and interprets APPROVE:/REJECT: output.

**Effort**: Small. The review script exists; just call it in step 5.

---

## 2. Phase 5 gate consolidation — MEDIUM

**What**: Fold two redundant gates to reduce API calls and cognitive load.

- `step3-autofix/logical-completeness.md` → fold into `step4-verification/logical-consistency.md`
  (step4 is strictly more comprehensive: covers the same checks plus tier-based depth)
- `step4-verification/ci-readiness.md` → fold into `step4-verification/ci-prediction.md`
  (different names, overlapping concerns; ci-readiness checks version refs/KIND which
  ci-prediction already covers in a broader context)

After: gate count drops from 33 to 31. `EXPECTED_GATES` auto-adjusts (dynamic).
`INFO_GATES` at `test-skill.sh:21` and two hardcoded gate lists in step3/step4 .md
files need manual update in the same commit.

**Do NOT fold**: `commit-messages` into `maintainer-review` — they check genuinely
different things (format vs scope/suppression).

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
