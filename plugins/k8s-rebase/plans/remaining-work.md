# Remaining Work — k8s-rebase Skill

Two genuine improvements remain. Everything else is done, deferred, or confirmed
not worth doing.

---

## 1. Production adversarial juror (step 5) — HIGH

**Gap**: Zero adversarial review of a production rebase before `gh pr create`.
The court only runs in test mode against a known-good branch.

**What to build**: A `claude -p` call in `skills/k8s-rebase/steps/step5-pr.md`
that reviews the full rebase diff before the PR is created. The prompt should ask:

- Are all `k8s.io/*` dependencies at consistent versions (no alpha/pre-release mix)?
- Does the commit history look complete (rebase + codegen + version refs + lint)?
- Are there any obvious regressions — API removals, dropped test cases, missing
  error handling that the gate passes missed?
- Does the diff match the claimed k8s target version?

Output: `APPROVE: <reason>` or `REJECT: <reason>`. The agent reads the verdict and
gates `gh pr create` on APPROVE.

**Implementation notes**: `scripts/k8s-rebase-review.sh` exists but is scoped to
per-fix-commit review during lint (takes `<commit> <error>`). The pre-PR juror needs
a whole-diff prompt instead. Options:
1. Add a `--final-review` mode to `k8s-rebase-review.sh` that takes no commit arg
   and diffs `HEAD..BASE` against `known_good`
2. Inline a `claude -p` call directly in step5-pr.md with the prompt above

The APPROVE:/REJECT: parsing pattern and the `claude -p --output-format text` invocation
already in `k8s-rebase-review.sh` (grep for `VERDICT=`) can be copied directly.

**Effort**: ~30 lines. Core machinery exists; only the prompt template is new.

---

## 2. Gate consolidation: fold logical-completeness — MEDIUM

**Gap**: `step3-autofix/logical-completeness.md` checks for set-but-not-read,
missing error paths, and incomplete field mappings within fix commits. Step 4's
`logical-consistency.md` is a strict superset: same checks plus tier-based depth
analysis and full-module grep across all touched files. Running step3's gate is
redundant.

**What to do**: Delete `gates/step3-autofix/logical-completeness.md`. No content
needs to migrate — step4 already covers everything.

Cleanup required in the same commit:
```bash
grep -rn 'logical-completeness' skills/ gates/ test/
```
Files that reference it: `skills/k8s-rebase/steps/step3-autofix.md` (gate list,
line ~79). Remove the entry. `EXPECTED_GATES` in `test-skill.sh` is dynamic
(counts .md files) — auto-updates. `INFO_GATES` at `test-skill.sh:21` does not
include logical-completeness — no change needed there.

Gate count: 33 → 32.

**Do NOT fold**:
- `ci-readiness` into `ci-prediction`: ci-readiness checks version strings in CI
  config files (KIND image tags, KUBERNETES_VERSION). ci-prediction checks whether
  code changes will cause CI test failures. Different concerns.
- `commit-messages` into `maintainer-review`: format vs scope/suppression. Different.

**Effort**: Small. One commit: delete the file, remove the step3 gate list entry,
verify `make test` shows 32 expected gates.

---

## Deferred (confirmed by adversarial review — do not reopen without new evidence)

- **build-vet → finish_filter**: Evidence gate works reliably. Fixture harness
  complexity not justified by one saved API call per run.
- **fix_feature_gates Layer 3b (SetFromMap autofix)**: Would inject SetFromMap
  into 43 suite files; human rebase only added it to 4. `SUITE_NO_SETFROMMAP`
  INFO check in `feature-gates.sh` already surfaces the gap with actionable
  guidance — that's the right layer.
- **type-conversions.sh companion**: No solo FAILs or suspicious PASSes in any
  matrix run. Add only on evidence of wrong verdicts.

---

## Done (major milestones, for reference)

- **Gate architecture v4 Phases 0, 2, 3** — all companion scripts, evidence transport,
  step1-4 orchestrator wiring, assert-evidence-paths.sh baseline at 8
- **Phase 3 additions** — `feature-gates.sh`, `rebase-completeness.sh`,
  `SUITE_NO_SETFROMMAP` INFO check
- **289 code simplifications** across 23 improvement waves (bash idioms, dead code,
  dynamic watch columns, evidence format fixes, BRE→ERE, echo|pipe→herestring)
- **Bug fixes this session**: `fix_klog_v2` vendor sync, ovn-kubernetes court
  INCONCLUSIVE (packages/ diff size), make watch gate count for no-worktree sessions,
  auto_record stale hunk count (prel sentinel), court model → claude-sonnet-4-6
