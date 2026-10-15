---
name: fix-go-cves
description: Use when asked to fix the CVE/GHSA findings of a Go repository — scans every module with Grype, updates dependencies on a new branch, ignores only findings without a published fix, verifies with rebuild, tests and rescan, and prints a PR command. Also scans without changes when only a report is wanted. For one known CVE with a user-supplied fix version or fork, use golang:fix-cve instead.
argument-hint: "[repo] [branch] | all <branch>"
user-invocable: true
allowed-tools: Bash, Read
---

# Fix Go CVEs

Deterministic scripts own every mutation, rollback, and verification gate.
Your job is to run them, then explain what they could not decide.

## Locate the scripts

`PLUGIN_ROOT` is `${CLAUDE_PLUGIN_ROOT}` when set; otherwise resolve the
**actual loaded** `SKILL.md` path and use its directory's `../..`. Verify
`$PLUGIN_ROOT/scripts/fix-all.sh` exists. Never search home directories for
another installed copy. `fix-all.sh` checks its prerequisites and exits 1
naming anything missing.

## Report only

When the user asks only to scan, check, or report, do not run `fix-all.sh`.
Scan the checked-out branch without creating a branch or commit (the build
still runs, and may leave build output):

```bash
bash "$PLUGIN_ROOT/scripts/report.sh" [REPO] </dev/null
```

## Fix one repository

Map the request to optional repository and branch arguments: a repository is
an absolute path or a [registry](../../README.md#repository-registry) name,
and `X.Y` means `release-X.Y`. With neither, the current checkout and branch
are used.

```bash
LOG=$(mktemp "${TMPDIR:-/tmp}/fix-go-cves.XXXXXX.log")
CVE_FIX_AGENT=claude bash "$PLUGIN_ROOT/scripts/fix-all.sh" [REPO] [BRANCH] </dev/null >"$LOG" 2>&1
```

- Set `CVE_FIX_AGENT` to the host runtime: `claude` in Claude Code, `codex`
  in Codex. It selects the reviewer the script calls.
- Builds and tests can each take 30 minutes. Run in the background and wait
  for the exit; do not let a tool timeout kill it.
- The checkout must have no uncommitted or untracked files. The script
  creates `fix-<version>-cves-<date>` from `origin/<branch>`, commits there,
  and leaves the checkout on that branch; tell the user how to return.
- Run each repository once per request. A rerun creates another `-vN`
  branch; suggest one with the change that would alter the result, and rerun
  only when the user asks.

Read the outcome rather than the whole log:

```bash
sed -n '/^--- Summary/,$p' "$LOG"
grep -n '^NEEDS_REVIEW\|^ERROR\|^TIMEOUT\|^STILL_VULNERABLE\|^NEW_FINDING' "$LOG"
```

## Fix all registered repositories

For `all <branch>`, list the names, then run `fix-all.sh NAME BRANCH` for each
one at a time; parallel builds and image pulls contend for resources.

```bash
for r in "${CVE_FIX_REPOS:-}" "${XDG_CONFIG_HOME:-$HOME/.config}/cve-fix/repos.yaml" "$PLUGIN_ROOT/repos.yaml"; do
  [[ -f "$r" ]] && { python3 "$PLUGIN_ROOT/scripts/read-config.py" repos-list "$r"; break; }
done
```

## Interpret the result

| Exit | Meaning |
| --- | --- |
| 0 | Every finding fixed or ignored, and all gates passed |
| 2 | Partial fix, unconfirmed result, or PR prerequisite failure |
| 1 | Setup or invocation error |
| 130, 143 | Interrupted; the fix branch was removed |

A PR command is printed only when a fork remote exists and the gates pass;
exit 0 without one means the user must add a fork remote. With findings
remaining it is titled "Partial CVE fix". `IGNORED` lines need no action: no
fix is published, and the ignore lapses once Grype records one.

For each `NEEDS_REVIEW`, `ERROR`, or `TIMEOUT` line, investigate and report
the cause, the evidence (log line or `file:line`), the recommended action,
and who decides:

- Breaking or incompatible update: read the target version's release notes
  and the repository's use of the changed API; estimate the migration.
- Kubernetes minor bump, or Go above the build image: name the team decision
  and what unblocks it (a newer builder, an approved bump).
- Test failure: read the failing output and judge whether the update caused
  it; tests that need `sudo` or a prompt need a non-interactive
  `test-command`.
- Transient network, timeout, or degraded scanner: recommend a rerun.
- Wrong build or test command: recommend `.cve-fix.yaml` fields or
  `CVE_FIX_*` overrides ([configuration](../../README.md#configuration)).

Do not hand-edit `go.mod`, `go.sum`, vendor trees, or `.grype.yaml` to force a
clean result, and do not delete the fix branch. Report the branch, commits,
and printed PR command; never push or create the PR yourself.
