# Changelog

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
