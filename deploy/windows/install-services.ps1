<#
.SYNOPSIS
  Install the Nova orchestrator daemons (artifactd, orchd, service) so they run at boot on Windows.

.DESCRIPTION
  The daemons are console programs, which Windows cannot run as native services directly (a service must
  answer the Service Control Manager handshake). Two supported methods:

    -Method Nssm           Register real Windows services via NSSM (the Non-Sucking Service Manager),
                           which is the standard shim for console apps. Requires nssm.exe on PATH or
                           passed with -Nssm <path>. Gives you `sc` / services.msc management + restart.
    -Method ScheduledTask  Register Scheduled Tasks that run at startup as SYSTEM (no extra software).
                           Works out of the box; manage with schtasks / Task Scheduler.

  Default: Nssm if nssm.exe is found, else ScheduledTask.

  NOTE: on Windows the fd-handoff data plane (service / orchd) is POSIX-only by design and its socket
  passing is stubbed, so those two are best-effort here. artifactd (blob + config store, HTTP) and
  orchctl (CLI) are fully functional. See the orchestrator CLAUDE.md.

.PARAMETER From      Directory containing service.exe / orchd.exe / orchctl.exe / artifactd.exe.
.PARAMETER BinDir    Install location for the binaries.       Default C:\Program Files\nova-orchestrator\bin
.PARAMETER ConfDir   Config directory (orchd.json/service.json). Default C:\ProgramData\nova-orchestrator\config
.PARAMETER DataDir   Data directory (artifacts, config.snap).  Default C:\ProgramData\nova-orchestrator\data
.PARAMETER Method    Nssm | ScheduledTask
.PARAMETER Nssm      Path to nssm.exe (if not on PATH).
.PARAMETER Start     Start the services/tasks after installing.
#>
[CmdletBinding()]
param(
  [string]$From    = (Join-Path $PSScriptRoot "..\..\build\release\windows-arm64\bin"),
  [string]$BinDir  = "C:\Program Files\nova-orchestrator\bin",
  [string]$ConfDir = "C:\ProgramData\nova-orchestrator\config",
  [string]$DataDir = "C:\ProgramData\nova-orchestrator\data",
  [ValidateSet("Nssm","ScheduledTask")] [string]$Method,
  [string]$Nssm,
  [switch]$Start
)
$ErrorActionPreference = "Stop"

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Run this in an elevated PowerShell (Administrator)."
  }
}
Assert-Admin

# Resolve nssm + method.
if (-not $Nssm) { $c = Get-Command nssm.exe -ErrorAction SilentlyContinue; if ($c) { $Nssm = $c.Source } }
if (-not $Method) { $Method = if ($Nssm) { "Nssm" } else { "ScheduledTask" } }
Write-Host "Method: $Method$(if($Method -eq 'Nssm'){" (nssm=$Nssm)"})"

# Lay down binaries + config.
New-Item -ItemType Directory -Force -Path $BinDir, $ConfDir, (Join-Path $DataDir "artifacts"), (Join-Path $DataDir "manifests") | Out-Null
$From = (Resolve-Path $From).Path
foreach ($b in "service","orchd","orchctl","artifactd") {
  $src = Join-Path $From "$b.exe"
  if (-not (Test-Path $src)) { throw "missing $src (build with `./build.sh --release --target windows-arm64` first)" }
  Copy-Item -Force $src (Join-Path $BinDir "$b.exe")
}
$orchdCfg   = Join-Path $ConfDir "orchd.json"
$serviceCfg = Join-Path $ConfDir "service.json"
if (-not (Test-Path $orchdCfg)) {
  @"
{
  "manifestsDir": "$($DataDir -replace '\\','/')/manifests",
  "reconcileMs": 2000,
  "nodeId": "node-1",
  "discoveryFile": "$($DataDir -replace '\\','/')/discovery.txt",
  "metricsFile": "$($DataDir -replace '\\','/')/metrics.prom",
  "store": { "enabled": true, "addr": "127.0.0.1:8135", "token": "", "tls": false }
}
"@ | Set-Content -Path $orchdCfg -Encoding UTF8
}
if (-not (Test-Path $serviceCfg)) {
  @"
{
  "listenHost": "0.0.0.0", "listenPort": 8090, "strategy": "roundrobin",
  "health": { "enabled": true, "path": "/healthz", "intervalMs": 2000, "timeoutMs": 1000, "rise": 2, "fall": 3 },
  "backends": []
}
"@ | Set-Content -Path $serviceCfg -Encoding UTF8
}

# Per-daemon definition: name, exe, args, environment.
$artRoot = (Join-Path $DataDir "artifacts")
$daemons = @(
  @{ Name="nova-artifactd"; Exe=(Join-Path $BinDir "artifactd.exe"); Args=@();            Env=@{ NOVA_ARTIFACT_ROOT=$artRoot; NOVA_PORT="8135"; NOVA_ARTIFACT_TOKEN="" } },
  @{ Name="nova-orchd";     Exe=(Join-Path $BinDir "orchd.exe");     Args=@($orchdCfg);   Env=@{} },
  @{ Name="nova-service";   Exe=(Join-Path $BinDir "service.exe");   Args=@($serviceCfg); Env=@{} }
)

function Install-Nssm($d) {
  & $Nssm install $d.Name $d.Exe @($d.Args) | Out-Null
  & $Nssm set $d.Name Start SERVICE_AUTO_START | Out-Null
  & $Nssm set $d.Name AppDirectory $DataDir | Out-Null
  & $Nssm set $d.Name AppStdout (Join-Path $DataDir "$($d.Name).log") | Out-Null
  & $Nssm set $d.Name AppStderr (Join-Path $DataDir "$($d.Name).log") | Out-Null
  if ($d.Env.Count -gt 0) {
    $pairs = $d.Env.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
    & $Nssm set $d.Name AppEnvironmentExtra @pairs | Out-Null
  }
  if ($Start) { & $Nssm start $d.Name | Out-Null }
}

function Install-ScheduledTask($d) {
  # Wrap in a cmd that sets env then execs the daemon, so a Scheduled Task can carry per-daemon env.
  $envPrefix = ($d.Env.GetEnumerator() | ForEach-Object { "set `"$($_.Key)=$($_.Value)`"& " }) -join ""
  $argLine = ($d.Args | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $cmd = "$envPrefix`"$($d.Exe)`" $argLine"
  $action    = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c $cmd"
  $trigger   = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $d.Name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  if ($Start) { Start-ScheduledTask -TaskName $d.Name }
}

foreach ($d in $daemons) {
  Write-Host "==> installing $($d.Name)"
  if ($Method -eq "Nssm") { Install-Nssm $d } else { Install-ScheduledTask $d }
}

Write-Host ""
if ($Method -eq "Nssm") {
  Write-Host "Installed as Windows services. Manage with: sc.exe {start|stop|query} nova-artifactd (or services.msc)."
} else {
  Write-Host "Installed as Scheduled Tasks (run at startup as SYSTEM). Manage with: schtasks /Query /TN nova-orchd, or Task Scheduler."
}
Write-Host "Binaries: $BinDir   Config: $ConfDir   Data: $DataDir"
Write-Host "Put the artifactd deploy token in the service/task env (NOVA_ARTIFACT_TOKEN) for production."
