<#
.SYNOPSIS
    Repo checks: every script parses, tools.json matches the scripts, the module exports what it
    should, parameters reach the scripts intact, the menu flow works, and nothing private leaked in.

.DESCRIPTION
    No dependencies (no Pester needed). Runs on Windows PowerShell 5.1 and PowerShell 7.
    Exit code = number of failures, so CI goes red on any of them.

    Private leak patterns: put one regex per line in tests\leak-patterns.local.txt (git-ignored),
    e.g. your employer's name or client names. They're checked but never committed.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\Test-Repo.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:Failures = 0
$script:Passes   = 0

function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) { $script:Passes++;   Write-Host "  PASS  $Message" -ForegroundColor Green }
    else            { $script:Failures++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}

function Test-SameSet {
    param($A, $B)
    ((@($A) | Sort-Object) -join '|') -eq ((@($B) | Sort-Object) -join '|')
}

function Get-ScriptParameterName {
    param([string] $Path)
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
    if (-not $ast.ParamBlock) { return @() }
    @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}

# Filter on Extension rather than -Include: Windows PowerShell 5.1 ignores -Include alongside -LiteralPath.
$scripts = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
    Where-Object { @('.ps1', '.psm1', '.psd1') -contains $_.Extension -and $_.FullName -notmatch '[\\/](\.git|dist)[\\/]' }

# ------------------------------------------------------------------------------------------------
Write-Host "`nParse" -ForegroundColor Cyan
foreach ($f in $scripts) {
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
    Assert ($e.Count -eq 0) ("{0} parses ({1} errors)" -f $f.Name, $e.Count)
}

# ------------------------------------------------------------------------------------------------
Write-Host "`nEncoding (non-ASCII needs a BOM or Windows PowerShell 5.1 misreads it)" -ForegroundColor Cyan
foreach ($f in $scripts) {
    $bytes   = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom  = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $start   = if ($hasBom) { 3 } else { 0 }
    $nonAscii = $false
    for ($i = $start; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 0x7F) { $nonAscii = $true; break } }
    Assert ($hasBom -or -not $nonAscii) "$($f.Name) is ASCII or has a BOM"
}

# ------------------------------------------------------------------------------------------------
Write-Host "`nManifest (tools.json)" -ForegroundColor Cyan
$manifest = Get-Content -LiteralPath (Join-Path $root 'tools.json') -Raw | ConvertFrom-Json
$tools    = @($manifest.tools)
Assert ($tools.Count -gt 0) "tools.json lists $($tools.Count) tools"
Assert (@($tools.id | Select-Object -Unique).Count -eq $tools.Count) 'tool ids are unique'
$commands = @($tools | Where-Object { $_.command } | ForEach-Object { $_.command })
Assert (@($commands | Select-Object -Unique).Count -eq $commands.Count) 'tool commands are unique'

foreach ($tool in $tools) {
    $path = Join-Path $root ($tool.path -replace '/', [IO.Path]::DirectorySeparatorChar)
    Assert (Test-Path -LiteralPath $path) "[$($tool.id)] script exists: $($tool.path)"
    Assert (@('child', 'process', 'window') -contains $tool.mode) "[$($tool.id)] mode '$($tool.mode)' is valid"
    Assert (@($manifest.categories) -contains $tool.category) "[$($tool.id)] category '$($tool.category)' is listed"
    if (-not (Test-Path -LiteralPath $path)) { continue }

    $scriptParams = Get-ScriptParameterName $path
    if ($tool.prompts) {
        foreach ($p in $tool.prompts) {
            Assert (@('switch', 'string', 'choice') -contains $p.type) "[$($tool.id)] prompt '$($p.param)' type '$($p.type)' is valid"
            Assert ($scriptParams -contains $p.param) "[$($tool.id)] prompt '$($p.param)' is a real script parameter"
            if ($p.type -eq 'choice') {
                Assert (@($p.options) -contains $p.default) "[$($tool.id)] choice '$($p.param)' default is one of its options"
            }
        }
    }
}

# ------------------------------------------------------------------------------------------------
Write-Host "`nModule manifest and exports" -ForegroundColor Cyan
$psd1Path = Join-Path $root 'EndpointToolkit.psd1'
$psd1     = Import-PowerShellDataFile -LiteralPath $psd1Path
$expected = @('Show-EndpointToolkit', 'Get-ToolkitTool', 'Invoke-ToolkitTool') + $commands
Assert (Test-SameSet $psd1.FunctionsToExport $expected) 'psd1 FunctionsToExport matches tools.json commands'

$mod = Import-Module -Name $psd1Path -Force -PassThru
$exported = @($mod.ExportedFunctions.Keys)
Assert (Test-SameSet $exported $expected) "module exports $($exported.Count) functions as expected"
Assert ($mod.ExportedAliases.ContainsKey('etk')) "alias 'etk' exported"

$common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
foreach ($tool in ($tools | Where-Object { $_.command })) {
    $path = Join-Path $root ($tool.path -replace '/', [IO.Path]::DirectorySeparatorChar)
    $cmd  = Get-Command -Name $tool.command -Module EndpointToolkit -ErrorAction SilentlyContinue
    Assert ($null -ne $cmd) "$($tool.command) exists"
    if (-not $cmd) { continue }
    $cmdParams = @($cmd.Parameters.Keys | Where-Object { $common -notcontains $_ })
    $want      = Get-ScriptParameterName $path
    Assert (Test-SameSet $cmdParams $want) "$($tool.command) has the script's parameters ($($want.Count))"
    $syn = (Get-Help -Name $tool.command).Synopsis
    Assert (-not [string]::IsNullOrWhiteSpace($syn) -and $syn -notmatch '^\s*' + [regex]::Escape($tool.command) + '\s*\[') "$($tool.command) has help"
}

# ------------------------------------------------------------------------------------------------
Write-Host "`nArgument passing" -ForegroundColor Cyan
Assert ((& $mod { Format-ToolkitArgument 'plain' }) -eq 'plain')                       'plain value untouched'
Assert ((& $mod { Format-ToolkitArgument 'Contoso Ltd' }) -eq '"Contoso Ltd"')         'value with a space is quoted'
Assert ((& $mod { Format-ToolkitArgument 'C:\Some Folder\' }) -eq '"C:\Some Folder\\"') 'trailing backslash doubled inside quotes'
Assert ((& $mod { Format-ToolkitArgument 'say "hi"' }) -eq '"say \"hi\""')             'embedded quotes escaped'
$argStr = & $mod { ConvertTo-ToolkitArgumentString ([ordered]@{ Flag = $true; Off = $false; Name = 'x y'; Empty = '' }) }
Assert ($argStr -eq '-Flag -Name "x y"') "hashtable -> '$argStr'"

# Inject a fixture tool into the loaded module and run it for real in a child process.
$outFile = Join-Path ([IO.Path]::GetTempPath()) ("etk-test-{0}.json" -f [guid]::NewGuid())
$env:ETK_TEST_OUT = $outFile
& $mod {
    $script:Tools += [pscustomobject]@{
        id = 'fixture-child'; name = 'Fixture (child)'; category = 'Report'; mode = 'child'; admin = $false
        path = 'tests/fixtures/Echo-Args.ps1'; description = 'test'; successCodes = @(0, 77)
        prompts = @(
            [pscustomobject]@{ param = 'Name'; type = 'choice'; prompt = 'Pick'; options = @('Alpha', 'Beta Gamma'); default = 'Alpha' }
            [pscustomobject]@{ param = 'Flag'; type = 'switch'; prompt = 'Flag?'; default = $false }
            [pscustomobject]@{ param = 'Path'; type = 'string'; prompt = 'Path'; required = $true }
        )
    }
    $script:Tools += [pscustomobject]@{
        id = 'fixture-process'; name = 'Fixture (process)'; category = 'Report'; mode = 'process'; admin = $false
        path = 'tests/fixtures/Echo-Args.ps1'; description = 'test'
    }
}

$r = Invoke-ToolkitTool -Id fixture-child -Parameters ([ordered]@{ Name = 'Contoso Ltd'; Path = 'C:\Some Folder\'; Flag = $true; Other = $false })
$got = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json
Assert ($r.ExitCode -eq 77 -and $r.Result -eq 'OK') "child mode: listed non-zero exit code counted as OK (got $($r.ExitCode) $($r.Result))"
Assert ($got.Name -eq 'Contoso Ltd')     "child mode: value with a space arrives intact ('$($got.Name)')"
Assert ($got.Path -eq 'C:\Some Folder\') "child mode: trailing-backslash path arrives intact ('$($got.Path)')"
Assert ($got.Flag -and -not $got.Other)  'child mode: switches on/off arrive correctly'
Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue

Invoke-ToolkitTool -Id fixture-process -Parameters @{ Name = 'In Process'; Other = $true } | Out-Null
$got = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json
Assert ($got.Name -eq 'In Process' -and $got.Other) 'process mode: parameters splatted straight to the script'
Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------------------------
Write-Host "`nMenu flow (scripted input)" -ForegroundColor Cyan
$fixtureNumber = (@(& $mod {
    $order = @($script:Manifest.categories)
    @(foreach ($c in $order) { $script:Tools | Where-Object { $_.category -eq $c } }).id
}).IndexOf('fixture-child')) + 1
Assert ($fixtureNumber -gt 0) "fixture appears in the menu as option $fixtureNumber"

# Junk, then the fixture: choice 2, flag yes, required path left blank once then given, Enter back to menu, quit.
$answers = @('nonsense', '999', "$fixtureNumber", '2', 'y', '', 'C:\Req Dir', '', 'q')
& $mod {
    param($a)
    $script:TestAnswers = [Collections.Queue]::new()
    foreach ($x in $a) { $script:TestAnswers.Enqueue($x) }
    function script:Read-ToolkitInput { param([string] $Prompt) $script:TestAnswers.Dequeue() }
} $answers

$menuOut = & { Show-EndpointToolkit } 6>&1 | Out-String
$got = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json
Assert ($got.Name -eq 'Beta Gamma' -and $got.Flag) 'menu: picked tool ran with the chosen options'
Assert ($got.Path -eq 'C:\Req Dir') "menu: required prompt re-asked until answered ('$($got.Path)')"
Assert ((& $mod { $script:TestAnswers.Count }) -eq 0) 'menu: consumed every answer and quit cleanly'
Assert ($menuOut -match 'ENDPOINT TOOLKIT v' + [regex]::Escape($psd1.ModuleVersion)) 'menu: banner shows the module version'
Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
Remove-Item Env:\ETK_TEST_OUT

# ------------------------------------------------------------------------------------------------
Write-Host "`nLeak scan" -ForegroundColor Cyan
$patterns = @(
    @{ Name = 'GUID (tenant / app id?)';     Regex = '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b' }
    @{ Name = 'business OneDrive path';      Regex = 'OneDrive - [A-Z]' }
    @{ Name = 'named user profile path';     Regex = 'C:\\Users\\(?!<|Public\b|%|\$)[A-Za-z]' }
    @{ Name = 'secret-looking assignment';   Regex = '(?i)(client_?secret|password|api_?key|token)\s*=\s*[''"][^''"$<{]{8,}' }
)
$localFile = Join-Path $PSScriptRoot 'leak-patterns.local.txt'
if (Test-Path -LiteralPath $localFile) {
    Get-Content -LiteralPath $localFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $patterns += @{ Name = "local pattern"; Regex = $_ } }
    Write-Host "  (including $((Get-Content $localFile | Where-Object { $_ -and $_ -notmatch '^\s*#' }).Count) private patterns from leak-patterns.local.txt)" -ForegroundColor DarkGray
}
# Known-safe hits: the module's own GUID, and Adobe's public CDN key for Reader version lookups.
$allow = @([regex]::Escape($psd1.GUID), 'api_key=dc-get-adobereader-cdn')

$files = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|dist)[\\/]' -and $_.Name -ne 'leak-patterns.local.txt' -and $_.Name -ne 'Test-Repo.ps1' }
foreach ($pat in $patterns) {
    $hits = foreach ($f in $files) {
        $n = 0
        foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
            $n++
            if ($l -match $pat.Regex) {
                $safe = $false
                foreach ($a in $allow) { if ($l -match $a) { $safe = $true } }
                if (-not $safe) { "{0}:{1}" -f $f.FullName.Substring($root.Length + 1), $n }
            }
        }
    }
    Assert (-not $hits) ("no {0}{1}" -f $pat.Name, $(if ($hits) { ' -> ' + (@($hits) -join ', ') } else { '' }))
}

# ------------------------------------------------------------------------------------------------
Remove-Module EndpointToolkit -ErrorAction SilentlyContinue
$colour = if ($script:Failures) { 'Red' } else { 'Green' }
Write-Host ("`n{0} passed, {1} failed" -f $script:Passes, $script:Failures) -ForegroundColor $colour
exit $script:Failures
