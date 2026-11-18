# Toolkit cleanup

For leaving a PC as you found it once the work's done. It lists everything Endpoint Toolkit has saved on the PC, with sizes, and deletes the groups you tick after one more yes. With nothing ticked it only lists.

| Group | What's in it | Ticked by default |
|---|---|---|
| **Reports and logs** | `C:\Triage` reports (triage, performance, Wi-Fi, battery, Windows Update status, comparisons), build reports and logs (`C:\ProgramData\DeploymentMaster`), tool logs in ProgramData (McAfee, debloat, OEM updates, Chrome + Reader, Office activation, Windows Update reset), `C:\OfficeReset` logs, device inventory, disk usage reports, Entra / Intune log bundles, M365 reports in Documents | No |
| **The toolkit itself** | The downloaded copies in `C:\ProgramData\EndpointToolkit` (and the Graph module cache), the installed module (`Documents\WindowsPowerShell\Modules\EndpointToolkit`, `Documents\PowerShell\Modules\EndpointToolkit`), saved licence names, Event triage mutes, and downloads or working files a tool left behind (Office Deployment Tool, Get Help, temp files) | No |
| **Driver backups** | Driver export's backups in `C:\DriverExport` (folder and zip). They're the restore point for a rebuild | No, and warned |
| **Windows Update reset backups** | The `SoftwareDistribution.old-*` and `catroot2.old-*` folders Windows Update reset sets aside. They're its undo | No, and warned |

## Run

- Menu: **Toolkit > Toolkit cleanup (remove its data)**, the last item
- Command: `Remove-ToolkitData` (list only), `Remove-ToolkitData -Reports -Toolkit`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Remove-ToolkitData.ps1 -Reports`

| Parameter | Effect |
|---|---|
| `-Reports` | Delete the reports and logs |
| `-Toolkit` | Remove the toolkit itself. Started from the toolkit window or console menu, that closes once this succeeds |
| `-DriverBackups` | Also delete the driver backups in `C:\DriverExport` |
| `-UpdateBackups` | Also delete Windows Update reset's old folders |
| `-Yes` | Delete without asking, for the RMM. Without it, a run that can't ask (a remote shell) deletes nothing |
| `-Quiet` | One summary line |
| `-PassThru` | Return what was found and deleted as objects |

## What it won't touch

- **Anything that isn't the toolkit's.** It only deletes what the tools create, matched by the names they use (`Tools\Shared\ToolkitData.psd1`). Your own files in `C:\Triage`, a spreadsheet in `M365Reports`, other modules, Dell's own `ProgramData\Dell`, the live `SoftwareDistribution` and `catroot2`: all listed as "not the toolkit's, left alone" where they share a folder, and never deleted.
- **A folder that still has something in it.** Folders are removed only once they're empty.
- **What a link points to.** Junctions and symlinks are removed as links, never followed.
- **Reports saved somewhere else** with a tool's `-ReportFolder` / `-OutputFolder`. It only knows the default places.
- **Other accounts' files.** Documents, AppData and Temp are those of the account running it. Run with a UAC prompt for a different admin account, that's the admin's, not the signed-in user's.
- **A local copy you run it from** (a clone, a USB stick): only the toolkit's known places are cleaned.

## Good to know

- **Needs admin** for anything in `C:\` or ProgramData; without it, it lists, says so and deletes nothing.
- **Removing the toolkit from the window:** the cleanup runs in its own PowerShell window like every tool. Read the result, press Enter, and the toolkit window closes too. To use it again, run the one-liner again.
- **"Couldn't be deleted"** is usually a file in use: close what has it open (or restart) and run it again.
- Exit codes: `0` = done (or listed only, or nothing to delete), `1` = something couldn't be deleted, or it needs admin, `2` = you said no.
- Console only, no log file: keep a transcript if you need one.
