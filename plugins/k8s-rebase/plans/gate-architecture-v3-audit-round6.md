# Gate Architecture v3 — Audit Round 6

**Audit date:** 2026-08-15
**Plan audited:** `gate-architecture-v3.md` at commit `c8d2037d`
**Prior audits:** Rounds 1-5 (7+10+14+6+10 = 47 findings) — all addressed before this round
**Verdict:** NEEDS_FIXES_FIRST — two HIGH and two MEDIUM findings, all concentrated in the
`check-phase1-baseline` condition definitions (lines ~997-1024). All fixes are targeted plan
text edits, no architectural changes needed. Plan is substantially ready otherwise.

## Methodology

22-agent ultracode workflow: 7 dimension auditors, adversarial challenge of all 14 HIGH/MEDIUM
findings (default-to-refuted), synthesis. 808K tokens, 191 tool calls. 5/14 survived.

**Dimensions audited:** `cmd_court_metrics $1` and process substitution · `assert-court-permissions.sh`
JSON two-part check · P0a `crd-validation` from-scratch body · `check-phase1-baseline` condition
(v) temporal mismatch · live code verification · overall convergence · condition (v) body-presence
and empty-BASE guard

---

## Key Refutations (confirm the plan is correct on contested points)

| Finding | Refutation |
|---------|-----------|
| condition (v) silently false-FAILs every post-Phase-2 regression run | **Refuted:** `check-phase1-baseline` runs ONCE at the Phase-1→Phase-2 boundary. Post-Phase-2 regression uses a separate comparison step (run `cmd_court_metrics` on working tree, compare against committed `court-baseline.tsv`) — not a re-invocation of `check-phase1-baseline`. The plan's "Two temporal caveats" note (lines ~994-998) is explicit. |
| Two-part JSON check is unimplementable (json format has no denied markers) | **Refuted:** The plan uses `--output-format stream-json --verbose` (not plain `--output-format json`). Stream-json verbose records all tool events including denied calls. The plan explicitly warns against plain json. |
| `make commit-court-baseline` only stages, not commits | **Refuted:** The Implementation Sequence step 5 says "commit the raw log + court-baseline.tsv together." The target name and step description both indicate it commits. |
| PASS and INCONCLUSIVE indistinguishable due to `permission_denials` | **Refuted:** `permission_denials` does not appear in the plan. The PASS signal is a present-and-denied stream-json event (branch-creation probe). |
| P0a crash-branch body omits CRD discovery command | **Refuted:** `crd-validation.sh:20-21` already provides the discovery mechanism; the from-scratch body can reference it. |

---

## Survived Findings

### R1 — HIGH: No retry limit on INCONCLUSIVE probe permanently blocks Phase 1

**Location:** Plan lines 795-803 (`assert-court-permissions.sh` spec)

**What is actually true:** The probe returns INCONCLUSIVE when the model declines in prose
without calling Bash (auth failure, network timeout, model refuses without attempting the
tool call). The plan mandates "INCONCLUSIVE (re-run required), never PASS" with no bound,
no fallback assertion, and no "probe-is-broken" declaration path. Condition (vi) of
`check-phase1-baseline` blocks unless `test/metrics/assert-court-permissions-result.txt`
reads exactly `PASS`. If the probe is systematically INCONCLUSIVE — which is plausible when
the model declines without making a tool_use event — condition (vi) is permanently
unresolvable, blocking the Phase-1 baseline measurement and all Phases 2–5. Exhaustive grep
for retry-limit vocabulary returns zero hits in the plan.

**Action:** Add a concrete bound: after N INCONCLUSIVE results (suggest 3), the probe is
declared broken and must be debugged before Phase 1 proceeds. Specify the diagnostic path:
check Vertex creds, inspect the stream-json transcript to distinguish prose-decline from auth
failure, adjust the probe prompt if the model is declining without calling Bash. Add this as
a numbered sub-step in Phase 1's Required Implementation Sequence. INCONCLUSIVE must remain
blocking — never auto-converted to PASS — but the plan must not leave an unbounded loop with
no exit criteria.

---

### R2 — HIGH: Condition (v) trigger-text grep cannot verify `crd-validation.md` from-scratch body is present

**Location:** Plan lines 1011-1014 (condition v); `gates/step3-autofix/crd-validation.md:13-29`

**What is actually true:** Condition (v) at plan lines 1011-1014 greps only for the trigger
sentence `'not found, crashes, or emits no'` in `crd-validation.md`. P0a's obligation is to
author a full self-contained from-scratch check body ("for each CRD schema file in the
repository, compare `git show $BASE:<path>` against the working copy"). A developer who
writes only the five-word trigger sentence satisfies condition (v). Phase 2 step 4 then
"deletes the FIRST STEP block and points the checks below at the from-scratch variant P0a
already added," but no such variant exists. The gate ends with the evidence template's
judge-from-scratch branch pointing at nothing — the subagent improvises or auto-PASSes.
Confirmed: `crd-validation.md` today (60 lines) has neither the trigger sentence nor any
from-scratch body. Adversary confirmed at HIGH.

**Action:** Strengthen condition (v) for `crd-validation.md` specifically: in addition to
the trigger-sentence grep, add a second grep asserting the from-scratch scope phrase is
present — e.g.,
`grep -q 'for each CRD schema file in the repository' gates/step3-autofix/crd-validation.md`.
Document in the plan that condition (v) is a **two-part check for `crd-validation.md`**
(trigger presence AND body presence) and a **single-part check for `patterns-completeness.md`**
(trigger only, because its check body pre-exists). This simultaneously resolves R3.

---

### R3 — MEDIUM: Condition (v) applied identically to both files despite structurally different adequacy

**Location:** Plan lines 1011-1014 (condition v definition site)

For `patterns-completeness.md`, trigger-sentence presence is a valid proxy for crash-branch
completeness — checks 1-4 are already self-contained (`go build`, `git diff`, `merge-base`,
none reads script output). For `crd-validation.md`, trigger presence is NOT a proxy for body
presence — the body is new prose that must be authored. The plan treats both identically in
condition (v) without calling out the asymmetry at the definition site. An implementer
reading condition (v) as uniform will assume `crd-validation.md` is fully covered once the
grep passes.

**Action:** Resolved by the R2 fix — making condition (v) a two-part check for
`crd-validation.md` and a one-part check for `patterns-completeness.md` explicitly documents
the asymmetry at the definition site. No additional change needed.

---

### R4 — MEDIUM: No enforcement that the empty-BASE guard is present in `crd-validation.md` crash branch

**Location:** Plan lines 526-531 (empty-BASE guard requirement); condition v (lines 1011-1014)

The plan at lines 526-531 requires the `crd-validation.md` crash branch body to carry an
empty-BASE guard: "if `$BASE` is empty (no merge-base), do not diff against the base at all;
judge every CRD's validation surface unfiltered and defer — never PASS on a self-comparison."
The plan calls this "the worst outcome" (line 529). Condition (v) greps only for the trigger
sentence; it cannot detect whether the guard was included. No condition in
`check-phase1-baseline` (i–vi) verifies the guard is present. Grep across `scripts/`,
`test/`, and `gates/` for `empty.*BASE`/`self-comparison` returns zero hits — no other
enforcement exists. Adversary confirmed at MEDIUM.

**Action:** Add a third element to condition (v)'s strengthened `crd-validation.md` check
(alongside the R2 fix): `grep -q 'BASE.*empty\|empty.*BASE\|self-comparison'
gates/step3-autofix/crd-validation.md`. Or prescribe an exact sentinel phrase P0a must
include (e.g., "if BASE is empty") so condition (v)'s grep is unambiguous. Document this as
a third sub-check in condition (v)'s `crd-validation.md` arm.

---

### R5 — LOW: Condition (vi) anti-fabrication gap not called out at its definition site

**Location:** Plan lines 1015-1017 (condition vi definition); lines 1025-1031 (anti-fabrication reasoning)

The plan's anti-fabrication reasoning (lines 1025-1031) is scoped to conditions (i)-(iv) —
re-deriving from `court-history.tsv` "raises the bar from edit two numbers to forge the
corpus." Condition (vi) requires only writing `PASS` to a committed file with no
re-derivation step. The plan's blanket "discipline gate" disclaimer (lines 1040-1044) covers
the whole target non-mechanically, so a careful reader cannot assume (vi) has a
corpus-forgery barrier — but the asymmetry is not called out at the condition (vi) definition
site (lines 1015-1017).

**Action:** Add a one-sentence note at condition (vi)'s definition site: "Unlike conditions
(i)-(iv), (vi) is a pure file-content check with no re-derivation — it is a discipline gate
that assumes the probe was run honestly, consistent with the whole `check-phase1-baseline`
target's status as a reviewer-run gate." Documentation only; no implementation change.

---

## Pre-Implementation Checklist (Round 6)

**Before Phase 1 implementation:**

- [ ] **R1 (MUST):** Add a bounded INCONCLUSIVE retry limit (suggest 3) and diagnostic path to the `assert-court-permissions.sh` spec. Add as a numbered sub-step in Phase 1's Required Implementation Sequence.

- [ ] **R2 (MUST):** Strengthen condition (v) to a two-part check for `crd-validation.md`: (1) trigger-sentence grep AND (2) from-scratch scope phrase grep (`'for each CRD schema file in the repository'`). For `patterns-completeness.md`, keep single-part trigger grep.

- [ ] **R4 (MUST, bundle with R2):** Add a third grep to condition (v)'s `crd-validation.md` arm: verify an empty-BASE guard phrase is present (e.g., `'BASE.*empty\|empty.*BASE\|self-comparison'`). Document as three sub-checks for `crd-validation.md`, one for `patterns-completeness.md`.

- [ ] **R3 (resolved by R2):** No separate action needed — R2's two-part/one-part split documents the asymmetry.

- [ ] **R5 (LOW, documentation only):** Add one sentence to condition (vi)'s definition site noting it is a discipline gate without re-derivation, unlike conditions (i)-(iv).

---

## Confirmed Correct (do not change)

The following were raised as potential issues and adversarially refuted — the plan is correct:

- **Condition (v) and post-Phase-2 regression:** `check-phase1-baseline` runs once at Phase-1→Phase-2 boundary. Later phases use a standalone comparison (run `cmd_court_metrics` on working tree, compare to committed `court-baseline.tsv`) — not another `check-phase1-baseline` invocation.
- **JSON format for assert-court-permissions:** The plan uses `--output-format stream-json --verbose` which records denied tool calls. The two-part (attempted+denied) check is implementable.
- **make commit-court-baseline:** Commits both files (per Implementation Sequence step 5), not just stages.
- **P0a CRD discovery:** `crd-validation.sh:20-21` provides the `find` command for discovery; P0a's from-scratch body can reference it directly.
- **awk $1 process substitution:** `cmd_court_metrics <(git show HEAD:test/court-history.tsv)` passes `/dev/fd/N` as `$1`, awk reads it correctly on Linux bash.
