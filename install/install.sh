#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-shaoningwang-57block/local-stellar-node}"
REF="${REF:-main}"   # 也可以写成 v0.1.0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://raw.githubusercontent.com/${REPO}/${REF}/install/local-stellar-nodeup"

echo "[install.sh] downloading installer..."
curl -fsSL "$URL" -o "$TMP/local-stellar-nodeup"
chmod +x "$TMP/local-stellar-nodeup"

echo "[install.sh] running installer..."
"$TMP/local-stellar-nodeup"