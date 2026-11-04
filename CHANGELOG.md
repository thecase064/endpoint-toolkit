# Changelog

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
