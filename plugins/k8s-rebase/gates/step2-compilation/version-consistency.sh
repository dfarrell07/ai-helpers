#!/bin/bash
# Gate companion: version-consistency — check k8s.io/* versions match target.
# Usage: bash version-consistency.sh <repo-path>

source "$(dirname "$0")/../../scripts/gate-script-lib.sh"
init_gate "$@"

details=()

TARGET=""
if [[ -f "$REPO/.rebase-tmp/target-k8s-api-version.txt" ]]; then
  TARGET=$(tr -d '[:space:]' < "$REPO/.rebase-tmp/target-k8s-api-version.txt")
  echo "TARGET_VERSION: $TARGET"
fi

for gomod in $(find . -name "go.mod" -not -path "*/vendor/*" | sort); do
  mod_dir=$(dirname "$gomod")
  echo "CHECK $mod_dir/go.mod"

  while read -r mod ver; do
    [[ -z "$mod" || -z "$ver" ]] && continue

    if [[ -n "$TARGET" && "$ver" != "$TARGET" ]]; then
      echo "  MISMATCH: $mod $ver (expected $TARGET)"
      details+=("MISMATCH: $mod_dir: $mod at $ver, expected $TARGET")
      inc NEW_ISSUES
    fi
  done < <(grep 'k8s.io/' "$gomod" | grep -v '^\s*//' | grep -v 'replace' | grep -v '=>' | \
            grep -E '^\s' | awk '{print $1, $2}')

  if [[ -d "$mod_dir/vendor" ]]; then
    verify_out=$(cd "$mod_dir" && go mod verify 2>&1) || true
    if [[ "$verify_out" =~ FAIL|modified ]]; then
      echo "  VENDOR-DRIFT: $mod_dir"
      details+=("VENDOR-DRIFT: $mod_dir: vendor drift detected by go mod verify")
      inc NEW_ISSUES
    fi
  fi
done

finish_evidence "$NEW_ISSUES version inconsistencies" "${details[@]}"
