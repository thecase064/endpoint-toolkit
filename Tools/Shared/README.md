# Shared helpers

Not a tool, and not in the menu. `Helpers.ps1` holds code that several tools load, so it lives in one place:

| Function | Used by | What it does |
|---|---|---|
| `Get-CurrentUserName` | the tools below | The account running the tool |
| `Get-OtherSignedInUser` | Office activation reset, Teams cache clear, Teams Meeting add-in fix | Returns the signed-in user when that's not the account running the tool, so per-user fixes can warn or stop |
| `Get-GetHelpCmd` | M365 Apps reset (`-DeepClean`), Office activation reset | Downloads Microsoft's Get Help command line, unpacks it and refuses it unless it's validly signed by Microsoft |
| `Invoke-GetHelpScenario` | the same | Runs one Get Help scenario from its own folder, shows and logs the output, returns the result code |
| `Clear-GetHelpDownload` | the same | Removes the download afterwards |

Get Help replaced the SaRA command line, which Microsoft removed from Windows in March 2026. Microsoft says each build stops working 90 days after it's made, so it's downloaded fresh every run and never committed to this repo.

Tools load it with:

```powershell
. (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')
```
