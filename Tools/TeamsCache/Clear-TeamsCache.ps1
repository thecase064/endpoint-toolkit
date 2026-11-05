<#
.SYNOPSIS
    Clears the Teams cache for the signed-in user, then starts Teams again.

.DESCRIPTION
    The first thing to try when Teams is slow, blank, stuck signing in, showing an old photo or
    name, or missing chats and channels. Closes Teams, empties the cache folders Microsoft
    documents, then restarts it:

      New Teams      %LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams
      Classic Teams  %APPDATA%\Microsoft\Teams   (only if it's still there)

    Only the cache folder is cleared, not the whole MSTeams package, so the user's Teams settings
    survive. The first launch afterwards is slower while Teams rebuilds the cache.

    Runs as the user, not as admin: the cache is per user. If it's run under a different account
    from the person signed in (e.g. an elevated admin session) it would clear the wrong cache, so
    it says so and stops unless you pass -Force.

.PARAMETER NoRestart
    Don't start Teams again afterwards.

.PARAMETER Force
    Clear the cache of the account running this even though someone else is signed in.

.EXAMPLE
    .\Clear-TeamsCache.ps1

.NOTES
    Exit codes: 0 = cleared, 1 = nothing cleared (no Teams cache found, wrong account) or some
    files stayed locked.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $NoRestart,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')

$me      = Get-CurrentUserName
$package = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe'
$caches  = @(
    [pscustomobject]@{ Name = 'New Teams';     Path = Join-Path $package 'LocalCache\Microsoft\MSTeams' }
    [pscustomobject]@{ Name = 'Classic Teams'; Path = Join-Path $env:APPDATA 'Microsoft\Teams' }
)

Write-Host "`n==> Teams cache clear for $me" -ForegroundColor Cyan

$other = Get-OtherSignedInUser
if ($other -and -not $Force) {
    Write-Host "    [!!] $other is signed in, but this is running as $me, so it would clear the wrong" -ForegroundColor Yellow
    Write-Host  "         person's cache. Run it from the user's own session (not elevated), or add -Force." -ForegroundColor Yellow
    exit 1
}

$found = @($caches | Where-Object { Test-Path -LiteralPath $_.Path })
if (-not $found) {
    Write-Host "    [!!] No Teams cache found for $me - is Teams installed and has this user opened it?" -ForegroundColor Yellow
    exit 1
}

# Close Teams in this session only (on a shared or terminal server, other users' Teams is left alone).
$session = (Get-Process -Id $PID).SessionId
$running = @(Get-Process -Name 'ms-teams', 'Teams' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
if ($running) {
    Write-Host '    Closing Teams...'
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and
           @(Get-Process -Name 'ms-teams', 'Teams' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }).Count) {
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 2   # its WebView2 helpers take a moment longer to let go of files
}

$locked = 0
foreach ($c in $found) {
    $items  = @(Get-ChildItem -LiteralPath $c.Path -Force -ErrorAction SilentlyContinue)
    $before = $items.Count
    foreach ($i in $items) { Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $left = @(Get-ChildItem -LiteralPath $c.Path -Force -Recurse -File -ErrorAction SilentlyContinue).Count
    $locked += $left
    if ($left) {
        Write-Host ("    [!!] {0}: cleared, but {1} file(s) were locked and stayed" -f $c.Name, $left) -ForegroundColor Yellow
    }
    else {
        Write-Host ("    [OK] {0}: cache cleared ({1} item(s))" -f $c.Name, $before) -ForegroundColor Green
    }
}
if ($locked) { Write-Host '         Restart the PC and run this again before Teams opens.' -ForegroundColor Yellow }

if (-not $NoRestart) {
    if (Test-Path -LiteralPath $package) {
        Write-Host '    Starting Teams (first launch is slower while it rebuilds the cache)...'
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:AppsFolder\MSTeams_8wekyb3d8bbwe!MSTeams' }
        catch { Write-Host "    [!!] Couldn't start Teams: $($_.Exception.Message). Open it from the Start menu." -ForegroundColor Yellow }
    }
    else { Write-Host '    New Teams isn''t installed for this user, so not restarting it.' }
}

if ($locked) { exit 1 }
exit 0
