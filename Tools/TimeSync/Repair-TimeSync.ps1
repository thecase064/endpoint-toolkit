<#
.SYNOPSIS
    The clock's wrong: checks how this PC keeps time, measures how far off it is, then resyncs it
    with the Windows Time service and measures again.

.DESCRIPTION
    Wrong time breaks more than the clock: sign-ins (Kerberos stops at 5 minutes), Teams, Outlook,
    certificate checks and VPNs. This tool:

      1. Checks:   domain or not, where the time comes from (the configured source and the one in use),
                   automatic time on or off, Group Policy in charge, the Windows Time service, the last
                   good sync, recent "can't reach the time source" events, the offset against a time
                   server, the largest jump Windows will make by itself, and the time zone.
      2. Fixes:    turns the Windows Time service back on if it's disabled, starts it, turns automatic
                   time back on if it's off, and resyncs (rediscovering the source when it isn't
                   syncing from anything). Every config change prints the command that undoes it.
      3. Checks again: the offset and source afterwards.

    It never changes where the PC gets its time from unless you ask with -SetPeer, and never on a
    domain-joined PC (domain members take their time from a domain controller). Domain controllers
    are only reported on, never changed. Nothing restarts.

.PARAMETER CheckOnly
    Only check and measure; change nothing.

.PARAMETER SetPeer
    Point a non-domain PC at -Peer (default time.windows.com) as its time server, then resync.
    Prints the command that puts the old setting back. Refused on domain members and DCs.

.PARAMETER Peer
    Time server for -SetPeer. Default time.windows.com.

.PARAMETER Reference
    Server to measure the offset against. Default: the PC's own time server, or time.windows.com
    when it isn't using a named server.

.PARAMETER Quiet
    Print only the one-line summary (for RMM).

.PARAMETER PassThru
    Emit the findings, actions and offsets to the pipeline.

.EXAMPLE
    .\Repair-TimeSync.ps1

.EXAMPLE
    .\Repair-TimeSync.ps1 -CheckOnly

.EXAMPLE
    .\Repair-TimeSync.ps1 -SetPeer -Peer uk.pool.ntp.org

.NOTES
    Run as Administrator (-CheckOnly works without, with less detail).
    Exit codes: 0 = in time (within 30 seconds) or check passed, 1 = still off, a step failed, or a FAIL in -CheckOnly.
    Network: the time check uses NTP (UDP 123) to the PC's own time source or -Reference.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [switch] $SetPeer,
    [ValidatePattern('^[A-Za-z0-9.\-:]+$')] [string] $Peer = 'time.windows.com',
    [ValidatePattern('^$|^[A-Za-z0-9.\-:]+$')] [string] $Reference = '',
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')

$now      = Get-Date
$Computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }
$IsAdmin  = Test-RunningAsAdmin
$WarnSeconds = 30          # worth fixing
$FailSeconds = 300         # Kerberos sign-ins fail past 5 minutes

$W32Key    = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time'
$ParamKey  = "$W32Key\Parameters"
$ConfigKey = "$W32Key\Config"
$PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\W32time\Parameters'
$TzKey     = 'HKLM:\SYSTEM\CurrentControlSet\Services\tzautoupdate'
$VmicKey   = "$W32Key\TimeProviders\VMICTimeProvider"

# What w32tm's error codes mean here.
$W32Errors = @{
    '0x800705B4' = 'no time data came back: the time source didn''t answer (UDP 123 blocked by a firewall or proxy, or the source is down)'
    '0x80070426' = 'the Windows Time service isn''t running'
    '0x80070005' = 'access denied: run it as admin'
    '0x80072AF9' = 'the time server''s name didn''t resolve (DNS)'
    '0x80072AFC' = 'the time server''s name didn''t resolve (DNS)'
}
# Windows Time events worth naming (System log, Microsoft-Windows-Time-Service).
$TimeEvents = @{
    36  = 'not synchronized for over 24 hours'
    47  = 'no valid response from the configured time server'
    129 = 'couldn''t find a domain controller to take the time from'
    134 = 'couldn''t resolve the configured time server''s name (DNS)'
}

# ================================================================================================
#  Plumbing
# ================================================================================================
$Findings = [System.Collections.Generic.List[object]]::new()
$Actions  = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string] $Area, [string] $Check, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')] [string] $Status, [string] $Detail, [string] $Fix)
    $Findings.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix; Order = $Findings.Count })
}
function Add-Action {
    param([string] $Step, [ValidateSet('OK', 'FAILED', 'SKIPPED')] [string] $Result, [string] $Detail, [string] $Undo)
    $Actions.Add([pscustomobject]@{ Step = $Step; Result = $Result; Detail = $Detail; Undo = $Undo })
    if (-not $Quiet) {
        $colour = switch ($Result) { 'OK' { 'Green' } 'FAILED' { 'Red' } default { 'DarkGray' } }
        Write-Host ('   [{0}] {1}' -f $Result, $Step) -ForegroundColor $colour
        if ($Detail) { Write-Host "          $Detail" -ForegroundColor DarkGray }
        if ($Undo)   { Write-Host "          Undo: $Undo" -ForegroundColor DarkGray }
    }
}

function Get-RegKey {
    param([string] $Path)
    $h = [ordered]@{}
    $p = $null
    try { $p = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop } catch { $p = $null }
    if ($p) { foreach ($prop in $p.PSObject.Properties) { if ($prop.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { $h[$prop.Name] = $prop.Value } } }
    $h
}
function Get-Val { param($Map, [string] $Name) if ($Map -and $Map.Contains($Name)) { $Map[$Name] } else { $null } }

function Invoke-W32tm {
    # w32tm prints to stdout and sets an exit code; keep both.
    param([string[]] $Arguments)
    $global:LASTEXITCODE = 0
    $lines = @(& w32tm @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code  = $LASTEXITCODE
    $hex   = [regex]::Match(($lines -join ' '), '0x[0-9A-Fa-f]{8}').Value.ToUpper() -replace '^0X', '0x'
    [pscustomobject]@{ Code = $code; Lines = $lines; Text = (($lines | Where-Object { $_.Trim() }) -join ' ').Trim(); Hex = $hex }
}

function Get-W32Explain {
    param($Result)
    if ($Result.Hex -and $W32Errors.ContainsKey($Result.Hex)) { return "$($Result.Hex): $($W32Errors[$Result.Hex])" }
    if ($Result.Text) { return $Result.Text }
    "exit code $($Result.Code)"
}

function Get-TimeSource {
    $r = Invoke-W32tm @('/query', '/source')
    if ($r.Code -ne 0) { return $null }
    ($r.Lines | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
}

function Get-TimeStatus {
    # "Label: value" lines from w32tm /query /status (English labels; other languages fall back to events).
    $r = Invoke-W32tm @('/query', '/status')
    $map = @{}
    if ($r.Code -eq 0) {
        foreach ($l in $r.Lines) { if ($l -match '^\s*([A-Za-z][A-Za-z ]+?)\s*:\s*(.*?)\s*$') { $map[$Matches[1]] = $Matches[2] } }
    }
    [pscustomobject]@{ Ok = ($r.Code -eq 0); Map = $map; Result = $r }
}

function Test-NotSyncing {
    # The time service is running on its own clock, not a server.
    param([string] $Source)
    [string]::IsNullOrWhiteSpace($Source) -or $Source -match 'Local CMOS Clock|Free-running System Clock'
}

function Get-HostFromPeer {
    # 'time.windows.com,0x9' -> 'time.windows.com'; the first of a space-separated list.
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $first = ($Text.Trim() -split '\s+')[0]
    ($first -split ',')[0].Trim()
}

function Measure-Offset {
    # w32tm /stripchart against a server: the median of three samples, in seconds. Only the size is
    # used: Microsoft doesn't document which way round the sign is.
    param([string] $Target)
    $r = Invoke-W32tm @('/stripchart', "/computer:$Target", '/dataonly', '/samples:3')
    $samples = @(foreach ($l in $r.Lines) {
        $m = [regex]::Match($l, ',\s*([+-]?\d+[.,]\d+)s\s*$')
        if ($m.Success) { [double]::Parse(($m.Groups[1].Value -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture) }
    })
    if (-not $samples.Count) {
        $err = [regex]::Match(($r.Lines -join ' '), '0x[0-9A-Fa-f]{8}').Value.ToUpper() -replace '^0X', '0x'
        $why = if ($err -and $W32Errors.ContainsKey($err)) { "${err}: $($W32Errors[$err])" } elseif ($err) { $err } elseif ($r.Text) { $r.Text } else { "exit code $($r.Code)" }
        return [pscustomobject]@{ Target = $Target; Seconds = $null; Error = $why }
    }
    $sorted = @($samples | Sort-Object)
    [pscustomobject]@{ Target = $Target; Seconds = $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]; Error = $null }
}

function Format-Offset {
    param([double] $Seconds)
    $a = [math]::Abs($Seconds)
    if ($a -lt 60) { return '{0:N3} s' -f $a }
    $span = [TimeSpan]::FromSeconds($a)
    $parts = @()
    if ($span.Days)    { $parts += "$($span.Days)d" }
    if ($span.Hours)   { $parts += "$($span.Hours)h" }
    if ($span.Minutes) { $parts += "$($span.Minutes)m" }
    if ($span.Seconds) { $parts += "$($span.Seconds)s" }
    $parts -join ' '
}

function Get-AgeText {
    param([datetime] $When)
    $span = $now - $When
    if ($span.TotalDays -ge 2) { return '{0} days ago' -f [int][math]::Floor($span.TotalDays) }
    if ($span.TotalHours -ge 2) { return '{0} hours ago' -f [int][math]::Floor($span.TotalHours) }
    if ($span.TotalMinutes -ge 1) { return '{0} min ago' -f [int][math]::Floor($span.TotalMinutes) }
    'just now'
}

function Get-OffsetStatus {
    param($Measured)
    if ($null -eq $Measured.Seconds) { return 'WARN' }
    $a = [math]::Abs($Measured.Seconds)
    if ($a -ge $FailSeconds) { 'FAIL' } elseif ($a -ge $WarnSeconds) { 'WARN' } else { 'PASS' }
}

function Get-SyncCommand {
    # The w32tm command that sets a Type / NtpServer pair (used for the undo lines).
    param([string] $Type, [string] $NtpServer)
    switch -Regex ($Type) {
        '^NT5DS$'   { return 'w32tm /config /syncfromflags:domhier /update' }
        '^NTP$'     { return ('w32tm /config /manualpeerlist:"{0}" /syncfromflags:manual /update' -f $NtpServer) }
        '^AllSync$' { return ('w32tm /config /manualpeerlist:"{0}" /syncfromflags:all /update' -f $NtpServer) }
        '^NoSync$'  { return 'w32tm /config /syncfromflags:NO /update' }
    }
    $null
}

# ================================================================================================
#  1. Check
# ================================================================================================
if (-not $Quiet) { Write-Host "Checking the clock on $Computer..." -ForegroundColor DarkGray }

$cs = $null
try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem } catch { $cs = $null }
$role      = if ($cs) { [int]$cs.DomainRole } else { 0 }          # 0/2 standalone, 1/3 member, 4/5 domain controller
$isDC      = $role -ge 4
$isMember  = $role -in 1, 3
$domain    = if ($cs -and $cs.PartOfDomain) { [string]$cs.Domain } else { '' }
$isVm      = $cs -and ("$($cs.Manufacturer) $($cs.Model)" -match 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|Xen')

$params  = Get-RegKey $ParamKey
$policy  = Get-RegKey $PolicyKey
$config  = Get-RegKey $ConfigKey
$svcKey  = Get-RegKey $W32Key
$type    = [string](Get-Val $params 'Type')
$ntp     = [string](Get-Val $params 'NtpServer')
$polType = [string](Get-Val $policy 'Type')
$effType = if ($polType) { $polType } else { $type }
$effNtp  = if ($polType -and (Get-Val $policy 'NtpServer')) { [string](Get-Val $policy 'NtpServer') } else { $ntp }
$svcStart = [string](Get-Val $svcKey 'Start')
$svc = $null
try { $svc = Get-Service -Name W32Time -ErrorAction Stop } catch { $svc = $null }
$running = $svc -and [string]$svc.Status -eq 'Running'

# Who this PC takes its time from
if ($isDC) {
    Add-Finding 'Setup' 'Role' 'INFO' "Domain controller of $domain" 'Domain controllers are only reported on: this tool changes nothing on them.'
}
elseif ($isMember) {
    Add-Finding 'Setup' 'Role' 'INFO' "Domain member of $domain`: takes its time from a domain controller"
}
else {
    Add-Finding 'Setup' 'Role' 'INFO' 'Not domain joined (Entra / workgroup): takes its time from an internet time server'
}

# The service
if (-not $svcKey.Count -and -not $svc) {
    Add-Finding 'Setup' 'Time service' 'FAIL' 'The Windows Time service (W32Time) is missing' 'Re-register it as admin: w32tm /register, then net start w32time.'
}
elseif ($svcStart -eq '4') {
    Add-Finding 'Setup' 'Time service' 'FAIL' 'The Windows Time service is disabled' 'This tool sets it back to Manual and starts it (an "optimiser" or debloat script usually did this).'
}
else {
    $startText = switch ($svcStart) { '2' { 'Automatic' } '3' { 'Manual (starts when needed)' } default { "start type $svcStart" } }
    $state = if ($running) { 'running' } else { 'not running right now (normal between syncs on a non-domain PC)' }
    Add-Finding 'Setup' 'Time service' 'PASS' "Windows Time service: $startText, $state"
}

# Automatic time and the configured source
$polNote = if ($polType) { ' (set by Group Policy / Intune)' } else { '' }
if ($effType -eq 'NoSync') {
    Add-Finding 'Setup' 'Automatic time' 'FAIL' "Set time automatically is off (Type = NoSync)$polNote" $(if ($polType) { 'Policy turned it off: change the W32Time policy; a local fix gets overwritten.' } else { 'This tool turns it back on (Settings > Time & language > Set time automatically does the same).' })
}
elseif ($isMember -and $effType -in 'NTP', 'AllSync') {
    Add-Finding 'Setup' 'Configured source' 'WARN' "Domain member set to time server(s) '$effNtp' (Type = $effType) instead of the domain$polNote" 'Domain PCs should follow the domain: w32tm /config /syncfromflags:domhier /update, then w32tm /resync /rediscover. Often left behind by a time-fix script.'
}
elseif (-not $isMember -and -not $isDC -and $effType -eq 'NT5DS') {
    Add-Finding 'Setup' 'Configured source' 'WARN' "Not domain joined, but set to follow a domain (Type = NT5DS)$polNote" 'Run this tool with -SetPeer to point it at time.windows.com.'
}
elseif ($effType) {
    $what = switch ($effType) { 'NT5DS' { 'the domain hierarchy' } 'NTP' { "time server(s) $effNtp" } 'AllSync' { "the domain and $effNtp" } default { $effType } }
    Add-Finding 'Setup' 'Configured source' 'PASS' "Set to take the time from $what$polNote"
}
if ($polType) { Add-Finding 'Setup' 'Policy' 'INFO' 'Windows Time settings come from Group Policy / Intune' 'Local changes are overwritten at the next policy refresh: fix the policy itself.' }

# What it's actually using, and when it last synced
$source = Get-TimeSource
$status = Get-TimeStatus
if ($status.Ok -and -not $source) { $source = [string]$status.Map['Source'] }
if (-not $source -and -not $IsAdmin) {
    Add-Finding 'Sync' 'Source in use' 'INFO' 'Couldn''t ask the time service (run as admin for the details)'
}
elseif (Test-NotSyncing $source) {
    Add-Finding 'Sync' 'Source in use' 'WARN' "Not syncing from anything: $(if ($source) { $source } else { 'no source' })" 'A resync with /rediscover usually picks the source up again; this tool does that.'
}
elseif ($source -match 'VM IC Time|Hyper-V|VMICTimeProvider') {
    Add-Finding 'Sync' 'Source in use' 'INFO' "Taking the time from the virtual machine host ($source)" $(if ($isMember) { 'On a domain-joined VM the host and the domain can fight; usually the domain should win.' } else { '' })
}
else {
    Add-Finding 'Sync' 'Source in use' 'PASS' "Syncing from $source"
}

$lastSync = $null; $lastSyncFromEvents = $false
$lsText = [string]$status.Map['Last Successful Sync Time']
if ($lsText -and $lsText -notmatch 'unspecified') {
    $d = [datetime]::MinValue
    if ([datetime]::TryParse($lsText, [ref]$d)) { $lastSync = $d }
}
$syncEvents = @()
try { $syncEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Time-Service'; StartTime = $now.AddDays(-14) } -MaxEvents 300 -ErrorAction Stop) } catch { $syncEvents = @() }
if (-not $lastSync) {
    $good = $syncEvents | Where-Object { $_.Id -in 35, 37 } | Sort-Object TimeCreated -Descending | Select-Object -First 1
    if ($good) { $lastSync = [datetime]$good.TimeCreated; $lastSyncFromEvents = $true }
}
$maxAge = if ($isMember -or $isDC) { 1 } else { 8 }                # domain members sync many times a day; others weekly
if ($lastSync -and $lastSyncFromEvents) {
    Add-Finding 'Sync' 'Last sync' 'INFO' ('Last time-sync event {0} ({1}); the exact last sync wasn''t readable' -f (Get-AgeText $lastSync), $lastSync.ToString('yyyy-MM-dd HH:mm'))
}
elseif ($lastSync) {
    $age  = ($now - $lastSync).TotalDays
    $text = 'Last good sync {0} ({1})' -f (Get-AgeText $lastSync), $lastSync.ToString('yyyy-MM-dd HH:mm')
    if ($age -gt $maxAge) { Add-Finding 'Sync' 'Last sync' 'WARN' $text 'It isn''t syncing on schedule: see the events and offset below.' }
    else { Add-Finding 'Sync' 'Last sync' 'PASS' $text }
}
elseif ($lsText -match 'unspecified') {
    Add-Finding 'Sync' 'Last sync' 'WARN' 'The time service has never synced since it started' 'A resync usually fixes it; if it fails, check UDP 123 to the time server.'
}
else { Add-Finding 'Sync' 'Last sync' 'INFO' 'Couldn''t tell when it last synced' }

# Recent trouble from the time service
$bad = @($syncEvents | Where-Object { $TimeEvents.ContainsKey([int]$_.Id) -and $_.TimeCreated -ge $now.AddDays(-7) })
foreach ($g in @($bad | Group-Object Id | Sort-Object Count -Descending)) {
    $last = ($g.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
    Add-Finding 'Sync' 'Time service events' 'WARN' ('Event {0}: {1} - {2} time(s) in 7 days, last {3}' -f $g.Name, $TimeEvents[[int]$g.Name], $g.Count, ([datetime]$last).ToString('yyyy-MM-dd HH:mm')) $(if ([int]$g.Name -eq 129) { 'Check the PC can reach a domain controller (VPN, DNS).' } else { 'Check UDP 123 to the time server through the firewall / proxy, and DNS.' })
}

# How far off is it?
$sourceHost = if (-not (Test-NotSyncing $source) -and $source -notmatch 'VM IC|Hyper-V|VMIC') { Get-HostFromPeer $source } else { $null }
$refHost = if ($Reference) { $Reference } elseif ($sourceHost) { $sourceHost } elseif ($effType -in 'NTP', 'AllSync' -and $effNtp) { Get-HostFromPeer $effNtp } else { 'time.windows.com' }
$before = Measure-Offset $refHost
# The biggest jump Windows makes by itself, forwards and back. 0xFFFFFFFF (or -1 as a DWORD) = no limit.
$limits = @(foreach ($n in 'MaxPosPhaseCorrection', 'MaxNegPhaseCorrection') {
    $v = Get-Val $config $n
    if ($null -ne $v -and [int64]$v -ge 0 -and [int64]$v -lt 4294967295) { [int64]$v }
})
$limitLow  = if ($limits.Count) { ($limits | Measure-Object -Minimum).Minimum } else { $null }
$limitHigh = if ($limits.Count -eq 2) { ($limits | Measure-Object -Maximum).Maximum } else { $null }
function Get-LimitFinding {
    # FAIL past both limits (or the only one set), WARN past the smaller one (depends which way it's out).
    param([double] $Seconds)
    $a = [math]::Abs($Seconds)
    if ($null -ne $limitHigh -and $a -gt $limitHigh) { return 'FAIL' }
    if ($null -eq $limitHigh -and $limits.Count -eq 1 -and $a -gt $limitLow) { return 'WARN' }
    if ($null -ne $limitLow -and $a -gt $limitLow) { return 'WARN' }
    $null
}
if ($null -eq $before.Seconds) {
    Add-Finding 'Clock' 'Offset' 'WARN' "Couldn't measure against $refHost`: $($before.Error)" 'NTP needs UDP 123 out to the time server; check the firewall / proxy. Try -Reference with another server to compare.'
}
else {
    $st   = Get-OffsetStatus $before
    $text = 'Clock is out by {0} against {1}' -f (Format-Offset $before.Seconds), $refHost
    $fix  = switch ($st) { 'FAIL' { 'Over 5 minutes: sign-ins (Kerberos), Teams and Outlook break. This tool resyncs it.' } 'WARN' { 'Worth a resync; this tool does it.' } default { '' } }
    Add-Finding 'Clock' 'Offset' $st $text $fix
    $lim = Get-LimitFinding $before.Seconds
    if ($lim) {
        $limText = (@($limits | Sort-Object -Unique | ForEach-Object { Format-Offset $_ }) -join ' / ')
        $howSure = if ($lim -eq 'FAIL') { 'further out than' } else { 'possibly further out than' }
        Add-Finding 'Clock' 'Too far off' $lim "The clock is $howSure Windows will correct by itself (limit $limText)" 'Set the date and time by hand first (Settings > Time & language > Date & time, or Set-Date), then run this again.'
    }
}

# Time zone (can't judge it, but it's the other half of "the clock's wrong")
try {
    $tz = Get-TimeZone
    $tzAuto = Get-Val (Get-RegKey $TzKey) 'Start'
    $autoText = switch ([string]$tzAuto) { '3' { 'set automatically: on' } '4' { 'set automatically: off' } default { '' } }
    $tzText = '{0} ({1})' -f $tz.Id, $tz.DisplayName
    if ($autoText) { $tzText += "; $autoText" }
    Add-Finding 'Clock' 'Time zone' 'INFO' $tzText 'If the time is right but shows the wrong hour, it''s the time zone: Settings > Time & language > Date & time.'
}
catch { Add-Finding 'Clock' 'Time zone' 'INFO' "Couldn't read the time zone: $($_.Exception.Message)" }

if ($isVm -and [string](Get-Val (Get-RegKey $VmicKey) 'Enabled') -eq '1' -and $isMember) {
    Add-Finding 'Setup' 'Virtual machine' 'INFO' 'Virtual machine with the host time provider on, and domain joined' 'If the time keeps jumping, the host and the domain may be fighting; see Microsoft''s guidance for time on domain VMs.'
}

# ================================================================================================
#  Print the check
# ================================================================================================
$AreaOrder = @('Clock', 'Setup', 'Sync')
$rank = { param($f) $i = [array]::IndexOf($AreaOrder, $f.Area); if ($i -lt 0) { 99 } else { $i } }
$attention = @($Findings | Where-Object { $_.Status -in 'FAIL', 'WARN' } | Sort-Object @{ e = { if ($_.Status -eq 'FAIL') { 0 } else { 1 } } }, @{ e = { & $rank $_ } }, Order)
$fine      = @($Findings | Where-Object { $_.Status -in 'PASS', 'INFO' } | Sort-Object @{ e = { & $rank $_ } }, Order)
if (-not $Quiet) {
    Write-Host ''
    Write-Host ("== Time sync - {0} - {1} " -f $Computer, $now.ToString('yyyy-MM-dd HH:mm')).PadRight(78, '=') -ForegroundColor Cyan
    if ($attention.Count) {
        Write-Host ("  NEEDS ATTENTION ({0})" -f $attention.Count) -ForegroundColor $(if (@($attention | Where-Object Status -eq 'FAIL').Count) { 'Red' } else { 'Yellow' })
        foreach ($f in $attention) {
            Write-Host ('   [{0}] {1,-6} {2}: {3}' -f $f.Status, $f.Area, $f.Check, $f.Detail) -ForegroundColor $(if ($f.Status -eq 'FAIL') { 'Red' } else { 'Yellow' })
            if ($f.Fix) { Write-Host ('{0,16}-> {1}' -f '', $f.Fix) -ForegroundColor DarkGray }
        }
    }
    else { Write-Host '  NOTHING NEEDS ATTENTION' -ForegroundColor Green }
    Write-Host ("  CHECKED ({0})" -f $fine.Count) -ForegroundColor Green
    foreach ($f in $fine) {
        Write-Host ('   {0,-6} {1}: {2}' -f $f.Area, $f.Check, $f.Detail) -ForegroundColor DarkGray
        if ($f.Fix -and $f.Status -eq 'INFO') { Write-Host ('{0,12}-> {1}' -f '', $f.Fix) -ForegroundColor DarkGray }
    }
}

# ================================================================================================
#  2. Fix
# ================================================================================================
$changed = $false; $stepFailed = $false; $after = $null
$fixReason = $null
if ($CheckOnly)         { $fixReason = 'Check only: nothing changed.' }
elseif (-not $IsAdmin)  { $fixReason = 'Not running as admin: nothing changed. Run it elevated to fix.' }
elseif ($isDC)          { $fixReason = 'Domain controller: nothing changed.' }

if ($fixReason) {
    if (-not $Quiet) { Write-Host ''; Write-Host "  $fixReason" -ForegroundColor DarkGray }
}
else {
    if (-not $Quiet) { Write-Host ''; Write-Host '  FIX' -ForegroundColor Cyan }

    # The service: back on, and running
    if ($svcStart -eq '4') {
        try {
            Set-Service -Name W32Time -StartupType Manual -ErrorAction Stop
            Add-Action 'Windows Time service set to Manual (was Disabled)' 'OK' '' 'Set-Service W32Time -StartupType Disabled'
            $changed = $true
        }
        catch { Add-Action 'Windows Time service set to Manual' 'FAILED' $_.Exception.Message; $stepFailed = $true }
    }
    if (-not $stepFailed -and -not $running) {
        try { Start-Service -Name W32Time -ErrorAction Stop; Add-Action 'Windows Time service started' 'OK' }
        catch { Add-Action 'Windows Time service start' 'FAILED' $_.Exception.Message; $stepFailed = $true }
    }

    # Automatic time off, or a new time server asked for
    $configured = $false
    if (-not $stepFailed) {
        $oldUndo = Get-SyncCommand $type $ntp
        if ($SetPeer) {
            if ($isMember) {
                Add-Action "Point it at $Peer" 'SKIPPED' 'Domain member: it should take its time from the domain, not an internet server.'
            }
            elseif ($polType) {
                Add-Action "Point it at $Peer" 'SKIPPED' 'Windows Time is set by policy here; a local change would be overwritten. Change the policy.'
            }
            else {
                $r = Invoke-W32tm @('/config', "/manualpeerlist:$Peer,0x9", '/syncfromflags:manual', '/update')
                if ($r.Code -eq 0) { Add-Action "Time server set to $Peer" 'OK' "Was: $(if ($type) { "$type $ntp".Trim() } else { 'not set' })" $oldUndo; $changed = $true; $configured = $true }
                else { Add-Action "Time server set to $Peer" 'FAILED' (Get-W32Explain $r); $stepFailed = $true }
            }
        }
        elseif ($effType -eq 'NoSync' -and -not $polType) {
            $args2 = if ($isMember) { @('/config', '/syncfromflags:domhier', '/update') }
                     else {
                         $list = if ($ntp) { $ntp } else { 'time.windows.com,0x9' }
                         @('/config', "/manualpeerlist:$list", '/syncfromflags:manual', '/update')
                     }
            $r = Invoke-W32tm $args2
            if ($r.Code -eq 0) { Add-Action 'Automatic time turned back on' 'OK' $(if ($isMember) { 'Following the domain' } else { "Time server: $(Get-HostFromPeer $(if ($ntp) { $ntp } else { 'time.windows.com' }))" }) 'w32tm /config /syncfromflags:NO /update'; $changed = $true; $configured = $true }
            else { Add-Action 'Automatic time turned back on' 'FAILED' (Get-W32Explain $r); $stepFailed = $true }
        }
    }

    # Resync
    if (-not $stepFailed) {
        $rediscover = $configured -or (Test-NotSyncing $source)
        $resyncArgs = if ($rediscover) { @('/resync', '/rediscover') } else { @('/resync') }
        $r = Invoke-W32tm $resyncArgs
        if ($r.Code -ne 0 -and $r.Hex -eq '0x80070426') {
            # The service stopped again between the start and the resync (trigger-start): start it and try once more.
            try { Start-Service -Name W32Time -ErrorAction Stop } catch { Write-Verbose $_.Exception.Message }
            $r = Invoke-W32tm $resyncArgs
        }
        if ($r.Code -eq 0) { Add-Action ('Resynced (w32tm {0})' -f ($resyncArgs -join ' ')) 'OK' }
        else {
            Add-Action ('Resync (w32tm {0})' -f ($resyncArgs -join ' ')) 'FAILED' (Get-W32Explain $r)
            $stepFailed = $true
        }
    }

    # 3. Check again
    Start-Sleep -Seconds 3
    $after = Measure-Offset $refHost
    $sourceAfter = Get-TimeSource
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  AFTER' -ForegroundColor Cyan
        if ($null -ne $after.Seconds) {
            $st = Get-OffsetStatus $after
            Write-Host ('   Clock is out by {0} against {1} (was {2})' -f (Format-Offset $after.Seconds), $refHost, $(if ($null -ne $before.Seconds) { Format-Offset $before.Seconds } else { 'not measured' })) -ForegroundColor $(switch ($st) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } })
        }
        else { Write-Host "   Couldn't measure against $refHost`: $($after.Error)" -ForegroundColor Yellow }
        if ($sourceAfter) { Write-Host "   Source: $sourceAfter" -ForegroundColor DarkGray }
        if ($null -ne $after.Seconds -and (Get-LimitFinding $after.Seconds)) {
            Write-Host '   Still too far out for Windows to correct by itself: set the time by hand, then run this again.' -ForegroundColor Yellow
        }
    }
}

# ================================================================================================
#  Summary and exit
# ================================================================================================
$beforeText = if ($null -ne $before.Seconds) { Format-Offset $before.Seconds } else { 'not measured' }
$fails = @($Findings | Where-Object Status -eq 'FAIL').Count
if ($after) {
    $afterText = if ($null -ne $after.Seconds) { Format-Offset $after.Seconds } else { 'not measured' }
    $result = if ($stepFailed) { 'resync FAILED' } elseif ($null -ne $after.Seconds -and (Get-OffsetStatus $after) -eq 'PASS') { 'in time' } else { 'still off' }
    $summary = '{0} time sync - {1}: was {2}, now {3} against {4}' -f $Computer, $result, $beforeText, $afterText, $refHost
    $exit = if ($result -eq 'in time') { 0 } else { 1 }
}
else {
    $issues = @($attention | ForEach-Object { $_.Check } | Select-Object -Unique)
    $tail = if ($issues.Count) { '; ' + ($issues -join ', ') } else { '' }
    $summary = '{0} time sync check - clock {1} against {2}{3}' -f $Computer, $beforeText, $refHost, $tail
    $exit = if ($fails) { 1 } else { 0 }
}

if ($Quiet) { Write-Output $summary }
else { Write-Host ''; Write-Host "  Summary: $summary" -ForegroundColor Cyan }

# .ToArray(), not @(): PowerShell 7.5 throws "Argument types do not match" on @(List) inside an object literal.
if ($PassThru) {
    [pscustomobject]@{
        Summary = $summary; Reference = $refHost; Before = $before; After = $after
        Findings = $Findings.ToArray(); Actions = $Actions.ToArray(); Changed = $changed
    }
}
exit $exit
