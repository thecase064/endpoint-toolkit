# Endpoint Toolkit

[![CI](https://github.com/thecase064/endpoint-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/thecase064/endpoint-toolkit/actions/workflows/ci.yml)

A PowerShell toolkit for Windows endpoint work in an MSP: build a new laptop, repair a broken one (Teams, printing, Office activation, Windows Update), check its Entra, Intune and BitLocker health, find out where the disk space went, cut through event log noise and report on M365 licensing and usage. You can run it from a menu, as a module, or with a single line pasted into any machine. No USB stick, nothing to copy across.

```
  ======================================================================
   ENDPOINT TOOLKIT v1.3.0                   thecase064/endpoint-toolkit
   Host: PC-1234   Elevated: YES   PS 5.1   Source: main (2026-11-04 12:00)
  ======================================================================

   BUILD
     1  New device setup (full build chain)           admin
     2  McAfee removal                                admin
     3  OEM debloat (HP / Dell)                       admin
     4  M365 Apps reset + reinstall                   admin
     5  Chrome + Adobe Reader install                 admin
     6  Hostname desktop shortcut
     7  Driver export (before a wipe)                 admin
     8  Driver import (from an export)                admin

   REPAIR
     9  Windows repair checks (DISM + SFC)            admin
    10  Windows Update reset                          admin
    11  Teams cache clear (new + classic)
    12  Print spooler clear                           admin
    13  Office activation reset                       admin
    14  Teams Meeting add-in fix (classic Outlook)

   DIAGNOSE
    15  Quick triage (first five minutes)
    16  Entra / Intune health check
    17  BitLocker key backup check                    admin
    18  Device inventory (hardware + OS)
    19  Disk usage report (HTML)
    20  Disk usage browser (GUI)                      window
    21  Event triage (GUI)                            window

   REPORT
    22  M365 licence report (Excel)
    23  Exchange + Planner usage report

     Q  Quit
```

## Quick start

Open PowerShell **as Administrator** on the machine and paste:

```powershell
irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1 | iex
```

That downloads the toolkit to `C:\ProgramData\EndpointToolkit\`, unblocks it and opens the menu. If you're not elevated, the menu offers to relaunch itself as admin when a tool needs it.

| Want to... | Run |
|---|---|
| Pin a release (recommended on client machines) | `& ([scriptblock]::Create((irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1))) -Ref v1.3.0` |
| Install as a module for everyday use | `& ([scriptblock]::Create((irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1))) -Install` then `Import-Module EndpointToolkit; etk` |
| Double-click instead of pasting | Copy `Launch-Toolkit.cmd` anywhere (desktop, USB, file share) and right-click > **Run as administrator** |
| Run from a clone or a USB copy | `powershell -ExecutionPolicy Bypass -File .\Start-Toolkit.ps1` |

## Tools

| | Tool | What it does | Command |
|---|---|---|---|
| **Build** | [New device setup](Tools/NewDeviceSetup) | Chains McAfee removal, debloat, M365 reinstall, Chrome + Reader and a hostname shortcut in one unattended pass, then reboots. Cut a new-laptop build from over half a day to under two hours. | `Invoke-NewDeviceSetup` |
| | [McAfee removal](Tools/McAfeeRemoval) | Removes the Store, MSI and EXE forms of Dell's McAfee preload. Intune / RMM-friendly exit codes. | `Remove-McAfee` |
| | [OEM debloat](Tools/OEMDebloat) | Strips HP / Dell consumer bloat while keeping SupportAssist, HP Support Assistant and hotkey drivers. List-driven, with `-DryRun`. | `Invoke-BuildDebloat` |
| | [M365 Apps reset](Tools/M365Reset) | ODT removal of every Office install (OEM stubs, language packs, MSI), then a clean M365 Apps install. `-DeepClean` adds Microsoft's Get Help Office scrub for broken installs. | `Reset-M365Apps` |
| | [Chrome + Reader](Tools/ChromeReader) | Chrome Enterprise MSI and the offline Reader installer, with Reader's cloud, AI and upsell features locked down by policy. | `Install-ChromeAndReader` |
| | [Hostname shortcut](Tools/HostnameShortcut) | Desktop shortcut that shows the computer name, for the "what's my PC called?" call. | `New-HostnameShortcut` |
| | [Driver export / import](Tools/DriverExport) | Backs up every third-party driver before a wipe, with a manifest, machine details and a restore note. Optionally zipped. `-ImportFrom` puts them back. | `Export-DeviceDriver` |
| **Repair** | [Windows repair checks](Tools/WindowsRepair) | DISM RestoreHealth, SFC, DISM component cleanup, with progress and a clear finish. | `Invoke-WindowsRepairChecks` |
| | [Windows Update reset](Tools/WindowsUpdateReset) | Stops the update services, sets aside SoftwareDistribution and catroot2 (renamed, not deleted), restarts and rescans. Flags the usual real causes first: pending reboot, dead WSUS, low disk. | `Reset-WindowsUpdate` |
| | [Teams cache clear](Tools/TeamsCache) | Closes Teams, empties the cache folder Microsoft documents (new Teams, and classic if it's still there) and starts it again. Settings survive. Runs as the user and refuses to clear the wrong person's cache. | `Clear-TeamsCache` |
| | [Print spooler clear](Tools/PrintSpooler) | Stops the spooler (ending it if it's wedged), deletes stuck jobs (`.SPL`/`.SHD` files only) and starts it again with its dependants. | `Clear-PrintSpooler` |
| | [Office activation reset](Tools/OfficeActivation) | Microsoft's Get Help `ResetOfficeActivation`: clears Office licences and cached sign-ins so the user can activate fresh. Downloaded each run and checked for Microsoft's signature. | `Reset-OfficeActivation` |
| | [Teams Meeting add-in fix](Tools/TeamsAddin) | The missing Teams Meeting button in classic Outlook: checks the add-in is installed and registered, fixes LoadBehavior and Outlook's disabled and do-not-disable lists, and gives Microsoft's reinstall steps for the rest. | `Repair-TeamsMeetingAddin` |
| **Diagnose** | [Quick triage](Tools/QuickTriage) | The first five minutes of any ticket on one page: device, uptime, pending reboot, disk space and health, crashes, updates, antivirus, Entra/Intune, memory and network. Problems first, each with a next step, plus a one-line summary for the ticket. `-Reports` adds Windows' own Wi-Fi and battery reports. | `Invoke-QuickTriage` |
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

Invoke-QuickTriage -Html
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
                                              │
                                              ├─ EndpointToolkit.psm1  reads tools.json, builds the menu and commands
                                              ├─ tools.json            one entry per tool: path, admin, mode, prompts
                                              └─ Tools\<Tool>\*.ps1    the scripts, unchanged by the toolkit
```

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
  "admin": true,
  "mode": "child",
  "confirm": "Optional: shown before it runs, for anything destructive.",
  "prompts": [
    { "param": "IncludeKeys", "type": "switch", "prompt": "Include the Wi-Fi passwords?", "default": false }
  ]
}
```

3. Add the command to `FunctionsToExport` in `EndpointToolkit.psd1`, then run the tests. They'll fail if a prompt names a parameter the script doesn't have.

Prompt types: `switch` (y/n), `string` (blank = skip), `choice` (numbered options).

## Security notes

- `irm | iex` runs whatever is on `main` at that moment. On client machines, pin a tag with `-Ref` so a later push can't change what runs.
- Nothing in this repo is tenant- or client-specific: no IDs, credentials or names. Every run asks for what it needs. CI runs a secret scan (gitleaks) on every push.
- Execution policy is only relaxed for the current process. If Group Policy enforces `AllSigned`, the launcher can't run until the scripts are signed.
- The launchers use plain `-File` / `-Command`, never `-EncodedCommand`, so they don't look like malware to EDR.

## Building an .exe (optional)

```powershell
.\build\Build-Exe.ps1 -RequireAdmin          # -> dist\EndpointToolkit.exe
```

The exe is a small stub that runs the one-line launcher, so it never goes stale. Unsigned PS2EXE binaries are a well-known AV false-positive magnet, so sign it (`-CertificateThumbprint`) or stick with `Launch-Toolkit.cmd`.

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Test-Repo.ps1
```

The tests check that every script parses, that `tools.json` matches the scripts' real parameters and the module exports match the manifest, that values with spaces and switches reach a child process intact, and that the menu works end to end with scripted input. They finish with a leak scan. Add your own private patterns (employer or client names) to `tests\leak-patterns.local.txt`. That file is git-ignored, so it's checked but never committed. CI runs the same tests on Windows PowerShell 5.1 and PowerShell 7, plus PSScriptAnalyzer.

## Licence

[MIT](LICENSE)
