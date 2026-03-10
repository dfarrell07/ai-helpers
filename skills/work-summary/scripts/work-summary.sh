#!/bin/bash
set -euo pipefail

# Parse arguments
DAYS="${1:-7}"

# Validate days is a number
if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Error: Days must be a number (got: $DAYS)" >&2
  exit 1
fi

# Check for jq
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed" >&2
  echo "Install: brew install jq (macOS) or apt install jq (Linux)" >&2
  exit 1
fi

SINCE_DATE=$(date -d "$DAYS days ago" +%Y-%m-%d 2>/dev/null || date -v-"${DAYS}"d +%Y-%m-%d)
TO_DATE=$(date +%Y-%m-%d)
AUTHOR_EMAIL=$(git config user.email 2>/dev/null || echo "")

# Collect GitHub Activity (already in JSON format from gh CLI)
PRS_JSON="[]"
ISSUES_JSON="[]"

if command -v gh &>/dev/null && gh auth status &>/dev/null; then
  GH_USER=$(gh api user --jq .login 2>/dev/null || echo "")

  if [[ -n "$GH_USER" ]]; then
    # gh search outputs JSON directly, we just filter by date and reshape
    PRS_JSON=$(gh search prs --author="$GH_USER" --limit 50 \
      --json number,title,repository,state,updatedAt,url \
      --jq "[.[] | select(.updatedAt >= \"$SINCE_DATE\") | {repo: .repository.nameWithOwner, number, title, state, url, updated_at: .updatedAt}]" \
      2>/dev/null || echo "[]")

    ISSUES_JSON=$(gh search issues --author="$GH_USER" --limit 50 \
      --json number,title,repository,state,updatedAt,url \
      --jq "[.[] | select(.updatedAt >= \"$SINCE_DATE\") | {repo: .repository.nameWithOwner, number, title, state, url, updated_at: .updatedAt}]" \
      2>/dev/null || echo "[]")
  fi
fi

# Discover repos using dual data structures for efficient deduplication:
# - Associative array (SEEN_REPOS) provides O(1) lookup to check if repo already seen
# - Indexed array (REPO_LIST) preserves discovery order for consistent output
declare -A SEEN_REPOS
REPO_LIST=()

if [[ -n "$AUTHOR_EMAIL" ]]; then
  for base_dir in "$HOME/go/src" "$HOME/konflux" "$HOME/projects" "$PWD"; do
    [[ ! -d "$base_dir" ]] && continue

    while IFS= read -r -d '' git_dir; do
      repo_path="${git_dir%/.git}"

      # Skip if already seen
      [[ -n "${SEEN_REPOS[$repo_path]:-}" ]] && continue
      SEEN_REPOS[$repo_path]=1
      REPO_LIST+=("$repo_path")
    done < <(find "$base_dir" -maxdepth 3 -type d -name ".git" -print0 2>/dev/null)
  done
fi

# Collect commits - build array of JSON objects, merge once
COMMITS_PARTS=()

for repo_path in "${REPO_LIST[@]}"; do
  commits=$(git -C "$repo_path" log --author="$AUTHOR_EMAIL" --since="$SINCE_DATE" --format='%h|%s' 2>/dev/null || true)

  if [[ -n "$commits" ]]; then
    repo_name=$(basename "$repo_path")

    # Convert commits to JSON array using jq (handles all escaping)
    commits_json=$(echo "$commits" | jq -R -s '
      split("\n") |
      map(select(length > 0) | split("|") | {hash: .[0], message: .[1]})
    ')

    # Add to parts array
    COMMITS_PARTS+=("$(jq -n --arg repo "$repo_name" --argjson commits "$commits_json" '{($repo): $commits}')")
  fi
done

# Merge all parts into single JSON object (single jq call)
COMMITS_JSON=$(printf '%s\n' "${COMMITS_PARTS[@]}" | jq -s 'reduce .[] as $item ({}; . + $item)')
REPOS_WITH_COMMITS=$(echo "$COMMITS_JSON" | jq 'keys | length')

# Build final JSON structure using jq (proper, safe, no manual escaping)
jq -n \
  --argjson days "$DAYS" \
  --arg since_date "$SINCE_DATE" \
  --arg to_date "$TO_DATE" \
  --argjson repos_searched "${#REPO_LIST[@]}" \
  --argjson repos_with_commits "$REPOS_WITH_COMMITS" \
  --argjson prs "$PRS_JSON" \
  --argjson issues "$ISSUES_JSON" \
  --argjson commits "$COMMITS_JSON" \
  '{
    metadata: {
      days: $days,
      since_date: $since_date,
      to_date: $to_date,
      repos_searched: $repos_searched,
      repos_with_commits: $repos_with_commits
    },
    github: {
      prs: $prs,
      issues: $issues
    },
    commits: $commits
  }'
