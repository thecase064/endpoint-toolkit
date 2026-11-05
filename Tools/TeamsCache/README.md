# Teams cache clear

The first thing to try when Teams is slow, blank, stuck signing in, showing an old photo or name, or missing chats.

1. Closes Teams (only in this user's session, so other people's Teams on a shared or terminal server is left alone)
2. Empties the cache folders [Microsoft documents](https://learn.microsoft.com/troubleshoot/microsoftteams/teams-administration/clear-teams-cache):
   - New Teams: `%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams`
   - Classic Teams: `%APPDATA%\Microsoft\Teams`, if it's still there
3. Starts new Teams again

Only the **cache folder** is cleared, not the whole `MSTeams_8wekyb3d8bbwe` package, so the user's Teams settings survive. The first launch afterwards is slower while Teams rebuilds its cache.

## Run

- Menu: **Repair > Teams cache clear**
- Command: `Clear-TeamsCache`
- Standalone: `powershell -ExecutionPolicy Bypass -File .\Clear-TeamsCache.ps1`

| Parameter | Effect |
|---|---|
| `-NoRestart` | Don't start Teams again afterwards |
| `-Force` | Clear the cache of the account running it even though someone else is signed in |

**Run it as the user, not as admin.** The cache is per user. If the account running it isn't the person signed in (e.g. you elevated as your admin account), it stops and says so rather than clearing the wrong person's cache.

Exit codes: `0` = cleared, `1` = no Teams cache found, wrong account, or some files stayed locked (restart and run it again before Teams opens).
