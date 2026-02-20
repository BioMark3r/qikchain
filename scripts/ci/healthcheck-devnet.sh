#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

STATUS_SCRIPT="$ROOT/scripts/devnet-ibft4-status.sh"
START_SCRIPT="$ROOT/scripts/devnet-ibft4.sh"
STOP_SCRIPT="$ROOT/scripts/devnet-ibft4-stop.sh"
NODE1_LOG="$ROOT/.data/ibft4/node1/server.log"

RPC_TIMEOUT_SECS="${RPC_TIMEOUT_SECS:-60}"
STATUS_TIMEOUT_SECS="${STATUS_TIMEOUT_SECS:-60}"
POLL_INTERVAL_SECS="${POLL_INTERVAL_SECS:-2}"

status_json=""

have() { command -v "$1" >/dev/null 2>&1; }

parse_status_fields() {
  local json="$1"
  if have jq; then
    printf '%s\t%s\t%s\n' \
      "$(printf '%s' "$json" | jq -r '.ok // false')" \
      "$(printf '%s' "$json" | jq -r '.sealing // false')" \
      "$(printf '%s' "$json" | jq -r '.nodes[0].rpc.peerCountHex // ""')"
    return
  fi

  python3 - <<'PY' "$json"
import json
import sys

data = json.loads(sys.argv[1])
ok = str(bool(data.get("ok", False))).lower()
sealing = str(bool(data.get("sealing", False))).lower()
peer_hex = ""
try:
    peer_hex = data["nodes"][0]["rpc"].get("peerCountHex") or ""
except Exception:
    pass
print(f"{ok}\t{sealing}\t{peer_hex}")
PY
}

peer_hex_ge_one() {
  local peer_hex="${1:-}"
  [[ -n "$peer_hex" && "$peer_hex" != "null" ]] || return 1

  if have jq; then
    jq -n --arg v "$peer_hex" '$v | ltrimstr("0x") | if . == "" then 0 else ("0x" + . | tonumber) end | . >= 1' | grep -q true
    return
  fi

  python3 - <<'PY' "$peer_hex"
import sys
v = (sys.argv[1] or "").strip().lower()
if not v:
    raise SystemExit(1)
if v.startswith("0x"):
    n = int(v, 16)
else:
    n = int(v)
raise SystemExit(0 if n >= 1 else 1)
PY
}

print_diagnostics() {
  echo "[healthcheck] diagnostics:"
  if [[ -n "$status_json" ]]; then
    echo "[healthcheck] last status JSON:"
    printf '%s\n' "$status_json"
  else
    echo "[healthcheck] status JSON unavailable"
  fi

  if [[ -f "$NODE1_LOG" ]]; then
    echo "[healthcheck] tail node1 log ($NODE1_LOG):"
    tail -n 120 "$NODE1_LOG" || true
  else
    echo "[healthcheck] node1 log not found: $NODE1_LOG"
  fi

  if have ss; then
    echo "[healthcheck] ss listeners (expected devnet ports):"
    ss -lntp | awk 'NR==1 || $4 ~ /:(8545|8546|8547|8548|9632|9633|9634|9635|1478|1479|1480|1481|9090|9091|9092|9093)$/' || true
  else
    echo "[healthcheck] ss command missing"
  fi
}

cleanup() {
  "$STOP_SCRIPT" || true
}
trap cleanup EXIT

if [[ ! -x "$STATUS_SCRIPT" ]]; then
  echo "[healthcheck] missing status script: $STATUS_SCRIPT"
  exit 1
fi

if [[ ! -x "$START_SCRIPT" ]]; then
  echo "[healthcheck] missing start script: $START_SCRIPT"
  exit 1
fi

if [[ ! -x "$STOP_SCRIPT" ]]; then
  echo "[healthcheck] missing stop script: $STOP_SCRIPT"
  exit 1
fi

echo "[healthcheck] starting devnet (fresh, poa)"
INSECURE_SECRETS=1 RESET=1 CONSENSUS=poa "$START_SCRIPT"

echo "[healthcheck] waiting for node1 RPC"
rpc_deadline=$((SECONDS + RPC_TIMEOUT_SECS))
while true; do
  if curl -fsS --max-time 2 http://127.0.0.1:8545 >/dev/null 2>&1; then
    break
  fi

  if (( SECONDS >= rpc_deadline )); then
    echo "[healthcheck] timeout waiting for node1 RPC after ${RPC_TIMEOUT_SECS}s"
    print_diagnostics
    exit 1
  fi

  sleep "$POLL_INTERVAL_SECS"
done

echo "[healthcheck] polling status JSON"
status_deadline=$((SECONDS + STATUS_TIMEOUT_SECS))
while true; do
  status_json="$(JSON=1 "$STATUS_SCRIPT" 2>/dev/null || true)"

  if [[ -n "$status_json" ]]; then
    fields="$(parse_status_fields "$status_json" 2>/dev/null || true)"
    ok_field="$(printf '%s' "$fields" | awk -F '\t' '{print $1}')"
    sealing_field="$(printf '%s' "$fields" | awk -F '\t' '{print $2}')"
    peer_hex_field="$(printf '%s' "$fields" | awk -F '\t' '{print $3}')"

    peer_ok=true
    if [[ -n "$peer_hex_field" && "$peer_hex_field" != "null" ]]; then
      if ! peer_hex_ge_one "$peer_hex_field"; then
        peer_ok=false
      fi
    fi

    if [[ "$ok_field" == "true" && "$sealing_field" == "true" && "$peer_ok" == "true" ]]; then
      echo "[healthcheck] healthy: ok=$ok_field sealing=$sealing_field node1.peerCountHex=${peer_hex_field:-n/a}"
      exit 0
    fi
  fi

  if (( SECONDS >= status_deadline )); then
    echo "[healthcheck] timeout waiting for healthy status after ${STATUS_TIMEOUT_SECS}s"
    print_diagnostics
    exit 1
  fi

  sleep "$POLL_INTERVAL_SECS"
done
