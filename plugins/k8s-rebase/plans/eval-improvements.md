# Eval Improvement Backlog

Coverage gaps found by deep audit (2026-09-14). Each item verified
against the actual eval code, orchestrator mechanics, and harness
conventions before inclusion.

---

## P0 — Silent correctness holes

### 1. Add `go_mod_version_correct` deterministic judge

**Gap:** `go_mod_and_vendor_modified` confirms go.mod changed, but not
*what it changed to*. A skill that bumped to 1.35 when asked for 1.36
passes all current judges.

**Why diff.patch is sufficient:** go.mod is not in `COURT_EXCLUDES`
(only `.rebase-tmp`, `vendor/`, `go.sum`, `packages/`, `mocks/` are
excluded). The go.mod hunk already appears in `diff.patch`:

```diff
-    k8s.io/api v0.35.1
+    k8s.io/api v0.36.2
```

No new output file needed — extract directly from `diff.patch`.

**Judge logic:**

```python
import json, re
all_f = {**outputs.get("files", {}), **outputs.get("modified_files", {})}
# ... standard infra_error exclusion block ...
diff_files = {k: v for k, v in all_f.items() if k.endswith("diff.patch")}
kg_files = {k: v for k, v in all_f.items() if k.endswith("known-good.patch")}
if not diff_files:
    return (False, "No diff.patch found")
diff = list(diff_files.values())[0]
# Extract minor version from known-good.patch — harness check blocks only
# expose `outputs`, not case input fields like `version`. known-good and
# result may differ in patch version (MVS-driven), but minor must match.
# Anchor: k8s.io/api is the canonical marker. k8s.io/client-go is an
# alternative anchor for repos that don't import k8s.io/api directly.
# Flatten extract_minor inline to avoid nested def (unusual in check blocks).
_anchors = ["k8s.io/api ", "k8s.io/client-go "]
diff_minor = None
for _anchor in _anchors:
    _m = re.search(
        r'^\+\s+' + re.escape(_anchor) + r'v0\.(\d+)\.', diff, re.MULTILINE)
    if _m:
        diff_minor = int(_m.group(1))
        break
# If no anchor found, skip rather than fail — repos without these direct
# deps (extremely rare) should not be penalized by a false failure.
if diff_minor is None:
    return (True, "No k8s.io/api or k8s.io/client-go anchor in diff.patch — skip")
kg_minor = None
if kg_files:
    kg_text = list(kg_files.values())[0]
    for _anchor in _anchors:
        _m = re.search(
            r'^\+\s+' + re.escape(_anchor) + r'v0\.(\d+)\.', kg_text, re.MULTILINE)
        if _m:
            kg_minor = int(_m.group(1))
            break
if kg_minor is not None and diff_minor != kg_minor:
    return (False, f"k8s minor mismatch: diff=v0.{diff_minor}.x, known-good=v0.{kg_minor}.x")
if kg_minor is None:
    # No known-good reference — verify a bump occurred (minor increased).
    # If no removal line exists (brand-new dep), skip the direction check.
    _removed = re.search(
        r'^-\s+k8s\.io/(?:api|client-go)\s+v0\.(\d+)\.', diff, re.MULTILINE)
    if _removed and int(_removed.group(1)) >= diff_minor:
        return (False,
                f"k8s minor not increased: was v0.{_removed.group(1)}.x, now v0.{diff_minor}.x")
return (True, f"k8s bumped to v0.{diff_minor}.x")
```

**Design notes:**
- Uses `k8s.io/api` then `k8s.io/client-go` as anchors; returns True (skip)
  rather than False when neither is found — avoids false failures on unusual repos.
- Inner `def` avoided — check blocks run in a restricted exec context; flattened
  imperative style matches existing judges.
- Brand-new dependency (no removal line): fallback check is skipped, judge
  returns True — acceptable since `go_mod_and_vendor_modified` already confirms
  changes occurred.

**Threshold:** `go_mod_version_correct: {min_pass_rate: 1.0}`

---

### 2. Verify step-5 `gh pr create` command was printed

**Gap:** `pr_command_never_attempted_or_blocked` checks the command was
not *executed*. It does not verify it was *presented* to the user.
A skill that skips step5-pr.md entirely and reports DONE still passes.

**Feasibility confirmed:** `session-output.json` is deleted at line 192
of `run-rebase.sh`, after all other extractions. The step-5 `gh pr
create` text appears in assistant message content in the stream-json
transcript — it is present in `session-output.json` and can be
extracted before deletion.

**Implementation:** Add before line 192 in `run-rebase.sh`:

```bash
# step5 outputs "gh pr create" as assistant text (not executed as a tool).
# Join all assistant text then check for required strings — don't try to
# capture the full command with grep -o, since the heredoc body spans many
# lines and patterns like [^)]* stop at the first ')'.
jq -rs '[.[] | select(.type=="assistant")
             | .message.content[]?
             | select(.type=="text")
             | .text] | join("\n")' \
  "$OUTPUT_DIR/session-output.json" \
  > "$OUTPUT_DIR/pr-command.txt" 2>/dev/null || true
```

Add deterministic judge `step5_pr_command_printed`:

```python
pr_files = {k: v for k, v in all_f.items() if k.endswith("pr-command.txt")}
if not pr_files:
    return (False, "No pr-command.txt found (run-rebase.sh update needed)")
content = list(pr_files.values())[0]
lines = content.splitlines()
# Find the "gh pr create" anchor line.
cmd_idx = next((i for i, l in enumerate(lines) if "gh pr create" in l), None)
if cmd_idx is None:
    return (False, "No 'gh pr create' found in assistant text")
# In practice step5 outputs: gh pr create --title "..." --body "$(cat <<'EOF'
# so --title is on the same line as gh pr create. The 4-line window handles
# any variant where flags are split across lines.
title_window = lines[cmd_idx:cmd_idx + 4]
if not any("--title" in l for l in title_window):
    return (False, f"'--title' not found within 4 lines of 'gh pr create'")
body_window = lines[cmd_idx:cmd_idx + 5]
if not any("--body" in l for l in body_window):
    return (False, f"'--body' not found within 5 lines of 'gh pr create'")
return (True, "gh pr create command with --title and --body found")
```

**Threshold:** `step5_pr_command_printed: {min_pass_rate: 1.0}`

---

## P1 — Coverage gaps

### 3. Add a negative test case (verify judges fail on bad input)

**Gap:** All 6 cases are "skill succeeds" cases. The LLM judges have
never been regression-tested against a deliberately bad diff. The
2026-09-13 calibration checked scores once manually — not a standing
check.

**Harness limitation:** The harness only supports `min_mean` and
`min_pass_rate` — there is no `max_mean`. A negative case cannot be
automatically asserted to score *below* a ceiling under the current
harness. This blocks implementation as a fully automated CI gate.
Implement manually at calibration time; automate when `max_mean` is
supported.

**Approach — separate eval YAML (preferred):** Use
`eval-k8s-rebase-negative.yaml` with a `cases/negative/` dataset and
its own runner script. Keeps real and synthetic logic independent. (One
runner per eval YAML; no per-case runner override is possible.)

Runner (`evals/scripts/run-synthetic-bad.sh`):

```bash
# Plants pre-baked bad artifacts; does not invoke the skill.
# $CASE_DIR is NOT provided by the harness — fixtures must be referenced
# via $AI_HELPERS_DIR (declared in the eval YAML env: block) or as an
# explicit runner argument (e.g. pass the case dir path as $1).
FIXTURES_DIR="$AI_HELPERS_DIR/plugins/k8s-rebase/evals/cases/negative/${1}/fixtures"
mkdir -p output
cp "$FIXTURES_DIR/"* output/
echo '{"status":"completed","reason":""}' > output/run-status.json
echo '{"token_usage":{"input":0,"output":0},"cost_usd":0,"num_turns":0,"model":"synthetic"}' \
  > output/metrics.json
```

**Synthetic diff quality:** The diff must be realistic enough for the
LLM judge to engage seriously. A trivially garbled diff scores 1 but
tests nothing. The synthetic diff should look like a plausible but wrong
rebase: correct go.mod version bump, but scope-creep changes (unexplained
refactors, added struct tags) and one silently dropped API fix from
known-good. This tests whether the judge reasons about content, not just
detects nonsense.

**Expected judge scores:** `rebase_correctness` ≤ 2, `no_scope_creep`
≤ 2. Deterministic judges must be seeded with plausible-looking fixtures
(run-status.json says "completed", gate reports say PASS) — they'll
PASS intentionally. The negative case tests LLM judges only.

Document in `agent-eval-harness.md` to re-run manual calibration
whenever judge prompts change.

---

### 4. Add gap-analysis judge for `rebase_correctness`

**Gap:** `rebase_correctness` does holistic comparison — "are there
regressions overall?" A judge that hallucinates "looks fine" passes
with no adversarial check. `make court` catches this (3-juror panel
with prosecution/defense/judge) but isn't in the automated eval.

**Why a second judge adds signal (if designed correctly):** The two
ways a rebase can be wrong are asymmetric:

- Things in `known-good.patch` but **absent** from `diff.patch` —
  fixes the result is missing.
- Things in `diff.patch` but **absent** from `known-good.patch` —
  changes the result added that it shouldn't have.

`rebase_correctness` checks both implicitly and holistically. A
**gap-analysis judge** checks them explicitly and in sequence, which
changes what the model attends to first and reduces the tendency to
give a high score without scrutiny. This is a structural difference,
not just a persona label.

**Important constraint:** Eval LLM judges have no tool access (unlike
`make court` jurors, which can run `git show BASE_REF:<file>`). The
gap-analysis judge must work from diff-only evidence. No
"verify at base branch" instructions — omit them or they mislead.

**Proposed judge name:** `rebase_gap_analysis`

**Prompt structure (draft):**

```text
You are reviewing a Kubernetes dependency rebase for correctness gaps.
Work in two phases before scoring:

If known-good.patch is empty, skip Phase 1 and score on Phase 2 only.
For large diffs, enumerate at most 20 files in Phase 1 — note if you
reached the cap, then sample representative hunks from each.

PHASE 1 — MISSING: List files changed in known-good.patch that have no
counterpart change in diff.patch (stop at 20 files). For each, state whether
its absence is acceptable (style difference, scope choice, equivalent
path) or suspicious (missing fix, dropped behavior, absent error
handling).

PHASE 2 — EXTRA: List every file changed in diff.patch that has no
counterpart change in known-good.patch. For each, state whether it is
justified (required by a build error, MVS version resolution, equivalent
API path) or suspicious (unexplained change, possible scope creep).

[same diff sections as rebase_correctness]

Score 1: Unexplained MISSING items LIKELY to break compilation or
         runtime based on diff evidence, or EXTRA items that introduce
         regressions. (Note: compilation cannot be verified without
         tooling — score 1 only when diff evidence is strongly
         indicative, e.g., removed interface implementations.)
Score 2: Suspicious gaps with weak justification.
Score 3: All gaps explained, but explanations are vague or unverifiable.
Score 4: All gaps explained with specific, plausible justification.
Score 5: No unexplained gaps; differences are all acceptable variance.
```

**Note on the 20-file cap:** This is a best-effort instruction — the
LLM has no tool access and cannot mechanically enforce it. For very
large diffs (e.g., case-001's ovn-kubernetes vendor tree) the model may
enumerate more than 20 or stop arbitrarily. If context explosion becomes
a real problem, the fix is runner-side truncation: pass only the first N
file hunks of known-good.patch to the judge rather than the full text.
For the current 6 cases this is not expected to be an issue.

**Threshold:** `rebase_gap_analysis: {min_mean: 2.5}`

**WARNING — calibrate before merging threshold.** Current calibration
(2026-09-13) used only the holistic judge. After implementing, run on
the case-002 good diff to establish expected score range. Adjust
threshold if the gap-analysis judge scores the good diff below 2.5 (it
may be stricter — raise threshold or lower to 2.0). Do not merge the
`{min_mean: 2.5}` threshold before this calibration run.

**Divergence signal:** If `rebase_correctness` and `rebase_gap_analysis`
differ by > 2 on the same case, flag for human review. Can't be encoded
as a harness threshold today — document as manual review trigger.

**Scope:** `rebase_correctness` only. `no_scope_creep` is mechanical
(per-hunk citation required) and not prone to the holistic-assessment
failure mode this addresses.

---

## P2 — Eval suite operational improvements

### 5. Document case weight order and full-suite runtime expectations ✓ DONE

**Context:** The harness defaults to `-j 1` (sequential, never
parallel) — running `claude plugin eval plugins/k8s-rebase` is safe;
all 6 cases run one after another, not simultaneously. No structural
change needed to prevent parallel execution.

**Remaining gap:** Developers don't know which cases are heavy vs.
light, or that the full suite can take 12+ hours. Case-001
(ovn-org/ovn-kubernetes) has a ~350MB vendor tree and sub-module layout
and is the most expensive by far.

**Done (f744c0c6):** `evals/README.md` now documents:
- Case weight order (002/003/004 fast, 005/006 medium, 001 heaviest)
- `--case` flag for running a single case during development
- Full-suite runtime expectation and RAM guidance

---

### 6. Add older-version cases (1.34.x and 1.35.x)

**Problem:** All 6 current cases test a rebase to 1.36.2. The skill
has no automated coverage for:
- Different minor version paths (API changes differ 1.34→1.35 vs
  1.35→1.36 — e.g., different deprecated APIs, different MVS resolution
  patterns)
- The `go_mod_version_correct` judge (Item 1) with a different target
  minor (it currently would always check for v0.36.x)
- Regressions in version-detection logic if the skill pattern-matches
  on "36" rather than parsing the version argument

**Target versions:** k8s 1.34.x (`v0.34.*`) and 1.35.x (`v0.35.*`).
These are the two immediately prior minor versions.

**Repo selection:** Use the smallest, cleanest repos — less variance,
faster run, same skill code path. `openshift/multus-cni` is the primary
candidate for both 1.34.x and 1.35.x; narrow k8s API surface means a
wrong version bump shows up clearly in go.mod.

**Constraint on ovn-kubernetes-mcp:** The oldest commit in that repo's
`go.mod` history already has `k8s.io/api v0.34.1` — the repo was
created at k8s 1.34. There is no v0.33.x state to use as `from_commit`
for a 1.34 target. `ovn-kubernetes-mcp` can only be used for 1.35.x
cases (v0.34.x → v0.35.x); for 1.34.x use a different repo.

**Finding `from_commit` and `known_good_ref`:**

For each case:
1. `from_commit` — a SHA where `k8s.io/api` is at `v0.N-1.*`
   (e.g., `v0.33.*` for a 1.34 target, `v0.34.*` for a 1.35 target)
2. `known_good_ref` — a SHA where `k8s.io/api` was bumped to `v0.N.*`
   and the rebase was clean

```bash
# Find the 1.35 boundary in ovn-kubernetes-mcp:
git -C ~/ovnk/ovn-kubernetes/ovn-kubernetes-mcp log --oneline \
  --all -- go.mod | head -20
# Look for commit bumping k8s.io/api from v0.34.* to v0.35.*
# That commit = known_good_ref; immediately prior commit = from_commit.

# Find the 1.34 boundary in multus-cni (or another older repo):
git -C ~/ovnk/openshift/multus-cni log --oneline --all -- go.mod | head -20
# Look for commit bumping k8s.io/api from v0.33.* to v0.34.*
```

**Case structure:** Extend `cases/pattern-retention` with new numbers:

| Case | Repo | Version | Notes |
|------|------|---------|-------|
| case-007 | openshift/multus-cni | 1.34.x | Needs v0.33.x from_commit |
| case-008 | openshift/ingress-node-firewall | 1.34.x | Backup if multus lacks history |
| case-009 | ovn-kubernetes/ovn-kubernetes-mcp | 1.35.x | v0.34.x → v0.35.x |
| case-010 | openshift/multus-cni | 1.35.x | Backup / second 1.35 case |

**Prerequisite:** Known-good rebases must be pinned to immutable SHAs
(not mutable branch heads). Fork repos if needed (as done for case-002,
case-003, case-005). Verify the known-good actually compiles at the
target version before adding the case.

**Not yet actionable:** Requires manual git archaeology per repo.
Track as backlog; do not block the current PR on it.

---

## Latent risks (not blocking, monitor)

**LLM judge `outputs.files` vs `outputs.modified_files`:** The two
`prompt:` judges (`rebase_correctness`, `no_scope_creep`) iterate only
`outputs.files.items()` in their Jinja2 templates. The five `check:`
judges defensively merge both with `{**outputs.get("files", {}),
**outputs.get("modified_files", {})}`. If the harness places output
files in `modified_files` (instead of or in addition to `files`), the
LLM judges would receive empty diffs and score silently on nothing.
Low-probability under the current harness but a silent failure mode.
Fix when/if a case produces unexpected empty diffs: change `prompt:`
templates to `{% for path, content in (outputs.files | combine(outputs.modified_files | default({}))).items() %}`.

---

## Items considered and rejected

**Gate count check** — redundant. If a gate report is missing,
`advance` returns exit 1 (BLOCKED), not DONE. `orchestrator_reports_done`
catches it because DONE is never written. `all_gates_resolved` also
catches a report with no VERDICT line. No gap exists.

**go.mod snapshot output file** — not needed for item 1 (diff.patch
already contains the go.mod hunk). Adds output file complexity for
speculative future judges. Add only when a concrete judge requires it.

**Sub-module build error capture** — not a gap. The regex
`^.+\.go:[0-9]+:` matches `go-controller/pkg/foo.go:42:` correctly.
Verified by inspection.

**Sub-module `go_mod_and_vendor_modified` paths** — not a gap.
`"go-controller/go.mod".endswith("go.mod")` returns `True`.
The check handles sub-module paths correctly as written.

**Independent `go build` in eval runner** — expensive, environment-
dependent (requires matching Go toolchain), and gate reports already
capture whether the skill's own build passed. Not justified.

**`make court` in eval loop** — that's what `make court` is for.
Running it in the eval loop duplicates existing infrastructure.
