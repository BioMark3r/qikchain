#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=scripts/devnet/common.sh
source "$ROOT/scripts/devnet/common.sh"

ensure_dirs

if [[ -f "$DEVNET_PID" ]]; then
  pid="$(read_pid_file || true)"
  if [[ -n "$pid" ]] && is_pid_alive "$pid"; then
    log "Stopping devnet process $pid with SIGTERM"
    kill "$pid" 2>/dev/null || true

    for _ in {1..20}; do
      if ! is_pid_alive "$pid"; then
        break
      fi
      sleep 0.5
    done

    if is_pid_alive "$pid"; then
      log "Process $pid still alive, sending SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
    fi
  else
    log "PID file exists but process is not running (stale PID)."
  fi
else
  log "No devnet PID file found."
fi

"$DEVNET_STOP_SCRIPT" >/dev/null 2>&1 || true

if [[ -f "$DEVNET_PID" ]]; then
  pid="$(read_pid_file || true)"
  if [[ -z "$pid" ]] || ! is_pid_alive "$pid"; then
    rm -f "$DEVNET_PID"
  fi
fi

if [[ -f "$DEVNET_PID" ]]; then
  log "Devnet did not stop cleanly (pid file still present)."
  exit 1
fi

log "Devnet stopped."
