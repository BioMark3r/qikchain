#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EDGE="${EDGE_BIN:-$ROOT/bin/polygon-edge}"

# Paths
DATA_ROOT="${DATA_ROOT:-$ROOT/.data}"
NODE_NAME="${NODE_NAME:-node-1}"
NODE_DIR="${NODE_DIR:-$DATA_ROOT/$NODE_NAME}"
GENESIS_PATH="${GENESIS_PATH:-$DATA_ROOT/genesis.json}"
NODE_ID_FILE="$NODE_DIR/nodeid"
SECRETS_INIT_LOG="$NODE_DIR/secrets-init.log"

# Network
RPC_HOST="${RPC_HOST:-127.0.0.1}"
RPC_PORT="${RPC_PORT:-8545}"
METRICS_HOST="${METRICS_HOST:-127.0.0.1}"
METRICS_PORT="${METRICS_PORT:-9090}"
GRPC_ADDR="${GRPC_ADDR:-127.0.0.1:9632}"
LIBP2P_ADDR="${LIBP2P_ADDR:-127.0.0.1:1478}" # host:port

# Consensus (PoA now; PoS-ready later)
CONSENSUS="${CONSENSUS:-ibft}"
IBFT_POS="${IBFT_POS:-0}" # set to 1 later if your Edge supports --pos for IBFT PoS genesis

# Behavior
RESET="${RESET:-0}"                 # RESET=1 wipes .data
INSECURE_SECRETS="${INSECURE_SECRETS:-1}"  # dev-only filesystem key storage

die() { echo "ERROR: $*" >&2; exit 1; }
msg() { echo -e "$*"; }

[[ -x "$EDGE" ]] || die "polygon-edge binary not found/executable at: $EDGE (run: make edge)"

if [[ "$RESET" == "1" ]]; then
  msg "RESET=1 -> removing $DATA_ROOT"
  rm -rf "$DATA_ROOT"
fi

mkdir -p "$NODE_DIR"

# --- Secrets init / Node ID ---
if [[ -f "$NODE_ID_FILE" ]]; then
  NODE_ID="$(tr -d '\r\n' < "$NODE_ID_FILE")"
else
  msg "Initializing validator secrets (DEV MODE)..."
  if [[ "$INSECURE_SECRETS" == "1" ]]; then
    msg "  [WARNING] Using --insecure (stores private keys on disk). DO NOT use in production."
    INIT_OUT="$("$EDGE" secrets init --data-dir "$NODE_DIR" --insecure 2>&1 | tee "$SECRETS_INIT_LOG")"
  else
    INIT_OUT="$("$EDGE" secrets init --data-dir "$NODE_DIR" 2>&1 | tee "$SECRETS_INIT_LOG")"
  fi

  # Your output format: "Node ID              = <peerid>"
  NODE_ID="$(echo "$INIT_OUT" | awk -F'= ' '/Node ID/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')"
  NODE_ID="$(echo -n "$NODE_ID" | tr -d '\r\n')"

  [[ -n "${NODE_ID:-}" ]] || die "Could not parse Node ID. Check $SECRETS_INIT_LOG"
  echo "$NODE_ID" > "$NODE_ID_FILE"
fi

LIBP2P_HOST="${LIBP2P_ADDR%:*}"
LIBP2P_PORT="${LIBP2P_ADDR##*:}"

# Multiaddr format required for bootnodes: /ip4/<ip>/tcp/<port>/p2p/<node_id> :contentReference[oaicite:2]{index=2}
BOOTNODE="${BOOTNODE:-/ip4/${LIBP2P_HOST}/tcp/${LIBP2P_PORT}/p2p/${NODE_ID}}"

# --- Genesis (NOTE: pass --bootnode HERE; your Edge requires it) :contentReference[oaicite:3]{index=3}
if [[ -f "$GENESIS_PATH" ]]; then
  msg "Genesis exists: $GENESIS_PATH (reusing)"
else
  msg "Generating genesis: $GENESIS_PATH"
  GENESIS_ARGS=(
    genesis
    --consensus "$CONSENSUS"
    --ibft-validators-prefix-path "$NODE_DIR"
    --bootnode "$BOOTNODE"
    --dir "$GENESIS_PATH"
  )
  if [[ "$IBFT_POS" == "1" ]]; then
    GENESIS_ARGS+=(--pos)
  fi
  "$EDGE" "${GENESIS_ARGS[@]}" >/dev/null
fi

msg ""
msg "Starting Polygon Edge node..."
msg "  JSON-RPC : http://${RPC_HOST}:${RPC_PORT}"
msg "  Metrics  : http://${METRICS_HOST}:${METRICS_PORT}/metrics"
msg "  LibP2P   : ${LIBP2P_ADDR}"
msg "  Bootnode : ${BOOTNODE}"
msg "  Data dir : ${NODE_DIR}"
msg "  Genesis  : ${GENESIS_PATH}"
msg "  Tip      : RESET=1 ./scripts/devnet-single.sh"
msg ""

# In the common IBFT local setup flow, nodes are started with the generated genesis/config; bootnodes are already embedded. :contentReference[oaicite:4]{index=4}
exec "$EDGE" server \
  --data-dir "$NODE_DIR" \
  --chain "$GENESIS_PATH" \
  --grpc-address "$GRPC_ADDR" \
  --libp2p "$LIBP2P_ADDR" \
  --jsonrpc "${RPC_HOST}:${RPC_PORT}" \
  --prometheus "${METRICS_HOST}:${METRICS_PORT}"
