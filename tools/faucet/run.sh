#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env.faucet"

init_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    echo ".env.faucet already exists"
  else
    cat >"${ENV_FILE}" <<'ENVEOF'
FAUCET_HOST=0.0.0.0
FAUCET_PORT=8787
FAUCET_RPC_URL=http://127.0.0.1:8545
FAUCET_AMOUNT_WEI=100000000000000000
FAUCET_TOKEN=devtoken-change-me
FAUCET_PRIVATE_KEY=
ENVEOF
    echo "Created .env.faucet"
  fi
  chmod 600 "${ENV_FILE}"
  echo "Next steps:"
  echo "  1) Edit .env.faucet and set FAUCET_PRIVATE_KEY + FAUCET_TOKEN"
  echo "  2) Run make faucet-up"
}

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  fi
}

apply_defaults() {
  export FAUCET_HOST="${FAUCET_HOST:-0.0.0.0}"
  export FAUCET_PORT="${FAUCET_PORT:-8787}"
  export FAUCET_RPC_URL="${FAUCET_RPC_URL:-${RPC_URL:-http://127.0.0.1:8545}}"
  export FAUCET_AMOUNT_WEI="${FAUCET_AMOUNT_WEI:-100000000000000000}"
}

print_missing_var_help() {
  local name="$1"
  echo "Error: Missing required faucet config: ${name}." >&2
  echo "Run next: make faucet-init" >&2
  echo "Then edit .env.faucet and set ${name}." >&2
  echo "Or export manually:" >&2
  echo "  export FAUCET_PRIVATE_KEY=..." >&2
  echo "  export FAUCET_TOKEN=..." >&2
}

validate_required() {
  local missing=0
  if [[ -z "${FAUCET_PRIVATE_KEY:-}" ]]; then
    print_missing_var_help "FAUCET_PRIVATE_KEY"
    missing=1
  fi
  if [[ -z "${FAUCET_TOKEN:-}" ]]; then
    print_missing_var_help "FAUCET_TOKEN"
    missing=1
  fi
  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

command="${1:-start}"
case "${command}" in
  init)
    init_env_file
    ;;
  validate)
    load_env_file
    apply_defaults
    validate_required
    echo "Faucet environment validated."
    ;;
  port)
    load_env_file
    apply_defaults
    echo "${FAUCET_PORT}"
    ;;
  url)
    load_env_file
    apply_defaults
    echo "FAUCET_URL=http://127.0.0.1:${FAUCET_PORT}"
    ;;
  start)
    load_env_file
    apply_defaults
    validate_required
    exec node "${ROOT_DIR}/tools/faucet/server.js"
    ;;
  *)
    echo "Usage: $0 [init|start|validate|port|url]" >&2
    exit 1
    ;;
esac
