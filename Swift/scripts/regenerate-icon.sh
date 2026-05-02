#!/bin/bash
# regenerate-icon.sh — reconstrói AppIcon.icns a partir de AppIcon-source.png
#
# Single source of truth: Swift/AppIcon-source.png (1024x1024 PNG, gerado via
# OpenAI gpt-image-1 em 2026-05-02, conceito IDF tactical scout).
# Saída: Swift/AppIcon.iconset/* + Swift/AppIcon.icns

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$SWIFT_DIR/AppIcon-source.png"
ICONSET="$SWIFT_DIR/AppIcon.iconset"

[[ -f "$SRC" ]] || { echo "ERRO: $SRC não encontrado" >&2; exit 1; }

mkdir -p "$ICONSET"
echo "==> regenerando iconset a partir de $(basename "$SRC")"

# tamanhos canônicos pra .icns macOS
for size in 16 32 64 128 256 512 1024; do
    sips -Z "$size" "$SRC" --out "$ICONSET/_tmp_${size}.png" >/dev/null
done

mv "$ICONSET/_tmp_16.png"   "$ICONSET/icon_16x16.png"
mv "$ICONSET/_tmp_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_16x16@2x.png" "$ICONSET/icon_32x32.png"
mv "$ICONSET/_tmp_64.png"   "$ICONSET/icon_32x32@2x.png"
mv "$ICONSET/_tmp_128.png"  "$ICONSET/icon_128x128.png"
mv "$ICONSET/_tmp_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_128x128@2x.png" "$ICONSET/icon_256x256.png"
mv "$ICONSET/_tmp_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_256x256@2x.png" "$ICONSET/icon_512x512.png"
mv "$ICONSET/_tmp_1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$SWIFT_DIR/AppIcon.icns"

echo "==> ok: $SWIFT_DIR/AppIcon.icns ($(stat -f%z "$SWIFT_DIR/AppIcon.icns") bytes)"
