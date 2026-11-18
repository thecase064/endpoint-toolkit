# Error code explainer

For "what does 0x800F0922 mean?". Paste a code, several codes, or the whole error message, and it finds every code in it and explains each one. Offline: nothing is looked up online, nothing is changed.

**It understands:** `0x80070005`, `80070005` (how logs often print it), `-2147024891` and `2147942405` (the same code in decimal), Setup pairs like `0xC1900101 - 0x40017`, `code 43`, `error 1603`, `exit code 3010`, a number on its own, and `AADSTS700003`. GUIDs in the text (correlation IDs) are ignored.

| For each code | Where it comes from |
|---|---|
| **What the toolkit knows**, with what to do | Windows Update / upgrade results, Windows Time errors, Device Manager problem codes, Dell Command \| Update and HP Image Assistant exit codes, Entra join errors (`Tools\Shared\ErrorCodes.psd1`, the same notes the other tools show) |
| **Windows' own name and message** | `certutil -error`, built into Windows (e.g. `ERROR_ACCESS_DENIED - Access is denied.`). If certutil isn't there, Windows' message via .NET. |
| **NTSTATUS codes** (`0xC0000005`, `0xC000007B`...) | Windows' own mapping to the error it reports for them (`RtlNtStatusToDosError`), since certutil doesn't cover these |
| **What the number itself says** | A Windows (Win32) error wrapped as an HRESULT (`0x8007xxxx`), the facility it comes from (Windows Update, BITS, Setup, BitLocker...), or a vendor's own code |
| **Setup phase and operation** | The extend code after the dash in upgrade failures, e.g. `0x40017` = second boot (OOBE) phase, during BOOT |
| **Blue screen stop codes** | The name and the usual cause, e.g. `0x0000007E` = SYSTEM_THREAD_EXCEPTION_NOT_HANDLED (also the `0x1000007E` variant) |

## Run

- Menu: **Diagnose > Error code explainer** (it asks for the code or message)
- Command: `Resolve-ErrorCode 0x800F0922`, or `Resolve-ErrorCode 'paste the whole message here'`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Resolve-ErrorCode.ps1 0x800F0922`

| Parameter | Effect |
|---|---|
| `-Code` (or just the codes after the command) | One or more codes, or text containing them |
| `-Quiet` | One line per code: the code and its best explanation |
| `-PassThru` | Return one object per code |

## Good to know

- **A number on its own can mean different things.** `43` is a Device Manager problem code and also Windows error 43; `1` is a Dell exit code and also a Device Manager code. It shows every match, each labelled with where it's from.
- **Unknown codes still get decoded.** Even when nothing knows the code, it says what kind it is and which component it came from, which narrows the search.
- **To teach it a code**, add a line to `Tools\Shared\ErrorCodes.psd1` (see `Tools\Shared\README.md`).
- **Some codes on their own aren't enough**: `0xC1900101` means "rolled back because of a driver", and the extend code after the dash says when. If you only have the first half, the Windows Update status tool shows SetupDiag's result when there is one, which usually has the rest.
- No admin needed. Exit codes: `0` = explained at least one code, `1` = no code found in the input.
