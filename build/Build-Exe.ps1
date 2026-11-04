<#
.SYNOPSIS
    Builds EndpointToolkit.exe - a double-click launcher - with PS2EXE.

.DESCRIPTION
    The exe is a thin stub (ExeStub.ps1): it opens PowerShell and runs the one-line launcher, so it
    always gets the latest toolkit from GitHub and never needs rebuilding when a script changes.

    Heads-up: unsigned PS2EXE binaries are a well-known AV/EDR false-positive magnet. Sign it with
    -CertificateThumbprint, or just use Launch-Toolkit.cmd, which does the same job with nothing to flag.

.PARAMETER OutputFolder
    Where to write the exe. Defaults to .\dist under the repo root (git-ignored).

.PARAMETER RequireAdmin
    Embed a UAC manifest so the exe always asks to elevate.

.PARAMETER CertificateThumbprint
    Thumbprint of a code-signing cert in Cert:\CurrentUser\My to sign the exe with.

.EXAMPLE
    .\build\Build-Exe.ps1 -RequireAdmin

.EXAMPLE
    .\build\Build-Exe.ps1 -RequireAdmin -CertificateThumbprint 0123456789ABCDEF0123456789ABCDEF01234567
#>
[CmdletBinding()]
param(
    [string] $OutputFolder = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'),
    [switch] $RequireAdmin,
    [string] $CertificateThumbprint
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installing ps2exe for the current user...' -ForegroundColor Cyan
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$repoRoot = Split-Path $PSScriptRoot -Parent
$version  = (Import-PowerShellDataFile (Join-Path $repoRoot 'EndpointToolkit.psd1')).ModuleVersion
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$exe = Join-Path $OutputFolder 'EndpointToolkit.exe'

$ps2exeArgs = @{
    InputFile   = Join-Path $PSScriptRoot 'ExeStub.ps1'
    OutputFile  = $exe
    NoConsole   = $true
    Title       = 'Endpoint Toolkit'
    Description = 'Launches the Endpoint Toolkit menu from GitHub'
    Product     = 'Endpoint Toolkit'
    Company     = 'Tom Fuller'
    Copyright   = '(c) 2026 Tom Fuller. MIT licence.'
    Version     = "$version.0"
}
if ($RequireAdmin) { $ps2exeArgs.RequireAdmin = $true }
Invoke-PS2EXE @ps2exeArgs

if ($CertificateThumbprint) {
    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object Thumbprint -eq $CertificateThumbprint
    if (-not $cert) { throw "No code-signing cert with thumbprint $CertificateThumbprint in Cert:\CurrentUser\My" }
    Set-AuthenticodeSignature -FilePath $exe -Certificate $cert -TimestampServer 'http://timestamp.digicert.com' | Out-Null
    Write-Host 'Signed.' -ForegroundColor Green
}

Write-Host "Built $exe (v$version)" -ForegroundColor Green
