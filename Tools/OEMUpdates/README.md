# OEM driver + BIOS updates (Dell / HP / Lenovo)

Gets driver, firmware and, if you ask, BIOS updates from the manufacturer, using the vendor's own updater. It works out which vendor made the machine and drives the right tool:

| Make | Updater | Notes |
|---|---|---|
| Dell | Dell Command \| Update (`dcu-cli.exe`) | Installed from winget (`Dell.CommandUpdate.Universal`) if missing |
| HP | HP Image Assistant | HP **business** PCs only (EliteBook, ProBook, ZBook, Elite/Pro desktops). Consumer models get "not supported" and should use HP Support Assistant. Installed from winget (`HP.ImageAssistant`) to `C:\SWSetup` if missing |
| Lenovo | [LSUClient](https://github.com/jantari/LSUClient) PowerShell module | Community module (MIT licence, millions of installs) that uses Lenovo's own update catalogue, the same one Lenovo System Update uses. Installed from the PowerShell Gallery if missing |

Anything else (VMs, other brands) gets told to use Windows Update's optional driver updates.

## What it does

1. **Scans** for drivers and firmware. BIOS is only included with `-IncludeBios`.
2. **Lists** what it found: name, version, type, severity, and the vendor's ID for each update.
3. **Asks before installing.** `-Install` skips the question; `-ScanOnly` just lists.
4. **Installs**, then says whether a restart is needed. **It never restarts the machine itself.**

If the vendor's updater isn't installed, it **asks before installing it**. `-InstallTool` allows that without asking, for unattended runs. Unattended without `-InstallTool`, it stops and says what's missing.

## BIOS updates

- Off by default. Tick it in the menu or use `-IncludeBios`.
- **BitLocker is suspended for one restart** so the BIOS flash doesn't trigger a recovery key prompt. Dell Command Update and LSUClient do this themselves; for HP the tool does it. It resumes on its own after the restart.
- **Plug the charger in.** Vendors refuse to flash a BIOS on battery, and the tool warns if you're on battery.
- **BIOS passwords:** if the machine has a BIOS admin password set, the vendor flash will usually fail. Clear it or update the BIOS by hand.
- Some Lenovo BIOS updates need a full **shutdown**, not a restart, to apply. The tool says which.

## Run

- Menu: **Build > OEM drivers + BIOS** (asks whether to include BIOS)
- Command: `Invoke-OEMUpdate`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Invoke-OEMUpdate.ps1`

| Parameter | Effect |
|---|---|
| `-IncludeBios` | Include BIOS/UEFI updates |
| `-Install` | Install what the scan finds without asking |
| `-ScanOnly` | List only. Exit code `2` if updates are waiting, so it works as an RMM or Intune detection check |
| `-InstallTool` | Install the vendor's updater if missing, without asking |
| `-LogFolder` | Logs and vendor reports. Default `C:\ProgramData\OEMUpdates` |
| `-ResultFile` | Also write the outcome as JSON: make, model, the updates found (or installed), exit code and the last problem. New device setup uses it for its build report |

Unattended example (RMM): `Invoke-OEMUpdate -Install -InstallTool`. Add `-IncludeBios` only if you're happy for BIOS updates to be staged for the next restart. New device setup runs exactly this (no BIOS) as its driver step, then `-ScanOnly -IncludeBios` to list what's left in its build report.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Up to date, or updates installed |
| `3010` | Updates installed, restart (or shutdown) needed |
| `2` | Updates available but not installed (`-ScanOnly`, or you said no) |
| `1` | Something failed, the vendor tool is missing, or it isn't a Dell/HP/Lenovo |

Each vendor's own result codes are translated into plain English (e.g. Dell 5 = "a restart is already pending", HP 4096 = "model not supported"). The full output is in the log.
