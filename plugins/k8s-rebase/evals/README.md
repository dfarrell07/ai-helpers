# Testing and evals

The workflow harness and pattern-retention evals exercise real rebases via
Claude. Offline checks cover shared interfaces. These are separate from
[Codex compatibility qualification](../plans/claude-codex-compatibility.md).

## Choose the check

Run these commands from `plugins/k8s-rebase/`:

| Check | Command | What it establishes |
| --- | --- | --- |
| Offline contracts | `make test-compatibility test-version-selection assert-evidence-paths` | Hook/review/gate interfaces, version selection, companion paths; no model calls or rebases |
| One full-skill run | `make test repo=ovn-kubernetes/ovn-kubernetes-mcp version=1.35 spec=none` | Launches a background rebase; inspect with `make watch`, then `make results` |
| Known-good comparison | `make court repo=ovn-kubernetes/ovn-kubernetes-mcp version=1.35` | Adversarial review of the result against its configured reference |
| Configured matrix | `make matrix spec=none` | Runs all configured repo/version cases, court, and bounded retries |
| Eval artifacts | `make eval case=012` | Synchronous run capturing metrics and evidence for the eval judges |

`version=1.35` selects `test/config-1.35.yaml`, whose target is 1.35.3.
Configs pair a pre-rebase `from_commit` with a `known_good` reference; compare
from the rebase's original baseline, not an unrelated later main-branch tip.
Harness state and court transcripts live under `test/.matrix-state/`.

### Withhold learned fixes

`make test` defaults to `spec=none`; **`make matrix` defaults to `spec=all`**.
Mutations affect a copied plugin, leaving the source intact:

| Spec | What is withheld |
| --- | --- |
| `none` | Nothing: pattern guidance and autofix remain enabled |
| `all-patterns` | Pattern table and detailed sections |
| `all-fns` | Autofix functions except the uncommitted-change cleanup helper |
| `all` | Both pattern content and autofix functions |
| `pattern:<key>` | The section mapped by `TAG_TO_PATTERN` in `test/test-skill.sh` |
| `fn:<tag>` | One `fix_<tag>` function |

Targeted pattern removal can remove a shared section; other prompts may
retain related guidance. These runs test recovery with less help on known
cases, not generalization to unseen breakage. See the [design guide](../docs/design.md).

## Running pattern-retention evals

**On a laptop: run one case at a time.** Each case spawns a full Claude
session (up to 200 turns) plus `go mod vendor`. All 16 cases
sequentially can take 24h+ and exhaust RAM on heavy cases.

### Single-case runs

> **Note:** `claude plugin eval --case <name>` does **not** work with
> this eval — the `--case` filter is only supported for prompt-file
> dataset mode, not the cli runner dataset mode used here. Use the
> runner script directly instead.

`make eval case=012` reads the case's `input.yaml` and writes to
`/tmp/k8s-rebase-eval-case-012/output/`. For custom runs,
[run-rebase.sh](scripts/run-rebase.sh) accepts the repo URL, baseline SHA,
target version, model, known-good URL, and known-good ref; output goes under
the caller's `output/` directory. Use a dedicated directory under `.work/`.

The runner caches clones under `evals/.repos/`, or `EVAL_REPO_DIR` when set.
It resets that checkout and deletes prior run changes and rebase branches;
use only disposable eval clones. Run cases sharing a clone sequentially.

`make eval` and the direct runner collect artifacts; they do **not** execute
the YAML judges. Scoring runs through the eval harness below.

### Full-suite runs

From the ai-helpers root, `claude plugin eval plugins/k8s-rebase`
runs and scores all 16 cases sequentially.
Intended for CI or a dedicated workstation with ≥ 32GB RAM (24h timeout).

**Case weight order** (lightest → heaviest, by vendor tree size and API
surface):

- **Fastest:** cases with ovn-kubernetes-mcp, multus-cni, ingress-node-firewall
  (002, 003, 004, 008, 012, 013, 014) — small repos, narrow API surface
- **Medium:** cloud-network-config-controller (005, 009, 015)
- **Medium-heavy:** cluster-network-operator (006, 010, 016)
- **Slowest:** ovn-org/ovn-kubernetes (001, 007, 011) — sub-module layout,
  ~350MB vendor tree, expect 1–3h per run

## pattern-retention (`cases/pattern-retention`)

Smoke check only — not a substitute for `make court`, and does not test
generalization to novel breakage. All 16 cases reuse repos the skill's
autofix patterns were tuned against.

16 cases across six repos and three releases: 4 at 1.34.1, 6 at 1.35.3,
and 6 at 1.36.2. Source data in `test/config-1.3{4,5,6}.yaml`.

| Case | Repo | Version | Weight |
|------|------|---------|--------|
| case-001 | ovn-org/ovn-kubernetes | 1.36.2 | Heavy — sub-module layout |
| case-002 | ovn-kubernetes/ovn-kubernetes-mcp | 1.36.2 | Light — minimal API surface |
| case-003 | openshift/multus-cni | 1.36.2 | Light — narrow API surface |
| case-004 | openshift/ingress-node-firewall | 1.36.2 | Light — narrow API surface |
| case-005 | openshift/cloud-network-config-controller | 1.36.2 | Medium |
| case-006 | openshift/cluster-network-operator | 1.36.2 | Medium-heavy — heavy openshift/api usage |
| case-007 | ovn-org/ovn-kubernetes | 1.34.1 | Heavy — sub-module layout |
| case-008 | openshift/multus-cni | 1.34.1 | Light — narrow API surface |
| case-009 | openshift/cloud-network-config-controller | 1.34.1 | Medium |
| case-010 | openshift/cluster-network-operator | 1.34.1 | Medium-heavy |
| case-011 | ovn-org/ovn-kubernetes | 1.35.3 | Heavy — sub-module layout |
| case-012 | ovn-kubernetes/ovn-kubernetes-mcp | 1.35.3 | Light — minimal API surface |
| case-013 | openshift/multus-cni | 1.35.3 | Light — narrow API surface |
| case-014 | openshift/ingress-node-firewall | 1.35.3 | Light — AI-produced known-good |
| case-015 | openshift/cloud-network-config-controller | 1.35.3 | Medium |
| case-016 | openshift/cluster-network-operator | 1.35.3 | Medium-heavy |

Note: 1.34 has no ovn-kubernetes-mcp or ingress-node-firewall cases —
those repos were not rebased to 1.34 (mcp didn't exist, infw had no
complete rebase).

## Interpreting scores

The [eval definition](eval-k8s-rebase-pattern-retention.yaml) has seven
deterministic checks (DONE, report verdicts, no forced advancement, publishing
guard, changed module/vendor files, target minor, printed PR command) and
three LLM judges (correctness, scope, missing/extra changes). The runner also
captures cost, tokens, turns, and model in `metrics.json`.

Read the artifacts behind a score:

- Deterministic checks return an excluded pass for `infra_error` runs,
  including missing/malformed run status. Check `run-status.json` before
  treating a passing score as evidence of a completed run.
- `all_gates_resolved` checks reports that exist; it does not inventory
  all expected gates or verify their HEAD stamps. Use the orchestrator's
  `reports` inventory for completeness and freshness.
- The version judge checks a minor-version anchor in the diff, not exact
  pins in every module. The PR-command judge checks text presence, not the
  accuracy of its verification claims.
- LLM scores are a smoke check, not the adversarial court. The gap-analysis
  threshold remains provisional. Known-good references are comparison
  evidence, not the only valid implementation; case-014 is AI-produced.

Harness summary policies also differ from in-run gate verdicts. Preserve
raw reports and findings when comparing results; a passing court or eval
score does not turn an unresolved gate into PASS.
