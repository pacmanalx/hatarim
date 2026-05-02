#!/bin/bash
# build-app.sh — compila o executável Swift e empacota como HaTarim.app
# Idempotente: pode rodar quantas vezes quiser.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="HaTarim"
APP_DIR="${APP_NAME}.app"
BUNDLE_ID="com.pacman.hatarim"
VERSION="0.3.0"

echo "==> swift build -c release"
swift build -c release

BIN_PATH=".build/release/${APP_NAME}"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "ERRO: binário não encontrado em $BIN_PATH" >&2
    exit 1
fi

echo "==> Garantindo AppIcon.icns"
if [[ ! -f "AppIcon.icns" ]]; then
    swift scripts/generate-icon.swift
else
    echo "    (já existe — para regenerar: rm AppIcon.icns)"
fi

echo "==> Montando ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "$BIN_PATH" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>      <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>       <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>          <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleExecutable</key>       <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundleIconName</key>         <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
</dict>
</plist>
EOF

echo "==> codesign ad-hoc"
codesign -s - -f --deep "${APP_DIR}" >/dev/null

echo "==> abrindo ${APP_DIR}"
# mata instância anterior se houver, pra evitar duplicado na menubar
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5
open "${APP_DIR}"

echo ""
echo "==> Pronto. Procure o ícone 'cpu' na barra de menu."
echo "    Bundle:    $(pwd)/${APP_DIR}"
echo "    Para sair: clique no ícone → Sair (ou ⌘Q com o menu aberto)"
