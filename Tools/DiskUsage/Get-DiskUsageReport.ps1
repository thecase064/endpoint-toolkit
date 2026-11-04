<#
.SYNOPSIS
    Disk space analyser for Windows endpoints. A lightweight stand-in for TreeSize
    that needs no install, no licence and runs fine over a remote PowerShell session.

.DESCRIPTION
    Walks a path, rolls folder sizes up the tree, and reports:
      * capacity summary for the volume
      * every top-level folder, sorted by total size
      * the largest folders by OWN content (excludes subfolders, so parents and
        children don't crowd each other out of the list)
      * the largest individual files
      * known cleanup targets with sizes and a safe/caution flag

    Optionally writes a self-contained HTML report (no internet needed to view it)
    that you can attach straight to a ticket.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Path
    Root to scan. Defaults to the system drive.

.PARAMETER TopFolders
    How many folders to list in the "largest folders" table. Default 25.

.PARAMETER TopFiles
    How many files to list in the "largest files" table. Default 30.

.PARAMETER MinFileSizeMB
    Files below this are never considered for the largest-files table. Keeps memory
    flat on volumes with millions of files. Default 50.

.PARAMETER ReportPath
    Where to write the HTML report. Defaults to C:\DiskUsageReports\DiskUsage_<COMPUTER>_<date>.html
    (the folder is created automatically if it doesn't exist). Use -NoHtml to skip it entirely.

.PARAMETER NoHtml
    Console output only.

.PARAMETER Quiet
    Suppress the progress bar and the console tables. Useful in Intune remediations
    where you only want the exit summary.

.PARAMETER PassThru
    Emit a result object to the pipeline for further processing.

.EXAMPLE
    .\Get-DiskUsageReport.ps1

.EXAMPLE
    .\Get-DiskUsageReport.ps1 -Path 'D:\Shares' -TopFolders 50 -ReportPath C:\Temp\d.html

.EXAMPLE
    Invoke-Command -ComputerName PC-1234 -FilePath .\Get-DiskUsageReport.ps1

.NOTES
    Known differences from TreeSize:
      * Reports LOGICAL size (.Length), not size-on-disk. Compressed, sparse or
        deduplicated volumes will read high compared to Explorer.
      * Hard-linked files are counted once per link, so WinSxS reads larger than it
        really is. Treat WinSxS numbers as indicative only.
      * Junctions and symlinks are skipped, not followed. This is deliberate --
        following them double-counts and can loop.
      * Paths over ~260 chars are skipped on PS 5.1 unless LongPathsEnabled is set.
        The count of skipped paths is reported.

    Run elevated to see other users' profiles and protected system folders.
#>

# Shared data model (kept in sync with Show-DiskUsageGui.ps1):
#   DiskNode : { Path/Name, ParentRef, OwnBytes, TotalBytes, Children[], Files[{Name,Bytes,Modified}] }
#   Walk     : iterative stack-based DFS over DirectoryInfo.EnumerateFiles()/EnumerateDirectories(),
#              skipping ReparsePoint directories, one try/catch per directory for
#              UnauthorizedAccessException / PathTooLongException / DirectoryNotFoundException.
#   Rollup   : OwnBytes -> TotalBytes by processing paths longest-first, adding each child's
#              total into its immediate parent.
#   This script's per-folder Files list is filtered by -MinFileSizeMB (a report attached to a
#   ticket shouldn't balloon to hundreds of MB). Show-DiskUsageGui.ps1 deliberately diverges:
#   its pre-scan keeps folder sizes only (no file retention) and fetches a folder's unfiltered
#   file list lazily, one folder at a time, when the user selects it in the tree.

[CmdletBinding()]
param(
    [string] $Path          = $env:SystemDrive,
    [int]    $TopFolders    = 25,
    [int]    $TopFiles      = 30,
    [int]    $MinFileSizeMB = 50,
    [string] $ReportPath,
    [switch] $NoHtml,
    [switch] $Quiet,
    [switch] $PassThru
)

#--------------------------------------------------------------------------------
# Setup
#--------------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$Start = Get-Date

if ($Path -match '^[A-Za-z]:$') { $Path = "$Path\" }
if (-not [IO.Directory]::Exists($Path)) { throw "Path not found: $Path" }
$Path = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin -and -not $Quiet) {
    Write-Warning 'Not elevated - other user profiles and protected folders will be skipped.'
}

if (-not $ReportPath) {
    $stamp        = $Start.ToString('yyyyMMdd-HHmm')
    $ReportFolder = 'C:\DiskUsageReports'
    if (-not [IO.Directory]::Exists($ReportFolder)) {
        [void] (New-Item -ItemType Directory -Path $ReportFolder -Force)
    }
    $ReportPath = Join-Path $ReportFolder "DiskUsage_${env:COMPUTERNAME}_$stamp.html"
}

function Format-Size {
    param([double] $Bytes)
    if     ($Bytes -ge 1TB) { '{0:N2} TB' -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0} KB' -f ($Bytes / 1KB) }
    else                    { '{0:N0} B'  -f $Bytes }
}

function Get-HtmlSafe {
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function ConvertTo-JsonString {
    # Minimal JSON string encoder. '<' is escaped to its \u unicode form so a filename
    # containing "</script" can never prematurely terminate the <script> block it is embedded in.
    param([string] $Text)
    if ($null -eq $Text) { return '""' }
    $Sb = New-Object System.Text.StringBuilder
    [void] $Sb.Append('"')
    foreach ($Ch in $Text.ToCharArray()) {
        switch ($Ch) {
            '"'  { [void] $Sb.Append('\"'); continue }
            '\'  { [void] $Sb.Append('\\'); continue }
            '<'  { [void] $Sb.Append([string]::Concat([char]92,'u003c')); continue }
            "`n" { [void] $Sb.Append('\n'); continue }
            "`r" { [void] $Sb.Append('\r'); continue }
            "`t" { [void] $Sb.Append('\t'); continue }
            default {
                if ([int] $Ch -lt 0x20) { [void] $Sb.Append(('\u{0:x4}' -f [int] $Ch)) }
                else                    { [void] $Sb.Append($Ch) }
            }
        }
    }
    [void] $Sb.Append('"')
    $Sb.ToString()
}

#--------------------------------------------------------------------------------
# Walk
#
# Iterative, stack-based, one try/catch per directory. Slower than a raw
# EnumerationOptions recursive walk but it survives access-denied on individual
# folders instead of aborting the whole enumeration -- which is what you need on a
# live endpoint. DirectoryInfo.EnumerateFiles() is used because it carries Length
# from the underlying find data, avoiding a separate stat call per file.
#--------------------------------------------------------------------------------

$Nodes     = @{}                                            # folder -> @{ Own; Files; SmallCount; SmallBytes }
$FloorSize = $MinFileSizeMB * 1MB

$Denied    = 0
$TooLong   = 0
$FileCount = 0
$DirCount  = 0

$RootKey = $Path.TrimEnd('\')
if ($RootKey -match '^[A-Za-z]:$') { $RootKey = "$RootKey\" }  # e.g. "C:" -> "C:\": a bare
# drive letter is resolved by .NET against the process's current directory on that drive,
# not the drive root -- and GetDirectoryName() of a drive-root child (e.g. "C:\Users")
# returns "C:\" (with the backslash), so the root key must match that shape too, or
# nothing scanned under a drive root will roll up into the total.

$Stack = New-Object System.Collections.Generic.Stack[string]
$Stack.Push($RootKey)

while ($Stack.Count -gt 0) {

    $Current = $Stack.Pop()
    $DirCount++

    if (-not $Quiet -and ($DirCount % 500) -eq 0) {
        Write-Progress -Activity 'Scanning' `
                       -Status  "$DirCount folders, $FileCount files" `
                       -CurrentOperation $Current
    }

    try {
        $Info  = New-Object System.IO.DirectoryInfo($Current)
        $Bytes = [long] 0
        $QualifyingFiles = New-Object System.Collections.ArrayList
        $SmallCount = 0
        $SmallBytes = [long] 0

        foreach ($File in $Info.EnumerateFiles()) {
            $Len    = $File.Length
            $Bytes += $Len
            $FileCount++

            if ($Len -ge $FloorSize) {
                [void] $QualifyingFiles.Add([PSCustomObject]@{
                    Name     = $File.Name
                    Bytes    = $Len
                    Modified = $File.LastWriteTime
                })
            }
            else {
                $SmallCount++
                $SmallBytes += $Len
            }
        }

        $Nodes[$Current] = @{
            Own        = $Bytes
            Files      = $QualifyingFiles
            SmallCount = $SmallCount
            SmallBytes = $SmallBytes
        }

        foreach ($Sub in $Info.EnumerateDirectories()) {
            if ($Sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $Stack.Push($Sub.FullName)
        }
    }
    catch [System.UnauthorizedAccessException] { $Denied++ }
    catch [System.IO.PathTooLongException]     { $TooLong++ }
    catch [System.IO.DirectoryNotFoundException] { }        # deleted mid-scan
    catch { Write-Verbose "Skipped $Current : $($_.Exception.Message)" }
}

if (-not $Quiet) { Write-Progress -Activity 'Scanning' -Completed }

#--------------------------------------------------------------------------------
# Roll up
#
# A child path is always longer than its parent path, so processing keys by
# descending string length guarantees every child total is final before it is
# added to its parent.
#--------------------------------------------------------------------------------

$Total = @{}
foreach ($Key in $Nodes.Keys) { $Total[$Key] = $Nodes[$Key].Own }

foreach ($Key in ($Nodes.Keys | Sort-Object -Property Length -Descending)) {
    $Parent = [IO.Path]::GetDirectoryName($Key)
    if ($Parent -and $Total.ContainsKey($Parent)) {
        $Total[$Parent] += $Total[$Key]
    }
}

$ScannedBytes = [double] $Total[$RootKey]
if ($ScannedBytes -le 0) { $ScannedBytes = 1 }

#--------------------------------------------------------------------------------
# Volume capacity
#--------------------------------------------------------------------------------

$Drive     = New-Object System.IO.DriveInfo($Path)
$DriveTot  = $Drive.TotalSize
$DriveFree = $Drive.AvailableFreeSpace
$DriveUsed = $DriveTot - $DriveFree
$UsedPct   = if ($DriveTot) { [math]::Round(($DriveUsed / $DriveTot) * 100, 1) } else { 0 }

#--------------------------------------------------------------------------------
# Tables
#--------------------------------------------------------------------------------

# Immediate children of the root, by rolled-up total
$TopLevel = foreach ($Key in $Total.Keys) {
    if ([IO.Path]::GetDirectoryName($Key) -eq $RootKey) {
        [PSCustomObject]@{ Path = $Key; Bytes = $Total[$Key] }
    }
}
$TopLevel = @($TopLevel | Sort-Object Bytes -Descending)

# Largest folders by own content -- no parent/child duplication
$Heaviest = @($Nodes.GetEnumerator() |
    Where-Object { $_.Value.Own -gt 0 } |
    Sort-Object { $_.Value.Own } -Descending |
    Select-Object -First $TopFolders |
    ForEach-Object { [PSCustomObject]@{ Path = $_.Key; Bytes = $_.Value.Own } })

# Largest individual files -- flattened once from each folder's per-node file list
$AllBigFiles = foreach ($NodeKey in $Nodes.Keys) {
    foreach ($F in $Nodes[$NodeKey].Files) {
        [PSCustomObject]@{
            Path     = Join-Path $NodeKey $F.Name
            Bytes    = $F.Bytes
            Modified = $F.Modified
        }
    }
}
$LargestFiles = @($AllBigFiles | Sort-Object Bytes -Descending | Select-Object -First $TopFiles)

#--------------------------------------------------------------------------------
# Known cleanup targets
#--------------------------------------------------------------------------------

$Targets = @(
    @{ P = "$env:SystemRoot\SoftwareDistribution\Download"; N = 'Windows Update cache';      S = 'Safe';    H = 'Stop wuauserv, delete contents, start wuauserv.' }
    @{ P = "$env:SystemRoot\Temp";                          N = 'System temp';               S = 'Safe';    H = 'Delete contents. In-use files will skip.' }
    @{ P = "$env:SystemRoot\Logs\CBS";                      N = 'Component servicing logs';  S = 'Safe';    H = 'Delete all but the newest CBS.log.' }
    @{ P = "$env:SystemRoot\ccmcache";                      N = 'SCCM package cache';        S = 'Safe';    H = 'Clear via Configuration Manager applet, not manually.' }
    @{ P = "$env:SystemDrive\Windows.old";                  N = 'Previous Windows install';  S = 'Safe';    H = 'Disk Cleanup > Previous Windows installations.' }
    @{ P = "$env:SystemDrive\`$Recycle.Bin";                N = 'Recycle bin (all users)';   S = 'Caution'; H = 'Confirm with the user before emptying.' }
    @{ P = "$env:ProgramData\Microsoft\Windows\WER";        N = 'Error reporting queue';     S = 'Safe';    H = 'Delete ReportQueue and ReportArchive contents.' }
    @{ P = "$env:SystemRoot\Installer";                     N = 'MSI installer cache';       S = 'Caution'; H = 'Never delete manually - breaks repair and uninstall. Use PatchCleaner.' }
    @{ P = "$env:SystemRoot\WinSxS";                        N = 'Component store';           S = 'Caution'; H = 'DISM /Online /Cleanup-Image /StartComponentCleanup. Size shown is inflated by hard links.' }
)

$CleanupRows = foreach ($T in $Targets) {
    $Resolved = $T.P
    $Bytes    = $null

    if ($Total.ContainsKey($Resolved)) {
        $Bytes = $Total[$Resolved]
    }
    elseif ([IO.Directory]::Exists($Resolved)) {
        # Outside the scanned root -- measure it directly
        try {
            $Bytes = ([IO.Directory]::EnumerateFiles($Resolved, '*', [IO.SearchOption]::AllDirectories) |
                      ForEach-Object { (New-Object System.IO.FileInfo($_)).Length } |
                      Measure-Object -Sum).Sum
        } catch { $Bytes = $null }
    }

    if ($null -ne $Bytes -and $Bytes -gt 0) {
        [PSCustomObject]@{
            Name   = $T.N
            Path   = $Resolved
            Bytes  = $Bytes
            Safety = $T.S
            Action = $T.H
        }
    }
}
$CleanupRows = @($CleanupRows | Sort-Object Bytes -Descending)
$Reclaimable = ($CleanupRows | Where-Object Safety -eq 'Safe' | Measure-Object Bytes -Sum).Sum

$Elapsed = (Get-Date) - $Start

#--------------------------------------------------------------------------------
# Console output
#--------------------------------------------------------------------------------

if (-not $Quiet) {

    Write-Host ''
    Write-Host "  $env:COMPUTERNAME - $Path" -ForegroundColor White
    Write-Host ("  {0} of {1} used ({2}%), {3} free" -f `
        (Format-Size $DriveUsed), (Format-Size $DriveTot), $UsedPct, (Format-Size $DriveFree)
    ) -ForegroundColor $(if ($UsedPct -ge 90) { 'Red' } elseif ($UsedPct -ge 80) { 'Yellow' } else { 'Green' })
    Write-Host ("  Scanned {0:N0} files in {1:N0} folders in {2:N0}s" -f `
        $FileCount, $DirCount, $Elapsed.TotalSeconds) -ForegroundColor DarkGray

    if ($Denied)  { Write-Host "  $Denied folders access denied"      -ForegroundColor DarkGray }
    if ($TooLong) { Write-Host "  $TooLong folders skipped (path too long)" -ForegroundColor DarkGray }

    Write-Host "`n  TOP-LEVEL BREAKDOWN" -ForegroundColor Cyan
    $TopLevel | Select-Object @{ n = 'Size'; e = { Format-Size $_.Bytes } },
                              @{ n = 'Share'; e = { '{0,5:N1}%' -f (($_.Bytes / $ScannedBytes) * 100) } },
                              Path |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    Write-Host "  HEAVIEST FOLDERS (own content, excludes subfolders)" -ForegroundColor Cyan
    $Heaviest | Select-Object @{ n = 'Size'; e = { Format-Size $_.Bytes } }, Path |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    Write-Host "  LARGEST FILES" -ForegroundColor Cyan
    $LargestFiles | Select-Object @{ n = 'Size'; e = { Format-Size $_.Bytes } },
                                  @{ n = 'Modified'; e = { $_.Modified.ToString('yyyy-MM-dd') } },
                                  Path |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    if ($CleanupRows) {
        Write-Host "  CLEANUP TARGETS" -ForegroundColor Cyan
        $CleanupRows | Select-Object @{ n = 'Size'; e = { Format-Size $_.Bytes } }, Safety, Name |
            Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        Write-Host ("  Reclaimable without risk: {0}`n" -f (Format-Size $Reclaimable)) -ForegroundColor Green
    }
}

#--------------------------------------------------------------------------------
# HTML report
#--------------------------------------------------------------------------------

if (-not $NoHtml) {

    $MaxTopLevel = 1.0; $MaxHeaviest = 1.0; $MaxFile = 1.0
    if ($TopLevel     -and $TopLevel[0].Bytes     -gt 0) { $MaxTopLevel = [double] $TopLevel[0].Bytes }
    if ($Heaviest     -and $Heaviest[0].Bytes     -gt 0) { $MaxHeaviest = [double] $Heaviest[0].Bytes }
    if ($LargestFiles -and $LargestFiles[0].Bytes -gt 0) { $MaxFile     = [double] $LargestFiles[0].Bytes }

    #----------------------------------------------------------------------------
    # Interactive folder tree -- a flat JSON array of nodes (id/parentId), embedded
    # in the page and walked client-side. Sorting all node keys by TotalBytes
    # descending once, up front, is enough to guarantee every parent's children
    # come out largest-first: a stable sort over the whole set preserves relative
    # order within any subset that shares the same parent.
    #----------------------------------------------------------------------------

    $TreeJson          = $null
    $TreeSkippedReason = $null
    $NodeCountLimit    = 250000

    if ($Nodes.Count -gt $NodeCountLimit) {
        $TreeSkippedReason = "Interactive tree skipped: {0:N0} folders exceeds the {1:N0}-folder safety limit for embedding in a single HTML file." -f $Nodes.Count, $NodeCountLimit
    }
    else {
        $SortedKeys = @($Nodes.Keys | Sort-Object { $Total[$_] } -Descending)
        $IdOf = @{}
        for ($i = 0; $i -lt $SortedKeys.Count; $i++) { $IdOf[$SortedKeys[$i]] = $i }

        $Jb = New-Object System.Text.StringBuilder
        [void] $Jb.Append('[')
        $FirstNode = $true

        foreach ($Key in $SortedKeys) {
            $Node     = $Nodes[$Key]
            $Parent   = [IO.Path]::GetDirectoryName($Key)
            $ParentId = if ($Parent -and $IdOf.ContainsKey($Parent)) { $IdOf[$Parent] } else { -1 }
            $Leaf     = if ($Key -eq $RootKey) { $Key } else { [IO.Path]::GetFileName($Key) }

            if (-not $FirstNode) { [void] $Jb.Append(',') }
            $FirstNode = $false

            [void] $Jb.Append('{"i":' + $IdOf[$Key] + ',"p":' + $ParentId + ',"n":' +
                (ConvertTo-JsonString $Leaf) + ',"o":' + $Node.Own + ',"t":' + $Total[$Key] +
                ',"sc":' + $Node.SmallCount + ',"sb":' + $Node.SmallBytes + ',"f":[')

            $FirstFile = $true
            foreach ($F in ($Node.Files | Sort-Object Bytes -Descending)) {
                if (-not $FirstFile) { [void] $Jb.Append(',') }
                $FirstFile = $false
                $Epoch = [DateTimeOffset]::new($F.Modified).ToUnixTimeSeconds()
                [void] $Jb.Append('[' + (ConvertTo-JsonString $F.Name) + ',' + $F.Bytes + ',' + $Epoch + ']')
            }

            [void] $Jb.Append(']}')
        }
        [void] $Jb.Append(']')
        $TreeJson = $Jb.ToString()
    }

    $Sb = New-Object System.Text.StringBuilder

    $CapClass = if ($UsedPct -ge 90) { 'crit' } elseif ($UsedPct -ge 80) { 'warn' } else { 'ok' }

    [void] $Sb.Append(@"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Disk usage - $(Get-HtmlSafe $env:COMPUTERNAME)</title>
<style>
:root{
  --ink:#12161c; --paper:#f7f8fa; --card:#ffffff; --rule:#dfe3e9;
  --muted:#6b7480; --signal:#2f6fd0; --signal-bg:#e4edfa;
  --warn:#a86a00; --warn-bg:#fbf0dc; --crit:#bc3428; --crit-bg:#fae4e1; --ok:#1f7a4d;
}
*{box-sizing:border-box}
body{margin:0;padding:32px 24px;background:var(--paper);color:var(--ink);
  font:14px/1.5 -apple-system,"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif}
.wrap{max-width:1180px;margin:0 auto}
.mono{font-family:"Cascadia Mono",Consolas,"Courier New",monospace}

header{border-bottom:2px solid var(--ink);padding-bottom:14px;margin-bottom:8px}
h1{margin:0;font-size:22px;font-weight:650;letter-spacing:-.2px}
h1 span{color:var(--muted);font-weight:400}
.meta{margin-top:6px;color:var(--muted);font-size:12.5px}

/* capacity strip */
.cap{margin:22px 0 30px}
.cap-nums{display:flex;align-items:baseline;gap:10px;margin-bottom:8px}
.cap-pct{font-size:38px;font-weight:650;letter-spacing:-1px;line-height:1}
.cap-pct.ok{color:var(--ok)} .cap-pct.warn{color:var(--warn)} .cap-pct.crit{color:var(--crit)}
.cap-lbl{color:var(--muted);font-size:13px}
.track{height:12px;background:#e7eaef;border-radius:2px;overflow:hidden}
.fill{height:100%;background:var(--signal)}
.fill.warn{background:var(--warn)} .fill.crit{background:var(--crit)}

h2{font-size:12px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;
  color:var(--muted);margin:34px 0 4px;padding-bottom:6px;border-bottom:1px solid var(--rule)}
h2 em{font-style:normal;font-weight:400;text-transform:none;letter-spacing:0;
  font-size:12.5px;margin-left:8px}

table{width:100%;border-collapse:collapse;margin-top:2px}
th{text-align:left;font-size:11px;font-weight:600;color:var(--muted);
  text-transform:uppercase;letter-spacing:.05em;padding:9px 10px;border-bottom:1px solid var(--rule)}
th.num,td.num{text-align:right;white-space:nowrap}
td{padding:0;border-bottom:1px solid #eef0f4;font-size:13px}
td.pad{padding:8px 10px}
tbody tr:hover{background:#f2f5f9}

/* signature: the row itself is the bar */
td.bar{position:relative;padding:8px 10px;overflow:hidden}
td.bar .fillbg{position:absolute;left:0;top:0;bottom:0;background:var(--signal-bg);z-index:0}
td.bar .txt{position:relative;z-index:1;word-break:break-all}
.rank{color:var(--muted);font-variant-numeric:tabular-nums;width:34px}
.size{font-weight:600;font-variant-numeric:tabular-nums;width:96px}
.share{color:var(--muted);font-variant-numeric:tabular-nums;width:64px}
.date{color:var(--muted);white-space:nowrap;width:104px}

.tag{display:inline-block;padding:1px 7px;border-radius:3px;font-size:11px;font-weight:600}
.tag.safe{background:#e2f2e9;color:var(--ok)}
.tag.caution{background:var(--warn-bg);color:var(--warn)}
.hint{color:var(--muted);font-size:12.5px}

.note{margin-top:34px;padding:14px 16px;background:var(--card);border:1px solid var(--rule);
  border-left:3px solid var(--muted);color:var(--muted);font-size:12.5px}
.note strong{color:var(--ink)}
.note ul{margin:8px 0 0;padding-left:18px} .note li{margin:3px 0}
.reclaim{background:var(--signal-bg);border-left-color:var(--signal);color:var(--ink)}

table.sortable thead th{cursor:pointer;user-select:none}
table.sortable thead th.sort-asc::after{content:" \25B4"}
table.sortable thead th.sort-desc::after{content:" \25BE"}

.tree{margin:2px 0 0}
.tree-list{list-style:none;margin:0;padding-left:20px}
.tree-list-root{padding-left:0}
.tree-node{margin:0}
.tree-row{display:flex;align-items:baseline;gap:8px;padding:6px 4px;border-bottom:1px solid #eef0f4;cursor:pointer}
.tree-row:hover{background:#f2f5f9}
.tree-toggle{width:14px;flex:none;color:var(--signal);font-weight:700;text-align:center;font-family:Consolas,monospace}
.tree-size{width:80px;flex:none;text-align:right;font-weight:600;font-variant-numeric:tabular-nums}
.tree-name{word-break:break-all}
.tree-small{margin-left:auto;white-space:nowrap;color:var(--muted);font-size:12px}
.tree-children{padding-left:2px}
table.filetable{margin:4px 0 10px 22px;width:calc(100% - 22px)}

@media print{body{padding:0;background:#fff}tbody tr:hover{background:none}}
@media(max-width:700px){.size,.share,.date,.rank{width:auto}body{padding:18px 12px}}
</style></head><body><div class="wrap">

<header>
  <h1>$(Get-HtmlSafe $env:COMPUTERNAME) <span>&mdash; $(Get-HtmlSafe $Path)</span></h1>
  <div class="meta mono">$($Start.ToString('yyyy-MM-dd HH:mm')) &middot; $('{0:N0}' -f $FileCount) files in $('{0:N0}' -f $DirCount) folders &middot; $('{0:N0}' -f $Elapsed.TotalSeconds)s$(if(-not $IsAdmin){' &middot; NOT ELEVATED'})$(if($Denied){" &middot; $Denied denied"})$(if($TooLong){" &middot; $TooLong path too long"})</div>
</header>

<div class="cap">
  <div class="cap-nums">
    <div class="cap-pct $CapClass">$UsedPct%</div>
    <div class="cap-lbl">$(Format-Size $DriveUsed) used of $(Format-Size $DriveTot) &middot; <strong>$(Format-Size $DriveFree) free</strong></div>
  </div>
  <div class="track"><div class="fill $CapClass" style="width:$UsedPct%"></div></div>
</div>
"@)

    # ---- interactive folder tree ----------------------------------------------
    if ($TreeJson) {
        [void] $Sb.Append('<h2>Folder tree<em>click a row to expand &mdash; largest first</em></h2>')
        [void] $Sb.Append('<div id="disk-tree-root" class="tree"></div>')
    }
    elseif ($TreeSkippedReason) {
        [void] $Sb.Append('<h2>Folder tree</h2>')
        [void] $Sb.Append("<div class=`"note`">$(Get-HtmlSafe $TreeSkippedReason)</div>")
    }

    # ---- top-level breakdown -------------------------------------------------
    [void] $Sb.Append('<h2>Top-level breakdown<em>rolled up &mdash; includes everything beneath</em></h2>')
    [void] $Sb.Append('<table class="sortable"><thead><tr><th class="num" data-type="num">Size</th><th class="num" data-type="num">Share</th><th data-type="text">Folder</th></tr></thead><tbody>')

    foreach ($R in $TopLevel) {
        $Pct = [math]::Round(($R.Bytes / $ScannedBytes) * 100, 1)
        $W   = [math]::Round(($R.Bytes / $MaxTopLevel) * 100, 2)
        [void] $Sb.Append((('<tr><td class="pad num size" data-val="{0}">{1}</td><td class="pad num share" data-val="{2}">{2}%</td>' +
            '<td class="bar" data-val="{3}"><div class="fillbg" style="width:{4}%"></div>' +
            '<div class="txt mono">{3}</div></td></tr>') -f `
            $R.Bytes, (Format-Size $R.Bytes), $Pct, (Get-HtmlSafe $R.Path), $W))
    }
    [void] $Sb.Append('</tbody></table>')

    # ---- heaviest folders ----------------------------------------------------
    [void] $Sb.Append('<h2>Heaviest folders<em>own content only &mdash; subfolders excluded, so a parent never buries its child</em></h2>')
    [void] $Sb.Append('<table class="sortable"><thead><tr><th class="num" data-type="num">#</th><th class="num" data-type="num">Size</th><th data-type="text">Folder</th></tr></thead><tbody>')

    $Rank = 0
    foreach ($R in $Heaviest) {
        $Rank++
        $W = [math]::Round(($R.Bytes / $MaxHeaviest) * 100, 2)
        [void] $Sb.Append((('<tr><td class="pad num rank mono" data-val="{0}">{0}</td><td class="pad num size" data-val="{1}">{2}</td>' +
            '<td class="bar" data-val="{3}"><div class="fillbg" style="width:{4}%"></div>' +
            '<div class="txt mono">{3}</div></td></tr>') -f `
            $Rank, $R.Bytes, (Format-Size $R.Bytes), (Get-HtmlSafe $R.Path), $W))
    }
    [void] $Sb.Append('</tbody></table>')

    # ---- largest files -------------------------------------------------------
    if ($LargestFiles) {
        [void] $Sb.Append("<h2>Largest files<em>over $MinFileSizeMB MB</em></h2>")
        [void] $Sb.Append('<table class="sortable"><thead><tr><th class="num" data-type="num">Size</th><th data-type="text">Modified</th><th data-type="text">File</th></tr></thead><tbody>')

        foreach ($R in $LargestFiles) {
            $W = [math]::Round(($R.Bytes / $MaxFile) * 100, 2)
            [void] $Sb.Append((('<tr><td class="pad num size" data-val="{0}">{1}</td><td class="pad date mono" data-val="{2}">{2}</td>' +
                '<td class="bar" data-val="{3}"><div class="fillbg" style="width:{4}%"></div>' +
                '<div class="txt mono">{3}</div></td></tr>') -f `
                $R.Bytes, (Format-Size $R.Bytes), $R.Modified.ToString('yyyy-MM-dd'), (Get-HtmlSafe $R.Path), $W))
        }
        [void] $Sb.Append('</tbody></table>')
    }

    # ---- cleanup targets -----------------------------------------------------
    if ($CleanupRows) {
        [void] $Sb.Append('<h2>Cleanup targets<em>found on this machine</em></h2>')
        [void] $Sb.Append('<table class="sortable"><thead><tr><th class="num" data-type="num">Size</th><th data-type="text">Flag</th><th data-type="text">Location</th><th data-type="text">How to clear</th></tr></thead><tbody>')

        foreach ($R in $CleanupRows) {
            [void] $Sb.Append((('<tr><td class="pad num size" data-val="{0}">{1}</td>' +
                '<td class="pad" data-val="{2}"><span class="tag {3}">{2}</span></td>' +
                '<td class="pad" data-val="{4}">{4}<br><span class="hint mono">{5}</span></td>' +
                '<td class="pad hint" data-val="{6}">{6}</td></tr>') -f `
                $R.Bytes, (Format-Size $R.Bytes), $R.Safety, $R.Safety.ToLower(),
                (Get-HtmlSafe $R.Name), (Get-HtmlSafe $R.Path), (Get-HtmlSafe $R.Action)))
        }
        [void] $Sb.Append('</tbody></table>')

        if ($Reclaimable -gt 0) {
            [void] $Sb.Append((('<div class="note reclaim"><strong>{0}</strong> is reclaimable from the ' +
                'items flagged Safe above, without touching user data.</div>') -f (Format-Size $Reclaimable)))
        }
    }

    # ---- tree data + interactive behaviour ------------------------------------
    if ($TreeJson) {
        [void] $Sb.Append('<script type="application/json" id="disk-tree-data">')
        [void] $Sb.Append($TreeJson)
        [void] $Sb.Append('</script>')
    }

    [void] $Sb.Append(@'
<script>
function makeSortable(table) {
  var ths = table.querySelectorAll('thead th');
  ths.forEach(function (th, idx) {
    if (!th.dataset.type) { return; }
    th.addEventListener('click', function () {
      var dir = th.dataset.dir === 'desc' ? 'asc' : 'desc';
      ths.forEach(function (h) { delete h.dataset.dir; h.classList.remove('sort-asc', 'sort-desc'); });
      th.dataset.dir = dir;
      th.classList.add(dir === 'asc' ? 'sort-asc' : 'sort-desc');

      var tbody = table.querySelector('tbody');
      var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));
      var isNum = th.dataset.type === 'num';

      rows.sort(function (a, b) {
        var av = a.children[idx].dataset.val, bv = b.children[idx].dataset.val;
        if (isNum) { av = parseFloat(av) || 0; bv = parseFloat(bv) || 0; }
        if (av < bv) { return dir === 'asc' ? -1 : 1; }
        if (av > bv) { return dir === 'asc' ? 1 : -1; }
        return 0;
      });
      rows.forEach(function (r) { tbody.appendChild(r); });
    });
  });
}

function diskUsageFormatSize(bytes) {
  if (bytes >= 1099511627776) { return (bytes / 1099511627776).toFixed(2) + ' TB'; }
  if (bytes >= 1073741824)    { return (bytes / 1073741824).toFixed(2) + ' GB'; }
  if (bytes >= 1048576)       { return (bytes / 1048576).toFixed(1) + ' MB'; }
  if (bytes >= 1024)          { return Math.round(bytes / 1024) + ' KB'; }
  return bytes + ' B';
}

function diskUsageFormatDate(epochSeconds) {
  return new Date(epochSeconds * 1000).toISOString().slice(0, 10);
}

function diskUsageBuildFilesTable(node) {
  if (!node.f || !node.f.length) { return null; }
  var table = document.createElement('table');
  table.className = 'sortable filetable';
  table.innerHTML = '<thead><tr><th class="num" data-type="num">Size</th>' +
    '<th data-type="text">Modified</th><th data-type="text">File</th></tr></thead><tbody></tbody>';
  var tbody = table.querySelector('tbody');
  node.f.forEach(function (f) {
    var name = f[0], bytes = f[1], epoch = f[2];
    var tr = document.createElement('tr');
    var tdSize = document.createElement('td');
    tdSize.className = 'pad num size mono'; tdSize.dataset.val = bytes; tdSize.textContent = diskUsageFormatSize(bytes);
    var tdDate = document.createElement('td');
    tdDate.className = 'pad date mono'; tdDate.dataset.val = epoch; tdDate.textContent = diskUsageFormatDate(epoch);
    var tdName = document.createElement('td');
    tdName.className = 'pad mono'; tdName.dataset.val = name; tdName.textContent = name;
    tr.appendChild(tdSize); tr.appendChild(tdDate); tr.appendChild(tdName);
    tbody.appendChild(tr);
  });
  makeSortable(table);
  return table;
}

function diskUsageBuildNode(node, childrenOf) {
  var li = document.createElement('li');
  li.className = 'tree-node';

  var row = document.createElement('div');
  row.className = 'tree-row';

  var kids = childrenOf[node.i] || [];
  var hasKids = kids.length > 0;
  var hasFiles = node.f && node.f.length > 0;
  var expandable = hasKids || hasFiles;

  var toggle = document.createElement('span');
  toggle.className = 'tree-toggle';
  toggle.textContent = expandable ? '+' : ' ';
  row.appendChild(toggle);

  var sizeSpan = document.createElement('span');
  sizeSpan.className = 'tree-size mono';
  sizeSpan.textContent = diskUsageFormatSize(node.t);
  row.appendChild(sizeSpan);

  var nameSpan = document.createElement('span');
  nameSpan.className = 'tree-name mono';
  nameSpan.textContent = node.n;
  row.appendChild(nameSpan);

  if (node.sc > 0) {
    var smallSpan = document.createElement('span');
    smallSpan.className = 'tree-small';
    smallSpan.textContent = '+ ' + node.sc + ' smaller file' + (node.sc === 1 ? '' : 's') +
      ' (' + diskUsageFormatSize(node.sb) + ')';
    row.appendChild(smallSpan);
  }
  li.appendChild(row);

  var childContainer = document.createElement('div');
  childContainer.className = 'tree-children';
  childContainer.style.display = 'none';
  li.appendChild(childContainer);

  var built = false;
  if (expandable) {
    row.addEventListener('click', function () {
      var open = childContainer.style.display !== 'none';
      if (open) {
        childContainer.style.display = 'none';
        toggle.textContent = '+';
        return;
      }
      if (!built) {
        built = true;
        if (hasFiles) {
          var ft = diskUsageBuildFilesTable(node);
          if (ft) { childContainer.appendChild(ft); }
        }
        if (hasKids) {
          var ul = document.createElement('ul');
          ul.className = 'tree-list';
          kids.forEach(function (k) { ul.appendChild(diskUsageBuildNode(k, childrenOf)); });
          childContainer.appendChild(ul);
        }
      }
      childContainer.style.display = '';
      toggle.textContent = '-';
    });
  }
  return li;
}

document.addEventListener('DOMContentLoaded', function () {
  document.querySelectorAll('table.sortable').forEach(makeSortable);

  var dataEl = document.getElementById('disk-tree-data');
  var container = document.getElementById('disk-tree-root');
  if (!dataEl || !container) { return; }

  var nodes = JSON.parse(dataEl.textContent);
  var childrenOf = {};
  nodes.forEach(function (n) {
    if (!childrenOf[n.p]) { childrenOf[n.p] = []; }
    childrenOf[n.p].push(n);
  });

  var rootNodes = childrenOf[-1] || [];
  var ul = document.createElement('ul');
  ul.className = 'tree-list tree-list-root';
  rootNodes.forEach(function (n) {
    var li = diskUsageBuildNode(n, childrenOf);
    ul.appendChild(li);
    li.querySelector('.tree-row').click();
  });
  container.appendChild(ul);
});
</script>
'@)

    # ---- caveats -------------------------------------------------------------
    [void] $Sb.Append(@"
<div class="note">
  <strong>Reading these numbers</strong>
  <ul>
    <li>Sizes are logical, not size-on-disk. Compressed, sparse or deduplicated volumes will read high against Explorer.</li>
    <li>Hard-linked files are counted once per link, so WinSxS is inflated. Treat it as indicative.</li>
    <li>Junctions and symlinks were skipped rather than followed, to avoid double-counting and loops.</li>
    <li>pagefile.sys, hiberfil.sys and swapfile.sys appear as ordinary files. Manage them through System Properties, not by deleting.</li>
    <li>Tables and the folder tree above are interactive: click a column header to sort, click a tree row to expand it.</li>
$(if (-not $IsAdmin) { '    <li><strong>This scan was not elevated</strong> &mdash; other user profiles and protected folders are missing from the totals.</li>' })
  </ul>
</div>

</div></body></html>
"@)

    $Sb.ToString() | Set-Content -LiteralPath $ReportPath -Encoding UTF8

    if (-not $Quiet) {
        Write-Host "  Report: $ReportPath" -ForegroundColor Cyan
        Write-Host ''
    }
}

#--------------------------------------------------------------------------------
# Pipeline output
#--------------------------------------------------------------------------------

if ($PassThru) {
    [PSCustomObject]@{
        ComputerName   = $env:COMPUTERNAME
        Path           = $Path
        ScannedAt      = $Start
        DurationSec    = [math]::Round($Elapsed.TotalSeconds, 1)
        FileCount      = $FileCount
        FolderCount    = $DirCount
        AccessDenied   = $Denied
        PathTooLong    = $TooLong
        Elevated       = $IsAdmin
        VolumeTotal    = $DriveTot
        VolumeFree     = $DriveFree
        VolumeUsedPct  = $UsedPct
        ScannedBytes   = [long] $ScannedBytes
        ReclaimableB   = [long] $Reclaimable
        TopLevel       = $TopLevel
        HeaviestFolder = $Heaviest
        LargestFiles   = $LargestFiles
        CleanupTargets = $CleanupRows
        ReportPath     = $(if ($NoHtml) { $null } else { $ReportPath })
    }
}