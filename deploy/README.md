# Running the Kyte orchestrator as system services

These scripts install the three long-running orchestrator daemons so they start on boot and restart on
failure. `kynatorctl` is an offline CLI, not a service, so it is copied alongside but not registered.

| Daemon | Role | Default port |
|--------|------|--------------|
| `artifactd` | content-addressed blob store + the orchestrator config store (`/cfg/*`, `config.snap`) | 8135 |
| `kynatord` | control plane: reconcile, supervise replicas, HA lease, service discovery | (no listen port; writes a discovery file) |
| `service` | data-plane gateway: L7 proxy / load balancer, fd-handoff | 8090 |

Build the binaries first (from the repository root):

```bash
./build.sh --release                       # native, current host
./build.sh --release --target windows-arm64  # or cross-compile for another target
```

## Linux (systemd)

```bash
sudo deploy/linux/install.sh --from build/release/bin --enable --start
# manage:
sudo systemctl status kyte-artifactd kyte-kynatord kyte-service
sudo systemctl restart kyte-kynatord
sudo deploy/linux/uninstall.sh            # add --purge to also delete config + data
```

Binaries go to `/opt/nova-orchestrator/bin`, config to `/etc/nova-orchestrator`, data to
`/var/lib/nova-orchestrator` (override with `BIN_DIR` / `CONF_DIR` / `DATA_DIR`). `artifactd` and
`service` run as an unprivileged `kyte` user; `kynatord` runs as root because it supervises processes and
applies cgroup / network-namespace isolation. Put the deploy token in `/etc/nova-orchestrator/artifactd.env`.

## macOS (launchd)

```bash
sudo deploy/macos/install.sh --from build/release/bin --load
# manage:
sudo launchctl print system/com.kyte.kynatord
sudo launchctl bootout system /Library/LaunchDaemons/com.kyte.kynatord.plist   # stop
sudo deploy/macos/uninstall.sh            # add --purge to also delete config/data/logs
```

Defaults live under `/usr/local/...` (override with `BIN_DIR` / `CONF_DIR` / `DATA_DIR` / `LOG_DIR`).
Daemons run as root (the default for `LaunchDaemons`).

## Windows (PowerShell, elevated)

A console program cannot be a native Windows service on its own (it would have to answer the Service
Control Manager handshake), so the installer uses one of two shims:

- **NSSM** (recommended, gives real services): install [nssm](https://nssm.cc/) so `nssm.exe` is on PATH.
- **Scheduled Tasks** (no extra software): tasks that run at startup as `SYSTEM`.

```powershell
# from an elevated PowerShell, after building for windows-x86_64 / windows-arm64:
./deploy/windows/install-services.ps1 -From build/release/windows-arm64/bin -Start
# force a method:
./deploy/windows/install-services.ps1 -Method ScheduledTask -Start
./deploy/windows/uninstall-services.ps1        # add -Purge to also delete config + data
```

The installer defaults to NSSM if `nssm.exe` is found, else Scheduled Tasks. Binaries go to
`C:\Program Files\nova-orchestrator\bin`, config + data under `C:\ProgramData\nova-orchestrator`.

**Windows caveat:** the fd-handoff data plane (`service` / `kynatord`) is POSIX-only by design (it uses
`SCM_RIGHTS`; the Windows socket-passing path is stubbed), so those two are best-effort on Windows.
`artifactd` (HTTP blob + config store) and `kynatorctl` (CLI) are fully functional. See `../CLAUDE.md`.

## Notes

- The installers seed `kynatord.json` / `service.json` templates only if absent; they never overwrite yours.
  Edit the config, then restart the daemon.
- `service.json` ships with an empty `backends` list; either fill it in, or run `kynatord` with a discovery
  file so `service` load-balances across the replicas kynatord currently has healthy.
- Set `KYTE_ARTIFACT_TOKEN` (the deploy bearer token) for any non-dev deployment; empty means auth is off.
