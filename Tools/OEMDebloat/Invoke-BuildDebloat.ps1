<#
.SYNOPSIS
    Debloat script for fresh HP / Dell builds.

.DESCRIPTION
    Removes OEM consumer bloat and Windows consumer apps while keeping the
    driver / support tooling worth having (Dell SupportAssist, HP Support
    Assistant, hotkey and system drivers).

    Everything it removes is driven by the $Remove* lists near the top.
    Anything matching a $Keep* pattern is protected, even if it also matches
    a remove pattern. Edit those lists, don't edit the logic.

.PARAMETER DryRun
    Log what would be removed, change nothing. Always run this first on a new model.

.PARAMETER Force
    Attempt silent uninstall of EXE-based apps that have no known silent switch.
    Without this, they are logged for manual handling instead of launching a GUI.

.PARAMETER SkipAppx
    Skip the Store/Appx section.

.PARAMETER SkipTweaks
    Skip the registry tweaks section.

.EXAMPLE
    .\Invoke-BuildDebloat.ps1 -DryRun
    .\Invoke-BuildDebloat.ps1
    .\Invoke-BuildDebloat.ps1 -Force

.NOTES
    Run as Administrator (or as SYSTEM via Intune / RMM).
    Reboot afterwards.
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SkipAppx,
    [switch]$SkipTweaks,
    [string]$LogPath = "$env:ProgramData\Debloat\debloat-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

#region ---------------------------------------------------------- KEEP LISTS

# Protected. Wildcards. Checked before anything is removed.
$KeepWin32 = @(
    # --- Dell: driver / support tooling ---
    'Dell SupportAssist'                # main app - drivers + hardware scans
    'Dell SupportAssist Remediation'    # required by SupportAssist, don't orphan it
    'SupportAssist Recovery Assistant'
    'Dell Command*'                     # Command | Update - the fleet driver tool
    'Dell Peripheral Manager'           # docks, webcams, headsets
    'Dell Power Manager*'               # battery thresholds / thermal profiles
    'Dell Trusted Device*'
    'Dell*Driver*'
    'Dell Watchdog Timer'

    # --- HP: driver / support tooling (the HP SupportAssist equivalent) ---
    'HP Support Assistant'              # <-- HP's SupportAssist. Keeping this.
    'HP Support Solutions Framework'    # HPSA depends on it
    'HP Image Assistant*'               # fleet driver tool, HP's answer to DCU
    'HP Notifications'                  # HPSA/driver notifications
    'HP Hotkey*'                        # REMOVING THIS BREAKS Fn KEYS
    'HP System Default Settings'
    'HP Programmable Key'
    'HP Analytics*'
    'HP PC Hardware Diagnostics*'       # genuinely useful for RMA evidence
    'HP Sure Recover*'                  # firmware-level recovery, leave alone
    'HP Client Security*'               # fingerprint / smartcard on business kit

    # --- General: never touch ---
    '*Intel*'
    '*Realtek*'
    '*NVIDIA*'
    '*AMD*'
    '*Microsoft*'
    '*Windows*'
    '*Visual C++*'
    '*.NET*'
    '*Synaptics*'
    '*Conexant*'
    '*Waves MaxxAudio*'                 # remove this and audio dies on some Dells
    '*Bang & Olufsen*'
)

$KeepAppx = @(
    'MicrosoftCorporationII.QuickAssist'
    'Microsoft.CompanyPortal'
    'Microsoft.WindowsStore'
    'Microsoft.WindowsTerminal'
    'Microsoft.WindowsNotepad'
    'Microsoft.ScreenSketch'
    'Microsoft.WindowsCalculator'
    'Microsoft.Windows.Photos'
    'Microsoft.Paint'
    'Microsoft.DesktopAppInstaller'
    'MSTeams'                           # new Teams work client
    'MicrosoftTeams'                    # legacy/personal Teams appx
    'Microsoft.Copilot'
    'Microsoft.Windows.Ai.Copilot.Provider'
    'Microsoft.MicrosoftOfficeHub'      # the Microsoft 365 app launcher
    'Microsoft.OutlookForWindows'       # new Outlook
    'Microsoft.Todos'
    'Microsoft.PowerAutomateDesktop'
    'Microsoft.Office*'
    'Microsoft.MicrosoftStickyNotes'
    'Microsoft.OneDrive*'
    'Microsoft.UI.Xaml*'
    'Microsoft.VCLibs*'
    'Microsoft.NET.Native*'
    'DellInc.DellSupportAssistforPCs'   # Dell SupportAssist (Store version)
    'AD2F1837.HPSupportAssistant'       # HP Support Assistant (Store version)
    'AD2F1837.HPPCHardwareDiagnosticsWindows'
)

#endregion

#region -------------------------------------------------------- REMOVE LISTS

$RemoveDell = @(
    'Dell Digital Delivery*'
    'Dell Customer Connect'
    'Dell Mobile Connect'
    'Dell Connect'
    'Screenovate*'                      # Dell Mobile Connect under the hood
    'MyDell*'
    'My Dell'
    'Dell Optimizer*'                   # flaky, phones home, duplicates Power Manager
    'Dell Core Services'
    'Dell Digital Delivery Services'
    'Dell SupportAssist OS Recovery*'   # separate from SupportAssist proper
    'Dell Update*'                      # superseded by Command | Update
    'DellTypeCStatus'
    'Dell Product Registration'
    'Dell Help & Support'
    'Dell Getting Started Guide'
    'Dell SupportAssistAgent'           # legacy agent
    'Dropbox*'                          # Dell ships a Dropbox promo build
    'Dell Migrate*'
    'Dell Display Manager*'             # optional - drop this line if you use it
)

$RemoveHP = @(
    'HP Wolf Security*'                 # see ordered removal below
    'HP Security Update Service'
    'HP Sure Sense*'
    'HP Sure Click*'
    'HP Sure Run*'
    'HP Sure Start*'
    'HP JumpStart*'
    'HP Sure Connect'
    'HP Connection Optimizer'
    'HP Documentation'
    'HP Registration Service'
    'HP Desktop Support Utilities'
    'HP Privacy Settings'
    'HP QuickDrop'
    'HP Easy Clean'
    'HP System Event Utility'           # check Fn keys on your model before trusting this
    'HP Performance Advisor'
    'HP Insights*'
    'HP Smart'                          # printer app
    'myHP'
    'HP Audio Switch'
    'HP Duet*'
    'HP ePrint*'
    'Poly Lens*'
    'HP Presence*'
    'ExpressVPN*'
    'McAfee*'
    'Norton*'
    'LastPass*'
    'WildTangent*'
    'Booking.com*'
    'Amazon*'
)

# Order matters. HP Wolf leaves the machine in a mess if pulled out of sequence.
$HPWolfOrder = @(
    'HP Wolf Security'
    'HP Wolf Security - Console'
    'HP Security Update Service'
)

$RemoveAppx = @(
    # Microsoft consumer
    'Microsoft.549981C3F5F10'           # Cortana
    'Microsoft.BingNews'
    'Microsoft.BingWeather'
    'Microsoft.BingSearch'
    'Microsoft.GamingApp'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MixedReality.Portal'
    'Microsoft.People'
    'Microsoft.SkypeApp'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.WindowsMaps'
    'Microsoft.Xbox.TCUI'
    'Microsoft.XboxGameOverlay'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.ZuneMusic'
    'Microsoft.ZuneVideo'
    'Microsoft.YourPhone'
    'Clipchamp.Clipchamp'
    'Microsoft.WindowsSoundRecorder'

    # OEM store apps
    'AD2F1837.*'                        # HP publisher - keep-list protects HPSA
    'DellInc.*'                         # Dell publisher - keep-list protects SupportAssist
    'RealtimeboardInc.RealtimeBoard'
    'SpotifyAB.SpotifyMusic'
    'Disney.37853FC22B2CE'
    '*Facebook*'
    '*Twitter*'
    '*TikTok*'
    '*CandyCrush*'
    '*Netflix*'
    '*Instagram*'
    '*Duolingo*'
    '*Prime*'
)

#endregion

#region ------------------------------------------------------------ PLUMBING

$ErrorActionPreference = 'Continue'
$script:Removed  = @()
$script:Skipped  = @()
$script:Manual   = @()
$script:Failed   = @()

New-Item -Path (Split-Path $LogPath) -ItemType Directory -Force | Out-Null

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','DRY')][string]$Level = 'INFO')
    $line = '{0}  [{1,-4}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogPath -Value $line
    $colour = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERR' {'Red'} 'DRY' {'Cyan'} default {'Gray'} }
    Write-Host $line -ForegroundColor $colour
}

function Test-Protected {
    param([string]$Name, [string[]]$KeepList)
    foreach ($p in $KeepList) { if ($Name -like $p) { return $true } }
    return $false
}

function Get-InstalledApps {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
        Select-Object DisplayName, DisplayVersion, Publisher, UninstallString,
                      QuietUninstallString, PSChildName
}

# Known silent switches for EXE uninstallers that don't publish QuietUninstallString
$SilentSwitches = @{
    'HP Connection Optimizer'   = '/s'
    'HP Documentation'          = '/s'
    'HP Sure Connect'           = '/s'
    'HP Desktop Support Utilities' = '/s'
    'Dell Optimizer*'           = '-silent'
    'Dell Digital Delivery*'    = '/S'
    'Dell Core Services'        = '/S'
}

function Split-UninstallString {
    param([string]$Raw)
    if ($Raw -match '^\s*"([^"]+)"\s*(.*)$') { return [pscustomobject]@{ File = $Matches[1]; Arguments = $Matches[2].Trim() } }
    if ($Raw -match '^\s*(.+?\.exe)\s*(.*)$')  { return [pscustomobject]@{ File = $Matches[1]; Arguments = $Matches[2].Trim() } }
    return [pscustomobject]@{ File = $Raw.Trim(); Arguments = '' }
}

function Remove-Win32App {
    param([Parameter(Mandatory)]$App)

    $name = $App.DisplayName

    # MSI - always safe and always silent
    if ($App.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
        if ($DryRun) { Write-Log "would remove (MSI): $name" 'DRY'; $script:Removed += $name; return }
        $p = Start-Process msiexec.exe -ArgumentList "/x $($App.PSChildName) /qn /norestart" -Wait -PassThru
        if ($p.ExitCode -in 0, 1605, 3010) { Write-Log "removed: $name (exit $($p.ExitCode))" 'OK'; $script:Removed += $name }
        else { Write-Log "failed: $name (exit $($p.ExitCode))" 'ERR'; $script:Failed += $name }
        return
    }

    # EXE with a published quiet string
    $raw = $App.QuietUninstallString
    $extra = ''
    if (-not $raw) {
        $raw = $App.UninstallString
        $match = $SilentSwitches.Keys | Where-Object { $name -like $_ } | Select-Object -First 1
        if ($match) { $extra = $SilentSwitches[$match] }
        elseif ($Force) { $extra = '/S' }
        else {
            Write-Log "manual: $name (no silent switch known)" 'WARN'
            $script:Manual += "$name  ->  $raw"
            return
        }
    }
    if (-not $raw) { Write-Log "manual: $name (no uninstall string)" 'WARN'; $script:Manual += $name; return }

    $u = Split-UninstallString $raw
    $args = (($u.Arguments, $extra) | Where-Object { $_ }) -join ' '

    if ($DryRun) { Write-Log "would remove (EXE): $name  ->  $($u.File) $args" 'DRY'; $script:Removed += $name; return }

    try {
        $p = Start-Process -FilePath $u.File -ArgumentList $args -Wait -PassThru -ErrorAction Stop
        if ($p.ExitCode -in 0, 1605, 3010) { Write-Log "removed: $name (exit $($p.ExitCode))" 'OK'; $script:Removed += $name }
        else { Write-Log "failed: $name (exit $($p.ExitCode))" 'ERR'; $script:Failed += $name }
    }
    catch { Write-Log "failed: $name - $($_.Exception.Message)" 'ERR'; $script:Failed += $name }
}

function Invoke-RemovalPass {
    param([string[]]$Patterns, [string]$Label)

    Write-Log "--- $Label ---"
    $apps = Get-InstalledApps
    foreach ($pattern in $Patterns) {
        foreach ($app in ($apps | Where-Object { $_.DisplayName -like $pattern })) {
            if (Test-Protected $app.DisplayName $KeepWin32) {
                Write-Log "protected: $($app.DisplayName)" 'INFO'
                $script:Skipped += $app.DisplayName
                continue
            }
            if ($script:Removed -contains $app.DisplayName) { continue }
            Remove-Win32App -App $app
        }
    }
}

# Writes a value to the default profile hive plus every loaded user hive,
# so it applies to new users too when running as SYSTEM.
function Set-AllUserHiveValue {
    param([string]$SubKey, [string]$Name, $Value, [string]$Type = 'DWord')

    $hives = @()
    $defaultDat = "$env:SystemDrive\Users\Default\NTUSER.DAT"
    $loaded = $false
    if (Test-Path $defaultDat) {
        reg.exe load 'HKU\_DefaultTemp' $defaultDat *>$null
        if ($LASTEXITCODE -eq 0) { $hives += 'Registry::HKEY_USERS\_DefaultTemp'; $loaded = $true }
    }
    Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
        ForEach-Object { $hives += "Registry::HKEY_USERS\$($_.PSChildName)" }

    foreach ($h in $hives) {
        $full = Join-Path $h $SubKey
        if (-not (Test-Path $full)) { New-Item -Path $full -Force | Out-Null }
        New-ItemProperty -Path $full -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }

    if ($loaded) { [gc]::Collect(); Start-Sleep -Milliseconds 500; reg.exe unload 'HKU\_DefaultTemp' *>$null }
}

function Set-PolicyValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

#endregion

#region --------------------------------------------------------------- START

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this as Administrator.' -ForegroundColor Red
    exit 1
}

$cs = Get-CimInstance Win32_ComputerSystem
$manufacturer = $cs.Manufacturer
$model = $cs.Model

Write-Log "Log: $LogPath"
Write-Log "Machine: $manufacturer / $model"
if ($DryRun) { Write-Log 'DRY RUN - nothing will be changed' 'DRY' }

#endregion

#region ------------------------------------------------------------ OEM PASS

if ($manufacturer -match 'Dell') {
    Invoke-RemovalPass -Patterns $RemoveDell -Label 'Dell bloatware'
}
elseif ($manufacturer -match 'HP|Hewlett') {
    Write-Log '--- HP Wolf Security (ordered) ---'
    foreach ($wolf in $HPWolfOrder) {
        $apps = Get-InstalledApps | Where-Object { $_.DisplayName -like $wolf }
        foreach ($a in $apps) { Remove-Win32App -App $a }
    }
    Invoke-RemovalPass -Patterns $RemoveHP -Label 'HP bloatware'
}
else {
    Write-Log "Manufacturer '$manufacturer' is not HP or Dell - running both lists" 'WARN'
    Invoke-RemovalPass -Patterns $RemoveDell -Label 'Dell bloatware'
    Invoke-RemovalPass -Patterns $RemoveHP   -Label 'HP bloatware'
}

#endregion

#region ----------------------------------------------------------- APPX PASS

if (-not $SkipAppx) {
    Write-Log '--- Appx / provisioned packages ---'

    foreach ($pattern in $RemoveAppx) {
        # Installed for any user
        Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Protected $_.Name $KeepAppx) { Write-Log "protected: $($_.Name)"; return }
            if ($DryRun) { Write-Log "would remove appx: $($_.Name)" 'DRY'; return }
            try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop
                  Write-Log "removed appx: $($_.Name)" 'OK'; $script:Removed += $_.Name }
            catch { Write-Log "failed appx: $($_.Name) - $($_.Exception.Message)" 'ERR' }
        }

        # Provisioned - stops it coming back for new users
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $pattern } | ForEach-Object {
                if (Test-Protected $_.DisplayName $KeepAppx) { Write-Log "protected (prov): $($_.DisplayName)"; return }
                if ($DryRun) { Write-Log "would remove provisioned: $($_.DisplayName)" 'DRY'; return }
                try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                      Write-Log "removed provisioned: $($_.DisplayName)" 'OK' }
                catch { Write-Log "failed provisioned: $($_.DisplayName)" 'ERR' }
            }
    }
}

#endregion

#region --------------------------------------------------------------- TWEAKS

if (-not $SkipTweaks -and -not $DryRun) {
    Write-Log '--- Registry tweaks ---'

    # Stop Windows silently reinstalling suggested apps and games
    Set-PolicyValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-PolicyValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 1
    Set-PolicyValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1

    # Kill the OOBE "finish setting up your device" nag
    Set-PolicyValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0

    # Widgets / news feed
    Set-PolicyValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0

    # Per-user, applied to default profile + existing profiles
    $cdm = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($v in 'SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled',
                   'ContentDeliveryAllowed','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled',
                   'SubscribedContent-353698Enabled','SubscribedContent-310093Enabled','SystemPaneSuggestionsEnabled') {
        Set-AllUserHiveValue -SubKey $cdm -Name $v -Value 0
    }

    # Start menu recommendations + File Explorer sanity
    Set-AllUserHiveValue -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Set-AllUserHiveValue -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
    Set-AllUserHiveValue -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1

    Write-Log 'tweaks applied' 'OK'
}

#endregion

#region -------------------------------------------------------------- SUMMARY

Write-Log ''
Write-Log "=== SUMMARY ==="
Write-Log "Removed:   $($script:Removed.Count)"
Write-Log "Protected: $($script:Skipped.Count)"
Write-Log "Failed:    $($script:Failed.Count)"
Write-Log "Manual:    $($script:Manual.Count)"
if ($script:Manual.Count) {
    Write-Log 'Needs manual handling (add a switch to $SilentSwitches or run with -Force):' 'WARN'
    $script:Manual | ForEach-Object { Write-Log "  $_" 'WARN' }
}
if ($script:Failed.Count) { $script:Failed | ForEach-Object { Write-Log "  failed: $_" 'ERR' } }

Write-Log ''
Write-Log 'DEBLOAT COMPLETE - PLEASE RESTART SYSTEM' 'OK'

# Intune-friendly exit code
if ($script:Failed.Count) { exit 1 } else { exit 0 }

#endregion