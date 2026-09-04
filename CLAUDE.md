# CLAUDE.md — nova-orchestrator

A container-free, Kubernetes-style orchestration stack written in **Nova**: a control plane that
supervises workloads (native processes, not containers) with rolling updates, readiness gates,
service discovery, autoscaling, and an HA config store hosted by artifactd (no separate database; NovaDB
was removed from the control plane 2026-09-03, see `src/store/httpconfig.nova` + `src/artifacts/cfgstore.nova`).

## Binaries (`bin/`)

- **`orchd`** — the control plane: reconciles a declarative YAML manifest, supervises replicas,
  runs rolling updates + the leader lease (HA), writes the discovery file.
- **`service`** — the data-plane gateway (k8s-Service-style): a stable front address that
  load-balances to replicas. Two modes: normal L7 proxy (parses HTTP, forwards) and the **fd-handoff**
  mode (out-of-path L4 — see below).
- **`orchctl`** — offline CLI (inspect/apply/scale).
- **`artifactd`** — content-addressed artifact daemon (blob store + registry) AND the orchestrator's
  config-store host (`/cfg/*` routes, snapshotted to `<root>/config.snap`).

## Build / run / test

**Unix (macOS / Linux / WSL2):**
```bash
./build.sh --release            # builds bin/*.nova (service/orchd/orchctl/artifactd) into build/release/bin
./run-tests.sh                  # runs every tests/*.nova via `nova test`
```

**Windows (PowerShell):**
```powershell
.\run-tests.ps1                 # PowerShell mirror of run-tests.sh (optional -Filter <substr>)
# building the binaries: `build.sh` is bash, so run it under Git Bash / WSL, or compile a single
# entrypoint directly, e.g.  nova bin/service.nova -o build\release\bin\service.exe --release
```

Both test runners must find **`nova(.exe)` on PATH** and run from a checkout laid out beside the `lang`
toolchain (the resolver finds this package via `../packages`, and the stdlib resolves relative to the
`lang/` CWD, which the scripts `cd` into). `nova` must be a **ReleaseFast** build: a Debug nova's leak
gate exits 1 on every `nova test`, so the suite would report red while printing "0 failed"
(`zig build -Doptimize=ReleaseFast` in `lang/`).

**Windows caveat:** the orchestrator is a Linux production concern. Its POSIX-only surfaces do NOT pass
on Windows: the fd-handoff data plane (AF_UNIX / `SCM_RIGHTS`, see below) and some reactor/isolation
tests (e.g. `183_isolation_sandbox`, `202_live_forwarding`). Use **WSL2** for a full green run; on
Windows `run-tests.ps1` covers the platform-neutral logic tests only.

## End-to-end smoke test on WSL2 (orchestrator + a real web app)

The data plane's fd-handoff (AF_UNIX / `SCM_RIGHTS`) is POSIX-only, so the real end-to-end check runs on
Linux: use **WSL2**, not native Windows. Run everything from a checkout laid out beside the `lang`
toolchain, with a ReleaseFast `nova` on PATH.

**Fastest -- the ready-made loop.** `lang/docs/guide/examples/run-live.sh` builds a NovaDB-backed web app,
starts two replicas (`NOVA_PORT` 8080/8081), puts them behind `service` (the gateway), curls the front
port to show round-robin, and drives `orchctl` over an offline config-store dump:
```bash
( cd ../../lang && zig build -Doptimize=ReleaseFast )   # installs nova to ~/.nova/bin
export PATH="$HOME/.nova/bin:$PATH"
cd ../../lang/docs/guide/examples && ./run-live.sh      # also needs zig (builds the NovaDB server) + curl
```
Green output (a create via :8080, a read-back from NovaDB, three round-robined GETs through :8090) means
the app + data-plane path work.

**Fuller -- orchd supervising a web app from a manifest** (exercises the control plane + config store):
1. Build the orchestrator binaries: `./build.sh --release` → `build/release/bin/{service,orchd,orchctl,artifactd}`.
2. Scaffold + build a web app: `nova init web --name shopweb && ( cd shopweb && nova build --release )`.
   The app honours `--port N` / `NOVA_PORT`, so orchd can run several replicas on one host.
3. Start `artifactd` (config store + blob origin) on :8135:
   `NOVA_ARTIFACT_ROOT=./artifacts NOVA_PORT=8135 build/release/bin/artifactd &`.
4. Write an `orchd.json` (points its `store` at artifactd `127.0.0.1:8135`, a `manifestsDir`, and a
   `discoveryFile`) and a `manifests/shopweb.yaml` (`workload.binary` → the built app, `replicas`,
   `lb.handoff: true`, `network.expose: gateway-only` + `servicePort`, `routes`). The exact field shapes
   are the templates `deploy/linux/install.sh` seeds and the manifest in `examples/manifests/shop.yaml`;
   the full schema is `lang/docs/guide/23-deploying-with-the-orchestrator.md`. Then run
   `build/release/bin/orchd orchd.json &` -- it reconciles the replicas and writes the discovery file.
5. Start `service` reading that discovery file and `curl` the front `servicePort`; requests are served by
   a replica over the fd-handoff path (the socket rendezvous is the short `/tmp/nova-shopweb.sock`).

Config-store state can be inspected offline with `orchctl inspect <dump>` (see the yt walkthrough
`lang/docs/guide/yt/23-deploying-with-the-orchestrator.md`). If any of this misbehaves, that is exactly
the integration the 4 Linux-only `ci.yml` failures point at -- capture the output (add
`NOVA_CRASH_TRACE=1` for the crash in `202_live_forwarding`) so it can be fixed with real evidence.

## Layout

- `src/net/` — `proxy.nova` (LB pool + the fd-handoff serve loop), `service.nova`, `autoscale.nova`,
  `netns.nova`.
- `src/orch/` — `manifest.nova`, `supervisor.nova`, `rollout.nova`, `lease.nova`/`asynclease.nova`
  (HA leader lease), `health.nova`, `spec.nova`, `membership.nova`, `autoscaler.nova`, `isolation.nova`.
- `src/store/` — the config store: `config.nova` (in-memory core + CAS), `wire.nova` (HTTP codec),
  `httpconfig.nova` (async client over artifactd's `/cfg/*`). artifactd hosts it via `src/artifacts/cfgstore.nova`.
- `src/artifacts/` — blob store + registry. `docs/` — design + `platform-readiness.md` (the roadmap).

## The fd-handoff data plane — and the Windows alternative (READ before touching handoff)

**What it is (POSIX).** In handoff mode `service` is a zero-copy L4 gateway. It binds an **AF_UNIX**
rendezvous socket and the front TCP port; each backend `app` connects to the rendezvous as a control
channel. On a new client connection, `service` picks a backend and **passes the client socket
file descriptor to the app** — `os.socket.sendFd(ctrl, clientFd, payload)` (`src/net/proxy.nova`
~L906), which on POSIX sends the fd as `SCM_RIGHTS` ancillary data over the AF_UNIX channel
(`lang/src/lib/std/os/posix/socket.nova`). The app then owns the socket and replies to the client
directly; `service` is out of the data path entirely. The app receives it via
`os.socket.recvFd(ctrl, cap)`.

**Two invariants that look like bugs if broken:**
- The rendezvous path is `/tmp/nova-<name>.sock` and the **short path is DELIBERATE** — AF_UNIX
  `sun_path` caps at ~104 bytes on macOS / ~108 on Linux. Do **NOT** "portably" swap `/tmp` for
  `dir.tempDir()` (`$TMPDIR` → `/var/folders/...`) — it overflows `sun_path` and breaks the macOS bind.
- The path is derived identically in `bin/service.nova`, `src/orch/spec.nova`, and
  `src/orch/manifest.nova` (from the workload name), and `NOVA_HANDOFF_SOCK` overrides it — service and
  apps MUST agree, so keep the derivation in one place if you change it.

**Windows: SCM_RIGHTS does not exist — the handoff needs `WSADuplicateSocket`.**
Today `lang/src/lib/std/os/windows/socket.nova` `sendFd`/`recvFd` are **stubs returning `-1`**: the
handoff compiles on Windows but fails at runtime. Windows has no ancillary-data fd passing (even its
AF_UNIX, Win10 1803+, carries no `SCM_RIGHTS`). The cross-platform equivalent is to duplicate the
socket by value into the target process:

1. **Control channel:** replace the AF_UNIX rendezvous with a **named pipe** (`\\.\pipe\nova-<name>`)
   or loopback TCP — the rendezvous "path" becomes a pipe name, not a filesystem path, so the
   derivation in `spec.nova`/`manifest.nova`/`service.nova` must be **target-conditional** (short
   `/tmp/*.sock` on POSIX, `\\.\pipe\nova-*` on Windows).
2. The app connects and sends its **PID** to `service` up front (WSADuplicateSocket targets a PID).
3. `service` calls `WSADuplicateSocket(clientSock, appPid, &protocolInfo)` → a `WSAPROTOCOL_INFO`
   blob valid only for that PID, then sends that fixed-size blob over the control channel (any channel
   works — the blob, not an fd, is the payload).
4. The app calls `WSASocketW(af, type, proto, &protocolInfo, 0, WSA_FLAG_OVERLAPPED)` to materialise
   **the same underlying socket**, then — for the IOCP reactor — `CreateIoCompletionPort`s it onto its
   own completion port BEFORE the first overlapped op (an unassociated socket delivers completions
   nowhere; see the lang CLAUDE.md IOCP notes). `service` then closes its copy.

**Where to implement:** the `os.socket` seam (`sendFd`/`recvFd`) is the right place, but the Windows
semantics differ from POSIX (you need the target PID before duplicating, and the payload is a blob not
an fd number). So either give the seam a Windows-aware shape (pass PID + return/accept the blob) or add
`dupSocketToPid`/`adoptSocketFromBlob` alongside it, and branch the control-channel + path logic in
`src/net/proxy.nova` on the target OS. Track: `docs/platform-readiness.md` row **C-Iso** ("confirm
fd-handoff on Win/macOS"). macOS already works (BSD `SCM_RIGHTS`); Windows is the open port. Also verify
the POSIX handoff under **io_uring** — a proactor's in-flight ops + inherited socket state differ from
epoll/kqueue.
