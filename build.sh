#!/usr/bin/env bash
# Build the two binaries of the split orchestrator stack:
#   proxyd  -- the data plane  (L7 reverse proxy / load balancer)
#   orchd   -- the control plane (nativelet reconcile loop)
#
# Each entrypoint lives in bin/ and pulls only its half of the package via the import graph, so the two
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
echo "Building proxyd (data plane)..."
nova build --file bin/proxyd.nova -o "$outdir/proxyd" $profile_flag >/dev/null
echo "Building orchd (control plane)..."
nova build --file bin/orchd.nova -o "$outdir/orchd" $profile_flag >/dev/null
echo "Built:"
echo "  $outdir/proxyd"
echo "  $outdir/orchd"
echo
echo "Validate a config without serving:  $outdir/proxyd proxyd.json --check"
