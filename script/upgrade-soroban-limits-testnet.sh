#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# upgrade-soroban-limits-testnet.sh
#
# Goal:
# - Align local network Soroban limits with a quickstart preset (testnet/unlimited)
# - Works against stellar-core admin HTTP endpoint: http://localhost:11626
#
# How it works (same as quickstart):
# - Derive NETWORK_ROOT account from NETWORK_PASSPHRASE (sha256 -> convert-id)
# - Use stellar-core get-settings-upgrade-txs to generate & sign 3~4 txs
# - Submit txs via core admin endpoint: /tx
# - Apply upgrade key via /upgrades
#
# Toolkit layout expectation:
#   <ROOT>/
#     bin/stellar-core/bin/stellar-core
#     opt/stellar-core/stellar-core.cfg
#     opt/upgrade/settings_enable_upgrades.json
#     opt/upgrade/p25/testnet.json
#     opt/upgrade/p25/unlimited.json
#     tmp/
#
# Dependencies (for now):
#   curl, jq, shasum, stellar (CLI), stellar-core binary
# -----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- configurable via env (but default is toolkit-relative) -------------------
WORKDIR="${WORKDIR:-$ROOT}"

CORE_BIN="${CORE_BIN:-$WORKDIR/bin/stellar-core/bin/stellar-core}"
CORE_CFG="${CORE_CFG:-$WORKDIR/opt/stellar-core/stellar-core.cfg}"

# core admin http
HTTP_BASE="${HTTP_BASE:-http://localhost:11626}"

# preset: testnet/unlimited
LIMITS_PRESET="${LIMITS_PRESET:-testnet}"

# upgrade json files
ENABLE_JSON="${ENABLE_JSON:-$WORKDIR/opt/upgrade/settings_enable_upgrades.json}"

# marker file: avoid running upgrades repeatedly
MARKER_FILE="${MARKER_FILE:-$WORKDIR/tmp/.soroban_limits_upgraded}"

TX_APPLY_TIMEOUT_S="${TX_APPLY_TIMEOUT_S:-180}"

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_file() { [[ -f "$1" ]] || die "missing file: $1"; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# -----------------------------------------------------------------------------
# Core readiness
# -----------------------------------------------------------------------------
wait_core_ready() {
  until curl -sf "$HTTP_BASE/info" >/dev/null; do
    sleep 1
  done
}

# -----------------------------------------------------------------------------
# Metrics / tx submission
# -----------------------------------------------------------------------------
tx_count() {
  curl -sf "$HTTP_BASE/metrics" | jq -r '.metrics."ledger.transaction.count".count'
}

wait_tx_inc() {
  local expected="$1"
  local start; start="$(date +%s)"

  while true; do
    local cur; cur="$(tx_count)"
    if [[ "$cur" == "$expected" ]]; then
      return 0
    fi

    if (( "$(date +%s)" - start >= TX_APPLY_TIMEOUT_S )); then
      log "timeout waiting ledger.transaction.count == $expected (cur=$cur)"
      log "/info:"
      curl -s "$HTTP_BASE/info" >&2 || true
      return 1
    fi

    sleep 1
  done
}

submit_tx() {
  local tx="$1"
  curl -sfG "$HTTP_BASE/tx" --data-urlencode "blob=$tx" | jq -r '.status'
}

set_upgrade_key() {
  local key="$1"
  local out
  out="$(curl -sfG "$HTTP_BASE/upgrades?mode=set&upgradetime=1970-01-01T00:00:00Z" \
    --data-urlencode "configupgradesetkey=$key")"
  log "set configupgradesetkey: ${out:-ok}"
}

encode_config_upgrade_set_xdr() {
  local json_path="$1"
  # Use Stellar CLI to encode JSON -> XDR base64
  # --quiet reduces noise, but if not supported it's OK to remove it
  stellar --quiet xdr encode --type ConfigUpgradeSet "$json_path" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Root account derivation (quickstart style)
# -----------------------------------------------------------------------------
derive_root_from_passphrase() {
  local passphrase="$1"

  local network_id
  network_id="$(printf '%s' "$passphrase" | shasum -a 256 | awk '{print $1}')"

  log "network_id:$network_id"

  # convert-id prints multiple interpretations, we only need the last 2 strKey lines
  local keys

  keys="$("$CORE_BIN" convert-id "$network_id" | awk -F': ' '/strKey: /{print $2}' | tail -2)"
  log "keys:$keys"

  local root_secret root_account
  root_secret="$(printf '%s\n' "$keys" | head -1)"
  root_account="$(printf '%s\n' "$keys" | tail -1)"

  [[ -n "${root_secret:-}" && -n "${root_account:-}" ]] || return 1

  printf '%s\n' "$root_secret" "$root_account"
}

# -----------------------------------------------------------------------------
# Main upgrade function
# -----------------------------------------------------------------------------
upgrade_soroban_config() {
  local config_file_path="$1"
  local seq_num="$2"

  log "upgrade_once: $(basename "$config_file_path") seq=$seq_num"

  local xdr
  xdr="$(encode_config_upgrade_set_xdr "$config_file_path")"
  [[ -n "${xdr:-}" ]] || die "xdr encode failed for $config_file_path"

  # IMPORTANT: keep the whole command in ONE LINE to avoid "--signtxs: command not found"
  local upgrade_output
  upgrade_output="$(
    printf '%s\n' "$NETWORK_ROOT_SECRET_KEY" | \
      "$CORE_BIN" get-settings-upgrade-txs \
        "$NETWORK_ROOT_ACCOUNT_ID" \
        "$seq_num" \
        "$NETWORK_PASSPHRASE" \
        --xdr "$xdr" \
        --signtxs
  )"

  local line_count
  line_count="$(printf '%s\n' "$upgrade_output" | wc -l | tr -d ' ')"

  local TX_COUNT
  TX_COUNT="$(tx_count)"
  [[ "$TX_COUNT" =~ ^[0-9]+$ ]] || die "cannot parse tx_count"
  TX_COUNT=$((TX_COUNT+1))

  printf '%s\n' "$upgrade_output" | {
    # 9 lines = restore tx+id + 3 tx+id + key
    if [[ "$line_count" == "9" ]]; then
      read -r tx; read -r txid
      log "restore txid: $txid .. $(submit_tx "$tx")"
      wait_tx_inc "$TX_COUNT"; TX_COUNT=$((TX_COUNT+1))
    fi

    read -r tx; read -r txid
    log "install txid:  $txid .. $(submit_tx "$tx")"
    wait_tx_inc "$TX_COUNT"; TX_COUNT=$((TX_COUNT+1))

    read -r tx; read -r txid
    log "deploy txid:   $txid .. $(submit_tx "$tx")"
    wait_tx_inc "$TX_COUNT"; TX_COUNT=$((TX_COUNT+1))

    read -r tx; read -r txid
    log "upload txid:   $txid .. $(submit_tx "$tx")"
    wait_tx_inc "$TX_COUNT"; TX_COUNT=$((TX_COUNT+1))

    read -r key
    log "config key:    $key"
    set_upgrade_key "$key"
  }

  log "upgrade_once: done"
}

# -----------------------------------------------------------------------------
# Entry
# -----------------------------------------------------------------------------
need_cmd curl
need_cmd jq
need_cmd shasum
need_cmd stellar

[[ -x "$CORE_BIN" ]] || die "missing stellar-core binary: $CORE_BIN"
need_file "$CORE_CFG"
need_file "$ENABLE_JSON"

# already upgraded?
if [[ -f "$MARKER_FILE" ]]; then
  log "marker exists: $MARKER_FILE"
  log "skip: soroban limits already upgraded"
  exit 0
fi

wait_core_ready

NETWORK_PASSPHRASE="$(grep -E '^NETWORK_PASSPHRASE=' "$CORE_CFG" | sed -E 's/^NETWORK_PASSPHRASE="(.*)".*/\1/')"
[[ -n "${NETWORK_PASSPHRASE:-}" ]] || die "cannot parse NETWORK_PASSPHRASE from $CORE_CFG"

# derive root keys from passphrase (quickstart style)
{
  read -r NETWORK_ROOT_SECRET_KEY
  read -r NETWORK_ROOT_ACCOUNT_ID
} < <(derive_root_from_passphrase "$NETWORK_PASSPHRASE") \
  || die "failed to derive root account from passphrase"
[[ -n "${NETWORK_ROOT_SECRET_KEY:-}" ]] || die "NETWORK_ROOT_SECRET_KEY empty"
[[ -n "${NETWORK_ROOT_ACCOUNT_ID:-}" ]] || die "NETWORK_ROOT_ACCOUNT_ID empty"

NETWORK_ROOT_SECRET_KEY="$NETWORK_ROOT_SECRET_KEY"
NETWORK_ROOT_ACCOUNT_ID="$NETWORK_ROOT_ACCOUNT_ID"

# detect core protocol (current ledger version)
PROTOCOL_VERSION="$(curl -sf "$HTTP_BASE/info" | jq -r '.info.ledger.version')"
[[ "$PROTOCOL_VERSION" =~ ^[0-9]+$ ]] || die "cannot parse protocol version from /info"

LIMITS_JSON="$WORKDIR/opt/upgrade/p${PROTOCOL_VERSION}/${LIMITS_PRESET}.json"
need_file "$LIMITS_JSON"

log "core protocol: $PROTOCOL_VERSION"
log "enable json:   $ENABLE_JSON"
log "limits preset: $LIMITS_PRESET"
log "limits json:   $LIMITS_JSON"
log "root account:  $NETWORK_ROOT_ACCOUNT_ID"
log "NOTE: assuming fresh DB sequence starts at 0."

log "[1/2] enable upgrades..."
upgrade_soroban_config "$ENABLE_JSON" 0

log "[2/2] apply '${LIMITS_PRESET}' limits..."
# quickstart behavior: second batch starts at seq=4 (or 5 if restore exists, but we assume fresh DB)
upgrade_soroban_config "$LIMITS_JSON" 4

# mark as done
mkdir -p "$(dirname "$MARKER_FILE")"
echo "protocol=$PROTOCOL_VERSION preset=$LIMITS_PRESET time=$(date -u +%FT%TZ)" > "$MARKER_FILE"

log "OK: soroban limits upgraded to '${LIMITS_PRESET}' (protocol $PROTOCOL_VERSION)"