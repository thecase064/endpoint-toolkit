<#
.SYNOPSIS
    Frees disk space from old user profiles: lists every profile with when it was last really used,
    its size and the files it holds outside OneDrive, then deletes only the ones you pick.

.DESCRIPTION
    Shared PCs and hand-me-down laptops collect the profiles of people who left months ago. This tool:

      1. Lists:  every user profile, oldest first, with when it was last used, its size, the files in
                 its Desktop / Documents / Pictures / Videos / Music / Downloads (not in OneDrive, so
                 they go with the profile) and whether the account still exists or is disabled.
      2. With -Remove: asks which to delete (numbers, or "all" for every stale one), shows the total
                 and asks once more. Deletes through Windows' own profile API (Win32_UserProfile:
                 the folder and its registry entry together, never just the folder), then checks each
                 one has gone and how much space came back.

    "Last used" comes from the sign-in and sign-out times Windows records for each profile (the
    same ones Windows' own "delete profiles older than" policy uses since Windows 10 1809), not from
    LastUseTime or NTUSER.DAT, which antivirus, updates and backup software keep bumping.
    NTUSER.DAT is only the fallback when no times are recorded. OneDrive files that are only in the
    cloud don't count towards the size.

    Never offered: a profile in use (signed in, or still loaded), system and service accounts, the
    built-in Administrator, the account running this, profiles outside the profiles folder and
    anything matching -Exclude. Offered by number but never by "all" or -Yes: profiles with no
    last-used date, the account that set this PC up (Entra join) and the last person to sign in.

    Also reports: folders in the profiles folder with no profile entry (Windows won't remove them),
    ".bak" profile entries (the "signed in with a temporary profile" problem) and the "delete
    profiles older than" policy. It changes neither.

.PARAMETER Remove
    Offer the stale profiles for deletion. You pick which, then confirm. Needs admin.

.PARAMETER OlderThanDays
    A profile is stale when it hasn't been used for this many days. Default 90, at least 30.

.PARAMETER User
    Only these profiles, by folder name, account or sign-in address (wildcards allowed), whatever
    their age. With -Remove: the "delete this person's profile" job.

.PARAMETER Exclude
    Never offer these profiles (folder name, account or sign-in address; wildcards allowed).

.PARAMETER Yes
    With -Remove: delete every stale profile without asking (for RMM). Skips the ones that are only
    offered by number (no last-used date, the Entra join account, the last person to sign in),
    unless they're named with -User.

.PARAMETER SkipSize
    Don't measure profile sizes (faster on big profiles).

.PARAMETER Quiet
    Print only the one-line summary (for RMM).

.PARAMETER PassThru
    Emit the profiles, notes and actions to the pipeline.

.EXAMPLE
    .\Remove-StaleProfile.ps1

.EXAMPLE
    .\Remove-StaleProfile.ps1 -Remove -OlderThanDays 180

.EXAMPLE
    .\Remove-StaleProfile.ps1 -Remove -User jbloggs

.EXAMPLE
    .\Remove-StaleProfile.ps1 -Remove -Yes -OlderThanDays 365 -Quiet

.NOTES
    Run as Administrator (listing works without, but can't size other people's profiles).
    Exit codes: 0 = done, 1 = a deletion failed, -Remove without admin, or -User matched nothing.
    Nothing is sent anywhere. Deleted profiles can't be brought back.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Remove,
    [ValidateRange(30, 3650)] [int] $OlderThanDays = 90,
    [string[]] $User,
    [string[]] $Exclude,
    [switch] $Yes,
    [switch] $SkipSize,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')

$now      = Get-Date
$Computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }
$IsAdmin  = Test-RunningAsAdmin
$MeSid    = Get-CurrentUserSid
$Sep      = [IO.Path]::DirectorySeparatorChar

$ProfileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$PolicyKey      = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
$LogonUiKey     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
$JoinInfoKey    = 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
$IdentityKey    = 'HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache'

$LocalFolders    = 'Desktop', 'Documents', 'Pictures', 'Videos', 'Music', 'Downloads'
$NotProfiles     = 'Public', 'Default', 'Default User', 'All Users'
$CloudOnlyAttr   = [int64](0x1000 -bor 0x40000 -bor 0x400000)   # Offline, RecallOnOpen, RecallOnDataAccess
$LowDword        = [int64]4294967295

# ================================================================================================
#  Plumbing
# ================================================================================================
$Notes   = [System.Collections.Generic.List[object]]::new()
$Actions = [System.Collections.Generic.List[object]]::new()
function Add-Note {
    param([ValidateSet('WARN', 'INFO')] [string] $Status, [string] $Detail, [string] $Fix)
    $Notes.Add([pscustomobject]@{ Status = $Status; Detail = $Detail; Fix = $Fix })
}
function Add-Action {
    param([string] $Step, [ValidateSet('OK', 'FAILED', 'SKIPPED')] [string] $Result, [string] $Detail)
    $Actions.Add([pscustomobject]@{ Step = $Step; Result = $Result; Detail = $Detail })
    if (-not $Quiet) {
        $colour = switch ($Result) { 'OK' { 'Green' } 'FAILED' { 'Red' } default { 'DarkGray' } }
        Write-Host ('   [{0}] {1}' -f $Result, $Step) -ForegroundColor $colour
        if ($Detail) { Write-Host "          $Detail" -ForegroundColor DarkGray }
    }
}
function Write-Line {
    param([string] $Text, [string] $Colour = 'Gray')
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Colour }
}
function Read-Answer {
    # A closed or non-interactive input (RMM, remote session) reads as a blank answer: nothing is deleted.
    param([string] $Prompt)
    try { [string](Read-Host -Prompt $Prompt) } catch { '' }
}

function Get-RegKey {
    param([string] $Path)
    $h = [ordered]@{}
    $p = $null
    try { $p = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop } catch { $p = $null }
    if ($p) { foreach ($prop in $p.PSObject.Properties) { if ($prop.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { $h[$prop.Name] = $prop.Value } } }
    $h
}
function Get-Val { param($Map, [string] $Name) if ($Map -and $Map.Contains($Name)) { $Map[$Name] } else { $null } }
function Get-SubKeyName {
    param([string] $Path)
    try { @(Get-ChildItem -LiteralPath $Path -ErrorAction Stop | ForEach-Object { [string]$_.PSChildName }) } catch { @() }
}

function ConvertFrom-FileTimePart {
    # The profile service stores each time as a FILETIME split into two DWORDs. Read back from the
    # registry a DWORD can come out negative, so each half is masked to 32 bits before joining.
    param($High, $Low)
    if ($null -eq $High -or $null -eq $Low) { return $null }
    $ft = (([int64]$High -band $LowDword) -shl 32) -bor ([int64]$Low -band $LowDword)
    if ($ft -le 0) { return $null }
    $d = $null
    try { $d = [datetime]::FromFileTime($ft) } catch { return $null }
    if ($d.Year -lt 2000 -or $d -gt $now.AddDays(1)) { return $null }
    $d
}

function Format-Size {
    param($Bytes)
    if ($null -eq $Bytes) { return '?' }
    $b = [double]$Bytes
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) }
    else { '{0:N0} B' -f $b }
}
function Format-Age {
    param($Days)
    if ($null -eq $Days) { return 'unknown' }
    if ($Days -le 0) { return 'today' }
    if ($Days -eq 1) { return '1 day ago' }
    "$Days days ago"
}

function Test-CloudOnly { param([int64] $Attributes) ($Attributes -band $CloudOnlyAttr) -ne 0 }
function Test-SkipDir {
    # Junctions and symbolic links: the old "Application Data" style ones (hidden + system) and any
    # other link. OneDrive's own folders are reparse points too, but not links, so they're measured.
    param($Dir)
    $a = [int64]$Dir.Attributes
    if (-not ($a -band 0x400)) { return $false }
    if (($a -band 0x6) -eq 0x6) { return $true }
    $lt = $null
    try { $lt = [string]$Dir.LinkType } catch { $lt = $null }
    $lt -in 'Junction', 'SymbolicLink'
}
function Measure-Folder {
    param([string] $Path, [switch] $NoDesktopIni)
    if (-not $Path -or -not [IO.Directory]::Exists($Path)) { return $null }
    $m = [pscustomobject]@{ Bytes = [int64]0; Files = 0; Unread = 0 }
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@([IO.DirectoryInfo]::new($Path), 0))
    while ($stack.Count) {
        $entry = $stack.Pop()
        $items = $null
        try { $items = $entry[0].GetFileSystemInfos() } catch { $m.Unread++; continue }
        foreach ($i in $items) {
            if ($i -is [IO.DirectoryInfo]) {
                if ($entry[1] -lt 64 -and -not (Test-SkipDir $i)) { $stack.Push(@($i, ($entry[1] + 1))) }
            }
            elseif (-not (Test-CloudOnly ([int64]$i.Attributes))) {
                if ($NoDesktopIni -and $i.Name -eq 'desktop.ini') { continue }
                $m.Bytes += $i.Length
                $m.Files++
            }
        }
    }
    $m
}

function Get-DiskFree {
    param([string] $Drive)
    try {
        $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction Stop | Select-Object -First 1
        if ($d -and $null -ne $d.FreeSpace) { return [pscustomobject]@{ Free = [int64]$d.FreeSpace; Size = [int64]$d.Size } }
    }
    catch { Write-Verbose "Couldn't read free space on ${Drive}: $($_.Exception.Message)" }
    $null
}

function Test-NameMatch {
    param($Item, [string[]] $Patterns)
    foreach ($pat in @($Patterns | Where-Object { $_ })) {
        foreach ($n in @($Item.Folder, $Item.Account, $Item.Upn) | Where-Object { $_ }) {
            if ($n -like $pat -or $n -like "*\$pat") { return $true }
        }
    }
    $false
}

# ================================================================================================
#  Read
# ================================================================================================
$pl = Get-RegKey $ProfileListKey
$ProfilesDir = [string](Get-Val $pl 'ProfilesDirectory')
if (-not $ProfilesDir) { $ProfilesDir = (Join-Path $(if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }) 'Users') }
$ProfilesDir = [Environment]::ExpandEnvironmentVariables($ProfilesDir).TrimEnd('\', '/')
$Drive = if ($ProfilesDir -match '^([A-Za-z]:)') { $Matches[1].ToUpper() } elseif ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }

$cimProfiles = $null
try { $cimProfiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop) }
catch {
    $msg = "$Computer profiles - couldn't read the profile list: $($_.Exception.Message)"
    if ($Quiet) { Write-Output $msg } else { Write-Host $msg -ForegroundColor Red }
    exit 1
}

# Local accounts: names, disabled, and the PC's own SID prefix (to tell a deleted local account
# from a domain account that just can't be looked up right now).
$LocalAccounts = @{}
$MachinePrefix = $null
try {
    foreach ($a in @(Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop)) {
        $LocalAccounts[[string]$a.SID] = $a
        if (-not $MachinePrefix -and [string]$a.SID -match '^(S-1-5-21-\d+-\d+-\d+)-\d+$') { $MachinePrefix = $Matches[1] }
    }
}
catch { Write-Verbose "Couldn't list local accounts: $($_.Exception.Message)" }

$LastSid = [string](Get-Val (Get-RegKey $LogonUiKey) 'LastLoggedOnUserSID')
$JoinUsers = @(foreach ($k in (Get-SubKeyName $JoinInfoKey)) { $e = Get-Val (Get-RegKey "$JoinInfoKey\$k") 'UserEmail'; if ($e) { [string]$e } })

function Get-Account {
    param([string] $Sid)
    $a = [ordered]@{ Account = $null; Upn = $null; Type = 'Other'; State = $null }
    if ($Sid -like 'S-1-12-1-*') {
        $a.Type = 'Entra'
        $cache = Get-RegKey "$IdentityKey\$Sid\IdentityCache\$Sid"
        foreach ($n in 'UserName', 'SAMName', 'DisplayName') { $v = Get-Val $cache $n; if ($v) { $a.Upn = [string]$v; break } }
        if ($a.Upn -and $a.Upn -notmatch '@') { $a.Upn = $null }
        $a.Account = if ($a.Upn) { $a.Upn } else { Resolve-AccountSid $Sid }
        if (-not $a.Account) { $a.State = 'Entra account this PC has no name for' }
    }
    elseif ($Sid -like 'S-1-5-21-*') {
        $local = $LocalAccounts[$Sid]
        if ($local) {
            $a.Type = 'Local'
            $a.Account = "$Computer\$($local.Name)"
            if ($local.Disabled) { $a.State = 'account disabled' }
        }
        elseif ($MachinePrefix -and $Sid.StartsWith("$MachinePrefix-")) { $a.Type = 'Local'; $a.State = 'account deleted' }
        else {
            $a.Type = 'Domain'
            $a.Account = Resolve-AccountSid $Sid
            if (-not $a.Account) { $a.State = 'account not found (deleted, or no domain controller in reach)' }
        }
    }
    $a
}

$profileRoot = $ProfilesDir + $Sep
$Profiles = [System.Collections.Generic.List[object]]::new()
foreach ($c in $cimProfiles) {
    if ($c.Special) { continue }
    $sid  = [string]$c.SID
    $path = [string]$c.LocalPath
    $acct = Get-Account $sid
    $p = [pscustomobject]@{
        Number = 0; Sid = $sid; Path = $path; Folder = $(if ($path) { Split-Path $path -Leaf } else { '' })
        Account = $acct.Account; Upn = $acct.Upn; Type = $acct.Type; AccountState = $acct.State; Display = $null
        Loaded = [bool]$c.Loaded; FolderExists = [bool]($path -and [IO.Directory]::Exists($path))
        LastUsed = $null; AgeDays = $null; AgeFrom = $null
        Status = $null; KeptWhy = $null; AskOnly = @(); SizeBytes = $null; SizeNote = $null; LocalBytes = $null; LocalIn = @()
    }
    $p.Display = if ($p.Account) { $p.Account } elseif ($p.Folder) { $p.Folder } else { $sid }

    # Last used: the profile service's own sign-in / sign-out times, NTUSER.DAT only as a fallback.
    if ($p.Loaded) { $p.LastUsed = $now; $p.AgeDays = 0; $p.AgeFrom = 'in use' }
    else {
        $k = Get-RegKey "$ProfileListKey\$sid"
        $in  = ConvertFrom-FileTimePart (Get-Val $k 'LocalProfileLoadTimeHigh') (Get-Val $k 'LocalProfileLoadTimeLow')
        $out = ConvertFrom-FileTimePart (Get-Val $k 'LocalProfileUnloadTimeHigh') (Get-Val $k 'LocalProfileUnloadTimeLow')
        if ($in -or $out) {
            if ($out -and (-not $in -or $out -ge $in)) { $p.LastUsed = $out; $p.AgeFrom = 'sign-out' } else { $p.LastUsed = $in; $p.AgeFrom = 'sign-in' }
        }
        elseif ($p.FolderExists) {
            foreach ($hive in 'NTUSER.MAN', 'NTUSER.DAT') {
                $f = Join-Path $path $hive
                if ([IO.File]::Exists($f)) { $p.LastUsed = [IO.File]::GetLastWriteTime($f); $p.AgeFrom = $hive; break }
            }
        }
        if ($p.LastUsed) { $p.AgeDays = [int][math]::Max(0, [math]::Floor(($now - $p.LastUsed).TotalDays)) }
    }

    # Never offered, in this order.
    $p.KeptWhy = if ($p.Loaded) { 'in use (signed in, or still loaded)' }
                 elseif ($MeSid -and $sid -eq $MeSid) { 'the account running this' }
                 elseif ($sid -notlike 'S-1-5-21-*' -and $sid -notlike 'S-1-12-1-*') { 'system or service account' }
                 elseif ($sid -like 'S-1-5-21-*-500') { 'built-in Administrator' }
                 elseif (-not $path -or -not $path.StartsWith($profileRoot, [StringComparison]::OrdinalIgnoreCase)) { "outside $ProfilesDir" }
                 elseif ($Exclude -and (Test-NameMatch $p $Exclude)) { 'excluded (-Exclude)' }
                 else { $null }

    if ($User) {
        if (-not (Test-NameMatch $p $User)) { continue }
        $p.Status = if ($p.KeptWhy) { 'Kept' } else { 'Named' }
    }
    elseif ($p.KeptWhy) { $p.Status = 'Kept' }
    elseif ($null -eq $p.AgeDays) { $p.Status = 'Unknown' }
    elseif ($p.AgeDays -ge $OlderThanDays) { $p.Status = 'Stale' }
    else { $p.Status = 'Recent' }

    if ($p.Status -in 'Stale', 'Unknown', 'Named') {
        if ($null -eq $p.AgeDays) { $p.AskOnly += 'no last-used date' }
        if ($p.Upn -and @($JoinUsers | Where-Object { $_ -eq $p.Upn }).Count) { $p.AskOnly += 'this account set this PC up (Entra join)' }
        if ($LastSid -and $sid -eq $LastSid) { $p.AskOnly += 'the last person to sign in' }
    }
    $Profiles.Add($p)
}

$Offer = @(
    @($Profiles | Where-Object Status -eq 'Stale' | Sort-Object @{ Expression = 'AgeDays'; Descending = $true }, Display)
    @($Profiles | Where-Object Status -eq 'Unknown' | Sort-Object Display)
    @($Profiles | Where-Object Status -eq 'Named' | Sort-Object @{ Expression = { if ($null -eq $_.AgeDays) { [int]::MaxValue } else { $_.AgeDays } }; Descending = $true }, Display)
)
for ($i = 0; $i -lt $Offer.Count; $i++) { $Offer[$i].Number = $i + 1 }

# Sizes, only for the ones offered (measuring a 60 GB profile that isn't going anywhere is wasted time).
if (-not $SkipSize) {
    foreach ($p in $Offer) {
        if (-not $p.FolderExists) { continue }
        if (-not $Quiet) { Write-Host ("  Measuring {0} ..." -f $p.Path) -ForegroundColor DarkGray }
        $m = Measure-Folder $p.Path
        if ($m) {
            $p.SizeBytes = $m.Bytes
            if ($m.Unread) { $p.SizeNote = if ($IsAdmin) { "$($m.Unread) folder(s) couldn't be read" } else { 'run as admin for the full size' } }
        }
        $lb = [int64]0
        foreach ($lf in $LocalFolders) {
            $lm = Measure-Folder (Join-Path $p.Path $lf) -NoDesktopIni
            if ($lm -and $lm.Files) { $lb += $lm.Bytes; $p.LocalIn += $lf }
        }
        $p.LocalBytes = $lb
    }
}

# ---- Things this tool reports but doesn't change ----
foreach ($k in (Get-SubKeyName $ProfileListKey)) {
    if ($k -notlike '*.bak') { continue }
    $base = $k.Substring(0, $k.Length - 4)
    $who  = @($Profiles | Where-Object Sid -eq $base | ForEach-Object Display) | Select-Object -First 1
    if (-not $who) { $who = [string](Get-Val (Get-RegKey "$ProfileListKey\$k") 'ProfileImagePath') }
    Add-Note 'WARN' "Profile entry $k ($who): the ""signed in with a temporary profile"" problem." 'Fix by hand, not with this tool: back up the ProfileList key, keep the entry whose ProfileImagePath is the real folder (without .bak), delete the other, restart.'
}

$knownPaths = @($cimProfiles | ForEach-Object { [string]$_.LocalPath } | Where-Object { $_ })
try {
    foreach ($d in @(Get-ChildItem -LiteralPath $ProfilesDir -Directory -Force -ErrorAction Stop)) {
        if ($d.Name -in $NotProfiles) { continue }
        if (([int64]$d.Attributes) -band 0x400) { continue }
        if (@($knownPaths | Where-Object { $_ -ieq $d.FullName }).Count) { continue }
        $size = if ($SkipSize) { $null } else { $mm = Measure-Folder $d.FullName; if ($mm) { $mm.Bytes } else { $null } }
        Add-Note 'INFO' ("Folder {0}{1} has no profile entry, so Windows won't remove it." -f $d.FullName, $(if ($null -ne $size) { " ($(Format-Size $size))" } else { '' })) 'Check what''s in it, then delete it by hand if nobody needs it. This tool leaves it alone.'
    }
}
catch { Write-Verbose "Couldn't list ${ProfilesDir}: $($_.Exception.Message)" }

$cleanup = Get-Val (Get-RegKey $PolicyKey) 'CleanupProfiles'
if ($cleanup -and [int]$cleanup -gt 0) {
    Add-Note 'INFO' "Policy: Windows deletes profiles not used for $cleanup days when the PC restarts (""Delete user profiles older than"")." 'Set by Group Policy / Intune. Profiles still listed here as stale are ones that policy hasn''t reached yet, or ones it skips.'
}
if (-not $IsAdmin) { Add-Note 'INFO' 'Not running as admin: other people''s profile sizes can''t be read and nothing can be deleted.' 'Run it as admin.' }
if ($Yes -and -not $Remove) { Add-Note 'INFO' '-Yes does nothing without -Remove.' '' }

$diskBefore = Get-DiskFree $Drive

# ================================================================================================
#  Show
# ================================================================================================
function Write-Profile {
    param($p, [switch] $Numbered)
    $age  = if ($p.Loaded) { 'in use now' } else { 'last used ' + (Format-Age $p.AgeDays) }
    $size = if ($null -ne $p.SizeBytes) { " - $(Format-Size $p.SizeBytes)" } else { '' }
    $lead = if ($Numbered) { '{0,4}. ' -f $p.Number } else { '     - ' }
    $colour = switch ($p.Status) { 'Stale' { 'Yellow' } 'Named' { 'Yellow' } 'Unknown' { 'Yellow' } default { 'DarkGray' } }
    Write-Line ("{0}{1} - {2}{3}" -f $lead, $p.Display, $age, $size) $colour
    if (-not $Numbered) {
        if ($p.KeptWhy) { Write-Line ("        kept: {0}" -f $p.KeptWhy) 'DarkGray' }
        return
    }
    $bits = @($p.Path)
    if ($p.LastUsed -and -not $p.Loaded) { $bits += '{0} ({1})' -f $p.LastUsed.ToString('yyyy-MM-dd'), $p.AgeFrom }
    if ($p.AccountState) { $bits += $p.AccountState }
    if (-not $p.FolderExists) { $bits += 'no folder: only the registry entry is left' }
    if ($p.SizeNote) { $bits += $p.SizeNote }
    Write-Line ('        ' + ($bits -join '; ')) 'DarkGray'
    if ($p.LocalBytes) { Write-Line ("        {0} of files in {1}, not in OneDrive: they go with the profile" -f (Format-Size $p.LocalBytes), ($p.LocalIn -join ', ')) 'Yellow' }
    if ($p.KeptWhy) { Write-Line ("        kept: {0}" -f $p.KeptWhy) 'DarkGray' }
    elseif ($p.AskOnly.Count) { Write-Line ("        only if picked by number: {0}" -f ($p.AskOnly -join '; ')) 'DarkGray' }
}

$stale   = @($Profiles | Where-Object Status -eq 'Stale')
$unknown = @($Profiles | Where-Object Status -eq 'Unknown')
$named   = @($Profiles | Where-Object Status -eq 'Named')
$recent  = @($Profiles | Where-Object Status -eq 'Recent' | Sort-Object AgeDays, Display)
$kept    = @($Profiles | Where-Object Status -eq 'Kept' | Sort-Object Display)
$sumBytes = { param($list) $t = [int64]0; foreach ($x in $list) { if ($null -ne $x.SizeBytes) { $t += $x.SizeBytes } }; $t }

if (-not $Quiet) {
    Write-Host ''
    Write-Host ("== Old user profiles - {0} - {1} " -f $Computer, $now.ToString('yyyy-MM-dd HH:mm')).PadRight(78, '=') -ForegroundColor Cyan
    $free = if ($diskBefore) { " Free on ${Drive} $(Format-Size $diskBefore.Free) of $(Format-Size $diskBefore.Size)." } else { '' }
    $scope = if ($User) { "Only: $($User -join ', ')." } else { "Stale = not used for $OlderThanDays days." }
    Write-Host ("  {0}: {1} profile(s). {2}{3}" -f $ProfilesDir, @($cimProfiles | Where-Object { -not $_.Special }).Count, $scope, $free) -ForegroundColor Gray
    if ($User) {
        Write-Host ''
        if ($named.Count -or $kept.Count) {
            Write-Host ("  NAMED ({0})" -f ($named.Count + $kept.Count)) -ForegroundColor Cyan
            foreach ($p in $Offer) { Write-Profile $p -Numbered }
            foreach ($p in $kept) { Write-Profile $p }
        }
        else { Write-Host "  No profile matches $($User -join ', ')." -ForegroundColor Yellow }
    }
    else {
        Write-Host ''
        $staleSize = & $sumBytes $stale
        Write-Host ("  STALE ({0}{1})" -f $stale.Count, $(if ($staleSize) { ", $(Format-Size $staleSize)" } else { '' })) -ForegroundColor $(if ($stale.Count) { 'Yellow' } else { 'Green' })
        if (-not $stale.Count) { Write-Host '     none' -ForegroundColor DarkGray }
        foreach ($p in @($Offer | Where-Object Status -eq 'Stale')) { Write-Profile $p -Numbered }
        if ($unknown.Count) {
            Write-Host ("  NO LAST-USED DATE ({0})" -f $unknown.Count) -ForegroundColor Yellow
            foreach ($p in @($Offer | Where-Object Status -eq 'Unknown')) { Write-Profile $p -Numbered }
        }
        Write-Host ("  RECENT ({0})" -f $recent.Count) -ForegroundColor Green
        foreach ($p in $recent) { Write-Profile $p }
        Write-Host ("  KEPT ({0})" -f $kept.Count) -ForegroundColor DarkGray
        foreach ($p in $kept) { Write-Profile $p }
    }
    if ($Notes.Count) {
        Write-Host '  NOTES' -ForegroundColor Cyan
        foreach ($n in $Notes) {
            Write-Host ('   [{0}] {1}' -f $n.Status, $n.Detail) -ForegroundColor $(if ($n.Status -eq 'WARN') { 'Yellow' } else { 'DarkGray' })
            if ($n.Fix) { Write-Host ('          -> {0}' -f $n.Fix) -ForegroundColor DarkGray }
        }
    }
}

# ================================================================================================
#  Delete
# ================================================================================================
function ConvertFrom-Selection {
    # "1,3 5-7" -> numbers. Anything it doesn't understand, or out of range, means nothing is deleted.
    param([string] $Text, [int] $Max)
    $set = [System.Collections.Generic.SortedSet[int]]::new()
    $bad = @()
    foreach ($part in ($Text -split '[,\s]+')) {
        if (-not $part) { continue }
        if ($part -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b -or $a -lt 1 -or $b -gt $Max) { $bad += $part; continue }
            foreach ($n in $a..$b) { [void]$set.Add($n) }
        }
        elseif ($part -match '^\d+$' -and [int]$part -ge 1 -and [int]$part -le $Max) { [void]$set.Add([int]$part) }
        else { $bad += $part }
    }
    [pscustomobject]@{ Numbers = @($set); Bad = $bad }
}

$picked = @()
$failed = 0
$exit = 0
if ($Remove) {
    if (-not $Quiet) { Write-Host ''; Write-Host '  DELETE' -ForegroundColor Cyan }
    $auto = @($Offer | Where-Object { $User -or -not $_.AskOnly.Count })
    if (-not $IsAdmin) { Add-Action 'Delete profiles' 'SKIPPED' 'Not running as admin: nothing deleted.'; $exit = 1 }
    elseif (-not $Offer.Count) { Write-Line '   Nothing to delete.' 'DarkGray' }
    elseif ($Yes) { $picked = $auto }
    else {
        $hint = if ($auto.Count -eq $Offer.Count) { 'all = every one listed' } else { "all = the $($auto.Count) without an ""only if picked by number"" note" }
        $ans = (Read-Answer ("  Delete which? Numbers (e.g. 1,3 or 2-4), {0}, Enter = none" -f $hint)).Trim()
        if (-not $ans) { Write-Line '   None picked: nothing deleted.' 'DarkGray' }
        elseif ($ans -match '^(all|a)$') { $picked = $auto }
        else {
            $sel = ConvertFrom-Selection $ans $Offer.Count
            if ($sel.Bad.Count) { Write-Line ("   Didn't understand {0} (numbers 1-{1}): nothing deleted." -f ($sel.Bad -join ', '), $Offer.Count) 'Yellow' }
            else { $picked = @($Offer | Where-Object { $_.Number -in $sel.Numbers }) }
        }
        if ($picked.Count) {
            $total = & $sumBytes $picked
            $names = ($picked | ForEach-Object Display) -join ', '
            $ok = Read-Answer ("  Delete {0} profile(s){1}: {2}? This can't be undone. [y/N]" -f $picked.Count, $(if ($total) { ", $(Format-Size $total)" } else { '' }), $names)
            if ($ok.Trim() -notmatch '^(y|yes)$') { Write-Line '   Not confirmed: nothing deleted.' 'DarkGray'; $picked = @() }
        }
        elseif ($ans -and $ans -match '^(all|a)$') { Write-Line '   Nothing in "all": every one listed needs picking by number.' 'DarkGray' }
    }
    if ($Yes -and $IsAdmin) {
        foreach ($p in @($Offer | Where-Object { $_ -notin $auto })) {
            Add-Action "Delete $($p.Display)" 'SKIPPED' ("Not with -Yes: {0}. Name it with -User, or run without -Yes and pick it." -f ($p.AskOnly -join '; '))
        }
    }

    foreach ($p in $picked) {
        if ($p.Sid -notmatch '^S-1-[0-9-]+$') { Add-Action "Delete $($p.Display)" 'FAILED' "Unexpected SID '$($p.Sid)'."; $failed++; continue }
        $filter = "SID='$($p.Sid)'"
        $live = $null
        try { $live = Get-CimInstance -ClassName Win32_UserProfile -Filter $filter -ErrorAction Stop | Select-Object -First 1 } catch { $live = $null }
        if (-not $live) { Add-Action "Delete $($p.Display)" 'SKIPPED' 'Already gone.'; continue }
        if ($live.Loaded) { Add-Action "Delete $($p.Display)" 'SKIPPED' 'Signed in now (or still loaded): not deleted. Sign them out or restart, then run this again.'; continue }
        $err = $null
        try { Remove-CimInstance -InputObject $live -ErrorAction Stop } catch { $err = $_.Exception.Message }
        $still = $null
        try { $still = Get-CimInstance -ClassName Win32_UserProfile -Filter $filter -ErrorAction Stop | Select-Object -First 1 } catch { $still = $null }
        $left = [bool]($p.Path -and [IO.Directory]::Exists($p.Path))
        $sizeText = if ($null -ne $p.SizeBytes) { ", $(Format-Size $p.SizeBytes)" } else { '' }
        if (-not $err -and -not $still -and -not $left) { Add-Action "Deleted $($p.Display)" 'OK' "$($p.Path)$sizeText" }
        elseif (-not $still -and $left) { Add-Action "Deleted $($p.Display), but part of the folder is left" 'FAILED' "Files in use. Restart, then delete $($p.Path) by hand."; $failed++ }
        else { Add-Action "Couldn't delete $($p.Display)" 'FAILED' $(if ($err) { $err } else { 'The profile is still there.' }); $failed++ }
    }
    if ($failed) { $exit = 1 }
}
if ($User -and -not ($named.Count + $kept.Count)) { $exit = 1 }

$deleted = @($Actions | Where-Object { $_.Result -eq 'OK' -and $_.Step -like 'Deleted *' }).Count
$diskAfter = if ($deleted) { Get-DiskFree $Drive } else { $null }
$freed = if ($diskBefore -and $diskAfter -and $diskAfter.Free -gt $diskBefore.Free) { $diskAfter.Free - $diskBefore.Free }
         elseif ($deleted) { $t = [int64]0; foreach ($p in $picked) { if ($null -ne $p.SizeBytes -and -not [IO.Directory]::Exists($p.Path)) { $t += $p.SizeBytes } }; if ($t) { $t } else { $null } }
         else { $null }
if ($deleted -and -not $Quiet) {
    Write-Host ''
    Write-Host '  AFTER' -ForegroundColor Cyan
    if ($diskBefore -and $diskAfter) { Write-Host ("   Free on {0} {1} (was {2})" -f $Drive, (Format-Size $diskAfter.Free), (Format-Size $diskBefore.Free)) -ForegroundColor Green }
    elseif ($freed) { Write-Host ("   About {0} freed" -f (Format-Size $freed)) -ForegroundColor Green }
}

# ================================================================================================
#  Summary
# ================================================================================================
$all = @($cimProfiles | Where-Object { -not $_.Special }).Count
$summary = if ($Remove -and -not $IsAdmin) { "$Computer profiles - not admin: nothing deleted ($($stale.Count) stale)" }
elseif ($Remove) {
    $what = if ($User) { 'named' } else { 'offered' }
    $s = "$Computer profiles - deleted $deleted of $($Offer.Count) $what"
    if ($freed) { $s += ", $(Format-Size $freed) back" }
    if ($failed) { $s += "; $failed FAILED" }
    $s
}
elseif ($User) {
    if ($named.Count + $kept.Count) { "$Computer profiles - $($named.Count) named, $($kept.Count) kept; nothing deleted" } else { "$Computer profiles - no profile matches $($User -join ', ')" }
}
elseif ($stale.Count) {
    $ss = & $sumBytes $stale
    "$Computer profiles - $($stale.Count) stale (not used for $OlderThanDays+ days{0}) of $all; nothing deleted" -f $(if ($ss) { ", $(Format-Size $ss)" } else { '' })
}
else { "$Computer profiles - none stale (not used for $OlderThanDays+ days) of $all" }
if ($unknown.Count -and -not $User -and -not $Remove) { $summary += "; $($unknown.Count) with no last-used date" }

if ($Quiet) { Write-Output $summary }
else {
    if (-not $Remove -and $Offer.Count -and $IsAdmin) { Write-Host ''; Write-Host '  Nothing deleted. To delete, run it with -Remove (you pick which, then confirm).' -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host "  Summary: $summary" -ForegroundColor Cyan
}

if ($PassThru) {
    [pscustomobject]@{
        Summary = $summary; OlderThanDays = $OlderThanDays; ProfilesFolder = $ProfilesDir
        Profiles = @($Profiles); Offered = @($Offer); Notes = @($Notes); Actions = @($Actions)
        Deleted = $deleted; FreedBytes = $freed
    }
}
exit $exit
