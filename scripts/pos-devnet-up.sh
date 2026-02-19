#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CONSENSUS=pos "$ROOT/scripts/generate-genesis.sh"
CONSENSUS=pos "$ROOT/scripts/devnet-ibft4.sh"
"$ROOT/scripts/deploy-pos-contracts.sh"
"$ROOT/scripts/bootstrap-pos-validators.sh"
