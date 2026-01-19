#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Stellar Toolkit - start-service.sh
#
# Goals:
# - Fully relocatable: no absolute paths
# - Read global config from:   opt/env/toolkit.env
# - First boot only:
#     * stellar-core new-db / new-hist
#     * set protocol version upgrade
#     * apply Soroban settings/limits preset
# - Start order:
#     caddy -> stellar-core -> (first boot upgrades) -> stellar-rpc -> friendbot
#
# Notes:
# - friendbot must start AFTER upgrades, to avoid sequence conflicts.
# -----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# Logging controls
#
# LOG_LEVEL:
#   0 = quiet   (only key milestones + errors)
#   1 = normal  (default)
#   2 = verbose (show more debug output)
#
# You can override with:
#   LOG_LEVEL=0 bash script/start-service.sh
#   LOG_LEVEL=2 bash script/start-service.sh
# ----------------------------------------------------------------------------

LOG_LEVEL="${LOG_LEVEL:-1}"

log() {
  # usage: log <level:int> <message>
  local lvl="$1"; shift
  if [[ "$LOG_LEVEL" -ge "$lvl" ]]; then
    echo "$@"
  fi
}

log_step() {
  # always show steps in normal/verbose; still show in quiet but shorter.
  if [[ "$LOG_LEVEL" -eq 0 ]]; then
    echo "$1"
  else
    echo "$1"
  fi
}

run_quiet() {
  # usage: run_quiet <logfile> <cmd...>
  local logfile="$1"; shift
  if [[ "$LOG_LEVEL" -ge 2 ]]; then
    "$@"
  else
    "$@" >>"$logfile" 2>&1
  fi
}

# Toolkit root directory (script/..)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load env config (optional)
ENV_FILE="$ROOT/opt/env/toolkit.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# ---------------------------
# Defaults (keep minimal)
# ---------------------------
ENTRY_PORT="${ENTRY_PORT:-9000}"
HISTORY_PORT="${HISTORY_PORT:-1570}"
CORE_HTTP_PORT="${CORE_HTTP_PORT:-11626}"
RPC_PORT="${RPC_PORT:-9003}"
FRIENDBOT_PORT="${FRIENDBOT_PORT:-9002}"

LIMITS_PRESET="${LIMITS_PRESET:-testnet}"                # testnet | unlimited | default
TARGET_PROTOCOL_VERSION="${TARGET_PROTOCOL_VERSION:-25}"  # internal-maintained

# ---------------------------
# Paths (all relative)
# ---------------------------
PIDDIR="$ROOT/tmp/pids"
LOGDIR="$ROOT/log"
CORE_LOGDIR="$ROOT/log/stellar-core"
HIST_DIR="$ROOT/tmp/stellar-core/history/vs"

CADDY_BIN="$ROOT/bin/caddy/caddy"
STELLAR_CORE_BIN="$ROOT/bin/stellar-core/bin/stellar-core"
STELLAR_RPC_BIN="$ROOT/bin/stellar-rpc/stellar-rpc"
FRIENDBOT_BIN="$ROOT/bin/friendbot/friendbot"

# CADDY_CONF="$ROOT/opt/caddy/caddy.cfg"
# CORE_CONF="$ROOT/opt/stellar-core/stellar-core.cfg"
# RPC_CONF="$ROOT/opt/stellar-rpc/stellar-rpc.cfg"
# BOT_CONF="$ROOT/opt/friendbot/friendbot.cfg"

UPGRADE_SCRIPT="$ROOT/script/upgrade-soroban-limits-testnet.sh"

# stellar-core dynamic libs (bundled)
export DYLD_LIBRARY_PATH="$ROOT/bin/stellar-core/lib:${DYLD_LIBRARY_PATH:-}"

mkdir -p "$PIDDIR" "$LOGDIR" "$CORE_LOGDIR" "$HIST_DIR/.well-known"

# ---------------------------
# Generate Configs
# ---------------------------
GEN_LOG="$LOGDIR/gen-configs.log"
log_step "Generating configs ..."
run_quiet "$GEN_LOG" bash "$ROOT/script/gen-configs.sh"
log 2 "gen-configs log: $GEN_LOG"
CADDY_CONF="$ROOT/tmp/generated/caddy.cfg"
CORE_CONF="$ROOT/tmp/generated/stellar-core.cfg"
RPC_CONF="$ROOT/tmp/generated/stellar-rpc.cfg"
BOT_CONF="$ROOT/tmp/generated/friendbot.cfg"

# ---------------------------
# Utils
# ---------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

require_bin() {
  local p="$1"
  [[ -x "$p" ]] || die "binary not found or not executable: $p"
}

is_running() {
  local pidfile="$1"
  [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

start_bg() {
  local name="$1"
  local logfile="$2"
  shift 2

  local pidfile="$PIDDIR/$name.pid"
  if is_running "$pidfile"; then
    log 1 "$name already running (pid=$(cat "$pidfile"))."
    return 0
  fi

  log_step "Starting $name ..."
  nohup "$@" >>"$logfile" 2>&1 </dev/null &
  echo $! >"$pidfile"
  log 1 "$name started (pid=$(cat "$pidfile")) log=$logfile"
}

# ---------------------------
# Core HTTP helpers (no jq/python)
# ---------------------------
core_http_base() {
  echo "http://127.0.0.1:${CORE_HTTP_PORT}"
}

wait_core_http() {
  local url
  url="$(core_http_base)/info"
  echo "Waiting for stellar-core HTTP at $url ..."
  for _ in {1..120}; do
    if curl -sf "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "stellar-core HTTP not ready. Showing last 120 lines of core log:"
  tail -n 120 "$CORE_LOGDIR/stellar-core.log" || true
  return 1
}

core_ledger_version() {
  # Extract first occurrence: "version" : 25
  curl -sf "$(core_http_base)/info" \
    | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    | head -n1
}

arm_protocol_upgrade_if_needed() {
  local cur
  cur="$(core_ledger_version || true)"
  echo "core ledger.version=${cur:-<unknown>} target=$TARGET_PROTOCOL_VERSION"

  if [[ -z "${cur:-}" ]]; then
    echo "WARN: cannot read ledger.version; skip protocol upgrade"
    return 0
  fi

  if [[ "$cur" -ge "$TARGET_PROTOCOL_VERSION" ]]; then
    echo "protocol upgrade skipped (already >= target)"
    return 0
  fi

  echo "Arming network upgrade: protocolversion=$TARGET_PROTOCOL_VERSION ..."
  "$STELLAR_CORE_BIN" http-command --conf "$CORE_CONF" \
    "upgrades?mode=set&upgradetime=1970-01-01T00:00:00Z&protocolversion=$TARGET_PROTOCOL_VERSION" >/dev/null 2>&1 || true

  echo "Waiting protocol upgrade to reach $TARGET_PROTOCOL_VERSION ..."
  for _ in {1..180}; do
    local v
    v="$(core_ledger_version || true)"
    if [[ "$v" == "$TARGET_PROTOCOL_VERSION" ]]; then
      echo "protocol upgrade done: ledger.version=$v"
      return 0
    fi
    sleep 1
  done

  echo "WARN: protocol upgrade timed out; current=$(core_ledger_version || true)"
  return 0
}

upgrade_settings_if_needed(){
    # Apply Soroban settings only when preset != default
  if [[ "$LIMITS_PRESET" != "default" ]]; then
    [[ -f "$UPGRADE_SCRIPT" ]] || die "missing upgrade script: $UPGRADE_SCRIPT"
    chmod +x "$UPGRADE_SCRIPT"

    # Let upgrade script reuse our ports/paths in a relocatable way
    export WORKDIR="$ROOT"
    export CORE_BIN="$STELLAR_CORE_BIN"
    export CORE_CFG="$CORE_CONF"
    export HTTP_BASE="$(core_http_base)"
    export LIMITS_PRESET="$LIMITS_PRESET"

    UPGRADE_LOG="$LOGDIR/soroban-upgrade.log"
    log_step "[first boot] Upgrading Soroban limits preset '$LIMITS_PRESET' ..."
    if ! run_quiet "$UPGRADE_LOG" bash "$UPGRADE_SCRIPT"; then
      echo "ERROR: Soroban upgrade failed. Last 120 lines from $UPGRADE_LOG:"
      tail -n 120 "$UPGRADE_LOG" || true
      exit 1
    fi
    log 2 "soroban upgrade log: $UPGRADE_LOG"
  else
    log 1 "[first boot] LIMITS_PRESET=default, skip Soroban settings upgrade"
  fi
}

# ---------------------------
# RPC health check (JSON-RPC)
# ---------------------------
rpc_http_url() {
  echo "http://127.0.0.1:${RPC_PORT}"
}

rpc_healthy() {
  local url="$1"
  curl -s -m 2 -X POST "$url" 2>/dev/null \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
  | grep -q '"status"[[:space:]]*:[[:space:]]*"healthy"'
}

wait_for_rpc() {
  local url="$1"
  local max_tries="${2:-180}"

  log_step "Waiting for stellar-rpc to become healthy ..."
  for ((i=1; i<=max_tries; i++)); do
    if rpc_healthy "$url"; then
      log 1 "stellar-rpc is healthy."
      return 0
    fi
    sleep 1
  done

  echo "ERROR: stellar-rpc did not become healthy. Showing last 120 lines of rpc log:" >&2
  tail -n 120 "$ROOT/log/stellar-rpc.log" || true
  return 1
}

# ---------------------------
# macOS fix macos_permissions
# ---------------------------
auto_fix_macos_permissions() {
  # Only run on macOS
  [[ "$(uname -s)" == "Darwin" ]] || return 0

  # You can disable this behavior via env if needed:
  # AUTO_FIX_MACOS=0 bash script/start-service.sh
  if [[ "${AUTO_FIX_MACOS:-1}" != "1" ]]; then
    return 0
  fi

  # Quiet mode: do not spam logs unless something is clearly wrong
  xattr -dr com.apple.quarantine "$ROOT" 2>/dev/null || true

  chmod +x "$ROOT/bin/caddy/caddy" 2>/dev/null || true
  chmod +x "$ROOT/bin/friendbot/friendbot" 2>/dev/null || true
  chmod +x "$ROOT/bin/friendbot/loadtest" 2>/dev/null || true
  chmod +x "$ROOT/bin/stellar-rpc/stellar-rpc" 2>/dev/null || true
  chmod +x "$ROOT/bin/stellar-core/bin/stellar-core" 2>/dev/null || true

  # Ad-hoc sign (best effort)
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$ROOT/bin/caddy/caddy" 2>/dev/null || true
    codesign --force --sign - "$ROOT/bin/friendbot/friendbot" 2>/dev/null || true
    codesign --force --sign - "$ROOT/bin/friendbot/loadtest" 2>/dev/null || true
    codesign --force --sign - "$ROOT/bin/stellar-rpc/stellar-rpc" 2>/dev/null || true
    codesign --force --sign - "$ROOT/bin/stellar-core/bin/stellar-core" 2>/dev/null || true

    if compgen -G "$ROOT/bin/stellar-core/lib/*.dylib" >/dev/null; then
      codesign --force --sign - "$ROOT/bin/stellar-core/lib/"*.dylib 2>/dev/null || true
    fi
  fi
}

# ---------------------------
# First boot marker
# ---------------------------
FIRST_BOOT_MARK="$ROOT/tmp/.first_boot_done"

is_first_boot() {
  [[ ! -f "$FIRST_BOOT_MARK" ]]
}

mark_first_boot_done() {
  date >"$FIRST_BOOT_MARK"
}

# ---------------------------
# Gatekeeper quarantine detection (optional, recommended)
# ---------------------------
warn_if_quarantined() {
  local p="$1"
  if xattr -p com.apple.quarantine "$p" >/dev/null 2>&1; then
    echo "ERROR: macOS Gatekeeper quarantine detected on: $p"
    echo "Please run: bash $ROOT/script/bootstrap-macos.sh"
    exit 1
  fi
}

# ---------------------------
# Sanity checks
# ---------------------------
auto_fix_macos_permissions
require_bin "$CADDY_BIN"
require_bin "$STELLAR_CORE_BIN"
require_bin "$STELLAR_RPC_BIN"
require_bin "$FRIENDBOT_BIN"

[[ -f "$CADDY_CONF" ]] || die "missing config: $CADDY_CONF"
[[ -f "$CORE_CONF"  ]] || die "missing config: $CORE_CONF"
[[ -f "$RPC_CONF"   ]] || die "missing config: $RPC_CONF"
[[ -f "$BOT_CONF"   ]] || die "missing config: $BOT_CONF"

warn_if_quarantined "$CADDY_BIN"
warn_if_quarantined "$STELLAR_CORE_BIN"
warn_if_quarantined "$STELLAR_RPC_BIN"
warn_if_quarantined "$FRIENDBOT_BIN"

# -----------------------------------------------------------------------------
# 1) Start Caddy (history server + reverse proxy)
# -----------------------------------------------------------------------------
start_bg "caddy" "$ROOT/log/caddy.log" \
  "$CADDY_BIN" run --config "$CADDY_CONF" --adapter caddyfile

# -----------------------------------------------------------------------------
# 2) Initialize stellar-core only on first boot
# -----------------------------------------------------------------------------
if is_first_boot; then
  log_step "[first boot] Initializing stellar-core DB + history archive ..."
  CORE_INIT_LOG="$LOGDIR/stellar-core.init.log"
  run_quiet "$CORE_INIT_LOG" "$STELLAR_CORE_BIN" new-db --conf "$CORE_CONF" || true
  run_quiet "$CORE_INIT_LOG" "$STELLAR_CORE_BIN" new-hist vs --conf "$CORE_CONF" || true
  log 2 "core init log: $CORE_INIT_LOG"
else
  log 1 "[not first boot] Skip new-db/new-hist"
fi

# -----------------------------------------------------------------------------
# 3) Start stellar-core
# -----------------------------------------------------------------------------
start_bg "stellar-core" "$CORE_LOGDIR/stellar-core.log" \
  "$STELLAR_CORE_BIN" run --conf "$CORE_CONF"

wait_core_http

# -----------------------------------------------------------------------------
# 4) Start stellar-rpc
# -----------------------------------------------------------------------------
start_bg "stellar-rpc" "$ROOT/log/stellar-rpc.log" \
  "$STELLAR_RPC_BIN" --config-path "$RPC_CONF"

RPC_URL="$(rpc_http_url)"
wait_for_rpc "$RPC_URL"

# -----------------------------------------------------------------------------
# 5) First boot upgrades (protocol / soroban settings)
# -----------------------------------------------------------------------------
if is_first_boot; then
  log_step "[first boot] Applying protocol + Soroban settings (LIMITS_PRESET=$LIMITS_PRESET) ..."
  # Upgrade protocol version (from 0 -> target)
  arm_protocol_upgrade_if_needed
  upgrade_settings_if_needed
  mark_first_boot_done
  log 1 "[first boot] Done."
else
  log 1 "[not first boot] Skip protocol upgrades/Soroban settings upgrade"
fi

# -----------------------------------------------------------------------------
# 6) Start friendbot (must be last)
# -----------------------------------------------------------------------------
start_bg "friendbot" "$ROOT/log/friendbot.log" \
  "$FRIENDBOT_BIN" run --conf "$BOT_CONF"

echo "All services started."
echo "entry:     http://localhost:${ENTRY_PORT}"
echo "history:   http://localhost:${HISTORY_PORT}"
echo "rpc:       http://localhost:${ENTRY_PORT}/rpc"
echo "friendbot: http://localhost:${ENTRY_PORT}/friendbot"