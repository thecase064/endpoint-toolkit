<#
.SYNOPSIS
    Finds and installs driver, firmware and (optionally) BIOS updates from Dell, HP or Lenovo,
    using each vendor's own updater.

.DESCRIPTION
    Works out who made the machine, then drives that vendor's official update tool:

      Dell     Dell Command | Update (dcu-cli.exe)
      HP       HP Image Assistant (HPImageAssistant.exe) - HP business PCs only
      Lenovo   LSUClient PowerShell module (community, MIT, widely used) - talks to Lenovo's
               own update catalogue, the same one Lenovo System Update uses

    1. Scans and lists what's available (drivers and firmware; BIOS only with -IncludeBios)
    2. Asks before installing anything (or -Install to skip the question, -ScanOnly to just list)
    3. Installs, and says plainly if a restart is needed. It never restarts the machine itself.

    If the vendor's updater isn't installed it asks before installing it (-InstallTool to skip the
    question): Dell and HP from winget, LSUClient from the PowerShell Gallery.

    BIOS updates: BitLocker is suspended for one restart first, so the BIOS update doesn't trigger
    a recovery key prompt (Dell Command Update and LSUClient do this themselves; for HP the tool
    does it). Plug the charger in - vendors won't flash a BIOS on battery.

.PARAMETER IncludeBios
    Include BIOS/UEFI updates. Off by default.

.PARAMETER Install
    Install what the scan finds without asking.

.PARAMETER ScanOnly
    List what's available and stop.

.PARAMETER InstallTool
    Install the vendor's updater if it's missing, without asking.

.PARAMETER LogFolder
    Where logs and vendor reports go. Default C:\ProgramData\OEMUpdates.

.EXAMPLE
    .\Invoke-OEMUpdate.ps1

.EXAMPLE
    .\Invoke-OEMUpdate.ps1 -IncludeBios -Install -InstallTool
    (Unattended: everything including BIOS, installing the vendor tool if needed. No restart.)

.EXAMPLE
    .\Invoke-OEMUpdate.ps1 -ScanOnly
    (Exit code 2 when updates are waiting - usable as an RMM or Intune detection check.)

.NOTES
    Run as Administrator. Needs internet access.
    Exit codes: 0 = up to date, or updates installed
                3010 = updates installed, restart needed (shutdown, for some Lenovo BIOS updates)
                2 = updates available but not installed (-ScanOnly, or you said no)
                1 = something failed, the vendor tool is missing, or it's not a Dell/HP/Lenovo
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch] $IncludeBios,
    [switch] $Install,
    [switch] $ScanOnly,
    [switch] $InstallTool,
    [string] $LogFolder = (Join-Path $env:ProgramData 'OEMUpdates')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null
$Interactive = [Environment]::UserInteractive -and -not $PSSenderInfo

function Write-Step($m)  { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)    { Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Write-Bad($m)   { Write-Host "    [XX] $m" -ForegroundColor Red }

function Read-YesNo {
    # Never blocks an unattended run: no console, no question, the answer is no.
    param([string] $Question)
    if (-not $Interactive) { return $false }
    try { $a = Read-Host "    $Question [y/N]" } catch { return $false }
    "$a".Trim() -match '^(y|yes)$'
}

function Invoke-Native {
    # Runs a vendor exe and returns its exit code. Console tools (dcu-cli) have their output shown
    # live and kept in the log. -Wait is for windowed tools (HP Image Assistant), which HP says to
    # run with Start-Process -Wait; they write their own logs and reports.
    param([string] $Exe, [string[]] $Arguments, [string] $Log, [switch] $Wait)
    Add-Content -LiteralPath $Log -Value ("{0}  {1} {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Exe, ($Arguments -join ' '))
    if ($Wait) {
        $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        Add-Content -LiteralPath $Log -Value "exit $($p.ExitCode)"
        return $p.ExitCode
    }
    & $Exe @Arguments | Tee-Object -FilePath $Log -Append | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    $LASTEXITCODE
}

function Install-WithWinget {
    param([string] $Id, [string] $Name)
    $winget = Get-Command -Name 'winget' -ErrorAction SilentlyContinue
    if (-not $winget) { throw "winget isn't available here, so $Name can't be installed automatically. Install it from the vendor's site, then run this again." }
    Write-Host "    Installing $Name with winget ($Id)..."
    & winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { throw "winget couldn't install $Name (exit $LASTEXITCODE)." }
}

function Confirm-ToolInstall {
    param([string] $Name, [switch] $NoAsk)
    Write-Warn2 "$Name isn't installed on this machine."
    if ($NoAsk) { return $true }
    if (-not $Interactive) { Write-Warn2 'Unattended, so not installing it. Run with -InstallTool to allow that.'; return $false }
    Read-YesNo "Install $Name now?"
}

# Everything the vendor sections hand back, in one shape.
function ConvertTo-UpdateItem {
    param([string] $Name, [string] $Version, [string] $Type, [string] $Severity, [string] $Id, [bool] $IsBios = $false, $Source = $null)
    [pscustomobject]@{ Name = $Name; Version = $Version; Type = $Type; Severity = $Severity; Id = $Id; IsBios = $IsBios; Source = $Source }
}

function Show-UpdateList {
    param($Items)
    foreach ($u in $Items) {
        $tag = if ($u.IsBios) { ' [BIOS]' } else { '' }
        Write-Host ('    - {0}{1}' -f $u.Name, $tag)
        $bits = @($u.Version, $u.Type, $u.Severity, $u.Id) | Where-Object { $_ }
        if ($bits) { Write-Host ('      {0}' -f ($bits -join ' | ')) -ForegroundColor DarkGray }
    }
}

function Suspend-BitLockerOnce {
    # One restart's worth, so a BIOS flash doesn't trip the recovery key prompt. Resumes by itself.
    try {
        $os = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ([string]$os.ProtectionStatus -eq 'On') {
            Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 | Out-Null
            Write-Ok 'BitLocker suspended for the next restart (it resumes by itself)'
        }
    }
    catch { Write-Warn2 "Couldn't check or suspend BitLocker: $($_.Exception.Message). Suspend it by hand before restarting." }
}

# ================================================================================================
#  Who made it?
# ================================================================================================
$cs    = Get-CimInstance -ClassName Win32_ComputerSystem
$maker = [string]$cs.Manufacturer
$model = [string]$cs.Model
$vendor = switch -Regex ($maker) {
    '^Dell'                   { 'Dell' }
    '^(HP|Hewlett[- ]Packard)' { 'HP' }
    '^Lenovo'                 { 'Lenovo' }
    default                   { $null }
}
$friendlyModel = $model
if ($vendor -eq 'Lenovo') {
    # Lenovo's Model is a machine-type code (e.g. 21CB); the marketing name lives elsewhere.
    try { $v = (Get-CimInstance -ClassName Win32_ComputerSystemProduct).Version; if ($v) { $friendlyModel = "$v ($model)" } } catch { $friendlyModel = $model }
}

Write-Step "OEM updates on $env:COMPUTERNAME - $maker $friendlyModel"
if (-not $vendor) {
    Write-Warn2 "This isn't a Dell, HP or Lenovo, so there's no vendor updater to drive."
    Write-Host  '    Use Windows Update instead: Settings > Windows Update > Advanced options > Optional updates.'
    exit 1
}
$what = if ($IncludeBios) { 'drivers, firmware and BIOS' } else { 'drivers and firmware (BIOS excluded - use -IncludeBios)' }
Write-Host "    Looking for $what."

if ($IncludeBios) {
    try {
        $batt = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
        # BatteryStatus 1 = discharging (on battery)
        if ($batt.Count -and @($batt | Where-Object { $_.BatteryStatus -eq 1 }).Count) {
            Write-Warn2 'Running on battery. Plug the charger in - BIOS updates are refused on battery.'
        }
    }
    catch { Write-Verbose 'No battery info' }
}

$log      = Join-Path $LogFolder "${vendor}_$stamp.log"
$reportDir = Join-Path $LogFolder "${vendor}_$stamp"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

# Each vendor block sets: $updates (list), and an installer scriptblock that returns
# [pscustomobject]@{ Code = 0|3010|1; Message = '...' }
$updates = @()
$installer = $null

switch ($vendor) {

# ================================================================================================
#  Dell - Dell Command | Update CLI
# ================================================================================================
'Dell' {
    $find = { @("$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe", "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe") |
              Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1 }
    $dcu = & $find
    if (-not $dcu) {
        if (-not (Confirm-ToolInstall 'Dell Command | Update' -NoAsk:$InstallTool)) { exit 1 }
        try { Install-WithWinget -Id 'Dell.CommandUpdate.Universal' -Name 'Dell Command | Update' } catch { Write-Bad $_.Exception.Message; exit 1 }
        $dcu = & $find
        if (-not $dcu) { Write-Bad 'Dell Command | Update installed, but dcu-cli.exe still isn''t where expected.'; exit 1 }
        Write-Ok 'Dell Command | Update installed'
    }

    $types = if ($IncludeBios) { 'driver,firmware,bios' } else { 'driver,firmware' }
    $dellCodes = @{
        1 = 'Updates installed; a restart is needed to finish.'
        2 = 'Dell Command | Update hit an unknown error - see the log.'
        3 = 'Dell Command | Update says this isn''t a Dell.'
        4 = 'Not running as administrator.'
        5 = 'A restart is already pending from earlier updates. Restart, then run this again.'
        6 = 'Dell Command | Update is already running (app or another script). Close it and retry.'
        7 = 'Dell Command | Update doesn''t support this model.'
        8 = 'No update types selected (toolkit bug - please report it).'
        501 = 'The scan failed while working out the available updates.'
        503 = 'A download failed during the scan - check the internet connection.'
        1000 = 'Couldn''t read the result of the install.'
        1002 = 'A download failed during the install - check the internet connection.'
        3000 = 'The Dell Client Management Service isn''t running.'
        3001 = 'The Dell Client Management Service isn''t installed - reinstall Dell Command | Update.'
        3003 = 'The Dell Client Management Service is busy - wait a minute and retry.'
        3005 = 'The Dell Client Management Service is installing pending updates - wait and retry.'
    }

    Write-Step 'Scanning with Dell Command | Update'
    $code = Invoke-Native $dcu @('/scan', "-updateType=$types", "-report=$reportDir", "-outputLog=$reportDir\scan.log") $log
    if ($code -eq 500) { $updates = @() }
    elseif ($code -ne 0) {
        $why = if ($dellCodes.ContainsKey([int]$code)) { $dellCodes[[int]$code] } else { "Unexpected exit code $code - see $log" }
        Write-Bad "Scan failed ($code): $why"; exit 1
    }
    else {
        $xml = Get-ChildItem -LiteralPath $reportDir -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($xml) {
            [xml]$doc = Get-Content -LiteralPath $xml.FullName -Raw
            # SelectSingleNode, not $_.name: on an XmlElement ".name" can mean the tag name, not the child.
            $field = { param($n, $k) $x = $n.SelectSingleNode($k); if ($x) { $x.InnerText.Trim() } }
            $updates = @($doc.SelectNodes('//update') | ForEach-Object {
                $type = & $field $_ 'type'
                ConvertTo-UpdateItem -Name (& $field $_ 'name') -Version (& $field $_ 'version') -Type $type `
                    -Severity (& $field $_ 'urgency') -Id (& $field $_ 'release') -IsBios ([string]$type -match 'BIOS')
            })
        }
        if (-not $updates) {
            # No report file: fall back to the "ABCDE: Name -- Type -- Urgency" lines DCU prints.
            $updates = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*([A-Z0-9]{5}):\s+(.+)$' } | ForEach-Object {
                $parts = $Matches[2] -split '\s+--\s+'
                ConvertTo-UpdateItem -Name $parts[0] -Type $(if ($parts.Count -gt 1) { $parts[1] }) -Severity $(if ($parts.Count -gt 2) { $parts[2] }) -Id $Matches[1] -IsBios ($Matches[2] -match 'BIOS')
            })
        }
        # Exit 0 from a scan means updates were found, even if their details couldn't be read.
        if (-not $updates) { $updates = @(ConvertTo-UpdateItem -Name "Updates found - see the Dell report in $reportDir") }
    }

    $installer = {
        $args2 = @('/applyUpdates', "-updateType=$types", '-autoSuspendBitLocker=enable', '-reboot=disable', "-outputLog=$reportDir\apply.log")
        $c = Invoke-Native $dcu $args2 $log
        switch ($c) {
            0       { [pscustomobject]@{ Code = 0; Message = 'Updates installed.' } }
            1       { [pscustomobject]@{ Code = 3010; Message = $dellCodes[1] } }
            500     { [pscustomobject]@{ Code = 0; Message = 'Nothing left to install.' } }
            default {
                $why = if ($dellCodes.ContainsKey([int]$c)) { $dellCodes[[int]$c] } else { "Unexpected exit code $c - see $log" }
                [pscustomobject]@{ Code = 1; Message = "Install failed ($c): $why" }
            }
        }
    }
}

# ================================================================================================
#  HP - HP Image Assistant
# ================================================================================================
'HP' {
    $find = { Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'SWSetup') -Filter 'HPImageAssistant.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
              Sort-Object { try { [version]$_.VersionInfo.FileVersion } catch { [version]'0.0' } } -Descending |
              Select-Object -First 1 -ExpandProperty FullName }
    $hpia = & $find
    if (-not $hpia) {
        if (-not (Confirm-ToolInstall 'HP Image Assistant' -NoAsk:$InstallTool)) { exit 1 }
        try { Install-WithWinget -Id 'HP.ImageAssistant' -Name 'HP Image Assistant' } catch { Write-Bad $_.Exception.Message; exit 1 }
        $hpia = & $find
        if (-not $hpia) { Write-Bad 'HP Image Assistant installed, but HPImageAssistant.exe isn''t under C:\SWSetup.'; exit 1 }
        Write-Ok 'HP Image Assistant installed'
    }

    $cats = if ($IncludeBios) { 'Drivers,Firmware,BIOS' } else { 'Drivers,Firmware' }
    $hpCodes = @{
        256  = 'Nothing to install.'
        257  = 'Nothing was selected to install.'
        3010 = 'Updates installed; a restart is needed to finish.'
        3020 = 'One or more updates failed to install - see the report folder.'
        4096 = 'HP Image Assistant doesn''t support this model (it covers HP business PCs; consumer models use HP Support Assistant).'
        4097 = 'HP Image Assistant rejected the parameters (toolkit bug - please report it).'
        4098 = 'No internet connection.'
        16384 = 'HP Image Assistant couldn''t open HP''s reference file - check the internet connection and retry.'
    }
    $common = @("/Category:$cats", '/Selection:All', '/Silent', "/ReportFolder:$reportDir")

    Write-Step 'Scanning with HP Image Assistant (a few minutes)'
    $code = Invoke-Native $hpia (@('/Operation:Analyze', '/Action:List') + $common) $log -Wait
    if ($code -in 256, 257) { $updates = @() }
    elseif ($code -ne 0) {
        $why = if ($hpCodes.ContainsKey([int]$code)) { $hpCodes[[int]$code] } else { "Unexpected exit code $code - see $reportDir" }
        Write-Bad "Scan failed ($code): $why"; exit 1
    }
    else {
        $json = Get-ChildItem -LiteralPath $reportDir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($json) {
            try {
                $data = Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json
                $recs = @($data.HPIA.Recommendations)
                $updates = @($recs | Where-Object { $_ } | ForEach-Object {
                    $isBios = ([string]$_.TargetComponent -match 'BIOS') -or ([string]$_.Name -match 'BIOS')
                    ConvertTo-UpdateItem -Name $(if ($_.Name) { $_.Name } else { $_.TargetComponent }) -Version $_.ReferenceVersion `
                        -Type $_.TargetComponent -Severity $_.RecommendationValue -Id $_.SoftPaqId -IsBios $isBios
                })
            }
            catch { Write-Verbose "Couldn't read the HP report: $($_.Exception.Message)" }
        }
        if (-not $updates) { $updates = @(ConvertTo-UpdateItem -Name "Updates found - see the HP report in $reportDir") }
    }

    $installer = {
        if ($IncludeBios -and @($updates | Where-Object IsBios).Count) { Suspend-BitLockerOnce }
        $dl = Join-Path $reportDir 'SoftPaqs'
        $c = Invoke-Native $hpia (@('/Operation:Analyze', '/Action:Install') + $common + @("/SoftpaqDownloadFolder:$dl")) $log -Wait
        switch ($c) {
            0       { [pscustomobject]@{ Code = 0; Message = 'Updates installed.' } }
            3010    { [pscustomobject]@{ Code = 3010; Message = $hpCodes[3010] } }
            256     { [pscustomobject]@{ Code = 0; Message = 'Nothing left to install.' } }
            default {
                $why = if ($hpCodes.ContainsKey([int]$c)) { $hpCodes[[int]$c] } else { "Unexpected exit code $c - see $reportDir" }
                [pscustomobject]@{ Code = 1; Message = "Install failed ($c): $why" }
            }
        }
    }
}

# ================================================================================================
#  Lenovo - LSUClient module
# ================================================================================================
'Lenovo' {
    if (-not (Get-Module -ListAvailable -Name LSUClient)) {
        if (-not (Confirm-ToolInstall 'the LSUClient PowerShell module' -NoAsk:$InstallTool)) { exit 1 }
        try {
            Write-Host '    Installing LSUClient from the PowerShell Gallery...'
            if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
            }
            Install-Module -Name LSUClient -Repository PSGallery -Scope AllUsers -Force -AllowClobber
            Write-Ok 'LSUClient installed'
        }
        catch { Write-Bad "Couldn't install LSUClient: $($_.Exception.Message)"; exit 1 }
    }
    Import-Module LSUClient -Force

    Write-Step 'Scanning Lenovo''s update catalogue'
    try { $found = @(Get-LSUpdate) }
    catch { Write-Bad "Scan failed: $($_.Exception.Message)"; exit 1 }

    $isBiosPkg = { param($p) ([string]$p.Type -eq 'BIOS') -or ([string]$p.Category -match 'BIOS|UEFI') -or ([string]$p.Title -match 'BIOS|UEFI') }
    $wanted = @($found | Where-Object { $IncludeBios -or -not (& $isBiosPkg $_) })
    $manual = @($wanted | Where-Object { -not $_.Installer.Unattended })
    $pkgs   = @($wanted | Where-Object { $_.Installer.Unattended })
    $updates = @($pkgs | ForEach-Object {
        ConvertTo-UpdateItem -Name $_.Title -Version $_.Version -Type $_.Category -Severity $_.Severity -Id $_.ID -IsBios (& $isBiosPkg $_) -Source $_
    })
    if ($manual) {
        Write-Warn2 ("{0} update(s) can't be installed silently - install by hand from Lenovo's site or Lenovo Vantage:" -f $manual.Count)
        foreach ($m in $manual) { Write-Host "      $($m.Title) ($($m.ID))" -ForegroundColor DarkGray }
    }

    $installer = {
        $pk = @($updates | ForEach-Object { $_.Source })
        try {
            $pk | Save-LSUpdate | Out-Null
            $results = @(Install-LSUpdate -Package $pk)
        }
        catch { return [pscustomobject]@{ Code = 1; Message = "Install failed: $($_.Exception.Message)" } }
        $failed = @($results | Where-Object {
            ($_.PSObject.Properties['Success'] -and -not $_.Success) -or ($_.FailureReason -and [string]$_.FailureReason -ne 'None') })
        foreach ($f in $failed) { Write-Bad "$($f.Title): $($f.FailureReason)" }
        $actions = @($results | ForEach-Object { [string]$_.PendingAction })
        $shutdown = $actions -contains 'SHUTDOWN'
        $reboot   = @($actions | Where-Object { $_ -like 'REBOOT*' }).Count -gt 0
        $msg = if ($shutdown) { 'Updates installed. A BIOS update needs a full SHUTDOWN (not a restart) - the machine powers back on to finish it.' }
               elseif ($reboot) { 'Updates installed; a restart is needed to finish.' } else { 'Updates installed.' }
        if ($failed) { [pscustomobject]@{ Code = 1; Message = "$($failed.Count) of $($results.Count) update(s) failed. $msg" } }
        elseif ($shutdown -or $reboot) { [pscustomobject]@{ Code = 3010; Message = $msg } }
        else { [pscustomobject]@{ Code = 0; Message = $msg } }
    }
}
}

# ================================================================================================
#  Show, ask, install
# ================================================================================================
if (-not $updates.Count) {
    Write-Ok 'Up to date - nothing to install.'
    Write-Host "    Log: $log"
    exit 0
}

Write-Host ''
Write-Host ("    {0} update(s) available:" -f $updates.Count) -ForegroundColor Cyan
Show-UpdateList $updates
if (-not $IncludeBios) { Write-Host '    (BIOS updates not included - run with -IncludeBios to check those too.)' -ForegroundColor DarkGray }

if ($ScanOnly) { Write-Host "`n    Scan only - nothing installed. Log: $log"; exit 2 }
if (-not $Install -and -not (Read-YesNo "Install these $($updates.Count) update(s) now?")) {
    Write-Host "    Not installed. Log: $log"
    exit 2
}

Write-Step 'Installing (drivers can blank the screen or drop the network for a moment)'
$result = & $installer
switch ($result.Code) {
    0    { Write-Ok $result.Message }
    3010 { Write-Warn2 $result.Message; Write-Host '    Not restarting automatically - restart when it suits the user.' -ForegroundColor Yellow }
    default { Write-Bad $result.Message }
}
Write-Host "    Log: $log"
exit $result.Code
