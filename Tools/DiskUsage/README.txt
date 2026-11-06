DISK USAGE TOOLS - HOW TO USE
==============================

Easiest: from the Endpoint Toolkit menu, pick "Disk usage report (HTML)" or
"Disk usage browser (GUI)" under DIAGNOSE. Or, with the module loaded, run
Get-DiskUsageReport / Show-DiskUsageGui. The steps below are for running the
scripts by hand from this folder (Tools\DiskUsage in the toolkit).

This folder contains two PowerShell scripts:

  Get-DiskUsageReport.ps1   - scans a drive/folder and writes a console
                              summary and/or a self-contained HTML report
                              with an interactive folder tree and sortable
                              tables. Safe to paste into a remote session
                              or push via Intune - no installs needed.

  Show-DiskUsageGui.ps1     - opens a live window (like TreeSize) where you
                              can browse folders, see sizes, and drill in.
                              Browse/identify only - it cannot delete, move,
                              or rename anything.


STEP 1 - ALLOW LOCAL SCRIPTS TO RUN (one-time setup)
-----------------------------------------------------
Open PowerShell and check your policy:

    Get-ExecutionPolicy

If it says "Restricted", allow local scripts for your user account only
(does not need Administrator):

    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned


STEP 2 - RUN THE REPORT SCRIPT
--------------------------------
Open PowerShell, then go to this folder in the toolkit (adjust the path
to wherever the toolkit lives):

    cd <toolkit>\Tools\DiskUsage
    .\Get-DiskUsageReport.ps1

This scans your C: drive with default settings and prints a summary to
the console. At the end it prints a line like:

    Report: C:\DiskUsageReports\DiskUsage_<computer>_<date>.html

The C:\DiskUsageReports folder is created automatically the first time
you run it. Double-click the HTML file to open it in your browser -
that's where the clickable folder tree and sortable tables are.

Other useful ways to run it:

    # Scan a different drive or folder, list more items, save the report
    # to a specific location (e.g. your Desktop)
    .\Get-DiskUsageReport.ps1 -Path D:\ -TopFolders 50 -ReportPath C:\Users\<you>\Desktop\disk-report.html

    # Console output only, skip writing an HTML file
    .\Get-DiskUsageReport.ps1 -NoHtml

Run PowerShell "as Administrator" first if you want the scan to include
other users' profiles and protected system folders (it will warn you if
you're not elevated, but will still run).


STEP 3 - RUN THE LIVE GUI
----------------------------
Open PowerShell, then:

    cd <toolkit>\Tools\DiskUsage
    .\Show-DiskUsageGui.ps1

A window opens and starts scanning C: right away, with a progress bar.
Once it finishes:

  - Left side: folder tree, largest first. Click a folder to expand it.
  - Right side: files in the currently selected folder, sorted by size.
  - Toolbar: change the Path box and click "Rescan", or click "Browse..."
    to pick a different folder.
  - Right-click a folder or file for "Open in Explorer" or "Copy path".
    There is no delete/move/rename option anywhere - by design.

Run PowerShell "as Administrator" first if you want it to see protected
folders and other users' profiles, same as the report script.


IF DOUBLE-CLICKING THE .ps1 FILES DOES NOTHING
-------------------------------------------------
Windows normally opens .ps1 files in a text editor instead of running
them. Either:

  a) Always launch them from an already-open PowerShell window as shown
     above, or

  b) Right-click the file in Explorer and choose "Run with PowerShell".


NOTES / KNOWN LIMITATIONS (both tools)
-----------------------------------------
  - Sizes are logical size (file length), not size-on-disk. Compressed,
    sparse, or deduplicated volumes will read higher than Explorer shows.
  - Hard-linked files are counted once per link, so WinSxS reads larger
    than it really is - treat that number as indicative only.
  - Junctions and symlinks are skipped, not followed (avoids double
    counting and infinite loops).
  - Very long paths (over ~260 characters) may be skipped on Windows
    PowerShell 5.1 unless long path support is enabled.
