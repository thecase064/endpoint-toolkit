@{
    RootModule        = 'EndpointToolkit.psm1'
    ModuleVersion     = '1.0.0'
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
        'Invoke-WindowsRepairChecks'
        'Get-DiskUsageReport'
        'Show-DiskUsageGui'
        'Start-EventTriage'
        'Get-M365LicenseReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('etk')

    PrivateData = @{
        PSData = @{
            Tags         = @('MSP', 'Intune', 'M365', 'Debloat', 'Endpoint', 'Windows', 'Toolkit')
            LicenseUri   = 'https://github.com/thecase064/endpoint-toolkit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/thecase064/endpoint-toolkit'
            ReleaseNotes = 'Initial release: manifest-driven menu, one-line launcher, ten tools.'
        }
    }
}
