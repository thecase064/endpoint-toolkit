# Performance check

"It's slow." This measures the PC for 30 seconds while the user does whatever is slow, then tells you **why**: problems first, worst first, each with what to do about it. Quick triage takes one snapshot; this watches for a while and goes looking for causes.

| Area | Checks |
|---|---|
| Hardware | Windows on a spinning hard drive or an SSD, free space, RAM size, one RAM stick in a two-slot machine (single-channel) |
| Load | CPU, system drive and memory **averaged over the sample**, plus paging and a missing page file |
| Power | On battery, power plan (Power saver?), power mode (Best power efficiency while plugged in?), maximum processor state, and whether the CPU **ran below its normal speed while busy**, which points at heat, a weak charger or power settings |
| Apps | What used the CPU, memory and disk during the sample, **grouped by app** (Chrome's 40 processes count as one), with advice for the usual suspects: Teams, WebView2, Defender scans, search indexing, OneDrive, Windows Update, browsers, Outlook, leftover McAfee, WMI, graphics and audio |
| Uptime | Days since boot, pending restarts |
| Stability | App hangs by app, and Windows' low-memory warnings, which name the apps that used the memory |
| Startup | How long recent start-ups took (to the sign-in screen and after), what Windows itself says slowed start-up (apps, drivers, services), and every startup app, on or off |
| Drivers | BIOS age, and a missing or old graphics driver |

It ends with a one-line summary you can paste into the ticket, e.g.:

```
PC-1234 performance check - 2 fail, 4 warn: System drive, CPU speed, Power plan, Browser, Uptime (+1 more)
```

## Run

- Menu: **Diagnose > Performance check (slow PC)**
- Command: `Invoke-PerformanceCheck -Html`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Invoke-PerformanceCheck.ps1 -Html`

| Parameter | Effect |
|---|---|
| `-Html` | One-page HTML report in `C:\Triage\`, next to the Quick triage reports, with the full startup app list. Opened when run locally. |
| `-Seconds` | How long to measure, 10-300, default 30. Use a longer sample for slowness that comes and goes. |
| `-Days` | Look-back for hangs, low-memory warnings and slow start-up events, default 7 |
| `-Fix` | After the report, offer the fixes below, asking before each one |
| `-Quiet` | Only the summary line, for RMM monitors |
| `-PassThru` | Return the findings, measurements, top apps, startup apps and changes as objects |

Works unelevated. **Run it as admin** to see start-up times (Windows only lets admins read that log) and to change startup apps for all users.

## -Fix: only things you can undo

Read-only unless you add `-Fix` (or say yes in the menu). Even then, nothing changes without a `y`:

| Offered when | Change | Undo |
|---|---|---|
| The plan is Power saver (and not set by policy) | Power plan to Balanced (`powercfg /setactive SCHEME_BALANCED`) | The exact `powercfg` command is printed |
| Maximum processor state is below 100% when plugged in | Back to 100% | The exact `powercfg` command, with the old value, is printed |
| Startup apps you pick by number | Turned off the same way Task Manager does it (its `StartupApproved` flag; the app itself isn't touched) | Task Manager > Startup apps > Enable |

It **never offers** to turn off security tools, remote support / RMM agents, VPN clients, audio, touchpad and hotkey helpers, or OneDrive. Store apps (new Teams, Phone Link) are listed but changed in Settings > Apps > Startup. It never deletes anything and **never restarts**. Every change, and how to undo it, is listed at the end and in the HTML report.

**Elevated as a different account?** Startup apps are per user, so it reads and changes the apps of the person **signed in at the PC**, not the admin account running it. Without admin rights it can only see the account it runs as, and says so.

In a remote session or an RMM shell, nobody can answer, so `-Fix` changes nothing.

## How it measures

- System counters every 2 seconds from Windows' performance classes (CIM, not `Get-Counter`, whose counter names are translated on non-English Windows).
- Per-app CPU and disk from the raw process counters at the start and end of the sample, so the averages are exact rather than a lucky moment.
- CPU speed is only judged while the CPU is busy. An idle CPU slows down on purpose.
- Start-up times come from the `Diagnostics-Performance` event log (event 100, and 101-103 for what slowed it).

It calls the toolkit's [device inventory](../DeviceInventory), so it needs that folder alongside it.

Exit codes: `0` = nothing failed, `1` = at least one FAIL.
