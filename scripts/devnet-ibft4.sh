#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

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
BLOCK_GAS_LIMIT="${BLOCK_GAS_LIMIT:-0x1c9c380}"
MIN_GAS_PRICE="${MIN_GAS_PRICE:-0}"
BASE_FEE_ENABLED="${BASE_FEE_ENABLED:-false}"

# Files
GENESIS_OUT="${GENESIS_OUT:-$ROOT/build/genesis.json}"
CHAIN_PATH="${CHAIN_PATH:-$GENESIS_OUT}"
CHAIN_SPLIT_OUT="${CHAIN_SPLIT_OUT:-$ROOT/build/chain.json}"
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

if [[ "${DEBUG:-0}" == "1" ]]; then
  log "Resolved paths (shell-escaped):"
  printf '  ROOT=%q\n' "$ROOT"
  printf '  EDGE_BIN=%q\n' "$EDGE_BIN"
  printf '  QIKCHAIN_BIN=%q\n' "$QIKCHAIN_BIN"
  printf '  DATA_ROOT=%q\n' "$DATA_ROOT"
  printf '  NET_DIR=%q\n' "$NET_DIR"
  printf '  GENESIS_OUT=%q\n' "$GENESIS_OUT"
  printf '  CHAIN_PATH=%q\n' "$CHAIN_PATH"
  for i in "${!NODE_DIRS[@]}"; do
    printf '  NODE_DIRS[%d]=%q\n' "$i" "${NODE_DIRS[$i]}"
  done
fi

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
  if [[ "$CONSENSUS" != "poa" && "$CONSENSUS" != "ibft" ]]; then
    log "WARNING: CONSENSUS=$CONSENSUS requested, but Phase 0 devnet genesis is forced to polygon-edge IBFT."
  fi

  log "Building Polygon Edge IBFT genesis (chainId=$CHAIN_ID blockTime=2s)"
  log "Genesis output: $GENESIS_OUT"

  local validator_addresses=()
  local validator_blspubs=()
  for i in 1 2 3 4; do
    local secrets="${NODE_DIRS[$((i-1))]}/secrets"
    local out
    out="$("$EDGE_BIN" secrets output --data-dir "$secrets")"

    local addr
    addr="$(echo "$out" | sed -nE 's/.*(Validator[[:space:]]+)?Address[[:space:]]*[:=][[:space:]]*(0x[0-9a-fA-F]+).*/\2/p' | head -n1)"
    [[ -n "$addr" ]] || {
      echo "ERROR: could not parse validator address for node$i from secrets output"
      echo "$out"
      exit 1
    }
    validator_addresses+=("$addr")

    local blspub
    blspub="$(echo "$out" | sed -nE 's/.*(BLS[[:space:]]+)?(Public key|Pubkey)[[:space:]]*[:=][[:space:]]*([0-9a-fA-Fx]+).*/\3/p' | head -n1)"
    if [[ -n "$blspub" ]]; then
      validator_blspubs+=("$blspub")
    fi
  done

  local bootnodes=()
  for i in 1 2 3 4; do
    local peer_id
    peer_id="$("$EDGE_BIN" secrets output --data-dir "${NODE_DIRS[$((i-1))]}/secrets" 2>/dev/null | sed -nE 's/.*(Node ID:|node id:|Peer ID:|peer id:)\s*([A-Za-z0-9]+).*/\2/p' | head -n1)"
    [[ -n "$peer_id" ]] || continue
    bootnodes+=("/ip4/127.0.0.1/tcp/${P2P_PORTS[$((i-1))]}/p2p/$peer_id")
  done

  local args=(
    genesis
    --consensus ibft
    --chain-id "$CHAIN_ID"
    --block-gas-limit "$BLOCK_GAS_LIMIT"
    --block-time 2s
    --dir "$GENESIS_OUT"
  )

  for b in "${bootnodes[@]}"; do
    args+=(--bootnode "$b")
  done

  local used_direct_validator_flags=0
  if "$EDGE_BIN" genesis --help 2>&1 | rg -q -- "--ibft-validator"; then
    for v in "${validator_addresses[@]}"; do
      args+=(--ibft-validator "$v")
    done
    used_direct_validator_flags=1
  elif "$EDGE_BIN" genesis --help 2>&1 | rg -q -- "--ibft-validators-prefix-path"; then
    args+=(--ibft-validators-prefix-path "$NET_DIR/node")
  else
    echo "ERROR: polygon-edge genesis does not expose an IBFT validator flag we can use"
    "$EDGE_BIN" genesis --help
    exit 1
  fi

  log "Validators: ${validator_addresses[*]}"
  if (( ${#validator_blspubs[@]} > 0 )); then
    log "Collected BLS public keys for validators (count=${#validator_blspubs[@]})"
  fi

  "$EDGE_BIN" "${args[@]}"

  if (( used_direct_validator_flags == 1 )); then
    log "Genesis built using explicit --ibft-validator entries for node1..node4"
  else
    log "Genesis built using --ibft-validators-prefix-path from node1..node4 secrets"
  fi
}

normalize_forks_for_polygon_edge() {
  local target="$1"
  if [[ ! -f "$target" ]]; then
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "WARNING: jq not found; skipping params.forks normalization for $target"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  if jq '
    .params.forks |= (
      (. // {})
      | with_entries(
          select(
            .key == "homestead" or
            .key == "byzantium" or
            .key == "constantinople" or
            .key == "petersburg" or
            .key == "istanbul"
          )
          | if (.value | type) == "number" then
              .value = {"block": .value}
            elif (.value | type) == "object" and (.value.block | type) == "number" then
              .value = {"block": .value.block}
            else
              empty
            end
        )
    )
  ' "$target" > "$tmp"; then
    mv "$tmp" "$target"
    local final_keys
    final_keys="$(jq -r '(.params.forks // {}) | keys | join(", ")' "$target")"
    if [[ -z "$final_keys" ]]; then
      final_keys="<none>"
    fi
    log "Normalized and filtered params.forks in $target"
    log "Final params.forks keys: $final_keys"
  else
    log "WARNING: jq normalization failed for $target"
    rm -f "$tmp"
  fi
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
        --chain "$CHAIN_PATH" \
        --grpc-address "127.0.0.1:$grpc" \
        --jsonrpc "127.0.0.1:$rpc" \
        --libp2p "127.0.0.1:$p2p" \
        "$METRICS_FLAG" "127.0.0.1:$metrics" \
        --bootnode "$bootnode"
    else
      "$EDGE_BIN" server \
        --data-dir "$dir" \
        --chain "$CHAIN_PATH" \
        --grpc-address "127.0.0.1:$grpc" \
        --jsonrpc "127.0.0.1:$rpc" \
        --libp2p "127.0.0.1:$p2p" \
        "$METRICS_FLAG" "127.0.0.1:$metrics"
    fi
  ) >"$log_file" 2>&1 &

  echo "$!" > "$pid_file"
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
