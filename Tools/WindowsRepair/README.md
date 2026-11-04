# Windows repair checks

The standard self-repair sequence, in order, with a progress bar and coloured step headers:

1. `DISM /Online /Cleanup-Image /RestoreHealth` repairs the component store
2. `sfc /scannow` repairs protected system files from it
3. `DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase` clears superseded components

It stops at the first failure and shows the step and exit code. DISM's 3010 (success, reboot pending) counts as success. On a clean finish it prints `CHECKS COMPLETE - PLEASE RESTART SYSTEM`.

## Run

- Menu: **Repair > Windows repair checks**
- Command: `Invoke-WindowsRepairChecks`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\WindowsRepairChecks.ps1`

## Note

`/ResetBase` makes currently installed updates permanent: they can't be uninstalled afterwards. If you might need to roll back a bad update, run steps 1 and 2 by hand and skip step 3.
