# Config-store HA runbooks (P7 operability)

Operator procedures for each failure mode in the risk register (beta-config-store-design.md section 7). Every
step maps to a real mechanism built in this repo (orchestrator lease + reconcile) or in BTreeDB (fencing,
durable commit, snapshot/PITR). A system is production grade when someone who did not write it can operate it
under failure -- this file is that.

## Signals to watch (from orch/health.nova, scraped at /metrics)

| Metric | Meaning | Alert when |
|---|---|---|
| `orch_up` | process alive + store reachable (liveness) | `0` for > 1 tick |
| `orch_ready` | reachable AND a valid unfenced role (leader/standby) | `0` for > 1 tick |
| `orch_leader_epoch` | this node's fencing epoch (0 = not leader) | flapping (repeated bumps) |
| `orch_under_provisioned` | workloads with running < desired ("converged?") | `> 0` sustained |
| `orch_reconcile_latency_ms` | last reconcile tick duration | rising trend |
| `orch_replication_lag_frames` | leader LSN minus follower confirmed-seq (0 on leader) | above your lag budget |

`/healthz` = liveness (store reachable). `/readyz` = readiness (reachable AND unfenced role). A FENCED old
leader is live (serves reads) but NOT ready -- expect `/healthz` ok, `/readyz` not-ready on a superseded node.

## 1. Leader loss / failover

SYMPTOMS: `orch_ready` 0 on the former leader; no node reports `orch_leader_epoch > 0` briefly; reconcile
stalls (`orch_under_provisioned` may rise if a workload also crashed).

DIAGNOSE: read the lease row (`leases/leader` in the config store) -- `holder|epoch|deadlineMs`. If
`deadlineMs` is in the past, the leader is gone.

RECOVER (automatic): a standby takes the expired lease via CAS, bumping the epoch (LeaderLease.tryAcquire),
and its next reconcile tick drives the fleet. Expected time to recover (RTO) = lease TTL + one reconcile tick.
Confirm: the new node reports `orch_leader_epoch = old+1` and `orch_ready 1`; `orch_under_provisioned` returns
to 0.

IF NO STANDBY PROMOTES: check every candidate can reach the store (`/healthz`). A store outage (section 4)
blocks election -- fix that first. Do NOT hand-edit the lease row to force a leader unless you have CONFIRMED
the old leader is fenced (section 2); a manual leader at a stale epoch is a split-brain.

## 2. Suspected split-brain (two leaders)

The lease CAS bounds the window; the FENCING EPOCH closes it. Two nodes can never both COMMIT, whatever their
clocks say (proven: test_clock_skew_does_not_break_fencing).

CONFIRM THE OLD LEADER IS FENCED before forcing anything:
1. Read the lease row epoch (call it E). The valid leader holds E.
2. The store's write-fence is at E (a promotion calls SqlConfigStore.setDurable/setWriteEpoch -> btree
   `SET FENCE EPOCH E`). Any node writing at an epoch < E is REJECTED by the btree executor (guardWrite)
   AND by every follower's frame check.
3. So a partitioned old leader at epoch E-1: its store writes return "Fenced: write rejected" and its shipped
   frames are dropped. It can still serve READS -- that is expected and safe.

ACTION: none required for safety -- fencing already rejects the stale writer. To retire it cleanly, stop the
old process; it will not have committed anything at its stale epoch.

## 3. Replication lag too high

SYMPTOMS: `orch_replication_lag_frames` above your budget; a promoted follower could be behind by that many
frames (the async RPO).

DIAGNOSE: lag = leader LSN minus the follower's confirmed-seq. A steady rise means the follower cannot keep
up (slow disk/network) or is stalled (check the follower `/healthz`).

RECOVER:
- For writes that must NOT be lost on failover, use DURABLE commit: the write blocks until a quorum has it
  (RPO=0). The config store enables this per connection via `SqlConfigStore.setDurable(true)` ("SET DURABLE
  COMMIT ON") -- use it for lease/CAS and workload-spec writes. Async writes trade a bounded lag for latency.
- If the follower is simply behind, let it catch up (the leader re-ships from confirmed-seq+1). If it is
  stalled, restart it; it resumes from its persisted confirmed-seq (crash-safe: applyStream durableFlushes
  before advancing confirmed-seq).
- Publish your async RPO as "at most <lag budget> frames" and page above it.

## 4. Store outage (the orchestrator depends on BTreeDB to CHANGE config)

SYMPTOMS: `orch_up 0` (store unreachable); config WRITES block; new desired-state changes cannot land.

BEHAVIOUR: reads degrade gracefully -- the leader keeps reconciling toward the LAST-GOOD desired state it
already read, so running workloads are NOT torn down during a brief store outage. Only config CHANGES block.

RECOVER: restore the BTreeDB store (restart the process; it recovers from its WAL). If the store's data file
is lost, restore from backup (section 6). Once `/healthz` is ok again, writes resume; the lease is
re-established on the next tick.

## 5. Clock skew

Fencing SAFETY does not depend on synchronized clocks -- the epoch, not time, guarantees a single writer
(test_clock_skew_does_not_break_fencing). Clocks are used ONLY for lease LIVENESS (when a standby MAY take an
abandoned lease).

SYMPTOM of bad skew: premature or delayed failover (a standby takes the lease too early, or too late). This
never causes split-brain (the epoch still fences the old leader), only sub-optimal liveness.

RECOVER: run NTP/chrony on all nodes. If a node's clock is wildly wrong, its lease TTL math is off but its
writes at a stale epoch are still rejected. Fix the clock; no data action needed.

## 6. Backup and restore

BACKUP (consistent snapshot, off-box): call `Database.exportSnapshot(dest_dir)` on the store (or run it on a
schedule). It flushes to a coherent checkpoint and writes `dest_dir/snapshot.db` (the page image) +
`dest_dir/wal/` (the WAL tail). Copy `dest_dir` off-box.

RESTORE (full, byte-for-byte):
1. Stop the store process.
2. `Database.restoreSnapshot(alloc, io, dest_dir, db_path, wal_dir)` -- copies the page image to `db_path` and
   the bundled WAL to `wal_dir`.
3. Start the store pointing at `db_path` + `wal_dir`. Opening runs recovery, which rebuilds the committed-txn
   set from the WAL so restored rows are MVCC-visible.
VERIFY: query a few known keys; the page image equals the snapshot byte-for-byte before the first open.

## 7. Point-in-time restore (roll back to before a bad change)

Use when a bad write corrupted config and you know the seq (LSN) to stop before.
1. Take/keep an EARLY checkpoint snapshot (exportSnapshot) plus the ARCHIVED WAL covering the range you may
   need to roll forward through (retain WAL segments; do not prune past your PITR window).
2. `restoreSnapshot(dest_dir, db_path, "")` to lay down the early page image, then copy the archived full WAL
   into `wal_dir`.
3. Open with `Database.openAt(db_path, pool, wal_dir, target_lsn)` where `target_lsn` is the last GOOD commit
   seq. Recovery replays the WAL FORWARD only to `target_lsn`; every txn committed after it is excluded.
VERIFY: the bad rows are gone; the last-good rows are present. (Proven: test "P7 PITR".)

## 8. Rolling upgrade with rollback (manual procedure)

Automated orchestration of this is future work; the SAFE manual sequence today:
1. Upgrade a STANDBY first. Restart it on the new build; confirm `/readyz` and that it applies frames
   (replication lag returns to ~0).
2. DRAIN the leader: stop it. The upgraded standby takes the lease (epoch bump) and drives the fleet.
3. Upgrade the OLD leader (now a standby) and rejoin. Confirm it catches up.
4. ROLLBACK: if the new build misbehaves, stop it; a node still on the old build takes the lease. Because the
   store format is unchanged across this upgrade, no data migration is needed. If a release DOES change the
   store format, snapshot first (section 6) and test restore on the new build before draining the leader.
INVARIANT: at every step at most one node holds the current epoch, so reconcile never double-drives the fleet.

## 9. Membership: add / remove a follower

ADD: start a new node as a follower (config.primary=false) pointing at the leader; it listens for shipped
frames and applies from confirmed-seq (it re-creates tables locally -- page-independent). It becomes a valid
standby once caught up (`orch_replication_lag_frames` ~0).

REMOVE: stop the follower. If it held the lease, a standby promotes (section 1). Update any quorum sizing:
DURABLE writes need N/2+1 acks counting the leader, so removing followers changes the quorum -- confirm
remaining nodes can still form one, or durable writes will time out and clients retry.

## 10. Detected corruption (frame or page)

Every shipped frame is CRC32'd; a corrupt frame is rejected at the deserialize boundary and NEVER applied
(proven: test "P8 chaos: a corrupted shipped frame ..."), so corruption does not propagate to a follower.

If a stored PAGE is corrupt (checksum/`InvalidChecksum` on open): restore from the most recent good backup
(section 6), or PITR to just before the corruption (section 7). Do not run against a db that logs checksum
errors on open -- snapshot the WAL first if you need forensic data, then restore.

## 11. Deploy / scale / tear down from the browser (orchweb)

`orchweb` is the writable web control plane (a Tailwind web app under `webui/`: a node -> service -> replica
tree, click a service for its manifest form, click a node to deploy). It does not reconcile anything itself:
every action writes desired state into the SAME config store `orchd` reconciles from, so a click is applied
by the leader `orchd`'s reconcile loop.

Run it beside the cluster:
1. Point it at the store: `NOVA_ORCHWEB_DSN=novadb://admin@<btree-host>:3009?db=nova`, `NOVA_PORT=8130`.
2. Start `build/*/bin/orchweb`; open `http://127.0.0.1:8130`. The table refreshes every 2s from the store.

- DEPLOY / update: paste a manifest YAML and click Deploy. It is validated (a bad manifest is rejected with
  the reason, nothing is written) then stored canonically at `workloads/<name>`. The leader `orchd` starts or
  updates the workload on its next tick.
- SCALE: set the app name + min/max and click Scale (the per-row Load button fills these in). It rewrites the
  stored manifest's replica band in place; `orchd` converges to the new count.
- TEAR DOWN: the per-row button deletes `workloads/<name>`. `orchd` then stops that workload's replicas.

VERIFY an action took effect without the UI: `orchctl inspect` over a store dump shows the workloads/ keys,
and `orch_workload_desired`/`_running` in `/metrics` move to the new count.

NOTE: orchweb is read-write against the store but holds NO lease and drives NO processes. If the store is
down, actions fail loudly (the status line goes red) and nothing changes -- exactly like `orchctl`. Run one
`orchweb` per cluster (it is stateless; a second instance is harmless but redundant).
