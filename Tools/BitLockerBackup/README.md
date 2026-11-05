# BitLocker key backup check

BitLocker can show as on while its recovery key never reached Entra ID. Nobody notices until the day the device asks for its key and there isn't one to give. This check finds out before that day.

For every encrypted drive it takes each recovery password and looks in the BitLocker management event log for:
- a successful backup to Entra (event **845**)
- a failed one (event **846**, with the error explained where it's a known one: DNS, dropped connection, TLS)

| Result | Meaning |
|---|---|
| PASS | Backed up, with the date |
| FAIL | The last attempt failed, the drive has no recovery password at all, or the device isn't Entra joined |
| WARN | No backup on record, or the system drive isn't encrypted |

`-Fix` backs up every key with no successful backup on record, using `BackupToAAD-BitLockerKeyProtector`. Backing up a key that's already in Entra is harmless. In the menu it asks before fixing.

**The recovery passwords themselves are never shown or logged**, only their protector IDs.

## Run

- Menu: **Diagnose > BitLocker key backup check**
- Command: `Test-BitLockerKeyBackup` (add `-Fix` to back up)
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Test-BitLockerKeyBackup.ps1 -Fix`

| Parameter | Effect |
|---|---|
| `-Fix` | Back up every key that isn't proven backed up |
| `-Quiet` | Only a one-line summary, for RMM monitors or as an Intune remediation detection script (exit 1 = needs fixing) |

## Limits

- The event log is the device's own record and can roll over. "No record" means **not proven**, not definitely missing. The final word is Entra: **Devices > the device > BitLocker keys**.
- Backing up to Entra only works on Entra joined or hybrid joined devices. Domain-only devices keep their keys in AD.
- A drive encrypted with no recovery password has nothing to back up. The tool gives you the command to add one. It doesn't add it for you, because that changes the drive's protectors.

Exit codes: `0` = every key is backed up, `1` = something isn't (or couldn't be checked).
