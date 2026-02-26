#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${HEALTHCHECK_RPC_URL:-http://127.0.0.1:${RPC_PORT:-8545}}"
STATE_DIR="${HEALTHCHECK_STATE_DIR:-/tmp}"
STATE_FILE="${STATE_DIR}/health-${NODE_NAME:-node}.block"

hex_to_dec() {
  printf '%d' "$((16#${1#0x}))"
}

resp="$(curl -fsS -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "$RPC_URL")"

block_hex="$(printf '%s' "$resp" | jq -r '.result // empty')"
[[ "$block_hex" =~ ^0x[0-9a-fA-F]+$ ]] || exit 1

current="$(hex_to_dec "$block_hex")"
if [[ -f "$STATE_FILE" ]]; then
  prev="$(cat "$STATE_FILE")"
  if (( current <= prev )); then
    exit 1
  fi
fi

mkdir -p "$STATE_DIR"
printf '%s' "$current" >"$STATE_FILE"
