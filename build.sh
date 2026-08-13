#!/usr/bin/env bash
# Build the binaries of the split orchestrator stack:
#   service  -- the data plane   (L7 reverse proxy / load balancer)
#   orchd    -- the control plane (nativelet reconcile loop)
#   orchctl  -- the operator CLI  (writes desired state, offline ops)
#   orchweb  -- the operator UI   (a Tailwind web app under webui/: node/service/replica tree + manifest forms)
#
# Each entrypoint lives in bin/ and pulls only its slice of the package via the import graph, so the
# binaries are naturally separated (dead-code elimination drops the unreferenced tier). Run from a
# checkout beside the `lang` toolchain (nova on PATH). Pass --release for an optimised build.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

profile_flag=""
outdir="build/debug/bin"
for a in "$@"; do
  case "$a" in
    --release|-r) profile_flag="--release"; outdir="build/release/bin" ;;
  esac
done

mkdir -p "$outdir"
echo "Building service (data plane)..."
nova build --file bin/service.nova -o "$outdir/service" $profile_flag >/dev/null
echo "Building orchd (control plane)..."
nova build --file bin/orchd.nova -o "$outdir/orchd" $profile_flag >/dev/null
echo "Building orchctl (operator CLI)..."
nova build --file bin/orchctl.nova -o "$outdir/orchctl" $profile_flag >/dev/null
# orchweb is the OPTIONAL control-plane UI; its sources live under webui/ (a work-in-progress tree). Build
# it best-effort so a missing or not-yet-building webui never fails the core stack (service/orchd/orchctl),
# which is what the platform slice and the acceptance test actually depend on.
orchweb_built=0
if [ -f webui/src/main.nova ]; then
    echo "Building orchweb (control-plane UI, best-effort)..."
    if nova build --file webui/src/main.nova -o "$outdir/orchweb" $profile_flag >/dev/null 2>&1; then
        orchweb_built=1
    else
        echo "  warning: orchweb skipped (webui not currently building)"
    fi
fi
echo "Built:"
echo "  $outdir/service"
echo "  $outdir/orchd"
echo "  $outdir/orchctl"
if [ "$orchweb_built" = 1 ]; then echo "  $outdir/orchweb"; fi
echo
echo "Validate a config without serving:  $outdir/service service.json --check"
