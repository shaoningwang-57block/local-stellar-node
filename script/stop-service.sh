#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# stop-service.sh
#
# Stops all toolkit services started by start-service.sh
# - Prefer PID files (safe)
# - Fallback to process pattern matching (best effort)
#
# Toolkit layout:
#   <ROOT>/
#     bin/...
#     tmp/pids/*.pid
# -----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="${WORKDIR:-$ROOT}"
PIDDIR="$WORKDIR/tmp/pids"
mkdir -p "$PIDDIR"

# NOTE:
# Pattern-kill is a fallback only.
# We intentionally include "$WORKDIR" in patterns to avoid killing other instances.
PAT_CADDY="$WORKDIR/bin/caddy/caddy run"
PAT_CORE="$WORKDIR/bin/stellar-core/bin/stellar-core run"
PAT_RPC="$WORKDIR/bin/stellar-rpc/stellar-rpc"
PAT_FRIENDBOT="$WORKDIR/bin/friendbot/friendbot run"

log() { printf '%s\n' "$*" >&2; }

is_running_pid() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null
}

stop_by_pidfile() {
  local name="$1"
  local pidfile="$PIDDIR/$name.pid"

  if [[ ! -f "$pidfile" ]]; then
    return 0
  fi

  local pid=""
  pid="$(cat "$pidfile" 2>/dev/null || true)"

  if [[ -z "${pid:-}" ]]; then
    rm -f "$pidfile"
    return 0
  fi

  if is_running_pid "$pid"; then
    log "Stopping $name (pid=$pid) ..."
    kill -TERM "$pid" 2>/dev/null || true

    # Wait up to ~8s for graceful shutdown
    for _ in {1..40}; do
      if is_running_pid "$pid"; then
        sleep 0.2
      else
        break
      fi
    done

    # Force kill if still running
    if is_running_pid "$pid"; then
      log "$name still running, forcing kill -KILL (pid=$pid) ..."
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi

  rm -f "$pidfile"
}

stop_by_pattern() {
  local name="$1"
  local pattern="$2"

  # Only if something matches the pattern
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    log "Fallback: stopping $name by pattern..."
    pkill -TERM -f "$pattern" 2>/dev/null || true
    sleep 0.4
    pkill -KILL -f "$pattern" 2>/dev/null || true
  fi
}

# Stop order (recommended):
# friendbot -> rpc -> core -> caddy
stop_by_pidfile "friendbot"
stop_by_pidfile "stellar-rpc"
stop_by_pidfile "stellar-core"
stop_by_pidfile "caddy"

# Fallback cleanup if pidfiles are missing/stale
stop_by_pattern "friendbot"   "$PAT_FRIENDBOT"
stop_by_pattern "stellar-rpc" "$PAT_RPC"
stop_by_pattern "stellar-core" "$PAT_CORE"
stop_by_pattern "caddy"       "$PAT_CADDY"

log "All services stopped."