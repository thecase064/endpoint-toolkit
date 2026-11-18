# Everything Endpoint Toolkit saves on a PC, for Toolkit cleanup (Tools\ToolkitCleanup\Remove-ToolkitData.ps1).
# Data only. tests\Test-Repo.ps1 keeps it in step with the folder table in docs\data-flow.md, so a tool that
# starts writing somewhere new has to be added to both.
#
# Each location:
#   Category  Reports        reports and logs the tools save
#             Toolkit        the toolkit itself: downloaded copies, installed module, caches, settings,
#                            downloads and working files left by the tools
#             DriverBackups  Driver export's backups (only when asked for: they're the restore point)
#             UpdateBackups  Windows Update reset's old folders (only when asked for: they're its undo)
#   Root      SystemDrive (C:\), ProgramData, Windows, Documents (both the real Documents folder and
#             %USERPROFILE%\Documents, which differ when OneDrive redirects it), AppData, LocalAppData, Temp.
#             Documents, AppData, LocalAppData and Temp are the account running the cleanup.
#   Folder    under the root ('' = the root itself)
#   Names     what the toolkit creates in that folder: PowerShell wildcards, matched case-insensitively against
#             names in the folder (a path such as 'Logs\Build_*' looks in a subfolder). Anything else there
#             is someone else's and is left alone.
#   Whole     $true when the folder is the toolkit's alone and goes as a whole (Names is then unused)
#   Empty     folders (under the root) to remove afterwards if they're empty, deepest first. Never a
#             shared parent such as ProgramData\Dell or Documents\WindowsPowerShell\Modules.
#   Tools     who writes there, for the listing
@{
    Locations = @(
        # ---- Reports and logs -------------------------------------------------------------------
        @{ Category = 'Reports'; Root = 'SystemDrive'; Folder = 'Triage'
           Names = 'Triage_*.html', 'Performance_*.html', 'Updates_*.html', 'Report_*.html', 'Battery_*.html', 'WiFi_*.html'
           Empty = 'Triage'
           Tools = 'Quick triage, Performance check, Before / after comparison, Windows Update status' }
        @{ Category = 'Reports'; Root = 'ProgramData'; Folder = 'DeploymentMaster'
           Names = 'Reports\BuildReport_*.html', 'Reports\BuildReport_*.json', 'Logs\MasterDeploy_*.log', 'Logs\Build_*'
           Empty = 'DeploymentMaster\Reports', 'DeploymentMaster\Logs', 'DeploymentMaster'
           Tools = 'New device setup' }
        @{ Category = 'Reports'; Root = 'ProgramData'; Folder = 'McAfeeRemoval'
           Names = 'McAfeeRemoval_*.log'
           Empty = 'McAfeeRemoval'
           Tools = 'McAfee removal' }
        @{ Category = 'Reports'; Root = 'ProgramData'; Folder = 'Debloat'
           Names = 'debloat-*.log'
           Empty = 'Debloat'
           Tools = 'OEM debloat' }
        @{ Category = 'Reports'; Root = 'ProgramData'; Folder = 'OEMUpdates'
           Names = 'Dell_*', 'HP_*', 'Lenovo_*'
           Empty = 'OEMUpdates'
           Tools = 'OEM drivers + BIOS' }
        @{ Category = 'Reports'; Root = 'ProgramData'; Folder = 'Dell\OEMUpdates'
           Names = 'Dell_*'
           Empty = 'Dell\OEMUpdates'
           Tools = 'OEM drivers + BIOS (Dell Command | Update reports)' }
        @{ Category = 'Reports'; Root = 'ProgramData'; Folder = 'AppDeploy\Logs'
           Names = 'Install-ChromeAndReader_*.log', 'Chrome_msi.log', 'Reader_msi.log'
           Empty = 'AppDeploy\Logs', 'AppDeploy'
           Tools = 'Chrome + Adobe Reader install' }
        @{ Category = 'Reports'; Root = 'ProgramData'; Folder = 'OfficeActivationReset'
           Names = 'GetHelp_*.log'
           Empty = 'OfficeActivationReset'
           Tools = 'Office activation reset' }
        @{ Category = 'Reports'; Root = 'ProgramData'; Folder = 'WindowsUpdateReset'
           Names = 'Reset_*.log'
           Empty = 'WindowsUpdateReset'
           Tools = 'Windows Update reset' }
        @{ Category = 'Reports'; Root = 'SystemDrive'; Folder = 'OfficeReset'
           Names = 'OfficeReset_*.log', 'GetHelp_*.log'
           Empty = 'OfficeReset'
           Tools = 'M365 Apps reset + reinstall' }
        @{ Category = 'Reports'; Root = 'SystemDrive'; Folder = 'DeviceInventory'
           Names = 'Inventory_*.html', 'Inventory_*.json'
           Empty = 'DeviceInventory'
           Tools = 'Device inventory' }
        @{ Category = 'Reports'; Root = 'SystemDrive'; Folder = 'DiskUsageReports'
           Names = 'DiskUsage_*.html'
           Empty = 'DiskUsageReports'
           Tools = 'Disk usage report' }
        @{ Category = 'Reports'; Root = 'SystemDrive'; Folder = 'EntraIntuneHealth'
           Names = 'EntraIntune_*'
           Empty = 'EntraIntuneHealth'
           Tools = 'Entra / Intune health (-CollectLogs)' }
        @{ Category = 'Reports'; Root = 'Documents'; Folder = 'M365Reports'
           Names = 'M365-License-Report_*.xlsx', 'M365_Usage_*.csv', 'M365_Usage_*.xlsx'
           Empty = 'M365Reports'
           Tools = 'M365 licence report, Exchange + Planner usage' }

        # ---- The toolkit itself ------------------------------------------------------------------
        @{ Category = 'Toolkit'; Root = 'ProgramData'; Folder = 'EndpointToolkit'; Whole = $true
           Tools = 'Launcher (downloaded copies), Intune primary user (_modules)' }
        @{ Category = 'Toolkit'; Root = 'LocalAppData'; Folder = 'EndpointToolkit'; Whole = $true
           Tools = 'M365 licence report, Exchange + Planner usage (saved licence names), Intune primary user (_modules, unelevated)' }
        @{ Category = 'Toolkit'; Root = 'Documents'; Folder = 'WindowsPowerShell\Modules\EndpointToolkit'; Whole = $true
           Tools = 'Launcher -Install (Windows PowerShell)' }
        @{ Category = 'Toolkit'; Root = 'Documents'; Folder = 'PowerShell\Modules\EndpointToolkit'; Whole = $true
           Tools = 'Launcher -Install (PowerShell 7)' }
        @{ Category = 'Toolkit'; Root = 'AppData'; Folder = 'EventTriage'
           Names = 'EventTriage.mutes.json'
           Empty = 'EventTriage'
           Tools = 'Event triage (mutes)' }
        @{ Category = 'Toolkit'; Root = 'SystemDrive'; Folder = 'OfficeReset'
           Names = 'setup.exe', 'remove.xml', 'install.xml', 'GetHelp', 'GetHelpCmd.zip', 'SaRA', 'SaRACmd.zip'
           Empty = 'OfficeReset'
           Tools = 'M365 Apps reset + reinstall (Office Deployment Tool, Get Help)' }
        @{ Category = 'Toolkit'; Root = 'ProgramData'; Folder = 'OfficeActivationReset'
           Names = 'GetHelp', 'GetHelpCmd.zip'
           Empty = 'OfficeActivationReset'
           Tools = 'Office activation reset (Get Help, if a run was interrupted)' }
        @{ Category = 'Toolkit'; Root = 'Temp'; Folder = ''
           Names = 'etk-run-*.json', 'endpoint-toolkit-*.zip', 'DriverImport_*', 'm365rpt_*.csv', 'AppDeploy\Chrome.msi', 'AppDeploy\AcroRdr*.exe'
           Empty = 'AppDeploy'
           Tools = 'Window run options, launcher, Driver import, Exchange + Planner usage, Chrome + Reader (if a run was interrupted)' }

        # ---- Only when asked for -----------------------------------------------------------------
        @{ Category = 'DriverBackups'; Root = 'SystemDrive'; Folder = 'DriverExport'
           Names = '*_*_*_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]', '*_*_*_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].zip'
           Empty = 'DriverExport'
           Tools = 'Driver export' }
        @{ Category = 'UpdateBackups'; Root = 'Windows'; Folder = ''
           Names = 'SoftwareDistribution.old-*'
           Tools = 'Windows Update reset' }
        @{ Category = 'UpdateBackups'; Root = 'Windows'; Folder = 'System32'
           Names = 'catroot2.old-*'
           Tools = 'Windows Update reset' }
    )
}
