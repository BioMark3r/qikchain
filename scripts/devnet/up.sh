#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=scripts/devnet/common.sh
source "$ROOT/scripts/devnet/common.sh"

ensure_dirs

if [[ "${RESET:-0}" == "1" ]]; then
  exec "$ROOT/scripts/devnet/reset.sh"
fi

if [[ -f "$GENESIS_PATH" ]]; then
  log "Genesis already exists — skipping generation."
fi

if [[ -f "$DEVNET_PID" ]]; then
  existing_pid="$(read_pid_file || true)"
  if [[ -n "$existing_pid" ]] && is_pid_alive "$existing_pid"; then
    if health_check; then
      log "Devnet already running."
      exit 0
    fi
    log "PID $existing_pid is alive but health check failed; stopping existing process."
    "$ROOT/scripts/devnet/down.sh" || true
  else
    log "Found stale PID file at $DEVNET_PID — cleaning up."
    rm -f "$DEVNET_PID"
  fi
fi

if health_check; then
  log "RPC is already responsive at $RPC_URL, treating devnet as running."
  if [[ -f "$NET_DIR/node1/server.pid" ]]; then
    cp "$NET_DIR/node1/server.pid" "$DEVNET_PID"
  fi
  log "Devnet already running."
  exit 0
fi

log "Starting devnet..."
"$DEVNET_START_SCRIPT" >>"$DEVNET_LOG" 2>&1

if [[ -f "$NET_DIR/node1/server.pid" ]]; then
  cp "$NET_DIR/node1/server.pid" "$DEVNET_PID"
else
  log "Failed to locate node1 server PID file after startup."
  print_log_tail
  exit 1
fi

start_ts="$(date +%s)"
while true; do
  if health_check; then
    log "Devnet started successfully (PID $(read_pid_file))."
    exit 0
  fi

  now_ts="$(date +%s)"
  elapsed=$((now_ts - start_ts))
  if (( elapsed >= HEALTH_TIMEOUT_SECONDS )); then
    log "Health check failed: RPC did not become responsive within ${HEALTH_TIMEOUT_SECONDS}s."
    print_log_tail
    exit 1
  fi

  sleep "$HEALTH_INTERVAL_SECONDS"
done
