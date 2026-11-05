# Changelog

## 1.4.0 - 2026-11-05

- **OEM driver + BIOS updates** (`Invoke-OEMUpdate`, Build): works out whether the machine is a Dell, HP or Lenovo, then uses that vendor's own updater:
  - Dell: Dell Command | Update CLI
  - HP: HP Image Assistant (business PCs)
  - Lenovo: the LSUClient module
- It scans and lists drivers and firmware, asks before installing, and never restarts the machine itself. Exit codes: `3010` when a restart is needed, `2` when updates are waiting (`-ScanOnly`).
- BIOS updates are only included when ticked (`-IncludeBios`). BitLocker is suspended for one restart, and it warns when running on battery.
- If the vendor's updater is missing it asks before installing it: winget for Dell and HP, the PowerShell Gallery for Lenovo. `-InstallTool` allows that without asking, for unattended runs.
- Each vendor's result codes are translated into plain English.

## 1.3.0 - 2026-11-05

New tools, each with its own menu entry:

- **Teams cache clear** (`Clear-TeamsCache`, Repair): closes Teams in this user's session only, empties the cache folder Microsoft documents for new Teams (and classic Teams if it's still there) and starts Teams again. Only the cache is cleared, so settings survive. It runs as the user, and stops rather than clear the wrong person's cache if the account running it isn't the one signed in.
- **Print spooler clear** (`Clear-PrintSpooler`, Repair): counts the queued jobs from disk (the spooler may be the thing that's hung), stops the spooler (ending `spoolsv.exe` if it won't stop), deletes the job files and starts it again with its dependants. Only `.SPL`/`.SHD` files are ever deleted, from the spool folder set in the registry.
- **Office activation reset** (`Reset-OfficeActivation`, Repair): Microsoft's Get Help `ResetOfficeActivation` scenario clears Office licences and cached sign-ins so the user can activate fresh. Every result code gets a plain-English message, and it warns when the admin running it isn't the signed-in user.
- **Teams Meeting add-in fix** (`Repair-TeamsMeetingAddin`, Repair): for the missing Teams Meeting button in classic Outlook.
  - Checks that the add-in is installed (and isn't the old 1.23.x version from classic Teams) and is registered with Outlook.
  - Fixes `LoadBehavior`, Outlook's disabled-items list and its do-not-disable list.
  - Points to Microsoft's reinstall steps for anything it can't fix.
  - Says when new Outlook is in use, since that has Teams meetings built in.
  - Written from Microsoft's documented checks, because Get Help's Teams troubleshooters don't support new Teams.
- **BitLocker key backup check** (`Test-BitLockerKeyBackup`, Diagnose): checks each recovery key against the BitLocker event log for a successful backup to Entra (845) or a failed one (846, with the error explained). `-Fix` backs up the missing keys. It never shows the keys themselves. Exit code 1 when anything isn't proven backed up, so it works as a remediation detection script.

Changes:

- **Quick triage `-Reports`** adds Windows' own Wi-Fi report and battery report to `C:\Triage`, linked from the HTML page. The battery report is skipped on desktops. The Wi-Fi report needs an elevated session and says so if it isn't elevated. The menu asks, default no.
- The Get Help download, signature check and runner moved into `Tools\Shared\Helpers.ps1`, shared by M365 Apps reset and Office activation reset. The deep clean behaves the same as in 1.2.1.

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
