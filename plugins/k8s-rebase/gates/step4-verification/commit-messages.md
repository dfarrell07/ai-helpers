Read the project's commit message guidelines:
1. Check docs/governance/CONTRIBUTING.md, then CONTRIBUTING.md
2. Look for prefix convention, case rules, length limits
3. If no guidelines found, run `git log --oneline -20` on the
   base branch (master or main) to infer the convention

Then check all rebase commits:
  git log --oneline $(git merge-base HEAD master 2>/dev/null ||
    git merge-base HEAD main)..HEAD

For each commit, check:
- Has a prefix before ":" if the project requires one
- First line is ≤72 characters
- Lowercase after prefix (if the project specifies this)

Also list the prefixes used in the rebase commits and compare
to prefixes in recent base-branch history. Note any prefixes
that don't appear in recent history (informational, not a
failure — new prefixes like `deps:` or `codegen:` can be valid
for rebase-specific commits).

Count commits that violate the FORMAT convention (missing
required prefix, over length limit, wrong case). Do not count
unusual-but-valid prefix choices.

Rules: report specific counts, not "looks good." You are
read-only — do not edit files. Cite commit hash and message
for any violations.
