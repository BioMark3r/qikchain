#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/evm.sh"
source "$ROOT/scripts/lib/json.sh"

require_tool
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v forge >/dev/null 2>&1 || { echo "forge is required" >&2; exit 1; }

CONFIG_FILE="${POS_CONTRACTS_CONFIG:-$ROOT/config/pos.contracts.json}"
OUT_FILE="${POS_DEPLOYMENTS_FILE:-$ROOT/build/deployments/pos.local.json}"
NETWORK="${POS_NETWORK:-local}"
RPC_URL="$(evm_rpc_url)"
FORCE_DEPLOY="${FORCE_DEPLOY:-0}"

[[ -f "$CONFIG_FILE" ]] || { echo "missing config file: $CONFIG_FILE" >&2; exit 1; }

: "${POS_DEPLOYER_PK:?POS_DEPLOYER_PK is required}"
DEPLOYER_ADDRESS="$(cast wallet address --private-key "$POS_DEPLOYER_PK")"
CHAIN_ID="$(evm_chain_id)"

mkdir -p "$(dirname "$OUT_FILE")"
if [[ ! -f "$OUT_FILE" ]]; then
  echo '{}' > "$OUT_FILE"
fi

is_deployed_and_code_present() {
  local address="$1"
  [[ -n "$address" && "$address" != "null" ]] || return 1
  local code
  code="$(evm_get_code "$address")"
  [[ "$code" != "0x" && "$code" != "0x0" ]]
}

load_existing_address() {
  local key="$1"
  jq -r --arg key "$key" '.[$key].address // empty' "$OUT_FILE"
}

contract_bytecode() {
  local fqcn="$1"
  forge inspect "$fqcn" bytecode
}

deploy_staking() {
  local existing
  existing="$(load_existing_address staking)"
  if [[ "$FORCE_DEPLOY" != "1" ]] && is_deployed_and_code_present "$existing"; then
    echo "$existing"
    return 0
  fi

  local min_stake max_validators unbonding_period constructor_admin
  constructor_admin="$DEPLOYER_ADDRESS"
  min_stake="$(jq -r '.staking.init.minStake' "$CONFIG_FILE")"
  max_validators="$(jq -r '.staking.init.maxValidators' "$CONFIG_FILE")"
  unbonding_period="$(jq -r '.staking.init.unbondingPeriod' "$CONFIG_FILE")"

  local bytecode tx_json tx_hash address
  bytecode="$(contract_bytecode contracts/QikStaking.sol:QikStaking)"
  tx_json="$(evm_deploy_contract "$POS_DEPLOYER_PK" "$bytecode" --constructor-args "$constructor_admin" "$min_stake" "$max_validators" "$unbonding_period")"
  tx_hash="$(echo "$tx_json" | jq -r '.transactionHash')"
  address="$(echo "$tx_json" | jq -r '.contractAddress')"

  is_deployed_and_code_present "$address" || { echo "staking deployment has no code: $address" >&2; exit 1; }
  jq \
    --arg network "$NETWORK" \
    --arg rpc "$RPC_URL" \
    --argjson chainId "$CHAIN_ID" \
    --arg deployer "$DEPLOYER_ADDRESS" \
    --arg address "$address" \
    --arg tx "$tx_hash" \
    '.network=$network | .rpc=$rpc | .chainId=$chainId | .deployer=$deployer | .staking={address:$address,tx:$tx}' \
    "$OUT_FILE" > "$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"

  echo "$address"
}

configure_staking_params() {
  local staking_address="$1"
  local desired_min desired_max desired_unbond
  desired_min="$(jq -r '.staking.init.minStake' "$CONFIG_FILE")"
  desired_max="$(jq -r '.staking.init.maxValidators' "$CONFIG_FILE")"
  desired_unbond="$(jq -r '.staking.init.unbondingPeriod' "$CONFIG_FILE")"

  local current_min current_max current_unbond
  current_min="$(evm_call "$staking_address" 'minStake()(uint256)')"
  current_max="$(evm_call "$staking_address" 'maxValidators()(uint256)')"
  current_unbond="$(evm_call "$staking_address" 'unbondingPeriod()(uint256)')"

  if [[ "$current_min" != "$desired_min" ]]; then
    evm_send "$POS_DEPLOYER_PK" "$staking_address" 'setMinStake(uint256)' "$desired_min" >/dev/null
  fi
  if [[ "$current_max" != "$desired_max" ]]; then
    evm_send "$POS_DEPLOYER_PK" "$staking_address" 'setMaxValidators(uint256)' "$desired_max" >/dev/null
  fi
  if [[ "$current_unbond" != "$desired_unbond" ]]; then
    evm_send "$POS_DEPLOYER_PK" "$staking_address" 'setUnbondingPeriod(uint256)' "$desired_unbond" >/dev/null
  fi
}

deploy_validator_set() {
  local staking_address="$1"
  local existing
  existing="$(load_existing_address validatorSet)"
  if [[ "$FORCE_DEPLOY" != "1" ]] && is_deployed_and_code_present "$existing"; then
    echo "$existing"
    return 0
  fi

  local bytecode tx_json tx_hash address
  bytecode="$(contract_bytecode contracts/QikValidatorSet.sol:QikValidatorSet)"
  tx_json="$(evm_deploy_contract "$POS_DEPLOYER_PK" "$bytecode" --constructor-args "$staking_address")"
  tx_hash="$(echo "$tx_json" | jq -r '.transactionHash')"
  address="$(echo "$tx_json" | jq -r '.contractAddress')"

  is_deployed_and_code_present "$address" || { echo "validatorSet deployment has no code: $address" >&2; exit 1; }
  jq --arg address "$address" --arg tx "$tx_hash" '.validatorSet={address:$address,tx:$tx}' "$OUT_FILE" > "$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"
  echo "$address"
}

staking_address="$(deploy_staking)"
configure_staking_params "$staking_address"
validator_set_address="$(deploy_validator_set "$staking_address")"

jq --arg network "$NETWORK" --arg rpc "$RPC_URL" --argjson chainId "$CHAIN_ID" --arg deployer "$DEPLOYER_ADDRESS" \
  '.network=$network | .rpc=$rpc | .chainId=$chainId | .deployer=$deployer' "$OUT_FILE" > "$OUT_FILE.tmp" && mv "$OUT_FILE.tmp" "$OUT_FILE"

cat "$OUT_FILE"
echo "deployed staking=$staking_address validatorSet=$validator_set_address"
