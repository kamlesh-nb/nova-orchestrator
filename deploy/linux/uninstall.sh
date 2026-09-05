#!/usr/bin/env bash
# Remove the Kyte orchestrator systemd units + binaries. Leaves CONF_DIR and DATA_DIR by default
# (pass --purge to delete config + data too).
set -euo pipefail
BIN_DIR="${BIN_DIR:-/opt/nova-orchestrator/bin}"
CONF_DIR="${CONF_DIR:-/etc/nova-orchestrator}"
DATA_DIR="${DATA_DIR:-/var/lib/nova-orchestrator}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
if [ "$(id -u)" -ne 0 ]; then echo "run as root (sudo)"; exit 1; fi

for u in kyte-service kyte-kynatord kyte-artifactd; do
  systemctl stop "$u.service" 2>/dev/null || true
  systemctl disable "$u.service" 2>/dev/null || true
  rm -f "/etc/systemd/system/$u.service"
done
systemctl daemon-reload
rm -rf "$BIN_DIR"
if [ "$PURGE" = 1 ]; then
  echo "purging config + data"
  rm -rf "$CONF_DIR" "$DATA_DIR"
else
  echo "left config ($CONF_DIR) and data ($DATA_DIR) in place; pass --purge to remove them"
fi
echo "Done."
