<#
.SYNOPSIS
    Per-user Exchange Online + Planner engagement report for a Microsoft 365 tenant.

.DESCRIPTION
    Answers: "have we licensed people for Exchange / Planner who don't actually use it?"

      Exchange : Graph usage report - emails sent/read/received over the report period.  Works on any licence.
      Planner  : Unified audit log - Planner/Project events, split into edits vs views.    Needs Audit (Premium) + paid Planner/Project licence (see NOTES).
                 Entra sign-in logs - sign-ins to Planner/Project apps.                    Needs Entra ID P1, 30 days max.
      Sign-in  : Entra signInActivity - last successful sign-in to anything.               Needs Entra ID P1.

    Output: CSV (plus XLSX if the ImportExcel module is installed) and a console summary.
    Flagged users (licensed-but-unused, disabled-but-licensed) sort to the top.

.PARAMETER TenantId
    Customer tenant, e.g. contoso.onmicrosoft.com. Strongly recommended.

.PARAMETER UseGDAP
    Connect to Exchange Online with -DelegatedOrganization (partner/GDAP access). Requires -TenantId.

.PARAMETER Days
    Look-back window. Default 90. The Exchange report snaps to the nearest Graph period (7/30/90/180).

.PARAMETER SkipSignInLogs
    Skip the Planner sign-in log check (it pages every successful sign-in for 30 days - slow on big tenants).

.PARAMETER TempUnconcealReports
    If report user names are concealed, switch that off for the run and restore it afterwards, without prompting.

.PARAMETER OutputFolder
    Where the report is saved. Default: Documents\M365Reports (created if missing).

.EXAMPLE
    .\Get-ExchangePlannerUsage.ps1 -TenantId contoso.onmicrosoft.com

.EXAMPLE
    .\Get-ExchangePlannerUsage.ps1 -TenantId contoso.onmicrosoft.com -UseGDAP -TempUnconcealReports -SkipSignInLogs

.NOTES
    Modules : Microsoft.Graph.Authentication, ExchangeOnlineManagement   (optional: ImportExcel)
    Roles   : Global Reader + View-Only Audit Logs covers all the reads.
              Toggling report concealment needs an admin who can change Org settings > Reports (e.g. Global Admin).

    PLANNER CAVEAT: Microsoft only writes Planner/Project audit events for tenants with Audit (Premium)
    (E5 or the add-on) AND a paid Project/Planner Plan 1 or higher (MC590113). On Business Premium / E3
    the audit search will usually find nothing. The script spots that and marks Planner as
    "Unknown - no audit data" rather than accusing the whole company of never opening Planner.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TenantId,
    [switch]$UseGDAP,
    [ValidateRange(1, 180)][int]$Days = 90,
    [switch]$SkipSignInLogs,
    [switch]$TempUnconcealReports,
    [string]$OutputFolder = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'M365Reports')
)

$ErrorActionPreference = 'Stop'

#region ---- Tunables ---------------------------------------------------------
$ExchangePlanPattern   = '^EXCHANGE_S_(STANDARD|ENTERPRISE|DESKLESS|ESSENTIALS)'  # mailbox-granting plans (EXCHANGE_S_FOUNDATION excluded - it's not a mailbox)
$PlannerPlanPattern    = '^PROJECTWORKMANAGEMENT'                                  # Planner (basic) service plan bundled in M365 suites
$PaidPlannerSkuPattern = '^(PROJECT(?!_MADEIRA)|PLANNER)'                          # Project / Planner Plan 1/3/5 SKUs (PROJECT_MADEIRA is Business Central, not Project)
$PlannerAppPattern     = 'Planner|Project'                                         # app display names matched in sign-in logs
$PlannerRecordTypes    = @('PlannerPlan', 'PlannerTask', 'PlannerPlanList', 'PlannerTaskList', 'PlannerCopyPlan', 'PlannerRoster',
                           'ProjectForTheWebProject', 'ProjectForTheWebTask')
$SignInDays            = 30                                                        # Entra sign-in log retention (P1/P2)
#endregion

#region ---- Helpers ----------------------------------------------------------
function Write-Step([string]$Message) { Write-Host "`n>> $Message" -ForegroundColor Cyan }

function ConvertTo-NullableDate($Value) {
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return [datetime]$Value } catch { return $null }
}

function Format-Date($Value) {
    if ($Value) { return ([datetime]$Value).ToString('yyyy-MM-dd') }
    return $null
}

function Invoke-GraphPaged([string]$Uri) {
    $items = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType HashTable
        foreach ($i in $resp.value) { $items.Add($i) }
        $Uri = $resp.'@odata.nextLink'
    }
    return , $items.ToArray()
}

function Get-GraphReport([string]$Function) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('m365rpt_{0}.csv' -f [guid]::NewGuid())
    try {
        Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/reports/$Function" -OutputFilePath $tmp
        return , @(Import-Csv -Path $tmp -Encoding UTF8)
    }
    finally { Remove-Item -Path $tmp -ErrorAction SilentlyContinue }
}

function Set-ReportConcealment([bool]$Conceal) {
    $body = @{ displayConcealedNames = $Conceal } | ConvertTo-Json
    Invoke-MgGraphRequest -Method PATCH -Uri 'https://graph.microsoft.com/v1.0/admin/reportSettings' -Body $body -ContentType 'application/json' | Out-Null
}

function Search-AuditWithRetry([datetime]$Start, [datetime]$End, [string]$RecordType, [string]$SessionId) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return , @(Search-UnifiedAuditLog -StartDate $Start -EndDate $End -RecordType $RecordType `
                    -SessionId $SessionId -SessionCommand ReturnLargeSet -ResultSize 5000 -ErrorAction Stop)
        }
        catch {
            # Don't retry on "that record type doesn't exist" style errors, only on transient ones
            if ($attempt -eq 3 -or $_.Exception.Message -match 'Cannot (bind|convert|validate)') { throw }
            Start-Sleep -Seconds (10 * $attempt)
        }
    }
}

function Add-AuditBatch($Batch) {
    foreach ($rec in $Batch) {
        if (-not $script:seenIds.Add([string]$rec.Identity)) { continue }   # ReturnLargeSet can hand back duplicates
        $upn = ([string]$rec.UserIds).ToLower()
        if (-not $script:plannerActivity.ContainsKey($upn)) {
            $script:plannerActivity[$upn] = @{ Last = $null; Views = 0; Edits = 0 }
        }
        $entry = $script:plannerActivity[$upn]
        if ($rec.Operations -match 'Read$') { $entry.Views++ } else { $entry.Edits++ }
        if (-not $entry.Last -or $rec.CreationDate -gt $entry.Last) { $entry.Last = $rec.CreationDate }
        $script:plannerEventTotal++
    }
}

# Searches one window; if it's over the 50k ReturnLargeSet cap, splits it in half and recurses.
function Invoke-AuditWindow([datetime]$Start, [datetime]$End, [string]$RecordType) {
    Write-Progress -Activity 'Planner audit search' -Status ('{0}  {1:dd MMM HH:mm} - {2:dd MMM HH:mm}' -f $RecordType, $Start, $End)
    $sessionId = [guid]::NewGuid().ToString()
    $batch = Search-AuditWithRetry -Start $Start -End $End -RecordType $RecordType -SessionId $sessionId
    if ($batch.Count -eq 0) { return }

    $expected = [int]$batch[0].ResultCount
    if ($expected -ge 50000) {
        if (($End - $Start).TotalHours -gt 2) {
            $mid = $Start.AddTicks([long](($End - $Start).Ticks / 2))
            Invoke-AuditWindow $Start $mid $RecordType
            Invoke-AuditWindow $mid $End $RecordType
            return
        }
        Write-Warning ('{0} {1:dd MMM HH:mm}: 50,000+ events in a 2-hour window - results for that window are partial.' -f $RecordType, $Start)
    }

    $retrieved = 0; $pages = 0
    while ($batch.Count -gt 0) {
        Add-AuditBatch $batch
        $retrieved += $batch.Count; $pages++
        if ($retrieved -ge $expected -or $pages -ge 10) { break }
        $batch = Search-AuditWithRetry -Start $Start -End $End -RecordType $RecordType -SessionId $sessionId
    }
}
#endregion

#region ---- Pre-flight -------------------------------------------------------
if ($UseGDAP -and -not $TenantId) { throw '-UseGDAP needs -TenantId (the customer''s tenant domain).' }
foreach ($m in 'Microsoft.Graph.Authentication', 'ExchangeOnlineManagement') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Module '$m' missing. Run: Install-Module $m -Scope CurrentUser" }
}
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }

$period      = if ($Days -le 7) { 7 } elseif ($Days -le 30) { 30 } elseif ($Days -le 90) { 90 } else { 180 }
$cutoff      = (Get-Date).Date.AddDays(-$Days)
$concealFlip = $false
#endregion

try {
    #region ---- Connect ------------------------------------------------------
    Write-Step 'Connecting to Microsoft Graph'
    $mg = @{
        Scopes    = 'User.Read.All', 'Reports.Read.All', 'AuditLog.Read.All', 'Organization.Read.All', 'ReportSettings.ReadWrite.All'
        NoWelcome = $true
    }
    if ($TenantId) { $mg.TenantId = $TenantId }
    Connect-MgGraph @mg

    $org        = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=displayName').value[0]
    $tenantName = $org.displayName
    if ((Read-Host "Connected to '$tenantName'. Correct tenant? (Y/N)") -notmatch '^[Yy]') { throw 'Aborted - wrong tenant.' }

    Write-Step 'Connecting to Exchange Online'
    $exo = @{ ShowBanner = $false }
    if ($UseGDAP) { $exo.DelegatedOrganization = $TenantId }
    Connect-ExchangeOnline @exo
    #endregion

    #region ---- Report concealment ------------------------------------------
    Write-Step 'Checking usage report name concealment'
    try {
        $rs = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/admin/reportSettings'
        if ($rs.displayConcealedNames) {
            Write-Warning 'Usage reports show concealed (hashed) names, so Exchange data can''t be matched to users.'
            if ($TempUnconcealReports -or (Read-Host 'Temporarily un-conceal for this run and restore afterwards? (Y/N)') -match '^[Yy]') {
                Set-ReportConcealment $false
                $concealFlip = $true
                Write-Host 'Concealment OFF for now - it gets switched back on after the Exchange pull.' -ForegroundColor Yellow
            }
        }
        else { Write-Host 'Names not concealed - good.' }
    }
    catch { Write-Warning "Couldn't read report settings ($($_.Exception.Message)). Carrying on." }
    #endregion

    #region ---- Users & licences ---------------------------------------------
    Write-Step 'Getting licensed users'
    $planNames = @{}; $skuNames = @{}
    foreach ($sku in (Invoke-GraphPaged 'https://graph.microsoft.com/v1.0/subscribedSkus')) {
        $skuNames[[string]$sku.skuId] = $sku.skuPartNumber
        foreach ($sp in $sku.servicePlans) { $planNames[[string]$sp.servicePlanId] = $sp.servicePlanName }
    }

    $select = 'id,displayName,userPrincipalName,accountEnabled,userType,assignedLicenses,assignedPlans'
    $hasSignInActivity = $true
    try {
        $allUsers = Invoke-GraphPaged "https://graph.microsoft.com/v1.0/users?`$select=$select,signInActivity&`$top=120"
    }
    catch {
        Write-Warning 'signInActivity unavailable (needs Entra ID P1) - "Last Sign-in" will be blank.'
        $hasSignInActivity = $false
        $allUsers = Invoke-GraphPaged "https://graph.microsoft.com/v1.0/users?`$select=$select&`$top=999"
    }
    $users = @($allUsers | Where-Object { $_.userType -eq 'Member' -and @($_.assignedLicenses).Count -gt 0 })
    Write-Host "$($users.Count) licensed member accounts"
    #endregion

    #region ---- Exchange -----------------------------------------------------
    Write-Step "Pulling Exchange email activity report (last $period days)"
    $emailRows  = Get-GraphReport "getEmailActivityUserDetail(period='D$period')"
    $emailByUpn = @{}
    foreach ($r in $emailRows) {
        if ($r.'User Principal Name') { $emailByUpn[$r.'User Principal Name'.ToLower()] = $r }
    }
    if ($emailRows.Count -and -not ($emailRows | Where-Object { $_.'User Principal Name' -like '*@*' })) {
        Write-Warning 'Report UPNs are still hashed - Exchange columns will be empty. If you just un-concealed, give it a few minutes and rerun.'
    }
    if ($concealFlip) {
        Set-ReportConcealment $true
        $concealFlip = $false
        Write-Host 'Report concealment restored.' -ForegroundColor Yellow
    }
    #endregion

    #region ---- Planner: audit log -------------------------------------------
    Write-Step "Searching audit log for Planner/Project events (last $Days days - grab a coffee)"
    try {
        if (-not (Get-AdminAuditLogConfig).UnifiedAuditLogIngestionEnabled) { Write-Warning 'Unified audit logging is OFF in this tenant.' }
    }
    catch { Write-Verbose "Couldn't read audit config: $($_.Exception.Message)" }

    $script:plannerActivity   = @{}
    $script:seenIds           = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:plannerEventTotal = 0
    $auditEnd                 = Get-Date

    foreach ($rt in $PlannerRecordTypes) {
        try { Invoke-AuditWindow -Start $cutoff -End $auditEnd -RecordType $rt }
        catch { Write-Warning ('Audit search for {0} failed: {1}' -f $rt, $_.Exception.Message) }
    }
    Write-Progress -Activity 'Planner audit search' -Completed
    Write-Host "$($script:plannerEventTotal) Planner/Project audit events across $($script:plannerActivity.Count) accounts"

    $hasAuditData = $script:plannerEventTotal -gt 0
    if (-not $hasAuditData) {
        Write-Warning ('No Planner/Project audit events at all. Microsoft only records these with Audit (Premium) + a paid ' +
                       'Planner/Project Plan 1 licence, so on Business Premium/E3 this is expected. It does NOT mean nobody uses Planner.')
    }
    #endregion

    #region ---- Planner: sign-in logs ----------------------------------------
    $plannerSignIns  = @{}
    $plannerAppsSeen = @{}
    if (-not $SkipSignInLogs) {
        Write-Step "Checking sign-in logs for Planner/Project apps (last $SignInDays days)"
        $since   = (Get-Date).ToUniversalTime().AddDays(-$SignInDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $filter  = [uri]::EscapeDataString("createdDateTime ge $since and status/errorCode eq 0")
        $uri     = "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$filter=$filter&`$top=1000"
        $scanned = 0
        try {
            while ($uri) {
                $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType HashTable
                foreach ($s in $resp.value) {
                    $scanned++
                    if ([string]$s.appDisplayName -notmatch $PlannerAppPattern) { continue }
                    $upn  = ([string]$s.userPrincipalName).ToLower()
                    $when = ConvertTo-NullableDate $s.createdDateTime
                    $plannerAppsSeen[[string]$s.appDisplayName] = $true
                    if (-not $plannerSignIns.ContainsKey($upn) -or $when -gt $plannerSignIns[$upn]) { $plannerSignIns[$upn] = $when }
                }
                Write-Progress -Activity 'Sign-in log scan' -Status "$scanned sign-ins scanned"
                $uri = $resp.'@odata.nextLink'
            }
            Write-Progress -Activity 'Sign-in log scan' -Completed
            Write-Host "$scanned sign-ins scanned; $($plannerSignIns.Count) users hit: $((@($plannerAppsSeen.Keys) | Sort-Object) -join ', ')"
        }
        catch { Write-Warning "Sign-in log query failed (needs Entra ID P1): $($_.Exception.Message)" }
    }
    #endregion

    #region ---- Build report -------------------------------------------------
    Write-Step 'Building report'
    $report = foreach ($u in $users) {
        $upn          = ([string]$u.userPrincipalName).ToLower()
        $enabledPlans = @($u.assignedPlans | Where-Object { $_.capabilityStatus -in 'Enabled', 'Warning' } |
                          ForEach-Object { $planNames[[string]$_.servicePlanId] } | Where-Object { $_ })
        $skuList      = @($u.assignedLicenses | ForEach-Object { $skuNames[[string]$_.skuId] } | Where-Object { $_ })

        $exLicensed = @($enabledPlans -match $ExchangePlanPattern).Count -gt 0
        $plPaid     = @($skuList -match $PaidPlannerSkuPattern).Count -gt 0
        $plLicensed = $plPaid -or (@($enabledPlans -match $PlannerPlanPattern).Count -gt 0)

        # --- Exchange
        $em = $emailByUpn[$upn]
        $sent = $null; $read = $null; $recv = $null; $exLast = $null
        if ($em) {
            $sent   = [int]$em.'Send Count'
            $read   = [int]$em.'Read Count'
            $recv   = [int]$em.'Receive Count'
            $exLast = ConvertTo-NullableDate $em.'Last Activity Date'
        }
        $exStatus = switch ($true) {
            (-not $exLicensed)      { 'Not licensed'; break }
            (-not $em)              { 'No report data'; break }
            (($sent + $read) -eq 0) { 'Unused'; break }
            ($sent -eq 0)           { 'Reading only'; break }
            default                 { 'Active' }
        }

        # --- Planner
        $pa = $plannerActivity[$upn]
        $ps = $plannerSignIns[$upn]
        $plLast = $null; $plEdits = $null; $plViews = $null
        if ($pa) { $plLast = $pa.Last; $plEdits = $pa.Edits; $plViews = $pa.Views }
        $plStatus = switch ($true) {
            (-not $plLicensed)         { 'Not licensed'; break }
            ($pa -and $pa.Edits -gt 0) { 'Active (editing)'; break }
            ($pa -and $pa.Views -gt 0) { 'Viewing only'; break }
            ([bool]$ps)                { 'Signed in to app only'; break }
            ($hasAuditData)            { 'Unused'; break }
            default                    { 'Unknown - no audit data' }
        }

        # --- Last sign-in (any app)
        $lastSignIn = $null
        if ($hasSignInActivity -and $u.signInActivity) {
            $sia = $u.signInActivity
            $lastSignIn = ConvertTo-NullableDate $(if ($sia.lastSuccessfulSignInDateTime) { $sia.lastSuccessfulSignInDateTime } else { $sia.lastSignInDateTime })
        }

        # --- Flags
        $flags = @()
        if (-not $u.accountEnabled)                     { $flags += 'Disabled but licensed' }
        if ($exStatus -eq 'Unused')                     { $flags += 'Exchange unused' }
        if ($plStatus -eq 'Unused' -and -not $plPaid)   { $flags += 'Planner unused' }
        if ($plPaid -and $plStatus -in 'Unused', 'Unknown - no audit data') { $flags += 'Paid Planner/Project licence - no use seen' }

        [pscustomobject]@{
            'Display Name'                         = $u.displayName
            'UPN'                                  = $u.userPrincipalName
            'Account Enabled'                      = $u.accountEnabled
            'Flags'                                = $flags -join '; '
            'Last Sign-in (any app)'               = Format-Date $lastSignIn
            'Exchange Licensed'                    = $exLicensed
            'Exchange Status'                      = $exStatus
            'Exchange Last Activity'               = Format-Date $exLast
            "Emails Sent (${period}d)"             = $sent
            "Emails Read (${period}d)"             = $read
            "Emails Received (${period}d)"         = $recv
            'Planner Licensed'                     = $plLicensed
            'Paid Planner/Project Licence'         = $plPaid
            'Planner Status'                       = $plStatus
            'Planner Last Activity'                = Format-Date $plLast
            "Planner Edits (${Days}d)"             = $plEdits
            "Planner Views (${Days}d)"             = $plViews
            "Planner App Sign-in (${SignInDays}d)" = Format-Date $ps
            'Licences'                             = $skuList -join '; '
        }
    }
    $report = @($report | Sort-Object @{ Expression = { [bool]$_.Flags }; Descending = $true }, 'Display Name')
    #endregion

    #region ---- Export -------------------------------------------------------
    $safeTenant = $tenantName -replace '[^\w\-]+', '_'
    $basePath   = Join-Path $OutputFolder ('M365_Usage_{0}_{1:yyyyMMdd_HHmm}' -f $safeTenant, (Get-Date))
    $report | Export-Csv -Path "$basePath.csv" -NoTypeInformation -Encoding UTF8
    Write-Host "`nSaved: $basePath.csv" -ForegroundColor Green
    if (Get-Module -ListAvailable -Name ImportExcel) {
        $report | Export-Excel -Path "$basePath.xlsx" -WorksheetName 'Usage' -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow
        Write-Host "Saved: $basePath.xlsx" -ForegroundColor Green
    }
    #endregion

    #region ---- Summary ------------------------------------------------------
    Write-Step "Summary - $tenantName"
    foreach ($svc in 'Exchange', 'Planner') {
        Write-Host "$svc (licensed users):" -ForegroundColor White
        $report | Where-Object { $_."$svc Licensed" } | Group-Object "$svc Status" | Sort-Object Count -Descending |
            Format-Table @{ n = 'Users'; e = { $_.Count } }, @{ n = 'Status'; e = { $_.Name } } -AutoSize | Out-Host
    }
    $disabled = @($report | Where-Object { $_.'Account Enabled' -eq $false }).Count
    if ($disabled) { Write-Warning "$disabled disabled account(s) still holding licences." }
    if (-not $hasAuditData) {
        Write-Warning 'Planner shows "Unknown" where there was no audit or sign-in evidence - see the licensing caveat in the script header.'
    }
    #endregion
}
finally {
    if ($concealFlip) {
        try { Set-ReportConcealment $true; Write-Host 'Report concealment restored.' -ForegroundColor Yellow }
        catch { Write-Warning "Could NOT restore report concealment - switch it back on in M365 admin centre > Settings > Org settings > Reports. ($($_.Exception.Message))" }
    }
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
}
