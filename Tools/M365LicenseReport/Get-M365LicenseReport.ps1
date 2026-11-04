#Requires -Version 5.1
<#
.SYNOPSIS
    Exports a Microsoft 365 user and licence assignment report to a formatted Excel workbook.

.DESCRIPTION
    Connects to Microsoft Graph, pulls every user in the tenant along with their assigned
    licences, and writes a multi-sheet, formatted .xlsx file containing:

        Report Info      - tenant name, who ran it, when, and record counts
        Users            - one row per user, licences summarised in a single column
        License Detail   - one row per user per licence (flat, pivot friendly)
        License Summary  - per SKU: purchased / assigned / available / utilisation %
        License Pivot    - auto-generated pivot + chart of users per licence
        Reclaim          - disabled users holding licences, and stale licensed accounts
        Unlicensed       - enabled users with no licences at all

    Assignment source (direct vs group-based licensing), disabled service plans and
    assignment errors are all captured.

.PARAMETER TenantId
    Tenant to connect to - GUID or domain (e.g. contoso.onmicrosoft.com). Useful when you
    hold accounts in several tenants. Omit to be prompted.

.PARAMETER ClientName
    Friendly name used in the output filename. Defaults to the tenant display name.

.PARAMETER OutputFolder
    Where the .xlsx is written. Created if it does not exist.

.PARAMETER IncludeGuests
    Include guest (B2B) accounts. Excluded by default.

.PARAMETER LicensedOnly
    Only include users holding at least one licence.

.PARAMETER IncludeLastSignIn
    Also pull last sign-in dates. Requires the AuditLog.Read.All scope and Entra ID P1/P2
    on the tenant. If the tenant is not licensed for it the script detects this up front,
    warns, and continues without sign-in data instead of returning an empty report.
    Adds noticeable time on large tenants but makes the Reclaim sheet far more useful.

.PARAMETER StaleDays
    Days without a sign-in before a licensed account is flagged as stale. Default 60.
    Only applies when -IncludeLastSignIn is used.

.PARAMETER InstallMissingModules
    Install any missing modules for the current user instead of stopping.

.PARAMETER NoOpen
    Do not open the workbook when finished.

.EXAMPLE
    .\Get-M365LicenseReport.ps1 -TenantId contoso.onmicrosoft.com -ClientName "Contoso"

.EXAMPLE
    .\Get-M365LicenseReport.ps1 -IncludeLastSignIn -StaleDays 90 -OutputFolder C:\Reports

.NOTES
    Graph scopes used:
        User.Read.All            - user objects and licence assignment states
        Organization.Read.All    - subscribed SKUs / purchased quantities
        Directory.Read.All       - directory metadata
        Group.Read.All           - resolves group names for group-based licensing
        AuditLog.Read.All        - only with -IncludeLastSignIn

    First run against a new tenant will prompt a Global Admin to consent to the
    "Microsoft Graph Command Line Tools" enterprise app. Read-only scopes only.
    The script disconnects at the end so a cached token is not carried into the next tenant.

    Modules: Microsoft.Graph.Authentication, Microsoft.Graph.Users,
             Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Groups, ImportExcel
#>

[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$ClientName,
    [string]$OutputFolder = (Join-Path $env:USERPROFILE 'Documents\M365Reports'),
    [switch]$IncludeGuests,
    [switch]$LicensedOnly,
    [switch]$IncludeLastSignIn,
    [int]$StaleDays = 60,
    [switch]$InstallMissingModules,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$script:StartTime = Get-Date
$script:SignInSkipReason = $null

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan
}

function Get-ColumnLetter {
    # 1 -> A, 27 -> AA. Avoids depending on EPPlus internals.
    param([Parameter(Mandatory)][int]$Column)
    $letter = ''
    while ($Column -gt 0) {
        $remainder = ($Column - 1) % 26
        $letter    = [char](65 + $remainder) + $letter
        $Column    = [math]::Floor(($Column - $remainder) / 26)
    }
    return $letter
}

function Test-SignInActivityBlocked {
    # True when a Graph failure is about the tenant/permissions not being entitled to
    # signInActivity rather than a genuine problem with the user query.
    param([Parameter(Mandatory)]$ErrorRecord)

    $text = @(
        $ErrorRecord.Exception.Message
        $ErrorRecord.ErrorDetails.Message
        $ErrorRecord.FullyQualifiedErrorId
    ) -join ' '

    return [bool]($text -match 'NonPremiumTenantOrB2CTenant|NonPremiumTenant|premium license|Authorization_RequestDenied|AuditLog')
}

function Get-TenantUser {
    param([Parameter(Mandatory)][string[]]$Properties)
    Get-MgUser -All -PageSize 999 -Property $Properties -ErrorAction Stop |
        Select-Object $Properties
}

#region ---------------------------------------------------------------- Modules

$requiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Identity.DirectoryManagement'
    'Microsoft.Graph.Groups'
    'ImportExcel'
)

$missing = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }

if ($missing) {
    if ($InstallMissingModules) {
        foreach ($m in $missing) {
            Write-Step "Installing module $m ..."
            Install-Module $m -Scope CurrentUser -Force -AllowClobber
        }
    }
    else {
        throw ("Missing module(s): {0}`nRun:  Install-Module {0} -Scope CurrentUser`nOr re-run this script with -InstallMissingModules" -f ($missing -join ', '))
    }
}

Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users,
              Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Groups,
              ImportExcel -ErrorAction Stop

#endregion

#region ------------------------------------------------------- Friendly SKU names

# Common SKU part numbers -> product names. Anything not listed falls back to a
# tidied-up version of the SKU part number, so the report never shows a bare GUID.
$skuFriendlyNames = @{
    'SPE_E3'                            = 'Microsoft 365 E3'
    'SPE_E5'                            = 'Microsoft 365 E5'
    'SPE_F1'                            = 'Microsoft 365 F3'
    'SPB'                               = 'Microsoft 365 Business Premium'
    'O365_BUSINESS_ESSENTIALS'          = 'Microsoft 365 Business Basic'
    'O365_BUSINESS_PREMIUM'             = 'Microsoft 365 Business Standard'
    'O365_BUSINESS'                     = 'Microsoft 365 Apps for Business'
    'OFFICESUBSCRIPTION'                = 'Microsoft 365 Apps for Enterprise'
    'STANDARDPACK'                      = 'Office 365 E1'
    'ENTERPRISEPACK'                    = 'Office 365 E3'
    'ENTERPRISEPREMIUM'                 = 'Office 365 E5'
    'DESKLESSPACK'                      = 'Office 365 F3'
    'EXCHANGESTANDARD'                  = 'Exchange Online (Plan 1)'
    'EXCHANGEENTERPRISE'                = 'Exchange Online (Plan 2)'
    'EXCHANGEDESKLESS'                  = 'Exchange Online Kiosk'
    'EXCHANGEARCHIVE_ADDON'             = 'Exchange Online Archiving'
    'EXCHANGEESSENTIALS'                = 'Exchange Online Essentials'
    'SHAREPOINTSTANDARD'                = 'SharePoint Online (Plan 1)'
    'SHAREPOINTENTERPRISE'              = 'SharePoint Online (Plan 2)'
    'MCOSTANDARD'                       = 'Skype for Business Online (Plan 2)'
    'MCOEV'                             = 'Microsoft Teams Phone Standard'
    'MCOEV_VIRTUALUSER'                 = 'Teams Phone Resource Account'
    'PHONESYSTEM_VIRTUALUSER'           = 'Teams Phone Resource Account'
    'MCOPSTN1'                          = 'Domestic Calling Plan'
    'MCOPSTN2'                          = 'Domestic and International Calling Plan'
    'MCOPSTNC'                          = 'Communications Credits'
    'MCOMEETADV'                        = 'Microsoft 365 Audio Conferencing'
    'MCOCAP'                            = 'Common Area Phone'
    'MEETING_ROOM'                      = 'Microsoft Teams Rooms Standard'
    'Teams_Room_Standard'               = 'Microsoft Teams Rooms Standard'
    'Teams_Room_Pro'                    = 'Microsoft Teams Rooms Pro'
    'TEAMS_EXPLORATORY'                 = 'Microsoft Teams Exploratory'
    'AAD_PREMIUM'                       = 'Microsoft Entra ID P1'
    'AAD_PREMIUM_P2'                    = 'Microsoft Entra ID P2'
    'EMS'                               = 'Enterprise Mobility + Security E3'
    'EMSPREMIUM'                        = 'Enterprise Mobility + Security E5'
    'INTUNE_A'                          = 'Microsoft Intune Plan 1'
    'INTUNE_A_D'                        = 'Microsoft Intune Device'
    'RIGHTSMANAGEMENT'                  = 'Azure Information Protection Plan 1'
    'WIN10_VDA_E3'                      = 'Windows 10/11 Enterprise E3'
    'WIN10_VDA_E5'                      = 'Windows 10/11 Enterprise E5'
    'WINDOWS_STORE'                     = 'Windows Store for Business'
    'WIN_DEF_ATP'                       = 'Microsoft Defender for Endpoint'
    'ATP_ENTERPRISE'                    = 'Defender for Office 365 (Plan 1)'
    'THREAT_INTELLIGENCE'               = 'Defender for Office 365 (Plan 2)'
    'IDENTITY_THREAT_PROTECTION'        = 'Microsoft 365 E5 Security'
    'INFORMATION_PROTECTION_COMPLIANCE' = 'Microsoft 365 E5 Compliance'
    'POWER_BI_STANDARD'                 = 'Power BI (free)'
    'POWER_BI_PRO'                      = 'Power BI Pro'
    'PBI_PREMIUM_PER_USER'              = 'Power BI Premium Per User'
    'FLOW_FREE'                         = 'Power Automate Free'
    'POWERAPPS_VIRAL'                   = 'Power Apps Plan 2 Trial'
    'PROJECTESSENTIALS'                 = 'Project Plan 1'
    'PROJECTPROFESSIONAL'               = 'Project Plan 3'
    'PROJECTPREMIUM'                    = 'Project Plan 5'
    'VISIOONLINE_PLAN1'                 = 'Visio Plan 1'
    'VISIOCLIENT'                       = 'Visio Plan 2'
    'STREAM'                            = 'Microsoft Stream'
    'Microsoft_365_Copilot'             = 'Microsoft 365 Copilot'
    'CCIBOTS_PRIVPREV_VIRAL'            = 'Power Virtual Agents Trial'
    'SPZA_IW'                           = 'App Connect IW'
}

function Get-FriendlyLicenseName {
    param([string]$SkuPartNumber)
    if ($skuFriendlyNames.ContainsKey($SkuPartNumber)) {
        return $skuFriendlyNames[$SkuPartNumber]
    }
    # Fallback: TITLE CASE the part number, e.g. FOO_BAR_PLAN1 -> Foo Bar Plan1
    $words = ($SkuPartNumber -replace '_', ' ').ToLower() -split '\s+'
    return (($words | ForEach-Object {
        if ($_.Length -gt 0) { $_.Substring(0,1).ToUpper() + $_.Substring(1) }
    }) -join ' ')
}

#endregion

#region ---------------------------------------------------------------- Connect

$scopes = @(
    'User.Read.All'
    'Organization.Read.All'
    'Directory.Read.All'
    'Group.Read.All'
)
if ($IncludeLastSignIn) { $scopes += 'AuditLog.Read.All' }

Write-Step 'Connecting to Microsoft Graph...'
$connectParams = @{ Scopes = $scopes; NoWelcome = $true }
if ($TenantId) { $connectParams['TenantId'] = $TenantId }
Connect-MgGraph @connectParams

$context = Get-MgContext
if (-not $context) { throw 'Failed to establish a Microsoft Graph connection.' }

$org        = Get-MgOrganization -ErrorAction SilentlyContinue | Select-Object -First 1
$tenantName = if ($org) { $org.DisplayName } else { $context.TenantId }
if (-not $ClientName) { $ClientName = $tenantName }

Write-Host ("  Tenant : {0}" -f $tenantName)     -ForegroundColor Green
Write-Host ("  Signed in as : {0}" -f $context.Account) -ForegroundColor Green

#endregion

#region ------------------------------------------------------------------- SKUs

Write-Step 'Retrieving subscribed SKUs...'
$subscribedSkus = Get-MgSubscribedSku -All

$skuLookup = @{}
foreach ($sku in $subscribedSkus) {
    $planMap = @{}
    foreach ($plan in $sku.ServicePlans) { $planMap[[string]$plan.ServicePlanId] = $plan.ServicePlanName }

    $skuLookup[[string]$sku.SkuId] = [PSCustomObject]@{
        SkuId         = [string]$sku.SkuId
        SkuPartNumber = $sku.SkuPartNumber
        FriendlyName  = Get-FriendlyLicenseName -SkuPartNumber $sku.SkuPartNumber
        Enabled       = $sku.PrepaidUnits.Enabled
        Warning       = $sku.PrepaidUnits.Warning
        Suspended     = $sku.PrepaidUnits.Suspended
        Consumed      = $sku.ConsumedUnits
        ServicePlans  = $planMap
    }
}
Write-Host ("  {0} SKUs found" -f $skuLookup.Count) -ForegroundColor Green

# Graph only exposes signInActivity on tenants entitled to Entra ID P1/P2. Check the
# subscribed SKUs for the AAD_PREMIUM service plans before spending a full user query
# discovering it the hard way (403 Authentication_RequestFromNonPremiumTenantOrB2CTenant).
if ($IncludeLastSignIn) {
    $hasEntraPremium = $false
    foreach ($sku in $subscribedSkus) {
        if ([int]$sku.PrepaidUnits.Enabled -le 0) { continue }
        foreach ($plan in $sku.ServicePlans) {
            if ($plan.ServicePlanName -in @('AAD_PREMIUM','AAD_PREMIUM_P2')) { $hasEntraPremium = $true }
        }
    }

    if (-not $hasEntraPremium) {
        $script:SignInSkipReason = 'Tenant is not licensed for Entra ID P1/P2, so Graph will not return sign-in activity'
        Write-Warning ("{0}. Continuing without sign-in data - the Reclaim sheet will only list disabled-but-licensed accounts." -f $script:SignInSkipReason)
        $IncludeLastSignIn = $false
    }
}

#endregion

#region ------------------------------------------------------------------ Users

$userProperties = @(
    'Id','DisplayName','UserPrincipalName','Mail','AccountEnabled','UserType'
    'Department','JobTitle','OfficeLocation','UsageLocation','CreatedDateTime'
    'AssignedLicenses','LicenseAssignmentStates','OnPremisesSyncEnabled'
)
if ($IncludeLastSignIn) { $userProperties += 'SignInActivity' }

Write-Step 'Retrieving users (this can take a few minutes on large tenants)...'

$users = @()
try {
    $users = @(Get-TenantUser -Properties $userProperties)
}
catch {
    if ($IncludeLastSignIn -and (Test-SignInActivityBlocked -ErrorRecord $_)) {
        $script:SignInSkipReason = ("Graph rejected the sign-in activity query: {0}" -f ($_.Exception.Message -replace '\s+', ' ').Trim())
        Write-Warning ("{0}. Retrying without it." -f $script:SignInSkipReason)
        $IncludeLastSignIn = $false
        $userProperties = @($userProperties | Where-Object { $_ -ne 'SignInActivity' })
        $users = @(Get-TenantUser -Properties $userProperties)
    }
    else { throw }
}

# The Graph SDK reports paging failures as non-terminating errors, so the call above can
# "succeed" and still hand back nothing. Treat an empty result as a failure and retry
# once without sign-in data before giving up.
if ($users.Count -eq 0 -and $IncludeLastSignIn) {
    if (-not $script:SignInSkipReason) {
        $script:SignInSkipReason = 'Sign-in activity query returned no users (tenant likely has no Entra ID P1/P2)'
    }
    Write-Warning ("{0}. Retrying without it." -f $script:SignInSkipReason)
    $IncludeLastSignIn = $false
    $userProperties = @($userProperties | Where-Object { $_ -ne 'SignInActivity' })
    $users = @(Get-TenantUser -Properties $userProperties)
}

if ($users.Count -eq 0) {
    throw ("No users were returned from Microsoft Graph for tenant '{0}'. Check that {1} has the User.Read.All scope and that admin consent was granted, then re-run." -f $tenantName, $context.Account)
}

if (-not $IncludeGuests) { $users = @($users | Where-Object { $_.UserType -ne 'Guest' }) }
Write-Host ("  {0} users retrieved" -f @($users).Count) -ForegroundColor Green

#endregion

#region --------------------------------------------------------- Build the data

Write-Step 'Building report data...'

$groupCache   = @{}
$userRows     = [System.Collections.Generic.List[object]]::new()
$detailRows   = [System.Collections.Generic.List[object]]::new()
$now          = Get-Date
$counter      = 0
$totalUsers   = @($users).Count

foreach ($user in $users) {

    $counter++
    if ($totalUsers -gt 0 -and ($counter % 50 -eq 0 -or $counter -eq $totalUsers)) {
        Write-Progress -Activity 'Processing users' -Status "$counter of $totalUsers" `
                       -PercentComplete (($counter / $totalUsers) * 100)
    }

    # Map SkuId -> disabled service plan GUIDs from the assigned licences collection
    $disabledPlanMap = @{}
    foreach ($al in $user.AssignedLicenses) { $disabledPlanMap[[string]$al.SkuId] = $al.DisabledPlans }

    $userLicenseNames = [System.Collections.Generic.List[string]]::new()
    $assignmentTypes  = [System.Collections.Generic.List[string]]::new()

    # Group licence assignment states by SKU so direct + group assignment collapses to one row
    $statesBySku = $user.LicenseAssignmentStates | Group-Object -Property SkuId

    foreach ($group in $statesBySku) {

        $skuId = [string]$group.Name
        $sku   = $skuLookup[$skuId]
        if (-not $sku) { continue }   # SKU no longer subscribed

        $states       = @($group.Group)
        $hasDirect    = [bool](@($states | Where-Object { -not $_.AssignedByGroup }).Count)
        $groupStates  = @($states | Where-Object { $_.AssignedByGroup })
        $hasGroup     = [bool]$groupStates.Count

        $assignmentType = if ($hasDirect -and $hasGroup) { 'Direct + Group' }
                          elseif ($hasGroup)             { 'Group' }
                          else                           { 'Direct' }

        # Resolve group display names (cached)
        $groupNames = foreach ($gs in $groupStates) {
            $gid = [string]$gs.AssignedByGroup
            if (-not $groupCache.ContainsKey($gid)) {
                try   { $groupCache[$gid] = (Get-MgGroup -GroupId $gid -Property DisplayName).DisplayName }
                catch { $groupCache[$gid] = $gid }
            }
            $groupCache[$gid]
        }

        $errorStates = @($states | Where-Object { $_.Error -and $_.Error -ne 'None' })
        $assignError = if ($errorStates) { ($errorStates.Error | Select-Object -Unique) -join ', ' } else { '' }

        # Disabled service plans within this licence
        $disabledNames = @()
        if ($disabledPlanMap.ContainsKey($skuId) -and $disabledPlanMap[$skuId]) {
            $disabledNames = foreach ($planId in $disabledPlanMap[$skuId]) {
                $key = [string]$planId
                if ($sku.ServicePlans.ContainsKey($key)) { $sku.ServicePlans[$key] } else { $key }
            }
        }

        $userLicenseNames.Add($sku.FriendlyName) | Out-Null
        if (-not $assignmentTypes.Contains($assignmentType)) { $assignmentTypes.Add($assignmentType) | Out-Null }

        $detailRows.Add([PSCustomObject]@{
            'Display Name'      = $user.DisplayName
            'User Principal'    = $user.UserPrincipalName
            'Enabled'           = [bool]$user.AccountEnabled
            'User Type'         = $user.UserType
            'Department'        = $user.Department
            'License'           = $sku.FriendlyName
            'SKU Part Number'   = $sku.SkuPartNumber
            'Assignment Type'   = $assignmentType
            'Assigned Via'      = ($groupNames -join '; ')
            'Assignment Error'  = $assignError
            'Disabled Services' = ($disabledNames -join '; ')
        }) | Out-Null
    }

    if ($LicensedOnly -and $userLicenseNames.Count -eq 0) { continue }

    $lastSignIn = $null
    $lastNonInteractive = $null
    $daysSinceSignIn = $null
    if ($IncludeLastSignIn -and $user.SignInActivity) {
        $lastSignIn         = $user.SignInActivity.LastSignInDateTime
        $lastNonInteractive = $user.SignInActivity.LastNonInteractiveSignInDateTime
        $mostRecent = @($lastSignIn, $lastNonInteractive) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
        if ($mostRecent) { $daysSinceSignIn = [int]($now - $mostRecent).TotalDays }
    }

    $row = [ordered]@{
        'Display Name'     = $user.DisplayName
        'User Principal'   = $user.UserPrincipalName
        'Enabled'          = [bool]$user.AccountEnabled
        'User Type'        = $user.UserType
        'Department'       = $user.Department
        'Job Title'        = $user.JobTitle
        'Office'           = $user.OfficeLocation
        'Usage Location'   = $user.UsageLocation
        'License Count'    = $userLicenseNames.Count
        'Licenses'         = (($userLicenseNames | Sort-Object) -join '; ')
        'Assignment Type'  = (($assignmentTypes | Sort-Object) -join ' / ')
        'Directory Synced' = [bool]$user.OnPremisesSyncEnabled
        'Created'          = if ($user.CreatedDateTime) { [datetime]$user.CreatedDateTime } else { $null }
    }
    if ($IncludeLastSignIn) {
        $row['Last Sign-In']         = if ($lastSignIn) { [datetime]$lastSignIn } else { $null }
        $row['Last Non-Interactive'] = if ($lastNonInteractive) { [datetime]$lastNonInteractive } else { $null }
        $row['Days Since Sign-In']   = $daysSinceSignIn
    }

    $userRows.Add([PSCustomObject]$row) | Out-Null
}
Write-Progress -Activity 'Processing users' -Completed

# ---- License summary -------------------------------------------------------
$disabledUserLicenseCounts = $detailRows |
    Where-Object { -not $_.Enabled } |
    Group-Object -Property 'SKU Part Number' -AsHashTable -AsString

$summaryRows = foreach ($sku in ($skuLookup.Values | Sort-Object FriendlyName)) {
    $onDisabled = 0
    if ($disabledUserLicenseCounts -and $disabledUserLicenseCounts.ContainsKey($sku.SkuPartNumber)) {
        $onDisabled = @($disabledUserLicenseCounts[$sku.SkuPartNumber]).Count
    }
    $total = [int]$sku.Enabled
    [PSCustomObject]@{
        'Product'             = $sku.FriendlyName
        'SKU Part Number'     = $sku.SkuPartNumber
        'Purchased'           = $total
        'Assigned'            = [int]$sku.Consumed
        'Available'           = $total - [int]$sku.Consumed
        'Utilisation'         = if ($total -gt 0) { [math]::Round([double]$sku.Consumed / $total, 4) } else { 0 }
        'On Disabled Users'   = $onDisabled
        'Warning Units'       = [int]$sku.Warning
        'Suspended Units'     = [int]$sku.Suspended
        'SKU ID'              = $sku.SkuId
    }
}
$summaryRows = @($summaryRows)

# ---- Reclaim candidates ----------------------------------------------------
$reclaimRows = [System.Collections.Generic.List[object]]::new()

foreach ($u in $userRows | Where-Object { $_.'License Count' -gt 0 -and -not $_.Enabled }) {
    $reclaimRows.Add([PSCustomObject]@{
        'Reason'         = 'Account disabled but licensed'
        'Display Name'   = $u.'Display Name'
        'User Principal' = $u.'User Principal'
        'License Count'  = $u.'License Count'
        'Licenses'       = $u.Licenses
        'Days Since Sign-In' = if ($IncludeLastSignIn) { $u.'Days Since Sign-In' } else { $null }
    }) | Out-Null
}

if ($IncludeLastSignIn) {
    foreach ($u in $userRows | Where-Object {
            $_.'License Count' -gt 0 -and $_.Enabled -and
            ($null -eq $_.'Days Since Sign-In' -or $_.'Days Since Sign-In' -ge $StaleDays)
        }) {
        $reason = if ($null -eq $u.'Days Since Sign-In') { 'Licensed, never signed in' }
                  else { "Licensed, no sign-in in $StaleDays+ days" }
        $reclaimRows.Add([PSCustomObject]@{
            'Reason'             = $reason
            'Display Name'       = $u.'Display Name'
            'User Principal'     = $u.'User Principal'
            'License Count'      = $u.'License Count'
            'Licenses'           = $u.Licenses
            'Days Since Sign-In' = $u.'Days Since Sign-In'
        }) | Out-Null
    }
}

# ---- Unlicensed enabled users ---------------------------------------------
$unlicensedRows = @($userRows | Where-Object { $_.'License Count' -eq 0 -and $_.Enabled } |
    Select-Object 'Display Name','User Principal','User Type','Department','Job Title','Directory Synced','Created')

#endregion

#region ----------------------------------------------------------- Excel export

if (-not (Test-Path $OutputFolder)) { New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null }

$safeClient = ($ClientName -replace '[\\/:*?"<>|]', '-').Trim()
$fileName   = "M365-License-Report_{0}_{1}.xlsx" -f $safeClient, (Get-Date -Format 'yyyyMMdd-HHmm')
$filePath   = Join-Path $OutputFolder $fileName
if (Test-Path $filePath) { Remove-Item $filePath -Force }

Write-Step "Writing workbook: $filePath"

# ---- Report info sheet -----------------------------------------------------
$info = @(
    [PSCustomObject]@{ Item = 'Tenant';                Value = $tenantName }
    [PSCustomObject]@{ Item = 'Tenant ID';             Value = $context.TenantId }
    [PSCustomObject]@{ Item = 'Report generated';      Value = (Get-Date -Format 'dd/MM/yyyy HH:mm') }
    [PSCustomObject]@{ Item = 'Generated by';          Value = $context.Account }
    [PSCustomObject]@{ Item = 'Run from';              Value = "$env:COMPUTERNAME ($env:USERNAME)" }
    [PSCustomObject]@{ Item = 'Users in report';       Value = $userRows.Count }
    [PSCustomObject]@{ Item = 'Licence assignments';   Value = $detailRows.Count }
    [PSCustomObject]@{ Item = 'Subscribed SKUs';       Value = $summaryRows.Count }
    [PSCustomObject]@{ Item = 'Guests included';       Value = [bool]$IncludeGuests }
    [PSCustomObject]@{ Item = 'Sign-in data included'; Value = [bool]$IncludeLastSignIn }
    [PSCustomObject]@{ Item = 'Stale threshold (days)';Value = $(if ($IncludeLastSignIn) { $StaleDays } else { 'n/a' }) }
)

if ($script:SignInSkipReason) {
    $info += [PSCustomObject]@{ Item = 'Sign-in data note'; Value = $script:SignInSkipReason }
}

$excel = $info | Export-Excel -Path $filePath -WorksheetName 'Report Info' `
    -TableName 'tblInfo' -TableStyle 'Light1' -AutoSize -PassThru

# ---- License summary -------------------------------------------------------
$excel = $summaryRows | Export-Excel -ExcelPackage $excel -WorksheetName 'License Summary' `
    -TableName 'tblSummary' -TableStyle 'Medium6' -AutoSize -FreezeTopRow -PassThru

$wsSummary = $excel.Workbook.Worksheets['License Summary']
$sumLast   = $summaryRows.Count + 1
if ($sumLast -gt 1) {
    Set-ExcelRange -Worksheet $wsSummary -Range "F2:F$sumLast" -NumberFormat '0.0%'
    Add-ConditionalFormatting -Worksheet $wsSummary -Address "F2:F$sumLast" -DataBarColor Blue
    # Highlight SKUs that are fully consumed (no spare licences)
    Add-ConditionalFormatting -Worksheet $wsSummary -Address "E2:E$sumLast" -RuleType LessThanOrEqual `
        -ConditionValue 0 -BackgroundColor '#FFC7CE' -ForegroundColor '#9C0006'
    # Highlight waste: licences sitting on disabled accounts
    Add-ConditionalFormatting -Worksheet $wsSummary -Address "G2:G$sumLast" -RuleType GreaterThan `
        -ConditionValue 0 -BackgroundColor '#FFEB9C' -ForegroundColor '#9C6500'

    try {
        Add-ExcelChart -Worksheet $wsSummary -ChartType ColumnClustered -Title 'Purchased vs Assigned' `
            -XRange "A2:A$sumLast" -YRange @("C2:C$sumLast", "D2:D$sumLast") `
            -Row 1 -Column ($summaryRows[0].PSObject.Properties.Name.Count + 1) -Width 700 -Height 380 | Out-Null
    }
    catch { Write-Warning "Chart could not be created: $($_.Exception.Message)" }
}

# ---- Users -----------------------------------------------------------------
$excel = $userRows | Export-Excel -ExcelPackage $excel -WorksheetName 'Users' `
    -TableName 'tblUsers' -TableStyle 'Medium2' -AutoSize -FreezeTopRow -PassThru

$wsUsers  = $excel.Workbook.Worksheets['Users']
$userLast = $userRows.Count + 1
if ($userLast -gt 1) {
    $lastColLetter = Get-ColumnLetter -Column $wsUsers.Dimension.End.Column
    # Grey out disabled accounts (column C = Enabled)
    Add-ConditionalFormatting -Worksheet $wsUsers -Address ("A2:{0}{1}" -f $lastColLetter, $userLast) `
        -RuleType Expression -ConditionValue '=$C2=FALSE' -BackgroundColor '#F2F2F2' -ForegroundColor '#808080'
    # Date columns
    foreach ($colName in @('Created','Last Sign-In','Last Non-Interactive')) {
        $idx = ($wsUsers.Cells['1:1'] | Where-Object { $_.Value -eq $colName } | Select-Object -First 1)
        if ($idx) {
            $letter = Get-ColumnLetter -Column $idx.Start.Column
            Set-ExcelRange -Worksheet $wsUsers -Range ("{0}2:{0}{1}" -f $letter, $userLast) -NumberFormat 'dd/mm/yyyy'
        }
    }
    # Keep the Licenses column readable rather than a mile wide
    $licIdx = ($wsUsers.Cells['1:1'] | Where-Object { $_.Value -eq 'Licenses' } | Select-Object -First 1)
    if ($licIdx) {
        $wsUsers.Column($licIdx.Start.Column).Width = 55
        $licLetter = Get-ColumnLetter -Column $licIdx.Start.Column
        Set-ExcelRange -Worksheet $wsUsers -Range ("{0}2:{0}{1}" -f $licLetter, $userLast) -WrapText
    }
}

# ---- License detail + pivot ------------------------------------------------
$detailExportParams = @{
    ExcelPackage  = $excel
    WorksheetName = 'License Detail'
    TableName     = 'tblDetail'
    TableStyle    = 'Medium2'
    AutoSize      = $true
    FreezeTopRow  = $true
    PassThru      = $true
}

# A pivot over an empty sheet just emits "Could not add 'License' to Rows" warnings,
# so only attach the definition when there is something to pivot.
if ($detailRows.Count -gt 0) {
    $detailExportParams['PivotTableDefinition'] = New-PivotTableDefinition -PivotTableName 'License Pivot' `
        -SourceWorkSheet 'License Detail' `
        -PivotRows 'License' -PivotColumns 'Assignment Type' `
        -PivotData @{ 'User Principal' = 'Count' } `
        -PivotTableStyle 'Medium6' -IncludePivotChart -ChartType BarClustered
}

$excel = $detailRows | Export-Excel @detailExportParams

$wsDetail  = $excel.Workbook.Worksheets['License Detail']
$detailLast = $detailRows.Count + 1
if ($detailLast -gt 1) {
    # Flag assignment errors (column J = Assignment Error)
    Add-ConditionalFormatting -Worksheet $wsDetail -Address "J2:J$detailLast" -RuleType Expression `
        -ConditionValue '=$J2<>""' -BackgroundColor '#FFC7CE' -ForegroundColor '#9C0006'
}

# ---- Reclaim ---------------------------------------------------------------
if ($reclaimRows.Count -gt 0) {
    $excel = $reclaimRows | Export-Excel -ExcelPackage $excel -WorksheetName 'Reclaim' `
        -TableName 'tblReclaim' -TableStyle 'Medium3' -AutoSize -FreezeTopRow -PassThru
}

# ---- Unlicensed ------------------------------------------------------------
if ($unlicensedRows.Count -gt 0) {
    $excel = $unlicensedRows | Export-Excel -ExcelPackage $excel -WorksheetName 'Unlicensed' `
        -TableName 'tblUnlicensed' -TableStyle 'Medium4' -AutoSize -FreezeTopRow -PassThru
}

# ---- Workbook-wide tidy-up -------------------------------------------------
foreach ($ws in $excel.Workbook.Worksheets) {
    $ws.View.ShowGridLines = $false
    if ($ws.Dimension) {
        Set-ExcelRange -Worksheet $ws -Range $ws.Dimension.Address -FontName 'Calibri' -FontSize 11
        Set-ExcelRange -Worksheet $ws -Range ("A1:{0}1" -f (Get-ColumnLetter -Column $ws.Dimension.End.Column)) -Bold
    }
}
$excel.Workbook.Properties.Title  = "Microsoft 365 Licence Report - $tenantName"
$excel.Workbook.Properties.Author = $context.Account
$excel.Workbook.Worksheets['Report Info'].Select()

Close-ExcelPackage $excel -Show:(-not $NoOpen)

#endregion

#region ---------------------------------------------------------------- Wrap up

Write-Step 'Disconnecting from Microsoft Graph...'
Disconnect-MgGraph | Out-Null

$duration = (Get-Date) - $script:StartTime
Write-Host ''
Write-Host '--------------------------------------------------' -ForegroundColor DarkGray
Write-Host ("Report complete in {0:mm}m {0:ss}s" -f $duration) -ForegroundColor Green
Write-Host ("  Users            : {0}" -f $userRows.Count)
Write-Host ("  Licences assigned: {0}" -f $detailRows.Count)
Write-Host ("  SKUs             : {0}" -f $summaryRows.Count)
Write-Host ("  Reclaim flags    : {0}" -f $reclaimRows.Count)
Write-Host ("  File             : {0}" -f $filePath) -ForegroundColor Yellow
Write-Host '--------------------------------------------------' -ForegroundColor DarkGray

#endregion
