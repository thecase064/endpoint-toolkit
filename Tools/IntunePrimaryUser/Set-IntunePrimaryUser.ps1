<#
.SYNOPSIS
    Shows, changes or removes this device's Intune primary user, signing in as a Microsoft 365 admin.

.DESCRIPTION
    After a build, Intune usually lists whoever set the device up as its primary user. This signs in
    to the tenant the device is joined to (Microsoft's own sign-in window, so MFA works), finds the
    device in Intune and then:

      -UserPrincipalName   makes that user the primary user
      -Remove              removes the primary user (a shared device)
      neither              shows the current primary user and changes nothing

    Intune updates the device's Entra owner and registered user to match. It doesn't change the
    "Enrolled by" user, the Autopilot assigned user, or who is a local administrator on the PC.

    Needs:
      - the PC Entra joined and enrolled in Intune (it reads both from the PC itself)
      - an admin with Intune Administrator (or Help Desk Operator) in that tenant
      - consent for "Microsoft Graph Command Line Tools" with DeviceManagementManagedDevices.ReadWrite.All
        and User.Read.All. If the tenant has never used it, the first sign-in asks a Global Admin to consent.

    Sign-in uses Microsoft's Microsoft.Graph.Authentication module. If it isn't installed, it's
    downloaded from the PowerShell Gallery into a cache folder (C:\ProgramData\EndpointToolkit\_modules
    as admin, otherwise %LOCALAPPDATA%\EndpointToolkit\_modules), refused unless its files carry valid
    signatures (Microsoft's on the module itself), and reused next time. New device setup deletes the
    cache at the end of a build.

.PARAMETER UserPrincipalName
    The new primary user's sign-in address, e.g. jane.doe@contoso.com.

.PARAMETER Remove
    Remove the primary user instead, leaving the device shared.

.PARAMETER TenantId
    Tenant to sign in to. Defaults to the one this PC is joined to.

.PARAMETER UseDeviceCode
    Sign in with a code on another device (microsoft.com/devicelogin). Used automatically where there's
    no desktop for a sign-in window (remote sessions). Some tenants block device code sign-in.

.PARAMETER ResultFile
    Also write the outcome as JSON here. New device setup uses this for its build report.

.EXAMPLE
    .\Set-IntunePrimaryUser.ps1
    Shows the current primary user.

.EXAMPLE
    .\Set-IntunePrimaryUser.ps1 -UserPrincipalName jane.doe@contoso.com

.EXAMPLE
    .\Set-IntunePrimaryUser.ps1 -Remove

.NOTES
    Exit codes: 0 = done, or nothing needed changing; 1 = couldn't do it (the reason is shown).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ResultFile', Justification = 'Read by Exit-WithResult.')]
[CmdletBinding()]
param(
    [string] $UserPrincipalName,
    [switch] $Remove,
    [string] $TenantId,
    [switch] $UseDeviceCode,
    [string] $ResultFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$Graph = 'https://graph.microsoft.com'

function Write-Step($m)  { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)    { Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn2($m) { $script:LastProblem = $m; Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Write-Bad($m)   { $script:LastProblem = $m; Write-Host "    [XX] $m" -ForegroundColor Red }

$script:LastProblem = $null
$script:Connected   = $false
$script:Outcome     = [ordered]@{
    Action = $null; Device = $env:COMPUTERNAME; IntuneDeviceId = $null; Tenant = $null; SignedInAs = $null
    Before = $null; After = $null; Changed = $false; ExitCode = 1; Message = $null
}

function Exit-WithResult {
    # Every exit goes through here: sign out, write -ResultFile (best effort), then exit.
    param([int] $Code, [string] $Message)
    if ($script:Connected) {
        try { Disconnect-MgGraph -ErrorAction Stop | Out-Null } catch { Write-Verbose 'Already signed out' }
    }
    if ($ResultFile) {
        $script:Outcome.ExitCode = $Code
        $script:Outcome.Message  = if ($Message) { $Message } else { $script:LastProblem }
        try { [pscustomobject]$script:Outcome | ConvertTo-Json | Set-Content -LiteralPath $ResultFile -Encoding UTF8 }
        catch { Write-Verbose "Couldn't write the result file: $($_.Exception.Message)" }
    }
    exit $Code
}

function ConvertFrom-DsregOutput {
    # dsregcmd /status prints "   Name : Value" lines under section headers. First occurrence wins.
    param([string[]] $Lines)
    $map = @{}
    foreach ($l in $Lines) {
        if ($l -match '^\s*([A-Za-z][A-Za-z0-9 ]*?)\s*:\s*(.*?)\s*$') {
            $key = $Matches[1].Trim()
            if (-not $map.ContainsKey($key)) { $map[$key] = $Matches[2] }
        }
    }
    $map
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $false }
}

function Get-ModuleCacheFolder {
    $base = if (Test-IsAdmin) { $env:ProgramData } else { $env:LOCALAPPDATA }
    Join-Path (Join-Path $base 'EndpointToolkit') '_modules'
}

function Test-ModuleSignature {
    # Every DLL must be validly signed, every signed file must still match its signature, and the
    # module's own DLL must be signed by Microsoft. Returns $null when fine, or the reason it isn't.
    param([string] $Folder)
    $files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File |
        Where-Object { @('.dll', '.psd1', '.psm1', '.ps1') -contains $_.Extension.ToLower() })
    $ownDll = $false
    foreach ($f in $files) {
        $sig = Get-AuthenticodeSignature -FilePath $f.FullName
        $status = [string]$sig.Status
        if ($f.Extension -eq '.dll' -and $status -ne 'Valid') { return "$($f.Name) isn't validly signed ($status)" }
        if ($status -ne 'Valid' -and $status -ne 'NotSigned') { return "$($f.Name) failed its signature check ($status)" }
        if ($f.Name -like 'Microsoft.Graph.Authentication*.dll') {
            if ([string]$sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { return "$($f.Name) isn't signed by Microsoft" }
            $ownDll = $true
        }
    }
    if (-not $ownDll) { return 'the module''s own DLL is missing' }
    $null
}

function Import-GraphSignIn {
    # Use an installed Microsoft.Graph.Authentication if there is one, else the cached or freshly
    # downloaded copy. Throws with a plain reason if it can't.
    if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication) {
        Import-Module Microsoft.Graph.Authentication
        return
    }
    $cache = Get-ModuleCacheFolder
    $psd1  = Get-ChildItem -Path (Join-Path $cache 'Microsoft.Graph.Authentication') -Filter 'Microsoft.Graph.Authentication.psd1' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $psd1) {
        Write-Step 'Getting Microsoft''s Graph sign-in module (first time on this PC)'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            $scope = if (Test-IsAdmin) { 'AllUsers' } else { 'CurrentUser' }
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope $scope | Out-Null
        }
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        Save-Module -Name Microsoft.Graph.Authentication -Repository PSGallery -Path $cache -Force
        $psd1 = Get-ChildItem -Path (Join-Path $cache 'Microsoft.Graph.Authentication') -Filter 'Microsoft.Graph.Authentication.psd1' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if (-not $psd1) { throw 'The download finished but the module isn''t where expected.' }
    }
    $problem = Test-ModuleSignature -Folder (Join-Path $cache 'Microsoft.Graph.Authentication')
    if ($problem) {
        Remove-Item -LiteralPath (Join-Path $cache 'Microsoft.Graph.Authentication') -Recurse -Force -ErrorAction SilentlyContinue
        throw "Not using the Graph module: $problem. The download was deleted."
    }
    Write-Ok "Graph sign-in module ready ($($psd1.Directory.Name), signature checked)"
    Import-Module -Name $psd1.FullName
}

function Get-GraphProblem {
    # A plain reason for a failed Graph call.
    param($ErrorRecord, [string] $What)
    $text = "$($ErrorRecord.Exception.Message) $($ErrorRecord.ErrorDetails)"
    if ($text -match '404|NotFound|ResourceNotFound|does not exist') { return "$What wasn't found." }
    if ($text -match '403|Forbidden|Authorization_RequestDenied|insufficient privileges|not authorized') {
        return "Not allowed: the account needs Intune Administrator (or Help Desk Operator) in this tenant."
    }
    "$What failed: $($ErrorRecord.Exception.Message)"
}

function Get-PrimaryUser {
    param([string] $DeviceId)
    $r = Invoke-MgGraphRequest -Method GET -Uri "$Graph/beta/deviceManagement/managedDevices/$DeviceId/users?`$select=id,userPrincipalName,displayName"
    @($r.value) | Select-Object -First 1
}

function Format-User {
    param($User)
    if (-not $User) { return 'none (shared device)' }
    if ($User.displayName) { "$($User.displayName) <$($User.userPrincipalName)>" } else { [string]$User.userPrincipalName }
}

# ================================================================================================
#  What are we doing?
# ================================================================================================
$action = if ($Remove) { 'Remove' } elseif ($UserPrincipalName) { 'Set' } else { 'Show' }
$script:Outcome.Action = $action
Write-Step "Intune primary user - $env:COMPUTERNAME"

if ($Remove -and $UserPrincipalName) { Write-Bad 'Give a user (-UserPrincipalName) or -Remove, not both.'; Exit-WithResult 1 }
if ($UserPrincipalName) {
    $UserPrincipalName = $UserPrincipalName.Trim()
    if ($UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        Write-Bad "'$UserPrincipalName' doesn't look like a sign-in address (name@domain)."
        Exit-WithResult 1
    }
}

# ================================================================================================
#  This PC: tenant and Intune device ID, both read locally
# ================================================================================================
try { $ds = ConvertFrom-DsregOutput @(dsregcmd.exe /status) }
catch { Write-Bad "Couldn't run dsregcmd /status: $($_.Exception.Message)"; Exit-WithResult 1 }
if ($ds['AzureAdJoined'] -ne 'YES') {
    Write-Bad 'This PC isn''t Entra joined, so Intune has no primary user for it.'
    Exit-WithResult 1
}
$tenant     = if ($TenantId) { $TenantId } elseif ($ds['TenantId']) { $ds['TenantId'] } else { $null }
$tenantName = if ($ds['TenantName']) { $ds['TenantName'] } else { $tenant }
if (-not $tenant) { Write-Bad 'Couldn''t read the tenant ID from dsregcmd. Pass -TenantId.'; Exit-WithResult 1 }
$script:Outcome.Tenant = $tenantName
Write-Ok "Entra joined to $tenantName"

$enrolment = $null
try {
    $enrolment = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction Stop |
        Where-Object { $_.ProviderID -eq 'MS DM Server' -and $_.EntDMID }) | Select-Object -First 1
}
catch { Write-Verbose "Enrollments key unreadable: $($_.Exception.Message)" }
if (-not $enrolment) {
    Write-Bad 'This PC isn''t enrolled in Intune, so there''s no primary user to set. Check Settings > Accounts > Access work or school.'
    Exit-WithResult 1
}
$intuneId = [string]$enrolment.EntDMID
$script:Outcome.IntuneDeviceId = $intuneId
Write-Ok "Enrolled in Intune (device ID $intuneId)"

# ================================================================================================
#  Sign in
# ================================================================================================
try { Import-GraphSignIn }
catch { Write-Bad "Couldn't load Microsoft's Graph sign-in module: $($_.Exception.Message)"; Exit-WithResult 1 }

$noDesktop = $false
try { $noDesktop = (Get-Process -Id $PID).SessionId -eq 0 -or -not [Environment]::UserInteractive } catch { $noDesktop = $false }
if ($noDesktop -and -not $UseDeviceCode) {
    Write-Host '    No desktop here for a sign-in window, so using a device code instead.' -ForegroundColor DarkGray
    $UseDeviceCode = $true
}

$scopes = if ($action -eq 'Show') { @('DeviceManagementManagedDevices.Read.All', 'User.Read.All') }
          else { @('DeviceManagementManagedDevices.ReadWrite.All', 'User.Read.All') }
Write-Step "Signing in to $tenantName"
Write-Host '    Use an admin with Intune Administrator (or Help Desk Operator). MFA works as normal.' -ForegroundColor DarkGray
$connect = @{ TenantId = $tenant; Scopes = $scopes; NoWelcome = $true; ErrorAction = 'Stop' }
if ($UseDeviceCode) { $connect.UseDeviceCode = $true }
try {
    Connect-MgGraph @connect | Out-Null
    $script:Connected = $true
    $ctx = Get-MgContext
    $script:Outcome.SignedInAs = [string]$ctx.Account
    Write-Ok "Signed in as $($ctx.Account)"
}
catch { Write-Bad "Sign-in didn't complete: $($_.Exception.Message)"; Exit-WithResult 1 }

# ================================================================================================
#  The device in Intune, and its primary user now
# ================================================================================================
Write-Step 'Finding this PC in Intune'
try {
    $dev = Invoke-MgGraphRequest -Method GET -Uri "$Graph/beta/deviceManagement/managedDevices/$intuneId`?`$select=id,deviceName,serialNumber,userPrincipalName"
}
catch {
    $why = Get-GraphProblem $_ 'This PC in Intune'
    if ($why -match "wasn't found") { $why += ' New enrolments can take a few minutes to appear; try again shortly.' }
    Write-Bad $why
    Exit-WithResult 1
}
try { $before = Get-PrimaryUser -DeviceId $intuneId }
catch { Write-Bad (Get-GraphProblem $_ 'Reading the primary user'); Exit-WithResult 1 }
$script:Outcome.Before = if ($before) { [string]$before.userPrincipalName } else { $null }

Write-Host ("    Device:        {0}   Serial: {1}" -f $dev.deviceName, $dev.serialNumber)
Write-Host ("    Enrolled by:   {0}" -f $(if ($dev.userPrincipalName) { $dev.userPrincipalName } else { '(no user - device enrolment)' }))
Write-Host ("    Primary user:  {0}" -f (Format-User $before))

if ($action -eq 'Show') {
    $script:Outcome.After = $script:Outcome.Before
    Write-Host "`n    Nothing changed. Run again with a user's address to change it, or -Remove." -ForegroundColor DarkGray
    Exit-WithResult 0
}

# ================================================================================================
#  Change it
# ================================================================================================
$target = $null
if ($action -eq 'Remove') {
    if (-not $before) {
        Write-Ok 'There''s no primary user to remove. Nothing to change.'
        Exit-WithResult 0 'No primary user to remove.'
    }
    Write-Step "Removing $($before.userPrincipalName) as primary user"
    try { Invoke-MgGraphRequest -Method DELETE -Uri "$Graph/beta/deviceManagement/managedDevices/$intuneId/users/`$ref" | Out-Null }
    catch { Write-Bad (Get-GraphProblem $_ 'Removing the primary user'); Exit-WithResult 1 }
}
else {
    try {
        $target = Invoke-MgGraphRequest -Method GET -Uri ("$Graph/v1.0/users/{0}?`$select=id,userPrincipalName,displayName,accountEnabled" -f [uri]::EscapeDataString($UserPrincipalName))
    }
    catch { Write-Bad (Get-GraphProblem $_ "User $UserPrincipalName"); Exit-WithResult 1 }
    if ($before -and [string]$before.id -eq [string]$target.id) {
        $script:Outcome.After = $script:Outcome.Before
        Write-Ok "$($target.userPrincipalName) is already the primary user. Nothing to change."
        Exit-WithResult 0 'Already the primary user.'
    }
    if ($target.accountEnabled -eq $false) { Write-Warn2 "$($target.userPrincipalName) is disabled in Entra. Setting it anyway." }
    Write-Step "Making $(Format-User $target) the primary user"
    $body = @{ '@odata.id' = "$Graph/beta/users/$($target.id)" } | ConvertTo-Json
    try { Invoke-MgGraphRequest -Method POST -Uri "$Graph/beta/deviceManagement/managedDevices/$intuneId/users/`$ref" -Body $body -ContentType 'application/json' | Out-Null }
    catch { Write-Bad (Get-GraphProblem $_ 'Setting the primary user'); Exit-WithResult 1 }
}

# Intune can take a moment to reflect it; check a few times.
$after = $null
foreach ($try in 1..4) {
    try { $after = Get-PrimaryUser -DeviceId $intuneId } catch { $after = $null }
    $done = if ($action -eq 'Remove') { -not $after } else { $after -and [string]$after.id -eq [string]$target.id }
    if ($done) { break }
    if ($try -lt 4) { Start-Sleep -Seconds 5 }
}
$script:Outcome.After   = if ($after) { [string]$after.userPrincipalName } else { $null }
$script:Outcome.Changed = $true

if ($done) {
    Write-Ok ("Primary user is now: {0}" -f (Format-User $after))
    Write-Host '    Intune updates the Entra device owner to match. The Company Portal shows it after the next sync.' -ForegroundColor DarkGray
    Exit-WithResult 0
}
Write-Warn2 ('Change sent, but Intune still shows {0}. It can take a few minutes; check the device in Intune.' -f (Format-User $after))
Exit-WithResult 0 'Change sent; Intune had not shown it yet.'
