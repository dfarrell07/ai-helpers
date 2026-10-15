---
name: fix-go-cves
description: Use when asked to scan a Go repository for vulnerabilities or fix all of its CVE/GHSA findings — runs a Grype-driven pipeline that updates dependencies, adds expiring ignores for unfixable findings, verifies with rebuild, tests and rescan, and prints a PR command. For a single known CVE with a user-supplied fix version or fork, use golang:fix-cve instead.
argument-hint: "[repo] [branch] | all <branch>"
user-invocable: true
allowed-tools: Bash, Read, Agent
---

# Fix Go CVEs

Scan every Go module in a repository with Grype, fix each finding on a new
branch, and verify the result before printing a PR command. Deterministic
scripts own every mutation, rollback, and verification gate. Your job is to
run them, then interpret what they could not decide.

## Prerequisites

`git`, `go`, `jq`, `python3`, `make`, `curl`, GNU `timeout`, `base64`, and
Bash 4+.
Grype is installed on demand (checksum-verified, into the plugin's `bin/`);
Docker or Podman is the fallback scanner. See the
[README](../../README.md#prerequisites) for macOS notes.

## Locate the scripts

Resolve the **actual loaded** `SKILL.md` path; its directory's `../..` is
`PLUGIN_ROOT`. Verify `$PLUGIN_ROOT/scripts/fix-all.sh` exists. Never search
home directories for another installed copy.

## Run one repository

Pass the user's optional repository and branch arguments through verbatim, in
their order; the script validates them. A repository is an absolute path or a
name from the [registry](../../README.md#repository-registry); with none, the
current checkout is used. `4.18` expands to `release-4.18`.

```bash
CVE_FIX_AGENT=claude bash "$PLUGIN_ROOT/scripts/fix-all.sh" [REPO] [BRANCH] </dev/null
```

- Set `CVE_FIX_AGENT` to the host runtime: `claude` in Claude Code, `codex`
  in Codex. It selects the read-only reviewer the script calls.
- Builds and tests can each take up to 30 minutes. Run the command in the
  background with output redirected to a log file, and wait for it to exit;
  do not let a tool timeout kill it.
- Keep stdin at `/dev/null` so repository builds cannot block on input.
- The target checkout must be clean. The script creates
  `fix-<version>-cves-<date>` from `origin/<branch>` and commits there.
- Run each repository once per request. A rerun creates another `-vN`
  branch; suggest one with the change that would alter the result, and rerun
  only when the user asks.

## Run all registered repositories

For `all <branch>`, read the registry (see the README), then run one
`fix-all.sh NAME BRANCH` per repository, one at a time; each run builds,
tests, and may pull images, so parallel runs contend for resources. Never
invoke this skill recursively or kill processes belonging to another run.

## Interpret the result

| Exit | Meaning |
| --- | --- |
| 0 | Every finding fixed or ignored and all gates passed |
| 2 | Needs attention: partial fix, unconfirmed result, or PR prerequisite failure |
| 1 | Setup or invocation error |

Read the `Summary` section. Each line is `FIXED`, `IGNORED`, `NEEDS_REVIEW`,
`ERROR`, or `TIMEOUT`. A PR command is printed when a writable fork remote
exists and the gates pass; with findings remaining it is titled "Partial CVE
fix". `NOT READY TO PUSH` lists why one was withheld. `IGNORED` entries cover
only the listed advisories, which had no published fix; each is exact, scoped
to the reporting module when known, and keeps Grype's `fix-state`, so it stops
applying once a fix is published.

For each `NEEDS_REVIEW`, `ERROR`, or `TIMEOUT` line, investigate and give the
user a concrete recommendation:

- Read the evidence the run printed (locate output, scan rows, rollback
  reason) and the affected `go.mod` files.
- For an incompatible or breaking update, check the target version's release
  notes and the repository's use of the changed API; estimate the migration.
- For a Kubernetes minor bump or a Go requirement above the build image,
  say which decision the team owns and what would unblock it.
- For a test failure, read the failing test output and judge whether the
  dependency update caused it.
- For a transient network, timeout or scanner-degraded result, recommend a
  rerun once the environment is healthy.

Do not hand-edit `go.mod`, `go.sum`, vendor trees, or `.grype.yaml` to force a
clean result, and do not delete the fix branch. Report the fix branch, the
commits, and the printed PR command; never push or create the PR yourself.

## Configuration

A `.cve-fix.yaml` in the target repository root overrides detection; all
fields are optional. Matching environment variables override the file for a
single run (`CVE_FIX_BUILD_CMD`, `CVE_FIX_CLEAN_CMD`, `CVE_FIX_TEST_CMD`,
`CVE_FIX_BUILD_IMAGE`).

| Field | Default |
| --- | --- |
| `build-command` | `make build` when a build target exists |
| `clean-command` | `make clean` when a clean target exists |
| `test-command` | First of `make unit`, `make test`, `make test-unit`, `go test ./...` |
| `build-image` | None; its `go version` bounds Go directive and toolchain bumps |
| `k8s-version-guard` | `false`; `true` treats Kubernetes minor bumps as breaking |
| `upstream-org` | Owner of `origin`, used for the PR command |
| `unset-env` | None; variables removed from build, test, and reviewer environments |

Fix policy, ignore semantics, and known limitations are in the
[README](../../README.md#how-fixes-are-chosen).
