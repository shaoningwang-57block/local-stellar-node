#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-57blocks/local-stellar-node}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://raw.githubusercontent.com/$REPO/HEAD/install/local-stellar-nodeup"

echo "[install.sh] downloading installer..."
curl -L "$URL" -o "$TMP/local-stellar-nodeup"
chmod +x "$TMP/local-stellar-nodeup"

echo "[install.sh] running installer..."
"$TMP/local-stellar-nodeup"