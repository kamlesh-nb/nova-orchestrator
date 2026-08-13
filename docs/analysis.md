# nova-orchestrator: what is good and what is missing

Status: analysis (2026-08-12). Scope: the whole package under `packages/nova-orchestrator/` (~9,100 lines of
Nova across `src/net`, `src/orch`, `src/store`, `src/cfg`, `src/os`, the four `bin/` entrypoints, the
`webui/` control-plane app, and the `tests/` suite). This is a companion to the README: the README says what
the stack does, this document says how far each part actually goes and what would have to change before it can
be called production HA.

## Headline

The orchestrator is a clean, coherent, container-free control plane. The data plane (L7 proxy, load balancing,
health checks, service discovery), the reconcile loop, the supervisor, and the observability surface are
genuinely solid and well tested at the logic level. The weak point is the HA story: it is a well-designed
single-store optimistic lease, not distributed consensus, and its central safety proof holds only against the
in-memory reference store. On the live NovaDB path the compare-and-set is not atomic, which is a real
split-brain hole. There are zero TODO/FIXME/stub markers in the tree; the incompleteness is architectural, not
littered, so it is easy to miss.

One caveat for anyone building on this: the working tree currently has uncommitted modifications (README,
`src/orch/{controlplane,manifest,nativelet}.nova`, `tests/186_controlplane.nova`, `gate.sh`, `run-tests.sh`,
`build.sh`, `docs/runbooks.md`). This analysis reads the working-tree state.

## Findings tracking table

This document is the audit; the fixes are planned in `platform-readiness.md` and tracked at
`../../../PLATFORM-PLAN.md`. Status values: `open`, `in progress`, `fixed`, `deferred`, `wontfix`. "Fix" points
to the plan item that closes the finding.

| ID | Finding | Severity | Fix | Status |
|----|---------|----------|-----|--------|
| F-1 | Live-path CAS not atomic -> split-brain election | CRITICAL | C-T2-1 | FIXED (casBy now issues a single guarded `UPDATE ... WHERE k=? AND revision=?`, an atomic read-modify-write under NovaDB's per-table exclusive lock, once B-3 gave the engine a real guarded UPDATE; the read-then-unguarded-write TOCTOU is gone) |
| F-2 | Quorum gate is dead code (never called by the lease) | HIGH | C-T2-2 | FIXED (AsyncLeaderLease.tryAcquire now calls hasQuorum(): with members configured, only a registered member with a store-visible majority may take the lease; no members = single-orchd mode, unchanged) |
| F-3 | HA is a single-store lease, not consensus (framing/doc) | HIGH | doc + single-orchd deployment | open |
| F-4 | Service VIP bind silently non-functional (binds INADDR_ANY) | HIGH | POLISH (deferrable at medium scale) | open |
| F-5 | Config validation only partly loud-fail (`?? default`) | MEDIUM | POLISH | open |
| F-6 | Graceful shutdown has no real grace window | HIGH | C-T1-3 | open |
| F-7 | Manifest change bounces the whole workload (no rolling update) | HIGH | C-T1-1 | open |
| F-8 | Probe-driven heal is stop-the-world, no backoff | MEDIUM | POLISH | open |
| F-9 | Autoscaler regulates aggregate cgroup CPU vs per-workload setpoint | MEDIUM | POLISH | open |
| F-10 | Blocking reaps inside the reactor-0 control coroutine | MEDIUM | C-T1-3 | open |
| F-11 | Data-plane 64 KB ceiling, idle-fd leak, unbounded concurrency, no shutdown | MEDIUM | C-T1-5 | open |
| F-12 | Non-atomic discovery file write (torn reads) | MEDIUM | C-T1-4 | open |
| F-13 | Silent isolation downgrade with no observability | MEDIUM | C-Iso | open |
| F-14 | httpProbe fixed-offset parse; backup no escaping; metrics/HTML no escaping; netns addr bound | LOW | POLISH | open |

## Part 1: correctness defects (fix first)

These are ranked by how badly they undermine a promise the stack makes.

1. **The live-path CAS is not atomic, so leader election can split-brain. CRITICAL.**
   The entire HA safety argument (`orch/lease.nova:5-10`, `orch/asynclease.nova`) rests on "CAS = exactly one
   winner per epoch." The in-memory `ConfigStore.casBy` (`store/config.nova:129-143`) is correctly atomic (a
   synchronous index check then write), which is why the offline chaos tests pass. But the live
   `SqlConfigStore.casBy` (`store/sqlconfig.nova:167-205`) is a read-then-write across two awaits:
   - Create path (`expectedRevision == 0`): `exists(key)` then an unconditional `INSERT` whose result is
     discarded (`let _1 = await ...`) and `rev` is returned regardless. Two nodes racing on a free lease can
     both observe `exists == false` and both "succeed", giving two leaders at epoch 1.
   - Update path: `SELECT revision`, compare, `nextRevision()`, `UPDATE`. Classic TOCTOU between the SELECT
     and the UPDATE.
   The code's defence is the comment "single writer, so no TOCTOU", but leader election is precisely the
   multi-writer moment before any single writer exists. The property proven offline is not the property that
   runs in production. Fix: make `casBy` a single guarded statement (`UPDATE ... WHERE k = ? AND revision = ?`
   plus a create that checks `rows_affected` / relies on the PRIMARY KEY conflict), or wrap it in a real
   transaction. The fencing epoch (item below) only saves you if acquire is atomic first.

2. **The quorum gate is dead code. HIGH.**
   `membership.quorum()` (`orch/membership.nova:49-52`) is documented as the guard that stops a minority
   partition electing a leader. Neither lease ever calls it: `tryAcquire` (`orch/lease.nova:90`,
   `orch/asynclease.nova:37`) never consults membership. The only caller is `bin/orchctl.nova:66`, for a status
   printout. So the advertised split-brain-prevention gate is not wired into the election path.

3. **HA is a single-store lease, not consensus. HIGH (framing).**
   There is no Raft/Paxos among the orchestrator nodes. All nodes contend on one lease row in one shared
   NovaDB (`store/sqlconfig.nova:3-8`). That is a legitimate design (etcd-style lease over a consistent store),
   but the doc-comments oversell it as fencing-grade distributed safety. Orchestrator HA is only ever as strong
   as NovaDB's own leader/follower durability (`SET DURABLE COMMIT`, `store/sqlconfig.nova:70-79`) plus a
   correct atomic acquire. State that plainly.

4. **Service VIP bind is silently non-functional. HIGH.**
   `net/proxy.nova:684-701` (`proxyAcceptLoop`) always binds `INADDR_ANY` via `sys.makeSockaddrIn(port, 0)` and
   discards the `host` argument; the comment at `:686-688` admits the specific-VIP bind is a follow-up. But
   `serveAddr(host, ...)` (`:877-880`) advertises "binds a SPECIFIC address (a Service VIP such as 127.0.0.2)"
   and `net/service.nova` depends on it. Net effect: every Service with a VIP binds all interfaces on that port,
   and two Services with distinct VIPs on the same port collide. The VIP feature reads as done but is not.

5. **Config validation is only partly loud-fail. MEDIUM.**
   The README promises "a present file with a bad value fails loudly at startup, never silently defaults."
   `validateOrch`/`validateProxy`/`validateStore` are real and do exit 1 with a reason on out-of-range ports,
   unknown strategies, or a missing backend list (`bin/orchd.nova:55-59`, `bin/service.nova:70`). But the load
   path (`cfg/config.nova:98-128, 251-269`) uses `?? default` on every field, so a present-but-wrong-type or
   malformed field silently falls back to its default rather than failing loudly. The loud-fail covers
   semantics and ranges, not type or shape.

## Part 2: robustness gaps

1. **Graceful shutdown has effectively no grace window. HIGH.**
   `Supervisor.stopProc` (`orch/supervisor.nova:165-175`) sends SIGTERM then spins `while (tries < 50)` over a
   non-blocking `tryWait` with no sleep, so the 50 iterations complete in microseconds and SIGKILL follows
   almost immediately. Any workload that needs more than a few microseconds to flush is killed hard. Give it a
   real timed window (sleep between polls, or a wall-clock deadline).

2. **A manifest change bounces the whole workload, no rolling update. HIGH.**
   `reconcileScan` (`orch/nativelet.nova:303-310`) reacts to any spec change with `stopAll()` then a fresh
   supervisor `start()`, so every replica goes down together and then comes back. There is no surge /
   maxUnavailable / rolling replacement for workload replicas. `orch/rollout.nova` is only for rolling
   control-plane node upgrades, not workloads. So "rolling upgrade safety" does not exist for the pods
   themselves; a spec edit is a hard bounce.

3. **Probe-driven heal is a stop-the-world bounce with no backoff. MEDIUM.**
   At `PROBE_FAIL_LIMIT`, `probeAndHeal` (`orch/nativelet.nova:412-416`) does `stopAll()` then `start()`,
   restarting every replica at once, on top of the per-replica restarts `poll()` already does. A persistently
   failing probe becomes a tight restart loop each tick. The crash-loop alert has hysteresis
   (`orch/alerts.nova:60`) but the action does not.

4. **The autoscaler regulates aggregate cgroup CPU against a per-workload setpoint. MEDIUM.**
   `isolation.cgroupDir` keys on `sp.name` only (`orch/isolation.nova:21-22`), so all replicas of a workload
   share one cgroup and `cpuUsageUsec` returns aggregate CPU across replicas. `tickCpu`
   (`orch/autoscaler.nova:62-74`) feeds that aggregate into a PID with a fixed percent setpoint, but aggregate
   CPU tracks total demand, not per-replica saturation, so adding replicas does not lower the measured metric
   the way the controller assumes; the loop can fail to converge or oscillate. It should divide by the replica
   count. Relatedly, the cgroup `cpu.max`/`memory.max` limits are a single budget shared across all N replicas
   (`orch/isolation.nova:36-48`), which is probably not what a user expects from "cpuMilli per workload."

5. **Blocking reaps inside the reactor-0 control coroutine. MEDIUM.**
   The autoscaler's scale-down calls `p.terminate()` then a synchronous `p.wait()` (`net/autoscale.nova:155`)
   on the same reactor that runs the health sweep; a backend slow to exit on SIGTERM stalls reactor 0.
   `netns.runIp` (`net/netns.nova:109-112`) likewise does a blocking `pr.wait()` with no timeout.

6. **Data-plane resource and lifecycle gaps. MEDIUM.**
   `net/proxy.nova` has a hard 64 KB per-message buffer (`readMessage`, `:427`): oversized bodies set
   `framed = false`, get clamped, and are returned truncated with the connection dropped from reuse. There is
   no streaming. Pooled idle backend fds (`b.idle[tid]`, `:534`) are never reclaimed on scale-down or drain and
   have no idle-timeout reaper. Client concurrency is unbounded (`coroStart(handleClient)` per accept, `:714`,
   each allocating 64 KB) with no backpressure, and every accept/health loop is `while(true)` with no
   cancellation or graceful drain.

7. **Non-atomic discovery file writes. MEDIUM.**
   `ServiceRegistry.flush` (`net/service.nova:93-103`) rewrites the whole `name=host:port` file via `writeText`
   on every register, with no temp-file-plus-rename and no locking, so a concurrent `resolveAllFrom` reader can
   see a partial or empty file. This is the one coupling between the control and data planes, so a torn read
   there drops backends.

8. **Silent security-relevant isolation downgrades. MEDIUM.**
   `isolation.applyLimits` (`orch/isolation.nova:31-49`) ignores every `writeText` result, so on macOS or
   unprivileged Linux the workload runs unlimited with no warning or metric. netns and sandbox degrade to a
   plain spawn off Linux (`orch/supervisor.nova:121-123, 150-156, 197`). This is correct by design, but there
   is no "isolation requested but not applied" signal anywhere, which is a quiet downgrade for something
   security-relevant. Surface it in `/metrics` and `readyz`.

9. **Smaller correctness notes. LOW.**
   `httpProbe` (`orch/nativelet.nova:427-440`) reads the status byte at fixed offset 9, assuming exactly
   `"HTTP/1.1 "`; an `HTTP/1.0` reply or any deviation misreads it, and only the first digit is checked.
   `backup.dump/restore` (`orch/backup.nova`) assumes values are tab/newline-free with no escaping, so a spec
   or lease value containing a newline corrupts the dump. `renderMetrics`/`appsTable`
   (`orch/health.nova:113`, `orch/controlplane.nova:120`) do not escape workload or app names, so a name with a
   quote breaks Prometheus exposition or the HTML. The unbounded `10.66.${idx}.0/30` netns addressing
   (`net/netns.nova:55`) produces invalid addresses beyond idx 255 with no check.

## Part 3: what is genuinely production-quality

This is a real system, and these parts are good.

- **The reconcile loop** (`orch/nativelet.nova:286-332`). The desired-vs-actual diff is correct and complete
  for its model: start-new, replace-changed, poll-unchanged, keep-on-unreadable (a half-written manifest this
  tick keeps the existing workload running rather than tearing it down, `:295-300`), and stop-only-when-the-file-
  is-genuinely-gone. It parses and validates a manifest before adopting it (`:174-176, 244-256`), so a broken
  manifest never replaces a healthy workload. Discovery is published before the probes deliberately (`:457-459`).

- **The supervisor** (`orch/supervisor.nova:216-255`). Non-blocking `tryWait` throughout, correct in-place list
  mutation on reap, port and netns-slot reclamation, restart policy honoured. The simulated path faithfully
  mirrors the real path, which is why the logic is testable offline.

- **The fencing-epoch design** (`orch/lease.nova`, `orch/health.nova:124-129`). This is the right model:
  epoch, not time, is what makes two committers impossible, and time is only for liveness. The sync/in-memory
  variant is fully correct. It would be correct on the live path too once the underlying CAS is atomic
  (Part 1, item 1).

- **The data plane** (`net/proxy.nova`). Four LB strategies, per-reactor lock-free cursors and connection
  pooling with HAProxy-style safe-reuse retry-once, a careful HTTP framing state machine (Content-Length,
  chunked, read-to-EOF), active health checks with rise/fall hysteresis, and SO_REUSEPORT share-nothing accept
  fan-out. Empty-pool and all-backends-down are handled (a port-0 selection becomes a 502). The
  per-reactor-lock-free reasoning is documented and internally consistent.

- **Observability** (`orch/health.nova`, `orch/alerts.nova`). healthz/readyz/metrics, replication-lag clamp,
  fenced-role readiness handling, and Prometheus plus log alert rendering with severities. Thorough and usable.

- **The PID autoscaler math** (`net/autoscale.nova:70-77`). Textbook PID with anti-windup integral clamp,
  output clamp, and a dt-guarded derivative, with actuation cleanly separated from the decision. The math is
  clean; the issue is the metric it is fed (Part 2, item 4), not the controller.

- **The webui** (`webui/src/`). A real, fully-wired `nova init web` vertical-slice app, not a skeleton. All six
  slices (GetTree/GetService/GetNode/NewServiceForm/DeployService/TeardownService) call the real async
  `SqlConfigStore`: deploy validates a manifest then `putBy("workloads/"+name, toYaml(m), "orchweb")`, teardown
  does `del("workloads/"+name)`, reads hit `list("members/")`/`list("workloads/")`. The webui does not itself
  reconcile; it writes to the same store `orchd` reconciles from, and the loop closes through
  `asynclease.haReconcileTick` then `nativelet.reconcileFromEntries`. The README claim is accurate.

## Part 4: the config store, plainly

There are two stores and the production path is NovaDB-backed.

- `ConfigStore` (`store/config.nova`) is the in-memory reference/oracle: keys in a `List` with linear-scan
  lookup (a deliberate workaround because a cross-module struct-valued `Map` mono-miscompiles today,
  `:15-16`), atomic synchronous CAS. Offline and deterministic.
- `SqlConfigStore` (`store/sqlconfig.nova`) is the real path over the async `Connection` seam against NovaDB.
  It supports CAS-on-revision, monotonic global revision, prefix list, delete, and a poll-based watch. It does
  NOT use transactions (the `Connection` trait exposes `begin`/`commit`/`rollback`, but the store never calls
  them), so all atomicity rests on the single-writer assumption, which is exactly the assumption Part 1 item 1
  shows is unenforced during election. A push-based watch is deferred; `list`/`watch` do a full scan plus
  Nova-side prefix filter (fine for a small config store, and independent of which SQL features NovaDB
  supports). `nextRevision` is a read-modify-write because NovaDB's UPDATE does not evaluate a
  column-referencing expression (this is one of the NovaDB SQL92 gaps tracked in
  `novadb/docs/sql92-compliance.md`).

## Part 5: the test suite, plainly

The gate proves the logic; it does not prove the live integration.

- `gate.sh` = `build.sh` + `run-tests.sh`, offline only: 27 offline test files (~157 `@test` functions) plus
  the webui feature tests. `run-live-tests.sh` is explicitly manual and NOT a merge gate; it spins a fresh
  NovaDB per file on 127.0.0.1:3009 (three live files).
- HA/lease/reconcile are genuinely tested at the logic level, not smoke-tested: `188_leader_lease.nova` and
  `198_ha_cluster.nova` are real property tests (fencing-after-promotion, clock-skew safety, N-node election,
  measured RTO, and a 120-round randomised partition/heal soak asserting no split-brain every round). The
  caveat is they run all nodes over ONE shared in-process `ConfigStore` with a mock clock, so they prove the
  `LeaderLease` algorithm, not the distributed system, and cannot catch the live-CAS hole in Part 1.
- `SqlConfigStore` is tested offline only via a hand-written `FakeConn` (`185_sqlconfig.nova`) that simulates
  the exact SQL strings: it proves the op-to-SQL mapping, parameter order, and revision math, but by
  construction cannot catch a real driver or engine mismatch, and the prepared-statement / transaction methods
  are stubbed.
- Net gate weakness: the tests that would prove the real integration (server-side FENCE EPOCH enforcement,
  durable commit, driver I/O) are exactly the three that are non-gating and manual. Making at least a minimal
  live lease + fencing test part of a CI gate (against a throwaway NovaDB) would close the gap between "the
  logic is proven" and "the running system is proven."

## Part 6: recommended sequencing

1. Make `SqlConfigStore.casBy` atomic (single guarded UPDATE / create that checks `rows_affected` or relies on
   the PRIMARY KEY), and add a gating live test that races two acquirers against a real NovaDB. This is the one
   fix that turns the HA design from "correct on paper" into "correct in production."
2. Wire `membership.quorum()` into `tryAcquire` so a minority partition cannot elect.
3. Give `Supervisor.stopProc` a real timed grace window.
4. Fix the Service VIP bind (host-to-addr resolution on the reactor bind path) or stop advertising per-VIP
   binding until it works.
5. Add per-workload rolling replacement (surge / maxUnavailable) so a spec edit is not a full bounce, and add
   backoff to `probeAndHeal`.
6. Make the isolation downgrade observable (a `/metrics` gauge and a `readyz` note when limits were requested
   but not applied), and make the discovery-file write atomic (temp-file plus rename).
7. Tidy the data-plane lifecycle: bound client concurrency, reap idle backend fds on drain, and add a graceful
   shutdown path.

Everything in Part 3 is real and worth keeping. The work above is what stands between this and being called
production HA rather than a well-built single-store control plane.
