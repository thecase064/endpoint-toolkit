<#
.SYNOPSIS
    Clears stuck print jobs: stops the Print Spooler, deletes the queued jobs, starts it again.

.DESCRIPTION
    For a print queue that won't clear, jobs stuck on "Deleting" or "Error", or a spooler that keeps
    crashing on a bad job.

      1. Shows how many jobs are queued and how old the oldest is, so you know what's going
      2. Stops the Print Spooler (and anything that depends on it)
      3. Deletes the queued job files (*.SPL and *.SHD only) from the spool folder
      4. Starts the Spooler again, plus any dependants that were running

    Every queued job on every printer on this PC is deleted - people will need to print again.
    Printers, drivers and settings aren't touched.

    The spool folder is read from the registry in case it's been moved, and only .SPL/.SHD files
    are ever deleted, so a mis-set spool folder can't take anything else with it.

.EXAMPLE
    .\Clear-PrintSpooler.ps1

.NOTES
    Run as Administrator.
    Exit codes: 0 = cleared and the spooler is running, 1 = it isn't running at the end, or jobs stayed.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-SpoolFile {
    param([string] $Folder)
    @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue |
        Where-Object { @('.spl', '.shd') -contains $_.Extension.ToLower() })
}

Write-Host "`n==> Print spooler clear on $env:COMPUTERNAME" -ForegroundColor Cyan

$spoolDir = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers' -ErrorAction SilentlyContinue).DefaultSpoolDirectory
if (-not $spoolDir) { $spoolDir = Join-Path $env:SystemRoot 'System32\spool\PRINTERS' }
$spoolDir = [Environment]::ExpandEnvironmentVariables($spoolDir)

# Count jobs from the files rather than asking the spooler, which may be the thing that's hung.
$jobs = @(Get-SpoolFile $spoolDir)
$jobCount = @($jobs | Where-Object { $_.Extension -ieq '.shd' }).Count
if ($jobs.Count) {
    $oldest = ($jobs | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
    $sizeMB = [math]::Round(($jobs | Measure-Object Length -Sum).Sum / 1MB, 1)
    Write-Host ("    {0} job(s) queued, {1} MB, oldest from {2:yyyy-MM-dd HH:mm}" -f $jobCount, $sizeMB, $oldest)
}
else { Write-Host '    No job files queued - restarting the spooler anyway.' }

$spooler    = Get-Service -Name Spooler
$dependants = @($spooler.DependentServices | Where-Object { $_.Status -eq 'Running' })

Write-Host '    Stopping the Print Spooler...'
try {
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    (Get-Service -Name Spooler).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
}
catch {
    # A wedged spooler can ignore the stop request; end the process instead.
    Write-Host '    [!!] It didn''t stop cleanly - ending spoolsv.exe' -ForegroundColor Yellow
    Get-Process -Name spoolsv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$removed = 0
foreach ($f in (Get-SpoolFile $spoolDir)) {
    try { Remove-Item -LiteralPath $f.FullName -Force; $removed++ }
    catch { Write-Verbose "Couldn't delete $($f.Name): $($_.Exception.Message)" }
}
$left = @(Get-SpoolFile $spoolDir)
if ($left.Count) { Write-Host ("    [!!] {0} job file(s) couldn't be deleted (still locked)" -f $left.Count) -ForegroundColor Yellow }
else       { Write-Host ("    [OK] Deleted {0} job file(s) from {1}" -f $removed, $spoolDir) -ForegroundColor Green }

Write-Host '    Starting the Print Spooler...'
try {
    Start-Service -Name Spooler
    (Get-Service -Name Spooler).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    foreach ($d in $dependants) {
        try { Start-Service -Name $d.Name } catch { Write-Host "    [!!] Couldn't restart $($d.DisplayName): $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}
catch { Write-Verbose "Start failed: $($_.Exception.Message)" }

if ((Get-Service -Name Spooler).Status -eq 'Running') {
    Write-Host '    [OK] Print Spooler is running. Ask them to print again.' -ForegroundColor Green
    if ($left.Count) { exit 1 }
    exit 0
}
Write-Host '    [!!] Print Spooler isn''t running. Check System event log (source PrintService / Service Control Manager).' -ForegroundColor Red
exit 1
