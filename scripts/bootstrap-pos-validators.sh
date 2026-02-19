#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/evm.sh"

require_tool
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

DEPLOYMENTS_FILE="${POS_DEPLOYMENTS_FILE:-$ROOT/build/deployments/pos.local.json}"
BOOTSTRAP_FILE="${POS_BOOTSTRAP_CONFIG:-$ROOT/config/pos.bootstrap.json}"

[[ -f "$DEPLOYMENTS_FILE" ]] || { echo "missing deployments file: $DEPLOYMENTS_FILE" >&2; exit 1; }
[[ -f "$BOOTSTRAP_FILE" ]] || { echo "missing bootstrap config: $BOOTSTRAP_FILE" >&2; exit 1; }

STAKING_ADDRESS="$(jq -r '.staking.address // empty' "$DEPLOYMENTS_FILE")"
[[ -n "$STAKING_ADDRESS" ]] || { echo "staking.address missing in $DEPLOYMENTS_FILE" >&2; exit 1; }

: "${POS_DEPLOYER_PK:?POS_DEPLOYER_PK is required}"
DEPLOYER_ADDRESS="$(cast wallet address --private-key "$POS_DEPLOYER_PK")"

resolve_token() {
  local value="$1"
  if [[ "$value" =~ ^\{\{([A-Z0-9_]+)\}\}$ ]]; then
    local token="${BASH_REMATCH[1]}"
    local resolved="${!token:-}"
    if [[ -z "$resolved" ]]; then
      echo "$value"
    else
      echo "$resolved"
    fi
    return
  fi
  echo "$value"
}

load_consensus_key() {
  local path="$1"
  [[ -f "$path" ]] || { echo "consensus key file not found: $path" >&2; return 1; }
  local raw
  raw="$(tr -d '[:space:]' < "$path")"
  raw="${raw#0x}"
  raw="${raw,,}"
  [[ -n "$raw" ]] || { echo "consensus key in $path is empty" >&2; return 1; }
  [[ "$raw" =~ ^[0-9a-f]+$ ]] || { echo "consensus key in $path is not hex" >&2; return 1; }
  echo "0x$raw"
}

is_registered() {
  local operator="$1"
  local out
  out="$(evm_call "$STAKING_ADDRESS" 'getOperator(address)((address,address,bytes,uint256,bool,bool))' "$operator")"
  [[ "$out" == *", true,"* || "$out" == *",true,"* ]]
}

operator_pk_for_index() {
  local idx="$1"
  local from_config_env
  from_config_env="$(jq -r --argjson idx "$idx" '.operators[$idx].privateKeyEnv // empty' "$BOOTSTRAP_FILE")"
  if [[ -n "$from_config_env" ]]; then
    echo "${!from_config_env:-}"
    return
  fi

  local key="OPERATOR${idx}_PK"
  if [[ -n "${!key:-}" ]]; then
    echo "${!key}"
    return
  fi

  echo ""
}

count="$(jq '.operators | length' "$BOOTSTRAP_FILE")"
for ((i=0; i<count; i++)); do
  operator="$(resolve_token "$(jq -r --argjson idx "$i" '.operators[$idx].operator' "$BOOTSTRAP_FILE")")"
  payout="$(resolve_token "$(jq -r --argjson idx "$i" '.operators[$idx].payout' "$BOOTSTRAP_FILE")")"
  key_file="$(jq -r --argjson idx "$i" '.operators[$idx].consensusKeyFile' "$BOOTSTRAP_FILE")"
  initial_stake="$(jq -r --argjson idx "$i" '.operators[$idx].initialStakeWei // "0"' "$BOOTSTRAP_FILE")"

  consensus_key="$(load_consensus_key "$ROOT/$key_file")"

  operator_pk="$(operator_pk_for_index "$i")"
  if [[ -z "$operator_pk" ]]; then
    if [[ "${operator,,}" == "${DEPLOYER_ADDRESS,,}" ]]; then
      operator_pk="$POS_DEPLOYER_PK"
    else
      echo "missing private key for operator[$i]=$operator (set operators[$i].privateKeyEnv or OPERATOR${i}_PK)" >&2
      exit 1
    fi
  fi

  operator_from_pk="$(cast wallet address --private-key "$operator_pk")"
  if [[ "${operator,,}" != "${operator_from_pk,,}" ]]; then
    echo "operator[$i] address ($operator) does not match provided private key address ($operator_from_pk)" >&2
    exit 1
  fi

  if is_registered "$operator"; then
    echo "operator already registered: $operator"
  else
    evm_send "$operator_pk" "$STAKING_ADDRESS" 'registerOperator(bytes,address)' "$consensus_key" "$payout" >/dev/null
    echo "registered operator: $operator"
  fi

  current_stake="$(evm_call "$STAKING_ADDRESS" 'stakeOf(address,address)(uint256)' "$operator" "$operator")"
  if [[ "$current_stake" =~ ^[0-9]+$ ]] && [[ "$initial_stake" =~ ^[0-9]+$ ]] && (( current_stake < initial_stake )); then
    top_up=$((initial_stake - current_stake))
    evm_send "$operator_pk" "$STAKING_ADDRESS" 'stake(address)' "$operator" --value "$top_up" >/dev/null
    echo "staked operator=$operator amount=$top_up"
  else
    echo "stake already >= target for operator: $operator"
  fi
done

echo "Active operators:"
evm_call "$STAKING_ADDRESS" 'getActiveOperators()(address[])'
echo "Active consensus keys:"
evm_call "$STAKING_ADDRESS" 'getActiveConsensusKeys()(bytes[])'
