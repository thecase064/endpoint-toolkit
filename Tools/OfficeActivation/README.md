# Office activation reset

For Office stuck on the wrong account, showing "Unlicensed Product", or refusing to activate after a user, licence or tenant change. It wipes Office's activation state so the user can sign in fresh.

It runs Microsoft's own fix: the **Get Help command line** `ResetOfficeActivation` scenario, which automates Microsoft's [Reset activation state for Microsoft 365 Apps](https://learn.microsoft.com/office/troubleshoot/activation/reset-office-365-proplus-activation-state) steps:

1. Closes every Office app
2. Clears Office's licences (`OLicenseCleanup`)
3. Signs Office out of its cached work/school accounts (`SignOutOfWamAccounts`)
4. Checks device registration and, **only if the device is workplace joined** (registered, not Entra joined), cleans that up (`WPJCleanup`)

Then open any Office app and sign in with the user's account.

Get Help is downloaded fresh on every run (Microsoft's builds expire after 90 days) and only runs if it's **validly signed by Microsoft**. The download is removed afterwards and the output log is kept.

## Run

- Menu: **Repair > Office activation reset**
- Command: `Reset-OfficeActivation`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Reset-OfficeActivation.ps1`

| Parameter | Effect |
|---|---|
| `-WorkDir` | Where Get Help is downloaded and the log kept. Default `C:\ProgramData\OfficeActivationReset` |

## Whose account gets signed out

It needs admin, but the account sign-out applies to **whoever is running it**. If you elevate as a separate admin account, the licence cleanup still covers the whole machine, but it's the admin's cached accounts that get cleared, not the user's. The tool warns when the account running it isn't the person signed in. In that case have the user sign out in Office (**File > Account > Sign out**) before signing back in.

## Results

The tool turns Get Help's result code into plain English.

| Code | Meaning |
|---|---|
| 80 | Done. Open Office and sign in. |
| 72 | Not elevated |
| 73-79 | One of the steps failed (licence cleanup, dsregcmd, account sign-out, workplace join cleanup, or Windows too old). The message links Microsoft's manual steps. |
| 71 | Get Help hit a problem. Try the Get Help app instead. |

Exit codes: `0` = reset done, `1` = anything else.
