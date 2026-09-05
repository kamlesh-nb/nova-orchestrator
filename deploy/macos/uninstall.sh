#!/usr/bin/env bash
# Remove the Kyte orchestrator launchd daemons + binaries. Leaves config/data/logs unless --purge.
set -euo pipefail
BIN_DIR="${BIN_DIR:-/usr/local/opt/nova-orchestrator/bin}"
CONF_DIR="${CONF_DIR:-/usr/local/etc/nova-orchestrator}"
DATA_DIR="${DATA_DIR:-/usr/local/var/lib/nova-orchestrator}"
LOG_DIR="${LOG_DIR:-/usr/local/var/log/nova-orchestrator}"
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1
if [ "$(id -u)" -ne 0 ]; then echo "run as root (sudo)"; exit 1; fi

for label in com.kyte.service com.kyte.kynatord com.kyte.artifactd; do
  launchctl bootout system "/Library/LaunchDaemons/$label.plist" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/$label.plist"
done
rm -rf "$BIN_DIR"
if [ "$PURGE" = 1 ]; then rm -rf "$CONF_DIR" "$DATA_DIR" "$LOG_DIR"; echo "purged config/data/logs"; else
  echo "left config/data/logs; pass --purge to remove them"; fi
echo "Done."
