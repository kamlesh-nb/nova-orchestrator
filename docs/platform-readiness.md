# Nova platform readiness: medium-scale production plan

Status: plan (2026-08-13). Companion to `analysis.md` (the what-is-good/what-is-missing audit). This document
turns that audit into a sequenced work list, tied to file-level touch points, and framed around the actual
architecture: single-threaded Nova replicas scaled horizontally, with the orchestrator as the control and data
plane that spreads traffic across them.

## The architecture this plan assumes

Nova is single-threaded on purpose, to avoid synchronisation cost. One reactor core already beats Rust axum
across 1.74 cores and Go across 1.57 on the same box, so per-replica throughput is capped by design and the way
you scale is to run more replicas. That has one consequence that drives the whole priority order:

- **The data plane (proxy / service VIPs) is the availability mechanism, not a side feature.** It is what
  spreads load across replicas and what keeps serving when a replica or the control plane restarts.
- **The control plane (orchd + lease) can restart without taking traffic down.** Existing replicas keep serving
  through the proxy while orchd is away; you only lose the ability to reconcile or scale until it returns.

So workload availability (rolling deploys, readiness-gated load balancing, graceful drain) is mandatory, and
the control plane's own multi-node HA is optional for medium scale. The tiers below follow from that.

## Deployment shape for medium scale

Run **one orchd** (control plane) plus **N `service` data-plane instances** (behind SO_REUSEPORT or a single
front proxy) plus **many workload replicas**, with NovaDB holding both application data and the orchestrator's
desired state. A single orchd means the leader lease is never contended, which removes the split-brain hole
(Tier 2) from the medium-scale critical path entirely. The day one orchd is not enough, Tier 2 makes multi-node
orchd safe.

## Tracking table

Status values: `not started`, `in progress`, `blocked`, `done`, `deferred`. "Master" cross-references the
consolidated plan at `../../../PLATFORM-PLAN.md`.

| ID | Item | Master | Priority | Status |
|----|------|--------|----------|--------|
| T1-1 | Per-workload rolling update (surge/maxUnavailable) | C-T1-1 | P0 | done (`src/orch/nativelet.nova:328-349` Job roll state machine + `src/orch/supervisor.nova` setSpec/rollOne: one replica swapped per grace window, N-1 keep serving) |
| T1-2 | Readiness gate before a replica takes traffic | C-T1-2 | P0 | done (`src/net/proxy.nova:222-230`: under health checks a new backend starts DRAINED and enters rotation only after `hcRise` consecutive OK probes) |
| T1-3 | Real timed graceful drain (drain-from-LB then kill) | C-T1-3 | P0 | done (`src/orch/supervisor.nova:202-220` stopProc: SIGTERM, wall-clock deadline poll, SIGKILL on overrun; LB-remove-first folds into T1-1) |
| T1-4 | Torn-free atomic discovery file write | C-T1-4 | P0 | done (`src/orch/nativelet.nova:35-39` atomicWriteText used at `:159`, and `src/net/service.nova:103-108`: temp file + atomic rename) |
| T1-5 | Data-plane backpressure + lifecycle | C-T1-5 | P1 | not started (F-11: 64 KB ceiling, idle-fd leak, unbounded client coroutines, no graceful shutdown) |
| C-Iso | Validate VETH/netns + cgroups on Linux; confirm fd-handoff on Win/macOS | C-Iso | P1 | in progress (degrade is now REPORTED, not silent: `src/orch/supervisor.nova:71-74` reportIsolationOnce logs "Limits are NOT applied" once and slice check 6 gates it; the LIVE VETH/netns + cgroups validation on a real Linux host, and the Windows fd-handoff port, are still outstanding) |
| T2-1 | Atomic live CAS (split-brain fix) | C-T2-1 | P2 | done (`src/store/sqlconfig.nova:244-250` casBy: a single guarded `UPDATE ... WHERE k=? AND revision=?`, atomic RMW under the table exclusive lock, rows_affected = CAS verdict; create path checks rows_affected at `:236`) |
| T2-2 | Wire quorum gate into tryAcquire | C-T2-2 | P2 | done (`src/orch/asynclease.nova:57-71` hasQuorum wired into tryAcquire: members configured => registered member + store-visible majority; none => single-orchd mode) |
| T2-3 | Promote live fencing test into a gate | C-T2-3 | P2 | partial (logic gated OFFLINE: `tests/198_ha_cluster.nova` fencing + no-split-brain soak; `run-live-tests.sh` NovaDB paths fixed; the live CI gate itself is still outstanding, blocked on a running NovaDB in CI) |
| T3-* | Tier-3 polish (autoscaler metric, escaping, probe, netns bound, VIP bind, config loud-fail, streaming) | POLISH | P3 | mostly done (VIP bind `src/net/proxy.nova:733` bindAddrFor; output escaping `src/orch/health.nova:112` promLabel, `src/orch/backup.nova:12` escapeField, `src/orch/controlplane.nova` htmlEscape; probe parse `src/orch/nativelet.nova:485-503`; netns bound `src/net/netns.nova:54-63`; config loud-fail `src/cfg/config.nova` badString/badNumber/badBool. Still open: autoscaler per-replica metric F-9, probeAndHeal backoff F-8, proxy >64 KB streaming F-11) |

## Tier 1: mandatory (the "pods like k8s" promise)

Without these, the platform cannot do a zero-downtime deploy or keep a new replica from serving 502s. This is
the tier that makes horizontal scaling actually safe.

### T1-1: per-workload rolling update (highest priority)

Today a spec change is a full-workload outage: `reconcileScan` reacts to any change with `job.sup.stopAll()`
then a fresh supervisor `start()` (`src/orch/nativelet.nova:303-310`), so every replica of that workload goes
down together. For a horizontal-scaling platform this is the single most important missing piece.

- Add `maxSurge` / `maxUnavailable` to the spec (`src/orch/spec.nova`, and the manifest schema in
  `src/orch/manifest.nova`), defaulting to a safe rolling policy (surge 1, unavailable 0).
- Change the spec-changed branch in `reconcileScan` to roll replicas in batches: bring up new-spec replicas up
  to `maxSurge`, wait for them to pass readiness (T1-2), then retire old-spec replicas, repeating until the
  whole set is on the new spec. The supervisor already tracks replicas individually
  (`src/orch/supervisor.nova:216-255`), so this is a per-replica state machine on top of it, not a rewrite.
- Keep the current full-replace as the fallback for `maxUnavailable == replicas` (an explicit "recreate"
  strategy), so the old behaviour is still reachable when a user wants it.

### T1-2: readiness gate before a replica takes traffic

A new replica is marked live before it is listening. In the autoscaler, `scaleTo` sets `b.up = 1` immediately
after spawn with no readiness check (`src/net/autoscale.nova:143`), so traffic routes to a not-yet-bound port
until the next health sweep, and if health checks are off the 502s persist. The supervisor path has the same
gap: a freshly spawned replica is countable in `running()` before it can serve.

- A replica must pass at least one readiness probe before the data plane routes to it. Reuse the existing
  probe machinery (`httpProbe` in `src/orch/nativelet.nova:427-440`, and the proxy's active health checks in
  `src/net/proxy.nova:620-679`) rather than adding a second one.
- In `net/autoscale.nova`, do not set `up = 1` on spawn; let the first successful health check flip it (the
  sweep already does rise/fall hysteresis). For workloads without a probe, fall back to a short fixed
  "assume-ready" delay so the behaviour degrades cleanly.
- Surface readiness in the discovery publish (T1-4): only advertise endpoints that are actually ready, so the
  data plane never learns about a replica before it can serve.

### T1-3: real graceful drain

SIGTERM then a microsecond busy-spin then SIGKILL is not a drain. `Supervisor.stopProc`
(`src/orch/supervisor.nova:165-175`) spins `while (tries < 50)` over a non-blocking `tryWait` with no sleep, so
the grace window is effectively zero.

- Give `stopProc` a real timed window: SIGTERM, then poll `tryWait` on a wall-clock deadline (with a sleep
  between polls, using the async timer so it does not block reactor 0), then SIGKILL only if the deadline
  passes. Make the window a spec field (`terminationGraceMs`, default a few seconds).
- Order drain correctly on scale-down and rolling deploy: first remove the replica from the data plane (mark
  `up = 0` and stop advertising it in discovery), let in-flight requests finish within the grace window, then
  SIGTERM. The autoscaler's scale-down already drains-then-kills at the pool level
  (`src/net/autoscale.nova:149`); extend the same ordering to workload replicas.
- Move the autoscaler's blocking `p.wait()` off the reactor (`src/net/autoscale.nova:155`) to the async reap,
  so a slow-to-exit backend cannot stall the reactor-0 health sweep.

### T1-4: torn-free service discovery

The `name=host:port` discovery file is the one coupling between control and data plane, and the write is not
atomic. `ServiceRegistry.flush` (`src/net/service.nova:93-103`) rewrites the whole file via `writeText` on
every register, so a concurrent `resolveAllFrom` reader can see a partial or empty file and drop every backend.

- Write to a temp file then rename over the target (atomic on POSIX), so a reader always sees a complete
  generation. `Nativelet.publishDiscovery` (`src/orch/nativelet.nova:452-459`) and the resolver
  (`src/net/service.nova:108-143`) are the two ends to keep in step.
- While here, only publish ready endpoints (pairs with T1-2), so the data plane's view is desired-and-ready,
  not desired-only.

### T1-5: data-plane backpressure and lifecycle

At medium scale the proxy is the hot path and currently has no ceiling. `proxyAcceptLoop` does
`coroStart(handleClient(...))` per accept with no cap (`src/net/proxy.nova:714`), each client allocates a 64 KB
buffer, and every accept/health loop is `while(true)` with no cancellation.

- Bound in-flight client coroutines (a simple per-reactor counter that stops accepting, or a semaphore), so a
  connection flood cannot grow memory without limit.
- Reap idle backend fds on drain: when a slot goes `up = 0`, close its pooled idle fds
  (`b.idle[tid]`, `src/net/proxy.nova:534`) instead of leaving them to accumulate; add a simple idle-timeout
  reaper.
- Add a graceful shutdown path (a cancellation flag the accept and health loops check) so a `service` instance
  can drain and exit cleanly for a rolling data-plane upgrade.

## Tier 2: multi-node control-plane HA (only when one orchd is not enough)

Defer this for medium scale by running a single orchd. Do not ship the lease as if it were safe while the CAS
races; either fix it or document single-orchd. When you do want orchd HA:

### T2-1: make the live CAS atomic (the split-brain fix)

`SqlConfigStore.casBy` (`src/store/sqlconfig.nova:167-205`) is a read-then-write across two awaits, so two
nodes racing a free lease can both win. This is the one defect that makes the fencing design correct on paper
but unsafe in production.

- Create path: check `rows_affected` on the INSERT (or rely on the PRIMARY KEY conflict on `k`) instead of
  discarding the result and returning `rev` unconditionally.
- Update path: replace the SELECT-then-UPDATE with a single guarded statement
  (`UPDATE config SET ... WHERE k = ? AND revision = ?`) and read `rows_affected` to decide success, or wrap
  the read-modify-write in a real transaction using the `Connection` trait's `begin`/`commit`/`rollback` (which
  the store currently never calls). This depends on NovaDB honouring a guarded UPDATE, which ties into the
  relational-engine work in `novadb/docs/sql92-compliance.md`.
- Add a gating live test that races two `AsyncLeaderLease.tryAcquire` calls against a real NovaDB and asserts
  exactly one wins. The current HA property tests (`tests/198_ha_cluster.nova`) run over one shared in-memory
  store with a mock clock, so by construction they cannot catch this.

### T2-2: wire the quorum gate

`membership.quorum()` (`src/orch/membership.nova:49-52`) is documented as the guard that stops a minority
partition electing, but neither lease calls it (only `bin/orchctl.nova:66` does, for a status printout). Call
it from `tryAcquire` (`src/orch/lease.nova:90`, `src/orch/asynclease.nova:37`) so a node that cannot see a
quorum of members does not attempt to become leader.

### T2-3: promote the live integration tests into a gate

The tests that prove real behaviour (server-side FENCE EPOCH enforcement, durable commit, driver I/O) are
exactly the three non-gating manual ones (`tests/live/`). Add a CI job that spins a throwaway NovaDB and runs a
minimal live lease + fencing test, so "the logic is proven" becomes "the running system is proven."

## Tier 3: operability hardening (not blocking, do continuously)

None of these block medium-scale use; they reduce operational surprise.

- **Isolation-downgrade observability.** `isolation.applyLimits` (`src/orch/isolation.nova:31-49`) ignores every
  write result, so an unprivileged or non-Linux host runs workloads unlimited with no signal. Emit a
  `/metrics` gauge and a `readyz` note when limits were requested but not applied.
- **Autoscaler metric.** `tickCpu` (`src/orch/autoscaler.nova:62-74`) feeds aggregate cgroup CPU into a PID
  with a per-workload setpoint; divide by replica count so the controller regulates per-replica saturation and
  actually converges. Consider per-replica cgroups rather than one shared budget
  (`src/orch/isolation.nova:36-48`).
- **Config loud-fail.** The load path (`src/cfg/config.nova:98-128, 251-269`) uses `?? default` on every field,
  so a present-but-wrong-type value silently defaults. Distinguish "absent" (default) from "present but
  malformed" (fail loudly), to match the README promise.
- **Output escaping.** `renderMetrics` / `appsTable` (`src/orch/health.nova:113`,
  `src/orch/controlplane.nova:120`) do not escape names, so a name with a quote breaks Prometheus exposition or
  the HTML. `backup.dump/restore` (`src/orch/backup.nova`) assumes tab/newline-free values; add escaping.
- **Probe robustness.** `httpProbe` (`src/orch/nativelet.nova:427-440`) reads the status byte at fixed offset 9
  assuming exactly `"HTTP/1.1 "`; parse the status line properly so an `HTTP/1.0` reply is not misread. Add
  backoff to `probeAndHeal` (`src/orch/nativelet.nova:412-416`) so a persistently failing probe does not become
  a tight restart loop.
- **Proxy streaming ceiling.** `readMessage` (`src/net/proxy.nova:427`) truncates response bodies over 64 KB;
  stream large bodies rather than buffering the whole message.
- **Service VIP bind.** `proxyAcceptLoop` binds `INADDR_ANY` and discards the `host` argument
  (`src/net/proxy.nova:684-701`) while `serveAddr` advertises per-VIP binding. At medium scale you front
  services by port behind one proxy, so this is deferrable, but either finish the per-VIP bind (host-to-addr
  resolution on the reactor bind path) or stop advertising it until it works.

## Sequencing summary

1. Tier 1 in order (T1-1 rolling update, T1-2 readiness gate, T1-3 graceful drain, T1-4 atomic discovery,
   T1-5 data-plane backpressure). This is what makes a zero-downtime deploy and health-gated scaling real.
2. Ship medium scale with a single orchd; document that orchd is single-instance for now.
3. Tier 2 when multi-node orchd is needed (T2-1 atomic CAS is the crux, then T2-2 quorum, then T2-3 the live
   gate).
4. Tier 3 continuously, as operability polish.

The parts already called production-quality in `analysis.md` (the reconcile loop, the supervisor, the
fencing-epoch design, the data-plane LB and health checks, observability, the webui) stay as they are. This
plan only adds what turns "a well-built single-store control plane" into "a platform you can run a fleet of
Nova replicas on at medium scale."
