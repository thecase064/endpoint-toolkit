# Exchange + Planner usage report

Per-user answer to "have we licensed people for Exchange or Planner who don't actually use it?". One row per licensed user, with flagged users at the top: licensed but unused, disabled but still licensed, or a paid Planner/Project licence with no use seen.

| Source | What it shows | Needs |
|---|---|---|
| Graph email activity report | Emails sent, read and received; Active / Reading only / Unused | Any licence |
| Unified audit log | Planner / Project edits vs views | Audit (Premium) + paid Planner/Project Plan 1 (see below) |
| Entra sign-in logs | Sign-ins to Planner / Project apps, last 30 days | Entra ID P1 |
| signInActivity | Last successful sign-in to anything | Entra ID P1 |

Output: CSV in `Documents\M365Reports\`, plus `.xlsx` if ImportExcel is installed.

## Run

```powershell
Install-Module Microsoft.Graph.Authentication, ExchangeOnlineManagement -Scope CurrentUser
```

- Menu: **Report > Exchange + Planner usage report**
- Command: `Get-ExchangePlannerUsage -TenantId customer.onmicrosoft.com` (add `-UseGDAP` for partner access)

| Parameter | Effect |
|---|---|
| `-TenantId` | Customer tenant domain. Strongly recommended |
| `-UseGDAP` | Connect to Exchange Online with delegated (partner) access |
| `-Days` | Look-back window, default 90 |
| `-SkipSignInLogs` | Skip the Planner sign-in scan (slow on big tenants) |
| `-TempUnconcealReports` | Un-hide report names for the run without asking, then restore |
| `-OutputFolder` | Where the files go |
| `-SkipNameDownload` | Don't download Microsoft's product-name list; use the saved copy, or show SKU part numbers |

**Roles:** Global Reader plus View-Only Audit Logs. Un-hiding report names needs Global Admin.

## Gotchas

- **Licences are shown by product name** ("Microsoft 365 Business Premium"), from Microsoft's own list: the CSV behind "Product names and service plan identifiers for licensing", downloaded from download.microsoft.com (no sign-in) at most once a week and saved to `%LOCALAPPDATA%\EndpointToolkit\LicenseNames.csv` (shared with the M365 licence report). The **Licence SKUs** column keeps the part numbers (`SPB`) for filtering. If the list can't be had, the Licences column falls back to the part numbers.

- **Planner auditing costs extra.** Microsoft only logs Planner activity with Audit (Premium) *and* a paid Project/Planner Plan 1 or higher. On Business Premium or E3 the audit search comes back empty, and the report says "Unknown - no audit data" rather than accusing everyone of never opening Planner.
- **Concealed names.** Most tenants hide names in usage reports. The script asks before un-hiding them, and switches hiding back on straight after the Exchange pull (or in cleanup if it fails partway).
- **Wrong-tenant guard.** It asks "is this the right tenant?" before doing anything, and disconnects at the end so the next customer doesn't inherit the session.
