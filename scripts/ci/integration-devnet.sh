#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Entry point selection notes:
# 1) If a Make target named `devnet` exists, run that.
# 2) Else if scripts/devnet.sh exists, run it.
# 3) Else prefer scripts/devnet-ibft4.sh (repo's primary devnet runner),
#    then scripts/run-devnet.sh, then scripts/start-devnet.sh.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LOG_DIR="$ROOT/.ci-logs"
DEVNET_LOG="$LOG_DIR/devnet.out"
mkdir -p "$LOG_DIR"
: > "$DEVNET_LOG"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
CI_FUNDER_PRIVKEY="${CI_FUNDER_PRIVKEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
export CI_FUNDER_PRIVKEY

DOCKER_DEVNET="${DOCKER_DEVNET:-0}"
START_CMD=()
STOP_CMD=()
if [[ "$DOCKER_DEVNET" == "1" ]]; then
  START_CMD=(make docker-devnet-up)
  STOP_CMD=(make docker-devnet-down RESET=1)
elif make -qp | awk -F: '/^[[:alnum:]_.-]+:/{print $1}' | rg -x 'devnet' >/dev/null 2>&1; then
  START_CMD=(make devnet)
  STOP_CMD=(make down)
elif [[ -x "$ROOT/scripts/devnet.sh" ]]; then
  START_CMD=(bash "$ROOT/scripts/devnet.sh")
  STOP_CMD=(bash "$ROOT/scripts/devnet-ibft4-stop.sh")
elif [[ -x "$ROOT/scripts/devnet-ibft4.sh" ]]; then
  START_CMD=(bash "$ROOT/scripts/devnet-ibft4.sh")
  STOP_CMD=(bash "$ROOT/scripts/devnet-ibft4-stop.sh")
elif [[ -x "$ROOT/scripts/run-devnet.sh" ]]; then
  START_CMD=(bash "$ROOT/scripts/run-devnet.sh")
  STOP_CMD=(bash "$ROOT/scripts/devnet-ibft4-stop.sh")
elif [[ -x "$ROOT/scripts/start-devnet.sh" ]]; then
  START_CMD=(bash "$ROOT/scripts/start-devnet.sh")
  STOP_CMD=(bash "$ROOT/scripts/devnet-ibft4-stop.sh")
else
  echo "ERROR: could not find a devnet entry point (make devnet / scripts/devnet*.sh)" >&2
  exit 1
fi

cleanup() {
  set +e
  echo "[cleanup] stopping devnet" | tee -a "$DEVNET_LOG"
  if ((${#STOP_CMD[@]} > 0)); then
    "${STOP_CMD[@]}" >>"$DEVNET_LOG" 2>&1 || true
  fi
}
trap cleanup EXIT

echo "[integration] starting devnet (DOCKER_DEVNET=$DOCKER_DEVNET): ${START_CMD[*]}" | tee -a "$DEVNET_LOG"
"${START_CMD[@]}" >>"$DEVNET_LOG" 2>&1 || {
  echo "ERROR: devnet failed to start" >&2
  tail -n 200 "$DEVNET_LOG" >&2 || true
  exit 1
}

eth_block_number() {
  curl -fsS -H 'content-type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$RPC_URL" | jq -r '.result'
}

echo "[integration] waiting for RPC readiness on $RPC_URL"
block_hex=""
for _ in $(seq 1 60); do
  if block_hex="$(eth_block_number 2>/dev/null)" && [[ "$block_hex" =~ ^0x[0-9a-fA-F]+$ ]]; then
    echo "[integration] RPC ready, blockNumber=$block_hex"
    break
  fi
  sleep 1
done
if [[ -z "$block_hex" || ! "$block_hex" =~ ^0x[0-9a-fA-F]+$ ]]; then
  echo "ERROR: RPC did not become ready within 60s" >&2
  tail -n 200 "$DEVNET_LOG" >&2 || true
  exit 1
fi

first_hex="$(eth_block_number)"
sleep 3
second_hex="$(eth_block_number)"
first_dec=$((first_hex))
second_dec=$((second_hex))
if (( second_dec <= first_dec )); then
  echo "ERROR: blocks are not sealing (blockNumber stuck at $first_hex -> $second_hex)" >&2
  tail -n 200 "$DEVNET_LOG" >&2 || true
  exit 1
fi
echo "[integration] sealing confirmed: $first_hex -> $second_hex"

echo "[integration] running tx smoke test"
if ! go run ./cmd/txsmoke --rpc "$RPC_URL" --timeout 45s; then
  echo "ERROR: tx smoke test failed" >&2
  tail -n 200 "$DEVNET_LOG" >&2 || true
  exit 1
fi

echo "[integration] success"
