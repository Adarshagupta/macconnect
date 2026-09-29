#!/bin/bash
# Tells the Mac agent which Windows PC to connect to, for networks where automatic discovery does not work.
#
#   bash scripts/set-windows-ip.sh 192.168.1.20    set the address
#   bash scripts/set-windows-ip.sh                 ask for it
#   bash scripts/set-windows-ip.sh --show          show the current address
#   bash scripts/set-windows-ip.sh --clear         go back to automatic discovery only
#
# The Windows viewer shows its address on the "Waiting for Mac" screen and in its tray menu.
set -euo pipefail

DIR="$HOME/Library/Application Support/MacConnect"
FILE="$DIR/config.json"
LABEL="com.macconnect.agent"

is_ipv4() {
  local ip="$1" part
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    (( 10#$part <= 255 )) || return 1
  done
  return 0
}

restart_agent() {
  local domain="gui/$(id -u)"
  if launchctl print "${domain}/${LABEL}" >/dev/null 2>&1; then
    launchctl kickstart -k "${domain}/${LABEL}"
    echo "Restarted the agent. It will try this address first."
  else
    echo "The agent is not running yet. It will use this address once installed (scripts/install-mac.sh)."
  fi
}

case "${1:-}" in
  --show)
    if [ -f "$FILE" ]; then
      echo "$FILE:"
      cat "$FILE"
    else
      echo "No address set. The agent uses automatic discovery."
    fi
    exit 0
    ;;
  --clear)
    rm -f "$FILE"
    echo "Removed the saved address. The agent uses automatic discovery."
    restart_agent
    exit 0
    ;;
esac

IP="${1:-}"
if [ -z "$IP" ]; then
  read -r -p "Windows PC address (for example 192.168.1.20): " IP
fi
IP="$(echo "$IP" | tr -d '[:space:]')"

if ! is_ipv4 "$IP"; then
  echo "\"$IP\" is not an IPv4 address like 192.168.1.20."
  exit 1
fi

mkdir -p "$DIR"
printf '{ "windowsHost": "%s" }\n' "$IP" > "$FILE"
echo "Saved $IP in $FILE"
restart_agent
