#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# QikChain Devnet Startup: IBFT 4-node (PoA or PoS)
#
# Usage examples:
#   CONSENSUS=poa ./scripts/devnet-ibft4.sh
#   CONSENSUS=pos ./scripts/devnet-ibft4.sh
#   RESET=1 CONSENSUS=poa ./scripts/devnet-ibft4.sh
#
# Optional:
#   ENV=devnet|staging|mainnet
#   CHAIN_ID=100
#   ALLOCATIONS_FILE=config/allocations/devnet.json
#   TOKEN_FILE=config/token.json
#   POS_DEPLOYMENTS=build/deployments/pos.local.json
#
# Notes:
# - For PoS, this script starts the chain. Contract deploy/bootstrap happens after:
#     ./scripts/deploy-pos-contracts.sh
#     ./scripts/bootstrap-pos-validators.sh
# ============================================================

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

EDGE_BIN="${EDGE_BIN:-$ROOT/bin/polygon-edge}"
QIKCHAIN_BIN="${QIKCHAIN_BIN:-$ROOT/bin/qikchain}"

# Data root
DATA_ROOT="${DATA_ROOT:-$ROOT/.data}"
NET_NAME="${NET_NAME:-ibft4}"
NET_DIR="${NET_DIR:-$DATA_ROOT/$NET_NAME}"

# Config toggles
RESET="${RESET:-0}"
CONSENSUS="${CONSENSUS:-poa}"           # poa|pos
ENV_NAME="${ENV:-devnet}"              # devnet|staging|mainnet
INSECURE_SECRETS="${INSECURE_SECRETS:-1}"  # dev-only

# Chain config
CHAIN_ID="${CHAIN_ID:-100}"
BLOCK_GAS_LIMIT="${BLOCK_GAS_LIMIT:-15000000}"
MIN_GAS_PRICE="${MIN_GAS_PRICE:-0}"
BASE_FEE_ENABLED="${BASE_FEE_ENABLED:-false}"

# Files
CHAIN_OUT="${CHAIN_OUT:-$ROOT/build/chain.json}"
GENESIS_ETH_OUT="${GENESIS_ETH_OUT:-$ROOT/build/genesis-eth.json}"
METADATA_OUT="${METADATA_OUT:-$ROOT/build/chain-metadata.json}"
ALLOCATIONS_FILE="${ALLOCATIONS_FILE:-$ROOT/config/allocations/devnet.json}"
TOKEN_FILE="${TOKEN_FILE:-$ROOT/config/token.json}"
POS_DEPLOYMENTS="${POS_DEPLOYMENTS:-$ROOT/build/deployments/pos.local.json}"

# Ports (node i => ports[i])
RPC_PORTS=(8545 8546 8547 8548)
GRPC_PORTS=(9632 9633 9634 9635)
P2P_PORTS=(1478 1479 1480 1481)
METRICS_PORTS=(9090 9091 9092 9093)

# Node dirs
NODE_DIRS=("$NET_DIR/node1" "$NET_DIR/node2" "$NET_DIR/node3" "$NET_DIR/node4")

METRICS_FLAG="--prometheus"
if "$EDGE_BIN" server --help 2>&1 | rg -q -- "--prometheus"; then
  METRICS_FLAG="--prometheus"
elif "$EDGE_BIN" server --help 2>&1 | rg -q -- "--metrics"; then
  METRICS_FLAG="--metrics"
fi


log() { echo "[$(date +"%H:%M:%S")] $*"; }

require_bin() {
  local b="$1"
  if [[ ! -x "$b" ]]; then
    echo "ERROR: missing executable: $b"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$NET_DIR" "$ROOT/build" "$ROOT/build/deployments"
  for d in "${NODE_DIRS[@]}"; do
    mkdir -p "$d"
  done
}

reset_net() {
  if [[ "$RESET" == "1" ]]; then
    log "RESET=1: wiping network dir: $NET_DIR"
    rm -rf "$NET_DIR"
    ensure_dirs
  fi
}

# Create node secrets if missing
init_secrets_if_needed() {
  for i in 1 2 3 4; do
    local dir="${NODE_DIRS[$((i-1))]}"
    local secrets="$dir/secrets"
    if [[ ! -d "$secrets" ]]; then
      log "Initializing secrets for node$i in $secrets"
      mkdir -p "$secrets"
      if [[ "$INSECURE_SECRETS" == "1" ]]; then
        "$EDGE_BIN" secrets init --data-dir "$secrets" --insecure >/dev/null
      else
        "$EDGE_BIN" secrets init --data-dir "$secrets" >/dev/null
      fi
    fi
  done
}

# Build bootnode list (multiaddr) from node1 (or use all nodes)
# polygon-edge uses libp2p multiaddr; we can use node key output.
# We'll derive enode-like? For polygon-edge, easiest is to use "server --bootnode" with libp2p addr.
# However, without repo-specific precedent, we keep it simple:
# - Start node1 first
# - Use node1 as bootnode for nodes2-4 (requires node1 libp2p address)
get_node1_bootnode_addr() {
  local node1_dir="${NODE_DIRS[0]}"
  local secrets="$node1_dir/secrets"

  # polygon-edge can print node ID via:
  #   polygon-edge secrets output --data-dir <secrets>
  # We'll attempt to read it. If this differs in your build, adjust this function.
  local out
  out="$("$EDGE_BIN" secrets output --data-dir "$secrets" 2>/dev/null || true)"
  # Expected to contain something like "Node ID: <peerID>" (varies by version).
  # Try to extract a peer ID-ish token:
  local peer_id
  peer_id="$(echo "$out" | sed -nE 's/.*(Node ID:|node id:)\s*([A-Za-z0-9]+).*/\2/p' | head -n1)"
  if [[ -z "${peer_id:-}" ]]; then
    # Fallback: try "Peer ID:"
    peer_id="$(echo "$out" | sed -nE 's/.*(Peer ID:|peer id:)\s*([A-Za-z0-9]+).*/\2/p' | head -n1)"
  fi

  if [[ -z "${peer_id:-}" ]]; then
    echo ""
    return 0
  fi

  # Bootnode multiaddr (assumes TCP + local)
  echo "/ip4/127.0.0.1/tcp/${P2P_PORTS[0]}/p2p/${peer_id}"
}

build_genesis() {
  log "Building genesis via CLI (consensus=$CONSENSUS env=$ENV_NAME chainId=$CHAIN_ID)"
  log "Chain output: $CHAIN_OUT"
  log "Eth genesis output: $GENESIS_ETH_OUT"
  local args=(
    genesis build
    --consensus "$CONSENSUS"
    --env "$ENV_NAME"
    --chain-id "$CHAIN_ID"
    --block-gas-limit "$BLOCK_GAS_LIMIT"
    --min-gas-price "$MIN_GAS_PRICE"
    --base-fee-enabled "$BASE_FEE_ENABLED"
    --allocations "$ALLOCATIONS_FILE"
    --token "$TOKEN_FILE"
    --out-chain "$CHAIN_OUT"
    --out-genesis "$GENESIS_ETH_OUT"
    --metadata-out "$METADATA_OUT"
  )

  # For PoS we try to inject addresses if deployments exist
  if [[ "$CONSENSUS" == "pos" ]]; then
    args+=(--pos-deployments "$POS_DEPLOYMENTS")
    # If deployments missing, you can allow missing placeholders by setting:
    #   ALLOW_MISSING_POS=1
    if [[ "${ALLOW_MISSING_POS:-0}" == "1" ]]; then
      args+=(--allow-missing-pos-addresses)
    fi
  fi

  "$QIKCHAIN_BIN" "${args[@]}"
  "$QIKCHAIN_BIN" genesis validate --chain "$CHAIN_OUT"
}

start_node() {
  local idx="$1" # 0-based
  local node_num=$((idx+1))
  local dir="${NODE_DIRS[$idx]}"

  local rpc="${RPC_PORTS[$idx]}"
  local grpc="${GRPC_PORTS[$idx]}"
  local p2p="${P2P_PORTS[$idx]}"
  local metrics="${METRICS_PORTS[$idx]}"

  local log_file="$dir/server.log"
  local pid_file="$dir/server.pid"

  # If already running, skip
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    log "node$node_num already running (pid=$(cat "$pid_file"))"
    return 0
  fi

  local bootnode=""
  if [[ "$idx" != "0" ]]; then
    bootnode="$(get_node1_bootnode_addr)"
  fi

  log "Starting node$node_num (rpc=$rpc p2p=$p2p metrics=$metrics) ..."
  # Note: Adjust flags if your polygon-edge build differs.
  # Common flags include: --data-dir, --chain, --grpc-address, --jsonrpc, --libp2p, --seal, --prometheus
  #
  # We keep it minimal + explicit port bindings.
  (
    set -x
    if [[ -n "$bootnode" ]]; then
      "$EDGE_BIN" server \
        --data-dir "$dir" \
        --chain "$CHAIN_OUT" \
        --grpc-address "127.0.0.1:$grpc" \
        --jsonrpc "127.0.0.1:$rpc" \
        --libp2p "127.0.0.1:$p2p" \
        ${METRICS_FLAG} "127.0.0.1:$metrics" \
        --bootnode "$bootnode"
    else
      "$EDGE_BIN" server \
        --data-dir "$dir" \
        --chain "$CHAIN_OUT" \
        --grpc-address "127.0.0.1:$grpc" \
        --jsonrpc "127.0.0.1:$rpc" \
        --libp2p "127.0.0.1:$p2p" \
        ${METRICS_FLAG} "127.0.0.1:$metrics"
    fi
  ) >"$log_file" 2>&1 &

  echo $! >"$pid_file"
  log "node$node_num started (pid=$(cat "$pid_file")) logs=$log_file"
}

status_hint() {
  cat <<EOF

Devnet is starting.

RPC endpoints:
  node1: http://127.0.0.1:${RPC_PORTS[0]}
  node2: http://127.0.0.1:${RPC_PORTS[1]}
  node3: http://127.0.0.1:${RPC_PORTS[2]}
  node4: http://127.0.0.1:${RPC_PORTS[3]}

Metrics endpoints:
  node1: http://127.0.0.1:${METRICS_PORTS[0]}
  node2: http://127.0.0.1:${METRICS_PORTS[1]}
  node3: http://127.0.0.1:${METRICS_PORTS[2]}
  node4: http://127.0.0.1:${METRICS_PORTS[3]}

Check chain:
  $QIKCHAIN_BIN block head --rpc http://127.0.0.1:${RPC_PORTS[0]}
  $QIKCHAIN_BIN status --rpc http://127.0.0.1:${RPC_PORTS[0]}

PoS follow-ups (after chain is up):
  ./scripts/deploy-pos-contracts.sh
  ./scripts/bootstrap-pos-validators.sh

EOF
}

main() {
  require_bin "$EDGE_BIN"
  require_bin "$QIKCHAIN_BIN"

  ensure_dirs
  reset_net
  init_secrets_if_needed
  build_genesis

  # Start nodes (node1 first, then others for bootnode)
  start_node 0
  sleep 1
  start_node 1
  start_node 2
  start_node 3

  status_hint
}

main "$@"
