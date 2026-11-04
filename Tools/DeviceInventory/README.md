# Device inventory

Everything you'd normally dig out of a dozen WMI classes, on one page.

| Section | What you get |
|---|---|
| System | Manufacturer, model (Lenovo marketing names, not machine types), serial, BIOS version and date, join state, logged-on user |
| OS | Edition, version (e.g. 24H2), full build, install date, last boot, uptime |
| CPU | Name, cores, threads, clock |
| Memory | Every stick: slot, size, type (DDR4 / DDR5 / LPDDR5...), form factor, speed, part number, plus slots used / total and max supported |
| Disks | Model, SSD / HDD, NVMe / SATA, size, health; wear %, temperature and power-on hours when elevated |
| Volumes | Size, free space, BitLocker status (elevated) |
| Monitors | Make, model, serial, year, connection (HDMI / DisplayPort / built-in) |
| Battery | Design vs full-charge capacity = health %, cycle count where the firmware reports it |
| Network | IP-enabled adapters: IPv4, MAC, gateway, DNS, DHCP |
| Security | Secure Boot, TPM (elevated) |

## Run

- Menu: **Diagnose > Device inventory**
- Command: `Get-DeviceInventory -Html`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Get-DeviceInventory.ps1 -Html`
- Remote: `Invoke-Command -ComputerName PC-1234 -FilePath .\Get-DeviceInventory.ps1`

| Parameter | Effect |
|---|---|
| `-Html` | Self-contained HTML report in `C:\DeviceInventory\`, opened when run locally |
| `-Json` | JSON alongside. Handy for diffing a machine before and after a rebuild |
| `-ReportFolder` | Change the output folder |
| `-PassThru` / `-Quiet` | Return the object, with or without console output |

Read-only, and fine as a standard user. Elevated adds disk wear, BitLocker, TPM and battery capacity. Each section fails on its own, so one broken WMI class doesn't sink the report.

## Gotchas

- Built-in laptop panels report the **panel maker** (CMN, AUO, BOE, LGD, SHP...) and often serial `0`. That's the panel, not a bug.
- Disk wear is what the drive reports as rated life used. Not every drive reports it.
