<#
.SYNOPSIS
    Opens Endpoint Toolkit from a local copy (cloned repo, USB stick, or the cached download).

.DESCRIPTION
    Opens the toolkit window. Where there's no desktop (remote session, RMM shell, Server Core)
    it opens the console menu instead.

.PARAMETER Console
    Always open the console menu, even where the window could open.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Start-Toolkit.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Start-Toolkit.ps1 -Console
#>
param([switch] $Console)

Import-Module -Name (Join-Path $PSScriptRoot 'EndpointToolkit.psd1') -Force -Global
if ($Console) { Show-EndpointToolkit } else { Show-EndpointToolkitGui }
