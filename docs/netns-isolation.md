# Network isolation for gateway-only apps

A manifest with `network.expose: gateway-only` means an app must be reachable **only through the
gateway**, never on the host's real interfaces. The intent is one thing; the implementation is chosen
per platform, the same way the reactor backend is chosen per OS:

| Platform | Mechanism | How the app is unreachable directly |
|----------|-----------|-------------------------------------|
| macOS / Windows | **fd-handoff** | The app has **no listening TCP port**. The gateway accepts the client and passes the socket (`SCM_RIGHTS`); the app only ever gets sockets the gateway hands it. |
| Linux (root + `ip`) | **netns + veth** | The app runs in its **own network namespace** behind a veth pair, with a private `/30` address the gateway forwards to. It is not on any host interface. |
| Linux (no root/`ip`) | **loopback** | Best-effort fallback: bind loopback only. |
| any (`expose: public`) | **host port** | The app binds `network.portBase` directly (dev convenience, not production). |

`manifest.isolationMode(m)` returns which of these applies on the current host.

## The Linux netns + veth path (`net/netns`)

Each gateway-only app at replica slot `idx` gets a private point-to-point link:

- namespace `nova-<app>`, veth pair `nvh<idx>` (host) ↔ `nva<idx>` (in the namespace)
- host side `10.66.<idx>.1/30`, app side `10.66.<idx>.2/30`
- a default route in the namespace via the host end, so the app can still reach shared services
  (e.g. NovaDB) through the host.

The recipe (`netns.setupCommands`), driven through iproute2:

```
ip netns add nova-<app>
ip link add nvh<idx> type veth peer name nva<idx>
ip link set nva<idx> netns nova-<app>
ip addr add 10.66.<idx>.1/30 dev nvh<idx>   ;  ip link set nvh<idx> up
ip -n nova-<app> addr add 10.66.<idx>.2/30 dev nva<idx>
ip -n nova-<app> link set nva<idx> up       ;  ip -n nova-<app> link set lo up
ip -n nova-<app> route add default via 10.66.<idx>.1
```

The app is launched inside the namespace with `ip netns exec nova-<app> <binary> …`
(`netns.wrapExec`), so it binds its port on the private address `10.66.<idx>.2`. The gateway forwards
there; nothing else can reach it.

`net/netns` is Linux-only. On macOS/Windows `available()` is false and `setup()` is a no-op — the caller
falls back to fd-handoff. iproute2 is used for this first cut; a pure-Nova netlink path is a later,
self-hosted step.

## Status

- Module + the full command recipe, addressing plan, exec wrapping, and platform gating are implemented
  and unit-tested (`tests/185_netns.nova`) on any OS.
- **Live kernel setup is verified only on Linux** (needs `ip` + `CAP_NET_ADMIN`). `examples/netns-demo.sh`
  brings up a namespace + veth and curls a server through the host end — run it on Linux/WSL.

## Still to wire (follow-on, Linux-verified)

- Supervisor spawns a gateway-only app through `netns.wrapExec` (currently spawns directly).
- The gateway forwards to the app's `netns` address instead of `127.0.0.1`.
- Per-app slot allocation for the `/30` blocks, and outbound NAT (`ip_forward` + masquerade) if apps
  need to reach the internet rather than just host services.
