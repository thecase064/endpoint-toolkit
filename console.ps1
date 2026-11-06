<#
.SYNOPSIS
    One-line launcher for remote shells: same as install.ps1, but always opens the console menu.

.DESCRIPTION
    For Enter-PSSession, RMM remote shells, Server Core, or any time you want the console menu:

        irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/console.ps1 | iex

    It fetches install.ps1 and runs it with -Console. To pin a release, call install.ps1 directly:

        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1))) -Ref v1.6.0 -Console
#>
# Inside a script block so nothing is left behind in your session.
& {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $installer = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/thecase064/endpoint-toolkit/main/install.ps1' -UseBasicParsing
    & ([scriptblock]::Create($installer)) -Console
}
