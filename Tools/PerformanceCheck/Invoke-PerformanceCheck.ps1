<#
.SYNOPSIS
    Why is this PC slow? Watches it for 30 seconds, checks the usual causes, and says what to do
    about each one - problems first, on one page.

.DESCRIPTION
    Quick triage takes one snapshot. This measures the machine over a short sample while the user
    does whatever is slow, then looks for the reasons:

      Hardware    Windows on a hard drive or an SSD, how much RAM and how many sticks, free space
      Load        CPU, system disk and memory, averaged over the sample rather than one moment
      Power       on battery, power plan, power mode, maximum processor state, and whether the CPU
                  ran below its normal speed while it was busy (heat, charger, power settings)
      Apps        what used the CPU, memory and disk during the sample, grouped by app (Chrome's
                  40 processes count as one), with advice for the usual suspects: Teams, Defender
                  scans, search indexing, OneDrive, Windows Update, browsers, Outlook, McAfee
      Uptime      days since boot and pending restarts
      Stability   apps that hung, and Windows' low-memory warnings (which name the apps to blame)
      Startup     how long recent start-ups took, the apps, drivers and services Windows itself
                  flagged as slowing start-up, and every startup app, on or off
      Drivers     BIOS age, and whether the graphics driver is missing or old

    Read-only unless you add -Fix. With -Fix it offers, one question at a time, only changes that
    are easy to undo:
      - power plan from Power saver back to Balanced
      - maximum processor state back to 100% when plugged in
      - turning off startup apps you pick, the same way Task Manager does, so they can be turned
        back on in Task Manager > Startup apps
    It never offers to turn off security, remote support, VPN, audio / touchpad / hotkey helpers or
    OneDrive, never deletes anything and never restarts. Every change is listed with its undo.

    Works unelevated. Run it as admin to see start-up times, and to change startup apps for all
    users or for the signed-in user when you are elevated as a different account.

.PARAMETER Seconds
    How long to measure for. Default 30. Ask the user to do whatever is slow while it runs.

.PARAMETER Days
    Look-back for hangs, low-memory warnings and slow start-up events. Default 7.

.PARAMETER Fix
    After the report, offer the fixes it found, asking before each. Nothing changes without a yes.

.PARAMETER Html
    Also write a one-page HTML report (and open it, when run locally and interactively).

.PARAMETER ReportFolder
    Where -Html writes. Default C:\Triage, next to the Quick triage reports.

.PARAMETER NoOpen
    Don't open the HTML report after writing it.

.PARAMETER Quiet
    Print only the one-line summary (for RMM monitors).

.PARAMETER PassThru
    Emit the findings, measurements, startup apps and any changes to the pipeline.

.EXAMPLE
    .\Invoke-PerformanceCheck.ps1 -Html

.EXAMPLE
    .\Invoke-PerformanceCheck.ps1 -Html -Fix
    (From an elevated session, so it can show start-up times and change startup apps for everyone.)

.EXAMPLE
    .\Invoke-PerformanceCheck.ps1 -Seconds 90
    (A longer sample for slowness that comes and goes.)

.NOTES
    Exit codes: 0 = nothing failed, 1 = at least one FAIL.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(10, 300)] [int] $Seconds = 30,
    [ValidateRange(1, 30)] [int] $Days = 7,
    [switch] $Fix,
    [switch] $Html,
    [string] $ReportFolder = (Join-Path $env:SystemDrive 'Triage'),
    [switch] $NoOpen,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$ToolsRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path (Join-Path $ToolsRoot 'Shared') 'Helpers.ps1')

$now   = Get-Date
$since = $now.AddDays(-$Days)
$SystemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }

$Findings  = New-Object System.Collections.Generic.List[object]
$FixOffers = New-Object System.Collections.Generic.List[object]
$Changes   = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param(
        [string] $Area, [string] $Check,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')] [string] $Status,
        [string] $Detail, [string] $Fix
    )
    $Findings.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix; Order = $Findings.Count })
}

# What to look at first when several things are wrong: hardware limits explain everything else.
$AreaOrder = @('Hardware', 'Load', 'Power', 'Apps', 'Uptime', 'Stability', 'Startup', 'Drivers', 'Device')

function Invoke-Check {
    # One broken check records a note and moves on; it never sinks the report.
    param([string] $Area, [scriptblock] $Body)
    try { & $Body }
    catch { Add-Finding $Area 'Check failed' 'INFO' "Couldn't run: $($_.Exception.Message)" }
}

function Get-RecentEvent {
    param([hashtable] $Filter, [int] $Max = 500)
    try { @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) }
    catch {
        if ($_.Exception.Message -match 'No events were found') { @() }
        else { throw }
    }
}

function Get-EventField {
    # Named EventData fields as a hashtable (Diagnostics-Performance events have no useful message).
    param($Record)
    $h = @{}
    try {
        foreach ($d in @(([xml]$Record.ToXml()).Event.EventData.Data)) { if ($d.Name) { $h[[string]$d.Name] = [string]$d.'#text' } }
    }
    catch { Write-Verbose "Couldn't read event data: $($_.Exception.Message)" }
    $h
}

function Test-IsElevated {
    try {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $false }
}

function Format-Size {
    param([double] $Bytes)
    if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N0} MB' -f ($Bytes / 1MB) }
    else { '{0:N0} KB' -f ($Bytes / 1KB) }
}

function Format-Duration {
    param([double] $Ms)
    $s = [int][math]::Round($Ms / 1000, [MidpointRounding]::AwayFromZero)
    if ($s -ge 60) { '{0}m {1:00}s' -f [int][math]::Floor($s / 60), ($s % 60) } else { "${s}s" }
}

function Read-Answer {
    # A closed or non-interactive input (RMM, remote session) reads as a blank answer: nothing changes.
    param([string] $Prompt)
    try { [string](Read-Host -Prompt $Prompt) } catch { '' }
}

function Add-FixOffer {
    param([string] $Name, [string] $Question, [scriptblock] $Apply, [string] $Undo)
    $FixOffers.Add([pscustomobject]@{ Name = $Name; Question = $Question; Apply = $Apply; Undo = $Undo })
}

$IsElevated = Test-IsElevated

# ------------------------------------------------------------------------------------------------
#  Known names
# ------------------------------------------------------------------------------------------------
# The usual suspects, by process name (no .exe). The advice is what to try first.
$Culprits = [ordered]@{
    'ms-teams|msteams|teams'                                    = @{ App = 'Teams'; Fix = 'Clear its cache: Repair > Teams cache clear. Still heavy afterwards: check Teams is up to date.' }
    'msedgewebview2'                                            = @{ App = 'WebView2 (new Teams, new Outlook, widgets)'; Fix = 'Usually new Teams or new Outlook underneath. Try Repair > Teams cache clear first.' }
    'msmpeng|mpdefendercoreservice|nissrv'                      = @{ App = 'Microsoft Defender'; Fix = 'A scan is running. Let it finish; if it happens every day in work hours, move the scheduled scan in Intune.' }
    'searchindexer|searchprotocolhost|searchfilterhost'         = @{ App = 'Windows Search indexing'; Fix = 'Normal for a day or so after a build or a new mailbox. If it never settles: Settings > Privacy & security > Searching Windows > Advanced indexing options > Advanced > Rebuild.' }
    'onedrive|onedrive\.sync\.service|filecoauth'               = @{ App = 'OneDrive'; Fix = 'Syncing. Check the OneDrive icon for a big upload or a stuck file; pausing sync for 2 hours proves it.' }
    'tiworker|trustedinstaller|mousocoreworker|usocoreworker|wuauclt' = @{ App = 'Windows Update'; Fix = 'Installing updates. Let it finish, then restart.' }
    'compattelrunner'                                           = @{ App = 'Compatibility telemetry'; Fix = 'Runs now and then and finishes by itself.' }
    'chrome|msedge|firefox|brave'                               = @{ App = 'Browser'; Fix = 'Too many tabs or a heavy extension. Shift+Esc in Chrome or Edge opens its own task manager to find which.' }
    'outlook|olk'                                               = @{ App = 'Outlook'; Fix = 'Big mailbox or a bad add-in. outlook.exe /safe tests without add-ins.' }
    'mcshield|mfemms|mfevtps|mfefire|mcapexe|modulecoreservice' = @{ App = 'McAfee'; Fix = 'McAfee is still on this machine. Build > McAfee removal.' }
    'wmiprvse'                                                  = @{ App = 'WMI'; Fix = 'Something is querying WMI hard - usually a monitoring or management agent.' }
    'dwm'                                                       = @{ App = 'Desktop Window Manager'; Fix = 'Graphics driver. Build > OEM drivers + BIOS, or the graphics maker''s own driver.' }
    'audiodg'                                                   = @{ App = 'Windows audio'; Fix = 'Audio driver or sound "enhancements". Update the audio driver, or turn enhancements off in Sound settings.' }
    'memcompression|memory compression'                         = @{ App = 'Memory compression'; Fix = 'Windows squeezing memory because it is running out. Close apps, or add RAM.' }
}

function Get-Culprit {
    param([string] $Name)
    foreach ($k in $Culprits.Keys) { if ($Name -match "^($k)$") { return $Culprits[$k] } }
    $null
}

# Startup entries never offered for turning off. Matched against the name and the command.
$KeepOn = @(
    @{ Why = 'security';            Rx = 'SecurityHealth|Defender|Sentinel|CrowdStrike|CSFalcon|Sophos|Huntress|Bitdefender|\bESET\b|\begui\b|Malwarebytes|Webroot|Cylance|Carbon ?Black|Cortex|Trend ?Micro|Symantec|Norton|Kaspersky|McAfee|\bmfe|Avast|\bAVG\b|ThreatLocker|Blackpoint|Arctic ?Wolf' }
    @{ Why = 'remote support';      Rx = 'ScreenConnect|ConnectWise|Datto|Ninja|N-able|\bNAble\b|Kaseya|Atera|TeamViewer|Splashtop|LogMeIn|BeyondTrust|Bomgar|Syncro|Pulseway|AnyDesk|Action1' }
    @{ Why = 'VPN / network';       Rx = 'VPN|AnyConnect|Cisco Secure|GlobalProtect|PanGPA|Forti|Zscaler|Netskope|NordLayer|Tailscale|WireGuard' }
    @{ Why = 'device helper';       Rx = 'Realtek|RtkAud|Synaptics|SynTP|\bELAN\b|ETDCtrl|Conexant|SmartAudio|Waves|MaxxAudio|Dolby|Nahimic|igfx|\bIntel\b|\bAMD\b|Radeon|NVIDIA|Hotkey|Bluetooth|Touchpad|Wacom|DisplayLink' }
    @{ Why = 'keeps files syncing'; Rx = 'OneDrive' }
)

function Get-KeepOnReason {
    param([string] $Text)
    foreach ($k in $KeepOn) { if ($Text -match $k.Rx) { return $k.Why } }
    $null
}

if (-not $Quiet) {
    Write-Host ("Measuring {0} for {1} seconds. Ask the user to do whatever is slow while this runs..." -f $env:COMPUTERNAME, $Seconds) -ForegroundColor DarkGray
}

# ------------------------------------------------------------------------------------------------
#  Device (inventory tool)
# ------------------------------------------------------------------------------------------------
$inv = $null
Invoke-Check 'Device' {
    $script:inv = & (Join-Path (Join-Path $ToolsRoot 'DeviceInventory') 'Get-DeviceInventory.ps1') -Quiet -PassThru
}

$cs = $null; $os = $null
try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem } catch { $cs = $null }
try { $os = Get-CimInstance -ClassName Win32_OperatingSystem } catch { $os = $null }
$TotalGB = if ($cs -and $cs.TotalPhysicalMemory) { [math]::Round([double]$cs.TotalPhysicalMemory / 1GB) }
           elseif ($os -and $os.TotalVisibleMemorySize) { [math]::Round([double]$os.TotalVisibleMemorySize / 1MB) } else { $null }
$Cores = if ($cs -and $cs.NumberOfLogicalProcessors) { [int]$cs.NumberOfLogicalProcessors } else { [Environment]::ProcessorCount }
if ($Cores -lt 1) { $Cores = 1 }

# ------------------------------------------------------------------------------------------------
#  The sample: system counters every 2 seconds, and per-process totals at the start and end.
#  CIM performance classes rather than Get-Counter, because counter names are translated on
#  non-English Windows and the class names aren't.
# ------------------------------------------------------------------------------------------------
function Get-PerfSample {
    $s = [ordered]@{ Cpu = $null; Perf = $null; FreqMHz = $null; DiskBusy = $null; Queue = $null; AvailMB = $null; CommitPct = $null; PagesIn = $null }
    try {
        $c = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name = '_Total'"
        if ($c) { $s.Cpu = [double]$c.PercentProcessorTime }
    } catch { Write-Verbose "CPU counter: $($_.Exception.Message)" }
    try {
        $p = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name = '_Total'"
        if ($p) { $s.Perf = [double]$p.PercentProcessorPerformance; $s.FreqMHz = [double]$p.ProcessorFrequency }
    } catch { Write-Verbose "Processor information counter: $($_.Exception.Message)" }
    try {
        $disks = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -ne '_Total' })
        # Instance names look like "0 C:" or "1 D: E:". Prefer the disk Windows is on.
        $d = @($disks | Where-Object { " $($_.Name) " -match ('\s{0}\s' -f [regex]::Escape($SystemDrive)) }) | Select-Object -First 1
        if (-not $d -and $disks.Count) { $d = $disks | Sort-Object { [double]$_.PercentIdleTime } | Select-Object -First 1 }
        if ($d) {
            $s.DiskBusy = [math]::Min(100, [math]::Max(0, 100 - [double]$d.PercentIdleTime))
            $s.Queue    = [double]$d.CurrentDiskQueueLength
        }
    } catch { Write-Verbose "Disk counter: $($_.Exception.Message)" }
    try {
        $m = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory
        if ($m) { $s.AvailMB = [double]$m.AvailableMBytes; $s.CommitPct = [double]$m.PercentCommittedBytesInUse; $s.PagesIn = [double]$m.PagesInputPersec }
    } catch { Write-Verbose "Memory counter: $($_.Exception.Message)" }
    [pscustomobject]$s
}

function Get-ProcessSnapshot {
    # Raw counters: CPU time and I/O bytes are running totals, so start and end give an exact average.
    $h = @{}
    foreach ($p in @(Get-CimInstance -ClassName Win32_PerfRawData_PerfProc_Process)) {
        if ($p.Name -in '_Total', 'Idle') { continue }
        $h['{0}|{1}' -f $p.IDProcess, $p.Name] = $p
    }
    $h
}

$Samples = New-Object System.Collections.Generic.List[object]
$startProcs = @{}; $endProcs = @{}
$sampleOk = $true
try {
    $startProcs = Get-ProcessSnapshot
    [void](Get-PerfSample)   # the first formatted reading can be stale; throw it away
    $rounds = [int][math]::Ceiling($Seconds / 2)
    for ($i = 1; $i -le $rounds; $i++) {
        if (-not $Quiet) { Write-Progress -Activity 'Performance check' -Status "Measuring ($($i * 2) of $Seconds s)" -PercentComplete ([int](100 * $i / $rounds)) }
        Start-Sleep -Seconds 2
        $Samples.Add((Get-PerfSample))
    }
    $endProcs = Get-ProcessSnapshot
}
catch {
    $sampleOk = $false
    Add-Finding 'Load' 'Measurement' 'INFO' "Couldn't measure: $($_.Exception.Message)"
}
finally {
    if (-not $Quiet) { Write-Progress -Activity 'Performance check' -Completed }
}

function Get-SampleStat {
    param([string] $Property, [switch] $Max)
    $v = @($Samples | ForEach-Object { $_.$Property } | Where-Object { $null -ne $_ })
    if (-not $v.Count) { return $null }
    if ($Max) { ($v | Measure-Object -Maximum).Maximum } else { ($v | Measure-Object -Average).Average }
}

# Per app: everything with the same process name counted together.
$Apps = @{}
foreach ($k in $endProcs.Keys) {
    $e = $endProcs[$k]; $s = $startProcs[$k]
    $name = ([string]$e.Name) -replace '#\d+$', ''
    if (-not $Apps.ContainsKey($name)) {
        $Apps[$name] = [pscustomobject]@{ Name = $name; Count = 0; CpuPct = 0.0; MemBytes = [double]0; IOBps = [double]0 }
    }
    $a = $Apps[$name]
    $a.Count++
    $a.MemBytes += [double]$e.WorkingSetPrivate
    if ($s) {
        $dt = [double]$e.Timestamp_Sys100NS - [double]$s.Timestamp_Sys100NS
        if ($dt -gt 0) {
            $a.CpuPct += [math]::Max(0, 100 * ([double]$e.PercentProcessorTime - [double]$s.PercentProcessorTime) / $dt / $Cores)
            $a.IOBps  += [math]::Max(0, ([double]$e.IODataBytesPersec - [double]$s.IODataBytesPersec) / ($dt / 1e7))
        }
    }
}
$AppList = @($Apps.Values)
$TopCpu  = @($AppList | Where-Object { $_.CpuPct -ge 1 } | Sort-Object CpuPct -Descending | Select-Object -First 5)
$TopMem  = @($AppList | Sort-Object MemBytes -Descending | Select-Object -First 5)
$TopIO   = @($AppList | Where-Object { $_.IOBps -ge 1MB } | Sort-Object IOBps -Descending | Select-Object -First 3)

function Format-AppName { param($App) if ($App.Count -gt 1) { '{0} (x{1})' -f $App.Name, $App.Count } else { $App.Name } }

$Measured = [pscustomobject]@{
    Seconds      = $Seconds
    CpuAvg       = Get-SampleStat Cpu
    CpuPeak      = Get-SampleStat Cpu -Max
    DiskBusyAvg  = Get-SampleStat DiskBusy
    DiskQueueAvg = Get-SampleStat Queue
    AvailMBAvg   = Get-SampleStat AvailMB
    CommitPctAvg = Get-SampleStat CommitPct
    PagesInAvg   = Get-SampleStat PagesIn
}

# ------------------------------------------------------------------------------------------------
#  Hardware
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Hardware' {
    $disks = @($inv.Disks | Where-Object { $_ })
    $sysDisk = $null
    try {
        $num = (Get-Partition -DriveLetter $SystemDrive.TrimEnd(':') -ErrorAction Stop | Select-Object -First 1).DiskNumber
        $sysDisk = $disks | Where-Object { [string]$_.Disk -eq [string]$num } | Select-Object -First 1
    }
    catch { $sysDisk = $null }
    if (-not $sysDisk -and $disks.Count -eq 1) { $sysDisk = $disks[0] }
    if ($sysDisk) {
        $name = '{0} ({1})' -f $sysDisk.Model, $sysDisk.Size
        switch -Regex ([string]$sysDisk.Media) {
            'HDD' { Add-Finding 'Hardware' 'System drive' 'FAIL' "Windows is on a spinning hard drive: $name" 'Replace it with an SSD. Nothing else on this list will make as big a difference.' }
            'SSD' { Add-Finding 'Hardware' 'System drive' 'PASS' "SSD: $name" }
            default { Add-Finding 'Hardware' 'System drive' 'INFO' "Drive type not reported: $name" }
        }
    }
    elseif ($disks.Count -and -not @($disks | Where-Object { [string]$_.Media -ne 'HDD' }).Count) {
        Add-Finding 'Hardware' 'System drive' 'FAIL' 'Every drive in this machine is a spinning hard drive' 'Replace the system drive with an SSD. Nothing else on this list will make as big a difference.'
    }

    $sys = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f $SystemDrive)
    if ($sys -and $sys.Size) {
        $freeGB = [math]::Round($sys.FreeSpace / 1GB, 1)
        $pct    = [int][math]::Round(100 * $sys.FreeSpace / $sys.Size)
        $text   = '{0} has {1} GB free ({2}%)' -f $SystemDrive, $freeGB, $pct
        $fix    = 'Run Diagnose > Disk usage report to see where it went.'
        if ($freeGB -lt 5 -or $pct -lt 5)       { Add-Finding 'Hardware' 'Free space' 'FAIL' $text "Critically low: Windows slows down and updates fail. $fix" }
        elseif ($freeGB -lt 20 -or $pct -lt 10) { Add-Finding 'Hardware' 'Free space' 'WARN' $text "Low. $fix" }
        else                                    { Add-Finding 'Hardware' 'Free space' 'PASS' $text }
    }

    if ($TotalGB) {
        if ($TotalGB -le 4)     { Add-Finding 'Hardware' 'Memory size' 'FAIL' "$TotalGB GB of RAM" 'Not enough for Windows 11 with Office and a browser. Add RAM or replace the machine.' }
        elseif ($TotalGB -le 8) { Add-Finding 'Hardware' 'Memory size' 'WARN' "$TotalGB GB of RAM" 'Tight for Office + Teams + a browser; 16 GB is the comfortable minimum now.' }
        else                    { Add-Finding 'Hardware' 'Memory size' 'PASS' "$TotalGB GB of RAM" }
    }

    $mem = $inv.Memory
    $mods = @($mem.Modules | Where-Object { $_ })
    if ($mods.Count -eq 1 -and [string]$mods[0].FormFactor -in 'DIMM', 'SO-DIMM' -and $mem.Slots -and [int]$mem.Slots -ge 2) {
        Add-Finding 'Hardware' 'Memory sticks' 'WARN' ('One {0} stick in a machine with {1} slots, so the memory runs single-channel' -f $mods[0].Size, $mem.Slots) `
            'Add a matching stick: more memory, and about double the memory speed. Matters most on laptops with no graphics card.'
    }
    elseif ($mods.Count) {
        Add-Finding 'Hardware' 'Memory sticks' 'PASS' ('{0} stick(s){1}' -f $mods.Count, $(if ($mem.Slots) { " in $($mem.Slots) slot(s)" } else { '' }))
    }
}

# ------------------------------------------------------------------------------------------------
#  Load (from the sample)
# ------------------------------------------------------------------------------------------------
if ($sampleOk -and $Samples.Count) {
    Invoke-Check 'Load' {
        $avg = $Measured.CpuAvg; $peak = $Measured.CpuPeak
        if ($null -ne $avg) {
            $text = 'Average {0:N0}%, peak {1:N0}% over {2} seconds' -f $avg, $peak, $Seconds
            if ($avg -ge 85)     { Add-Finding 'Load' 'CPU' 'FAIL' $text 'Flat out the whole time. See the apps below for what is using it.' }
            elseif ($avg -ge 50) { Add-Finding 'Load' 'CPU' 'WARN' $text 'Busy. See the apps below for what is using it.' }
            else                 { Add-Finding 'Load' 'CPU' 'PASS' $text }
        }

        $busy = $Measured.DiskBusyAvg
        if ($null -ne $busy) {
            $q = if ($null -ne $Measured.DiskQueueAvg -and $Measured.DiskQueueAvg -ge 2) { ', {0:N1} requests waiting on average' -f $Measured.DiskQueueAvg } else { '' }
            $text = '{0} drive busy {1:N0}% of the time{2}' -f $SystemDrive, $busy, $q
            if ($busy -ge 80)     { Add-Finding 'Load' 'Disk' 'FAIL' $text 'The drive is the bottleneck. See the apps below for what is reading and writing.' }
            elseif ($busy -ge 50) { Add-Finding 'Load' 'Disk' 'WARN' $text 'Busy. See the apps below for what is reading and writing.' }
            else                  { Add-Finding 'Load' 'Disk' 'PASS' $text }
        }

        if ($null -ne $Measured.AvailMBAvg -and $TotalGB) {
            $availPct = [int][math]::Round(100 * $Measured.AvailMBAvg / ($TotalGB * 1024))
            $commit   = $Measured.CommitPctAvg
            $paging   = if ($null -ne $Measured.PagesInAvg -and $Measured.PagesInAvg -ge 500) { ', and reading back from the page file ({0:N0} pages/s)' -f $Measured.PagesInAvg } else { '' }
            $text = '{0} free of {1} GB ({2}%), {3:N0}% of the commit limit in use{4}' -f (Format-Size ($Measured.AvailMBAvg * 1MB)), $TotalGB, $availPct, $commit, $paging
            $fix = if ($TotalGB -le 8) { "Only $TotalGB GB. Close what isn't needed (biggest apps below), or add RAM." } else { 'Close or restart the biggest app below; if it keeps growing, it has a leak - update it.' }
            if ($availPct -lt 5 -or $commit -ge 95)      { Add-Finding 'Load' 'Memory' 'FAIL' $text "Out of memory. $fix" }
            elseif ($availPct -lt 15 -or $commit -ge 85) { Add-Finding 'Load' 'Memory' 'WARN' $text "Running short. $fix" }
            else                                         { Add-Finding 'Load' 'Memory' 'PASS' $text }
        }

        try {
            $pf = @(Get-CimInstance -ClassName Win32_PageFileUsage)
            if (-not $pf.Count -and $cs -and -not $cs.AutomaticManagedPagefile) {
                Add-Finding 'Load' 'Page file' 'WARN' 'No page file' 'Apps crash when memory runs out. System > About > Advanced system settings > Performance > Advanced > Virtual memory: System managed.'
            }
        } catch { Write-Verbose "Page file: $($_.Exception.Message)" }
    }

    # --------------------------------------------------------------------------------------------
    #  Apps (from the sample)
    # --------------------------------------------------------------------------------------------
    Invoke-Check 'Apps' {
        if ($TopCpu.Count) {
            $text = ($TopCpu | ForEach-Object { '{0} {1:N0}%' -f (Format-AppName $_), $_.CpuPct }) -join ', '
            $status = if ($TopCpu[0].CpuPct -ge 25) { 'WARN' } else { 'PASS' }
            Add-Finding 'Apps' 'Top CPU' $status $text $(if ($status -eq 'WARN') { "$($TopCpu[0].Name) used a quarter or more of the whole machine." })
        }
        else { Add-Finding 'Apps' 'Top CPU' 'PASS' 'Nothing used more than 1% of the CPU' }

        if ($TopMem.Count) {
            Add-Finding 'Apps' 'Top memory' 'INFO' (($TopMem | ForEach-Object { '{0} {1}' -f (Format-AppName $_), (Format-Size $_.MemBytes) }) -join ', ')
        }
        if ($TopIO.Count) {
            Add-Finding 'Apps' 'Top disk / network' 'INFO' (($TopIO | ForEach-Object { '{0} {1}/s' -f (Format-AppName $_), (Format-Size $_.IOBps) }) -join ', ')
        }

        # The usual suspects, if they were doing anything worth mentioning.
        $seen = @{}
        $heavy = @($TopCpu | Where-Object { $_.CpuPct -ge 10 }) + @($TopMem | Where-Object { $_.MemBytes -ge 2GB }) + @($TopIO | Where-Object { $_.IOBps -ge 5MB })
        foreach ($a in $heavy) {
            $c = Get-Culprit $a.Name
            if (-not $c -or $seen.ContainsKey($c.App)) { continue }
            $seen[$c.App] = $true
            $what = @()
            if ($a.CpuPct -ge 10)    { $what += '{0:N0}% CPU' -f $a.CpuPct }
            if ($a.MemBytes -ge 1GB) { $what += Format-Size $a.MemBytes }
            if ($a.IOBps -ge 1MB)    { $what += '{0}/s disk' -f (Format-Size $a.IOBps) }
            Add-Finding 'Apps' $c.App 'WARN' ('{0}: {1}' -f (Format-AppName $a), ($what -join ', ')) $c.Fix
        }
    }
}

# ------------------------------------------------------------------------------------------------
#  Power
# ------------------------------------------------------------------------------------------------
$PowerSaver   = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$PowerModes   = @{
    '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Best power efficiency'
    '3af9b8d9-7c97-431d-ad78-34a8bfea439f' = 'Better performance'
    'ded574b5-45a0-4f42-8737-46345c09c238' = 'Best performance'
}
$Efficiency = '961cc777-2547-4f9d-8174-7d86181b8a7a'
$OnBattery  = $false

Invoke-Check 'Power' {
    $bat = @(Get-CimInstance -ClassName Win32_Battery)
    if ($bat.Count -and @($bat | Where-Object { [int]$_.BatteryStatus -eq 1 }).Count) {
        $script:OnBattery = $true
        Add-Finding 'Power' 'Power source' 'INFO' 'Running on battery' 'Windows trades speed for battery life on battery. Plug it in and check again before blaming anything else.'
    }
    elseif ($bat.Count) { Add-Finding 'Power' 'Power source' 'PASS' 'Plugged in' }
}

Invoke-Check 'Power' {
    # CPU speed while busy: below about 60% of normal under load means something is holding it back.
    $busySamples = @($Samples | Where-Object { $null -ne $_.Cpu -and $_.Cpu -ge 40 -and $null -ne $_.Perf })
    if ($busySamples.Count -ge 3) {
        $perf = ($busySamples | Measure-Object -Property Perf -Average).Average
        $freq = ($busySamples | Measure-Object -Property FreqMHz -Average).Average
        $ghz  = if ($freq) { ' (about {0:N1} GHz of {1:N1} GHz)' -f ($freq * $perf / 100 / 1000), ($freq / 1000) } else { '' }
        $text = 'Ran at {0:N0}% of its normal speed while busy{1}' -f $perf, $ghz
        if ($perf -ge 60) { Add-Finding 'Power' 'CPU speed' 'PASS' "$text (over 100% is turbo)" }
        elseif ($OnBattery) { Add-Finding 'Power' 'CPU speed' 'INFO' "$text - expected on battery" 'Plugged in, it should be near or above 100%.' }
        else {
            Add-Finding 'Power' 'CPU speed' $(if ($perf -lt 40) { 'FAIL' } else { 'WARN' }) "$text - something is holding it back" `
                'Check the power settings below. If they are fine: a weak or non-original charger, or heat - dust in the fan or a blocked vent. Firmware updates (Build > OEM drivers + BIOS) can fix it too.'
        }
    }
    elseif (@($Samples | Where-Object { $null -ne $_.Perf }).Count) {
        # (No speed counter at all - some VMs - says nothing rather than something wrong.)
        Add-Finding 'Power' 'CPU speed' 'INFO' 'The CPU was not busy enough during the sample to judge its speed' 'Run it again while the slowness is happening.'
    }
}

Invoke-Check 'Power' {
    $active = [string](& powercfg.exe /getactivescheme 2>$null)
    $guid = if ($active -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $Matches[1].ToLower() } else { $null }
    $planName = if ($active -match '\(([^)]+)\)\s*$') { $Matches[1] } else { $guid }
    $byPolicy = $false
    try { $byPolicy = [bool](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings' -ErrorAction Stop).ActivePowerScheme } catch { $byPolicy = $false }
    if ($guid -eq $PowerSaver) {
        if ($byPolicy) { Add-Finding 'Power' 'Power plan' 'WARN' "$planName (set by policy)" 'Change the power policy in Intune or Group Policy; changing it here would be put back.' }
        else {
            Add-Finding 'Power' 'Power plan' 'WARN' $planName 'Power saver slows everything down. Switch to Balanced (-Fix offers this).'
            $apply = {
                & powercfg.exe /setactive SCHEME_BALANCED
                if ($LASTEXITCODE) { throw "powercfg exited $LASTEXITCODE" }
            }
            Add-FixOffer 'Power plan to Balanced' "Switch the power plan from $planName to Balanced?" $apply "powercfg /setactive $guid"
        }
    }
    elseif ($guid) { Add-Finding 'Power' 'Power plan' 'PASS' $(if ($byPolicy) { "$planName (set by policy)" } else { $planName }) }
}

Invoke-Check 'Power' {
    # Power mode (the Windows 11 / 10 slider), when Windows has one set.
    $pm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -ErrorAction SilentlyContinue
    if ($pm) {
        $ac = ([string]$pm.ActiveOverlayAcPowerScheme).ToLower()
        $dc = ([string]$pm.ActiveOverlayDcPowerScheme).ToLower()
        $nameOf = { param($g) if ($g -and $PowerModes.ContainsKey($g)) { $PowerModes[$g] } else { 'Balanced' } }
        if ($ac -or $dc) {
            $text = 'Plugged in: {0}; on battery: {1}' -f (& $nameOf $ac), (& $nameOf $dc)
            if ($ac -eq $Efficiency) { Add-Finding 'Power' 'Power mode' 'WARN' $text 'Best power efficiency even when plugged in. Settings > System > Power & battery > Power mode: Balanced.' }
            else { Add-Finding 'Power' 'Power mode' 'PASS' $text }
        }
    }
}

Invoke-Check 'Power' {
    # Maximum processor state: below 100% caps the CPU outright. The values are the last two hex
    # numbers in powercfg's output (plugged in, then battery); the labels are translated, they aren't.
    $q = @(& powercfg.exe /query SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 2>$null) -join "`n"
    $hex = @([regex]::Matches($q, '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToInt32($_.Value, 16) })
    if ($hex.Count -ge 2) {
        $acMax = $hex[$hex.Count - 2]; $dcMax = $hex[$hex.Count - 1]
        if ($acMax -lt 100) {
            Add-Finding 'Power' 'Max processor state' 'WARN' "$acMax% when plugged in" 'Something capped the CPU. Set it back to 100% (-Fix offers this), or Power Options > Change plan settings > Advanced > Processor power management.'
            $apply = {
                & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100
                if ($LASTEXITCODE) { throw "powercfg exited $LASTEXITCODE" }
                & powercfg.exe /setactive SCHEME_CURRENT
                if ($LASTEXITCODE) { throw "powercfg exited $LASTEXITCODE" }
            }
            Add-FixOffer 'Max processor state to 100%' "Set the maximum processor state back to 100% when plugged in (now $acMax%)?" $apply `
                "powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX $acMax; powercfg /setactive SCHEME_CURRENT"
        }
        else { Add-Finding 'Power' 'Max processor state' 'PASS' ('100% plugged in, {0}% on battery' -f $dcMax) }
    }
}

# ------------------------------------------------------------------------------------------------
#  Uptime and pending restart
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Uptime' {
    $boot = [datetime]$os.LastBootUpTime
    $up   = $now - $boot
    $fast = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled -eq 1
    $text = '{0}d {1}h since last boot ({2})' -f $up.Days, $up.Hours, $boot.ToString('yyyy-MM-dd HH:mm')
    $fastNote = if ($fast) { ' Fast Startup is on, so "Shut down" does not reset this - use Restart.' } else { '' }
    if ($up.TotalDays -gt 7) { Add-Finding 'Uptime' 'Uptime' 'WARN' $text ("Restart first: memory leaks and half-installed updates build up.$fastNote") }
    else { Add-Finding 'Uptime' 'Uptime' 'PASS' $text }

    $reasons = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')     { $reasons += 'component servicing' }
    $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) { $reasons += 'pending file renames' }
    if ($reasons) { Add-Finding 'Uptime' 'Pending restart' 'WARN' ('Waiting on {0}' -f ($reasons -join ', ')) 'Restart: updates keep working in the background until then.' }
    else { Add-Finding 'Uptime' 'Pending restart' 'PASS' 'None' }
}

# ------------------------------------------------------------------------------------------------
#  Stability: hangs and low memory
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Stability' {
    $hangs = Get-RecentEvent @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002; StartTime = $since }
    if ($hangs.Count) {
        $top = $hangs | Group-Object { if ($_.Properties -and $_.Properties.Count) { [string]$_.Properties[0].Value } else { 'unknown' } } |
            Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }
        $status = if ($hangs.Count -ge 3) { 'WARN' } else { 'INFO' }
        Add-Finding 'Stability' 'App hangs' $status ('{0} in {1} days: {2}' -f $hangs.Count, $Days, ($top -join ', ')) `
            $(if ($status -eq 'WARN') { 'If the top one is the app they mean: update or repair it (Office: Build > M365 Apps reset; Teams: Repair > Teams cache clear).' })
    }
    else { Add-Finding 'Stability' 'App hangs' 'PASS' "None in $Days days" }

    $low = Get-RecentEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004; StartTime = $since }
    if ($low.Count) {
        # "...consumed the most virtual memory: chrome.exe (1234) consumed 5678 bytes, ..."
        $users = @{}
        foreach ($ev in $low) {
            foreach ($m in [regex]::Matches([string]$ev.Message, '(?i)(\S+\.exe) \(\d+\) consumed (\d+) bytes')) {
                $exe = $m.Groups[1].Value; $b = [double]$m.Groups[2].Value
                if (-not $users.ContainsKey($exe) -or $users[$exe] -lt $b) { $users[$exe] = $b }
            }
        }
        $names = @($users.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { '{0} {1}' -f $_.Key, (Format-Size $_.Value) })
        $who = if ($names.Count) { ". Biggest users: $($names -join ', ')" } else { '' }
        $fix = if ($TotalGB -and $TotalGB -le 8) { "Only $TotalGB GB of RAM - add more, or keep fewer apps open." } else { 'The biggest user is probably leaking: update or reinstall it.' }
        Add-Finding 'Stability' 'Low memory' $(if ($low.Count -ge 3) { 'FAIL' } else { 'WARN' }) ('Windows ran low on memory {0} time(s) in {1} days{2}' -f $low.Count, $Days, $who) $fix
    }
    else { Add-Finding 'Stability' 'Low memory' 'PASS' "No low-memory warnings in $Days days" }
}

# ------------------------------------------------------------------------------------------------
#  Startup: boot times, what Windows says slowed it, and the startup apps
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Startup' {
    $log = 'Microsoft-Windows-Diagnostics-Performance/Operational'
    try {
        $boots = @(Get-RecentEvent @{ LogName = $log; Id = 100; StartTime = $now.AddDays(-30) } -Max 5)
        if ($boots.Count) {
            $d = Get-EventField $boots[0]
            $total = [double]$d['BootTime']; $main = [double]$d['MainPathBootTime']; $post = [double]$d['BootPostBootTime']
            $avg = (@($boots | ForEach-Object { [double](Get-EventField $_)['BootTime'] }) | Measure-Object -Average).Average
            $text = 'Last start-up {0} ({1} to the sign-in screen, {2} after signing in until it settled); average of last {3}: {4}' -f `
                (Format-Duration $total), (Format-Duration $main), (Format-Duration $post), $boots.Count, (Format-Duration $avg)
            if ($main -gt 60000 -or $total -gt 180000) { Add-Finding 'Startup' 'Start-up time' 'WARN' $text 'See what Windows says slowed it, and the startup apps, below.' }
            else { Add-Finding 'Startup' 'Start-up time' 'PASS' $text }
        }
        else { Add-Finding 'Startup' 'Start-up time' 'INFO' 'No start-up timing recorded in the last 30 days' }

        $slow = @(Get-RecentEvent @{ LogName = $log; Id = 101, 102, 103; StartTime = $since })
        if ($slow.Count) {
            $kinds = @{ 101 = 'app'; 102 = 'driver'; 103 = 'service' }
            $items = foreach ($ev in $slow) {
                $f = Get-EventField $ev
                $n = if ($f['FriendlyName']) { $f['FriendlyName'] } elseif ($f['Name']) { Split-Path $f['Name'] -Leaf } else { 'unknown' }
                $ms = if ($f['DegradationTime']) { [double]$f['DegradationTime'] } else { [double]$f['TotalTime'] }
                [pscustomobject]@{ Key = '{0} ({1})' -f $n, $kinds[[int]$ev.Id]; Ms = $ms }
            }
            $top = $items | Group-Object Key | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Count = $_.Count; MaxMs = ($_.Group | Measure-Object Ms -Maximum).Maximum }
            } | Sort-Object MaxMs -Descending | Select-Object -First 5
            $text = ($top | ForEach-Object { '{0} +{1}{2}' -f $_.Name, (Format-Duration $_.MaxMs), $(if ($_.Count -gt 1) { " x$($_.Count)" } else { '' }) }) -join ', '
            Add-Finding 'Startup' 'Slowing start-up' 'WARN' $text 'Apps: turn them off at startup (-Fix). Drivers: Build > OEM drivers + BIOS. Services: find out what installed them.'
        }
        else { Add-Finding 'Startup' 'Slowing start-up' 'PASS' "Windows flagged nothing in $Days days" }
    }
    catch {
        if (-not $IsElevated) { Add-Finding 'Startup' 'Start-up time' 'INFO' 'Run as admin to see start-up times' }
        else { throw }
    }
}

# Whose startup apps: the person signed in at the console, even when this runs elevated as a
# different admin account (their HKCU isn't ours). Falls back to the account running this.
function Get-TargetUser {
    $me = [pscustomobject]@{ Name = (Get-CurrentUserName); Root = 'Registry::HKEY_CURRENT_USER'; Classes = 'Registry::HKEY_CURRENT_USER\Software\Classes'; IsOther = $false; Note = $null }
    $other = Get-OtherSignedInUser
    if (-not $other) { return $me }
    if (-not $IsElevated) {
        $me.Note = "$other is signed in, but this isn't elevated, so these are $($me.Name)'s startup apps. Run as admin to see theirs."
        return $me
    }
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'")) {
        try {
            $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
            if (('{0}\{1}' -f $o.Domain, $o.User) -ne $other) { continue }
            $sid = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid
            if ($sid -and (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) {
                return [pscustomobject]@{ Name = $other; Root = "Registry::HKEY_USERS\$sid"; Classes = "Registry::HKEY_USERS\${sid}_Classes"; IsOther = $true; Note = $null }
            }
        }
        catch { Write-Verbose "Explorer owner: $($_.Exception.Message)" }
    }
    $me.Note = "$other is signed in, but their settings couldn't be found, so these are $($me.Name)'s startup apps."
    $me
}

function Get-RegistryValueMap {
    param([string] $Path)
    $map = [ordered]@{}
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item) {
        foreach ($p in $item.PSObject.Properties) {
            if ($p.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' -and $p.Name -ne '(default)') { $map[$p.Name] = $p.Value }
        }
    }
    $map
}

$StartupApps = New-Object System.Collections.Generic.List[object]
$TargetUser  = $null
Invoke-Check 'Startup' {
    $script:TargetUser = Get-TargetUser
    $u = $script:TargetUser
    $approvedUser = "$($u.Root)\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved"
    $approvedAll  = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

    $sources = @(
        @{ From = 'This user';             Kind = 'Run';    Path = "$($u.Root)\Software\Microsoft\Windows\CurrentVersion\Run"; Approved = "$approvedUser\Run"; Machine = $false }
        @{ From = 'All users';             Kind = 'Run';    Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = "$approvedAll\Run"; Machine = $true }
        @{ From = 'All users (32-bit)';    Kind = 'Run';    Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "$approvedAll\Run32"; Machine = $true }
    )
    $userStartup = $null
    try { $userStartup = (Get-ItemProperty -LiteralPath "$($u.Root)\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" -ErrorAction Stop).Startup } catch { $userStartup = $null }
    if ($userStartup) { $sources += @{ From = 'This user (Startup folder)'; Kind = 'Folder'; Path = $userStartup; Approved = "$approvedUser\StartupFolder"; Machine = $false } }
    $allStartup = if ($env:ProgramData) { Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp' } else { $null }
    if ($allStartup) { $sources += @{ From = 'All users (Startup folder)'; Kind = 'Folder'; Path = $allStartup; Approved = "$approvedAll\StartupFolder"; Machine = $true } }

    foreach ($src in $sources) {
        $entries = @()
        if ($src.Kind -eq 'Run') {
            $map = Get-RegistryValueMap $src.Path
            $entries = foreach ($k in $map.Keys) { [pscustomobject]@{ Name = $k; Value = $k; Command = [string]$map[$k] } }
        }
        elseif (Test-Path -LiteralPath $src.Path) {
            $entries = foreach ($f in @(Get-ChildItem -LiteralPath $src.Path -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
                $target = $f.FullName
                if ($f.Extension -eq '.lnk') {
                    try { $target = (New-Object -ComObject WScript.Shell).CreateShortcut($f.FullName).TargetPath } catch { $target = $f.FullName }
                }
                [pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension($f.Name); Value = $f.Name; Command = [string]$target }
            }
        }
        if (-not $entries) { continue }
        $approved = Get-RegistryValueMap $src.Approved
        foreach ($e in $entries) {
            # Task Manager's switch: 12 bytes, first byte even = on, odd = off. No entry = on.
            $flag = $approved[$e.Value]
            $on = -not ($flag -is [byte[]] -and $flag.Length -ge 1 -and ($flag[0] % 2) -eq 1)
            $keep = Get-KeepOnReason ('{0} {1}' -f $e.Name, $e.Command)
            $StartupApps.Add([pscustomobject]@{
                Name = $e.Name; From = $src.From; Command = $e.Command; On = $on; KeepOn = $keep
                ApprovedKey = $src.Approved; ValueName = $e.Value; NeedsAdmin = ($src.Machine -or $u.IsOther) -and -not $IsElevated
            })
        }
    }

    # Store apps (new Teams, Spotify, Phone Link...): listed, but changed in Settings > Apps > Startup.
    $appData = "$($u.Classes)\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData"
    if (Test-Path -LiteralPath $appData) {
        foreach ($pkg in @(Get-ChildItem -LiteralPath $appData -ErrorAction SilentlyContinue)) {
            foreach ($task in @(Get-ChildItem -LiteralPath $pkg.PSPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -notin 'Schemas', 'HAM' })) {
                $st = (Get-ItemProperty -LiteralPath $task.PSPath -ErrorAction SilentlyContinue).State
                if ($null -eq $st) { continue }
                $pkgName = ($pkg.PSChildName -split '_')[0]
                $StartupApps.Add([pscustomobject]@{
                    Name = ($pkgName -split '\.')[-1]; From = 'Store app'; Command = "$pkgName ($($task.PSChildName))"
                    On = ([int]$st -in 2, 4); KeepOn = $null; ApprovedKey = $null; ValueName = $null; NeedsAdmin = $false
                })
            }
        }
    }

    $onList  = @($StartupApps | Where-Object On)
    $offCount = $StartupApps.Count - $onList.Count
    $optional = @($onList | Where-Object { -not $_.KeepOn })
    $names = @($onList | ForEach-Object { $_.Name } | Select-Object -Unique)
    $more = if ($names.Count -gt 12) { " (+$($names.Count - 12) more)" } else { '' }
    $whose = if ($u.IsOther) { " for $($u.Name)" } else { '' }
    $text = '{0} on at sign-in{1}: {2}{3}; {4} turned off' -f $onList.Count, $whose, (($names | Select-Object -First 12) -join ', '), $more, $offCount
    if (-not $onList.Count) { $text = "Nothing starts at sign-in$whose; $offCount turned off" }
    if ($optional.Count -ge 8) { Add-Finding 'Startup' 'Startup apps' 'WARN' $text "$($optional.Count) of them are optional. Turn off what the user doesn't need at sign-in: -Fix, or Task Manager > Startup apps." }
    else { Add-Finding 'Startup' 'Startup apps' 'PASS' $text }
    if ($u.Note) { Add-Finding 'Startup' 'Whose apps' 'INFO' $u.Note }
}

# ------------------------------------------------------------------------------------------------
#  Drivers: BIOS and graphics
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Drivers' {
    $maker = [string]$inv.System.Manufacturer
    $oem = $maker -match 'Dell|HP|Hewlett|Lenovo'
    if ($inv.System.BIOSDate) {
        $biosDate = [datetime]$inv.System.BIOSDate
        $years = ($now - $biosDate).TotalDays / 365
        $text = 'BIOS {0} from {1}' -f $inv.System.BIOSVersion, $biosDate.ToString('yyyy-MM-dd')
        if ($years -gt 2) {
            $fix = if ($oem) { 'Firmware updates often fix heat, fan and battery problems. Build > OEM drivers + BIOS (with BIOS ticked).' } else { 'Check the manufacturer''s site for a newer BIOS.' }
            Add-Finding 'Drivers' 'BIOS age' 'WARN' ('{0} ({1:N0} years old)' -f $text, [math]::Floor($years)) $fix
        }
        else { Add-Finding 'Drivers' 'BIOS age' 'PASS' $text }
    }

    $gpus = @(Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.Name -notmatch 'Remote|Mirage|Hyper-V|Virtual|Citrix|Indirect|DisplayLink|Parsec' })
    foreach ($g in $gpus) {
        if ($g.Name -match 'Microsoft Basic Display') {
            Add-Finding 'Drivers' 'Graphics driver' 'FAIL' 'No graphics driver: Windows is drawing the screen in software' 'Install the graphics driver: Build > OEM drivers + BIOS, or the graphics maker''s site.'
            continue
        }
        if ($g.DriverDate) {
            $dd = [datetime]$g.DriverDate
            $text = '{0} driver {1} from {2}' -f $g.Name, $g.DriverVersion, $dd.ToString('yyyy-MM-dd')
            if (($now - $dd).TotalDays -gt 730) { Add-Finding 'Drivers' 'Graphics driver' 'WARN' "$text (over 2 years old)" 'Update it: Build > OEM drivers + BIOS, or the graphics maker''s site.' }
            else { Add-Finding 'Drivers' 'Graphics driver' 'PASS' $text }
        }
    }
}

# ================================================================================================
#  Report
# ================================================================================================
$rank = { param($f) $i = [array]::IndexOf($AreaOrder, $f.Area); if ($i -lt 0) { 99 } else { $i } }
$attention = @($Findings | Where-Object { $_.Status -in 'FAIL', 'WARN' } |
    Sort-Object @{ e = { if ($_.Status -eq 'FAIL') { 0 } else { 1 } } }, @{ e = { & $rank $_ } }, Order)
$fine  = @($Findings | Where-Object { $_.Status -in 'PASS', 'INFO' } | Sort-Object @{ e = { & $rank $_ } }, Order)
$fails = @($attention | Where-Object Status -eq 'FAIL').Count
$warns = $attention.Count - $fails

$sysI = $inv.System; $osI = $inv.OS; $cpuI = @($inv.CPU) | Select-Object -First 1
$headline = if ($sysI) {
    '{0} {1} | {2} | {3} GB RAM | {4} {5} ({6}) | user {7}' -f $sysI.Manufacturer, $sysI.Model, $(if ($cpuI) { $cpuI.Name } else { 'CPU unknown' }), $TotalGB,
        $osI.Edition, $osI.Version, $osI.Build, $(if ($sysI.LoggedOnUser) { $sysI.LoggedOnUser } else { 'none' })
} else { 'Device details unavailable' }

function Get-Summary {
    if ($attention.Count) {
        $names = @($attention | ForEach-Object { $_.Check } | Select-Object -Unique)
        $more  = if ($names.Count -gt 5) { " (+$($names.Count - 5) more)" } else { '' }
        '{0} performance check - {1} fail, {2} warn: {3}{4}' -f $env:COMPUTERNAME, $fails, $warns, (($names | Select-Object -First 5) -join ', '), $more
    } else { "$env:COMPUTERNAME performance check - no issues found" }
}
$summary = Get-Summary

if ($Quiet) {
    Write-Output $summary
}
else {
    Write-Host ''
    Write-Host ("== Performance check - {0} - {1} " -f $env:COMPUTERNAME, $now.ToString('yyyy-MM-dd HH:mm')).PadRight(78, '=') -ForegroundColor Cyan
    Write-Host "   $headline" -ForegroundColor Gray

    Write-Host ''
    if ($attention.Count) {
        Write-Host ("  NEEDS ATTENTION ({0})" -f $attention.Count) -ForegroundColor $(if ($fails) { 'Red' } else { 'Yellow' })
        foreach ($f in $attention) {
            $colour = if ($f.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
            Write-Host ('   [{0}] ' -f $f.Status) -ForegroundColor $colour -NoNewline
            Write-Host ('{0,-10} {1}: {2}' -f $f.Area, $f.Check, $f.Detail)
            if ($f.Fix) { Write-Host ('{0,20}-> {1}' -f '', $f.Fix) -ForegroundColor DarkGray }
        }
    }
    else { Write-Host '  NOTHING NEEDS ATTENTION' -ForegroundColor Green }

    Write-Host ''
    Write-Host ("  CHECKED AND FINE ({0})" -f $fine.Count) -ForegroundColor Green
    foreach ($f in $fine) { Write-Host ('   {0,-10} {1}: {2}' -f $f.Area, $f.Check, $f.Detail) -ForegroundColor DarkGray }

    $onApps = @($StartupApps | Where-Object On)
    if ($onApps.Count) {
        Write-Host ''
        Write-Host ("  STARTUP APPS ON ({0})" -f $onApps.Count) -ForegroundColor Cyan
        foreach ($a in $onApps) {
            $note = if ($a.KeepOn) { "  [leave on: $($a.KeepOn)]" } elseif (-not $a.ApprovedKey) { '  [change in Settings > Apps > Startup]' } else { '' }
            Write-Host ('   {0,-32} {1}{2}' -f $a.Name, $a.From, $note) -ForegroundColor $(if ($a.KeepOn) { 'DarkGray' } else { 'Gray' })
        }
    }

    Write-Host ''
    Write-Host "  Summary: $summary" -ForegroundColor Cyan
}

# ------------------------------------------------------------------------------------------------
#  -Fix: one question at a time, nothing changes without a yes
# ------------------------------------------------------------------------------------------------
if ($Fix) {
    $pickable = @($StartupApps | Where-Object { $_.On -and -not $_.KeepOn -and $_.ApprovedKey -and -not $_.NeedsAdmin })
    $adminOnly = @($StartupApps | Where-Object { $_.On -and -not $_.KeepOn -and $_.ApprovedKey -and $_.NeedsAdmin })
    Write-Host ''
    if (-not $FixOffers.Count -and -not $pickable.Count) {
        Write-Host '  FIXES: nothing here that -Fix can change.' -ForegroundColor Green
    }
    else {
        Write-Host '  FIXES - each one asks first; Enter or n skips it' -ForegroundColor Cyan
        foreach ($o in $FixOffers) {
            $ans = Read-Answer "  $($o.Question) [y/N]"
            if ($ans -notmatch '^\s*y') { Write-Host '   Skipped.' -ForegroundColor DarkGray; continue }
            try {
                & $o.Apply | Out-Null
                $Changes.Add([pscustomobject]@{ What = $o.Name; Result = 'Done'; Undo = $o.Undo })
                Write-Host "   Done. To undo: $($o.Undo)" -ForegroundColor Green
            }
            catch {
                $Changes.Add([pscustomobject]@{ What = $o.Name; Result = "Failed: $($_.Exception.Message)"; Undo = $null })
                Write-Host "   Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        if ($pickable.Count) {
            Write-Host ''
            Write-Host '  Startup apps that can be turned off (security, remote support, VPN, drivers and OneDrive are never offered):' -ForegroundColor Cyan
            for ($i = 0; $i -lt $pickable.Count; $i++) {
                Write-Host ('   {0,2}. {1,-32} {2}' -f ($i + 1), $pickable[$i].Name, $pickable[$i].From)
            }
            $ans = Read-Answer '  Numbers to turn off, e.g. 1,3 (Enter for none)'
            $nums = @(foreach ($tok in ($ans -split '[,\s]+' | Where-Object { $_ })) {
                $n = 0
                if ([int]::TryParse($tok, [ref]$n) -and $n -ge 1 -and $n -le $pickable.Count) { $n }
            }) | Select-Object -Unique
            $picked = @($nums | ForEach-Object { $pickable[$_ - 1] })
            if ($picked.Count) {
                $ok = Read-Answer ('  Turn off {0} at sign-in: {1}? [y/N]' -f $picked.Count, (($picked | ForEach-Object { $_.Name }) -join ', '))
                if ($ok -match '^\s*y') {
                    foreach ($a in $picked) {
                        try {
                            if (-not (Test-Path -LiteralPath $a.ApprovedKey)) { New-Item -Path $a.ApprovedKey -Force | Out-Null }
                            # Exactly what Task Manager writes: 03 00 00 00, then when it was turned off.
                            $bytes = [byte[]](@([byte]3, [byte]0, [byte]0, [byte]0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()))
                            New-ItemProperty -LiteralPath $a.ApprovedKey -Name $a.ValueName -PropertyType Binary -Value $bytes -Force | Out-Null
                            $a.On = $false
                            $undo = "Task Manager > Startup apps > $($a.Name) > Enable"
                            if ($TargetUser -and $TargetUser.IsOther -and $a.From -like 'This user*') { $undo += " (signed in as $($TargetUser.Name))" }
                            $Changes.Add([pscustomobject]@{ What = "Startup app off: $($a.Name) ($($a.From))"; Result = 'Done'; Undo = $undo })
                            Write-Host "   $($a.Name): off" -ForegroundColor Green
                        }
                        catch {
                            $Changes.Add([pscustomobject]@{ What = "Startup app off: $($a.Name)"; Result = "Failed: $($_.Exception.Message)"; Undo = $null })
                            Write-Host "   $($a.Name): failed - $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }
                }
                else { Write-Host '   Left as they are.' -ForegroundColor DarkGray }
            }
        }
        if ($adminOnly.Count) {
            Write-Host ("   {0} more can only be turned off from an admin session: {1}" -f $adminOnly.Count, (($adminOnly | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor DarkGray
        }
    }
    if ($Changes.Count) {
        Write-Host ''
        Write-Host ("  CHANGES MADE ({0})" -f @($Changes | Where-Object Result -eq 'Done').Count) -ForegroundColor Cyan
        foreach ($c in $Changes) { Write-Host ('   {0}: {1}{2}' -f $c.What, $c.Result, $(if ($c.Undo) { " - undo: $($c.Undo)" } else { '' })) }
        Write-Host '   Nothing restarts by itself. Startup app changes apply at the next sign-in.' -ForegroundColor DarkGray
    }
}

if ($Html) {
    if (-not (Test-Path -LiteralPath $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
    $file = Join-Path $ReportFolder ('Performance_{0}_{1:yyyyMMdd-HHmm}.html' -f $env:COMPUTERNAME, $now)
    $enc  = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $rows = {
        param($list, [switch]$WithFix)
        foreach ($f in $list) {
            $fx = if ($WithFix -and $f.Fix) { "<div class=""fix"">&rarr; $(& $enc $f.Fix)</div>" } else { '' }
            "<tr class=""$($f.Status.ToLower())""><td class=""st"">$($f.Status)</td><td>$(& $enc $f.Area)</td><td>$(& $enc $f.Check)</td><td>$(& $enc $f.Detail)$fx</td></tr>"
        }
    }
    $attHtml  = if ($attention.Count) { "<table>$((& $rows $attention -WithFix) -join '')</table>" } else { '<p class="ok">Nothing needs attention.</p>' }
    $fineHtml = "<table>$((& $rows $fine) -join '')</table>"
    $appHtml  = if ($StartupApps.Count) {
        $r = foreach ($a in ($StartupApps | Sort-Object @{ e = { -not $_.On } }, From, Name)) {
            $st = if ($a.On) { 'On' } else { 'Off' }
            $note = if ($a.KeepOn) { & $enc "leave on: $($a.KeepOn)" } elseif (-not $a.ApprovedKey) { 'Change in Settings &gt; Apps &gt; Startup' } else { '' }
            "<tr class=""$(if ($a.On) { 'pass' } else { 'info' })""><td class=""st"">$st</td><td>$(& $enc $a.Name)</td><td>$(& $enc $a.From)</td><td><span class=""cmd"">$(& $enc $a.Command)</span><div class=""fix"">$note</div></td></tr>"
        }
        "<h2>Startup apps ($(@($StartupApps | Where-Object On).Count) on)</h2><table>$($r -join '')</table>"
    } else { '' }
    $chgHtml = if ($Changes.Count) {
        $r = foreach ($c in $Changes) { "<tr><td>$(& $enc $c.What)</td><td>$(& $enc $c.Result)</td><td>$(& $enc $c.Undo)</td></tr>" }
        "<h2>Changes made</h2><table><tr><th>Change</th><th>Result</th><th>To undo</th></tr>$($r -join '')</table><p class=""fix"">Nothing restarted. Startup app changes apply at the next sign-in.</p>"
    } else { '' }
    $page = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Performance check - $env:COMPUTERNAME</title>
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; max-width: 1100px; }
 h1 { font-size: 20px; margin-bottom: 2px; } .sub { color: #656d76; margin-bottom: 14px; }
 h2 { font-size: 15px; margin: 20px 0 6px; border-bottom: 2px solid #0969da; padding-bottom: 3px; }
 .summary { background: #f6f8fa; border: 1px solid #d0d7de; padding: 8px 12px; font-family: Consolas, monospace; font-size: 13px; }
 table { border-collapse: collapse; font-size: 13px; width: 100%; }
 td, th { border-bottom: 1px solid #d0d7de; padding: 5px 8px; vertical-align: top; text-align: left; }
 td.st { font-weight: 600; width: 44px; } tr.fail td.st { color: #cf222e; } tr.warn td.st { color: #9a6700; }
 tr.pass td.st { color: #1a7f37; } tr.info td.st { color: #656d76; }
 .fix { color: #656d76; margin-top: 3px; } .ok { color: #1a7f37; font-weight: 600; }
 .cmd { font-family: Consolas, monospace; font-size: 12px; word-break: break-all; }
</style></head><body>
<h1>Performance check - $env:COMPUTERNAME</h1>
<div class="sub">$(& $enc $headline) &middot; $($now.ToString('yyyy-MM-dd HH:mm')) &middot; measured for $Seconds seconds</div>
<div class="summary">$(& $enc $summary)</div>
<h2>Needs attention ($($attention.Count))</h2>$attHtml
$chgHtml
<h2>Checked and fine ($($fine.Count))</h2>$fineHtml
$appHtml
</body></html>
"@
    $page | Set-Content -LiteralPath $file -Encoding UTF8
    if (-not $Quiet) { Write-Host "  Report:  $file" -ForegroundColor Cyan }
    if (-not $NoOpen -and [Environment]::UserInteractive -and -not $PSSenderInfo) {
        try { Invoke-Item -LiteralPath $file } catch { Write-Verbose 'Could not open the report' }
    }
}

# .ToArray(), not @(): PowerShell 7.5 throws "Argument types do not match" on @(List) inside an object literal.
if ($PassThru) {
    [pscustomobject]@{
        Summary = $summary; Device = $inv; Measured = $Measured; Findings = $Findings.ToArray()
        TopCpu = $TopCpu; TopMemory = $TopMem; TopDisk = $TopIO
        StartupApps = $StartupApps.ToArray(); Changes = $Changes.ToArray()
    }
}
if ($fails) { exit 1 }
exit 0
