#!/bin/bash
# Restarts the MacConnect agent. Also works over SSH:
#   ssh YOUR_MAC_USER@YOUR_MAC_IP 'bash ~/path/to/macconnect/scripts/restart-mac-agent.sh'
# or, without the script:
#   ssh YOUR_MAC_USER@YOUR_MAC_IP 'launchctl kickstart -k gui/$(id -u)/com.macconnect.agent'
set -euo pipefail

LABEL="com.macconnect.agent"
DOMAIN="gui/$(id -u)"

if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  launchctl kickstart -k "${DOMAIN}/${LABEL}"
  echo "Restarted ${LABEL}."
else
  PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
  if [ ! -f "$PLIST" ]; then
    echo "The agent is not installed. Run scripts/install-mac.sh first."
    exit 1
  fi
  launchctl bootstrap "${DOMAIN}" "$PLIST"
  launchctl kickstart -k "${DOMAIN}/${LABEL}"
  echo "Loaded and started ${LABEL}."
fi

echo "Log: $HOME/Library/Logs/MacConnect/agent.log"
