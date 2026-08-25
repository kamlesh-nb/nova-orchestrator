#!/usr/bin/env bash
# Host gate for the orchestrator stack (service data plane + orchd control plane + orchctl/orchweb operator
# surfaces). Builds all binaries and runs the full Nova test suite on THIS host OS, exiting non-zero on any
# failure. Needs `nova`
# on PATH (from the lang gate's `zig build`) and the lang toolchain beside this repo. See CI-POLICY.md.
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.nova/bin:$PATH"
OS="$(uname -s)-$(uname -m)"
fail=0
step() { echo; echo ">>> $* [$OS]"; }

step "build service + orchd + orchctl + orchweb"
./build.sh || fail=1

if [ $fail -eq 0 ]; then
  step "nova test (offline deterministic suite: config, discovery, alerts, lifecycle, HA cluster, operability)"
  ./run-tests.sh || fail=1
fi

# Opt-in LIVE gate: with NOVA_LIVE=1 and a built NovaDB beside the toolchain, also run the live HA tests
# (real store round-trips: split-brain CAS + server-side FENCE). Off by default so the merge gate stays
# offline and server-free; CI that has a NovaDB build sets NOVA_LIVE=1 to prove the live path too.
if [ $fail -eq 0 ] && [ "${NOVA_LIVE:-0}" = "1" ]; then
  step "live HA tests vs a fresh NovaDB (opt-in: NOVA_LIVE=1)"
  ./run-live-tests.sh || fail=1
fi

echo
if [ $fail -eq 0 ]; then echo "GATE PASS  orchestrator (service/orchd/orchctl/orchweb)  [$OS]"; else echo "GATE FAIL  orchestrator  [$OS]"; fi
exit $fail
