#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# reset-workdir.sh
#
# Purpose:
# - Stop all services
# - Clean runtime state (db/log/tmp) so toolkit starts from a fresh state
#
# What it removes:
# - db/* (stellar-core sqlite / stellar-rpc sqlite / captive-core db)
# - log/* (all logs)
# - tmp/* (pidfiles, cached history, markers)
#
# What it preserves:
# - opt/* configs
# - bin/* binaries
#
# Options:
#   RESET_KEEP_HISTORY=1   -> keep history archive directory content
#   RESET_KEEP_LOGS=1      -> keep log files
# -----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-$ROOT}"

DBDIR="$WORKDIR/db"
LOGDIR="$WORKDIR/log"
TMPDIR="$WORKDIR/tmp"

HIST_DIR="$WORKDIR/tmp/stellar-core/history/vs"
PIDDIR="$WORKDIR/tmp/pids"

MARKER_UPGRADE="$WORKDIR/tmp/.soroban_limits_upgraded"

log() { printf '%s\n' "$*" >&2; }

# -----------------------------------------------------------------------------
# 1) Stop services first (best effort)
# -----------------------------------------------------------------------------
if [[ -x "$WORKDIR/script/stop-service.sh" ]]; then
  log "[reset] stopping services..."
  bash "$WORKDIR/script/stop-service.sh" || true
fi

# -----------------------------------------------------------------------------
# 2) Remove DB files
# -----------------------------------------------------------------------------
log "[reset] cleaning db directory..."
if [[ -d "$DBDIR" ]]; then
  rm -rf "$DBDIR"/*
fi
mkdir -p "$DBDIR/stellar-core" "$DBDIR/stellar-rpc" "$DBDIR/captive-core"

# -----------------------------------------------------------------------------
# 3) Remove logs (optional)
# -----------------------------------------------------------------------------
if [[ "${RESET_KEEP_LOGS:-0}" == "1" ]]; then
  log "[reset] keeping logs (RESET_KEEP_LOGS=1)"
else
  log "[reset] cleaning log directory..."
  if [[ -d "$LOGDIR" ]]; then
    rm -rf "$LOGDIR"/*
  fi
fi
mkdir -p "$LOGDIR" "$LOGDIR/stellar-core"

# -----------------------------------------------------------------------------
# 4) Remove tmp files
# -----------------------------------------------------------------------------
log "[reset] cleaning tmp directory..."
if [[ -d "$TMPDIR" ]]; then
  rm -rf "$TMPDIR"
fi
mkdir -p "$TMPDIR" "$PIDDIR"

# -----------------------------------------------------------------------------
# 5) History archive handling
# -----------------------------------------------------------------------------
mkdir -p "$HIST_DIR"

if [[ "${RESET_KEEP_HISTORY:-0}" == "1" ]]; then
  log "[reset] keeping history archive contents (RESET_KEEP_HISTORY=1)"
else
  log "[reset] wiping history archive contents..."
  rm -rf "$HIST_DIR"/*
  mkdir -p "$HIST_DIR/.well-known"
fi

# -----------------------------------------------------------------------------
# 6) Remove upgrade marker
# -----------------------------------------------------------------------------
rm -f "$MARKER_UPGRADE" 2>/dev/null || true

log "[reset] done."
log "[reset] next step: run start-service.sh"

rm -rf "$WORKDIR"/buckets