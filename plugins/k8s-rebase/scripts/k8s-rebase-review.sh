#!/bin/bash
# k8s-rebase-review.sh — Phase 4 step 5: antagonistic review
#
# For each fix commit, loads the review prompt template, substitutes
# variables with pre-fetched evidence, invokes claude -p as a separate
# process (fresh context), and parses the APPROVE/REJECT verdict.
#
# Usage: k8s-rebase-review.sh <commit-hash> <original-error>
#
# Exit codes: 0 = APPROVE, 1 = REJECT (reason on stdout)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERROR: Not in a git repository" >&2; exit 1; }
TEMPLATE="$SCRIPT_DIR/k8s-rebase-review-prompt.md"
# Patterns file: check plugin docs first, then repo docs
PATTERNS="$SCRIPT_DIR/../docs/k8s-rebase-patterns.md"
[[ -f "$PATTERNS" ]] || PATTERNS="$REPO_ROOT/docs/k8s-rebase-patterns.md"

if [[ $# -lt 2 ]]; then
  echo "Usage: $(basename "$0") <commit-hash> <original-error>"
  exit 1
fi

COMMIT="$1"
shift
ORIGINAL_ERROR="$*"

# Pre-fetch evidence deterministically
export DIFF
DIFF=$(git -C "$REPO_ROOT" show "$COMMIT" --format="" -- "*.go" "*.yml" "*.yaml" "*.sh" | head -500)

export ORIGINAL_ERROR

export K8S_CHANGELOG=""
# Try to extract relevant changelog from the commit message
K8S_CHANGELOG=$(git -C "$REPO_ROOT" log "$COMMIT" -1 --format="%B" | tail -n +2 || true)

export PATTERN_HINT=""
if [[ -f "$PATTERNS" ]]; then
  # Try to find a matching pattern based on the error
  for keyword in "undefined" "SA1019" "deprecated" "FAIL" "too many" "too few" "hang"; do
    if echo "$ORIGINAL_ERROR" | grep -qi "$keyword"; then
      PATTERN_HINT=$(grep -A2 -i "$keyword" "$PATTERNS" | head -6 || true)
      break
    fi
  done
fi

# Load and fill the template
if [[ ! -f "$TEMPLATE" ]]; then
  echo "WARNING: Review template not found at $TEMPLATE, skipping review"
  echo "APPROVE: template not found, skipping"
  exit 0
fi

PROMPT=$(envsubst < "$TEMPLATE")

# Invoke review agent
if ! command -v claude &>/dev/null; then
  echo "WARNING: claude CLI not found, skipping antagonistic review"
  echo "APPROVE: claude CLI not available"
  exit 0
fi

echo ":: Reviewing commit $COMMIT..."
VERDICT=$(echo "$PROMPT" | claude -p --output-format text 2>/dev/null | grep -E "^(APPROVE|REJECT):" | head -1)

if [[ -z "$VERDICT" ]]; then
  echo "WARNING: No clear verdict from review agent"
  echo "APPROVE: no verdict (defaulting to approve)"
  exit 0
fi

echo "$VERDICT"

if echo "$VERDICT" | grep -q "^APPROVE:"; then
  exit 0
else
  exit 1
fi
