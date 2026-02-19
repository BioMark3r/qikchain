#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[genesis] $*" >&2
}

die() {
  echo "[genesis] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

normalize_address() {
  local value="$1"
  value="${value#0x}"
  value="$(echo "$value" | tr '[:upper:]' '[:lower:]')"

  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || die "Invalid address: $1"
  echo "0x$value"
}

load_validators() {
  local validators_dir="$1"
  [[ -d "$validators_dir" ]] || die "Validator directory not found: $validators_dir"

  mapfile -t VALIDATORS < <(
    find "$validators_dir" -mindepth 2 -maxdepth 2 -type f -name address -print \
      | sort \
      | while read -r file; do
          addr="$(tr -d '\r\n[:space:]' < "$file")"
          normalize_address "$addr"
        done
  )

  [[ "${#VALIDATORS[@]}" -gt 0 ]] || die "No validator address files found under $validators_dir"

  mapfile -t VALIDATORS < <(printf '%s\n' "${VALIDATORS[@]}" | sort -u)
}

build_ibft_extra_data() {
  local joined
  joined="$(printf '%s\n' "${VALIDATORS[@]}" | paste -sd, -)"

  python3 - "$joined" <<'PY'
import sys

addrs = [a.strip().lower() for a in sys.argv[1].split(",") if a.strip()]


def to_binary(addr: str) -> bytes:
    if addr.startswith("0x"):
        addr = addr[2:]
    if len(addr) != 40:
        raise ValueError(f"invalid address length: {addr}")
    return bytes.fromhex(addr)


def enc_len(length: int, offset: int) -> bytes:
    if length < 56:
        return bytes([offset + length])
    data = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([offset + 55 + len(data)]) + data


def rlp_bytes(payload: bytes) -> bytes:
    if len(payload) == 1 and payload[0] < 0x80:
        return payload
    return enc_len(len(payload), 0x80) + payload


def rlp_list(items: list[bytes]) -> bytes:
    payload = b"".join(items)
    return enc_len(len(payload), 0xC0) + payload

validators_rlp = rlp_list([rlp_bytes(to_binary(addr)) for addr in addrs])
proposer_seal_rlp = rlp_bytes(bytes(65))
committed_seals_rlp = rlp_list([])
extra = bytes(32) + rlp_list([validators_rlp, proposer_seal_rlp, committed_seals_rlp])
print("0x" + extra.hex())
PY
}

build_allocations_json() {
  local allocations_file="$1"
  local validators_amount="$2"
  local treasury_amount="$3"
  local faucet_amount="$4"
  local treasury_address="$5"
  local faucet_address="$6"

  local validators_json
  validators_json="$(printf '%s\n' "${VALIDATORS[@]}" | jq -R . | jq -s '.')"

  jq -n \
    --arg treasuryAddress "$treasury_address" \
    --arg treasuryAmount "$treasury_amount" \
    --arg faucetAddress "$faucet_address" \
    --arg faucetAmount "$faucet_amount" \
    --arg validatorAmount "$validators_amount" \
    --argjson validators "$validators_json" \
    '
      reduce $validators[] as $v ({}; . + {($v): {"balance": $validatorAmount}})
      + {
          ($treasuryAddress): {"balance": $treasuryAmount},
          ($faucetAddress): {"balance": $faucetAmount}
        }
    '
}

render_template() {
  local template_file="$1"
  local chain_id="$2"
  local block_gas_limit="$3"
  local min_gas_price="$4"
  local base_fee_enabled="$5"
  local validator_extra_data="$6"
  local preallocations_json="$7"

  python3 - "$template_file" "$chain_id" "$block_gas_limit" "$min_gas_price" "$base_fee_enabled" "$validator_extra_data" "$preallocations_json" <<'PY'
import json
import pathlib
import sys

template = pathlib.Path(sys.argv[1]).read_text()
chain_id, block_gas_limit, min_gas_price, base_fee_enabled, extra_data, preallocations = sys.argv[2:]

replacements = {
    "{{CHAIN_ID}}": chain_id,
    "{{BLOCK_GAS_LIMIT}}": block_gas_limit,
    "{{MIN_GAS_PRICE}}": min_gas_price,
    "{{BASE_FEE_ENABLED}}": base_fee_enabled,
    "{{VALIDATOR_EXTRA_DATA}}": extra_data,
    "{{PREALLOCATIONS}}": preallocations,
}

for key, value in replacements.items():
    template = template.replace(key, value)

json.loads(template)
print(template)
PY
}

load_allocation_amount() {
  local key="$1"
  local file="$2"
  jq -r --arg key "$key" '.[$key]' "$file"
}
