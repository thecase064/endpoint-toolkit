# Windows Update reset

The classic fix for updates stuck downloading, failing with the same error every night, or "Something went wrong" in Settings.

1. **Checks the usual real causes first** and says so: a reboot already pending, the device pointed at a WSUS server, or under 10 GB free on the system drive.
2. Stops `wuauserv`, BITS, `cryptsvc`, `msiserver`, `UsoSvc` and Delivery Optimization.
3. Renames `C:\Windows\SoftwareDistribution` and `C:\Windows\System32\catroot2` to `*.old-<timestamp>`. They're **renamed, not deleted**, so you can put them back. It retries if `cryptsvc` restarts itself mid-rename (it does).
4. Optionally resets Winsock (`-ResetNetwork`).
5. Starts the services again and triggers an update scan.

The update history list in Settings starts empty afterwards. The updates themselves stay installed.

## Run

- Menu: **Repair > Windows Update reset**
- Command: `Reset-WindowsUpdate`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Reset-WindowsUpdate.ps1`

| Parameter | Effect |
|---|---|
| `-ResetNetwork` | Also `netsh winsock reset`. Only for updates that won't download at all. Needs a reboot. |
| `-RemoveOldCopies` | Delete `.old-*` folders from earlier runs (this run's copies are kept) |
| `-NoScan` | Don't trigger a scan at the end |

## Exit codes

`0` = done, `3010` = done, reboot needed, `1` = a step failed. Log: `C:\ProgramData\WindowsUpdateReset\`
