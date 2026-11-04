# Hostname desktop shortcut

A "Hostname" shortcut on the desktop that opens a command window showing the computer name. For the support call where the user asks "what's my computer called?" and the alternative is a tour of System Settings.

It runs `cmd.exe /k title Hostname & hostname` (`/k` keeps the window open).

## Run

- Menu: **Build > Hostname desktop shortcut**
- Command: `New-HostnameShortcut` (current user) or `New-HostnameShortcut -AllUsers` (Public desktop, admin)
- Automatically: step 5 of **New device setup**, on the Public desktop. Skip it with `-SkipHostnameShortcut`.

Without `-AllUsers` it follows OneDrive desktop redirection. If you're elevated as a separate admin account, use `-AllUsers`, or the shortcut lands on the admin's desktop instead of the user's.
