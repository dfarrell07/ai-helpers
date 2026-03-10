---
name: work-summary
description: Show recent work: git commits and GitHub activity (PRs, issues)
version: 1.0.0
argument-hint: "[days]"
user-invocable: true
allowed-tools: Bash
---

# Work Summary

Shows recent GitHub activity (PRs, issues) and git commits.

```bash
/work-summary      # Last 7 days (default)
/work-summary 14   # Last 14 days
```

Auto-discovers repos in `~/go/src`, `~/konflux`, `~/projects`, current directory.

**Arguments:** $ARGUMENTS

```bash
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
bash "$SCRIPT_DIR/scripts/work-summary.sh" ${ARGUMENTS:-7}
```
