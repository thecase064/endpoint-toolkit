<#
.SYNOPSIS
    Resets the Windows Update components: stops the update services, sets aside the download cache and
    catalog database, starts everything again and kicks off a fresh scan.

.DESCRIPTION
    The classic fix for updates stuck downloading, failing with the same error every night, or
    "Something went wrong" in Settings:

      1. Reports anything that commonly causes it instead (pending reboot, WSUS policy, low disk)
      2. Stops wuauserv, BITS, cryptsvc, msiserver, UsoSvc and Delivery Optimization
      3. Renames  C:\Windows\SoftwareDistribution  ->  SoftwareDistribution.old-<timestamp>
                  C:\Windows\System32\catroot2     ->  catroot2.old-<timestamp>
         (renamed, not deleted: if anything goes wrong you can put them back)
      4. Optionally resets Winsock (-ResetNetwork)
      5. Starts the services and triggers an update scan

    Side effect: the update history list in Settings starts empty again. The updates themselves stay
    installed; only the list is lost.

.PARAMETER ResetNetwork
    Also run "netsh winsock reset". Only for updates that fail to download at all. Needs a reboot.

.PARAMETER RemoveOldCopies
    Delete the .old-* folders left by previous runs of this script (this run's copies are kept).

.PARAMETER NoScan
    Don't trigger an update scan at the end.

.EXAMPLE
    .\Reset-WindowsUpdate.ps1

.EXAMPLE
    .\Reset-WindowsUpdate.ps1 -RemoveOldCopies

.NOTES
    Run as Administrator.
    Exit codes: 0 = reset done, 3010 = done, reboot needed (Winsock reset or reboot already pending), 1 = a step failed.
    Log: C:\ProgramData\WindowsUpdateReset\Reset_<timestamp>.log
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch] $ResetNetwork,
    [switch] $RemoveOldCopies,
    [switch] $NoScan
)

$ErrorActionPreference = 'Stop'
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogDir = Join-Path $env:ProgramData 'WindowsUpdateReset'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir "Reset_$stamp.log"
$script:Failed       = $false
$script:NeedsReboot  = $false

function Write-ResetLog {
    param([string] $Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERR')] [string] $Level = 'INFO')
    $line = '{0}  [{1,-4}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line
    $colour = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } default { 'Cyan' } }
    Write-Host $line -ForegroundColor $colour
}

$Services   = @('wuauserv', 'bits', 'cryptsvc', 'msiserver', 'UsoSvc', 'dosvc')
$Folders    = @(
    @{ Path = Join-Path $env:SystemRoot 'SoftwareDistribution'; Name = 'SoftwareDistribution' }
    @{ Path = Join-Path $env:SystemRoot 'System32\catroot2';    Name = 'catroot2' }
)

Write-ResetLog "===== Windows Update reset on $env:COMPUTERNAME ====="

# ------------------------------------------------------------------------------------------------
#  1. Things that cause update failures that a reset won't fix
# ------------------------------------------------------------------------------------------------
$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($pending) {
    Write-ResetLog 'A reboot is already pending. That alone often clears stuck updates - reboot after this run.' 'WARN'
    $script:NeedsReboot = $true
}

$wuPolicy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
$auPolicy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
if ($auPolicy -and $auPolicy.UseWUServer -eq 1 -and $wuPolicy.WUServer) {
    Write-ResetLog "Device is pointed at WSUS: $($wuPolicy.WUServer). If that server is gone, no reset will help - fix the policy." 'WARN'
}

$sysDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f $env:SystemDrive)
if ($sysDrive -and $sysDrive.FreeSpace -lt 10GB) {
    Write-ResetLog ('Only {0:N1} GB free on {1}. Feature updates need 20 GB+; clear space as well.' -f ($sysDrive.FreeSpace / 1GB), $env:SystemDrive) 'WARN'
}

# ------------------------------------------------------------------------------------------------
#  2. Stop services
# ------------------------------------------------------------------------------------------------
$wasRunning = @()
foreach ($name in $Services) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    if ($svc.Status -eq 'Running') { $wasRunning += $name }
}

function Invoke-ServiceStop {
    param([string] $Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -eq 'Stopped') { return $true }
    try {
        Stop-Service -Name $Name -Force -ErrorAction Stop
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        Write-ResetLog "Stopped $Name" 'OK'
        return $true
    }
    catch {
        # Delivery Optimization and the orchestrator refuse to stop on some builds; that's fine.
        $level = if ($Name -in 'dosvc', 'UsoSvc') { 'WARN' } else { 'ERR' }
        Write-ResetLog "Couldn't stop ${Name}: $($_.Exception.Message)" $level
        return ($level -eq 'WARN')
    }
}

Write-ResetLog 'Stopping update services'
foreach ($name in $Services) {
    if (-not (Invoke-ServiceStop $name)) { $script:Failed = $true }
}

# ------------------------------------------------------------------------------------------------
#  3. Set aside SoftwareDistribution and catroot2
# ------------------------------------------------------------------------------------------------
if (-not $script:Failed) {
    foreach ($f in $Folders) {
        if (-not (Test-Path -LiteralPath $f.Path)) { Write-ResetLog "$($f.Name) not found - nothing to rename"; continue }
        $newName = '{0}.old-{1}' -f $f.Name, $stamp
        $done = $false
        for ($attempt = 1; $attempt -le 3 -and -not $done; $attempt++) {
            try {
                Rename-Item -LiteralPath $f.Path -NewName $newName -ErrorAction Stop
                $done = $true
                Write-ResetLog "Renamed $($f.Name) -> $newName" 'OK'
            }
            catch {
                # cryptsvc and BITS like to restart themselves when something asks for them; stop and retry.
                Write-ResetLog "Rename of $($f.Name) failed (attempt $attempt): $($_.Exception.Message)" 'WARN'
                foreach ($name in 'cryptsvc', 'bits', 'wuauserv') { [void](Invoke-ServiceStop $name) }
                Start-Sleep -Seconds 3
            }
        }
        if (-not $done) { Write-ResetLog "Couldn't rename $($f.Name). Something still has it open - reboot and run again." 'ERR'; $script:Failed = $true }
    }
}
else {
    Write-ResetLog 'Skipping the folder reset because a core service would not stop.' 'ERR'
}

# ------------------------------------------------------------------------------------------------
#  4. Winsock (optional)
# ------------------------------------------------------------------------------------------------
if ($ResetNetwork) {
    Write-ResetLog 'Resetting Winsock'
    $out = & (Join-Path $env:SystemRoot 'System32\netsh.exe') winsock reset 2>&1
    if ($LASTEXITCODE -eq 0) { Write-ResetLog 'Winsock reset - reboot required' 'OK'; $script:NeedsReboot = $true }
    else { Write-ResetLog "netsh winsock reset failed: $out" 'ERR'; $script:Failed = $true }
}

# ------------------------------------------------------------------------------------------------
#  5. Start services and scan
# ------------------------------------------------------------------------------------------------
Write-ResetLog 'Starting services'
foreach ($name in (@('cryptsvc', 'bits', 'wuauserv') + $wasRunning | Select-Object -Unique)) {
    try {
        Start-Service -Name $name -ErrorAction Stop
        Write-ResetLog "Started $name" 'OK'
    }
    catch { Write-ResetLog "Couldn't start ${name}: $($_.Exception.Message)" 'WARN' }
}

if (-not $NoScan -and -not $script:Failed) {
    $uso = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
    try {
        if (Test-Path -LiteralPath $uso) { & $uso StartScan }
        else { (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow() }
        Write-ResetLog 'Update scan triggered - check Settings > Windows Update in a few minutes.' 'OK'
    }
    catch { Write-ResetLog "Couldn't trigger a scan ($($_.Exception.Message)). Click Check for updates manually." 'WARN' }
}

# ------------------------------------------------------------------------------------------------
#  6. Tidy previous runs (optional)
# ------------------------------------------------------------------------------------------------
if ($RemoveOldCopies) {
    foreach ($f in $Folders) {
        $parent = Split-Path -Path $f.Path -Parent
        Get-ChildItem -LiteralPath $parent -Directory -Filter "$($f.Name).old-*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne ('{0}.old-{1}' -f $f.Name, $stamp) } |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop; Write-ResetLog "Removed old copy $($_.Name)" 'OK' }
                catch { Write-ResetLog "Couldn't remove $($_.Name): $($_.Exception.Message)" 'WARN' }
            }
    }
}

# ------------------------------------------------------------------------------------------------
Write-ResetLog ''
if ($script:Failed) {
    Write-ResetLog "Reset did NOT complete cleanly - see above. Log: $LogFile" 'ERR'
    exit 1
}
if ($script:NeedsReboot) {
    Write-ResetLog "Reset done. Reboot, then check for updates. Log: $LogFile" 'OK'
    exit 3010
}
Write-ResetLog "Reset done. Check for updates (a scan is already running). Log: $LogFile" 'OK'
exit 0
