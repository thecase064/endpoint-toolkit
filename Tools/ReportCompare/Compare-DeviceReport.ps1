<#
.SYNOPSIS
    Before and after: reads the Performance check, Quick triage, Wi-Fi and battery reports already
    saved for a PC, and writes up what changed, what's still wrong and what to look at next.

.DESCRIPTION
    Run the checks before you start (Quick triage -Html -Reports, Performance check -Html), do the
    work, run them again, then run this. It finds every report for the PC in C:\Triage and puts
    them side by side:

      What changed     fails and warnings from the first run to the latest; each check that was
                       fixed, got better, got worse or is new; restarts and Windows builds between
      Before / after   the numbers that matter for every run, side by side: CPU, disk, memory,
                       paging, start-up times, free space, build, drivers, last update, shutdowns
      Worth knowing    things that only show when you read the reports together: a first run
                       caught mid-update, an idle after run, no battery plus unexpected shutdowns,
                       updates that nothing manages, classic Teams still starting, new startup
                       apps, crashing management-engine software
      Still to do      everything still WARN or FAIL in the latest reports, each with its fix
      Wi-Fi, battery   what Windows' own reports show, and what they couldn't (Location off)

    Read-only. It reads the reports and writes one HTML page next to them, named after the PC:
    Report_<PC>_<time>.html. Nothing is sent anywhere: the write-up comes from rules in this
    script, not from an online service.

.PARAMETER ReportFolder
    Where the reports are, and where the comparison is written. Default C:\Triage.

.PARAMETER ComputerName
    Whose reports to compare. Default this PC. Use it for reports copied from another machine.

.PARAMETER Days
    Only use reports from the last N days. Default 30.

.PARAMETER Path
    Compare these report files instead of searching ReportFolder. Wildcards work.

.PARAMETER Ticket
    Ticket number, shown on the report.

.PARAMETER NoOpen
    Don't open the comparison after writing it.

.PARAMETER Quiet
    Print only the one-line summary.

.PARAMETER PassThru
    Emit the comparison (runs, what moved, numbers, notes, what's left) to the pipeline.

.EXAMPLE
    .\Compare-DeviceReport.ps1

.EXAMPLE
    .\Compare-DeviceReport.ps1 -Ticket 123456

.EXAMPLE
    .\Compare-DeviceReport.ps1 -ComputerName PC-1234 -ReportFolder \\server\share\Triage
    (Reports copied off another machine.)

.NOTES
    Exit codes: 0 = comparison written, 1 = no reports found.
    Reads the toolkit's own HTML reports, so it works on reports made before it existed.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $ReportFolder = (Join-Path $(if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }) 'Triage'),
    [string] $ComputerName = $env:COMPUTERNAME,
    [ValidateRange(1, 365)] [int] $Days = 30,
    [string[]] $Path,
    [string] $Ticket,
    [switch] $NoOpen,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$now = Get-Date
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Arrow = '->'   # ASCII: survives remote sessions and RMM shells; the HTML turns it into a real arrow
$Dot   = [string][char]0x00B7
$MaxRuns = 6

# ------------------------------------------------------------------------------------------------
#  Small helpers
# ------------------------------------------------------------------------------------------------
function ConvertFrom-HtmlText {
    param([string] $Html)
    $t = $Html -replace '(?i)<br\s*/?>', ' ' -replace '<[^>]+>', ''
    ([Net.WebUtility]::HtmlDecode($t) -replace '\s+', ' ').Trim()
}

function ConvertTo-Number {
    # Numbers as the reports print them: "5,037", "173.2", "1,234.5", and "2,2" on comma-decimal PCs.
    param([string] $Text)
    $t = ($Text -replace '[^\d.,]', '').Trim('.', ',')
    if (-not $t) { return $null }
    if ($t -match '^(.*)[.,](\d)$') { $t = ($Matches[1] -replace '[.,]', '') + '.' + $Matches[2] }
    else { $t = $t -replace '[.,]', '' }
    [double]::Parse($t, $Inv)
}

function ConvertFrom-Duration {
    # "1m 20s", "49s" (Performance check's own format)
    param([string] $Text)
    if ($Text -match '^(?:(\d+)m\s*)?(\d+)s$') { [int]$Matches[2] + 60 * [int]("0$($Matches[1])") } else { $null }
}

function Format-When { param([datetime] $When) $When.ToString('d MMM HH:mm', $Inv) }

function Get-Finding {
    param($Report, [string] $Check)
    if (-not $Report) { return $null }
    @($Report.Findings | Where-Object { $_.Check -eq $Check }) | Select-Object -First 1
}

function Get-Detail { param($Report, [string] $Check) $f = Get-Finding $Report $Check; if ($f) { $f.Detail } }

function ConvertTo-MetricValue { param([string] $Text, $Value) [pscustomobject]@{ Text = $Text; Value = $Value } }

$StatusRank = @{ PASS = 0; INFO = 1; WARN = 2; FAIL = 3 }
function Test-Bad { param([string] $Status) $Status -eq 'WARN' -or $Status -eq 'FAIL' }

# Worst-first order for "still to do": hardware and stability before tidying.
$AreaOrder = @('Hardware', 'Disk', 'Battery', 'Stability', 'Updates', 'Entra/Intune', 'Security', 'Load', 'Resources',
    'Power', 'Apps', 'Uptime', 'Reboot', 'Startup', 'Drivers', 'Network', 'Device')
function Get-AreaRank { param([string] $Area) $i = [array]::IndexOf($AreaOrder, $Area); if ($i -lt 0) { 99 } else { $i } }

# ------------------------------------------------------------------------------------------------
#  Find the reports
# ------------------------------------------------------------------------------------------------
$NameRx = '^(?:.*?[-_ ])?(?<type>Performance|Triage|WiFi|Battery)_(?<pc>.+)_(?<ts>\d{8}-\d{4})\.html?$'

function Get-ReportMeta {
    param([IO.FileInfo] $File)
    if ($File.Name -notmatch $NameRx) { return $null }
    $when = [datetime]::ParseExact($Matches['ts'], 'yyyyMMdd-HHmm', $Inv)
    [pscustomobject]@{ Type = $Matches['type']; Pc = $Matches['pc']; When = $when; File = $File.FullName; Name = $File.Name }
}

$candidates = New-Object System.Collections.Generic.List[object]
if ($Path) {
    $seen = @{}
    foreach ($p in $Path) {
        foreach ($item in @(Get-Item -Path $p -ErrorAction SilentlyContinue)) {
            if ($item -is [IO.FileInfo] -and -not $seen.ContainsKey($item.FullName)) {
                $seen[$item.FullName] = $true
                $m = Get-ReportMeta $item
                if ($m) { $candidates.Add($m) }
                elseif (-not $Quiet) { Write-Host "  Skipped (not a toolkit, Wi-Fi or battery report): $($item.Name)" -ForegroundColor DarkGray }
            }
        }
    }
    if ($candidates.Count -and -not $PSBoundParameters.ContainsKey('ComputerName')) {
        $ComputerName = ($candidates | Group-Object Pc | Sort-Object Count -Descending | Select-Object -First 1).Name
    }
}
elseif (Test-Path -LiteralPath $ReportFolder) {
    foreach ($f in @(Get-ChildItem -LiteralPath $ReportFolder -File -Filter '*.htm*')) {
        $m = Get-ReportMeta $f
        if ($m -and $m.When -ge $now.AddDays(-$Days)) { $candidates.Add($m) }
    }
}

$PcName = if ($ComputerName) { $ComputerName } else { 'this PC' }
$metas = @($candidates | Where-Object { $_.Pc -eq $PcName } | Sort-Object When)
if (-not $metas.Count) {
    $others = @($candidates | Select-Object -ExpandProperty Pc -Unique)
    $where = if ($Path) { 'the files given' } else { "$ReportFolder (last $Days days)" }
    $msg = "No reports for $PcName in $where."
    if ($others.Count) { $msg += " Found reports for: $($others -join ', '). Use -ComputerName." }
    else { $msg += ' Run Quick triage -Html -Reports and Performance check -Html first, then again after the work.' }
    if ($Quiet) { Write-Output $msg } else { Write-Host "  $msg" -ForegroundColor Yellow }
    exit 1
}

# ------------------------------------------------------------------------------------------------
#  Read them
# ------------------------------------------------------------------------------------------------
function Read-ToolkitReport {
    # Performance check and Quick triage pages: the same layout, written by this toolkit.
    param($Meta)
    $html = [IO.File]::ReadAllText($Meta.File)
    $sub  = if ($html -match '(?s)<div class="sub">(.*?)</div>') { ConvertFrom-HtmlText $Matches[1] } else { '' }
    $sum  = if ($html -match '(?s)<div class="summary">(.*?)</div>') { ConvertFrom-HtmlText $Matches[1] } else { '' }
    $findings = New-Object System.Collections.Generic.List[object]
    $apps     = New-Object System.Collections.Generic.List[object]
    $notes    = New-Object System.Collections.Generic.List[string]
    $hasApps  = $false

    foreach ($sec in [regex]::Split($html, '(?i)<h2>')) {
        if ($sec -notmatch '(?s)^(.*?)</h2>') { continue }
        $title = ConvertFrom-HtmlText $Matches[1]
        if ($title -match '^(Needs attention|Checked and fine)') {
            $rx = '(?s)<tr class="\w+"><td class="st">(?<st>PASS|WARN|FAIL|INFO)</td><td>(?<area>.*?)</td><td>(?<check>.*?)</td><td>(?<detail>.*?)</td></tr>'
            foreach ($m in [regex]::Matches($sec, $rx)) {
                $d = $m.Groups['detail'].Value; $fix = ''
                if ($d -match '(?s)^(.*?)<div class="fix">(.*?)</div>') { $d = $Matches[1]; $fix = ConvertFrom-HtmlText $Matches[2] }
                $fix = $fix -replace ('^\s*(?:' + [char]0x2192 + '|->)\s*'), ''
                $findings.Add([pscustomobject]@{
                    Status = $m.Groups['st'].Value; Area = ConvertFrom-HtmlText $m.Groups['area'].Value
                    Check = ConvertFrom-HtmlText $m.Groups['check'].Value; Detail = ConvertFrom-HtmlText $d; Fix = $fix; Key = $null })
            }
        }
        elseif ($title -match '^Startup apps') {
            $hasApps = $true
            $rx = '(?s)<tr class="\w+"><td class="st">(?<st>On|Off)</td><td>(?<name>.*?)</td><td>(?<from>.*?)</td><td>(?<rest>.*?)</td></tr>'
            foreach ($m in [regex]::Matches($sec, $rx)) {
                $rest = $m.Groups['rest'].Value
                $cmd  = if ($rest -match '(?s)<span class="cmd">(.*?)</span>') { ConvertFrom-HtmlText $Matches[1] } else { '' }
                $note = if ($rest -match '(?s)<div class="fix">(.*?)</div>') { ConvertFrom-HtmlText $Matches[1] } else { '' }
                $apps.Add([pscustomobject]@{ Name = ConvertFrom-HtmlText $m.Groups['name'].Value; On = $m.Groups['st'].Value -eq 'On'
                    From = ConvertFrom-HtmlText $m.Groups['from'].Value; Command = $cmd; Note = $note })
            }
        }
        elseif ($title -match '^Reports') {
            foreach ($m in [regex]::Matches($sec, '(?s)<li>(.*?)</li>')) { $notes.Add((ConvertFrom-HtmlText $m.Groups[1].Value)) }
        }
    }

    # The same check can appear twice (two antivirus products), so the key counts them.
    $n = @{}
    foreach ($f in $findings) {
        $k = "$($f.Area)|$($f.Check)"
        $n[$k] = 1 + [int]$n[$k]
        $f.Key = "$k|$($n[$k])"
    }

    $headline = ($sub -split [regex]::Escape($Dot))[0].Trim()
    $fails = 0; $warns = 0
    if ($sum -match '(\d+) fail, (\d+) warn') { $fails = [int]$Matches[1]; $warns = [int]$Matches[2] }
    [pscustomobject]@{
        Type = $Meta.Type; When = $Meta.When; File = $Meta.File; Name = $Meta.Name; Label = Format-When $Meta.When
        Headline = $headline; Summary = $sum; Fails = $fails; Warns = $warns
        Build = $(if ($headline -match '\((\d{5}\.\d+)\)') { $Matches[1] })
        RamGB = $(if ($headline -match '\|\s*(\d+) GB RAM') { [int]$Matches[1] })
        Findings = $findings.ToArray(); StartupApps = $apps.ToArray(); HasStartupApps = $hasApps; Notes = $notes.ToArray()
    }
}

function Read-WifiReport {
    # Windows' own report (netsh wlan show wlanreport), as Quick triage -Reports saves it.
    param($Meta)
    $html = [IO.File]::ReadAllText($Meta.File)
    $w = [ordered]@{
        Type = 'WiFi'; When = $Meta.When; File = $Meta.File; Name = $Meta.Name; Label = Format-When $Meta.When
        Created = $null; Duration = $null; LocationOff = $false; Adapter = $null; DriverVersion = $null; DriverDate = $null
        Successes = $null; Failures = $null; Warnings = $null; Reasons = @(); Connects = 0; Disconnects = 0; FailedConnects = 0
        Errors = 0; Boots = 0; WifiUpDelays = @(); Dns = @(); Profiles = @(); Ssid = $null; Signal = $null; Channel = $null; Radio = $null
    }
    if ($html -match 'Report created:\s*<b>([^<]+)</b>') { $w.Created = $Matches[1].Trim() }
    if ($html -match 'Report duration:\s*<b>([^<]+)</b>') { $w.Duration = $Matches[1].Trim() }

    foreach ($m in [regex]::Matches($html, '(?s)<p>Device: <b>(?<dev>[^<]+)</b></p>(?<body>.*?)(?=<p>Device: <b>|</div>)')) {
        $dev = $m.Groups['dev'].Value.Trim()
        if ($dev -match 'Wi-?Fi|Wireless|WLAN|802\.11' -and $dev -notmatch 'Direct|Virtual') {
            $body = $m.Groups['body'].Value
            $w.Adapter = $dev
            if ($body -match 'Current driver version:\s*<b>([^<]+)</b>') { $w.DriverVersion = $Matches[1].Trim() }
            if ($body -match 'Driver date:\s*<b>\s*(\d{1,2})-(\d{1,2})-(\d{4})') {
                try { $w.DriverDate = New-Object DateTime ([int]$Matches[3]), ([int]$Matches[1]), ([int]$Matches[2]) } catch { $w.DriverDate = $null }
            }
            break
        }
    }

    $text = (@([regex]::Matches($html, '(?s)<textarea[^>]*>(.*?)</textarea>') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) })) -join "`n"
    $w.LocationOff = $text -match 'need location permission'
    $lines = @($text -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'DNS Servers[ .]*:\s*(\S+)') {
            $dns = @($Matches[1])
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match '^\s*$') { continue }
                if ($lines[$j] -match '^\s+((?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]+:[0-9a-fA-F:%]+)\s*$') { $dns += $Matches[1] } else { break }
            }
            $w.Dns = @($w.Dns + $dns | Select-Object -Unique)
        }
    }
    $w.Profiles = @([regex]::Matches($text, '(?m)(?:All User|Current User) Profile\s*:\s*(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($text -match '(?s)SHOW INTERFACES(.*?)SHOW HOSTED NETWORK') {
        $ifText = $Matches[1]
        if ($ifText -match '(?m)^\s*SSID\s*:\s*(.+?)\s*$') { $w.Ssid = $Matches[1] }
        if ($ifText -match '(?m)^\s*Signal\s*:\s*(\d+)%') { $w.Signal = [int]$Matches[1] }
        if ($ifText -match '(?m)^\s*Channel\s*:\s*(\d+)') { $w.Channel = [int]$Matches[1] }
        if ($ifText -match '(?m)^\s*Radio type\s*:\s*(\S+)') { $w.Radio = $Matches[1] }
    }

    foreach ($m in [regex]::Matches($html, '(?s)(Successes|Failures|Warnings)\s*</td>\s*<td class="count">(\d+)</td>')) {
        $w[$m.Groups[1].Value] = [int]$m.Groups[2].Value
    }
    if ($html -match '(?s)<table id="disconnect-reasons">(.*?)</table>') {
        $w.Reasons = @([regex]::Matches($Matches[1], '(?s)<tr>\s*<td[^>]*>(?<r>.*?)</td>\s*<td class="count">(?<n>\d+)</td>') |
            ForEach-Object { '{0} x{1}' -f (ConvertFrom-HtmlText $_.Groups['r'].Value), $_.Groups['n'].Value })
    }

    $evRx = '(?s)<tr class="(?<cls>[^"]*)">\s*<td>(?<id>\d+)<a[^>]*></a></td>\s*<td>(?<t>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})</td>\s*<td>.*?<span class="message-body">(?<msg>.*?)</span>'
    $boot = $null; $delays = @()
    foreach ($m in [regex]::Matches($html, $evRx)) {
        $msg = ConvertFrom-HtmlText $m.Groups['msg'].Value
        $t   = [datetime]::ParseExact($m.Groups['t'].Value, 'yyyy-MM-ddTHH:mm:ss', $Inv)
        if ($m.Groups['cls'].Value -match '\berror\b') { $w.Errors++ }
        if ($msg -match 'successfully connected') { $w.Connects++ }
        if ($msg -match 'disconnected from') { $w.Disconnects++ }
        if ($msg -match 'failed to connect') { $w.FailedConnects++ }
        if ($msg -match 'operating system started') { $boot = $t; $w.Boots++ }
        elseif ($boot -and $msg -match 'adapter arrival' -and $msg -match 'Type:\s*Wlan') {
            $delays += [pscustomobject]@{ Boot = $boot; Minutes = [math]::Round(($t - $boot).TotalMinutes, 1) }
            $boot = $null
        }
    }
    $w.WifiUpDelays = $delays
    [pscustomobject]$w
}

function Read-BatteryReport {
    # Windows' own report (powercfg /batteryreport). Layout read loosely; anything missing stays blank.
    param($Meta)
    $html = [IO.File]::ReadAllText($Meta.File)
    $get = {
        param([string] $LabelText)
        if ($html -match "(?s)$LabelText</span>\s*</td>\s*<td>\s*([\d.,\s]+?)\s*(?:mWh|</td>)") { ConvertTo-Number $Matches[1] }
    }
    $design = & $get 'DESIGN CAPACITY'
    $full   = & $get 'FULL CHARGE CAPACITY'
    $cycles = & $get 'CYCLE COUNT'
    [pscustomobject]@{
        Type = 'Battery'; When = $Meta.When; File = $Meta.File; Name = $Meta.Name; Label = Format-When $Meta.When
        DesignmWh = $design; FullmWh = $full; Cycles = $cycles
        HealthPercent = $(if ($design -and $full) { [int][math]::Round(100 * $full / $design) })
    }
}

$Runs = New-Object System.Collections.Generic.List[object]
foreach ($m in $metas) {
    try {
        switch ($m.Type) {
            'Performance' { $Runs.Add((Read-ToolkitReport $m)) }
            'Triage'      { $Runs.Add((Read-ToolkitReport $m)) }
            'WiFi'        { $Runs.Add((Read-WifiReport $m)) }
            'Battery'     { $Runs.Add((Read-BatteryReport $m)) }
        }
    }
    catch { if (-not $Quiet) { Write-Host "  Couldn't read $($m.Name): $($_.Exception.Message)" -ForegroundColor Yellow } }
}

if (-not $Runs.Count) {
    $msg = "None of the $($metas.Count) report(s) for $PcName could be read."
    if ($Quiet) { Write-Output $msg } else { Write-Host "  $msg" -ForegroundColor Yellow }
    exit 1
}

$Perf    = @($Runs | Where-Object Type -eq 'Performance' | Sort-Object When)
$Triage  = @($Runs | Where-Object Type -eq 'Triage' | Sort-Object When)
$Wifi    = @($Runs | Where-Object Type -eq 'WiFi' | Sort-Object When)
$Battery = @($Runs | Where-Object Type -eq 'Battery' | Sort-Object When)
$Toolkit = @($Runs | Where-Object { $_.Type -in 'Performance', 'Triage' } | Sort-Object When)
$LastPerf   = if ($Perf.Count) { $Perf[-1] } else { $null }
$LastTriage = if ($Triage.Count) { $Triage[-1] } else { $null }

function Select-Shown {
    # Up to six runs as columns: the first, then the most recent.
    param([object[]] $List)
    if ($List.Count -le $MaxRuns) { return $List }
    @($List[0]) + @($List[($List.Count - $MaxRuns + 1)..($List.Count - 1)])
}

# ------------------------------------------------------------------------------------------------
#  What moved: each check, first run against latest, per report type
# ------------------------------------------------------------------------------------------------
function Compare-Run {
    param($First, $Last)
    $out = New-Object System.Collections.Generic.List[object]
    $a = @{}; foreach ($f in $First.Findings) { $a[$f.Key] = $f }
    $b = @{}; foreach ($f in $Last.Findings)  { $b[$f.Key] = $f }
    $keys = @($Last.Findings | ForEach-Object { $_.Key }) + @($First.Findings | Where-Object { -not $b.ContainsKey($_.Key) } | ForEach-Object { $_.Key })
    foreach ($k in $keys) {
        $f1 = $a[$k]; $f2 = $b[$k]
        $s1 = if ($f1) { $f1.Status } else { $null }
        $s2 = if ($f2) { $f2.Status } else { $null }
        $move = if ((Test-Bad $s1) -and -not $f2) { 'Cleared' }
            elseif ((Test-Bad $s1) -and -not (Test-Bad $s2)) { 'Fixed' }
            elseif ((Test-Bad $s1) -and (Test-Bad $s2)) {
                if ($StatusRank[$s2] -lt $StatusRank[$s1]) { 'Better' } elseif ($StatusRank[$s2] -gt $StatusRank[$s1]) { 'Worse' } else { 'Still' }
            }
            elseif (Test-Bad $s2) { if ($f1) { 'Worse' } else { 'New' } }
            else { 'Fine' }
        $any = if ($f2) { $f2 } else { $f1 }
        $out.Add([pscustomobject]@{
            Type = $Last.Type; Area = $any.Area; Check = $any.Check; Move = $move; From = $s1; To = $s2
            Before = $(if ($f1) { $f1.Detail }); After = $(if ($f2) { $f2.Detail }); Fix = $(if ($f2) { $f2.Fix })
        })
    }
    $out.ToArray()
}

$Moves = @()
if ($Perf.Count -ge 2)   { $Moves += Compare-Run $Perf[0] $Perf[-1] }
if ($Triage.Count -ge 2) { $Moves += Compare-Run $Triage[0] $Triage[-1] }
$MoveOrder = @('Fixed', 'Cleared', 'Better', 'Worse', 'New', 'Still')

# ------------------------------------------------------------------------------------------------
#  The numbers, per run
# ------------------------------------------------------------------------------------------------
$Common = @(
    @{ Name = 'Result'; Better = 'Lower'; Get = { param($r) ConvertTo-MetricValue ('{0} fail, {1} warn' -f $r.Fails, $r.Warns) ($r.Fails * 1000 + $r.Warns) } }
    @{ Name = 'Windows build'; Better = 'Changed'; Get = { param($r) if ($r.Build) { ConvertTo-MetricValue $r.Build $null } } }
)
$PerfMetrics = $Common + @(
    @{ Name = 'CPU average'; Better = 'Lower'; Get = { param($r)
        if ((Get-Detail $r 'CPU') -match 'Average (\d[\d.,]*)%, peak (\d[\d.,]*)%') { ConvertTo-MetricValue ('{0}% (peak {1}%)' -f $Matches[1], $Matches[2]) (ConvertTo-Number $Matches[1]) } } }
    @{ Name = 'Disk busy'; Better = 'Lower'; Get = { param($r)
        if ((Get-Detail $r 'Disk') -match 'busy (\d[\d.,]*)% of the time(?:, (\d[\d.,]*) requests waiting)?') {
            $t = '{0}%' -f $Matches[1]; if ($Matches[2]) { $t += ', {0} waiting' -f $Matches[2] }
            ConvertTo-MetricValue $t (ConvertTo-Number $Matches[1]) } } }
    @{ Name = 'Memory free'; Better = 'Higher'; Get = { param($r)
        if ((Get-Detail $r 'Memory') -match '^(\d[\d.,]*)\s*(GB|MB|KB) free of (\d+) GB \((\d+)%\)') {
            $gb = ConvertTo-Number $Matches[1]; if ($Matches[2] -eq 'MB') { $gb = $gb / 1024 } elseif ($Matches[2] -eq 'KB') { $gb = $gb / 1MB }
            ConvertTo-MetricValue ('{0} {1} ({2}%)' -f $Matches[1], $Matches[2], $Matches[4]) $gb } } }
    @{ Name = 'Commit in use'; Better = 'Lower'; Get = { param($r)
        if ((Get-Detail $r 'Memory') -match '(\d+)% of the commit limit') { ConvertTo-MetricValue ('{0}%' -f $Matches[1]) ([int]$Matches[1]) } } }
    @{ Name = 'Paging from disk'; Better = 'Lower'; Get = { param($r)
        $d = Get-Detail $r 'Memory'
        if ($d -match '\((\d[\d.,]*) pages/s\)') { ConvertTo-MetricValue ('{0} pages/s' -f $Matches[1]) (ConvertTo-Number $Matches[1]) }
        elseif ($d) { ConvertTo-MetricValue 'none' 0 } } }
    @{ Name = 'Start-up, total'; Better = 'Lower'; Get = { param($r)
        if ((Get-Detail $r 'Start-up time') -match '^Last start-up ((?:\d+m )?\d+s)') { ConvertTo-MetricValue $Matches[1] (ConvertFrom-Duration $Matches[1]) } } }
    @{ Name = 'Power-on to sign-in screen'; Better = 'Lower'; Get = { param($r)
        if ((Get-Detail $r 'Start-up time') -match '\(((?:\d+m )?\d+s) to the sign-in screen') { ConvertTo-MetricValue $Matches[1] (ConvertFrom-Duration $Matches[1]) } } }
    @{ Name = 'Sign-in to settled'; Better = 'Lower'; Get = { param($r)
        if ((Get-Detail $r 'Start-up time') -match '((?:\d+m )?\d+s) after signing in') { ConvertTo-MetricValue $Matches[1] (ConvertFrom-Duration $Matches[1]) } } }
    @{ Name = 'Free space'; Better = 'Higher'; Get = { param($r)
        if ((Get-Detail $r 'Free space') -match 'has (\d[\d.,]*) GB free \((\d+)%\)') { ConvertTo-MetricValue ('{0} GB ({1}%)' -f $Matches[1], $Matches[2]) (ConvertTo-Number $Matches[1]) } } }
    @{ Name = 'Pending restart'; Better = 'Lower'; Get = { param($r)
        $d = Get-Detail $r 'Pending restart'; if ($d -eq 'None') { ConvertTo-MetricValue 'None' 0 } elseif ($d) { ConvertTo-MetricValue 'Yes' 1 } } }
    @{ Name = 'Last boot'; Better = 'Changed'; Get = { param($r)
        if ((Get-Detail $r 'Uptime') -match '\((\d{4}-\d{2}-\d{2} \d{2}:\d{2})\)') { ConvertTo-MetricValue (Format-When ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm', $Inv))) $null } } }
    @{ Name = 'Busiest app (CPU)'; Better = ''; Get = { param($r)
        $d = Get-Detail $r 'Top CPU'; if ($d) { ConvertTo-MetricValue (($d -split ',\s*')[0]) $null } } }
    @{ Name = 'Startup apps on'; Better = 'Lower'; Get = { param($r)
        if ($r.HasStartupApps) { $n = @($r.StartupApps | Where-Object On).Count; ConvertTo-MetricValue "$n" $n } } }
    @{ Name = 'Graphics driver'; Better = 'Changed'; Get = { param($r)
        if ((Get-Detail $r 'Graphics driver') -match 'driver (\S+) from (\d{4}-\d{2}-\d{2})') { ConvertTo-MetricValue ('{0} ({1})' -f $Matches[1], $Matches[2]) $null } } }
    @{ Name = 'BIOS'; Better = 'Changed'; Get = { param($r)
        if ((Get-Detail $r 'BIOS age') -match 'BIOS (\S+) from (\d{4}-\d{2}-\d{2})') { ConvertTo-MetricValue ('{0} ({1})' -f $Matches[1], $Matches[2]) $null } } }
)
$CountRx = '^(\d+) in (\d+) days'
$TriageMetrics = $Common + @(
    @{ Name = 'Last update'; Better = 'Lower'; Get = { param($r)
        if ((Get-Detail $r 'Last update') -match 'Installed (\d+) days ago \((\d{4}-\d{2}-\d{2})') { ConvertTo-MetricValue ('{0} days ago ({1})' -f $Matches[1], $Matches[2]) ([int]$Matches[1]) } } }
    @{ Name = 'Unexpected shutdowns'; Better = 'Lower'; Get = { param($r)
        $d = Get-Detail $r 'Unexpected shutdowns'; if ($d -match $CountRx) { ConvertTo-MetricValue $d ([int]$Matches[1]) } elseif ($d) { ConvertTo-MetricValue $d 0 } } }
    @{ Name = 'Blue screens'; Better = 'Lower'; Get = { param($r)
        $d = Get-Detail $r 'Blue screens'; if ($d -match $CountRx) { ConvertTo-MetricValue ('{0} in {1} days' -f $Matches[1], $Matches[2]) ([int]$Matches[1]) } elseif ($d) { ConvertTo-MetricValue $d 0 } } }
    @{ Name = 'App crashes'; Better = 'Lower'; Get = { param($r)
        $d = Get-Detail $r 'App crashes'; if ($d -match $CountRx) { ConvertTo-MetricValue $d ([int]$Matches[1]) } elseif ($d) { ConvertTo-MetricValue $d 0 } } }
    @{ Name = 'Memory in use'; Better = 'Lower'; Get = { param($r)
        if ((Get-Detail $r 'Memory') -match '^(\d+)% of (\d+) GB') { ConvertTo-MetricValue ('{0}% of {1} GB' -f $Matches[1], $Matches[2]) ([int]$Matches[1]) } } }
    @{ Name = 'CPU load'; Better = 'Lower'; Get = { param($r)
        if ((Get-Detail $r 'CPU') -match '^(\d+)% load') { ConvertTo-MetricValue ('{0}%' -f $Matches[1]) ([int]$Matches[1]) } } }
    @{ Name = 'Free space'; Better = 'Higher'; Get = { param($r)
        if ((Get-Detail $r 'Free space') -match 'has (\d[\d.,]*) GB free \((\d+)%\)') { ConvertTo-MetricValue ('{0} GB ({1}%)' -f $Matches[1], $Matches[2]) (ConvertTo-Number $Matches[1]) } } }
    @{ Name = 'Pending reboot'; Better = 'Lower'; Get = { param($r)
        $d = Get-Detail $r 'Pending reboot'; if ($d -eq 'None') { ConvertTo-MetricValue 'None' 0 } elseif ($d) { ConvertTo-MetricValue 'Yes' 1 } } }
    @{ Name = 'Join type'; Better = ''; Get = { param($r) $d = Get-Detail $r 'Join type'; if ($d) { ConvertTo-MetricValue $d $null } } }
    @{ Name = 'Intune enrolment'; Better = ''; Get = { param($r) $d = Get-Detail $r 'MDM enrolment'; if ($d) { ConvertTo-MetricValue $d $null } } }
)

function Get-Trend {
    param($First, $Last, [string] $Better)
    if ($null -eq $First -or $null -eq $Last) { return '' }
    if ($Better -in 'Lower', 'Higher' -and $null -ne $First.Value -and $null -ne $Last.Value) {
        if ($First.Value -eq $Last.Value) { return 'same' }
        if (($Better -eq 'Lower') -eq ($Last.Value -lt $First.Value)) { return 'better' }
        return 'worse'
    }
    if ($First.Text -ne $Last.Text) { 'changed' } else { 'same' }
}

function Get-MetricTable {
    param([object[]] $List, [object[]] $Metrics)
    $shown = Select-Shown $List
    foreach ($m in $Metrics) {
        $cells = @(foreach ($r in $shown) { $v = & $m.Get $r; if ($v) { $v.Text } else { '' } })
        if (-not @($cells | Where-Object { $_ }).Count) { continue }
        $first = & $m.Get $List[0]; $last = & $m.Get $List[-1]
        [pscustomobject]@{ Name = $m.Name; Cells = $cells; Trend = $(if ($List.Count -ge 2) { Get-Trend $first $last $m.Better } else { '' }); First = $first; Last = $last }
    }
}

$PerfTable   = @(if ($Perf.Count)   { Get-MetricTable $Perf $PerfMetrics })
$TriageTable = @(if ($Triage.Count) { Get-MetricTable $Triage $TriageMetrics })
function Get-Row { param([object[]] $Table, [string] $Name) @($Table | Where-Object Name -eq $Name) | Select-Object -First 1 }
function Get-MetricValue {
    param($Report, [string] $Name)
    $m = @($PerfMetrics + $TriageMetrics | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
    if ($m -and $Report) { & $m.Get $Report }
}

# ------------------------------------------------------------------------------------------------
#  Builds and restarts across every toolkit run
# ------------------------------------------------------------------------------------------------
$Builds = @($Toolkit | Where-Object Build | ForEach-Object { $_.Build } | Select-Object -Unique)
$BuildChanged = $Builds.Count -gt 1
$BuildFirst = if ($Builds.Count) { $Builds[0] } else { $null }
$BuildLast  = if ($Builds.Count) { $Builds[-1] } else { $null }
$BuildChangeTime = $null
for ($i = 1; $i -lt $Toolkit.Count; $i++) {
    if ($Toolkit[$i].Build -and $Toolkit[$i - 1].Build -and $Toolkit[$i].Build -ne $Toolkit[$i - 1].Build) { $BuildChangeTime = $Toolkit[$i - 1].When; break }
}
$Boots = @($Toolkit | ForEach-Object { if ((Get-Detail $_ 'Uptime') -match '\((\d{4}-\d{2}-\d{2} \d{2}:\d{2})\)') { $Matches[1] } } | Select-Object -Unique)
$Restarted = $Boots.Count -gt 1

# ------------------------------------------------------------------------------------------------
#  Worth knowing: what only shows when the reports are read together
# ------------------------------------------------------------------------------------------------
$Notes = New-Object System.Collections.Generic.List[object]
function Add-Note { param([int] $Rank, [string] $Title, [string] $Text) $Notes.Add([pscustomobject]@{ Rank = $Rank; Title = $Title; Text = $Text }) }
function Format-AppName { param([string] $Name) $Name -replace '_[0-9A-Fa-f]{32}$', '' }

$RmmRx = [ordered]@{ 'CentraStage|Datto' = 'Datto RMM'; 'Ninja' = 'NinjaOne'; 'N-able|NAble|SolarWinds MSP' = 'N-able'; 'Kaseya' = 'Kaseya'
    'Atera' = 'Atera'; 'Syncro' = 'Syncro'; 'LTSvc|LabTech|ConnectWise Automate' = 'ConnectWise Automate'; 'Action1' = 'Action1'; 'Pulseway' = 'Pulseway' }
$AllApps = @($Perf | ForEach-Object { $_.StartupApps })
$LastApps = if ($LastPerf) { @($LastPerf.StartupApps | Where-Object On) } else { @() }

if ($Perf.Count -ge 2) {
    $p1 = $Perf[0]; $p2 = $Perf[-1]
    $cpu = Get-Row $PerfTable 'CPU average'

    # Runs measured under load within an hour of start-up, when Windows does its own background work
    $busyAfterBoot = @{}
    foreach ($r in $Perf) {
        $c = Get-MetricValue $r 'CPU average'; $dk = Get-MetricValue $r 'Disk busy'
        if ((Get-Detail $r 'Uptime') -match '^0d 0h' -and (($c -and $c.Value -ge 50) -or ($dk -and $dk.Value -ge 50))) { $busyAfterBoot[$r.Name] = $true }
    }
    $bootLine = 'It also ran within an hour of start-up, when Windows does its own background work (updates, indexing, scans).'

    # A first run caught installing updates
    $updTxt = @($p1.Findings | Where-Object { $_.Check -eq 'Windows Update' -or ($_.Area -eq 'Apps' -and $_.Detail -match 'TiWorker|TrustedInstaller|MoUsoCoreWorker') })
    if ($updTxt.Count -and -not (Get-Finding $p2 'Windows Update')) {
        $extra = @()
        if (@($p1.Findings | Where-Object { $_.Area -eq 'Apps' -and $_.Detail -match 'MicrosoftEdgeUpdate' }).Count) { $extra += 'Edge was updating itself as well.' }
        if ($busyAfterBoot.ContainsKey($p1.Name)) { $extra += $bootLine; $busyAfterBoot.Remove($p1.Name) }
        Add-Note 40 'The first check ran mid-update' ((@("Windows was installing updates (TiWorker) during the first check on $($p1.Label), so most of its CPU and disk load came from the install, not a lasting fault. The drop since is mostly the update finishing.") + $extra) -join ' ')
    }
    foreach ($r in @($Perf | Where-Object { $busyAfterBoot.ContainsKey($_.Name) })) {
        Add-Note 45 "Busy just after start-up ($($r.Label))" "That run was under load. $bootLine"
    }
    # An idle after-run
    if ($cpu -and $cpu.First -and $cpu.Last -and $cpu.First.Value -ge 50 -and $cpu.Last.Value -lt 15) {
        Add-Note 50 'Not like for like' ("The latest check ran with the PC nearly idle ($($cpu.Last.Value)% average CPU), the first under load ($($cpu.First.Value)%). Run Performance check again while the user works to compare like for like.")
    }
    # Start-up times
    $sign = Get-Row $PerfTable 'Power-on to sign-in screen'; $after = Get-Row $PerfTable 'Sign-in to settled'
    $added = @($p2.StartupApps | Where-Object { $_.On -and -not @($p1.StartupApps | Where-Object { $_.On } | Where-Object Name -eq $_.Name).Count })
    if ($after -and $after.Trend -eq 'worse') {
        $why = if ($added.Count) { ' New startup apps (below) add to it.' } else { '' }
        $lead = if ($sign -and $sign.Trend -eq 'better') { "Power-on to the sign-in screen got faster ($($sign.First.Text) $Arrow $($sign.Last.Text)), but sign-in to settled got slower" } else { 'Sign-in to settled got slower' }
        Add-Note 60 'Sign-in got slower' ("$lead ($($after.First.Text) $Arrow $($after.Last.Text)). The first sign-in after updates runs set-up tasks.$why Measure again after a couple of restarts.")
    }
    # Slowing start-up entries left over from update boots
    $slow = Get-Detail $p2 'Slowing start-up'
    if ($BuildChanged -and $slow -match 'Windows Modules Installer|TiWorker|TrustedInstaller|Antimalware|Defender') {
        Add-Note 80 'Start-up slowed by updates' 'Windows Modules Installer and Defender in "Slowing start-up" come from the start-ups that installed updates. They drop out of the 7-day look-back on their own; check again next week before acting on them.'
    }
    # Free space after updates
    $free = Get-Row $PerfTable 'Free space'
    if ($free -and $free.First -and $free.Last -and ($free.First.Value - $free.Last.Value) -ge 2 -and $BuildChanged) {
        Add-Note 85 'Space used by updates' ('C: has {0:N1} GB less free than at the first check, about what a new build and the old update files it replaced take. Repair > Windows repair checks ends with a component clean-up that gets some of it back.' -f ($free.First.Value - $free.Last.Value))
    }
    # New startup apps
    if ($added.Count) {
        $txt = "New at sign-in since the first check: $(($added | ForEach-Object { Format-AppName $_.Name }) -join ', ')."
        if (@($added | Where-Object { $_.Name -match 'EdgeAutoLaunch' -or $_.Command -match 'msedge\.exe.*--no-startup-window' }).Count) {
            $txt += " MicrosoftEdgeAutoLaunch is Edge's Startup boost, which keeps Edge loaded in the background"
            $txt += $(if ($LastPerf.RamGB -and $LastPerf.RamGB -le 8) { "; on $($LastPerf.RamGB) GB, turn it off in Edge > Settings > System and performance." } else { '; turn it off in Edge > Settings > System and performance if memory is tight.' })
        }
        Add-Note 65 'New startup apps' $txt
    }
}

if ($LastTriage) {
    # Quick triage older than the work: its update / shutdown / crash / battery checks need a re-run
    $lastUpd = Get-Finding $LastTriage 'Last update'
    $updatePredates = $lastUpd -and (Test-Bad $lastUpd.Status) -and $BuildChangeTime -and $LastTriage.When -le $BuildChangeTime
    $triageStale = $LastPerf -and $Perf.Count -ge 2 -and @($Perf | Where-Object { $_.When -gt $LastTriage.When }).Count -gt 0
    if ($updatePredates -or $triageStale) {
        $txt = "Quick triage last ran $($LastTriage.Label)"
        $txt += $(if ($LastPerf -and $LastPerf.When -gt $LastTriage.When) { ", before the latest performance check ($($LastPerf.Label))." } else { '.' })
        if ($updatePredates) { $txt += " Its last-update warning came before Windows moved to build $BuildLast." }
        $txt += ' Run it again so updates, shutdowns, crashes and battery are checked after the work too.'
        Add-Note 30 'Run Quick triage again' $txt
    }

    # No battery and unexpected shutdowns
    $noBat = @($LastTriage.Notes | Where-Object { $_ -match 'No battery' }).Count -gt 0
    $shut = Get-Finding $LastTriage 'Unexpected shutdowns'
    if ($noBat -and $shut -and (Test-Bad $shut.Status)) {
        $speed = @($Perf | Sort-Object When -Descending | ForEach-Object { Get-Detail $_ 'CPU speed' } | Where-Object { $_ -match '^Ran at \d+%' }) | Select-Object -First 1
        $cpuNote = if ($speed -match '^Ran at (\d+)%') { " It wasn't holding the CPU back when measured (it ran at $($Matches[1])% of its normal speed), but some laptops slow the CPU right down without a healthy battery." } else { '' }
        $count = if ($shut.Detail -match '^(\d+) in (\d+) days') { "$($Matches[1]) unexpected shutdowns in $($Matches[2]) days" } else { 'unexpected shutdowns' }
        Add-Note 10 'No battery and unexpected shutdowns' ("Quick triage found $count, and Windows reports no battery. If this is a laptop, the battery is dead, disconnected or not detected, so any knock of the charger or power blip switches it straight off. Check the battery in the BIOS or the maker's power app.$cpuNote")
    }
    # Updates nothing manages
    $upd = Get-Finding $LastTriage 'Last update'; $join = Get-Finding $LastTriage 'Join type'; $mdm = Get-Finding $LastTriage 'MDM enrolment'
    if ($upd -and (Test-Bad $upd.Status) -and (($join -and (Test-Bad $join.Status)) -or ($mdm -and (Test-Bad $mdm.Status)))) {
        $rmm = $null
        foreach ($k in $RmmRx.Keys) { $hit = @($AllApps | Where-Object { "$($_.Name) $($_.Command)" -match $k }) | Select-Object -First 1; if ($hit) { $rmm = "$($RmmRx[$k]) ($($hit.Name))"; break } }
        $behind = if ($upd.Detail -match 'Installed (\d+) days ago') { "$($Matches[1]) days" } else { 'a long time' }
        $txt = if ($rmm) { "It isn't in Intune, so its Windows updates depend on $rmm, which is installed. It still went $behind without an update, so check that the RMM's patch policy covers this device, or it will fall behind again." }
               else { "It isn't in Intune and no RMM agent shows in its startup apps, so nothing may be managing its updates. It went $behind without one." }
        Add-Note 20 'Who patches it?' $txt
    }
    # Known crashers
    $crash = Get-Detail $LastTriage 'App crashes'
    if ($crash -match '\bLMS\.exe') {
        Add-Note 90 'LMS.exe crashing' "LMS.exe is part of Intel's management engine software. Its firmware and driver usually come with the BIOS and chipset updates: Build > OEM drivers + BIOS."
    }
}

# Classic Teams still starting
$classic = @($LastApps | Where-Object { $_.Name -match 'com\.squirrel\.Teams|TeamsMachineInstaller' -or $_.Command -match 'Microsoft\\Teams\\Update\.exe|Teams Installer' })
if ($classic.Count) {
    $alongside = if (@($LastApps | Where-Object Name -match '^MSTeams$').Count) { ' alongside new Teams' } else { '' }
    Add-Note 70 'Classic Teams still starts' ("$(($classic | ForEach-Object { $_.Name }) -join ' and ') still start at sign-in$alongside. Classic Teams is retired: uninstall it and the Teams Machine-Wide Installer to save memory and start-up time.")
}

$Notes = @($Notes | Sort-Object Rank, Title)

# ------------------------------------------------------------------------------------------------
#  Still to do: latest WARN/FAIL from each report type, skipping triage items a newer check cleared
# ------------------------------------------------------------------------------------------------
$Equivalent = @{ 'Pending reboot' = 'Pending restart'; 'Memory' = 'Memory'; 'CPU' = 'CPU'; 'Free space' = 'Free space'; 'Uptime' = 'Uptime' }
$Todo = New-Object System.Collections.Generic.List[object]
$seenChecks = @{}
foreach ($src in @($LastPerf, $LastTriage)) {
    if (-not $src) { continue }
    foreach ($f in @($src.Findings | Where-Object { Test-Bad $_.Status })) {
        $detail = $f.Detail
        if ($src.Type -eq 'Triage' -and $LastPerf -and $LastPerf.When -gt $src.When -and $Equivalent.ContainsKey($f.Check)) {
            $newer = Get-Finding $LastPerf $Equivalent[$f.Check]
            if ($newer -and -not (Test-Bad $newer.Status)) { continue }
        }
        if ($f.Check -eq 'Last update' -and $BuildChanged -and $BuildChangeTime -and $src.When -le $BuildChangeTime) {
            $detail += " - Windows has been updated since ($BuildFirst $Arrow $BuildLast); run Quick triage again to confirm"
        }
        $k = $f.Check -replace 'Pending reboot', 'Pending restart'
        if ($seenChecks.ContainsKey($k)) { continue }
        $seenChecks[$k] = $true
        $Todo.Add([pscustomobject]@{ Status = $f.Status; Area = $f.Area; Check = $f.Check; Detail = $detail; Fix = $f.Fix; From = $src.Type; When = $src.Label })
    }
}
$Todo = @($Todo | Sort-Object @{ e = { if ($_.Status -eq 'FAIL') { 0 } else { 1 } } }, @{ e = { Get-AreaRank $_.Area } })

# ------------------------------------------------------------------------------------------------
#  Wi-Fi and battery notes
# ------------------------------------------------------------------------------------------------
$PublicDns = @('8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9', '149.112.112.112', '208.67.222.222', '208.67.220.220')
$WifiNotes = New-Object System.Collections.Generic.List[object]
$LastWifi = if ($Wifi.Count) { $Wifi[-1] } else { $null }
if ($LastWifi) {
    $w = $LastWifi
    function Add-WifiNote { param([string] $Status, [string] $Text) $WifiNotes.Add([pscustomobject]@{ Status = $Status; Text = $Text }) }
    $span = if ($w.Duration) { "covers $($w.Duration) up to $($w.Label)" } else { "from $($w.Label)" }
    if ($w.LocationOff) {
        Add-WifiNote 'WARN' "Location services is off, so Windows left out the network name, signal and access point details. Turn Location on (Settings > Privacy & security > Location), run Quick triage -Reports again, then turn it back off if policy wants it off."
    }
    $sessions = [int]$w.Successes + [int]$w.Failures + [int]$w.Warnings
    if ($sessions) {
        $st = if ([int]$w.Failures -gt 0) { 'WARN' } else { 'INFO' }
        Add-WifiNote $st ('The report {0}: {1} Wi-Fi sessions, {2} ended normally, {3} failed, {4} with warnings.' -f $span, $sessions, [int]$w.Successes, [int]$w.Failures, [int]$w.Warnings)
    }
    else { Add-WifiNote 'INFO' "The report $span and logged no Wi-Fi sessions, so it can't show drops. If the complaint is about Wi-Fi, reproduce it, then save the report again." }
    if ($w.Reasons.Count) { Add-WifiNote 'INFO' "Disconnect reasons: $($w.Reasons -join '; ')." }
    if ($w.FailedConnects) { Add-WifiNote 'WARN' "$($w.FailedConnects) failed connection attempt(s) in the event list." }
    if ($w.Errors) { Add-WifiNote 'WARN' "$($w.Errors) event(s) marked as errors in the session list." }
    if ($w.Ssid) {
        $sig = if ($null -ne $w.Signal) { ", signal $($w.Signal)%" } else { '' }
        $chn = if ($w.Channel) { ", channel $($w.Channel)" } else { '' }
        $rad = if ($w.Radio) { " ($($w.Radio))" } else { '' }
        Add-WifiNote $(if ($null -ne $w.Signal -and $w.Signal -lt 60) { 'WARN' } else { 'INFO' }) "Connected to $($w.Ssid)$sig$chn$rad."
    }
    if ($w.Adapter) {
        $age = if ($w.DriverDate) { ($now - $w.DriverDate).TotalDays / 365.25 } else { $null }
        $dt = if ($w.DriverDate) { ' from ' + $w.DriverDate.ToString('MMM yyyy', $Inv) } else { '' }
        if ($null -ne $age -and $age -gt 2) { Add-WifiNote 'WARN' ("{0} driver {1}{2}, over {3:N0} years old. Update it: Build > OEM drivers + BIOS." -f $w.Adapter, $w.DriverVersion, $dt, [math]::Floor($age)) }
        else { Add-WifiNote 'INFO' "$($w.Adapter) driver $($w.DriverVersion)$dt." }
    }
    foreach ($d in $w.WifiUpDelays) {
        if ($d.Minutes -ge 2) { Add-WifiNote 'WARN' ("At the start-up on {0}, the Wi-Fi adapter came up {1:N0} minutes after Windows started. That points at a slow start-up, not the Wi-Fi itself." -f (Format-When $d.Boot), $d.Minutes) }
    }
    if ($w.Dns.Count) {
        $pub = @($w.Dns | Where-Object { $PublicDns -contains $_ })
        if ($pub.Count -eq $w.Dns.Count) { Add-WifiNote 'INFO' "DNS: $($w.Dns -join ', '), all public resolvers. Fine if intended, but nothing internal (file servers, printers, on-prem apps) will resolve by name." }
        else { Add-WifiNote 'INFO' "DNS: $($w.Dns -join ', ')." }
    }
    if ($w.Profiles.Count) {
        $txt = "Saved networks: $($w.Profiles -join ', ')."
        if ($w.Profiles.Count -gt 1) { $txt += ' Check each one is meant to be on this PC; it can join any of them by itself.' }
        Add-WifiNote 'INFO' $txt
    }
}
$LastBattery = if ($Battery.Count) { $Battery[-1] } else { $null }
$bn = $null
if (-not $LastBattery -and $LastTriage) {
    $bn = @($LastTriage.Notes | Where-Object { $_ -match '^Battery report' }) | Select-Object -First 1
}

# ------------------------------------------------------------------------------------------------
#  The write-up
# ------------------------------------------------------------------------------------------------
function Get-NameList { param([object[]] $List, [int] $Max = 6)
    $n = @($List | ForEach-Object { $_.Check } | Select-Object -Unique)
    $more = if ($n.Count -gt $Max) { " (+$($n.Count - $Max) more)" } else { '' }
    (($n | Select-Object -First $Max) -join ', ') + $more
}

$Lead = New-Object System.Collections.Generic.List[string]
foreach ($set in @(@{ Name = 'performance check'; List = $Perf }, @{ Name = 'quick triage'; List = $Triage })) {
    $l = $set.List
    if (-not $l.Count) { continue }
    if ($l.Count -eq 1) {
        $Lead.Add(('One {0} ({1}): {2} fail, {3} warn.' -f $set.Name, $l[0].Label, $l[0].Fails, $l[0].Warns))
    }
    else {
        $Lead.Add(('{0} {1}s from {2} to {3}: fails {4} {6} {5}, warnings {7} {6} {8}.' -f $l.Count, $set.Name, $l[0].Label, $l[-1].Label, $l[0].Fails, $l[-1].Fails, $Arrow, $l[0].Warns, $l[-1].Warns))
    }
}
if ($BuildChanged) { $Lead.Add("Windows went from build $BuildFirst to $BuildLast.") }
if ($Restarted) { $Lead.Add("Restarted in between (last boot $(($Boots | ForEach-Object { Format-When ([datetime]::ParseExact($_, 'yyyy-MM-dd HH:mm', $Inv)) }) -join " $Arrow ")).") }

$fixed = @($Moves | Where-Object { $_.Move -in 'Fixed', 'Cleared' })
$worse = @($Moves | Where-Object { $_.Move -in 'Worse', 'New' })
$parts = @()
foreach ($set in @(@{ N = 'performance'; L = $Perf }, @{ N = 'triage'; L = $Triage })) {
    if ($set.L.Count -ge 2) { $parts += '{0} {1} fail {2} warn -> {3} fail {4} warn' -f $set.N, $set.L[0].Fails, $set.L[0].Warns, $set.L[-1].Fails, $set.L[-1].Warns }
}
if ($fixed.Count) { $parts += 'fixed: ' + (Get-NameList $fixed 5) }
if ($worse.Count) { $parts += 'worse/new: ' + (Get-NameList $worse 3) }
if ($Todo.Count)  { $parts += 'still: ' + (Get-NameList $Todo 5) }
if (-not $parts.Count) { $parts += 'nothing to compare yet (one run of each check)' }
$Summary = '{0} report - {1}' -f $PcName, ($parts -join '; ')

# ------------------------------------------------------------------------------------------------
#  Console
# ------------------------------------------------------------------------------------------------
if ($Quiet) { Write-Output $Summary }
else {
    Write-Host ''
    Write-Host ("== {0} report - before and after - {1} " -f $PcName, $now.ToString('yyyy-MM-dd HH:mm')).PadRight(78, '=') -ForegroundColor Cyan
    Write-Host ("   {0} report(s): {1}" -f $Runs.Count, (($Runs | Group-Object Type | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }) -join ', ')) -ForegroundColor Gray
    Write-Host ''
    foreach ($l in $Lead) { Write-Host "  $l" }
    foreach ($mv in $MoveOrder) {
        $list = @($Moves | Where-Object Move -eq $mv)
        if (-not $list.Count -or $mv -eq 'Still') { continue }
        $c = if ($mv -in 'Fixed', 'Cleared', 'Better') { 'Green' } else { 'Red' }
        Write-Host ''
        Write-Host ("  {0} ({1})" -f $mv.ToUpper(), $list.Count) -ForegroundColor $c
        foreach ($x in $list) {
            $after = if ($x.After) { $x.After } else { 'no longer reported' }
            Write-Host ('   {0,-22} {1} {2} {3}' -f $x.Check, $(if ($x.Before) { $x.Before } else { '(not reported)' }), $Arrow, $after) -ForegroundColor Gray
        }
    }
    foreach ($t in @(@{ N = 'PERFORMANCE'; T = $PerfTable; L = $Perf }, @{ N = 'QUICK TRIAGE'; T = $TriageTable; L = $Triage })) {
        if (-not $t.T.Count -or $t.L.Count -lt 2) { continue }
        Write-Host ''
        Write-Host ("  {0}, FIRST {1} LATEST" -f $t.N, $Arrow) -ForegroundColor Cyan
        foreach ($r in $t.T) {
            $c = switch ($r.Trend) { 'better' { 'Green' } 'worse' { 'Red' } default { 'Gray' } }
            Write-Host ('   {0,-27} {1} {2} {3}  {4}' -f $r.Name, $r.Cells[0], $Arrow, $r.Cells[-1], $r.Trend) -ForegroundColor $c
        }
    }
    if ($Notes.Count) {
        Write-Host ''
        Write-Host ("  WORTH KNOWING ({0})" -f $Notes.Count) -ForegroundColor Cyan
        foreach ($n in $Notes) {
            $sep = if ($n.Title -match '[?.!]$') { ' ' } else { ': ' }
            Write-Host "   $($n.Title)$sep" -NoNewline -ForegroundColor Yellow; Write-Host $n.Text
        }
    }
    Write-Host ''
    if ($Todo.Count) {
        Write-Host ("  STILL NEEDS ATTENTION ({0})" -f $Todo.Count) -ForegroundColor Yellow
        foreach ($f in $Todo) {
            Write-Host ('   [{0}] ' -f $f.Status) -ForegroundColor $(if ($f.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }) -NoNewline
            Write-Host ('{0}: {1}' -f $f.Check, $f.Detail)
            if ($f.Fix) { Write-Host ('{0,9}-> {1}' -f '', $f.Fix) -ForegroundColor DarkGray }
        }
    }
    else { Write-Host '  NOTHING STILL NEEDS ATTENTION' -ForegroundColor Green }
    if ($WifiNotes.Count) {
        Write-Host ''
        Write-Host '  WI-FI' -ForegroundColor Cyan
        foreach ($n in $WifiNotes) { Write-Host "   $($n.Text)" -ForegroundColor $(if ($n.Status -eq 'WARN') { 'Yellow' } else { 'Gray' }) }
    }
    Write-Host ''
    Write-Host "  Summary: $Summary" -ForegroundColor Cyan
}

# ------------------------------------------------------------------------------------------------
#  HTML
# ------------------------------------------------------------------------------------------------
$enc = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) -replace ' -&gt; ', ' &rarr; ' }
$st  = { param($s) if ($s) { "<span class=""s $($s.ToLower())"">$s</span>" } else { '<span class="s none">-</span>' } }

$latestHead = @($Toolkit | Where-Object Headline | Select-Object -Last 1)
$headline = if ($latestHead.Count) { $latestHead[0].Headline } else { $PcName }
$span = '{0} to {1}' -f $Runs[0].Label, $Runs[-1].Label
try { $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $who = [string]$env:USERNAME }
$subBits = @($headline, "before and after: reports $span", ("written $($now.ToString('yyyy-MM-dd HH:mm'))" + $(if ($who) { " by $who" } else { '' })))
if ($Ticket) { $subBits += "ticket $Ticket" }

$leadHtml = '<p>' + (($Lead | ForEach-Object { & $enc $_ }) -join ' ') + '</p>'
$moveHtml = ''
foreach ($mv in $MoveOrder) {
    $list = @($Moves | Where-Object Move -eq $mv)
    if (-not $list.Count) { continue }
    $moveLabel = switch ($mv) { 'Fixed' { 'Fixed' } 'Cleared' { 'No longer reported' } 'Better' { 'Better, not fixed' } 'Worse' { 'Worse' } 'New' { 'New problems' } 'Still' { 'Unchanged problems' } }
    $cls = switch ($mv) { { $_ -in 'Fixed', 'Cleared', 'Better' } { 'good' } { $_ -in 'Worse', 'New' } { 'bad' } default { 'same' } }
    $rows = foreach ($x in $list) {
        $type = if ($x.Type -eq 'Triage') { 'Quick triage' } else { 'Performance' }
        "<tr><td>$(& $enc $x.Check)<div class=""fix"">$type</div></td><td>$(& $st $x.From) $(& $enc $x.Before)</td><td>$(if ($x.After) { "$(& $st $x.To) $(& $enc $x.After)" } else { '<span class=""fix"">no longer reported</span>' })</td></tr>"
    }
    $moveHtml += "<h3 class=""$cls"">$moveLabel ($($list.Count))</h3><table class=""moves""><tr><th>Check</th><th>First</th><th>Latest</th></tr>$($rows -join '')</table>"
}

function ConvertTo-MetricHtml {
    param([object[]] $Table, [object[]] $List, [string] $Title)
    if (-not $Table.Count) { return '' }
    $shown = Select-Shown $List
    $hidden = $List.Count - $shown.Count
    $head = ($shown | ForEach-Object { "<th>$(& $enc $_.Label)</th>" }) -join ''
    $trendHead = if ($List.Count -ge 2) { '<th>First to latest</th>' } else { '' }
    $rows = foreach ($r in $Table) {
        $cells = for ($i = 0; $i -lt $r.Cells.Count; $i++) {
            $b = if ($i -eq $r.Cells.Count - 1 -and $List.Count -ge 2) { ' class="last"' } else { '' }
            "<td$b>$(& $enc $r.Cells[$i])</td>"
        }
        $trend = if ($List.Count -ge 2) { "<td class=""t $($r.Trend)"">$(& $enc $r.Trend)</td>" } else { '' }
        "<tr><td>$(& $enc $r.Name)</td>$($cells -join '')$trend</tr>"
    }
    $note = if ($hidden -gt 0) { "<p class=""fix"">$hidden run(s) in between not shown.</p>" } else { '' }
    "<h2>$Title</h2><table class=""metrics""><tr><th></th>$head$trendHead</tr>$($rows -join '')</table>$note"
}

function ConvertTo-CheckHtml {
    param([object[]] $List, [string] $Title)
    if (-not $List.Count) { return '' }
    $shown = Select-Shown $List
    $keys = New-Object System.Collections.Generic.List[string]
    $info = @{}
    foreach ($r in $shown) { foreach ($f in $r.Findings) { if (-not $info.ContainsKey($f.Key)) { $keys.Add($f.Key); $info[$f.Key] = $f } } }
    $head = ($shown | ForEach-Object { "<th>$(& $enc $_.Label)</th>" }) -join ''
    $order = @($keys | Sort-Object @{ e = { Get-AreaRank $info[$_].Area } }, @{ e = { $keys.IndexOf($_) } })
    $rows = foreach ($k in $order) {
        $cells = foreach ($r in $shown) { $f = @($r.Findings | Where-Object Key -eq $k) | Select-Object -First 1; "<td>$(& $st $(if ($f) { $f.Status }))</td>" }
        $latest = @($shown[-1].Findings | Where-Object Key -eq $k) | Select-Object -First 1
        "<tr><td>$(& $enc $info[$k].Area)</td><td>$(& $enc $info[$k].Check)</td>$($cells -join '')<td>$(if ($latest) { & $enc $latest.Detail })</td></tr>"
    }
    "<details><summary>$Title ($($keys.Count) checks)</summary><table class=""checks""><tr><th>Area</th><th>Check</th>$head<th>Latest detail</th></tr>$($rows -join '')</table></details>"
}

$notesHtml = if ($Notes.Count) {
    '<h2>Worth knowing</h2><ul class="notes">' + (($Notes | ForEach-Object {
        $t = if ($_.Title -match '[?.!]$') { $_.Title } else { "$($_.Title)." }
        "<li><b>$(& $enc $t)</b> $(& $enc $_.Text)</li>" }) -join '') + '</ul>'
} else { '' }
$todoHtml = if ($Todo.Count) {
    $rows = foreach ($f in $Todo) {
        $fx = if ($f.Fix) { "<div class=""fix"">&rarr; $(& $enc $f.Fix)</div>" } else { '' }
        $src = if ($f.From -eq 'Triage') { 'Quick triage' } else { 'Performance' }
        "<tr class=""$($f.Status.ToLower())""><td class=""st"">$($f.Status)</td><td>$(& $enc $f.Check)<div class=""fix"">$src, $(& $enc $f.When)</div></td><td>$(& $enc $f.Detail)$fx</td></tr>"
    }
    "<h2>Still needs attention ($($Todo.Count))</h2><table>$($rows -join '')</table>"
} else { '<h2>Still needs attention</h2><p class="ok">Nothing in the latest reports.</p>' }
$wifiHtml = if ($WifiNotes.Count) {
    "<h2>Wi-Fi ($(& $enc $LastWifi.Label))</h2><ul class=""notes"">" + (($WifiNotes | ForEach-Object { "<li class=""$($_.Status.ToLower())"">$(& $enc $_.Text)</li>" }) -join '') + '</ul>'
} else { '' }
$batHtml = if ($LastBattery) {
    $bits = @()
    if ($LastBattery.HealthPercent) { $bits += 'holds {0}% of its design capacity ({1:N0} of {2:N0} mWh)' -f $LastBattery.HealthPercent, $LastBattery.FullmWh, $LastBattery.DesignmWh }
    if ($null -ne $LastBattery.Cycles) { $bits += '{0:N0} charge cycles' -f $LastBattery.Cycles }
    $txt = if ($bits.Count) { 'The battery ' + ($bits -join ', ') + '.' } else { 'Saved, but the capacity figures could not be read from it; open the report itself.' }
    if ($LastBattery.HealthPercent -and $LastBattery.HealthPercent -lt 60) { $txt += ' Worn: replacement time if battery life is the complaint.' }
    "<h2>Battery ($(& $enc $LastBattery.Label))</h2><p>$(& $enc $txt)</p>"
} elseif ($bn) { "<h2>Battery</h2><p>$(& $enc $bn)</p>" } else { '' }

$usedHtml = '<h2>Reports used</h2><ul>' + (($Runs | ForEach-Object {
    $t = switch ($_.Type) { 'Performance' { 'Performance check' } 'Triage' { 'Quick triage' } 'WiFi' { 'Wi-Fi report' } 'Battery' { 'Battery report' } }
    $sum = if ($_.PSObject.Properties['Summary'] -and $_.Summary) { " - <span class=""fix"">$(& $enc $_.Summary)</span>" } else { '' }
    "<li>$(& $enc $_.Label): <a href=""$(& $enc $_.Name)"">$t</a>$sum</li>"
}) -join '') + '</ul>'

$titleText = "$PcName report"
$page = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>$(& $enc $titleText)</title>
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; max-width: 1100px; }
 h1 { font-size: 20px; margin-bottom: 2px; } .sub { color: #656d76; margin-bottom: 14px; }
 h2 { font-size: 15px; margin: 22px 0 6px; border-bottom: 2px solid #0969da; padding-bottom: 3px; }
 h3 { font-size: 13px; margin: 14px 0 4px; } h3.good { color: #1a7f37; } h3.bad { color: #cf222e; } h3.same { color: #9a6700; }
 .summary { background: #f6f8fa; border: 1px solid #d0d7de; padding: 8px 12px; font-family: Consolas, monospace; font-size: 13px; }
 table { border-collapse: collapse; font-size: 13px; width: 100%; }
 td, th { border-bottom: 1px solid #d0d7de; padding: 5px 8px; vertical-align: top; text-align: left; }
 th { color: #656d76; font-weight: 600; } table.metrics td.last { font-weight: 600; }
 table.moves td:first-child { width: 22%; } table.moves td { width: 39%; }
 td.st { font-weight: 600; width: 44px; } tr.fail td.st { color: #cf222e; } tr.warn td.st { color: #9a6700; }
 .s { font-weight: 600; font-size: 11px; } .s.fail { color: #cf222e; } .s.warn { color: #9a6700; } .s.pass { color: #1a7f37; } .s.info, .s.none { color: #656d76; }
 td.t.better { color: #1a7f37; font-weight: 600; } td.t.worse { color: #cf222e; font-weight: 600; } td.t.changed { color: #0969da; } td.t.same { color: #656d76; }
 ul.notes li { margin-bottom: 6px; } ul.notes li.warn { color: #7d4e00; }
 .fix { color: #656d76; margin-top: 3px; font-size: 12px; } .ok { color: #1a7f37; font-weight: 600; }
 details summary { cursor: pointer; color: #0969da; margin: 8px 0; }
 @media print { details > summary { list-style: none; } }
</style>
<script>window.addEventListener('beforeprint', function () { document.querySelectorAll('details').forEach(function (d) { d.open = true; }); });</script>
</head><body>
<h1>$(& $enc $PcName) report</h1>
<div class="sub">$((($subBits | ForEach-Object { & $enc $_ }) -join ' &middot; '))</div>
<div class="summary">$(& $enc $Summary)</div>
<h2>What changed</h2>$leadHtml$moveHtml
$(ConvertTo-MetricHtml $PerfTable $Perf 'Performance check: the numbers')
$(ConvertTo-MetricHtml $TriageTable $Triage 'Quick triage: the numbers')
$notesHtml
$todoHtml
$wifiHtml
$batHtml
<h2>Every check, run by run</h2>
$(ConvertTo-CheckHtml $Perf 'Performance check')
$(ConvertTo-CheckHtml $Triage 'Quick triage')
$usedHtml
<p class="fix">Built from the reports above by the toolkit's own rules; nothing was sent anywhere.</p>
</body></html>
"@

$outFolder = if ($Path -and -not $PSBoundParameters.ContainsKey('ReportFolder')) { Split-Path $metas[0].File -Parent } else { $ReportFolder }
if (-not (Test-Path -LiteralPath $outFolder)) { New-Item -ItemType Directory -Path $outFolder -Force | Out-Null }
$OutFile = Join-Path $outFolder ('Report_{0}_{1:yyyyMMdd-HHmm}.html' -f $PcName, $now)
$page | Set-Content -LiteralPath $OutFile -Encoding UTF8
if (-not $Quiet) { Write-Host "  Report:  $OutFile" -ForegroundColor Cyan }
if (-not $NoOpen -and [Environment]::UserInteractive -and -not $PSSenderInfo -and $env:OS -eq 'Windows_NT') {
    try { Invoke-Item -LiteralPath $OutFile } catch { Write-Verbose 'Could not open the report' }
}

if ($PassThru) {
    [pscustomobject]@{
        Summary = $Summary; File = $OutFile; ComputerName = $PcName; Lead = $Lead.ToArray()
        Runs = @($Runs | ForEach-Object { [pscustomobject]@{ Type = $_.Type; When = $_.When; Name = $_.Name } })
        Moves = $Moves; Performance = $PerfTable; Triage = $TriageTable; Notes = $Notes; Todo = $Todo
        WiFi = $WifiNotes.ToArray(); Battery = $LastBattery
    }
}
exit 0
