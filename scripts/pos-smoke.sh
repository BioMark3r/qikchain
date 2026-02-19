#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/evm.sh"

require_tool
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

DEPLOYMENTS_FILE="${POS_DEPLOYMENTS_FILE:-$ROOT/build/deployments/pos.local.json}"
RPC_URL="$(evm_rpc_url)"

staking="$(jq -r '.staking.address // empty' "$DEPLOYMENTS_FILE")"
validator_set="$(jq -r '.validatorSet.address // empty' "$DEPLOYMENTS_FILE")"

for addr in "$staking" "$validator_set"; do
  [[ -n "$addr" ]] || { echo "missing deployed contract address" >&2; exit 1; }
  code="$(evm_get_code "$addr")"
  [[ "$code" != "0x" && "$code" != "0x0" ]] || { echo "no code at $addr" >&2; exit 1; }
done

echo "code exists at staking/validatorSet"

ops="$(evm_call "$staking" 'getActiveOperators()(address[])')"
count="$(echo "$ops" | tr -d '[] ' | awk -F',' 'NF{print NF; exit} !NF{print 0}')"
if (( count < 1 )); then
  echo "expected at least 1 active operator; got: $ops" >&2
  exit 1
fi

echo "active operators count >= 1 ($count)"

start_block="$(cast block-number --rpc-url "$RPC_URL")"
sleep 10
end_block="$(cast block-number --rpc-url "$RPC_URL")"
if (( end_block <= start_block )); then
  echo "block height did not increase ($start_block -> $end_block)" >&2
  exit 1
fi

echo "blocks increasing: $start_block -> $end_block"

peer_hex="$(cast rpc --rpc-url "$RPC_URL" net_peerCount)"
peer_count="$((peer_hex))"
expected="${EXPECTED_MIN_PEERS:-1}"
if (( peer_count < expected )); then
  echo "peer count too low: $peer_count < $expected" >&2
  exit 1
fi

echo "peer count ok: $peer_count"
