#!/bin/bash
# install.sh - Instala MonitorINO2 como app de boot (LaunchAgent) no macOS.
# Compila do source, empacota .app, copia pra ~/Applications/, cria LaunchAgent.
# Sem sudo, sem rede.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="MonitorINO2"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_DIR="$HOME/Applications"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="com.pacman.monitorino2"
PLIST="$LAUNCH_AGENT_DIR/$LABEL.plist"
BUNDLE_VERSION="0.5.9"

echo "==> MonitorINO2 installer"

# 0. Pré-flight: Apple Silicon + Swift toolchain
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "ERRO: requer Apple Silicon (arm64). Detectei: $(uname -m)" >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "ERRO: 'swift' não encontrado. Instale Command Line Tools: xcode-select --install" >&2
    exit 1
fi

cd "$SCRIPT_DIR"

# 1. Compila release
echo "==> swift build -c release (pode demorar na primeira vez)"
swift build -c release

BIN_PATH=".build/release/${APP_NAME}"
[[ -f "$BIN_PATH" ]] || { echo "ERRO: binário não gerado em $BIN_PATH" >&2; exit 1; }

# 2a. Garante AppIcon.icns
if [[ ! -f "AppIcon.icns" ]]; then
    echo "==> Gerando AppIcon.icns"
    swift scripts/generate-icon.swift
fi

# 2b. Empacota .app local
echo "==> Empacotando ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "$BIN_PATH" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>      <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>       <string>${LABEL}</string>
    <key>CFBundleVersion</key>          <string>${BUNDLE_VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${BUNDLE_VERSION}</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleExecutable</key>       <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundleIconName</key>         <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSLocationUsageDescription</key>          <string>Necessário pra ler o nome (SSID) da rede Wi-Fi atual no card Network. Nenhuma coordenada é coletada.</string>
    <key>NSLocationWhenInUseUsageDescription</key> <string>Necessário pra ler o nome (SSID) da rede Wi-Fi atual no card Network. Nenhuma coordenada é coletada.</string>
</dict>
</plist>
EOF

# Codesign ad-hoc (necessário em arm64)
codesign -s - -f --deep "${APP_BUNDLE}" >/dev/null

# 3. Para qualquer instância em execução
echo "==> Parando instância atual (se houver)"
pkill -x "${APP_NAME}" 2>/dev/null || true
if [[ -f "$PLIST" ]]; then
    launchctl unload "$PLIST" 2>/dev/null || true
fi
sleep 1

# 4. Move pro ~/Applications/
echo "==> Instalando em ${INSTALL_DIR}/${APP_BUNDLE}"
mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}/${APP_BUNDLE}"
cp -R "${APP_BUNDLE}" "${INSTALL_DIR}/"

# 5. Cria LaunchAgent que abre no login
echo "==> Criando LaunchAgent ${PLIST}"
mkdir -p "$LAUNCH_AGENT_DIR"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>StandardOutPath</key>
    <string>/tmp/monitorino2.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/monitorino2.err</string>
</dict>
</plist>
EOF

# 6. Carrega
launchctl load "$PLIST"
sleep 1

if launchctl list | grep -q "${LABEL}"; then
    echo ""
    echo "==> MonitorINO2 instalado e rodando!"
    echo "    Bundle:  ${INSTALL_DIR}/${APP_BUNDLE}"
    echo "    Plist:   $PLIST"
    echo "    Logs:    /tmp/monitorino2.{log,err}"
    echo ""
    echo "    Parar:    launchctl unload \"$PLIST\""
    echo "    Iniciar:  launchctl load   \"$PLIST\""
    echo "    Remover:  ./uninstall.sh"
else
    echo "ERRO: LaunchAgent não iniciou — checar /tmp/monitorino2.err" >&2
    exit 1
fi
