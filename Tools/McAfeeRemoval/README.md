# McAfee removal

Removes the McAfee consumer products Dell preloads, in all three forms they ship:

| Form | Examples | How it's removed |
|---|---|---|
| Microsoft Store (AppX) | McAfee Personal Security | `Remove-AppxPackage -AllUsers` + provisioned package |
| MSI | Safe Connect, suite components | `msiexec /x` from the uninstall registry |
| EXE | WebAdvisor, LiveSafe / MSC suite | vendor uninstaller with silent switches |

Services and processes are stopped first. Runs fully silent, so it's fine as SYSTEM from Intune or an RMM.

## Run

- Menu: **Build > McAfee removal**
- Command: `Remove-McAfee`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\AVNuke.ps1`

## Exit codes

| Code | Meaning |
|---|---|
| 0 | No McAfee found, nothing to do |
| 3010 | Removed, reboot recommended |
| 1 | Leftovers remain. Check the log, and use McAfee's MCPR tool for stubborn full suites |

Log: `C:\ProgramData\McAfeeRemoval\McAfeeRemoval_<date>.log`
