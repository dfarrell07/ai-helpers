# Remaining Work — k8s-rebase Skill

**All TODO items are done.** Nothing genuine remains. See Deferred and Done sections below.

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
- **ci-readiness → ci-prediction fold**: Different concerns. ci-readiness checks
  version strings in CI config files; ci-prediction checks whether code changes
  cause CI test failures.

---

## Done (major milestones, for reference)

- **Gate architecture v4 Phases 0, 2, 3** — all companion scripts, evidence transport,
  step1-4 orchestrator wiring, assert-evidence-paths.sh baseline at 8
- **Phase 3 additions** — `feature-gates.sh`, `rebase-completeness.sh`,
  `SUITE_NO_SETFROMMAP` INFO check
- **Phase 5 (partial)** — logical-completeness folded into logical-consistency (33→32
  gates); adversarial pre-PR juror added to step5-pr.md section 5b
- **289 code simplifications** across 23 improvement waves (bash idioms, dead code,
  dynamic watch columns, evidence format fixes, BRE→ERE, echo|pipe→herestring)
- **Bug fixes this session**: `fix_klog_v2` vendor sync, ovn-kubernetes court
  INCONCLUSIVE (packages/ and mocks/ excluded from court diff), make watch gate count
  for no-worktree sessions, auto_record stale hunk count (prel sentinel), court model
  → claude-sonnet-4-6, _do_record_one using wrong config for known_good
