#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Nuke & pave for Microsoft 365 Apps on new out-of-box laptops.
    Removes ALL preinstalled Office/M365 products (C2R in every language, legacy MSI,
    and the Microsoft Store stub apps), then reinstalls a clean copy via the
    Office Deployment Tool (ODT).

.DESCRIPTION
    Phase 1 - Remove:
      - Kills running Office processes
      - Removes Microsoft Store Office stubs (Office Hub / Desktop Apps)
      - Downloads the latest ODT setup.exe from the Office CDN
      - Runs an ODT "Remove All" config (also strips legacy MSI Office via RemoveMSI)
      - Optional: SaRAcmd deep scrub for stubborn leftovers (-DeepClean)

    Phase 2 - Install:
      - Reinstalls M365 Apps silently with your chosen Product ID / channel / language

.PARAMETER ProductID
    O365BusinessRetail  = M365 Apps for business (Business Standard / Business Premium)
    O365ProPlusRetail   = M365 Apps for enterprise (E3 / E5)

.PARAMETER Channel
    Current (default) or MonthlyEnterprise for managed environments.

.PARAMETER DeepClean
    Also runs Microsoft SaRAcmd OfficeScrubScenario after the ODT removal.
    Slower, but catches broken/orphaned installs ODT can't see.

.PARAMETER SkipInstall
    Removal only - don't reinstall.

.PARAMETER RemoveNewOutlook
    Also removes the preinstalled "new Outlook" (olk) Store app.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Reset-M365Apps.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Reset-M365Apps.ps1 -ProductID O365ProPlusRetail -DeepClean -RemoveNewOutlook

.NOTES
    Run from an elevated PowerShell prompt. Internet required (install pulls ~3-4 GB
    from the Office CDN). Reboot recommended when finished.
#>

[CmdletBinding()]
param(
    [ValidateSet("O365BusinessRetail","O365ProPlusRetail")]
    [string]$ProductID = "O365BusinessRetail",

    [ValidateSet("Current","MonthlyEnterprise","SemiAnnual")]
    [string]$Channel = "Current",

    [string]$Language = "en-GB",

    [ValidateSet("64","32")]
    [string]$Bitness = "64",

    [switch]$DeepClean,
    [switch]$SkipInstall,
    [switch]$RemoveNewOutlook
)

# ------------------------------------------------------------------ setup ----
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$WorkDir  = "C:\OfficeReset"
$LogFile  = Join-Path $WorkDir ("OfficeReset_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$SetupExe = Join-Path $WorkDir "setup.exe"

New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null
Start-Transcript -Path $LogFile | Out-Null

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    [!!] $msg" -ForegroundColor Yellow }

# ---------------------------------------------- 1. kill office processes ----
Write-Step "Closing any running Office processes"
$officeProcs = "winword","excel","powerpnt","outlook","onenote","onenoteim",
               "msaccess","mspub","visio","winproj","lync","teams","ms-teams","olk"
Get-Process -Name $officeProcs -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Write-Ok "Done"

# ------------------------------------- 2. remove Microsoft Store stubs ------
Write-Step "Removing preinstalled Microsoft Store Office stub apps"
$stubPatterns = @("Microsoft.Office.Desktop", "Microsoft.MicrosoftOfficeHub")
if ($RemoveNewOutlook) { $stubPatterns += "Microsoft.OutlookForWindows" }

foreach ($pattern in $stubPatterns) {
    Get-AppxPackage -AllUsers -Name "$pattern*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host "    Removing appx: $($_.Name)"
            Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like "$pattern*" } |
        ForEach-Object {
            Write-Host "    Deprovisioning: $($_.PackageName)"
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null
        }
}
Write-Ok "Store stubs cleared"

# ----------------------------------------------- 3. download ODT setup ------
Write-Step "Downloading latest Office Deployment Tool (setup.exe)"
# Evergreen link on Microsoft's Office CDN (same file winget uses for Microsoft.Office)
Invoke-WebRequest -Uri "https://officecdn.microsoft.com/pr/wsus/setup.exe" `
                  -OutFile $SetupExe -UseBasicParsing

$sig = Get-AuthenticodeSignature -FilePath $SetupExe
if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notmatch "Microsoft") {
    Stop-Transcript | Out-Null
    throw "Downloaded setup.exe failed signature validation - aborting."
}
Write-Ok "setup.exe downloaded and signature verified ($($sig.SignerCertificate.Subject -replace ',.*',''))"

# --------------------------------------------- 4. ODT remove-all phase ------
Write-Step "Removing ALL Click-to-Run and MSI Office products (this takes a few minutes)"
$removeXml = @"
<Configuration>
  <Remove All="TRUE" />
  <RemoveMSI />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
"@
$removeXmlPath = Join-Path $WorkDir "remove.xml"
$removeXml | Out-File -FilePath $removeXmlPath -Encoding utf8 -Force

$p = Start-Process -FilePath $SetupExe -ArgumentList "/configure `"$removeXmlPath`"" -Wait -PassThru
if ($p.ExitCode -eq 0) { Write-Ok "ODT removal completed (exit code 0)" }
else { Write-Warn2 "ODT removal exit code: $($p.ExitCode) - continuing" }

# --------------------------------------- 5. optional SaRA deep scrub --------
if ($DeepClean) {
    Write-Step "DeepClean: running Microsoft SaRA Office scrub"
    $saraZip = Join-Path $WorkDir "SaRACmd.zip"
    $saraDir = Join-Path $WorkDir "SaRA"
    try {
        Invoke-WebRequest -Uri "https://aka.ms/SaRA_EnterpriseVersionFiles" `
                          -OutFile $saraZip -UseBasicParsing
        Expand-Archive -Path $saraZip -DestinationPath $saraDir -Force
        $saraExe = Get-ChildItem -Path $saraDir -Filter "SaRAcmd.exe" -Recurse |
                   Select-Object -First 1 -ExpandProperty FullName
        if (-not $saraExe) { throw "SaRAcmd.exe not found in extracted package." }

        $sp = Start-Process -FilePath $saraExe `
              -ArgumentList "-S OfficeScrubScenario -AcceptEula -OfficeVersion All" `
              -Wait -PassThru
        if ($sp.ExitCode -eq 0) { Write-Ok "SaRA scrub completed (exit code 0)" }
        else { Write-Warn2 "SaRA scrub exit code: $($sp.ExitCode) (see SaRA docs for meaning)" }
    }
    catch {
        Write-Warn2 "SaRA scrub skipped/failed: $($_.Exception.Message)"
    }
}

# ------------------------------------------------- 6. clean reinstall -------
if (-not $SkipInstall) {
    Write-Step "Installing Microsoft 365 Apps ($ProductID, $Channel channel, $Language, $Bitness-bit)"
    Write-Host "    Downloading ~3-4 GB from the Office CDN - grab a coffee..."
    $installXml = @"
<Configuration>
  <Add OfficeClientEdition="$Bitness" Channel="$Channel">
    <Product ID="$ProductID">
      <Language ID="$Language" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
    </Product>
  </Add>
  <Updates Enabled="TRUE" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Property Name="SharedComputerLicensing" Value="0" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
"@
    $installXmlPath = Join-Path $WorkDir "install.xml"
    $installXml | Out-File -FilePath $installXmlPath -Encoding utf8 -Force

    $p = Start-Process -FilePath $SetupExe -ArgumentList "/configure `"$installXmlPath`"" -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Warn2 "Install exit code: $($p.ExitCode)"
    }

    # ------------------------------------------------- 7. verify install ----
    Write-Step "Verifying installation"
    $c2r = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" `
           -ErrorAction SilentlyContinue
    if ($c2r) {
        Write-Ok "Installed: $($c2r.ProductReleaseIds)"
        Write-Ok "Version:   $($c2r.VersionToReport)"
    } else {
        Write-Warn2 "ClickToRun registry key not found - install may have failed. Check $LogFile"
    }
}

Write-Step "Finished. A reboot is recommended before handing the device over."
Write-Host "    Log: $LogFile`n"
Stop-Transcript | Out-Null