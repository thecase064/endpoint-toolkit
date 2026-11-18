@{
    # Error codes the toolkit already explains, gathered in one place for the error code explainer
    # (Tools/ErrorCodes). Generated from the tools' own tables; tests/Test-Repo.ps1 checks they still match,
    # so change a meaning in the tool and here together.
    #   Code     0x-prefixed hex for 32-bit codes, plain digits for exit / problem codes, or text (AADSTS...)
    #   Source   where the code comes from, shown in front of the meaning
    #   Meaning  what it means;  Fix  what to do (may be empty)
    Codes = @(
        @{ Code = '0x80240016'; Source = 'Windows Update / upgrade'; Meaning = 'Another install was running, or a restart was pending.'; Fix = 'Restart, then check for updates again.' }
        @{ Code = '0x8024000B'; Source = 'Windows Update / upgrade'; Meaning = 'The install was cancelled, usually by a shutdown or restart part-way through.'; Fix = 'It retries by itself. Leave the PC on and plugged in.' }
        @{ Code = '0x80240020'; Source = 'Windows Update / upgrade'; Meaning = 'It was waiting for someone to sign in.'; Fix = 'Usually fine: it installs once a user is signed in.' }
        @{ Code = '0x80240017'; Source = 'Windows Update / upgrade'; Meaning = 'Not applicable to this PC.'; Fix = 'Usually harmless.' }
        @{ Code = '0x80240034'; Source = 'Windows Update / upgrade'; Meaning = 'The download failed.'; Fix = 'Check the connection, proxy or web filter, then Repair > Windows Update reset.' }
        @{ Code = '0x8024200D'; Source = 'Windows Update / upgrade'; Meaning = 'The download was incomplete.'; Fix = 'It retries by itself; if it keeps happening, Repair > Windows Update reset.' }
        @{ Code = '0x80242016'; Source = 'Windows Update / upgrade'; Meaning = 'The update was in an unexpected state after the restart.'; Fix = 'It usually retries by itself.' }
        @{ Code = '0x80246007'; Source = 'Windows Update / upgrade'; Meaning = 'The update files were missing or incomplete.'; Fix = 'Repair > Windows Update reset, then check for updates.' }
        @{ Code = '0x8024402C'; Source = 'Windows Update / upgrade'; Meaning = 'Couldn''t reach the update server: its name didn''t resolve.'; Fix = 'Check DNS and any proxy; with WSUS, check the server name in the policy.' }
        @{ Code = '0x8024401C'; Source = 'Windows Update / upgrade'; Meaning = 'The update server timed out.'; Fix = 'Check the connection and proxy; a WSUS server may be overloaded.' }
        @{ Code = '0x80244019'; Source = 'Windows Update / upgrade'; Meaning = 'The update server answered "not found" (HTTP 404).'; Fix = 'The WSUS address in the policy is wrong, or a proxy is changing it.' }
        @{ Code = '0x80244022'; Source = 'Windows Update / upgrade'; Meaning = 'The update server is unavailable (HTTP 503).'; Fix = 'WSUS: its IIS application pool has probably stopped; restart it on the server.' }
        @{ Code = '0x8024402F'; Source = 'Windows Update / upgrade'; Meaning = 'Part of the download was blocked, usually by a web filter or proxy.'; Fix = 'Let the Windows Update endpoints through the web filter / proxy.' }
        @{ Code = '0x8024002E'; Source = 'Windows Update / upgrade'; Meaning = 'Windows Update is turned off by policy.'; Fix = 'See the Policy checks.' }
        @{ Code = '0x80070422'; Source = 'Windows Update / upgrade'; Meaning = 'An update service is disabled.'; Fix = 'See the Services checks.' }
        @{ Code = '0x800F0922'; Source = 'Windows Update / upgrade'; Meaning = 'The install failed: often too little space (including the small system partitions) or a VPN / proxy in the way.'; Fix = 'Free space, disconnect any VPN, restart and try again.' }
        @{ Code = '0x800F081F'; Source = 'Windows Update / upgrade'; Meaning = 'Windows couldn''t find the files it needs to repair itself.'; Fix = 'Run Repair > Windows repair checks (DISM + SFC), then try again.' }
        @{ Code = '0x80073712'; Source = 'Windows Update / upgrade'; Meaning = 'Windows'' component store is damaged.'; Fix = 'Run Repair > Windows repair checks (DISM + SFC), then try again.' }
        @{ Code = '0x800F0831'; Source = 'Windows Update / upgrade'; Meaning = 'A package this update builds on is missing.'; Fix = 'Install the latest cumulative update from the Microsoft Update Catalog, or run Windows repair checks.' }
        @{ Code = '0x80070002'; Source = 'Windows Update / upgrade'; Meaning = 'Files the update needs are missing (file not found).'; Fix = 'Repair > Windows Update reset, then check for updates.' }
        @{ Code = '0x80070003'; Source = 'Windows Update / upgrade'; Meaning = 'Files the update needs are missing (path not found).'; Fix = 'Repair > Windows Update reset, then check for updates.' }
        @{ Code = '0x8007000D'; Source = 'Windows Update / upgrade'; Meaning = 'Update data is corrupt.'; Fix = 'Repair > Windows Update reset; if it repeats, Windows repair checks.' }
        @{ Code = '0x8007000E'; Source = 'Windows Update / upgrade'; Meaning = 'Ran out of memory or space while installing.'; Fix = 'Free disk space, restart and try again.' }
        @{ Code = '0x80070070'; Source = 'Windows Update / upgrade'; Meaning = 'Not enough disk space.'; Fix = 'Free space on the system drive (20 GB for a feature update).' }
        @{ Code = '0x800705B4'; Source = 'Windows Update / upgrade'; Meaning = 'The update took too long or was interrupted.'; Fix = 'Leave it on and plugged in; restart and try again.' }
        @{ Code = '0x80070020'; Source = 'Windows Update / upgrade'; Meaning = 'Another program had a file locked (often antivirus or backup).'; Fix = 'Restart and try again; check any third-party antivirus.' }
        @{ Code = '0x80070005'; Source = 'Windows Update / upgrade'; Meaning = 'Access denied.'; Fix = 'Often third-party security software; restart and try again.' }
        @{ Code = '0x80070643'; Source = 'Windows Update / upgrade'; Meaning = 'The installer failed. Common with the recovery partition (WinRE) update when that partition is too small, and with .NET updates.'; Fix = 'Check which update it was; a WinRE update needs a bigger recovery partition (Microsoft has the steps).' }
        @{ Code = '0xC1900101'; Source = 'Windows Update / upgrade'; Meaning = 'A driver problem during the upgrade, so it rolled back.'; Fix = 'Update drivers (Build > OEM drivers), unplug extra devices, remove third-party antivirus, try again.' }
        @{ Code = '0xC1900107'; Source = 'Windows Update / upgrade'; Meaning = 'Cleanup from an earlier upgrade attempt is still pending.'; Fix = 'Restart, then try again.' }
        @{ Code = '0xC1900200'; Source = 'Windows Update / upgrade'; Meaning = 'This PC doesn''t meet the requirements for that version.'; Fix = 'See the Upgrade checks for the reason.' }
        @{ Code = '0xC1900202'; Source = 'Windows Update / upgrade'; Meaning = 'This PC doesn''t meet the requirements for that version.'; Fix = 'See the Upgrade checks for the reason.' }
        @{ Code = '0xC1900208'; Source = 'Windows Update / upgrade'; Meaning = 'An incompatible app is blocking the upgrade.'; Fix = 'Run as admin to see Setup''s compatibility report; update or remove the app.' }
        @{ Code = '0xC190020E'; Source = 'Windows Update / upgrade'; Meaning = 'Not enough free space for the upgrade.'; Fix = 'Free at least 20 GB on the system drive.' }
        @{ Code = '0xC1900223'; Source = 'Windows Update / upgrade'; Meaning = 'Problem downloading the upgrade; Windows Update tries again later.'; Fix = 'Usually nothing to do; if it repeats, check the proxy / web filter.' }
        @{ Code = '0x800705B4'; Source = 'Windows Time (w32tm)'; Meaning = 'no time data came back: the time source didn''t answer (UDP 123 blocked by a firewall or proxy, or the source is down)'; Fix = '' }
        @{ Code = '0x80070426'; Source = 'Windows Time (w32tm)'; Meaning = 'the Windows Time service isn''t running'; Fix = '' }
        @{ Code = '0x80070005'; Source = 'Windows Time (w32tm)'; Meaning = 'access denied: run it as admin'; Fix = '' }
        @{ Code = '0x80072AF9'; Source = 'Windows Time (w32tm)'; Meaning = 'the time server''s name didn''t resolve (DNS)'; Fix = '' }
        @{ Code = '0x80072AFC'; Source = 'Windows Time (w32tm)'; Meaning = 'the time server''s name didn''t resolve (DNS)'; Fix = '' }
        @{ Code = '1'; Source = 'Device Manager problem code'; Meaning = 'not configured correctly'; Fix = 'Device Manager > right-click > Properties shows the detail.' }
        @{ Code = '3'; Source = 'Device Manager problem code'; Meaning = 'driver may be corrupted'; Fix = 'Reinstall the driver from the manufacturer''s support page (Dell / HP / Lenovo) or Windows Update.' }
        @{ Code = '10'; Source = 'Device Manager problem code'; Meaning = 'can''t start'; Fix = 'Restart. If it''s still there, reinstall the driver from the manufacturer.' }
        @{ Code = '12'; Source = 'Device Manager problem code'; Meaning = 'not enough free resources'; Fix = 'Device Manager > right-click > Properties shows the detail.' }
        @{ Code = '14'; Source = 'Device Manager problem code'; Meaning = 'needs a restart'; Fix = 'Restart. If it''s still there, reinstall the driver from the manufacturer.' }
        @{ Code = '18'; Source = 'Device Manager problem code'; Meaning = 'drivers need reinstalling'; Fix = 'Reinstall the driver from the manufacturer''s support page (Dell / HP / Lenovo) or Windows Update.' }
        @{ Code = '19'; Source = 'Device Manager problem code'; Meaning = 'registry configuration damaged'; Fix = 'Device Manager > right-click > Properties shows the detail.' }
        @{ Code = '21'; Source = 'Device Manager problem code'; Meaning = 'being removed'; Fix = 'Device Manager > right-click > Properties shows the detail.' }
        @{ Code = '22'; Source = 'Device Manager problem code'; Meaning = 'disabled'; Fix = 'Device Manager > right-click > Enable device.' }
        @{ Code = '24'; Source = 'Device Manager problem code'; Meaning = 'not present or not working'; Fix = 'Device Manager > right-click > Properties shows the detail.' }
        @{ Code = '28'; Source = 'Device Manager problem code'; Meaning = 'no driver installed'; Fix = 'Reinstall the driver from the manufacturer''s support page (Dell / HP / Lenovo) or Windows Update.' }
        @{ Code = '29'; Source = 'Device Manager problem code'; Meaning = 'disabled in the firmware'; Fix = 'Device Manager > right-click > Properties shows the detail.' }
        @{ Code = '31'; Source = 'Device Manager problem code'; Meaning = 'driver couldn''t load'; Fix = 'Reinstall the driver from the manufacturer''s support page (Dell / HP / Lenovo) or Windows Update.' }
        @{ Code = '32'; Source = 'Device Manager problem code'; Meaning = 'driver service disabled'; Fix = 'Device Manager > right-click > Properties shows the detail.' }
        @{ Code = '37'; Source = 'Device Manager problem code'; Meaning = 'driver couldn''t start'; Fix = 'Restart. If it''s still there, reinstall the driver from the manufacturer.' }
        @{ Code = '39'; Source = 'Device Manager problem code'; Meaning = 'driver missing or corrupted'; Fix = 'Reinstall the driver from the manufacturer''s support page (Dell / HP / Lenovo) or Windows Update.' }
        @{ Code = '41'; Source = 'Device Manager problem code'; Meaning = 'driver loaded but device not found'; Fix = 'Device Manager > right-click > Properties shows the detail.' }
        @{ Code = '43'; Source = 'Device Manager problem code'; Meaning = 'stopped after reporting a problem'; Fix = 'Restart. If it''s still there, reinstall the driver from the manufacturer.' }
        @{ Code = '45'; Source = 'Device Manager problem code'; Meaning = 'not connected'; Fix = 'Normal for a device that is switched off or unplugged (Bluetooth especially).' }
        @{ Code = '47'; Source = 'Device Manager problem code'; Meaning = 'prepared for safe removal'; Fix = 'Device Manager > right-click > Properties shows the detail.' }
        @{ Code = '48'; Source = 'Device Manager problem code'; Meaning = 'driver blocked'; Fix = 'Reinstall the driver from the manufacturer''s support page (Dell / HP / Lenovo) or Windows Update.' }
        @{ Code = '52'; Source = 'Device Manager problem code'; Meaning = 'driver signature couldn''t be verified'; Fix = 'Reinstall the driver from the manufacturer''s support page (Dell / HP / Lenovo) or Windows Update.' }
        @{ Code = '1'; Source = 'Dell Command | Update exit code'; Meaning = 'Updates installed; a restart is needed to finish.'; Fix = '' }
        @{ Code = '2'; Source = 'Dell Command | Update exit code'; Meaning = 'Dell Command | Update hit an unknown error - see the log.'; Fix = '' }
        @{ Code = '3'; Source = 'Dell Command | Update exit code'; Meaning = 'Dell Command | Update says this isn''t a Dell.'; Fix = '' }
        @{ Code = '4'; Source = 'Dell Command | Update exit code'; Meaning = 'Not running as administrator.'; Fix = '' }
        @{ Code = '5'; Source = 'Dell Command | Update exit code'; Meaning = 'A restart is already pending from earlier updates. Restart, then run this again.'; Fix = '' }
        @{ Code = '6'; Source = 'Dell Command | Update exit code'; Meaning = 'Dell Command | Update is already running (app or another script). Close it and retry.'; Fix = '' }
        @{ Code = '7'; Source = 'Dell Command | Update exit code'; Meaning = 'Dell Command | Update doesn''t support this model.'; Fix = '' }
        @{ Code = '8'; Source = 'Dell Command | Update exit code'; Meaning = 'No update types selected (toolkit bug - please report it).'; Fix = '' }
        @{ Code = '107'; Source = 'Dell Command | Update exit code'; Meaning = 'Dell Command | Update rejected an option (often a folder it won''t write to) - its reason is in the log.'; Fix = '' }
        @{ Code = '501'; Source = 'Dell Command | Update exit code'; Meaning = 'The scan failed while working out the available updates.'; Fix = '' }
        @{ Code = '503'; Source = 'Dell Command | Update exit code'; Meaning = 'A download failed during the scan - check the internet connection.'; Fix = '' }
        @{ Code = '1000'; Source = 'Dell Command | Update exit code'; Meaning = 'Couldn''t read the result of the install.'; Fix = '' }
        @{ Code = '1002'; Source = 'Dell Command | Update exit code'; Meaning = 'A download failed during the install - check the internet connection.'; Fix = '' }
        @{ Code = '3000'; Source = 'Dell Command | Update exit code'; Meaning = 'The Dell Client Management Service isn''t running.'; Fix = '' }
        @{ Code = '3001'; Source = 'Dell Command | Update exit code'; Meaning = 'The Dell Client Management Service isn''t installed - reinstall Dell Command | Update.'; Fix = '' }
        @{ Code = '3003'; Source = 'Dell Command | Update exit code'; Meaning = 'The Dell Client Management Service is busy - wait a minute and retry.'; Fix = '' }
        @{ Code = '3005'; Source = 'Dell Command | Update exit code'; Meaning = 'The Dell Client Management Service is installing pending updates - wait and retry.'; Fix = '' }
        @{ Code = '256'; Source = 'HP Image Assistant exit code'; Meaning = 'Nothing to install.'; Fix = '' }
        @{ Code = '257'; Source = 'HP Image Assistant exit code'; Meaning = 'Nothing was selected to install.'; Fix = '' }
        @{ Code = '3010'; Source = 'HP Image Assistant exit code'; Meaning = 'Updates installed; a restart is needed to finish.'; Fix = '' }
        @{ Code = '3020'; Source = 'HP Image Assistant exit code'; Meaning = 'One or more updates failed to install - see the report folder.'; Fix = '' }
        @{ Code = '4096'; Source = 'HP Image Assistant exit code'; Meaning = 'HP Image Assistant doesn''t support this model (it covers HP business PCs; consumer models use HP Support Assistant).'; Fix = '' }
        @{ Code = '4097'; Source = 'HP Image Assistant exit code'; Meaning = 'HP Image Assistant rejected the parameters (toolkit bug - please report it).'; Fix = '' }
        @{ Code = '4098'; Source = 'HP Image Assistant exit code'; Meaning = 'No internet connection.'; Fix = '' }
        @{ Code = '16384'; Source = 'HP Image Assistant exit code'; Meaning = 'HP Image Assistant couldn''t open HP''s reference file - check the internet connection and retry.'; Fix = '' }
        @{ Code = '0x801c03f2'; Source = 'Entra / Intune join'; Meaning = 'Device object not found in Entra. For hybrid join: is the computer in Entra Connect sync scope?'; Fix = '' }
        @{ Code = '0x801c001d'; Source = 'Entra / Intune join'; Meaning = 'Discovery failed: no SCP / tenant info. Check the Entra Connect SCP or the hybrid join GPO.'; Fix = '' }
        @{ Code = 'AADSTS700003'; Source = 'Entra / Intune join'; Meaning = 'Device object deleted or missing in Entra. Leave and rejoin (dsregcmd /forcerecovery on Entra joined).'; Fix = '' }
    )

    # HRESULT facility numbers (bits 16-26), from Microsoft's winerror.h.
    Facilities = @{
        0 = 'none (general)'
        1 = 'RPC'
        2 = 'COM dispatch'
        3 = 'COM storage'
        4 = 'COM interface (defined by the app or component)'
        7 = 'Win32 (a plain Windows error code)'
        8 = 'Windows'
        9 = 'security (SSPI)'
        10 = 'control'
        11 = 'certificates'
        12 = 'internet (WinINet)'
        13 = 'media server'
        14 = 'message queuing'
        15 = 'Setup API / servicing'
        16 = 'smart card'
        17 = 'COM+'
        18 = 'AAF'
        19 = '.NET runtime'
        23 = 'side-by-side (SxS)'
        24 = 'Windows CE / MDM enrollment'
        25 = 'HTTP'
        32 = 'BITS (background transfers)'
        34 = 'state management'
        35 = 'Identity Server'
        36 = 'Windows Update'
        37 = 'Active Directory'
        38 = 'graphics'
        39 = 'shell'
        49 = 'BitLocker'
        51 = 'WinRM'
        80 = 'Microsoft Defender'
        208 = 'Delivery Optimization'
    }

    # Windows Setup extend codes (0xC1900101 - 0x40017): first digit = phase, rest = operation.
    # From Microsoft's "Windows upgrade error codes" page.
    SetupPhases = @{
        0 = 'unknown'
        1 = 'downlevel (still in the old Windows)'
        2 = 'Safe OS (WinRE)'
        3 = 'first boot'
        4 = 'second boot (OOBE)'
        5 = 'uninstall (rolling back)'
    }
    SetupOperations = @{
        0x0 = 'UNKNOWN'
        0x1 = 'COPY_PAYLOAD'
        0x2 = 'DOWNLOAD_UPDATES'
        0x3 = 'INSTALL_UPDATES'
        0x4 = 'INSTALL_RECOVERY_ENVIRONMENT'
        0x5 = 'INSTALL_RECOVERY_IMAGE'
        0x6 = 'REPLICATE_OC'
        0x7 = 'INSTALL_DRIVERS'
        0x8 = 'PREPARE_SAFE_OS'
        0x9 = 'PREPARE_ROLLBACK'
        0xA = 'PREPARE_FIRST_BOOT'
        0xB = 'PREPARE_OOBE_BOOT'
        0xC = 'APPLY_IMAGE'
        0xD = 'MIGRATE_DATA'
        0xE = 'SET_PRODUCT_KEY'
        0xF = 'ADD_UNATTEND'
        0x10 = 'ADD_DRIVER'
        0x11 = 'ENABLE_FEATURE'
        0x12 = 'DISABLE_FEATURE'
        0x13 = 'REGISTER_ASYNC_PROCESS'
        0x14 = 'REGISTER_SYNC_PROCESS'
        0x15 = 'CREATE_FILE'
        0x16 = 'CREATE_REGISTRY'
        0x17 = 'BOOT'
        0x18 = 'SYSPREP'
        0x19 = 'OOBE'
        0x1A = 'BEGIN_FIRST_BOOT'
        0x1B = 'END_FIRST_BOOT'
        0x1C = 'BEGIN_OOBE_BOOT'
        0x1D = 'END_OOBE_BOOT'
        0x1E = 'PRE_OOBE'
        0x1F = 'POST_OOBE'
        0x20 = 'ADD_PROVISIONING_PACKAGE'
    }

    # Blue screen stop codes (bug check codes): Microsoft's name, and the usual cause.
    StopCodes = @{
        0xA = @('IRQL_NOT_LESS_OR_EQUAL', 'Usually a driver, sometimes faulty memory.')
        0x19 = @('BAD_POOL_HEADER', 'Usually a driver, sometimes memory.')
        0x1A = @('MEMORY_MANAGEMENT', 'Often faulty memory: run Windows Memory Diagnostic.')
        0x1E = @('KMODE_EXCEPTION_NOT_HANDLED', 'Usually a driver: the crash dump or Event triage names it; update or remove recently added drivers.')
        0x3B = @('SYSTEM_SERVICE_EXCEPTION', 'Usually a driver or security software.')
        0x50 = @('PAGE_FAULT_IN_NONPAGED_AREA', 'A driver, faulty memory or a failing disk.')
        0x7A = @('KERNEL_DATA_INPAGE_ERROR', 'Usually the disk, its cable or controller: check the disk health.')
        0x7B = @('INACCESSIBLE_BOOT_DEVICE', 'Windows can''t read its boot disk: storage driver, the BIOS disk mode, or a failing disk.')
        0x7E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'Usually a driver: the crash dump or Event triage names it; update or remove recently added drivers.')
        0x7F = @('UNEXPECTED_KERNEL_MODE_TRAP', 'Often hardware (memory, overheating) or a driver.')
        0x9F = @('DRIVER_POWER_STATE_FAILURE', 'A driver failed going into or out of sleep: update drivers, BIOS and dock firmware.')
        0xA0 = @('INTERNAL_POWER_ERROR', 'Power management: update the BIOS and chipset drivers.')
        0xC2 = @('BAD_POOL_CALLER', 'Usually a driver: the crash dump or Event triage names it; update or remove recently added drivers.')
        0xD1 = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'Usually a driver: the crash dump or Event triage names it; update or remove recently added drivers.')
        0xEF = @('CRITICAL_PROCESS_DIED', 'A critical Windows process stopped: run Windows repair checks (DISM + SFC) and check recent driver changes.')
        0xF4 = @('CRITICAL_OBJECT_TERMINATION', 'A critical process stopped, often because the disk failed to read: check the disk health.')
        0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'A processor stopped responding: update the BIOS and chipset drivers; check for overheating.')
        0x116 = @('VIDEO_TDR_FAILURE', 'The graphics driver stopped responding: update or reinstall it.')
        0x117 = @('VIDEO_TDR_TIMEOUT_DETECTED', 'The graphics driver stopped responding: update or reinstall it.')
        0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'A hardware error the processor reported (memory, CPU, overheating, power).')
        0x133 = @('DPC_WATCHDOG_VIOLATION', 'A driver ran too long: often storage or network drivers, or SSD firmware.')
        0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'Usually a driver or damaged system files.')
        0x13A = @('KERNEL_MODE_HEAP_CORRUPTION', 'Usually a driver: the crash dump or Event triage names it; update or remove recently added drivers.')
        0x154 = @('UNEXPECTED_STORE_EXCEPTION', 'Often the disk (or antivirus): check the disk health and firmware.')
        0xC000021A = @('STATUS_SYSTEM_PROCESS_TERMINATED', 'A core Windows process died, often after a bad update or driver: Windows repair checks, or uninstall the latest update from WinRE.')
    }
}
