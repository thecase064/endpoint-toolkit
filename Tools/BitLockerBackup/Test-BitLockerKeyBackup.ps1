<#
.SYNOPSIS
    Checks that each BitLocker recovery key on this device has been backed up to Entra ID, and
    backs up any that haven't (with -Fix).

.DESCRIPTION
    BitLocker can show as on while its recovery key never reached Entra ID - so the day the device
    asks for its key, there isn't one to give. This finds out before that day.

    For every encrypted drive it looks at each recovery password and checks the BitLocker
    management event log for a successful backup to Entra (event 845) or a failed one (846).
    Without -Fix it only reports. With -Fix it backs up every key that has no successful backup on
    record (BackupToAAD-BitLockerKeyProtector). Backing up a key that's already in Entra is harmless.

    The recovery passwords themselves are never shown or logged - only their protector IDs.

    Limits: the event log is the device's own record and can roll over, so "no record" means
    "not proven", not "definitely missing". Entra (Devices > the device > BitLocker keys) is the
    final word. Backing up to Entra only works on Entra or hybrid joined devices.

.PARAMETER Fix
    Back up every recovery key that has no successful backup on record.

.PARAMETER Quiet
    Print only the one-line summary (for RMM monitors or an Intune remediation detection script).

.EXAMPLE
    .\Test-BitLockerKeyBackup.ps1

.EXAMPLE
    .\Test-BitLockerKeyBackup.ps1 -Fix

.NOTES
    Run as Administrator.
    Exit codes: 0 = every key is backed up, 1 = something isn't (or couldn't be checked).
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch] $Fix,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string] $Drive, [string] $Item, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')] [string] $Status, [string] $Detail, [string] $Fix)
    $Results.Add([pscustomobject]@{ Drive = $Drive; Item = $Item; Status = $Status; Detail = $Detail; Fix = $Fix })
}

function Get-ErrorHint {
    param([string] $Text)
    $code = if ($Text -match '(0x[0-9a-fA-F]{8})') { $Matches[1].ToUpper() -replace '^0X', '0x' } else { $null }
    $hint = switch ($code) {
        '0x80072EE7' { 'the device couldn''t resolve the Entra server name (DNS)' }
        '0x80072EFE' { 'the connection to Entra dropped' }
        '0x80072F8F' { 'a TLS/security error - check the clock and any proxy or SSL inspection' }
        default      { $null }
    }
    if ($code -and $hint) { "$code, $hint" } elseif ($code) { $code } else { $null }
}

# -- Entra join: BackupToAAD only works on Entra or hybrid joined devices ---------------------------
$joined = $false
try { $joined = [bool](@(dsregcmd /status) -match '^\s*AzureAdJoined\s*:\s*YES') } catch { $joined = $false }
if ($joined) { Add-Result '-' 'Entra join' 'PASS' 'Device is Entra joined (or hybrid joined)' }
else {
    Add-Result '-' 'Entra join' 'FAIL' 'Device isn''t Entra joined, so keys can''t be backed up to Entra' `
        'Fix the join first (Diagnose > Entra / Intune health check). Domain-only devices keep keys in AD instead.'
}

# -- What the event log says has been backed up ----------------------------------------------------
$events = @()
try {
    $log = Get-WinEvent -ListLog '*BitLocker*' -ErrorAction Stop |
        Where-Object { $_.LogName -match 'Management' -and $_.RecordCount } | Select-Object -First 1
    if ($log) {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log.LogName; Id = 845, 846 } -MaxEvents 500 -ErrorAction Stop |
            ForEach-Object {
                $msg = [string]$_.Message
                [pscustomobject]@{
                    Ok     = $_.Id -eq 845
                    Time   = $_.TimeCreated
                    Volume = if ($msg -match 'volume\s+([A-Za-z]:)') { $Matches[1].ToUpper() } else { $null }
                    Ids    = @([regex]::Matches($msg, '\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?') |
                             ForEach-Object { '{' + $_.Value.Trim('{', '}').ToUpper() + '}' })
                    Error  = Get-ErrorHint $msg
                }
            })
    }
}
catch { if ($_.Exception.Message -notmatch 'No events were found') { Write-Verbose "Event log: $($_.Exception.Message)" } }

# -- Each encrypted drive and its recovery passwords -----------------------------------------------
$volumes = @(Get-BitLockerVolume | Sort-Object MountPoint)
$allIds  = @($volumes | ForEach-Object { $_.KeyProtector } | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } |
    ForEach-Object { $_.KeyProtectorId.ToUpper() })

foreach ($v in $volumes) {
    $drive = $v.MountPoint
    if ([string]$v.VolumeStatus -eq 'FullyDecrypted') {
        if ([string]$v.VolumeType -eq 'OperatingSystem') {
            Add-Result $drive 'Encryption' 'WARN' 'Not encrypted, so there''s no key to back up' 'Check the BitLocker policy assigned in Intune.'
        }
        continue
    }
    $recovery = @($v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
    if (-not $recovery) {
        Add-Result $drive 'Recovery password' 'FAIL' 'Encrypted, but has no recovery password at all - nothing to back up' `
            "Add one: Add-BitLockerKeyProtector -MountPoint $drive -RecoveryPasswordProtector, then run this with -Fix."
        continue
    }

    foreach ($p in $recovery) {
        $id   = $p.KeyProtectorId.ToUpper()
        $item = "Key $id"
        # Events naming this key; or events for this drive that don't name a key we know about.
        $mine = @($events | Where-Object {
            ($_.Ids -contains $id) -or ($_.Volume -eq $drive.ToUpper() -and -not @($_.Ids | Where-Object { $allIds -contains $_ }).Count) })
        $ok   = $mine | Where-Object Ok | Sort-Object Time -Descending | Select-Object -First 1
        $bad  = $mine | Where-Object { -not $_.Ok } | Sort-Object Time -Descending | Select-Object -First 1
        $state = if ($ok -and (-not $bad -or $ok.Time -ge $bad.Time)) { 'backed' }
                 elseif ($bad) { 'failed' } else { 'unknown' }

        if ($state -ne 'backed' -and $Fix -and $joined) {
            try {
                BackupToAAD-BitLockerKeyProtector -MountPoint $drive -KeyProtectorId $p.KeyProtectorId -ErrorAction Stop | Out-Null
                Add-Result $drive $item 'PASS' 'Backed up to Entra just now'
                continue
            }
            catch {
                $why = Get-ErrorHint $_.Exception.Message
                $msg = if ($why) { $why } else { $_.Exception.Message }
                Add-Result $drive $item 'FAIL' "Backup to Entra failed: $msg" 'Check the device can reach Entra (Diagnose > Entra / Intune health check), then retry.'
                continue
            }
        }

        switch ($state) {
            'backed'  { Add-Result $drive $item 'PASS' ('Backed up to Entra {0:yyyy-MM-dd HH:mm}' -f $ok.Time) }
            'failed'  {
                $why = if ($bad.Error) { ": $($bad.Error)" } else { '' }
                Add-Result $drive $item 'FAIL' ('Last backup attempt failed {0:yyyy-MM-dd HH:mm}{1}' -f $bad.Time, $why) 'Run with -Fix once the cause is sorted.'
            }
            default   { Add-Result $drive $item 'WARN' 'No backup on record in the event log (may never have reached Entra)' 'Run with -Fix, or check the device''s BitLocker keys in Entra.' }
        }
    }
}

# -- Report ------------------------------------------------------------------------------------------
$fails = @($Results | Where-Object Status -eq 'FAIL').Count
$warns = @($Results | Where-Object Status -eq 'WARN').Count
$keys  = @($Results | Where-Object { $_.Item -like 'Key *' })
$notOk = @($keys | Where-Object Status -ne 'PASS').Count
$summary = if (-not ($fails -or $warns)) {
    '{0} BitLocker key backup - all {1} key(s) backed up to Entra' -f $env:COMPUTERNAME, $keys.Count
} elseif ($notOk) {
    '{0} BitLocker key backup - {1} of {2} key(s) not proven backed up to Entra' -f $env:COMPUTERNAME, $notOk, $keys.Count
} else {
    '{0} BitLocker key backup - {1} problem(s), see details' -f $env:COMPUTERNAME, ($fails + $warns)
}

if ($Quiet) { Write-Output $summary }
else {
    Write-Host "`n==> BitLocker key backup on $env:COMPUTERNAME" -ForegroundColor Cyan
    foreach ($r in $Results) {
        $colour = switch ($r.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
        Write-Host ('    [{0}] ' -f $r.Status) -ForegroundColor $colour -NoNewline
        Write-Host ('{0,-3} {1}: {2}' -f $r.Drive, $r.Item, $r.Detail)
        if ($r.Fix) { Write-Host ('{0,15}-> {1}' -f '', $r.Fix) -ForegroundColor DarkGray }
    }
    if (-not $Fix -and $notOk -and $joined) {
        Write-Host "`n    Run again with -Fix (or answer yes in the menu) to back them up now." -ForegroundColor Cyan
    }
    Write-Host "`n    Summary: $summary" -ForegroundColor Cyan
}

if ($fails -or $warns) { exit 1 }
exit 0
