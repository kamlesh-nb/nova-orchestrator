#!/usr/bin/env bash
# Host gate for the orchestrator stack (orchd + service control/data planes + orchctl). Builds all three
# binaries and runs the full Nova test suite on THIS host OS, exiting non-zero on any failure. Needs `nova`
# on PATH (from the lang gate's `zig build`) and the lang toolchain beside this repo. See CI-POLICY.md.
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.nova/bin:$PATH"
OS="$(uname -s)-$(uname -m)"
fail=0
step() { echo; echo ">>> $* [$OS]"; }

step "build service + orchd + orchctl"
./build.sh || fail=1

if [ $fail -eq 0 ]; then
  step "nova test (offline deterministic suite: config, discovery, alerts, lifecycle, HA cluster, operability)"
  ./run-tests.sh || fail=1
fi

echo
if [ $fail -eq 0 ]; then echo "GATE PASS  orchestrator (orchd/service/orchctl)  [$OS]"; else echo "GATE FAIL  orchestrator  [$OS]"; fi
exit $fail
