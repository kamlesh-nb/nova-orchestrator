#!/usr/bin/env bash
# Run every package test via `kyte test`. The Kyte resolver finds this package's modules through
# `../packages`; run from a checkout beside the `lang` toolchain (kyte on PATH). We invoke from the
# lang/ dir so the stdlib (src/std) resolves relative to CWD.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lang="$here/../../lang"
cd "$lang" || { echo "expected the Kyte toolchain at $lang"; exit 1; }
pass=0; fail=0
# nullglob: a directory with no .ky files must expand to NOTHING, not to the literal pattern.
# Without it, bash hands `.../features/*.ky` to the compiler verbatim and the run reports a
# phantom FAIL for a test named "*.ky" -- which is what happened the moment the last webui
# feature test was removed.
shopt -s nullglob
for t in "$here"/tests/*.ky "$here"/webui/tests/features/*.ky; do
  if kyte test "$t" >/tmp/kyteorch.log 2>&1 && grep -q "0 failed" /tmp/kyteorch.log; then
    echo "PASS  $(basename "$t")"; pass=$((pass+1))
  else
    echo "FAIL  $(basename "$t")"; tail -6 /tmp/kyteorch.log; fail=$((fail+1))
  fi
done
rm -f /tmp/kyteorch.log
echo "----------------------------------------"
echo "nova-orchestrator: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
