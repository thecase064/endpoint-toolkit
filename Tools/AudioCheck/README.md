# Audio check

For "there's no sound" and "my mic doesn't work in Teams". It checks the usual causes in one go and says what to change. Read-only, no admin needed.

| Area | What it checks |
|---|---|
| **Services** | **Windows Audio** and **Windows Audio Endpoint Builder**: missing, disabled or not running. |
| **Playback** | No working output at all (with which ones are disabled or unplugged). **Which device is the default, its volume and mute.** Devices disabled in Sound settings or unplugged. Calls going to a different device from everything else. A Bluetooth headset in **hands-free (call) mode**, which sounds mono and tinny. |
| **Recording** | The same for microphones: none working, the default **muted** or at 0%, a very low level. |
| **Privacy** | Microphone access off for **the whole PC**, for **the signed-in user**, for **desktop apps** (classic Teams, Zoom, browsers) or for **new Teams**, and the Group Policy / Intune app-privacy setting. Other apps blocked from the mic are listed. |
| **Hardware** | Sound devices in Device Manager with a **problem code** (disabled, no driver, won't start), their driver versions and dates, and Windows' generic **High Definition Audio Device** driver standing in for the manufacturer's. |

## Run

- Menu: **Diagnose > Audio check (no sound / mic)**
- Command: `Get-AudioStatus`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Get-AudioStatus.ps1`

| Parameter | Effect |
|---|---|
| `-Quiet` | One summary line, for the RMM |
| `-PassThru` | Return the devices and findings as objects |

## Good to know

- **The default device, volume and mute come from Windows' own audio API (Core Audio)**, compiled in when it runs. If that's blocked (Constrained Language Mode, some antivirus), everything else still runs and it says it couldn't read them.
- **Microphone privacy is read for whoever is signed in**, not the account running the check. That holds when you run it elevated as an admin account, or as SYSTEM from the RMM. If nobody is signed in, the per-user part is skipped.
- **"Not present" devices** are ones used before that aren't connected now (an old headset, a dock). They're counted, not listed.
- **Teams has its own speaker / mic setting** (Settings > Devices in Teams). This checks Windows' side. If Windows looks right and Teams still can't hear the mic, check Teams' own setting next.
- **Problem code 45 ("not connected")** is normal for a Bluetooth device that's switched off, so it isn't flagged.
- It changes nothing. Most fixes are a click in Sound settings or `ms-settings:privacy-microphone`. Starting a stopped audio service needs admin (`Start-Service Audiosrv`).
- Exit codes: `0` = no FAIL, `1` = at least one FAIL.
- Console only, no log file: keep a transcript if you need one.
