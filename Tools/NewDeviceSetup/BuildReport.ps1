<#
.SYNOPSIS
    Build report helpers for Invoke-NewDeviceSetup.ps1. Dot-sourced; does nothing on its own.

.DESCRIPTION
    Get-BuildDeviceInfo        Make, model, serial, BIOS, Windows, Entra, Intune, BitLocker, TPM,
                               Secure Boot, disk and memory, as rows for the report.
    Get-BuildAppInfo           Office, Chrome and Reader versions, and whether any McAfee is left.
    Get-PendingWindowsUpdate   Windows' own update scan (read-only): updates and drivers still waiting.
                               Runs in a background job so a stuck scan can't hang the build.
    Test-PendingReboot         Whether Windows is waiting for a restart, and why.
    Format-BuildDuration       "2 min 14 s".
    ConvertTo-BuildReportHtml  The report as one self-contained HTML page (no internet needed to view).

    Every collector returns something even when a check fails ("Unknown", with the reason), so one
    broken check never costs you the whole report.
#>

function New-BuildRow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a report row object only.')]
    # One line of the device / apps tables. State: ok, warn, bad or info (colours the value).
    param([string] $Label, [string] $Value, [ValidateSet('ok', 'warn', 'bad', 'info')] [string] $State = 'info')
    [pscustomobject]@{ Label = $Label; Value = $Value; State = $State }
}

function Format-BuildDuration {
    param([double] $Seconds)
    $t = [TimeSpan]::FromSeconds([math]::Round([math]::Max(0, $Seconds)))
    if ($t.TotalHours -ge 1) { return '{0} h {1} min' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
    if ($t.TotalMinutes -ge 1) { return '{0} min {1} s' -f [int][math]::Floor($t.TotalMinutes), $t.Seconds }
    '{0} s' -f $t.Seconds
}

function Get-BuildInstalledApp {
    param([string] $Pattern)
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $Pattern })
}

function Get-BuildDeviceInfo {
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add((New-BuildRow 'Computer name' $env:COMPUTERNAME))

    try {
        $cs    = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $model = [string]$cs.Model
        if ([string]$cs.Manufacturer -match '^Lenovo') {
            try { $v = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).Version; if ($v) { $model = "$v ($model)" } } catch { Write-Verbose 'No Lenovo product name' }
        }
        $rows.Add((New-BuildRow 'Make and model' ("{0} {1}" -f $cs.Manufacturer, $model).Trim()))
        $rows.Add((New-BuildRow 'Memory' ('{0:N0} GB' -f ([double]$cs.TotalPhysicalMemory / 1GB))))
    }
    catch { $rows.Add((New-BuildRow 'Make and model' "Unknown ($($_.Exception.Message))" 'warn')) }

    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $rows.Add((New-BuildRow 'Serial number' ([string]$bios.SerialNumber)))
        $biosDate = if ($bios.ReleaseDate) { ' ({0:yyyy-MM-dd})' -f [datetime]$bios.ReleaseDate } else { '' }
        $rows.Add((New-BuildRow 'BIOS version' ("{0}{1}" -f $bios.SMBIOSBIOSVersion, $biosDate)))
    }
    catch { $rows.Add((New-BuildRow 'Serial number' "Unknown ($($_.Exception.Message))" 'warn')) }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $build = if ($cv -and $null -ne $cv.UBR) { "$($os.BuildNumber).$($cv.UBR)" } else { [string]$os.BuildNumber }
        $ver   = if ($cv -and $cv.DisplayVersion) { " $($cv.DisplayVersion)" } else { '' }
        $rows.Add((New-BuildRow 'Windows' ("{0}{1} (build {2})" -f $os.Caption, $ver, $build)))
    }
    catch { $rows.Add((New-BuildRow 'Windows' "Unknown ($($_.Exception.Message))" 'warn')) }

    $ds = @{}
    try {
        foreach ($l in @(dsregcmd.exe /status)) {
            if ($l -match '^\s*([A-Za-z][A-Za-z0-9 ]*?)\s*:\s*(.*?)\s*$' -and -not $ds.ContainsKey($Matches[1].Trim())) { $ds[$Matches[1].Trim()] = $Matches[2] }
        }
    }
    catch { Write-Verbose "dsregcmd failed: $($_.Exception.Message)" }
    if ($ds['AzureAdJoined'] -eq 'YES') {
        $rows.Add((New-BuildRow 'Entra ID' ("Joined to {0}" -f $(if ($ds['TenantName']) { $ds['TenantName'] } else { $ds['TenantId'] })) 'ok'))
    }
    elseif ($ds['DomainJoined'] -eq 'YES') { $rows.Add((New-BuildRow 'Entra ID' "Not Entra joined (domain joined to $($ds['DomainName']))" 'warn')) }
    elseif ($ds.Count) { $rows.Add((New-BuildRow 'Entra ID' 'Not joined' 'warn')) }
    else { $rows.Add((New-BuildRow 'Entra ID' 'Unknown (dsregcmd gave nothing)' 'warn')) }

    $enrol = $null
    try {
        $enrol = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction Stop |
            Where-Object { $_.ProviderID -eq 'MS DM Server' }) | Select-Object -First 1
    }
    catch { Write-Verbose 'Enrollments key unreadable' }
    if ($enrol) {
        $by = if ($enrol.UPN) { " by $($enrol.UPN)" } else { '' }
        $rows.Add((New-BuildRow 'Intune' "Enrolled$by" 'ok'))
    }
    else { $rows.Add((New-BuildRow 'Intune' 'Not enrolled' 'warn')) }

    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $hasKey = @($bl.KeyProtector | Where-Object { [string]$_.KeyProtectorType -eq 'RecoveryPassword' }).Count -gt 0
        $text = '{0}, {1}, {2}% encrypted{3}' -f $bl.ProtectionStatus, $bl.VolumeStatus, $bl.EncryptionPercentage, $(if ($hasKey) { ', recovery key set' } else { ', no recovery key yet' })
        $state = if ([string]$bl.ProtectionStatus -eq 'On' -and $hasKey) { 'ok' } else { 'warn' }
        $rows.Add((New-BuildRow 'BitLocker (system drive)' $text $state))
    }
    catch { $rows.Add((New-BuildRow 'BitLocker (system drive)' "Unknown ($($_.Exception.Message))" 'warn')) }

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $state = if ($tpm.TpmPresent -and $tpm.TpmReady) { 'ok' } else { 'warn' }
        $rows.Add((New-BuildRow 'TPM' ("Present: {0}, ready: {1}" -f $tpm.TpmPresent, $tpm.TpmReady) $state))
    }
    catch { $rows.Add((New-BuildRow 'TPM' "Unknown ($($_.Exception.Message))" 'warn')) }

    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        $rows.Add((New-BuildRow 'Secure Boot' $(if ($sb) { 'On' } else { 'Off' }) $(if ($sb) { 'ok' } else { 'warn' })))
    }
    catch { $rows.Add((New-BuildRow 'Secure Boot' 'Unknown (legacy BIOS, or not readable)' 'warn')) }

    try {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction Stop
        $free = [double]$disk.FreeSpace / 1GB; $size = [double]$disk.Size / 1GB
        $state = if ($size -and ($free / $size) -lt 0.15) { 'warn' } else { 'ok' }
        $rows.Add((New-BuildRow 'System drive' ('{0:N0} GB free of {1:N0} GB' -f $free, $size) $state))
    }
    catch { $rows.Add((New-BuildRow 'System drive' "Unknown ($($_.Exception.Message))" 'warn')) }

    $rows.ToArray()
}

function Get-BuildAppInfo {
    $rows = New-Object System.Collections.Generic.List[object]

    $c2r = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($c2r -and $c2r.VersionToReport) {
        $rows.Add((New-BuildRow 'Microsoft 365 Apps' ("{0} ({1}, {2})" -f $c2r.VersionToReport, $c2r.ProductReleaseIds, $c2r.Platform) 'ok'))
    }
    else { $rows.Add((New-BuildRow 'Microsoft 365 Apps' 'Not found' 'bad')) }

    foreach ($app in @(
            @{ Label = 'Google Chrome'; Pattern = '^Google Chrome$' }
            @{ Label = 'Adobe Acrobat Reader'; Pattern = '^Adobe Acrobat( Reader)?( \(64-bit\)| DC| \S+)*$' })) {
        $found = Get-BuildInstalledApp $app.Pattern | Select-Object -First 1
        if ($found) { $rows.Add((New-BuildRow $app.Label ([string]$found.DisplayVersion) 'ok')) }
        else { $rows.Add((New-BuildRow $app.Label 'Not found' 'bad')) }
    }

    $left = @(Get-BuildInstalledApp 'McAfee' | ForEach-Object { [string]$_.DisplayName })
    try { $left += @(Get-AppxPackage -AllUsers -Name '*McAfee*' -ErrorAction Stop | ForEach-Object { [string]$_.Name }) }
    catch { Write-Verbose 'Appx list unavailable' }
    if ($left) { $rows.Add((New-BuildRow 'McAfee' ('Still installed: ' + (($left | Select-Object -Unique) -join ', ')) 'bad')) }
    else { $rows.Add((New-BuildRow 'McAfee' 'Not found - removed' 'ok')) }

    $rows.ToArray()
}

function Get-PendingWindowsUpdate {
    # Windows' own scan (read-only) of updates and drivers still to install. A first scan on a new PC
    # can take several minutes; after -TimeoutSeconds it gives up rather than hold up the build.
    param([int] $TimeoutSeconds = 900)
    $job = Start-Job -ScriptBlock {
        $session = New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID = 'Endpoint Toolkit build report'
        $found = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
        foreach ($u in $found.Updates) {
            [pscustomobject]@{
                Title    = [string]$u.Title
                Kind     = $(if ([int]$u.Type -eq 2) { 'Driver' } else { 'Update' })
                KB       = (@($u.KBArticleIDs) | ForEach-Object { "KB$_" }) -join ', '
                Severity = [string]$u.MsrcSeverity
                Optional = [bool]$u.BrowseOnly
            }
        }
    }
    try {
        if (Wait-Job -Job $job -Timeout $TimeoutSeconds) {
            if ($job.State -eq 'Failed') { throw $job.ChildJobs[0].JobStateInfo.Reason }
            $items = @(Receive-Job -Job $job -ErrorAction Stop | Select-Object Title, Kind, KB, Severity, Optional)
            [pscustomobject]@{ Status = 'OK'; Message = $null; Updates = $items }
        }
        else {
            Stop-Job -Job $job
            [pscustomobject]@{ Status = 'TimedOut'; Message = ("Windows Update didn't answer within {0} minutes. Check Settings > Windows Update." -f [int]($TimeoutSeconds / 60)); Updates = @() }
        }
    }
    catch { [pscustomobject]@{ Status = 'Failed'; Message = "Windows Update scan failed: $($_.Exception.Message)"; Updates = @() } }
    finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
}

function Test-PendingReboot {
    $reasons = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Windows servicing' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    try {
        $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
        if ($sm.PendingFileRenameOperations) { $reasons += 'installers waiting to replace files' }
    }
    catch { Write-Verbose 'No pending file renames' }
    [pscustomobject]@{ Pending = ($reasons.Count -gt 0); Reasons = $reasons }
}

# ------------------------------------------------------------------------------------------------
#  HTML
# ------------------------------------------------------------------------------------------------

function ConvertTo-HtmlText {
    param($Value)
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-BuildPill {
    # Status word -> coloured pill.
    param([string] $Status)
    $map = @{ OK = 'ok', 'OK'; CHECK = 'warn', 'Check'; FAILED = 'bad', 'Failed'; MISSING = 'bad', 'Missing'; SKIPPED = 'skip', 'Skipped' }
    $m = if ($map.ContainsKey($Status)) { $map[$Status] } else { @('skip', $Status) }
    '<span class="pill {0}">{1}</span>' -f $m[0], (ConvertTo-HtmlText $m[1])
}

function ConvertTo-BuildRowsHtml {
    param($Rows)
    $out = foreach ($r in @($Rows)) {
        '<tr><td>{0}</td><td class="v {1}">{2}</td></tr>' -f (ConvertTo-HtmlText $r.Label), $r.State, (ConvertTo-HtmlText $r.Value)
    }
    '<table class="kv">' + ($out -join '') + '</table>'
}

function ConvertTo-BuildUpdateTableHtml {
    # Vendor update list (from Invoke-OEMUpdate -ResultFile) as a table.
    param($Updates)
    $rows = foreach ($u in @($Updates)) {
        $bios = if ($u.IsBios) { ' <span class="pill warn">BIOS</span>' } else { '' }
        '<tr><td>{0}{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f (ConvertTo-HtmlText $u.Name), $bios,
            (ConvertTo-HtmlText $u.Version), (ConvertTo-HtmlText $u.Type), (ConvertTo-HtmlText $u.Severity)
    }
    '<table><tr><th>Update</th><th>Version</th><th>Type</th><th>Severity</th></tr>' + ($rows -join '') + '</table>'
}

function ConvertTo-BuildOutputHtml {
    # A step's console output, collapsed. Very long output keeps its end (where results usually are).
    param([string] $Output, [string] $File, [int] $MaxChars = 200000)
    if ([string]::IsNullOrWhiteSpace($Output)) { return '' }
    $text  = $Output.TrimEnd()
    $lines = ($text -split "`n").Count
    $note  = ''
    if ($text.Length -gt $MaxChars) {
        $text = $text.Substring($text.Length - $MaxChars)
        $note = '<div class="small">Showing the end only. Full output: {0}</div>' -f (ConvertTo-HtmlText $File)
    }
    $count = if ($lines -eq 1) { '1 line' } else { "$lines lines" }
    '<details><summary>Output ({0})</summary>{1}<pre>{2}</pre></details>' -f $count, $note, (ConvertTo-HtmlText $text)
}

function ConvertTo-BuildReportHtml {
    param([Parameter(Mandatory)] $Report)
    $e = { param($v) ConvertTo-HtmlText $v }

    $steps   = @($Report.Steps)
    $ran     = @($steps | Where-Object { $_.Status -ne 'SKIPPED' })
    $okSteps = @($ran | Where-Object { $_.Status -eq 'OK' })
    $badSteps = @($ran | Where-Object { $_.Status -ne 'OK' })
    $wu      = $Report.Outstanding.WindowsUpdate
    $oem     = $Report.Outstanding.Oem
    $reboot  = $Report.Outstanding.Reboot
    $wuCount  = @($wu.Updates).Count
    $oemCount = @($oem.Updates).Count

    $banner = if ($badSteps.Count) {
        '<div class="banner warn">{0} of {1} steps need a look</div>' -f $badSteps.Count, $ran.Count
    }
    else { '<div class="banner ok">All {0} steps finished OK</div>' -f $ran.Count }

    $wuTile  = if ($wu.Status -eq 'OK') { [string]$wuCount } else { '?' }
    $oemTile = switch ($oem.Status) { 'OK' { [string]$oemCount } 'Skipped' { '-' } default { '?' } }
    # Leading commas keep each row as its own array (@() would flatten them into one list).
    $tiles = @(
        ,@('Steps OK', ('{0} / {1}' -f $okSteps.Count, $ran.Count), $(if ($badSteps.Count) { 'warn' } else { 'ok' }))
        ,@('Windows updates waiting', $wuTile, $(if ($wu.Status -ne 'OK' -or $wuCount) { 'warn' } else { 'ok' }))
        ,@(('{0} updates waiting' -f $(if ($oem.Vendor) { $oem.Vendor } else { 'Vendor' })), $oemTile, $(if ($oem.Status -eq 'OK' -and -not $oemCount) { 'ok' } elseif ($oem.Status -eq 'Skipped') { 'skip' } else { 'warn' }))
        ,@('Restart pending', $(if ($reboot.Pending) { 'Yes' } else { 'No' }), $(if ($reboot.Pending) { 'warn' } else { 'ok' }))
    )
    $tilesHtml = ($tiles | ForEach-Object { '<div class="tile {2}"><div class="k">{0}</div><div class="v">{1}</div></div>' -f (& $e $_[0]), (& $e $_[1]), $_[2] }) -join ''

    # Build details (tech notes)
    $meta = @(
        ,@('Ticket', $(if ($Report.Ticket) { $Report.Ticket } else { '(none given)' }))
        ,@('Technician', $Report.Technician)
        ,@('Ran as', $Report.RunAs)
        ,@('Started', $Report.Started.ToString('ddd d MMM yyyy, HH:mm'))
        ,@('Finished', $Report.Finished.ToString('ddd d MMM yyyy, HH:mm'))
        ,@('Took', (Format-BuildDuration ($Report.Finished - $Report.Started).TotalSeconds))
        ,@('Toolkit', $Report.Toolkit)
        ,@('Logs', $Report.LogFolder)
    )
    $metaHtml = '<table class="kv">' + (($meta | ForEach-Object { '<tr><td>{0}</td><td>{1}</td></tr>' -f (& $e $_[0]), (& $e $_[1]) }) -join '') + '</table>'

    # Steps
    $n = 0
    $stepHtml = foreach ($s in $steps) {
        $n++
        $metaBits = @()
        if ($null -ne $s.ExitCode) { $metaBits += "exit $($s.ExitCode)" }
        if ($s.Status -ne 'SKIPPED' -and $s.Seconds) { $metaBits += (Format-BuildDuration $s.Seconds) }
        $extra = ''
        if ($s.Note) { $extra += '<div class="note">{0}</div>' -f (& $e $s.Note) }
        if ($s.Id -eq 'oem-updates' -and $s.Details -and $s.Details.Installed -and @($s.Details.Updates).Count) {
            $extra += '<div class="small">Installed:</div>' + (ConvertTo-BuildUpdateTableHtml $s.Details.Updates)
        }
        if ($s.Id -eq 'intune-primary-user' -and $s.Details) {
            $d = $s.Details
            $was = if ($d.Before) { $d.Before } else { 'none' }
            $now = if ($d.After) { $d.After } else { 'none (shared device)' }
            $extra += '<table class="kv small"><tr><td>Primary user</td><td>{0} &rarr; {1}</td></tr><tr><td>Signed in as</td><td>{2}</td></tr><tr><td>Tenant</td><td>{3}</td></tr></table>' -f (& $e $was), (& $e $now), (& $e $d.SignedInAs), (& $e $d.Tenant)
        }
        $places = @()
        if ($s.Script) { $places += 'Script: ' + $s.Script }
        if ($s.Logs) { $places += 'Logs: ' + $s.Logs }
        $where = if ($places) { '<div class="small">{0}</div>' -f (& $e ($places -join '   |   ')) } else { '' }
        @"
<div class="step $(if ($s.Status -eq 'OK') { 'ok' } elseif ($s.Status -eq 'SKIPPED') { 'skip' } else { 'warn' })">
  <div class="head"><span class="n">$n</span><span class="name">$(& $e $s.Name)</span>$(Get-BuildPill $s.Status)<span class="meta">$(& $e ($metaBits -join '  |  '))</span></div>
  <div class="brief">$(& $e $s.Brief)</div>$extra$where$(ConvertTo-BuildOutputHtml -Output $s.Output -File $s.OutputFile)
</div>
"@
    }

    # Still to do
    $wuHtml = switch ($wu.Status) {
        'OK' {
            if (-not $wuCount) { '<p class="okline">Nothing waiting.</p>' }
            else {
                $rows = foreach ($u in @($wu.Updates)) {
                    $kind = if ($u.Optional) { "$($u.Kind) (optional)" } else { $u.Kind }
                    '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f (& $e $u.Title), (& $e $kind), (& $e $u.KB), (& $e $u.Severity)
                }
                '<table><tr><th>Update</th><th>Type</th><th>KB</th><th>Severity</th></tr>' + ($rows -join '') + '</table>'
            }
        }
        default { '<p class="warnline">{0}</p>' -f (& $e $wu.Message) }
    }
    $vendorName = if ($oem.Vendor) { $oem.Vendor } else { 'Dell / HP / Lenovo' }
    $oemHtml = switch ($oem.Status) {
        'OK' {
            if (-not $oemCount) { '<p class="okline">Nothing waiting (drivers, firmware and BIOS checked).</p>' }
            else { (ConvertTo-BuildUpdateTableHtml $oem.Updates) + '<p class="small">BIOS updates aren''t installed by the build. Run "OEM drivers + BIOS" with BIOS ticked, on mains power.</p>' }
        }
        'Skipped' { '<p class="skipline">{0}</p>' -f (& $e $oem.Message) }
        default   { '<p class="warnline">{0}</p>' -f (& $e $oem.Message) }
    }
    $oemHtml += ConvertTo-BuildOutputHtml -Output $oem.Output -File $oem.OutputFile
    $rebootHtml = if ($reboot.Pending) {
        $why = if ($Report.Restarting) { 'Expected after a build. The PC restarts at the end of it.' } else { 'Restart before handing the PC over.' }
        '<p class="warnline">Yes ({0}). {1}</p>' -f (& $e (@($reboot.Reasons) -join ', ')), (& $e $why)
    }
    else { '<p class="okline">No.</p>' }

    $title = "Build report - $($Report.Computer)"
    $sub = @($Report.MakeModel, $(if ($Report.Serial) { "Serial $($Report.Serial)" }), $Report.Started.ToString('d MMM yyyy')) | Where-Object { $_ }
@"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(& $e $title)</title>
<style>
 :root { --fg:#1f2328; --muted:#656d76; --line:#d8dee4; --soft:#f6f8fa; --accent:#0969da;
         --ok:#1a7f37; --okbg:#dafbe1; --warn:#9a6700; --warnbg:#fff8c5; --bad:#cf222e; --badbg:#ffebe9; }
 * { box-sizing: border-box; }
 body { font-family: "Segoe UI", Arial, sans-serif; color: var(--fg); background: #eef1f4; margin: 0; font-size: 14px; }
 .page { max-width: 1080px; margin: 24px auto; background: #fff; border: 1px solid var(--line); border-radius: 12px; padding: 28px 34px 22px; }
 .top { display: flex; align-items: flex-start; gap: 16px; }
 .top .titles { flex: 1; } h1 { font-size: 23px; margin: 0 0 4px; } .sub { color: var(--muted); }
 .tools button { font: inherit; font-size: 12.5px; border: 1px solid var(--line); background: #fff; border-radius: 6px; padding: 5px 10px; cursor: pointer; margin-left: 6px; }
 .tools button:hover { background: var(--soft); }
 .banner { margin: 18px 0 12px; padding: 11px 15px; border-radius: 8px; font-weight: 600; }
 .banner.ok { background: var(--okbg); color: var(--ok); } .banner.warn { background: var(--warnbg); color: var(--warn); }
 .tiles { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
 .tile { background: var(--soft); border-radius: 8px; padding: 10px 13px; border-left: 4px solid var(--line); }
 .tile.ok { border-left-color: var(--ok); } .tile.warn { border-left-color: #d4a72c; } .tile.skip { border-left-color: var(--line); }
 .tile .k { font-size: 12px; color: var(--muted); } .tile .v { font-size: 20px; font-weight: 600; margin-top: 2px; }
 h2 { font-size: 16px; margin: 30px 0 10px; padding-bottom: 6px; border-bottom: 2px solid var(--accent); }
 h3 { font-size: 14px; margin: 18px 0 6px; }
 table { border-collapse: collapse; width: 100%; font-size: 13px; }
 th { text-align: left; color: var(--muted); font-weight: 600; font-size: 12px; border-bottom: 1px solid var(--line); padding: 6px 8px; }
 td { border-bottom: 1px solid var(--line); padding: 7px 8px; vertical-align: top; }
 table.kv td:first-child { color: var(--muted); width: 200px; }
 td.v.ok { color: var(--ok); } td.v.warn { color: var(--warn); } td.v.bad { color: var(--bad); font-weight: 600; }
 .pill { display: inline-block; padding: 1px 9px; border-radius: 999px; font-size: 12px; font-weight: 600; white-space: nowrap; }
 .pill.ok { background: var(--okbg); color: var(--ok); } .pill.warn { background: var(--warnbg); color: var(--warn); }
 .pill.bad { background: var(--badbg); color: var(--bad); } .pill.skip { background: var(--soft); color: var(--muted); }
 .step { border: 1px solid var(--line); border-left: 4px solid var(--ok); border-radius: 8px; margin: 10px 0; padding: 11px 14px; }
 .step.warn { border-left-color: #d4a72c; } .step.skip { border-left-color: var(--line); background: #fbfcfd; }
 .step .head { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
 .step .n { color: var(--muted); font-weight: 600; min-width: 14px; } .step .name { font-weight: 600; font-size: 14.5px; }
 .step .meta { margin-left: auto; color: var(--muted); font-size: 12.5px; }
 .step .brief { color: #424a53; margin: 5px 0 0 24px; font-size: 13px; }
 .step .note, .step .small, .step table, .step details { margin-left: 24px; }
 .step table { width: calc(100% - 24px); }
 .note { margin-top: 6px; font-size: 13px; } .small { color: var(--muted); font-size: 12px; margin-top: 6px; }
 details { margin-top: 8px; } summary { cursor: pointer; color: var(--accent); font-size: 12.5px; }
 pre { background: #0d1117; color: #e6edf3; padding: 10px 12px; border-radius: 6px; font-size: 12px; line-height: 1.45;
       white-space: pre-wrap; word-break: break-word; max-height: 440px; overflow: auto; }
 .okline { color: var(--ok); } .warnline { color: var(--warn); } .skipline { color: var(--muted); }
 .notes { min-height: 90px; border: 1px dashed #b8c0c8; border-radius: 8px; padding: 10px 12px; outline: none; }
 .notes:empty:before { content: attr(data-placeholder); color: var(--muted); }
 .foot { color: var(--muted); font-size: 12px; margin-top: 28px; border-top: 1px solid var(--line); padding-top: 10px; }
 @media print {
   body { background: #fff; font-size: 12px; } .page { border: 0; margin: 0; padding: 0; max-width: none; }
   .tools { display: none; } pre { max-height: none; overflow: visible; } .step { break-inside: avoid; }
   .notes:empty:before { content: ''; }
 }
</style></head>
<body><div class="page">
<div class="top"><div class="titles"><h1>$(& $e $title)</h1><div class="sub">$(& $e ($sub -join '   |   '))</div></div>
<div class="tools"><button type="button" onclick="showAll(true)">Show all output</button><button type="button" onclick="window.print()">Print or save as PDF</button></div></div>
$banner
<div class="tiles">$tilesHtml</div>

<h2>Build</h2>
$metaHtml

<h2>Steps</h2>
$($stepHtml -join "`n")

<h2>Still to do</h2>
<h3>Windows Update</h3>
$wuHtml
<h3>$(& $e $vendorName) drivers, firmware and BIOS</h3>
$oemHtml
<h3>Restart pending</h3>
$rebootHtml

<h2>Device</h2>
$(ConvertTo-BuildRowsHtml $Report.Device)

<h2>Apps</h2>
$(ConvertTo-BuildRowsHtml $Report.Apps)

<h2>Notes</h2>
<div class="notes" contenteditable="true" data-placeholder="Type any notes here, then print or save as PDF for the ticket."></div>

<div class="foot">Endpoint Toolkit build report. Saved as $(& $e $Report.ReportFile)</div>
</div>
<script>
function showAll(open) { document.querySelectorAll('details').forEach(function (d) { d.open = open; }); }
window.addEventListener('beforeprint', function () { showAll(true); });
</script>
</body></html>
"@
}
