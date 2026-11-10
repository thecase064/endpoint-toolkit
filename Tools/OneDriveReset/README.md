# OneDrive reset

[Microsoft's fix](https://support.microsoft.com/en-us/onedrive/reset-onedrive) for OneDrive sync problems that won't clear: stuck on "Processing changes", sync errors that keep coming back, files that never upload. It's `OneDrive.exe /reset`, without trying each path in turn to find the exe.

1. **Finds OneDrive.exe**, in this order:
   - the copy that's running for this user
   - the one OneDrive registered for this user (`HKCU\Software\Microsoft\OneDrive\OneDriveTrigger`)
   - the three places Microsoft lists:
     - `%LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe` (per-user install)
     - `C:\Program Files\Microsoft OneDrive\OneDrive.exe` (per-machine install)
     - `C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe` (older 32-bit per-machine install)
2. **Shows what's connected:** the version, the accounts signed in (work and personal) with their folders, SharePoint / Teams libraries synced outside the OneDrive folder, and the OneDrive policies that matter afterwards (silent sign-in, known folders moved to OneDrive, libraries added by policy).
3. **Resets it:** runs `OneDrive.exe /reset` and checks the old OneDrive closed.
4. **Makes sure it's back:** waits up to 2 minutes for OneDrive to start again by itself, and starts it if it doesn't.
5. **Says what's left:** who needs to sign in, "Use this folder", choose folders, and which libraries to sync again.

## What a reset does

From Microsoft's page: it resets all OneDrive settings and disconnects every sync connection, personal and work or school. **No files are deleted.** OneDrive then does a full sync, which can take a while on big libraries.

Afterwards:
- **Sign-in:** with silent sign-in set by policy, the work account may come back by itself. Otherwise OneDrive shows "Set up OneDrive" and the user signs in. If it says the folder already exists, choose **Use this folder**.
- **Choose folders:** if the user only synced some folders, set that again once the sync finishes.
- **Synced libraries** (the Sync button in SharePoint or Teams) need syncing again, unless a policy adds them. Those come back by themselves, which can take up to 8 hours. Shortcuts added to My files live inside OneDrive and come back with it.

## Run

- Menu: **Repair > OneDrive reset**
- Command: `Reset-OneDrive`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Reset-OneDrive.ps1`

| Parameter | Effect |
|---|---|
| `-CheckOnly` | Show the install, accounts, synced libraries and policies; change nothing |
| `-WaitSeconds` | How long to wait for OneDrive to start again by itself before starting it (default 120) |
| `-Force` | Reset the OneDrive of the account running it even though someone else is signed in at the console (e.g. your own session on a terminal server) |

**Run it as the user, not as admin.** OneDrive won't start with full admin rights, and the reset only touches the account running it. So it stops if:
- it's elevated. That includes an admin's remote session (`Enter-PSSession`) and SYSTEM from an RMM, so it can't be run from a remote shell. Remote-control the user's session instead. If the toolkit window was opened as administrator, open it again without, then pick OneDrive reset.
- someone else is signed in at the PC (unless `-Force`), rather than reset the wrong person's OneDrive.

On a shared or terminal server only this user's OneDrive is touched.

If OneDrive came from the Microsoft Store rather than the sync app, there's no OneDrive.exe to reset: use **Settings > Apps > OneDrive > Advanced options > Reset**.

Exit codes: `0` = reset and OneDrive running again (or `-CheckOnly`), `1` = not reset (elevated, wrong account, OneDrive not found, the old OneDrive wouldn't close) or OneDrive didn't start again (open it from the Start menu).
