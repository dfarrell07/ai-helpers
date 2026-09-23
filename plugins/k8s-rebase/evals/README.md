# Testing and evals

The workflow harness and pattern-retention evals exercise real rebases via
Claude. Offline checks cover shared interfaces. These are separate from
[runtime compatibility qualification](../docs/compatibility.md).

## Choose the check

Run these commands from `plugins/k8s-rebase/`. The workflow harness needs
`claude`, Go-based `yq` v4, `jq`, Git, and `rsync` in addition to the
rebase prerequisites.

| Check | Command | What it establishes |
| --- | --- | --- |
| Offline contracts | `make test-compatibility test-version-selection assert-evidence-paths` | Hook/review/gate interfaces, version selection, companion paths; no model calls or rebases |
| One full-skill run | `make test repo=ovn-kubernetes/ovn-kubernetes-mcp version=1.35 spec=none` | Launches a background rebase; inspect with `make watch version=1.35`, then `make results version=1.35` |
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

Full runs call models and build real projects; start with one case at a time.
The eval runner defaults to 200 turns per case. Time and cost vary by repo.

### Single-case runs

`make eval case=012` reads the case's `input.yaml` and writes to
`/tmp/k8s-rebase-eval-case-012/output/`. For custom runs,
[run-rebase.sh](scripts/run-rebase.sh) accepts the repo URL, baseline SHA,
target version, model, known-good URL, and known-good ref; output goes under
the caller's `output/` directory. Use a dedicated directory under `.work/`.

The runner caches clones under `evals/.repos/`, or `EVAL_REPO_DIR` when set.
It resets that checkout and deletes prior run changes and rebase branches;
use only disposable eval clones. Run cases sharing a clone sequentially.

`make eval` and the direct runner collect artifacts; they do **not** execute
the YAML judges.

### Scoring compatibility

The YAML definition uses the
[agent-eval-harness](https://github.com/opendatahub-io/agent-eval-harness#evalyaml)
CLI-runner schema with `input.yaml` datasets and inline judges.
Its timeout and budget settings apply per invocation, not across the suite.

This repository does not install or pin a scoring harness, and the built-in
`claude plugin eval` expects a different case layout (`case.yaml` or
`prompt.md`), so it discovers no cases here. Use `make matrix spec=none` and
`make court` to evaluate the workflow and `make eval case=NNN` to collect
artifacts; verify harness and schema compatibility before YAML scoring.

## Coverage

Pattern retention covers the repos used to develop the autofix patterns;
it does not test unseen breakage. The 16 cases cover the same repo/version
combinations as `test/config-1.3{4,5,6}.yaml`. Each link opens the case's
pinned baseline and known-good commits.

| Case | Repository | Version |
| --- | --- | --- |
| case-001 | ovn-org/ovn-kubernetes | [1.36.2](cases/pattern-retention/case-001/input.yaml) |
| case-002 | ovn-kubernetes/ovn-kubernetes-mcp | [1.36.2](cases/pattern-retention/case-002/input.yaml) |
| case-003 | openshift/multus-cni | [1.36.2](cases/pattern-retention/case-003/input.yaml) |
| case-004 | openshift/ingress-node-firewall | [1.36.2](cases/pattern-retention/case-004/input.yaml) |
| case-005 | openshift/cloud-network-config-controller | [1.36.2](cases/pattern-retention/case-005/input.yaml) |
| case-006 | openshift/cluster-network-operator | [1.36.2](cases/pattern-retention/case-006/input.yaml) |
| case-007 | ovn-org/ovn-kubernetes | [1.34.1](cases/pattern-retention/case-007/input.yaml) |
| case-008 | openshift/multus-cni | [1.34.1](cases/pattern-retention/case-008/input.yaml) |
| case-009 | openshift/cloud-network-config-controller | [1.34.1](cases/pattern-retention/case-009/input.yaml) |
| case-010 | openshift/cluster-network-operator | [1.34.1](cases/pattern-retention/case-010/input.yaml) |
| case-011 | ovn-org/ovn-kubernetes | [1.35.3](cases/pattern-retention/case-011/input.yaml) |
| case-012 | ovn-kubernetes/ovn-kubernetes-mcp | [1.35.3](cases/pattern-retention/case-012/input.yaml) |
| case-013 | openshift/multus-cni | [1.35.3](cases/pattern-retention/case-013/input.yaml) |
| case-014 | openshift/ingress-node-firewall | [1.35.3](cases/pattern-retention/case-014/input.yaml) |
| case-015 | openshift/cloud-network-config-controller | [1.35.3](cases/pattern-retention/case-015/input.yaml) |
| case-016 | openshift/cluster-network-operator | [1.35.3](cases/pattern-retention/case-016/input.yaml) |

The 1.34 config omits ovn-kubernetes-mcp and ingress-node-firewall.
Case-014 uses an AI-produced known-good reference; the others use the
existing rebase references.

Configuration records the cases to run, not their results for a new revision.
For review, retain the plugin commit, runtime/model, mutation spec, baseline
and resolved reference SHAs, raw gate reports, and court result. Some workflow
configs use moving reference branches; resolve them before comparing runs.

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
- LLM scores are a smoke check, not the adversarial court. Scope and gap-analysis
  thresholds remain provisional. Known-good references are comparison
  evidence, not the only valid implementation.

The workflow harness can count advisory verdicts and older failures as SKIP.
Court excludes vendor, go.sum, package metadata, and mocks from its diff;
an identical filtered diff returns PASS without a jury. Preserve raw reports
and findings: these summaries do not turn an unresolved gate into PASS.

### Remaining eval work

- Pin and validate a compatible scoring harness, or port the cases and judges
  to the built-in CLI format before documenting a full-suite scoring command.
- Calibrate the scope and gap-analysis thresholds across cases and add deliberately
  bad diffs to check that judges reject plausible regressions.
- Check expected report completeness/freshness and final PR claims directly;
  existing verdict/text checks do not establish those properties.
- LLM prompt templates currently read only `outputs.files`, while deterministic
  checks also read `modified_files`. Verify artifact delivery when changing
  the harness; empty judge inputs must not look like clean diffs.
