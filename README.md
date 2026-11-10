# Endpoint Toolkit

[![CI](https://github.com/thecase064/endpoint-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/thecase064/endpoint-toolkit/actions/workflows/ci.yml)

A PowerShell toolkit for Windows endpoint work in an MSP: build a new laptop and bring its drivers and BIOS up to date, repair a broken one (Teams, OneDrive, printing, Office activation, Windows Update), check its Entra, Intune and BitLocker health, find out where the disk space went, cut through event log noise and report on M365 licensing and usage. You can run it from a window, from a console menu that works over remote shells, or as a module, all from a single line pasted into any machine. No USB stick, nothing to copy across.

```
┌ Endpoint Toolkit v1.10.0 ───────────────────  PC-1234 · PS 5.1   Not elevated   [Relaunch as admin]   _  []  X ┐
│ [ Search tools          ]   │  Print spooler clear   [Changes the machine] [Needs admin]                       │
│ Build                       │                                                                                  │
│   New device setup   admin  │  Clears stuck print jobs: stops the Print Spooler, deletes the queued jobs,      │
│   McAfee removal     admin  │  starts it again. Shows how many jobs are queued first. Printers, drivers and    │
│   ...                       │  settings aren't touched.                                                        │
│ Repair                      │                                                                                  │
│   Teams cache clear         │  Warning: Deletes every queued print job on this PC - people will need to        │
│ > Print spooler clear admin │  print again.                                                                    │
│   Office activation  admin  │                                                                                  │
│   ...                       │  Options                                                                         │
│ Diagnose                    │  None. It just runs.                                                             │
│   Quick triage              │                                                                                  │
│   ...                       │                                                                                  │
│                             │  Windows asks for admin rights (UAC), then it    [ Run as admin ]                │
│                             │  runs in its own PowerShell window.                                              │
├─────────────────────────────┴──────────────────────────────────────────────────────────────────────────────────┤
│ Runs from this window   11:02   Quick triage - finished, exit code 0 [OK]                                      │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Pick a tool (or search) to see what it does, whether it changes anything, any warning and its options. Nothing runs until you click **Run**. Every tool has its own icon (from Windows' built-in icon font), and a shield marks the ones that need admin. Each tool then opens in its own PowerShell window, with a UAC prompt first if it needs admin, so you can carry on in the toolkit while it works. The bottom panel shows how each run finished. The window follows Windows' light or dark mode; the sun / moon button in the title bar flips it for that session.

### Console menu (remote shells)

Over `Enter-PSSession`, an RMM remote shell or Server Core there's no desktop for a window, so the toolkit uses a console menu instead. It does this by itself, or you can ask for it with `console.ps1` (see Quick start). Same tools, same briefs, same options:

```
  ======================================================================
   ENDPOINT TOOLKIT v1.10.0                  thecase064/endpoint-toolkit
   Host: PC-1234   Elevated: YES   PS 5.1   Source: main (2026-11-04 12:00)
  ======================================================================

   BUILD
     1  New device setup (full build chain)           admin
     2  McAfee removal                                admin
     3  OEM debloat (HP / Dell)                       admin
     4  OEM drivers + BIOS (Dell / HP / Lenovo)       admin
     5  M365 Apps reset + reinstall                   admin
     6  Chrome + Adobe Reader install                 admin
     7  Intune primary user (change or remove)
     8  Driver export (before a wipe)                 admin
     9  Driver import (from an export)                admin

   REPAIR
    10  Windows repair checks (DISM + SFC)            admin
    11  Windows Update reset                          admin
    12  Teams cache clear (new + classic)
    13  Print spooler clear                           admin
    14  Office activation reset                       admin
    15  Teams Meeting add-in fix (classic Outlook)
    16  OneDrive reset (sync app)

   DIAGNOSE
    17  Quick triage (first five minutes)
    18  Performance check (slow PC)
    19  Before / after comparison
    20  Entra / Intune health check
    21  BitLocker key backup check                    admin
    22  Device inventory (hardware + OS)
    23  Disk usage report (HTML)
    24  Disk usage browser (GUI)                      window
    25  Event triage (GUI)                            window

   REPORT
    26  M365 licence report (Excel)
    27  Exchange + Planner usage report

     Q  Quit
```

Pick a number and nothing runs yet. You get a short brief first: what the tool does, what it changes, any warning, and how many questions follow. Then `Run it? [y/N]`. Only `y` runs it; anything else (Enter included) goes back to the menu.

In a remote session, each tool's output is piped back to your session as it runs. Nobody can answer a question halfway through a run there, so tools that would ask take the safe answer: the OEM updater lists updates without installing, for example.

```
  ----------------------------------------------------------------------
   Print spooler clear
  ----------------------------------------------------------------------
   Clears stuck print jobs: stops the Print Spooler, deletes the queued jobs, starts it again.
   Shows how many jobs are queued first. Printers, drivers and settings aren't touched.

   WARNING: Deletes every queued print job on this PC - people will need to print again.
   Runs as admin.

  Run it? [y/N]
```

## Quick start

On the machine itself, open PowerShell (as Administrator saves a UAC prompt per tool) and paste:

```powershell
irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1 | iex
```

In a remote shell (`Enter-PSSession`, RMM console), or any time you want the console menu:

```powershell
irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/console.ps1 | iex
```

Both download the toolkit to `C:\ProgramData\EndpointToolkit\` and unblock it. The first opens the window, and falls back to the console menu by itself where there's no desktop. The second always opens the console menu.

| Want to... | Run |
|---|---|
| Pin a release (recommended on client machines) | `& ([scriptblock]::Create((irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1))) -Ref v1.10.0` (add `-Console` for the console menu) |
| Install as a module for everyday use | `& ([scriptblock]::Create((irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1))) -Install` then `Import-Module EndpointToolkit; etk` (window) or `etkc` (console menu) |
| Double-click instead of pasting | Copy `Launch-Toolkit.cmd` anywhere (desktop, USB, file share) and right-click > **Run as administrator** |
| Run from a clone or a USB copy | `powershell -ExecutionPolicy Bypass -File .\Start-Toolkit.ps1` (add `-Console` for the console menu) |

## Tools

| | Tool | What it does | Command |
|---|---|---|---|
| **Build** | [New device setup](Tools/NewDeviceSetup) | The whole build in one pass, then reboots: Intune primary user (optional), McAfee removal, debloat, M365 reinstall, Chrome + Reader and Dell/HP/Lenovo drivers. Ends with an **HTML build report** for the ticket: each step's result and output, outstanding Windows and driver updates (BIOS included), device details and app versions. Cut a new-laptop build from over half a day to under two hours. | `Invoke-NewDeviceSetup` |
| | [McAfee removal](Tools/McAfeeRemoval) | Removes the Store, MSI and EXE forms of Dell's McAfee preload. Intune / RMM-friendly exit codes. | `Remove-McAfee` |
| | [OEM debloat](Tools/OEMDebloat) | Strips HP / Dell consumer bloat while keeping SupportAssist, HP Support Assistant and hotkey drivers. List-driven, with `-DryRun`. | `Invoke-BuildDebloat` |
| | [OEM driver + BIOS updates](Tools/OEMUpdates) | Dell, HP or Lenovo: scans with the vendor's own updater (Dell Command Update, HP Image Assistant, LSUClient), lists what's available, asks, installs. BIOS only when asked, with BitLocker suspended for the restart. Asks before installing a missing updater; never restarts by itself. | `Invoke-OEMUpdate` |
| | [M365 Apps reset](Tools/M365Reset) | ODT removal of every Office install (OEM stubs, language packs, MSI), then a clean M365 Apps install. `-DeepClean` adds Microsoft's Get Help Office scrub for broken installs. | `Reset-M365Apps` |
| | [Chrome + Reader](Tools/ChromeReader) | Chrome Enterprise MSI and the offline Reader installer, with Reader's cloud, AI and upsell features locked down by policy. | `Install-ChromeAndReader` |
| | [Intune primary user](Tools/IntunePrimaryUser) | Shows, changes or removes the PC's Intune primary user (Intune updates the Entra owner to match). Reads the tenant and Intune ID from the PC itself; you sign in as a tenant admin in Microsoft's window (MFA works). | `Set-IntunePrimaryUser` |
| | [Driver export / import](Tools/DriverExport) | Backs up every third-party driver before a wipe, with a manifest, machine details and a restore note. Optionally zipped. `-ImportFrom` puts them back. | `Export-DeviceDriver` |
| **Repair** | [Windows repair checks](Tools/WindowsRepair) | DISM RestoreHealth, SFC, DISM component cleanup, with progress and a clear finish. | `Invoke-WindowsRepairChecks` |
| | [Windows Update reset](Tools/WindowsUpdateReset) | Stops the update services, sets aside SoftwareDistribution and catroot2 (renamed, not deleted), restarts and rescans. Flags the usual real causes first: pending reboot, dead WSUS, low disk. | `Reset-WindowsUpdate` |
| | [Teams cache clear](Tools/TeamsCache) | Closes Teams, empties the cache folder Microsoft documents (new Teams, and classic if it's still there) and starts it again. Settings survive. Runs as the user and refuses to clear the wrong person's cache. | `Clear-TeamsCache` |
| | [Print spooler clear](Tools/PrintSpooler) | Stops the spooler (ending it if it's wedged), deletes stuck jobs (`.SPL`/`.SHD` files only) and starts it again with its dependants. | `Clear-PrintSpooler` |
| | [Office activation reset](Tools/OfficeActivation) | Microsoft's Get Help `ResetOfficeActivation`: clears Office licences and cached sign-ins so the user can activate fresh. Downloaded each run and checked for Microsoft's signature. | `Reset-OfficeActivation` |
| | [Teams Meeting add-in fix](Tools/TeamsAddin) | The missing Teams Meeting button in classic Outlook: checks the add-in is installed and registered, fixes LoadBehavior and Outlook's disabled and do-not-disable lists, and gives Microsoft's reinstall steps for the rest. | `Repair-TeamsMeetingAddin` |
| | [OneDrive reset](Tools/OneDriveReset) | Microsoft's `OneDrive.exe /reset` without hunting for the exe: finds the copy that's running or registered (per-user or Program Files), lists the accounts and synced libraries first, resets, then makes sure OneDrive starts again. No files are deleted. Runs as the user and refuses to run as admin, which OneDrive won't start under. `-CheckOnly` changes nothing. | `Reset-OneDrive` |
| **Diagnose** | [Quick triage](Tools/QuickTriage) | The first five minutes of any ticket on one page: device, uptime, pending reboot, disk space and health, crashes, updates, antivirus, Entra/Intune, memory and network. Problems first, each with a next step, plus a one-line summary for the ticket. `-Reports` adds Windows' own Wi-Fi and battery reports. | `Invoke-QuickTriage` |
| | [Performance check](Tools/PerformanceCheck) | "Why is it slow?" Measures CPU, disk and memory for 30 seconds while the user does what's slow, names the apps responsible (grouped, with advice for Teams, Defender scans, indexing, OneDrive, browsers and more), and checks power plan and mode, CPU held below its normal speed, startup apps, start-up time, hangs, low-memory warnings, SSD or hard drive, RAM size and sticks, BIOS and graphics driver age. Read-only; `-Fix` offers only undoable fixes (power plan, maximum processor state, startup apps the Task Manager way), one question at a time, and never touches security, remote support, VPN or driver helpers. | `Invoke-PerformanceCheck` |
| | [Before / after comparison](Tools/ReportCompare) | The write-up for the ticket once the work's done. Reads every Quick triage, Performance check, Wi-Fi and battery report already saved for the PC and puts them side by side: what got fixed, better, worse or is new, the numbers for every run (CPU, disk, memory, paging, start-up times, free space, build, drivers, last update, shutdowns), what's still to do with each fix, and notes that only show across the reports, like a first run caught mid-update, no battery plus unexpected shutdowns, or updates nothing manages. Works on reports made before it existed. Read-only, and nothing is sent anywhere. | `Compare-DeviceReport` |
| | [Entra / Intune health check](Tools/EntraIntuneHealth) | Join state, device auth, PRT, MDM enrolment, Intune certificate expiry, last check-in, push service, IME, event log errors and endpoint reachability, each with a fix hint. Can force a sync or zip the logs for escalation. Exit code 1 on failure, so it doubles as a remediation detection script. | `Get-EntraIntuneHealth` |
| | [BitLocker key backup check](Tools/BitLockerBackup) | Is every recovery key backed up to Entra? Checks each key against the BitLocker event log (845/846, with the error explained); `-Fix` backs up the missing ones. Never shows the keys themselves. | `Test-BitLockerKeyBackup` |
| | [Device inventory](Tools/DeviceInventory) | Model, serial, BIOS, OS build, every RAM stick, disks with health and wear, monitors with serials, battery wear, network, TPM and Secure Boot. Console, HTML or JSON. | `Get-DeviceInventory` |
| | [Disk usage report](Tools/DiskUsage) | TreeSize-style scan with no install or licence: biggest folders by their own content, biggest files, known cleanup targets flagged safe/caution, self-contained HTML report. Works over `Invoke-Command`. | `Get-DiskUsageReport` |
| | [Disk usage browser](Tools/DiskUsage) | Live WPF folder-size browser. Read-only. | `Show-DiskUsageGui` |
| | [Event triage](Tools/EventTriage) | WPF front end that groups event logs by provider + ID, mutes known noise, pulls context around an event and builds a redacted AI troubleshooting prompt. Local or remote. | `Start-EventTriage` |
| **Report** | [M365 licence report](Tools/M365LicenseReport) | Multi-tenant Microsoft Graph report to Excel: users, licence detail, SKU summary, pivot, reclaim candidates, unlicensed users. | `Get-M365LicenseReport` |
| | [Exchange + Planner usage](Tools/ExchangePlannerUsage) | Who's licensed for Exchange or Planner but not using them: mail activity, Planner audit events and app sign-ins per user. Handles concealed report names and GDAP. | `Get-ExchangePlannerUsage` |

Each folder has the tool's own guide.

## Using it as a module

Every tool is also a command with the script's own parameters, tab completion and `Get-Help`:

```powershell
Import-Module EndpointToolkit

etk                     # the window (Show-EndpointToolkitGui)
etkc                    # the console menu (Show-EndpointToolkit)

Invoke-QuickTriage -Html
Compare-DeviceReport -Ticket 123456
Get-EntraIntuneHealth -Sync
Get-DeviceInventory -Html
Get-DiskUsageReport -Path D:\ -TopFolders 50 -PassThru
Get-M365LicenseReport -TenantId contoso.onmicrosoft.com -ClientName 'Contoso' -IncludeLastSignIn
Export-DeviceDriver -Destination E:\Drivers -Zip
Invoke-NewDeviceSetup -SkipReboot

Get-ToolkitTool | Format-Table Id, Name, Admin, Mode
Get-Help Get-DiskUsageReport -Full
```

## How it works

```
install.ps1 ──> downloads repo zip @ ref ──> C:\ProgramData\EndpointToolkit\<ref>-<time>\
(console.ps1 = install.ps1 -Console)          │
                                              ├─ EndpointToolkit.psm1  reads tools.json, builds the console menu and commands
                                              ├─ Gui\                  the window: layout (XAML), code, and the per-run launcher
                                              ├─ tools.json            one entry per tool: path, brief, admin, mode, prompts
                                              └─ Tools\<Tool>\*.ps1    the scripts, unchanged by the toolkit
```

The window and the console menu share everything: the same `tools.json`, briefs, options and run code. When you click **Run** in the window, it starts `Gui\Invoke-ToolWindow.ps1` in a new PowerShell window (elevated with UAC when the tool needs admin), and that runs the tool exactly as the console menu would.

Each tool runs in one of three modes (set per tool in `tools.json`):

- **child** runs in a separate `powershell.exe` in the same console. State stays isolated and you get real exit codes. Used for the build and repair tools.
- **process** runs in your session, so `-PassThru` objects come back to the pipeline (disk usage report).
- **window** is for the GUI tools. Each launches in its own process and the menu carries on.

### Adding a tool

1. Drop the script in `Tools\<Folder>\`. Anything several tools share goes in `Tools\Shared\Helpers.ps1`.
2. Add an entry to `tools.json`:

```json
{
  "id": "wifi-profiles",
  "name": "Wi-Fi profile export",
  "category": "Build",
  "path": "Tools/WifiProfiles/Export-WifiProfile.ps1",
  "command": "Export-WifiProfile",
  "description": "Exports the saved Wi-Fi networks before a rebuild.",
  "brief": [
    "Saves every Wi-Fi network this machine knows to a folder, ready for the new build.",
    "Read-only: nothing on this machine changes."
  ],
  "admin": true,
  "mode": "child",
  "confirm": "Optional: shown before it runs, for anything destructive.",
  "prompts": [
    { "param": "IncludeKeys", "type": "switch", "prompt": "Include the Wi-Fi passwords?", "default": false }
  ]
}
```

3. Add the command to `FunctionsToExport` in `EndpointToolkit.psd1`, then run the tests. They'll fail if a prompt names a parameter the script doesn't have, or if the tool has no `brief`.

`description` is the one-liner for `Get-ToolkitTool`. `brief` is what the menu shows before asking `Run it?`: 1 to 5 plain-English lines of up to 96 characters. Say what it does, what it changes (or that it's read-only) and anything the tech should know first. `confirm` is shown in the brief as a yellow warning.

Prompt types: `switch` (y/n), `string` (blank = skip), `choice` (numbered options).

## Security notes

- `irm | iex` runs whatever is on `main` at that moment. On client machines, pin a tag with `-Ref` so a later push can't change what runs.
- Nothing in this repo is tenant- or client-specific: no IDs, credentials or names. Every run asks for what it needs. CI runs a secret scan (gitleaks) on every push.
- Execution policy is only relaxed for the current process. If Group Policy enforces `AllSigned`, the launcher can't run until the scripts are signed.
- The launchers use plain `-File` / `-Command`, never `-EncodedCommand`, so they don't look like malware to EDR.
- **Runs from the window.** The options you pick go to the new PowerShell window in a temp file, with the file's SHA-256 on the command line. The run refuses a file that doesn't match, so nothing can swap the options between you clicking Run and the tool starting elevated. The file is deleted as soon as it's read. Admin tools get their own UAC prompt per run; the window itself doesn't need to be elevated.
- **What gets downloaded at run time.** Nothing third-party is bundled in this repo. Some tools fetch software from the vendor when they run:

  | Tool | Downloads | Check before it runs |
  |---|---|---|
  | M365 Apps reset | Office Deployment Tool, from Microsoft's Office CDN | Must be validly signed by Microsoft, or it aborts |
  | M365 Apps reset `-DeepClean`, Office activation reset | Microsoft Get Help command line (`aka.ms/SaRA_EnterpriseVersionFiles`) | Must be validly signed by Microsoft, or it won't run. Deleted afterwards |
  | OEM drivers + BIOS | Dell Command Update / HP Image Assistant via **winget**, or the LSUClient module (MIT) from the **PowerShell Gallery** for Lenovo | **Asks first.** Only `-InstallTool` installs without asking; New device setup uses it, since a build runs unattended. The vendor tools then fetch updates from Dell, HP or Lenovo |
  | Intune primary user (and New device setup when setting one) | Microsoft's `Microsoft.Graph.Authentication` module from the **PowerShell Gallery**, if it isn't installed | Every DLL must be validly signed, and the module's own by Microsoft, or it's deleted and not loaded. Cached in `ProgramData\EndpointToolkit\_modules`; New device setup deletes it at the end |
  | Chrome + Adobe Reader | Installers straight from Google's and Adobe's download servers (HTTPS) | Must be validly signed by Google LLC / Adobe Inc., or it's deleted and not installed |
  | M365 licence report | Microsoft Graph and ImportExcel modules from the PowerShell Gallery | Only with `-InstallMissingModules` |

## Building an .exe (optional)

```powershell
.\build\Build-Exe.ps1 -RequireAdmin          # -> dist\EndpointToolkit.exe
```

The exe is a small stub that runs the one-line launcher, so it never goes stale. Unsigned PS2EXE binaries are a well-known AV false-positive magnet, so sign it (`-CertificateThumbprint`) or stick with `Launch-Toolkit.cmd`.

## Releasing

Bump the version, add a `## x.y.z - date` section to `CHANGELOG.md`, push `main`, wait for CI to go green, then tag and publish:

```powershell
git tag -a v1.11.0 -m "v1.11.0: What it adds"; git push origin v1.11.0
.\build\Publish-Releases.ps1 -WhatIf    # what it would publish
.\build\Publish-Releases.ps1
```

`Publish-Releases.ps1` creates a GitHub release for every version tag that hasn't got one, with that version's CHANGELOG section as the notes, and marks the newest Latest. It skips tags already released, so it's safe to run again, and never creates or moves a tag. It needs the GitHub CLI (`winget install GitHub.cli`, then `gh auth login`).

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-Repo.ps1
```

The tests check that every script parses, that `tools.json` matches the scripts' real parameters and the module exports match the manifest, that every tool has a brief, that values with spaces and switches reach a child process intact, and that the menu works end to end with scripted input (including that saying no to `Run it?` runs nothing). For the window, they check that the layout and the code agree on every control and colour, that untouched options give exactly what pressing Enter at every console prompt gives (all tools), that a changed options file is refused, and that tool output reaches a remote session. On Windows (CI) they also build the window and click through it in code without showing it. They finish with a leak scan. Add your own private patterns (employer or client names) to `tests\leak-patterns.local.txt`. That file is git-ignored, so it's checked but never committed. CI runs the same tests on Windows PowerShell 5.1 and PowerShell 7, plus PSScriptAnalyzer (pinned to 1.25.0 and run one file at a time; its known intermittent crash is retried once, then shown as a warning naming the file). Any Error-severity finding fails the build.

## Licence

[MIT](LICENSE)
