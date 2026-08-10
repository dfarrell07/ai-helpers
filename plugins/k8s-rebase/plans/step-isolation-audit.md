# Audit: Making k8s-rebase Outstanding

What to build, in what order, and why. Every section drives action.

---

## 1. Ship Companion Scripts Now

The highest-leverage change. Add 4 `.sh` files alongside existing
gate `.md` files. No architecture change. Works today.

**build-vet.sh** (shared by step2 + step4 recheck):
```bash
source "$(dirname "$0")/../../scripts/gate-script-lib.sh"
init_gate "$@"
NEW_ISSUES=0
for mod_dir in $(find "$REPO" -name go.mod -not -path '*/vendor/*' \
    -exec dirname {} \;); do
  [[ -d "$mod_dir/vendor" && ! -e "$mod_dir/vendor/.gitignore" ]] || continue
  cd "$mod_dir"
  go build ./... 2>&1 | while read -r line; do
    base_has "$line" || ((NEW_ISSUES++))
  done
  go vet ./... 2>&1 | while read -r line; do
    base_has "$line" || ((NEW_ISSUES++))
  done
done
finish_gate "$NEW_ISSUES"
```

**version-consistency.sh**:
```bash
source "$(dirname "$0")/../../scripts/gate-script-lib.sh"
init_gate "$@"
TARGET=$(cat "$REPO/.rebase-tmp/target-k8s-api-version.txt" 2>/dev/null)
NEW_ISSUES=0
for gomod in $(find "$REPO" -name go.mod -not -path '*/vendor/*'); do
  grep 'k8s.io/' "$gomod" | grep -v '^//' | while read -r mod ver; do
    [[ "$ver" == *"$TARGET"* ]] || ((NEW_ISSUES++))
  done
done
finish_gate "$NEW_ISSUES"
```

**go-version-check.sh**: Compare `go` directive across go.mod,
Dockerfiles (`FROM golang:`), Makefiles (`GO_VERSION`). Pure grep.

**major-version-imports.sh**: `grep -rn '"k8s.io/klog"' --include='*.go'`
excluding vendor. If bare import found AND go.mod has `klog/v2`,
count as issue.

**gate-script-lib.sh** (~40 lines): `init_gate` parses repo arg,
computes BASE via `git merge-base HEAD main || git merge-base HEAD
master`, sets up NEW_ISSUES counter. `base_has` checks if a finding
exists on the base branch. `finish_gate` calls `write-gate-report.sh`
with PASS (if 0) or outputs findings for the AI gate to evaluate.
Trap handler writes FAIL report on crash (no limbo). `set -euo
pipefail`. Timeout watchdog via `timeout ${GATE_TIMEOUT:-300}`.

**After shipping these 4:** Measure. If gate flakiness drops for
the scripted gates, expand to the evidence tier: `deprecated-calls.sh`
(run staticcheck, filter pre-existing), `deprecated-imports.sh`
(grep for promoted x/ packages), `version-completeness.sh` (grep
for stale version strings in CI files).

---

## 2. Split SKILL.md into Step Files + Boot Loader

The 981-line SKILL.md exceeds the 5,000-word skill limit (it's
6,619 words). The boot loader pattern gives each step fresh context
and eliminates the attentional pull toward Step 5.

**What the boot loader does** (~55 lines):
- Run `orchestrator.sh status` to find current step
- Read the step file into context (enables injecting priors,
  previous step results, orchestrator state into the Agent prompt)
- Launch `Agent()` with step instructions + rules.md + repo context
- Run `orchestrator.sh advance` — proceed or retry
- Repeat until done

**Step file extraction** (line-by-line map verified):
- rules.md: ~108 lines (module safety, commit discipline, scope,
  OCP version mapping hoisted from Step 5)
- step1-rebase.md: ~100 lines
- step2-compilation.md: ~170 lines
- step3-autofix.md: ~110 lines
- step4-verification.md: ~240 lines — extract 4d (--bump-tools)
  to separate file + move test-splitting RAM examples to docs to
  fit under 200 lines
- step5-pr.md: ~110 lines

**Key constraint:** Step files loaded via Read do NOT get
`${CLAUDE_PLUGIN_ROOT}` text-substitution. The boot loader must
pass the resolved path in the Agent prompt. Step files reference
it from the prompt, not with `${CLAUDE_PLUGIN_ROOT}` syntax.

---

## 3. Build the Orchestrator

The state machine that makes step ordering deterministic. ~300 lines
of bash with 4 subcommands.

**init**: Create state.json + `.session-active` sentinel. Auto-detect
resume (valid state.json → resume; absent/corrupt → fresh start with
report clearing).

**gates**: Iterate gate .md files. Run companion `.sh` if it exists
alongside the `.md` (convention: same basename). If `NEW_ISSUES=0`,
call `write-gate-report.sh` directly — no subagent. Output
RESOLVED/PENDING lists.

**advance**: Check all reports exist with PASS/FAIL verdicts.
SHA-based stale detection (add `HEAD: $(git rev-parse HEAD)` to
`write-gate-report.sh` — 1-line change). All fresh + all PASS →
bump step. Otherwise exit 1 with specific missing/failing gate names.
Force-advance after 3 blocks with `force_reason: stale|FAIL` in
INCOMPLETE marker.

**status**: Compact table reconstructable from `.report` files alone
(state.json is a cache, not source of truth).

**block-module-ops.md is safe** — PreToolUse hooks see the Bash
tool's `tool_input` (what the AI typed: `bash /path/to/script.sh`),
not commands nested inside the script (`go mod tidy`). All legitimate
module operations flow through scripts. Add `.session-active` check
so the hook doesn't interfere with non-rebase sessions.

---

## 4. Three-Tier Gate Architecture

Every gate falls into one of three tiers. The tier determines the
engineering approach:

**Tier 1 — Fully deterministic** (~19 gates): Companion script
produces the verdict. Zero flakiness. The 4 priority scripts above
plus the 2 existing ones (crd-validation.sh, patterns-completeness.sh)
cover 6. The remaining ~13 are straightforward to script:

| Gate | What the script does |
|------|---------------------|
| rebase-completeness | File checks, git log, go.mod version grep |
| test-compilation | `go test -run='^$' -count=0 ./...` |
| autofix-result | git log + go build exit code |
| feature-gates | grep KUBE_FEATURE_ vs vendor |
| cleanliness | git status + find + git ls-files |
| deprecated-imports | grep for promoted x/ packages |
| version-completeness | grep for stale version strings |
| commit-messages | Line length, prefix regex |
| dep-cve-check | curl osv.dev API, filter severity |

4 always-PASS informational gates (commit-messages, dep-cve-check,
maintainer-review, skill-improvement) can auto-PASS without even
running a script.

**Tier 2 — Evidence + interpretation** (~8 gates): Script gathers
deterministic evidence, AI judges only flagged items. This is the
highest-value expansion target after the initial 4 scripts:

| Gate | Evidence (script) | Judgment (AI) |
|------|------------------|---------------|
| deprecated-calls | Run staticcheck SA1019 | Interpret edge cases |
| deprecated-api-remnants | grep + go build | Web search for replacements |
| e2e-infra | grep kindest/node, K8S_VERSION | Verify compatibility |
| ci-readiness | grep version strings in CI | Interpret skip conditions |
| correctness | Format string grep, Eventf scan | Classify change necessity |
| gomod-diff-analysis | Parse go.mod diff | Judge pseudo-version pins |
| diff-scope | File extension allowlist | Classify commits |
| logical-completeness | List modified functions from diff | Trace data flow |

**Tier 3 — Fully agentic** (~6 gates): AI reads code, traces data
flow. Always launch subagent. No shortcut possible:

fix-correctness, type-conversions, autofix-diff-review,
dep-release-notes, ci-prediction, logical-consistency, k8s-changelog

---

## 5. Strengthen the Court

Jurors have tool access (git show, Read) but never use it — zero
VERIFIED lines across 15 juror outputs in 5 court sessions. Fix:

Add to the juror prompt in `test-skill.sh` `cmd_court` (~5 lines):
```
REQUIREMENT: Before rendering your verdict, you MUST use at least
one tool (git show, git diff, or Read) to independently verify
one claim from the prosecution or defense. Include a VERIFIED:
line citing the file:line and what you found.
```

The court's value is adversarial structure with independent
verification. Without forced tool use, jurors collapse to a voting
system on pre-digested arguments — the same pattern as a single
reviewer, just with 3 copies.

---

## 6. What the Skill Doesn't Do Yet (and Should)

**Close the CI loop.** The skill ends at "here's a `gh pr create`
command." An outstanding skill would: create a draft PR, monitor CI,
investigate failures, fix them, iterate. The `/loop` command already
exists — Step 5 could suggest `/loop 5m check CI, explore failures`.
But structured CI feedback (parse Prow job output, identify which
test failed, cross-reference with rebase changes) would make the
skill genuinely end-to-end.

**Handle downstream.** openshift/ovn-kubernetes has Dockerfiles
(Dockerfile, Dockerfile.base, Dockerfile.microshift), OTE tests
(openshift/ directory with its own go.mod replacing all k8s.io/*
with openshift/kubernetes forks), and release branches
(release-4.17 through release-5.1). None of the 33 gates check
downstream-specific concerns. The rebase script already handles
some downstream detection (OCP version mapping, CI image refs),
but the gates verify upstream-shaped output.

**Detect blocked dependencies.** Before starting, check if upstream
deps (library-go, openshift/api) have been rebased to the target
k8s version. A simple `go list -m -json github.com/openshift/
library-go@release-5.0 | jq .Version` check would prevent wasting
an entire 45-minute run on unsolvable compilation errors.

**Record decision provenance.** When the agent chooses between two
valid fixes (ptr.To[int32] vs pointer.Int32, both compile), record
WHY in the rebase report. This helps the human reviewer focus on
low-confidence choices and helps the court evaluate contested diffs.

---

## 7. The Principle That Matters Most

**Migrate complexity from probabilistic to deterministic.**

Every component that is currently AI judgment should be examined:
can it be a bash script? If yes, make it one. If partially, split
it into a deterministic evidence phase and an agentic judgment phase.

This is not just a performance optimization. It is a reliability
transformation. A deterministic check is correct every time or
wrong every time — you can test it once and trust it forever. An
AI judgment check is correct 94% of the time on average but wrong
unpredictably — you can never trust any single result.

The companion scripts are the first step. The three-tier gate
architecture is the map. The end state: the AI handles only the
~6 gates that genuinely require reading code and tracing data flow.
Everything else is bash.

---

## Ship Order

| # | What | Why |
|---|------|-----|
| 1 | 4 companion scripts + gate-script-lib.sh | Works now. No architecture change. Measure gate flakiness before and after. |
| 2 | SKILL.md boot loader + 6 step files | Eliminates step-skipping. Each step gets fresh context. |
| 3 | Orchestrator | Deterministic advancement, resume, status. Enables stop hook. |
| 4 | Stop hook + enforcement hooks | Mechanical enforcement. Add `.session-active` sentinel checks. |
| 5 | Court juror fix | ~5 lines of prompt. Independent of everything else. |
| 6 | Evidence-tier companion scripts | Expand from 6 to ~14 scripted gates based on what commit 1 data shows. |
