<#
.SYNOPSIS
    "No sound" / "my mic doesn't work": checks the audio services, the playback and recording devices
    (which is the default, volume, mute, disabled, unplugged), microphone privacy (whole PC, the user,
    desktop apps, new Teams, policy) and the sound hardware in Device Manager. Read-only.

.DESCRIPTION
    The usual causes, in the order they're checked:

      Services   Windows Audio and Windows Audio Endpoint Builder: missing, disabled or not running.
      Playback   No working output at all, or the default one muted or at 0%. Devices disabled in Sound
                 settings or unplugged. Calls going to a different device than everything else. A
                 Bluetooth headset stuck in its hands-free (call-quality) mode.
      Recording  The same for microphones.
      Privacy    Microphone access off for the whole PC, for the user, for desktop apps (classic Teams,
                 Zoom, browsers), or for new Teams; or a Group Policy / Intune setting blocking it.
      Hardware   Sound devices in Device Manager with a problem code (disabled, no driver, won't start),
                 their driver versions, and Windows' generic "High Definition Audio Device" driver
                 standing in for the manufacturer's.

    Which device is the default, its volume and mute come from Windows' own audio API (Core Audio),
    compiled in on the fly. Where that isn't allowed (Constrained Language Mode, some antivirus) the
    rest still runs and it says so. Microphone privacy is read for the signed-in user, even when this
    runs as an admin account or SYSTEM.

    Changes nothing. Every problem comes with what to do about it.

.PARAMETER Quiet
    Print only the one-line summary (for RMM).

.PARAMETER PassThru
    Emit the devices and findings to the pipeline.

.EXAMPLE
    .\Get-AudioStatus.ps1

.NOTES
    No admin needed. Exit codes: 0 = no FAIL, 1 = at least one FAIL.
    Nothing is sent anywhere.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $Quiet,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')

$now      = Get-Date
$Computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }

$MMKey        = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
$SvcKey       = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$ConsentPath  = 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
$PolicyKey    = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$DescProp     = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'   # the endpoint, e.g. "Speakers"
$AdapterProp  = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'   # the adapter, e.g. "Realtek(R) Audio"
$MediaClass   = '{4d36e96c-e325-11ce-bfc1-08002be10318}'     # Sound, video and game controllers
$TeamsPackage = 'MSTeams_8wekyb3d8bbwe'
$PrivacyPage  = 'Settings > Privacy & security > Microphone (ms-settings:privacy-microphone)'
$SoundPanel   = 'Sound settings > More sound settings (mmsys.cpl)'

$StateNames = @{ 1 = 'active'; 2 = 'disabled'; 4 = 'not present'; 8 = 'unplugged' }
$ProblemCodes = @{
    1 = 'not configured correctly'; 3 = 'driver may be corrupted'; 10 = "can't start"; 12 = 'not enough free resources'
    14 = 'needs a restart'; 18 = 'drivers need reinstalling'; 19 = 'registry configuration damaged'; 21 = 'being removed'
    22 = 'disabled'; 24 = 'not present or not working'; 28 = 'no driver installed'; 29 = 'disabled in the firmware'
    31 = "driver couldn't load"; 32 = 'driver service disabled'; 37 = "driver couldn't start"; 39 = 'driver missing or corrupted'
    41 = 'driver loaded but device not found'; 43 = 'stopped after reporting a problem'; 45 = 'not connected'
    47 = 'prepared for safe removal'; 48 = 'driver blocked'; 52 = "driver signature couldn't be verified"
}

# Core Audio, as little of it as needed: the default endpoint per direction / role, and each active
# endpoint's master volume and mute. C# 5 so Windows PowerShell 5.1 can compile it.
$CoreAudioCs = @'
using System;
using System.Runtime.InteropServices;
namespace EtkCoreAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorCom { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr notify);
        [PreserveSig] int GetChannelCount(out int count);
        [PreserveSig] int SetMasterVolumeLevel(float levelDb, ref Guid context);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid context);
        [PreserveSig] int GetMasterVolumeLevel(out float levelDb);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(int channel, float levelDb, ref Guid context);
        [PreserveSig] int SetChannelVolumeLevelScalar(int channel, float level, ref Guid context);
        [PreserveSig] int GetChannelVolumeLevel(int channel, out float levelDb);
        [PreserveSig] int GetChannelVolumeLevelScalar(int channel, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    public class EndpointVolume {
        public string Id;
        public float Volume;
        public bool Muted;
        public string Error;
    }

    public static class Reader {
        const int ENotFound = unchecked((int)0x80070490);

        static IMMDeviceEnumerator Enumerator() { return (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom()); }

        // flow: 0 = playback, 1 = recording. role: 0 = console, 2 = communications. Null when there is none.
        public static string DefaultId(int flow, int role) {
            IMMDevice dev;
            int hr = Enumerator().GetDefaultAudioEndpoint(flow, role, out dev);
            if (hr == ENotFound) { return null; }
            Marshal.ThrowExceptionForHR(hr);
            if (dev == null) { return null; }
            string id;
            Marshal.ThrowExceptionForHR(dev.GetId(out id));
            return id;
        }

        public static EndpointVolume Volume(string id) {
            EndpointVolume r = new EndpointVolume();
            r.Id = id;
            try {
                IMMDevice dev;
                Marshal.ThrowExceptionForHR(Enumerator().GetDevice(id, out dev));
                Guid iid = typeof(IAudioEndpointVolume).GUID;
                object o;
                Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out o));
                IAudioEndpointVolume v = (IAudioEndpointVolume)o;
                float level;
                Marshal.ThrowExceptionForHR(v.GetMasterVolumeLevelScalar(out level));
                bool muted;
                Marshal.ThrowExceptionForHR(v.GetMute(out muted));
                r.Volume = level;
                r.Muted = muted;
            }
            catch (Exception e) { r.Error = e.Message; }
            return r;
        }
    }
}
'@

# ================================================================================================
#  Plumbing
# ================================================================================================
$Findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string] $Area, [string] $Check, [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')] [string] $Status, [string] $Detail, [string] $Fix, [string] $Short)
    $Findings.Add([pscustomobject]@{ Area = $Area; Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix; Short = $Short })
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
function Get-InnerMessage {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    if ($e.Message) { $e.Message } else { $e.GetType().Name }
}

# ================================================================================================
#  Services
# ================================================================================================
foreach ($s in @(
        @{ Name = 'Audiosrv'; Label = 'Windows Audio' },
        @{ Name = 'AudioEndpointBuilder'; Label = 'Windows Audio Endpoint Builder' })) {
    $start = Get-Val (Get-RegKey "$SvcKey\$($s.Name)") 'Start'
    $svc = $null
    try { $svc = Get-Service -Name $s.Name -ErrorAction Stop } catch { $svc = $null }
    if (-not $svc) {
        Add-Finding 'Service' $s.Label 'FAIL' "The $($s.Label) service is missing." 'Run Windows repair checks (DISM + SFC) from this toolkit, then restart.' "$($s.Label) missing"
    }
    elseif ($null -ne $start -and [int]$start -eq 4) {
        Add-Finding 'Service' $s.Label 'FAIL' "The $($s.Label) service is disabled." "As admin: Set-Service $($s.Name) -StartupType Automatic; Start-Service $($s.Name)" "$($s.Label) disabled"
    }
    elseif ([string]$svc.Status -ne 'Running') {
        Add-Finding 'Service' $s.Label 'FAIL' "The $($s.Label) service isn't running ($($svc.Status))." "As admin: Start-Service $($s.Name) (a restart starts it too)." "$($s.Label) stopped"
    }
    else { Add-Finding 'Service' $s.Label 'PASS' 'Running' '' }
}

# ================================================================================================
#  Devices: endpoints from the registry, names from Device Manager, volume / mute / defaults from Core Audio
# ================================================================================================
$pnpNames = @{}
try {
    foreach ($e in @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPClass='AudioEndpoint'" -ErrorAction Stop)) {
        if ([string]$e.DeviceID -match '\{0\.0\.[01]\.00000000\}\.(\{[0-9A-Fa-f-]+\})') { $pnpNames[$Matches[1].ToUpper()] = [string]$e.Name }
    }
}
catch { Write-Verbose "Couldn't list audio endpoints in Device Manager: $($_.Exception.Message)" }

$Endpoints = [System.Collections.Generic.List[object]]::new()
foreach ($flow in 'Render', 'Capture') {
    foreach ($k in (Get-SubKeyName "$MMKey\$flow")) {
        if ($k -notmatch '^\{[0-9A-Fa-f-]+\}$') { continue }
        $raw  = Get-Val (Get-RegKey "$MMKey\$flow\$k") 'DeviceState'
        $code = if ($null -ne $raw) { [int]([int64]$raw -band 0xF) } else { 0 }
        $props = Get-RegKey "$MMKey\$flow\$k\Properties"
        $desc = [string](Get-Val $props $DescProp)
        $adapter = [string](Get-Val $props $AdapterProp)
        $name = if ($pnpNames[$k.ToUpper()]) { $pnpNames[$k.ToUpper()] }
                elseif ($desc -and $adapter) { "$desc ($adapter)" }
                elseif ($desc) { $desc } elseif ($adapter) { $adapter } else { $k }
        $Endpoints.Add([pscustomobject]@{
            Flow = $(if ($flow -eq 'Render') { 'Output' } else { 'Input' }); Guid = $k
            Id = ('{0.0.' + $(if ($flow -eq 'Render') { '0' } else { '1' }) + '.00000000}.' + $k.ToLower())
            Name = $name; StateCode = $code; State = $(if ($StateNames.ContainsKey($code)) { $StateNames[$code] } else { "state $code" })
            Default = $false; DefaultComms = $false; Volume = $null; Muted = $null; VolumeError = $null
        })
    }
}

$CoreError = $null
$Core = $null
try {
    if (-not ('EtkCoreAudio.Reader' -as [type])) { Add-Type -TypeDefinition $CoreAudioCs -Language CSharp -ErrorAction Stop }
    $Core = 'EtkCoreAudio.Reader' -as [type]
}
catch { $CoreError = Get-InnerMessage $_ }

$coreOk = $false
$defaults = @{}
if ($Core) {
    try {
        foreach ($d in @(@('Output', 0, 0), @('OutputComms', 0, 2), @('Input', 1, 0), @('InputComms', 1, 2))) { $defaults[$d[0]] = $Core::DefaultId($d[1], $d[2]) }
        $coreOk = $true
    }
    catch { $CoreError = Get-InnerMessage $_ }
}
if ($coreOk) {
    foreach ($e in $Endpoints) {
        foreach ($key in 'Output', 'Input') {
            if ($e.Flow -eq $key -and $defaults[$key] -and $defaults[$key].EndsWith($e.Guid, [StringComparison]::OrdinalIgnoreCase)) { $e.Default = $true }
            if ($e.Flow -eq $key -and $defaults["${key}Comms"] -and $defaults["${key}Comms"].EndsWith($e.Guid, [StringComparison]::OrdinalIgnoreCase)) { $e.DefaultComms = $true }
        }
        if ($e.StateCode -ne 1) { continue }
        $v = $null
        try { $v = $Core::Volume($e.Id) } catch { $e.VolumeError = Get-InnerMessage $_; continue }
        if ($v.Error) { $e.VolumeError = [string]$v.Error }
        else { $e.Volume = [int][math]::Round([double]$v.Volume * 100); $e.Muted = [bool]$v.Muted }
    }
}

function Get-LevelText {
    param($e)
    if (-not $e) { return 'none' }
    if ($e.Muted) { return "$($e.Name) muted" }
    if ($null -ne $e.Volume) { return "$($e.Name) $($e.Volume)%" }
    $e.Name
}

foreach ($side in @(
        @{ Flow = 'Output'; Area = 'Playback'; Thing = 'playback device'; Low = 10; Missing = 'FAIL'; What = 'speakers / headphones' },
        @{ Flow = 'Input'; Area = 'Recording'; Thing = 'microphone'; Low = 20; Missing = 'WARN'; What = 'microphone / headset' })) {
    $mine     = @($Endpoints | Where-Object Flow -eq $side.Flow)
    $active   = @($mine | Where-Object StateCode -eq 1)
    $disabled = @($mine | Where-Object StateCode -eq 2)
    $unplug   = @($mine | Where-Object StateCode -eq 8)
    $area     = $side.Area

    if (-not $active.Count) {
        $fix = if ($disabled.Count) { "$SoundPanel > $(if ($side.Flow -eq 'Output') { 'Playback' } else { 'Recording' }): right-click > Show Disabled Devices, then right-click > Enable." }
               elseif ($unplug.Count) { "Plug the $($side.What) back in (or into the other jack)." }
               else { 'Check the sound hardware below in Device Manager, then the driver.' }
        $also = @()
        if ($disabled.Count) { $also += 'disabled: ' + (($disabled | ForEach-Object Name) -join ', ') }
        if ($unplug.Count) { $also += 'unplugged: ' + (($unplug | ForEach-Object Name) -join ', ') }
        Add-Finding $area "Working $($side.Thing)" $side.Missing ("No working $($side.Thing)" + $(if ($also.Count) { ' (' + ($also -join '; ') + ')' } else { '' }) + '.') $fix "no $($side.Thing)"
    }
    elseif ($coreOk) {
        $def = @($active | Where-Object Default) | Select-Object -First 1
        if (-not $def) {
            Add-Finding $area 'Default' 'WARN' "No default $($side.Thing) is set." "Sound settings: pick one under $(if ($side.Flow -eq 'Output') { 'Output' } else { 'Input' })." "no default $($side.Thing)"
        }
        elseif ($def.VolumeError) {
            Add-Finding $area 'Default' 'INFO' "Default: $($def.Name). Couldn't read its volume or mute: $($def.VolumeError)" 'Check the volume icon on the taskbar.'
        }
        elseif ($def.Muted) {
            Add-Finding $area 'Default' 'FAIL' "The default $($side.Thing), $($def.Name), is muted." $(if ($side.Flow -eq 'Output') { 'Unmute it: the volume icon on the taskbar.' } else { "Unmute it: Sound settings > Input > $($def.Name), or the mute key / switch on the headset or laptop." }) "$(if ($side.Flow -eq 'Output') { 'sound' } else { 'mic' }) muted"
        }
        elseif ($def.Volume -le 0) {
            Add-Finding $area 'Default' 'FAIL' "The default $($side.Thing), $($def.Name), is at 0%." 'Turn it up in Sound settings.' "$(if ($side.Flow -eq 'Output') { 'volume' } else { 'mic level' }) 0%"
        }
        elseif ($def.Volume -lt $side.Low) {
            Add-Finding $area 'Default' 'WARN' "The default $($side.Thing), $($def.Name), is very low ($($def.Volume)%)." 'Turn it up in Sound settings.' "$(if ($side.Flow -eq 'Output') { 'volume' } else { 'mic level' }) $($def.Volume)%"
        }
        else { Add-Finding $area 'Default' 'PASS' "$($def.Name) at $($def.Volume)%, not muted" '' }

        $comms = @($active | Where-Object DefaultComms) | Select-Object -First 1
        if ($comms -and $def -and $comms.Guid -ne $def.Guid) {
            Add-Finding $area 'Calls' 'INFO' "Calls go to $($comms.Name), everything else to $($def.Name)$(if ($comms.Muted) { ' (the call device is muted)' } elseif ($null -ne $comms.Volume) { " (calls at $($comms.Volume)%)" })." "If that's not intended: $SoundPanel > right-click the device > Set as Default Communication Device. Teams also has its own device setting."
        }
        if ($side.Flow -eq 'Output' -and $def -and $def.Name -match 'Hands-Free') {
            Add-Finding $area 'Bluetooth' 'INFO' "$($def.Name) is a Bluetooth headset's hands-free (call) mode: sound is mono and low quality." "For music and video pick the same headset's stereo / headphones entry as the output; calls switch to hands-free by themselves."
        }
    }
    else {
        Add-Finding $area "Working $($side.Thing)" 'PASS' ("$($active.Count) working: " + (($active | ForEach-Object Name) -join ', ')) ''
    }
    if ($active.Count -and $disabled.Count) {
        Add-Finding $area 'Disabled' 'INFO' ('Disabled in Sound settings: ' + (($disabled | ForEach-Object Name) -join ', ')) "To use one: $SoundPanel, right-click > Show Disabled Devices, then Enable."
    }
    if ($active.Count -and $unplug.Count) {
        Add-Finding $area 'Unplugged' 'INFO' ('Unplugged: ' + (($unplug | ForEach-Object Name) -join ', ')) ''
    }
}
if (-not $coreOk) {
    Add-Finding 'Playback' 'Volume and mute' 'INFO' "Couldn't read which devices are the defaults, or their volume and mute: $CoreError" 'Check the volume icon on the taskbar and Sound settings by hand.'
}

# ================================================================================================
#  Microphone privacy
# ================================================================================================
$pol = Get-RegKey $PolicyKey
$polMic = Get-Val $pol 'LetAppsAccessMicrophone'
$polDeny = @(Get-Val $pol 'LetAppsAccessMicrophone_ForceDenyTheseApps' | Where-Object { $_ })
if ($null -ne $polMic -and [int]$polMic -eq 2) {
    Add-Finding 'Privacy' 'Policy' 'FAIL' 'Group Policy / Intune blocks apps from the microphone (Let Windows apps access the microphone = Force Deny).' 'Change the policy (AppPrivacy > LetAppsAccessMicrophone). It wins over anything set in Settings.' 'mic blocked by policy'
}
elseif ($null -ne $polMic -and [int]$polMic -eq 1) {
    Add-Finding 'Privacy' 'Policy' 'INFO' 'Group Policy / Intune forces microphone access on for apps.' ''
}
if (@($polDeny | Where-Object { $_ -like 'MSTeams_*' }).Count) {
    Add-Finding 'Privacy' 'Policy' 'FAIL' 'Group Policy / Intune blocks new Teams from the microphone (LetAppsAccessMicrophone_ForceDenyTheseApps).' 'Take MSTeams_8wekyb3d8bbwe out of that policy list.' 'Teams mic blocked by policy'
}

if ([string](Get-Val (Get-RegKey "HKLM:\$ConsentPath") 'Value') -eq 'Deny') {
    Add-Finding 'Privacy' 'This PC' 'FAIL' 'Microphone access is off for the whole PC.' "An admin turns on Microphone access in $PrivacyPage." 'mic access off (PC)'
}
else { Add-Finding 'Privacy' 'This PC' 'PASS' 'Microphone access is on for the PC' '' }

# Per-user settings belong to whoever is signed in, which isn't the account running this when it runs
# elevated as an admin account or as SYSTEM from the RMM.
$who = $null
$userRoot = $null
$other = Get-OtherSignedInUser
if ($other) {
    $who = $other
    $leaf = ($other -split '\\')[-1]
    foreach ($sid in (Get-SubKeyName 'Registry::HKEY_USERS')) {
        if ($sid -notmatch '^S-1-(5-21|12-1)-[0-9-]+$') { continue }
        $ve = Get-RegKey "Registry::HKEY_USERS\$sid\Volatile Environment"
        $un = [string](Get-Val $ve 'USERNAME'); $ud = [string](Get-Val $ve 'USERDOMAIN')
        if ($un -and ("$ud\$un" -ieq $other -or $un -ieq $leaf)) { $userRoot = "Registry::HKEY_USERS\$sid"; break }
    }
    if (-not $userRoot) { Add-Finding 'Privacy' 'User' 'INFO' "Couldn't read $other's microphone settings (their registry isn't loaded)." "Check $PrivacyPage while signed in as them." }
}
elseif ((Get-CurrentUserSid) -eq 'S-1-5-18') {
    Add-Finding 'Privacy' 'User' 'INFO' "Nobody is signed in, so the per-user microphone settings weren't checked." ''
}
else { $who = Get-CurrentUserName; $userRoot = 'HKCU:' }

if ($userRoot) {
    $base = "$userRoot\$ConsentPath"
    $userOff = [string](Get-Val (Get-RegKey $base) 'Value') -eq 'Deny'
    if ($userOff) { Add-Finding 'Privacy' 'User' 'FAIL' "Microphone access is off for $who." "Turn on Microphone access in $PrivacyPage." 'mic access off (user)' }
    if ([string](Get-Val (Get-RegKey "$base\NonPackaged") 'Value') -eq 'Deny') {
        Add-Finding 'Privacy' 'Desktop apps' 'FAIL' "'Let desktop apps access your microphone' is off for ${who}: classic Teams, Zoom, browsers and other desktop apps get no microphone." "Turn it on in $PrivacyPage." 'desktop apps blocked from mic'
    }
    if ([string](Get-Val (Get-RegKey "$base\$TeamsPackage") 'Value') -eq 'Deny') {
        Add-Finding 'Privacy' 'New Teams' 'FAIL' "New Teams is blocked from the microphone for $who." "Turn on Microsoft Teams in $PrivacyPage." 'Teams blocked from mic'
    }
    $otherApps = @(foreach ($k in (Get-SubKeyName $base)) {
        if ($k -in 'NonPackaged', $TeamsPackage) { continue }
        if ([string](Get-Val (Get-RegKey "$base\$k") 'Value') -eq 'Deny') { ($k -replace '_[a-z0-9]{13}$', '') }
    })
    if ($otherApps.Count) { Add-Finding 'Privacy' 'Other apps' 'INFO' ("Also blocked from the microphone for ${who}: " + (($otherApps | Select-Object -First 6) -join ', ') + $(if ($otherApps.Count -gt 6) { " and $($otherApps.Count - 6) more" } else { '' })) "Turn them on in $PrivacyPage if they need it." }
    if (-not @($Findings | Where-Object { $_.Area -eq 'Privacy' -and $_.Check -in 'User', 'Desktop apps', 'New Teams' }).Count) {
        Add-Finding 'Privacy' 'User' 'PASS' "Microphone allowed for $who (desktop apps and new Teams too)" ''
    }
}

# ================================================================================================
#  Sound hardware (Device Manager)
# ================================================================================================
$drivers = @{}
try {
    foreach ($d in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceClass='MEDIA'" -ErrorAction Stop)) {
        if ($d.DeviceID) { $drivers[([string]$d.DeviceID).ToUpper()] = $d }
    }
}
catch { Write-Verbose "Couldn't list drivers: $($_.Exception.Message)" }

$Hardware = [System.Collections.Generic.List[object]]::new()
$hwError = $null
try {
    foreach ($m in @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "ClassGuid='$MediaClass'" -ErrorAction Stop | Sort-Object Name)) {
        $drv = $drivers[([string]$m.DeviceID).ToUpper()]
        $date = $null
        if ($drv -and $drv.DriverDate) { try { $date = ([datetime]$drv.DriverDate).ToString('yyyy-MM-dd') } catch { $date = $null } }
        $Hardware.Add([pscustomobject]@{
            Name = [string]$m.Name; Code = [int]$m.ConfigManagerErrorCode; Bluetooth = ([string]$m.Service -like 'Bth*')
            Driver = $(if ($drv) { [string]$drv.DriverVersion } else { $null }); DriverDate = $date; Provider = $(if ($drv) { [string]$drv.DriverProviderName } else { $null })
        })
    }
}
catch { $hwError = $_.Exception.Message }

if ($hwError) { Add-Finding 'Hardware' 'Devices' 'INFO' "Couldn't read Device Manager: $hwError" '' }
elseif (-not $Hardware.Count) {
    Add-Finding 'Hardware' 'Devices' 'FAIL' 'No sound hardware in Device Manager (Sound, video and game controllers is empty).' "Check it's enabled in the BIOS / UEFI, then install the manufacturer's audio driver." 'no sound hardware'
}
else {
    $bad = 0
    foreach ($h in $Hardware) {
        if ($h.Code -eq 0 -or $h.Code -eq 45) { continue }
        $bad++
        $meaning = if ($ProblemCodes.ContainsKey($h.Code)) { $ProblemCodes[$h.Code] } else { 'see Device Manager' }
        if ($h.Code -eq 22) {
            Add-Finding 'Hardware' $h.Name 'WARN' "$($h.Name) is disabled in Device Manager." 'Device Manager > Sound, video and game controllers > right-click > Enable device.' "$($h.Name) disabled"
        }
        else {
            $fix = switch ($h.Code) {
                { $_ -in 28, 31, 39, 48, 52, 18, 3 } { "Reinstall the audio driver from the manufacturer's support page (Dell / HP / Lenovo) or Windows Update." }
                { $_ -in 10, 43, 14, 37 } { "Restart. If it's still there, reinstall the audio driver from the manufacturer." }
                default { 'Device Manager > right-click > Properties shows the detail.' }
            }
            Add-Finding 'Hardware' $h.Name 'FAIL' "$($h.Name): code $($h.Code), $meaning." $fix "$($h.Name) code $($h.Code)"
        }
    }
    if (-not $bad) { Add-Finding 'Hardware' 'Devices' 'PASS' "$($Hardware.Count) sound device(s), none with a problem" '' }
    if (@($Hardware | Where-Object { $_.Name -eq 'High Definition Audio Device' -and $_.Provider -eq 'Microsoft' }).Count) {
        Add-Finding 'Hardware' 'Generic driver' 'INFO' "Windows' generic 'High Definition Audio Device' driver is in use instead of the manufacturer's." "If the headset jack, mic or speakers misbehave, install the audio driver from the manufacturer's support page."
    }
}

# ================================================================================================
#  Show
# ================================================================================================
$outDef = @($Endpoints | Where-Object { $_.Flow -eq 'Output' -and $_.Default }) | Select-Object -First 1
$inDef  = @($Endpoints | Where-Object { $_.Flow -eq 'Input' -and $_.Default }) | Select-Object -First 1
$fails  = @($Findings | Where-Object Status -eq 'FAIL')
$warns  = @($Findings | Where-Object Status -eq 'WARN')

if (-not $Quiet) {
    $order = @{ FAIL = 0; WARN = 1; INFO = 2; PASS = 3 }
    $areaOrder = @{ Service = 0; Playback = 1; Recording = 2; Privacy = 3; Hardware = 4 }
    $colour = @{ FAIL = 'Red'; WARN = 'Yellow'; INFO = 'DarkGray'; PASS = 'Green' }
    Write-Host ''
    Write-Host ("== Audio check - {0} - {1} " -f $Computer, $now.ToString('yyyy-MM-dd HH:mm')).PadRight(78, '=') -ForegroundColor Cyan
    foreach ($flow in 'Output', 'Input') {
        Write-Host ('  {0}' -f $(if ($flow -eq 'Output') { 'PLAYBACK' } else { 'RECORDING' })) -ForegroundColor Cyan
        $list = @($Endpoints | Where-Object { $_.Flow -eq $flow -and $_.StateCode -ne 4 } | Sort-Object @{ Expression = 'Default'; Descending = $true }, StateCode, Name)
        if (-not $list.Count) { Write-Host '     none' -ForegroundColor DarkGray }
        foreach ($e in $list) {
            $tags = @()
            if ($e.Default) { $tags += 'default' }
            if ($e.DefaultComms -and -not $e.Default) { $tags += 'calls' }
            $level = if ($e.StateCode -ne 1) { $e.State } elseif ($e.Muted) { 'MUTED' } elseif ($null -ne $e.Volume) { "$($e.Volume)%" } else { 'active' }
            $line = '   {0} {1} {2}' -f $(if ($e.Default) { '*' } else { ' ' }), $e.Name.PadRight(52), $level
            if ($tags.Count) { $line += '  (' + ($tags -join ', ') + ')' }
            Write-Host $line -ForegroundColor $(if ($e.StateCode -ne 1) { 'DarkGray' } elseif ($e.Muted -or $e.Volume -eq 0) { 'Red' } elseif ($e.Default) { 'Green' } else { 'Gray' })
        }
        $gone = @($Endpoints | Where-Object { $_.Flow -eq $flow -and $_.StateCode -eq 4 }).Count
        if ($gone) { Write-Host "     (+$gone not present: devices used before, not connected now)" -ForegroundColor DarkGray }
    }
    Write-Host '  SOUND HARDWARE' -ForegroundColor Cyan
    if (-not $Hardware.Count) { Write-Host '     none' -ForegroundColor DarkGray }
    foreach ($h in $Hardware) {
        $st = if ($h.Code -eq 0) { 'OK' } elseif ($h.Code -eq 45) { 'not connected' } else { "code $($h.Code)" }
        $drv = @($h.Driver, $h.DriverDate, $h.Provider) | Where-Object { $_ }
        Write-Host ('     {0} {1} {2}' -f $h.Name.PadRight(44), $st.PadRight(14), ($drv -join '  ')) -ForegroundColor $(if ($h.Code -in 0, 45) { 'Gray' } elseif ($h.Code -eq 22) { 'Yellow' } else { 'Red' })
    }
    $attention = @($Findings | Where-Object { $_.Status -in 'FAIL', 'WARN' } | Sort-Object @{ Expression = { $order[$_.Status] } }, @{ Expression = { $areaOrder[$_.Area] } })
    if ($attention.Count) {
        Write-Host ''
        Write-Host '  NEEDS ATTENTION' -ForegroundColor Yellow
        foreach ($f in $attention) {
            Write-Host ('   [{0}] {1} - {2}: {3}' -f $f.Status, $f.Area, $f.Check, $f.Detail) -ForegroundColor $colour[$f.Status]
            if ($f.Fix) { Write-Host ('          -> {0}' -f $f.Fix) -ForegroundColor DarkGray }
        }
    }
    Write-Host ''
    Write-Host '  CHECKED' -ForegroundColor Cyan
    foreach ($f in @($Findings | Where-Object { $_.Status -in 'PASS', 'INFO' } | Sort-Object @{ Expression = { $areaOrder[$_.Area] } }, @{ Expression = { $order[$_.Status] } })) {
        Write-Host ('   [{0}] {1} - {2}: {3}' -f $f.Status, $f.Area, $f.Check, $f.Detail) -ForegroundColor $colour[$f.Status]
        if ($f.Fix -and $f.Status -eq 'INFO') { Write-Host ('          -> {0}' -f $f.Fix) -ForegroundColor DarkGray }
    }
}

$levels = if ($coreOk) { "output: $(Get-LevelText $outDef); mic: $(Get-LevelText $inDef)" } else { 'volume and mute not readable' }
$summary = if ($fails.Count) {
    "$Computer audio - $($fails.Count) problem(s): " + ((@($fails | ForEach-Object { if ($_.Short) { $_.Short } else { "$($_.Area) $($_.Check)" } }) | Select-Object -First 3) -join ', ') + "; $levels"
}
elseif ($warns.Count) { "$Computer audio - $($warns.Count) warning(s): " + ((@($warns | ForEach-Object { if ($_.Short) { $_.Short } else { "$($_.Area) $($_.Check)" } }) | Select-Object -First 3) -join ', ') + "; $levels" }
else { "$Computer audio - OK; $levels" }

if ($Quiet) { Write-Output $summary }
else { Write-Host ''; Write-Host "  Summary: $summary" -ForegroundColor Cyan }

if ($PassThru) {
    [pscustomobject]@{
        Summary = $summary; CoreAudio = $coreOk; CoreAudioError = $CoreError; User = $who
        Output = @($Endpoints | Where-Object Flow -eq 'Output'); Input = @($Endpoints | Where-Object Flow -eq 'Input')
        Hardware = @($Hardware); Findings = @($Findings)
    }
}
exit $(if ($fails.Count) { 1 } else { 0 })
