#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

[[ "$#" -eq 0 ]] || { echo "Unknown arguments: $*" >&2; exit 1; }

CONSENSUS="${CONSENSUS:-poa}"
ENVIRONMENT="${ENVIRONMENT:-devnet}"
CHAIN_ID="${CHAIN_ID:-}"
BLOCK_GAS_LIMIT="${BLOCK_GAS_LIMIT:-0x1c9c380}"
MIN_GAS_PRICE="${MIN_GAS_PRICE:-0}"
BASE_FEE_ENABLED="${BASE_FEE_ENABLED:-false}"
POS_DEPLOYMENTS_FILE="${POS_DEPLOYMENTS_FILE:-$ROOT/build/deployments/pos.local.json}"
ALLOCATIONS_FILE="${ALLOCATIONS_FILE:-$ROOT/config/allocations/${ENVIRONMENT}.json}"
TOKEN_FILE="${TOKEN_FILE:-$ROOT/config/token.json}"
QIKCHAIN_BIN="${QIKCHAIN_BIN:-$ROOT/bin/qikchain}"
CHAIN_OUT_FILE="${CHAIN_OUTPUT_FILE:-${OUTPUT_FILE:-$ROOT/build/chain.json}}"
GENESIS_OUT_FILE="${GENESIS_OUTPUT_FILE:-$ROOT/build/genesis-eth.json}"
META_OUT_FILE="${METADATA_FILE:-$ROOT/build/chain-metadata.json}"

[[ -x "$QIKCHAIN_BIN" ]] || { echo "qikchain binary not found or not executable: $QIKCHAIN_BIN" >&2; exit 1; }

cmd=("$QIKCHAIN_BIN" genesis build
  --consensus "$CONSENSUS"
  --env "$ENVIRONMENT"
  --token "$TOKEN_FILE"
  --allocations "$ALLOCATIONS_FILE"
  --block-gas-limit "$BLOCK_GAS_LIMIT"
  --min-gas-price "$MIN_GAS_PRICE"
  --base-fee-enabled "$BASE_FEE_ENABLED"
  --pos-deployments "$POS_DEPLOYMENTS_FILE"
  --out-chain "$CHAIN_OUT_FILE"
  --out-genesis "$GENESIS_OUT_FILE"
  --metadata-out "$META_OUT_FILE")

if [[ -n "$CHAIN_ID" ]]; then
  cmd+=(--chain-id "$CHAIN_ID")
fi

if [[ "$DRY_RUN" == "1" ]]; then
  cmd+=(--out-chain /tmp/qikchain.chain.dryrun.json --out-genesis /tmp/qikchain.genesis-eth.dryrun.json --metadata-out /tmp/qikchain.meta.dryrun.json)
fi

"${cmd[@]}"

if [[ "$DRY_RUN" == "1" ]]; then
  cat /tmp/qikchain.chain.dryrun.json
  cat /tmp/qikchain.genesis-eth.dryrun.json
fi
