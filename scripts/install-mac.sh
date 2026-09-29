#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/mac"

if ! command -v swift >/dev/null 2>&1; then
  echo "Install the Xcode command line tools, then run this script again:"
  echo "  xcode-select --install"
  exit 1
fi

echo "Building MacConnect agent..."
swift build -c release

APP="$HOME/Applications/MacConnectAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/MacConnectAgent" "$APP/Contents/MacOS/MacConnectAgent"
cp "$ROOT/mac/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/MacConnectAgent"
codesign --force --deep --sign - "$APP"

LOG_DIR="$HOME/Library/Logs/MacConnect"
mkdir -p "$LOG_DIR"
PLIST="$HOME/Library/LaunchAgents/com.macconnect.agent.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.macconnect.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP}/Contents/MacOS/MacConnectAgent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/agent.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/agent.log</string>
</dict>
</plist>
EOF

UID_NUM="$(id -u)"
launchctl bootout "gui/${UID_NUM}/com.macconnect.agent" 2>/dev/null || true
launchctl bootstrap "gui/${UID_NUM}" "$PLIST"
launchctl enable "gui/${UID_NUM}/com.macconnect.agent" || true
launchctl kickstart -k "gui/${UID_NUM}/com.macconnect.agent"

open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true

echo
echo "MacConnect agent is installed. It starts again whenever you log in."
echo "On the permission screens, turn on MacConnect Agent for:"
echo "  1. Screen Recording"
echo "  2. Accessibility"
echo "Log: ${LOG_DIR}/agent.log"
