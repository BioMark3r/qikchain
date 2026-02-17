#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_ROOT="${DATA_ROOT:-$ROOT/.data}"
NET_DIR="${NET_DIR:-$DATA_ROOT/ibft4}"
PID_DIR="$NET_DIR/pids"

if [[ ! -d "$PID_DIR" ]]; then
  echo "No PID dir found at $PID_DIR"
  exit 0
fi

for pidfile in "$PID_DIR"/*.pid; do
  [[ -f "$pidfile" ]] || continue
  pid="$(cat "$pidfile" || true)"
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "Stopping PID $pid ($pidfile)"
    kill "$pid" || true
  fi
  rm -f "$pidfile" || true
done

echo "Done."
