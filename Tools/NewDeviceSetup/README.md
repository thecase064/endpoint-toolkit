# New device setup

The whole new-laptop build in one pass, ending with an HTML build report for the ticket.

| # | Step | Script | Notes |
|---|---|---|---|
| 1 | Intune primary user | `IntunePrimaryUser\Set-IntunePrimaryUser.ps1` | Only if you give a user (or ask to remove it). Runs first, so you sign in while you're at the PC. |
| 2 | McAfee removal | `McAfeeRemoval\AVNuke.ps1` | |
| 3 | OEM debloat | `OEMDebloat\Invoke-BuildDebloat.ps1 -Force` | |
| 4 | Microsoft 365 Apps | `M365Reset\Reset-M365Apps.ps1 -ProductID O365BusinessRetail` | The long one: a 3-4 GB download. |
| 5 | Chrome + Reader | `ChromeReader\Install-ChromeAndReader.ps1` | |
| 6 | Dell / HP / Lenovo drivers | `OEMUpdates\Invoke-OEMUpdate.ps1 -Install -InstallTool` | Drivers and firmware, never BIOS. Installs the vendor's updater if needed. Other makes are skipped. |

Each step runs in its own PowerShell process. A failed step doesn't stop the build; every step runs and its result goes in the report. Output shows live in the console as before, and is also saved for the report (step 1's sign-in is shown live only).

Then it checks what's left, writes the report, opens it, and restarts the PC after a 60-second countdown.

## Running it

From the toolkit: **New device setup**. It asks for:

| Option | Default |
|---|---|
| Ticket number | blank (optional) |
| Your name | the Windows account running it |
| Intune primary user to set (their sign-in address) | blank = leave it alone |
| Or remove the Intune primary user (shared device) | off |
| Skip the Dell / HP / Lenovo driver updates | off |
| Skip the automatic reboot | off |

By hand, from an elevated PowerShell:

```powershell
Invoke-NewDeviceSetup -Ticket 48213 -PrimaryUser jane.doe@contoso.com
.\Invoke-NewDeviceSetup.ps1 -SkipReboot -NoOpen
```

If you set a primary user, Microsoft's sign-in window appears within the first minute. Sign in as a tenant admin (Intune Administrator or Help Desk Operator); MFA works as normal. After that you can walk away. A wrong address, or asking to set and remove at once, is caught before anything runs.

## The build report

Saved to `C:\ProgramData\DeploymentMaster\Reports\BuildReport_<PC>_<date>.html`, with the same data as `.json` beside it. It opens at the end. **Print or save as PDF** puts it on the ticket, with all step output expanded.

- **At the top:** OK or "N steps need a look", plus tiles for steps OK, Windows updates waiting, vendor updates waiting and restart pending.
- **Build:** ticket, technician, the account it ran as, start, finish, time taken, toolkit version, logs folder.
- **Steps:** each with what it does (the same brief as the menu), result, exit code, time taken and its output (collapsed). The primary user step shows who it was and who it is now. The driver step lists what it installed.
- **Still to do:**
  - Windows Update: Windows' own scan, read-only, drivers included; optional ones are marked.
  - The vendor's driver, firmware **and BIOS** updates still available (read-only scan; BIOS is never installed by the build).
  - Whether a restart is pending.
- **Device:** make, model, serial, BIOS, Windows build, Entra join, Intune enrolment, BitLocker (and whether a recovery key exists), TPM, Secure Boot, disk space.
- **Apps:** Microsoft 365 Apps, Chrome and Reader versions, and confirmation that McAfee is gone.
- **Notes:** a box to type in before printing.

The Windows Update scan gets 15 minutes. After that the report says it didn't answer, rather than holding up the build.

## Logs

| What | Where |
|---|---|
| This build's log | `C:\ProgramData\DeploymentMaster\Logs\MasterDeploy_<date>.log` |
| Each step's output and result files | `C:\ProgramData\DeploymentMaster\Logs\Build_<date>\` |
| McAfee removal | `C:\ProgramData\McAfeeRemoval\` |
| OEM debloat | `C:\ProgramData\Debloat\` |
| Microsoft 365 reset | `C:\OfficeReset\` |
| Chrome + Reader | `C:\ProgramData\AppDeploy\Logs\` |
| Vendor drivers | `C:\ProgramData\OEMUpdates\` |

## Before you run it

- Run it elevated, from the toolkit (it calls its sibling folders in `Tools\`).
- It needs internet: Office, Chrome, Reader, the vendor's updater and, when setting a primary user, Microsoft's Graph sign-in module. The module is cached while the build runs and deleted at the end.
- Expect 20-40 minutes. Office and driver installs are the slow parts and show little progress. It isn't stuck.
- **The PC restarts at the end.** `shutdown /a` in another window cancels the countdown. Use **Skip the automatic reboot** to stop it happening.

## Exit codes

`0` every step OK or skipped; `1` at least one step needs a look (the report says which), or the options were wrong and nothing ran.

## Changing the defaults

The steps' fixed options are in the `$steps` list in `Invoke-NewDeviceSetup.ps1`: Business licence for Office, debloat with `-Force`, no BIOS. For a one-off build that needs something different, run that tool on its own from the menu.
