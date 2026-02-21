#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/app}"
BUILD_DIR="${BUILD_DIR:-$APP_DIR/build}"
EDGE_BIN="${EDGE_BIN:-$APP_DIR/bin/polygon-edge}"
QIKCHAIN_BIN="${QIKCHAIN_BIN:-$APP_DIR/bin/qikchain}"

NODE_NAME="${NODE_NAME:-node1}"
NODE_HOSTNAME="${NODE_HOSTNAME:-$NODE_NAME}"

RPC_PORT="${RPC_PORT:-8545}"
GRPC_PORT="${GRPC_PORT:-9632}"
P2P_PORT="${P2P_PORT:-1478}"
METRICS_PORT="${METRICS_PORT:-9090}"

CONSENSUS="${CONSENSUS:-poa}"
ENV_NAME="${ENV_NAME:-devnet}"
CHAIN_ID="${CHAIN_ID:-100}"
BLOCK_GAS_LIMIT="${BLOCK_GAS_LIMIT:-15000000}"
MIN_GAS_PRICE="${MIN_GAS_PRICE:-0}"
BASE_FEE_ENABLED="${BASE_FEE_ENABLED:-false}"
INSECURE_SECRETS="${INSECURE_SECRETS:-1}"

ALLOCATIONS_FILE="${ALLOCATIONS_FILE:-$APP_DIR/config/allocations/devnet.json}"
TOKEN_FILE="${TOKEN_FILE:-$APP_DIR/config/token.json}"
POS_DEPLOYMENTS="${POS_DEPLOYMENTS:-$APP_DIR/build/deployments/pos.local.json}"

CHAIN_OUT="$BUILD_DIR/chain.json"
COMBINED_OUT="$BUILD_DIR/genesis.json"
GENESIS_OUT="$BUILD_DIR/genesis-eth.json"
METADATA_OUT="$BUILD_DIR/chain-metadata.json"
BOOTNODE_FILE="$BUILD_DIR/node1.bootnode"

NODE_DATA_DIR="${NODE_DATA_DIR:-/data/$NODE_NAME}"
SECRETS_DIR="$NODE_DATA_DIR/secrets"

log() {
  echo "[$(date +"%H:%M:%S")] [$NODE_NAME] $*"
}

require_bin() {
  local bin="$1"
  if [[ ! -x "$bin" ]]; then
    echo "Missing executable: $bin" >&2
    exit 1
  fi
}

wait_for_file() {
  local file="$1"
  local timeout="${2:-120}"
  local waited=0

  until [[ -f "$file" ]]; do
    sleep 1
    waited=$((waited + 1))
    if (( waited >= timeout )); then
      echo "Timed out waiting for $file" >&2
      exit 1
    fi
  done
}

ensure_secrets() {
  if [[ -d "$SECRETS_DIR" && -f "$SECRETS_DIR/consensus/key" ]]; then
    return 0
  fi

  mkdir -p "$SECRETS_DIR"
  if [[ "$INSECURE_SECRETS" == "1" ]]; then
    "$EDGE_BIN" secrets init --data-dir "$SECRETS_DIR" --insecure >/dev/null
  else
    "$EDGE_BIN" secrets init --data-dir "$SECRETS_DIR" >/dev/null
  fi
}

extract_peer_id() {
  local output peer_id
  output="$("$EDGE_BIN" secrets output --data-dir "$SECRETS_DIR" 2>/dev/null || true)"
  peer_id="$(echo "$output" | sed -nE 's/.*(Node ID:|node id:|Peer ID:|peer id:)\s*([A-Za-z0-9]+).*/\2/p' | head -n1)"
  echo "$peer_id"
}

build_genesis_if_node1() {
  if [[ "$NODE_NAME" != "node1" ]]; then
    return 0
  fi

  mkdir -p "$BUILD_DIR"

  if [[ -f "$COMBINED_OUT" && -f "$CHAIN_OUT" && -f "$GENESIS_OUT" ]]; then
    log "Genesis artifacts already exist in $BUILD_DIR"
    return 0
  fi

  log "Generating genesis artifacts in $BUILD_DIR"
  local build_args=(
    genesis build
    --consensus "$CONSENSUS"
    --env "$ENV_NAME"
    --chain-id "$CHAIN_ID"
    --block-gas-limit "$BLOCK_GAS_LIMIT"
    --min-gas-price "$MIN_GAS_PRICE"
    --base-fee-enabled "$BASE_FEE_ENABLED"
    --allocations "$ALLOCATIONS_FILE"
    --token "$TOKEN_FILE"
    --out-combined "$COMBINED_OUT"
    --out-chain "$CHAIN_OUT"
    --out-genesis "$GENESIS_OUT"
    --metadata-out "$METADATA_OUT"
  )

  if [[ "$CONSENSUS" == "pos" && -f "$POS_DEPLOYMENTS" ]]; then
    build_args+=(--pos-deployments "$POS_DEPLOYMENTS")
  fi

  "$QIKCHAIN_BIN" "${build_args[@]}"
  "$QIKCHAIN_BIN" genesis validate --chain "$COMBINED_OUT"
}

detect_metrics_flag() {
  if "$EDGE_BIN" server --help 2>&1 | rg -q -- '--prometheus'; then
    echo "--prometheus"
    return
  fi

  echo "--metrics"
}

write_bootnode_file_if_node1() {
  if [[ "$NODE_NAME" != "node1" ]]; then
    return 0
  fi

  local peer_id
  peer_id="$(extract_peer_id)"
  if [[ -z "$peer_id" ]]; then
    echo "Unable to derive node1 peer ID for bootnode" >&2
    exit 1
  fi

  echo "/dns4/${NODE_HOSTNAME}/tcp/${P2P_PORT}/p2p/${peer_id}" >"$BOOTNODE_FILE"
  log "Bootnode written to $BOOTNODE_FILE"
}

main() {
  require_bin "$EDGE_BIN"
  require_bin "$QIKCHAIN_BIN"

  mkdir -p "$NODE_DATA_DIR" "$BUILD_DIR"

  build_genesis_if_node1

  if [[ "$NODE_NAME" != "node1" ]]; then
    log "Waiting for shared chain artifacts"
    wait_for_file "$COMBINED_OUT" 180
  fi

  ensure_secrets
  if [[ "$NODE_NAME" == "node1" ]]; then
    write_bootnode_file_if_node1
  else
    wait_for_file "$BOOTNODE_FILE" 180
  fi

  local metrics_flag
  metrics_flag="$(detect_metrics_flag)"

  local bootnode_arg=()
  if [[ "$NODE_NAME" != "node1" ]]; then
    bootnode_arg=(--bootnode "$(cat "$BOOTNODE_FILE")")
    log "Using bootnode: ${bootnode_arg[1]}"
  fi

  log "Starting polygon-edge"
  exec "$EDGE_BIN" server \
    --data-dir "$NODE_DATA_DIR" \
    --chain "$COMBINED_OUT" \
    --grpc-address "0.0.0.0:${GRPC_PORT}" \
    --jsonrpc "0.0.0.0:${RPC_PORT}" \
    --libp2p "0.0.0.0:${P2P_PORT}" \
    "$metrics_flag" "0.0.0.0:${METRICS_PORT}" \
    "${bootnode_arg[@]}"
}

main "$@"
