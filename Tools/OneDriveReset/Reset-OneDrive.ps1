<#
.SYNOPSIS
    Resets the OneDrive sync app for the signed-in user (Microsoft's onedrive.exe /reset), then
    makes sure OneDrive is running again.

.DESCRIPTION
    The fix Microsoft gives for OneDrive sync problems that won't clear: stuck on "Processing
    changes", sync errors that keep coming back, or files that never upload.

    It finds OneDrive.exe instead of guessing: the copy that's running, then the one OneDrive
    registered for this user, then the three places Microsoft lists:

      %LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe            (per-user install)
      C:\Program Files\Microsoft OneDrive\OneDrive.exe          (per-machine install)
      C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe    (older 32-bit per-machine install)

    Before resetting it lists the accounts signed in and any SharePoint / Teams libraries synced
    outside the OneDrive folder, so you know what to check afterwards. Then it runs
    OneDrive.exe /reset, waits for OneDrive to come back, and starts it if it doesn't.

    What a reset does (Microsoft): resets all OneDrive settings and disconnects every sync
    connection, personal and work. No files are deleted. OneDrive then does a full sync. If only
    some folders were chosen to sync, that has to be set again; synced libraries may need syncing
    again unless a policy adds them.

    Runs as the user, NOT as admin. OneDrive refuses to run with full admin rights, and the reset
    only touches the account running it. So it stops if it's elevated (including an admin's remote
    session or SYSTEM from an RMM), and if a different person is signed in at the PC (unless -Force).

.PARAMETER CheckOnly
    Show the OneDrive install, accounts and synced libraries, and change nothing.

.PARAMETER WaitSeconds
    How long to wait for OneDrive to start again by itself before starting it. Default 120.

.PARAMETER Force
    Reset the OneDrive of the account running this even though someone else is signed in at the
    console (e.g. your own session on a terminal server).

.EXAMPLE
    .\Reset-OneDrive.ps1 -CheckOnly

.EXAMPLE
    .\Reset-OneDrive.ps1

.NOTES
    Exit codes: 0 = reset and OneDrive running again (or -CheckOnly), 1 = not reset (elevated,
    wrong account, OneDrive not found, old OneDrive wouldn't close) or OneDrive didn't start again.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [ValidateRange(10, 900)]
    [int] $WaitSeconds = 120,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')

$me = Get-CurrentUserName
Write-Host "`n==> OneDrive reset for $me" -ForegroundColor Cyan

# --- Right person, no admin rights -----------------------------------------------------------------

if (Test-RunningAsAdmin) {
    Write-Host "    [!!] This is running as administrator ($me). OneDrive won't start with admin rights," -ForegroundColor Yellow
    Write-Host  '         and the reset only touches the account running it. Run it in the user''s own session,' -ForegroundColor Yellow
    Write-Host  '         not elevated: open the toolkit without "Run as administrator", then pick it again.' -ForegroundColor Yellow
    Write-Host  '         It can''t run from a remote shell or an RMM script (those are admin or SYSTEM).' -ForegroundColor Yellow
    exit 1
}

$other = Get-OtherSignedInUser
if ($other -and -not $Force) {
    Write-Host "    [!!] $other is signed in, but this is running as $me, so it would reset the wrong" -ForegroundColor Yellow
    Write-Host  "         person's OneDrive. Run it from the user's own session (not elevated), or add -Force." -ForegroundColor Yellow
    exit 1
}

# --- Helpers -------------------------------------------------------------------------------------

$session = (Get-Process -Id $PID).SessionId

function Get-OneDriveProcess {
    # OneDrive in this session only: on a terminal server, other people's OneDrive is left alone.
    @(Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
}

function Get-RegValue {
    param([string] $Path, [string] $Name)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        if ($item -and $item.PSObject.Properties[$Name]) { return $item.$Name }
    }
    catch { Write-Verbose "No $Path\$Name" }
    $null
}

function Get-RegValueName {
    # The value names under a key (OneDrive keeps synced folder paths as value names).
    param([string] $Path)
    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        @($item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' } |
            ForEach-Object { $_.Name })
    }
    catch { @() }
}

function Get-RegSubKeyName {
    param([string] $Path)
    try { @(Get-ChildItem -LiteralPath $Path -ErrorAction Stop | ForEach-Object { $_.PSChildName }) }
    catch { @() }
}

function Test-UnderFolder {
    param([string] $Path, [string] $Folder)
    if (-not $Path -or -not $Folder) { return $false }
    $p = $Path.TrimEnd('\'); $f = $Folder.TrimEnd('\')
    ($p -eq $f) -or $p.StartsWith("$f\", [StringComparison]::OrdinalIgnoreCase)
}

# --- Find OneDrive.exe -----------------------------------------------------------------------------

$candidates = New-Object System.Collections.Generic.List[object]
foreach ($p in (Get-OneDriveProcess)) {
    if ($p.Path) { $candidates.Add([pscustomobject]@{ Path = [string]$p.Path; From = 'running' }) }
}
$trigger = Get-RegValue -Path 'HKCU:\Software\Microsoft\OneDrive' -Name 'OneDriveTrigger'
if ($trigger -and ([string]$trigger) -match 'OneDrive\.exe"?$') {
    $candidates.Add([pscustomobject]@{ Path = ([string]$trigger).Trim('"'); From = 'registered for this user' })
}
$defaults = @(
    $(if ($env:LOCALAPPDATA)           { Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe' })
    $(if ($env:ProgramFiles)           { Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe' })
    $(if (${env:ProgramFiles(x86)})    { Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe' })
)
foreach ($d in $defaults) { $candidates.Add([pscustomobject]@{ Path = $d; From = 'default location' }) }

$exe = $candidates | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path -PathType Leaf) } | Select-Object -First 1
if (-not $exe) {
    Write-Host "    [!!] OneDrive.exe not found for $me. Checked:" -ForegroundColor Yellow
    foreach ($d in $defaults) { Write-Host "           $d" -ForegroundColor Yellow }
    Write-Host  '         The OneDrive sync app isn''t installed for this user. If OneDrive came from the' -ForegroundColor Yellow
    Write-Host  '         Microsoft Store, reset it in Settings > Apps > OneDrive > Advanced options > Reset.' -ForegroundColor Yellow
    exit 1
}

$version = $null
try { $version = (Get-Item -LiteralPath $exe.Path).VersionInfo.FileVersion } catch { Write-Verbose 'No version info' }
$kind = if ($env:LOCALAPPDATA -and (Test-UnderFolder -Path $exe.Path -Folder $env:LOCALAPPDATA)) { 'per-user' } else { 'per-machine' }
$runningBefore = @(Get-OneDriveProcess)
$state = if ($runningBefore) { 'running' } else { 'not running' }
$details = @($(if ($version) { $version } else { 'version unknown' }), $kind, $state) -join ', '
Write-Host "    OneDrive: $($exe.Path) ($details)"

# --- What's connected now --------------------------------------------------------------------------

$accountsKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
$accounts  = New-Object System.Collections.Generic.List[object]
$libraries = New-Object System.Collections.Generic.List[string]
foreach ($name in (Get-RegSubKeyName -Path $accountsKey | Sort-Object)) {
    $key    = "$accountsKey\$name"
    $email  = [string](Get-RegValue -Path $key -Name 'UserEmail')
    $folder = [string](Get-RegValue -Path $key -Name 'UserFolder')
    if (-not $email -and -not $folder) { continue }    # a leftover key with no account in it
    $type = if ($name -like 'Business*') { 'Work' } elseif ($name -eq 'Personal') { 'Personal' } else { $name }
    $accounts.Add([pscustomobject]@{ Type = $type; Email = $email; Folder = $folder })

    if ($name -like 'Business*') {
        # Libraries synced from SharePoint / Teams. Shortcuts inside the OneDrive folder come back
        # with OneDrive itself, so only folders outside it are listed.
        $paths = @()
        $cache = "$key\ScopeIdToMountPointPathCache"
        foreach ($v in (Get-RegValueName -Path $cache)) { $paths += [string](Get-RegValue -Path $cache -Name $v) }
        foreach ($t in (Get-RegSubKeyName -Path "$key\Tenants")) { $paths += Get-RegValueName -Path "$key\Tenants\$t" }
        foreach ($p in $paths) {
            if ($p -match '^[A-Za-z]:\\' -and -not (Test-UnderFolder -Path $p -Folder $folder) -and
                -not ($libraries | Where-Object { $_ -eq $p.TrimEnd('\') })) {
                $libraries.Add($p.TrimEnd('\'))
            }
        }
    }
}

if ($accounts.Count) {
    Write-Host '    Accounts signed in:'
    foreach ($a in $accounts) {
        $who = if ($a.Email) { $a.Email } else { '(no address recorded)' }
        Write-Host ("      {0,-9} {1}{2}" -f $a.Type, $who, $(if ($a.Folder) { " -> $($a.Folder)" }))
    }
}
else { Write-Host '    Accounts signed in: none' }

if ($libraries.Count) {
    Write-Host '    Synced libraries (sync these again afterwards unless a policy adds them):'
    foreach ($l in ($libraries | Sort-Object | Select-Object -First 15)) { Write-Host "      $l" }
    if ($libraries.Count -gt 15) { Write-Host "      ...and $($libraries.Count - 15) more" }
}

$policyKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
$silent      = (Get-RegValue -Path $policyKey -Name 'SilentAccountConfig') -eq 1
$kfm         = [bool](Get-RegValue -Path $policyKey -Name 'KFMSilentOptIn')
$autoMount   = (@(Get-RegValueName -Path "$policyKey\TenantAutoMount").Count +
                @(Get-RegValueName -Path 'HKCU:\SOFTWARE\Policies\Microsoft\OneDrive\TenantAutoMount').Count) -gt 0
$policies = @(
    $(if ($silent)    { 'silent sign-in' })
    $(if ($kfm)       { 'Desktop/Documents/Pictures moved to OneDrive' })
    $(if ($autoMount) { 'libraries added automatically' })
)
if ($policies) { Write-Host "    Set by policy: $($policies -join ', ')" }

Write-Host ''
Write-Host '    A reset disconnects every account above and resets OneDrive''s settings. No files are deleted.'
Write-Host '    OneDrive then re-syncs everything, which can take a while on big libraries.'

if ($CheckOnly) {
    Write-Host "`n    Check only: nothing changed." -ForegroundColor Cyan
    exit 0
}

# --- Reset -----------------------------------------------------------------------------------------

Write-Host "`n    Resetting OneDrive ($($exe.Path) /reset)..."
$beforeIds = @($runningBefore | ForEach-Object { $_.Id })
try { $reset = Start-Process -FilePath $exe.Path -ArgumentList '/reset' -PassThru }
catch {
    Write-Host "    [!!] Couldn't start the reset: $($_.Exception.Message)" -ForegroundColor Yellow
    exit 1
}

# The reset closes OneDrive, clears its settings, and normally starts it again by itself.
Wait-Process -Id $reset.Id -Timeout 60 -ErrorAction SilentlyContinue
$resetStillRunning = [bool](Get-OneDriveProcess | Where-Object { $_.Id -eq $reset.Id })

$oldLeft = @(Get-OneDriveProcess | Where-Object { $beforeIds -contains $_.Id })
for ($i = 0; $oldLeft -and $i -lt 8; $i++) {
    Start-Sleep -Seconds 2
    $oldLeft = @(Get-OneDriveProcess | Where-Object { $beforeIds -contains $_.Id })
}
if ($oldLeft) {
    Write-Host '    [!!] OneDrive didn''t close for the reset, so it probably didn''t happen. Quit OneDrive from' -ForegroundColor Yellow
    Write-Host  '         its icon (Settings > Pause syncing > Quit OneDrive) and run this again.' -ForegroundColor Yellow
    exit 1
}
if ($beforeIds) { Write-Host '    [OK] OneDrive closed for the reset' -ForegroundColor Green }

$back = $null
if ($resetStillRunning) {
    $back = 'it carried on running after the reset'
}
else {
    Write-Host ("    Waiting for OneDrive to start again (up to {0})..." -f $(if ($WaitSeconds % 60) { "$WaitSeconds s" } else { "$($WaitSeconds / 60) min" }))
    for ($i = 0; $i -lt [math]::Ceiling($WaitSeconds / 2); $i++) {
        if (Get-OneDriveProcess | Where-Object { $beforeIds -notcontains $_.Id -and $_.Id -ne $reset.Id }) { $back = 'started again by itself'; break }
        Start-Sleep -Seconds 2
    }
    if (-not $back) {
        Write-Host '    It didn''t come back by itself, so starting it...'
        try {
            $null = Start-Process -FilePath $exe.Path -PassThru
            for ($i = 0; $i -lt 10; $i++) {
                if (Get-OneDriveProcess | Where-Object { $beforeIds -notcontains $_.Id }) { $back = 'started by this tool'; break }
                Start-Sleep -Seconds 2
            }
        }
        catch { Write-Verbose "Start failed: $($_.Exception.Message)" }
    }
}

if (-not $back) {
    Write-Host '    [!!] The reset ran, but OneDrive isn''t running. Open OneDrive from the Start menu.' -ForegroundColor Yellow
    exit 1
}
Write-Host "    [OK] OneDrive is running again ($back)" -ForegroundColor Green

# --- What's left for the tech ----------------------------------------------------------------------

$work = @($accounts | Where-Object { $_.Type -eq 'Work' -and $_.Email } | ForEach-Object { $_.Email })
Write-Host "`n    Next:"
if ($silent -and $work) {
    Write-Host "      - Silent sign-in is set by policy, so $($work -join ', ') may sign back in by itself."
    Write-Host '        If OneDrive shows "Set up OneDrive" instead, sign in there.'
}
elseif ($accounts.Count) {
    $all = @($accounts | Where-Object { $_.Email } | ForEach-Object { $_.Email })
    Write-Host "      - Sign in to OneDrive again$(if ($all) { ' as ' + ($all -join ' and ') })."
}
else { Write-Host '      - Sign in to OneDrive if it asks.' }
Write-Host '      - If it says the OneDrive folder already exists, choose "Use this folder" to carry on with it.'
Write-Host '      - If the user only synced some folders, set Choose folders again once the sync finishes.'
if ($libraries.Count) {
    $how = if ($autoMount) { ' (ones a policy adds come back by themselves, which can take up to 8 hours)' } else { '' }
    Write-Host "      - Sync the libraries listed above again from SharePoint or Teams$how."
}
exit 0
