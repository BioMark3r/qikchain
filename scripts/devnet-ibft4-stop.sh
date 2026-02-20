#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# QikChain Devnet Stop: IBFT 4-node
#
# Stops nodes started by scripts/devnet-ibft4.sh (pidfile-based),
# with safe fallbacks for port-based cleanup if needed.
#
# Usage:
#   ./scripts/devnet-ibft4-stop.sh
#   FORCE=1 ./scripts/devnet-ibft4-stop.sh         # escalate to SIGKILL sooner
#   CLEAN_PORTS=1 ./scripts/devnet-ibft4-stop.sh   # also kill anything still listening on known ports
#
# ============================================================

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DATA_ROOT="${DATA_ROOT:-$ROOT/.data}"
NET_NAME="${NET_NAME:-ibft4}"
NET_DIR="${NET_DIR:-$DATA_ROOT/$NET_NAME}"

FORCE="${FORCE:-0}"
CLEAN_PORTS="${CLEAN_PORTS:-0}"

# Match devnet-ibft4.sh defaults
RPC_PORTS=(8545 8546 8547 8548)
GRPC_PORTS=(9632 9633 9634 9635)
P2P_PORTS=(1478 1479 1480 1481)
METRICS_PORTS=(9090 9091 9092 9093)

NODE_DIRS=("$NET_DIR/node1" "$NET_DIR/node2" "$NET_DIR/node3" "$NET_DIR/node4")

log() { echo "[$(date +"%H:%M:%S")] $*"; }

kill_pid_gracefully() {
  local pid="$1"
  local label="$2"

  if ! kill -0 "$pid" 2>/dev/null; then
    log "$label: pid $pid not running"
    return 0
  fi

  log "$label: sending SIGTERM to pid $pid"
  kill "$pid" 2>/dev/null || true

  # Wait up to ~10s for graceful stop
  for _ in {1..20}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "$label: stopped"
      return 0
    fi
    sleep 0.5
  done

  if [[ "$FORCE" == "1" ]]; then
    log "$label: still running; sending SIGKILL to pid $pid (FORCE=1)"
    kill -9 "$pid" 2>/dev/null || true
  else
    log "$label: still running after SIGTERM (set FORCE=1 to SIGKILL)"
  fi
}

stop_via_pidfiles() {
  local any=0
  for i in 1 2 3 4; do
    local dir="${NODE_DIRS[$((i-1))]}"
    local pid_file="$dir/server.pid"
    local label="node$i"

    if [[ -f "$pid_file" ]]; then
      local pid
      pid="$(cat "$pid_file" 2>/dev/null || true)"
      if [[ -n "${pid:-}" ]]; then
        any=1
        kill_pid_gracefully "$pid" "$label"
      fi
      # Remove pidfile regardless to avoid stale state
      rm -f "$pid_file"
    else
      log "$label: no pidfile found ($pid_file)"
    fi
  done

  if [[ "$any" == "0" ]]; then
    log "No pidfiles found. If nodes are still running, consider CLEAN_PORTS=1."
  fi
}

# Safely kill anything still listening on known devnet ports
kill_listeners_on_ports() {
  local ports=("$@")
  for port in "${ports[@]}"; do
    # Using ss (Linux/WSL). If unavailable, try lsof.
    local pids=""
    if command -v ss >/dev/null 2>&1; then
      # Extract pid=1234 from ss output
      pids="$(ss -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print $0}' \
        | sed -nE 's/.*pid=([0-9]+),.*/\1/p' | sort -u)"
    elif command -v lsof >/dev/null 2>&1; then
      pids="$(lsof -ti tcp:"$port" 2>/dev/null | sort -u)"
    fi

    if [[ -n "$pids" ]]; then
      for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
          log "port $port: sending SIGTERM to pid $pid"
          kill "$pid" 2>/dev/null || true
        fi
      done
    fi
  done

  # Optionally escalate
  if [[ "$FORCE" == "1" ]]; then
    sleep 1
    for port in "${ports[@]}"; do
      local pids=""
      if command -v ss >/dev/null 2>&1; then
        pids="$(ss -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print $0}' \
          | sed -nE 's/.*pid=([0-9]+),.*/\1/p' | sort -u)"
      elif command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -ti tcp:"$port" 2>/dev/null | sort -u)"
      fi

      if [[ -n "$pids" ]]; then
        for pid in $pids; do
          if kill -0 "$pid" 2>/dev/null; then
            log "port $port: sending SIGKILL to pid $pid (FORCE=1)"
            kill -9 "$pid" 2>/dev/null || true
          fi
        done
      fi
    done
  fi
}

print_status() {
  log "Remaining listeners (expected none on devnet ports):"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | egrep ':(8545|8546|8547|8548|9090|9091|9092|9093|9632|9633|9634|9635|1478|1479|1480|1481)\b' || true
  else
    log "ss not available; skipping listener check"
  fi
}

main() {
  log "Stopping IBFT4 devnet at: $NET_DIR"
  stop_via_pidfiles

  if [[ "$CLEAN_PORTS" == "1" ]]; then
    log "CLEAN_PORTS=1: cleaning up any remaining listeners on known ports"
    kill_listeners_on_ports "${RPC_PORTS[@]}" "${GRPC_PORTS[@]}" "${P2P_PORTS[@]}" "${METRICS_PORTS[@]}"
  fi

  print_status
  log "Done."
}

main "$@"
