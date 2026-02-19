#!/usr/bin/env bash
set -euo pipefail

require_tool() {
  if ! command -v cast >/dev/null 2>&1; then
    echo "[evm] ERROR: Foundry 'cast' is required for PoS deployment/bootstrap scripts." >&2
    echo "[evm] Install Foundry from https://book.getfoundry.sh/getting-started/installation" >&2
    return 1
  fi
}

evm_rpc_url() {
  echo "${EVM_RPC_URL:-${RPC_URL:-http://127.0.0.1:8545}}"
}

evm_chain_id() {
  require_tool >/dev/null
  cast chain-id --rpc-url "$(evm_rpc_url)"
}

evm_send_raw_tx() {
  local signed_tx="$1"
  require_tool >/dev/null
  cast publish --rpc-url "$(evm_rpc_url)" "$signed_tx"
}

evm_deploy_contract() {
  local from_pk="$1"
  local bytecode="$2"
  shift 2
  require_tool >/dev/null
  cast send --json --private-key "$from_pk" --create "$bytecode" "$@" --rpc-url "$(evm_rpc_url)"
}

evm_call() {
  local to="$1"
  local sig="$2"
  shift 2
  require_tool >/dev/null
  cast call "$to" "$sig" "$@" --rpc-url "$(evm_rpc_url)"
}

evm_send() {
  local from_pk="$1"
  local to="$2"
  local sig="$3"
  shift 3
  require_tool >/dev/null
  cast send --json --private-key "$from_pk" "$to" "$sig" "$@" --rpc-url "$(evm_rpc_url)"
}

evm_get_code() {
  local address="$1"
  require_tool >/dev/null
  cast code "$address" --rpc-url "$(evm_rpc_url)"
}

hex_to_bytes_literal() {
  local value="${1#0x}"
  echo "0x${value,,}"
}
