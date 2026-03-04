#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
RPC_TIMEOUT_SECONDS="${RPC_TIMEOUT_SECONDS:-120}"
RPC_POLL_INTERVAL_SECONDS="${RPC_POLL_INTERVAL_SECONDS:-2}"
UI_URL="${UI_URL:-http://127.0.0.1:8788}"
UI_TIMEOUT_SECONDS="${UI_TIMEOUT_SECONDS:-60}"

has_make_target() {
  make -qp | awk -F: '/^[[:alnum:]_.-]+:/{print $1}' | grep -Fx "$1" >/dev/null 2>&1
}

extract_result() {
  sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

cleanup() {
  set +e
  if has_make_target "faucet-down"; then
    make faucet-down >/dev/null 2>&1 || true
  elif has_make_target "faucet-stop"; then
    make faucet-stop >/dev/null 2>&1 || true
  fi

  if has_make_target "stop-ui"; then
    make stop-ui >/dev/null 2>&1 || true
  fi

  make down >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Starting devnet with RESET=1"
make down >/dev/null 2>&1 || true
make up RESET=1

echo "==> Waiting for JSON-RPC at $RPC_URL"
rpc_deadline=$((SECONDS + RPC_TIMEOUT_SECONDS))
block_number=""
while true; do
  response="$(curl -fsS -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$RPC_URL" 2>/dev/null || true)"
  block_number="$(printf '%s' "$response" | extract_result | head -n1)"

  if [ -n "$block_number" ]; then
    break
  fi

  if [ "$SECONDS" -ge "$rpc_deadline" ]; then
    echo "Timed out waiting for JSON-RPC at $RPC_URL" >&2
    exit 1
  fi

  sleep "$RPC_POLL_INTERVAL_SECONDS"
done
echo "eth_blockNumber=$block_number"

peer_response="$(curl -fsS -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":2}' \
  "$RPC_URL")"
peer_count="$(printf '%s' "$peer_response" | extract_result | head -n1)"
if [ -z "$peer_count" ]; then
  echo "net_peerCount returned an empty result" >&2
  exit 1
fi
echo "net_peerCount=$peer_count"

if has_make_target "status-ui"; then
  echo "==> status-ui target detected, starting optional UI"
  ui_port="$(printf '%s' "$UI_URL" | sed -n 's#http://[^:]*:\([0-9][0-9]*\).*#\1#p')"
  if [ -z "$ui_port" ]; then
    ui_port=8788
  fi
  STATUS_UI_HOST=127.0.0.1 STATUS_UI_PORT="$ui_port" make status-ui

  ui_deadline=$((SECONDS + UI_TIMEOUT_SECONDS))
  while true; do
    if curl -fsS "$UI_URL" >/dev/null 2>&1; then
      echo "status-ui reachable at $UI_URL"
      break
    fi

    if [ "$SECONDS" -ge "$ui_deadline" ]; then
      echo "Timed out waiting for UI at $UI_URL" >&2
      exit 1
    fi

    sleep 2
  done
fi

if [ -n "${FAUCET_PRIVATE_KEY:-}" ] && has_make_target "faucet-up"; then
  echo "==> FAUCET_PRIVATE_KEY set and faucet-up target detected, starting faucet"
  make faucet-up
fi

echo "Integration checks passed"
