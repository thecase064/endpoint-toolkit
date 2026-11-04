<#
.SYNOPSIS
    One-page hardware and OS inventory for a Windows device: model, serial, CPU, RAM sticks, disks and
    their health, monitors with serials, battery wear, network and security state.

.DESCRIPTION
    Pulls together what you'd otherwise dig out of a dozen WMI classes and Storage cmdlets:

      System    manufacturer, model, serial, BIOS version/date, join state
      OS        edition, version (e.g. 24H2), full build, install date, uptime
      CPU       name, cores/threads, clock
      Memory    every stick: slot, size, type (DDR4/DDR5...), speed, part number; slots used/total
      Disks     model, SSD/HDD, NVMe/SATA, size, health; wear, temperature and power-on hours (admin)
      Volumes   size, free space, BitLocker status (admin)
      Monitors  make, model, serial, manufacture year, connection (HDMI/DP/built-in)
      Battery   design vs full-charge capacity = wear %, cycle count (where the firmware reports it)
      Network   IP-enabled adapters: IPv4, MAC, gateway, DNS, DHCP
      Security  TPM, Secure Boot

    Read-only. Runs as a standard user; elevated adds disk reliability counters, BitLocker, TPM and battery detail.
    Each section fails on its own, so one broken WMI class doesn't sink the report.

.PARAMETER Html
    Also write a self-contained HTML report (and open it, when run locally and interactively).

.PARAMETER Json
    Also write the inventory as JSON (handy for diffing a machine before and after a rebuild).

.PARAMETER ReportFolder
    Where -Html / -Json files go. Default C:\DeviceInventory (created if missing).

.PARAMETER NoOpen
    Don't open the HTML report after writing it.

.PARAMETER Quiet
    No console output (use with -PassThru, -Html or -Json).

.PARAMETER PassThru
    Emit the inventory object to the pipeline.

.EXAMPLE
    .\Get-DeviceInventory.ps1

.EXAMPLE
    .\Get-DeviceInventory.ps1 -Html -Json

.EXAMPLE
    Invoke-Command -ComputerName PC-1234 -FilePath .\Get-DeviceInventory.ps1

.EXAMPLE
    (.\Get-DeviceInventory.ps1 -Quiet -PassThru).Monitors | Format-Table

.NOTES
    Built-in laptop panels usually report serial 0 and a panel-maker code (CMN, AUO, BOE, LGD, SHP, SDC...),
    not the laptop brand. That's the panel, not a bug.
    Disk wear is the percentage of rated life used, as the drive reports it. Not every drive does.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Html,
    [switch] $Json,
    [string] $ReportFolder = (Join-Path $env:SystemDrive 'DeviceInventory'),
    [switch] $NoOpen,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------------------------
#  Lookups
# ------------------------------------------------------------------------------------------------
$MemoryTypes = @{
    18 = 'DDR'; 19 = 'DDR2'; 20 = 'DDR2 FB-DIMM'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'
    29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5'
}
$FormFactors = @{ 8 = 'DIMM'; 12 = 'SO-DIMM'; 13 = 'SRIMM'; 21 = 'BGA (soldered)'; 23 = 'LGA' }
$Connections = @{
    -1 = 'Other'; 0 = 'VGA'; 1 = 'S-Video'; 2 = 'Composite'; 3 = 'Component'; 4 = 'DVI'; 5 = 'HDMI'
    6 = 'Built-in (LVDS)'; 10 = 'DisplayPort'; 11 = 'Built-in (eDP)'; 15 = 'Miracast'; 16 = 'USB / dock'
}
$PanelMakers = @{
    ACR = 'Acer'; AOC = 'AOC'; APP = 'Apple'; AUO = 'AU Optronics (panel)'; BNQ = 'BenQ'; BOE = 'BOE (panel)'
    CMN = 'Chimei Innolux (panel)'; DEL = 'Dell'; ENC = 'Eizo'; GSM = 'LG'; HPN = 'HP'; HWP = 'HP'; IVO = 'InfoVision (panel)'
    LEN = 'Lenovo'; LGD = 'LG Display (panel)'; MSI = 'MSI'; NEC = 'NEC'; PHL = 'Philips'; SAM = 'Samsung'
    SDC = 'Samsung Display (panel)'; SHP = 'Sharp (panel)'; SNY = 'Sony'; VSC = 'ViewSonic'; IIY = 'iiyama'; HKC = 'HKC'
}

$IsElevated = $false
try {
    $IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch { Write-Verbose 'Could not determine elevation' }

$Notes = New-Object System.Collections.Generic.List[string]

function Invoke-Section {
    # Runs one section; on failure records a note and returns $null instead of killing the report.
    param([string] $Name, [scriptblock] $Body)
    try { & $Body }
    catch {
        $Notes.Add("$Name - $($_.Exception.Message)")
        $null
    }
}

function ConvertFrom-WmiString {
    # WmiMonitorID fields are uint16 arrays padded with zeros.
    param($Codes)
    if (-not $Codes) { return $null }
    $s = -join (@($Codes) | Where-Object { $_ -gt 0 } | ForEach-Object { [char][int]$_ })
    $s = $s.Trim()
    if ($s) { $s } else { $null }
}

function Format-Size {
    param([double] $Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N0} GB' -f ($Bytes / 1GB) }
    '{0:N0} MB' -f ($Bytes / 1MB)
}

# ------------------------------------------------------------------------------------------------
#  Sections
# ------------------------------------------------------------------------------------------------
$cs   = Invoke-Section 'ComputerSystem' { Get-CimInstance -ClassName Win32_ComputerSystem }
$bios = Invoke-Section 'BIOS'           { Get-CimInstance -ClassName Win32_BIOS }
$csp  = Invoke-Section 'Product'        { Get-CimInstance -ClassName Win32_ComputerSystemProduct }
$os   = Invoke-Section 'OS'             { Get-CimInstance -ClassName Win32_OperatingSystem }

$system = Invoke-Section 'System' {
    $joinKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
    $entra   = Test-Path -LiteralPath $joinKey
    $join = if ($entra -and $cs.PartOfDomain) { "Hybrid Entra joined ($($cs.Domain))" }
            elseif ($entra)                   { 'Entra joined' }
            elseif ($cs.PartOfDomain)         { "Domain joined ($($cs.Domain))" }
            else                              { "Workgroup ($($cs.Domain))" }
    # Lenovo keeps the marketing name (e.g. "ThinkPad T14 Gen 4") in Product.Version; the Model is a machine type.
    $friendly = if ($cs.Manufacturer -match 'Lenovo' -and $csp.Version) { $csp.Version } else { $cs.Model }
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        Manufacturer = $cs.Manufacturer
        Model        = $friendly
        ModelNumber  = if ($friendly -ne $cs.Model) { $cs.Model } else { $null }
        SerialNumber = $bios.SerialNumber
        BIOSVersion  = $bios.SMBIOSBIOSVersion
        BIOSDate     = if ($bios.ReleaseDate) { ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') } else { $null }
        JoinState    = $join
        LoggedOnUser = $cs.UserName
    }
}

$osInfo = Invoke-Section 'OS' {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = if ($cv -and $null -ne $cv.UBR) { '{0}.{1}' -f $os.BuildNumber, $cv.UBR } else { $os.BuildNumber }
    # Windows 11 still says "Windows 10" in ProductName on some builds; the build number doesn't lie.
    $caption = $os.Caption -replace '^Microsoft\s+', ''
    if ([int]$os.BuildNumber -ge 22000) { $caption = $caption -replace 'Windows 10', 'Windows 11' }
    $uptime = (Get-Date) - [datetime]$os.LastBootUpTime
    [pscustomobject]@{
        Edition      = $caption
        Version      = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
        Build        = $build
        Architecture = $os.OSArchitecture
        InstallDate  = ([datetime]$os.InstallDate).ToString('yyyy-MM-dd')
        LastBoot     = ([datetime]$os.LastBootUpTime).ToString('yyyy-MM-dd HH:mm')
        Uptime       = '{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes
    }
}

$cpu = Invoke-Section 'CPU' {
    @(Get-CimInstance -ClassName Win32_Processor) | ForEach-Object {
        [pscustomobject]@{
            Name     = ($_.Name -replace '\s+', ' ').Trim()
            Cores    = $_.NumberOfCores
            Threads  = $_.NumberOfLogicalProcessors
            MaxClock = '{0:N2} GHz' -f ($_.MaxClockSpeed / 1000)
        }
    }
}

$memory = Invoke-Section 'Memory' {
    $sticks = @(Get-CimInstance -ClassName Win32_PhysicalMemory)
    $array  = @(Get-CimInstance -ClassName Win32_PhysicalMemoryArray) | Where-Object { $_.Use -eq 3 -or -not $_.Use } | Select-Object -First 1
    $modules = foreach ($m in $sticks) {
        $typeCode = [int]$m.SMBIOSMemoryType
        [pscustomobject]@{
            Slot         = if ($m.DeviceLocator) { $m.DeviceLocator } else { $m.BankLabel }
            Size         = Format-Size $m.Capacity
            Type         = if ($MemoryTypes.ContainsKey($typeCode)) { $MemoryTypes[$typeCode] } else { "Unknown ($typeCode)" }
            FormFactor   = if ($FormFactors.ContainsKey([int]$m.FormFactor)) { $FormFactors[[int]$m.FormFactor] } else { "Other ($($m.FormFactor))" }
            SpeedMHz     = if ($m.ConfiguredClockSpeed) { $m.ConfiguredClockSpeed } else { $m.Speed }
            RatedMHz     = $m.Speed
            Manufacturer = ([string]$m.Manufacturer).Trim()
            PartNumber   = ([string]$m.PartNumber).Trim()
            Serial       = ([string]$m.SerialNumber).Trim()
        }
    }
    $total = ($sticks | Measure-Object -Property Capacity -Sum).Sum
    $maxGB = $null
    if ($array) {
        $maxKB = if ($array.MaxCapacityEx) { [double]$array.MaxCapacityEx } else { [double]$array.MaxCapacity }
        if ($maxKB -gt 0) { $maxGB = [math]::Round($maxKB / 1MB) }
    }
    [pscustomobject]@{
        Total     = Format-Size $total
        SlotsUsed = $sticks.Count
        Slots     = if ($array -and $array.MemoryDevices) { $array.MemoryDevices } else { $null }
        MaxGB     = $maxGB
        Modules   = @($modules)
    }
}

$disks = Invoke-Section 'Disks' {
    $physical = @(Get-PhysicalDisk | Sort-Object { [int]$_.DeviceId })
    foreach ($d in $physical) {
        $rel = $null
        if ($IsElevated) {
            try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $rel = $null }
        }
        [pscustomobject]@{
            Disk          = $d.DeviceId
            Model         = ([string]$d.FriendlyName).Trim()
            Media         = [string]$d.MediaType
            Bus           = [string]$d.BusType
            Size          = Format-Size $d.Size
            Health        = [string]$d.HealthStatus
            Status        = ($d.OperationalStatus -join ', ')
            WearPercent   = if ($rel -and $null -ne $rel.Wear) { $rel.Wear } else { $null }
            TemperatureC  = if ($rel -and $rel.Temperature) { $rel.Temperature } else { $null }
            PowerOnHours  = if ($rel -and $rel.PowerOnHours) { $rel.PowerOnHours } else { $null }
            Serial        = ([string]$d.SerialNumber).Trim()
        }
    }
}
if (-not $disks) {
    # Storage module unavailable (or no rights) - fall back to plain WMI.
    $disks = Invoke-Section 'Disks (WMI fallback)' {
        @(Get-CimInstance -ClassName Win32_DiskDrive) | ForEach-Object {
            [pscustomobject]@{
                Disk = $_.Index; Model = $_.Model; Media = $_.MediaType; Bus = $_.InterfaceType; Size = Format-Size $_.Size
                Health = $_.Status; Status = $null; WearPercent = $null; TemperatureC = $null; PowerOnHours = $null
                Serial = ([string]$_.SerialNumber).Trim()
            }
        }
    }
}

$volumes = Invoke-Section 'Volumes' {
    $bitlocker = @{}
    if ($IsElevated -and (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        try {
            foreach ($b in @(Get-BitLockerVolume -ErrorAction Stop)) {
                $bitlocker[[string]$b.MountPoint] = '{0} ({1}%)' -f $b.ProtectionStatus, $b.EncryptionPercentage
            }
        }
        catch { $Notes.Add("BitLocker - $($_.Exception.Message)") }
    }
    @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3') | ForEach-Object {
        $pct = if ($_.Size) { [int][math]::Round(100 * $_.FreeSpace / $_.Size) } else { $null }
        [pscustomobject]@{
            Drive       = $_.DeviceID
            Label       = $_.VolumeName
            FileSystem  = $_.FileSystem
            Size        = Format-Size $_.Size
            Free        = Format-Size $_.FreeSpace
            FreePercent = $pct
            BitLocker   = if ($bitlocker.ContainsKey([string]$_.DeviceID)) { $bitlocker[[string]$_.DeviceID] }
                          elseif ($IsElevated) { 'Not found' } else { 'needs admin' }
        }
    }
}

$monitors = Invoke-Section 'Monitors' {
    $conn = @{}
    try {
        foreach ($c in @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop)) {
            $conn[[string]$c.InstanceName] = [int64]$c.VideoOutputTechnology
        }
    }
    catch { Write-Verbose 'No monitor connection data' }

    @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID) | ForEach-Object {
        $code   = ConvertFrom-WmiString $_.ManufacturerName
        $tech   = $conn[[string]$_.InstanceName]
        $techName = if ($null -eq $tech) { $null }
                    elseif ($tech -eq 2147483648 -or $tech -eq -2147483648) { 'Built-in' }
                    elseif ($Connections.ContainsKey([int]$tech)) { $Connections[[int]$tech] }
                    else { "Other ($tech)" }
        [pscustomobject]@{
            Make       = if ($code -and $PanelMakers.ContainsKey($code)) { $PanelMakers[$code] } else { $code }
            Model      = ConvertFrom-WmiString $_.UserFriendlyName
            Serial     = ConvertFrom-WmiString $_.SerialNumberID
            ProductId  = ConvertFrom-WmiString $_.ProductCodeID
            Year       = if ($_.YearOfManufacture) { $_.YearOfManufacture } else { $null }
            Connection = $techName
        }
    }
}

$battery = Invoke-Section 'Battery' {
    $present = @(Get-CimInstance -ClassName Win32_Battery)
    if (-not $present) { return $null }
    $design = $null; $full = $null; $cycles = $null
    try {
        $design = (@(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop) | Select-Object -First 1).DesignedCapacity
        $full   = (@(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop) | Select-Object -First 1).FullChargedCapacity
    }
    catch { Write-Verbose 'Battery capacity classes unavailable' }
    try {
        $cycles = (@(Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop) | Select-Object -First 1).CycleCount
    }
    catch { Write-Verbose 'Battery cycle count unavailable' }
    $healthPct = if ($design -and $full) { [int][math]::Round(100 * $full / $design) } else { $null }
    [pscustomobject]@{
        Name           = $present[0].Name
        ChargePercent  = $present[0].EstimatedChargeRemaining
        DesignmWh      = $design
        FullChargemWh  = $full
        HealthPercent  = $healthPct
        CycleCount     = if ($cycles) { $cycles } else { $null }
        Note           = if (-not $healthPct -and -not $IsElevated) { 'capacity needs admin' } else { $null }
    }
}

$network = Invoke-Section 'Network' {
    @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True') | ForEach-Object {
        [pscustomobject]@{
            Adapter = $_.Description
            IPv4    = (@($_.IPAddress) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ', '
            MAC     = $_.MACAddress
            Gateway = (@($_.DefaultIPGateway) | Where-Object { $_ }) -join ', '
            DNS     = (@($_.DNSServerSearchOrder) | Where-Object { $_ }) -join ', '
            DHCP    = [bool]$_.DHCPEnabled
        }
    }
}

$security = Invoke-Section 'Security' {
    $sbKey = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue
    $secureBoot = if ($null -eq $sbKey) { 'Not supported (legacy BIOS?)' } elseif ($sbKey.UEFISecureBootEnabled -eq 1) { 'On' } else { 'Off' }
    $tpm = 'needs admin'
    if ($IsElevated) {
        try {
            $t = Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction Stop
            $tpm = if (-not $t) { 'Not found' }
                   else {
                       $spec = ([string]$t.SpecVersion -split ',')[0].Trim()
                       '{0}, {1} (spec {2})' -f $(if ($t.IsEnabled_InitialValue) { 'Enabled' } else { 'Disabled' }),
                           $(if ($t.IsActivated_InitialValue) { 'activated' } else { 'not activated' }), $spec
                   }
        }
        catch { $tpm = "Unavailable ($($_.Exception.Message))" }
    }
    [pscustomobject]@{ SecureBoot = $secureBoot; TPM = $tpm }
}

$inventory = [pscustomobject]@{
    Generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    Elevated  = $IsElevated
    System    = $system
    OS        = $osInfo
    CPU       = @($cpu)
    Memory    = $memory
    Disks     = @($disks)
    Volumes   = @($volumes)
    Monitors  = @($monitors)
    Battery   = $battery
    Network   = @($network)
    Security  = $security
    Notes     = @($Notes)
}

# ------------------------------------------------------------------------------------------------
#  Console
# ------------------------------------------------------------------------------------------------
function Write-Block {
    param([string] $Title, $Data, [switch] $Table)
    Write-Host ''
    Write-Host ('== {0} ' -f $Title).PadRight(72, '=') -ForegroundColor Cyan
    if (-not $Data) { Write-Host '  (nothing found)' -ForegroundColor DarkGray; return }
    # Out-String rather than Out-Host so tables still render over Invoke-Command.
    if ($Table) { ($Data | Format-Table -AutoSize | Out-String -Width 200).TrimEnd() | Write-Host }
    else        { ($Data | Format-List | Out-String -Width 200).Trim() | Write-Host }
}

if (-not $Quiet) {
    Write-Block 'System' $system
    Write-Block 'Operating system' $osInfo
    Write-Block 'CPU' $cpu -Table
    if ($memory) {
        Write-Block ('Memory - {0}, {1} of {2} slots used{3}' -f $memory.Total, $memory.SlotsUsed,
            $(if ($memory.Slots) { $memory.Slots } else { '?' }), $(if ($memory.MaxGB) { ", max $($memory.MaxGB) GB" } else { '' })) `
            ($memory.Modules | Select-Object Slot, Size, Type, FormFactor, SpeedMHz, Manufacturer, PartNumber) -Table
    }
    else { Write-Block 'Memory' $null }
    Write-Block 'Disks' ($disks | Select-Object Disk, Model, Media, Bus, Size, Health, WearPercent, TemperatureC, PowerOnHours) -Table
    Write-Block 'Volumes' $volumes -Table
    Write-Block 'Monitors' $monitors -Table
    if ($battery) { Write-Block 'Battery' $battery }
    Write-Block 'Network' ($network | Select-Object Adapter, IPv4, MAC, Gateway, DHCP) -Table
    Write-Block 'Security' $security
    if (-not $IsElevated) {
        Write-Host "`n  Not elevated: disk wear/temperature, BitLocker, TPM and battery capacity need admin." -ForegroundColor Yellow
    }
    foreach ($n in $Notes) { Write-Host "  Skipped: $n" -ForegroundColor DarkYellow }
}

# ------------------------------------------------------------------------------------------------
#  Files
# ------------------------------------------------------------------------------------------------
if ($Html -or $Json) {
    if (-not (Test-Path -LiteralPath $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }
    $base = Join-Path $ReportFolder ('Inventory_{0}_{1:yyyyMMdd-HHmm}' -f $env:COMPUTERNAME, (Get-Date))

    if ($Json) {
        $inventory | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$base.json" -Encoding UTF8
        if (-not $Quiet) { Write-Host "`n  JSON:   $base.json" -ForegroundColor Cyan }
    }

    if ($Html) {
        $css = @'
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1f2328; }
 h1 { font-size: 20px; margin-bottom: 2px; } .sub { color: #656d76; margin-bottom: 18px; }
 h2 { font-size: 15px; margin: 22px 0 6px; border-bottom: 2px solid #0969da; padding-bottom: 3px; }
 table { border-collapse: collapse; font-size: 13px; }
 th, td { border: 1px solid #d0d7de; padding: 4px 8px; text-align: left; vertical-align: top; }
 th { background: #f6f8fa; }
 .note { color: #9a6700; font-size: 12px; }
</style>
'@
        $sections = New-Object System.Text.StringBuilder
        $add = {
            param($Title, $Data, [switch]$List)
            [void]$sections.Append("<h2>$([Net.WebUtility]::HtmlEncode($Title))</h2>")
            if (-not $Data) { [void]$sections.Append('<p class="note">Nothing found.</p>'); return }
            $as = if ($List) { 'List' } else { 'Table' }
            [void]$sections.Append(($Data | ConvertTo-Html -Fragment -As $as | Out-String))
        }
        & $add 'System' $system -List
        & $add 'Operating system' $osInfo -List
        & $add 'CPU' $cpu
        if ($memory) {
            & $add ('Memory - {0}, {1} of {2} slots used' -f $memory.Total, $memory.SlotsUsed, $(if ($memory.Slots) { $memory.Slots } else { '?' })) $memory.Modules
        }
        & $add 'Disks' $disks
        & $add 'Volumes' $volumes
        & $add 'Monitors' $monitors
        if ($battery) { & $add 'Battery' $battery -List }
        & $add 'Network' $network
        & $add 'Security' $security -List
        foreach ($n in $Notes) { [void]$sections.Append("<p class=""note"">Skipped: $([Net.WebUtility]::HtmlEncode($n))</p>") }

        $title = 'Device inventory - {0}' -f $env:COMPUTERNAME
        $page  = "<!DOCTYPE html><html><head><meta charset=""utf-8""><title>$title</title>$css</head><body>" +
                 "<h1>$title</h1><div class=""sub"">$($system.Manufacturer) $($system.Model) &middot; serial $($system.SerialNumber) &middot; generated $($inventory.Generated)$(if (-not $IsElevated) { ' &middot; not elevated, some detail missing' })</div>" +
                 $sections.ToString() + '</body></html>'
        $page | Set-Content -LiteralPath "$base.html" -Encoding UTF8
        if (-not $Quiet) { Write-Host "  Report: $base.html" -ForegroundColor Cyan }
        if (-not $NoOpen -and [Environment]::UserInteractive -and -not $PSSenderInfo) {
            try { Invoke-Item -LiteralPath "$base.html" } catch { Write-Verbose 'Could not open the report' }
        }
    }
}

if ($PassThru) { $inventory }
