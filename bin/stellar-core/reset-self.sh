TOOLKIT="/Users/57block/stellar-toolkit/bin/stellar-core"
LIBDIR="$TOOLKIT/lib"
BINDIR="$TOOLKIT/bin"

# 1) 把每个 dylib 的 install-name(ID) 改成 @loader_path/<file>
for f in "$LIBDIR"/*.dylib; do
  [ -f "$f" ] || continue
  install_name_tool -id "@loader_path/$(basename "$f")" "$f"
done

# 2) 重新 adhoc 签名（修改 Mach-O 后需要）
codesign --force --sign - "$BINDIR/stellar-core" 2>/dev/null || true
codesign --force --sign - "$LIBDIR/"*.dylib 2>/dev/null || true