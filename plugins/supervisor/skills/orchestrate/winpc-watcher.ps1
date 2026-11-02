<#
.SYNOPSIS
winpc availability watcher: writes whether the user is using the PC (busy) or not (idle) to a
status file that winpc reads before it grants a run.

.DESCRIPTION
Runs in the user's own Windows account as a logon scheduled task (install-winpc-watcher.ps1
registers it), unprivileged, with no account links or API keys. Every -IntervalSeconds it
checks, and reports busy when any of these holds:

  steam       HKCU:\Software\Valve\Steam RunningAppID is nonzero (a Steam game is running).
  epic        a process runs from an Epic Games install folder (InstallLocation in
              C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests\*.item).
  gog         a process runs from a GOG game folder (HKLM GOG.com\Games\* "path").
  fullscreen  the foreground window covers its whole monitor (games, fullscreen video); the
              desktop, taskbar and lock screen don't count.
  gpu         a process of this user holds at least -GpuBusyPercent of a GPU engine
              (\GPU Engine(*)\Utilization Percentage). Only this user's processes count, so
              the claude user's runs never make the PC look busy. These Windows counters are
              used instead of nvidia-smi because under WDDM (the normal Windows driver mode
              for a GeForce card) nvidia-smi reports no per-process utilization, only memory,
              so it can't tell the user's game from the claude user's run.

A detector that fails (missing permissions, Add-Type blocked, counters unavailable) fails
closed: unless another detector already says busy, the state is unknown, which winpc refuses
like a stale file, and the reason names it ("error: <detector>: <message>") so `winpc status`
shows what to fix.

Known limitations:
  - Elevated (run-as-admin) processes: their paths and owners aren't readable unelevated, so
    an elevated game is caught only by Steam's flag or the fullscreen check, not by its
    install folder or its GPU use.
  - The GPU counters' names are English; on a Windows set to another display language the
    gpu detector fails, and the state stays unknown until that's fixed.
  - The watcher runs only while the user is logged in; after logout the file goes stale and
    winpc refuses grants.
  - Unknown (or stale) mid-run doesn't stop a run already going; only busy does.

The status file (UTF-8 without BOM, written atomically, LF line endings) is what winpc parses:

  state=idle|busy|unknown
  reason=<detectors that fired, "; "-separated, then errors; "none" when idle>
  updated=<ISO 8601 local time with offset>
  epoch=<Unix seconds>
  interval=<IntervalSeconds>

winpc treats a file older than 3 x interval + 30 s as stale (unknown), so stopping the watcher
or logging out refuses grants rather than granting them.

.PARAMETER StatusDir
Folder for status.txt; the claude user needs read access (the installer sets it).

.PARAMETER IntervalSeconds
Seconds between checks.

.PARAMETER GpuBusyPercent
GPU engine utilization (percent) at which one of this user's processes makes the PC busy.

.PARAMETER GpuCounter
The performance counter path the gpu detector samples (override only for the manual check of a
failing detector).

.PARAMETER Once
Check once, write the file, print it and exit (for manual checks).

.PARAMETER SelfTest
Run the pure-function tests (no system access) and exit 0 when all pass, 1 otherwise.

.NOTES
Windows PowerShell 5.1 syntax (the version every Windows 10/11 has). There is no Pester suite
since nothing on the Mac runs PowerShell; -SelfTest covers the pure logic, and this list covers
the detectors on the PC (run by the user in U7, or by P1):

  1. .\winpc-watcher.ps1 -SelfTest                     -> "all passed", exit code 0.
  2. Nothing open: .\winpc-watcher.ps1 -Once           -> state=idle, reason=none, with no
                                                          "error:" in the reason. Do this first
                                                          on the real PC: a detector that throws
                                                          there (the watcher fails closed) would
                                                          leave the PC permanently unknown.
  3. Start a Steam game; -Once                         -> busy, reason has "steam: app <id>".
  4. Start an Epic game (and a GOG game if installed)  -> busy, "epic: <exe>" / "gog: <exe>".
  5. Play a video fullscreen in a browser; -Once       -> busy, "fullscreen: <process>".
  6. With a GPU-heavy app windowed (e.g. a benchmark)  -> busy, "gpu: <process> <n>%".
  7. As the claude user, run a GPU test over winpc while idle -> stays idle (not "gpu").
  8. After install: winpc status on the Mac            -> watcher idle, age under the interval.
  9. Stop the scheduled task; wait 3 x interval + 30 s; winpc status -> stale, grants refused.
 10. A failing detector: run -Once with -GpuCounter '\No Such(*)\Counter'
                                                       -> state=unknown, reason has
                                                          "error: gpu: ..."; with the task
                                                          running so, winpc status -> unknown.
 11. As the claude user (ssh in): create a file in the status folder, e.g.
     cmd /c "echo x > C:\ProgramData\winpc\x.txt"   -> Access is denied; `type` of
                                                          status.txt works.
#>
[CmdletBinding()]
param(
    [string]$StatusDir = 'C:\ProgramData\winpc',
    [ValidateRange(2, 3600)][int]$IntervalSeconds = 15,
    [ValidateRange(1, 100)][int]$GpuBusyPercent = 50,
    [string]$GpuCounter = '\GPU Engine(*)\Utilization Percentage',
    [switch]$Once,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- pure functions (self-tested)

function Test-PathUnderFolder {
    # True when $Path is inside one of $Folders (case-insensitive, whole path components).
    param([string]$Path, [string[]]$Folders)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $p = $Path.Replace('/', '\').ToLowerInvariant()
    foreach ($f in $Folders) {
        if ([string]::IsNullOrEmpty($f)) { continue }
        $d = $f.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
        if ($d.Length -lt 3) { continue }   # never treat a drive root as a game folder
        if ($p.StartsWith($d + '\')) { return $true }
    }
    return $false
}

function Get-EpicInstallLocations {
    # InstallLocation of each Epic manifest (*.item JSON text); unparsable ones are skipped.
    param([string[]]$ManifestTexts)
    $out = @()
    foreach ($t in $ManifestTexts) {
        try { $j = $t | ConvertFrom-Json } catch { continue }
        if ($null -ne $j -and $j.PSObject.Properties['InstallLocation'] -and $j.InstallLocation) {
            $out += [string]$j.InstallLocation
        }
    }
    return , $out
}

function Test-RectCoversMonitor {
    # True when a window rectangle covers the monitor rectangle (each has Left, Top, Right, Bottom).
    param($Window, $Monitor)
    return ($Window.Left -le $Monitor.Left -and $Window.Top -le $Monitor.Top -and
            $Window.Right -ge $Monitor.Right -and $Window.Bottom -ge $Monitor.Bottom)
}

function Test-IgnoredWindowClass {
    # Shell windows that cover the screen without the user being in a fullscreen app.
    param([string]$ClassName)
    return @('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd',
             'Windows.UI.Core.CoreWindow', 'LockScreenControllerProxyWindow') -contains $ClassName
}

function Get-GpuHogs {
    # From GPU Engine counter samples (each has Path and Value), the pids whose busiest engine
    # type (utilization summed over that type's engines) reaches $Threshold, as objects with
    # Pid and Percent, busiest first.
    param($Samples, [double]$Threshold)
    $sum = @{}
    foreach ($s in $Samples) {
        if ($s.Path -notmatch 'pid_(\d+)_.*engtype_([^)\\]+)') { continue }
        $key = $Matches[1] + '|' + $Matches[2]
        if (-not $sum.ContainsKey($key)) { $sum[$key] = 0.0 }
        $sum[$key] += [double]$s.Value
    }
    $best = @{}
    foreach ($k in $sum.Keys) {
        $procId = [int]($k.Split('|')[0])
        if (-not $best.ContainsKey($procId) -or $sum[$k] -gt $best[$procId]) { $best[$procId] = $sum[$k] }
    }
    $out = @()
    foreach ($procId in $best.Keys) {
        if ($best[$procId] -ge $Threshold) {
            $out += New-Object psobject -Property @{ Pid = $procId; Percent = [math]::Round($best[$procId]) }
        }
    }
    return , @($out | Sort-Object -Property Percent -Descending)
}

function New-DetectorResult {
    param([string]$Name, [bool]$Busy = $false, [string]$Reason = '', [string]$ErrorText = '')
    return New-Object psobject -Property @{ Name = $Name; Busy = $Busy; Reason = $Reason; ErrorText = $ErrorText }
}

function Get-Verdict {
    # Combines detector results: busy when any detector is busy; otherwise unknown (fail closed)
    # when any detector failed; otherwise idle.
    param($Results)
    $reasons = @(); $errors = @()
    foreach ($r in $Results) {
        if ($r.Busy) { $reasons += ($r.Name + ': ' + $r.Reason) }
        if ($r.ErrorText) { $errors += ('error: ' + $r.Name + ': ' + $r.ErrorText) }
    }
    $state = 'idle'
    if ($reasons.Count -gt 0) { $state = 'busy' } elseif ($errors.Count -gt 0) { $state = 'unknown' }
    $all = $reasons + $errors
    $reason = 'none'
    if ($all.Count -gt 0) { $reason = $all -join '; ' }
    return New-Object psobject -Property @{ State = $state; Reason = $reason }
}

function Format-StatusText {
    # The status file's content; $Now is a DateTimeOffset.
    param([string]$State, [string]$Reason, [DateTimeOffset]$Now, [int]$Interval)
    $oneLine = ($Reason -replace '[\r\n]+', ' ').Trim()
    if (-not $oneLine) { $oneLine = 'none' }
    return ("state={0}`nreason={1}`nupdated={2}`nepoch={3}`ninterval={4}`n" -f
            $State, $oneLine, $Now.ToString('yyyy-MM-ddTHH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture), $Now.ToUnixTimeSeconds(), $Interval)
}

# ---------------------------------------------------------------- self test

function Invoke-SelfTest {
    $script:fails = 0
    function Check([string]$Name, $Got, $Want) {
        if ("$Got" -ceq "$Want") { Write-Host "ok $Name" }
        else { Write-Host "FAIL $Name`n  got:  $Got`n  want: $Want"; $script:fails++ }
    }
    $games = @('C:\Games\Foo', 'D:/Epic/Bar\')
    Check 'path inside' (Test-PathUnderFolder 'C:\Games\Foo\bin\foo.exe' $games) $true
    Check 'path case-insensitive' (Test-PathUnderFolder 'c:\games\FOO\foo.exe' $games) $true
    Check 'path sibling prefix' (Test-PathUnderFolder 'C:\Games\FooBar\x.exe' $games) $false
    Check 'path slashes, trailing sep' (Test-PathUnderFolder 'D:\Epic\Bar\Win64\b.exe' $games) $true
    Check 'path folder itself' (Test-PathUnderFolder 'C:\Games\Foo' $games) $false
    Check 'path null' (Test-PathUnderFolder $null $games) $false
    Check 'path drive root ignored' (Test-PathUnderFolder 'C:\x.exe' @('C:\')) $false

    $epic = Get-EpicInstallLocations @('{"DisplayName":"A","InstallLocation":"C:\\Program Files\\Epic Games\\A"}',
                                       'not json', '{"DisplayName":"B"}', '{"InstallLocation":""}')
    Check 'epic count' $epic.Count 1
    Check 'epic location' $epic[0] 'C:\Program Files\Epic Games\A'
    Check 'epic none' (Get-EpicInstallLocations @()).Count 0

    $mon = New-Object psobject -Property @{ Left = 0; Top = 0; Right = 2560; Bottom = 1440 }
    $r = { param($l, $t, $rr, $b) New-Object psobject -Property @{ Left = $l; Top = $t; Right = $rr; Bottom = $b } }
    Check 'rect exact' (Test-RectCoversMonitor (& $r 0 0 2560 1440) $mon) $true
    Check 'rect larger (borderless)' (Test-RectCoversMonitor (& $r -8 -8 2568 1448) $mon) $true
    Check 'rect maximized window' (Test-RectCoversMonitor (& $r 0 0 2560 1400) $mon) $false
    $mon2 = New-Object psobject -Property @{ Left = 2560; Top = 0; Right = 4480; Bottom = 1080 }
    Check 'rect second monitor' (Test-RectCoversMonitor (& $r 2560 0 4480 1080) $mon2) $true
    Check 'rect other monitor' (Test-RectCoversMonitor (& $r 0 0 2560 1440) $mon2) $false

    Check 'class desktop' (Test-IgnoredWindowClass 'WorkerW') $true
    Check 'class game' (Test-IgnoredWindowClass 'UnrealWindow') $false

    $s = { param($p, $v) New-Object psobject -Property @{ Path = $p; Value = $v } }
    $samples = @(
        (& $s '\\pc\gpu engine(pid_100_luid_0x0_0x1_phys_0_eng_0_engtype_3d)\utilization percentage' 40),
        (& $s '\\pc\gpu engine(pid_100_luid_0x0_0x1_phys_0_eng_1_engtype_3d)\utilization percentage' 30),
        (& $s '\\pc\gpu engine(pid_100_luid_0x0_0x1_phys_0_eng_5_engtype_copy)\utilization percentage' 90),
        (& $s '\\pc\gpu engine(pid_200_luid_0x0_0x1_phys_0_eng_0_engtype_3d)\utilization percentage' 49.4),
        (& $s '\\pc\gpu engine(pid_300_luid_0x0_0x1_phys_0_eng_2_engtype_compute_0)\utilization percentage' 75),
        (& $s '\\pc\gpu engine(garbage)\utilization percentage' 99))
    $hogs = Get-GpuHogs $samples 50
    Check 'gpu hog count' $hogs.Count 2
    Check 'gpu hog order' (($hogs | ForEach-Object { "$($_.Pid):$($_.Percent)" }) -join ',') '100:90,300:75'
    Check 'gpu none' (Get-GpuHogs @() 50).Count 0

    $v = Get-Verdict @((New-DetectorResult 'steam'), (New-DetectorResult 'gpu'))
    Check 'verdict idle' "$($v.State)|$($v.Reason)" 'idle|none'
    $v = Get-Verdict @((New-DetectorResult 'steam' $true 'app 570'), (New-DetectorResult 'fullscreen' $true 'game.exe'))
    Check 'verdict busy' "$($v.State)|$($v.Reason)" 'busy|steam: app 570; fullscreen: game.exe'
    $v = Get-Verdict @((New-DetectorResult 'gpu' $false '' 'counters unavailable'), (New-DetectorResult 'steam'))
    Check 'verdict failed detector is unknown' "$($v.State)|$($v.Reason)" 'unknown|error: gpu: counters unavailable'
    $v = Get-Verdict @((New-DetectorResult 'gog' $false '' 'denied'), (New-DetectorResult 'epic' $true 'a.exe'))
    Check 'verdict busy wins over a failure' "$($v.State)|$($v.Reason)" 'busy|epic: a.exe; error: gog: denied'

    $now = New-Object DateTimeOffset 2026, 11, 1, 12, 30, 5, ([TimeSpan]::FromHours(-5))
    Check 'status text' (Format-StatusText 'busy' "a`r`nb" $now 15) "state=busy`nreason=a b`nupdated=2026-11-01T12:30:05-05:00`nepoch=1793554205`ninterval=15`n"
    Check 'status text empty reason' ((Format-StatusText 'idle' '' $now 15).Split("`n")[1]) 'reason=none'

    if ($script:fails -eq 0) { Write-Host 'all passed' } else { Write-Host "$($script:fails) failed" }
}

# ---------------------------------------------------------------- detectors (need Windows)

function Get-UserProcesses {
    # This session's processes with a readable path (other users' paths aren't readable).
    return @(Get-Process | Where-Object { $_.Path })
}

function Test-Steam {
    $key = 'HKCU:\Software\Valve\Steam'
    if (-not (Test-Path $key)) { return New-DetectorResult 'steam' }
    $p = Get-ItemProperty -Path $key
    if ($p.PSObject.Properties['RunningAppID'] -and [int64]$p.RunningAppID -ne 0) {
        return New-DetectorResult 'steam' $true ('app ' + $p.RunningAppID)
    }
    return New-DetectorResult 'steam'
}

function Test-ProcessesUnder([string]$Name, [string[]]$Folders, $Processes) {
    if ($Folders.Count -eq 0) { return New-DetectorResult $Name }
    $hits = @($Processes | Where-Object { Test-PathUnderFolder $_.Path $Folders } |
              ForEach-Object { $_.ProcessName + '.exe' } | Sort-Object -Unique)
    if ($hits.Count -gt 0) { return New-DetectorResult $Name $true ($hits -join ',') }
    return New-DetectorResult $Name
}

function Test-Epic($Processes) {
    $dir = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path $dir)) { return New-DetectorResult 'epic' }
    $texts = @(Get-ChildItem -Path $dir -Filter '*.item' -File |
               ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
    return Test-ProcessesUnder 'epic' (Get-EpicInstallLocations $texts) $Processes
}

function Test-Gog($Processes) {
    $folders = @()
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games', 'HKLM:\SOFTWARE\GOG.com\Games') {
        if (-not (Test-Path $key)) { continue }
        foreach ($g in Get-ChildItem -Path $key) {
            $p = Get-ItemProperty -Path $g.PSPath
            if ($p.PSObject.Properties['path'] -and $p.path) { $folders += [string]$p.path }
        }
    }
    return Test-ProcessesUnder 'gog' $folders $Processes
}

$script:user32Loaded = $false
function Initialize-User32 {
    if ($script:user32Loaded) { return }
    Add-Type -Namespace WinpcWatcher -Name User32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
[DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO info);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int max);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
    # Physical pixels for both rectangles, whatever the display scaling.
    [void][WinpcWatcher.User32]::SetProcessDPIAware()
    $script:user32Loaded = $true
}

function Test-Fullscreen {
    Initialize-User32
    $h = [WinpcWatcher.User32]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return New-DetectorResult 'fullscreen' }
    $sb = New-Object System.Text.StringBuilder 256
    [void][WinpcWatcher.User32]::GetClassName($h, $sb, $sb.Capacity)
    if (Test-IgnoredWindowClass $sb.ToString()) { return New-DetectorResult 'fullscreen' }
    $wr = New-Object WinpcWatcher.User32+RECT
    if (-not [WinpcWatcher.User32]::GetWindowRect($h, [ref]$wr)) { return New-DetectorResult 'fullscreen' }
    $mi = New-Object WinpcWatcher.User32+MONITORINFO
    $mi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($mi)
    $mon = [WinpcWatcher.User32]::MonitorFromWindow($h, 2)   # MONITOR_DEFAULTTONEAREST
    if (-not [WinpcWatcher.User32]::GetMonitorInfo($mon, [ref]$mi)) { return New-DetectorResult 'fullscreen' }
    if (-not (Test-RectCoversMonitor $wr $mi.rcMonitor)) { return New-DetectorResult 'fullscreen' }
    $procId = [uint32]0
    [void][WinpcWatcher.User32]::GetWindowThreadProcessId($h, [ref]$procId)
    $name = 'pid ' + $procId
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc) { $name = $proc.ProcessName + '.exe' }
    return New-DetectorResult 'fullscreen' $true $name
}

function Test-Gpu([int]$Threshold) {
    # Samples of processes that exit mid-sample raise non-terminating errors; only no data at
    # all (counters missing, e.g. a non-English counter name) is a failure.
    $set = Get-Counter -Counter $GpuCounter -ErrorAction SilentlyContinue
    if (-not $set) { throw "no samples from $GpuCounter" }
    $samples = $set.CounterSamples
    $hogs = Get-GpuHogs $samples $Threshold
    $mine = @()
    foreach ($hog in $hogs) {
        # Only this user's processes count: the claude user's runs and system processes don't.
        $cim = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $hog.Pid) -ErrorAction SilentlyContinue
        if (-not $cim) { continue }
        $owner = Invoke-CimMethod -InputObject $cim -MethodName GetOwner -ErrorAction SilentlyContinue
        if (-not $owner -or $owner.ReturnValue -ne 0) { continue }
        if ($owner.User -ne $env:USERNAME -or $owner.Domain -ne $env:USERDOMAIN) { continue }
        $mine += ($cim.Name + ' ' + $hog.Percent + '%')
    }
    if ($mine.Count -gt 0) { return New-DetectorResult 'gpu' $true ($mine -join ',') }
    return New-DetectorResult 'gpu'
}

function Invoke-Detector([string]$Name, [scriptblock]$Block) {
    try { return & $Block }
    catch { return New-DetectorResult $Name $false '' (($_.Exception.Message -replace '[\r\n]+', ' ').Trim()) }
}

function Get-CurrentVerdict {
    $procs = @()
    $procError = ''
    try { $procs = Get-UserProcesses } catch { $procError = $_.Exception.Message }
    $results = @(
        (Invoke-Detector 'steam' { Test-Steam }),
        (Invoke-Detector 'epic' { if ($procError) { throw $procError }; Test-Epic $procs }),
        (Invoke-Detector 'gog' { if ($procError) { throw $procError }; Test-Gog $procs }),
        (Invoke-Detector 'fullscreen' { Test-Fullscreen }),
        (Invoke-Detector 'gpu' { Test-Gpu $GpuBusyPercent }))
    return Get-Verdict $results
}

function Write-StatusFile([string]$Text) {
    # never recreate the folder: it would get the inherited ACL, so claude could create files in it
    if (-not (Test-Path $StatusDir)) { throw "$StatusDir is missing; rerun install-winpc-watcher.ps1 (no status is written, so winpc treats the PC as unknown)" }
    $dest = Join-Path $StatusDir 'status.txt'
    $tmp = Join-Path $StatusDir ('status.' + $PID + '.tmp')
    [IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding $false))
    if (Test-Path $dest) { [IO.File]::Replace($tmp, $dest, $null) }
    else { [IO.File]::Move($tmp, $dest) }
}

# ---------------------------------------------------------------- main

if ($SelfTest) {
    Invoke-SelfTest
    if ($script:fails -eq 0) { exit 0 } else { exit 1 }
}

# The loop never dies on an error (Task Scheduler's restart doesn't fire on a script error); a
# round that can't write the file leaves it to go stale, which winpc refuses.
while ($true) {
    try {
        $v = Get-CurrentVerdict
        $text = Format-StatusText $v.State $v.Reason ([DateTimeOffset]::Now) $IntervalSeconds
        Write-StatusFile $text
        if ($Once) { Write-Output $text; exit 0 }
    } catch {
        Write-Warning ('this round failed: ' + $_.Exception.Message)
        if ($Once) { exit 1 }
    }
    Start-Sleep -Seconds $IntervalSeconds
}
