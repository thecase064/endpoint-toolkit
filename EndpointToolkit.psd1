@{
    RootModule        = 'EndpointToolkit.psm1'
    ModuleVersion     = '1.7.1'
    GUID              = '5f0b9c1e-7d2a-4c63-9a8e-3e1b6f4d2a71'
    Author            = 'Tom Fuller'
    Copyright         = '(c) 2026 Tom Fuller. MIT licence.'
    Description       = 'Windows endpoint toolkit for MSP technicians: new-device build chain, OEM driver and BIOS updates, everyday repairs (Teams, printing, Office activation, Windows Update), diagnostics, and M365 licence reporting. Window or console menu, runs straight from GitHub.'
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
        'Invoke-QuickTriage'
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
            Tags         = @('MSP', 'Intune', 'Entra', 'M365', 'Teams', 'BitLocker', 'Drivers', 'BIOS', 'Dell', 'HP', 'Lenovo', 'Debloat', 'Endpoint', 'Windows', 'Toolkit')
            LicenseUri   = 'https://github.com/thecase064/endpoint-toolkit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/thecase064/endpoint-toolkit'
            ReleaseNotes = '1.7.1: Fix - over a remote session on Windows PowerShell 5.1, a question mid-run could get an invisible character instead of a blank answer. 1.7.0: New device setup ends with an HTML build report (steps, outstanding Windows and driver updates, device and app details) and adds Dell/HP/Lenovo drivers and an optional Intune primary user step; new Intune primary user tool; Chrome + Reader installers are signature-checked; Hostname shortcut removed. 1.6.0: Toolkit window (WPF) with search, briefs, options and Run; console.ps1 one-liner for remote shells; child tools stream their output back in remote sessions. 1.5.0: Menu shows a short brief of what each tool does and asks Run it? before anything starts. 1.4.1: Docs refresh (M365 reset README, run-time downloads in the security notes) and CI hardening. 1.4.0: OEM driver + BIOS updates for Dell, HP and Lenovo using the vendors'' own updaters. 1.3.0: Teams cache clear, print spooler clear, Office activation reset, Teams Meeting add-in fix, BitLocker key backup check, Wi-Fi + battery reports in Quick triage. 1.2.1: M365 reset -DeepClean now uses Microsoft Get Help (SaRA was retired). 1.2.0: Quick triage - the first five minutes of a ticket on one page. 1.1.0: Entra/Intune health check, device inventory, driver export/import, Windows Update reset, hostname shortcut, Exchange + Planner usage report.'
        }
    }
}
