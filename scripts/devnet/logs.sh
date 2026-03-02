#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=scripts/devnet/common.sh
source "$ROOT/scripts/devnet/common.sh"

ensure_dirs
lines="${LINES:-50}"
if [[ "${FOLLOW:-0}" == "1" ]]; then
  touch "$DEVNET_LOG"
  tail -n "$lines" -f "$DEVNET_LOG"
else
  if [[ -f "$DEVNET_LOG" ]]; then
    tail -n "$lines" "$DEVNET_LOG"
  else
    log "No log file found at $DEVNET_LOG"
  fi
fi
