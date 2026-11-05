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
      - Optional: Microsoft Get Help deep scrub for stubborn leftovers (-DeepClean)

    Phase 2 - Install:
      - Reinstalls M365 Apps silently with your chosen Product ID / channel / language

.PARAMETER ProductID
    O365BusinessRetail  = M365 Apps for business (Business Standard / Business Premium)
    O365ProPlusRetail   = M365 Apps for enterprise (E3 / E5)

.PARAMETER Channel
    Current (default) or MonthlyEnterprise for managed environments.

.PARAMETER DeepClean
    Also runs Microsoft's Get Help command line (GetHelpCmd.exe) Office scrub
    (OfficeScrubScenario) after the ODT removal. Slower, but catches broken or
    orphaned installs ODT can't see. Get Help replaced the SaRA command line,
    which Microsoft removed from Windows in March 2026. It's downloaded fresh on
    every run (each build expires after 90 days) and must be signed by Microsoft
    or it won't run. Output is saved to C:\OfficeReset\GetHelp_<time>.log.

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

# Includes every process Get Help checks for before its Office scrub (it stops
# with result 06 if any of them are running).
$OfficeProcesses = "winword","excel","powerpnt","outlook","onenote","onenoteim",
                   "msaccess","mspub","visio","winproj","lync","teams","ms-teams","olk",
                   "mstore","infopath","setlang","msouc","ois","groove","graph"

function Invoke-OfficeProcessStop {
    Get-Process -Name $OfficeProcesses -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Resolve-GetHelpResult {
    # Office Uninstall result codes, from Microsoft Learn: "Use the command-line
    # version of Get Help to uninstall Office".
    param([int]$Code)
    $ok = $true
    $text = switch ($Code) {
        0  { "Office scrub completed. Restart to finish the cleanup." }
        66 { "Nothing left to scrub - the ODT removal already got it all." }
        68 { "Nothing left to scrub - the ODT removal already got it all." }
        6  { $ok = $false; "An Office app was still running, so Get Help stopped. Close everything and rerun with -DeepClean." }
        8  { $ok = $false; "Multiple Office versions found. Use the full Get Help app (Get Help > Office uninstall)." }
        9  { $ok = $false; "Get Help couldn't remove Office. Use the full Get Help app (Get Help > Office uninstall)." }
        10 { $ok = $false; "Get Help says it isn't elevated. Rerun from an admin PowerShell." }
        67 { $ok = $false; "Get Help rejected the -OfficeVersion value. Microsoft may have changed the switch." }
        default { $ok = $false; "Unrecognised result. The Get Help build may have expired (they last 90 days) - check the output log." }
    }
    [pscustomobject]@{ Ok = $ok; Text = $text }
}

function Invoke-GetHelpScrub {
    # Microsoft removed the SaRA command line from Windows in March 2026. Get Help's
    # command line (GetHelpCmd.exe) replaces it and has the same OfficeScrubScenario.
    # Each build stops working 90 days after it's made, so it's always downloaded
    # fresh and never bundled.
    param([Parameter(Mandatory)][string]$WorkDir)

    $ghZip = Join-Path $WorkDir "GetHelpCmd.zip"
    $ghDir = Join-Path $WorkDir "GetHelp"
    $ghLog = Join-Path $WorkDir ("GetHelp_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
    # Also clear out anything older runs left behind, including the old SaRA download.
    $scratch = $ghZip, $ghDir, (Join-Path $WorkDir "SaRACmd.zip"), (Join-Path $WorkDir "SaRA")

    try {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -Uri "https://aka.ms/SaRA_EnterpriseVersionFiles" `
                          -OutFile $ghZip -UseBasicParsing
        Expand-Archive -LiteralPath $ghZip -DestinationPath $ghDir -Force
        $ghExe = Get-ChildItem -LiteralPath $ghDir -Filter "GetHelpCmd.exe" -Recurse -File |
                 Select-Object -First 1
        if (-not $ghExe) { throw "GetHelpCmd.exe not found in the download - Microsoft may have changed the package." }

        $ghSig = Get-AuthenticodeSignature -FilePath $ghExe.FullName
        if ($ghSig.Status -ne "Valid" -or $ghSig.SignerCertificate.Subject -notmatch "Microsoft") {
            throw "GetHelpCmd.exe failed signature validation ($($ghSig.Status)) - not running it."
        }
        Write-Ok "GetHelpCmd.exe downloaded and signature verified"

        # ODT can relaunch helpers; Get Help refuses to run with any Office app open.
        Invoke-OfficeProcessStop

        # Run from its own folder, as Microsoft's instructions do. Output is shown
        # live and saved to the log.
        Push-Location -LiteralPath $ghExe.DirectoryName
        try {
            $output = @(& $ghExe.FullName -S OfficeScrubScenario -AcceptEula -OfficeVersion All |
                        Tee-Object -FilePath $ghLog |
                        ForEach-Object { Write-Host "    $_"; $_ })
            $exitCode = $LASTEXITCODE
        }
        finally { Pop-Location }

        # Get Help prints its result as "NN: message". Trust that line, fall back to the exit code.
        $resultLine = $output | Where-Object { "$_" -match '^\s*\d{2}:\s' } | Select-Object -Last 1
        $code = if ("$resultLine" -match '^\s*(\d{2}):') { [int]$Matches[1] } else { $exitCode }

        $result = Resolve-GetHelpResult -Code $code
        if ($result.Ok) { Write-Ok "Get Help: $($result.Text)" }
        else { Write-Warn2 "Get Help result $($code): $($result.Text)" }
        Write-Host "    Get Help output: $ghLog"
    }
    catch {
        Write-Warn2 "Get Help scrub skipped/failed: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $ghZip, $ghDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------- 1. kill office processes ----
Write-Step "Closing any running Office processes"
Invoke-OfficeProcessStop
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

# ----------------------------------- 5. optional Get Help deep scrub --------
if ($DeepClean) {
    Write-Step "DeepClean: running Microsoft Get Help Office scrub (a few minutes)"
    Invoke-GetHelpScrub -WorkDir $WorkDir
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