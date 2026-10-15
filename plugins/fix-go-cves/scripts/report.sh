#!/usr/bin/env bash
# Scan a repository's current checkout without creating a branch or commit.
# Usage: report.sh [repo]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

[[ $# -le 1 ]] || die "Usage: report.sh [repo]"
preflight_check
use_upstream_goexperiment

STATE_FILE=$("$SCRIPT_DIR/detect.sh" "$@" | tail -1) || die "detect.sh failed"
[[ "$STATE_FILE" == */cve-fix-*/state.env ]] || die "unexpected state path: $STATE_FILE"
trap 'rm -rf -- "$(dirname "$STATE_FILE")"' EXIT
"$SCRIPT_DIR/scan.sh" "$STATE_FILE" --fresh
