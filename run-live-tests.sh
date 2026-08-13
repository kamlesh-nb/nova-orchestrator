#!/usr/bin/env bash
# NOTE (2026-08-13): the tests/live/*.nova files manually pump a low-level `net.reactor.Reactor` (the old
# conformance-205 pattern). A later lang stdlib refactor removed `net/reactor.nova` and split it into
# net/poller + net/aio + net/eventedio, so these three live tests no longer resolve `import net.reactor`
# and need porting to the new manual-pump surface before this script is green again. The behaviours they
# assert have deterministic offline equivalents that DO gate (run-tests.sh: 188 lease, 198 HA cluster =
# fencing + 5-node no-split-brain soak), and the live CAS atomicity is proven at the SQL layer (B-3). The
# btree->novadb paths below are fixed; the remaining work is the reactor-API port.
#
# MANUAL ONLY -- NOT A MERGE GATE. Run the LIVE integration tests (tests/live/*.nova) against a fresh NovaDB
# server. Unlike run-tests.sh (offline, deterministic, the GATE), these connect to a real btree on
# 127.0.0.1:3009 and are timing-sensitive; they confirm behaviour but never gate a merge. Their guarantees
# have deterministic equivalents in run-tests.sh (188 lease, O2 198_ha_cluster) -- see ../../TEST-STRATEGY.md.
# Requires the btree repo built beside the lang toolchain (btree/zig-out/bin/btree) and `nova` on PATH.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lang="$here/../../lang"
btree="$here/../../novadb"
server="$btree/zig-out/bin/novadb"

[ -x "$server" ] || { echo "build NovaDB first: (cd $btree && zig build)"; exit 1; }

# Each live test gets its OWN fresh server: the persisted FENCE high-water (max_epoch_seen, in the WAL dir)
# is global to a server, so a test that promotes a lease would poison the next test's low-epoch election.
# Every test's header promises a fresh server; honor it per file, not per suite.
livepid=""
start_server() {
  ( cd "$btree" && rm -rf data/nova.db data/wal nova.db wal test_wal_recovery ) 2>/dev/null
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
