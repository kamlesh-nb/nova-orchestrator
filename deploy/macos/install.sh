#!/usr/bin/env bash
# Install the Kyte orchestrator daemons (artifactd, orchd, service) as launchd system daemons on macOS.
#
# Layout (override with env vars):
#   BIN_DIR   /usr/local/opt/nova-orchestrator/bin
#   CONF_DIR  /usr/local/etc/nova-orchestrator
#   DATA_DIR  /usr/local/var/lib/nova-orchestrator
#   LOG_DIR   /usr/local/var/log/nova-orchestrator
#
# Usage:  sudo ./install.sh [--from <dir-with-binaries>] [--load]
#   --from  directory with service/orchd/orchctl/artifactd (default: ../../build/release/bin)
#   --load  launchctl bootstrap (load + start) the daemons now
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

BIN_DIR="${BIN_DIR:-/usr/local/opt/nova-orchestrator/bin}"
CONF_DIR="${CONF_DIR:-/usr/local/etc/nova-orchestrator}"
DATA_DIR="${DATA_DIR:-/usr/local/var/lib/nova-orchestrator}"
LOG_DIR="${LOG_DIR:-/usr/local/var/log/nova-orchestrator}"
FROM="$here/../../build/release/bin"
DO_LOAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) shift; FROM="${1:?--from needs a dir}" ;;
    --load) DO_LOAD=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac; shift
done
if [ "$(id -u)" -ne 0 ]; then echo "run as root (sudo)"; exit 1; fi

echo "==> Creating directories"
mkdir -p "$BIN_DIR" "$CONF_DIR" "$DATA_DIR/artifacts" "$DATA_DIR/manifests" "$LOG_DIR"

echo "==> Installing binaries from $FROM"
for b in service orchd orchctl artifactd; do
  if [ ! -x "$FROM/$b" ]; then echo "  missing $FROM/$b (build with ./build.sh --release first)"; exit 1; fi
  install -m 0755 "$FROM/$b" "$BIN_DIR/$b"
done

echo "==> Seeding config templates (only if absent)"
[ -f "$CONF_DIR/orchd.json" ]   || printf '{\n  "manifestsDir": "%s/manifests",\n  "reconcileMs": 2000,\n  "nodeId": "node-1",\n  "discoveryFile": "%s/discovery.txt",\n  "metricsFile": "%s/metrics.prom",\n  "store": { "enabled": true, "addr": "127.0.0.1:8135", "token": "", "tls": false }\n}\n' "$DATA_DIR" "$DATA_DIR" "$DATA_DIR" > "$CONF_DIR/orchd.json"
[ -f "$CONF_DIR/service.json" ] || printf '{\n  "listenHost": "0.0.0.0", "listenPort": 8090, "strategy": "roundrobin",\n  "health": { "enabled": true, "path": "/healthz", "intervalMs": 2000, "timeoutMs": 1000, "rise": 2, "fall": 3 },\n  "backends": []\n}\n' > "$CONF_DIR/service.json"

echo "==> Installing launchd plists (substituting paths)"
for label in com.ky.artifactd com.ky.orchd com.ky.service; do
  sed -e "s#@BIN_DIR@#$BIN_DIR#g" -e "s#@CONF_DIR@#$CONF_DIR#g" -e "s#@DATA_DIR@#$DATA_DIR#g" -e "s#@LOG_DIR@#$LOG_DIR#g" \
      "$here/$label.plist" > "/Library/LaunchDaemons/$label.plist"
  chown root:wheel "/Library/LaunchDaemons/$label.plist"
  chmod 0644 "/Library/LaunchDaemons/$label.plist"
done

if [ "$DO_LOAD" = 1 ]; then
  echo "==> Bootstrapping daemons"
  for label in com.ky.artifactd com.ky.orchd com.ky.service; do
    launchctl bootout system "/Library/LaunchDaemons/$label.plist" 2>/dev/null || true
    launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"
    launchctl enable "system/$label"
  done
  launchctl print system/com.ky.orchd 2>/dev/null | sed -n '1,12p' || true
fi

echo "Done. Manage with: sudo launchctl {bootstrap,bootout} system /Library/LaunchDaemons/com.ky.<c>.plist"
echo "Logs in $LOG_DIR ; config in $CONF_DIR (restart a daemon after editing: bootout then bootstrap)."
