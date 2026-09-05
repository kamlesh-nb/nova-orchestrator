<#
.SYNOPSIS  Remove the Kyte orchestrator services / scheduled tasks installed by install-services.ps1.
.PARAMETER Nssm   Path to nssm.exe (if the services were installed with NSSM and it is not on PATH).
.PARAMETER Purge  Also delete the config + data directories.
#>
[CmdletBinding()]
param(
  [string]$Nssm,
  [string]$ConfDir = "C:\ProgramData\nova-orchestrator\config",
  [string]$DataDir = "C:\ProgramData\nova-orchestrator\data",
  [string]$BinDir  = "C:\Program Files\nova-orchestrator\bin",
  [switch]$Purge
)
$ErrorActionPreference = "Stop"
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
  throw "Run this in an elevated PowerShell (Administrator)."
}
if (-not $Nssm) { $c = Get-Command nssm.exe -ErrorAction SilentlyContinue; if ($c) { $Nssm = $c.Source } }

foreach ($name in "kyte-service","kyte-orchd","kyte-artifactd") {
  # Try NSSM service first, then Scheduled Task -- either may exist.
  $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
  if ($svc) {
    if ($Nssm) { & $Nssm stop $name 2>$null | Out-Null; & $Nssm remove $name confirm 2>$null | Out-Null }
    else       { sc.exe stop $name | Out-Null; sc.exe delete $name | Out-Null }
    Write-Host "removed service $name"
  }
  if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Write-Host "removed scheduled task $name"
  }
}
Remove-Item -Recurse -Force $BinDir -ErrorAction SilentlyContinue
if ($Purge) {
  Remove-Item -Recurse -Force $ConfDir, $DataDir -ErrorAction SilentlyContinue
  Write-Host "purged config + data"
} else {
  Write-Host "left config ($ConfDir) + data ($DataDir); pass -Purge to remove them"
}
Write-Host "Done."
