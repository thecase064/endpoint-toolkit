# Changelog

## 1.2.1 - 2026-11-05

- **M365 Apps reset `-DeepClean` works again.** Microsoft removed the SaRA command line from Windows in March 2026 and its download link now serves the Get Help command line instead, so the deep scrub was being skipped with a warning every time. It now runs `GetHelpCmd.exe -S OfficeScrubScenario`. The download is fresh on every run (each build expires after 90 days), it won't run unless it's signed by Microsoft, it runs from its own folder, and Office apps are closed again first. Every documented result code gets a plain-English message, the output is saved to `C:\OfficeReset\GetHelp_<time>.log`, and old SaRA leftovers are cleared out.
- The menu now asks whether to run the deep scrub (default no).

## 1.2.0 - 2026-11-04

- **Quick triage** (`Invoke-QuickTriage`): the first five minutes of any ticket in one go. Device details, uptime (and whether Fast Startup is hiding it), pending reboot, free space and disk health, battery wear, Entra/Intune health, blue screens, unexpected shutdowns and app crashes, last update, antivirus and Defender state, memory and CPU, gateway and DNS. Problems come first, worst first, each with a next step, plus a one-line summary to paste into the ticket. Console and one-page HTML. Builds on the inventory and Entra/Intune tools rather than duplicating them.

## 1.1.0 - 2026-11-04

New tools:

- **Entra / Intune health check** (`Get-EntraIntuneHealth`): join state, device auth, PRT, MDM enrolment, Intune certificate, last check-in, push service, IME, event log errors and endpoint reachability, each with a fix hint. `-Sync` forces a check-in, `-CollectLogs` zips everything for escalation, and exit code 1 on failure makes it usable as an Intune remediation detection script.
- **Device inventory** (`Get-DeviceInventory`): model, serial, BIOS, OS build, CPU, every RAM stick, disks with health and wear, volumes and BitLocker, monitors with serials, battery wear, network, TPM and Secure Boot. Console, HTML and JSON.
- **Driver export / import** (`Export-DeviceDriver`): backs up third-party drivers with a manifest and restore note, optionally zipped; `-ImportFrom` puts them back.
- **Windows Update reset** (`Reset-WindowsUpdate`): stops the update services, sets aside SoftwareDistribution and catroot2 (renamed, not deleted), restarts and rescans. Flags pending reboots, WSUS policy and low disk first.
- **Hostname desktop shortcut** (`New-HostnameShortcut`), now also step 5 of the new device build (skip with `-SkipHostnameShortcut`).
- **Exchange + Planner usage report** (`Get-ExchangePlannerUsage`): licensed-but-unused users, from Graph usage reports, the unified audit log and sign-in logs. Default output folder is now `Documents\M365Reports`, matching the licence report.

Toolkit:

- Menu prompts can be marked `"required": true`.

## 1.0.0 - 2026-11-04

First public release.

- Menu-driven launcher (`Show-EndpointToolkit` / `etk`) built from `tools.json`.
- One-line bootstrap (`install.ps1`), double-click `Launch-Toolkit.cmd`, optional PS2EXE stub.
- Every tool also exported as a command with the script's own parameters and help.
- Repo tests (`tests/Test-Repo.ps1`) and CI on Windows PowerShell 5.1 and PowerShell 7.

Changes to the tool scripts versus their standalone versions:

- **New device setup:** resolves sub-scripts from the toolkit's `Tools\` folder layout instead of fixed folder names.
- **Windows repair checks:** DISM exit code 3010 (success, reboot pending) no longer stops the run.
- **Event triage:** mute list moved to `%APPDATA%\EventTriage` so it survives toolkit updates; seeded from the bundled list.
