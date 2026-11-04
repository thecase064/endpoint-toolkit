1. Open powershell as admin
2. cd "D:\365 Nuke"
3. powershell -ExecutionPolicy Bypass -File .\Reset-M365Apps.ps1


Here's the full run-through on a new laptop:

Get through Windows setup first — complete OOBE and sign in with an admin account (your local admin or the Entra-joined tech account, whatever your usual provisioning flow is).
Copy the script onto the machine — USB stick is easiest; drop Reset-M365Apps.ps1 somewhere like C:\Temp, or just run it straight off the USB.
Open an elevated PowerShell — right-click Start → Terminal (Admin) (or Windows PowerShell (Admin) on Win10). It must be elevated or the script will refuse to run.
Navigate to the script folder:

 cd "D:\365 Nuke"

Run it:

powershell -ExecutionPolicy Bypass -File .\Reset-M365Apps.ps1
That's the plain default run (Business licensing, en-GB, 64-bit). Add parameters if needed, e.g.:
powershellpowershell -ExecutionPolicy Bypass -File .\Reset-M365Apps.ps1 -ProductID O365ProPlusRetail -DeepClean
The Bypass is per-run only — it doesn't change the machine's execution policy, so nothing to revert afterwards.

Let it work — you'll see the cyan ==> step headers as it goes. Removal takes a few minutes; the reinstall then pulls ~3–4 GB from Microsoft's CDN silently, so on average broadband expect 10–20 minutes with no visible installer window. Don't assume it's hung — watch the console.
Check the result — at the end you want two green lines like Installed: O365BusinessRetail and a Version: number. If instead you get the yellow warning about the ClickToRun key missing, check the log in C:\OfficeReset\.
Reboot, then open Word or Outlook and sign in with the client's M365 account to activate. Done.

Only real prerequisite is internet access on the machine — both phases download from Microsoft directly, so nothing else needs pre-staging.