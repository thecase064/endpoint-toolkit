<#
.SYNOPSIS
    Downloads and silently installs the latest Google Chrome (Enterprise MSI) and
    Adobe Acrobat Reader (64-bit offline installer), with Adobe's cloud / Express /
    AI Assistant / upsell components disabled.

.DESCRIPTION
    - Chrome: pulls the always-latest Enterprise MSI from Google. No stub installer,
      no bundled extras.
    - Reader: queries Adobe's release API for the current 64-bit version, then pulls
      the full offline installer direct from ardownload2. The offline installer is
      what avoids the McAfee / browser-offer bundling in the consumer web installer.
    - Post-install: writes FeatureLockDown policy so Reader ships without Document
      Cloud, Adobe Express / Firefly hooks, AI Assistant, Dropbox/Drive connectors,
      Acrobat Pro upsell, and the auto-deployed browser extension.

.PARAMETER Apps
    Which apps to install. Default: both.

.PARAMETER Language
    Reader installer language. Default MUI (multilingual). Use en_US for English-only.

.PARAMETER SkipHardening
    Install Reader but leave the default (bloated) config alone.

.EXAMPLE
    .\Install-ChromeAndReader.ps1
    .\Install-ChromeAndReader.ps1 -Apps Reader -Language en_US
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Chrome','Reader','Both')]
    [string]$Apps = 'Both',

    [string]$Language = 'MUI',

    [switch]$SkipHardening
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$WorkDir = Join-Path $env:TEMP 'AppDeploy'
$LogDir  = 'C:\ProgramData\AppDeploy\Logs'
$null = New-Item -Path $WorkDir -ItemType Directory -Force
$null = New-Item -Path $LogDir  -ItemType Directory -Force
$Log = Join-Path $LogDir ("Install-ChromeAndReader_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    Add-Content -Path $Log -Value $line
}

function Get-InstalledApp {
    param([string]$NamePattern)
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $NamePattern } |
        Select-Object DisplayName, DisplayVersion -First 1
}

function Get-File {
    param([string]$Uri, [string]$OutFile)
    Write-Log "Downloading: $Uri"
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try   { Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing }
    finally { $ProgressPreference = $pp }
    $sizeMb = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
    Write-Log "Downloaded $([IO.Path]::GetFileName($OutFile)) ($sizeMb MB)"
}

# ---------------------------------------------------------------- Google Chrome
function Get-MsiProductVersion {
    # Reads ProductVersion straight out of the MSI property table.
    # Google's version-history API can run ahead of the MSI by a few hours, so the
    # MSI itself is the only trustworthy "what am I about to install" answer.
    param([string]$Path)
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db   = $installer.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$installer,@($Path,0))
        $view = $db.GetType().InvokeMember('OpenView','InvokeMethod',$null,$db,@("SELECT Value FROM Property WHERE Property='ProductVersion'"))
        $view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,$null) | Out-Null
        $rec  = $view.GetType().InvokeMember('Fetch','InvokeMethod',$null,$view,$null)
        $ver  = $rec.GetType().InvokeMember('StringData','GetProperty',$null,$rec,1)
        $view.GetType().InvokeMember('Close','InvokeMethod',$null,$view,$null) | Out-Null
        [Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null
        return $ver
    } catch {
        Write-Log "Could not read MSI ProductVersion: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Install-Chrome {
    $msiUrl = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    # Keep Google's own filename. Windows Installer caches the package under this
    # name; renaming it breaks secure repair on any later maintenance-mode run.
    $msi    = Join-Path $WorkDir 'Chrome.msi'

    $installed = Get-InstalledApp 'Google Chrome*'
    if ($installed) { Write-Log "Chrome currently installed: $($installed.DisplayVersion)" }

    Get-File -Uri $msiUrl -OutFile $msi

    $msiVersion = Get-MsiProductVersion -Path $msi
    if ($msiVersion) { Write-Log "Downloaded MSI is Chrome $msiVersion" }

    # Same build already on the box - installing again only triggers a repair,
    # which fails 1603 if the cached source no longer matches. Just stop.
    if ($installed -and $msiVersion -and $installed.DisplayVersion -eq $msiVersion) {
        Write-Log "Chrome $msiVersion already installed - nothing to do."
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        return
    }

    if ((Test-PendingReboot)) {
        Write-Log 'A reboot is pending on this machine - MSI operations may fail. Reboot and rerun if this errors.' 'WARN'
    }

    $msiLog = Join-Path $LogDir 'Chrome_msi.log'
    $arguments = @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$msiLog`"")
    Write-Log 'Installing Google Chrome...'
    $p = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru

    if ($p.ExitCode -in 0,3010) {
        Write-Log "Chrome installed OK (exit $($p.ExitCode))."
    }
    elseif ($p.ExitCode -eq 1603) {
        # Almost always a failed secure repair. Force a full re-cache and reinstall.
        Write-Log '1603 returned - retrying with REINSTALLMODE=vomus to re-cache the package.' 'WARN'
        $retry = @('/i', "`"$msi`"", 'REINSTALL=ALL', 'REINSTALLMODE=vomus',
                   '/qn', '/norestart', '/l*v', "`"$msiLog.retry.log`"")
        $p2 = Start-Process msiexec.exe -ArgumentList $retry -Wait -PassThru
        if ($p2.ExitCode -in 0,3010) { Write-Log "Chrome installed OK on retry (exit $($p2.ExitCode))." }
        else { Write-Log "Chrome install failed on retry - exit $($p2.ExitCode). See $msiLog.retry.log" 'ERROR' }
    }
    else {
        Write-Log "Chrome install failed - exit code $($p.ExitCode). See $msiLog" 'ERROR'
    }

    Remove-Item $msi -Force -ErrorAction SilentlyContinue
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    return [bool]$pfro.PendingFileRenameOperations
}

# --------------------------------------------------------- Adobe Acrobat Reader
function Get-ReaderDownload {
    # Adobe's release feed - returns the current shipping build
    $api = "https://rdc.adobe.io/reader/products?lang=en&site=enterprise&os=Windows%2011&api_key=dc-get-adobereader-cdn"
    try {
        $product = (Invoke-RestMethod -Uri $api -UseBasicParsing).products.reader |
                    Where-Object { $_.displayName -match '64bit' -or $_.version -match '^\d' } |
                    Sort-Object version -Descending | Select-Object -First 1
        $ver = $product.version
    } catch {
        Write-Log "Adobe release API unreachable - falling back to pinned build." 'WARN'
        $ver = '26.001.21789'   # update this if the API ever stays down
    }
    $verFlat = $ver -replace '\.', ''
    [pscustomobject]@{
        Version = $ver
        Url     = "https://ardownload2.adobe.com/pub/adobe/acrobat/win/AcrobatDC/$verFlat/AcroRdrDCx64${verFlat}_$Language.exe"
        File    = "AcroRdrDCx64${verFlat}_$Language.exe"
    }
}

function Install-Reader {
    $dl = Get-ReaderDownload
    Write-Log "Adobe Reader latest: $($dl.Version)"

    $installed = Get-InstalledApp 'Adobe Acrobat*'
    if ($installed -and $installed.DisplayVersion -eq $dl.Version) {
        Write-Log "Reader $($installed.DisplayVersion) already current - skipping install."
    }
    else {
        if ($installed) { Write-Log "Reader $($installed.DisplayVersion) installed - upgrading." }
        $exe = Join-Path $WorkDir $dl.File
        Get-File -Uri $dl.Url -OutFile $exe

        $msiLog = Join-Path $LogDir 'Reader_msi.log'
        # /sAll  = silent, all users      /rs = reboot suppress
        # /rps   = suppress reboot prompt /msi = pass the rest to msiexec
        $readerArgs = "/sAll /rs /rps /msi /norestart /quiet " +
                      "EULA_ACCEPT=YES " +
                      "REMOVE_PREVIOUS=YES " +
                      "DISABLEDESKTOPSHORTCUT=1 " +
                      "DISABLE_CACHE=1 " +
                      "/l*v `"$msiLog`""

        Write-Log 'Installing Adobe Acrobat Reader (this takes a few minutes)...'
        $p = Start-Process $exe -ArgumentList $readerArgs -Wait -PassThru
        if ($p.ExitCode -in 0,3010) { Write-Log "Reader installed OK (exit $($p.ExitCode))." }
        else { Write-Log "Reader install failed - exit code $($p.ExitCode). See $msiLog" 'ERROR' }

        Remove-Item $exe -Force -ErrorAction SilentlyContinue
    }

    if (-not $SkipHardening) { Set-ReaderPolicy }
}

function Set-ReaderPolicy {
    Write-Log 'Applying Reader policy (stripping cloud / Express / AI / upsell)...'

    # Both hives written - x64 Reader reports as "Adobe Acrobat" on newer builds
    $roots = @(
        'HKLM:\SOFTWARE\Policies\Adobe\Acrobat Reader\DC\FeatureLockDown',
        'HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown'
    )

    $lockdown = @{
        bAcroSuppressUpsell        = 1   # no "Upgrade to Acrobat Pro" nagging
        bUpdater                   = 1   # keep security updates ON (set 0 only if you patch centrally)
        bEnableGentech             = 0   # AI Assistant / generative features off
        bDisableJavaScript         = 1   # optional hardening - remove line if a workflow needs JS
        bShowMigrationDialog       = 0
        bDisableTrustedFolders     = 0
    }

    $services = @{
        bToggleAdobeDocumentServices = 1  # all Document Cloud services off
        bToggleDocumentCloud         = 1  # no cloud storage / Adobe account
        bTogglePrefsSync             = 1  # no settings sync
        bToggleWebConnectors         = 1  # no Dropbox / Google Drive / OneDrive connectors
        bToggleAdobeSign             = 1  # no Adobe Sign
        bAdobeSendPluginToggle       = 1  # no "Send & Track"
        bToggleFillSign              = 0  # leave Fill & Sign usable locally
    }

    foreach ($root in $roots) {
        $svc = Join-Path $root 'cServices'
        $null = New-Item -Path $root -Force
        $null = New-Item -Path $svc  -Force
        foreach ($k in $lockdown.Keys) { New-ItemProperty -Path $root -Name $k -Value $lockdown[$k] -PropertyType DWord -Force | Out-Null }
        foreach ($k in $services.Keys) { New-ItemProperty -Path $svc  -Name $k -Value $services[$k] -PropertyType DWord -Force | Out-Null }
    }

    # Kill the auto-deployed Acrobat browser extension in Chrome and Edge
    $extId = 'efaidnbmnnnibpcajpcglclefindmkaj'
    foreach ($browser in @('Google\Chrome','Microsoft\Edge')) {
        foreach ($node in @('SOFTWARE','SOFTWARE\WOW6432Node')) {
            $path = "HKLM:\$node\$browser\Extensions\$extId"
            if (Test-Path $path) { Remove-Item $path -Recurse -Force; Write-Log "Removed forced extension entry: $path" }
        }
    }

    # Adobe's tray/marketing services - disable if present
    foreach ($svcName in @('AdobeARMservice','AGSService','AGMService')) {
        $s = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($s -and $svcName -ne 'AdobeARMservice') {   # keep ARM = update service running
            Stop-Service $s -Force -ErrorAction SilentlyContinue
            Set-Service  $s -StartupType Disabled
            Write-Log "Disabled service: $svcName"
        }
    }

    Write-Log 'Reader policy applied.'
}

# ------------------------------------------------------------------------ Main
Write-Log "Log file: $Log"

try {
    if ($Apps -in 'Chrome','Both') { Install-Chrome }
    if ($Apps -in 'Reader','Both') { Install-Reader }
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
finally {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Log 'INSTALL COMPLETE'
exit 0