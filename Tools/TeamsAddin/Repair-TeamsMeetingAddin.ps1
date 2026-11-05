<#
.SYNOPSIS
    Fixes the missing "Teams Meeting" button in classic Outlook for the signed-in user.

.DESCRIPTION
    Checks the things that make the Teams Meeting add-in vanish from classic Outlook, fixes the
    ones that can be fixed per user, and says exactly what to do about the rest:

      Installed       "Microsoft Teams Meeting Add-in for Microsoft Office" is installed, and not
                      the old 1.23.x version left over from classic Teams
      Registered      Outlook has the add-in registered (TeamsAddin.FastConnect)
      LoadBehavior    set to 3 (load at startup) - Microsoft's documented fix          [fixed]
      Disabled list   Outlook hasn't put it on its disabled-items list after a slow    [fixed]
                      or crashed start
      Keep enabled    it's on Outlook's do-not-disable list, so a slow start doesn't   [fixed]
                      get it switched off again

    These are the same checks Microsoft's Get Help troubleshooter makes. Get Help's own version
    isn't used because it only supports classic Teams.

    New Outlook doesn't use this add-in at all - it has Teams meetings built in (the Teams meeting
    toggle on a new event). The tool says so if new Outlook is switched on.

    Fixes are per user, so it runs as the user, not as admin. It closes classic Outlook first
    (settings are only read at startup). If it's run under a different account from the person
    signed in, it says so and stops unless you pass -Force.

.PARAMETER CheckOnly
    Report only; change nothing and don't close Outlook.

.PARAMETER Force
    Fix the account running this even though someone else is signed in.

.EXAMPLE
    .\Repair-TeamsMeetingAddin.ps1

.EXAMPLE
    .\Repair-TeamsMeetingAddin.ps1 -CheckOnly

.NOTES
    Exit codes: 0 = nothing wrong (or everything fixed), 1 = something still needs doing.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')

$me          = Get-CurrentUserName
$ProgId      = 'TeamsAddin.FastConnect'
$AddinKeyCU  = "HKCU:\Software\Microsoft\Office\Outlook\Addins\$ProgId"
$AddinKeysLM = @("HKLM:\Software\Microsoft\Office\Outlook\Addins\$ProgId", "HKLM:\Software\WOW6432Node\Microsoft\Office\Outlook\Addins\$ProgId")
$Resiliency  = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Resiliency'
$Uninstall   = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*')
$Reinstall   = 'Quit Teams and Outlook, start new Teams and wait for "Microsoft Teams Meeting Add-in" to appear in Settings > Apps > Installed apps, then open Outlook.'

$Results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string] $Check, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO', 'FIXED')] [string] $Status, [string] $Detail, [string] $Fix)
    $Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix })
}
function Get-RegValue {
    param([string] $Key, [string] $Name)
    if (-not (Test-Path -LiteralPath $Key)) { return $null }
    (Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue).$Name
}

Write-Host "`n==> Teams Meeting add-in check for $me" -ForegroundColor Cyan

$other = Get-OtherSignedInUser
if ($other -and -not $Force) {
    Write-Host "    [!!] $other is signed in, but this is running as $me, so it would check and fix the" -ForegroundColor Yellow
    Write-Host  "         wrong person's Outlook. Run it from the user's own session (not elevated), or add -Force." -ForegroundColor Yellow
    exit 1
}

# -- Classic Outlook at all? ---------------------------------------------------------------------
$outlookPaths = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE',
                  'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE')
$classic = @($outlookPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
if (-not $classic) {
    Write-Host '    [INFO] Classic Outlook isn''t installed. New Outlook has Teams meetings built in - no add-in' -ForegroundColor Gray
    Write-Host '           needed. In a new event, switch on the "Teams meeting" toggle.' -ForegroundColor Gray
    exit 0
}
if ((Get-RegValue 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Preferences' 'UseNewOutlook') -eq 1) {
    Add-Result 'New Outlook' 'INFO' 'New Outlook is switched on for this user. The add-in only works in classic Outlook' `
        'In new Outlook, use the "Teams meeting" toggle on a new event. To get the button back, switch the "New Outlook" toggle off.'
}

# -- Installed and registered (not fixable per user, so we advise) ---------------------------------
$installed = @(Get-ItemProperty -Path $Uninstall -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like 'Microsoft Teams Meeting Add-in*' }) |
    Sort-Object { try { [version]$_.DisplayVersion } catch { [version]'0.0' } } -Descending | Select-Object -First 1
if (-not $installed) {
    Add-Result 'Installed' 'FAIL' 'The Teams Meeting add-in isn''t installed' "$Reinstall If it never appears, see Microsoft's steps: https://aka.ms/TMARepair"
}
elseif ([string]$installed.DisplayVersion -like '1.23.*') {
    Add-Result 'Installed' 'WARN' "Old version $($installed.DisplayVersion) left over from classic Teams" `
        "Run Microsoft's UninstallOldTMA.ps1 (https://aka.ms/TMARepair) as admin. $Reinstall"
}
else { Add-Result 'Installed' 'PASS' "Version $($installed.DisplayVersion)" }

$regCU = Test-Path -LiteralPath $AddinKeyCU
$regLM = @($AddinKeysLM | Where-Object { Test-Path -LiteralPath $_ })
if (-not $regCU -and -not $regLM.Count) {
    if ($installed) {
        Add-Result 'Registered' 'FAIL' 'Installed, but Outlook has no registration for it' `
            "Run Microsoft's UninstallTMA.ps1 (https://aka.ms/AAsllbb), then: $Reinstall"
    }
}
else { Add-Result 'Registered' 'PASS' $(if ($regCU) { 'Registered for this user' } else { 'Registered for all users' }) }

# -- Per-user settings Outlook uses to decide whether to load it (fixable) -------------------------
$todo = New-Object System.Collections.Generic.List[object]

if ($regCU) {
    $lb = Get-RegValue $AddinKeyCU 'LoadBehavior'
    if ($lb -ne 3) {
        $todo.Add([pscustomobject]@{ Check = 'LoadBehavior'; Detail = "Set to $(if ($null -eq $lb) { 'nothing' } else { $lb }), so Outlook doesn't load it at startup"
            Action = { New-ItemProperty -LiteralPath $AddinKeyCU -Name 'LoadBehavior' -PropertyType DWord -Value 3 -Force | Out-Null }; Done = 'Set to 3 (load at startup)' })
    }
    else { Add-Result 'LoadBehavior' 'PASS' '3 (load at startup)' }
}
elseif ($regLM.Count) {
    $lb = Get-RegValue $regLM[0] 'LoadBehavior'
    if ($lb -ne 3) { Add-Result 'LoadBehavior' 'WARN' "Machine-wide setting is $lb, not 3" 'Needs admin: set LoadBehavior to 3 under HKLM ...\Outlook\Addins\TeamsAddin.FastConnect, or reinstall the add-in.' }
    else { Add-Result 'LoadBehavior' 'PASS' '3 (load at startup, machine-wide)' }
}

$disabledKey = "$Resiliency\DisabledItems"
if (Test-Path -LiteralPath $disabledKey) {
    $props = Get-ItemProperty -LiteralPath $disabledKey -ErrorAction SilentlyContinue
    $hits = @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Value -is [byte[]] -and
        ([Text.Encoding]::Unicode.GetString($_.Value) -match 'teams') })
    foreach ($h in $hits) {
        $name = $h.Name
        $todo.Add([pscustomobject]@{ Check = 'Disabled list'; Detail = 'Outlook has disabled it (after a slow or crashed start)'
            Action = { Remove-ItemProperty -LiteralPath $disabledKey -Name $name -Force }.GetNewClosure(); Done = 'Removed from the disabled list' })
    }
    if (-not $hits) { Add-Result 'Disabled list' 'PASS' 'Not disabled by Outlook' }
}
else { Add-Result 'Disabled list' 'PASS' 'Not disabled by Outlook' }

$keepKey = "$Resiliency\DoNotDisableAddinList"
if ((Get-RegValue $keepKey $ProgId) -ne 1) {
    $todo.Add([pscustomobject]@{ Check = 'Keep enabled'; Detail = 'Not on the do-not-disable list, so Outlook can switch it off when it starts slowly'
        Action = { if (-not (Test-Path -LiteralPath $keepKey)) { New-Item -Path $keepKey -Force | Out-Null }
                   New-ItemProperty -LiteralPath $keepKey -Name $ProgId -PropertyType DWord -Value 1 -Force | Out-Null }
        Done = 'Added to the do-not-disable list' })
}
else { Add-Result 'Keep enabled' 'PASS' 'On the do-not-disable list' }

# -- Fix -------------------------------------------------------------------------------------------
if ($todo.Count -and -not $CheckOnly) {
    $session = (Get-Process -Id $PID).SessionId
    $open = @(Get-Process -Name 'outlook' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
    if ($open) {
        Write-Host '    Closing Outlook...'
        $open | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    foreach ($t in $todo) {
        try { & $t.Action; Add-Result $t.Check 'FIXED' $t.Done }
        catch { Add-Result $t.Check 'FAIL' "$($t.Detail) - couldn't fix: $($_.Exception.Message)" }
    }
}
else {
    foreach ($t in $todo) { Add-Result $t.Check 'WARN' $t.Detail 'Run without -CheckOnly to fix.' }
}

# -- Report ----------------------------------------------------------------------------------------
foreach ($r in $Results) {
    $colour = switch ($r.Status) { 'PASS' { 'Green' } 'FIXED' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ('    [{0}] ' -f $r.Status) -ForegroundColor $colour -NoNewline
    Write-Host ('{0}: {1}' -f $r.Check, $r.Detail)
    if ($r.Fix) { Write-Host ('{0,12}-> {1}' -f '', $r.Fix) -ForegroundColor DarkGray }
}

$pending = @($Results | Where-Object { $_.Status -in 'WARN', 'FAIL' })
if (@($Results | Where-Object Status -eq 'FIXED').Count) {
    Write-Host "`n    Now start Teams, then Outlook. The Teams Meeting button is under Calendar > New Teams Meeting." -ForegroundColor Cyan
}
elseif (-not $pending) {
    Write-Host "`n    Nothing wrong here. If the button's still missing, check the user's Teams meeting policy in the" -ForegroundColor Cyan
    Write-Host '    Teams admin centre (Outlook add-in allowed), then restart Teams and Outlook.' -ForegroundColor Cyan
}
if ($pending) { exit 1 }
exit 0
