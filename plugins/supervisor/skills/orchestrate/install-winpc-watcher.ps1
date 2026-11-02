<#
.SYNOPSIS
Installs (or with -Uninstall removes) the winpc availability watcher for the current user.

.DESCRIPTION
Run in your own Windows account (not the claude user's), from a normal, unelevated PowerShell
(not "Run as administrator": an elevated token makes the folder below owned by Administrators and
the installer refuses to run), from the folder that holds
winpc-watcher.ps1, in Windows PowerShell:

  powershell -ExecutionPolicy Bypass -File .\install-winpc-watcher.ps1 -ClaudeUser claude

It:
  1. runs the watcher's -SelfTest and stops if it fails;
  2. copies winpc-watcher.ps1 to %LOCALAPPDATA%\winpc;
  3. creates -StatusDir (you own it) and replaces its inherited ACL with: you, SYSTEM and
     Administrators full control, -ClaudeUser read only; then deletes whatever is in it. The
     ACL inherited from C:\ProgramData would let every user, claude included, create files
     there, so code running as claude could plant a fresh "state=idle" status.txt. If the
     folder exists but isn't yours, it stops: delete the folder as admin and rerun;
  4. registers the scheduled task "winpc watcher": at your logon, as you, unelevated, hidden,
     no time limit, one instance (the watcher catches its own errors; Task Scheduler's restart
     setting is only a backup, since it doesn't fire on a script's nonzero exit);
  5. starts the task and prints the status file once it is written.

No admin rights are needed, and it refuses to run elevated. Rerunning it updates the installed copy and the task. Then check
from the Mac with `winpc status`, and as the claude user check that it can't create a file in
the folder (the watcher's manual check list, item 11).

What the watcher detects, why it reads Windows GPU counters rather than nvidia-smi (under WDDM
nvidia-smi has no per-process utilization), and its known limitations: see the header of
winpc-watcher.ps1.

.PARAMETER ClaudeUser
The Windows account winpc logs in as (D5); it gets read access to the status folder.

.PARAMETER IntervalSeconds
Seconds between the watcher's checks (winpc treats the file as stale after 3 x this + 30 s).

.PARAMETER StatusDir
Folder for status.txt; must match `status_file` in the Mac's ~/.config/winpc.conf.

.PARAMETER Uninstall
Unregister the task, delete the installed copy and the status file (grants then refuse).
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Install')][string]$ClaudeUser,
    [Parameter(ParameterSetName = 'Install')][ValidateRange(2, 3600)][int]$IntervalSeconds = 15,
    [string]$StatusDir = 'C:\ProgramData\winpc',
    [Parameter(Mandatory = $true, ParameterSetName = 'Uninstall')][switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$taskName = 'winpc watcher'
$installDir = Join-Path $env:LOCALAPPDATA 'winpc'
$installed = Join-Path $installDir 'winpc-watcher.ps1'
$statusFile = Join-Path $StatusDir 'status.txt'
$me = "$env:USERDOMAIN\$env:USERNAME"

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "removed task '$taskName'"
    }
    if (Test-Path $installDir) { Remove-Item -Recurse -Force $installDir; Write-Host "removed $installDir" }
    if (Test-Path $statusFile) { Remove-Item -Force $statusFile; Write-Host "removed $statusFile" }
    exit 0
}

$source = Join-Path $PSScriptRoot 'winpc-watcher.ps1'
if (-not (Test-Path $source)) { throw "winpc-watcher.ps1 not found next to the installer ($PSScriptRoot)" }

# 0. An elevated token would create the status folder owned by Administrators, not by this user.
if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'this PowerShell is elevated; close it and rerun the installer from a normal, unelevated PowerShell (no "Run as administrator")'
}

# 1. Self-test, in a separate process so its exit code is the verdict.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $source -SelfTest | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'watcher self-test failed; nothing installed' }

# 2. Installed copy, so the task doesn't depend on where this checkout lives.
if (-not (Test-Path $installDir)) { [void](New-Item -ItemType Directory -Path $installDir) }
Copy-Item -Force $source $installed
Write-Host "installed $installed"

# 3. Status folder only this user (and SYSTEM, Administrators) can write and the claude user can
#    read. ProgramData lets users create folders they then own, and an owner may set the ACL, so
#    this needs no elevation.
$mySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not (Test-Path $StatusDir)) { [void](New-Item -ItemType Directory -Path $StatusDir) }
$ownerSid = (Get-Acl $StatusDir).GetOwner([Security.Principal.SecurityIdentifier]).Value
if ($ownerSid -ne $mySid) {
    throw "$StatusDir exists but is owned by $((Get-Acl $StatusDir).Owner), not you; delete it in an admin prompt (rmdir /s /q `"$StatusDir`") and rerun"
}
& icacls.exe $StatusDir /inheritance:r /grant:r "*${mySid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "${ClaudeUser}:(OI)(CI)RX" | Out-Host
if ($LASTEXITCODE -ne 0) { throw "icacls failed on $StatusDir (is '$ClaudeUser' an account on this PC?)" }
# anything already there may have been planted before the ACL was tightened
Get-ChildItem -Path $StatusDir -Force | Remove-Item -Recurse -Force

# 4. Logon task in this account, unelevated and hidden.
$arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installed`"" +
             " -StatusDir `"$StatusDir`" -IntervalSeconds $IntervalSeconds"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
[void](Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Writes whether the PC is in use for winpc (claude-skills).')
Write-Host "registered task '$taskName' for $me"

# 5. Start it now and show the first status.
$before = $null
if (Test-Path $statusFile) { $before = (Get-Item $statusFile).LastWriteTimeUtc }
Start-ScheduledTask -TaskName $taskName
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    if ((Test-Path $statusFile) -and (Get-Item $statusFile).LastWriteTimeUtc -ne $before) { break }
    Start-Sleep -Seconds 1
}
if ((Test-Path $statusFile) -and (Get-Item $statusFile).LastWriteTimeUtc -ne $before) {
    Write-Host "`n${statusFile}:"
    Get-Content $statusFile | Out-Host
    Write-Host "`ndone; check from the Mac with: winpc status"
} else {
    Write-Warning "the task started but $statusFile wasn't written within 30 s; see Task Scheduler > '$taskName' > History, or run: powershell -File `"$installed`" -Once"
    exit 1
}
