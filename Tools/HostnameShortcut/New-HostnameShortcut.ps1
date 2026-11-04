<#
.SYNOPSIS
    Puts a "Hostname" shortcut on the desktop that opens a command window showing the computer name.

.DESCRIPTION
    For the support call where someone asks "what's my computer called?" and the alternative is
    talking them through System Settings. Double-click, read it out, done.

    The shortcut runs:  cmd.exe /k title Hostname & hostname
    (/k keeps the window open so the name doesn't flash and vanish.)

.PARAMETER AllUsers
    Put it on the Public desktop so every user on the machine gets it. Needs admin.
    Without this it goes on the current user's desktop (OneDrive-redirected desktops included).

.PARAMETER Name
    Shortcut name. Default "Hostname".

.EXAMPLE
    .\New-HostnameShortcut.ps1

.EXAMPLE
    .\New-HostnameShortcut.ps1 -AllUsers

.NOTES
    When run elevated as a different admin account, use -AllUsers: otherwise the shortcut lands on
    the admin's desktop, not the user's. The new-device build runs it with -AllUsers.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch] $AllUsers,
    [string] $Name = 'Hostname'
)

$ErrorActionPreference = 'Stop'

if ($AllUsers) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Write-Host '-AllUsers writes to the Public desktop, which needs an elevated session.' -ForegroundColor Red; exit 1 }
}

$folderName = if ($AllUsers) { 'CommonDesktopDirectory' } else { 'Desktop' }
$desktop    = [Environment]::GetFolderPath($folderName)
if (-not $desktop) { Write-Host "Couldn't find the $folderName folder for this account." -ForegroundColor Red; exit 1 }

$path  = Join-Path $desktop "$Name.lnk"
$shell = New-Object -ComObject WScript.Shell
$lnk   = $shell.CreateShortcut($path)
$lnk.TargetPath  = Join-Path $env:SystemRoot 'System32\cmd.exe'
$lnk.Arguments   = '/k title Hostname & hostname'
$lnk.Description = 'Show computer name'
$lnk.Save()

Write-Host "Shortcut created: $path" -ForegroundColor Green
exit 0
