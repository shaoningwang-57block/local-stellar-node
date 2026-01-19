#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# gen-configs.sh
# Generate runtime configs into tmp/generated/ from templates in opt/**/*
# No python, no jq. Compatible with macOS bash 3.2.
# -----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="${WORKDIR:-$ROOT}"

ENV_FILE="$WORKDIR/opt/env/toolkit.env"
OUT_DIR="$WORKDIR/tmp/generated"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[gen] $*" >&2; }

[[ -f "$ENV_FILE" ]] || die "missing env file: $ENV_FILE"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# shellcheck disable=SC1090
source "$ENV_FILE"

# Defaults
TOOLKIT_HTTP_PORT="${TOOLKIT_HTTP_PORT:-9000}"
HISTORY_HTTP_PORT="${HISTORY_HTTP_PORT:-1570}"
STELLAR_RPC_PORT="${STELLAR_RPC_PORT:-9003}"
FRIENDBOT_PORT="${FRIENDBOT_PORT:-9002}"
CORE_HTTP_PORT="${CORE_HTTP_PORT:-11626}"

CORE_PEER_PORT="${CORE_PEER_PORT:-11625}"
CAPTIVE_CORE_HTTP_PORT="${CAPTIVE_CORE_HTTP_PORT:-11826}"
CAPTIVE_CORE_PEER_PORT="${CAPTIVE_CORE_PEER_PORT:-11825}"

NETWORK_PASSPHRASE="${NETWORK_PASSPHRASE:-Standalone Network ; February 2017}"

# Where stellar-core binary is in your toolkit layout
CORE_BIN="${CORE_BIN:-$WORKDIR/bin/stellar-core/bin/stellar-core}"
[[ -x "$CORE_BIN" ]] || die "stellar-core not found or not executable: $CORE_BIN"

# Default NODE_SEED (your original one)
CORE_NODE_SEED="${CORE_NODE_SEED:-SBFKPGU6QFZOZIYXYF6NXVCTMKPWNJZYELJSXVWKICWW6IAVUGARAROX}"

escape_sed() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

derive_root_from_passphrase() {
  local passphrase="$1"
  local network_id keys root_secret root_account

  network_id="$(printf '%s' "$passphrase" | shasum -a 256 | awk '{print $1}')"
  keys="$("$CORE_BIN" convert-id "$network_id" | awk -F': ' '/strKey: /{print $2}' | tail -2)"

  root_secret="$(printf '%s\n' "$keys" | head -1)"
  root_account="$(printf '%s\n' "$keys" | tail -1)"

  [[ -n "${root_secret:-}" && -n "${root_account:-}" ]] || return 1
  printf '%s\n' "$root_secret" "$root_account"
}

# Derive root secret/account for friendbot + upgrades
{
  read -r NETWORK_ROOT_SECRET_KEY
  read -r NETWORK_ROOT_ACCOUNT_ID
} < <(derive_root_from_passphrase "$NETWORK_PASSPHRASE") \
  || die "failed to derive root keys from passphrase"

# Derive core validator pubkey from NODE_SEED
CORE_VALIDATOR_PUBKEY="$(printf '%s\n' "$CORE_NODE_SEED" | "$CORE_BIN" sec-to-pub 2>/dev/null || true)"
[[ -n "${CORE_VALIDATOR_PUBKEY:-}" ]] || die "failed to derive CORE_VALIDATOR_PUBKEY from CORE_NODE_SEED"

apply_template() {
  local in="$1"
  local out="$2"

  [[ -f "$in" ]] || die "missing template: $in"

  local E_WORKDIR E_NETWORK_PASSPHRASE E_CORE_NODE_SEED
  local E_TOOLKIT_HTTP_PORT E_HISTORY_HTTP_PORT E_STELLAR_RPC_PORT E_FRIENDBOT_PORT
  local E_CORE_HTTP_PORT E_CORE_PEER_PORT E_CAPTIVE_CORE_HTTP_PORT E_CAPTIVE_CORE_PEER_PORT
  local E_NETWORK_ROOT_SECRET_KEY E_NETWORK_ROOT_ACCOUNT_ID E_CORE_VALIDATOR_PUBKEY

  E_WORKDIR="$(escape_sed "$WORKDIR")"
  E_NETWORK_PASSPHRASE="$(escape_sed "$NETWORK_PASSPHRASE")"
  E_CORE_NODE_SEED="$(escape_sed "$CORE_NODE_SEED")"

  E_TOOLKIT_HTTP_PORT="$(escape_sed "$TOOLKIT_HTTP_PORT")"
  E_HISTORY_HTTP_PORT="$(escape_sed "$HISTORY_HTTP_PORT")"
  E_STELLAR_RPC_PORT="$(escape_sed "$STELLAR_RPC_PORT")"
  E_FRIENDBOT_PORT="$(escape_sed "$FRIENDBOT_PORT")"

  E_CORE_HTTP_PORT="$(escape_sed "$CORE_HTTP_PORT")"
  E_CORE_PEER_PORT="$(escape_sed "$CORE_PEER_PORT")"
  E_CAPTIVE_CORE_HTTP_PORT="$(escape_sed "$CAPTIVE_CORE_HTTP_PORT")"
  E_CAPTIVE_CORE_PEER_PORT="$(escape_sed "$CAPTIVE_CORE_PEER_PORT")"

  E_NETWORK_ROOT_SECRET_KEY="$(escape_sed "$NETWORK_ROOT_SECRET_KEY")"
  E_NETWORK_ROOT_ACCOUNT_ID="$(escape_sed "$NETWORK_ROOT_ACCOUNT_ID")"
  E_CORE_VALIDATOR_PUBKEY="$(escape_sed "$CORE_VALIDATOR_PUBKEY")"

  sed \
    -e "s|__WORKDIR__|$E_WORKDIR|g" \
    -e "s|__NETWORK_PASSPHRASE__|$E_NETWORK_PASSPHRASE|g" \
    -e "s|__CORE_NODE_SEED__|$E_CORE_NODE_SEED|g" \
    -e "s|__TOOLKIT_HTTP_PORT__|$E_TOOLKIT_HTTP_PORT|g" \
    -e "s|__HISTORY_HTTP_PORT__|$E_HISTORY_HTTP_PORT|g" \
    -e "s|__STELLAR_RPC_PORT__|$E_STELLAR_RPC_PORT|g" \
    -e "s|__FRIENDBOT_PORT__|$E_FRIENDBOT_PORT|g" \
    -e "s|__CORE_HTTP_PORT__|$E_CORE_HTTP_PORT|g" \
    -e "s|__CORE_PEER_PORT__|$E_CORE_PEER_PORT|g" \
    -e "s|__CAPTIVE_CORE_HTTP_PORT__|$E_CAPTIVE_CORE_HTTP_PORT|g" \
    -e "s|__CAPTIVE_CORE_PEER_PORT__|$E_CAPTIVE_CORE_PEER_PORT|g" \
    -e "s|__NETWORK_ROOT_SECRET_KEY__|$E_NETWORK_ROOT_SECRET_KEY|g" \
    -e "s|__NETWORK_ROOT_ACCOUNT_ID__|$E_NETWORK_ROOT_ACCOUNT_ID|g" \
    -e "s|__CORE_VALIDATOR_PUBKEY__|$E_CORE_VALIDATOR_PUBKEY|g" \
    "$in" > "$out"
}

log "WORKDIR=$WORKDIR"
log "PASS='$NETWORK_PASSPHRASE'"
log "TOOLKIT_HTTP_PORT=$TOOLKIT_HTTP_PORT, HISTORY_HTTP_PORT=$HISTORY_HTTP_PORT"
log "STELLAR_RPC_PORT=$STELLAR_RPC_PORT, FRIENDBOT_PORT=$FRIENDBOT_PORT"
log "CORE_HTTP_PORT=$CORE_HTTP_PORT, CORE_PEER_PORT=$CORE_PEER_PORT"
log "CAPTIVE_CORE_HTTP_PORT=$CAPTIVE_CORE_HTTP_PORT, CAPTIVE_CORE_PEER_PORT=$CAPTIVE_CORE_PEER_PORT"
log "ROOT_ACCOUNT=$NETWORK_ROOT_ACCOUNT_ID"

apply_template "$WORKDIR/opt/caddy/caddy.cfg" \
               "$OUT_DIR/caddy.cfg"

apply_template "$WORKDIR/opt/stellar-core/stellar-core.cfg" \
               "$OUT_DIR/stellar-core.cfg"

apply_template "$WORKDIR/opt/stellar-rpc/stellar-rpc.cfg" \
               "$OUT_DIR/stellar-rpc.cfg"

apply_template "$WORKDIR/opt/friendbot/friendbot.cfg" \
               "$OUT_DIR/friendbot.cfg"

apply_template "$WORKDIR/opt/captive-core/stellar-captive-core.cfg" \
               "$OUT_DIR/stellar-captive-core.cfg"

log "generated configs:"
log "  $OUT_DIR/caddy.cfg"
log "  $OUT_DIR/stellar-core.cfg"
log "  $OUT_DIR/stellar-rpc.cfg"
log "  $OUT_DIR/friendbot.cfg"
log "  $OUT_DIR/stellar-captive-core.cfg"