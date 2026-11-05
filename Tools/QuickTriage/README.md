# Quick triage

The first five minutes of any ticket, in one go. It runs the checks you'd otherwise do by hand, then shows **what needs attention first** (worst first, each with a next step), followed by everything that checked out fine.

| Area | Checks |
|---|---|
| Device | Make, model, serial, OS version and build, logged-on user |
| Uptime | Days since boot, and whether Fast Startup means "Shut down" isn't resetting it |
| Reboot | Pending from Windows Update, servicing, file renames or a computer rename |
| Disk | System drive free space, physical disk health and wear |
| Battery | Wear (elevated) |
| Entra / Intune | The full [health check](../EntraIntuneHealth): join, SSO token, enrolment, check-in, certificates, endpoints |
| Stability | Blue screens (with the bugcheck code), unexpected shutdowns, app crashes by app |
| Updates | Days since the last update was installed |
| Security | Antivirus registered with Security Center, Defender real-time and signature age |
| Resources | Memory in use, CPU load, top processes by memory |
| Network | Default gateway and DNS |

It ends with a one-line summary you can paste into the ticket, e.g.:

```
PC-1234 quick triage - 2 fail, 3 warn: Free space, Blue screens, Pending reboot, Uptime, App crashes
```

## Run

- Menu: **Diagnose > Quick triage**
- Command: `Invoke-QuickTriage -Html`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Invoke-QuickTriage.ps1 -Html`

| Parameter | Effect |
|---|---|
| `-Html` | One-page HTML report in `C:\Triage\`, opened when run locally |
| `-Days` | Look-back for crashes and shutdowns, default 7 |
| `-SkipNetwork` | Skip the gateway, DNS and endpoint checks |
| `-Reports` | Also save Windows' own **Wi-Fi report** (connections, drops and errors over the last few days) and **battery report** (capacity history, charge cycles) to `C:\Triage\`, linked from the HTML page. Battery is skipped on desktops; the Wi-Fi report needs an elevated session and a Wi-Fi adapter, and says so if either is missing. |
| `-Quiet` | Only the summary line, for RMM monitors |
| `-PassThru` | Return the findings and device details as objects |

Read-only, and fine unelevated. Takes 10-30 seconds. It calls the toolkit's [device inventory](../DeviceInventory) and [Entra/Intune health check](../EntraIntuneHealth), so it needs those folders alongside it.

Exit codes: `0` = nothing failed, `1` = at least one FAIL.
