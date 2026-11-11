# Data flow: where everything goes

Reports save to the PC. Only three tools sign into Microsoft 365: Intune primary user (also run by New device setup), M365 licence report, and Exchange + Planner usage.

For each tool, this page shows where it gets information or signs in, what it runs, and where it saves. It's written from the scripts as of v1.10.1. If a tool's paths, downloads or sign-ins change, update this page in the same commit.

```mermaid
flowchart LR
    classDef tool fill:#CFEBC8,stroke:#5E9E55,color:#1b1b1b
    classDef local fill:#FFFFFF,stroke:#9A9A9A,color:#1b1b1b
    classDef out fill:#FFF0A6,stroke:#C9AF2E,color:#1b1b1b
    classDef net fill:#CFE2FA,stroke:#5F8FCB,color:#1b1b1b
    classDef auth fill:#FFD8BE,stroke:#D98A57,color:#1b1b1b
    K1("Toolkit tool"):::tool
    K2["On the PC: reads or runs"]:::local
    K3["Saves to"]:::out
    K4["Goes online (no sign-in)"]:::net
    K5["Signs into Microsoft 365"]:::auth
    K1 ~~~ K2 ~~~ K3 ~~~ K4 ~~~ K5
```

Arrows point the way information flows. A two-way arrow means the tool also changes something there: Intune primary user sets the device's primary user in the tenant, Exchange + Planner usage can un-conceal report names for the run (and puts them back), Entra / Intune health `-Sync` makes the device check in with Intune, and BitLocker `-Fix` backs keys up to Entra.

## Contents

- [Starting the toolkit](#starting-the-toolkit)
- [Build](#build)
- [Repair](#repair)
- [Diagnose](#diagnose)
- [Report (Microsoft 365 tenant)](#report-microsoft-365-tenant)
- [Every folder it writes to on the PC](#every-folder-it-writes-to-on-the-pc)

## Starting the toolkit

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart TB
    classDef tool fill:#CFEBC8,stroke:#5E9E55,color:#1b1b1b
    classDef local fill:#FFFFFF,stroke:#9A9A9A,color:#1b1b1b
    classDef out fill:#FFF0A6,stroke:#C9AF2E,color:#1b1b1b
    classDef net fill:#CFE2FA,stroke:#5F8FCB,color:#1b1b1b
    classDef auth fill:#FFD8BE,stroke:#D98A57,color:#1b1b1b
    L1["<b>1. You run a launcher</b><br/>irm .../install.ps1 #124; iex opens the<br/>window<br/>irm .../console.ps1 #124; iex for remote<br/>shells<br/>or Launch-Toolkit.cmd,<br/>EndpointToolkit.exe, or<br/>Start-Toolkit.ps1 from a local copy"]:::local
    L2["<b>2. Pulls the toolkit from GitHub</b><br/>raw.githubusercontent.com: the launcher<br/>script<br/>codeload.github.com: a zip of<br/>thecase064/endpoint-toolkit at the<br/>chosen ref (default main, pin with -Ref)"]:::net
    L3["<b>3. Unzips it on the PC</b><br/>C:\ProgramData\EndpointToolkit\<br/>#lt;ref#gt;-#lt;time#gt;\<br/>.etk-source.json records the ref. Keeps<br/>the newest 3 copies.<br/>-Install also copies it to<br/>Documents\WindowsPowerShell\Modules\"]:::out
    L4("<b>4. Window or console menu</b><br/>Window with a desktop#59; console menu over<br/>Enter-PSSession, RMM or -Console<br/>Shows the brief, asks Run it? [y/N]"):::tool
    L5["<b>5. Runs the tool you picked</b><br/>Options go to %TEMP%\etk-run-#lt;guid#gt;.json<br/>(SHA-256 checked, deleted once read)<br/>New PowerShell window per tool#59; UAC<br/>prompt for admin tools<br/>Exit code shows as OK or CHECK LOG"]:::local
    L1 --> L2 --> L3 --> L4 --> L5
```

## Build

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart LR
    classDef tool fill:#CFEBC8,stroke:#5E9E55,color:#1b1b1b
    classDef local fill:#FFFFFF,stroke:#9A9A9A,color:#1b1b1b
    classDef out fill:#FFF0A6,stroke:#C9AF2E,color:#1b1b1b
    classDef net fill:#CFE2FA,stroke:#5F8FCB,color:#1b1b1b
    classDef auth fill:#FFD8BE,stroke:#D98A57,color:#1b1b1b
    B1T("<b>New device setup</b><br/>Admin. Runs in order: primary<br/>user, McAfee, debloat, M365,<br/>Chrome + Reader, Dell / HP /<br/>Lenovo drivers<br/>Then restarts in 60 s (shutdown /a<br/>cancels)"):::tool
    B1A["<b>Microsoft Graph sign-in</b><br/>Only if a primary user is given (the Intune<br/>primary user step)"]:::auth <--> B1T
    B1N["<b>Online</b><br/>Whatever each step downloads (see those tools)<br/>Windows Update scan for the report (COM, 15<br/>min limit)"]:::net --> B1T
    B1L["Ticket, technician, primary user (asked at the<br/>start)<br/>tools.json briefs#59; device + app details (CIM,<br/>registry, dsregcmd)#59; pending restart"]:::local --> B1T
    B1T --> B1O["C:\ProgramData\DeploymentMaster\Reports\<br/>BuildReport_#lt;PC#gt;_#lt;time#gt;.html + .json (opens at<br/>the end)<br/>C:\ProgramData\DeploymentMaster\Logs\<br/>MasterDeploy_#lt;time#gt;.log and Build_#lt;time#gt;\ (step<br/>output)<br/>Plus each step's own log folder. Deletes the<br/>_modules cache."]:::out
    B2T("<b>McAfee removal</b><br/>Admin. Remove-AppxPackage, msiexec<br/>/x, McAfee's own uninstallers<br/>Exit 3010 = removed, restart"):::tool
    B2L["McAfee Store apps (all users)<br/>HKLM Uninstall keys (32 + 64-bit)<br/>WebAdvisor uninstaller in Program Files"]:::local --> B2T
    B2T --> B2O["C:\ProgramData\McAfeeRemoval\McAfeeRemoval_<br/>#lt;date#gt;.log<br/>Only links to MCPR for stubborn suites#59;<br/>downloads nothing"]:::out
    B3T("<b>OEM debloat (HP / Dell)</b><br/>Admin. Removes OEM + consumer<br/>apps, keeps SupportAssist / HP<br/>Support Assistant<br/>Menu default: dry run"):::tool
    B3L["Store + provisioned apps<br/>Uninstall keys (HKLM + HKCU)<br/>Writes settings to the Default user hive<br/>(NTUSER.DAT) and loaded user hives"]:::local --> B3T
    B3T --> B3O["C:\ProgramData\Debloat\debloat-#lt;time#gt;.log"]:::out
    B4T("<b>OEM drivers + BIOS</b><br/>Admin. Scans, lists, asks,<br/>installs drivers + firmware (BIOS<br/>only if ticked)<br/>Never restarts"):::tool
    B4N["<b>Downloads (asks first)</b><br/>winget: Dell.CommandUpdate.Universal,<br/>HP.ImageAssistant<br/>PowerShell Gallery: LSUClient (+ NuGet)<br/>Then the vendor's own update catalogue"]:::net --> B4T
    B4L["Make from Win32_ComputerSystem<br/>Dell: Program<br/>Files\Dell\CommandUpdate\dcu-cli.exe<br/>HP: C:\SWSetup\...\HPImageAssistant.exe"]:::local --> B4T
    B4T --> B4O["C:\ProgramData\OEMUpdates\#lt;Vendor#gt;_#lt;time#gt;.log +<br/>report folder<br/>Dell:<br/>C:\ProgramData\Dell\OEMUpdates\Dell_#lt;time#gt;\<br/>(copied back)"]:::out
    B5T("<b>M365 Apps reset + reinstall</b><br/>Admin. ODT Remove All, optional<br/>Get Help scrub (-DeepClean), then<br/>a clean install"):::tool
    B5N["<b>Downloads</b><br/>officecdn.microsoft.com: ODT setup.exe<br/>(signature checked) + the 3-4 GB install<br/>aka.ms/SaRA_EnterpriseVersionFiles: Get Help,<br/>-DeepClean only (Microsoft signature checked)"]:::net --> B5T
    B5L["Every installed Office, MSI Office included"]:::local --> B5T
    B5T --> B5O["C:\OfficeReset\OfficeReset_#lt;time#gt;.log<br/>(transcript)<br/>setup.exe, remove.xml, install.xml<br/>GetHelp_#lt;time#gt;.log (-DeepClean)"]:::out
    B6T("<b>Chrome + Adobe Reader</b><br/>Admin. Silent installs#59; locks down<br/>Reader cloud / AI features<br/>(HKLM\SOFTWARE\Policies\Adobe)"):::tool
    B6N["<b>Downloads</b><br/>dl.google.com: Chrome Enterprise MSI (must be<br/>signed Google LLC)<br/>rdc.adobe.io: latest Reader version<br/>ardownload2.adobe.com: Reader installer (must<br/>be signed Adobe Inc.)"]:::net --> B6T
    B6L["Installed apps (HKLM Uninstall keys)"]:::local --> B6T
    B6T --> B6O["Downloads land in %TEMP%\AppDeploy\<br/>C:\ProgramData\AppDeploy\Logs\<br/>Install-ChromeAndReader_#lt;time#gt;.log +<br/>Chrome_msi.log"]:::out
    B7T("<b>Intune primary user</b><br/>No admin needed. Shows, sets or<br/>removes the primary user#59; Intune<br/>updates the Entra owner"):::tool
    B7A["<b>Microsoft Graph sign-in as a tenant admin</b><br/>Sign-in window#59; device code with no desktop<br/>DeviceManagementManagedDevices.ReadWrite.All<br/>(Read.All when only showing) + User.Read.All<br/>Reads + changes the device's users in Intune<br/>(Graph beta)"]:::auth <--> B7T
    B7N["<b>Downloads</b><br/>PowerShell Gallery:<br/>Microsoft.Graph.Authentication, only if<br/>missing (signature checked)"]:::net --> B7T
    B7L["Tenant ID from dsregcmd /status<br/>Intune device ID from<br/>HKLM\SOFTWARE\Microsoft\Enrollments"]:::local --> B7T
    B7T --> B7O["Console only<br/>Module cache:<br/>C:\ProgramData\EndpointToolkit\_modules (admin)<br/>or %LOCALAPPDATA%\EndpointToolkit\_modules"]:::out
    B8T("<b>Driver export</b><br/>Admin, read-only. Backs up<br/>third-party drivers before a wipe"):::tool
    B8L["Drivers in the running Windows<br/>(Export-WindowsDriver, falls back to pnputil<br/>/export-driver) or an offline image"]:::local --> B8T
    B8T --> B8O["C:\DriverExport\#lt;PC#gt;_#lt;Make#gt;_#lt;Model#gt;_#lt;date#gt;\<br/>drivers.csv, device.json, RESTORE.txt<br/>+ a .zip (menu default)"]:::out
    B9T("<b>Driver import</b><br/>Admin. pnputil /add-driver *.inf<br/>/subdirs /install"):::tool
    B9L["An export folder or .zip<br/>A .zip is unpacked to<br/>%TEMP%\DriverImport_#lt;time#gt;\"]:::local --> B9T
    B9T --> B9O["Console only<br/>Drivers go into Windows' driver store"]:::out
```

## Repair

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart LR
    classDef tool fill:#CFEBC8,stroke:#5E9E55,color:#1b1b1b
    classDef local fill:#FFFFFF,stroke:#9A9A9A,color:#1b1b1b
    classDef out fill:#FFF0A6,stroke:#C9AF2E,color:#1b1b1b
    classDef net fill:#CFE2FA,stroke:#5F8FCB,color:#1b1b1b
    classDef auth fill:#FFD8BE,stroke:#D98A57,color:#1b1b1b
    R1T("<b>Windows repair checks</b><br/>Admin. DISM RestoreHealth, SFC<br/>/scannow, DISM component cleanup"):::tool
    R1N["<b>Online</b><br/>Windows Update: DISM RestoreHealth can fetch<br/>repair files from it"]:::net --> R1T
    R1L["Windows component store + system files"]:::local --> R1T
    R1T --> R1O["Console only, ends CHECKS COMPLETE - PLEASE<br/>RESTART SYSTEM<br/>Windows keeps its own<br/>C:\Windows\Logs\CBS\CBS.log and DISM\dism.log"]:::out
    R2T("<b>Windows Update reset</b><br/>Admin. Stops services, renames<br/>SoftwareDistribution + catroot2,<br/>restarts, rescans<br/>Options: winsock reset, delete old<br/>copies"):::tool
    R2N["<b>Online</b><br/>Windows Update: rescan (UsoClient) after the<br/>reset"]:::net --> R2T
    R2L["wuauserv, BITS, cryptsvc, msiserver, UsoSvc,<br/>dosvc"]:::local --> R2T
    R2T --> R2O["C:\ProgramData\WindowsUpdateReset\Reset_#lt;time#gt;.<br/>log<br/>C:\Windows\SoftwareDistribution.old-#lt;time#gt;<br/>C:\Windows\System32\catroot2.old-#lt;time#gt;"]:::out
    R3T("<b>Teams cache clear</b><br/>Run as the user. Closes Teams,<br/>empties the cache, starts new<br/>Teams again"):::tool
    R3L["%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\<br/>LocalCache\Microsoft\MSTeams\<br/>%APPDATA%\Microsoft\Teams\ (classic, if still<br/>there)"]:::local --> R3T
    R3T --> R3O["Console only"]:::out
    R4T("<b>Print spooler clear</b><br/>Admin. Stops Spooler, deletes .SPL<br/>/ .SHD jobs, starts it +<br/>dependants"):::tool
    R4L["Spool folder from<br/>HKLM\SYSTEM\CurrentControlSet\Control\Print\<br/>Printers<br/>(default C:\Windows\System32\spool\PRINTERS\)"]:::local --> R4T
    R4T --> R4O["Console only"]:::out
    R5T("<b>Office activation reset</b><br/>Admin. Get Help<br/>ResetOfficeActivation#59; signs<br/>Office out (success = 80)"):::tool
    R5N["<b>Downloads</b><br/>aka.ms/SaRA_EnterpriseVersionFiles: Get Help<br/>(Microsoft signature checked)"]:::net --> R5T
    R5L["Office licences + cached sign-ins of the<br/>account running it<br/>dsregcmd"]:::local --> R5T
    R5T --> R5O["C:\ProgramData\OfficeActivationReset\GetHelp_<br/>#lt;time#gt;.log<br/>The Get Help download is deleted afterwards"]:::out
    R6T("<b>Teams Meeting add-in fix</b><br/>Run as the user. Closes classic<br/>Outlook#59; fixes LoadBehavior,<br/>disabled list, do-not-disable list"):::tool
    R6L["HKCU / HKLM<br/>...\Office\Outlook\Addins\TeamsAddin.<br/>FastConnect<br/>HKCU ...\Office\16.0\Outlook\Resiliency\"]:::local --> R6T
    R6T --> R6O["Console only"]:::out
    R7T("<b>OneDrive reset</b><br/>Run as the user (refuses admin).<br/>OneDrive.exe /reset, then makes<br/>sure it starts again"):::tool
    R7L["OneDrive.exe: running copy, then HKCU<br/>OneDriveTrigger, then the 3 install folders<br/>Accounts + libraries:<br/>HKCU\Software\Microsoft\OneDrive\Accounts"]:::local --> R7T
    R7T --> R7O["Console only"]:::out
```

## Diagnose

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart LR
    classDef tool fill:#CFEBC8,stroke:#5E9E55,color:#1b1b1b
    classDef local fill:#FFFFFF,stroke:#9A9A9A,color:#1b1b1b
    classDef out fill:#FFF0A6,stroke:#C9AF2E,color:#1b1b1b
    classDef net fill:#CFE2FA,stroke:#5F8FCB,color:#1b1b1b
    classDef auth fill:#FFD8BE,stroke:#D98A57,color:#1b1b1b
    D1T("<b>Quick triage</b><br/>Read-only. Problems first, on one<br/>page<br/>Runs Device inventory + Entra /<br/>Intune health inside it"):::tool
    D1N["<b>Online checks (no sign-in)</b><br/>Pings the gateway, resolves<br/>login.microsoftonline.com<br/>Port 443 to the Entra / Intune endpoints"]:::net --> D1T
    D1L["System + Application event logs, Get-HotFix,<br/>AV (SecurityCenter2), Defender, pending reboot<br/>-Reports: netsh wlan show wlanreport, powercfg<br/>/batteryreport"]:::local --> D1T
    D1T --> D1O["C:\Triage\Triage_#lt;PC#gt;_#lt;time#gt;.html<br/>-Reports: C:\Triage\WiFi_#lt;PC#gt;_#lt;time#gt;.html and<br/>Battery_#lt;PC#gt;_#lt;time#gt;.html"]:::out
    D2T("<b>Performance check</b><br/>Read-only by default. -Fix asks<br/>before each change: power plan,<br/>max CPU state, startup apps"):::tool
    D2L["CIM performance counters (30 s), app hang +<br/>low memory + start-up events, powercfg<br/>Startup apps: Run keys, Startup folders,<br/>StartupApproved"]:::local --> D2T
    D2T --> D2O["C:\Triage\Performance_#lt;PC#gt;_#lt;time#gt;.html"]:::out
    D3T("<b>Before / after comparison</b><br/>Read-only. Rule-based write-up,<br/>nothing sent anywhere"):::tool
    D3L["C:\Triage\: Triage_, Performance_, WiFi_ and<br/>Battery_ reports for this PC (last 30 days)"]:::local --> D3T
    D3T --> D3O["C:\Triage\Report_#lt;PC#gt;_#lt;time#gt;.html"]:::out
    D4T("<b>Entra / Intune health</b><br/>Read-only by default. -Sync and<br/>-CollectLogs need admin"):::tool
    D4N["<b>Online (no sign-in)</b><br/>Port 443: login.microsoftonline.com,<br/>enterpriseregistration.windows.net,<br/>enrollment.manage.microsoft.com<br/>-Sync: the device checks in with Intune"]:::net <--> D4T
    D4L["dsregcmd /status, HKLM Enrollments,<br/>EnterpriseMgmt tasks, machine certificates,<br/>IME service + log, event log errors"]:::local --> D4T
    D4T --> D4O["Console only<br/>-CollectLogs:<br/>C:\EntraIntuneHealth\EntraIntune_#lt;PC#gt;_#lt;time#gt;.zip<br/>(dsregcmd, results, IME logs, MDM diagnostics,<br/>.evtx)"]:::out
    D5T("<b>BitLocker key backup check</b><br/>Admin, read-only by default. Never<br/>shows the keys"):::tool
    D5N["<b>Online (no sign-in)</b><br/>-Fix backs keys up to Entra with the device's<br/>own join (BackupToAAD-BitLockerKeyProtector)"]:::net <--> D5T
    D5L["dsregcmd (Entra joined?)<br/>BitLocker management log, events 845 / 846<br/>Get-BitLockerVolume"]:::local --> D5T
    D5T --> D5O["Console only"]:::out
    D6T("<b>Device inventory</b><br/>Read-only. Model, serial, RAM,<br/>disks + wear, monitors, battery,<br/>network, TPM"):::tool
    D6L["CIM / WMI classes (Win32_*, WmiMonitorID,<br/>Win32_Tpm)<br/>Get-PhysicalDisk + reliability counters"]:::local --> D6T
    D6T --> D6O["C:\DeviceInventory\Inventory_#lt;PC#gt;_#lt;time#gt;.html<br/>(+ .json with -Json)"]:::out
    D7T("<b>Disk usage report</b><br/>Read-only. Biggest folders, files<br/>and safe cleanup targets"):::tool
    D7L["Folder + file sizes under a path (default the<br/>system drive)"]:::local --> D7T
    D7T --> D7O["C:\DiskUsageReports\DiskUsage_#lt;PC#gt;_#lt;date#gt;.html"]:::out
    D8T("<b>Disk usage browser (GUI)</b><br/>Read-only, own window. Can't<br/>delete anything"):::tool
    D8L["Live folder sizes, starting at the system<br/>drive"]:::local --> D8T
    D8T --> D8O["Nothing saved"]:::out
    D9T("<b>Event triage (GUI)</b><br/>Read-only, own window. Groups<br/>event noise into what's wrong"):::tool
    D9N["<b>Online (optional)</b><br/>Remote PCs over WinRM or RPC, optional<br/>credentials<br/>Search button opens a Google search"]:::net --> D9T
    D9L["Event logs on this PC"]:::local --> D9T
    D9T --> D9O["Mutes:<br/>%APPDATA%\EventTriage\EventTriage.mutes.json<br/>CSV export: wherever you pick"]:::out
```

## Report (Microsoft 365 tenant)

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 400}}}%%
flowchart LR
    classDef tool fill:#CFEBC8,stroke:#5E9E55,color:#1b1b1b
    classDef local fill:#FFFFFF,stroke:#9A9A9A,color:#1b1b1b
    classDef out fill:#FFF0A6,stroke:#C9AF2E,color:#1b1b1b
    classDef net fill:#CFE2FA,stroke:#5F8FCB,color:#1b1b1b
    classDef auth fill:#FFD8BE,stroke:#D98A57,color:#1b1b1b
    P1T("<b>M365 licence report (Excel)</b><br/>No admin. Users + licences,<br/>reclaim and unlicensed sheets"):::tool
    P1A["<b>Microsoft Graph sign-in</b><br/>Pick the tenant, or -TenantId<br/>User.Read.All, Organization.Read.All,<br/>Directory.Read.All, Group.Read.All (+<br/>AuditLog.Read.All for last sign-in)<br/>Read-only"]:::auth --> P1T
    P1N["<b>Downloads</b><br/>PowerShell Gallery: Graph modules +<br/>ImportExcel, only with -InstallMissingModules"]:::net --> P1T
    P1T --> P1O["Documents\M365Reports\M365-License-Report_<br/>#lt;client#gt;_#lt;time#gt;.xlsx"]:::out
    P2T("<b>Exchange + Planner usage</b><br/>No admin. Who's licensed but not<br/>using it"):::tool
    P2A["<b>Microsoft Graph + Exchange Online sign-in</b><br/>User.Read.All, Reports.Read.All,<br/>AuditLog.Read.All, Organization.Read.All,<br/>ReportSettings.ReadWrite.All<br/>GDAP: Exchange via -DelegatedOrganization<br/>Asks to un-conceal report names for the run,<br/>then restores"]:::auth <--> P2T
    P2T --> P2O["Documents\M365Reports\M365_Usage_#lt;tenant#gt;_<br/>#lt;time#gt;.csv<br/>(+ .xlsx with ImportExcel)"]:::out
```

## Every folder it writes to on the PC

`<PC>` is the computer name and `<time>` a timestamp. Folders are created on first use.

| Folder | Written by |
|---|---|
| `C:\ProgramData\EndpointToolkit\` | Launcher (toolkit copies), Intune primary user (_modules) |
| `C:\ProgramData\DeploymentMaster\` | New device setup (Reports, Logs) |
| `C:\ProgramData\McAfeeRemoval\` | McAfee removal |
| `C:\ProgramData\Debloat\` | OEM debloat |
| `C:\ProgramData\OEMUpdates\ + Dell\OEMUpdates\` | OEM drivers + BIOS |
| `C:\ProgramData\AppDeploy\Logs\` | Chrome + Adobe Reader |
| `C:\ProgramData\OfficeActivationReset\` | Office activation reset |
| `C:\ProgramData\WindowsUpdateReset\` | Windows Update reset |
| `C:\OfficeReset\` | M365 Apps reset + reinstall |
| `C:\Triage\` | Quick triage, Performance check, Before / after comparison |
| `C:\DeviceInventory\` | Device inventory |
| `C:\DiskUsageReports\` | Disk usage report |
| `C:\DriverExport\` | Driver export |
| `C:\EntraIntuneHealth\` | Entra / Intune health (-CollectLogs) |
| `Documents\M365Reports\` | M365 licence report, Exchange + Planner usage |
| `%APPDATA%\EventTriage\` | Event triage (mutes) |
| `%TEMP%` | Window run options, Chrome + Reader downloads, Driver import unzip |
| Console only (no file: keep a transcript) | Intune primary user, Windows repair, Teams cache, Print spooler, Teams add-in fix, OneDrive reset, BitLocker check, Driver import |

`Documents` is the Documents folder of the account running the tool, which follows OneDrive redirection.
