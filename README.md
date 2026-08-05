# nova-orchestrator

A native, container-free orchestration stack written in **Nova** — a Kubernetes-style control plane that
runs workloads as **native binaries, not containers**. This is an *application package* built on the Nova
language + runtime; it is **not** part of the language standard library.

It bundles the whole I1–I4 infrastructure tier:

| Module | What it is |
|--------|------------|
| `net.proxy`     | L7 reverse proxy + backend `Pool` with pluggable LB (round-robin / weighted / least-conn / consistent-hash), HAProxy-style per-reactor connection pooling, and active health-checked membership. Share-nothing multi-core (SO_REUSEPORT accept fan-out). |
| `net.autoscale` | A PID controller + a proxy autoscaler that spawns/kills backend processes from a live in-flight metric. |
| `net.service`   | k8s-Service-style virtual endpoints: a stable front address load-balancing to replicas on ephemeral ports, with a name→endpoint registry + discovery file. |
| `orch.spec`       | Workload manifest (`Spec`) + JSON parsing, change detection, restart-policy logic. |
| `orch.supervisor` | Keeps one workload's replica set running: spawn N, restart-on-crash per policy, graceful SIGTERM→SIGKILL. |
| `orch.nativelet`  | The node agent: watches a manifest dir and reconciles desired vs actual; async HTTP health probes. |
| `orch.isolation`  | cgroups-v2 resource limits (cpu/mem/pids) + a CPU-utilisation metric. |
| `orch.autoscaler` | PID-driven replica autoscaling for a workload. |
| `os.sandbox`      | Container-grade isolation dial (levels 0/1/3): Linux namespaces + private rootfs + dropped caps + seccomp. |

## Two binaries: data plane and control plane

The stack ships as **two separate binaries** along the same data-plane / control-plane line Kubernetes
draws between `kube-proxy` and the controller manager. Each entrypoint lives in `bin/` and pulls only its
half of the package through the import graph, so dead-code elimination keeps the two genuinely separate.

| Binary | Plane | Owns | Modules |
|--------|-------|------|---------|
| **`proxyd`** | data | traffic: L7 reverse proxy, load balancing, health-checked membership, service VIPs | `net.proxy`, `net.service`, `net.autoscale` |
| **`orchd`**  | control | desired state: manifest reconcile, replica supervision, restart policy, isolation, leader lease, config store, `/metrics` + alerts | `orch.*`, `store.*`, `os.sandbox` |
| **`orchctl`** | ops | an OFFLINE operator CLI over a config-store backup dump: inspect, edit cluster membership, print a rolling-upgrade plan | `orch.membership`, `orch.backup`, `orch.rollout` |

They share no process and forward nothing to each other directly. The **only** coupling is a
service-discovery file, and it is fully wired:

- `orchd` publishes, every reconcile tick, one `name=host:port` line per replica of each workload it
  manages (`Nativelet.publishDiscovery`). A workload exposes replica endpoints by setting
  `"service": { "basePort": 9000, "portFlag": "--port" }` in its manifest: replica *i* is spawned on
  `basePort + i` (the port passed via `portFlag`) and advertised on `advertiseHost`. A workload with no
  `basePort` advertises its single shared `probe.port` instead.
- `proxyd` resolves **all** endpoints for its `discoveryService` from that file
  (`net.service.resolveAllFrom`) into its backend pool, and its active health checks prune any advertised
  endpoint that is not actually serving yet. So the control plane advertises the desired topology and the
  data plane owns liveness.

Either can run and be restarted independently. End to end: `orchd` writes
`web=127.0.0.1:9000` / `web=127.0.0.1:9001`; a `proxyd` whose config sets `discoveryService: "web"` then
load-balances across both replicas.

Each reads a **validated JSON config** (a missing file falls back to documented defaults; a present file
with a bad value fails loudly at startup, never silently defaults):

```sh
./build.sh                      # builds build/debug/bin/{proxyd,orchd}  (--release for optimised)

proxyd proxyd.json              # serve; or `proxyd` (defaults to ./proxyd.json), or PROXYD_CONFIG=...
proxyd proxyd.json --check      # validate the config and exit 0/1 WITHOUT serving (CI / operator lint)
orchd  orchd.json               # reconcile loop; ORCHD_CONFIG=... ; orchd --check to lint
```

`proxyd.json`:

```json
{
  "listenPort": 8080, "timeoutMs": 15000, "strategy": "roundrobin",
  "health": { "enabled": true, "path": "/healthz", "intervalMs": 2000, "rise": 2, "fall": 3 },
  "backends": [ { "host": "127.0.0.1", "port": 9001, "weight": 1 },
                { "host": "127.0.0.1", "port": 9002, "weight": 2 } ],
  "discoveryFile": "", "discoveryService": ""
}
```

`orchd.json`:

```json
{ "manifestsDir": "manifests", "reconcileMs": 2000, "nodeId": "node-1", "discoveryFile": "" }
```

`strategy` is one of `roundrobin | weighted | leastconn | consistenthash`. `NOVA_PORT` overrides
`proxyd`'s listen port so many proxy replicas can run on one host. When `discoveryFile` +
`discoveryService` are set on `proxyd`, its backend is resolved from that file instead of (or in addition
to) the static `backends` list.

## Requirements

Built against the Nova toolchain (`nova`) and its runtime, which provide the seams this package calls:
`nova_process_spawn` / `_try_wait` / `_pid` / `_spawn_isolated`, `nova_aserver_listen_addr`, the async
socket/timer primitives (`net.aio`), `process`, `io.file`, `io.dir`, `serde.json`, `collections`.

**Linux-only features:** cgroups-v2 limits, cgroup-CPU autoscaling, and `os.sandbox` isolation
(namespaces/rootfs/seccomp) require a Linux host (root / CAP_SYS_ADMIN). On macOS they degrade cleanly to
plain process supervision, so the orchestrator still runs.

## Install

```sh
nova get https://github.com/kamlesh-nb/nova-orchestrator
```

This clones the package into `~/.nova/cache/nova-orchestrator` and locks it in your `project.json`
`dependencies`. `nova get` with no argument restores every locked dependency. Imports then resolve from
the cache — no vendoring:

```nova
import orch.nativelet;   // resolved from the fetched package
import net.proxy;
import os.sandbox;
```

## Usage (programmatic)

The two binaries above are the normal entrypoints. To embed a tier directly, this is exactly what
`bin/orchd.nova` does (`net.aio` is the async runtime module, formerly `net.asyncio`):

```nova
import orch.nativelet;
import net.aio;

fn main(): int {
    aio.holdReactors();
    let n = nativelet.Nativelet("manifests");   // watch dir of *.json workload manifests
    let _ = nativelet.run(n, 2000);             // reconcile every 2s, forever
    return 0;
}
```

A workload manifest (`manifests/web.json`):

```json
{
  "name": "web", "binaryPath": "/opt/app", "args": ["--port", "8080"],
  "restartPolicy": "always", "replicas": 3,
  "cpuMilli": 500, "memMaxBytes": 268435456, "pidsMax": 128,
  "isolationLevel": 1, "rootfs": "/var/lib/nova/rootfs/web",
  "probe": { "port": 8080, "path": "/healthz", "periodMs": 2000 }
}
```

## Tests

```sh
./run-tests.sh          # runs every tests/*.nova via `nova test`
```

Run from a checkout that sits alongside the `lang` toolchain (the resolver finds this package via
`../packages`). Requires `nova` on `PATH`.
