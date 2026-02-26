#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/app}"
EDGE_BIN="${EDGE_BIN:-$APP_DIR/bin/polygon-edge}"
NODE_NAME="${NODE_NAME:-node1}"
NODE_DATA_DIR="${NODE_DATA_DIR:-/data/${NODE_NAME}}"

CONSENSUS="${CONSENSUS:-poa}"
CHAIN_ID="${CHAIN_ID:-100}"
BLOCK_GAS_LIMIT="${BLOCK_GAS_LIMIT:-0x1c9c380}"
CI_FUNDER_ADDRESS="${CI_FUNDER_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
CI_FUNDER_BALANCE_WEI_HEX="${CI_FUNDER_BALANCE_WEI_HEX:-0x3635c9adc5dea00000}"

RPC_PORT="${RPC_PORT:-8545}"
GRPC_PORT="${GRPC_PORT:-9632}"
P2P_PORT="${P2P_PORT:-1478}"
METRICS_PORT="${METRICS_PORT:-9090}"

SHARED_DIR="${SHARED_DIR:-/shared}"
GENESIS_OUT="${GENESIS_OUT:-$SHARED_DIR/genesis.json}"
NODE1_MULTIADDR_FILE="${NODE1_MULTIADDR_FILE:-$SHARED_DIR/node1.multiaddr}"
SECRETS_INFO_DIR="${SECRETS_INFO_DIR:-$SHARED_DIR/secrets-output}"
VALIDATOR_COUNT="${VALIDATOR_COUNT:-4}"

log() { echo "[$(date +"%H:%M:%S")] [$NODE_NAME] $*"; }

detect_metrics_flag() {
  if "$EDGE_BIN" server --help 2>&1 | grep -q -- '--prometheus'; then
    echo "--prometheus"
  else
    echo "--metrics"
  fi
}

wait_for_file() {
  local file="$1"
  local timeout="${2:-180}"
  local i
  for i in $(seq 1 "$timeout"); do
    [[ -f "$file" ]] && return 0
    sleep 1
  done
  echo "Timed out waiting for $file" >&2
  exit 1
}

ensure_secrets() {
  if [[ -f "$NODE_DATA_DIR/consensus/validator.key" ]]; then
    return
  fi

  mkdir -p "$NODE_DATA_DIR"
  "$EDGE_BIN" secrets init --data-dir "$NODE_DATA_DIR" --insecure >/dev/null
}

publish_secrets_output() {
  mkdir -p "$SECRETS_INFO_DIR"
  "$EDGE_BIN" secrets output --data-dir "$NODE_DATA_DIR" >"$SECRETS_INFO_DIR/${NODE_NAME}.txt"
}

extract_field() {
  local key="$1"
  local file="$2"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*[:=][[:space:]]*([^[:space:]]+).*/\\1/p" "$file" | head -n1 | tr -d '\r\n'
}

build_genesis_if_node1() {
  [[ "$NODE_NAME" == "node1" ]] || return 0
  [[ "$CONSENSUS" == "poa" || "$CONSENSUS" == "ibft" ]] || log "CONSENSUS=$CONSENSUS requested; using IBFT genesis for docker devnet"

  mkdir -p "$SHARED_DIR"
  if [[ -f "$GENESIS_OUT" && -f "$NODE1_MULTIADDR_FILE" ]]; then
    log "Reusing existing genesis in shared volume"
    return 0
  fi

  log "Waiting for validator secrets from ${VALIDATOR_COUNT} nodes"
  local i
  for i in $(seq 1 "$VALIDATOR_COUNT"); do
    wait_for_file "$SECRETS_INFO_DIR/node${i}.txt" 240
  done

  local validators=()
  local node1_id=""
  for i in $(seq 1 "$VALIDATOR_COUNT"); do
    local f="$SECRETS_INFO_DIR/node${i}.txt"
    local node_id addr bls
    node_id="$(extract_field 'Node ID' "$f")"
    addr="$(sed -nE 's/^[[:space:]]*Public key \(address\)[[:space:]]*[:=][[:space:]]*(0x[0-9a-fA-F]{40}).*/\1/p' "$f" | head -n1 | tr -d '\r\n')"
    bls="$(extract_field 'BLS Public key' "$f")"
    if [[ -z "$node_id" || -z "$addr" || -z "$bls" ]]; then
      echo "Failed to parse validator data from $f" >&2
      cat "$f" >&2
      exit 1
    fi
    [[ -z "$node1_id" ]] && node1_id="$node_id"
    validators+=("${addr}:${bls}")
  done

  local node1_p2p_port="${NODE1_P2P_PORT:-1478}"
  local node1_bootnode="/dns4/node1/tcp/${node1_p2p_port}/p2p/${node1_id}"
  printf '%s' "$node1_bootnode" >"$NODE1_MULTIADDR_FILE"

  local args=(
    genesis
    --consensus ibft
    --ibft-validator-type bls
    --chain-id "$CHAIN_ID"
    --name qikchain-ibft4-devnet
    --block-gas-limit "$BLOCK_GAS_LIMIT"
    --block-time 2s
    --dir "$GENESIS_OUT"
    --bootnode "$node1_bootnode"
    --premine "${CI_FUNDER_ADDRESS}:${CI_FUNDER_BALANCE_WEI_HEX}"
  )

  for validator in "${validators[@]}"; do
    args+=(--validators "$validator")
  done

  "$EDGE_BIN" "${args[@]}"
  log "Built genesis at $GENESIS_OUT"
}

main() {
  mkdir -p "$NODE_DATA_DIR" "$SHARED_DIR"

  ensure_secrets
  publish_secrets_output
  build_genesis_if_node1

  if [[ "$NODE_NAME" != "node1" ]]; then
    wait_for_file "$GENESIS_OUT" 240
    wait_for_file "$NODE1_MULTIADDR_FILE" 240
  fi

  local metrics_flag
  metrics_flag="$(detect_metrics_flag)"

  local args=(
    server
    --data-dir "$NODE_DATA_DIR"
    --chain "$GENESIS_OUT"
    --grpc-address "0.0.0.0:${GRPC_PORT}"
    --jsonrpc "0.0.0.0:${RPC_PORT}"
    --libp2p "0.0.0.0:${P2P_PORT}"
    "$metrics_flag" "0.0.0.0:${METRICS_PORT}"
  )

  if [[ "$NODE_NAME" != "node1" ]]; then
    args+=(--bootnode "$(cat "$NODE1_MULTIADDR_FILE")")
  fi

  log "Starting polygon-edge"
  exec "$EDGE_BIN" "${args[@]}"
}

main "$@"
