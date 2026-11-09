<#
.SYNOPSIS
    The first five minutes of any ticket, in one go: what the machine is, what's wrong with it,
    and what's fine - problems first, on one page.

.DESCRIPTION
    Runs the checks you'd otherwise do by hand at the start of every ticket and puts anything that
    needs attention at the top, each with a suggested next step:

      Device       make, model, serial, OS build, logged-on user           (Get-DeviceInventory)
      Uptime       days since boot, and whether Fast Startup is hiding it
      Reboot       pending reboot from Windows Update, servicing, file renames or a rename
      Disk         system drive free space, physical disk health and wear  (Get-DeviceInventory)
      Battery      wear                                                    (Get-DeviceInventory)
      Entra/Intune join, SSO token, enrolment, check-in, certificates      (Get-EntraIntuneHealth)
      Stability    blue screens, unexpected shutdowns and app crashes over the last few days
      Updates      when the last update was installed
      Security     antivirus registered with Security Center, Defender state and signature age
      Resources    memory in use, CPU load, top processes by memory
      Network      default gateway and DNS

    Read-only. Works unelevated; elevated adds disk wear, BitLocker and a few Entra/Intune details.
    The inventory and Entra/Intune checks come from the toolkit's own tools, so improving those
    improves this too.

.PARAMETER Html
    Also write a one-page HTML report (and open it, when run locally and interactively).

.PARAMETER ReportFolder
    Where -Html and -Reports write. Default C:\Triage (created if missing).

.PARAMETER Days
    Look-back for crashes and shutdowns. Default 7.

.PARAMETER SkipNetwork
    Skip the gateway, DNS and Entra/Intune endpoint checks.

.PARAMETER Reports
    Also save Windows' own Wi-Fi report (netsh wlan show wlanreport: connections, drops and
    errors over the last few days) and battery report (powercfg /batteryreport: capacity history
    and charge cycles) to ReportFolder, linked from the HTML page. The battery report is skipped on
    machines without a battery; the Wi-Fi report needs an admin session and a Wi-Fi adapter.

.PARAMETER NoOpen
    Don't open the HTML report after writing it.

.PARAMETER Quiet
    Print only the one-line summary (for RMM monitors).

.PARAMETER PassThru
    Emit the findings and device details to the pipeline.

.EXAMPLE
    .\Invoke-QuickTriage.ps1

.EXAMPLE
    .\Invoke-QuickTriage.ps1 -Html

.EXAMPLE
    .\Invoke-QuickTriage.ps1 -Html -Reports
    (From an elevated session to get the Wi-Fi report as well as the battery report.)

.EXAMPLE
    Invoke-Command -ComputerName PC-1234 -FilePath .\Invoke-QuickTriage.ps1
    (Remote runs need the whole toolkit on the target, as this calls its sibling tools.)

.NOTES
    Exit codes: 0 = nothing failed, 1 = at least one FAIL.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Html,
    [string] $ReportFolder = (Join-Path $env:SystemDrive 'Triage'),
    [ValidateRange(1, 30)] [int] $Days = 7,
    [switch] $SkipNetwork,
    [switch] $Reports,
    [switch] $NoOpen,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$ToolsRoot = Split-Path $PSScriptRoot -Parent
$now   = Get-Date
$since = $now.AddDays(-$Days)

$Findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param(
        [string] $Area, [string] $Check,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')] [string] $Status,
        [string] $Detail, [string] $Fix
    )
    $Findings.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix; Order = $Findings.Count })
}

# What to look at first when several things are wrong: hardware and crashes before housekeeping.
$AreaOrder = @('Disk', 'Stability', 'Security', 'Reboot', 'Uptime', 'Updates', 'Entra/Intune', 'Network', 'Resources', 'Battery', 'Device')

function Invoke-Check {
    # One broken check records a note and moves on; it never sinks the triage.
    param([string] $Area, [scriptblock] $Body)
    try { & $Body }
    catch { Add-Finding $Area 'Check failed' 'INFO' "Couldn't run: $($_.Exception.Message)" }
}

function Get-RecentEvent {
    param([hashtable] $Filter)
    try { @(Get-WinEvent -FilterHashtable $Filter -MaxEvents 500 -ErrorAction Stop) }
    catch {
        if ($_.Exception.Message -match 'No events were found') { @() }
        else { throw }
    }
}

if (-not $Quiet) { Write-Host "Triaging $env:COMPUTERNAME - takes 10-30 seconds..." -ForegroundColor DarkGray }

# ------------------------------------------------------------------------------------------------
#  Device (inventory tool)
# ------------------------------------------------------------------------------------------------
$inv = $null
Invoke-Check 'Device' {
    $script:inv = & (Join-Path $ToolsRoot 'DeviceInventory\Get-DeviceInventory.ps1') -Quiet -PassThru
}

# ------------------------------------------------------------------------------------------------
#  Uptime and pending reboot
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Uptime' {
    $os   = Get-CimInstance -ClassName Win32_OperatingSystem
    $boot = [datetime]$os.LastBootUpTime
    $up   = $now - $boot
    $fast = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled -eq 1
    $text = '{0}d {1}h since last boot ({2})' -f $up.Days, $up.Hours, $boot.ToString('yyyy-MM-dd HH:mm')
    $fastNote = if ($fast) { ' Fast Startup is on, so "Shut down" does not reset this - use Restart.' } else { '' }
    if ($up.TotalDays -gt 14)    { Add-Finding 'Uptime' 'Uptime' 'WARN' $text ("Restart before digging further: long uptimes cause half the weird stuff.$fastNote") }
    elseif ($up.TotalDays -gt 7) { Add-Finding 'Uptime' 'Uptime' 'WARN' $text ("Worth a restart.$fastNote") }
    else                         { Add-Finding 'Uptime' 'Uptime' 'PASS' $text }
}

Invoke-Check 'Reboot' {
    $reasons = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')     { $reasons += 'component servicing' }
    $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) { $reasons += 'pending file renames' }
    $active  = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
    $pending = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $pending -and $active -ne $pending) { $reasons += "computer rename to $pending" }
    if ($reasons) { Add-Finding 'Reboot' 'Pending reboot' 'WARN' ("Waiting on {0}" -f ($reasons -join ', ')) 'Restart first - updates and installs stay half-applied until then.' }
    else          { Add-Finding 'Reboot' 'Pending reboot' 'PASS' 'None' }
}

# ------------------------------------------------------------------------------------------------
#  Disk and battery
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Disk' {
    $sys = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f $env:SystemDrive)
    if ($sys -and $sys.Size) {
        $freeGB = [math]::Round($sys.FreeSpace / 1GB, 1)
        $pct    = [int][math]::Round(100 * $sys.FreeSpace / $sys.Size)
        $text   = '{0} has {1} GB free ({2}%)' -f $env:SystemDrive, $freeGB, $pct
        $fix    = 'Run Diagnose > Disk usage report to see where it went.'
        if ($freeGB -lt 5 -or $pct -lt 5)       { Add-Finding 'Disk' 'Free space' 'FAIL' $text "Critically low. $fix" }
        elseif ($freeGB -lt 20 -or $pct -lt 10) { Add-Finding 'Disk' 'Free space' 'WARN' $text "Low - feature updates need 20 GB+. $fix" }
        else                                    { Add-Finding 'Disk' 'Free space' 'PASS' $text }
    }
    foreach ($d in @($inv.Disks | Where-Object { $_ })) {
        $name = '{0} ({1})' -f $d.Model, $d.Size
        if ($d.Health -and $d.Health -notin 'Healthy', 'OK') {
            Add-Finding 'Disk' 'Disk health' 'FAIL' "$name reports $($d.Health)" 'Back up the user''s data now and replace the drive.'
        }
        elseif ($null -ne $d.WearPercent -and [int]$d.WearPercent -ge 80) {
            Add-Finding 'Disk' 'Disk wear' 'WARN' "$name is $($d.WearPercent)% through its rated life" 'Plan a replacement.'
        }
        else {
            $wear = if ($null -ne $d.WearPercent) { ", $($d.WearPercent)% wear" } else { '' }
            Add-Finding 'Disk' 'Disk health' 'PASS' "$name healthy$wear"
        }
    }
}

Invoke-Check 'Battery' {
    $b = $inv.Battery
    if ($b -and $b.HealthPercent) {
        $text = 'Holds {0}% of its design capacity' -f $b.HealthPercent
        if ([int]$b.HealthPercent -lt 60) { Add-Finding 'Battery' 'Battery wear' 'WARN' $text 'Worn - if they''re complaining about battery life, that''s why. Replacement time.' }
        else { Add-Finding 'Battery' 'Battery wear' 'PASS' $text }
    }
}

# ------------------------------------------------------------------------------------------------
#  Entra / Intune (health tool)
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Entra/Intune' {
    $args2 = @{ Quiet = $true; PassThru = $true }
    if ($SkipNetwork) { $args2.SkipNetwork = $true }
    $results = @(& (Join-Path $ToolsRoot 'EntraIntuneHealth\Get-EntraIntuneHealth.ps1') @args2 |
        Where-Object { $_ -isnot [string] -and $_.Status })
    $passes = @($results | Where-Object Status -eq 'PASS')
    foreach ($r in ($results | Where-Object { $_.Status -in 'WARN', 'FAIL' -and $_.Area -ne 'Network' })) {
        Add-Finding 'Entra/Intune' $r.Check $r.Status $r.Detail $r.Fix
    }
    # One line for all unreachable endpoints rather than one per host.
    $down = @($results | Where-Object { $_.Area -eq 'Network' -and $_.Status -eq 'FAIL' })
    if ($down.Count) {
        Add-Finding 'Entra/Intune' 'Endpoints' 'FAIL' ('Not reachable on 443: {0}' -f (($down.Check) -join ', ')) $down[0].Fix
    }
    $join = $results | Where-Object Check -eq 'Join type' | Select-Object -First 1
    $summary = '{0} check(s) passed' -f $passes.Count
    if ($join -and $join.Status -eq 'PASS') { $summary = "$($join.Detail); $summary" }
    Add-Finding 'Entra/Intune' 'Health check' 'PASS' $summary
}

# ------------------------------------------------------------------------------------------------
#  Stability
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Stability' {
    $bsod = Get-RecentEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }
    $dirty = Get-RecentEvent @{ LogName = 'System'; Id = 41, 6008; StartTime = $since }
    if ($bsod.Count) {
        $last = ($bsod | Sort-Object TimeCreated -Descending | Select-Object -First 1)
        $code = if ($last.Message -match '(0x[0-9a-fA-F]{8})') { " (bugcheck $($Matches[1]))" } else { '' }
        Add-Finding 'Stability' 'Blue screens' 'FAIL' ('{0} in {1} days, last {2}{3}' -f $bsod.Count, $Days, $last.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $code) `
            'Check drivers updated recently (Event triage > Crashes), and C:\Windows\Minidump.'
    }
    else { Add-Finding 'Stability' 'Blue screens' 'PASS' "None in $Days days" }

    if ($dirty.Count) {
        Add-Finding 'Stability' 'Unexpected shutdowns' 'WARN' ('{0} in {1} days (power loss, hard power-off or a hang)' -f $dirty.Count, $Days) `
            'Ask if they''re holding the power button. If not: power supply, battery or overheating.'
    }
    else { Add-Finding 'Stability' 'Unexpected shutdowns' 'PASS' "None in $Days days" }

    $crashes = Get-RecentEvent @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since }
    if ($crashes.Count) {
        $top = $crashes | Group-Object { if ($_.Properties -and $_.Properties.Count) { [string]$_.Properties[0].Value } else { 'unknown' } } |
            Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }
        $status = if ($crashes.Count -ge 10) { 'WARN' } else { 'INFO' }
        Add-Finding 'Stability' 'App crashes' $status ('{0} in {1} days: {2}' -f $crashes.Count, $Days, ($top -join ', ')) `
            $(if ($status -eq 'WARN') { 'If the top one is the app they''re calling about: repair/reinstall it, or reset the Office/Teams cache.' })
    }
    else { Add-Finding 'Stability' 'App crashes' 'PASS' "None in $Days days" }
}

# ------------------------------------------------------------------------------------------------
#  Updates
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Updates' {
    $latest = @(Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending) | Select-Object -First 1
    if (-not $latest) { Add-Finding 'Updates' 'Last update' 'INFO' 'No install dates recorded' }
    else {
        $age  = [int]($now - [datetime]$latest.InstalledOn).TotalDays
        $text = 'Installed {0} days ago ({1}, {2})' -f $age, ([datetime]$latest.InstalledOn).ToString('yyyy-MM-dd'), $latest.HotFixID
        if ($age -gt 60)     { Add-Finding 'Updates' 'Last update' 'FAIL' $text 'Over two months behind. Run Repair > Windows Update reset, then check update policy in Intune.' }
        elseif ($age -gt 40) { Add-Finding 'Updates' 'Last update' 'WARN' $text 'Missed at least one Patch Tuesday. Check Settings > Windows Update for errors.' }
        else                 { Add-Finding 'Updates' 'Last update' 'PASS' $text }
    }
}

# ------------------------------------------------------------------------------------------------
#  Security
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Security' {
    # Security Center only exists on client Windows; servers skip straight to Defender.
    $avs = @()
    try { $avs = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop) } catch { $avs = @() }
    # productState is a bit field: middle byte 10/11 = on, last byte 00 = definitions up to date.
    $states = foreach ($av in $avs) {
        $hex = '{0:X6}' -f [int]$av.productState
        [pscustomobject]@{ Name = $av.displayName; On = $hex.Substring(2, 2) -in '10', '11'; UpToDate = $hex.Substring(4, 2) -eq '00' }
    }
    $anyOn = @($states | Where-Object On).Count -gt 0
    foreach ($a in $states) {
        if (-not $a.On) {
            # Defender reports "off" whenever a third-party AV is primary - only worth a mention, not a warning.
            if ($anyOn) { Add-Finding 'Security' 'Antivirus' 'INFO' "$($a.Name): off (another antivirus is active)" }
        }
        elseif (-not $a.UpToDate) { Add-Finding 'Security' 'Antivirus' 'WARN' "$($a.Name) is on but out of date" 'Force a definition update and check it can reach its update server.' }
        else { Add-Finding 'Security' 'Antivirus' 'PASS' "$($a.Name): on, up to date" }
    }
    if ($states -and -not $anyOn) {
        Add-Finding 'Security' 'Antivirus' 'FAIL' ('No antivirus is switched on ({0} registered)' -f (($states.Name) -join ', ')) 'Find out why before anything else.'
    }

    if (Get-Command -Name Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            if ($mp.AMRunningMode -match 'Passive') { Add-Finding 'Security' 'Defender' 'INFO' 'Passive mode (another antivirus is primary)' }
            elseif (-not $mp.RealTimeProtectionEnabled) { Add-Finding 'Security' 'Defender' 'FAIL' 'Real-time protection is OFF' 'Turn it back on and find out what turned it off (tamper protection should stop this).' }
            elseif ($mp.AntivirusSignatureAge -gt 3) { Add-Finding 'Security' 'Defender' 'WARN' "Signatures are $($mp.AntivirusSignatureAge) days old" 'Update-MpSignature, then check the device can reach Microsoft Update.' }
            else { Add-Finding 'Security' 'Defender' 'PASS' ('Real-time on, signatures {0} day(s) old' -f $mp.AntivirusSignatureAge) }
        }
        catch { Add-Finding 'Security' 'Defender' 'INFO' "Status unavailable ($($_.Exception.Message))" }
    }
}

# ------------------------------------------------------------------------------------------------
#  Resources
# ------------------------------------------------------------------------------------------------
Invoke-Check 'Resources' {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $usedPct = [int][math]::Round(100 * (1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)))
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB)
    $top = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
        ForEach-Object { if ($_.WorkingSet64 -ge 1GB) { '{0} {1:N1} GB' -f $_.ProcessName, ($_.WorkingSet64 / 1GB) } else { '{0} {1:N0} MB' -f $_.ProcessName, ($_.WorkingSet64 / 1MB) } }
    $text = '{0}% of {1} GB in use. Top: {2}' -f $usedPct, $totalGB, ($top -join ', ')
    if ($usedPct -ge 90)   { Add-Finding 'Resources' 'Memory' 'WARN' $text $(if ($totalGB -le 8) { "Only $totalGB GB - this machine needs more RAM for modern Office + Teams + a browser." } else { 'Close or restart the top process; check it for a leak. Diagnose > Performance check measures it properly.' }) }
    else                   { Add-Finding 'Resources' 'Memory' 'PASS' $text }

    $load = (@(Get-CimInstance -ClassName Win32_Processor) | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -ne $load) {
        if ($load -ge 90) { Add-Finding 'Resources' 'CPU' 'WARN' ('{0:N0}% load right now' -f $load) 'Run Diagnose > Performance check to see which app (often an update, an AV scan or Teams).' }
        else { Add-Finding 'Resources' 'CPU' 'PASS' ('{0:N0}% load right now' -f $load) }
    }
}

# ------------------------------------------------------------------------------------------------
#  Network
# ------------------------------------------------------------------------------------------------
if (-not $SkipNetwork) {
    Invoke-Check 'Network' {
        $gw = @($inv.Network | ForEach-Object { ($_.Gateway -split ',\s*') } | Where-Object { $_ }) | Select-Object -First 1
        if (-not $gw) { Add-Finding 'Network' 'Gateway' 'FAIL' 'No default gateway on any adapter' 'Not on a network at all: check Wi-Fi / cable / VPN.' }
        elseif (Test-Connection -ComputerName $gw -Count 1 -Quiet) { Add-Finding 'Network' 'Gateway' 'PASS' "$gw answers" }
        else { Add-Finding 'Network' 'Gateway' 'WARN' "$gw doesn't answer ping" 'Some routers ignore ping; if browsing also fails, check the local network.' }

        try {
            $ips = [Net.Dns]::GetHostAddresses('login.microsoftonline.com')
            Add-Finding 'Network' 'DNS' 'PASS' ('Resolves login.microsoftonline.com ({0} address(es))' -f @($ips).Count)
        }
        catch {
            $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            Add-Finding 'Network' 'DNS' 'FAIL' "Can't resolve login.microsoftonline.com ($msg)" 'Check the DNS servers on the adapter (ipconfig /all), then ipconfig /flushdns.'
        }
    }
}

# ------------------------------------------------------------------------------------------------
#  Optional: Windows' own Wi-Fi and battery reports (-Reports)
# ------------------------------------------------------------------------------------------------
$ExtraReports = New-Object System.Collections.Generic.List[object]
function Add-ExtraReport { param([string] $Name, [string] $Path, [string] $Note)
    $ExtraReports.Add([pscustomobject]@{ Name = $Name; Path = $Path; Note = $Note }) }

if ($Reports) {
    if (-not $Quiet) { Write-Host 'Saving the Wi-Fi and battery reports...' -ForegroundColor DarkGray }
    if (-not (Test-Path -LiteralPath $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
    $tag = '{0}_{1:yyyyMMdd-HHmm}.html' -f $env:COMPUTERNAME, $now

    try {
        if (@(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop).Count) {
            $file = Join-Path $ReportFolder "Battery_$tag"
            & powercfg.exe /batteryreport /output $file | Out-Null
            if (Test-Path -LiteralPath $file) { Add-ExtraReport 'Battery report' $file 'Capacity history, charge cycles and battery life estimates' }
            else { Add-ExtraReport 'Battery report' $null 'powercfg didn''t produce a report' }
        }
        else { Add-ExtraReport 'Battery report' $null 'No battery - skipped' }
    }
    catch { Add-ExtraReport 'Battery report' $null "Couldn't run: $($_.Exception.Message)" }

    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not (Get-Service -Name WlanSvc -ErrorAction SilentlyContinue)) { Add-ExtraReport 'Wi-Fi report' $null 'No Wi-Fi on this machine - skipped' }
        elseif (-not $isAdmin) { Add-ExtraReport 'Wi-Fi report' $null 'Needs an admin session - run Quick triage elevated with -Reports to get it' }
        else {
            & netsh.exe wlan show wlanreport | Out-Null
            $src = Join-Path $env:ProgramData 'Microsoft\Windows\WlanReport\wlan-report-latest.html'
            if (Test-Path -LiteralPath $src) {
                $file = Join-Path $ReportFolder "WiFi_$tag"
                Copy-Item -LiteralPath $src -Destination $file -Force
                Add-ExtraReport 'Wi-Fi report' $file 'Connections, disconnects and errors over the last few days'
            }
            else { Add-ExtraReport 'Wi-Fi report' $null 'netsh didn''t produce a report' }
        }
    }
    catch { Add-ExtraReport 'Wi-Fi report' $null "Couldn't run: $($_.Exception.Message)" }
}

# ================================================================================================
#  Report
# ================================================================================================
$rank = { param($f) $i = [array]::IndexOf($AreaOrder, $f.Area); if ($i -lt 0) { 99 } else { $i } }
$attention = @($Findings | Where-Object { $_.Status -in 'FAIL', 'WARN' } |
    Sort-Object @{ e = { if ($_.Status -eq 'FAIL') { 0 } else { 1 } } }, @{ e = { & $rank $_ } }, Order)
$fine      = @($Findings | Where-Object { $_.Status -in 'PASS', 'INFO' } | Sort-Object @{ e = { & $rank $_ } }, Order)
$fails     = @($attention | Where-Object Status -eq 'FAIL').Count
$warns     = $attention.Count - $fails

$sys = $inv.System; $osI = $inv.OS
$headline = if ($sys) {
    '{0} {1} | serial {2} | {3} {4} ({5}) | user {6}' -f $sys.Manufacturer, $sys.Model, $sys.SerialNumber, $osI.Edition, $osI.Version, $osI.Build,
        $(if ($sys.LoggedOnUser) { $sys.LoggedOnUser } else { 'none' })
} else { 'Device details unavailable' }

# One line you can paste into a ticket: the headline problems by name, worst first.
$summary = if ($attention.Count) {
    $names = @($attention | ForEach-Object { $_.Check } | Select-Object -Unique)
    $more  = if ($names.Count -gt 5) { " (+$($names.Count - 5) more)" } else { '' }
    '{0} quick triage - {1} fail, {2} warn: {3}{4}' -f $env:COMPUTERNAME, $fails, $warns, (($names | Select-Object -First 5) -join ', '), $more
} else { "$env:COMPUTERNAME quick triage - no issues found" }

if ($Quiet) {
    Write-Output $summary
}
else {
    Write-Host ''
    Write-Host ("== Quick triage - {0} - {1} " -f $env:COMPUTERNAME, $now.ToString('yyyy-MM-dd HH:mm')).PadRight(78, '=') -ForegroundColor Cyan
    Write-Host "   $headline" -ForegroundColor Gray

    Write-Host ''
    if ($attention.Count) {
        Write-Host ("  NEEDS ATTENTION ({0})" -f $attention.Count) -ForegroundColor $(if ($fails) { 'Red' } else { 'Yellow' })
        foreach ($f in $attention) {
            $colour = if ($f.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
            Write-Host ('   [{0}] ' -f $f.Status) -ForegroundColor $colour -NoNewline
            Write-Host ('{0,-13} {1}: {2}' -f $f.Area, $f.Check, $f.Detail)
            if ($f.Fix) { Write-Host ('{0,23}-> {1}' -f '', $f.Fix) -ForegroundColor DarkGray }
        }
    }
    else { Write-Host '  NOTHING NEEDS ATTENTION' -ForegroundColor Green }

    Write-Host ''
    Write-Host ("  CHECKED AND FINE ({0})" -f $fine.Count) -ForegroundColor Green
    foreach ($f in $fine) { Write-Host ('   {0,-13} {1}: {2}' -f $f.Area, $f.Check, $f.Detail) -ForegroundColor DarkGray }

    if ($ExtraReports.Count) {
        Write-Host ''
        Write-Host '  REPORTS' -ForegroundColor Cyan
        foreach ($r in $ExtraReports) {
            if ($r.Path) { Write-Host ('   {0,-15} {1}' -f $r.Name, $r.Path) }
            else { Write-Host ('   {0,-15} {1}' -f $r.Name, $r.Note) -ForegroundColor DarkGray }
        }
    }

    Write-Host ''
    Write-Host "  Summary: $summary" -ForegroundColor Cyan
}

if ($Html) {
    if (-not (Test-Path -LiteralPath $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
    $file = Join-Path $ReportFolder ('Triage_{0}_{1:yyyyMMdd-HHmm}.html' -f $env:COMPUTERNAME, $now)
    $enc  = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $rows = {
        param($list, [switch]$WithFix)
        foreach ($f in $list) {
            $fix = if ($WithFix -and $f.Fix) { "<div class=""fix"">&rarr; $(& $enc $f.Fix)</div>" } else { '' }
            "<tr class=""$($f.Status.ToLower())""><td class=""st"">$($f.Status)</td><td>$(& $enc $f.Area)</td><td>$(& $enc $f.Check)</td><td>$(& $enc $f.Detail)$fix</td></tr>"
        }
    }
    $attHtml  = if ($attention.Count) { "<table>$((& $rows $attention -WithFix) -join '')</table>" } else { '<p class="ok">Nothing needs attention.</p>' }
    $fineHtml = "<table>$((& $rows $fine) -join '')</table>"
    $repHtml  = if ($ExtraReports.Count) {
        $items = foreach ($r in $ExtraReports) {
            if ($r.Path) {
                # Saved next to this page, so a relative link works wherever the folder is copied.
                "<li><a href=""$(& $enc ([IO.Path]::GetFileName($r.Path)))"">$(& $enc $r.Name)</a> - $(& $enc $r.Note)</li>"
            }
            else { "<li>$(& $enc $r.Name): <span class=""fix"">$(& $enc $r.Note)</span></li>" }
        }
        "<h2>Reports</h2><ul>$($items -join '')</ul>"
    } else { '' }
    $page = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Quick triage - $env:COMPUTERNAME</title>
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; max-width: 1100px; }
 h1 { font-size: 20px; margin-bottom: 2px; } .sub { color: #656d76; margin-bottom: 14px; }
 h2 { font-size: 15px; margin: 20px 0 6px; border-bottom: 2px solid #0969da; padding-bottom: 3px; }
 .summary { background: #f6f8fa; border: 1px solid #d0d7de; padding: 8px 12px; font-family: Consolas, monospace; font-size: 13px; }
 table { border-collapse: collapse; font-size: 13px; width: 100%; }
 td { border-bottom: 1px solid #d0d7de; padding: 5px 8px; vertical-align: top; }
 td.st { font-weight: 600; width: 44px; } tr.fail td.st { color: #cf222e; } tr.warn td.st { color: #9a6700; }
 tr.pass td.st { color: #1a7f37; } tr.info td.st { color: #656d76; }
 .fix { color: #656d76; margin-top: 3px; } .ok { color: #1a7f37; font-weight: 600; }
</style></head><body>
<h1>Quick triage - $env:COMPUTERNAME</h1>
<div class="sub">$(& $enc $headline) &middot; $($now.ToString('yyyy-MM-dd HH:mm'))</div>
<div class="summary">$(& $enc $summary)</div>
<h2>Needs attention ($($attention.Count))</h2>$attHtml
<h2>Checked and fine ($($fine.Count))</h2>$fineHtml
$repHtml
</body></html>
"@
    $page | Set-Content -LiteralPath $file -Encoding UTF8
    if (-not $Quiet) { Write-Host "  Report:  $file" -ForegroundColor Cyan }
    if (-not $NoOpen -and [Environment]::UserInteractive -and -not $PSSenderInfo) {
        try { Invoke-Item -LiteralPath $file } catch { Write-Verbose 'Could not open the report' }
    }
}

# .ToArray(), not @(): PowerShell 7.5 throws "Argument types do not match" on @(List) inside an object literal.
if ($PassThru) { [pscustomobject]@{ Summary = $summary; Device = $inv; Findings = $Findings.ToArray(); Reports = $ExtraReports.ToArray() } }
if ($fails) { exit 1 }
exit 0
