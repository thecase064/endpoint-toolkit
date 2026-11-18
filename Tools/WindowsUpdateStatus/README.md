# Windows Update status

Answers "why isn't this PC updating?" on one page, instead of clicking through Settings, the registry, three logs and Microsoft's release notes. Problems come first, each with what to do. Read-only.

| Area | Checks |
|---|---|
| Support | Windows version and edition against Microsoft's end-of-updates dates (Home / Pro, Enterprise / Education and LTSC each have their own). Windows 10 past its end date but still getting patches is flagged as probably ESU. |
| Updates | When the last Windows patch was installed, when Windows last checked for updates successfully, and **failed updates** from Windows Update's own history: grouped by KB, with the error code explained and a fix. An update that failed and then installed later is left out. Repeated "can't connect to the update service" events. |
| Restart | Updates installed and waiting for a restart |
| Policy | **Who manages updates:** Intune / MDM, Group Policy, WSUS, an RMM agent (Datto RMM, NinjaOne, N-able, Kaseya and others), or nothing. Automatic updates turned off or set to notify only, pauses (Intune, Group Policy or someone in Settings), deferrals, a **version pin** (and whether it pins an out-of-support version), and whether the **WSUS server answers**. |
| Services | Windows Update, Update Orchestrator, Update Medic, BITS, Windows Modules Installer, Cryptographic Services and Delivery Optimization not disabled. Disabling these is what "update blocker" tools do. |
| Disk | Free space for monthly updates (10 GB) and feature updates (20 GB) |
| Upgrade | **Windows' own readiness check** for the next version (Red / Orange / Yellow / Green), the hardware reason when it's Red (TPM, Secure Boot, CPU, RAM, disk), and **Microsoft safeguard holds**. Windows Setup's compatibility report: apps and drivers that block the upgrade. **SetupDiag's verdict** on the last failed upgrade. Setup files left on the drive. |
| Activity | Update and Setup processes running right now (TiWorker, MoUsoCoreWorker, SetupHost and others) |

It also lists the last dozen entries from Windows Update's history and, in the HTML report, every update policy value it found.

## Run

- Menu: **Diagnose > Windows Update status**
- Command: `Get-WindowsUpdateStatus -Html`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Get-WindowsUpdateStatus.ps1 -Html`

| Parameter | Effect |
|---|---|
| `-Html` | Also write `C:\Triage\Updates_<PC>_<time>.html` and open it |
| `-Watch` | After the report, watch update activity (see below) |
| `-WatchMinutes` | How long `-Watch` runs, default 30 |
| `-Days` | How far back to read update history and events, default 90 |
| `-SkipNetwork` | Don't test the WSUS server |
| `-ReportFolder` | Where `-Html` writes, default `C:\Triage` |
| `-NoOpen` | Don't open the HTML report |
| `-Quiet` | One summary line, for RMM monitors |
| `-PassThru` | Return the findings, version, recent updates and policies as objects |

Works unelevated. **Run it as admin to read Windows Setup's compatibility report**, which only admins can open.

## -Watch: stuck or just slow?

After the report it checks every 10 seconds and prints a line only when something moves:

```
   10:14:20  + TiWorker started
   10:14:30  busy: TiWorker +6.2 s CPU, MoUsoCoreWorker +0.8 s CPU
   10:15:40  update install started: 2026-11 Cumulative Update for Windows 11, version 25H2 ...
   10:31:10  Setup log +48 KB: 2026-11-18 10:31:09, Info MOUPG ...
   10:42:00  update installed: 2026-11 Cumulative Update ...
   10:42:00  ! a restart is now needed to finish
```

With nothing happening it says so once a minute. Ctrl+C stops it; the report is already saved. Remote-safe: plain lines, no screen redraws.

## Exit codes

`0` = no failures, `1` = at least one FAIL. With `-Quiet` that makes it an RMM monitor or an Intune remediation detection script.

## Good to know

- **End-of-updates dates** come from Microsoft's Windows release information, checked 18 Nov 2026. A newer build shows as INFO ("not in this tool's table") rather than a guess. When Microsoft publishes new dates, update `$EndOfUpdates` in the script.
- **"Last patch"** is the newest Windows patch (the same as Quick triage), not the newest Defender definition, which installs every day even on a PC that hasn't patched in months.
- **Readiness colours** are Windows' own compatibility check (the Compatibility Appraiser). It needs diagnostic data on and its scheduled task enabled; without them there's no verdict, and the tool says so.
- **A safeguard hold** means Microsoft is deliberately holding the upgrade back because of a known problem with something on the PC. Don't force it: update drivers, check the release health known issues, wait.
- **The only network use** is a TCP connection to a WSUS server named in the PC's own policy. Nothing is sent anywhere, and nothing is changed.
- When it finds a broken update setup, the fix is usually **Repair > Windows Update reset** or **Repair > Windows repair checks** (DISM + SFC); the findings say which.
