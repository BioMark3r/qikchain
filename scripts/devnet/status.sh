#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=scripts/devnet/common.sh
source "$ROOT/scripts/devnet/common.sh"

ensure_dirs

if [[ ! -f "$DEVNET_PID" ]]; then
  log "Devnet not running."
  exit 1
fi

pid="$(read_pid_file || true)"
if [[ -z "$pid" ]] || ! is_pid_alive "$pid"; then
  log "Devnet not running."
  exit 1
fi

log "PID: $pid"

block_payload="$(rpc_request eth_blockNumber 2>/dev/null || true)"
peer_payload="$(rpc_request net_peerCount 2>/dev/null || true)"
block_result="$(rpc_result_field "$block_payload")"
peer_result="$(rpc_result_field "$peer_payload")"

if [[ -n "$block_result" ]]; then
  log "RPC reachable: yes ($RPC_URL)"
  log "eth_blockNumber: $block_result"
  if [[ -n "$peer_result" ]]; then
    log "net_peerCount: $peer_result"
  fi
  exit 0
fi

log "RPC reachable: no ($RPC_URL)"
print_log_tail
exit 1
