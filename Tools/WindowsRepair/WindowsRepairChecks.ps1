# Windows Repair Checks Script
# Run PowerShell as Administrator before launching this script

$ErrorActionPreference = "Stop"

# Check for Admin rights
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host "Please run this script as Administrator." -ForegroundColor Red
    pause
    exit 1
}

$steps = @(
    @{
        Name = "Repairing Windows image with DISM RestoreHealth"
        Command = "dism /online /cleanup-image /restorehealth"
    },
    @{
        Name = "Scanning and repairing system files with SFC"
        Command = "sfc /scannow"
    },
    @{
        Name = "Cleaning Windows component store with DISM ResetBase"
        Command = "dism /online /cleanup-image /startcomponentcleanup /resetbase"
    }
)

for ($i = 0; $i -lt $steps.Count; $i++) {
    $step = $steps[$i]
    $percent = [int](($i / $steps.Count) * 100)

    Write-Progress `
        -Activity "Windows Repair Checks" `
        -Status $step.Name `
        -PercentComplete $percent

    Write-Host ""
    Write-Host "[$($i + 1)/$($steps.Count)] $($step.Name)" -ForegroundColor Cyan
    Write-Host "Running: $($step.Command)" -ForegroundColor DarkGray
    Write-Host ""

    cmd.exe /c $step.Command

    # 3010 = success, reboot pending (DISM returns it after a successful repair)
    if ($LASTEXITCODE -notin 0, 3010) {
        Write-Progress -Activity "Windows Repair Checks" -Completed
        Write-Host ""
        Write-Host "A command failed. Stopping script." -ForegroundColor Red
        Write-Host "Failed step: $($step.Name)" -ForegroundColor Red
        Write-Host "Exit code: $LASTEXITCODE" -ForegroundColor Red
        pause
        exit $LASTEXITCODE
    }
}

Write-Progress -Activity "Windows Repair Checks" -Status "Complete" -PercentComplete 100
Start-Sleep -Seconds 1
Write-Progress -Activity "Windows Repair Checks" -Completed

Write-Host ""
Write-Host "====================================================" -ForegroundColor Green
Write-Host " CHECKS COMPLETE - PLEASE RESTART SYSTEM" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green
Write-Host ""

pause