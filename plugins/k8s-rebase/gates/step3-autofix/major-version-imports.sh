#!/bin/bash
# Gate script: major-version-imports pre-existing check
# Finds bare imports where a /vN version exists in go.mod.
# Usage: bash major-version-imports.sh <repo-path>

set -uo pipefail
repo="${1:-.}"
cd "$repo" || exit 1

BASE=$(git merge-base HEAD master 2>/dev/null || git merge-base HEAD main 2>/dev/null)
new=0 pre=0

# Mandatory klog v1 check
klog_hits=$(grep -rn '"k8s.io/klog"' --include='*.go' . 2>/dev/null | grep -v vendor/ | grep -v .cache/ | grep -v '/v2' || true)
if [[ -n "$klog_hits" ]]; then
  while IFS= read -r hit; do
    file=$(echo "$hit" | cut -d: -f1)
    if [[ -n "$BASE" ]]; then
      base_has=$(git show "$BASE:$file" 2>/dev/null | grep -c '"k8s.io/klog"' || true)
      if [[ "$base_has" -gt 0 ]]; then
        echo "$hit PRE-EXISTING"
        pre=$((pre + 1))
      else
        echo "$hit NEW"
        new=$((new + 1))
      fi
    else
      echo "$hit NEW (no base)"
      new=$((new + 1))
    fi
  done <<< "$klog_hits"
fi

# Generic major-version check from go.mod
PRIMARY_GOMOD=$(find . -name "go.mod" -not -path "*/vendor/*" -not -path "*/.claude/*" -exec grep -l "k8s.io/" {} \; 2>/dev/null | head -1)
if [[ -n "$PRIMARY_GOMOD" ]]; then
  for mod in $(grep -oP 'k8s\.io/[a-zA-Z0-9_-]+/v\d+' "$PRIMARY_GOMOD" 2>/dev/null | sed 's|/v[0-9]*$||' | sort -u); do
    bare_hits=$(grep -rn "\"$mod\"" --include='*.go' . 2>/dev/null | grep -v vendor/ | grep -v "${mod}/v" || true)
    if [[ -n "$bare_hits" ]]; then
      while IFS= read -r hit; do
        file=$(echo "$hit" | cut -d: -f1)
        if [[ -n "$BASE" ]]; then
          base_has=$(git show "$BASE:$file" 2>/dev/null | grep -c "\"$mod\"" || true)
          [[ "$base_has" -gt 0 ]] && { echo "$hit PRE-EXISTING ($mod)"; pre=$((pre+1)); } \
            || { echo "$hit NEW ($mod)"; new=$((new+1)); }
        else
          echo "$hit NEW ($mod, no base)"
          new=$((new + 1))
        fi
      done <<< "$bare_hits"
    fi
  done
fi

echo ""
echo "NEW_ISSUES=$new"
echo "PRE_EXISTING=$pre"
