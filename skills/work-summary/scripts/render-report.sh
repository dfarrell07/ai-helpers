#!/bin/bash
set -euo pipefail

# Render markdown report from JSON data
# Usage: render-report.sh [path-to-json]
# If no path given, tries enriched JSON first, falls back to raw data

if [[ -n "${1:-}" ]]; then
  # Explicit path provided - use it or fail
  JSON_FILE="$1"
  if [[ ! -f "$JSON_FILE" ]]; then
    echo "Error: File not found: $JSON_FILE" >&2
    exit 1
  fi
else
  # No path - try enriched, fall back to raw
  if [[ -f /tmp/work-summary-enriched.json ]]; then
    JSON_FILE="/tmp/work-summary-enriched.json"
  elif [[ -f /tmp/work-summary-data.json ]]; then
    JSON_FILE="/tmp/work-summary-data.json"
  else
    echo "Error: No JSON data found" >&2
    exit 1
  fi
fi

# Extract all values in single jq call
read -r DAYS SINCE TO REPOS_SEARCHED REPOS_WITH_COMMITS PR_COUNT PR_MERGED PR_OPEN ISSUE_COUNT COMMIT_COUNT HAS_ANALYSIS <<< \
  "$(jq -r '[
    .metadata.days,
    .metadata.since_date,
    .metadata.to_date,
    .metadata.repos_searched,
    .metadata.repos_with_commits,
    (.github.prs | length),
    ([.github.prs[] | select(.state == "merged")] | length),
    ([.github.prs[] | select(.state == "open")] | length),
    (.github.issues | length),
    ([.commits | to_entries[] | .value | length] | add // 0),
    (has("analysis") | tostring)
  ] | join(" ")' "$JSON_FILE")"

echo "# Work Summary: Last $DAYS Days ($SINCE to $TO)"
echo ""
echo "## Executive Summary"
echo ""

if [[ "$HAS_ANALYSIS" == "true" ]]; then
  echo "### Key Accomplishments"
  echo ""
  jq -r '.analysis.themes[] | "- **\(.name)**: \(.description) (\(.items | map("[\(.repo)#\(.number)](\(.url))") | join(", ")))"' "$JSON_FILE"
  echo ""
  echo "### In Progress"
  echo ""
  jq -r '.analysis.in_progress[] | "- \(.description) ([\(.repo)#\(.number)](\(.url)))"' "$JSON_FILE"
  echo ""
fi

echo "### Activity Stats"
echo ""
echo "- $PR_COUNT PRs ($PR_MERGED merged, $PR_OPEN open) | $ISSUE_COUNT issues | $COMMIT_COUNT commits across $REPOS_WITH_COMMITS repos"
echo "- Period: $SINCE to $TO"
echo ""
echo "---"
echo ""
echo "## Detailed Work Log"
echo ""
echo "### GitHub Activity"
echo ""
echo "#### Pull Requests ($PR_COUNT total)"
echo ""

jq -r '.github.prs[] | "- [\(.repo)#\(.number)](\(.url)) \(.title) (\(.state))"' "$JSON_FILE"

echo ""
echo "#### Issues ($ISSUE_COUNT total)"
echo ""

if [[ "$ISSUE_COUNT" -eq 0 ]]; then
  echo "No issues created or updated in this period."
else
  jq -r '.github.issues[] | "- [\(.repo)#\(.number)](\(.url)) \(.title) (\(.state))"' "$JSON_FILE"
fi

echo ""
echo "### Git Commits"
echo ""
echo "**Searched $REPOS_SEARCHED repositories, found commits in $REPOS_WITH_COMMITS**"
echo ""

jq -r '.commits | to_entries[] | "#### \(.key)\n" + (.value | map("\(.hash) \(.message)") | join("\n")) + "\n"' "$JSON_FILE"
