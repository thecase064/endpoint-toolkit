NEW DEVICE SETUP - MASTER SCRIPT
=================================

Runs all four deployment steps back-to-back, unattended:

  1. McAfee Nuke   - removes McAfee
  2. Debloat       - strips OEM bloat / consumer apps, applies tweaks
  3. 365 Nuke      - removes old Office, installs clean M365 Apps (Business)
  4. Adobe Chrome  - installs Chrome + hardened Adobe Acrobat Reader

Then reboots automatically (60-second cancellable countdown).


HOW TO RUN
----------
Easiest: from the Endpoint Toolkit menu, pick "New device setup".

Or by hand:
1. Open PowerShell as Administrator.
2. cd to the toolkit's Tools\NewDeviceSetup folder
3. powershell -ExecutionPolicy Bypass -File .\Invoke-NewDeviceSetup.ps1

That's it - it does not need any parameters for a normal run. Let it work;
you'll see each sub-script's own coloured output print to the console as it
goes. Don't close the window.


BEFORE YOU RUN IT
-----------------
- Must stay inside the toolkit's Tools folder - it calls the four
  sub-scripts from its sibling folders (e.g. "..\McAfeeRemoval\AVNuke.ps1").
  If you move it, take the four folders ("McAfeeRemoval", "OEMDebloat",
  "M365Reset", "ChromeReader") with it.
- Needs an elevated (Administrator) PowerShell session - it will refuse to
  run otherwise.
- Needs internet access - steps 3 and 4 download from Microsoft's and
  Google/Adobe's CDNs (the M365 download alone is ~3-4 GB).
- Expect roughly 15-30+ minutes total, most of it the M365 download/install.
  The console won't show a progress bar during that part - it's not hung,
  just downloading silently.
- The machine WILL reboot on its own when everything finishes. Don't run
  this if you're not ready for that.


WHAT IT DOES NOT DO
--------------------
- It does not stop and ask you anything partway through.
- It does not stop if one step fails - it logs the problem and moves on to
  the next step so the whole run still completes unattended. Check the
  summary printed at the end (and the individual logs below) for anything
  that needs a manual look.


OPTIONAL PARAMETER
-------------------
-SkipReboot   Runs all four steps as normal but skips the automatic reboot
              at the end (just prints that one is recommended). Useful if
              you want to review everything before restarting yourself.

Example:
  powershell -ExecutionPolicy Bypass -File .\Invoke-NewDeviceSetup.ps1 -SkipReboot


CANCELLING THE REBOOT
----------------------
Once the final "Rebooting in 60 seconds..." message appears, you have 60
seconds to cancel it. Open another Administrator PowerShell/CMD window and
run:
  shutdown /a


LOGS
----
Master run log (summary of all 4 steps, exit codes, pass/fail):
  C:\ProgramData\DeploymentMaster\Logs\

Each step also keeps its own detailed log:
  McAfee Removal        -> C:\ProgramData\McAfeeRemoval\
  OEM Debloat           -> C:\ProgramData\Debloat\
  Microsoft 365 Reset   -> C:\OfficeReset\
  Chrome + Reader       -> C:\ProgramData\AppDeploy\Logs\

If the master summary flags a step as anything other than [OK], check that
step's log above for details.


CHANGING DEFAULTS
------------------
This script calls the sub-scripts with fixed choices baked in (Debloat runs
with -Force, M365 installs as O365BusinessRetail/en-GB/64-bit). If a
particular deployment needs different options (e.g. an Enterprise M365
license, or a different Reader language), either:
  - run that one sub-script manually with its own parameters instead of
    using the master script for that step, or
  - edit the relevant -ArgumentList line in Invoke-NewDeviceSetup.ps1.
