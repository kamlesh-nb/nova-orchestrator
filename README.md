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

## Requirements

Built against the Nova toolchain (`nova`) and its runtime, which provide the seams this package calls:
`nova_process_spawn` / `_try_wait` / `_pid` / `_spawn_isolated`, `nova_aserver_listen_addr`, the async
socket/timer primitives (`net.asyncio`), `process`, `io.file`, `io.dir`, `serde.json`, `collections`.

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

## Usage

```nova
import orch.nativelet;
import net.asyncio;

fn main(): int {
    asyncio.holdReactors();
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
