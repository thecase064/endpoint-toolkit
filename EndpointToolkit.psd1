@{
    RootModule        = 'EndpointToolkit.psm1'
    ModuleVersion     = '1.10.1'
    GUID              = '5f0b9c1e-7d2a-4c63-9a8e-3e1b6f4d2a71'
    Author            = 'Tom Fuller'
    Copyright         = '(c) 2026 Tom Fuller. MIT licence.'
    Description       = 'Windows endpoint toolkit for MSP technicians: new-device build chain, OEM driver and BIOS updates, everyday repairs (Teams, OneDrive, printing, Office activation, Windows Update), diagnostics including slow-PC checks, and M365 licence reporting. Window or console menu, runs straight from GitHub.'
    PowerShellVersion = '5.1'

    # Keep in step with the "command" values in tools.json (tests\Test-Repo.ps1 checks this).
    FunctionsToExport = @(
        'Show-EndpointToolkit'
        'Show-EndpointToolkitGui'
        'Get-ToolkitTool'
        'Invoke-ToolkitTool'
        'Invoke-NewDeviceSetup'
        'Remove-McAfee'
        'Invoke-BuildDebloat'
        'Invoke-OEMUpdate'
        'Reset-M365Apps'
        'Install-ChromeAndReader'
        'Set-IntunePrimaryUser'
        'Export-DeviceDriver'
        'Invoke-WindowsRepairChecks'
        'Reset-WindowsUpdate'
        'Clear-TeamsCache'
        'Clear-PrintSpooler'
        'Reset-OfficeActivation'
        'Repair-TeamsMeetingAddin'
        'Reset-OneDrive'
        'Invoke-QuickTriage'
        'Invoke-PerformanceCheck'
        'Compare-DeviceReport'
        'Get-EntraIntuneHealth'
        'Test-BitLockerKeyBackup'
        'Get-DeviceInventory'
        'Get-DiskUsageReport'
        'Show-DiskUsageGui'
        'Start-EventTriage'
        'Get-M365LicenseReport'
        'Get-ExchangePlannerUsage'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('etk', 'etkc')

    PrivateData = @{
        PSData = @{
            Tags         = @('MSP', 'Intune', 'Entra', 'M365', 'Teams', 'OneDrive', 'BitLocker', 'Drivers', 'BIOS', 'Dell', 'HP', 'Lenovo', 'Debloat', 'Endpoint', 'Windows', 'Toolkit')
            LicenseUri   = 'https://github.com/thecase064/endpoint-toolkit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/thecase064/endpoint-toolkit'
            ReleaseNotes = '1.10.1: Fix - OneDrive reset listed a leftover Personal registry key (holding only a placeholder %UserProfile%\OneDrive folder) as a signed-in account; keys with no email address are no longer counted. Found on a real laptop. 1.10.0: New OneDrive reset - Microsoft''s OneDrive.exe /reset for the signed-in user without hunting for the exe (running copy, registered copy, then the per-user and Program Files paths); lists accounts, synced libraries and OneDrive policies first, checks the old OneDrive closed, and starts it again if it does not come back by itself. No files are deleted. Refuses to run elevated or as another account, since OneDrive will not start with admin rights; -CheckOnly changes nothing. 1.9.0: New Before / after comparison - reads the Quick triage, Performance check, Wi-Fi and battery reports already saved for a PC and writes one page on what changed: fixed, better, worse and new checks, the numbers side by side for every run, what is still to do with each fix, and notes that only show across the reports (a first run caught mid-update, an idle after-run, no battery plus unexpected shutdowns, updates nothing manages, classic Teams still starting). Read-only; nothing is sent anywhere. 1.8.1: Fix - Dell driver updates failed at the scan (exit 107): newer Dell Command | Update refuses C:\ProgramData\OEMUpdates as a report folder, so DCU now writes its report under C:\ProgramData\Dell and it is copied back; if still refused, the scan reruns without a report. 1.8.0: New Performance check (slow PC) - measures CPU, disk and memory for 30 seconds, names the apps responsible and checks power settings, startup apps, hangs, start-up time, SSD vs hard drive and RAM; -Fix offers only undoable fixes (power plan, maximum processor state, startup apps), one question at a time. 1.7.2: Fix - over a remote session on Windows PowerShell 5.1 with a UTF-8 console, a question mid-run got junk characters instead of a blank answer (1.7.1 did not fix it). 1.7.1: First attempt at that fix. 1.7.0: New device setup ends with an HTML build report (steps, outstanding Windows and driver updates, device and app details) and adds Dell/HP/Lenovo drivers and an optional Intune primary user step; new Intune primary user tool; Chrome + Reader installers are signature-checked; Hostname shortcut removed. 1.6.0: Toolkit window (WPF) with search, briefs, options and Run; console.ps1 one-liner for remote shells; child tools stream their output back in remote sessions. 1.5.0: Menu shows a short brief of what each tool does and asks Run it? before anything starts. 1.4.1: Docs refresh (M365 reset README, run-time downloads in the security notes) and CI hardening. 1.4.0: OEM driver + BIOS updates for Dell, HP and Lenovo using the vendors'' own updaters. 1.3.0: Teams cache clear, print spooler clear, Office activation reset, Teams Meeting add-in fix, BitLocker key backup check, Wi-Fi + battery reports in Quick triage. 1.2.1: M365 reset -DeepClean now uses Microsoft Get Help (SaRA was retired). 1.2.0: Quick triage - the first five minutes of a ticket on one page. 1.1.0: Entra/Intune health check, device inventory, driver export/import, Windows Update reset, hostname shortcut, Exchange + Planner usage report.'
        }
    }
}
