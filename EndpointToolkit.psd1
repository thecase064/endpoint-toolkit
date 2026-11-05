@{
    RootModule        = 'EndpointToolkit.psm1'
    ModuleVersion     = '1.3.0'
    GUID              = '5f0b9c1e-7d2a-4c63-9a8e-3e1b6f4d2a71'
    Author            = 'Tom Fuller'
    Copyright         = '(c) 2026 Tom Fuller. MIT licence.'
    Description       = 'Windows endpoint toolkit for MSP technicians: new-device build chain, everyday repairs (Teams, printing, Office activation, Windows Update), diagnostics, and M365 licence reporting. Menu-driven, runs straight from GitHub.'
    PowerShellVersion = '5.1'

    # Keep in step with the "command" values in tools.json (tests\Test-Repo.ps1 checks this).
    FunctionsToExport = @(
        'Show-EndpointToolkit'
        'Get-ToolkitTool'
        'Invoke-ToolkitTool'
        'Invoke-NewDeviceSetup'
        'Remove-McAfee'
        'Invoke-BuildDebloat'
        'Reset-M365Apps'
        'Install-ChromeAndReader'
        'New-HostnameShortcut'
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
    AliasesToExport   = @('etk')

    PrivateData = @{
        PSData = @{
            Tags         = @('MSP', 'Intune', 'Entra', 'M365', 'Teams', 'BitLocker', 'Debloat', 'Endpoint', 'Windows', 'Toolkit')
            LicenseUri   = 'https://github.com/thecase064/endpoint-toolkit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/thecase064/endpoint-toolkit'
            ReleaseNotes = '1.3.0: Teams cache clear, print spooler clear, Office activation reset, Teams Meeting add-in fix, BitLocker key backup check, Wi-Fi + battery reports in Quick triage. 1.2.1: M365 reset -DeepClean now uses Microsoft Get Help (SaRA was retired). 1.2.0: Quick triage - the first five minutes of a ticket on one page. 1.1.0: Entra/Intune health check, device inventory, driver export/import, Windows Update reset, hostname shortcut, Exchange + Planner usage report.'
        }
    }
}
