#!/usr/bin/env bash
# MANUAL ONLY -- NOT A MERGE GATE. Run the LIVE integration tests (tests/live/*.nova) against a fresh NovaDB
# server. Unlike run-tests.sh (offline, deterministic, the GATE), these connect to a real btree on
# 127.0.0.1:3009 and are timing-sensitive; they confirm behaviour but never gate a merge. Their guarantees
# have deterministic equivalents in run-tests.sh (188 lease, O2 198_ha_cluster) -- see ../../TEST-STRATEGY.md.
# Requires the btree repo built beside the lang toolchain (btree/zig-out/bin/btree) and `nova` on PATH.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lang="$here/../../lang"
btree="$here/../../btree"
server="$btree/zig-out/bin/btree"

[ -x "$server" ] || { echo "build btree first: (cd $btree && zig build)"; exit 1; }

# Each live test gets its OWN fresh server: the persisted FENCE high-water (max_epoch_seen, in the WAL dir)
# is global to a server, so a test that promotes a lease would poison the next test's low-epoch election.
# Every test's header promises a fresh server; honor it per file, not per suite.
livepid=""
start_server() {
  ( cd "$btree" && rm -rf nova.db wal test_wal_recovery ) 2>/dev/null
  # The orchestrator config store is the "config workload" (P0): run it sync-commit so every acked lease/CAS
  # or workload-spec write is fsync-durable across a crash (RPO=0). Config is tiny; the fsync is not the cost.
  ( cd "$btree" && SYNCHRONOUS_COMMIT=true "$server" >/tmp/btree_live_server.log 2>&1 & echo $! >/tmp/btree_live.pid )
  sleep 3
  livepid="$(cat /tmp/btree_live.pid)"
}
stop_server() { [ -n "$livepid" ] && kill "$livepid" 2>/dev/null; livepid=""; }
trap 'stop_server' EXIT

cd "$lang" || { echo "expected the Nova toolchain at $lang"; exit 1; }
pass=0; fail=0
for t in "$here"/tests/live/*.nova; do
  start_server
  if nova test "$t" >/tmp/novaorch_live.log 2>&1 && grep -q "0 failed" /tmp/novaorch_live.log; then
    echo "PASS  $(basename "$t")"; pass=$((pass+1))
  else
    echo "FAIL  $(basename "$t")"; tail -8 /tmp/novaorch_live.log; fail=$((fail+1))
  fi
  stop_server
done
rm -f /tmp/novaorch_live.log
echo "----------------------------------------"
echo "nova-orchestrator LIVE: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
