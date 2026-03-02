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
CHAIN_NAME="${CHAIN_NAME:-qikchain-ibft4-devnet}"
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
CI_FUNDER_ADDRESS="${CI_FUNDER_ADDRESS:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
CI_FUNDER_BALANCE_WEI_HEX="${CI_FUNDER_BALANCE_WEI_HEX:-0x3635c9adc5dea00000}"

# Ports (node i => ports[i])
RPC_PORTS=(8545 8546 8547 8548)
GRPC_PORTS=(9632 9633 9634 9635)
P2P_PORTS=(1478 1479 1480 1481)
METRICS_PORTS=(9090 9091 9092 9093)

# Node dirs
NODE_DIRS=("$NET_DIR/node1" "$NET_DIR/node2" "$NET_DIR/node3" "$NET_DIR/node4")
NODE1_MULTIADDR=""

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
}

reset_net() {
  if [[ "$RESET" == "1" ]]; then
    local stop_script="$ROOT/scripts/devnet-ibft4-stop.sh"
    if [[ -x "$stop_script" ]]; then
      log "RESET=1: stopping running devnet processes (best effort)"
      FORCE=1 CLEAN_PORTS=1 bash "$stop_script" >/dev/null 2>&1 || true
    fi

    log "RESET=1: wiping network dir: $DATA_ROOT"
    rm -rf "$DATA_ROOT"

    log "RESET=1: removing generated chain artifacts"
    rm -f "$GENESIS_OUT" "$CHAIN_SPLIT_OUT" "$GENESIS_ETH_OUT" "$METADATA_OUT"

    ensure_dirs
  fi
}

genesis_fingerprint() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
    return
  fi

  echo "ERROR: no SHA256 tool available (need sha256sum, shasum, or openssl)" >&2
  exit 1
}

node_is_initialized() {
  local dir="$1"
  [[ -f "$dir/consensus/validator.key" || -f "$dir/.genesis.sha256" || -d "$dir/blockchain" ]]
}

has_initialized_nodes() {
  local d
  for d in "${NODE_DIRS[@]}"; do
    if node_is_initialized "$d"; then
      return 0
    fi
  done
  return 1
}

persist_genesis_fingerprint() {
  local fingerprint="$1"
  local d
  for d in "${NODE_DIRS[@]}"; do
    if node_is_initialized "$d"; then
      mkdir -p "$d"
      printf '%s\n' "$fingerprint" > "$d/.genesis.sha256"
    fi
  done
}

best_effort_verify_stored_genesis() {
  local node_dir="$1"

  if "$EDGE_BIN" genesis --help 2>&1 | rg -q "verify"; then
    if "$EDGE_BIN" genesis verify --chain "$CHAIN_PATH" --data-dir "$node_dir" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

fail_genesis_mismatch() {
  cat >&2 <<'EOF'
Genesis changed since this data dir was initialized.
Run: RESET=1 make up
EOF
  exit 1
}

check_existing_genesis_fingerprint() {
  local current_fingerprint="$1"
  local d

  for d in "${NODE_DIRS[@]}"; do
    if ! node_is_initialized "$d"; then
      continue
    fi

    local fingerprint_file="$d/.genesis.sha256"
    if [[ -f "$fingerprint_file" ]]; then
      local saved
      saved="$(tr -d '[:space:]' < "$fingerprint_file" 2>/dev/null || true)"
      if [[ -z "$saved" || "$saved" != "$current_fingerprint" ]]; then
        fail_genesis_mismatch
      fi
      continue
    fi

    if best_effort_verify_stored_genesis "$d"; then
      printf '%s\n' "$current_fingerprint" > "$fingerprint_file"
      continue
    fi

    fail_genesis_mismatch
  done
}

# Create node secrets if missing
init_secrets_if_needed() {
  for i in 1 2 3 4; do
    local dir="${NODE_DIRS[$((i-1))]}"
    if [[ ! -f "$dir/consensus/validator.key" ]]; then
      log "Initializing secrets for node$i in $dir"
      mkdir -p "$dir"
      if [[ "$INSECURE_SECRETS" == "1" ]]; then
        "$EDGE_BIN" secrets init --data-dir "$dir" --insecure >/dev/null
      else
        "$EDGE_BIN" secrets init --data-dir "$dir" >/dev/null
      fi
    fi
  done
}

build_genesis() {
  if [[ -f "$GENESIS_OUT" ]]; then
    echo "Genesis already exists — skipping generation."
    return 0
  fi

  if [[ "$CONSENSUS" != "poa" && "$CONSENSUS" != "ibft" ]]; then
    log "WARNING: CONSENSUS=$CONSENSUS requested, but Phase 0 devnet genesis is forced to polygon-edge IBFT."
  fi

  log "Building Polygon Edge IBFT genesis (chainId=$CHAIN_ID blockTime=2s)"
  log "Genesis output: $GENESIS_OUT"

  local VALIDATORS_ROOT="$NET_DIR/validators"
  rm -rf "$VALIDATORS_ROOT"
  mkdir -p "$VALIDATORS_ROOT"
  for i in 1 2 3 4; do
    ln -sfn "$NET_DIR/node$i" "$VALIDATORS_ROOT/test-chain-$i"
  done

  log "Debug: validator directory layout under $VALIDATORS_ROOT/test-chain-1 (maxdepth=4, following symlinks)"
  find -L "$VALIDATORS_ROOT/test-chain-1" -maxdepth 4 -type f -print

  local validators=()
  local first_node_id=""
  local i
  for i in 1 2 3 4; do
    local out node_id addr bls validator_entry
    out="$("$EDGE_BIN" secrets output --data-dir "$NET_DIR/node$i")"

    node_id="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*Node ID[[:space:]]*[:=][[:space:]]*([^[:space:]]+).*/\1/p' | head -n1 | tr -d '\r\n')"
    addr="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*Public key \(address\)[[:space:]]*[:=][[:space:]]*(0x[0-9a-fA-F]{40}).*/\1/p' | head -n1 | tr -d '\r\n')"
    bls="$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*BLS Public key[[:space:]]*[:=][[:space:]]*(0x[0-9a-fA-F]+).*/\1/p' | head -n1 | tr -d '\r\n')"

    if [[ -z "$node_id" ]]; then
      node_id="$(printf '%s\n' "$out" | grep -Eo '16Uiu2H[0-9A-Za-z]+' | head -n1 | tr -d '\r\n' || true)"
    fi

    validator_entry="${addr}:${bls}"
    if [[ ! "$validator_entry" =~ ^0x[0-9a-fA-F]{40}:0x[0-9a-fA-F]+$ ]]; then
      echo "ERROR: invalid validator format for node$i" >&2
      echo "Parsed addr: ${addr:-<empty>}" >&2
      echo "Parsed bls:  ${bls:-<empty>}" >&2
      echo "Full secrets output:" >&2
      echo "$out" >&2
      exit 1
    fi

    if [[ -z "$first_node_id" ]]; then
      first_node_id="$node_id"
    fi

    validators+=( "$validator_entry" )
  done

  NODE1_MULTIADDR="/ip4/127.0.0.1/tcp/${P2P_PORTS[0]}/p2p/${first_node_id}"
  log "[p2p] NODE1_MULTIADDR=${NODE1_MULTIADDR}"

  local args=(
    genesis
    --consensus ibft
    --ibft-validator-type bls
    --chain-id "$CHAIN_ID"
    --name "qikchain-ibft4-devnet"
    --block-gas-limit "$BLOCK_GAS_LIMIT"
    --block-time 2s
    --dir "$GENESIS_OUT"
    --bootnode "$NODE1_MULTIADDR"
    --premine "${CI_FUNDER_ADDRESS}:${CI_FUNDER_BALANCE_WEI_HEX}"
  )

  local v
  for v in "${validators[@]}"; do
    args+=( --validators "$v" )
  done

  log "Validators provided explicitly via --validators"

  "$EDGE_BIN" "${args[@]}"

  local extra_data_hex
  extra_data_hex="$(jq -r '.genesis.extraData // empty' "$GENESIS_OUT" 2>/dev/null || true)"
  if [[ -z "$extra_data_hex" || "$extra_data_hex" == "null" ]]; then
    echo "ERROR: Could not read genesis.extraData from $GENESIS_OUT" >&2
    exit 1
  fi

  local extra_data_len=0
  if [[ "$extra_data_hex" == 0x* ]]; then
    extra_data_len=$(((${#extra_data_hex} - 2) / 2))
  fi

  if (( extra_data_len <= 40 )); then
    echo "ERROR: genesis.extraData is too small (${extra_data_len} bytes). Likely missing validator set in extraData" >&2
    exit 1
  fi

  log "Genesis built using explicit --validators tuples with IBFT BLS validators"
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

  log "Starting node$node_num (rpc=$rpc p2p=$p2p metrics=$metrics) ..."
  # Note: Adjust flags if your polygon-edge build differs.
  # Common flags include: --data-dir, --chain, --grpc-address, --jsonrpc, --libp2p, --seal, --prometheus
  #
  # We keep it minimal + explicit port bindings.
  (
    set -x
    "$EDGE_BIN" server \
      --data-dir "$dir" \
      --chain "$CHAIN_PATH" \
      --grpc-address "127.0.0.1:$grpc" \
      --jsonrpc "127.0.0.1:$rpc" \
      --libp2p "127.0.0.1:$p2p" \
      "$METRICS_FLAG" "127.0.0.1:$metrics"
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
  local had_initialized_nodes=0
  if has_initialized_nodes; then
    had_initialized_nodes=1
  fi

  init_secrets_if_needed
  build_genesis

  if [[ ! -f "$CHAIN_PATH" ]]; then
    echo "ERROR: chain file not found at $CHAIN_PATH" >&2
    exit 1
  fi

  local current_fingerprint
  current_fingerprint="$(genesis_fingerprint "$CHAIN_PATH")"

  if [[ "$had_initialized_nodes" == "1" && "$RESET" != "1" ]]; then
    check_existing_genesis_fingerprint "$current_fingerprint"
  fi
  persist_genesis_fingerprint "$current_fingerprint"

  # Start nodes (node1 first, then others for bootnode)
  start_node 0
  sleep 1
  start_node 1
  sleep 1
  start_node 2
  sleep 1
  start_node 3

  status_hint
}

main "$@"
