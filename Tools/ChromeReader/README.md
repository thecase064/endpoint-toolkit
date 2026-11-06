# Install-ChromeAndReader.ps1

Silently installs the latest **Google Chrome** (Enterprise MSI) and **Adobe Acrobat Reader 64-bit**
(full offline installer), with Adobe's cloud / Express / AI Assistant / upsell components disabled.

---

## Quick start

1. Save `Install-ChromeAndReader.ps1` to `C:\Scripts`.
2. Open PowerShell **as Administrator**.
3. Run:

```powershell
Set-Location C:\Scripts
powershell.exe -ExecutionPolicy Bypass -File .\Install-ChromeAndReader.ps1
```

If the file came from a browser download, unblock it first:

```powershell
Unblock-File C:\Scripts\Install-ChromeAndReader.ps1
```

---

## Parameters

| Parameter | Values | Default | Notes |
|---|---|---|---|
| `-Apps` | `Chrome`, `Reader`, `Both` | `Both` | Pick one or install both |
| `-Language` | `MUI`, `en_US`, `en_GB`, etc. | `MUI` | Reader installer language pack |
| `-SkipHardening` | switch | off | Installs Reader but leaves default config alone |

Examples:

```powershell
.\Install-ChromeAndReader.ps1 -Apps Reader -Language en_US
.\Install-ChromeAndReader.ps1 -Apps Chrome
.\Install-ChromeAndReader.ps1 -SkipHardening
```

---

## What it does

**Chrome**
- Pulls `googlechromestandaloneenterprise64.msi` from Google — that URL always serves current stable.
- Checks the signature (see below), then reads the version from the MSI itself and skips if that
  version is already installed.
- Installs with `/qn /norestart`.

**Adobe Reader**
- Queries Adobe's release feed for the current 64-bit build, then downloads the **offline** installer
  direct from `ardownload2.adobe.com`. The consumer web stub is what bundles McAfee and browser
  offers — the offline exe never has them.
- Checks the signature (see below).
- Installs with `/sAll /rs /rps /msi /quiet EULA_ACCEPT=YES REMOVE_PREVIOUS=YES DISABLEDESKTOPSHORTCUT=1`.

**Signature check** (both apps, before anything runs)
- Windows must report the installer's signature as **Valid**: signed, not changed since, and chained
  to a trusted root.
- The signing certificate's organisation (`O=`) must be exactly **`Google LLC`** for Chrome and
  **`Adobe Inc.`** for Reader. A renewed certificate still passes; a look-alike name doesn't.
- Anything else is deleted and not installed, and the log says what it was actually signed by.
- If one app is refused or fails, the other still installs, and the script exits `1`.

**Post-install hardening** (skip with `-SkipHardening`)
- Writes `HKLM\SOFTWARE\Policies\Adobe\...\DC\FeatureLockDown` to disable:
  Document Cloud, cloud storage, settings sync, Dropbox/Drive/OneDrive connectors, Adobe Sign,
  Send & Track, Acrobat Pro upsell, and AI Assistant (`bEnableGentech`).
- Deletes the force-installed Acrobat browser extension key for Chrome and Edge.
- Disables `AGSService` / `AGMService` (Adobe Genuine). Leaves `AdobeARMservice` running so
  security updates still land.

---

## Two things to decide before wide deployment

- **`bDisableJavaScript = 1`** is set as hardening. Some interactive PDF forms (HSE, Revenue,
  council forms) break with JS off. Delete that line from `Set-ReaderPolicy` if you hit it.
- **`bUpdater = 1`** leaves Reader self-updating. Set to `0` if you patch centrally instead.

---

## Logs and exit codes

- Logs: `C:\ProgramData\AppDeploy\Logs\Install-ChromeAndReader_<timestamp>.log`
- MSI verbose logs: `Chrome_msi.log` and `Reader_msi.log` in the same folder
- Exit `0` = everything asked for is installed or already current
- Exit `1` = an app failed to download, failed the signature check or failed to install (reason in the log)
- MSI exit `3010` is treated as success — reboot pending

---

## Deploying via Intune

**Option A — Platform script** (Devices > Scripts and remediations > Platform scripts)
- Run as: **System**
- Run script in 64-bit PowerShell: **Yes**
- Enforce script signature check: **No**

**Option B — Win32 app**

Package with `IntuneWinAppUtil.exe`, then:

```
Install command:
  powershell.exe -ExecutionPolicy Bypass -File .\Install-ChromeAndReader.ps1

Uninstall command:
  powershell.exe -ExecutionPolicy Bypass -Command "Get-Package 'Adobe Acrobat*','Google Chrome*' | Uninstall-Package -Force"

Install behaviour: System
```

Detection rules — add one per app:

| Rule type | Path | Value |
|---|---|---|
| Registry | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` | key exists for `Google Chrome` |
| Registry | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` | key exists for `Adobe Acrobat` |

Or use a file-based rule against
`C:\Program Files\Google\Chrome\Application\chrome.exe` and
`C:\Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Adobe release API unreachable` warning | Feed timed out; the pinned fallback build in `Get-ReaderDownload` is used. Update that version string occasionally. |
| Reader download 404s | Language code doesn't exist for that build. Fall back to `-Language MUI`. |
| `failed the signature check` | Don't override it. `status: HashMismatch` means the file was changed or cut short; retry the download. `NotTrusted` / `UnknownError` usually means Windows can't build the certificate chain, e.g. root certificates missing on an image that's never been online or has root certificate updates blocked. A different `signed by:` name means either the vendor renamed itself (check, then update the name in the script) or the download isn't from the vendor. |
| Exit code 1603 on Reader | Usually an existing Reader/Acrobat install mid-repair. Reboot, then rerun. |
| Script won't run | `Unblock-File` it, and confirm you're in an elevated session. |
| Chrome skipped unexpectedly | Already at current stable. Force with `-Apps Chrome` after uninstalling, or ignore. |
