# M365 Apps reset + reinstall

Removes every Office install on the machine and puts a clean copy of Microsoft 365 Apps back. It's built for new laptops that arrive with OEM Office stubs and a stack of language packs, and for broken Office installs that a repair won't fix.

**Phase 1: remove**
1. Closes every Office app.
2. Removes the Microsoft Store Office stubs (Office Hub / desktop app stubs), plus the preinstalled new Outlook app if you ask (`-RemoveNewOutlook`).
3. Downloads the latest **Office Deployment Tool** from Microsoft's Office CDN and **checks it's signed by Microsoft** before running it.
4. Runs an ODT "remove all", which also strips old MSI-based Office.
5. Optional `-DeepClean`: runs Microsoft's **Get Help** Office scrub for broken or orphaned installs ODT can't see (details below).

**Phase 2: install**
- Reinstalls Microsoft 365 Apps silently with the product, channel, language and bitness you choose. The default is Business, Current channel, en-GB, 64-bit.

## Run

- Menu: **Build > M365 Apps reset + reinstall**. It asks for the product and whether to deep clean.
- Command: `Reset-M365Apps`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Reset-M365Apps.ps1`

| Parameter | Effect |
|---|---|
| `-ProductID` | `O365BusinessRetail` (default: Business Standard / Premium) or `O365ProPlusRetail` (enterprise: E3 / E5) |
| `-Channel` | `Current` (default), `MonthlyEnterprise` or `SemiAnnual` |
| `-Language` | Default `en-GB` |
| `-Bitness` | `64` (default) or `32` |
| `-DeepClean` | Also run Microsoft's Get Help Office scrub after the ODT removal. Slower. |
| `-SkipInstall` | Remove only, don't reinstall |
| `-RemoveNewOutlook` | Also remove the preinstalled new Outlook Store app |

Example: `Reset-M365Apps -ProductID O365ProPlusRetail -DeepClean -RemoveNewOutlook`

## What to expect

- Removal takes a few minutes. The reinstall then downloads about **3–4 GB** from Microsoft's CDN with no installer window, so allow **10–20 minutes** on normal broadband. It hasn't hung; watch the console.
- It's done when you see two green lines: `Installed: O365BusinessRetail` (or ProPlus) and a `Version:` number. If you get a yellow warning about the ClickToRun key instead, check the log.
- **Restart**, then open Word or Outlook and sign in with the user's account to activate.

## Deep clean (Microsoft Get Help)

`-DeepClean` runs `GetHelpCmd.exe -S OfficeScrubScenario -AcceptEula -OfficeVersion All`. Get Help is Microsoft's replacement for the old SaRA command line, which Microsoft removed from Windows in March 2026.

- It's **downloaded fresh every run** (Microsoft's builds expire after 90 days) and is only run if it's **validly signed by Microsoft**. The download is deleted afterwards.
- Office apps are closed again first, because Get Help refuses to run with any open.
- Get Help's result codes are shown in plain English: 00 = scrubbed; 66/68 = nothing left (ODT already got it all); 06 = an Office app was still open; 09 = it couldn't remove Office, so try the Get Help app.
- Its output is saved to `C:\OfficeReset\GetHelp_<time>.log`.

## Logs

Everything goes to `C:\OfficeReset\`: the full transcript (`OfficeReset_<time>.log`), the Get Help output, and the ODT config files used.

## Needs

- An **elevated** PowerShell session. It refuses to run otherwise.
- **Internet access.** Both phases download from Microsoft directly, so nothing needs pre-staging.
- The **Shared** folder next to this one (`Tools\Shared\Helpers.ps1`), which holds the Get Help download and signature check. It's always there when you run from the toolkit. If you copy this script somewhere on its own, take `Tools\Shared` with it.
