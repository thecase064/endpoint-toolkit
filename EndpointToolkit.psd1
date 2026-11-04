@{
    RootModule        = 'EndpointToolkit.psm1'
    ModuleVersion     = '1.2.0'
    GUID              = '5f0b9c1e-7d2a-4c63-9a8e-3e1b6f4d2a71'
    Author            = 'Tom Fuller'
    Copyright         = '(c) 2026 Tom Fuller. MIT licence.'
    Description       = 'Windows endpoint toolkit for MSP technicians: new-device build chain, repair, disk and event-log diagnostics, and M365 licence reporting. Menu-driven, runs straight from GitHub.'
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
        'Invoke-QuickTriage'
        'Get-EntraIntuneHealth'
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
            Tags         = @('MSP', 'Intune', 'Entra', 'M365', 'Debloat', 'Endpoint', 'Windows', 'Toolkit')
            LicenseUri   = 'https://github.com/thecase064/endpoint-toolkit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/thecase064/endpoint-toolkit'
            ReleaseNotes = '1.2.0: Quick triage - the first five minutes of a ticket on one page. 1.1.0: Entra/Intune health check, device inventory, driver export/import, Windows Update reset, hostname shortcut, Exchange + Planner usage report.'
        }
    }
}
