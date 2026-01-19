#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist"
mkdir -p "$OUT"

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *) echo "unsupported OS: $os"; exit 1 ;;
esac

case "$arch" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *) echo "unsupported arch: $arch"; exit 1 ;;
esac

platform="${os}_${arch}"
pkg="local-stellar-node_${platform}.tar.gz"

echo "[build] platform=$platform"
echo "[build] output=$OUT/$pkg"

# 产物必须包含这些目录
need() {
  [[ -e "$ROOT/$1" ]] || { echo "missing required path: $1"; exit 1; }
}

need "bin/stellar-tool"
need "bin/stellar-core"
need "bin/stellar-rpc"
need "bin/friendbot"
need "script"
need "opt"

# 确保可执行权限
chmod +x "$ROOT/bin/stellar-tool" || true
chmod +x "$ROOT/bin/stellar-core" || true
chmod +x "$ROOT/bin/stellar-rpc" || true
chmod +x "$ROOT/bin/friendbot" || true

# 如果你还有 caddy
[[ -f "$ROOT/bin/caddy" ]] && chmod +x "$ROOT/bin/caddy" || true

rm -f "$OUT/$pkg"

# 打包（lib/db/log/tmp 允许不存在，但建议你创建空目录占位）
tar -czf "$OUT/$pkg" \
  -C "$ROOT" \
  bin script opt lib db log tmp 2>/dev/null || true

echo "[build] done: $OUT/$pkg"
ls -lh "$OUT/$pkg"