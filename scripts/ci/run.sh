#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CI_INTEGRATION="${CI_INTEGRATION:-1}"
CI_TX="${CI_TX:-0}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

printf 'go version: '
go version
printf 'node version: '
node --version
printf 'npm version: '
npm --version
printf 'make version: '
make --version | head -n 1

echo "==> Checking Go formatting"
mapfile -t go_files < <(find . -type f -name '*.go' -not -path './third_party/*')
if [ "${#go_files[@]}" -eq 0 ]; then
  echo "No Go files found"
else
  mapfile -t unformatted < <(gofmt -l "${go_files[@]}")
  if [ "${#unformatted[@]}" -gt 0 ]; then
    echo "The following files need gofmt:" >&2
    printf '%s\n' "${unformatted[@]}" >&2
    exit 1
  fi
fi

echo "==> Running unit tests"
go test ./... -count=1

echo "==> Building"
make build

if [ "$CI_INTEGRATION" = "1" ]; then
  echo "==> Running integration tests"
  RPC_URL="$RPC_URL" bash scripts/tests/integration.sh
else
  echo "==> Skipping integration tests (CI_INTEGRATION=$CI_INTEGRATION)"
fi

if [ "$CI_TX" = "1" ]; then
  echo "==> Running tx integration tests"
  RPC_URL="$RPC_URL" bash scripts/tests/tx_integration.sh
else
  echo "==> Skipping tx integration tests (CI_TX=$CI_TX)"
fi
