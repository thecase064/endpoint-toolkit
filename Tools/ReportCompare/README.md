# Before / after comparison

The write-up for the ticket once the work's done. It reads the Quick triage, Performance check, Wi-Fi and battery reports already saved for the PC and puts them side by side on one page: what got fixed, what got worse, the numbers for every run, what's still to do, and the things you only spot when you read the reports together.

It ends with a one-line summary you can paste into the ticket, e.g.:

```
PC-1234 report - performance 1 fail 9 warn -> 0 fail 4 warn; fixed: CPU, Disk, Pending restart, Start-up time, Graphics driver (+1 more); still: Memory size, Memory sticks, Slowing start-up, BIOS age
```

## How to use it

1. **Before you start:** Quick triage with the HTML report and `-Reports` (in an admin session for the Wi-Fi report), and Performance check with `-Html`, ideally while the user does what's slow.
2. Do the work.
3. **After:** run the same checks again. Restart first if the work needs one.
4. Run **Diagnose > Before / after comparison**. It opens the report (**PC-1234 report**) when it's done.

It finds the reports by their names in `C:\Triage` (`Triage_<PC>_<time>.html`, `Performance_<PC>_<time>.html`, `WiFi_...`, `Battery_...`), so it works on reports made before this tool existed, and on copies with something added to the front of the name (a ticket attachment, say).

## What's on the page

| Section | What it shows |
|---|---|
| What changed | Fails and warnings from the first run to the latest, Windows build changes and restarts in between. Then each check that was **fixed**, is **no longer reported**, got **better** (FAIL to WARN), got **worse**, is **new**, or is **unchanged**, with the first and latest detail side by side |
| The numbers | Performance check: CPU, disk, free memory, commit, paging, start-up times (total, to the sign-in screen, after sign-in), free space, pending restart, last boot, busiest app, startup apps on, graphics driver, BIOS. Quick triage: last update, unexpected shutdowns, blue screens, app crashes, memory, CPU, free space, pending reboot, join type, Intune. One column per run (the first and the latest five if there are more), and whether it got better or worse |
| Worth knowing | Notes that only show across the reports, most important first (see below) |
| Still needs attention | Everything still WARN or FAIL in the latest Performance check and Quick triage, FAILs first, each with its fix. A Quick triage item that a newer Performance check found fine (a pending restart, say) is left out |
| Wi-Fi | From Windows' own Wi-Fi report: sessions and drops, disconnect reasons, failed connections, the network and signal, the adapter's driver age, how long the adapter took to come up after start-up, DNS servers, saved networks. Says so when Location services was off and Windows left the network details out |
| Battery | Capacity against design and charge cycles, from Windows' battery report, or why there isn't one |
| Every check, run by run | The full grid of every check's status in every run (collapsed; expanded when printed) |
| Reports used | Links to each report it read |

### Worth knowing: the cross-report notes

| Note | When it appears |
|---|---|
| No battery and unexpected shutdowns | Quick triage found unexpected shutdowns and Windows reports no battery: on a laptop, any knock of the charger switches it off |
| Who patches it? | Updates are months behind and the PC isn't in Intune. Names the RMM agent if one is in the startup apps (Datto RMM, NinjaOne, N-able and others), so you know where to look |
| Run Quick triage again | The latest Quick triage is older than the work, or its last-update warning came before Windows moved to a new build |
| The first check ran mid-update | The first Performance check caught Windows installing updates (TiWorker), so its load wasn't a lasting fault |
| Busy just after start-up | A run under load was taken within an hour of start-up |
| Not like for like | The first run was under load and the latest nearly idle |
| Sign-in got slower | Power-on to the sign-in screen improved but sign-in to settled got worse |
| New startup apps | Apps that start at sign-in now but didn't at the first check, with a note on Edge's Startup boost |
| Classic Teams still starts | The retired classic Teams or its machine-wide installer still starts at sign-in |
| Start-up slowed by updates | "Slowing start-up" names Windows Modules Installer or Defender after a build change: they age out on their own |
| Space used by updates | Free space dropped by 2 GB or more across a build change, with where to get some back |
| LMS.exe crashing | Intel's management engine software crashing: comes with the BIOS and chipset updates |

## Run

- Menu: **Diagnose > Before / after comparison**
- Command: `Compare-DeviceReport -Ticket 123456`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Compare-DeviceReport.ps1`

| Parameter | Effect |
|---|---|
| `-Ticket` | Ticket number, shown on the page |
| `-ReportFolder` | Where the reports are, and where the comparison goes. Default `C:\Triage` |
| `-ComputerName` | Whose reports to compare, default this PC. For reports copied from another machine |
| `-Days` | Only reports from the last N days, default 30 |
| `-Path` | Compare these files instead of searching the folder (wildcards work). The PC name comes from the files |
| `-Quiet` | Only the summary line |
| `-PassThru` | Return the runs, what moved, the numbers, the notes and what's left as objects |

Read-only and needs no admin. It writes `Report_<PC>_<time>.html` next to the reports, headed with the PC's name (e.g. **PC-1234 report**). Exit code 0 when the comparison is written, 1 when there were no reports to read.

## Good to know

- **Nothing leaves the PC.** The write-up comes from rules in the script, not an online service, so client data stays where it is.
- It reads the toolkit's own HTML reports, so if a check's wording changes in a later version, the matching number here needs updating too.
- Windows' battery report is read loosely (design capacity, full charge capacity, cycle count). If Windows changes its layout, the battery section says it couldn't read the figures rather than guessing.
- A single run of each check still gives a page (the latest state and the notes), but "what changed" needs at least two runs of the same check.
