# Get-M365LicenseReport.ps1 — How To

### First-time module install

powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Groups, ImportExcel -Scope CurrentUser


Or just add `-InstallMissingModules` to the first run and let the script do it.

## What it does

Connects to Microsoft Graph, pulls every user in a tenant plus their licence assignments, and writes a formatted multi-sheet `.xlsx` report. Read-only — it never changes anything in the tenant.

Built for per-client tenant reporting: it takes a `-TenantId`, names the output file after the client, and disconnects from Graph at the end so a cached token isn't carried into the next tenant.

## Running it

**Standard client report:**

powershell
.\Get-M365LicenseReport.ps1 -TenantId contoso.onmicrosoft.com -ClientName "Contoso"


**Full licence audit with sign-in data (the useful one):**

powershell
.\Get-M365LicenseReport.ps1 -TenantId contoso.onmicrosoft.com -ClientName "Contoso" -IncludeLastSignIn -StaleDays 90


**Licensed users only, saved to a specific folder, no auto-open:**

powershell
.\Get-M365LicenseReport.ps1 -TenantId contoso.onmicrosoft.com -LicensedOnly -OutputFolder C:\Reports -NoOpen








**Output sheets:**

| Sheet | Contents |
|---|---|
| Report Info | Tenant, who ran it, when, record counts, which switches were used |
| License Summary | Per SKU: purchased / assigned / available / utilisation %, plus a purchased-vs-assigned chart |
| Users | One row per user, licences collapsed into a single column |
| License Detail | One row per user *per licence* — flat and pivot-friendly |
| License Pivot | Auto-generated pivot + bar chart, users per licence broken down by assignment type |
| Reclaim | Disabled accounts still holding licences, plus stale licensed accounts |
| Unlicensed | Enabled users with no licences |

Reclaim and Unlicensed are only created if there's something to put in them.

## Prerequisites

- PowerShell 5.1 or later
- Modules: `Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`, `Microsoft.Graph.Identity.DirectoryManagement`, `Microsoft.Graph.Groups`, `ImportExcel`
- An account in the target tenant with read access to users, groups and subscriptions
- Excel installed if you want the workbook to auto-open (otherwise use `-NoOpen`)



### Graph consent

First run against a new tenant prompts a Global Admin to consent to the **Microsoft Graph Command Line Tools** enterprise app. Scopes requested:

```
User.Read.All            users + licence assignment states
Organization.Read.All    subscribed SKUs / purchased quantities
Directory.Read.All       directory metadata
Group.Read.All           resolves group names for group-based licensing
AuditLog.Read.All        only added when -IncludeLastSignIn is used
```

All read-only.

## Running it

**Standard client report:**

powershell
.\Get-M365LicenseReport.ps1 -TenantId contoso.onmicrosoft.com -ClientName "Contoso"


**Full licence audit with sign-in data (the useful one):**

powershell
.\Get-M365LicenseReport.ps1 -TenantId contoso.onmicrosoft.com -ClientName "Contoso" -IncludeLastSignIn -StaleDays 90


**Licensed users only, saved to a specific folder, no auto-open:**

powershell
.\Get-M365LicenseReport.ps1 -TenantId contoso.onmicrosoft.com -LicensedOnly -OutputFolder C:\Reports -NoOpen


Omit `-TenantId` to be prompted for which tenant to sign into.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-TenantId` | prompt | GUID or domain. Use it when you hold accounts in several tenants |
| `-ClientName` | tenant display name | Used in the output filename only |
| `-OutputFolder` | `%USERPROFILE%\Documents\M365Reports` | Created if it doesn't exist |
| `-IncludeGuests` | off | B2B guests are excluded by default |
| `-LicensedOnly` | off | Drops unlicensed users from the report |
| `-IncludeLastSignIn` | off | Adds sign-in dates. Needs `AuditLog.Read.All` + Entra ID P1 |
| `-StaleDays` | 60 | Days without sign-in before a licensed account is flagged. Only applies with `-IncludeLastSignIn` |
| `-InstallMissingModules` | off | Installs missing modules for the current user instead of stopping |
| `-NoOpen` | off | Don't open the workbook when finished |

Output filename: `M365-License-Report_<ClientName>_<yyyyMMdd-HHmm>.xlsx`

## Reading the output

**License Summary** is where you start:
- **Available ≤ 0** highlighted red — SKU fully consumed, no spare licences
- **On Disabled Users > 0** highlighted amber — licences sitting on disabled accounts, i.e. immediate reclaim
- **Utilisation** column has data bars for a quick visual scan

**Reclaim** gives you the two categories worth chasing:
- `Account disabled but licensed` — always safe to question
- `Licensed, no sign-in in X+ days` / `Licensed, never signed in` — only populated with `-IncludeLastSignIn`

**License Detail** flags assignment errors in red. Anything in the *Assignment Error* column means the licence didn't apply cleanly — usually a missing usage location or a dependency conflict on a group-based assignment.

**Users** greys out disabled accounts so they're easy to skip when scanning.

## Gotchas

- **Sign-in data silently degrades.** If `-IncludeLastSignIn` fails (no P1, or the scope wasn't consented), the script warns, drops the switch, and re-runs the user query without it. You still get a report — just no Reclaim stale rows. Check the console output rather than assuming.
- **Summary "Assigned" is tenant-wide.** That figure comes from Graph's `ConsumedUnits`, so it counts every assignment including guests and shared mailboxes. If you ran without `-IncludeGuests` or with `-LicensedOnly`, the row count in License Detail won't match it. That's expected, not a bug.
- **Large tenants take a while.** Group-based licensing means one Graph lookup per unique group (cached after the first). Sign-in activity also slows the user query noticeably.
- **Unknown SKUs still work.** Anything not in the friendly-name table falls back to a tidied version of the SKU part number, so you never get a bare GUID — but the name may look odd. Add it to the `$skuFriendlyNames` hashtable near the top if you see it regularly.
- **Deprovisioned SKUs are skipped.** If a user holds a licence for a SKU the tenant is no longer subscribed to, that row is dropped.
- **Same-minute reruns overwrite.** Filename is precise to the minute, so a rerun within the same minute replaces the previous file.