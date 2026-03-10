#!/bin/bash
set -euo pipefail

# Parse arguments
DAYS="${1:-7}"

# Validate days is a number
if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "Error: Days must be a number (got: $DAYS)" >&2
  exit 1
fi

SINCE_DATE=$(date -d "$DAYS days ago" +%Y-%m-%d 2>/dev/null || date -v-"${DAYS}"d +%Y-%m-%d)
AUTHOR_EMAIL=$(git config user.email 2>/dev/null || echo "")

echo "# Work Summary: Last $DAYS Days"
echo ""
echo "**Period:** $SINCE_DATE to $(date +%Y-%m-%d)"
echo ""

# Helper function for GitHub queries
gh_activity() {
  local type=$1
  local title=$2
  local user=$3
  local since=$4

  echo "### $title"

  local output
  # jq's string comparison operator >= works for ISO 8601 timestamps
  # (2026-03-10T15:30:00Z) when comparing with YYYY-MM-DD format
  # Use 'gh search' instead of 'gh list' to search across all repositories
  output=$(gh search "$type" --author="$user" --limit 50 \
    --json number,title,repository,state,updatedAt,url \
    --jq ".[] | select(.updatedAt >= \"$since\") | \"- [\(.repository.nameWithOwner)#\(.number)](\(.url)) \(.title) (\(.state))\"" \
    2>/dev/null || true)

  [[ -n "$output" ]] && echo "$output" || echo "None"
  echo ""
}

# GitHub Activity
if command -v gh &>/dev/null && gh auth status &>/dev/null; then
  GH_USER=$(gh api user --jq .login 2>/dev/null || echo "")

  if [[ -n "$GH_USER" ]]; then
    echo "## GitHub Activity"
    echo ""

    gh_activity prs "Pull Requests" "$GH_USER" "$SINCE_DATE"
    gh_activity issues "Issues" "$GH_USER" "$SINCE_DATE"
  else
    echo "## GitHub Activity"
    echo ""
    echo "Error: Unable to fetch GitHub user information"
    echo ""
  fi
fi

# Git Commits from common repos
echo "## Recent Commits"
echo ""

if [[ -z "$AUTHOR_EMAIL" ]]; then
  echo "Error: No git user.email configured - skipping git commits"
  exit 0
fi

# Discover repos using dual data structures for efficient deduplication:
# - Associative array (SEEN_REPOS) provides O(1) lookup to check if repo already seen
# - Indexed array (REPO_LIST) preserves discovery order for consistent output
declare -A SEEN_REPOS
REPO_LIST=()

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

# Show commits from each repo
if [[ ${#REPO_LIST[@]} -eq 0 ]]; then
  echo "No repositories found"
else
  # Collect all commits first
  COMMITS_OUTPUT=""
  REPOS_WITH_COMMITS=0

  for repo_path in "${REPO_LIST[@]}"; do
    commits=$(git -C "$repo_path" log --author="$AUTHOR_EMAIL" --since="$SINCE_DATE" --oneline 2>/dev/null || true)

    if [[ -n "$commits" ]]; then
      REPOS_WITH_COMMITS=$((REPOS_WITH_COMMITS + 1))
      COMMITS_OUTPUT+="### $(basename "$repo_path")"$'\n'
      COMMITS_OUTPUT+='```'$'\n'
      COMMITS_OUTPUT+="$commits"$'\n'
      COMMITS_OUTPUT+='```'$'\n\n'
    fi
  done

  # Show summary
  echo "**Searched ${#REPO_LIST[@]} repositories, found commits in $REPOS_WITH_COMMITS**"
  echo ""

  # Show commits or message
  if [[ $REPOS_WITH_COMMITS -eq 0 ]]; then
    echo "No commits found in the last $DAYS days"
  else
    echo -n "$COMMITS_OUTPUT"
  fi
fi
