#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

source "$ROOT/scripts/lib/genesis.sh"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

[[ "$#" -eq 0 ]] || die "Unknown arguments: $*"

require_cmd jq
require_cmd python3

CONSENSUS="${CONSENSUS:-poa}"
CHAIN_ID="${CHAIN_ID:-51001}"
BLOCK_GAS_LIMIT="${BLOCK_GAS_LIMIT:-0x1c9c380}"
MIN_GAS_PRICE="${MIN_GAS_PRICE:-0}"
BASE_FEE_ENABLED="${BASE_FEE_ENABLED:-false}"
POS_BLOCK_REWARD="${POS_BLOCK_REWARD:-0x0}"

VALIDATORS_DIR="${VALIDATORS_DIR:-/data/validators}"
ALLOCATIONS_FILE="${ALLOCATIONS_FILE:-$ROOT/config/allocations.json}"
TREASURY_ADDRESS="${TREASURY_ADDRESS:-0x1000000000000000000000000000000000000001}"
FAUCET_ADDRESS="${FAUCET_ADDRESS:-0x1000000000000000000000000000000000000002}"

TREASURY_ADDRESS="$(normalize_address "$TREASURY_ADDRESS")"
FAUCET_ADDRESS="$(normalize_address "$FAUCET_ADDRESS")"

TEMPLATE_FILE="$ROOT/config/genesis.template.json"
OVERLAY_FILE="$ROOT/config/consensus/${CONSENSUS}.json"
OUTPUT_FILE="$ROOT/build/genesis.json"

[[ -f "$TEMPLATE_FILE" ]] || die "Template file not found: $TEMPLATE_FILE"
[[ -f "$OVERLAY_FILE" ]] || die "Consensus overlay not found for CONSENSUS=$CONSENSUS"
[[ -f "$ALLOCATIONS_FILE" ]] || die "Allocations file not found: $ALLOCATIONS_FILE"

load_validators "$VALIDATORS_DIR"
VALIDATOR_EXTRA_DATA="$(build_ibft_extra_data)"

TREASURY_AMOUNT="$(load_allocation_amount treasury "$ALLOCATIONS_FILE")"
VALIDATOR_AMOUNT="$(load_allocation_amount validators "$ALLOCATIONS_FILE")"
FAUCET_AMOUNT="$(load_allocation_amount faucet "$ALLOCATIONS_FILE")"

[[ "$TREASURY_AMOUNT" != "null" ]] || die "Missing 'treasury' key in $ALLOCATIONS_FILE"
[[ "$VALIDATOR_AMOUNT" != "null" ]] || die "Missing 'validators' key in $ALLOCATIONS_FILE"
[[ "$FAUCET_AMOUNT" != "null" ]] || die "Missing 'faucet' key in $ALLOCATIONS_FILE"

PREALLOCATIONS="$(build_allocations_json "$ALLOCATIONS_FILE" "$VALIDATOR_AMOUNT" "$TREASURY_AMOUNT" "$FAUCET_AMOUNT" "$TREASURY_ADDRESS" "$FAUCET_ADDRESS")"

TEMPLATE_RENDERED="$(render_template \
  "$TEMPLATE_FILE" \
  "$CHAIN_ID" \
  "$BLOCK_GAS_LIMIT" \
  "$MIN_GAS_PRICE" \
  "$BASE_FEE_ENABLED" \
  "$VALIDATOR_EXTRA_DATA" \
  "$PREALLOCATIONS")"

OVERLAY_RENDERED="$(python3 - "$OVERLAY_FILE" "$POS_BLOCK_REWARD" <<'PY'
import pathlib
import sys

overlay = pathlib.Path(sys.argv[1]).read_text()
overlay = overlay.replace("{{POS_BLOCK_REWARD}}", sys.argv[2])
print(overlay)
PY
)"

GENESIS_JSON="$(jq -S -s '.[0] * .[1]' <(printf '%s\n' "$TEMPLATE_RENDERED") <(printf '%s\n' "$OVERLAY_RENDERED"))"

printf '%s\n' "$GENESIS_JSON" | jq empty >/dev/null

if [[ "$DRY_RUN" == "1" ]]; then
  log "Dry-run enabled. Consensus mode: $CONSENSUS"
  printf '%s\n' "$GENESIS_JSON"
  exit 0
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '%s\n' "$GENESIS_JSON" > "$OUTPUT_FILE"
log "Genesis written to $OUTPUT_FILE"
