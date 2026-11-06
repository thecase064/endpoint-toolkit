<#
.SYNOPSIS
    Runs one toolkit tool in this PowerShell window. The toolkit window starts this for you.

.DESCRIPTION
    Each time you click Run in the toolkit window, it starts this script in a new PowerShell window
    (elevated, with a UAC prompt, when the tool needs admin). Every tool gets a real console for its
    output and any questions it asks, and the toolkit window stays free.

    The options you picked arrive in a small JSON file. It's deleted as soon as it's read, and its
    SHA-256 must match -ParamHash from the command line, so a file changed in between is refused
    rather than run as admin.

.PARAMETER Id
    The tool's id in tools.json.

.PARAMETER ParamFile
    JSON file of options written by the toolkit window.

.PARAMETER ParamHash
    SHA-256 of that file as it was written.

.PARAMETER NoPause
    Close straight away instead of waiting for Enter. ETK_NO_PAUSE=1 does the same (used by the tests).
#>
param(
    [Parameter(Mandatory)] [string] $Id,
    [string] $ParamFile,
    [string] $ParamHash,
    [switch] $NoPause
)

$module = Import-Module -Name (Join-Path (Split-Path $PSScriptRoot -Parent) 'EndpointToolkit.psd1') -Force -PassThru
try { $Host.UI.RawUI.WindowTitle = "Endpoint Toolkit - $Id" } catch { Write-Verbose 'This host has no window title' }

$code = & $module { param($i, $f, $h) Invoke-ToolkitToolFromFile -Id $i -ParamFile $f -ParamHash $h } $Id $ParamFile $ParamHash
$code = [int]($code | Select-Object -Last 1)

if (-not $NoPause -and $env:ETK_NO_PAUSE -ne '1' -and [Environment]::UserInteractive) {
    [void](Read-Host "`n  Press Enter to close this window")
}
exit $code
