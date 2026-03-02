#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
GENESIS_PATH="${GENESIS_PATH:-$BUILD_DIR/genesis.json}"
DATA_ROOT="${DATA_ROOT:-$ROOT/.data}"
NET_DIR="${NET_DIR:-$DATA_ROOT/ibft4}"
LOG_DIR="${LOG_DIR:-$ROOT/.logs}"
PID_DIR="${PID_DIR:-$ROOT/.pids}"

DEVNET_LOG="${DEVNET_LOG:-$LOG_DIR/devnet.log}"
DEVNET_PID="${DEVNET_PID:-$PID_DIR/devnet.pid}"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-30}"
HEALTH_INTERVAL_SECONDS="${HEALTH_INTERVAL_SECONDS:-1}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-50}"

DEVNET_START_SCRIPT="${DEVNET_START_SCRIPT:-$ROOT/scripts/devnet-ibft4.sh}"
DEVNET_STOP_SCRIPT="${DEVNET_STOP_SCRIPT:-$ROOT/scripts/devnet-ibft4-stop.sh}"

log() {
  echo "[devnet] $*"
}

ensure_dirs() {
  mkdir -p "$BUILD_DIR" "$DATA_ROOT" "$NET_DIR" "$LOG_DIR" "$PID_DIR"
}

is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

read_pid_file() {
  if [[ -f "$DEVNET_PID" ]]; then
    tr -d '[:space:]' <"$DEVNET_PID"
  fi
}

rpc_request() {
  local method="$1"
  curl -sS -X POST \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":[],\"id\":1}" \
    "$RPC_URL"
}

rpc_result_field() {
  local payload="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.result // empty' <<<"$payload" 2>/dev/null || true
  else
    sed -nE 's/.*"result"[[:space:]]*:[[:space:]]*"?([^",}]+)"?.*/\1/p' <<<"$payload" | head -n1
  fi
}

health_check() {
  local payload
  payload="$(rpc_request eth_blockNumber 2>/dev/null || true)"
  local result
  result="$(rpc_result_field "$payload")"
  [[ -n "$result" ]]
}

print_log_tail() {
  if [[ -f "$DEVNET_LOG" ]]; then
    echo "----- last ${LOG_TAIL_LINES} lines from $DEVNET_LOG -----"
    tail -n "$LOG_TAIL_LINES" "$DEVNET_LOG" || true
    echo "----- end devnet log -----"
  else
    echo "No devnet log found at $DEVNET_LOG"
  fi
}

assert_safe_path_for_delete() {
  local target="$1"
  local target_abs
  target_abs="$(realpath -m "$target")"
  local root_abs
  root_abs="$(realpath -m "$ROOT")"

  if [[ -z "$target_abs" || "$target_abs" == "/" ]]; then
    echo "ERROR: refusing to delete unsafe path: '$target'"
    exit 1
  fi

  if [[ "$target_abs" != "$root_abs"/* ]]; then
    echo "ERROR: refusing to delete path outside repo root: '$target_abs'"
    exit 1
  fi
}
