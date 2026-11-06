<#
.SYNOPSIS
    New-laptop build in one pass, ending with an HTML build report.

.DESCRIPTION
    Runs the toolkit's build scripts in order, each in its own PowerShell process:

      1. Intune primary user   IntunePrimaryUser\Set-IntunePrimaryUser.ps1
                               Only with -PrimaryUser or -RemovePrimaryUser. Runs first, so the admin
                               sign-in happens while you're still at the PC. The rest runs unattended.
      2. McAfee removal        McAfeeRemoval\AVNuke.ps1
      3. OEM debloat           OEMDebloat\Invoke-BuildDebloat.ps1 -Force
      4. Microsoft 365 Apps    M365Reset\Reset-M365Apps.ps1 -ProductID O365BusinessRetail
      5. Chrome + Reader       ChromeReader\Install-ChromeAndReader.ps1
      6. Vendor drivers        OEMUpdates\Invoke-OEMUpdate.ps1 -Install -InstallTool
                               Dell / HP / Lenovo drivers and firmware, no BIOS. Other makes are skipped.

    A failed step doesn't stop the build: every step runs and its result goes in the report. Each
    step's output shows live and is saved for the report (the sign-in step shows live only).

    Then it checks what's left: Windows Update (Windows' own scan, read-only), the vendor's driver,
    firmware and BIOS updates (vendor scan, read-only), and whether a restart is pending.

    The report opens at the end and is saved (HTML, plus the same data as JSON) in
    C:\ProgramData\DeploymentMaster\Reports. It has:
      - each step: what it does, result, exit code, time taken and its output
      - what's still to do: Windows updates, vendor updates (BIOS included), pending restart
      - device details: make, model, serial, BIOS, Windows, Entra, Intune, BitLocker, TPM, Secure Boot
      - app versions: Microsoft 365 Apps, Chrome, Reader, and confirmation McAfee is gone
      - the ticket number, who ran it and when, and a notes box for printing or saving as PDF

    Finally the PC restarts after a 60-second countdown ("shutdown /a" cancels) unless -SkipReboot.

.PARAMETER Ticket
    Ticket number to put on the build report.

.PARAMETER Technician
    Your name for the build report. Defaults to the Windows account running the build.

.PARAMETER PrimaryUser
    Make this user (their sign-in address) the device's Intune primary user, replacing the account
    the PC was set up with. You'll be asked to sign in as a tenant admin at the start.

.PARAMETER RemovePrimaryUser
    Remove the Intune primary user instead (a shared device).

.PARAMETER SkipDriverUpdates
    Skip the Dell / HP / Lenovo driver updates and the vendor scan in the report.

.PARAMETER SkipReboot
    Don't restart at the end (the report says a restart is still needed).

.PARAMETER NoOpen
    Don't open the report at the end.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Invoke-NewDeviceSetup.ps1 -Ticket 12345 -PrimaryUser jane.doe@contoso.com

.NOTES
    Run elevated on the target PC. Scripts are found in the toolkit's Tools folder (this script's parent).
    Internet is needed for Office, Chrome, Reader, the vendor updater and the Graph sign-in module.
    Expect 20-40 minutes, most of it the Office download and driver installs.
    Exit code: 0 = every step OK (or skipped), 1 = at least one step needs a look.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $Ticket,
    [string] $Technician,
    [string] $PrimaryUser,
    [switch] $RemovePrimaryUser,
    [switch] $SkipDriverUpdates,
    [switch] $SkipReboot,
    [switch] $NoOpen
)

$ErrorActionPreference = 'Continue'
$ToolsRoot   = Split-Path $PSScriptRoot -Parent          # Tools\ - sibling tool folders live here
$ToolkitRoot = Split-Path $ToolsRoot -Parent
$BaseDir     = Join-Path $env:ProgramData 'DeploymentMaster'
$LogDir      = Join-Path $BaseDir 'Logs'
$ReportDir   = Join-Path $BaseDir 'Reports'
$Stamp       = Get-Date -Format 'yyyyMMdd_HHmmss'
$RunDir      = Join-Path $LogDir "Build_$Stamp"
New-Item -Path $RunDir, $ReportDir -ItemType Directory -Force | Out-Null
$MasterLog   = Join-Path $LogDir "MasterDeploy_$Stamp.log"

. (Join-Path $PSScriptRoot 'BuildReport.ps1')

# Tools target Windows PowerShell 5.1, so steps always run in it.
$HostExe = $null
if ($env:SystemRoot) { $HostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
if (-not $HostExe -or -not (Test-Path -LiteralPath $HostExe)) { $HostExe = (Get-Process -Id $PID).Path }

function Write-MasterLog {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERR')][string]$Level = 'INFO')
    $line = '{0}  [{1,-4}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $MasterLog -Value $line
    $colour = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } default { 'Cyan' } }
    Write-Host $line -ForegroundColor $colour
}

function ConvertTo-ArgumentText {
    # Quote one value for a Windows command line.
    param([string] $Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    '"' + $escaped + '"'
}

function Invoke-CapturedProcess {
    # Run a step with its output shown live here and kept for the report. Its window and keyboard
    # stay this console's, so anything needing a console still has one.
    param([string] $Arguments, [string] $WorkingDirectory, [string] $OutputFile)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $HostExe
    $psi.Arguments              = $Arguments
    $psi.WorkingDirectory       = $WorkingDirectory
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $text = New-Object System.Text.StringBuilder
    $p = [System.Diagnostics.Process]::Start($psi)
    $errors = $p.StandardError.ReadToEndAsync()      # alongside stdout, so neither pipe fills and blocks
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        [void]$text.AppendLine($line)
        $colour = if ($line -match '\[(ERR|XX|FAIL)\]|\bERROR\b|\bFAILED\b') { 'Red' }
                  elseif ($line -match '\[(WARN|!!)\]|\bWARNING\b') { 'Yellow' }
                  elseif ($line -match '\[(OK|PASS)\]|\bSUCCESS') { 'Green' } else { 'Gray' }
        Write-Host "    $line" -ForegroundColor $colour
    }
    $p.WaitForExit()
    $err = $errors.Result
    if ($err -and $err.Trim()) {
        [void]$text.AppendLine('--- errors ---').AppendLine($err.TrimEnd())
        Write-Host ($err.TrimEnd() -replace '(?m)^', '    ') -ForegroundColor Red
    }
    $out = $text.ToString()
    try { Set-Content -LiteralPath $OutputFile -Value $out -Encoding UTF8 } catch { Write-Verbose "Couldn't save output: $($_.Exception.Message)" }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out }
}

function Read-ResultFile {
    param([string] $Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { Write-Verbose "Unreadable result file $Path" }
    }
    $null
}

# What each step does, from tools.json, so the report and the menu say the same thing.
$Briefs = @{}
try {
    foreach ($t in (Get-Content -LiteralPath (Join-Path $ToolkitRoot 'tools.json') -Raw | ConvertFrom-Json).tools) {
        $Briefs[$t.id] = (@($t.brief) -join ' ')
    }
}
catch { Write-Verbose 'tools.json not found next to Tools; using built-in descriptions' }

function Invoke-BuildStep {
    param([hashtable] $Step)
    $n = $script:StepNumber = $script:StepNumber + 1
    $brief = if ($Briefs[$Step.Id]) { $Briefs[$Step.Id] } else { $Step.Fallback }
    $rec = [ordered]@{
        Id = $Step.Id; Name = $Step.Name; Brief = $brief; Script = "Tools\$($Step.Script)"; Logs = $Step.Logs
        Status = 'OK'; ExitCode = $null; Note = $null; Started = Get-Date; Seconds = 0; Output = $null; OutputFile = $null; Details = $null
    }

    Write-MasterLog ('=' * 60)
    Write-MasterLog "STEP $n`: $($Step.Name)"
    Write-MasterLog ('=' * 60)

    if ($Step.Skip) {
        $rec.Status = 'SKIPPED'; $rec.Note = $Step.SkipWhy
        Write-MasterLog "Skipped: $($Step.SkipWhy)" 'WARN'
        return [pscustomobject]$rec
    }
    $path = Join-Path $ToolsRoot $Step.Script
    if (-not (Test-Path -LiteralPath $path)) {
        $rec.Status = 'MISSING'; $rec.Note = "Script not found: $path"
        Write-MasterLog $rec.Note 'ERR'
        return [pscustomobject]$rec
    }

    $argLine = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + @($Step.Args) | ForEach-Object { ConvertTo-ArgumentText ([string]$_) }) -join ' '
    $rec.OutputFile = Join-Path $RunDir ('{0:00}-{1}.log' -f $n, $Step.Id)
    try {
        if ($Step.Interactive) {
            # Sign-in windows need this console, so this step's output is shown, not captured.
            $p = Start-Process -FilePath $HostExe -ArgumentList $argLine -WorkingDirectory (Split-Path $path) -Wait -PassThru -NoNewWindow
            $rec.ExitCode = $p.ExitCode
            $rec.OutputFile = $null
        }
        else {
            $run = Invoke-CapturedProcess -Arguments $argLine -WorkingDirectory (Split-Path $path) -OutputFile $rec.OutputFile
            $rec.ExitCode = $run.ExitCode
            $rec.Output   = $run.Output
        }
    }
    catch {
        $rec.Status = 'FAILED'; $rec.Note = "Couldn't start it: $($_.Exception.Message)"
        Write-MasterLog $rec.Note 'ERR'
    }
    $rec.Seconds = ((Get-Date) - $rec.Started).TotalSeconds
    if ($Step.ResultFile) { $rec.Details = Read-ResultFile $Step.ResultFile }

    if ($rec.Status -ne 'FAILED') {
        if ($rec.ExitCode -in $Step.SuccessCodes) { $rec.Status = 'OK' }
        else { $rec.Status = 'CHECK'; $rec.Note = "Exit code $($rec.ExitCode). Check the output below and the step's logs." }
        if ($Step.After) { & $Step.After $rec }
    }
    $level = switch ($rec.Status) { 'OK' { 'OK' } 'SKIPPED' { 'WARN' } default { 'WARN' } }
    Write-MasterLog ("Finished '{0}' - exit code {1} [{2}] in {3}" -f $Step.Name, $rec.ExitCode, $rec.Status, (Format-BuildDuration $rec.Seconds)) $level
    [pscustomobject]$rec
}

# ================================================================================================
#  Start
# ================================================================================================
$started = Get-Date
if ($PrimaryUser -and $RemovePrimaryUser) {
    Write-MasterLog 'Give -PrimaryUser or -RemovePrimaryUser, not both. Nothing has been changed.' 'ERR'
    exit 1
}
if ($PrimaryUser) {
    $PrimaryUser = $PrimaryUser.Trim()
    if ($PrimaryUser -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        Write-MasterLog "'$PrimaryUser' doesn't look like a sign-in address (name@domain). Nothing has been changed." 'ERR'
        exit 1
    }
}
$runAs = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { [string]$env:USERNAME }
if (-not $Technician) { $Technician = $runAs }

Write-MasterLog "===== New device setup started on $env:COMPUTERNAME ====="
Write-MasterLog "Ticket: $(if ($Ticket) { $Ticket } else { '(none)' })   Technician: $Technician"
Write-MasterLog "Log: $MasterLog"

$puResult  = Join-Path $RunDir 'intune-primary-user.json'
$oemResult = Join-Path $RunDir 'oem-updates.json'
$puArgs = @('-ResultFile', $puResult)
if ($PrimaryUser) { $puArgs = @('-UserPrincipalName', $PrimaryUser) + $puArgs }
if ($RemovePrimaryUser) { $puArgs = @('-Remove') + $puArgs }

$puAfter = {
    param($rec)
    $d = $rec.Details
    if ($rec.Status -ne 'OK' -and $d -and $d.Message) { $rec.Note = "$($d.Message) (exit $($rec.ExitCode))" }
    elseif ($rec.Status -eq 'OK' -and $d -and $d.Message) { $rec.Note = $d.Message }
    elseif ($rec.Status -ne 'OK' -and -not $d) { $rec.Note = "Exit code $($rec.ExitCode) and no result recorded. Did the sign-in window get closed?" }
}

$oemAfter = {
    param($rec)
    $d = $rec.Details
    if ($d -and -not $d.Vendor) {
        $rec.Status = 'SKIPPED'
        $rec.Note = "Not a Dell, HP or Lenovo ($($d.Maker)). Windows Update covers its drivers; see Still to do."
    }
    elseif ($rec.ExitCode -eq 3010) { $rec.Note = 'Installed; a restart finishes them.' }
    elseif ($d -and $rec.Status -ne 'OK' -and $d.Message) { $rec.Note = "$($d.Message) (exit $($rec.ExitCode))" }
}

$steps = @(
    @{ Id = 'intune-primary-user'; Name = 'Intune primary user'; Script = 'IntunePrimaryUser\Set-IntunePrimaryUser.ps1'
       Args = $puArgs; SuccessCodes = @(0); Interactive = $true; ResultFile = $puResult; After = $puAfter
       Skip = -not ($PrimaryUser -or $RemovePrimaryUser); SkipWhy = 'Not asked for (no primary user given).'
       Fallback = 'Changes or removes the device''s Intune primary user.' }
    @{ Id = 'mcafee-removal'; Name = 'McAfee removal'; Script = 'McAfeeRemoval\AVNuke.ps1'; SuccessCodes = @(0, 3010)
       Logs = 'C:\ProgramData\McAfeeRemoval'; Fallback = 'Removes the McAfee that OEMs preinstall.' }
    @{ Id = 'oem-debloat'; Name = 'OEM debloat'; Script = 'OEMDebloat\Invoke-BuildDebloat.ps1'; Args = @('-Force'); SuccessCodes = @(0)
       Logs = 'C:\ProgramData\Debloat'; Fallback = 'Removes OEM and Windows consumer bloat.' }
    @{ Id = 'm365-reset'; Name = 'Microsoft 365 Apps reset + reinstall'; Script = 'M365Reset\Reset-M365Apps.ps1'
       Args = @('-ProductID', 'O365BusinessRetail'); SuccessCodes = @(0); Logs = 'C:\OfficeReset'
       Fallback = 'Removes any Office and installs a clean Microsoft 365 Apps.' }
    @{ Id = 'chrome-reader'; Name = 'Chrome + Adobe Reader'; Script = 'ChromeReader\Install-ChromeAndReader.ps1'; SuccessCodes = @(0)
       Logs = 'C:\ProgramData\AppDeploy\Logs'; Fallback = 'Installs Google Chrome and Adobe Acrobat Reader.' }
    @{ Id = 'oem-updates'; Name = 'Dell / HP / Lenovo drivers'; Script = 'OEMUpdates\Invoke-OEMUpdate.ps1'
       Args = @('-Install', '-InstallTool', '-ResultFile', $oemResult); SuccessCodes = @(0, 3010); ResultFile = $oemResult
       Skip = [bool]$SkipDriverUpdates; SkipWhy = 'Skipped (-SkipDriverUpdates).'; After = $oemAfter
       Logs = 'C:\ProgramData\OEMUpdates'; Fallback = 'Installs driver and firmware updates from the PC''s maker (no BIOS).' }
)

$script:StepNumber = 0
$results = foreach ($s in $steps) { if (-not $s.ContainsKey('Args')) { $s.Args = @() }; Invoke-BuildStep $s }

# The Graph sign-in module is cached for the primary user step; a client PC doesn't need to keep it.
if (-not $steps[0].Skip) {
    Remove-Item -LiteralPath (Join-Path (Join-Path $env:ProgramData 'EndpointToolkit') '_modules') -Recurse -Force -ErrorAction SilentlyContinue
}

# ================================================================================================
#  What's left
# ================================================================================================
Write-MasterLog ''
Write-MasterLog ('=' * 60)
Write-MasterLog 'CHECKING WHAT''S LEFT'
Write-MasterLog ('=' * 60)

$oemStep = $results | Where-Object { $_.Id -eq 'oem-updates' }
$oemScan = [ordered]@{ Status = 'Skipped'; Vendor = $null; Updates = @(); Message = $null; Output = $null; OutputFile = $null }
if ($SkipDriverUpdates) { $oemScan.Message = 'Not checked: driver updates were skipped for this build.' }
elseif ($oemStep.Details -and -not $oemStep.Details.Vendor) {
    $oemScan.Message = "Not a Dell, HP or Lenovo ($($oemStep.Details.Maker)). Windows Update covers its drivers (above)."
}
else {
    Write-MasterLog 'Scanning for vendor updates still available (BIOS included)...'
    $scanFile = Join-Path $RunDir 'oem-scan.json'
    $scanPath = Join-Path $ToolsRoot 'OEMUpdates\Invoke-OEMUpdate.ps1'
    $scanArgs = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scanPath, '-ScanOnly', '-IncludeBios', '-InstallTool', '-ResultFile', $scanFile) |
        ForEach-Object { ConvertTo-ArgumentText $_ }) -join ' '
    try {
        $scan = Invoke-CapturedProcess -Arguments $scanArgs -WorkingDirectory (Split-Path $scanPath) -OutputFile (Join-Path $RunDir 'oem-scan.log')
        $d = Read-ResultFile $scanFile
        $oemScan.Output = $scan.Output; $oemScan.OutputFile = Join-Path $RunDir 'oem-scan.log'
        if ($d) { $oemScan.Vendor = $d.Vendor }
        if ($d -and $scan.ExitCode -in @(0, 2)) { $oemScan.Status = 'OK'; $oemScan.Updates = @($d.Updates) }
        else {
            $oemScan.Status = 'Failed'
            $oemScan.Message = "Vendor scan didn't finish (exit $($scan.ExitCode))$(if ($d.Message) { ": $($d.Message)" })."
        }
    }
    catch { $oemScan.Status = 'Failed'; $oemScan.Message = "Vendor scan couldn't start: $($_.Exception.Message)" }
}

Write-MasterLog 'Asking Windows Update what''s still waiting (can take a few minutes)...'
$wu = Get-PendingWindowsUpdate -TimeoutSeconds 900
$reboot = Test-PendingReboot
Write-MasterLog 'Collecting device details and app versions...'
$device = Get-BuildDeviceInfo
$apps   = Get-BuildAppInfo

# ================================================================================================
#  Report
# ================================================================================================
$toolkit = 'Endpoint Toolkit'
try {
    $ver = (Import-PowerShellDataFile -LiteralPath (Join-Path $ToolkitRoot 'EndpointToolkit.psd1')).ModuleVersion
    $toolkit = "Endpoint Toolkit v$ver"
    $src = Join-Path $ToolkitRoot '.etk-source.json'
    if (Test-Path -LiteralPath $src) { $toolkit += " ($((Get-Content -LiteralPath $src -Raw | ConvertFrom-Json).ref))" }
}
catch { Write-Verbose 'Toolkit version unknown' }

$row = { param($label) ($device | Where-Object { $_.Label -eq $label } | Select-Object -First 1).Value }
$reportBase = Join-Path $ReportDir ('BuildReport_{0}_{1}' -f $env:COMPUTERNAME, $Stamp)
$report = [pscustomobject]@{
    Computer    = $env:COMPUTERNAME
    MakeModel   = & $row 'Make and model'
    Serial      = & $row 'Serial number'
    Ticket      = $Ticket
    Technician  = $Technician
    RunAs       = $runAs
    Started     = $started
    Finished    = Get-Date
    Toolkit     = $toolkit
    LogFolder   = $RunDir
    ReportFile  = "$reportBase.html"
    Restarting  = -not $SkipReboot
    Steps       = @($results)
    Outstanding = [pscustomobject]@{ WindowsUpdate = $wu; Oem = [pscustomobject]$oemScan; Reboot = $reboot }
    Device      = @($device)
    Apps        = @($apps)
}
try {
    ConvertTo-BuildReportHtml -Report $report | Set-Content -LiteralPath "$reportBase.html" -Encoding UTF8
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$reportBase.json" -Encoding UTF8
    Write-MasterLog "Build report: $reportBase.html" 'OK'
}
catch { Write-MasterLog "Couldn't write the build report: $($_.Exception.Message)" 'ERR' }

# ================================================================================================
#  Summary
# ================================================================================================
Write-MasterLog ''
Write-MasterLog ('=' * 60)
Write-MasterLog 'SUMMARY'
Write-MasterLog ('=' * 60)
foreach ($r in $results) {
    $lvl = if ($r.Status -in @('OK', 'SKIPPED')) { 'OK' } else { 'WARN' }
    $exitDisplay = if ($null -ne $r.ExitCode) { $r.ExitCode } else { 'n/a' }
    Write-MasterLog ('{0,-38} exit={1,-6} [{2}]' -f $r.Name, $exitDisplay, $r.Status) $lvl
}
$wuLine = if ($wu.Status -eq 'OK') { "$(@($wu.Updates).Count) waiting" } else { $wu.Status }
$oemLine = if ($oemScan.Status -eq 'OK') { "$(@($oemScan.Updates).Count) waiting" } else { $oemScan.Status }
Write-MasterLog "Windows Update: $wuLine   Vendor updates: $oemLine   Restart pending: $(if ($reboot.Pending) { 'yes' } else { 'no' })"

$needLook = @($results | Where-Object { $_.Status -notin @('OK', 'SKIPPED') })
if ($needLook) { Write-MasterLog "$($needLook.Count) step(s) need a look - see the build report." 'WARN' }
else { Write-MasterLog 'All steps completed cleanly.' 'OK' }

if (-not $NoOpen -and [Environment]::UserInteractive -and -not $PSSenderInfo -and (Test-Path -LiteralPath "$reportBase.html")) {
    try { Invoke-Item -LiteralPath "$reportBase.html" } catch { Write-Verbose 'Could not open the report' }
}

Write-MasterLog ''
if ($SkipReboot) {
    Write-MasterLog '-SkipReboot given - restart when ready.' 'WARN'
}
else {
    Write-MasterLog 'Restarting in 60 seconds to finish up. Run "shutdown /a" in another window to cancel.' 'OK'
    shutdown.exe /r /t 60 /c "New device setup complete - restarting to finish the build. Report: $reportBase.html"
}
if ($needLook) { exit 1 }
exit 0
