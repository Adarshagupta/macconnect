#!/bin/bash
# Builds and installs the MacConnect agent.
# Safe to run again: the new build is tested first, and if it does not start, the previous version is put back.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.macconnect.agent"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/MacConnectAgent.app"
PREVIOUS="$APP_DIR/MacConnectAgent.previous.app"
LOG_DIR="$HOME/Library/Logs/MacConnect"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"

if ! command -v swift >/dev/null 2>&1; then
  echo "Install the Xcode command line tools, then run this script again:"
  echo "  xcode-select --install"
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "1/5 Building the agent..."
cd "$ROOT/mac"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "2/5 Packaging..."
NEW_APP="$STAGE/MacConnectAgent.app"
mkdir -p "$NEW_APP/Contents/MacOS"
cp "$BIN_DIR/MacConnectAgent" "$NEW_APP/Contents/MacOS/MacConnectAgent"
cp "$ROOT/mac/Info.plist" "$NEW_APP/Contents/Info.plist"
chmod +x "$NEW_APP/Contents/MacOS/MacConnectAgent"
codesign --force --deep --sign - --identifier "$LABEL" "$NEW_APP"

echo "3/5 Checking that the new build starts..."
if ! "$NEW_APP/Contents/MacOS/MacConnectAgent" --check | grep -q "MacConnect agent OK"; then
  echo "The new build did not start. Nothing was changed."
  exit 1
fi

write_plist() {
  mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP}/Contents/MacOS/MacConnectAgent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
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
}

stop_agent() {
  launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
  sleep 1
}

start_agent() {
  launchctl bootstrap "${DOMAIN}" "$PLIST"
  launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
  launchctl kickstart -k "${DOMAIN}/${LABEL}"
}

agent_running() {
  launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | grep -q "state = running"
}

echo "4/5 Installing..."
mkdir -p "$APP_DIR"
stop_agent
rm -rf "$PREVIOUS"
HAD_PREVIOUS=0
if [ -d "$APP" ]; then
  mv "$APP" "$PREVIOUS"
  HAD_PREVIOUS=1
fi
mv "$NEW_APP" "$APP"
write_plist

echo "5/5 Starting and verifying..."
STARTED=0
if start_agent 2>/dev/null; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if agent_running; then
      STARTED=1
      break
    fi
  done
fi

if [ "$STARTED" -ne 1 ]; then
  echo "The new agent did not start."
  stop_agent
  if [ "$HAD_PREVIOUS" -eq 1 ]; then
    echo "Putting the previous version back..."
    rm -rf "$APP"
    mv "$PREVIOUS" "$APP"
    write_plist
    start_agent || true
    echo "Previous version restored."
  fi
  echo "Look at $LOG_DIR/agent.log for the reason."
  exit 1
fi

echo
echo "MacConnect agent is installed and running. It starts again every time you log in."
echo
echo "Turn on MacConnect Agent under System Settings > Privacy & Security:"
echo "  1. Screen Recording"
echo "  2. Accessibility"
echo
echo "Log: $LOG_DIR/agent.log"
echo "Restart it any time with: bash scripts/restart-mac-agent.sh"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
