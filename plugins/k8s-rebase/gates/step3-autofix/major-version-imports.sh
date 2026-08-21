#!/bin/bash
# Gate companion: major-version-imports — check for stale v1 imports.
# Usage: bash major-version-imports.sh <repo-path>

source "$(dirname "$0")/../../scripts/gate-script-lib.sh"
init_gate "$@"

details=()

check_import() {
  local bare="$1" versioned="$2"
  local hits
  hits=$(grep -rn "\"$bare\"" --include='*.go' . 2>/dev/null \
    | grep -v vendor/ | grep -v '.cache/' | grep -v "/$versioned" || true)

  if [[ -z "$hits" ]]; then
    echo "CLEAN: no bare $bare imports"
    return
  fi

  # Per-file count-delta: track how many base occurrences remain to absorb as PRE-EXISTING.
  # Avoids the binary base_file_has test that marked all current hits PRE-EXISTING if even
  # one existed before the rebase.
  declare -A _bc
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    file="${match%%:*}"
    if [[ -n "$BASE" ]] && [[ -z "${_bc[$file]+set}" ]]; then
      _bc[$file]=$(git show "$BASE:$file" 2>/dev/null | grep -cF "\"$bare\"" || echo 0)
    fi
    local bc=${_bc[$file]:-0}
    if [[ $bc -gt 0 ]]; then
      echo "  PRE-EXISTING: $match"
      _bc[$file]=$(( bc - 1 ))
    else
      echo "  NEW: $match"
      details+=("$match (should be $bare/$versioned)")
      inc NEW_ISSUES
    fi
  done <<< "$hits"
}

check_import "k8s.io/klog" "v2"

if grep -q 'sigs.k8s.io/controller-runtime/v2' go.mod 2>/dev/null; then
  check_import "sigs.k8s.io/controller-runtime" "v2"
fi

versioned_mods=$(grep -E '/v[0-9]+' go.mod 2>/dev/null | grep -v '^\s*//' | \
  sed -n 's|.*[[:space:]]\([a-z][a-z0-9._/-]*/v[0-9]\+\)[[:space:]].*|\1|p' | sort -u || true)
for vmod in $versioned_mods; do
  bare="${vmod%/v[0-9]*}"
  [[ "$bare" == "k8s.io/klog" ]] && continue
  hits=$(grep -rn "\"$bare\"" --include='*.go' . 2>/dev/null \
    | grep -v vendor/ | grep -v '.cache/' | grep -v "/$vmod" | head -5 || true)
  if [[ -n "$hits" ]]; then
    unset _bc; declare -A _bc
    while IFS= read -r match; do
      file="${match%%:*}"
      if [[ -n "$BASE" ]] && [[ -z "${_bc[$file]+set}" ]]; then
        _bc[$file]=$(git show "$BASE:$file" 2>/dev/null | grep -cF "\"$bare\"" || echo 0)
      fi
      bc=${_bc[$file]:-0}
      if [[ $bc -gt 0 ]]; then
        echo "  PRE-EXISTING: $match"
        _bc[$file]=$(( bc - 1 ))
      else
        echo "  NEW: $match"
        details+=("$match (should use $vmod)")
        inc NEW_ISSUES
      fi
    done <<< "$hits"
  fi
done

finish_evidence "$NEW_ISSUES stale major-version imports" "${details[@]}"
