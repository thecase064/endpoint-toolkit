# Shared helpers

Not a tool, and not in the menu. `Helpers.ps1` holds code that several tools load, and `ErrorCodes.psd1` the error codes they explain, so each lives in one place.

## Helpers.ps1

| Function | Used by | What it does |
|---|---|---|
| `Get-CurrentUserName` | the tools below | The account running the tool |
| `Get-CurrentUserSid` | Old user profile cleanup, Audio check | Its SID (`S-1-5-18` when it's SYSTEM) |
| `Resolve-AccountSid` | Old user profile cleanup | `DOMAIN\name` for a SID, or nothing when Windows can't name it (a deleted account, no domain controller in reach, an Entra account it hasn't cached) |
| `Get-LicenseNameMap` | M365 licence report, Exchange + Planner usage | Microsoft's own product names for licences (`SPB` -> Microsoft 365 Business Premium), from the CSV behind "Product names and service plan identifiers for licensing". Downloaded from download.microsoft.com at most once a week into `%LOCALAPPDATA%\EndpointToolkit\LicenseNames.csv`; the saved copy is used when the download fails. Keyed by part number and SKU id. |
| `Get-OtherSignedInUser` | Office activation reset, Teams cache clear, Teams Meeting add-in fix, OneDrive reset, Audio check | Returns the signed-in user when that's not the account running the tool, so per-user fixes can warn or stop |
| `Get-GetHelpCmd` | M365 Apps reset (`-DeepClean`), Office activation reset | Downloads Microsoft's Get Help command line, unpacks it and refuses it unless it's validly signed by Microsoft |
| `Invoke-GetHelpScenario` | the same | Runs one Get Help scenario from its own folder, shows and logs the output, returns the result code |
| `Clear-GetHelpDownload` | the same | Removes the download afterwards |

Get Help replaced the SaRA command line, which Microsoft removed from Windows in March 2026. Microsoft says each build stops working 90 days after it's made, so it's downloaded fresh every run and never committed to this repo.

Tools load it with:

```powershell
. (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')
```

## ErrorCodes.psd1

Every error code the toolkit explains, in one data file (no code runs when it's read): what it means, where it comes from and what to do. The Error code explainer reads it; so can anything else.

| Section | What's in it | Where it came from |
|---|---|---|
| `Codes` | Windows Update / upgrade results, Windows Time errors, Device Manager problem codes, Dell Command \| Update and HP Image Assistant exit codes, Entra join errors | The tools' own tables. `tests/Test-Repo.ps1` checks each tool's table still matches this file, so **change a meaning in the tool and here together** (the test says which). |
| `Facilities` | HRESULT facility numbers and what they are | Microsoft's `winerror.h` |
| `SetupPhases`, `SetupOperations` | The two halves of a Windows Setup extend code (`0xC1900101 - 0x40017`) | Microsoft's "Windows upgrade error codes" page |
| `StopCodes` | Common blue screen stop codes: the name and the usual cause | Microsoft's bug check reference |

To add a code, add a line to `Codes` with `Code` (`0x`-hex, plain digits, or text like `AADSTS50076`), `Source`, `Meaning` and `Fix`.
