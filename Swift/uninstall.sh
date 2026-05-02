#!/bin/bash
# uninstall.sh - Remove HaTarim do macOS (LaunchAgent + .app + logs).
set -euo pipefail

APP_NAME="HaTarim"
APP_BUNDLE="${APP_NAME}.app"
INSTALL_DIR="$HOME/Applications"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="com.pacman.hatarim"
PLIST="$LAUNCH_AGENT_DIR/$LABEL.plist"

echo "==> HaTarim uninstaller"

# 1. Para LaunchAgent (se existir)
if [[ -f "$PLIST" ]]; then
    echo "==> Parando LaunchAgent"
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "    plist removido: $PLIST"
fi

# 2. Mata processo (qualquer instância manual aberta)
pkill -x "$APP_NAME" 2>/dev/null || true

# 3. Remove .app
if [[ -d "${INSTALL_DIR}/${APP_BUNDLE}" ]]; then
    rm -rf "${INSTALL_DIR}/${APP_BUNDLE}"
    echo "    bundle removido: ${INSTALL_DIR}/${APP_BUNDLE}"
fi

# 4. Logs
rm -f /tmp/hatarim.log /tmp/hatarim.err

# 5. Verifica
if launchctl list | grep -q "${LABEL}"; then
    echo "ATENÇÃO: ainda há LaunchAgent ${LABEL} carregado." >&2
    exit 1
fi
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "ATENÇÃO: processo ${APP_NAME} ainda em execução." >&2
    exit 1
fi

echo "==> HaTarim desinstalado."
