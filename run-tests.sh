#!/usr/bin/env bash
# Run every package test via `nova test`. The Nova resolver finds this package's modules through
# `../packages`; run from a checkout beside the `lang` toolchain (nova on PATH). We invoke from the
# lang/ dir so the stdlib (src/std) resolves relative to CWD.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lang="$here/../../lang"
cd "$lang" || { echo "expected the Nova toolchain at $lang"; exit 1; }
pass=0; fail=0
for t in "$here"/tests/*.nova; do
  if nova test "$t" >/tmp/novaorch.log 2>&1 && grep -q "0 failed" /tmp/novaorch.log; then
    echo "PASS  $(basename "$t")"; pass=$((pass+1))
  else
    echo "FAIL  $(basename "$t")"; tail -6 /tmp/novaorch.log; fail=$((fail+1))
  fi
done
rm -f /tmp/novaorch.log
echo "----------------------------------------"
echo "nova-orchestrator: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
