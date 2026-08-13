# Gate Architecture v2: Pre/Post Verification

**STATUS: PLANNED.** Extends the three-tier gate architecture
(step-isolation-and-generality.md §4.4) with post-verification
scripts and reclassifies all 33 gates based on 7-agent evaluation.

## Problem

6 of 33 gates have companion .sh scripts. The remaining 27 rely
entirely on AI judgment — the orchestrator runs the .md prompt,
an AI subagent writes a verdict, and nothing verifies it. This
creates two failure modes:

1. **Satisficing.** The AI writes "PASS, no issues found" without
   actually running the checks. No script catches this.
2. **Hallucination.** The AI claims "all 5 struct fields mapped"
   but the struct has 7 fields. No script cross-checks.

The current companion script pattern (run .sh BEFORE AI) only
addresses one direction: gathering evidence and fast-pathing PASS
when clean. It doesn't verify what the AI claims afterward.

## Design: Four Gate Types

### Type 1: full-sh (12 gates)

Script produces the final verdict. No AI subagent launched.

The orchestrator already supports this: companion .sh runs, if
`NEW_ISSUES=0` the gate resolves as PASS. But today the script
outputs PENDING when issues are found, deferring to AI. For
full-sh gates, the script should write PASS or FAIL directly.

**New library function: `finish_gate_final`** — like `finish_gate`
but writes verdicts for both PASS and FAIL (current `finish_gate`
only writes PASS, defers FAIL to AI).

```bash
finish_gate_final() {
  local issues="${1:?}" summary="${2:-}"
  shift 2 2>/dev/null || true
  local verdict="PASS"
  [[ "$issues" -gt 0 ]] && verdict="FAIL"
  bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" "$verdict" "$issues" "$summary" "$@"
  echo "RESOLVED: $GATE_NAME $verdict (companion script)"
  trap - EXIT; exit 0
}
```

**Orchestrator change:** None needed — `cmd_gates` already checks
for `NEW_ISSUES=0` and resolves. For `finish_gate_final`, the
script calls `write-gate-report.sh` directly, so the report exists
when the orchestrator re-checks. The script outputs `RESOLVED:`
which the orchestrator parses.

### Type 2: mix-pre-sh (7 gates)

Script gathers evidence BEFORE AI. Fast-paths PASS when clean.
AI only judges items the script flagged. This is the current
companion script pattern — no changes needed.

### Type 3: mix-both-sh (13 gates)

Script gathers evidence BEFORE AI, then a second script VERIFIES
AI claims AFTER. The post-script catches satisficing and
hallucination by re-running deterministic checks against the
AI's report.

**New file convention:** `gate-name.post.sh` alongside
`gate-name.sh` and `gate-name.md`. Discovered by the orchestrator
via `${gate_md%.md}.post.sh`.

**New library functions:**

```bash
init_post_gate() {
  REPO="${1:?Usage: $0 <repo-path> <report-path>}"
  REPORT_PATH="${2:?Usage: $0 <repo-path> <report-path>}"
  cd "$REPO" || exit 1
  GATE_NAME=$(basename "${BASH_SOURCE[1]}" .post.sh)
  local step_dir step_prefix
  step_dir=$(basename "$(dirname "${BASH_SOURCE[1]}")")
  step_prefix=$(echo "$step_dir" | grep -oE '^step[0-9]+')
  GATE_NAME="${step_prefix}-${GATE_NAME}"
  AI_VERDICT=$(grep '^VERDICT:' "$REPORT_PATH" | awk '{print $2}')
  POST_TOTAL=0
  POST_PASSED=0
  POST_DETAILS=()
}

post_check() {
  local name="$1" passed="$2" detail="${3:-}"
  ((POST_TOTAL++)) || true
  [[ "$passed" == "true" ]] && { ((POST_PASSED++)) || true; }
  [[ -n "$detail" ]] && POST_DETAILS+=("$detail")
}

finish_post_gate() {
  local status="CONFIRMED"
  [[ "$POST_PASSED" -lt "$POST_TOTAL" ]] && status="INCONSISTENCY"
  {
    echo "POST_VERIFIED: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "POST_CHECKS: ${POST_PASSED}/${POST_TOTAL} passed"
    echo "POST_STATUS: $status"
    for d in "${POST_DETAILS[@]}"; do
      echo "POST_DETAIL: $d"
    done
  } >> "$REPORT_PATH"
  if [[ "$status" == "INCONSISTENCY" && "$AI_VERDICT" == "PASS" ]]; then
    bash "$WRITE_REPORT" "$REPO" "$GATE_NAME" FAIL 1 \
      "Post-verification override: ${POST_DETAILS[*]}" "${POST_DETAILS[@]}"
    echo "POST_OVERRIDE: $GATE_NAME FAIL (was PASS)"
  else
    echo "POST_CONFIRMED: $GATE_NAME $AI_VERDICT"
  fi
  trap - EXIT; exit 0
}
```

**Orchestrator change (~8 lines in `cmd_gates`):**

When a fresh report with a verdict exists, check for a `.post.sh`.
If it exists and the report lacks `POST_VERIFIED:`, run it. The
post-script appends to the report and may override the verdict.

```bash
# In cmd_gates, after finding a fresh report with verdict:
if [[ -f "$rpt" ]] && report_has_verdict "$rpt" && report_is_fresh "$rpt" "$repo"; then
  local post="${gate_md%.md}.post.sh"
  if [[ -x "$post" ]] && ! grep -q '^POST_VERIFIED:' "$rpt"; then
    info "Post-verifying: $(basename "$post")"
    timeout "${GATE_TIMEOUT:-300}" bash "$post" "$repo" "$rpt" 2>&1 || true
  fi
  # re-read verdict (may have been overridden by post-script)
  local verdict
  verdict=$(grep '^VERDICT:' "$rpt" | tail -1 | awk '{print $2}')
  echo "EXISTING: $gate_name $verdict"
  ...
fi
```

### Type 4: full-md (1 gate)

AI reads code, makes judgment. No useful script possible.
Only `maintainer-review` falls here — and it's informational
(always PASS), so the lack of scripting is harmless.

## Gate Classification Table

All 33 gates classified by the 7-agent evaluation workflow.
12 challenges raised by adversarial review, 6 accepted.

### Step 1 — Rebase (1 gate)

| Gate | Type | Has .sh | Priority | Change |
|------|------|---------|----------|--------|
| rebase-completeness | mix-both-sh | no | next | new pre + post |

Pre: result file, git status, conflict markers, codegen targets,
k8s.io version extraction. Post: re-run counts, cross-check
version claims against go.mod.

### Step 2 — Compilation (6 gates)

| Gate | Type | Has .sh | Priority | Change |
|------|------|---------|----------|--------|
| build-vet | full-sh | yes | next | upgrade to write FAIL directly |
| version-consistency | full-sh | yes | now | upgrade to write FAIL directly |
| diff-scope | full-sh | no | **now** | new script |
| test-compilation | mix-pre-sh | no | **now** | new pre script |
| type-conversions | mix-both-sh | no | next | new pre + post |
| fix-correctness | mix-both-sh | no | next | new pre + post |

### Step 3 — Autofix (11 gates)

| Gate | Type | Has .sh | Priority | Change |
|------|------|---------|----------|--------|
| autofix-result | full-sh | no | **now** | new script |
| deprecated-calls | full-sh | no | next | new script |
| feature-gates | full-sh | no | **now** | new script |
| major-version-imports | full-sh | yes | now | upgrade to write FAIL |
| crd-validation | mix-both-sh | yes | next | add post script |
| patterns-completeness | mix-both-sh | yes | next | add post script |
| e2e-infra | mix-pre-sh | no | **now** | new pre script |
| autofix-diff-review | mix-both-sh | no | next | new pre + post |
| deprecated-api-remnants | mix-both-sh | no | next | new pre + post |
| dep-release-notes | mix-both-sh | no | later | complex (API calls) |
| logical-completeness | mix-both-sh | no | later | function enumeration |

### Step 4 — Verification (15 gates)

| Gate | Type | Has .sh | Priority | Change |
|------|------|---------|----------|--------|
| build-vet-recheck | full-sh | no | **now** | new script (reuse build-vet) |
| cleanliness | full-sh | no | **now** | new script (~15 lines) |
| deprecated-imports | full-sh | no | next | new script |
| version-completeness | full-sh | no | next | new script |
| dep-cve-check | full-sh | no | later | informational, API calls |
| go-version-check | mix-pre-sh | yes | **done** | no change |
| gomod-diff-analysis | mix-pre-sh | no | next | new pre script |
| ci-readiness | mix-pre-sh | no | next | new pre script |
| commit-messages | mix-pre-sh | no | later | informational |
| skill-improvement | mix-pre-sh | no | later | informational |
| correctness | mix-both-sh | no | next | new pre + post |
| ci-prediction | mix-both-sh | no | next | new pre + post |
| k8s-changelog | mix-both-sh | no | next | new pre + post |
| logical-consistency | mix-both-sh | no | later | function enumeration |
| maintainer-review | full-md | no | later | informational, no script |

## Implementation Sequence

### Phase 1: Library + full-sh scripts (priority: now)

Infrastructure and the easiest wins. Zero risk — additive only.

**1a. Extend gate-script-lib.sh** (~15 lines)

Add `finish_gate_final` for full-sh gates that write both PASS
and FAIL verdicts directly. The existing `finish_gate` stays
unchanged for mix-pre-sh compatibility.

**1b. Write new full-sh scripts** (6 scripts, ~25 lines each)

| Script | What it does |
|--------|-------------|
| `diff-scope.sh` | git diff --name-only on fix commits, classify extensions |
| `autofix-result.sh` | git log for counts, go build/vet |
| `feature-gates.sh` | grep KUBE_FEATURE_ vs vendor, pre-existing filter |
| `build-vet-recheck.sh` | reuse build-vet.sh logic for step4 |
| `cleanliness.sh` | git status + find + git ls-files |
| `e2e-infra.sh` | grep version strings, consistency check, SKIP if no e2e |

Also: `test-compilation.sh` (mix-pre-sh, same pattern as
build-vet.sh but with `go test -run='^$' -count=0`).

**1c. Upgrade existing scripts to full-sh**

`build-vet.sh`, `version-consistency.sh`, `major-version-imports.sh`:
change `finish_gate` to `finish_gate_final` so they write FAIL
reports directly instead of deferring to AI. This eliminates 3 AI
subagent launches per run.

Expected impact: 12 gates resolve deterministically (up from 6).
~9 fewer AI subagent launches per run.

### Phase 2: Post-verification infrastructure

**2a. Add post-gate functions to gate-script-lib.sh** (~30 lines)

`init_post_gate`, `post_check`, `finish_post_gate` as specified
above.

**2b. Extend orchestrator** (~8 lines in `cmd_gates`)

Add post-verification block that runs `.post.sh` after finding
a fresh report without `POST_VERIFIED:`.

**2c. Write first post-scripts** (3 highest-value)

| Script | What post-sh verifies |
|--------|----------------------|
| `type-conversions.post.sh` | struct field counts match AI claims |
| `fix-correctness.post.sh` | AI reviewed all fix commits, citations valid |
| `crd-validation.post.sh` | removed validation lines match AI count |

### Phase 3: Remaining scripts (priority: next)

Build out pre and post scripts for the remaining gates per the
classification table. Order by priority column.

### Phase 4: Consolidation (priority: later)

From step-isolation-and-generality.md §8:
- Drop `logical-completeness` (strict superset in `logical-consistency`)
- Narrow `deprecated-api-remnants` to web-search discovery only
- Consider merging `ci-readiness` into `ci-prediction`

## Post-Verification Design Rationale

**Why verify after, not just before?**

Pre-scripts catch "nothing to check" (fast-path PASS) and reduce
the problem space. But they can't catch AI satisficing on the
items that ARE flagged. A post-script re-runs the same
deterministic checks the AI was supposed to analyze and compares
against the AI's claimed findings.

Example: `type-conversions` pre-script finds 3 struct conversion
sites and extracts field counts (StructA: 7 fields, StructB: 5).
AI writes "all fields mapped, PASS." Post-script re-counts: StructA
actually has 7 fields, AI report mentions 5. Override → FAIL.

**Why not two separate AI passes?**

Deterministic scripts are cheaper, faster, and 100% reproducible.
A second AI pass costs tokens and is subject to the same satisficing
risk. The post-script runs in <5 seconds and catches the most
dangerous class of errors: numerical claims that can be mechanically
verified.

**Why append to the report, not rewrite?**

The AI's analysis is preserved for human review. The post-script
adds a POST_VERIFIED section with its checks. The verdict override
path (PASS → FAIL) uses `write-gate-report.sh` which atomically
rewrites, but the POST_DETAIL lines explain why. Reviewers see
both the AI's reasoning and the script's verification.

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Post-scripts slow the pipeline | Low | <5s each, run only once per report (POST_VERIFIED guard) |
| False overrides | Medium | Post-scripts must be conservative — override only on clear numerical mismatch, not interpretation differences |
| Report format coupling | Low | POST_ prefix convention isolates post-verification lines from the rest of the report |
| Over-engineering informational gates | Low | dep-cve-check, commit-messages, skill-improvement stay low priority — scripting them is correctness, not urgency |

## Relation to Other Plans

- **step-isolation-and-generality.md:** This plan implements the
  "companion script expansion" deferred in §4.4 and extends the
  three-tier architecture to four types.
- **next-work.md line 57-58:** "Companion script migration" and
  "gate consolidation 33 → 31" are subsumed here.
- **future-ideas.md line 20-24:** Feature gate auto-discovery is
  orthogonal — it improves autofix, not gates.
- **pr-feedback-resolution.md:** Thread 17 (4 diverged build/vet
  implementations) is addressed by the full-sh upgrade of
  build-vet.sh.

<!-- Budget: 250 lines. Currently ~230. -->
