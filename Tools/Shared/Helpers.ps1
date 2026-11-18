<#
.SYNOPSIS
    Shared helpers for toolkit scripts. Dot-source it; it isn't a menu tool and does nothing on its own.

.DESCRIPTION
    Get-CurrentUserName     The account running this script (DOMAIN\user or AzureAD\user).
    Get-CurrentUserSid      Its SID (S-1-5-18 for SYSTEM).
    Resolve-AccountSid      DOMAIN\name for a SID, or nothing when Windows can't name it (a deleted
                            account, no domain controller in reach, an Entra account not cached here).
    Get-LicenseNameMap      Microsoft's own product names for licences (SPB -> Microsoft 365 Business
                            Premium), from its published CSV, cached for a week.
    Get-OtherSignedInUser   Who is signed in at the console, when that's not the account running this.
                            Per-user fixes (Teams, Outlook, Office sign-in) only touch the account
                            running them, so this lets a tool warn when that's the wrong person.
    Test-RunningAsAdmin     Whether this is running elevated (or as SYSTEM). For tools whose app
                            refuses to run with admin rights, such as OneDrive.

    Get-GetHelpCmd          Downloads Microsoft's Get Help command line (GetHelpCmd.exe), unpacks it
                            and refuses it unless it's validly signed by Microsoft.
    Invoke-GetHelpScenario  Runs one Get Help scenario from the exe's own folder, shows the output live,
                            saves it to a log and returns the result code.
    Clear-GetHelpDownload   Removes the download afterwards.

    Get Help replaced the SaRA command line, which Microsoft removed from Windows in March 2026.
    Each build stops working 90 days after it's made, so it's downloaded fresh on every run and
    never bundled in the repo.

.EXAMPLE
    . (Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'Shared') 'Helpers.ps1')
#>

function Get-CurrentUserName {
    try { [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch { if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { [string]$env:USERNAME } }
}

function Get-CurrentUserSid {
    try { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $null }
}

function Resolve-AccountSid {
    param([string] $Sid)
    try { ([Security.Principal.SecurityIdentifier]::new($Sid)).Translate([Security.Principal.NTAccount]).Value }
    catch { $null }
}

function Get-OtherSignedInUser {
    # Returns the console user (e.g. AzureAD\JaneDoe) when it differs from the account running this
    # script, otherwise $null. Remote/RDP sessions have no console user, so they return $null too.
    try {
        $me      = Get-CurrentUserName
        $console = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($console -and $me -and $console -ne $me) { return $console }
    }
    catch { Write-Verbose "Couldn't read the signed-in user: $($_.Exception.Message)" }
    $null
}

function Test-RunningAsAdmin {
    # True when this process has a full admin token: an elevated window, an admin's remote session
    # (Enter-PSSession) or SYSTEM (RMM). False for a normal user window, or if it can't be told.
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $false }
}

function Get-GetHelpCmd {
    # Downloads and unpacks Get Help into <WorkDir>\GetHelp, checks the signature and returns
    # GetHelpCmd.exe as a FileInfo. Throws if anything is off; never runs an unsigned exe.
    param([Parameter(Mandatory)][string] $WorkDir)

    $zip = Join-Path $WorkDir 'GetHelpCmd.zip'
    $dir = Join-Path $WorkDir 'GetHelp'
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    Remove-Item -LiteralPath $zip, $dir -Recurse -Force -ErrorAction SilentlyContinue

    Invoke-WebRequest -Uri 'https://aka.ms/SaRA_EnterpriseVersionFiles' -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    $exe = Get-ChildItem -LiteralPath $dir -Filter 'GetHelpCmd.exe' -Recurse -File | Select-Object -First 1
    if (-not $exe) { throw 'GetHelpCmd.exe not found in the download - Microsoft may have changed the package.' }

    $sig = Get-AuthenticodeSignature -FilePath $exe.FullName
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') {
        throw "GetHelpCmd.exe failed signature validation ($($sig.Status)) - not running it."
    }
    $exe
}

function Invoke-GetHelpScenario {
    # Runs "GetHelpCmd.exe -S <Scenario> -AcceptEula <Switches>" from the exe's own folder, as
    # Microsoft's instructions do. Output is shown live and saved to LogFile.
    # Get Help prints its result as "NN: message"; that line wins, the exit code is the fallback.
    param(
        [Parameter(Mandatory)][System.IO.FileInfo] $Exe,
        [Parameter(Mandatory)][string] $Scenario,
        [string[]] $Switches = @(),
        [Parameter(Mandatory)][string] $LogFile
    )
    $argList = @('-S', $Scenario, '-AcceptEula') + $Switches
    Push-Location -LiteralPath $Exe.DirectoryName
    try {
        $output = @(& $Exe.FullName @argList | Tee-Object -FilePath $LogFile |
                    ForEach-Object { Write-Host "    $_"; $_ })
        $exitCode = $LASTEXITCODE
    }
    finally { Pop-Location }

    $line = $output | Where-Object { "$_" -match '^\s*\d{2}:\s' } | Select-Object -Last 1
    $code = if ("$line" -match '^\s*(\d{2}):') { [int]$Matches[1] } else { $exitCode }
    [pscustomobject]@{ Code = $code; ExitCode = $exitCode; Line = "$line".Trim(); Log = $LogFile }
}

function Clear-GetHelpDownload {
    param([Parameter(Mandatory)][string] $WorkDir)
    Remove-Item -LiteralPath (Join-Path $WorkDir 'GetHelpCmd.zip'), (Join-Path $WorkDir 'GetHelp') `
        -Recurse -Force -ErrorAction SilentlyContinue
}

$script:LicenseCsvUrl = 'https://download.microsoft.com/download/e/3/e/e3e9faf2-f28b-490a-9ada-c6089a1fc5b0/Product%20names%20and%20service%20plan%20identifiers%20for%20licensing.csv'
$script:LicenseCsvMaxBytes = 20MB

function ConvertFrom-LicenseCsv {
    # Reads Microsoft's licensing CSV into name lookups keyed by SKU part number (String_Id) and SKU id
    # (GUID); PowerShell hashtables ignore case. Throws when it doesn't look like that file.
    param([Parameter(Mandatory)][string] $Path)
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -gt $script:LicenseCsvMaxBytes) { throw "it's unexpectedly large ($([math]::Round($file.Length / 1MB)) MB)" }
    # Read as UTF-8 so the file's byte-order mark doesn't end up in the first column name.
    $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    $rows = @(($text -split "\r?\n" | Where-Object { $_ }) | ConvertFrom-Csv)
    if (-not $rows.Count -or -not $rows[0].PSObject.Properties['Product_Display_Name'] -or -not $rows[0].PSObject.Properties['String_Id'] -or -not $rows[0].PSObject.Properties['GUID']) {
        throw "it doesn't have the expected columns (Product_Display_Name, String_Id, GUID)"
    }
    $names = @{}
    foreach ($r in $rows) {
        $n = ([string]$r.Product_Display_Name).Trim()
        if (-not $n) { continue }
        foreach ($k in @(([string]$r.String_Id).Trim(), ([string]$r.GUID).Trim())) {
            if ($k -and -not $names.ContainsKey($k)) { $names[$k] = $n }
        }
    }
    if ($names.Count -lt 50) { throw "it only has $($names.Count) names in it" }
    $names
}

function Get-LicenseNameMap {
    # Microsoft's own product names for licences, from the CSV behind "Product names and service plan
    # identifiers for licensing" (the names the admin centres show). Downloaded at most once every
    # MaxAgeDays into CacheFolder; the cached copy is used when the download fails, whatever its age.
    # Returns Names (part number or SKU id -> name; empty when there's neither), Source ('downloaded' /
    # 'cached yyyy-MM-dd' / '') and Note (why not, when it couldn't).
    param(
        [string] $CacheFolder = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'EndpointToolkit'),
        [int] $MaxAgeDays = 7,
        [switch] $Offline
    )
    $cache  = Join-Path $CacheFolder 'LicenseNames.csv'
    $result = [pscustomobject]@{ Names = @{}; Source = ''; Note = '' }
    $fresh  = (Test-Path -LiteralPath $cache) -and ((Get-Item -LiteralPath $cache).LastWriteTime -gt (Get-Date).AddDays(-$MaxAgeDays))
    if (-not $fresh -and -not $Offline) {
        $tmp = Join-Path $CacheFolder ('LicenseNames.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        try {
            if (-not (Test-Path -LiteralPath $CacheFolder)) { New-Item -ItemType Directory -Path $CacheFolder -Force | Out-Null }
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'   # this function only; 5.1's progress bar slows downloads a lot
            Invoke-WebRequest -Uri $script:LicenseCsvUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 30
            $names = ConvertFrom-LicenseCsv $tmp
            Move-Item -LiteralPath $tmp -Destination $cache -Force
            $result.Names = $names
            $result.Source = 'downloaded'
            return $result
        }
        catch { $result.Note = "Couldn't get Microsoft's list: $($_.Exception.Message)" }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $cache) {
        try {
            $result.Names = ConvertFrom-LicenseCsv $cache
            $result.Source = 'cached ' + (Get-Item -LiteralPath $cache).LastWriteTime.ToString('yyyy-MM-dd')
        }
        catch { $result.Note = (@($result.Note, "The saved copy is unreadable: $($_.Exception.Message)") | Where-Object { $_ }) -join ' ' }
    }
    elseif ($Offline) { $result.Note = 'Not downloaded (-SkipNameDownload) and there is no saved copy.' }
    $result
}
