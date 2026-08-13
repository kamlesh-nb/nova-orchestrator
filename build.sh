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
#
# CROSS-COMPILING (host build matrix): pass --target <triple> to build for another OS/arch. The nova
# toolchain cross-compiles from any host (macOS, Windows, WSL/Linux). Supported triples:
#   --target linux-x86_64     Linux x86_64
#   --target linux-arm64      Linux aarch64
#   --target macos-x86_64     macOS x86_64 (intel)
#   --target macos-arm64      macOS aarch64 (arm64)
#   --target windows-x86_64   Windows x86_64  (produces .exe)
#   --target windows-arm64    Windows aarch64 (produces .exe)
# Cross binaries land in build/<profile>/<triple>/bin/. Example: ./build.sh --release --target linux-arm64
#
# Native builds use `nova build` (the fast per-file object cache under build/<profile>/obj). Cross builds
# use nova's single-file compile mode instead: the build-mode object cache is not target-aware, so mixing
# a native build and a cross build in the same profile dir collides (duplicate symbols at link time).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

profile_flag=""
profile="debug"
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release|-r) profile_flag="--release"; profile="release" ;;
    --target|-t)
      shift
      target="${1:-}"
      if [ -z "$target" ]; then echo "error: --target needs a triple (e.g. linux-arm64)" >&2; exit 2; fi
      ;;
    --target=*) target="${1#--target=}" ;;
    *) echo "warning: ignoring unknown argument '$1'" >&2 ;;
  esac
  shift
done

# Per-binary build. Native = `nova build --file` (cached); cross = single-file compile with --target.
ext=""
if [ -n "$target" ]; then
  case "$target" in
    windows-x86_64|windows-arm64) ext=".exe" ;;
    linux-x86_64|linux-arm64|macos-x86_64|macos-arm64) ext="" ;;
    *) echo "error: unknown --target '$target'. Supported: linux-x86_64 linux-arm64 macos-x86_64 macos-arm64 windows-x86_64 windows-arm64" >&2; exit 2 ;;
  esac
  outdir="build/$profile/$target/bin"
else
  outdir="build/$profile/bin"
fi

build_one() { # $1 = name, $2 = source .nova
  local name="$1" src="$2"
  if [ -n "$target" ]; then
    nova "$src" -o "$outdir/$name$ext" $profile_flag --target "$target" >/dev/null
  else
    nova build --file "$src" -o "$outdir/$name" $profile_flag >/dev/null
  fi
}

mkdir -p "$outdir"
echo "Building service (data plane)...${target:+ [target=$target]}"
build_one service bin/service.nova
echo "Building orchd (control plane)...${target:+ [target=$target]}"
build_one orchd bin/orchd.nova
echo "Building orchctl (operator CLI)...${target:+ [target=$target]}"
build_one orchctl bin/orchctl.nova
# orchweb is the OPTIONAL control-plane UI; its sources live under webui/ (a work-in-progress tree). Build
# it best-effort so a missing or not-yet-building webui never fails the core stack (service/orchd/orchctl),
# which is what the platform slice and the acceptance test actually depend on.
orchweb_built=0
if [ -f webui/src/main.nova ]; then
    echo "Building orchweb (control-plane UI, best-effort)...${target:+ [target=$target]}"
    if build_one orchweb webui/src/main.nova 2>/dev/null; then
        orchweb_built=1
    else
        echo "  warning: orchweb skipped (webui not currently building)"
    fi
fi
echo "Built:"
echo "  $outdir/service$ext"
echo "  $outdir/orchd$ext"
echo "  $outdir/orchctl$ext"
if [ "$orchweb_built" = 1 ]; then echo "  $outdir/orchweb$ext"; fi
echo
echo "Validate a config without serving:  $outdir/service$ext service.json --check"
