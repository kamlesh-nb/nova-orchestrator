# Orchestrator to Production Grade + BTreeDB-backed replicated config store

Status: DESIGN (not started). Scope decided 2026-08-01; revised 2026-08-01 to a PRODUCTION-GRADE bar
(the earlier Beta scope is folded in as the P0-P4 midpoint, and sections 9-12 add what production
actually requires). Implementation is a later, gated effort; this document only has to be ready so the
work can start cleanly.

## 0. Beta vs Production grade (read this first)

These are two different bars and the difference is not "more features" - it is provable behaviour under
failure. This document targets the SECOND bar, but ships through the first.

- BETA (P0-P4): durable config, single-writer replication with hot standbys, lease-based failover, and
  reconcile driven from the store. Good enough for internal and staging workloads. Failover works in the
  happy path; the split-brain window is documented, not closed; data loss on failover is bounded only by
  "a few frames".
- PRODUCTION GRADE (P0-P8): everything in Beta, PLUS the three things that separate a demo from a system
  you can page someone about at 3am:
  1. FENCING - a promoted leader can prove the old leader can no longer commit (no split-brain writes,
     not just a documented window).
  2. A STATED, TESTED RPO/RTO - "on leader loss you lose at most X and recover within Y", proven by a
     chaos suite, not asserted in prose.
  3. OPERABILITY - backup/restore, rolling upgrade with rollback, authn/authz + TLS on every hop,
     observability with alerting, and a runbook. A system is production grade when someone who did not
     write it can operate it under failure.

If only P0-P4 land, say "Beta" honestly. Do not call P0-P4 "production grade" - that mislabel is exactly
how a documented split-brain window becomes a 3am incident.

## 1. Goal

Take the native orchestrator from MVP to PRODUCTION GRADE, and give it a durable, replicated
control-plane store instead of a local file directory. The store is BTreeDB. "Replicate config" means:
the desired-state config survives a node crash AND is mirrored to standby orchestrator nodes so one can
take over WITHOUT losing committed config and WITHOUT two leaders ever writing at once. This is the same
shape as etcd behind Kubernetes, scaled down and built on what already exists.

Three coupled deliverables:
1. BTreeDB: finish durability, finish the replication path (ship side exists; follower/apply and wiring
   do not), and add the primitives production needs (fencing epoch/CAS, quorum-ack option, backup/restore,
   authenticated+TLS replication).
2. A config-store layer on BTreeDB (etcd-shaped key/value + watch + txn/CAS), owned by the orchestrator.
3. Orchestrator production hardening: read/reconcile desired state from the store instead of the manifest
   directory, fenced leader election, plus the operability items in sections 6 and 9-12.

## 2. Current state (honest)

### Orchestrator (packages/nova-orchestrator)
- `orch/nativelet` is the node agent: watches a JSON MANIFEST DIRECTORY (`Nativelet("manifests")`),
  reconciles desired vs actual, restarts crashed replicas, HTTP-probes and restarts on probe failure,
  stops workloads whose manifest was deleted. One async coroutine drives the loop.
- `orch/autoscaler` is a PID workload scaler (cgroup CPU-rate sampled). `orch/supervisor`, `orch/spec`,
  `orch/isolation` provide spawn/stdio/wait/kill and the isolation layer. `net/proxy` + `net/autoscale`
  are the reverse-proxy + LB + PID-replica autoscaler (I1).
- CONFIG IS LOCAL AND FILE-BASED. It is not durable beyond the filesystem, not versioned, not
  replicated, and there is no leader/standby concept. This is the MVP gap.

### BTreeDB (btree/, separate Zig repo)
- Durability: LARGELY DONE (the readiness plan section 0 exec-summary is stale; section A records the
  fixes). WAL is write-ahead via the `poolWalFlushTo` page gate; async commit `write()`s to the OS at
  commit (survives process crash, not power loss); leader/follower group fsync (`ensureDurableTo`,
  `appendLocked`) with no fsync-under-mutex; crash sync+async 200/200, concurrency gate 3600/3600.
  REMAINING durability item to confirm/close: undo-log reconstruction on boot (recovery can otherwise
  erase committed rows), and making sync-commit the default for the config workload.
- Concurrency: still a single process-wide `db.rw_lock` (the ~5-thread ceiling). LOAD-BEARING for
  correctness; the lower layers race without it. For a CONFIG store this does NOT matter (tiny data,
  low write rate, a handful of clients), so lock-narrowing is OUT OF SCOPE here and stays gated on
  measured evidence per the readiness plan.
- Replication: `src/query/replication.zig` has the SHIP side only. `ReplWal` (segmented replication WAL
  with checkpoint/rotate/read), `ReplClient.ship` (streams WAL frames to a peer), `CheckpointRecord`.
  MISSING: the follower/apply side (receive frames, apply to the local db, ack a confirmed seq), and any
  wiring into the server/db (nothing outside replication.zig references it). Leader election does not
  exist.

## 3. Target architecture

A small, single-writer, WAL-shipping replicated store. Deliberately NOT multi-master or Raft: config is
low-volume and a single leader with hot standbys is enough for Beta and matches what BTreeDB already has.

```
          orchestrator node A (LEADER)                 node B (FOLLOWER / standby)
        +----------------------------+               +----------------------------+
        | reconcile loop  <-- watch  |               | reconcile loop (paused or  |
        |        |                   |               |   read-only until promoted)|
        | config-store API           |               | config-store API (RO)      |
        |   put/get/list/watch       |               |   get/list/watch           |
        |        |                   |               |        ^                   |
        |   BTreeDB (writer)         |  WAL frames   |   BTreeDB (applies frames) |
        |   ReplWal.append + ship ---+-------------->+---> follower.apply -> db   |
        +----------------------------+   (ship side  +----------------------------+
                                          exists;       (apply side = to build)
                                          apply = new)
```

- The LEADER is the only BTreeDB writer. Config changes are rows in a `config` table (or a KV table):
  `(key TEXT PRIMARY KEY, value BLOB, revision INTEGER, ...)`.
- BTreeDB's existing durability makes each committed config change crash-safe on the leader.
- `ReplClient.ship` streams the leader's committed WAL frames to each follower; the follower APPLIES them
  (new code) so its BTreeDB is a byte-consistent replica, and ACKs a confirmed seq (the `CheckpointRecord`
  already models this).
- On leader loss, a follower is PROMOTED: it stops applying, becomes the writer, and starts shipping. For
  Beta, leader election can be simple (a configured priority list + a lease/lock row, or an operator-set
  leader) rather than full consensus; document the failure modes.

### Config-store API (the etcd-shaped seam, in Nova, in the orchestrator package)
- `put(key, value) -> revision`  (leader only; goes through the BTreeDB driver on the async DB seam)
- `get(key) -> (value, revision) | none`
- `list(prefix) -> [(key, value, revision)]`
- `watch(prefix) -> stream of change events` (poll the `revision` column initially; a push channel later)
- `txn` / compare-and-set on `revision` for optimistic concurrency (needed for leader lease + safe writes)

The orchestrator's reconcile loop reads DESIRED STATE from `list("workloads/")` instead of scanning the
manifest directory. The manifest directory becomes an OPTIONAL bootstrap importer (load files once into
the store), not the source of truth.

## 4. Phased plan (ordered; each phase independently shippable)

- P0 BTreeDB durability close-out: confirm/land undo-log rebuild on boot; default the config workload to
  sync commit; a crash test that kills the leader mid-write and proves no committed config is lost. Gate:
  btree crash tests green.
- P1 Config-store layer (single node, no replication yet): the KV/config table + the Nova config-store
  API over the existing BTreeDB async driver seam. Orchestrator reads desired state from the store; the
  manifest dir becomes a bootstrap importer. Gate: reconcile works entirely from the store on one node.
  STATUS (2026-08-02): the etcd-shaped API exists in TWO forms, both offline-tested:
  (a) `src/store/config.nova` -- in-memory ConfigStore reference/oracle (test 184, 5 cases);
  (b) `src/store/sqlconfig.nova` -- SqlConfigStore, the async SQL-backed path over the data.db Connection
  seam (config + config_meta tables; put = upsert, cas = check-then-bump, list/watch = scan + filter),
  tested against a FakeConn that simulates the tables (test 185, 5 cases; a sync @test block-drives the
  async methods).
  Reconcile is REWIRED (2026-08-02): Nativelet.reconcileFromEntries(entries, "workloads/") decodes store
  rows into the existing source-agnostic reconcileScan diff, so the config store is the source of truth
  and the manifest dir is an optional bootstrap importer (test 186: start/replace/drop/prefix-isolation/
  stop-all/keep-on-empty, 2 cases). The daemon does the async store fetch and passes entries in, so it
  works with either ConfigStore (sync) or SqlConfigStore (async).
  P1 GATE MET (2026-08-02): tests/live/187_sqlconfig_live.nova runs the full API + store-driven reconcile
  against a REAL btree server (nova-btreedb driver on the reactor); run-live-tests.sh starts/stops a fresh
  server. The live run required one fix -- BTreeDB UPDATE does not evaluate a column-referencing
  expression (`SET rev = rev + 1` -> empty tag), so nextRevision is a read-modify-write with an explicit
  value (`UPDATE ... SET rev = $1`). TEXT PRIMARY KEY + INT + $N params all accepted. **P1 COMPLETE.**
- P2 BTreeDB replication apply side: implement follower receive+apply+ack; wire ship/apply into the db
  lifecycle; a two-node test where a write on the leader appears on the follower and survives a follower
  restart from its checkpoint. Gate: leader/follower byte-consistent under a write workload.
- P3 Orchestrator HA (FENCED): leader/standby roles, a leader lease (a CAS row in the store) carrying a
  monotonically increasing FENCING EPOCH, promotion on leader loss, followers reconcile read-only until
  promoted. Every write and every shipped WAL frame carries the epoch; a follower/store REJECTS any write
  or frame stamped with an epoch older than the highest it has seen, so a partitioned old leader cannot
  commit even before its lease TTL expires. Gate: kill the leader, a standby promotes, and the old leader
  (artificially unpaused after promotion) has its writes REJECTED by fencing - proven, not documented.
- P4 Beta line (section 6 checklist). This is the "honest Beta" cut point: ship internally here if needed.
  Gate: the Beta definition-of-done met. Everything below is what makes it PRODUCTION grade.
- P5 Bounded durability on failover (RPO): make the config write path either sync-replicate to a quorum
  before ack (writer waits for N/2+1 followers' confirmed-seq to cover the frame) OR expose a per-write
  "durable" flag that does so. State the RPO explicitly (RPO=0 for durable writes; bounded lag for async).
  Gate: kill the leader immediately after a durable-acked write; the promoted follower HAS that write.
- P6 Security on every hop: authn + authz on the config-store API (only the orchestrator identity may
  write; RBAC for read scopes), and mutually-authenticated TLS on the replication stream and the client
  connections (reuse the pure-Nova TLS 1.3 stack). No plaintext WAL frames on the wire, no unauthenticated
  writer. Gate: an unauthenticated peer cannot ship frames or write config; a wrong-cert follower is
  refused.
- P7 Operability: backup + point-in-time restore of the store; rolling upgrade of orchestrator nodes with
  rollback (drain leader -> promote standby -> upgrade old -> rejoin); a membership/reconfiguration path
  (add/remove a follower without downtime); a runbook for each failure mode. Gate: a full backup/restore
  cycle recovers config byte-for-byte; a rolling upgrade keeps reconcile continuous.
- P8 Chaos + soak (the RPO/RTO proof): an automated fault-injection suite (kill leader mid-write, partition
  old leader, kill follower mid-apply, corrupt a shipped frame, disk-full on commit, clock skew) plus a
  multi-hour soak under a write workload. Gate: across the whole suite, ZERO committed-config loss beyond
  the stated RPO, ZERO split-brain writes, and recovery within the stated RTO - reported as numbers.

Ordering rationale: durability before you trust the store with config (P0); the store before replication
(P1 gives value on one node immediately); replication before HA (P2 is the mechanism, P3 is the policy);
FENCING lands WITH failover in P3 (an unfenced failover is not safe to ship even for Beta demos beyond a
single operator); then the production layers - bounded RPO (P5), security (P6), operability (P7) - and
finally the chaos suite (P8) that PROVES the RPO/RTO claims the earlier phases only implement.

## 5. BTreeDB work items (btree repo)

> The DB-provider side of these items is designed in detail in the btree repo:
> `btree/docs/replication-ha-design.md` (follower/apply, fencing epoch, quorum-ack, backup/restore,
> leader-lease CAS, the wire additions, phased plan R0-R6, and the test matrix). The list below is the
> orchestrator-facing summary; that doc is the implementation reference.

1. Undo-log reconstruction on boot (durability correctness). Confirm current behavior with a
   kill-during-uncommitted-txn test; if recovery can drop committed rows, rebuild the undo state from the
   WAL on open. [durability]
2. Sync-commit default for the config path (config is tiny; pay the fsync, it is not the bottleneck per
   the readiness plan's measurement). [durability]
3. Replication follower/apply: a `Follower`/`apply` that reads shipped frames, applies them to the local
   db in seq order, persists the confirmed seq (reuse `CheckpointRecord`), and acks. Wire ship on the
   leader + apply on the follower into db open/close. [replication]
4. A leader-lease primitive: a CAS on a well-known row (revision compare-and-set) so exactly one node
   writes. Election policy can live in the orchestrator; BTreeDB only needs the CAS. [replication]
5. FENCING EPOCH (production): the lease row carries a monotonically increasing epoch; every write and
   every shipped WAL frame is stamped with the writer's epoch; the store and each follower persist the
   highest epoch seen and REJECT anything stamped lower. This closes split-brain independently of lease
   TTL/clock. [replication/safety]
6. QUORUM-ACK option (production, for RPO=0 writes): the writer can wait until N/2+1 followers report a
   confirmed-seq covering the frame before acking the client. Async remains the default; durable writes opt
   in. [replication/durability]
7. AUTHENTICATED + TLS replication (production): the ship/apply stream runs over mutually-authenticated TLS
   (pure-Nova TLS 1.3 stack) and rejects an unauthenticated or wrong-identity peer. No plaintext frames.
   [security]
8. BACKUP / RESTORE (production): a consistent snapshot (checkpoint + WAL tail) that can be copied off-box
   and restored to a known revision; point-in-time restore by replaying WAL to a target seq. [operability]
9. Tests: two-node ship/apply consistency; leader-kill no-loss; follower-restart-from-checkpoint; FENCED
   old-leader write rejected; quorum-ack survives leader kill with RPO=0; backup/restore round-trips
   byte-for-byte; corrupt-frame is detected and rejected (checksum), not applied.

Explicitly OUT OF SCOPE for this design: removing the global `db.rw_lock` (the concurrency epic; gated on
throughput evidence, and irrelevant to a config store). Full Raft/multi-master (single-writer + fencing +
quorum-ack is the deliberate, sufficient choice for a low-volume control plane; revisit only if config
write volume ever demands multi-writer, which it will not).

## 6. Definition-of-done

### 6a. Beta line (P0-P4) - honest internal/staging cut
- Desired state comes from the replicated store, not the local manifest directory (manifest dir is a
  bootstrap importer only).
- HA: a standby promotes on leader loss and keeps reconciling from the last committed config (P3), and the
  promotion is FENCED (old leader's writes rejected).
- Config is versioned (the `revision` column) and changes are auditable (who/when as columns).
- Reconcile is idempotent and crash-safe: a mid-reconcile crash re-derives from the store on restart,
  never double-starts or orphans a workload.
- Health/readiness of the orchestrator itself is exposed (an endpoint), separate from workload probes.
- Rollout safety: a bad spec update does not take down healthy replicas (validate before apply; keep the
  last-good revision).
- Observability: structured logs + basic metrics (reconcile latency, replica count vs desired, restart
  counts, leader identity, replication lag = leader LSN minus follower confirmed seq).
- Bounded blast radius: resource limits + isolation already exist (I4); confirm they are enforced on the
  store-driven path.

### 6b. Production-grade line (P5-P8) - everything above PLUS
- SAFETY: fencing is proven by test (P3 gate) - two leaders can never both commit. No split-brain writes
  under any injected partition (P8).
- DURABILITY: a stated RPO. Durable (quorum-acked) writes have RPO=0 across a leader kill (P5 gate); async
  writes have a stated, monitored bounded lag. The number is published, not implied.
- RECOVERY: a stated RTO. Time from leader loss to a promoted, reconciling standby is measured and within
  the published bound (P8 gate).
- SECURITY: authn + authz on the config API; mutually-authenticated TLS on replication and client hops; no
  unauthenticated writer, no plaintext frames (P6 gate).
- OPERABILITY: backup + point-in-time restore verified (P7); rolling upgrade with rollback keeps reconcile
  continuous (P7); a runbook exists for each failure mode in the risk register (section 7).
- PROVEN, NOT ASSERTED: the chaos + soak suite (P8) runs in CI or on a schedule and reports RPO/RTO/no-loss
  /no-split-brain as numbers. A claim without a passing fault-injection test does not count.

## 7. Risks and open decisions (each needs a runbook entry for production)

- LEADER ELECTION policy: Beta may start operator-set or static-priority + lease; PRODUCTION requires the
  fencing epoch (section 5 item 5) so an unfenced failover is never the shipped path. Decide the auto vs
  operator-triggered promotion bar; either way, promotion bumps the epoch.
- SPLIT-BRAIN: the lease/CAS row bounds the window; the FENCING EPOCH closes it (old leader's stamped
  writes/frames are rejected regardless of clock or lease TTL). Runbook: how to confirm the old leader is
  fenced before forcing promotion.
- REPLICATION LAG vs consistency: async WAL shipping means a promoted follower can be behind. Production
  answer: quorum-ack (P5) for writes that must not be lost; monitor lag and alert past a threshold; state
  the async RPO explicitly. Runbook: what lag value pages, and what to do.
- COUPLING: the orchestrator hard-depends on BTreeDB being up to CHANGE config. Mitigate: the leader caches
  the last-good desired state in memory so RECONCILE survives a brief store outage (read path degrades
  gracefully; writes block). Runbook: store-down procedure.
- CLOCK SKEW: leases use time; fencing epochs do not. Production must not depend on synchronized clocks for
  SAFETY (only for liveness/lease expiry). Verify fencing holds under injected skew (P8).
- CORRUPTION: a shipped frame or a page could be corrupt. Every frame is checksummed and rejected on
  mismatch (never applied); backup/restore is the recovery path. Runbook: detected-corruption procedure.
- PRIORITY: per the standing rule, language/compiler/runtime work outranks this. This is infra; schedule it
  deliberately and do not let it pull focus from the language gates. Production grade here is a real
  multi-week effort (P5-P8 roughly double the P0-P4 cost); do not start it until an orchestrator is on the
  critical path.

## 8. Summary of what exists vs what to build

Legend: [B] = Beta line (P0-P4). [P] = Production line (P5-P8).

| Piece | Exists | To build |
|---|---|---|
| BTreeDB durability | crash sync/async, WAL-before-page gate | [B] undo-rebuild-on-boot confirm; sync-commit default for config |
| BTreeDB replication (ship) | ReplWal, ReplClient.ship, CheckpointRecord | [B] follower apply+ack; wiring; leader-lease CAS |
| Config store (KV + watch + txn/CAS) | nothing | [B] the table + the Nova API over the async DB seam |
| Orchestrator config source | local JSON manifest dir | [B] read/reconcile from the store; manifest dir as bootstrap importer |
| Orchestrator HA (fenced) | nothing (single node) | [B] leader/standby, lease, promotion + fencing epoch |
| Orchestrator Beta hardening | MVP reconcile/restart/probe/autoscale | [B] section 6a checklist |
| Fencing epoch (split-brain close) | nothing | [P] epoch on lease + stamped writes/frames; reject-lower on store+follower |
| Bounded RPO (quorum-ack) | nothing (async only) | [P] quorum-ack write path + per-write durable flag; stated RPO |
| Security (authn/authz + TLS) | pure-Nova TLS 1.3 stack exists | [P] mutual-TLS on replication+client; RBAC on config API |
| Backup / restore (PITR) | WAL + checkpoint exist | [P] consistent snapshot off-box; replay-to-seq restore |
| Rolling upgrade + membership | nothing | [P] drain/promote/upgrade/rejoin; add/remove follower live |
| Chaos + soak proof (RPO/RTO) | nothing | [P] fault-injection suite + multi-hour soak; numbers in CI |
| Runbooks | nothing | [P] one per failure mode in section 7 |
