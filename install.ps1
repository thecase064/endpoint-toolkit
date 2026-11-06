<#
.SYNOPSIS
    One-line launcher for Endpoint Toolkit. Downloads the toolkit from GitHub and opens the window.

.DESCRIPTION
    Paste into PowerShell (as Administrator for the build tools):

        irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1 | iex

    For remote shells (Enter-PSSession, RMM consoles) there's a console-menu version:

        irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/console.ps1 | iex

    What it does:
      1. Downloads the repo at the chosen ref (branch, tag or commit) as a zip from GitHub.
      2. Extracts it to C:\ProgramData\EndpointToolkit\<ref>-<timestamp>\ and unblocks the files.
      3. Imports the module and opens the window (or the console menu where there's no desktop, or
         with -Console). Older copies beyond the newest three are tidied up.

    Nothing is installed permanently unless you pass -Install.

.PARAMETER Ref
    Branch, tag or commit to run. Defaults to $env:ETK_REF, then 'main'.
    Pin a release so a later push can't change what runs:  -Ref v1.0.0

.PARAMETER Install
    Also copy the module into your PowerShell modules folder, so later you can just run:
        Import-Module EndpointToolkit; etk

.PARAMETER Console
    Open the console menu instead of the window. console.ps1 is this with -Console.

.PARAMETER NoMenu
    Download and import only; don't open the window or menu.

.EXAMPLE
    irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1))) -Ref v1.0.0 -Install
#>
param(
    [string] $Ref,
    [switch] $Install,
    [switch] $Console,
    [switch] $NoMenu
)

# Everything runs inside this block so nothing (like $ErrorActionPreference) leaks into your session.
& {
    param([string] $Ref, $Install, $Console, $NoMenu)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest in 5.1 crawls with the progress bar on

    $Owner = 'thecase064'
    $Repo  = 'endpoint-toolkit'
    if (-not $Ref) { $Ref = if ($env:ETK_REF) { $env:ETK_REF } else { 'main' } }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # Lets the module load even where the machine policy is Restricted. Process scope only: gone when the window closes.
    try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop } catch {
        Write-Warning "Couldn't set a process execution policy (probably enforced by Group Policy): $($_.Exception.Message)"
    }

    $baseDir  = Join-Path $env:ProgramData 'EndpointToolkit'
    $safeRef  = $Ref -replace '[^\w.-]', '_'
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destDir  = Join-Path $baseDir "$safeRef-$stamp"
    $zipPath  = Join-Path ([IO.Path]::GetTempPath()) "endpoint-toolkit-$safeRef-$stamp.zip"
    $zipUrl   = "https://codeload.github.com/$Owner/$Repo/zip/$Ref"

    Write-Host "Endpoint Toolkit: downloading $Owner/$Repo @ $Ref ..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    }
    catch {
        throw "Download failed from $zipUrl - check the ref exists and the machine can reach github.com. $($_.Exception.Message)"
    }

    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $destDir -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    # GitHub zips wrap everything in a "<repo>-<ref>" folder; find the module wherever it landed.
    $psd1 = Get-ChildItem -LiteralPath $destDir -Filter 'EndpointToolkit.psd1' -Recurse | Select-Object -First 1
    if (-not $psd1) { throw "EndpointToolkit.psd1 not found in the download - is '$Ref' the right ref?" }
    $moduleRoot = $psd1.DirectoryName

    try { Get-ChildItem -LiteralPath $moduleRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue }
    catch { Write-Warning "Couldn't unblock files: $($_.Exception.Message)" }

    [pscustomobject]@{
        repo       = "$Owner/$Repo"
        ref        = $Ref
        downloaded = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $moduleRoot '.etk-source.json') -Encoding UTF8

    # Keep the newest three copies. Best effort: folders another user created may not be removable.
    Get-ChildItem -LiteralPath $baseDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending | Select-Object -Skip 3 |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    if ($Install) {
        $edition   = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
        $docs      = [Environment]::GetFolderPath('MyDocuments')     # follows OneDrive redirection
        if (-not $docs) { $docs = Join-Path $HOME 'Documents' }
        $version   = (Import-PowerShellDataFile -LiteralPath $psd1.FullName).ModuleVersion
        $installTo = Join-Path $docs "$edition\Modules\EndpointToolkit\$version"
        if (Test-Path -LiteralPath $installTo) { Remove-Item -LiteralPath $installTo -Recurse -Force }
        New-Item -ItemType Directory -Path $installTo -Force | Out-Null
        Copy-Item -Path (Join-Path $moduleRoot '*') -Destination $installTo -Recurse -Force
        Write-Host "Installed to $installTo" -ForegroundColor Green
        Write-Host "Next time: Import-Module EndpointToolkit; etk   (etkc for the console menu)" -ForegroundColor Green
        Write-Host "(If Import-Module is blocked: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned)" -ForegroundColor DarkGray
    }

    Import-Module -Name $psd1.FullName -Force -Global
    Write-Host "Loaded from $moduleRoot" -ForegroundColor DarkGray

    if (-not $NoMenu) {
        if ($Console) { Show-EndpointToolkit } else { Show-EndpointToolkitGui }
    }
} $Ref $Install $Console $NoMenu
