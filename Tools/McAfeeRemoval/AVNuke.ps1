<#
.SYNOPSIS
    Removes McAfee consumer products pre-installed on Dell devices.

.DESCRIPTION
    Dell ships McAfee in up to three forms - this script handles all of them:
      1. Microsoft Store (AppX) version  - McAfee Personal Security
      2. MSI-based components            - Safe Connect, suite components
      3. EXE-based components            - WebAdvisor, LiveSafe / MSC suite

    Runs fully silent. Designed for SYSTEM context (Intune / Datto RMM)
    or an elevated PowerShell session.

    Log file: C:\ProgramData\McAfeeRemoval\McAfeeRemoval_<date>.log

.NOTES
    Exit 0    = No McAfee found / nothing to do
    Exit 3010 = Removed successfully - reboot recommended
    Exit 1    = Leftovers remain (check log) - run MCPR for stubborn suites
#>

#Requires -RunAsAdministrator

# ------------------------------------------------------------- Logging -----
$LogDir  = 'C:\ProgramData\McAfeeRemoval'
$LogFile = Join-Path $LogDir ("McAfeeRemoval_{0:yyyy-MM-dd_HHmm}.log" -f (Get-Date))
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    Write-Output $line
}

Write-Log "===== McAfee removal started on $env:COMPUTERNAME ====="
$RemovedSomething = $false

# ------------------------------------ 1. Stop McAfee services & processes --
Write-Log "Stopping McAfee services and processes..."

$services = Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.DisplayName -like '*McAfee*' -or
    $_.Name -like 'mfe*' -or
    $_.Name -in 'ModuleCoreService','PEFService','McAPExe','mccspsvc'
}
foreach ($svc in $services) {
    try {
        Stop-Service -Name $svc.Name -Force -ErrorAction Stop
        Write-Log "Stopped service: $($svc.Name)"
    } catch {
        Write-Log "Could not stop service $($svc.Name): $($_.Exception.Message)" 'WARN'
    }
}

# Explicit list - avoids accidentally killing Windows processes
$procNames = 'mcshield','McUICnt','McAPExe','ModuleCoreService','PEFService',
             'ProtectedModuleHost','mfemms','mfevtps','QcShm','McCSPServiceHost'
foreach ($p in $procNames) {
    Stop-Process -Name $p -Force -ErrorAction SilentlyContinue
}

# ------------------------------------ 2. Remove Store (AppX) version -------
Write-Log "Checking for McAfee Store (AppX) packages..."
try {
    $appx = Get-AppxPackage -AllUsers -Name '*McAfee*' -ErrorAction SilentlyContinue
    foreach ($pkg in $appx) {
        Write-Log "Removing AppX package: $($pkg.PackageFullName)"
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        $RemovedSomething = $true
    }
} catch {
    Write-Log "AppX removal error: $($_.Exception.Message)" 'WARN'
}

try {
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*McAfee*' } |
        ForEach-Object {
            Write-Log "Removing provisioned package: $($_.DisplayName)"
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
            $RemovedSomething = $true
        }
} catch {
    Write-Log "Provisioned package removal error: $($_.Exception.Message)" 'WARN'
}

# ------------------------------------ 3. WebAdvisor (supports /s switch) ---
$waPaths = @(
    "$env:ProgramFiles\McAfee\WebAdvisor\uninstaller.exe",
    "${env:ProgramFiles(x86)}\McAfee\WebAdvisor\uninstaller.exe"
)
foreach ($wa in $waPaths) {
    if (Test-Path $wa) {
        Write-Log "Uninstalling WebAdvisor silently: $wa"
        Start-Process -FilePath $wa -ArgumentList '/s' -Wait -NoNewWindow
        $RemovedSomething = $true
    }
}

# ------------------------------------ 4. Registry-driven uninstalls --------
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$entries = foreach ($root in $uninstallRoots) {
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props.DisplayName -like '*McAfee*') { $props }
    }
}

foreach ($app in $entries) {
    Write-Log "Found installed product: $($app.DisplayName)"

    # --- MSI-based products ---
    if ($app.PSChildName -match '^\{[0-9A-F-]+\}$' -or $app.UninstallString -match 'msiexec') {
        $guid = if ($app.PSChildName -match '^\{.+\}$') { $app.PSChildName }
                elseif ($app.UninstallString -match '(\{[0-9A-Fa-f-]+\})') { $Matches[1] }
        if ($guid) {
            Write-Log "MSI uninstall: msiexec /x $guid /qn /norestart"
            $proc = Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart REBOOT=ReallySuppress" -Wait -PassThru
            Write-Log "msiexec exit code: $($proc.ExitCode)"
            if ($proc.ExitCode -in 0, 3010, 1605) { $RemovedSomething = $true }
            continue
        }
    }

    # --- EXE-based products: attempt silent switch with a timeout ---
    if ($app.UninstallString) {
        if ($app.UninstallString -match '^"([^"]+)"\s*(.*)$') {
            $exe = $Matches[1]; $exeArgs = $Matches[2]
        } else {
            $exe = ($app.UninstallString -split '\s+')[0]
            $exeArgs = ($app.UninstallString -replace [regex]::Escape($exe), '').Trim()
        }

        if (Test-Path $exe) {
            $silentArgs = "$exeArgs /s".Trim()
            Write-Log "EXE uninstall attempt: `"$exe`" $silentArgs"
            try {
                $proc = Start-Process -FilePath $exe -ArgumentList $silentArgs -PassThru
                if (-not $proc.WaitForExit(300000)) {  # 5-minute timeout
                    Write-Log "Uninstaller hung after 5 min - killed. This product likely needs MCPR." 'WARN'
                    $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                } else {
                    Write-Log "Uninstaller exit code: $($proc.ExitCode)"
                    $RemovedSomething = $true
                }
            } catch {
                Write-Log "EXE uninstall failed: $($_.Exception.Message)" 'WARN'
            }
        } else {
            Write-Log "Uninstaller path not found: $exe" 'WARN'
        }
    }
}

# ------------------------------------ 5. Verify & clean leftovers ----------
Start-Sleep -Seconds 5

$remaining = foreach ($root in $uninstallRoots) {
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props.DisplayName -like '*McAfee*') { $props.DisplayName }
    }
}

if ($remaining) {
    Write-Log "Products still registered: $($remaining -join ', ')" 'WARN'
    Write-Log "Stubborn suites (LiveSafe / Total Protection) need MCPR: https://download.mcafee.com/molbin/iss-loc/SupportTools/MCPR/MCPR.exe" 'WARN'
    Write-Log "===== Finished with leftovers - manual follow-up required ====="
    exit 1
}

# Safe to clear orphaned folders once nothing is registered
$leftoverDirs = @(
    "$env:ProgramFiles\McAfee",
    "${env:ProgramFiles(x86)}\McAfee",
    "$env:ProgramData\McAfee"
) | Where-Object { Test-Path $_ }

foreach ($dir in $leftoverDirs) {
    try {
        Remove-Item $dir -Recurse -Force -ErrorAction Stop
        Write-Log "Deleted leftover folder: $dir"
    } catch {
        Write-Log "Could not delete ${dir}: $($_.Exception.Message)" 'WARN'
    }
}

if ($RemovedSomething) {
    Write-Log "===== McAfee removed - reboot recommended ====="
    exit 3010
} else {
    Write-Log "===== No McAfee products found ====="
    exit 0
}