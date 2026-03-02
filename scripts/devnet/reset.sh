#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
# shellcheck source=scripts/devnet/common.sh
source "$ROOT/scripts/devnet/common.sh"

log "RESET detected — wiping previous chain data."
"$ROOT/scripts/devnet/down.sh" || true

assert_safe_path_for_delete "$GENESIS_PATH"
assert_safe_path_for_delete "$DATA_ROOT"

rm -f "$GENESIS_PATH"
rm -rf "$DATA_ROOT"

"$ROOT/scripts/devnet/up.sh"
