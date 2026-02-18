#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EDGE="${EDGE_BIN:-$ROOT/bin/polygon-edge}"

# Root state directory
DATA_ROOT="${DATA_ROOT:-$ROOT/.data}"
NET_DIR="${NET_DIR:-$DATA_ROOT/ibft4}"

# Chain files
GENESIS_PATH="${GENESIS_PATH:-$NET_DIR/genesis.json}"

# Behavior toggles
RESET="${RESET:-0}"                 # RESET=1 wipes the network dir
INSECURE_SECRETS="${INSECURE_SECRETS:-1}"  # dev-only filesystem key storage
CONSENSUS="${CONSENSUS:-ibft}"      # PoA now
IBFT_POS="${IBFT_POS:-0}"           # set to 1 later if your Edge supports --pos for IBFT PoS genesis

# Host/ports (local)
HOST="${HOST:-127.0.0.1}"
BASE_RPC_PORT="${BASE_RPC_PORT:-8545}"       # node i uses BASE_RPC_PORT+(i-1)
BASE_METRICS_PORT="${BASE_METRICS_PORT:-9090}" # node i uses BASE_METRICS_PORT+(i-1)
BASE_LIBP2P_PORT="${BASE_LIBP2P_PORT:-1478}" # node i uses BASE_LIBP2P_PORT+(i-1)
BASE_GRPC_PORT="${BASE_GRPC_PORT:-9632}"     # node i uses BASE_GRPC_PORT+(i-1)

LOG_DIR="$NET_DIR/logs"
PID_DIR="$NET_DIR/pids"

die() { echo "ERROR: $*" >&2; exit 1; }
msg() { echo -e "$*"; }

[[ -x "$EDGE" ]] || die "polygon-edge binary not found/executable at: $EDGE (run: make edge)"

if [[ "$RESET" == "1" ]]; then
  msg "RESET=1 -> removing $NET_DIR"
  rm -rf "$NET_DIR"
fi

mkdir -p "$NET_DIR" "$LOG_DIR" "$PID_DIR"

# Helper: start node in background
start_node() {
  local i="$1"
  local dir="$2"
  local rpc_port="$3"
  local metrics_port="$4"
  local libp2p_port="$5"
  local grpc_port="$6"

  local log_file="$LOG_DIR/chain-$i.log"
  local pid_file="$PID_DIR/chain-$i.pid"

  msg "Starting chain-$i  rpc:$rpc_port metrics:$metrics_port libp2p:$libp2p_port grpc:$grpc_port"

  nohup "$EDGE" server \
    --seal \
    --data-dir "$dir" \
    --chain "$GENESIS_PATH" \
    --jsonrpc "${HOST}:${rpc_port}" \
    --prometheus "${HOST}:${metrics_port}" \
    --libp2p "${HOST}:${libp2p_port}" \
    --grpc-address "${HOST}:${grpc_port}" \
   >"$log_file" 2>&1 &

  echo $! > "$pid_file"
}

# Helper: parse Node ID (your output format: "Node ID              = <peerid>")
parse_node_id() {
  awk -F'= ' '/Node ID/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}'
}

# --- 1) Create 4 validator dirs and secrets ---
# IMPORTANT: for multi-validator genesis, Edge expects a *prefix* like "chain-"
# and validator folders like "chain-1", "chain-2", etc. :contentReference[oaicite:2]{index=2}
PREFIX="$NET_DIR/chain-"

BOOTNODES=()

for i in 1 2 3 4; do
  DIR="${PREFIX}${i}"
  NODEID_FILE="$DIR/nodeid"
  INIT_LOG="$DIR/secrets-init.log"

  mkdir -p "$DIR"

  if [[ -f "$NODEID_FILE" ]]; then
    NODE_ID="$(tr -d '\r\n' < "$NODEID_FILE")"
  else
    msg "Initializing secrets for chain-$i (DEV MODE)..."
    if [[ "$INSECURE_SECRETS" == "1" ]]; then
      INIT_OUT="$("$EDGE" secrets init --data-dir "$DIR" --insecure 2>&1 | tee "$INIT_LOG")"
    else
      INIT_OUT="$("$EDGE" secrets init --data-dir "$DIR" 2>&1 | tee "$INIT_LOG")"
    fi

    NODE_ID="$(echo "$INIT_OUT" | parse_node_id || true)"
    NODE_ID="$(echo -n "${NODE_ID:-}" | tr -d '\r\n')"
    [[ -n "$NODE_ID" ]] || die "Could not parse Node ID for chain-$i. Check $INIT_LOG"

    echo "$NODE_ID" > "$NODEID_FILE"
  fi

  LIBP2P_PORT=$((BASE_LIBP2P_PORT + i - 1))
  BOOTNODES+=( "/ip4/${HOST}/tcp/${LIBP2P_PORT}/p2p/${NODE_ID}" )
done

# --- 2) Generate genesis (once) ---
if [[ -f "$GENESIS_PATH" ]]; then
  msg "Genesis exists: $GENESIS_PATH (reusing)"
else
  msg "Generating genesis: $GENESIS_PATH"

  # Collect validator ECDSA addresses from secrets init logs
  IBFT_VALIDATORS=()
  for i in 1 2 3 4; do
    DIR="${PREFIX}${i}"
    ADDR="$(sed -n '1,60p' "$DIR/secrets-init.log" | awk -F'= ' '/Public key \(address\)/ {print $2; exit}')"
    ADDR="$(echo -n "${ADDR:-}" | tr -d '\r\n')"
    [[ -n "$ADDR" ]] || die "Could not parse validator address for chain-$i from $DIR/secrets-init.log"
    IBFT_VALIDATORS+=( "$ADDR" )
  done

  GENESIS_ARGS=(
    genesis
    --consensus "$CONSENSUS"
    --dir "$GENESIS_PATH"
  )

  # Add validators explicitly (repeated flag)
  for v in "${IBFT_VALIDATORS[@]}"; do
    GENESIS_ARGS+=( --ibft-validator "$v" )
  done

  # Add bootnodes (your build requires at least one)
  for b in "${BOOTNODES[@]}"; do
    GENESIS_ARGS+=( --bootnode "$b" )
  done

  # Optional: premine validators for easy testing (default huge amount if balance omitted)
  for v in "${IBFT_VALIDATORS[@]}"; do
    GENESIS_ARGS+=( --premine "${v}" )
  done

  if [[ "$IBFT_POS" == "1" ]]; then
    GENESIS_ARGS+=( --pos )
  fi

  "$EDGE" "${GENESIS_ARGS[@]}" >/dev/null
fi

# --- 3) Start 4 nodes ---
msg ""
msg "Bootnodes embedded in genesis:"
for b in "${BOOTNODES[@]}"; do
  msg "  $b"
done
msg ""

for i in 1 2 3 4; do
  DIR="${PREFIX}${i}"
  RPC_PORT=$((BASE_RPC_PORT + i - 1))
  METRICS_PORT=$((BASE_METRICS_PORT + i - 1))
  LIBP2P_PORT=$((BASE_LIBP2P_PORT + i - 1))
  GRPC_PORT=$((BASE_GRPC_PORT + i - 1))

  start_node "$i" "$DIR" "$RPC_PORT" "$METRICS_PORT" "$LIBP2P_PORT" "$GRPC_PORT"
done

msg ""
msg "IBFT4 network started."
msg "RPC endpoints:"
msg "  chain-1: http://${HOST}:$((BASE_RPC_PORT+0))"
msg "  chain-2: http://${HOST}:$((BASE_RPC_PORT+1))"
msg "  chain-3: http://${HOST}:$((BASE_RPC_PORT+2))"
msg "  chain-4: http://${HOST}:$((BASE_RPC_PORT+3))"
msg ""
msg "Metrics endpoints:"
msg "  chain-1: http://${HOST}:$((BASE_METRICS_PORT+0))/metrics"
msg "  chain-2: http://${HOST}:$((BASE_METRICS_PORT+1))/metrics"
msg "  chain-3: http://${HOST}:$((BASE_METRICS_PORT+2))/metrics"
msg "  chain-4: http://${HOST}:$((BASE_METRICS_PORT+3))/metrics"
msg ""
msg "Logs: $LOG_DIR"
msg "Stop:  ./scripts/devnet-ibft4-stop.sh  (create using snippet below)"
msg "Reset: RESET=1 ./scripts/devnet-ibft4.sh"
