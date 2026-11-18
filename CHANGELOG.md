# Changelog

## 1.18.0 - 2026-11-18

### Added
- **Toolkit cleanup** (`Remove-ToolkitData`, menu 33 in a new **Toolkit** section, admin). For leaving a PC as you found it. Lists everything the toolkit has saved on the PC with sizes, in four groups, and deletes the groups you tick after one more `[y/N]`. Nothing ticked: list only.
  - **Reports and logs:** `C:\Triage` reports, build reports and logs, tool logs in ProgramData, `C:\OfficeReset` logs, device inventory, disk usage reports, Entra / Intune log bundles, M365 reports (both the redirected Documents folder and `%USERPROFILE%\Documents`, since the two reports default to different ones).
  - **The toolkit itself:** the downloaded copies in `C:\ProgramData\EndpointToolkit` (with the Graph module cache), the installed module, saved licence names, Event triage mutes, and downloads or working files a tool left behind. Run from the toolkit window or console menu, **that closes once the removal succeeds** (`closesToolkit` in `tools.json`).
  - **Driver backups** (`C:\DriverExport`) and **Windows Update reset backups** (`SoftwareDistribution.old-*`, `catroot2.old-*`): their own options, off by default, with a warning.
  - **Only the toolkit's own files**, matched by the names the tools use, from one list (`Tools\Shared\ToolkitData.psd1`). Anything else in those folders is listed as left alone; a folder goes only once it's empty; links are removed as links, never followed; shared parents (`ProgramData\Dell`, `Documents\WindowsPowerShell\Modules`) are never removed. It steps out of the toolkit's folder before deleting (Windows won't delete a folder a process is in). Needs admin for `C:\` and ProgramData; `-Yes` for the RMM, and a run that can't ask deletes nothing. Exit 0 done, 1 something couldn't be deleted, 2 you said no.
- `docs/data-flow.md`: a Toolkit cleanup diagram, and the folder table now also lists the installed module, Windows Update reset's old folders and the unelevated Graph module cache.

### Fixed
- **A missing answer always reads as no.** With nobody to answer (input closed, or piped input used up) `Read-Host` returns nothing at all, and PowerShell's `-notmatch` on that is empty, so `if ($answer -notmatch '^y')` treats it as a yes. Found while testing the cleanup, then checked everywhere: the console menu's `Run it? [y/N]` could run a tool when piped input ran out right after its number, and the Exchange + Planner report's "Correct tenant?" could pass unanswered. Every `Read-Host` answer is now made a string first (Performance check, Old profile cleanup and the OEM updater already did, or tested it safely).

### Tests
- Toolkit cleanup: 42 checks with a harness that builds a fake PC holding every file the tools write (their real name formats) and things that must survive (your notes in `C:\Triage`, a spreadsheet in `M365Reports`, Dell's own folder, other modules, someone else's temp files, the live `SoftwareDistribution` and `catroot2`, a driver folder named otherwise, links pointing outside). List only, no, no answer at all, yes, each group alone, not admin (refused for C:\ and ProgramData, fine for the account's own files), nothing there, `-Quiet`, `-PassThru`. Run under UTC, New York and Tokyo. Sixteen key behaviours broken on purpose, each caught.
- **New repo tests:** every place in `ToolkitData.psd1` follows the rules and matches the data-flow folder table both ways; the cleanup reads its list and steps out of the toolkit's folder before deleting; `closesToolkit` names one of the tool's switches; the console menu closes after a successful removal and not otherwise (run for real with a fixture); on Windows the window closes only after a removal that exited 0; every `Read-Host` answer in the shipped scripts is a string.

## 1.17.0 - 2026-11-18

### Changed
- **The PowerShell window gets out of the way.** After `irm ... | iex`, `etk` or `Launch-Toolkit.cmd`, the PowerShell window the toolkit window was started from is **hidden while the toolkit is open** and **comes back when you close it**. Its prompt is busy until then anyway. In **Windows Terminal** it's minimised instead (Windows Terminal can't hide a single tab, so the whole Terminal window minimises), and restored afterwards.
  - It always comes back, even if the toolkit window closes with an error (the error is still shown).
  - Left alone when it's already hidden or minimised (an RMM shell, a shortcut that starts minimised), in VS Code's terminal and the ISE, and wherever the console menu opens instead of the window (remote sessions, Server Core). Tool runs still open in their own PowerShell windows, as before.
  - Uses Windows' own window calls (`GetConsoleWindow`, `ShowWindow`), compiled when the toolkit window opens. If that's blocked (Constrained Language Mode), the window simply stays visible as before.

### Tests
- 20 checks with a harness faking Windows' window calls: the classic console (hidden, then shown), Windows Terminal (minimised, then restored, not just shown), already hidden, already minimised, no console, VS Code, another host, the calls failing; and the toolkit window itself: hidden while open, back after, back after an error, never hidden when the window can't open. The real code compiles and fails safe off Windows. Twelve key behaviours broken on purpose, each caught.
- **New repo tests:** the hide / restore wraps the window with the restore in a `finally`; hiding and restoring never throws; on Windows (CI) the real code compiles and runs under 5.1 and 7.

## 1.16.0 - 2026-11-18

### Changed
- **Licence names from Microsoft's own list** in the **M365 licence report** and the **Exchange + Planner usage report.** Licences are named the way the admin centres name them, from the CSV behind Microsoft's "Product names and service plan identifiers for licensing" page, instead of a hand-kept table that goes stale every time Microsoft renames something (Azure AD -> Entra, Power BI (free) -> Microsoft Fabric (Free)).
  - Downloaded from download.microsoft.com (no sign-in, nothing sent) at most **once a week**, saved to `%LOCALAPPDATA%\EndpointToolkit\LicenseNames.csv`, shared by both reports. If the download fails, the saved copy is used. A file that isn't the list (a Wi-Fi sign-in page, a cut-down or oversized file) is rejected and never replaces a good saved copy.
  - Looked up by SKU part number, then by SKU id, so a SKU Microsoft has renamed still gets its name.
  - **Licence report:** falls back to its built-in names, then a tidied part number, as before. The **Report Info** sheet has a new "Product names" row saying which list was used and when it was saved.
  - **Usage report:** the **Licences** column now shows product names ("Microsoft 365 Business Premium"); a new **Licence SKUs** column keeps the part numbers (`SPB`) for filtering. Paid Planner / Project detection still goes by part number. Without the list, Licences shows part numbers, as before.
  - **`-SkipNameDownload`** on both: no download, use the saved copy (or the fallbacks).
- **`Get-LicenseNameMap`** added to `Tools/Shared/Helpers.ps1` (and its README), for any tool that needs licence names.
- `docs/data-flow.md`: the new download and the `%LOCALAPPDATA%\EndpointToolkit\` folder.

### Tests
- 43 checks with a harness running the real helper against a fake download: first download, a fresh saved copy (used), an old one (replaced), `-MaxAgeDays`; no network with and without a saved copy; a captive-portal page, a cut-down file and a 21 MB file (all rejected, nothing left behind, the good copy kept); with and without a byte-order mark; part numbers and SKU ids in any case, a quoted name with a comma, first row wins, blank names skipped; `-SkipNameDownload` with an old copy, no copy and an unreadable one. Both reports' naming code is lifted out and tested (Microsoft's name first, then by SKU id, the built-in name, the tidied part number, no list at all), plus how each report is wired up.
- Run under UTC, New York and Tokyo time; key behaviours broken on purpose, each caught.
- **New repo test (CI only, needs the internet):** downloads Microsoft's real CSV through the helper. `SPB` and its SKU id must come back as Microsoft 365 Business Premium, `ENTERPRISEPACK` as Office 365 E3, with a believable number of names. A network failure skips; a file that downloads but doesn't read fails, as that means Microsoft moved or changed it. It also prints where the licence report's built-in names differ from Microsoft's.

## 1.15.0 - 2026-11-18

### Added
- **Error code explainer** (`Resolve-ErrorCode`, Diagnose, read-only, offline). For "what does 0x800F0922 mean?". Paste one or more codes, or the whole error message, and every code in it is found and explained:
  - **Finds:** `0x80070005`, `80070005`, `-2147024891` / `2147942405`, Setup pairs (`0xC1900101 - 0x40017`, any dash), `code 43` / `error 1603` / `exit code 3010`, a number on its own, `AADSTS...`. Ignores GUIDs (correlation IDs), dates, plain 8-digit numbers and Unix times. Each argument is read on its own; the same code is explained once.
  - **The toolkit's own notes**, with what to do: Windows Update / upgrade, Windows Time, Device Manager problem codes, Dell Command | Update and HP Image Assistant exit codes, Entra join errors. A plain number matches exit / problem codes and its `0x8007...` form, each labelled with where it's from.
  - **Windows' own name and message** from `certutil -error` (built into Windows), read whatever language its label is in. certutil's answer is final; Windows' message via .NET only if certutil is missing or blocked. Message blanks (`%1`, `0x%p`) are shown as `...`; a message with blanks and no name is dropped (on real Windows, `certutil -error 43` picks up an unrelated message, as there's no Windows error 43). **NTSTATUS codes** come from certutil where it knows them (`STATUS_ACCESS_VIOLATION`), otherwise mapped to the Windows error they mean (`RtlNtStatusToDosError`).
  - Windows itself has no name or text for many Windows Update and servicing codes (`0x800F0922`, `0x80240016` on a current build): that's where the toolkit's notes come in.
  - **Decoded:** a Win32 error wrapped as an HRESULT, the facility (Windows Update, BITS, Setup, BitLocker...), a vendor's own code (customer bit), success / information.
  - **Setup extend codes** as phase and operation (Microsoft's tables), and **blue screen stop codes** (and their `0x1000...` variants) with the name and usual cause.
  - `-Quiet` one line per code, `-PassThru`. Exit 1 when no code is found.
- **`Tools/Shared/ErrorCodes.psd1`:** every code the toolkit explains, in one data file, generated from the tools' own tables, plus the facility, Setup and stop code tables. The tools that already had tables keep them unchanged.
- `Tools/Shared/README.md` now lists `Get-CurrentUserSid` and `Resolve-AccountSid` (added in 1.13.0) and the shared code file.

### Tests
- Resolve-ErrorCode, 61 checks with a harness using the real shared code file and faking certutil (English, another language, unknown codes, missing, blocked) and Windows' NTSTATUS mapping. Covered: every way of writing a code, Setup pairs (with an en dash, no spaces, non-Setup results, two HRESULTs, a small first number), code / error / exit code, numbers in sentences, AADSTS (known and not), GUIDs / dates / Unix times ignored, duplicates in one argument and across several; the toolkit's notes (Windows Update, Device Manager, Dell + Device Manager for 1, the HRESULT form of 5, hex not matching problem codes, mixed case, Entra, HP 3010), an unreadable shared file; certutil names and messages, unknown (and final), a Windows Update code Windows doesn't know, the stray message for 43, a real message with blanks, the fallback; NTSTATUS from certutil, mapped, unmapped; decoding (Win32, facility 36, unknown facility, vendor, success); stop codes (`0x0000007e`, `0x1000007E`, `0xC000021A`, `0x133`, never from a decimal); `-Quiet`, order, ASCII.
- A second run without the fake checks the real P/Invoke code compiles and fails cleanly where ntdll isn't there.
- Run under UTC, New York and Tokyo time. Twenty-five key behaviours were broken on purpose; each was caught. Testing found two bugs before release: a dash between a small number and another code swallowed the second code, and the Windows line printed `System.Object[]`. The first Windows CI run found two more things a fake certutil couldn't: the stray message for 43, and that certutil knows NTSTATUS names but not `0x800F0922`; the CI test now prints certutil's raw answers.
- **New repo tests:** each tool's own code table must match `ErrorCodes.psd1` exactly (meaning and fix, nothing missing or extra). On Windows (CI) the NTSTATUS C# is compiled for real under 5.1 and 7 and `0xC0000005` must map to error 998, and the explainer runs against the real certutil: `0x80070005` must come back as `ERROR_ACCESS_DENIED`, `0x800F0922` with the toolkit's note, `0xC0000005` as `STATUS_ACCESS_VIOLATION` with its blanks tidied, and `code 43` with the Device Manager note and no stray Windows message.

## 1.14.0 - 2026-11-18

### Added
- **Audio check** (`Get-AudioStatus`, Diagnose, read-only, no admin). For "there's no sound" and "my mic doesn't work in Teams":
  - **Services:** Windows Audio and Windows Audio Endpoint Builder missing, disabled or stopped (with the commands to fix).
  - **Playback and recording:** every endpoint with its state (active, disabled in Sound settings, unplugged; "not present" ones counted). **Which device is the default, its volume and mute**, from Windows' own Core Audio API compiled in at run time. Default muted or at 0% is a FAIL, under 10% (speakers) / 20% (mic) a WARN. No working output is a FAIL, no working mic a WARN, each saying which ones are disabled or unplugged and how to get them back. Calls going to a different device, and a Bluetooth headset stuck in hands-free mode, are noted. If Core Audio can't be used (Constrained Language Mode, antivirus), the rest still runs and says so.
  - **Microphone privacy:** off for the whole PC, for the signed-in user, for desktop apps (classic Teams, Zoom, browsers) or for new Teams; the app-privacy policy (force deny, or Teams on the deny list); other apps blocked. Read for **whoever is signed in**, even when it runs elevated as an admin account or as SYSTEM from the RMM.
  - **Sound hardware:** Device Manager problem codes in plain words (disabled = WARN; no driver, won't start and the rest = FAIL with what to do; "not connected" Bluetooth ignored), driver version / date / provider, and Windows' generic High Definition Audio driver standing in for the manufacturer's.
  - `-Quiet` one line (`output: Speakers (Realtek(R) Audio) 45%; mic: ... muted`), `-PassThru`, exit 1 on a FAIL.

### Tests
- Get-AudioStatus, 67 checks with a harness faking the registry (machine, current user and other users' hives), services, Device Manager, drivers and the Core Audio reader. Covered: healthy; muted / 0% / low output and mic; rounding; volume unreadable; default IDs in either case; no defaults; calls on another device (and muted); Bluetooth hands-free; no output (disabled, unplugged, nothing at all); no mic; Core Audio failing; each service stopped / disabled / missing; every privacy setting, the policy and its deny list; an admin or SYSTEM running it with someone else signed in, their registry not loaded, nobody signed in; problem codes 22 / 28 / 10 / unknown / 45; no hardware; Device Manager unreadable; the generic driver; names from Device Manager, the registry or neither.
- A second run without the fake checks the real Core Audio C# compiles, fails cleanly where it can't run, and is reused on a second run in the same session.
- Run under UTC, New York and Tokyo time. Twenty-two key behaviours were broken on purpose; each was caught. Breaking them showed the case-insensitive default-device match wasn't really being tested (an all-digit GUID); fixed.
- Repo tests: the Core Audio C# is checked for C# 5 only, and on Windows (CI) it's compiled for real under Windows PowerShell 5.1 and PowerShell 7, with a lookup of a device that doesn't exist coming back as an error, not a crash.
- Repo leak scan: Windows' public audio IDs (Core Audio classes and interfaces, endpoint property keys, the sound device class) added to the known-safe list, each named.

## 1.13.0 - 2026-11-18

### Added
- **Old user profile cleanup** (`Remove-StaleProfile`, Repair, admin). For shared PCs, hand-me-down laptops and "the C drive is full" when `C:\Users` holds people who left months ago. Read-only unless `-Remove`.
  - **List:** every user profile, oldest first. **Last used** comes from the sign-in / sign-out times Windows records per profile (`ProfileList\<SID>` `LocalProfileLoadTime` / `LocalProfileUnloadTime`, what Windows' own "delete profiles older than" policy uses since 1809), not `LastUseTime` or `NTUSER.DAT`, which antivirus and updates keep bumping. `NTUSER.DAT` is only the fallback. **Size** leaves out cloud-only OneDrive files and doesn't follow junctions. **Files in Desktop / Documents / Pictures / Videos / Music / Downloads** that aren't in OneDrive are flagged, because they go with the profile. Says whether the account still exists or is disabled. Entra accounts are named from Windows' own cache and never called deleted just because Windows can't name them offline. Domain accounts it can't look up say "deleted, or no domain controller in reach".
  - **Also reports, never changes:** folders in the profiles folder with no profile entry, `.bak` entries (the "temporary profile" problem, with the fix by hand) and the delete-old-profiles policy.
  - **Delete (`-Remove`):** pick by number (`1,3`, `2-4`), `all`, or Enter for none, then confirm with the count, size and names. Anything it doesn't understand deletes nothing. Deletes through `Win32_UserProfile` (folder and registry entry together), re-checking each profile isn't signed in first, then checks it has gone and shows the space that came back. A folder left behind (files in use) is a FAILED with what to do.
  - **Never offered:** profiles in use, system and service accounts, the built-in Administrator, the account running it, profiles outside the profiles folder, `-Exclude`. **Only if picked by number** (never by `all` or `-Yes`): no last-used date, the account that set the PC up (Entra join), the last person to sign in.
  - `-OlderThanDays` (default 90, at least 30), `-User` (one person's profile, any age), `-Yes` (RMM), `-SkipSize`, `-Quiet`. Exit 1 when a deletion fails, `-Remove` without admin, or `-User` matches nothing.
- Shared helpers: `Get-CurrentUserSid`, `Resolve-AccountSid`.

### Tests
- Remove-StaleProfile, 81 checks with a harness faking the registry, CIM (profiles, local accounts, disks), SID lookups, prompts and the clock; profile folders are real files, so sizes, symlinks and `NTUSER.DAT` dates are measured for real. Covered: the list (ages, sources, accounts, sizes, local files, kept reasons, order, notes, summary, ASCII); `-OlderThanDays`, `-SkipSize`, `-Quiet`, `-Exclude`, the account running it, an unreadable profile list; uncached Entra accounts, disabled and deleted local accounts, crash (sign-in after sign-out), zero and future times, a low DWORD read back negative, an entry with no folder; Entra join and last-signed-in protection; interactive picks (none, numbers, ranges, all, seven bad selections, confirm yes / no / blank); unelevated; `-Yes`; `-User` (any age, by address, can't reach kept profiles, no match); a delete that throws, a folder left behind, signed in or gone between list and delete, no disk figures; the cloud-only attribute logic.
- Run under UTC, New York and Tokyo time. Twenty key behaviours were broken on purpose (each kept rule, the delete-time re-check, `all` / `-Yes` protection, DWORD masking, sign-in vs sign-out, future times, cloud-only files, links, bad selections, the confirm, Entra naming, left-behind folders, exit codes, admin, `desktop.ini`); each was caught. It also found the free-space line printing "C::".

## 1.12.0 - 2026-11-18

### Added
- **Time sync fix** (`Repair-TimeSync`, Repair, admin). For "the clock's wrong" and sign-ins or Teams failing because the time is out. Checks first, fixes, then measures again:
  - **Check:** whether the PC is a domain controller, a domain member or not joined; the Windows Time service (missing, disabled, stopped is normal); **Set time automatically** turned off; the configured time source against the PC's role (a domain member on an outside server, a workgroup PC set to follow a domain); time settings from Group Policy / Intune; the source actually in use (Local CMOS Clock, Free-running System Clock, the VM host); the last good sync; Time-Service events from the last 7 days (no answer from the server, can't reach a DC); the time zone and whether it's set automatically.
  - **Measure:** how far out the clock is, from three samples against its own source (the median, so one bad sample doesn't count). Over 30 s is a WARN, over 5 minutes a FAIL (Kerberos sign-ins break). Shows how far out, not which way. A FAIL when the clock is further out than the largest jump Windows will make by itself.
  - **Fix:** turns the time service back on (Manual) and starts it, turns automatic time back on (the domain for members, the existing or time.windows.com server otherwise), resyncs (rediscovering the source after a change, retrying once if the service had stopped), then measures again and shows before and after. Every change prints its undo command.
  - Leaves alone: domain controllers (report only), anything set by policy, and the time server unless `-SetPeer` is given, which is refused on domain members. `-Peer` picks a different server, `-Reference` measures against one without changing anything. Never restarts.
  - `-CheckOnly` changes nothing; unelevated it checks only. `-Quiet` prints one line. Exit 0 when the clock ends up in time (check only: no FAIL).

### Tests
- Repair-TimeSync, 84 checks with a harness faking `w32tm` (sources, status, stripchart samples, resync and config results, error codes), the registry, services, CIM, events, the time zone and the clock. Covered: healthy, `-CheckOnly`, unelevated, `-Quiet`; offsets in time / WARN / FAIL / fixed / still off / one wild sample / comma decimals / days long / unmeasurable; the phase-correction limits (both, one, unlimited, -1); the service disabled, failing to change, failing to start, already running, missing, stopping before the resync; automatic time off (workgroup, no server, domain member, by policy); a domain member on pool.ntp.org; a workgroup PC on NT5DS; domain member and controller; `-SetPeer` (allowed, custom peer, refused on a member and under policy, config failing, bad host names); `-Reference`; sources (CMOS clock, VM host); last sync thresholds, never, non-English output; events; output order and ASCII.
- Run under UTC, New York and Tokyo time. Fifteen key behaviours were broken on purpose (DCs left alone, `-CheckOnly`, `-SetPeer` refusals, the median, comma decimals, the -1 limit, rediscover, undo commands, the 0x80070426 retry, daily sync for domain members, the 7-day event window, domhier for members, measuring against its own source, the exit code); each was caught.

## 1.11.0 - 2026-11-18

### Added
- **Windows Update status** (`Get-WindowsUpdateStatus`, Diagnose). "Why isn't this PC updating?" on one page, problems first, each with what to do. Read-only:
  - **Support:** Windows version and edition against Microsoft's end-of-updates dates (Home / Pro, Enterprise / Education and LTSC each have their own). Windows 10 past its end but still being patched is flagged as probably ESU. A build newer than the table shows as INFO, not a guess.
  - **Updates:** the last Windows patch (not the daily Defender definition), the last successful check for updates, and **failed updates** from Windows Update's own history, grouped by KB with the error code explained and a fix. A failure that later installed is left out. Repeated "can't connect to the update service" events. Falls back to the event log when the history can't be read.
  - **Policy:** who manages updates (Intune / MDM, Group Policy, WSUS, an RMM agent such as Datto RMM or NinjaOne, or nothing, with a note when Intune and an RMM agent can both patch); automatic updates turned off or notify-only; pauses from Intune, Group Policy or Settings (with the 35-day expiry); deferrals; a **version pin**, and a FAIL when it pins an out-of-support version; whether the **WSUS server answers**.
  - **Services:** Windows Update, Update Orchestrator, **Update Medic**, BITS, Windows Modules Installer, Cryptographic Services and Delivery Optimization not disabled, which is what "update blocker" tools change. Read from the registry, so it works unelevated.
  - **Restart, Disk:** updates waiting for a restart; free space for monthly (10 GB) and feature (20 GB) updates.
  - **Upgrade:** Windows' own readiness verdict for the next version (Red / Orange / Yellow / Green) with the hardware reason (TPM, Secure Boot, CPU, RAM, drive), **Microsoft safeguard holds**, Windows Setup's compatibility report (apps, hardware and drivers that block it; run as admin), **SetupDiag's** verdict on the last failed upgrade, and Setup files left on the drive. Old reports, and reports from before the current Windows install, drop to INFO.
  - **Activity:** update and Setup processes running right now.
  - **`-Watch`** then follows update activity for `-WatchMinutes` (default 30), one plain line whenever something moves: servicing processes starting, finishing or using CPU, Windows Update events (download, install started, installed, failed with the code explained), the Setup log growing, a restart becoming due. Quiet once a minute otherwise. Remote-safe.
  - HTML report `C:\Triage\Updates_<PC>_<time>.html` with the last dozen history entries and every update policy value found. `-Quiet` + exit code 1 on a FAIL for RMM monitors.
- Windows Update reset's README now points at the status tool first: a reset clears the history it reads and doesn't fix a pin, a pause, a dead WSUS or a safeguard hold.
- Ideas for the checks came from reading Killer Tools' scripts and KillerBench (GPLv3 / no licence file, so no code was copied).

### Fixed (before release)
- Pause start dates (`2026-11-10`) are calendar days. Treating them as UTC midnight showed the day before in any time zone west of UTC; found by running the harness under New York time.

### Tests
- Get-WindowsUpdateStatus, 158 checks with a harness faking the registry, the Windows Update agent (COM), event logs, Setup files, processes, services and the clock. Covered:
  - Healthy 25H2 Pro.
  - Support: 24H2 Pro out of support, 24H2 Enterprise, 23H2 Education, LTSC 2024, Windows 10 22H2 with and without ESU patches, old Windows 10, Windows 10 LTSC 2021 (not guessed), 26H2 (not in the table), 72 days before end of support, Server, N editions.
  - Updates: last patch and scan thresholds; failures repeated, single, aborted, fixed later, failing again, older than `-Days`, uninstalls, unknown codes (Win32 and not), more than five, no KB in the title, the 300-entry cap, the event-log fallback, connection events.
  - Policy: Intune with and without the MDM marker, RMM agents, Intune plus an RMM agent, NoAutoUpdate, AllowAutoUpdate 5, notify-only, every kind of pause (live and expired), deferrals with and without the GPO switch, pins (out-of-support, supported, forward, Windows 10, switched off), WSUS answering / not answering / not a URL / not in use.
  - Services: disabled, missing and optional ones. Disk thresholds, no disk and CIM failure.
  - Upgrade: Red with each reason, UpgExU, Windows 10 keys ignored, plain key over ...Setup, safeguard holds, Orange, Yellow, no data. CompatData: hard blocks (hardware and app, namespaced XML), drivers that won't migrate, old, pre-install, clean, unreadable. SetupDiag: XML with and without remediation, old, registry fallback, unknown values, no date.
  - Activity, ordering, `-Quiet`, the HTML (escaping, sections, footer), ASCII-only console output, and `-Watch`: start, CPU, events once each, Setup log growth, restart due, finish, heartbeats.
- Run under UTC, New York and Tokyo time. Fifteen key behaviours were broken on purpose (later success clears a failure, pause expiry, the Intune marker, plain readiness key, HTML escaping, Windows 10 targets, pin matching, ESU, LTSC, N editions, UTC conversion, events once, patch thresholds, calendar dates, the GPO deferral switch); each was caught.
- Rendered the HTML report in headless Chrome and checked it.

## 1.10.1 - 2026-11-10

### Fixed
- **OneDrive reset listed an account that wasn't there.** OneDrive can leave a `Personal` key under `HKCU\Software\Microsoft\OneDrive\Accounts` holding only a placeholder folder (`%UserProfile%\OneDrive`) and no address. The tool showed it as `Personal (no address recorded)` and would have told the tech to sign it back in. A key now only counts as a signed-in account when it has an email address. Found by running `-CheckOnly` on a real Entra-joined laptop; the exe, work account, synced library and policies it found there were all right.

### Tests
- Reset-OneDrive harness, 63 checks: the laptop's exact `Personal` key, that it stays out of the sign-in advice, and keys with folders but no addresses (no accounts, so no libraries). Putting the old rule back fails two of them.

## 1.10.0 - 2026-11-10

### Added
- **OneDrive reset** (`Reset-OneDrive`, Repair). Microsoft's `OneDrive.exe /reset` for the signed-in user, without trying each path by hand:
  - **Finds the right OneDrive.exe:** the copy that's running, then the one registered for the user, then Microsoft's three paths (per-user `%LOCALAPPDATA%`, `Program Files`, `Program Files (x86)`).
  - **Shows what's connected first:** version, per-user or per-machine, the work and personal accounts with their folders, SharePoint / Teams libraries synced outside the OneDrive folder, and the policies that matter afterwards (silent sign-in, known folders moved to OneDrive, libraries added by policy).
  - **Resets it, then checks:** the old OneDrive closed, and OneDrive started again within 2 minutes. If it doesn't come back by itself, the tool starts it.
  - **Says what's left:** who signs in again, "Use this folder", choose folders, and which libraries to sync again.
  - No files are deleted. `-CheckOnly` shows everything and changes nothing.
- It runs as the user and stops if it's elevated (an admin window, an admin's remote session or SYSTEM), because OneDrive won't start with full admin rights. It also stops if someone else is signed in at the PC, unless `-Force`. On a terminal server only this user's OneDrive is touched.
- `Test-RunningAsAdmin` in the shared helpers.

### Tests
- Reset-OneDrive, 61 checks with a harness faking processes, the registry, Windows paths and the shared helpers:
  - A normal reset; check only; elevated, with and without `-Force`; someone else signed in, with and without `-Force`; not installed.
  - Picking the exe: running beats registered beats default, a quoted registered path, a registered value that isn't OneDrive.exe, only the x86 copy, another session's OneDrive ignored and left running.
  - After the reset: comes back by itself, doesn't (started by the tool, start fails, start throws), the reset process carries on running, the old OneDrive won't close, the reset won't start, `-WaitSeconds`.
  - Accounts and policies: none, a leftover key, an account with no address, policies on and off (including per-user auto-mount), libraries de-duplicated across both registry lists, shortcuts inside OneDrive left out, non-path values ignored, long lists cut at 15.
  - Six key behaviours were broken on purpose (elevated guard, shortcut filter, starting it twice, session filter, old-instance check, running copy first); each was caught.

## 1.9.0 - 2026-11-10

### Added
- **Before / after comparison** (`Compare-DeviceReport`, Diagnose). Run the checks before and after the work, then this: it reads every Quick triage, Performance check, Wi-Fi and battery report already saved for the PC in `C:\Triage` and writes one page for the ticket:
  - **What changed:** fails and warnings from the first run to the latest, build changes and restarts in between, and each check that was fixed, is no longer reported, got better, got worse, is new or is unchanged, first and latest detail side by side.
  - **The numbers** for every run: CPU, disk, memory, paging, start-up times, free space, pending restart, startup apps, drivers and BIOS from Performance check; last update, shutdowns, blue screens, crashes, memory, CPU, join type and Intune from Quick triage. The first and latest five runs when there are more.
  - **Worth knowing:** notes that only show across the reports, most important first. A first run caught mid-update, a run busy just after start-up, an idle after-run, sign-in getting slower, new startup apps (Edge's Startup boost), classic Teams still starting, slow start-ups left over from updates, space taken by updates, no battery plus unexpected shutdowns, months without updates on a PC that isn't in Intune (naming the RMM agent if there is one), Quick triage older than the work, and LMS.exe crashes.
  - **Still needs attention:** everything WARN or FAIL in the latest reports, FAILs first, with each fix. Quick triage items a newer Performance check found fine are left out.
  - **Wi-Fi and battery:** sessions, drops and reasons, network and signal, adapter driver age, how long the adapter took after start-up, DNS servers, saved networks, and whether Location services hid the details; battery capacity and cycles.
  - Named after the PC (**PC-1234 report**, saved as `Report_<PC>_<time>.html`), with a one-line summary for the ticket, an optional ticket number, and links to every report it read.
- Read-only. It finds reports by name, so it works on reports made before it existed. Nothing is sent anywhere: the write-up comes from rules in the script.

### Tests
- Compare-DeviceReport, 75 checks with a harness: five real reports from a Latitude 7490 (before, overnight, after a restart, plus Quick triage and Wi-Fi), and made-up reports for no reports, other PCs only, one run, things getting worse or new, a FAIL turning into a WARN, eight runs, reports older than `-Days`, comma-decimal and dot-thousands numbers, HTML in report text, two checks with the same name, Quick triage pairs, a Wi-Fi report with Location on, a worn battery, stray files and earlier comparisons in the folder, and `-Path`. Six key behaviours were broken on purpose (WARN not counted, stale triage items kept, HTML not escaped, comma decimals misread, notes unranked, every run shown); each was caught.

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
