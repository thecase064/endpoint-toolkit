<#
.SYNOPSIS
    Shared helpers for toolkit scripts. Dot-source it; it isn't a menu tool and does nothing on its own.

.DESCRIPTION
    Get-CurrentUserName     The account running this script (DOMAIN\user or AzureAD\user).
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
