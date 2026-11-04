<#
.SYNOPSIS
    Master "run it and leave it" deployment script for new devices.

.DESCRIPTION
    Chains the four existing per-task scripts in one unattended pass, in this order:

      1. McAfee Nuke   (McAfeeRemoval\AVNuke.ps1)                - removes McAfee first,
                                                                    since its web-protection /
                                                                    WebAdvisor component can
                                                                    interfere with the silent
                                                                    downloads steps 3-4 do.
      2. Debloat       (OEMDebloat\Invoke-BuildDebloat.ps1 -Force) - strips OEM bloat / consumer
                                                                    appx / applies tweaks, so
                                                                    installs land on a clean box.
      3. 365 Nuke      (M365Reset\Reset-M365Apps.ps1)            - removes any preinstalled
                                                                    Office and reinstalls clean
                                                                    M365 Apps (Business license).
      4. Adobe Chrome  (ChromeReader\Install-ChromeAndReader.ps1)- installs Chrome + hardened
                                                                    Adobe Acrobat Reader.

    Each step runs as its own child PowerShell process (so none of their internal
    Start-Transcript / $ErrorActionPreference / variable state can collide with this
    script or with each other). Steps are NOT skipped on a bad exit code from a
    previous step - this is meant to run unattended, so every step always runs and
    failures are just recorded for the summary at the end.

    Sub-scripts are left completely untouched. This script only calls them.

    At the end, the machine reboots automatically after a 60-second cancellable
    countdown (Ctrl+C in this console, or `shutdown /a`, cancels it).

.PARAMETER SkipReboot
    Run everything but skip the automatic reboot at the end (just logs that one
    is recommended). Useful for testing this master script itself.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Invoke-NewDeviceSetup.ps1

.NOTES
    Run from an elevated PowerShell prompt on the target machine. Sub-scripts are
    resolved from the toolkit's Tools folder (this script's parent). Internet is
    required for steps 3 and 4. Expect 15-30+ minutes total, most of it the M365
    download.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$SkipReboot
)

$ErrorActionPreference = 'Continue'
$Root   = Split-Path $PSScriptRoot -Parent   # Tools\ folder - sibling tool folders live here
$LogDir = 'C:\ProgramData\DeploymentMaster\Logs'
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
$MasterLog = Join-Path $LogDir ("MasterDeploy_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-MasterLog {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR')][string]$Level = 'INFO')
    $line = '{0}  [{1,-4}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $MasterLog -Value $line
    $colour = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERR' {'Red'} default {'Cyan'} }
    Write-Host $line -ForegroundColor $colour
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessCodes = @(0, 3010)
    )

    Write-MasterLog ('=' * 60)
    Write-MasterLog "STEP: $Name"
    Write-MasterLog ('=' * 60)

    if (-not (Test-Path $ScriptPath)) {
        Write-MasterLog "Script not found: $ScriptPath - SKIPPING THIS STEP" 'ERR'
        return [pscustomobject]@{ Step = $Name; ExitCode = $null; Result = 'MISSING' }
    }

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"") + $ArgumentList

    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs `
             -WorkingDirectory (Split-Path $ScriptPath) -Wait -PassThru -NoNewWindow
        $code = $p.ExitCode
    }
    catch {
        Write-MasterLog "Failed to launch '$Name': $($_.Exception.Message)" 'ERR'
        return [pscustomobject]@{ Step = $Name; ExitCode = $null; Result = 'LAUNCH_FAILED' }
    }

    if ($code -in $SuccessCodes) {
        Write-MasterLog "Finished '$Name' - exit code $code [OK]" 'OK'
        return [pscustomobject]@{ Step = $Name; ExitCode = $code; Result = 'OK' }
    }
    else {
        Write-MasterLog "Finished '$Name' - exit code $code [CHECK LOG]" 'WARN'
        return [pscustomobject]@{ Step = $Name; ExitCode = $code; Result = 'WARN' }
    }
}

Write-MasterLog "===== New device setup started on $env:COMPUTERNAME ====="
Write-MasterLog "Master log: $MasterLog"

$results = @()

$results += Invoke-Step -Name 'McAfee Removal' `
    -ScriptPath (Join-Path $Root 'McAfeeRemoval\AVNuke.ps1') `
    -SuccessCodes @(0, 3010)

$results += Invoke-Step -Name 'OEM Debloat' `
    -ScriptPath (Join-Path $Root 'OEMDebloat\Invoke-BuildDebloat.ps1') `
    -ArgumentList @('-Force') `
    -SuccessCodes @(0)

$results += Invoke-Step -Name 'Microsoft 365 Reset' `
    -ScriptPath (Join-Path $Root 'M365Reset\Reset-M365Apps.ps1') `
    -ArgumentList @('-ProductID', 'O365BusinessRetail') `
    -SuccessCodes @(0)

$results += Invoke-Step -Name 'Chrome + Adobe Reader Install' `
    -ScriptPath (Join-Path $Root 'ChromeReader\Install-ChromeAndReader.ps1') `
    -SuccessCodes @(0)

Write-MasterLog ''
Write-MasterLog ('=' * 60)
Write-MasterLog 'SUMMARY'
Write-MasterLog ('=' * 60)
foreach ($r in $results) {
    $lvl = if ($r.Result -eq 'OK') { 'OK' } else { 'WARN' }
    $exitDisplay = if ($null -ne $r.ExitCode) { $r.ExitCode } else { 'n/a' }
    Write-MasterLog ('{0,-32} exit={1,-6} [{2}]' -f $r.Step, $exitDisplay, $r.Result) $lvl
}

$failures = $results | Where-Object { $_.Result -ne 'OK' }
if ($failures) {
    Write-MasterLog "$($failures.Count) step(s) need a look - check their individual logs " -Level WARN
    Write-MasterLog '  McAfee Removal        -> C:\ProgramData\McAfeeRemoval\' 'WARN'
    Write-MasterLog '  OEM Debloat           -> C:\ProgramData\Debloat\' 'WARN'
    Write-MasterLog '  Microsoft 365 Reset   -> C:\OfficeReset\' 'WARN'
    Write-MasterLog '  Chrome + Reader       -> C:\ProgramData\AppDeploy\Logs\' 'WARN'
}
else {
    Write-MasterLog 'All steps completed cleanly.' 'OK'
}

Write-MasterLog ''
if ($SkipReboot) {
    Write-MasterLog '-SkipReboot specified - reboot manually when ready.' 'WARN'
}
else {
    Write-MasterLog 'Rebooting in 60 seconds to finish up. Run "shutdown /a" in another window to cancel.' 'OK'
    shutdown.exe /r /t 60 /c "New device setup complete - restarting to finish McAfee/Debloat/M365/Chrome deployment."
}
