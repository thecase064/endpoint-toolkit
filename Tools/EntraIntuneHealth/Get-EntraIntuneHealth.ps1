<#
.SYNOPSIS
    Checks whether a Windows device is healthy in Entra ID and Intune, says what's wrong in plain
    English, and optionally forces a sync or bundles the logs for an escalation.

.DESCRIPTION
    Read-only by default. Checks, each marked PASS / WARN / FAIL / INFO with a fix hint:

      Join         Entra / hybrid / domain / registered state, device auth, TPM-backed key, device cert,
                   Primary Refresh Token (SSO), and any join error codes dsregcmd reports
      Enrolment    MDM enrolment and its UPN, Intune MDM certificate expiry, last successful check-in,
                   EnterpriseMgmt sync tasks, the push-notification service
      Agent        Intune Management Extension: installed, running, version, last log activity
      Events       Errors in the MDM and AAD event logs over the last few days
      Network      HTTPS reachability of the Entra and Intune endpoints

    Actions (opt-in, need admin):
      -Sync         trigger an MDM check-in and restart the Intune Management Extension
      -CollectLogs  zip dsregcmd output, the results, IME logs, MDM diagnostics and event logs

.PARAMETER Sync
    Trigger an MDM sync (the EnterpriseMgmt PushLaunch task) and an IME check-in after the checks.

.PARAMETER CollectLogs
    Bundle logs for escalation into <OutputFolder>\EntraIntune_<COMPUTER>_<timestamp>.zip.

.PARAMETER OutputFolder
    Where -CollectLogs writes. Default C:\EntraIntuneHealth.

.PARAMETER EventDays
    How far back to look for event log errors. Default 7.

.PARAMETER SkipNetwork
    Skip the endpoint reachability checks.

.PARAMETER Quiet
    Print one summary line only (for Intune remediations / RMM monitors).

.PARAMETER PassThru
    Emit the check results to the pipeline.

.EXAMPLE
    .\Get-EntraIntuneHealth.ps1

.EXAMPLE
    .\Get-EntraIntuneHealth.ps1 -Sync

.EXAMPLE
    .\Get-EntraIntuneHealth.ps1 -CollectLogs

.NOTES
    Exit codes: 0 = no failures, 1 = at least one FAIL (works as an Intune remediation detection script).
    The PRT (SSO) check is for the account running the script. Elevating as a separate admin account
    checks that account's token, not the user's - run it unelevated as the user for SSO problems.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Sync,
    [switch] $CollectLogs,
    [string] $OutputFolder = (Join-Path $env:SystemDrive 'EntraIntuneHealth'),
    [ValidateRange(1, 30)] [int] $EventDays = 7,
    [switch] $SkipNetwork,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

$IsElevated = $false
try {
    $IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch { Write-Verbose 'Could not determine elevation' }

if (($Sync -or $CollectLogs) -and -not $IsElevated) {
    Write-Host '-Sync and -CollectLogs need an elevated session. Running the checks only.' -ForegroundColor Yellow
    $Sync = $false; $CollectLogs = $false
}

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param(
        [string] $Area, [string] $Check,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')] [string] $Status,
        [string] $Detail, [string] $Fix
    )
    $Results.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix })
}

# Error codes worth naming. Anything else is shown as-is.
$KnownErrors = @{
    '0x801c03f2' = 'Device object not found in Entra. For hybrid join: is the computer in Entra Connect sync scope?'
    '0x801c001d' = 'Discovery failed: no SCP / tenant info. Check the Entra Connect SCP or the hybrid join GPO.'
    'AADSTS700003' = 'Device object deleted or missing in Entra. Leave and rejoin (dsregcmd /forcerecovery on Entra joined).'
}

function Get-KnownError([string] $Text) {
    foreach ($k in $KnownErrors.Keys) { if ($Text -match [regex]::Escape($k)) { return $KnownErrors[$k] } }
    $null
}

function ConvertFrom-DsregOutput {
    # dsregcmd /status prints "   Name : Value" lines under section headers. First occurrence wins.
    param([string[]] $Lines)
    $map = [ordered]@{}
    foreach ($l in $Lines) {
        if ($l -match '^\s*([A-Za-z][A-Za-z0-9 ]*?)\s*:\s*(.*?)\s*$') {
            $key = $Matches[1].Trim()
            if (-not $map.Contains($key)) { $map[$key] = $Matches[2] }
        }
    }
    $map
}

function ConvertFrom-OmaDmTime {
    # ConnInfo times look like 20261104T101500Z
    param([string] $Value)
    if (-not $Value) { return $null }
    try { return [datetime]::ParseExact($Value, "yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture,
                                         [Globalization.DateTimeStyles]::AssumeUniversal) }
    catch { return $null }
}

function Test-Port {
    param([string] $HostName, [int] $Port = 443, [int] $TimeoutMs = 4000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMs)) { return 'timed out' }
        if ($client.Connected) { return 'ok' }
        return 'refused'
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        return $inner.Message
    }
    finally { $client.Dispose() }
}

$now = Get-Date

# ================================================================================================
#  Join state (dsregcmd)
# ================================================================================================
$dsregText = @()
$ds = $null
try {
    $dsregText = @(dsregcmd.exe /status)
    $ds = ConvertFrom-DsregOutput $dsregText
}
catch { Add-Result 'Join' 'dsregcmd' 'FAIL' "Couldn't run dsregcmd /status: $($_.Exception.Message)" 'Windows 10 1607 or later is needed.' }

if ($ds) {
    $aad  = $ds['AzureAdJoined'] -eq 'YES'
    $dom  = $ds['DomainJoined'] -eq 'YES'
    $wpj  = $ds['WorkplaceJoined'] -eq 'YES'
    $tenant = if ($ds['TenantName']) { $ds['TenantName'] } else { $ds['TenantId'] }

    if ($aad -and $dom)  { Add-Result 'Join' 'Join type' 'PASS' "Hybrid Entra joined ($($ds['DomainName']), tenant $tenant)" }
    elseif ($aad)        { Add-Result 'Join' 'Join type' 'PASS' "Entra joined (tenant $tenant)" }
    elseif ($dom)        { Add-Result 'Join' 'Join type' 'WARN' "Domain joined ($($ds['DomainName'])) but not in Entra" 'If this should be hybrid joined, check the diagnostics below, Entra Connect sync scope and the SCP. Expected if hybrid join isn''t used.' }
    elseif ($wpj)        { Add-Result 'Join' 'Join type' 'WARN' 'Entra registered only (workplace join), not joined' 'Registered devices get app policies, not full device management. Join it if it''s a company device.' }
    else                 { Add-Result 'Join' 'Join type' 'FAIL' 'Not joined to Entra or a domain' 'Settings > Accounts > Access work or school > Connect, or rebuild with Autopilot.' }

    if ($aad) {
        Add-Result 'Join' 'Device ID' 'INFO' $ds['DeviceId']

        switch ($ds['DeviceAuthStatus']) {
            'SUCCESS' { Add-Result 'Join' 'Device auth' 'PASS' 'Device authenticates to Entra' }
            $null     { Add-Result 'Join' 'Device auth' 'INFO' 'Not reported by this Windows build' }
            default   { Add-Result 'Join' 'Device auth' 'FAIL' "DeviceAuthStatus: $($ds['DeviceAuthStatus'])" 'The device object may be disabled or deleted in Entra (Entra admin centre > Devices). Entra joined: dsregcmd /forcerecovery as admin; otherwise leave and rejoin.' }
        }

        if ($ds['TpmProtected'] -eq 'YES') { Add-Result 'Join' 'TPM-protected key' 'PASS' 'Device key is held in the TPM' }
        else { Add-Result 'Join' 'TPM-protected key' 'WARN' "TpmProtected: $($ds['TpmProtected'])" 'Device key is software-only. Check the TPM is on and ready (tpm.msc); rejoin after fixing it.' }

        $validity = $ds['DeviceCertificateValidity']
        if ($validity -match '--\s*(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})') {
            $certEnd = [datetime]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            if ($certEnd -lt $now) { Add-Result 'Join' 'Device certificate' 'FAIL' "Expired $($certEnd.ToString('yyyy-MM-dd'))" 'Leave and rejoin Entra to get a new device certificate.' }
            else { Add-Result 'Join' 'Device certificate' 'PASS' "Valid until $($certEnd.ToString('yyyy-MM-dd'))" }
        }
    }

    # Primary Refresh Token - only meaningful for a real user session
    $account = $ds['Executing Account Name']
    if ($account -match 'SYSTEM$|^NT AUTHORITY') {
        Add-Result 'Join' 'SSO token (PRT)' 'INFO' 'Running as SYSTEM - the PRT check needs a user session'
    }
    elseif ($aad -or $wpj) {
        if ($ds['AzureAdPrt'] -eq 'YES') {
            Add-Result 'Join' 'SSO token (PRT)' 'PASS' "PRT present for $account (updated $($ds['AzureAdPrtUpdateTime']))"
        }
        else {
            $hint = 'Sign out and back in as the user. If it persists, check the Attempt Status / error codes below.'
            Add-Result 'Join' 'SSO token (PRT)' 'FAIL' "No Primary Refresh Token for $account - M365 apps will keep prompting" $hint
        }
    }

    # Diagnostic error details (only present when something failed) - one line, named if we know the code
    $diag = foreach ($k in 'Client ErrorCode', 'Server ErrorCode', 'Server Error Code', 'Attempt Status', 'Server Message', 'Server Error Description') {
        $v = $ds[$k]
        if ($v -and $v -notmatch '^(0x0+|0|S_OK|SUCCESS|N/A|undefined)$') { "${k}: $v" }
    }
    if ($diag) {
        $known = Get-KnownError ($diag -join ' ')
        Add-Result 'Join' 'Join error details' 'WARN' ($diag -join '; ') $(if ($known) { $known } else { 'Search the code plus "dsregcmd" - Microsoft documents most of them.' })
    }
}

# ================================================================================================
#  MDM enrolment
# ================================================================================================
$enrolment = $null
try {
    $enrolment = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction Stop |
        Where-Object { $_.ProviderID -eq 'MS DM Server' }) | Select-Object -First 1
}
catch { Write-Verbose "Enrollments key unreadable: $($_.Exception.Message)" }

if ($enrolment) {
    $guid = $enrolment.PSChildName
    Add-Result 'Enrolment' 'MDM enrolment' 'PASS' ("Enrolled as {0}" -f $(if ($enrolment.UPN) { $enrolment.UPN } else { '(no UPN - device/Autopilot enrolment)' }))

    $conn = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$guid\Protected\ConnInfo" -ErrorAction SilentlyContinue
    $lastOk   = if ($conn) { ConvertFrom-OmaDmTime $conn.ServerLastSuccessTime } else { $null }
    $lastFail = if ($conn) { ConvertFrom-OmaDmTime $conn.ServerLastFailureTime } else { $null }
    if (-not $lastOk) {
        Add-Result 'Enrolment' 'Last Intune check-in' 'WARN' 'No successful check-in recorded' 'Run with -Sync, then check Company Portal > Settings > Sync.'
    }
    else {
        $age = $now.ToUniversalTime() - $lastOk.ToUniversalTime()
        $ageText = if ($age.TotalHours -lt 1) { '{0:N0} min ago' -f $age.TotalMinutes } elseif ($age.TotalDays -lt 2) { '{0:N0} h ago' -f $age.TotalHours } else { '{0:N0} days ago' -f $age.TotalDays }
        $detail = "Last successful check-in $ageText ($($lastOk.ToLocalTime().ToString('yyyy-MM-dd HH:mm')))"
        if ($lastFail -and $lastFail -gt $lastOk) { $detail += "; a later check-in failed at $($lastFail.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" }
        if ($age.TotalDays -gt 7)      { Add-Result 'Enrolment' 'Last Intune check-in' 'FAIL' $detail 'Over a week: check the MDM certificate and network below, then -Sync. Devices silent for long enough get flagged non-compliant.' }
        elseif ($age.TotalHours -gt 24 -or ($lastFail -and $lastFail -gt $lastOk)) { Add-Result 'Enrolment' 'Last Intune check-in' 'WARN' $detail 'Run with -Sync and re-check.' }
        else { Add-Result 'Enrolment' 'Last Intune check-in' 'PASS' $detail }
    }

    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$guid\" -ErrorAction Stop) } catch { $tasks = @() }
    if ($tasks.Count) { Add-Result 'Enrolment' 'Sync tasks' 'PASS' "$($tasks.Count) EnterpriseMgmt task(s) present" }
    elseif ($IsElevated) { Add-Result 'Enrolment' 'Sync tasks' 'WARN' 'No EnterpriseMgmt sync tasks for this enrolment' 'Scheduled check-ins won''t run. Re-enrolling recreates them.' }
    else { Add-Result 'Enrolment' 'Sync tasks' 'INFO' 'Not checked - needs admin' }
}
else {
    $why = if ($ds -and $ds['AzureAdJoined'] -eq 'YES') {
        'Entra joined but not enrolled: check Entra > Mobility (MDM and WIP) > Microsoft Intune user scope, licences, and enrolment restrictions. Hybrid: the "Enable automatic MDM enrollment" GPO.'
    } else { 'Join the device to Entra first (or enrol via Company Portal for BYOD).' }
    Add-Result 'Enrolment' 'MDM enrolment' 'FAIL' 'Not enrolled in Intune' $why
}

$certs = @()
try { $certs = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction Stop) } catch { Write-Verbose 'Machine certificate store unreadable' }
$mdmCert = $certs | Where-Object { $_.Issuer -match 'Microsoft Intune MDM Device CA' } | Sort-Object NotAfter -Descending | Select-Object -First 1
if ($enrolment) {
    if (-not $mdmCert) { Add-Result 'Enrolment' 'Intune MDM certificate' 'FAIL' 'Missing from LocalMachine\My' 'Without it the device can''t check in. Re-enrol the device.' }
    elseif ($mdmCert.NotAfter -lt $now) { Add-Result 'Enrolment' 'Intune MDM certificate' 'FAIL' "Expired $($mdmCert.NotAfter.ToString('yyyy-MM-dd'))" 'It renews itself only while the device checks in. Expired means re-enrol.' }
    elseif ($mdmCert.NotAfter -lt $now.AddDays(30)) { Add-Result 'Enrolment' 'Intune MDM certificate' 'WARN' "Expires $($mdmCert.NotAfter.ToString('yyyy-MM-dd'))" 'It renews automatically if check-ins work. Run -Sync and watch the date move.' }
    else { Add-Result 'Enrolment' 'Intune MDM certificate' 'PASS' "Valid until $($mdmCert.NotAfter.ToString('yyyy-MM-dd'))" }
}

$push = Get-Service -Name 'dmwappushservice' -ErrorAction SilentlyContinue
if (-not $push) { Add-Result 'Enrolment' 'Push service' 'WARN' 'dmwappushservice not found' 'Intune can''t push sync requests; the device only checks in on its schedule.' }
elseif ([string]$push.StartType -eq 'Disabled') { Add-Result 'Enrolment' 'Push service' 'FAIL' 'dmwappushservice is disabled (often by a debloat script)' 'Set it back to Manual (Trigger Start): "Sync" in Intune does nothing until then.' }
else { Add-Result 'Enrolment' 'Push service' 'PASS' "dmwappushservice $($push.StartType), $($push.Status)" }

# ================================================================================================
#  Intune Management Extension
# ================================================================================================
$ime = Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue
if (-not $ime) {
    Add-Result 'Agent' 'Intune Management Extension' 'INFO' 'Not installed' 'Normal until a Win32 app, script or remediation is assigned - Intune installs it then.'
}
else {
    $exe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe'
    $ver = if (Test-Path -LiteralPath $exe) { (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } else { 'unknown version' }
    if ($ime.Status -eq 'Running') { Add-Result 'Agent' 'Intune Management Extension' 'PASS' "Running ($ver)" }
    else { Add-Result 'Agent' 'Intune Management Extension' 'WARN' "Service is $($ime.Status) ($ver)" 'Start it, or run with -Sync. Apps and scripts won''t arrive while it''s stopped.' }

    $imeLog = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log'
    if (Test-Path -LiteralPath $imeLog) {
        $logAge = $now - (Get-Item -LiteralPath $imeLog).LastWriteTime
        $status = if ($logAge.TotalDays -gt 2) { 'WARN' } else { 'INFO' }
        Add-Result 'Agent' 'IME log activity' $status ('Last written {0:N0} h ago' -f $logAge.TotalHours) $(if ($status -eq 'WARN') { 'The agent has gone quiet. Restart the service (-Sync) and watch the log.' })
    }
}

# ================================================================================================
#  Event logs
# ================================================================================================
$since = $now.AddDays(-$EventDays)
foreach ($log in @(
        @{ Name = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'; Label = 'MDM event log' }
        @{ Name = 'Microsoft-Windows-AAD/Operational'; Label = 'AAD event log' })) {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log.Name; Level = 2; StartTime = $since } -MaxEvents 500 -ErrorAction Stop)
    }
    catch {
        if ($_.Exception.Message -match 'No events were found') { $events = @() }
        else { Add-Result 'Events' $log.Label 'INFO' "Couldn't read: $($_.Exception.Message)"; continue }
    }
    if (-not $events.Count) { Add-Result 'Events' $log.Label 'PASS' "No errors in the last $EventDays days"; continue }

    $top = $events | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object {
        $msg = (([string]$_.Group[0].Message) -split "`r?`n")[0]
        if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) + '...' }
        'ID {0} x{1}: {2}' -f $_.Name, $_.Count, $msg
    }
    $known = Get-KnownError (($events | Select-Object -First 50 | ForEach-Object { $_.Message }) -join ' ')
    Add-Result 'Events' $log.Label 'WARN' ("{0} error(s) in {1} days. Top: {2}" -f $events.Count, $EventDays, ($top -join ' | ')) `
        $(if ($known) { $known } else { 'A few are normal noise. Look for the same ID repeating, and compare times with the last check-in.' })
}

# ================================================================================================
#  Network
# ================================================================================================
if (-not $SkipNetwork) {
    foreach ($h in 'login.microsoftonline.com', 'enterpriseregistration.windows.net', 'enrollment.manage.microsoft.com') {
        $r = Test-Port -HostName $h
        if ($r -eq 'ok') { Add-Result 'Network' $h 'PASS' 'HTTPS reachable' }
        else { Add-Result 'Network' $h 'FAIL' "Not reachable on 443 ($r)" 'Check firewall / proxy / DNS. Intune and Entra need these endpoints unauthenticated.' }
    }
}

# ================================================================================================
#  Actions
# ================================================================================================
if ($Sync) {
    if ($enrolment) {
        $pushTask = @(Get-ScheduledTask -TaskPath "\Microsoft\Windows\EnterpriseMgmt\$($enrolment.PSChildName)\" -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -eq 'PushLaunch' }) | Select-Object -First 1
        if ($pushTask) {
            try { $pushTask | Start-ScheduledTask; Add-Result 'Action' 'MDM sync' 'INFO' 'Check-in triggered (PushLaunch)' }
            catch { Add-Result 'Action' 'MDM sync' 'WARN' "Couldn't start PushLaunch: $($_.Exception.Message)" 'Use Company Portal > Settings > Sync.' }
        }
        else { Add-Result 'Action' 'MDM sync' 'WARN' 'PushLaunch task not found' 'Use Company Portal > Settings > Sync, or Access work or school > Info > Sync.' }
    }
    if ($ime) {
        try { Restart-Service -Name 'IntuneManagementExtension' -Force -ErrorAction Stop; Add-Result 'Action' 'IME check-in' 'INFO' 'Intune Management Extension restarted (checks in on start)' }
        catch { Add-Result 'Action' 'IME check-in' 'WARN' "Couldn't restart the IME: $($_.Exception.Message)" }
    }
}

# ================================================================================================
#  Report
# ================================================================================================
$fails = @($Results | Where-Object Status -eq 'FAIL').Count
$warns = @($Results | Where-Object Status -eq 'WARN').Count
$summary = if ($fails) { "FAIL: $fails failure(s), $warns warning(s)" } elseif ($warns) { "WARN: $warns warning(s), no failures" } else { 'PASS: no problems found' }

if ($Quiet) {
    $first = $Results | Where-Object Status -eq 'FAIL' | Select-Object -First 1
    Write-Output ($summary + $(if ($first) { " - $($first.Check): $($first.Detail)" }))
}
else {
    Write-Host ''
    Write-Host ("== Entra / Intune health - {0} " -f $env:COMPUTERNAME).PadRight(78, '=') -ForegroundColor Cyan
    if (-not $IsElevated) { Write-Host '   (not elevated: sync tasks unchecked, -Sync and -CollectLogs unavailable)' -ForegroundColor DarkGray }
    $lastArea = $null
    foreach ($r in $Results) {
        if ($r.Area -ne $lastArea) { Write-Host "`n  $($r.Area.ToUpper())" -ForegroundColor Cyan; $lastArea = $r.Area }
        $colour = switch ($r.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
        Write-Host ('   [{0}] ' -f $r.Status) -ForegroundColor $colour -NoNewline
        Write-Host ('{0,-28} {1}' -f $r.Check, $r.Detail)
        if ($r.Fix -and $r.Status -in 'WARN', 'FAIL') { Write-Host ('{0,36}-> {1}' -f '', $r.Fix) -ForegroundColor DarkGray }
    }
    $sumColour = if ($fails) { 'Red' } elseif ($warns) { 'Yellow' } else { 'Green' }
    Write-Host "`n  $summary" -ForegroundColor $sumColour
}

if ($CollectLogs) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bundle = Join-Path $OutputFolder ('EntraIntune_{0}_{1}' -f $env:COMPUTERNAME, $stamp)
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null

    $dsregText | Set-Content -LiteralPath (Join-Path $bundle 'dsregcmd-status.txt') -Encoding UTF8
    $Results | Export-Csv -LiteralPath (Join-Path $bundle 'health-results.csv') -NoTypeInformation -Encoding UTF8

    $imeLogs = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
    if (Test-Path -LiteralPath $imeLogs) { Copy-Item -LiteralPath $imeLogs -Destination (Join-Path $bundle 'IME-Logs') -Recurse -ErrorAction SilentlyContinue }

    # Each collector is best effort: a missing tool or locked log shouldn't lose the rest of the bundle.
    $wevtutil = Join-Path $env:SystemRoot 'System32\wevtutil.exe'
    if (Test-Path -LiteralPath $wevtutil) {
        foreach ($log in 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin',
                         'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Operational',
                         'Microsoft-Windows-AAD/Operational') {
            $file = Join-Path $bundle (($log -replace '[/\\]', '_') + '.evtx')
            try { & $wevtutil epl $log $file 2>$null } catch { Write-Verbose "Couldn't export ${log}: $($_.Exception.Message)" }
        }
    }

    $mdmDiag = Join-Path $env:SystemRoot 'System32\MdmDiagnosticsTool.exe'
    if (Test-Path -LiteralPath $mdmDiag) {
        if (-not $Quiet) { Write-Host '  Running MdmDiagnosticsTool (a minute or two)...' -ForegroundColor DarkGray }
        try { & $mdmDiag -area 'DeviceEnrollment;DeviceProvisioning;Autopilot' -zip (Join-Path $bundle 'MdmDiagnostics.zip') | Out-Null }
        catch { Write-Verbose "MdmDiagnosticsTool failed: $($_.Exception.Message)" }
    }

    $zip = "$bundle.zip"
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zip -Force
    Remove-Item -LiteralPath $bundle -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $Quiet) { Write-Host "  Logs: $zip" -ForegroundColor Cyan }
}

if ($PassThru) { $Results }
if ($fails) { exit 1 }
exit 0
