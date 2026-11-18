<#
.SYNOPSIS
    Why isn't this PC updating? Windows Update and upgrade status on one page, problems first:
    version and end of support, last patch and scan, failed updates with what each error means,
    who manages updates, disabled update services, disk space and Windows 11 / feature update blocks.

.DESCRIPTION
    Read-only. Checks, each with what to do:

      Support   Windows version and edition against Microsoft's end-of-updates dates
      Updates   when the last Windows patch was installed, when Windows last checked for updates,
                failed updates in Windows Update's own history (grouped, with the error code
                explained and dropped once the same update later installed), and repeated
                "can't connect to the update service" events
      Restart   updates installed and waiting for a restart
      Policy    who manages updates (Intune, Group Policy, WSUS, an RMM agent, or nothing),
                automatic updates turned off, pauses, deferrals, a version pin, and whether the
                WSUS server answers
      Services  Windows Update, Update Orchestrator, Update Medic, BITS, Windows Modules
                Installer, Cryptographic Services and Delivery Optimization not disabled
                (what "update blocker" tools change)
      Disk      free space for monthly and feature updates
      Upgrade   Windows' own readiness check for the next version (Red / Orange / Yellow / Green,
                the hardware reason, Microsoft safeguard holds), Windows Setup's compatibility
                report (apps and drivers that block the upgrade), SetupDiag's verdict on the last
                failed upgrade, and Setup files left on the drive
      Activity  update and Setup processes running right now

    -Watch then keeps an eye on update activity, one line at a time: servicing processes starting,
    finishing and using CPU, Windows Update events (download and install started, installed,
    failed) and the Windows Setup log growing. That tells "stuck" apart from "slow".

    Works unelevated. Run as admin to read Windows Setup's compatibility report.

.PARAMETER Html
    Also write a one-page HTML report (and open it, when run locally and interactively).

.PARAMETER ReportFolder
    Where -Html writes. Default C:\Triage (created if missing).

.PARAMETER Days
    How far back to look at update history and events. Default 90.

.PARAMETER SkipNetwork
    Don't test whether a WSUS server set by policy answers.

.PARAMETER Watch
    After the report, watch update activity for -WatchMinutes, checking every 10 seconds.
    Ctrl+C stops it; the report is already written by then.

.PARAMETER WatchMinutes
    How long -Watch runs. Default 30.

.PARAMETER NoOpen
    Don't open the HTML report after writing it.

.PARAMETER Quiet
    Print only the one-line summary (for RMM monitors).

.PARAMETER PassThru
    Emit the findings, version, recent updates and policies to the pipeline.

.EXAMPLE
    .\Get-WindowsUpdateStatus.ps1 -Html

.EXAMPLE
    .\Get-WindowsUpdateStatus.ps1 -Watch -WatchMinutes 60
    (While an update is "stuck": is it doing anything?)

.NOTES
    Exit codes: 0 = nothing failed, 1 = at least one FAIL.
    End-of-updates dates come from Microsoft's Windows release information, checked 2026-11-18.
    A build newer than that table is reported as INFO, not guessed.
    Nothing is changed and nothing is sent anywhere. The only network use is a TCP connection to a
    WSUS server named in this PC's own policy (skip it with -SkipNetwork).
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Html,
    [string] $ReportFolder = (Join-Path $env:SystemDrive 'Triage'),
    [ValidateRange(7, 365)] [int] $Days = 90,
    [switch] $SkipNetwork,
    [switch] $Watch,
    [ValidateRange(1, 240)] [int] $WatchMinutes = 30,
    [switch] $NoOpen,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$now      = Get-Date
$since    = $now.AddDays(-$Days)
$SysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
$SysRoot  = if ($env:SystemRoot) { $env:SystemRoot } else { "$SysDrive\Windows" }
$Computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }
$TestWsus = -not $SkipNetwork

# ================================================================================================
#  Reference data
# ================================================================================================

# End of updates by build and edition family, from Microsoft's Windows release information
# (checked 2026-11-18). HomePro = Home, Pro, Pro Education, Pro for Workstations, SE.
# EntEdu = Enterprise, Education, IoT Enterprise, Enterprise multi-session. LTSC = the long-term
# servicing editions. Windows 10 22H2 ended for every edition; ESU keeps enrolled PCs patched.
$TableChecked  = '2026-11-18'
$LatestVersion = '25H2'
$EndOfUpdates = @{
    '19045|HomePro' = '2025-10-14'; '19045|EntEdu' = '2025-10-14'
    '22000|HomePro' = '2023-10-10'; '22000|EntEdu' = '2024-10-08'
    '22621|HomePro' = '2024-10-08'; '22621|EntEdu' = '2025-10-14'
    '22631|HomePro' = '2025-11-11'; '22631|EntEdu' = '2026-11-10'
    '26100|HomePro' = '2026-10-13'; '26100|EntEdu' = '2027-10-12'; '26100|LTSC' = '2029-10-09'
    '26200|HomePro' = '2027-10-12'; '26200|EntEdu' = '2028-10-10'
    '28000|HomePro' = '2028-03-14'; '28000|EntEdu' = '2029-03-13'
    '14393|LTSC'    = '2026-10-13'
}
$VersionByBuild = @{ 19045 = '22H2'; 22000 = '21H2'; 22621 = '22H2'; 22631 = '23H2'; 26100 = '24H2'; 26200 = '25H2'; 26300 = '26H2'; 28000 = '26H1' }
$EditionNames = @{
    Core = 'Home'; CoreSingleLanguage = 'Home Single Language'; CoreCountrySpecific = 'Home China'
    Professional = 'Pro'; ProfessionalEducation = 'Pro Education'; ProfessionalWorkstation = 'Pro for Workstations'
    Enterprise = 'Enterprise'; Education = 'Education'; EnterpriseS = 'Enterprise LTSC'; IoTEnterprise = 'IoT Enterprise'
    IoTEnterpriseS = 'IoT Enterprise LTSC'; ServerRdsh = 'Enterprise multi-session'; CloudEdition = 'SE'
}

# Windows Update and Setup result codes worth naming (Microsoft's Windows Update error reference,
# common Windows Update errors, and upgrade error codes). Anything else falls back to Windows' own
# message for the code. Meaning, then what to do.
$KnownCodes = @{
    '0x80240016' = @('Another install was running, or a restart was pending.', 'Restart, then check for updates again.')
    '0x8024000B' = @('The install was cancelled, usually by a shutdown or restart part-way through.', 'It retries by itself. Leave the PC on and plugged in.')
    '0x80240020' = @('It was waiting for someone to sign in.', 'Usually fine: it installs once a user is signed in.')
    '0x80240017' = @('Not applicable to this PC.', 'Usually harmless.')
    '0x80240034' = @('The download failed.', 'Check the connection, proxy or web filter, then Repair > Windows Update reset.')
    '0x8024200D' = @('The download was incomplete.', 'It retries by itself; if it keeps happening, Repair > Windows Update reset.')
    '0x80242016' = @('The update was in an unexpected state after the restart.', 'It usually retries by itself.')
    '0x80246007' = @('The update files were missing or incomplete.', 'Repair > Windows Update reset, then check for updates.')
    '0x8024402C' = @('Couldn''t reach the update server: its name didn''t resolve.', 'Check DNS and any proxy; with WSUS, check the server name in the policy.')
    '0x8024401C' = @('The update server timed out.', 'Check the connection and proxy; a WSUS server may be overloaded.')
    '0x80244019' = @('The update server answered "not found" (HTTP 404).', 'The WSUS address in the policy is wrong, or a proxy is changing it.')
    '0x80244022' = @('The update server is unavailable (HTTP 503).', 'WSUS: its IIS application pool has probably stopped; restart it on the server.')
    '0x8024402F' = @('Part of the download was blocked, usually by a web filter or proxy.', 'Let the Windows Update endpoints through the web filter / proxy.')
    '0x8024002E' = @('Windows Update is turned off by policy.', 'See the Policy checks.')
    '0x80070422' = @('An update service is disabled.', 'See the Services checks.')
    '0x800F0922' = @('The install failed: often too little space (including the small system partitions) or a VPN / proxy in the way.', 'Free space, disconnect any VPN, restart and try again.')
    '0x800F081F' = @('Windows couldn''t find the files it needs to repair itself.', 'Run Repair > Windows repair checks (DISM + SFC), then try again.')
    '0x80073712' = @('Windows'' component store is damaged.', 'Run Repair > Windows repair checks (DISM + SFC), then try again.')
    '0x800F0831' = @('A package this update builds on is missing.', 'Install the latest cumulative update from the Microsoft Update Catalog, or run Windows repair checks.')
    '0x80070002' = @('Files the update needs are missing (file not found).', 'Repair > Windows Update reset, then check for updates.')
    '0x80070003' = @('Files the update needs are missing (path not found).', 'Repair > Windows Update reset, then check for updates.')
    '0x8007000D' = @('Update data is corrupt.', 'Repair > Windows Update reset; if it repeats, Windows repair checks.')
    '0x8007000E' = @('Ran out of memory or space while installing.', 'Free disk space, restart and try again.')
    '0x80070070' = @('Not enough disk space.', 'Free space on the system drive (20 GB for a feature update).')
    '0x800705B4' = @('The update took too long or was interrupted.', 'Leave it on and plugged in; restart and try again.')
    '0x80070020' = @('Another program had a file locked (often antivirus or backup).', 'Restart and try again; check any third-party antivirus.')
    '0x80070005' = @('Access denied.', 'Often third-party security software; restart and try again.')
    '0x80070643' = @('The installer failed. Common with the recovery partition (WinRE) update when that partition is too small, and with .NET updates.', 'Check which update it was; a WinRE update needs a bigger recovery partition (Microsoft has the steps).')
    '0xC1900101' = @('A driver problem during the upgrade, so it rolled back.', 'Update drivers (Build > OEM drivers), unplug extra devices, remove third-party antivirus, try again.')
    '0xC1900107' = @('Cleanup from an earlier upgrade attempt is still pending.', 'Restart, then try again.')
    '0xC1900200' = @('This PC doesn''t meet the requirements for that version.', 'See the Upgrade checks for the reason.')
    '0xC1900202' = @('This PC doesn''t meet the requirements for that version.', 'See the Upgrade checks for the reason.')
    '0xC1900208' = @('An incompatible app is blocking the upgrade.', 'Run as admin to see Setup''s compatibility report; update or remove the app.')
    '0xC190020E' = @('Not enough free space for the upgrade.', 'Free at least 20 GB on the system drive.')
    '0xC1900223' = @('Problem downloading the upgrade; Windows Update tries again later.', 'Usually nothing to do; if it repeats, check the proxy / web filter.')
}

# Why Windows' readiness check says Red (Microsoft's Windows 11 readiness documentation).
$RedReasons = @{
    Tpm             = @('no TPM 2.0', 'Turn on the TPM (Intel PTT / AMD fTPM) in the BIOS, if the chip supports 2.0.')
    UefiSecureBoot  = @('not Secure Boot capable', 'Switch the BIOS to UEFI (convert the disk with MBR2GPT first), then turn on Secure Boot.')
    Memory          = @('under 4 GB of RAM', 'Add memory, or replace the PC.')
    CPU             = @('CPU has under 2 cores or runs under 1 GHz', 'Replace the PC.')
    CpuCores        = @('CPU has under 2 cores', 'Replace the PC.')
    CpuSpeed        = @('CPU runs under 1 GHz', 'Replace the PC.')
    CpuFms          = @('CPU isn''t on Microsoft''s supported list', 'Replace the PC, or keep it on extended security updates.')
    SModeState      = @('in S mode', 'Switch out of S mode (Microsoft Store), then upgrade.')
    SystemDriveSize = @('system drive under 64 GB', 'A bigger drive, or replace the PC.')
    SystemDriveFull = @('system reserved partition too small', 'Grow the system reserved / EFI partition.')
}

# Update and Setup processes worth naming when they're running.
$ServicingNames = @('TiWorker', 'TrustedInstaller', 'MoUsoCoreWorker', 'usocoreworker', 'wuauclt', 'SetupHost', 'SetupPrep',
                    'WindowsUpdateBox', 'Windows10UpgraderApp', 'Windows11InstallationAssistant', 'DismHost')

# RMM agents that usually do their own patching (matched on service display names).
$RmmAgents = @(
    @('Datto RMM', 'CentraStage|Datto RMM'), @('NinjaOne', 'NinjaRMM|NinjaOne'), @('N-able', 'N-able|Advanced Monitoring Agent'),
    @('Kaseya', 'Kaseya'), @('Atera', 'Atera'), @('Syncro', 'Syncro'), @('ConnectWise Automate', 'LTService|LabTech|ConnectWise Automate'),
    @('Action1', 'Action1'), @('Pulseway', 'Pulseway'), @('Automox', 'Automox'), @('ManageEngine', 'ManageEngine')
)

# ================================================================================================
#  Plumbing
# ================================================================================================
$Findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param(
        [string] $Area, [string] $Check,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')] [string] $Status,
        [string] $Detail, [string] $Fix
    )
    $Findings.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix; Order = $Findings.Count })
}

# What to look at first when several things are wrong.
$AreaOrder = @('Support', 'Updates', 'Services', 'Policy', 'Restart', 'Disk', 'Upgrade', 'Activity')

function Invoke-Check {
    # One broken check records a note and moves on; it never sinks the report.
    param([string] $Area, [scriptblock] $Body)
    try { & $Body }
    catch { Add-Finding $Area 'Check failed' 'INFO' "Couldn't run: $($_.Exception.Message)" }
}

function Get-RegKey {
    # All values of one registry key as an ordered hashtable (empty when the key isn't there).
    param([string] $Path)
    $h = [ordered]@{}
    $p = $null
    try { $p = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop } catch { $p = $null }
    if ($p) {
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { $h[$prop.Name] = $prop.Value }
        }
    }
    $h
}

function Get-Val {
    param($Map, [string] $Name)
    if ($Map -and $Map.Contains($Name)) { $Map[$Name] } else { $null }
}

function Get-RegSubKeyName {
    param([string] $Path)
    try { @(Get-ChildItem -LiteralPath $Path -ErrorAction Stop | ForEach-Object { $_.PSChildName }) } catch { @() }
}

function Test-PathSafe {
    param([string] $Path)
    try { [bool](Test-Path -LiteralPath $Path) } catch { $false }
}

function Get-RecentEvent {
    param([hashtable] $Filter, [int] $Max = 500)
    try { @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) }
    catch { @() }
}

function ConvertTo-LocalTime {
    # The update agent hands back UTC dates with Kind Unspecified.
    param($Value)
    if ($null -eq $Value -or $Value -isnot [datetime] -or $Value.Year -lt 2000) { return $null }
    [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc).ToLocalTime()
}

function ConvertFrom-DateText {
    # Policy dates arrive as text: '2026-11-01', '2026-11-01T10:00:00Z' and similar.
    param($Text)
    if ($Text -is [datetime]) { return $Text }
    if ([string]::IsNullOrWhiteSpace([string]$Text)) { return $null }
    $d = [datetime]::MinValue
    if ([string]$Text -match '^\s*\d{4}-\d{2}-\d{2}\s*$') {
        # A plain date (Intune / GPO pause start) is a calendar day, not a UTC instant.
        if ([datetime]::TryParseExact(([string]$Text).Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
        return $null
    }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetime]::TryParse([string]$Text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) { return $d.ToLocalTime() }
    $null
}

function Get-AgeText {
    param([datetime] $When)
    $span = $now - $When
    if ($span.TotalDays -ge 2) { return '{0} days ago' -f [int][math]::Floor($span.TotalDays) }
    if ($span.TotalHours -ge 2) { return '{0} hours ago' -f [int][math]::Floor($span.TotalHours) }
    if ($span.TotalMinutes -ge 1) { return '{0} min ago' -f [int][math]::Floor($span.TotalMinutes) }
    'just now'
}

function Format-Date { param([datetime] $When) $When.ToString('yyyy-MM-dd') }

function Format-HResult {
    param($Code)
    if ($null -eq $Code -or [string]$Code -eq '') { return '' }
    $v = [int64]$Code
    if ($v -gt [int32]::MaxValue) { $v -= 4294967296 }
    '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$v), 0)
}

function Get-CodeHelp {
    # Plain English for an update result code: our list first, then Windows' own message table.
    param([string] $Hex)
    $Hex = $Hex.ToUpper() -replace '^0X', '0x'
    if ($KnownCodes.ContainsKey($Hex)) { return [pscustomobject]@{ Meaning = $KnownCodes[$Hex][0]; Fix = $KnownCodes[$Hex][1] } }
    $text = $null
    try {
        $u = [Convert]::ToUInt32($Hex.Substring(2), 16)
        $n = if (($u -shr 16) -eq 0x8007) { [int]($u -band 0xFFFF) } else { [BitConverter]::ToInt32([BitConverter]::GetBytes($u), 0) }
        $text = ([ComponentModel.Win32Exception]::new($n)).Message
    }
    catch { $text = $null }
    if ($text -and $text -notmatch '^Unknown error') { return [pscustomobject]@{ Meaning = ($text.Trim().TrimEnd('.') + '.'); Fix = '' } }
    [pscustomobject]@{ Meaning = 'No description for this code.'; Fix = 'Search the code together with the update''s KB number.' }
}

function Get-VersionRank {
    # '24H2' -> 242, so versions compare as numbers. 0 when there's no version in the text.
    param([string] $Text)
    $m = [regex]::Match([string]$Text, '(\d{2})H(\d)')
    if ($m.Success) { [int]$m.Groups[1].Value * 10 + [int]$m.Groups[2].Value } else { 0 }
}

function Test-TcpPort {
    param([string] $HostName, [int] $Port, [int] $TimeoutMs = 4000)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($TimeoutMs)) { return 'timed out' }
        if ($client.Connected) { return 'ok' }
        'refused'
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $inner.Message
    }
    finally { $client.Dispose() }
}

function Get-ServicingProcess {
    $list = @()
    foreach ($p in @(Get-Process -Name $ServicingNames -ErrorAction SilentlyContinue)) {
        $cpu = $null; $start = $null
        try { if ($null -ne $p.CPU) { $cpu = [double]$p.CPU } } catch { $cpu = $null }
        try { if ($p.StartTime) { $start = [datetime]$p.StartTime } } catch { $start = $null }
        $list += [pscustomobject]@{ Name = [string]$p.Name; Id = [int]$p.Id; Cpu = $cpu; Start = $start }
    }
    $list
}

function Get-RestartState {
    [pscustomobject]@{
        Updates   = Test-PathSafe 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        Servicing = Test-PathSafe 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    }
}

$SetupActLogs = @(('{0}\$WINDOWS.~BT\Sources\Panther\setupact.log' -f $SysDrive), "$SysRoot\Panther\setupact.log")
function Get-SetupLogState {
    foreach ($f in $SetupActLogs) {
        try {
            $i = Get-Item -LiteralPath $f -Force -ErrorAction Stop
            return [pscustomobject]@{ Path = $f; Length = [int64]$i.Length; Time = $i.LastWriteTime }
        }
        catch { Write-Verbose "No setup log at $f" }
    }
    $null
}

if (-not $Quiet) { Write-Host "Checking Windows Update on $Computer - takes 10-30 seconds..." -ForegroundColor DarkGray }

# ================================================================================================
#  What is this PC?
# ================================================================================================
$cv        = Get-RegKey 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build     = 0
[void][int]::TryParse([string]$(if (Get-Val $cv 'CurrentBuild') { Get-Val $cv 'CurrentBuild' } else { Get-Val $cv 'CurrentBuildNumber' }), [ref]$build)
$ubr       = Get-Val $cv 'UBR'
$editionId = [string](Get-Val $cv 'EditionID')
$isServer  = [string](Get-Val $cv 'InstallationType') -eq 'Server'
$display   = [string](Get-Val $cv 'DisplayVersion')
if (-not $display) { $display = [string](Get-Val $cv 'ReleaseId') }
if (-not $display -and $VersionByBuild.ContainsKey($build)) { $display = $VersionByBuild[$build] }
$isWin11   = $build -ge 22000
$osName    = if ($isServer) { [string](Get-Val $cv 'ProductName') } elseif ($isWin11) { 'Windows 11' } else { 'Windows 10' }
$baseEd    = $editionId -creplace 'N$', ''
$edName    = if ($EditionNames.ContainsKey($baseEd)) { $EditionNames[$baseEd] } elseif ($editionId) { $editionId } else { '' }
if ($editionId -cne $baseEd -and $edName) { $edName += ' N' }
$family    = if ($editionId -cmatch '^(IoT)?EnterpriseSN?$') { 'LTSC' } elseif ($editionId -match '^(IoT)?Enterprise|^Education|^ServerRdsh') { 'EntEdu' } else { 'HomePro' }
$buildText = if ($null -ne $ubr) { "$build.$ubr" } else { "$build" }
$osLabel   = (('{0} {1} {2}' -f $osName, $(if ($isServer) { '' } else { $edName }), $display) -replace '\s+', ' ').Trim() + " ($buildText)"
$installDate = $null
if (Get-Val $cv 'InstallDate') { try { $installDate = [DateTimeOffset]::FromUnixTimeSeconds([int64](Get-Val $cv 'InstallDate')).LocalDateTime } catch { $installDate = $null } }

# ================================================================================================
#  Gather: patches, the update agent, history, policies
# ================================================================================================
$lastPatch = $null
try {
    $lastPatch = @(Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending) | Select-Object -First 1
}
catch { $lastPatch = $null }
$lastPatchAge = if ($lastPatch) { ($now - [datetime]$lastPatch.InstalledOn).TotalDays } else { $null }

$auResults = $null
try { $auResults = (New-Object -ComObject 'Microsoft.Update.AutoUpdate').Results } catch { $auResults = $null }
$lastScan       = if ($auResults) { ConvertTo-LocalTime $auResults.LastSearchSuccessDate } else { $null }
$lastInstallAny = if ($auResults) { ConvertTo-LocalTime $auResults.LastInstallationSuccessDate } else { $null }

$History = @()
$historyError = $null
try {
    $session  = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $total    = [int]$searcher.GetTotalHistoryCount()
    if ($total -gt 0) {
        $History = @(foreach ($e in @($searcher.QueryHistory(0, [Math]::Min($total, 300)))) {
            if ($null -eq $e -or [int]$e.Operation -ne 1) { continue }          # 1 = install, 2 = uninstall
            $when = ConvertTo-LocalTime $e.Date
            if (-not $when) { continue }
            $title = [string]$e.Title
            $kb    = [regex]::Match($title, 'KB\d{6,8}').Value
            [pscustomobject]@{
                Date   = $when
                Title  = $title
                KB     = $kb
                Key    = $(if ($kb) { $kb } else { $title })
                Result = [int]$e.ResultCode                                    # 2 ok, 3 ok with errors, 4 failed, 5 aborted
                Code   = Format-HResult $e.HResult
            }
        })
    }
}
catch { $historyError = $_.Exception.Message }
$History = @($History | Sort-Object Date -Descending)

$wuPol = Get-RegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$auPol = Get-RegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$mdm   = Get-RegKey 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
$ux    = Get-RegKey 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$mdmPolicyNames = @($mdm.Keys | Where-Object { $_ -notmatch '_(ProviderSet|WinningProvider|LastWrite)$' })
# A policy delivered by MDM (Intune) leaves a <Name>_WinningProvider value naming the enrolment.
$mdmFromIntune  = @($mdm.Keys | Where-Object { $_ -match '_WinningProvider$' }).Count -gt 0

$supportEnded = $false

# ================================================================================================
#  Support
# ================================================================================================
Invoke-Check 'Support' {
    if ($isServer) {
        Add-Finding 'Support' 'Version' 'INFO' "$osLabel" 'Windows Server: check its date on Microsoft''s lifecycle pages; this table covers Windows 10 and 11.'
        return
    }
    $endText = $EndOfUpdates["$build|$family"]
    $oldWin10 = (-not $endText) -and $build -ge 10240 -and $build -lt 19045 -and $family -ne 'LTSC'
    if (-not $endText -and -not $oldWin10) {
        Add-Finding 'Support' 'Version' 'INFO' "$osLabel - not in this tool's table (checked $TableChecked)" 'Check Microsoft''s Windows release information for its end date.'
        return
    }
    $recentPatch = $null -ne $lastPatchAge -and $lastPatchAge -le 45
    if ($oldWin10) {
        $script:supportEnded = $true
        Add-Finding 'Support' 'Version' 'FAIL' "$osLabel - this Windows 10 version stopped getting updates years ago" 'Upgrade to Windows 11 (see the Upgrade checks for whether it can), or at least to Windows 10 22H2.'
        return
    }
    $end  = [datetime]::ParseExact($endText, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $left = [int][math]::Floor(($end - $now.Date).TotalDays)
    if ($left -lt 0) {
        $script:supportEnded = $true
        if (-not $isWin11 -and $recentPatch) {
            Add-Finding 'Support' 'Version' 'WARN' ("$osLabel - out of support since {0}, but still patched {1}: probably Extended Security Updates" -f $endText, (Get-AgeText ([datetime]$lastPatch.InstalledOn))) 'Confirm the ESU licence covers it, and plan the move to Windows 11.'
        }
        elseif ($isWin11) {
            $how = if ($build -eq 26100) { 'a quick enablement package from 24H2' } else { 'a full feature update' }
            Add-Finding 'Support' 'Version' 'FAIL' ("$osLabel - no security updates since {0}" -f $endText) ("Move it to {0} ({1}) through Settings > Windows Update. If a policy pins the version, raise the pin (see Policy)." -f $LatestVersion, $how)
        }
        else {
            Add-Finding 'Support' 'Version' 'FAIL' ("$osLabel - no security updates since {0}" -f $endText) 'Upgrade to Windows 11 (see the Upgrade checks for whether it can), or enrol it in Extended Security Updates.'
        }
    }
    elseif ($left -le 90) {
        Add-Finding 'Support' 'Version' 'WARN' ("$osLabel - updates end {0} ({1} days)" -f $endText, $left) ("Plan the move to {0} before then." -f $LatestVersion)
    }
    else {
        Add-Finding 'Support' 'Version' 'PASS' ("$osLabel - supported until {0}" -f $endText)
    }
}

# ================================================================================================
#  Updates
# ================================================================================================
Invoke-Check 'Updates' {
    if (-not $lastPatch) {
        $any = if ($lastInstallAny) { '; Windows Update last installed something ' + (Get-AgeText $lastInstallAny) } else { '' }
        Add-Finding 'Updates' 'Last patch' 'INFO' "No install dates recorded for Windows patches$any"
    }
    else {
        $text = 'Installed {0} ({1}, {2})' -f (Get-AgeText ([datetime]$lastPatch.InstalledOn)), (Format-Date ([datetime]$lastPatch.InstalledOn)), $lastPatch.HotFixID
        if ($lastPatchAge -gt 60)     { Add-Finding 'Updates' 'Last patch' 'FAIL' $text 'Over two months behind. Work through the checks below: failed updates, policy, services, disk.' }
        elseif ($lastPatchAge -gt 40) { Add-Finding 'Updates' 'Last patch' 'WARN' $text 'Missed at least one Patch Tuesday. See the failed updates and policy checks below.' }
        else                          { Add-Finding 'Updates' 'Last patch' 'PASS' $text }
    }
}

Invoke-Check 'Updates' {
    if (-not $lastScan) {
        $why = if ($auResults) { 'Windows has no record of a successful check' } else { 'Couldn''t ask the update agent' }
        Add-Finding 'Updates' 'Last check for updates' 'INFO' $why
        return
    }
    $age  = ($now - $lastScan).TotalDays
    $text = 'Last successful check {0} ({1})' -f (Get-AgeText $lastScan), $lastScan.ToString('yyyy-MM-dd HH:mm')
    if ($age -gt 30)    { Add-Finding 'Updates' 'Last check for updates' 'FAIL' $text 'It can''t reach its update source, or the update service is broken. See Policy and Services below.' }
    elseif ($age -gt 7) { Add-Finding 'Updates' 'Last check for updates' 'WARN' $text 'Click Check for updates in Settings and see whether it errors. See Policy and Services below.' }
    else                { Add-Finding 'Updates' 'Last check for updates' 'PASS' $text }
}

Invoke-Check 'Updates' {
    if ($historyError) {
        # No agent history: fall back to install-failure events (20) in the System log.
        $events = Get-RecentEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20; StartTime = $since }
        if (-not $events.Count) { Add-Finding 'Updates' 'Failed updates' 'INFO' "Couldn't read the update history ($historyError), and no install failures logged in $Days days" ; return }
        $groups = $events | ForEach-Object {
            $msg  = [string]$_.Message
            $code = [regex]::Match($msg, '0x[0-9A-Fa-f]{8}').Value
            $name = ($msg -replace '(?s)^.*?0x[0-9A-Fa-f]{8}\s*:?\s*', '').Trim()
            [pscustomobject]@{ When = $_.TimeCreated; Code = $code; Name = $name }
        } | Group-Object Name
        foreach ($g in @($groups | Sort-Object Count -Descending | Select-Object -First 5)) {
            $last = $g.Group | Sort-Object When -Descending | Select-Object -First 1
            $help = if ($last.Code) { Get-CodeHelp $last.Code } else { [pscustomobject]@{ Meaning = ''; Fix = '' } }
            $status = if ($g.Count -ge 2) { 'FAIL' } else { 'WARN' }
            Add-Finding 'Updates' 'Failed update' $status ('{0}: failed {1}x, last {2}, {3} - {4}' -f $g.Name, $g.Count, (Format-Date $last.When), $last.Code, $help.Meaning) $help.Fix
        }
        return
    }
    $failed = @($History | Where-Object { $_.Result -in 4, 5 -and $_.Date -ge $since })
    $open = foreach ($g in @($failed | Group-Object Key)) {
        $lastFail = $g.Group | Sort-Object Date -Descending | Select-Object -First 1
        $fixedLater = @($History | Where-Object { $_.Key -eq $g.Name -and $_.Result -in 2, 3 -and $_.Date -gt $lastFail.Date }).Count -gt 0
        if (-not $fixedLater) { [pscustomobject]@{ Last = $lastFail; Count = $g.Count } }
    }
    $open = @($open | Sort-Object @{ e = { $_.Count }; Descending = $true }, @{ e = { $_.Last.Date }; Descending = $true })
    if (-not $open.Count) {
        $fixedNote = if ($failed.Count) { " ({0} earlier failure(s) installed fine later)" -f $failed.Count } else { '' }
        Add-Finding 'Updates' 'Failed updates' 'PASS' ("None outstanding in the last {0} days{1}" -f $Days, $fixedNote)
        return
    }
    foreach ($o in @($open | Select-Object -First 5)) {
        $help   = Get-CodeHelp $o.Last.Code
        $status = if ($o.Count -ge 2) { 'FAIL' } else { 'WARN' }
        $times  = if ($o.Count -ge 2) { "failed $($o.Count) times" } else { 'failed' }
        Add-Finding 'Updates' 'Failed update' $status ('{0}: {1}, last {2}. {3} {4}' -f $o.Last.Title, $times, (Format-Date $o.Last.Date), $o.Last.Code, $help.Meaning) $help.Fix
    }
    if ($open.Count -gt 5) { Add-Finding 'Updates' 'Failed update' 'INFO' ('{0} more update(s) failing - see the history below' -f ($open.Count - 5)) }
}

Invoke-Check 'Updates' {
    $cant = Get-RecentEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 16; StartTime = $now.AddDays(-7) }
    if ($cant.Count -ge 3) {
        $last = ($cant | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
        Add-Finding 'Updates' 'Connection' 'WARN' ("Couldn't connect to the update service {0} times in 7 days (last {1})" -f $cant.Count, ([datetime]$last).ToString('yyyy-MM-dd HH:mm')) 'Check the proxy, firewall and web filter, or the WSUS server (see Policy).'
    }
}

# ================================================================================================
#  Restart
# ================================================================================================
Invoke-Check 'Restart' {
    $r = Get-RestartState
    if ($r.Updates)       { Add-Finding 'Restart' 'Restart pending' 'WARN' 'Updates are installed and waiting for a restart' 'Restart it: nothing else installs until it does.' }
    elseif ($r.Servicing) { Add-Finding 'Restart' 'Restart pending' 'WARN' 'Windows servicing is waiting for a restart' 'Restart it before installing anything else.' }
    else                  { Add-Finding 'Restart' 'Restart pending' 'PASS' 'No restart waiting for updates' }
}

# ================================================================================================
#  Policy: who's in charge, and what it says
# ================================================================================================
$Managers = [System.Collections.Generic.List[string]]::new()
$PolicyRows = [System.Collections.Generic.List[object]]::new()

Invoke-Check 'Policy' {
    foreach ($src in @(@('Group Policy', 'Policies\...\WindowsUpdate', $wuPol), @('Group Policy', 'Policies\...\WindowsUpdate\AU', $auPol),
                       @('Intune / MDM', 'PolicyManager\current\device\Update', $mdm), @('Settings app', 'WindowsUpdate\UX\Settings', $ux))) {
        foreach ($k in @($src[2].Keys)) {
            if ($k -match '_(ProviderSet|WinningProvider|LastWrite)$') { continue }
            if ($src[0] -eq 'Settings app' -and $k -notmatch '^Pause') { continue }
            $PolicyRows.Add([pscustomobject]@{ Source = $src[0]; Key = $src[1]; Name = $k; Value = [string]$src[2][$k] })
        }
    }

    $useWsus = [string](Get-Val $auPol 'UseWUServer') -eq '1' -and [string](Get-Val $wuPol 'WUServer')
    if ($mdmFromIntune) { $Managers.Add('Intune / MDM update policy') }
    elseif ($mdmPolicyNames.Count) { $Managers.Add('Update policy (PolicyManager)') }
    if (($wuPol.Count + $auPol.Count) -gt 0) { $Managers.Add('Group Policy') }
    if ($useWsus) { $Managers.Add("WSUS ($(Get-Val $wuPol 'WUServer'))") }
    $rmm = @()
    try {
        $names = @(Get-Service -ErrorAction Stop | ForEach-Object { [string]$_.DisplayName })
        foreach ($a in $RmmAgents) { if (@($names -match $a[1]).Count) { $rmm += $a[0] } }
    }
    catch { Write-Verbose "Couldn't list services: $($_.Exception.Message)" }
    foreach ($r in $rmm) { $Managers.Add("RMM agent: $r") }

    if ($Managers.Count) {
        $note = if ($rmm.Count -and $mdmFromIntune) { 'Both Intune and an RMM agent can patch this PC: check which one is meant to.' } else { '' }
        Add-Finding 'Policy' 'Managed by' 'INFO' ($Managers -join ', ') $note
    }
    else { Add-Finding 'Policy' 'Managed by' 'INFO' 'Nothing: plain Windows Update with no update policies' }

    # Automatic updates off, or notify only
    if ([string](Get-Val $auPol 'NoAutoUpdate') -eq '1') {
        Add-Finding 'Policy' 'Automatic updates' 'FAIL' 'Turned off by Group Policy (NoAutoUpdate = 1)' 'Remove that policy (GPO, registry or RMM script) unless something else installs updates here.'
    }
    elseif ([string](Get-Val $mdm 'AllowAutoUpdate') -eq '5') {
        Add-Finding 'Policy' 'Automatic updates' 'FAIL' 'Turned off by the Intune / MDM update policy (AllowAutoUpdate = 5)' 'Change the update ring''s automatic update behaviour in Intune.'
    }
    elseif ([string](Get-Val $auPol 'AUOptions') -eq '2' -or [string](Get-Val $mdm 'AllowAutoUpdate') -eq '0') {
        Add-Finding 'Policy' 'Automatic updates' 'WARN' 'Set to notify only: nothing downloads or installs until someone clicks' 'Set automatic install in the policy, unless the RMM installs updates.'
    }

    # WSUS
    if ($useWsus) {
        $url = [string](Get-Val $wuPol 'WUServer')
        if (-not $TestWsus) { Add-Finding 'Policy' 'WSUS server' 'INFO' "Updates come from $url (not tested: -SkipNetwork)" }
        else {
            $uri = $null
            try { $uri = [uri]$url } catch { $uri = $null }
            if (-not $uri -or -not $uri.Host) { Add-Finding 'Policy' 'WSUS server' 'FAIL' "The WSUS address in the policy isn't a valid URL: $url" 'Fix or remove the WSUS policy.' }
            else {
                $port = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq 'https') { 443 } else { 80 }
                $res  = Test-TcpPort -HostName $uri.Host -Port $port
                if ($res -eq 'ok') { Add-Finding 'Policy' 'WSUS server' 'PASS' "Updates come from $url, which answers on port $port" }
                else { Add-Finding 'Policy' 'WSUS server' 'FAIL' "Updates come from $url, which isn't answering on port ${port}: $res" 'If that server has been retired, remove the WSUS policy (GPO / RMM) so it uses Windows Update; otherwise check the server and its port.' }
            }
        }
    }

    # Pauses: Intune, Group Policy, and the Settings app
    $pauses = @()
    foreach ($p in @(
        @('Quality', 'Intune', ([string](Get-Val $mdm 'PauseQualityUpdates') -eq '1'), (Get-Val $mdm 'PauseQualityUpdatesStartTime')),
        @('Feature', 'Intune', ([string](Get-Val $mdm 'PauseFeatureUpdates') -eq '1'), (Get-Val $mdm 'PauseFeatureUpdatesStartTime')),
        @('Quality', 'Group Policy', [bool](Get-Val $wuPol 'PauseQualityUpdatesStartTime'), (Get-Val $wuPol 'PauseQualityUpdatesStartTime')),
        @('Feature', 'Group Policy', [bool](Get-Val $wuPol 'PauseFeatureUpdatesStartTime'), (Get-Val $wuPol 'PauseFeatureUpdatesStartTime')))) {
        if (-not $p[2]) { continue }
        $start = ConvertFrom-DateText $p[3]
        $until = if ($start) { $start.AddDays(35) } else { $null }
        if ($until -and $until -lt $now) { continue }                              # a pause lasts 35 days
        $pauses += [pscustomobject]@{ Kind = $p[0]; By = $p[1]; Start = $start; Until = $until }
    }
    $uxUntil = ConvertFrom-DateText (Get-Val $ux 'PauseUpdatesExpiryTime')
    if ($uxUntil -and $uxUntil -gt $now) { $pauses += [pscustomobject]@{ Kind = 'All'; By = 'someone in Settings'; Start = $null; Until = $uxUntil } }
    foreach ($p in $pauses) {
        $what  = switch ($p.Kind) { 'Quality' { 'Monthly (quality) updates' } 'Feature' { 'Feature updates' } default { 'Updates' } }
        $when  = if ($p.Until) { ' until about ' + (Format-Date $p.Until) } else { '' }
        $from  = if ($p.Start) { ' since ' + (Format-Date $p.Start) } else { '' }
        $fix   = if ($p.By -eq 'someone in Settings') { 'Settings > Windows Update > Resume updates.' } else { "Resume them in the $($p.By) policy if the pause wasn't meant to last." }
        $level = if ($p.Kind -eq 'Feature') { 'INFO' } else { 'WARN' }
        Add-Finding 'Policy' 'Paused' $level ("$what paused by $($p.By)$from$when") $fix
    }

    # Deferrals
    $qDefer = Get-Val $mdm 'DeferQualityUpdatesPeriodInDays'
    if ($null -eq $qDefer -and [string](Get-Val $wuPol 'DeferQualityUpdates') -eq '1') { $qDefer = Get-Val $wuPol 'DeferQualityUpdatesPeriodInDays' }
    if ($null -ne $qDefer -and [int]$qDefer -gt 0) {
        $level = if ([int]$qDefer -ge 30) { 'WARN' } else { 'INFO' }
        Add-Finding 'Policy' 'Deferral' $level ("Monthly updates held back {0} days after release" -f $qDefer) $(if ($level -eq 'WARN') { 'A month or more behind on purpose: check the update ring is right for this PC.' } else { '' })
    }
    $fDefer = Get-Val $mdm 'DeferFeatureUpdatesPeriodInDays'
    if ($null -eq $fDefer -and [string](Get-Val $wuPol 'DeferFeatureUpdates') -eq '1') { $fDefer = Get-Val $wuPol 'DeferFeatureUpdatesPeriodInDays' }
    if ($null -ne $fDefer -and [int]$fDefer -gt 0) { Add-Finding 'Policy' 'Deferral' 'INFO' ("Feature updates held back {0} days after release" -f $fDefer) }

    # Version pin
    $pinVer = $null; $pinProd = $null; $pinBy = $null
    if ([string](Get-Val $wuPol 'TargetReleaseVersion') -eq '1' -and (Get-Val $wuPol 'TargetReleaseVersionInfo')) {
        $pinVer = [string](Get-Val $wuPol 'TargetReleaseVersionInfo'); $pinProd = [string](Get-Val $wuPol 'ProductVersion'); $pinBy = 'Group Policy'
    }
    elseif ([string](Get-Val $mdm 'TargetReleaseVersion') -match '\d{2}H\d') {
        $pinVer = [string](Get-Val $mdm 'TargetReleaseVersion'); $pinProd = [string](Get-Val $mdm 'ProductVersion'); $pinBy = 'Intune / MDM'
    }
    if ($pinVer) {
        $prod = if ($pinProd) { $pinProd } else { $osName }
        $same = (Get-VersionRank $pinVer) -eq (Get-VersionRank $display) -and ($prod -notmatch '10' -or -not $isWin11)
        if ($same -and $script:supportEnded) {
            Add-Finding 'Policy' 'Version pin' 'FAIL' "Pinned to $prod $pinVer by $pinBy, and that version is out of support" ("Raise the target version to {0} in the {1} policy." -f $LatestVersion, $pinBy)
        }
        else { Add-Finding 'Policy' 'Version pin' 'INFO' "Feature updates pinned to $prod $pinVer by $pinBy" }
    }

    if ([string](Get-Val $wuPol 'SetDisableUXWUAccess') -eq '1' -or [string](Get-Val $wuPol 'DisableWindowsUpdateAccess') -eq '1') {
        Add-Finding 'Policy' 'Settings access' 'INFO' 'Users can''t use Windows Update in Settings (policy)'
    }
    if ([string](Get-Val $wuPol 'ExcludeWUDriversInQualityUpdate') -eq '1' -or [string](Get-Val $mdm 'ExcludeWUDriversInQualityUpdate') -eq '1') {
        Add-Finding 'Policy' 'Drivers' 'INFO' 'Drivers don''t come through Windows Update (policy)' 'Use Build > OEM drivers + BIOS for drivers.'
    }
}

# ================================================================================================
#  Services (start types from the registry, which works unelevated and for protected services)
# ================================================================================================
Invoke-Check 'Services' {
    $services = @(
        @('wuauserv', 'Windows Update', 'FAIL'), @('UsoSvc', 'Update Orchestrator', 'FAIL'), @('WaaSMedicSvc', 'Windows Update Medic', 'FAIL'),
        @('BITS', 'Background Intelligent Transfer (BITS)', 'FAIL'), @('TrustedInstaller', 'Windows Modules Installer', 'FAIL'),
        @('CryptSvc', 'Cryptographic Services', 'FAIL'), @('DoSvc', 'Delivery Optimization', 'WARN'))
    $bad = 0
    foreach ($s in $services) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s[0])"
        $svc = Get-RegKey $key
        if (-not $svc.Count) {
            if ($s[0] -eq 'wuauserv') { Add-Finding 'Services' 'Update service' 'FAIL' "$($s[1]) ($($s[0])) is missing" 'Windows Update itself has been removed or broken; an in-place repair install of Windows fixes it.'; $bad++ }
            continue
        }
        if ([string](Get-Val $svc 'Start') -eq '4') {
            $bad++
            $fix = if ($s[0] -eq 'WaaSMedicSvc') {
                'Something deliberately disabled it, usually an "update blocker" tool or script: find and remove that, then set it back to Manual (registry Start = 3) and restart.'
            } else {
                'Set it back to its normal start type (Manual for most, Automatic for BITS / CryptSvc) and find what disabled it, often an "update blocker" tool or script.'
            }
            Add-Finding 'Services' 'Update service' $s[2] "$($s[1]) ($($s[0])) is disabled" $fix
        }
    }
    if (-not $bad) { Add-Finding 'Services' 'Update services' 'PASS' 'None of the update services are disabled' }
}

# ================================================================================================
#  Disk
# ================================================================================================
Invoke-Check 'Disk' {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f $SysDrive)
    if (-not $disk) { Add-Finding 'Disk' 'Free space' 'INFO' "Couldn't read $SysDrive"; return }
    $free = [double]$disk.FreeSpace / 1GB
    $text = '{0:N1} GB free on {1}' -f $free, $SysDrive
    if ($free -lt 10)     { Add-Finding 'Disk' 'Free space' 'FAIL' $text 'Monthly updates can fail with this little room. Free space (Diagnose > Disk usage report shows where it went).' }
    elseif ($free -lt 20) { Add-Finding 'Disk' 'Free space' 'WARN' $text 'Enough for monthly updates, but a feature update needs about 20 GB.' }
    else                  { Add-Finding 'Disk' 'Free space' 'PASS' $text }
}

# ================================================================================================
#  Upgrade: Windows' readiness check, Setup's compatibility report, SetupDiag
# ================================================================================================
Invoke-Check 'Upgrade' {
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\TargetVersionUpgradeExperienceIndicators'
    $currentRank = if ($isWin11) { Get-VersionRank $display } else { 0 }
    $targets = foreach ($name in (Get-RegSubKeyName $root)) {
        $rank = Get-VersionRank $name
        if (-not $rank) { continue }
        if (-not $isWin11 -and $name -notmatch '^[A-Za-z]{2}\d{2}H\d') { continue }   # on Windows 10 only Windows 11 targets (CO21H2, NI22H2, GE24H2...)
        if ($isWin11 -and $rank -le $currentRank) { continue }
        $v = Get-RegKey "$root\$name"
        $color = [string](Get-Val $v 'UpgEx'); if (-not $color) { $color = [string](Get-Val $v 'UpgExU') }
        [pscustomobject]@{
            Key = $name; Rank = $rank; Version = [regex]::Match($name, '\d{2}H\d').Value; Color = $color
            Red = [string](Get-Val $v 'RedReason'); Hold = [string](Get-Val $v 'GatedBlockId'); HoldReason = [string](Get-Val $v 'GatedBlockReason')
        }
    }
    # One per version, preferring the plain key over the "...Setup" one Windows Setup writes.
    $targets = @($targets | Sort-Object Rank, @{ e = { $_.Key.Length } } | Group-Object Version | ForEach-Object { $_.Group[0] } | Sort-Object Rank -Descending)
    if (-not $targets.Count) {
        $msg = if ($isWin11) { 'Windows hasn''t assessed a newer version for this PC (none out yet, or its compatibility check hasn''t run)' } else { 'Windows hasn''t assessed Windows 11 for this PC (its compatibility check hasn''t run, or diagnostic data is off)' }
        Add-Finding 'Upgrade' 'Readiness' 'INFO' $msg
        return
    }
    $t = $targets[0]
    $label = "Windows 11 $($t.Version)"
    $hasHold = $t.Hold -and $t.Hold -notmatch '^(None|0)?$'
    if ($t.Color -eq 'Red') {
        $codes = @($t.Red -split '[\s,;|]+' | Where-Object { $_ -and $_ -ne 'None' })
        $why = @(); $fixes = @()
        foreach ($c in $codes) {
            $hit = $RedReasons.Keys | Where-Object { $_ -ieq $c } | Select-Object -First 1
            if ($hit) { $why += $RedReasons[$hit][0]; $fixes += $RedReasons[$hit][1] } else { $why += $c }
        }
        $whyText = if ($why.Count) { $why -join ', ' } else { 'no reason recorded' }
        Add-Finding 'Upgrade' 'Readiness' 'FAIL' "Can't move to ${label}: $whyText (Windows' own check)" (@($fixes | Select-Object -Unique) -join ' ')
    }
    elseif ($hasHold) {
        $reason = if ($t.HoldReason -and $t.HoldReason -notmatch '^None$') { " ($($t.HoldReason))" } else { '' }
        Add-Finding 'Upgrade' 'Readiness' 'WARN' "Microsoft is holding $label back from this PC: safeguard hold $($t.Hold)$reason" 'A known problem with something on this PC, often a driver or app. It lifts by itself once Microsoft or the vendor fixes it; check the Windows release health known issues and update drivers. Don''t force the upgrade.'
    }
    elseif ($t.Color -eq 'Orange') {
        Add-Finding 'Upgrade' 'Readiness' 'WARN' "$label is possible, but an app or driver will stop working after it (Windows' own check: Orange)" 'Run as admin to see Setup''s compatibility report; update the apps and drivers first.'
    }
    elseif ($t.Color -eq 'Yellow') {
        Add-Finding 'Upgrade' 'Readiness' 'WARN' "$label needs an app uninstalled first (Windows' own check: Yellow)" 'Run as admin to see Setup''s compatibility report for which app.'
    }
    elseif ($t.Color -eq 'Green') {
        Add-Finding 'Upgrade' 'Readiness' 'PASS' "Ready for $label (Windows' own check)"
    }
    else {
        Add-Finding 'Upgrade' 'Readiness' 'INFO' "Windows assessed $label but gave no verdict ($($t.Color))"
    }
}

Invoke-Check 'Upgrade' {
    # Windows Setup's compatibility report from the last upgrade attempt.
    $dirs = @(('{0}\$WINDOWS.~BT\Sources\Panther' -f $SysDrive), "$SysRoot\Panther")
    $files = @(); $denied = $false
    foreach ($d in $dirs) {
        try { $files += @(Get-ChildItem -LiteralPath $d -Filter 'CompatData*.xml' -File -Force -ErrorAction Stop) }
        catch [System.UnauthorizedAccessException] { $denied = $true }
        catch { if ($_.Exception.Message -match 'denied') { $denied = $true } }
    }
    $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) {
        if ($denied) { Add-Finding 'Upgrade' 'Setup compatibility report' 'INFO' 'Couldn''t read Windows Setup''s logs' 'Run as admin to see Setup''s compatibility report.' }
        return
    }
    $doc = [xml](Get-Content -LiteralPath $newest.FullName -Raw)
    $hard = @()
    foreach ($ci in @($doc.SelectNodes("//*[local-name()='CompatibilityInfo'][@BlockingType='Hard']"))) {
        $owner = $ci.ParentNode
        $name  = @($owner.GetAttribute('Name'), $owner.GetAttribute('HardwareType'), $owner.LocalName) | Where-Object { $_ } | Select-Object -First 1
        $hard += [string]$name
    }
    $drivers = @(foreach ($dp in @($doc.SelectNodes("//*[local-name()='DriverPackage'][@BlockMigration='True']"))) { ([string]$dp.GetAttribute('Inf') -split ':')[0].Trim() })
    $age   = ($now - $newest.LastWriteTime).TotalDays
    $stamp = Format-Date $newest.LastWriteTime
    if ($installDate -and $newest.LastWriteTime -lt $installDate) { $age = 9999 }    # from before the current Windows install
    if ($hard.Count) {
        $text = "Windows Setup found {0} blocker(s) on {1}: {2}" -f $hard.Count, $stamp, ((@($hard | Select-Object -Unique) | Select-Object -First 6) -join '; ')
        if ($age -le 60) { Add-Finding 'Upgrade' 'Setup compatibility report' 'FAIL' $text 'Update or remove those apps / drivers, then try the upgrade again.' }
        else { Add-Finding 'Upgrade' 'Setup compatibility report' 'INFO' "$text (old report)" }
    }
    if ($drivers.Count) {
        $text = "{0} driver(s) won't carry over to the new version: {1}" -f $drivers.Count, ((@($drivers | Select-Object -Unique) | Select-Object -First 8) -join ', ')
        $level = if ($age -le 60) { 'WARN' } else { 'INFO' }
        Add-Finding 'Upgrade' 'Setup compatibility report' $level $text 'Update or remove those drivers before upgrading (Build > OEM drivers + BIOS).'
    }
    if (-not $hard.Count -and -not $drivers.Count) { Add-Finding 'Upgrade' 'Setup compatibility report' 'PASS' "No blockers in Setup's last report ($stamp)" }
}

Invoke-Check 'Upgrade' {
    # SetupDiag runs by itself when an upgrade fails and leaves its verdict here.
    $xmlPath = "$SysRoot\Logs\SetupDiag\SetupDiagResults.xml"
    $sdProfile = $null; $failure = $null; $details = $null; $fixText = $null; $when = $null
    if (Test-PathSafe $xmlPath) {
        $item = Get-Item -LiteralPath $xmlPath -Force
        $when = $item.LastWriteTime
        $doc  = [xml](Get-Content -LiteralPath $xmlPath -Raw)
        $node = { param($n) $x = $doc.SelectSingleNode("//*[local-name()='$n']"); if ($x) { $x.InnerText } }
        $sdProfile = & $node 'ProfileName'; $failure = & $node 'FailureData'; $details = & $node 'FailureDetails'; $fixText = & $node 'Remediation'
    }
    else {
        $r = Get-RegKey 'HKLM:\SYSTEM\Setup\SetupDiag\Results'
        if (-not $r.Count) { return }
        $sdProfile = Get-Val $r 'ProfileName'; $failure = Get-Val $r 'FailureData'; $details = Get-Val $r 'FailureDetails'; $fixText = Get-Val $r 'Remediation'
        $stampText = @(Get-Val $r 'DateTime'; Get-Val $r 'UpgradeEndTime'; Get-Val $r 'UpgradeStartTime') | Where-Object { $_ } | Select-Object -First 1
        $when = ConvertFrom-DateText $stampText
        if (-not $failure -and -not $sdProfile) {
            $failure = (@($r.Values | Where-Object { $_ -is [string] -and $_.Length -gt 10 }) | Select-Object -First 2) -join ' | '
        }
    }
    if (-not $sdProfile -and -not $failure) { return }
    $sdText = ((@($sdProfile, $failure) | Where-Object { $_ }) -join ': ') -replace '\s+', ' '
    if ($sdText.Length -gt 240) { $sdText = $sdText.Substring(0, 237) + '...' }
    $code = [regex]::Match("$failure $details", '0x[0-9A-Fa-f]{8}').Value
    $help = if ($code) { Get-CodeHelp $code } else { $null }
    if ($help) { $sdText += " ($($code.ToUpper() -replace '^0X', '0x'): $($help.Meaning))" }
    $fix  = if ($fixText) { [string]$fixText } elseif ($help -and $help.Fix) { $help.Fix } else { 'Fix that, then try the upgrade again.' }
    if (-not $when) { Add-Finding 'Upgrade' 'Last failed upgrade' 'INFO' "SetupDiag (date unknown, may be old): $sdText" $fix; return }
    $whenText = Format-Date $when
    $stale = (($now - $when).TotalDays -gt 90) -or ($installDate -and $when -lt $installDate)
    if ($stale) { Add-Finding 'Upgrade' 'Last failed upgrade' 'INFO' "SetupDiag ($whenText, old): $sdText" }
    else { Add-Finding 'Upgrade' 'Last failed upgrade' 'WARN' "SetupDiag ($whenText): $sdText" $fix }
}

Invoke-Check 'Upgrade' {
    $bt = '{0}\$WINDOWS.~BT' -f $SysDrive
    if (Test-PathSafe $bt) {
        $t = (Get-Item -LiteralPath $bt -Force).LastWriteTime
        Add-Finding 'Upgrade' 'Setup files' 'INFO' ("Windows Setup files are on the drive ({0}, last changed {1})" -f $bt, (Get-AgeText $t)) 'Normal while a feature update is on its way; Disk Cleanup removes them once it''s done or abandoned.'
    }
}

# ================================================================================================
#  Activity: anything installing right now?
# ================================================================================================
$Running = @()
Invoke-Check 'Activity' {
    $script:Running = @(Get-ServicingProcess)
    if (-not $Running.Count) { Add-Finding 'Activity' 'Installing now' 'PASS' 'No update or Setup processes running'; return }
    $parts = foreach ($p in $Running) {
        $bits = @()
        if ($null -ne $p.Cpu) { $bits += 'CPU {0:N0} s' -f $p.Cpu }
        if ($p.Start) { $bits += 'running ' + ((Get-AgeText $p.Start) -replace ' ago$', '') }
        if ($bits.Count) { '{0} ({1})' -f $p.Name, ($bits -join ', ') } else { $p.Name }
    }
    $setup = @($Running | Where-Object { $_.Name -match '^(SetupHost|SetupPrep|WindowsUpdateBox|Windows10UpgraderApp|Windows11InstallationAssistant)$' }).Count
    $what  = if ($setup) { 'A feature update / upgrade is running: ' } else { 'Updating right now: ' }
    Add-Finding 'Activity' 'Installing now' 'INFO' ($what + ($parts -join ', ')) 'Give it time. Run again with -Watch to see whether it''s moving.'
}

# ================================================================================================
#  Report
# ================================================================================================
$rank = { param($f) $i = [array]::IndexOf($AreaOrder, $f.Area); if ($i -lt 0) { 99 } else { $i } }
$attention = @($Findings | Where-Object { $_.Status -in 'FAIL', 'WARN' } |
    Sort-Object @{ e = { if ($_.Status -eq 'FAIL') { 0 } else { 1 } } }, @{ e = { & $rank $_ } }, Order)
$fine      = @($Findings | Where-Object { $_.Status -in 'PASS', 'INFO' } | Sort-Object @{ e = { & $rank $_ } }, Order)
$fails     = @($attention | Where-Object Status -eq 'FAIL').Count
$warns     = $attention.Count - $fails

$managedText = if ($Managers.Count) { $Managers -join ', ' } else { 'no update policies' }
$patchText   = if ($lastPatch) { 'last patch ' + (Format-Date ([datetime]$lastPatch.InstalledOn)) } else { 'last patch unknown' }
$headline    = '{0} | {1} | managed by: {2}' -f $osLabel, $patchText, $managedText

$summary = if ($attention.Count) {
    $names = @($attention | ForEach-Object { $_.Check } | Select-Object -Unique)
    $more  = if ($names.Count -gt 5) { " (+$($names.Count - 5) more)" } else { '' }
    '{0} update status - {1} fail, {2} warn: {3}{4}' -f $Computer, $fails, $warns, (($names | Select-Object -First 5) -join ', '), $more
} else { "$Computer update status - no issues found" }

$ResultNames = @{ 1 = 'In progress'; 2 = 'Installed'; 3 = 'Installed (errors)'; 4 = 'FAILED'; 5 = 'Aborted' }
$recent = @($History | Select-Object -First 12)

if ($Quiet) {
    Write-Output $summary
}
else {
    Write-Host ''
    Write-Host ("== Windows Update status - {0} - {1} " -f $Computer, $now.ToString('yyyy-MM-dd HH:mm')).PadRight(78, '=') -ForegroundColor Cyan
    Write-Host "   $headline" -ForegroundColor Gray

    Write-Host ''
    if ($attention.Count) {
        Write-Host ("  NEEDS ATTENTION ({0})" -f $attention.Count) -ForegroundColor $(if ($fails) { 'Red' } else { 'Yellow' })
        foreach ($f in $attention) {
            $colour = if ($f.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
            Write-Host ('   [{0}] ' -f $f.Status) -ForegroundColor $colour -NoNewline
            Write-Host ('{0,-9} {1}: {2}' -f $f.Area, $f.Check, $f.Detail)
            if ($f.Fix) { Write-Host ('{0,19}-> {1}' -f '', $f.Fix) -ForegroundColor DarkGray }
        }
    }
    else { Write-Host '  NOTHING NEEDS ATTENTION' -ForegroundColor Green }

    Write-Host ''
    Write-Host ("  CHECKED AND FINE ({0})" -f $fine.Count) -ForegroundColor Green
    foreach ($f in $fine) {
        Write-Host ('   {0,-9} {1}: {2}' -f $f.Area, $f.Check, $f.Detail) -ForegroundColor DarkGray
        if ($f.Fix -and $f.Status -eq 'INFO') { Write-Host ('{0,15}-> {1}' -f '', $f.Fix) -ForegroundColor DarkGray }
    }

    if ($recent.Count) {
        Write-Host ''
        Write-Host '  RECENT UPDATES (Windows Update history)' -ForegroundColor Cyan
        foreach ($h in $recent) {
            $res   = if ($ResultNames.ContainsKey($h.Result)) { $ResultNames[$h.Result] } else { "result $($h.Result)" }
            $code  = if ($h.Result -in 4, 5 -and $h.Code) { "  $($h.Code)" } else { '' }
            $title = if ($h.Title.Length -gt 80) { $h.Title.Substring(0, 77) + '...' } else { $h.Title }
            $colour = if ($h.Result -in 4, 5) { 'Yellow' } else { 'DarkGray' }
            Write-Host ('   {0}  {1,-18} {2}{3}' -f $h.Date.ToString('yyyy-MM-dd'), $res, $title, $code) -ForegroundColor $colour
        }
    }
    elseif ($historyError) {
        Write-Host ''
        Write-Host "  (Couldn't read Windows Update's history: $historyError)" -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host "  Summary: $summary" -ForegroundColor Cyan
}

if ($Html) {
    if (-not (Test-Path -LiteralPath $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
    $file = Join-Path $ReportFolder ('Updates_{0}_{1:yyyyMMdd-HHmm}.html' -f $Computer, $now)
    $enc  = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $rows = {
        param($list, [switch]$WithFix)
        foreach ($f in $list) {
            $fix = if ($f.Fix -and ($WithFix -or $f.Status -eq 'INFO')) { "<div class=""fix"">&rarr; $(& $enc $f.Fix)</div>" } else { '' }
            "<tr class=""$($f.Status.ToLower())""><td class=""st"">$($f.Status)</td><td>$(& $enc $f.Area)</td><td>$(& $enc $f.Check)</td><td>$(& $enc $f.Detail)$fix</td></tr>"
        }
    }
    $attHtml  = if ($attention.Count) { "<table>$((& $rows $attention -WithFix) -join '')</table>" } else { '<p class="ok">Nothing needs attention.</p>' }
    $fineHtml = "<table>$((& $rows $fine) -join '')</table>"
    $histHtml = if ($recent.Count) {
        $hr = foreach ($h in $recent) {
            $res = if ($ResultNames.ContainsKey($h.Result)) { $ResultNames[$h.Result] } else { "result $($h.Result)" }
            $cls = if ($h.Result -in 4, 5) { ' class="hfail"' } else { '' }
            $code = if ($h.Result -in 4, 5) { $h.Code } else { '' }
            "<tr$cls><td>$($h.Date.ToString('yyyy-MM-dd HH:mm'))</td><td>$(& $enc $res)</td><td>$(& $enc $h.Title)</td><td>$(& $enc $code)</td></tr>"
        }
        "<h2>Recent updates ($($recent.Count))</h2><table>$($hr -join '')</table>"
    } elseif ($historyError) { "<h2>Recent updates</h2><p class=""fix"">Couldn't read Windows Update's history: $(& $enc $historyError)</p>" } else { '' }
    $polHtml = if ($PolicyRows.Count) {
        $pr = foreach ($p in $PolicyRows) { "<tr><td>$(& $enc $p.Source)</td><td>$(& $enc $p.Key)</td><td>$(& $enc $p.Name)</td><td>$(& $enc $p.Value)</td></tr>" }
        "<h2>Update policies on this PC ($($PolicyRows.Count))</h2><table>$($pr -join '')</table>"
    } else { '<h2>Update policies on this PC</h2><p class="fix">None set.</p>' }
    $page = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Windows Update status - $Computer</title>
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; max-width: 1100px; }
 h1 { font-size: 20px; margin-bottom: 2px; } .sub { color: #656d76; margin-bottom: 14px; }
 h2 { font-size: 15px; margin: 20px 0 6px; border-bottom: 2px solid #0969da; padding-bottom: 3px; }
 .summary { background: #f6f8fa; border: 1px solid #d0d7de; padding: 8px 12px; font-family: Consolas, monospace; font-size: 13px; }
 table { border-collapse: collapse; font-size: 13px; width: 100%; }
 td { border-bottom: 1px solid #d0d7de; padding: 5px 8px; vertical-align: top; }
 td.st { font-weight: 600; width: 44px; } tr.fail td.st { color: #cf222e; } tr.warn td.st { color: #9a6700; }
 tr.pass td.st { color: #1a7f37; } tr.info td.st { color: #656d76; } tr.hfail td { color: #9a6700; }
 .fix { color: #656d76; margin-top: 3px; } .ok { color: #1a7f37; font-weight: 600; }
 .foot { color: #656d76; font-size: 12px; margin-top: 16px; }
</style></head><body>
<h1>Windows Update status - $Computer</h1>
<div class="sub">$(& $enc $headline) &middot; $($now.ToString('yyyy-MM-dd HH:mm'))</div>
<div class="summary">$(& $enc $summary)</div>
<h2>Needs attention ($($attention.Count))</h2>$attHtml
<h2>Checked and fine ($($fine.Count))</h2>$fineHtml
$histHtml
$polHtml
<p class="foot">End-of-updates dates from Microsoft's Windows release information, checked $TableChecked. Read-only: nothing was changed.</p>
</body></html>
"@
    $page | Set-Content -LiteralPath $file -Encoding UTF8
    if (-not $Quiet) { Write-Host "  Report:  $file" -ForegroundColor Cyan }
    if (-not $NoOpen -and [Environment]::UserInteractive -and -not $PSSenderInfo) {
        try { Invoke-Item -LiteralPath $file } catch { Write-Verbose 'Could not open the report' }
    }
}

# ================================================================================================
#  Watch: one line whenever something moves
# ================================================================================================
if ($Watch) {
    $EventText = @{ 16 = 'can''t connect to the update service'; 19 = 'installed'; 20 = 'FAILED'; 43 = 'install started'; 44 = 'download started' }
    $ticks    = $WatchMinutes * 6
    $prev     = @{}; foreach ($p in @(Get-ServicingProcess)) { $prev["$($p.Name)|$($p.Id)"] = $p }
    $prevLog  = Get-SetupLogState
    $prevRst  = Get-RestartState
    $lastSeen = $now
    $quietTicks = 0
    Write-Host ''
    Write-Host ("  WATCHING update activity for {0} min, every 10 s (Ctrl+C stops)" -f $WatchMinutes) -ForegroundColor Cyan
    for ($i = 1; $i -le $ticks; $i++) {
        Start-Sleep -Seconds 10
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $lines = @()

        $cur = @{}; foreach ($p in @(Get-ServicingProcess)) { $cur["$($p.Name)|$($p.Id)"] = $p }
        foreach ($k in $cur.Keys)  { if (-not $prev.ContainsKey($k)) { $lines += "+ $($cur[$k].Name) started" } }
        foreach ($k in $prev.Keys) { if (-not $cur.ContainsKey($k)) { $lines += "- $($prev[$k].Name) finished" } }
        $busy = foreach ($k in $cur.Keys) {
            if ($prev.ContainsKey($k) -and $null -ne $cur[$k].Cpu -and $null -ne $prev[$k].Cpu) {
                $d = $cur[$k].Cpu - $prev[$k].Cpu
                if ($d -ge 0.5) { '{0} +{1:N1} s CPU' -f $cur[$k].Name, $d }
            }
        }
        if (@($busy).Count) { $lines += 'busy: ' + (@($busy) -join ', ') }

        $events = Get-RecentEvent @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; StartTime = $lastSeen } 50
        foreach ($e in @($events | Where-Object { $_.TimeCreated -gt $lastSeen } | Sort-Object TimeCreated)) {
            $what = if ($EventText.ContainsKey([int]$e.Id)) { $EventText[[int]$e.Id] } else { "event $($e.Id)" }
            $msg  = (([string]$e.Message) -split "`r?`n")[0] -replace '\s+', ' '
            $name = ($msg -replace '^.*:\s*', '').Trim()
            $code = [regex]::Match($msg, '0x[0-9A-Fa-f]{8}').Value
            $extra = if ([int]$e.Id -eq 20 -and $code) { " ($code - $((Get-CodeHelp $code).Meaning))" } else { '' }
            if ($name.Length -gt 110) { $name = $name.Substring(0, 107) + '...' }
            $lines += "update ${what}: $name$extra"
            if ($e.TimeCreated -gt $lastSeen) { $lastSeen = $e.TimeCreated }
        }

        $log = Get-SetupLogState
        if ($log -and (-not $prevLog -or $log.Length -gt $prevLog.Length)) {
            $grew = if ($prevLog) { '+{0:N0} KB' -f (($log.Length - $prevLog.Length) / 1KB) } else { 'started' }
            $tail = ''
            try { $tail = [string](Get-Content -LiteralPath $log.Path -Tail 1 -ErrorAction Stop) } catch { $tail = '' }
            $tail = ($tail -replace '\s+', ' ').Trim()
            if ($tail.Length -gt 110) { $tail = $tail.Substring(0, 107) + '...' }
            $lines += "Setup log $grew" + $(if ($tail) { ": $tail" } else { '' })
        }
        $prevLog = $log

        $rst = Get-RestartState
        if (($rst.Updates -and -not $prevRst.Updates) -or ($rst.Servicing -and -not $prevRst.Servicing)) { $lines += '! a restart is now needed to finish' }
        $prevRst = $rst

        if ($lines.Count) {
            $quietTicks = 0
            foreach ($l in $lines) { Write-Host "   $stamp  $l" -ForegroundColor $(if ($l -match 'FAILED|^!') { 'Yellow' } else { 'Gray' }) }
        }
        else {
            $quietTicks++
            if ($quietTicks % 6 -eq 0) {
                $state = if ($cur.Count) { 'still running, idle: ' + ((@($cur.Values | ForEach-Object { $_.Name }) | Select-Object -Unique) -join ', ') } else { 'quiet: nothing installing' }
                Write-Host "   $stamp  $state" -ForegroundColor DarkGray
            }
        }
        $prev = $cur
    }
    Write-Host ("   Watch ended after {0} min." -f $WatchMinutes) -ForegroundColor Cyan
}

# .ToArray(), not @(): PowerShell 7.5 throws "Argument types do not match" on @(List) inside an object literal.
if ($PassThru) {
    [pscustomobject]@{
        Summary  = $summary
        Version  = [pscustomobject]@{ Name = $osName; Edition = $edName; EditionId = $editionId; Version = $display; Build = $buildText; Family = $family }
        Findings = $Findings.ToArray()
        History  = $recent
        Policies = $PolicyRows.ToArray()
        Managers = $Managers.ToArray()
    }
}
if ($fails) { exit 1 }
exit 0
