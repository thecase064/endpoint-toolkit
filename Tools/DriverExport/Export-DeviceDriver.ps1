<#
.SYNOPSIS
    Backs up every third-party driver on a machine before a wipe, and puts them back afterwards.

.DESCRIPTION
    Export (default):
      Exports all third-party (non-inbox) drivers from the running OS - or from an offline Windows
      image - into a folder named after the machine, with:
        drivers.csv        what was exported: class, provider, version, date, original .inf
        device.json        make, model, serial and OS of the source machine
        RESTORE.txt        the one command that puts them back
      Optionally zipped into a single file for the USB stick.

    Import (-ImportFrom):
      Installs every driver from a previous export (folder or .zip) with pnputil, recursing into
      subfolders. Already-present drivers are skipped by Windows.

.PARAMETER Destination
    Export folder. Default C:\DriverExport\<COMPUTER>_<Make>_<Model>_<date>.
    Point it at a USB drive or share if you're about to wipe this one.

.PARAMETER OfflineImagePath
    Export from an offline Windows installation instead of the running OS: the root of the mounted
    image or the other drive (the folder that contains \Windows), e.g. D:\ or C:\Mount.

.PARAMETER Zip
    Also compress the export into <Destination>.zip.

.PARAMETER ImportFrom
    Install drivers from a previous export folder or .zip instead of exporting.

.EXAMPLE
    .\Export-DeviceDriver.ps1 -Destination E:\Drivers -Zip

.EXAMPLE
    .\Export-DeviceDriver.ps1 -OfflineImagePath D:\ -Destination E:\Drivers\OldLaptop

.EXAMPLE
    .\Export-DeviceDriver.ps1 -ImportFrom E:\Drivers\PC-1234_Dell_Latitude-5440_20261104.zip

.NOTES
    Run as Administrator. Exit codes: 0 = OK, 3010 = imported, reboot to finish, 1 = failed.
    Exports only third-party drivers: inbox Windows drivers come back with Windows anyway.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = 'Export')]
param(
    [Parameter(ParameterSetName = 'Export')] [string] $Destination,
    [Parameter(ParameterSetName = 'Export')] [string] $OfflineImagePath,
    [Parameter(ParameterSetName = 'Export')] [switch] $Zip,
    [Parameter(ParameterSetName = 'Import', Mandatory)] [string] $ImportFrom
)

$ErrorActionPreference = 'Stop'

function Write-Step([string] $Message) { Write-Host "`n>> $Message" -ForegroundColor Cyan }

function Get-SafeName([string] $Text) { (($Text -replace '[^\w\-]+', '-').Trim('-')) }

# ------------------------------------------------------------------------------------------------
#  Import
# ------------------------------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Import') {
    if (-not (Test-Path -LiteralPath $ImportFrom)) { Write-Host "Not found: $ImportFrom" -ForegroundColor Red; exit 1 }

    $source  = $ImportFrom
    $tempDir = $null
    if ($ImportFrom -match '\.zip$') {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('DriverImport_{0:yyyyMMddHHmmss}' -f (Get-Date))
        Write-Step "Extracting $ImportFrom"
        Expand-Archive -LiteralPath $ImportFrom -DestinationPath $tempDir -Force
        $source = $tempDir
    }

    $infCount = @(Get-ChildItem -LiteralPath $source -Recurse -Filter '*.inf' -File).Count
    if (-not $infCount) { Write-Host "No .inf files under $source - is that a driver export?" -ForegroundColor Red; exit 1 }

    $manifest = Get-ChildItem -LiteralPath $source -Recurse -Filter 'device.json' -File | Select-Object -First 1
    if ($manifest) {
        $from = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
        Write-Host ("Export came from {0} - {1} {2} (serial {3})" -f $from.ComputerName, $from.Manufacturer, $from.Model, $from.SerialNumber)
    }

    Write-Step "Installing $infCount driver package(s) with pnputil"
    $pnp = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    & $pnp /add-driver (Join-Path $source '*.inf') /subdirs /install | ForEach-Object { Write-Host "  $_" }
    $code = $LASTEXITCODE
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }

    # pnputil: 0 = done, 3010 = done but reboot needed, 259 = packages added but no device needed an update
    switch ($code) {
        0       { Write-Host "`nDrivers installed." -ForegroundColor Green; exit 0 }
        3010    { Write-Host "`nDrivers installed - reboot to finish." -ForegroundColor Green; exit 3010 }
        259     { Write-Host "`nDriver packages added to the store - no device needed an update." -ForegroundColor Green; exit 0 }
        default { Write-Host "`npnputil finished with exit code $code - check the output above." -ForegroundColor Yellow; exit 1 }
    }
}

# ------------------------------------------------------------------------------------------------
#  Export
# ------------------------------------------------------------------------------------------------
$cs   = Get-CimInstance -ClassName Win32_ComputerSystem
$bios = Get-CimInstance -ClassName Win32_BIOS
$os   = Get-CimInstance -ClassName Win32_OperatingSystem

if (-not $Destination) {
    $name = '{0}_{1}_{2}_{3:yyyyMMdd}' -f $env:COMPUTERNAME, (Get-SafeName $cs.Manufacturer.Split(' ')[0]), (Get-SafeName $cs.Model), (Get-Date)
    $Destination = Join-Path (Join-Path $env:SystemDrive 'DriverExport') $name
}
if ((Test-Path -LiteralPath $Destination) -and @(Get-ChildItem -LiteralPath $Destination -Force).Count) {
    Write-Host "Destination isn't empty: $Destination - pick a new folder so exports don't get mixed." -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Path $Destination -Force | Out-Null

$sourceLabel = if ($OfflineImagePath) { "offline image at $OfflineImagePath" } else { 'this machine' }
Write-Step "Exporting third-party drivers from $sourceLabel"
Write-Host "  to $Destination"

try {
    $exported = if ($OfflineImagePath) {
        @(Export-WindowsDriver -Path $OfflineImagePath -Destination $Destination)
    }
    else {
        @(Export-WindowsDriver -Online -Destination $Destination)
    }
}
catch {
    if ($OfflineImagePath) { Write-Host "Export failed: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
    # DISM module missing or broken - pnputil does the same job for the running OS (no manifest detail).
    Write-Warning "Export-WindowsDriver failed ($($_.Exception.Message)) - falling back to pnputil."
    & (Join-Path $env:SystemRoot 'System32\pnputil.exe') /export-driver * $Destination | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "pnputil export failed with exit code $LASTEXITCODE." -ForegroundColor Red; exit 1 }
    $exported = @()
}

$packages = @(Get-ChildItem -LiteralPath $Destination -Directory)
if (-not $packages.Count) {
    Write-Host 'No third-party drivers found to export.' -ForegroundColor Yellow
}

if ($exported.Count) {
    $exported |
        Select-Object ClassName, ProviderName, Version, @{ n = 'Date'; e = { if ($_.Date) { ([datetime]$_.Date).ToString('yyyy-MM-dd') } } },
                      OriginalFileName, Driver |
        Sort-Object ClassName, ProviderName |
        Export-Csv -LiteralPath (Join-Path $Destination 'drivers.csv') -NoTypeInformation -Encoding UTF8
}

[pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    Manufacturer = $cs.Manufacturer
    Model        = $cs.Model
    SerialNumber = $bios.SerialNumber
    OS           = '{0} ({1})' -f $os.Caption, $os.BuildNumber
    Source       = $sourceLabel
    Exported     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    Packages     = $packages.Count
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'device.json') -Encoding UTF8

@"
Driver export from $env:COMPUTERNAME ($($cs.Manufacturer) $($cs.Model), serial $($bios.SerialNumber)) on $(Get-Date -Format 'yyyy-MM-dd').

To put these drivers back (elevated PowerShell):

    pnputil /add-driver "<this folder>\*.inf" /subdirs /install

Or with the Endpoint Toolkit:  Build > Driver import, or  Export-DeviceDriver -ImportFrom "<this folder or its .zip>"
"@ | Set-Content -LiteralPath (Join-Path $Destination 'RESTORE.txt') -Encoding UTF8

$sizeMB = [math]::Round(((Get-ChildItem -LiteralPath $Destination -Recurse -File | Measure-Object -Property Length -Sum).Sum) / 1MB)
Write-Host ("`nExported {0} driver package(s), {1} MB." -f $packages.Count, $sizeMB) -ForegroundColor Green

if ($Zip) {
    Write-Step 'Zipping'
    $zipPath = "$Destination.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $Destination '*') -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "  $zipPath ($([math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB)) MB)" -ForegroundColor Green
}

$destRoot = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Destination).Path)
if (-not $OfflineImagePath -and $destRoot -and $destRoot.TrimEnd('\') -ieq $env:SystemDrive) {
    Write-Host "`nHeads-up: the export is on this machine's own drive. Copy it somewhere else before you wipe it." -ForegroundColor Yellow
}
exit 0
