# OEM debloat (HP / Dell)

Removes OEM consumer bloat and Windows consumer apps from fresh HP and Dell builds. It keeps the tooling worth having: Dell SupportAssist, HP Support Assistant, hotkey/Fn, audio and system drivers, Teams, Copilot and the Office apps.

Everything is list-driven. The `$Remove*` lists near the top say what goes, and anything matching a `$Keep*` pattern is protected even if it also matches a remove pattern. Edit the lists, not the logic.

## Run

- Menu: **Build > OEM debloat**. It asks whether to do a dry run first (default yes).
- Command: `Invoke-BuildDebloat -DryRun`, then `Invoke-BuildDebloat`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Invoke-BuildDebloat.ps1 -DryRun`

Always dry-run a new model first.

## Parameters

| Parameter | Effect |
|---|---|
| `-DryRun` | Log what would be removed, change nothing |
| `-Force` | Attempt silent uninstall of EXE apps with no known silent switch (otherwise they're logged for manual handling) |
| `-SkipAppx` | Skip the Store/AppX section |
| `-SkipTweaks` | Skip the registry tweaks (applied to the default user profile too, so new profiles inherit them) |
| `-LogPath` | Override the log location |

Log: `C:\ProgramData\Debloat\debloat-<timestamp>.log`. Reboot afterwards.
