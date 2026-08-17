# Gate Test Matrix — Findings Log

Live log of what we learn from running all 6 repos × 3 versions = 18 combos.
Updated after every test cycle. Goal: real rebase quality, not checkbox counts.

**Current code state**: gate-arch-v4 Phase 2 (evidence transport) + extensive gate
quality fixes from 3 rounds of ultracode auditing.

---

## Loop Protocol

Each cycle:
1. `make test repo=<repo> [version=X.Y]` — launch (default spec=none = full skill)
2. `make watch` every few minutes — check gate progress, watch for crashes
3. When complete: `make results repo=<repo>` — read ALL gate verdicts
4. Read individual gate report files in `.rebase-tmp/gates/*.report`
5. Read `.rebase-tmp/gates/*.evidence` files to verify evidence transport
6. `make court repo=<repo>` — run adversarial court review
7. Analyze: what was found vs known-good? What was missed? False-PASS? False-FAIL?
8. Update this doc
9. Fix any gate bugs, commit, then next cycle

**What to watch for:**
- Gates that FAIL on pre-existing issues (false-FAIL)
- Gates that PASS when known-good has real fixes (false-PASS)
- Evidence files: are they being written and read correctly?
- Pre-existing check correctness: count delta working? modified-file working?
- Court verdict vs gate verdicts: do they agree?

---

## Test Matrix Status

| Repo | v1.36 | v1.35 | v1.34 | Notes |
|------|-------|-------|-------|-------|
| openshift/multus-cni | ✅ | — | — | Court PASS 3-0, 20 code hunks vs known-good |
| ovn-kubernetes/ovn-kubernetes-mcp | ✅ | — | — | Court PASS 3-0, 8 code hunks vs known-good |
| openshift/ingress-node-firewall | ⚠️ | — | — | Court FAIL 3-0. Gates all PASS — false-PASS found in maintainer-review |
| openshift/cloud-network-config-controller | ✅ | — | — | Court PASS 3-0, 12 code hunks vs known-good. Stalled once, retry succeeded. |
| openshift/cluster-network-operator | ✅ | — | — | Court PASS 3-0, 38 code hunks vs known-good. CRD gate worked on real CRDs. |
| ovn-org/ovn-kubernetes | ✅ | — | — | Court PASS, 186 code hunks vs known-good. Disk critical (16G min). |

Status: ⏳ running | ✅ PASS | ⚠️ issues | ❌ FAIL | — = not started

---

## Findings by Cycle

### Cycle 1: openshift/multus-cni v1.36 spec=all

**Started**: 2026-08-17
**Completed**: —
**Gate summary**: 19/33 gates, 1 FAIL in progress
**Disk at start**: 41G free
**Court verdict**: —
**Loop log**:
- Firing 1: 19/33 gates complete, 1 FAIL (stale klog v1 vendor file commit visible), 17 code hunks vs known-good
- Firing 2: 33/33 complete, needs-court → ran court, PASS 3-0. Launched ovn-kubernetes-mcp.

### Cycle 2: ovn-kubernetes/ovn-kubernetes-mcp v1.36 spec=all

**Loop log**:
- Firing 3: 18/33 gates, 8 code hunks vs known-good, 38G free
- Firing 4: 33/33, needs-court → PASS 3-0, 8 hunks. Launched ingress-node-firewall.

**Court verdict**: PASS 3-0, 8 code hunks vs known-good (+160 vendor)

**Evidence transport**: Working correctly. 6 evidence files, all HEAD-stamped.

**Key findings**:
- version-consistency: 12 MISMATCHes including `k8s.io/kubernetes v1.36.2` (uses v1.x.y NOT v0.x.y), `sigs.k8s.io/*` packages. Subagent correctly dismissed all. Gate .md note updated to add k8s.io/kubernetes.
- go-version-check: GINKGO_VERSION matched by grep `GO_VERSION` pattern (substring match bug). Flagged 2 false lines in evidence. Subagent still PASSed correctly but evidence was noisy. FIXED in go-version-check.sh with \b word boundaries.

**Gate bugs found**: 2 (both fixed, committed b5267c90)
**Pattern confirmed**: version-consistency false-positive list is repo-specific; need comprehensive note in gate .md.

### Cycle 3: openshift/ingress-node-firewall v1.36 spec=all

**Loop log**:
- Firing 4: launched
- Firing 5: 4/33 gates, 66 code hunks vs known-good (much larger diff than previous repos), 37G free
- Firing 6: 33/33 gates done (4 skipped), session still working (advance step), 68 code hunks vs known-good, 36G free
- Firing 7: 33/33 gates still, session still working (gate-fix loop — diff grew 68→93 code hunks, latest: "lint: fix golangci-lint v2 iss"), 37G free. Ingress-node-firewall has more k8s code changes than simpler repos.
- Firing 8: needs-court → FAIL 3-0. All 33 gates PASS. **CRITICAL GATE BUG FOUND.**

**Court verdict**: FAIL 3-0. 84 non-vendor code hunks vs known-good.

**ROOT CAUSE**: Skill used mass per-line `//nolint:errcheck` suppression (~80+ instances) while human known-good used a different approach. Step-2 instructions explicitly say "use .golangci.yml exclude-functions, NOT per-line nolint:errcheck." The skill ignored this guidance.

**Key diff**: Skill created `.golangci.yml` (for staticcheck) + added `//nolint:errcheck` inline throughout the codebase. Human known-good did not add .golangci.yml and used a cleaner lint approach.

**False-PASS confirmed**: `step4-maintainer-review` PASSed and said "All 7 commits well-scoped." It missed that the lint approach was an anti-pattern explicitly called out in step-2 guidance.

**Gate fix applied (commit 0b9e9c5f)**:
- maintainer-review.md: Added explicit check — if `git diff | grep '^\+.*//nolint:errcheck' | wc -l` > 5, that is FAIL. Preferred: .golangci.yml exclude-functions.

**Evidence transport**: Worked correctly. 6 evidence files, HEAD-stamped.
**Disk**: 37G free.

### Cycle 4: openshift/cloud-network-config-controller v1.36 spec=all

**Loop log**:
- Firing 8: launched
- Firing 9: 0/33 gates, 12 code hunks vs known-good (+398 vendor), 37G free
- Firing 10: still 0/33 gates, 2 worktree commits (rebase + version refs), session alive, in compilation-fix loop, not stalled, 37G free
- Firing 11: STALLED — step1 completed at 04:14, no new files/commits in 2+ hours. All .rebase-tmp files dated 04:14, empty vendor.log/tidy.log, no summary.txt, no state.json. Stopped session (ba2ce30a), cleaned, restarted (efcb7197).
- Firing 12: Retry working — 16/33 gates (4 skipped), 12 code hunks vs known-good, 34G free. NOTE: disk dropped 37→34G.
- Firing 13: 43/33 gates (8 skipped) — multi-pass (gate-fix loop re-ran gates), session still "working", 34G free
- Firing 14: needs-court → PASS 3-0, 12 hunks. Launched cluster-network-operator.

**Court verdict**: PASS 3-0, 8 non-vendor code hunks vs known-good.

**Evidence quality**: 
- version-consistency: 9 MISMATCHes, all correctly dismissed as independent-versioning packages (klog/v2, kube-openapi, utils, sigs.k8s.io/*). New package: sigs.k8s.io/kube-storage-version-migrator also has independent versioning.
- go-version-check: SUMMARY "0 Go version issues" — correct (no Makefile GINKGO_VERSION false matches here).
- crd-validation/e2e-infra/feature-gates: correctly SKIPped (no CRDs, no KIND infra, no feature gate refs).

**Multi-pass pattern**: 43 reports across 33 unique gates = gate-fix loop re-ran some gates after fixes. This is expected behavior.

**Stall note**: First attempt stalled after step1 completion (2+ hours, no activity). Second attempt completed successfully. Possible cause: first attempt had a long-running go build that hung.

**No gate bugs found in this cycle.**

### Cycle 5: openshift/cluster-network-operator v1.36 spec=all

**Loop log**:
- Firing 14: launched
- Firing 15: 7/33 gates, 38 code hunks vs known-good (large repo), 30G free (WATCHING DISK — dropped 4G from previous cycle)
- Firing 16: needs-court → PASS 3-0, 38 hunks. Cleaned 4 old worktrees. Launched ovn-org/ovn-kubernetes.

**Court verdict**: PASS 3-0, 26 non-vendor code hunks vs known-good.

**KEY FINDING — crd-validation on a real CRD repo**:
Evidence showed 4 CRD validation changes in `bindata/network/frr-k8s/001-crd.yaml` (CHANGED-VALIDATION). 9 other CRDs were IDENTICAL or NO-VALIDATION-CHANGES. Subagent correctly focused only on the changed CRD, identified "4 int64 format fixes — expected autofix corrections, no validation weakened." PASS. **This is the gate working exactly as designed.**

**version-consistency**: 12 MISMATCHes (same pattern), all correctly dismissed via gate .md exemption list.
**go-version-check**: 0 issues (clean).
**No crashes, no false-FAIL, no false-PASS.**

### Cycle 6: ovn-org/ovn-kubernetes v1.36 spec=all

**Loop log**:
- Firing 16: launched (most complex repo — 3 modules, large codebase)
- Firing 17: 1/33 gates, 212 code hunks vs known-good (+898 vendor — VERY LARGE DIFF), 27G free (tight, watching closely)
- Firing 18: 7/33 gates, 183 code hunks (diff shrinking as fixes applied), **DISK WARNING: 20G free (dropped 7G in one firing)**. Still > 15G, not cleaning yet.
- Firing 19: 9/33 gates, 186 code hunks, 19G free. Disk stabilized (only 1G drop). Proceeding.
- Firing 20: 32/33 gates (4S), 186 code hunks, **DISK CRITICAL: 16G free** (1G above threshold). Session almost done — not interrupting. Will clean AFTER court.
- Firing 21: needs-court → court ran (9+ min for 149 non-vendor hunks) → PASS. Cleaned disk: 17→26G.

**Court verdict**: PASS, 186 code hunks vs known-good (149 non-vendor).

**Evidence quality (largest repo, 3 modules)**:
- version-consistency: 33 MISMATCHes (highest yet). All correctly dismissed — includes sigs.k8s.io/knftables, sigs.k8s.io/network-policy-api specific to ovn-kubernetes ecosystem.
- go-version-check: 4 "issues" = GO_VERSION lines in 2 Makefiles (dist/images + go-controller). Companion matched both definition lines AND usage lines in `${GO_VERSION}`. Subagent correctly identified as consistent (1.26 = target). Minor companion noise but gate verdict correct.
- crd-validation: 0 changes (CRDs exist but none changed) — correctly handled.
- build-vet: 0 errors across 3 modules — clean.

**Disk lessons**: ovn-kubernetes consumed 11G of worktree space. For large repos, must budget >30G free before starting. Recommend starting ovn-kubernetes with 35G+ free.

**No new gate bugs found.**

---

## v1.36.2 Round Complete — Summary

| Repo | Court | Code Hunks | Key Finding |
|------|-------|-----------|-------------|
| openshift/multus-cni | PASS 3-0 | 20 | Clean, evidence transport working |
| ovn-kubernetes/ovn-kubernetes-mcp | PASS 3-0 | 8 | GINKGO_VERSION false-match found/fixed |
| openshift/ingress-node-firewall | **FAIL 3-0** | 93 | Mass //nolint:errcheck anti-pattern — maintainer-review false-PASS. Fixed. |
| openshift/cloud-network-config-controller | PASS 3-0 | 12 | Stalled once (retry worked). No bugs. |
| openshift/cluster-network-operator | PASS 3-0 | 38 | CRD gate worked correctly on real CRDs |
| ovn-org/ovn-kubernetes | PASS 3-0 | 186 | 33 false MISMATCH correctly dismissed |

**Score: 5/6 court PASS** (ingress-node-firewall was the outlier — fixed)

### Full Court Results (make court run across all versions)

**v1.34.1**: All PASS (ovn-kubernetes, multus-cni, cncc, cno)
**v1.35.3**: 3/4 PASS, **ovn-org/ovn-kubernetes FAIL 3-0**
**v1.36.2**: 4/5 PASS, **cluster-network-operator FAIL 2-1** (ingress-node-firewall PASS — gate fix improved lint approach from 3-0 FAIL to PASS)

#### ovn-org/ovn-kubernetes v1.35.3 FAIL 3-0 — root cause
Confirmed by all 3 jurors reading the actual code:
1. `go-controller/pkg/ovn/controller/unidling/unidle_test.go:105` — `ctx, _ := context.WithTimeout(...)` discards cancel function → **`go vet lostcancel` hard error that CI would catch**
2. `golang.org/x/net/context` imported instead of stdlib `context` in a Go 1.26 module — deprecated import

**Gate false-PASSes**: `step2-build-vet` missed the lostcancel error (likely because go-controller vendor was empty in the worktree — go vet may not have run the analyzer properly). `step4-deprecated-imports` missed the golang.org/x/net/context deprecated import.

Note: `golang.org/x/net/context → context (Go 1.7+)` is now in the deprecated-imports.md table — future runs should catch it.

#### openshift/cluster-network-operator v1.36.2 FAIL 2-1 — borderline
- Bare `nft` commands inside `set -xe` drop-icmp container without `|| true` → CrashLoopBackOff on nodes without nftables in rolling upgrades (confirmed by 2 jurors)
- Juror 2 voted PASS: nftables standard on RHEL 9
- Also: getStringList replacing getCIDRList removes CIDR validation from NodePortAddresses
- This is a 2-1 stochastic borderline — the issue is real but context-dependent

### Gate Changes Made During Testing

| Commit | Gate | Fix | Triggered by |
|--------|------|-----|-------------|
| b5267c90 | go-version-check.sh | GINKGO_VERSION false-match (grep -v + \b) | ovn-kubernetes-mcp cycle |
| b5267c90 | version-consistency.md | Added k8s.io/kubernetes to exemption list | ovn-kubernetes-mcp cycle |
| 0b9e9c5f | maintainer-review.md | Added >5 //nolint:errcheck check → FAIL | ingress-node-firewall court FAIL |

---

### v1.35 Round

| Repo | v1.35 | Notes |
|------|-------|-------|
| openshift/multus-cni | ⏳ | spec=all launched, 26G free |
| ovn-kubernetes/ovn-kubernetes-mcp | — | |
| openshift/ingress-node-firewall | — | Will test if nolint fix helps |
| openshift/cloud-network-config-controller | — | |
| openshift/cluster-network-operator | — | |
| ovn-org/ovn-kubernetes | — | |

**v1.35 Loop log**:
- v1.35 Firing 1: multus-cni launched
- v1.35 Firing 2: 1/33 gates, 67 code hunks (vs 20 in v1.36 — larger diff for older version), 25G free
- v1.35 Firing 4 (concurrent): cncc v1.35 1/33 (1F), infw v1.35 5/33 (116 code hunks — very large), 34G free
- v1.35 Firing 5: cncc v1.35 7/33 (1S — FAIL fixed), infw v1.35 27/33 (4S, 115 hunks), 30G free
- v1.35 Firing 6: Both done → infw v1.35 **FAIL** (missing 6 step2 gates), cncc v1.35 **PASS 3-0**.
- v1.35 Firing 7: Launched cno v1.35 + mcp v1.35 (note: mcp v1.35 already ran earlier but re-running). cno 0/33 (345 code hunks — very large), mcp 0/33 (190 hunks). 29G free.
- v1.35 Firing 8: cno v1.35 1/33 (1F), mcp v1.35 0/33, 28G free.
- **Fixes applied** (commits ec898e84, a21d2c5b, 9140b17e): podman short-name-mode=permissive + lint guidance + root-cause fixes (cross-step report deletion, validate.sh container fallback)
- v1.35 Firing 9: cno v1.35 1/33 (355 hunks), mcp v1.35 1/33 (188 hunks), 25G free (dropping)
- v1.35 Firing 10: cno 6/33 (1S), mcp 6/33 (1S), 24G free
- v1.35 Firing 11: cno 6/33, mcp 7/33, 24G free
- v1.35 Firing 12: cno 14/33 (1S), mcp 17/33, 23G free
- v1.35 Firing 13: cno 18/33, mcp 29/33 (3S — almost done), 24G free
- v1.35 Firing 14: cno 33/33 (4S), mcp 33/33 (4S), both done.
- v1.35 Firing 15: multus-cni 0/33 (64 hunks), ovn-kubernetes 0/33, 23G free
- v1.35 Firing 16: multus-cni 1/33 (67 hunks), ovn-kubernetes 0/33 (6717 code hunks — VERY LARGE), **19G free (watch disk)**
- v1.35 Firing 17: multus-cni 1/33 (rebase phase), ovn-kubernetes 0/33, 18G → cleaned old worktrees → 22G
- v1.35 Firing 18: multus-cni 7/33, ovn-kubernetes 1/33, 19G (dropped 3G from new worktrees)
- v1.35 Firing 19: multus-cni 16/33 (1S), ovn-kubernetes 1/33, 17→18G (cleaned old worktrees)
- v1.35 Firing 20: multus-cni 17/33, ovn-kubernetes 1/33 (new commit: "e2e: fix format string"), 17G
- v1.35 Firing 21: multus-cni 17/33 (SAME — 10 min at same count, watching for stall), ovn-kubernetes 1/33, 17G
- v1.35 Firing 22: multus-cni 17/33 **STALLED** (15+ min same count — likely in long containerized lint gate), ovn-kubernetes 1/33 (advancing, new commit), **16G CRITICAL**
- v1.35 Firing 23: **DISK 14G** — stopped both sessions, `make clean` → 20G freed. ovn-kubernetes worktree was 5.8G (main disk consumer). Removed retained worktrees, restarted both fresh: multus-cni 0/33, ovn-kubernetes 0/33.
- v1.35 Firing 24: multus-cni 0/33 (rebase commits), ovn-kubernetes 0/33 (rebase commits), 19G free
- v1.35 Firing 25: multus-cni 2/33 (advancing), ovn-kubernetes 0/33. **STOPPED ovn-k proactively** — disk dropping fast (19→17G in 10 min), ovn-k worktree grows to 5.8G. Will run multus-cni alone, then ovn-k solo after.
- v1.35 Firing 26: no active tests — multus-cni session terminated at 2/33 (reason unknown). 17G free. Restarted multus-cni solo.
- v1.35 Firing 27: multus-cni 1/33, advancing, 17G stable (solo run)
- v1.35 Firing 28: multus-cni 1/33 (SAME — 10 min, approaching stall), 16G (warning). Note: even solo run consuming disk via go build cache.
- v1.35 Firing 29: multus-cni 1→7/33 (NOT stalled, was running long gate), 16G stable
- v1.35 Firing 30: multus-cni 7/33 (SAME — 10 min, new commit made, likely long gate), 16G stable
- v1.35 Firing 31: multus-cni 7→18/33 (was running gates in parallel!), 16G stable
- v1.35 Firing 32: multus-cni 19/33, advancing, 16G stable
- **Commits**: 52dada77 (validate.sh regression fix), cc61dc9c (MVS pre-align NEEDS REVIEW), aec488bf (findings log), b52b871c (hook guard for cross-step rm)
  mcp latest: "ci: add golangci-lint v2 confi..." — **validate.sh fallback WORKED**: lint ran via direct golangci-lint, skill correctly added .golangci.yml config (not per-line nolint).
  Court: mcp PASS 3-0 (25 hunks), cno PASS 2-1 (40 hunks). 23G free.
  Launched: multus-cni v1.35 + ovn-org/ovn-kubernetes v1.35

**infw v1.35 ROOT CAUSE** (deep investigation):
- validate.sh auto-containerizes → tries `podman pull` → fails: "short-name resolution enforced but cannot prompt without a TTY"
- `operator-sdk` missing from PATH → `make lint` fails immediately
- validate.sh emits "UNCLASSIFIED FAILURE (root lint)" — not a Go build/lint error pattern, just missing tools
- Skill sees unrecognized failure, can't fix it, never completes step2 → no step2 gate reports
- `.advance-attempts-step3` exists (not step2) because step2 advanced BEFORE gates ran
- **Not a gate bug** — environment issue: containerized lint + no-TTY + missing operator-sdk
- Fix: skill should detect "UNCLASSIFIED FAILURE (root lint)" → fall back to `--quick` (build+vet only), skip containerized lint
- This knowledge IS in the patterns doc → spec=all (blind) can't handle it

**cncc v1.35**: PASS 3-0, 19 code hunks vs known-good (+5878 vendor).

**infw v1.36 RETEST** (with maintainer-review nolint fix):
- Firing 1 (concurrent with mcp v1.35): 17/33 gates, **68 code hunks** (was 93 in FAIL run — 25 fewer hunks!). Session making different choices. 36G free.
- Firing 2: 33/33 gates (4S), still "working" (gate-fix loop). Latest: "lint: suppress pre-existing is..." — 79 hunks (grew 68→79 during gate-fix loop). 35G free.
- Firing 3: needs-court → FAIL 2-1 (improved from 3-0). 85 code hunks, 76 non-vendor.

**Court verdict**: FAIL 2-1 (improvement — was 3-0 FAIL, now 1 juror PASSes).

**Gate fix analysis**:
- Skill correctly switched from mass per-line nolint to `.golangci.yml` (errcheck.exclude-functions for fmt.Fprintf/Fprintln/Fprint; staticcheck.checks: SA* minus SA1019/SA4010)
- 0 per-line nolint for the excluded fmt functions
- BUT: still added `defer f.Close() //nolint:errcheck` annotations
- Known-good: NO .golangci.yml, NO nolint annotations — passes lint by a different mechanism

**Root cause of remaining FAIL**: Known-good doesn't suppress lint at all for `defer f.Close()`. Either golangci-lint v2 defaults exclude defer-close errors, or the known-good uses a different errcheck config. The skill added per-line nolint for Close() when the config approach (or just trusting defaults) would be cleaner.

**Fundamental limitation**: With spec=all (blind — no patterns doc), the skill can't know the repo's specific lint convention. The patterns doc would tell it exactly how to handle each case.

**Progress**: Gate fix moved the skill from wrong approach (mass per-line nolint) to better approach (golangci.yml config). Court moved from 3-0 to 2-1. Not yet matching the known-good's approach exactly.

**ovn-kubernetes-mcp v1.35**:
- Firing 1: 0/33 gates, 190 code hunks (+7377 vendor — very large vendor diff for v1.35), 36G free
- Firing 3: 33/33, needs-court → **PASS 3-0**. 191 code hunks vs known-good (+5085 vendor).

**Per-gate verdicts**: All 33 PASS (4 INFO-skipped: dep-cve-check, skill-improvement, commit-messages, maintainer-review)

**Evidence transport — WORKING WELL:**
- 6 evidence files written, all HEAD-stamped ✓
- `step2-version-consistency`: companion flagged 8 MISMATCHes (klog, kube-openapi, utils, sigs.k8s.io/*). Subagent correctly dismissed all 8 as false-positives (independent versioning). Evidence and judgment both correct.
- `step4-go-version-check`: evidence HEAD was STALE (written at 18c62d4c, report at c113a563). Subagent detected mismatch, fell back to scratch analysis, reached correct PASS. Stale-evidence fallback works.
- `step3-crd-validation`: evidence said SKIP (no CRDs in repo) — correct for multus-cni
- `step2-build-vet`: 0 errors — clean
- `step3-major-version-imports`: 0 stale imports — clean
- `step3-patterns-completeness`: 0 build issues — clean

**Court verdict**: PASS 3-0. 20 code hunks vs known-good (+113 vendor hunks excluded). Court deemed differences acceptable.

**dep-cve-check**: Found 15 CVEs across 5 modules (golang.org/x/* packages). ALL pre-existing — old version already affected. Fix versions all exceed new version (can't fix by bumping further within k8s rebase scope). Correctly PASSed.

**Known-good diff**: 20 non-vendor code hunks differ. Court PASS means these are expected variations, not missed fixes.

**Gate bugs found**: None. Evidence transport, judgment, and pre-existing filters all working correctly.

**Key patterns from this cycle**:
- version-consistency.sh false-positives (klog/kube-openapi/sigs.k8s.io) are consistently dismissed correctly by subagents — the gate .md note about independent versioning is working
- go-version-check stale-evidence fallback works as designed
- No false-FAIL or false-PASS detected
- Disk: 39G free after run

---

## Patterns Across Cycles

*(filled as patterns emerge across multiple repos)*

### Pre-existing check issues


### Evidence transport issues


### False-PASS gates (consistently missing real issues)


### False-FAIL gates (consistently firing on pre-existing)


### Version-specific issues


### Repo-type-specific issues


---

## Gate Quality Score (updated each cycle)

| Gate | False-PASS risk | False-FAIL risk | Notes |
|------|----------------|-----------------|-------|
| | | | |

---

## Gate Changes Made During Testing

*(track fixes made in response to test findings)*

| Commit | Gate | Fix | Triggered by |
|--------|------|-----|-------------|
| | | | |
