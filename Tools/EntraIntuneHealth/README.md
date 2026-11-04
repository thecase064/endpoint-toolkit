# Entra / Intune health check

Answers "is this device actually healthy in Entra and Intune?" without digging through `dsregcmd`, the registry, the certificate store and three event logs. Every check comes back **PASS**, **WARN**, **FAIL** or **INFO**, with a fix hint for anything that isn't a pass.

| Area | Checks |
|---|---|
| Join | Entra / hybrid / domain / registered state, device authentication, TPM-protected key, device certificate expiry, Primary Refresh Token (SSO), and any join error codes `dsregcmd` reports, with plain-English meanings for the common ones |
| Enrolment | MDM enrolment and UPN, Intune MDM certificate expiry, last successful check-in (and any later failure), EnterpriseMgmt sync tasks, the push-notification service (`dmwappushservice`, which debloat scripts love to disable) |
| Agent | Intune Management Extension: installed, running, version, last log activity |
| Events | Errors in the MDM and AAD event logs over the last 7 days, top IDs first |
| Network | HTTPS reachability of `login.microsoftonline.com`, `enterpriseregistration.windows.net`, `enrollment.manage.microsoft.com` |

## Run

- Menu: **Diagnose > Entra / Intune health check**
- Command: `Get-EntraIntuneHealth`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Get-EntraIntuneHealth.ps1`

| Parameter | Effect |
|---|---|
| `-Sync` | After the checks, trigger an MDM check-in (PushLaunch task) and restart the IME so it checks in too. Admin. |
| `-CollectLogs` | Zip `dsregcmd` output, the results, IME logs, MDM/AAD event logs and `MdmDiagnosticsTool` output to `C:\EntraIntuneHealth\`. Admin. |
| `-EventDays` | Event log look-back, default 7 |
| `-SkipNetwork` | Skip the endpoint checks |
| `-Quiet` | One summary line, for remediations and RMM monitors |
| `-PassThru` | Return the results as objects |

## Exit codes

`0` = no failures, `1` = at least one FAIL. That makes it a ready-made Intune remediation **detection** script (`-Quiet`), or an RMM monitor.

## Gotchas

- **The PRT check is for whoever runs it.** Elevating as a separate admin account checks the admin's token. For SSO problems, run it unelevated as the user.
- **Read-only unless you ask.** Nothing changes without `-Sync` or `-CollectLogs`.
- A few event log errors are normal noise. Look for the same ID repeating, and compare the times with the last check-in.
