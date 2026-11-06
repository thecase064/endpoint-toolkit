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
    $brief = @($tool.brief)
    $badLines = @($brief | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_.Length -gt 96 })
    Assert ($brief.Count -ge 1 -and $brief.Count -le 5 -and $badLines.Count -eq 0) "[$($tool.id)] has a 1-5 line brief, lines up to 96 chars ($($brief.Count) lines)"
    Assert ($tool.name.Length -le 44) "[$($tool.id)] name fits the menu column ($($tool.name.Length) chars)"
    Assert ([string]$tool.icon -match '^[EF][0-9A-F]{3}$') "[$($tool.id)] has an icon-font code point ($($tool.icon))"
    $ro = $tool.readOnly
    $briefText = @($tool.brief) -join ' '
    Assert ($null -eq $ro -or $ro -eq $true -or [string]$ro -eq 'default') "[$($tool.id)] readOnly is true, ""default"" or absent"
    if ($null -eq $ro) { Assert ($briefText -notmatch 'Read-only') "[$($tool.id)] not marked read-only, and the brief doesn't claim it is" }
    else {
        Assert ($briefText -match 'Read-only|Browse only|changes nothing') "[$($tool.id)] marked read-only, and the brief says so"
        if ([string]$ro -eq 'default') {
            Assert (@($tool.prompts | Where-Object { $_.type -eq 'switch' }).Count -ge 1) "[$($tool.id)] read-only by default, so it has an option that changes that"
        }
    }
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
$expected = @('Show-EndpointToolkit', 'Show-EndpointToolkitGui', 'Get-ToolkitTool', 'Invoke-ToolkitTool') + $commands
Assert (Test-SameSet $psd1.FunctionsToExport $expected) 'psd1 FunctionsToExport matches tools.json commands'

$mod = Import-Module -Name $psd1Path -Force -PassThru
$exported = @($mod.ExportedFunctions.Keys)
Assert (Test-SameSet $exported $expected) "module exports $($exported.Count) functions as expected"
Assert ($mod.ExportedAliases.ContainsKey('etk') -and $mod.ExportedAliases['etk'].Definition -eq 'Show-EndpointToolkitGui') "alias 'etk' opens the window"
Assert ($mod.ExportedAliases.ContainsKey('etkc') -and $mod.ExportedAliases['etkc'].Definition -eq 'Show-EndpointToolkit') "alias 'etkc' opens the console menu"
Assert (Test-SameSet $psd1.AliasesToExport @('etk', 'etkc')) 'psd1 AliasesToExport matches'
Assert (@((Get-ToolkitTool -Id quick-triage).Brief).Count -ge 1) 'Get-ToolkitTool returns the brief'

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
        brief = @('Fixture brief line one.', 'Fixture brief line two.'); confirm = 'Fixture warning text.'
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

# Child mode both ways: its own console output (normal), and piped back here (remote session / RMM shell).
foreach ($stream in @('0', '1')) {
    $env:ETK_STREAM = $stream
    $how = if ($stream -eq '1') { 'child mode, piped back' } else { 'child mode' }
    $shown = @(Invoke-ToolkitTool -Id fixture-child -Parameters ([ordered]@{ Name = 'Contoso Ltd'; Path = 'C:\Some Folder\'; Flag = $true; Other = $false }) 6>&1)
    $r   = $shown | Where-Object { $_.PSObject.Properties['ExitCode'] } | Select-Object -Last 1
    $got = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json
    Assert ($r.ExitCode -eq 77 -and $r.Result -eq 'OK') "${how}: listed non-zero exit code counted as OK (got $($r.ExitCode) $($r.Result))"
    Assert ($got.Name -eq 'Contoso Ltd')     "${how}: value with a space arrives intact ('$($got.Name)')"
    Assert ($got.Path -eq 'C:\Some Folder\') "${how}: trailing-backslash path arrives intact ('$($got.Path)')"
    Assert ($got.Flag -and -not $got.Other)  "${how}: switches on/off arrive correctly"
    if ($stream -eq '1') {
        Assert (($shown | Out-String) -match 'fixture ran: Contoso Ltd') "${how}: the tool's output is printed in this session"
    }
    Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
}
$env:ETK_STREAM = '1'
$r   = Invoke-ToolkitTool -Id fixture-child -Parameters ([ordered]@{ Name = 'Asker'; Ask = $true }) 6>$null
$got = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json
Assert ($r.ExitCode -eq 77 -and [string]::IsNullOrEmpty($got.Answer)) 'child mode, piped back: a question mid-run gets a blank answer instead of hanging'
Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
Remove-Item Env:\ETK_STREAM
Assert ((& $mod { $env:ETK_STREAM = '1'; $a = Test-ToolkitStreamOutput; $env:ETK_STREAM = '0'; $b = Test-ToolkitStreamOutput; Remove-Item Env:\ETK_STREAM; $a -and -not $b })) 'ETK_STREAM=1 / 0 forces piped-back output on / off'

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

# Scripted answers; every prompt the menu asks is logged so the order can be checked.
function Use-MenuAnswer {
    param([string[]] $Answers)
    & $mod {
        param($a)
        $script:TestAnswers = [Collections.Queue]::new()
        foreach ($x in $a) { $script:TestAnswers.Enqueue($x) }
        $script:TestPrompts = [Collections.Generic.List[string]]::new()
        function script:Read-ToolkitInput { param([string] $Prompt) $script:TestPrompts.Add($Prompt.Trim()); $script:TestAnswers.Dequeue() }
    } $Answers
}

# Pick the fixture, read the brief, say no: back to the menu without running it or asking its options.
Use-MenuAnswer @("$fixtureNumber", 'n', "$fixtureNumber", '', 'q')
$menuOut = & { Show-EndpointToolkit } 6>&1 | Out-String
$prompts = @(& $mod { $script:TestPrompts })
Assert (-not (Test-Path -LiteralPath $outFile)) 'menu: answering n (or Enter) to "Run it?" runs nothing'
Assert (($prompts -join '|') -eq 'Pick a number|Run it? [y/N]|Pick a number|Run it? [y/N]|Pick a number') "menu: declining goes straight back to the menu ($($prompts -join ' > '))"
Assert ($menuOut -match 'Fixture brief line one\.' -and $menuOut -match 'Fixture brief line two\.') 'menu: the brief is shown before asking'
Assert ($menuOut -match 'WARNING: Fixture warning text\.') 'menu: the warning is part of the brief'
Assert ($menuOut -match 'Asks 3 questions first') 'menu: the brief says how many questions follow'
Assert ($menuOut -match 'ENDPOINT TOOLKIT v' + [regex]::Escape($psd1.ModuleVersion)) 'menu: banner shows the module version'

# Junk, then the fixture: y to run, choice 2, flag yes, required path left blank once then given, Enter back to menu, quit.
Use-MenuAnswer @('nonsense', '999', "$fixtureNumber", 'y', '2', 'y', '', 'C:\Req Dir', '', 'q')
$menuOut = & { Show-EndpointToolkit } 6>&1 | Out-String
$prompts = @(& $mod { $script:TestPrompts })
$got = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json
Assert ($got.Name -eq 'Beta Gamma' -and $got.Flag) 'menu: y runs the picked tool with the chosen options'
Assert ($got.Path -eq 'C:\Req Dir') "menu: required prompt re-asked until answered ('$($got.Path)')"
Assert ($prompts.IndexOf('Run it? [y/N]') -ge 0 -and $prompts.IndexOf('Run it? [y/N]') -lt $prompts.IndexOf('Choice')) 'menu: "Run it?" is asked before any of the tool''s options'
Assert ((& $mod { $script:TestAnswers.Count }) -eq 0) 'menu: consumed every answer and quit cleanly'
Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
Remove-Item Env:\ETK_TEST_OUT

# ------------------------------------------------------------------------------------------------
Write-Host "`nWindow: layout, colours and logic (any OS)" -ForegroundColor Cyan
$xamlPath = Join-Path (Join-Path $root 'Gui') 'ToolkitWindow.xaml'
$xamlText = Get-Content -LiteralPath $xamlPath -Raw
$xamlDoc  = $null
try { $xamlDoc = [xml]$xamlText } catch { Write-Verbose $_.Exception.Message }
Assert ($null -ne $xamlDoc) 'ToolkitWindow.xaml is well-formed XML'
if ($xamlDoc) {
    $xpath = "//*[not(ancestor::*[local-name()='ControlTemplate'])]/@*[local-name()='Name' and namespace-uri()='http://schemas.microsoft.com/winfx/2006/xaml']"
    $xamlNames = @($xamlDoc.SelectNodes($xpath) | ForEach-Object { $_.Value })
    $codeNames = @(& $mod { $script:GuiControlNames })
    Assert (Test-SameSet $xamlNames $codeNames) "every named control in the XAML is wired up in code and vice versa ($($xamlNames.Count))"
}
$light = & $mod { Get-ToolkitPalette -Theme Light }
$dark  = & $mod { Get-ToolkitPalette -Theme Dark }
Assert (Test-SameSet @($light.Keys) @($dark.Keys)) "light and dark palettes have the same $($light.Count) colours"
$xamlBrushes = @([regex]::Matches($xamlText, '\{DynamicResource (\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$guiCode     = Get-Content -LiteralPath (Join-Path (Join-Path $root 'Gui') 'ToolkitGui.ps1') -Raw
$codeBrushes = @([regex]::Matches($guiCode, "(?:-Brush|Property,)\s+'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
$codeBrushes += @([regex]::Matches($guiCode, "\`$brush = if .*") | ForEach-Object { [regex]::Matches($_.Value, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value } } | Where-Object { $_ -ne 'OK' })
$codeBrushes += @((& $mod { $script:GuiPillBrushes }).Values | ForEach-Object { $_ })
$missing = @(($xamlBrushes + $codeBrushes) | Select-Object -Unique | Where-Object { -not $light.ContainsKey($_) })
Assert ($missing.Count -eq 0) "every colour the window uses is in the palette ($(@($xamlBrushes + $codeBrushes | Select-Object -Unique).Count) used$(if ($missing) { '; missing: ' + ($missing -join ', ') }))"
$badHex = @($light.Values + $dark.Values | Where-Object { $_ -notmatch '^#[0-9A-Fa-f]{6}$' })
Assert ($badHex.Count -eq 0) 'palette colours are all #RRGGBB'

$themes = & $mod { $env:ETK_THEME = 'Dark'; $d = Get-ToolkitTheme; $env:ETK_THEME = 'Light'; $l = Get-ToolkitTheme; Remove-Item Env:\ETK_THEME; "$d/$l" }
Assert ($themes -eq 'Dark/Light') "ETK_THEME overrides the Windows theme ($themes)"
$toggles = & $mod { @((Get-ToolkitThemeToggle -Theme Dark), (Get-ToolkitThemeToggle -Theme Light)) }
Assert ($toggles[0].Glyph -eq 'E706' -and $toggles[0].Next -eq 'Light' -and $toggles[1].Glyph -eq 'E708' -and $toggles[1].Next -eq 'Dark') 'theme button: sun in dark mode switches to light, moon in light mode switches to dark'

$plans = & $mod {
    $admin = [pscustomobject]@{ id = 'a'; name = 'A'; category = 'Build'; mode = 'child'; admin = $true }
    $user  = [pscustomobject]@{ id = 'u'; name = 'U'; category = 'Repair'; mode = 'child'; admin = $false; readOnly = 'default' }
    $win   = [pscustomobject]@{ id = 'w'; name = 'W'; category = 'Diagnose'; mode = 'window'; admin = $false; readOnly = $true }
    [pscustomobject]@{
        UserTags       = @(Get-ToolkitToolTag -Tool $user -IsAdmin $false | ForEach-Object { $_.Text })
        AdminFromUser  = Get-ToolkitRunPlan -Tool $admin -IsAdmin $false
        AdminFromAdmin = Get-ToolkitRunPlan -Tool $admin -IsAdmin $true
        User           = Get-ToolkitRunPlan -Tool $user -IsAdmin $false
        Window         = Get-ToolkitRunPlan -Tool $win -IsAdmin $false
        AdminTags      = @(Get-ToolkitToolTag -Tool $admin -IsAdmin $false | ForEach-Object { $_.Text })
        AdminTagsAdmin = @(Get-ToolkitToolTag -Tool $admin -IsAdmin $true | ForEach-Object { $_.Text })
        WindowTags     = @(Get-ToolkitToolTag -Tool $win -IsAdmin $false | ForEach-Object { $_.Text })
    }
}
Assert ($plans.AdminFromUser.Elevate -and $plans.AdminFromUser.Label -eq 'Run as admin' -and $plans.AdminFromUser.Kind -eq 'console') 'admin tool from a normal window: Run as admin, UAC, own console'
Assert (-not $plans.AdminFromAdmin.Elevate -and $plans.AdminFromAdmin.Label -eq 'Run') 'admin tool from an elevated window: plain Run'
Assert (-not $plans.User.Elevate -and $plans.User.Label -eq 'Run' -and $plans.User.Kind -eq 'console') 'normal tool: Run in its own console'
Assert ($plans.Window.Kind -eq 'window' -and $plans.Window.Label -eq 'Open') 'window tool: Open'
Assert (($plans.AdminTags -join '|') -eq 'Changes the machine|Needs admin' -and ($plans.AdminTagsAdmin -join '|') -eq 'Changes the machine|Runs as admin') "tags: changes the machine, then admin ($($plans.AdminTags -join ', '))"
Assert (($plans.WindowTags -join '|') -eq 'Read-only|Opens a window') "tags: read-only window tool ($($plans.WindowTags -join ', '))"
Assert (($plans.UserTags -join '|') -eq 'Read-only by default') "tags: read-only unless an option is ticked ($($plans.UserTags -join ', '))"
Assert ($plans.AdminFromUser.Glyph -eq 'EA18' -and $plans.User.Glyph -eq 'E768' -and $plans.Window.Glyph -eq 'E8A7') 'Run button icons: shield for admin, play for run, new window for open'

$looks = & $mod {
    $noIcon = [pscustomobject]@{ id = 'x'; name = 'X'; category = 'Repair' }
    $odd    = [pscustomobject]@{ id = 'y'; name = 'Y'; category = 'Elsewhere' }
    [pscustomobject]@{
        Glyph     = ConvertTo-ToolkitGlyph 'E9D9'
        Fallback  = Get-ToolkitToolIcon $noIcon
        Fallback2 = Get-ToolkitToolIcon $odd
        Short     = Get-ToolkitShortName 'OEM drivers + BIOS (Dell / HP / Lenovo)'
        Plain     = Get-ToolkitShortName 'McAfee removal'
        AllShort  = @($script:Tools | Where-Object { $_.id -notlike 'fixture-*' } | ForEach-Object { Get-ToolkitShortName $_.name })
    }
}
Assert ($looks.Glyph.Length -eq 1 -and [int][char]$looks.Glyph -eq 0xE9D9) 'icon code points become the icon-font character'
Assert ($looks.Fallback -eq 'E90F' -and $looks.Fallback2 -eq 'E713') 'a tool with no icon gets its category''s, or a gear'
Assert ($looks.Short -eq 'OEM drivers + BIOS' -and $looks.Plain -eq 'McAfee removal') "the list drops the bracketed part of a name ('$($looks.Short)')"
Assert (@($looks.AllShort | Select-Object -Unique).Count -eq $tools.Count -and -not ($looks.AllShort -contains '')) 'short names are all different and none are blank'

$labels = & $mod {
    @(
        Get-ToolkitPromptLabel ([pscustomobject]@{ type = 'switch'; prompt = 'Skip the reboot?' })
        Get-ToolkitPromptLabel ([pscustomobject]@{ type = 'string'; prompt = 'Folder'; required = $true })
    )
}
Assert ($labels[0] -eq 'Skip the reboot' -and $labels[1] -eq 'Folder (required)') "option labels drop the '?' and mark required ones ($($labels -join ' / '))"

# The window must turn untouched options into exactly what pressing Enter at every console prompt gives.
$parity = & $mod {
    foreach ($t in @($script:Tools | Where-Object { $_.id -notlike 'fixture-*' })) {
        $required = @($t.prompts | Where-Object { $_ -and $_.required })
        $script:RequiredPrompts = @($required | ForEach-Object { "  $($_.prompt)" })
        function script:Read-ToolkitInput { param([string] $Prompt) if ($script:RequiredPrompts -contains $Prompt) { 'X' } else { '' } }
        $console = Read-ToolkitToolOption -Tool $t 6>$null
        $values  = @{}
        foreach ($p in $required) { $values[$p.param] = 'X' }
        $gui = (ConvertTo-ToolkitGuiParameter -Tool $t -Values $values).Parameters
        [pscustomobject]@{ Id = $t.id; Console = (ConvertTo-Json -InputObject $console -Compress); Gui = (ConvertTo-Json -InputObject $gui -Compress) }
    }
}
$differ = @($parity | Where-Object { $_.Console -ne $_.Gui })
Assert ($parity.Count -eq $tools.Count -and $differ.Count -eq 0) "defaults match the console prompts for all $($parity.Count) tools$(if ($differ) { ': ' + (($differ | ForEach-Object { "$($_.Id) console $($_.Console) window $($_.Gui)" }) -join '; ') })"

$conv = & $mod {
    $fx = $script:Tools | Where-Object { $_.id -eq 'fixture-child' }
    [pscustomobject]@{
        Missing = ConvertTo-ToolkitGuiParameter -Tool $fx -Values @{ Name = 'Beta Gamma'; Flag = $true; Path = '  ' }
        Good    = ConvertTo-ToolkitGuiParameter -Tool $fx -Values @{ Name = 'Beta Gamma'; Flag = $true; Path = ' C:\Req Dir ' }
        BadPick = ConvertTo-ToolkitGuiParameter -Tool $fx -Values @{ Name = 'Nope'; Path = 'x' }
    }
}
Assert (@($conv.Missing.Errors).Count -eq 1 -and $conv.Missing.Errors[0] -match 'Path') "a blank required box is caught before running ($($conv.Missing.Errors -join ''))"
Assert (@($conv.Good.Errors).Count -eq 0 -and $conv.Good.Parameters['Name'] -eq 'Beta Gamma' -and $conv.Good.Parameters['Flag'] -eq $true -and $conv.Good.Parameters['Path'] -eq 'C:\Req Dir') 'picked options become parameters (trimmed)'
Assert (@($conv.BadPick.Errors).Count -eq 1) 'a choice outside the options is refused'

if ($env:OS -ne 'Windows_NT') {
    Assert (-not (& $mod { Test-ToolkitGuiAvailable })) 'no window off Windows'
    & $mod { $script:TestAnswers = [Collections.Queue]::new(); $script:TestAnswers.Enqueue('q')
             function script:Read-ToolkitInput { param([string] $Prompt) $null = $Prompt; $script:TestAnswers.Dequeue() } }
    $fallback = & { Show-EndpointToolkitGui } 6>&1 | Out-String
    Assert ($fallback -match 'No desktop here' -and $fallback -match 'ENDPOINT TOOLKIT v') 'with no desktop, the window falls back to the console menu'
}

# ------------------------------------------------------------------------------------------------
Write-Host "`nWindow: runs (each tool in its own console, options passed by file + hash)" -ForegroundColor Cyan
$env:ETK_TEST_OUT = $outFile
function Write-OptionFile {
    param([string] $Json)
    $path  = Join-Path ([IO.Path]::GetTempPath()) ('etk-run-test-{0}.json' -f [guid]::NewGuid())
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Json)
    [IO.File]::WriteAllBytes($path, $bytes)
    [pscustomobject]@{ Path = $path; Hash = (& $mod { param($b) Get-ToolkitSha256 -Bytes $b } $bytes) }
}
$opt  = Write-OptionFile '{"Name":"Contoso Ltd","Path":"C:\\Some Folder\\","Flag":true}'
$code = & $mod { param($f, $h) Invoke-ToolkitToolFromFile -Id fixture-child -ParamFile $f -ParamHash $h } $opt.Path $opt.Hash 6>$null
$got  = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json }
Assert ($code -eq 77 -and $got.Name -eq 'Contoso Ltd' -and $got.Path -eq 'C:\Some Folder\' -and $got.Flag) "options from the window reach the tool intact (exit $code)"
Assert (-not (Test-Path -LiteralPath $opt.Path)) 'the options file is deleted once read'
Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue

$opt  = Write-OptionFile '{"Name":"Changed later"}'
$code = & $mod { param($f) Invoke-ToolkitToolFromFile -Id fixture-child -ParamFile $f -ParamHash ('0' * 64) } $opt.Path 6>$null
Assert ($code -eq 1 -and -not (Test-Path -LiteralPath $outFile)) 'an options file that does not match its hash is refused, and nothing runs'
Assert (-not (Test-Path -LiteralPath $opt.Path)) '...and is still deleted'

$opt  = Write-OptionFile '{}'
$code = & $mod { param($f, $h) Invoke-ToolkitToolFromFile -Id no-such-tool -ParamFile $f -ParamHash $h } $opt.Path $opt.Hash 6>$null
Assert ($code -eq 1 -and -not (Test-Path -LiteralPath $opt.Path)) 'unknown tool id: exit 1, options file still deleted'

# The real launch path: Run button -> new PowerShell -> Gui\Invoke-ToolWindow.ps1. The fixture isn't in
# tools.json, so the runner reports an unknown tool; what's checked is that it starts, gets its options
# file and hash on the command line intact (path with spaces included), deletes the file and exits.
$env:ETK_NO_PAUSE = '1'
$before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'etk-run-*.json' -ErrorAction SilentlyContinue).Count
$proc = & $mod {
    $fx = $script:Tools | Where-Object { $_.id -eq 'fixture-child' }
    Start-ToolkitGuiRun -Tool $fx -Parameters ([ordered]@{ Name = 'Via runner'; Flag = $true }) -Plan (Get-ToolkitRunPlan -Tool $fx -IsAdmin $true)
}
$exited = $proc -and $proc.WaitForExit(120000)
$after  = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'etk-run-*.json' -ErrorAction SilentlyContinue).Count
Assert ($exited -and $proc.ExitCode -eq 1) "Run starts the runner in its own PowerShell and gets its exit code back ($(if ($exited) { $proc.ExitCode } else { 'did not exit' }))"
Assert ($after -le $before) 'the runner deleted the options file the Run button wrote'
Remove-Item Env:\ETK_NO_PAUSE
Remove-Item Env:\ETK_TEST_OUT -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------------------------
Write-Host "`nWindow: built and clicked through in code (Windows only, never shown)" -ForegroundColor Cyan
if ($env:OS -ne 'Windows_NT') {
    Write-Host '  SKIP  WPF only exists on Windows; CI runs this part' -ForegroundColor DarkGray
}
elseif ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host '  SKIP  needs a single-threaded (STA) PowerShell' -ForegroundColor DarkGray
}
else {
    $ui = & $mod {
        $w = New-ToolkitGuiWindow -IsAdmin $false -Theme Dark
        $g = $script:Gui
        $r = [ordered]@{ Built = [bool]$w; ListCount = $g.C.ToolList.Items.Count; FirstName = $g.C.ToolName.Text }
        $pick = { param($id) $g.C.ToolList.SelectedItem = ($g.Items | Where-Object { $_.Tool.id -eq $id }).Item }

        & $pick 'm365-reset'
        $r.M365Name    = $g.C.ToolName.Text
        $r.M365Run     = $g.C.RunLabel.Text
        $r.M365Icon    = [int][char]$g.C.RunIcon.Text
        $r.M365Warn    = [string]$g.C.WarnBox.Visibility
        $r.M365Tags    = $g.C.TagPanel.Children.Count
        $r.M365Options = @($g.Options).Count
        $r.M365Params  = ConvertTo-Json -Compress -InputObject (ConvertTo-ToolkitGuiParameter -Tool $g.Current -Values (Get-ToolkitGuiOptionValue)).Parameters

        & $pick 'driver-import'
        Invoke-ToolkitGuiRun        # required folder left blank: must stop at the message, start nothing
        $r.ImportMessage = $g.C.ErrorText.Text
        $r.ImportRuns    = $g.C.RunsList.Children.Count

        & $pick 'disk-usage-gui'
        $r.WindowRun = $g.C.RunLabel.Text
        $row = ($g.Items | Where-Object { $_.Tool.id -eq 'oem-updates' }).Item.Content
        $r.RowName  = $row.Children[1].Text
        $r.RowIcon  = [int][char]$row.Children[0].Text
        $r.RowMarks = $row.Children.Count
        $r.Caption  = @($g.C.MinButton, $g.C.MaxButton, $g.C.CloseButton | Where-Object { $_ }).Count
        $r.DarkBg   = $w.Resources['Bg'].ToString()
        $r.DarkIcon = [int][char][string]$g.C.ThemeButton.Content
        $g.C.ThemeButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $r.LightBg   = $w.Resources['Bg'].ToString()
        $r.LightIcon = [int][char][string]$g.C.ThemeButton.Content
        $r.LightTip  = [string]$g.C.ThemeButton.ToolTip
        $g.C.ThemeButton.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        $r.BackBg   = $w.Resources['Bg'].ToString()

        $g.C.SearchBox.Text = 'spooler'
        $r.SearchShown = @($g.Items | Where-Object { [string]$_.Item.Visibility -eq 'Visible' }).Count
        $r.SearchPick  = $g.Current.id
        $g.C.SearchBox.Text = 'zzz-nothing-matches'
        $r.NoneName = $g.C.ToolName.Text
        $r.NoneRun  = [string]$g.C.RunButton.Visibility
        $g.C.SearchBox.Text = ''
        $r.AllShown = @($g.Items | Where-Object { [string]$_.Item.Visibility -eq 'Visible' }).Count
        $w.Close()
        [pscustomobject]$r
    }
    $listed     = @(& $mod { $script:Tools })     # includes the two test fixtures injected above
    $categories = @($listed.category | Select-Object -Unique).Count
    Assert ($ui.Built -and $ui.ListCount -eq ($listed.Count + $categories)) "window builds with every tool under its category ($($ui.ListCount) rows)"
    Assert ($ui.FirstName -eq $tools[0].name) "first tool is selected on open ('$($ui.FirstName)')"
    Assert ($ui.M365Name -like 'M365*' -and $ui.M365Run -eq 'Run as admin' -and $ui.M365Icon -eq 0xEA18 -and $ui.M365Warn -eq 'Visible') 'selecting a tool shows its name, warning and a shield "Run as admin" button'
    Assert ($ui.M365Tags -eq 2 -and $ui.M365Options -eq 2) "...its tags and both options ($($ui.M365Tags) tags, $($ui.M365Options) options)"
    Assert ($ui.M365Params -eq '{"ProductID":"O365BusinessRetail"}') "...and untouched options give the defaults ($($ui.M365Params))"
    Assert ($ui.ImportMessage -match 'required|Fill in' -and $ui.ImportRuns -eq 0) "Run with a required box empty says so and starts nothing ('$($ui.ImportMessage)')"
    Assert ($ui.WindowRun -eq 'Open') 'window tools get an Open button'
    Assert ($ui.RowName -eq 'OEM drivers + BIOS' -and $ui.RowIcon -eq 0xE896 -and $ui.RowMarks -eq 3) "list rows: icon, short name, admin shield ('$($ui.RowName)')"
    Assert ($ui.Caption -eq 3) 'own title bar has minimise, maximise and close'
    Assert ($ui.DarkBg -eq '#FF1C1C1C' -and $ui.DarkIcon -eq 0xE706) "opens dark when asked, with the sun on the theme button ($($ui.DarkBg))"
    Assert ($ui.LightBg -eq '#FFF5F5F5' -and $ui.LightIcon -eq 0xE708 -and $ui.LightTip -eq 'Switch to dark mode') "clicking the theme button switches to light, live ($($ui.LightBg))"
    Assert ($ui.BackBg -eq '#FF1C1C1C') 'clicking again switches back to dark'
    Assert ($ui.SearchShown -eq 1 -and $ui.SearchPick -eq 'print-spooler') "search narrows the list and picks the match ($($ui.SearchShown) shown)"
    Assert ($ui.NoneName -match 'No tools match' -and $ui.NoneRun -eq 'Collapsed') 'no matches: says so, and no Run button'
    Assert ($ui.AllShown -eq $listed.Count) 'clearing the search shows everything again'
}

# ------------------------------------------------------------------------------------------------
Write-Host "`nLaunchers" -ForegroundColor Cyan
Assert ((Get-ScriptParameterName (Join-Path $root 'install.ps1')) -contains 'Console') 'install.ps1 has -Console'
Assert ((Get-ScriptParameterName (Join-Path $root 'Start-Toolkit.ps1')) -contains 'Console') 'Start-Toolkit.ps1 has -Console'
$consoleLauncher = Get-Content -LiteralPath (Join-Path $root 'console.ps1') -Raw
Assert ($consoleLauncher -match 'raw\.githubusercontent\.com/thecase064/endpoint-toolkit/main/install\.ps1' -and $consoleLauncher -match '\)\)\s+-Console') 'console.ps1 runs install.ps1 with -Console'

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
