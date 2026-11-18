<#
.SYNOPSIS
    Explains Windows error codes, offline: paste a code (or a whole error message) and get what it
    means, from the toolkit's own notes and from Windows itself.

.DESCRIPTION
    Takes one or more codes, or a pasted error line / log text, and finds every code in it:
    0x80070005, 80070005, -2147024891, 2147942405, AADSTS700003, "code 43", "exit code 3010", and
    Windows Setup pairs like 0xC1900101 - 0x40017.

    For each code it shows:
      Toolkit   What the toolkit already knows about it, with what to do: Windows Update / upgrade,
                Windows Time, Device Manager problem codes, Dell Command | Update and HP Image Assistant
                exit codes, Entra / Intune join errors (Tools\Shared\ErrorCodes.psd1).
      Windows   Windows' own name and message for it (certutil -error, built into Windows), and for
                NTSTATUS codes like 0xC0000005 the Windows error they map to.
      Decoded   What the number itself says: a Win32 error wrapped as an HRESULT, the facility it comes
                from (Windows Update, BITS, Setup...), or a vendor's own code.
      Setup     For upgrade failures, the phase and operation from the extend code.
      Stop code For blue screen codes (0x0000007E, 0x00000133...), the name and the usual cause.

    Nothing is looked up online and nothing is changed.

.PARAMETER Code
    The code(s), or text containing them. Several codes, or a whole pasted message, are fine.

.PARAMETER Quiet
    One line per code: the code and its best explanation.

.PARAMETER PassThru
    Emit one object per code.

.EXAMPLE
    .\Resolve-ErrorCode.ps1 0x800F0922

.EXAMPLE
    .\Resolve-ErrorCode.ps1 'We couldn''t install Windows 11. 0xC1900101 - 0x40017'

.EXAMPLE
    .\Resolve-ErrorCode.ps1 -2147024891 'code 43' AADSTS700003

.NOTES
    No admin needed. Exit codes: 0 = explained at least one code, 1 = no code found in the input.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]] $Code,
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$Shared = Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared'
. (Join-Path $Shared 'Helpers.ps1')

$NativeCs = @'
using System.Runtime.InteropServices;
namespace EtkErrorCode {
    public static class Native {
        // Maps an NTSTATUS to the Win32 error Windows would report for it (317 = no mapping).
        [DllImport("ntdll.dll")]
        public static extern int RtlNtStatusToDosError(int status);
    }
}
'@
$NoMapping = 317   # ERROR_MR_MID_NOT_FOUND

# 32-bit constants as int64: PowerShell reads 0x80000000 and up as negative 32-bit numbers.
$Bit31     = [int64]2147483648    # 0x80000000
$Win32Base = [int64]2147942400    # 0x80070000, HRESULT_FROM_WIN32
$SevError  = [int64]3221225472    # 0xC0000000
$HighWord  = [int64]4294901760    # 0xFFFF0000
$MVariant  = [int64]268435456     # 0x10000000, the "_M" stop code variants
$Mask32    = [int64]4294967295

# ================================================================================================
#  The toolkit's own codes
# ================================================================================================
function ConvertTo-Key {
    # A 32-bit code as a non-negative int64, however it was written or read (0xC000021A reads as negative).
    param($Value)
    [int64]$Value -band $script:Mask32
}

$Table = $null
$TableError = $null
try { $Table = Import-PowerShellDataFile -LiteralPath (Join-Path $Shared 'ErrorCodes.psd1') }
catch { $TableError = $_.Exception.Message }

$Known = @{}        # int64 -> entries, for hex and numeric codes
$KnownText = @{}    # upper-case text -> entries, for AADSTS and the like
$Facilities = @{}; $Phases = @{}; $Operations = @{}; $StopCodes = @{}
if ($Table) {
    foreach ($e in @($Table.Codes)) {
        $c = [string]$e.Code
        $k = $null
        if ($c -match '^0x([0-9A-Fa-f]{1,8})$') { $k = [Convert]::ToInt64($Matches[1], 16) }
        elseif ($c -match '^\d{1,10}$') { $k = [int64]$c }
        if ($null -ne $k) { if (-not $Known.ContainsKey($k)) { $Known[$k] = @() }; $Known[$k] += $e }
        else { $u = $c.ToUpperInvariant(); if (-not $KnownText.ContainsKey($u)) { $KnownText[$u] = @() }; $KnownText[$u] += $e }
    }
    foreach ($kv in $Table.Facilities.GetEnumerator()) { $Facilities[(ConvertTo-Key $kv.Key)] = [string]$kv.Value }
    foreach ($kv in $Table.SetupPhases.GetEnumerator()) { $Phases[(ConvertTo-Key $kv.Key)] = [string]$kv.Value }
    foreach ($kv in $Table.SetupOperations.GetEnumerator()) { $Operations[(ConvertTo-Key $kv.Key)] = [string]$kv.Value }
    foreach ($kv in $Table.StopCodes.GetEnumerator()) { $StopCodes[(ConvertTo-Key $kv.Key)] = @($kv.Value) }
}

# ================================================================================================
#  Finding the codes in what was pasted
# ================================================================================================
function Find-Code {
    param([string] $Text)
    $found = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    function Add-Found([string] $Raw, [int64] $Value, [string] $Form, $Extend, [string] $Label) {
        $key = if ($Label) { "T:$Label" } else { "V:$Value|$Form|$Extend" }
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $found.Add([pscustomobject]@{ Raw = $Raw; Value = $Value; Form = $Form; Extend = $Extend; Label = $Label })
    }
    $hits = [System.Collections.Generic.List[object]]::new()
    # Hex, with an optional Setup extend code after a dash.
    foreach ($m in [regex]::Matches($Text, '(?<![0-9A-Za-z])0[xX]([0-9A-Fa-f]{1,8})(?![0-9A-Za-z])(?:\s*[-\u2013]\s*0[xX]([0-9A-Fa-f]{1,5})(?![0-9A-Za-z]))?')) {
        $v = [Convert]::ToInt64($m.Groups[1].Value, 16)
        $ext = $null
        if ($m.Groups[2].Success) {
            $e = [Convert]::ToInt64($m.Groups[2].Value, 16)
            if ($v -ge $Bit31 -and $e -le 0x5FFFF) { $ext = $e }
        }
        $raw = if ($null -ne $ext) { $m.Value } else { '0x' + $m.Groups[1].Value }
        $form = if ($m.Groups[1].Value.Length -eq 8) { 'hex8' } else { 'hex' }
        $hits.Add(@($m.Index, $raw, $v, $form, $ext, $null))
        if ($m.Groups[2].Success -and $null -eq $ext) {
            # Not a Setup pair after all: the second number is a code of its own.
            $hits.Add(@($m.Groups[2].Index, ('0x' + $m.Groups[2].Value), [Convert]::ToInt64($m.Groups[2].Value, 16), 'hex', $null, $null))
        }
    }
    # Bare 8-digit hex the way logs often print it (800f0922): only when it has a letter or starts 8 / C,
    # and never part of a GUID (correlation IDs in Entra errors).
    foreach ($m in [regex]::Matches($Text, '(?<![0-9A-Za-z-])([0-9A-Fa-f]{8})(?![0-9A-Za-z-])')) {
        $t = $m.Groups[1].Value
        if ($t -match '[A-Fa-f]' -or $t -match '^[8Cc]') { $hits.Add(@($m.Index, $t, [Convert]::ToInt64($t, 16), 'hex8', $null, $null)) }
    }
    # Entra sign-in errors.
    foreach ($m in [regex]::Matches($Text, '(?i)\bAADSTS\d{3,}\b')) { $hits.Add(@($m.Index, $m.Value.ToUpperInvariant(), 0, 'text', $null, $m.Value.ToUpperInvariant())) }
    # Decimal HRESULTs, signed or not.
    foreach ($m in [regex]::Matches($Text, '(?<![0-9A-Za-z.])(-?\d{10})(?![0-9])')) {
        $d = [int64]$m.Groups[1].Value
        if ($d -lt 0 -and $d -ge -2147483648) { $hits.Add(@($m.Index, $m.Groups[1].Value, (ConvertTo-Key $d), 'decimal', $null, $null)) }
        elseif ($d -ge 2147483648 -and $d -le 4294967295) { $hits.Add(@($m.Index, $m.Groups[1].Value, $d, 'decimal', $null, $null)) }
    }
    # Small numbers: on their own, or after "code" / "error" / "exit code".
    if ($Text -match '^\s*(\d{1,6})\s*$') { $hits.Add(@(0, $Matches[1], [int64]$Matches[1], 'number', $null, $null)) }
    else {
        foreach ($m in [regex]::Matches($Text, '(?i)\b(?:exit\s+code|error\s+code|code|error)\s*[:#]?\s*(\d{1,6})(?![0-9A-Za-z.])')) {
            $hits.Add(@($m.Groups[1].Index, $m.Groups[1].Value, [int64]$m.Groups[1].Value, 'number', $null, $null))
        }
    }
    foreach ($h in @($hits | Sort-Object { $_[0] })) { Add-Found $h[1] $h[2] $h[3] $h[4] $h[5] }
    $found
}

# ================================================================================================
#  Windows' own explanation
# ================================================================================================
function Get-WindowsText {
    # certutil -error: "0x80070005 (WIN32: 5 ERROR_ACCESS_DENIED) -- 2147942405 (-2147024891)" then
    # "Error message text: Access is denied." (the label is translated on other languages). certutil's
    # answer is final: it reads the same message tables .NET would. Seen on real Windows:
    #   - unknown codes echo back as "Error 0x800f0922 (...)" with no name
    #   - a number with no Windows error behind it (43) can pick up a stray message with %1 blanks and no
    #     name, so a message with blanks only counts when Windows also gave it a name
    #   - real messages can have blanks too (0xC0000005: "...at 0x%p..."): shown as "..."
    param([int64] $Value, [string] $Form)
    $arg = if ($Form -eq 'number') { [string]$Value } else { '0x{0:X8}' -f $Value }
    $r = [pscustomobject]@{ Name = $null; Text = $null; Via = $null }
    $lines = $null
    try { $lines = @(& certutil -error $arg 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) } catch { $lines = $null }
    if ($lines -and $lines.Count -ge 2 -and $lines[0] -match '^\s*0x[0-9A-Fa-f]+\s*\(([^)]*)\)') {
        $inside = $Matches[1]
        $names = @([regex]::Matches($inside, '\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b') | ForEach-Object Value)
        if ($names.Count) { $r.Name = $names[-1] }
        $msg = ($lines[1] -split ':\s*', 2)[-1].Trim()
        if ($msg -and $msg -notmatch '^(Error\s+)?0x[0-9A-Fa-f]+\b') { $r.Text = Format-WindowsText $msg $r.Name }
        $r.Via = 'certutil'
        return $r
    }
    try {
        $signed = if ($Value -gt 0x7FFFFFFF) { $Value - 4294967296 } else { $Value }
        $m = ([ComponentModel.Win32Exception]::new([int]$signed)).Message
        if ($m -and $m -notmatch '^Unknown error') { $r.Text = Format-WindowsText $m $null; if ($r.Text) { $r.Via = 'FormatMessage' } }
    }
    catch { Write-Verbose "No Windows text for ${arg}: $($_.Exception.Message)" }
    $r
}

function Format-WindowsText {
    # Fills message blanks (%1, %p, %s...) with "...", or drops the message when it has blanks but no name.
    param([string] $Text, [string] $Name)
    $blanks = '%(?:\d+(?:![^!]*!)?|[a-zA-Z]{1,2})'
    if ($Text -match $blanks) {
        if (-not $Name) { return $null }
        $Text = [regex]::Replace($Text, $blanks, '...')
    }
    $Text
}

$NativeError = $null
$Native = $null
function Get-NtMapping {
    param([int64] $Value)
    if (-not $script:Native -and -not $script:NativeError) {
        try {
            if (-not ('EtkErrorCode.Native' -as [type])) { Add-Type -TypeDefinition $NativeCs -Language CSharp -ErrorAction Stop }
            $script:Native = 'EtkErrorCode.Native' -as [type]
        }
        catch { $script:NativeError = $_.Exception.Message }
    }
    if (-not $script:Native) { return $null }
    try {
        $w = [int64]$script:Native::RtlNtStatusToDosError([int]($Value - 4294967296))
        if ($w -gt 0 -and $w -ne $NoMapping) { return $w }
    }
    catch { $script:NativeError = $_.Exception.Message }
    $null
}

# ================================================================================================
#  Explain one code
# ================================================================================================
function Get-Explanation {
    param($Item)
    $v = $Item.Value
    $x = [pscustomobject]@{
        Input = $Item.Raw; Hex = $null; Unsigned = $null; Signed = $null; Kind = $null; Facility = $null
        Toolkit = @(); WindowsName = $null; WindowsText = $null; WindowsVia = $null; NtWin32 = $null; NtText = $null
        Setup = $null; StopCode = $null; StopHint = $null; Best = $null
    }
    if ($Item.Label) {
        $x.Kind = 'Entra sign-in error'
        if ($KnownText.ContainsKey($Item.Label)) { $x.Toolkit = @($KnownText[$Item.Label]) }
        $x.Best = if ($x.Toolkit.Count) { "$($x.Toolkit[0].Source): $($x.Toolkit[0].Meaning)" } else { "Entra sign-in error: look it up at login.microsoft.com/error?code=$($Item.Label -replace '^AADSTS', '')" }
        return $x
    }
    $x.Hex = '0x{0:X8}' -f $v
    $x.Unsigned = $v
    $x.Signed = if ($v -gt 0x7FFFFFFF) { $v - 4294967296 } else { $v }

    # Toolkit: the code itself; for a small number also its HRESULT form (5 -> 0x80070005).
    # A number as typed matches exit / problem codes; anything written as hex or a big decimal matches hex codes.
    $wantHex = $Item.Form -ne 'number'
    $hits = @(if ($Known.ContainsKey($v)) { $Known[$v] | Where-Object { ([string]$_.Code -match '^0x') -eq $wantHex } })
    if ($Item.Form -eq 'number' -and $v -le 0xFFFF) {
        $hr = $Win32Base + $v
        $hrText = '0x{0:X8}' -f $hr
        if ($Known.ContainsKey($hr)) { foreach ($e in $Known[$hr]) { $hits += [pscustomobject]@{ Code = $hrText; Source = "$($e.Source), as $hrText"; Meaning = $e.Meaning; Fix = $e.Fix } } }
    }
    $x.Toolkit = @($hits)

    $s = (($v -shr 31) -band 1); $c = (($v -shr 29) -band 1)
    $fac = ($v -shr 16) -band 0x7FF; $low = $v -band 0xFFFF
    if ($Item.Form -eq 'number') { $x.Kind = 'a number: a Windows (Win32) error, or an app''s exit / problem code' }
    elseif ($v -le 0xFFFF) { $x.Kind = 'a small number: a Windows (Win32) error, or a stop code' }
    elseif (($v -band $HighWord) -eq $Win32Base) { $x.Kind = "Windows (Win32) error $low wrapped as an HRESULT" }
    elseif (($v -band $SevError) -eq $SevError -and $fac -eq 0 -and -not $c) { $x.Kind = 'NTSTATUS error (from Windows'' kernel or a crashed program)' }
    elseif ($c) { $x.Kind = 'a vendor''s own code (customer bit set): it comes from an app or driver, not Windows' }
    elseif ($s) { $x.Kind = 'HRESULT failure' }
    else { $x.Kind = 'HRESULT success / information' }
    if ($v -gt 0xFFFF -and -not $c) {
        $x.Facility = if ($Facilities.ContainsKey([int64]$fac)) { "$fac, $($Facilities[[int64]$fac])" } else { "$fac" }
    }

    $w = Get-WindowsText $v $Item.Form
    $x.WindowsName = $w.Name; $x.WindowsText = $w.Text; $x.WindowsVia = $w.Via
    if ($x.Kind -like 'NTSTATUS*' -and -not $x.WindowsText) {
        $mapped = Get-NtMapping $v
        if ($mapped) {
            $x.NtWin32 = $mapped
            $t = Get-WindowsText $mapped 'number'
            $x.NtText = if ($t.Name -and $t.Text) { "$($t.Name): $($t.Text)" } elseif ($t.Text) { $t.Text } else { $t.Name }
        }
    }

    if ($null -ne $Item.Extend) {
        $ph = ($Item.Extend -shr 16) -band 0xF; $op = $Item.Extend -band 0xFFFF
        $phName = if ($Phases.ContainsKey([int64]$ph)) { $Phases[[int64]$ph] } else { "phase $ph" }
        $opName = if ($Operations.ContainsKey([int64]$op)) { $Operations[[int64]$op] } else { 'operation 0x{0:X}' -f $op }
        $x.Setup = "failed in the $phName phase, during $opName (extend code 0x{0:X})" -f $Item.Extend
    }
    if ($Item.Form -in 'hex', 'hex8') {
        $sk = if (($v -band $HighWord) -eq $MVariant) { $v - $MVariant } else { $v }
        if ($StopCodes.ContainsKey([int64]$sk)) { $x.StopCode = $StopCodes[[int64]$sk][0]; $x.StopHint = $StopCodes[[int64]$sk][1] }
    }

    $x.Best = if ($x.Toolkit.Count) { "$($x.Toolkit[0].Source): $($x.Toolkit[0].Meaning)" }
              elseif ($x.StopCode -and $v -le 0xFFFF) { "blue screen $($x.StopCode): $($x.StopHint)" }
              elseif ($x.WindowsText) { $(if ($x.WindowsName) { "$($x.WindowsName): $($x.WindowsText)" } else { $x.WindowsText }) }
              elseif ($x.WindowsName) { $x.WindowsName }
              elseif ($x.NtText) { "maps to Windows error $($x.NtWin32): $($x.NtText)" }
              elseif ($x.StopCode) { "blue screen $($x.StopCode): $($x.StopHint)" }
              else { "not known to Windows or the toolkit: $($x.Kind)" }
    if ($x.Setup) { $x.Best = "$($x.Best) ($($x.Setup))" }
    $x
}

# ================================================================================================
#  Run
# ================================================================================================
# Each argument is read on its own, so a lone number passed next to others still counts.
$text = ($Code | Where-Object { $_ }) -join ' '
$items = [System.Collections.Generic.List[object]]::new()
$taken = @{}
foreach ($arg in @($Code | Where-Object { $_ })) {
    foreach ($i in @(Find-Code $arg)) {
        $key = "$($i.Value)|$($i.Form)|$($i.Extend)|$($i.Label)"
        if (-not $taken.ContainsKey($key)) { $taken[$key] = $true; $items.Add($i) }
    }
}

if (-not $items.Count) {
    $msg = if ($text) { "No error code found in: $text" } else { 'Give it a code, e.g. Resolve-ErrorCode 0x80070005 (or paste the whole error message).' }
    if ($Quiet) { Write-Output $msg } else { Write-Host $msg -ForegroundColor Yellow }
    exit 1
}

$results = foreach ($i in $items) { Get-Explanation $i }

foreach ($x in $results) {
    $title = if ($x.Hex -and $x.Input -notmatch '^0x[0-9A-Fa-f]{8}$' -and $x.Input -notmatch '^\d{1,6}$') { "$($x.Input) = $($x.Hex)" } else { $x.Input }
    if ($Quiet) { Write-Output ("{0}: {1}" -f $title, $x.Best); continue }
    Write-Host ''
    Write-Host ("== {0} " -f $title).PadRight(78, '=') -ForegroundColor Cyan
    foreach ($t in $x.Toolkit) {
        Write-Host ('  {0}: {1}' -f $t.Source, $t.Meaning) -ForegroundColor Yellow
        if ($t.Fix) { Write-Host ('     -> {0}' -f $t.Fix) -ForegroundColor DarkGray }
    }
    if ($x.Setup) { Write-Host ('  Setup: {0}' -f $x.Setup) -ForegroundColor Yellow }
    if ($x.StopCode) {
        $lead = if ($x.Hex -and [int64]$x.Unsigned -le 0xFFFF) { 'As a blue screen stop code' } else { 'Blue screen stop code' }
        Write-Host ('  {0}: {1}. {2}' -f $lead, $x.StopCode, $x.StopHint) -ForegroundColor Yellow
    }
    if ($x.WindowsName -or $x.WindowsText) {
        $lead = if ($x.Kind -like 'a *number*') { 'As a Windows error' } else { 'Windows says' }
        $said = (@($x.WindowsName, $x.WindowsText) | Where-Object { $_ }) -join ' - '
        Write-Host ('  {0}: {1}' -f $lead, $said) -ForegroundColor Gray
    }
    if ($x.NtText) { Write-Host ('  Windows maps it to error {0}: {1}' -f $x.NtWin32, $x.NtText) -ForegroundColor Gray }
    if (-not $x.Toolkit.Count -and -not ($x.WindowsName -or $x.WindowsText) -and -not $x.NtText -and -not $x.StopCode -and $x.Kind -ne 'Entra sign-in error') {
        Write-Host '  Neither Windows nor the toolkit knows this one.' -ForegroundColor DarkGray
    }
    if ($x.Kind -eq 'Entra sign-in error' -and -not $x.Toolkit.Count) { Write-Host "  $($x.Best)" -ForegroundColor Gray }
    if ($x.Hex) {
        $dec = if ($x.Unsigned -le 0xFFFF) { "$($x.Unsigned)" } else { "$($x.Unsigned) / $($x.Signed)" }
        $parts = @($x.Kind)
        if ($x.Facility) { $parts += "facility $($x.Facility)" }
        Write-Host ('  Decoded: {0}. Also written {1} / {2}.' -f ($parts -join ', '), $x.Hex, $dec) -ForegroundColor DarkGray
    }
}
if (-not $Quiet) {
    if ($TableError) { Write-Host "`n  (The toolkit's own code list couldn't be read: $TableError)" -ForegroundColor DarkGray }
    Write-Host ''
}

if ($PassThru) { $results }
exit 0
