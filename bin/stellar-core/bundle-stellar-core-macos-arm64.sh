#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${WORKDIR:-/Users/57block/stellar-toolkit}"
OUT="${OUT:-$WORKDIR/bin/stellar-core}"
CORE_BIN="${CORE_BIN:-/opt/homebrew/bin/stellar-core}"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"

BIN_DIR="$OUT/bin"
LIB_DIR="$OUT/lib"

mkdir -p "$BIN_DIR" "$LIB_DIR"

log(){ printf '%s\n' "$*" >&2; }
die(){ log "ERROR: $*"; exit 1; }

[[ -x "$CORE_BIN" ]] || die "stellar-core not found or not executable: $CORE_BIN"
command -v otool >/dev/null || die "missing otool"
command -v install_name_tool >/dev/null || die "missing install_name_tool"
command -v codesign >/dev/null || die "missing codesign"

is_brew_path() {
  case "$1" in
    "$BREW_PREFIX"/*"/lib/"*.dylib) return 0 ;;
    "$BREW_PREFIX"/*.dylib) return 0 ;;
    *) return 1 ;;
  esac
}

deps_of() {
  local f="$1"
  otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    if is_brew_path "$dep"; then
      echo "$dep"
    fi
  done
}

# Copy stellar-core
cp "$CORE_BIN" "$BIN_DIR/stellar-core"
chmod +x "$BIN_DIR/stellar-core"

# Temp files (portable set/queue)
TMP_DIR="$(mktemp -d)"
SEEN="$TMP_DIR/seen.txt"
QUEUE="$TMP_DIR/queue.txt"

touch "$SEEN" "$QUEUE"

enqueue() {
  local p="$1"
  [[ -z "$p" ]] && return 0
  # already seen?
  if grep -Fxq "$p" "$SEEN"; then
    return 0
  fi
  echo "$p" >>"$SEEN"
  echo "$p" >>"$QUEUE"
}

# seed queue with stellar-core deps
while read -r d; do enqueue "$d"; done < <(deps_of "$BIN_DIR/stellar-core")

# BFS over queue (line by line)
i=1
while true; do
  dep="$(sed -n "${i}p" "$QUEUE" || true)"
  [[ -z "${dep:-}" ]] && break

  base="$(basename "$dep")"
  dst="$LIB_DIR/$base"

  if [[ ! -f "$dst" ]]; then
    cp "$dep" "$dst"
    chmod 644 "$dst"
  fi

  # enqueue deps of copied dylib
  while read -r d2; do enqueue "$d2"; done < <(deps_of "$dst")

  i=$((i+1))
done

log "Copied Homebrew dylibs into $LIB_DIR:"
ls -lh "$LIB_DIR" >&2 || true

# Add rpath to stellar-core
install_name_tool -add_rpath "@executable_path/../lib" "$BIN_DIR/stellar-core" 2>/dev/null || true

# Rewrite stellar-core: brew paths -> @rpath/<name>
while read -r dep; do
  name="$(basename "$dep")"
  install_name_tool -change "$dep" "@rpath/$name" "$BIN_DIR/stellar-core"
done < <(deps_of "$BIN_DIR/stellar-core")

# Rewrite dylibs: brew paths -> @loader_path/<name>
for f in "$LIB_DIR/"*.dylib; do
  [[ -f "$f" ]] || continue
  install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
  while read -r dep; do
    name="$(basename "$dep")"
    install_name_tool -change "$dep" "@loader_path/$name" "$f"
  done < <(deps_of "$f")
done

# Ad-hoc codesign
codesign --force --sign - "$BIN_DIR/stellar-core" 2>/dev/null || true
for f in "$LIB_DIR/"*.dylib; do
  [[ -f "$f" ]] || continue
  codesign --force --sign - "$f" 2>/dev/null || true
done

log "Verify stellar-core deps (should NOT contain $BREW_PREFIX):"
otool -L "$BIN_DIR/stellar-core" >&2

rm -rf "$TMP_DIR"
log "Done."