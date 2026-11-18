# Old user profile cleanup

For shared PCs, hand-me-down laptops and "the C drive is full" where `C:\Users` holds people who left months ago. It lists every profile with when it was really last used, then deletes only the ones you pick.

| Step | What happens |
|---|---|
| **List** | Every user profile, oldest first: **when it was last used**, its **size**, the **files in Desktop / Documents / Pictures / Videos / Music / Downloads** (not in OneDrive, so they go with the profile), and whether the **account still exists** or is disabled. Stale = not used for 90 days (`-OlderThanDays`). Also reports: folders in `C:\Users` with **no profile entry** (Windows won't remove those), **`.bak` profile entries** (the "signed in with a temporary profile" problem) and the **"delete profiles older than" policy**. |
| **Pick** (`-Remove`) | Asks which to delete: numbers (`1,3` or `2-4`), `all`, or Enter for none. Then shows the total and asks once more. Blank or anything other than `y` means nothing is deleted. |
| **Delete** | Through Windows' own profile API (`Win32_UserProfile`), which removes the folder and the registry entry together. Re-checks each one first (signed in since? skipped), then checks it has really gone and shows how much space came back. |

## Run

- Menu: **Repair > Old user profile cleanup**
- Command: `Remove-StaleProfile`
- Standalone (elevated): `powershell -ExecutionPolicy Bypass -File .\Remove-StaleProfile.ps1`

| Parameter | Effect |
|---|---|
| `-Remove` | Offer the stale profiles for deletion: you pick, then confirm. Needs admin. |
| `-OlderThanDays` | Stale after this many days, default `90`, at least `30` |
| `-User` | Only these profiles (folder name, account or sign-in address; wildcards allowed), whatever their age. With `-Remove`: "delete this person's profile". |
| `-Exclude` | Never offer these (same matching as `-User`) |
| `-Yes` | With `-Remove`: delete every stale profile without asking, for the RMM. Skips the "only if picked by number" ones (below) unless named with `-User`. |
| `-SkipSize` | Don't measure sizes (faster on big profiles) |
| `-Quiet` | One summary line, for the RMM |
| `-PassThru` | Return the profiles, notes and actions as objects |

## What it won't touch

- **Never offered:** a profile in use (signed in, or still loaded), system and service accounts, the built-in Administrator, the account running the tool, profiles outside the profiles folder and anything in `-Exclude`.
- **Only if you pick it by number** (never by `all` or `-Yes`): a profile with **no last-used date**, the account that **set this PC up** (Entra join) and the **last person to sign in**.
- **Folders with no profile entry, `.bak` entries and the policy:** reported, never changed. Deleting a profile's folder on its own is what leaves those behind in the first place.
- **Nothing is sent anywhere.** Deleted profiles can't be brought back.

## Good to know

- **"Last used" is the sign-in / sign-out time Windows records for each profile** (`ProfileList\<SID>` `LocalProfileLoadTime` / `LocalProfileUnloadTime`), the same times Windows' own "delete profiles older than" policy uses since Windows 10 1809. It deliberately ignores `LastUseTime` and the date on `NTUSER.DAT`: antivirus, Windows updates and backup software keep bumping those, which is why so many cleanup scripts find nothing to delete. `NTUSER.DAT` is only the fallback when no times are recorded, and the list says which it used.
- **Size leaves out OneDrive files that are only in the cloud**, so it's roughly the space you'll get back. Junctions (the old "Application Data" style links) aren't followed.
- **Files outside OneDrive are flagged in yellow.** With Known Folder Move on, Desktop and Documents live in OneDrive and these are usually empty; Downloads never is. Anything listed there is lost with the profile: copy it off first if it matters.
- **On Entra-joined PCs** accounts are named from Windows' own cache of Entra sign-ins. An account this PC has never cached shows as "Entra account this PC has no name for", **not** as deleted: unlike some cleanup scripts, it doesn't call an Entra account orphaned just because Windows can't name it offline.
- **A domain account it can't look up** says "deleted, or no domain controller in reach": check over the VPN or in AD before deleting on that basis alone.
- **"Part of the folder is left"** means a file was in use. Restart and delete that folder by hand.
- **Temporary profile (`.bak`) fix by hand:** back up `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`, keep the entry whose `ProfileImagePath` is the real folder (renamed without `.bak`), delete the other, restart.
- Exit codes: `0` = done, `1` = a deletion failed, `-Remove` without admin, or `-User` matched nothing.
- Console only, no log file: keep a transcript if you need one.
