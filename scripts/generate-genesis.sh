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
POS_DEPLOYMENTS_FILE="${POS_DEPLOYMENTS_FILE:-$ROOT/build/deployments/pos.local.json}"

VALIDATORS_DIR="${VALIDATORS_DIR:-/data/validators}"
ALLOCATIONS_FILE="${ALLOCATIONS_FILE:-$ROOT/config/allocations/devnet.json}"
TOKEN_FILE="${TOKEN_FILE:-$ROOT/config/token.json}"

QIKCHAIN_BIN="${QIKCHAIN_BIN:-$ROOT/bin/qikchain}"

TEMPLATE_FILE="$ROOT/config/genesis.template.json"
OVERLAY_FILE="$ROOT/config/consensus/${CONSENSUS}.json"
OUTPUT_FILE="$ROOT/build/genesis.json"

[[ -x "$QIKCHAIN_BIN" ]] || die "qikchain binary not found or not executable: $QIKCHAIN_BIN"
[[ -f "$TEMPLATE_FILE" ]] || die "Template file not found: $TEMPLATE_FILE"
[[ -f "$OVERLAY_FILE" ]] || die "Consensus overlay not found for CONSENSUS=$CONSENSUS"
[[ -f "$ALLOCATIONS_FILE" ]] || die "Allocations file not found: $ALLOCATIONS_FILE"
[[ -f "$TOKEN_FILE" ]] || die "Token file not found: $TOKEN_FILE"

load_validators "$VALIDATORS_DIR"
VALIDATOR_EXTRA_DATA="$(build_ibft_extra_data)"

"$QIKCHAIN_BIN" allocations verify --file "$ALLOCATIONS_FILE"
PREALLOCATIONS="$("$QIKCHAIN_BIN" allocations render --file "$ALLOCATIONS_FILE")"
"$QIKCHAIN_BIN" chain metadata --token "$TOKEN_FILE" --out "$ROOT/build/chain-metadata.json"

TEMPLATE_RENDERED="$(render_template \
  "$TEMPLATE_FILE" \
  "$CHAIN_ID" \
  "$BLOCK_GAS_LIMIT" \
  "$MIN_GAS_PRICE" \
  "$BASE_FEE_ENABLED" \
  "$VALIDATOR_EXTRA_DATA" \
  "$PREALLOCATIONS")"

POS_STAKING_ADDRESS="{{STAKING_ADDRESS}}"
POS_VALIDATOR_SET_ADDRESS="{{VALIDATOR_SET_ADDRESS}}"
if [[ "$CONSENSUS" == "pos" ]]; then
  if [[ -f "$POS_DEPLOYMENTS_FILE" ]]; then
    POS_STAKING_ADDRESS="$(jq -r '.staking.address // "{{STAKING_ADDRESS}}"' "$POS_DEPLOYMENTS_FILE")"
    POS_VALIDATOR_SET_ADDRESS="$(jq -r '.validatorSet.address // "{{VALIDATOR_SET_ADDRESS}}"' "$POS_DEPLOYMENTS_FILE")"
  fi

  if [[ "$POS_STAKING_ADDRESS" == "{{STAKING_ADDRESS}}" || "$POS_VALIDATOR_SET_ADDRESS" == "{{VALIDATOR_SET_ADDRESS}}" ]]; then
    log "WARNING: PoS deployment addresses are unresolved. Run ./scripts/deploy-pos-contracts.sh before locking final genesis."
  fi

  PHASE1_REWARDS="$(jq -r '.phase1PosRewards' "$TOKEN_FILE")"
  [[ "$PHASE1_REWARDS" == "0" ]] || die "Phase 1 PoS rewards must be 0, got: $PHASE1_REWARDS"
  POS_BLOCK_REWARD="0x0"
fi

OVERLAY_RENDERED="$(python3 - "$OVERLAY_FILE" "$POS_BLOCK_REWARD" "$POS_STAKING_ADDRESS" "$POS_VALIDATOR_SET_ADDRESS" <<'PY'
import pathlib
import sys

overlay = pathlib.Path(sys.argv[1]).read_text()
overlay = overlay.replace("{{POS_BLOCK_REWARD}}", sys.argv[2])
overlay = overlay.replace("{{STAKING_ADDRESS}}", sys.argv[3])
overlay = overlay.replace("{{VALIDATOR_SET_ADDRESS}}", sys.argv[4])
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
