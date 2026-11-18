<#
.SYNOPSIS
    Removes what Endpoint Toolkit has saved on this PC: its reports and logs, the toolkit itself, and (only
    when asked) driver backups and Windows Update reset's old folders.

.DESCRIPTION
    Lists everything the toolkit has left on this PC with its size, then deletes what you ticked after
    one "Delete these? [y/N]". With nothing ticked it only lists.

      Reports and logs    C:\Triage reports, build reports, tool logs in ProgramData, device inventory,
                          disk usage and Entra / Intune log bundles, M365 reports in Documents
      The toolkit itself  the downloaded copies in C:\ProgramData\EndpointToolkit, the installed module,
                          saved licence names, Event triage mutes, downloads and working files a tool
                          left behind. Run from the toolkit window or menu, that closes afterwards.
      Driver backups      C:\DriverExport (only with -DriverBackups: they're the restore point)
      Update backups      SoftwareDistribution.old-* and catroot2.old-* from Windows Update reset (only
                          with -UpdateBackups: they're its undo)

    It only deletes what the toolkit itself creates, matched by the names the tools use
    (Tools\Shared\ToolkitData.psd1). Anything else in those folders is someone else's: it's listed and left
    alone, and a folder is only removed once it's empty. Links (junctions, symlinks) are removed as links,
    never followed. Reports saved somewhere else with -ReportFolder / -OutputFolder aren't found.

    Documents, AppData and Temp are the account running it: with a UAC prompt for a different admin
    account, that's the admin's, not the signed-in user's.

.PARAMETER Reports
    Delete the reports and logs the tools saved.

.PARAMETER Toolkit
    Remove the toolkit itself. Run from the toolkit window or console menu, that closes when this finishes.

.PARAMETER DriverBackups
    Also delete Driver export's backups in C:\DriverExport.

.PARAMETER UpdateBackups
    Also delete the SoftwareDistribution.old-* and catroot2.old-* folders Windows Update reset left.

.PARAMETER Yes
    Delete without asking, for the RMM. Without it, a run that can't ask (a remote shell) deletes nothing.

.PARAMETER Quiet
    One summary line.

.PARAMETER PassThru
    Return what was found (and deleted) as objects.

.EXAMPLE
    .\Remove-ToolkitData.ps1
    Lists everything the toolkit has saved on this PC. Deletes nothing.

.EXAMPLE
    .\Remove-ToolkitData.ps1 -Reports -Toolkit
    Lists it, asks, then deletes the reports, logs and the toolkit itself.

.EXAMPLE
    .\Remove-ToolkitData.ps1 -Reports -Yes -Quiet
    From the RMM: delete the reports and logs without asking, one line of output.

.NOTES
    Exit codes: 0 done (or listed only, or nothing to delete), 1 something couldn't be deleted or it needs
    admin, 2 you said no (nothing deleted).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Quiet and PassThru are read in Write-Line and Complete-Run.')]
[CmdletBinding()]
param(
    [switch] $Reports,
    [switch] $Toolkit,
    [switch] $DriverBackups,
    [switch] $UpdateBackups,
    [switch] $Yes,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

# Read everything needed before anything is deleted: this script may be inside the toolkit copy it removes.
$shared = Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared'
. (Join-Path $shared 'Helpers.ps1')
$data = Import-PowerShellDataFile -LiteralPath (Join-Path $shared 'ToolkitData.psd1')

# Step out of the toolkit's folder: Windows won't delete a folder a process is "in", and the toolkit
# starts tools with their working folder inside its own copy.
$safeDir = if ($env:SystemRoot -and (Test-Path -LiteralPath $env:SystemRoot)) { $env:SystemRoot } else { [IO.Path]::GetTempPath() }
Set-Location -LiteralPath $safeDir
[Environment]::CurrentDirectory = $safeDir

$CategoryNames = [ordered]@{
    Reports       = 'Reports and logs'
    Toolkit       = 'The toolkit itself'
    DriverBackups = 'Driver backups'
    UpdateBackups = 'Windows Update reset backups'
}
$Ticked = @{ Reports = [bool]$Reports; Toolkit = [bool]$Toolkit; DriverBackups = [bool]$DriverBackups; UpdateBackups = [bool]$UpdateBackups }
$MachineRoots = 'SystemDrive', 'ProgramData', 'Windows'

function Write-Line {
    param([string] $Text = '', [string] $Colour = 'Gray')
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Colour }
}

function Format-Size {
    param([double] $Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    '{0:N0} bytes' -f $Bytes
}

function Join-RelativePath {
    # Joins 'Logs\Build_x' style paths one part at a time, so they work whatever the separator.
    param([string] $Base, [string] $Relative)
    $p = $Base
    foreach ($part in ($Relative -split '[\\/]' | Where-Object { $_ })) { $p = Join-Path $p $part }
    $p
}

function Get-RootFolder {
    # The folder(s) a root name stands for on this PC, for the account running this. Nothing when unknown.
    param([string] $Root)
    $sep = [IO.Path]::DirectorySeparatorChar
    $paths = switch ($Root) {
        'SystemDrive'  { if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\', '/') + $sep } }
        'ProgramData'  { $env:ProgramData }
        'Windows'      { $env:SystemRoot }
        'Documents'    { [Environment]::GetFolderPath('MyDocuments'); if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Documents' } }
        'AppData'      { $env:APPDATA }
        'LocalAppData' { $env:LOCALAPPDATA }
        'Temp'         { [IO.Path]::GetTempPath() }
    }
    $seen = @{}
    foreach ($p in @($paths)) {
        if (-not $p) { continue }
        $full = [IO.Path]::GetFullPath($p).TrimEnd('\', '/')
        if (-not $full) { $full = $p }
        if (-not $seen.ContainsKey($full)) { $seen[$full] = $true; $full }
    }
}

function Test-IsLink {
    param([IO.FileSystemInfo] $Item)
    ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

function Measure-Entry {
    # Size, file count and newest change of a file or folder. Links count as nothing and are never followed.
    param([IO.FileSystemInfo] $Item)
    $r = [pscustomobject]@{ Bytes = [int64]0; Files = 0; Newest = $Item.LastWriteTime }
    if (Test-IsLink $Item) { return $r }
    if ($Item -is [IO.FileInfo]) { $r.Bytes = $Item.Length; $r.Files = 1; return $r }
    $stack = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $stack.Push($Item)
    while ($stack.Count) {
        $dir = $stack.Pop()
        try { $children = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($c in $children) {
            if ($c.LastWriteTime -gt $r.Newest) { $r.Newest = $c.LastWriteTime }
            if (Test-IsLink $c) { continue }
            if ($c -is [IO.DirectoryInfo]) { $stack.Push($c) }
            else { $r.Bytes += $c.Length; $r.Files++ }
        }
    }
    $r
}

function Remove-Entry {
    # Deletes a file or folder. A link is removed as a link (its target is untouched); read-only files go too.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only called after the list and the [y/N] (or -Yes).')]
    param([IO.FileSystemInfo] $Item)
    $Item.Refresh()
    if (-not $Item.Exists) { return }
    if (Test-IsLink $Item) {
        if ($Item -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($Item.FullName) } else { [IO.File]::Delete($Item.FullName) }
        return
    }
    if ($Item -is [IO.FileInfo]) {
        if ($Item.IsReadOnly) { $Item.IsReadOnly = $false }
        [IO.File]::Delete($Item.FullName)
        return
    }
    foreach ($c in $Item.GetFileSystemInfos()) { Remove-Entry -Item $c }
    if (($Item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { $Item.Attributes = $Item.Attributes -bxor [IO.FileAttributes]::ReadOnly }
    [IO.Directory]::Delete($Item.FullName)
}

function Find-ToolkitData {
    # Everything the toolkit has saved here, one object per file or folder, plus what else sits in the
    # folders it would like to remove.
    param($Locations)
    $found = [Collections.Generic.List[object]]::new()
    $seen  = @{}
    foreach ($loc in $Locations) {
        foreach ($rootPath in @(Get-RootFolder $loc.Root)) {
            $base = if ($loc.Folder) { Join-RelativePath $rootPath $loc.Folder } else { $rootPath }
            if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
            $matched = @()
            if ($loc.Whole) {
                if (-not $loc.Folder) { continue }   # never a whole root
                $matched = @(Get-Item -LiteralPath $base -Force)
            }
            else {
                foreach ($pattern in @($loc.Names)) {
                    $parts = @($pattern -split '[\\/]' | Where-Object { $_ })
                    $dir = $base
                    if ($parts.Count -gt 1) { $dir = Join-RelativePath $base ($parts[0..($parts.Count - 2)] -join '\') }
                    $leaf = $parts[-1]
                    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
                    $matched += @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -like $leaf })
                }
            }
            foreach ($m in $matched) {
                $key = $m.FullName.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $size = Measure-Entry -Item $m
                $found.Add([pscustomobject]@{
                    Category = $loc.Category
                    Path     = $m.FullName
                    Item     = $m
                    IsFolder = $m -is [IO.DirectoryInfo]
                    IsLink   = Test-IsLink $m
                    Bytes    = $size.Bytes
                    Files    = $size.Files
                    Newest   = $size.Newest
                    Machine  = $MachineRoots -contains $loc.Root
                    Tools    = $loc.Tools
                    Root     = $rootPath
                    Empty    = @($loc.Empty)
                    Deleted  = $false
                    Error    = $null
                })
            }
        }
    }
    [pscustomobject]@{ Items = $found }
}

function Get-OtherEntry {
    # What's in a folder the toolkit would remove, that isn't the toolkit's and isn't one of its own subfolders.
    param([string] $Folder, $Items, [string[]] $OwnSubfolders)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return @() }
    $mine = @{}
    foreach ($i in $Items) { $mine[$i.Path.ToLowerInvariant()] = $true }
    foreach ($s in $OwnSubfolders) { $mine[$s.ToLowerInvariant()] = $true }
    @(Get-ChildItem -LiteralPath $Folder -Force | Where-Object { -not $mine.ContainsKey($_.FullName.ToLowerInvariant()) })
}

# ------------------------------------------------------------------------------------------------
#  Find
# ------------------------------------------------------------------------------------------------
$isAdmin = $false
try { $isAdmin = [bool](Test-RunningAsAdmin) } catch { $isAdmin = $false }
$whoAmI = [Environment]::UserName
try { $whoAmI = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $null = $_ }

$result = Find-ToolkitData -Locations $data.Locations
$items  = @($result.Items)

# Folders the toolkit would remove once empty, and what else is in them.
$emptyFolders = [ordered]@{}
foreach ($i in $items) {
    foreach ($e in $i.Empty) {
        if (-not $e) { continue }
        $full = Join-RelativePath $i.Root $e
        $emptyFolders[$full.ToLowerInvariant()] = $full
    }
}
$allEmpty = @($emptyFolders.Values)
$otherNotes = [Collections.Generic.List[string]]::new()
foreach ($f in $allEmpty) {
    $own = @($allEmpty | Where-Object { $_ -ne $f -and $_.StartsWith($f, [StringComparison]::OrdinalIgnoreCase) })
    $other = @(Get-OtherEntry -Folder $f -Items $items -OwnSubfolders $own)
    if ($other.Count) {
        $names = ($other | Select-Object -First 3 | ForEach-Object Name) -join ', '
        if ($other.Count -gt 3) { $names += ', ...' }
        $otherNotes.Add(("{0}: {1} other item(s), not the toolkit's, left alone ({2})" -f $f, $other.Count, $names))
    }
}

$selected = @($items | Where-Object { $Ticked[$_.Category] })
$anyTicked = @($Ticked.Values | Where-Object { $_ }).Count -gt 0

# ------------------------------------------------------------------------------------------------
#  List
# ------------------------------------------------------------------------------------------------
Write-Line ''
Write-Line ("  TOOLKIT CLEANUP   {0}   run as {1}{2}" -f $env:COMPUTERNAME, $whoAmI, $(if ($isAdmin) { ' (admin)' } else { '' })) 'Cyan'
Write-Line ''
foreach ($cat in $CategoryNames.Keys) {
    $these = @($items | Where-Object Category -eq $cat)
    $total = ($these | Measure-Object -Property Bytes -Sum).Sum
    $state = if ($Ticked[$cat]) { 'DELETE' } else { 'keep' }
    $head = '  {0,-30} {1,4} item(s) {2,10}   {3}' -f $CategoryNames[$cat], $these.Count, $(if ($these.Count) { Format-Size $total } else { '' }), $state
    Write-Line $head $(if ($Ticked[$cat] -and $these.Count) { 'Yellow' } elseif ($these.Count) { 'White' } else { 'DarkGray' })
    $shown = 0
    foreach ($i in ($these | Sort-Object Path)) {
        if ($shown -ge 15) { Write-Line ('      ... and {0} more' -f ($these.Count - $shown)) 'DarkGray'; break }
        $kind = if ($i.IsLink) { 'link' } elseif ($i.IsFolder) { '{0} file(s)' -f $i.Files } else { '' }
        Write-Line ('      {0}   {1} {2}  {3:yyyy-MM-dd}' -f $i.Path, (Format-Size $i.Bytes), $(if ($kind) { "($kind)" } else { '' }), $i.Newest) 'Gray'
        $shown++
    }
}
foreach ($n in $otherNotes) { Write-Line "  $n" 'DarkGray' }
Write-Line ''

$selBytes = ($selected | Measure-Object -Property Bytes -Sum).Sum
if (-not $selBytes) { $selBytes = 0 }

function Complete-Run {
    param([int] $Code, [string] $Summary)
    if ($Quiet) { Write-Output ("Toolkit cleanup: {0}" -f $Summary) }
    if ($PassThru) {
        $items | Select-Object Category, Path, IsFolder, IsLink, Bytes, Files, Newest, Tools, Deleted, Error
    }
    exit $Code
}

if (-not $anyTicked) {
    Write-Line '  Nothing ticked, so nothing deleted. Tick what to remove (or use -Reports / -Toolkit) and run it again.' 'Green'
    Complete-Run 0 ('found {0} item(s), {1}; nothing ticked, nothing deleted' -f $items.Count, (Format-Size (($items | Measure-Object Bytes -Sum).Sum + 0)))
}
if (-not $selected.Count) {
    Write-Line '  Nothing of what you ticked is on this PC. Nothing to delete.' 'Green'
    Complete-Run 0 'nothing to delete'
}

$needAdmin = @($selected | Where-Object Machine)
if ($needAdmin.Count -and -not $isAdmin) {
    Write-Line ("  {0} of these are in C:\ or ProgramData and need admin to delete. Run it as admin. Nothing deleted." -f $needAdmin.Count) 'Red'
    Complete-Run 1 ('needs admin for {0} item(s); nothing deleted' -f $needAdmin.Count)
}

# ------------------------------------------------------------------------------------------------
#  Confirm
# ------------------------------------------------------------------------------------------------
$tickedNames = ($CategoryNames.Keys | Where-Object { $Ticked[$_] -and @($selected | Where-Object Category -eq $_).Count } | ForEach-Object { $CategoryNames[$_] }) -join ' + '
if ($Toolkit -and @($selected | Where-Object Category -eq 'Toolkit').Count) {
    Write-Line '  The toolkit itself is on the list: if this was started from the toolkit window or menu, it closes' 'Yellow'
    Write-Line '  when this finishes. To use it again, run the one-liner again.' 'Yellow'
}
if (@($selected | Where-Object Category -eq 'DriverBackups').Count) {
    Write-Line '  Driver backups are on the list: make sure they aren''t needed for a rebuild first.' 'Yellow'
}
if (@($selected | Where-Object Category -eq 'UpdateBackups').Count) {
    Write-Line '  Windows Update reset backups are on the list: after this, that reset can''t be undone.' 'Yellow'
}

if (-not $Yes) {
    # [string] matters: with nobody to answer (no console, input closed) Read-Host returns nothing at all,
    # not '', and "nothing -notmatch 'y'" is empty (false), which would read as a yes.
    $answer = ''
    try { $answer = [string](Read-Host ("  Delete {0} item(s), {1} ({2})? [y/N]" -f $selected.Count, (Format-Size $selBytes), $tickedNames)) } catch { $answer = '' }
    if (-not ($answer -match '^\s*y')) {
        Write-Line '  Nothing deleted.' 'Green'
        Complete-Run 2 'cancelled, nothing deleted'
    }
}

# ------------------------------------------------------------------------------------------------
#  Delete: reports first, the toolkit last
# ------------------------------------------------------------------------------------------------
$order = @{ Reports = 1; DriverBackups = 2; UpdateBackups = 3; Toolkit = 4 }
$freed = [int64]0
foreach ($i in ($selected | Sort-Object { $order[$_.Category] }, Path)) {
    try {
        Remove-Entry -Item $i.Item
        $i.Deleted = $true
        $freed += $i.Bytes
    }
    catch {
        $i.Error = $_.Exception.Message
        if ($_.Exception.InnerException) { $i.Error = $_.Exception.InnerException.Message }
    }
}

# Then the folders they were in, once empty (deepest first).
$tickedEmpty = [ordered]@{}
foreach ($i in $selected) {
    foreach ($e in $i.Empty) {
        if (-not $e) { continue }
        $full = Join-RelativePath $i.Root $e
        $tickedEmpty[$full.ToLowerInvariant()] = $full
    }
}
$removedFolders = 0
foreach ($f in (@($tickedEmpty.Values) | Sort-Object { $_.Length } -Descending)) {
    try {
        $d = Get-Item -LiteralPath $f -Force -ErrorAction Stop
        if ($d -is [IO.DirectoryInfo] -and -not (Test-IsLink $d) -and -not @($d.GetFileSystemInfos()).Count) {
            [IO.Directory]::Delete($d.FullName)
            $removedFolders++
        }
    }
    catch { $null = $_ }
}

$failed = @($selected | Where-Object { -not $_.Deleted })
$done   = @($selected | Where-Object Deleted)
Write-Line ''
Write-Line ("  Deleted {0} item(s), {1} freed{2}." -f $done.Count, (Format-Size $freed), $(if ($removedFolders) { ", and $removedFolders empty folder(s)" } else { '' })) 'Green'
if ($failed.Count) {
    Write-Line ("  {0} couldn't be deleted:" -f $failed.Count) 'Red'
    foreach ($f in $failed) { Write-Line ("    {0}: {1}" -f $f.Path, $f.Error) 'Red' }
    Write-Line '  Usually a file in use: close what has it open (or restart) and run this again.' 'Yellow'
    Complete-Run 1 ('deleted {0} item(s), {1}; {2} failed' -f $done.Count, (Format-Size $freed), $failed.Count)
}
Complete-Run 0 ('deleted {0} item(s), {1}' -f $done.Count, (Format-Size $freed))
