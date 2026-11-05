# Teams Meeting add-in fix

For the missing **Teams Meeting** button in classic Outlook. It checks everything that makes the add-in disappear, fixes what can be fixed for the user, and tells you exactly what to do about the rest.

| Check | What it looks for | Fixed automatically? |
|---|---|---|
| Installed | "Microsoft Teams Meeting Add-in for Microsoft Office" is installed, and isn't the old 1.23.x version left over from classic Teams | No: tells you Microsoft's reinstall steps |
| Registered | Outlook has the add-in registered (`TeamsAddin.FastConnect`) | No: tells you Microsoft's reinstall steps |
| LoadBehavior | Set to `3`, load at startup ([Microsoft's documented fix](https://learn.microsoft.com/troubleshoot/microsoftteams/meetings/resolve-teams-meeting-add-in-issues)) | Yes |
| Disabled list | Outlook hasn't put it on its disabled list after a slow or crashed start | Yes |
| Keep enabled | It's on Outlook's do-not-disable list, so a slow start doesn't switch it off again | Yes |

These are the same checks Microsoft's Get Help troubleshooter makes. Get Help itself isn't used here, because Microsoft says its Teams troubleshooters don't support new Teams.

**New Outlook doesn't use this add-in at all.** It has Teams meetings built in (the *Teams meeting* toggle on a new event). The tool tells you if new Outlook is switched on for the user, or if classic Outlook isn't installed.

## Run

- Menu: **Repair > Teams Meeting add-in fix (classic Outlook)**
- Command: `Repair-TeamsMeetingAddin`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Repair-TeamsMeetingAddin.ps1`

| Parameter | Effect |
|---|---|
| `-CheckOnly` | Report only. Changes nothing and leaves Outlook open. |
| `-Force` | Fix the account running it even though someone else is signed in |

It closes classic Outlook before fixing, because Outlook only reads these settings at startup. Afterwards, start Teams, then Outlook.

**Run it as the user, not as admin.** The settings are per user. If the account running it isn't the person signed in, it stops and says so.

If it all checks out and the button is still missing, check the user's Teams meeting policy in the Teams admin centre (the Outlook add-in must be allowed).

Exit codes: `0` = nothing wrong or everything fixed, `1` = something still needs doing.
