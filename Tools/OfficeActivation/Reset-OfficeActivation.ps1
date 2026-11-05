<#
.SYNOPSIS
    Resets Microsoft 365 Apps activation so Office can be signed in and activated fresh.

.DESCRIPTION
    For Office stuck on the wrong account, "Unlicensed Product", or refusing to activate after a
    user, licence or tenant change. Runs Microsoft's Get Help command line ResetOfficeActivation
    scenario, which automates Microsoft's "Reset activation state for Microsoft 365 Apps" steps:

      - closes every Office app
      - clears Office licences (OLicenseCleanup)
      - signs Office out of its cached work/school accounts (SignOutOfWamAccounts)
      - checks the device registration (dsregcmd) and, only if the device is workplace joined
        (registered, not Entra joined), cleans that up too (WPJCleanup)

    Afterwards: open any Office app and sign in with the user's account.

    Get Help is downloaded fresh each run (each build expires after 90 days) and only runs if
    it's signed by Microsoft. The download is removed afterwards; the output log is kept.

    The account sign-out applies to whoever is running this. If you elevate as a different admin
    account, the licence cleanup still covers the whole machine but the account sign-out clears the
    admin's accounts, not the user's. The tool warns when that's the case.

.PARAMETER WorkDir
    Where Get Help is downloaded to and its output log kept. Default C:\ProgramData\OfficeActivationReset.

.EXAMPLE
    .\Reset-OfficeActivation.ps1

.NOTES
    Run as Administrator. Needs internet access to download Get Help.
    Exit codes: 0 = reset done (Get Help result 80), 1 = anything else.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $WorkDir = (Join-Path $env:ProgramData 'OfficeActivationReset')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
. (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')

function Resolve-ActivationResult {
    # Reset Office Activation result codes, from Microsoft Learn: "Reset Office Activation scenario".
    param([int] $Code)
    $manual = 'Manual steps: https://learn.microsoft.com/office/troubleshoot/activation/reset-office-365-proplus-activation-state'
    $ok = $false
    $text = switch ($Code) {
        80 { $ok = $true; 'Activation reset. Open any Office app and sign in with the user''s account to activate.' }
        1  { 'Get Help wanted a switch it didn''t get (-CloseOffice). That''s a toolkit bug - please report it.' }
        71 { 'Get Help hit a problem. Try the Get Help app instead (Start > Get Help > "Office activation").' }
        72 { 'Get Help says it isn''t elevated. Rerun from an admin session.' }
        73 { "Clearing the Office licences (OLicenseCleanup) failed. $manual" }
        74 { "Checking the device registration (dsregcmd) failed. $manual" }
        75 { "Windows is older than 10 1803, which this needs. $manual" }
        76 { "Signing Office out of its cached accounts failed. $manual" }
        78 { "The device is workplace joined but Windows is older than 10 1809, which the cleanup needs. $manual" }
        79 { "Cleaning up the workplace join (WPJCleanup) failed. $manual" }
        default { 'Unrecognised result. The Get Help build may have expired (they last 90 days) - check the output log.' }
    }
    [pscustomobject]@{ Ok = $ok; Text = $text }
}

Write-Host "`n==> Office activation reset on $env:COMPUTERNAME" -ForegroundColor Cyan

$other = Get-OtherSignedInUser
if ($other) {
    Write-Host ("    [!!] Running as {0}, but {1} is signed in. Licences are cleared for the whole machine," -f `
        (Get-CurrentUserName), $other) -ForegroundColor Yellow
    Write-Host  "         but only this account gets signed out of Office. Have the user sign out in" -ForegroundColor Yellow
    Write-Host  "         Office (File > Account > Sign out) before they sign back in." -ForegroundColor Yellow
}

$log = Join-Path $WorkDir ('GetHelp_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
$exitCode = 1
try {
    Write-Host '    Downloading Microsoft Get Help...'
    $exe = Get-GetHelpCmd -WorkDir $WorkDir
    Write-Host '    [OK] GetHelpCmd.exe downloaded and signature verified' -ForegroundColor Green
    Write-Host '    Closing Office and resetting activation (a minute or two)...'

    $run    = Invoke-GetHelpScenario -Exe $exe -Scenario ResetOfficeActivation -Switches '-CloseOffice' -LogFile $log
    $result = Resolve-ActivationResult -Code $run.Code
    if ($result.Ok) {
        Write-Host "    [OK] $($result.Text)" -ForegroundColor Green
        $exitCode = 0
    }
    else { Write-Host "    [!!] Get Help result $($run.Code): $($result.Text)" -ForegroundColor Yellow }
    Write-Host "    Get Help output: $log"
}
catch {
    Write-Host "    [!!] Activation reset didn't run: $($_.Exception.Message)" -ForegroundColor Yellow
}
finally {
    Clear-GetHelpDownload -WorkDir $WorkDir
}

exit $exitCode
