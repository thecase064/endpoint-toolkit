# Changelog

## 1.8.1 - 2026-11-10

### Fixed
- **Dell driver updates failed at the scan with exit 107** ("The path provided for option '-report' is a reserved folder that may not be used"). Newer Dell Command | Update refuses some folders for its report and log, and in practice that includes `C:\ProgramData\OEMUpdates`, not just the Windows, Program Files and Users\Public folders Dell documents. DCU now writes its report to `C:\ProgramData\Dell\OEMUpdates\Dell_<time>`, the one ProgramData path Dell says is fine, and the report is copied back into `C:\ProgramData\OEMUpdates` as before, so New device setup's log folder doesn't change. If DCU still refuses it, the scan runs again without a report and the updates are read from DCU's console output. Found on a Latitude 7490.
- DCU's `-outputLog` is no longer passed to the scan or the install. The toolkit's own log already keeps everything DCU prints, so it was a copy that could be refused the same way.
- Exit 107 from DCU now has a plain message instead of "Unexpected exit code".

## 1.8.0 - 2026-11-09

### Added
- **Performance check (slow PC)** (`Invoke-PerformanceCheck`, Diagnose). It measures the PC for 30 seconds while the user does whatever is slow, then reports why, problems first, each with what to do:
  - **Hardware:** Windows on a hard drive or an SSD, free space, RAM size, and a single RAM stick in a two-slot machine.
  - **Load:** CPU, system drive and memory averaged over the sample, plus paging and a missing page file.
  - **Power:** on battery, power plan, power mode, maximum processor state, and whether the CPU ran below its normal speed while it was busy.
  - **Apps:** what used the CPU, memory and disk, grouped by app, with advice for Teams, Defender scans, search indexing, OneDrive, Windows Update, browsers, Outlook, leftover McAfee and more.
  - **Stability:** app hangs, and Windows' low-memory warnings with the apps they name.
  - **Startup:** recent start-up times, what Windows says slowed start-up, and every startup app (Run keys, Startup folders, Store apps), on or off.
  - **Drivers:** BIOS age, and a missing or old graphics driver.
  - Uptime and pending restarts.
- **`-Fix`**: after the report, it offers only changes you can undo, one question at a time: the power plan from Power saver to Balanced, the maximum processor state back to 100%, and startup apps you pick, turned off the way Task Manager does it. Security, remote support, VPN, driver helpers and OneDrive are never offered. Each change is listed with its undo. It never restarts. A blank answer (remote session, RMM) changes nothing.
- When run elevated as a different account, it reads and changes the startup apps of the person signed in at the PC, not the admin's.

### Changed
- Quick triage's memory and CPU warnings now point at Performance check.
- Test-Repo's leak scan allows Windows' built-in power plan and power mode GUIDs, listed by name.

### Tests
- Performance check, 121 checks with faked CIM, event logs, registry, powercfg and typed answers: a healthy PC (nothing flagged), a slow PC (every check firing, FAILs first, hardware first), process grouping and exact CPU maths, the system disk picked over a busier data disk, power mode names, the maximum processor state read from `powercfg` output, boot times and what slowed start-up, low-memory messages in either case, hangs by app, Task Manager's on/off flag (02, 06 on; 03 off; no entry on), Store app startup tasks, Startup folders, 32-bit Run keys, the never-offered list, and HTML escaping.
  - `-Fix`: yes / no / numbers with duplicates and junk, blank answers changing nothing, failed changes recorded as failed, nothing to fix, admin-only apps not offered without admin, the signed-in user's hive used when elevated as someone else, a policy-set plan not offered.
  - Robustness: the measurement failing, no CPU speed counter, no Storage module, no inventory.
  - Each key behaviour was also broken on purpose to prove the tests catch it.

## 1.7.2 - 2026-11-06

### Fixed
- **The 1.7.1 fix didn't work; this one does.** On Windows PowerShell 5.1, .NET Framework writes the byte order mark into the child's input as the process *starts*, not when the input is closed. CI showed it arriving as `∩╗┐` (U+2229 U+2557 U+2510: the three bytes read back on code page 437). The console's input encoding is now swapped for UTF-8 without a byte order mark just while the child starts, then put back. That only happens on Windows PowerShell 5.1 with a UTF-8 console, the one case that sent it.

### Changed
- CI: `actions/checkout` v4 → v6 and `gitleaks/gitleaks-action` v2 → v3, both on Node 24. This clears GitHub's "Node.js 20 is deprecated" warnings.

### Tests
- The blank-answer test also prints the PowerShell edition and the console's input code page.

## 1.7.1 - 2026-11-06

### Fixed
- **Piped-back output (remote sessions, RMM shells) on Windows PowerShell 5.1** (first attempt; see 1.7.2): a tool asking a question mid-run could get an invisible character instead of a blank answer. Closing the child's input on .NET Framework wrote a UTF-8 byte order mark first when the console was in UTF-8 mode; PowerShell 7 never did. The pipe is now closed without writing anything. Found by the Windows PowerShell 5.1 CI job, which had failed this one test since 1.6.0.

### Tests
- That test now prints the exit code and the answer's characters, so a failure says what actually arrived.

## 1.7.0 - 2026-11-06

### Added
- **Build report for New device setup.** An HTML page (plus the same data as JSON) in `C:\ProgramData\DeploymentMaster\Reports`, opened at the end of the build. It has:
  - **Each step:** what it does (the menu's brief), result, exit code, time taken and its full output (collapsed).
  - **Still to do:**
    - Windows Update: Windows' own scan, read-only, drivers included, with a 15-minute limit.
    - Dell / HP / Lenovo: driver, firmware and BIOS updates still available (read-only scan).
    - Whether a restart is pending.
  - **Device details:** make, model, serial, BIOS, Windows build, Entra, Intune, BitLocker with recovery key, TPM, Secure Boot, disk, memory.
  - **App versions:** Microsoft 365 Apps, Chrome and Reader, and confirmation that McAfee is gone.
  - **Build details:** ticket number, technician, the account it ran as, start, finish and duration, toolkit version, and a notes box.
  - **Print or save as PDF** expands all output first.
- New device setup asks for a **ticket number** and **your name** for the report.
- New device setup **installs Dell / HP / Lenovo drivers and firmware** (never BIOS) as a step, installing the vendor's updater if needed. Other makes are skipped, and the report says why. `-SkipDriverUpdates` turns it off.
- **Intune primary user** tool (`Set-IntunePrimaryUser`, also an optional first step of New device setup):
  - Shows, changes or removes the PC's Intune primary user; Intune updates the Entra device owner to match.
  - Reads the tenant and Intune device ID from the PC itself, then signs in as a tenant admin in Microsoft's window (MFA works). Remote sessions use a device code.
  - Downloads Microsoft's Graph sign-in module only if it's missing, and refuses it unless the signatures check out. The cache is deleted at the end of a build.
  - New device setup runs it first, so you sign in while you're still at the PC.
- `Invoke-OEMUpdate -ResultFile`: writes the make, model, updates found or installed, exit code and last problem as JSON.
- Window: a **Changes the tenant** pill for tools that change Microsoft 365 rather than the PC (`"changes": "tenant"` in `tools.json`).

### Changed
- New device setup shows each step's output live as before, and also saves it. The output is plain text now (no colours from the step itself); the build script colours OK, warning and error lines.
- New device setup exits `1` when any step needs a look (it used to always exit `0`), so the window and menu show CHECK LOG.
- `install.ps1` leaves folders starting with `_` (the module cache) alone when tidying old copies.
- The New device setup guide is now `Tools/NewDeviceSetup/README.md` (was `README.txt`).
- **Chrome + Reader installers are signature-checked.** Each must be validly signed by its vendor (certificate organisation exactly `Google LLC` / `Adobe Inc.`) before it runs; anything else is deleted and not installed. That was the last run-time download the toolkit didn't verify.
- Chrome + Reader: one app failing no longer stops the other, and a failed download, signature check or install now exits `1`. Installs that failed used to log an error but still exit `0`, so the build report showed them as OK.

### Removed
- **Hostname desktop shortcut** (`New-HostnameShortcut`, `Tools/HostnameShortcut`): gone from the toolkit, the menu and the window, along with its New device setup step and `-SkipHostnameShortcut`.

### Tests
- Build chain, with fake steps, 36 checks: step order and arguments, primary user given / not given / removed / failing, bad options refused before anything runs, a failing step not stopping the build, missing scripts, other makes, skipped drivers, drivers needing a restart, no reboot, Windows Update timing out, leftover McAfee, step output escaped in the HTML, briefs taken from `tools.json`.
- Intune primary user, 27 checks: show, set, already set, remove, nothing to remove, unknown user, bad address, both options, not joined, not enrolled, not in Intune yet, no permission, sign-in cancelled, slow to update, disabled user, tenant override, device code with no desktop, module download, cache reuse, and signature refusals (unsigned DLL, tampered file, non-Microsoft signer).
- OEM tool: 5 more checks for `-ResultFile` (now 43).
- Chrome + Reader signature checks, 29 checks: valid, unsigned, tampered, untrusted, wrong company, look-alike names (`Google LLC Ltd`, `OU=` instead of `O=`, `CO=` inside another field), quoted names, refused file deleted, one app refused while the other installs, install failures and download failures exiting `1`.

## 1.6.0 - 2026-11-06

### Added
- **Toolkit window (WPF).** Tool list grouped by category with search on the left. Pick a tool to see its brief, tags (category, needs admin, opens a window), any warning, and its options as checkboxes, choices and text boxes. **Run** starts it in its own PowerShell window: with a UAC prompt when it needs admin, and a Yes/No check first for tools with a warning. A panel at the bottom shows each run's exit code and OK / CHECK LOG. Follows Windows' light or dark mode (`ETK_THEME=Dark` or `Light` overrides), and a sun / moon button in the title bar switches it live for that window (nothing saved). Built into Windows, nothing to download.
  - Looks: its own dark title bar (WindowChrome, no native code), an icon per tool from Windows' icon font (Segoe Fluent Icons / Segoe MDL2 Assets), short names in the list with a shield on admin tools, rounded search box, thin scrollbars, and themed checkboxes and radio buttons.
  - Pills beside the name: **Read-only**, **Read-only by default** (an option can change that) or **Changes the machine**, plus **Needs admin** and **Opens a window**.
- `tools.json`: `icon` (an icon-font code point) for every tool, and `readOnly` (`true` or `"default"`) for the ten tools that change nothing. Tests check every brief agrees with its flag.
- **`console.ps1` one-liner** for remote shells: `irm .../console.ps1 | iex` always opens the console menu. `install.ps1` and `Start-Toolkit.ps1` take `-Console` for the same thing.
- `Show-EndpointToolkitGui` command. `etk` now opens the window; `etkc` opens the console menu.
- `Gui\Invoke-ToolWindow.ps1` runs one tool for the window. Options travel in a temp file with its SHA-256 on the command line; a file that doesn't match is refused, and the file is deleted once read.

### Changed
- Exchange + Planner usage brief: it said it changes nothing in the tenant, but if the tenant hides names in usage reports it offers to show them for the run (and hides them again). The brief now says so. M365 licence report brief now says it installs modules only if ticked.
- `install.ps1` (and `Launch-Toolkit.cmd`, and the exe) open the window. Where there's no desktop (remote session, RMM shell running as a service, Server Core, or WPF missing) they fall back to the console menu by themselves.
- **Remote sessions:** child-mode tools now pipe their output back to your session as they run. Before, `Start-Process -NoNewWindow` output was lost over `Enter-PSSession`. Their input is closed, so a question mid-run gets a blank (safe) answer instead of hanging. Detected automatically; `ETK_STREAM=1` or `0` forces it.

### Tests
- Window: layout and code agree on all 20 named controls and every colour. Light and dark palettes match. Untouched options give exactly what pressing Enter at every console prompt gives, for all 24 tools. Required boxes, bad choices, run plans, tags and labels are checked. The options-file hash check is tested, including a changed file. The Run button's launch path is tested end to end. On Windows the window is built and clicked through in code (select, options, search, Run with a required box empty), never shown.
- Remote output: child tools tested both ways (own console, piped back), including a mid-run question.

## 1.5.0 - 2026-11-06

### Changed
- **Menu: brief first, then `Run it?`.** Picking a number no longer starts anything. The menu shows a short brief (what the tool does, what it changes or that it's read-only, any warning, whether it needs admin or opens a window, how many questions follow), then asks `Run it? [y/N]`. Only `y` runs it; anything else goes back to the menu. Admin tools still offer the elevated relaunch first and show the brief again in the new window.
- The old warning-only `Carry on? [y/N]` question is gone. The warning is now part of the brief, so there's one question for every tool instead of two for some.
- `Get-ToolkitTool` returns each tool's `Brief`.

### Added
- `brief` field in `tools.json`, written for all 24 tools and checked against what each script actually does.
- Tests: every tool has a 1-5 line brief within 96 characters; menu names fit the menu column; the brief and warning are shown; saying no runs nothing and goes straight back to the menu; `Run it?` is asked before any of the tool's own options.

## 1.4.1 - 2026-11-06

Docs and CI only. No tool behaviour changed.

- **M365 Apps reset README** rewritten as `README.md`. It replaces the old USB-stick note and now covers the menu and command, every parameter, what to expect, logs, and the Get Help deep clean (`-DeepClean`).
- **Security notes** in the main README now list what each tool downloads at run time, where from, and what's checked before it runs.
- **Disk usage README** points at the toolkit menu and folder instead of an old standalone path.
- **CI:** PSScriptAnalyzer is pinned to 1.25.0 and run one file at a time. Its known intermittent "Object reference not set" crash is retried once, then reported as a warning naming the file, instead of failing the whole job. Error-severity findings still fail the build.

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
