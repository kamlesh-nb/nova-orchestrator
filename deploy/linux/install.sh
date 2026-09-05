#!/usr/bin/env bash
# Install the Kyte orchestrator daemons (artifactd, orchd, service) as systemd units on Linux.
#
# Layout (override with env vars):
#   BIN_DIR   /opt/nova-orchestrator/bin      built binaries are copied here
#   CONF_DIR  /etc/nova-orchestrator          orchd.json / service.json / artifactd.env
#   DATA_DIR  /var/lib/nova-orchestrator      blobs, config.snap, discovery/metrics files
#   SVC_USER  kyte                            unprivileged user for artifactd + service
#
# Usage:  sudo ./install.sh [--from <dir-with-binaries>] [--enable] [--start]
#   --from   directory containing service/orchd/orchctl/artifactd (default: ../../build/release/bin)
#   --enable systemctl enable the units (start on boot)
#   --start  systemctl start the units now
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

BIN_DIR="${BIN_DIR:-/opt/nova-orchestrator/bin}"
CONF_DIR="${CONF_DIR:-/etc/nova-orchestrator}"
DATA_DIR="${DATA_DIR:-/var/lib/nova-orchestrator}"
SVC_USER="${SVC_USER:-kyte}"
FROM="$here/../../build/release/bin"
DO_ENABLE=0; DO_START=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) shift; FROM="${1:?--from needs a dir}" ;;
    --enable) DO_ENABLE=1 ;;
    --start) DO_START=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac; shift
done

if [ "$(id -u)" -ne 0 ]; then echo "run as root (sudo)"; exit 1; fi
command -v systemctl >/dev/null || { echo "systemctl not found (this installer is for systemd Linux)"; exit 1; }

echo "==> Creating service user '$SVC_USER' (if absent) and directories"
id -u "$SVC_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
install -d -m 0755 "$BIN_DIR" "$CONF_DIR"
install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$DATA_DIR" "$DATA_DIR/artifacts"

echo "==> Installing binaries from $FROM"
for b in service orchd orchctl artifactd; do
  if [ ! -x "$FROM/$b" ]; then echo "  missing $FROM/$b (build with ./build.sh --release first)"; exit 1; fi
  install -m 0755 "$FROM/$b" "$BIN_DIR/$b"
done

echo "==> Seeding config templates (only if absent -- never overwrites yours)"
[ -f "$CONF_DIR/orchd.json" ]    || printf '{\n  "manifestsDir": "%s/manifests",\n  "reconcileMs": 2000,\n  "nodeId": "node-1",\n  "discoveryFile": "%s/discovery.txt",\n  "metricsFile": "%s/metrics.prom",\n  "store": { "enabled": true, "addr": "127.0.0.1:8135", "token": "", "tls": false }\n}\n' "$DATA_DIR" "$DATA_DIR" "$DATA_DIR" > "$CONF_DIR/orchd.json"
[ -f "$CONF_DIR/service.json" ]  || printf '{\n  "listenHost": "0.0.0.0", "listenPort": 8090, "strategy": "roundrobin",\n  "health": { "enabled": true, "path": "/healthz", "intervalMs": 2000, "timeoutMs": 1000, "rise": 2, "fall": 3 },\n  "backends": []\n}\n' > "$CONF_DIR/service.json"
[ -f "$CONF_DIR/artifactd.env" ] || { printf '# KYTE_ARTIFACT_TOKEN=change-me-deploy-token\n' > "$CONF_DIR/artifactd.env"; chmod 0640 "$CONF_DIR/artifactd.env"; chgrp "$SVC_USER" "$CONF_DIR/artifactd.env"; }
install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$DATA_DIR/manifests"

echo "==> Installing systemd units"
install -m 0644 "$here/kyte-artifactd.service" "$here/kyte-orchd.service" "$here/kyte-service.service" /etc/systemd/system/
systemctl daemon-reload

if [ "$DO_ENABLE" = 1 ]; then
  echo "==> Enabling units (start on boot)"
  systemctl enable kyte-artifactd.service kyte-orchd.service kyte-service.service
fi
if [ "$DO_START" = 1 ]; then
  echo "==> Starting units"
  systemctl start kyte-artifactd.service kyte-orchd.service kyte-service.service
  systemctl --no-pager status kyte-artifactd.service kyte-orchd.service kyte-service.service | sed -n '1,30p' || true
fi

echo "Done. Manage with: systemctl {status,start,stop,restart} kyte-{artifactd,orchd,service}"
echo "Edit config in $CONF_DIR, then: systemctl restart kyte-<component>"
