#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
RPC_TIMEOUT_SECONDS="${RPC_TIMEOUT_SECONDS:-120}"
RPC_POLL_INTERVAL_SECONDS="${RPC_POLL_INTERVAL_SECONDS:-2}"
RECEIPT_TIMEOUT_SECONDS="${RECEIPT_TIMEOUT_SECONDS:-120}"
GAS_MULTIPLIER="${GAS_MULTIPLIER:-1.2}"
BURN_ADDRESS="${BURN_ADDRESS:-0x000000000000000000000000000000000000dEaD}"
STATUS_UI_URL="${STATUS_UI_URL:-http://127.0.0.1:8788}"
TX_HTTP_URL="${TX_HTTP_URL:-}"
TX_TOKEN="${TX_TOKEN:-}"
DEVNET_ALREADY_RUNNING="${DEVNET_ALREADY_RUNNING:-0}"

NODE_WORKDIR=""
SENDER_PRIVATE_KEY=""
SENDER_ADDRESS=""
CHAIN_ID=""

has_make_target() {
  make -qp | awk -F: '/^[[:alnum:]_.-]+:/{print $1}' | grep -Fx "$1" >/dev/null 2>&1
}

cleanup() {
  set +e
  if [ "$DEVNET_ALREADY_RUNNING" = "1" ]; then
    return
  fi

  if has_make_target "faucet-down"; then
    make faucet-down >/dev/null 2>&1 || true
  elif has_make_target "faucet-stop"; then
    make faucet-stop >/dev/null 2>&1 || true
  fi

  if has_make_target "stop-ui"; then
    make stop-ui >/dev/null 2>&1 || true
  fi

  make down >/dev/null 2>&1 || true
}

json_get() {
  local json="$1"
  local expr="$2"
  JSON_INPUT="$json" JSON_EXPR="$expr" node <<'NODE'
const obj = JSON.parse(process.env.JSON_INPUT);
const expr = process.env.JSON_EXPR;
let cur = obj;
for (const part of expr.split('.')) {
  if (!part) continue;
  if (cur == null || !(part in cur)) {
    process.stdout.write('');
    process.exit(0);
  }
  cur = cur[part];
}
if (cur === null || cur === undefined) process.stdout.write('');
else if (typeof cur === 'object') process.stdout.write(JSON.stringify(cur));
else process.stdout.write(String(cur));
NODE
}

rpc_call() {
  local method="$1"
  local params_json="$2"
  curl -fsS -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params_json},\"id\":1}" \
    "$RPC_URL"
}

rpc_get_result() {
  local method="$1"
  local params_json="$2"
  local response
  response="$(rpc_call "$method" "$params_json")"
  local err
  err="$(json_get "$response" "error.message")"
  if [ -n "$err" ]; then
    echo "RPC error from ${method}: $err" >&2
    return 1
  fi
  json_get "$response" "result"
}

wait_for_rpc() {
  echo "==> Waiting for JSON-RPC at $RPC_URL"
  local deadline=$((SECONDS + RPC_TIMEOUT_SECONDS))
  while true; do
    local block
    block="$(rpc_get_result eth_blockNumber '[]' 2>/dev/null || true)"
    if [ -n "$block" ]; then
      echo "eth_blockNumber=$block"
      return 0
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "Timed out waiting for JSON-RPC at $RPC_URL" >&2
      exit 1
    fi
    sleep "$RPC_POLL_INTERVAL_SECONDS"
  done
}

wait_for_receipt() {
  local tx_hash="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))

  while true; do
    local receipt
    receipt="$(rpc_get_result eth_getTransactionReceipt "[\"${tx_hash}\"]")"
    if [ "$receipt" != "" ] && [ "$receipt" != "null" ]; then
      printf '%s' "$receipt"
      return 0
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "Timed out waiting for receipt for tx ${tx_hash}" >&2
      return 1
    fi

    sleep 2
  done
}

assert_receipt_success() {
  local receipt_json="$1"
  local status
  status="$(json_get "$receipt_json" "status")"
  if [ "$status" != "0x1" ] && [ "$status" != "1" ]; then
    echo "Transaction failed; receipt status=$status" >&2
    echo "$receipt_json" >&2
    exit 1
  fi
}

get_nonce() {
  local address="$1"
  rpc_get_result eth_getTransactionCount "[\"${address}\",\"pending\"]"
}

get_gas_price() {
  rpc_get_result eth_gasPrice '[]'
}

estimate_gas() {
  local tx_obj_json="$1"
  rpc_get_result eth_estimateGas "[${tx_obj_json}]"
}

ensure_node_workspace() {
  if [ -n "$NODE_WORKDIR" ]; then
    return
  fi

  NODE_WORKDIR="$(mktemp -d)"
  pushd "$NODE_WORKDIR" >/dev/null
  npm init -y >/dev/null
  npm install --silent ethers@^6 >/dev/null
  popd >/dev/null
}

normalize_private_key() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  if [[ "$raw" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    printf '%s' "$raw"
    return 0
  fi
  if [[ "$raw" =~ ^[0-9a-fA-F]{64}$ ]]; then
    printf '0x%s' "$raw"
    return 0
  fi
  return 1
}

derive_address_from_key() {
  local pk="$1"
  ensure_node_workspace
  NODE_PATH="$NODE_WORKDIR/node_modules" PRIVATE_KEY="$pk" node <<'NODE'
const { Wallet } = require('ethers');
const pk = process.env.PRIVATE_KEY;
const wallet = new Wallet(pk);
process.stdout.write(wallet.address);
NODE
}

discover_devnet_private_key() {
  local candidate
  while IFS= read -r candidate; do
    [ -f "$candidate" ] || continue
    local raw
    raw="$(head -n1 "$candidate" | tr -d '[:space:]')"
    local normalized
    normalized="$(normalize_private_key "$raw" 2>/dev/null || true)"
    if [ -z "$normalized" ]; then
      continue
    fi
    if PRIVATE_KEY="$normalized" derive_address_from_key "$normalized" >/dev/null 2>&1; then
      printf '%s' "$normalized"
      return 0
    fi
  done < <(find "$ROOT/.data" -type f \( -name 'validator.key' -o -name 'ecdsa.key' -o -name 'priv_key' \) 2>/dev/null | sort)

  return 1
}

resolve_sender() {
  local candidate=""
  if [ -n "${SENDER_PRIVATE_KEY:-}" ]; then
    candidate="${SENDER_PRIVATE_KEY}"
  elif [ -n "${FAUCET_PRIVATE_KEY:-}" ]; then
    candidate="${FAUCET_PRIVATE_KEY}"
  else
    candidate="$(discover_devnet_private_key 2>/dev/null || true)"
  fi

  if [ -z "$candidate" ]; then
    echo "tx tests skipped: no key"
    exit 0
  fi

  local normalized
  normalized="$(normalize_private_key "$candidate" 2>/dev/null || true)"
  if [ -z "$normalized" ]; then
    echo "tx tests skipped: no key"
    exit 0
  fi

  local addr
  addr="$(derive_address_from_key "$normalized" 2>/dev/null || true)"
  if [ -z "$addr" ]; then
    echo "tx tests skipped: no key"
    exit 0
  fi

  SENDER_PRIVATE_KEY="$normalized"
  SENDER_ADDRESS="$addr"
  echo "Using sender address: $SENDER_ADDRESS"
}

sign_tx() {
  local nonce_hex="$1"
  local gas_price_hex="$2"
  local gas_limit_hex="$3"
  local to_addr="$4"
  local value_wei="$5"
  local data_hex="$6"

  ensure_node_workspace

  NODE_PATH="$NODE_WORKDIR/node_modules" \
  PRIVATE_KEY="$SENDER_PRIVATE_KEY" \
  CHAIN_ID="$CHAIN_ID" \
  NONCE_HEX="$nonce_hex" \
  GAS_PRICE_HEX="$gas_price_hex" \
  GAS_LIMIT_HEX="$gas_limit_hex" \
  GAS_MULTIPLIER="$GAS_MULTIPLIER" \
  TO_ADDR="$to_addr" \
  VALUE_WEI="$value_wei" \
  DATA_HEX="$data_hex" \
  node <<'NODE'
const { Wallet, getAddress } = require('ethers');

function parseChainId(raw) {
  if (raw.startsWith('0x')) return Number(BigInt(raw));
  return Number(raw);
}

const wallet = new Wallet(process.env.PRIVATE_KEY);
const gas = BigInt(process.env.GAS_LIMIT_HEX);
const multiplier = Number(process.env.GAS_MULTIPLIER || '1.2');
const scaledGas = BigInt(Math.ceil(Number(gas) * multiplier));
const tx = {
  chainId: parseChainId(process.env.CHAIN_ID),
  nonce: BigInt(process.env.NONCE_HEX),
  gasPrice: BigInt(process.env.GAS_PRICE_HEX),
  gasLimit: scaledGas,
  to: process.env.TO_ADDR ? getAddress(process.env.TO_ADDR) : null,
  value: BigInt(process.env.VALUE_WEI || '0'),
  data: process.env.DATA_HEX || '0x',
};
wallet.signTransaction(tx).then((signed) => process.stdout.write(signed));
NODE
}

send_raw_and_wait() {
  local raw_tx="$1"
  local send_resp tx_hash
  send_resp="$(rpc_call eth_sendRawTransaction "[\"${raw_tx}\"]")"
  tx_hash="$(json_get "$send_resp" "result")"
  if [ -z "$tx_hash" ]; then
    echo "eth_sendRawTransaction failed: $send_resp" >&2
    exit 1
  fi
  echo "submitted tx: $tx_hash"

  local receipt
  receipt="$(wait_for_receipt "$tx_hash" "$RECEIPT_TIMEOUT_SECONDS")"
  assert_receipt_success "$receipt"
  printf '%s' "$receipt"
}

start_devnet_if_needed() {
  if [ "$DEVNET_ALREADY_RUNNING" = "1" ]; then
    echo "==> DEVNET_ALREADY_RUNNING=1, reusing existing devnet"
    return
  fi

  trap cleanup EXIT
  echo "==> Starting fresh devnet with RESET=1"
  make down >/dev/null 2>&1 || true
  RESET=1 make up
}

detect_ui_tx_mode() {
  if [ -n "$TX_HTTP_URL" ]; then
    if [ -z "$TX_TOKEN" ]; then
      echo "TX_HTTP_URL is set but TX_TOKEN is missing" >&2
      exit 1
    fi
    return 0
  fi

  if [ -z "$TX_TOKEN" ]; then
    return 1
  fi

  local config_json
  config_json="$(curl -fsS "$STATUS_UI_URL/api/config" 2>/dev/null || true)"
  if [ -z "$config_json" ]; then
    return 1
  fi

  if [ "$(json_get "$config_json" "txEnabled")" = "true" ]; then
    TX_HTTP_URL="$STATUS_UI_URL/api/tx/send-wei"
    return 0
  fi

  return 1
}

ui_base_url() {
  local url="$1"
  printf '%s' "$url" | sed -E 's#/api/tx/.*$##'
}

run_test_send_wei() {
  echo "==> Test 1: send 1 wei to burn address"

  if detect_ui_tx_mode; then
    local base send_url response tx_hash receipt
    base="$(ui_base_url "$TX_HTTP_URL")"
    send_url="$base/api/tx/send-wei"

    response="$(curl -fsS -H "X-TX-TOKEN: $TX_TOKEN" -H 'content-type: application/json' \
      --data "{\"rpcUrl\":\"$RPC_URL\"}" "$send_url")"
    tx_hash="$(json_get "$response" "txHash")"
    if [ -z "$tx_hash" ]; then
      tx_hash="$(json_get "$response" "result.txHash")"
    fi
    if [ -z "$tx_hash" ]; then
      echo "send-wei endpoint did not return tx hash: $response" >&2
      exit 1
    fi

    receipt="$(wait_for_receipt "$tx_hash" "$RECEIPT_TIMEOUT_SECONDS")"
    assert_receipt_success "$receipt"
    echo "send-wei via UI passed"
    return
  fi

  local nonce gas_price gas_estimate tx_obj raw_tx
  nonce="$(get_nonce "$SENDER_ADDRESS")"
  gas_price="$(get_gas_price)"
  tx_obj="{\"from\":\"$SENDER_ADDRESS\",\"to\":\"$BURN_ADDRESS\",\"value\":\"0x1\"}"
  gas_estimate="$(estimate_gas "$tx_obj")"
  raw_tx="$(sign_tx "$nonce" "$gas_price" "$gas_estimate" "$BURN_ADDRESS" "1" "0x")"
  send_raw_and_wait "$raw_tx" >/dev/null
  echo "send-wei direct RPC passed"
}

run_test_deploy_contract() {
  echo "==> Test 2: deploy minimal contract"
  local init_code="0x600a600c600039600a6000f3602a60005260206000f3"

  if detect_ui_tx_mode; then
    local base deploy_url response tx_hash receipt contract_addr code
    base="$(ui_base_url "$TX_HTTP_URL")"
    deploy_url="$base/api/tx/deploy-test-contract"

    response="$(curl -fsS -H "X-TX-TOKEN: $TX_TOKEN" -H 'content-type: application/json' \
      --data "{\"rpcUrl\":\"$RPC_URL\"}" "$deploy_url")"
    tx_hash="$(json_get "$response" "txHash")"
    if [ -z "$tx_hash" ]; then
      tx_hash="$(json_get "$response" "result.txHash")"
    fi
    if [ -z "$tx_hash" ]; then
      echo "deploy endpoint did not return tx hash: $response" >&2
      exit 1
    fi

    receipt="$(wait_for_receipt "$tx_hash" "$RECEIPT_TIMEOUT_SECONDS")"
    assert_receipt_success "$receipt"
    contract_addr="$(json_get "$receipt" "contractAddress")"
    if [ -z "$contract_addr" ] || [ "$contract_addr" = "null" ]; then
      echo "deploy receipt missing contractAddress" >&2
      exit 1
    fi
    code="$(rpc_get_result eth_getCode "[\"$contract_addr\",\"latest\"]")"
    if [ -z "$code" ] || [ "$code" = "0x" ]; then
      echo "deployed contract code is empty at $contract_addr" >&2
      exit 1
    fi
    echo "deploy via UI passed ($contract_addr)"
    return
  fi

  local nonce gas_price gas_estimate tx_obj raw_tx receipt contract_addr code
  nonce="$(get_nonce "$SENDER_ADDRESS")"
  gas_price="$(get_gas_price)"
  tx_obj="{\"from\":\"$SENDER_ADDRESS\",\"data\":\"$init_code\"}"
  gas_estimate="$(estimate_gas "$tx_obj")"
  raw_tx="$(sign_tx "$nonce" "$gas_price" "$gas_estimate" "" "0" "$init_code")"
  receipt="$(send_raw_and_wait "$raw_tx")"

  contract_addr="$(json_get "$receipt" "contractAddress")"
  if [ -z "$contract_addr" ] || [ "$contract_addr" = "null" ]; then
    echo "deploy receipt missing contractAddress" >&2
    exit 1
  fi

  code="$(rpc_get_result eth_getCode "[\"$contract_addr\",\"latest\"]")"
  if [ -z "$code" ] || [ "$code" = "0x" ]; then
    echo "deployed contract code is empty at $contract_addr" >&2
    exit 1
  fi
  echo "deploy direct RPC passed ($contract_addr)"
}

run_test_send_raw_explicit() {
  echo "==> Test 3: submit explicit raw signed tx (2 wei)"
  local dest="0x0000000000000000000000000000000000000001"
  local nonce gas_price gas_estimate tx_obj raw_tx response tx_hash receipt

  nonce="$(get_nonce "$SENDER_ADDRESS")"
  gas_price="$(get_gas_price)"
  tx_obj="{\"from\":\"$SENDER_ADDRESS\",\"to\":\"$dest\",\"value\":\"0x2\"}"
  gas_estimate="$(estimate_gas "$tx_obj")"
  raw_tx="$(sign_tx "$nonce" "$gas_price" "$gas_estimate" "$dest" "2" "0x")"

  if detect_ui_tx_mode; then
    local base raw_url
    base="$(ui_base_url "$TX_HTTP_URL")"
    raw_url="$base/api/tx/send-raw"
    response="$(curl -fsS -H "X-TX-TOKEN: $TX_TOKEN" -H 'content-type: application/json' \
      --data "{\"rawTxHex\":\"$raw_tx\",\"rpcUrl\":\"$RPC_URL\"}" "$raw_url")"
    tx_hash="$(json_get "$response" "txHash")"
    if [ -z "$tx_hash" ]; then
      tx_hash="$(json_get "$response" "result.txHash")"
    fi
    if [ -z "$tx_hash" ]; then
      echo "send-raw endpoint did not return tx hash: $response" >&2
      exit 1
    fi
    receipt="$(wait_for_receipt "$tx_hash" "$RECEIPT_TIMEOUT_SECONDS")"
  else
    receipt="$(send_raw_and_wait "$raw_tx")"
  fi

  assert_receipt_success "$receipt"
  echo "explicit raw tx passed"
}

main() {
  start_devnet_if_needed
  wait_for_rpc

  CHAIN_ID="$(rpc_get_result eth_chainId '[]')"
  if [ -z "$CHAIN_ID" ]; then
    echo "Failed to determine chain ID" >&2
    exit 1
  fi
  echo "chainId=$CHAIN_ID"

  resolve_sender

  run_test_send_wei
  run_test_deploy_contract
  run_test_send_raw_explicit

  echo "Tx integration checks passed"
}

main "$@"
