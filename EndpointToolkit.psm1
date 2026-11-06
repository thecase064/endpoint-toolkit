#Requires -Version 5.1
<#
    EndpointToolkit module.

    Everything is driven by tools.json in the module folder. Each tool is a plain .ps1 under Tools\
    and is never modified by the toolkit - the module only finds it, asks for any options, and runs it.

    Run modes (set per tool in tools.json):
      child   - runs in a separate powershell.exe in this console. Isolated state, real exit codes.
                In a remote session or RMM shell its output is piped back here instead (see
                Test-ToolkitStreamOutput).
      process - runs in this session, so -PassThru objects come back to your pipeline.
      window  - GUI tools. Launched in their own process; the menu carries on.

    Two front ends share all of this: the console menu (Show-EndpointToolkit, alias etkc) and the
    WPF window (Show-EndpointToolkitGui, alias etk, in Gui\ToolkitGui.ps1).

    Adding a tool: drop the script in Tools\<Folder>\, add an entry to tools.json. That's it.
#>

$script:ModuleRoot = $PSScriptRoot
$script:Manifest   = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tools.json') -Raw | ConvertFrom-Json
$script:Tools      = @($script:Manifest.tools)
$script:RepoName   = 'thecase064/endpoint-toolkit'

# ------------------------------------------------------------------------------------------------
#  Helpers (not exported)
# ------------------------------------------------------------------------------------------------

function Test-ToolkitWindows { $env:OS -eq 'Windows_NT' }

function Test-ToolkitAdmin {
    if (-not (Test-ToolkitWindows)) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ToolkitHostPath {
    # Tools target Windows PowerShell 5.1 (WPF, Appx cmdlets), so child processes always use it on Windows.
    if (Test-ToolkitWindows) {
        $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $winPs) { return $winPs }
        return 'powershell.exe'
    }
    (Get-Process -Id $PID).Path   # non-Windows: only used by the repo's own tests
}

function Get-ToolkitToolPath {
    param([Parameter(Mandatory)] $Tool)
    Join-Path $script:ModuleRoot ($Tool.path -replace '/', [IO.Path]::DirectorySeparatorChar)
}

function Format-ToolkitArgument {
    # Quote one value for a Windows command line (CommandLineToArgvW rules).
    param([string] $Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    '"' + $escaped + '"'
}

function ConvertTo-ToolkitArgumentString {
    # Hashtable of parameters -> "-Name value -Switch" for powershell.exe -File.
    param([System.Collections.IDictionary] $Parameters)
    if (-not $Parameters) { return '' }
    $parts = foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter] -or $value -is [bool]) {
            if ([bool]$value) { "-$key" }
        }
        elseif ($null -ne $value -and "$value" -ne '') {
            "-$key"
            Format-ToolkitArgument ([string]$value)
        }
    }
    @($parts) -join ' '
}

function Read-ToolkitInput {
    param([string] $Prompt)
    Read-Host -Prompt $Prompt
}

function Test-ToolkitStreamOutput {
    # A child powershell.exe started with -NoNewWindow writes to this console. In a remote session
    # (Enter-PSSession), the ISE or an RMM shell there's no console, so that output would vanish: pipe it
    # back and print it here instead. ETK_STREAM=1 or 0 forces it on or off.
    if ($env:ETK_STREAM -eq '1') { return $true }
    if ($env:ETK_STREAM -eq '0') { return $false }
    if ($Host.Name -in @('ServerRemoteHost', 'Windows PowerShell ISE Host')) { return $true }
    try { return [Console]::IsOutputRedirected } catch { return $true }
}

function Invoke-ToolkitChildStreamed {
    # Run a child process with its output piped back line by line. Its input is closed straight away:
    # there's nobody to answer a question over a remote session, so prompts get a blank answer
    # (the tools treat that as "no") instead of hanging. Returns the exit code.
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string] $Arguments,
        [string] $WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    # Windows PowerShell 5.1 (.NET Framework) builds the child's input writer from the console's input
    # encoding and flushes it as the process starts. With the console in UTF-8 mode that sends a UTF-8
    # byte order mark, so a question mid-run got three junk characters instead of a blank answer.
    # Swap in UTF-8 without one for the start only, then put the original back. PowerShell 7 never
    # sends one, and a console that isn't in UTF-8 mode has none to send.
    $restoreInput = $null
    if ($PSVersionTable.PSEdition -ne 'Core') {
        try {
            $current = [Console]::InputEncoding
            if ($current.CodePage -eq 65001 -and $current.GetPreamble().Length -gt 0) {
                [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
                $restoreInput = $current
            }
        }
        catch { Write-Verbose "Console input encoding left as it was: $($_.Exception.Message)" }
    }
    try { $p = [System.Diagnostics.Process]::Start($psi) }
    finally {
        if ($restoreInput) {
            try { [Console]::InputEncoding = $restoreInput }
            catch { Write-Verbose "Couldn't restore the console input encoding: $($_.Exception.Message)" }
        }
    }
    # Close the pipe underneath rather than the writer, so nothing more is written on the way out.
    # Don't Dispose() $p: that would flush the writer onto the closed pipe and throw.
    $p.StandardInput.BaseStream.Close()
    $errors = $p.StandardError.ReadToEndAsync()   # read alongside stdout so neither pipe fills up and blocks
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) { Write-Host $line }
    $p.WaitForExit()
    $errText = $errors.Result
    if ($errText -and $errText.Trim()) { Write-Host $errText.TrimEnd() -ForegroundColor Red }
    $p.ExitCode
}

function Get-ToolkitSource {
    $file = Join-Path $script:ModuleRoot '.etk-source.json'
    if (Test-Path -LiteralPath $file) {
        try { return Get-Content -LiteralPath $file -Raw | ConvertFrom-Json }
        catch { Write-Verbose "Ignoring unreadable $file" }
    }
    $null
}

function Read-ToolkitToolOption {
    # Ask the tool's prompts (from tools.json). Returns an ordered hashtable of parameters.
    param([Parameter(Mandatory)] $Tool)
    $params = [ordered]@{}
    if (-not $Tool.prompts) { return $params }

    foreach ($p in $Tool.prompts) {
        switch ($p.type) {
            'switch' {
                $hint   = if ($p.default) { '[Y/n]' } else { '[y/N]' }
                $answer = Read-ToolkitInput "  $($p.prompt) $hint"
                $on     = if ([string]::IsNullOrWhiteSpace($answer)) { [bool]$p.default } else { $answer -match '^\s*y' }
                if ($on) { $params[$p.param] = $true }
            }
            'choice' {
                Write-Host "  $($p.prompt):"
                for ($i = 0; $i -lt $p.options.Count; $i++) {
                    $mark = if ($p.options[$i] -eq $p.default) { ' (default)' } else { '' }
                    Write-Host ("    {0}) {1}{2}" -f ($i + 1), $p.options[$i], $mark)
                }
                $value = $null
                while (-not $value) {
                    $answer = Read-ToolkitInput '  Choice'
                    if ([string]::IsNullOrWhiteSpace($answer)) { $value = $p.default }
                    elseif ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $p.options.Count) {
                        $value = $p.options[[int]$answer - 1]
                    }
                    elseif ($p.options -contains $answer.Trim()) { $value = $answer.Trim() }
                    else { Write-Host '  Not one of the options - try again.' -ForegroundColor Yellow }
                }
                $params[$p.param] = $value
            }
            default {
                $answer = Read-ToolkitInput "  $($p.prompt)"
                while ($p.required -and [string]::IsNullOrWhiteSpace($answer)) {
                    Write-Host '  This one is required.' -ForegroundColor Yellow
                    $answer = Read-ToolkitInput "  $($p.prompt)"
                }
                if (-not [string]::IsNullOrWhiteSpace($answer)) { $params[$p.param] = $answer.Trim() }
                elseif ($p.default) { $params[$p.param] = $p.default }
            }
        }
    }
    $params
}

function Show-ToolkitBrief {
    # What a tool is about to do, shown before the menu asks "Run it?". Text comes from tools.json.
    param([Parameter(Mandatory)] $Tool, [bool] $IsAdmin)
    $rule = '  ' + ('-' * 70)
    Write-Host ''
    Write-Host $rule -ForegroundColor DarkCyan
    Write-Host "   $($Tool.name)" -ForegroundColor Cyan
    Write-Host $rule -ForegroundColor DarkCyan

    $lines = @($Tool.brief | Where-Object { $_ })
    if (-not $lines) { $lines = @($Tool.description) }
    foreach ($l in $lines) { Write-Host "   $l" }
    Write-Host ''

    if ($Tool.confirm) { Write-Host "   WARNING: $($Tool.confirm)" -ForegroundColor Yellow }
    if ($Tool.admin) {
        if ($IsAdmin) { Write-Host '   Runs as admin.' -ForegroundColor DarkGray }
        else { Write-Host '   Needs admin - the toolkit will offer to relaunch elevated.' -ForegroundColor Yellow }
    }
    if ($Tool.mode -eq 'window') { Write-Host '   Opens in its own window.' -ForegroundColor DarkGray }
    $q = @($Tool.prompts).Where({ $_ }).Count
    if ($q -eq 1) { Write-Host '   Asks 1 question first (Enter takes the default).' -ForegroundColor DarkGray }
    elseif ($q -gt 1) { Write-Host "   Asks $q questions first (Enter takes the default)." -ForegroundColor DarkGray }
    Write-Host ''
}

function Get-ToolkitRunResult {
    # 'OK' when the exit code is one the tool lists as success (default: 0), otherwise 'CHECK LOG'.
    param([Parameter(Mandatory)] $Tool, [int] $ExitCode)
    $ok = @(0)
    if ($Tool.successCodes) { $ok = @($Tool.successCodes) }
    if ($ExitCode -in $ok) { 'OK' } else { 'CHECK LOG' }
}

function Get-ToolkitSha256 {
    param([Parameter(Mandatory)] [byte[]] $Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
}

function Invoke-ToolkitToolFromFile {
    # Used by Gui\Invoke-ToolWindow.ps1, which the window starts in its own console (elevated if needed).
    # The options arrive in a small JSON file; its SHA-256 comes on the command line, so a file changed
    # after the window wrote it is refused rather than run, possibly as admin. Returns an exit code.
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $ParamFile,
        [string] $ParamHash
    )
    # Read and delete the options file first, so it never outlives the run whatever happens next.
    $bytes = $null
    if ($ParamFile) {
        if (-not (Test-Path -LiteralPath $ParamFile)) { Write-Host "Options file missing: $ParamFile" -ForegroundColor Red; return 1 }
        try { $bytes = [IO.File]::ReadAllBytes($ParamFile) }
        finally { Remove-Item -LiteralPath $ParamFile -Force -ErrorAction SilentlyContinue }
    }

    $tool = $script:Tools | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $tool) { Write-Host "No tool with id '$Id'." -ForegroundColor Red; return 1 }

    $params = [ordered]@{}
    if ($null -ne $bytes) {
        if ((Get-ToolkitSha256 -Bytes $bytes) -ne $ParamHash) {
            Write-Host 'The options file was changed after the toolkit wrote it, so this run was stopped.' -ForegroundColor Red
            return 1
        }
        $saved = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        foreach ($prop in $saved.PSObject.Properties) { $params[$prop.Name] = $prop.Value }
    }

    $rule = '  ' + ('-' * 70)
    Write-Host $rule -ForegroundColor DarkCyan
    Write-Host "   $($tool.name)" -ForegroundColor Cyan
    Write-Host $rule -ForegroundColor DarkCyan
    if ($params.Count) {
        $shown = foreach ($k in $params.Keys) { if ($params[$k] -is [bool]) { "-$k" } else { "-$k $($params[$k])" } }
        Write-Host ('   Options: ' + ($shown -join ' ')) -ForegroundColor DarkGray
    }
    Write-Host ''

    try {
        $out = Invoke-ToolkitTool -Id $Id -Parameters $params
        if ($tool.mode -eq 'process' -and $out) { $out | Out-String | Write-Host }
        $run = @($out) | Where-Object { $_ -and $_.PSObject.Properties['ExitCode'] } | Select-Object -Last 1
        if ($tool.mode -eq 'child' -and $run) { return [int]$run.ExitCode }
        return 0
    }
    catch {
        Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
        return 1
    }
}

function Start-ElevatedToolkit {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only opens a UAC prompt; the user confirms there.')]
    [CmdletBinding()]
    param([switch] $Console)
    # Plain -File rather than -EncodedCommand: encoded PowerShell is exactly what EDR (Huntress, Defender) flags.
    $starter = Join-Path $script:ModuleRoot 'Start-Toolkit.ps1'
    $argLine = if ($Console) { '-NoProfile -ExecutionPolicy Bypass -NoExit -File {0} -Console' }
               else { '-NoProfile -ExecutionPolicy Bypass -File {0}' }
    Start-Process -FilePath (Get-ToolkitHostPath) -Verb RunAs -ArgumentList ($argLine -f (Format-ToolkitArgument $starter))
}

# ------------------------------------------------------------------------------------------------
#  Public
# ------------------------------------------------------------------------------------------------

function Get-ToolkitTool {
    <#
    .SYNOPSIS
        Lists the tools in the toolkit (from tools.json), with their full script paths.
    .EXAMPLE
        Get-ToolkitTool
    .EXAMPLE
        Get-ToolkitTool -Category Build | Format-Table Id, Name, Admin
    #>
    [CmdletBinding()]
    param(
        [string] $Id,
        [string] $Category
    )
    $script:Tools |
        Where-Object { (-not $Id -or $_.id -eq $Id) -and (-not $Category -or $_.category -eq $Category) } |
        ForEach-Object {
            [pscustomobject]@{
                Id          = $_.id
                Name        = $_.name
                Category    = $_.category
                Command     = $_.command
                Admin       = [bool]$_.admin
                Mode        = $_.mode
                Description = $_.description
                Brief       = [string[]]@($_.brief | Where-Object { $_ })
                Path        = Get-ToolkitToolPath $_
            }
        }
}

function Invoke-ToolkitTool {
    <#
    .SYNOPSIS
        Runs a toolkit tool by id, passing parameters through to its script.
    .EXAMPLE
        Invoke-ToolkitTool -Id disk-usage-report -Parameters @{ Path = 'D:\'; NoHtml = $true }
    .EXAMPLE
        Invoke-ToolkitTool -Id new-device-setup -Parameters @{ SkipReboot = $true }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [System.Collections.IDictionary] $Parameters = @{}
    )

    $tool = $script:Tools | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $tool) { throw "No tool with id '$Id'. Run Get-ToolkitTool to see the list." }

    $path = Get-ToolkitToolPath $tool
    if (-not (Test-Path -LiteralPath $path)) { throw "Script missing: $path" }

    if ($tool.admin -and -not (Test-ToolkitAdmin)) {
        throw "'$($tool.name)' needs an elevated session. Open PowerShell as Administrator (or use option A in the menu)."
    }

    $splat = @{}
    foreach ($k in $Parameters.Keys) { $splat[$k] = $Parameters[$k] }

    switch ($tool.mode) {
        'process' {
            & $path @splat
            return
        }
        'window' {
            $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -File {0} {1}' -f `
                (Format-ToolkitArgument $path), (ConvertTo-ToolkitArgumentString $splat)
            Start-Process -FilePath (Get-ToolkitHostPath) -ArgumentList $argLine.Trim() `
                -WorkingDirectory (Split-Path $path) -WindowStyle Hidden
            Write-Host "Launched '$($tool.name)' in its own window." -ForegroundColor Green
            return
        }
        default {
            $argLine = '-NoProfile -ExecutionPolicy Bypass -File {0} {1}' -f `
                (Format-ToolkitArgument $path), (ConvertTo-ToolkitArgumentString $splat)
            if (Test-ToolkitStreamOutput) {
                $exitCode = Invoke-ToolkitChildStreamed -FilePath (Get-ToolkitHostPath) -Arguments $argLine.Trim() `
                    -WorkingDirectory (Split-Path $path)
            }
            else {
                $p = Start-Process -FilePath (Get-ToolkitHostPath) -ArgumentList $argLine.Trim() `
                    -WorkingDirectory (Split-Path $path) -Wait -PassThru -NoNewWindow
                $exitCode = $p.ExitCode
            }

            $result = Get-ToolkitRunResult -Tool $tool -ExitCode $exitCode
            $colour = if ($result -eq 'OK') { 'Green' } else { 'Yellow' }
            Write-Host ("`n{0} finished - exit code {1} [{2}]" -f $tool.name, $exitCode, $result) -ForegroundColor $colour

            [pscustomobject]@{ Id = $tool.id; Name = $tool.name; ExitCode = $exitCode; Result = $result }
        }
    }
}

function Show-EndpointToolkit {
    <#
    .SYNOPSIS
        Opens the toolkit's console menu.
    .DESCRIPTION
        Pick a number to see what that tool does, then answer y to run it (anything else goes back).
        Tools that need admin offer to relaunch the toolkit elevated.
        Tools with options ask for them next (press Enter to take the default).
        This is the console menu: it works anywhere, including remote sessions and RMM shells.
        For the window, use Show-EndpointToolkitGui (etk).
    .EXAMPLE
        Show-EndpointToolkit
    .EXAMPLE
        etkc
    #>
    [CmdletBinding()]
    param()

    $version  = $ExecutionContext.SessionState.Module.Version
    $order    = @($script:Manifest.categories)
    $ordered  = @(foreach ($cat in $order) { $script:Tools | Where-Object { $_.category -eq $cat } })
    $ordered += @($script:Tools | Where-Object { $order -notcontains $_.category })

    while ($true) {
        $isAdmin = Test-ToolkitAdmin
        $source  = Get-ToolkitSource
        try { Clear-Host } catch { Write-Verbose 'Host cannot clear the screen' }

        $line = '  ' + ('=' * 70)
        Write-Host $line -ForegroundColor DarkCyan
        Write-Host ("   ENDPOINT TOOLKIT v{0}" -f $version) -ForegroundColor Cyan -NoNewline
        Write-Host ("{0,46}" -f $script:RepoName) -ForegroundColor DarkGray
        $elev = if ($isAdmin) { 'YES' } else { 'NO' }
        $src  = if ($source) { "   Source: $($source.ref) ($($source.downloaded))" } else { '' }
        $psv  = '{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor
        Write-Host ("   Host: {0}   Elevated: {1}   PS {2}{3}" -f $env:COMPUTERNAME, $elev, $psv, $src) -ForegroundColor DarkGray
        Write-Host $line -ForegroundColor DarkCyan

        $n = 0
        $lastCat = $null
        foreach ($t in $ordered) {
            $n++
            if ($t.category -ne $lastCat) {
                Write-Host ''
                Write-Host ('   ' + $t.category.ToUpper()) -ForegroundColor Cyan
                $lastCat = $t.category
            }
            $tag = @()
            if ($t.admin)             { $tag += 'admin' }
            if ($t.mode -eq 'window') { $tag += 'window' }
            Write-Host ("   {0,3}  {1,-46}" -f $n, $t.name) -NoNewline
            $tagColour = if ($t.admin -and -not $isAdmin) { 'Yellow' } else { 'DarkGray' }
            Write-Host ($tag -join ' ') -ForegroundColor $tagColour
        }

        Write-Host ''
        if (-not $isAdmin) { Write-Host '     A  Relaunch as Administrator' -ForegroundColor Yellow }
        Write-Host '     Q  Quit'
        Write-Host ''

        $choice = (Read-ToolkitInput '  Pick a number').Trim()
        if ($choice -match '^(q|quit|exit)$') { return }
        if ($choice -match '^a$') {
            if ($isAdmin) { continue }
            Start-ElevatedToolkit -Console
            Write-Host '  Elevated toolkit opening in a new window. This one can be closed.' -ForegroundColor Green
            return
        }
        if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $ordered.Count) { continue }

        $tool = $ordered[[int]$choice - 1]
        Show-ToolkitBrief -Tool $tool -IsAdmin $isAdmin

        if ($tool.admin -and -not $isAdmin) {
            # Nothing runs here; the elevated window shows the brief again and asks "Run it?" there.
            $answer = Read-ToolkitInput '  This one needs admin. Relaunch the toolkit elevated? [Y/n]'
            if ($answer -notmatch '^\s*n') {
                Start-ElevatedToolkit -Console
                Write-Host '  Elevated toolkit opening in a new window. This one can be closed.' -ForegroundColor Green
                return
            }
            continue
        }

        $answer = Read-ToolkitInput '  Run it? [y/N]'
        if ($answer -notmatch '^\s*y') { continue }

        $options = Read-ToolkitToolOption -Tool $tool
        Write-Host ''
        try {
            $output = Invoke-ToolkitTool -Id $tool.id -Parameters $options
            if ($tool.mode -eq 'process' -and $output) { $output | Out-String | Write-Host }
        }
        catch {
            Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        [void](Read-ToolkitInput "`n  Enter to return to the menu")
    }
}

# ------------------------------------------------------------------------------------------------
#  Per-tool commands. Each tool's "command" in tools.json becomes a function with the script's own
#  parameters and help, so tab completion and Get-Help work. The function just calls Invoke-ToolkitTool.
# ------------------------------------------------------------------------------------------------

$script:ToolCommands = @()
foreach ($tool in $script:Tools) {
    if (-not $tool.command) { continue }
    $toolPath = Get-ToolkitToolPath $tool
    if (-not (Test-Path -LiteralPath $toolPath)) { continue }

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($toolPath, [ref]$tokens, [ref]$errors)

    $helpToken = $tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -match '(?s)^<#.*\.SYNOPSIS' } |
        Select-Object -First 1
    $helpText = if ($helpToken) { $helpToken.Text } else { "<#`n.SYNOPSIS`n    $($tool.description)`n#>" }

    $paramText = 'param()'
    if ($ast.ParamBlock) {
        $attrs     = @($ast.ParamBlock.Attributes | ForEach-Object { $_.Extent.Text }) -join "`n"
        $paramText = $ast.ParamBlock.Extent.Text
        if ($attrs -and -not $paramText.TrimStart().StartsWith('[')) { $paramText = "$attrs`n$paramText" }
    }

    $body = "{0}`n{1}`nInvoke-ToolkitTool -Id '{2}' -Parameters `$PSBoundParameters" -f $helpText, $paramText, $tool.id
    Set-Item -Path ("function:script:{0}" -f $tool.command) -Value ([scriptblock]::Create($body))
    $script:ToolCommands += $tool.command
}

# The WPF window (Show-EndpointToolkitGui and its helpers) lives in its own file.
. (Join-Path (Join-Path $PSScriptRoot 'Gui') 'ToolkitGui.ps1')

Set-Alias -Name etk  -Value Show-EndpointToolkitGui
Set-Alias -Name etkc -Value Show-EndpointToolkit

Export-ModuleMember -Function (@('Get-ToolkitTool', 'Invoke-ToolkitTool', 'Show-EndpointToolkit', 'Show-EndpointToolkitGui') + $script:ToolCommands) `
                    -Alias etk, etkc
