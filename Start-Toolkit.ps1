<#
.SYNOPSIS
    Opens the Endpoint Toolkit menu from a local copy (cloned repo, USB stick, or the cached download).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Start-Toolkit.ps1
#>
Import-Module -Name (Join-Path $PSScriptRoot 'EndpointToolkit.psd1') -Force -Global
Show-EndpointToolkit
