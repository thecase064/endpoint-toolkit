<#
    Endpoint Toolkit window (WPF). Dot-sourced by EndpointToolkit.psm1, so it runs in the module's scope and
    uses the same tools.json, briefs, prompts and Invoke-ToolkitTool as the console menu.

    Nothing runs inside the window. Each tool starts in its own PowerShell window through
    Gui\Invoke-ToolWindow.ps1 (elevated with a UAC prompt when it needs admin), so tools keep a real console
    for their output and any questions they ask, and the window never freezes.

    The plain helpers (options -> parameters, run plan, tags, theme) are tested on any OS by tests\Test-Repo.ps1.
    The window itself is built and clicked through in code on Windows (CI), without being shown.
#>

# Every named control in ToolkitWindow.xaml. The tests check this list matches the XAML.
$script:GuiControlNames = @(
    'Root', 'VersionText', 'HostText', 'ElevatedPill', 'ElevatedText', 'AdminButton',
    'ThemeButton', 'MinButton', 'MaxButton', 'CloseButton',
    'SearchBox', 'SearchHint', 'ToolList',
    'ToolName', 'TagPanel', 'BriefPanel', 'WarnBox', 'WarnText', 'OptionsHeader', 'OptionsPanel', 'ErrorText',
    'FootText', 'RunButton', 'RunIcon', 'RunLabel', 'RunsPanel', 'RunsList'
)

# Windows' own icon font: Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets on 10 (same code points).
$script:GuiIconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'

# Icon for a tool with no "icon" in tools.json, by category. Code points checked against Microsoft's
# Segoe MDL2 Assets list: E7F8 laptop, E90F wrench, E9D9 diagnostic, E9F9 report, E713 gear.
$script:GuiCategoryIcons = @{ Build = 'E7F8'; Repair = 'E90F'; Diagnose = 'E9D9'; Report = 'E9F9' }

# Pill colours (background, text) by kind. Palette names; the tests check they exist.
$script:GuiPillBrushes = @{
    Neutral = 'Line', 'Fg2'; Info = 'AccentSoft', 'AccentText'; Warn = 'WarnBg', 'WarnFg'
    Ok = 'OkBg', 'OkFg'; Danger = 'DangerBg', 'DangerFg'
}

# ------------------------------------------------------------------------------------------------
#  Plain helpers (no WPF)
# ------------------------------------------------------------------------------------------------

function Test-ToolkitGuiAvailable {
    # A window needs Windows, a desktop to draw on and WPF. Remote sessions, RMM shells running as a
    # service, and Server Core get the console menu instead.
    if (-not (Test-ToolkitWindows)) { return $false }
    if ($Host.Name -eq 'ServerRemoteHost' -or $PSSenderInfo) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    try { if ((Get-Process -Id $PID -ErrorAction Stop).SessionId -eq 0) { return $false } } catch { return $false }
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function Get-ToolkitTheme {
    # 'Dark' or 'Light', following Windows' app colour mode. ETK_THEME=Dark or Light overrides it.
    if ($env:ETK_THEME -eq 'Dark')  { return 'Dark' }
    if ($env:ETK_THEME -eq 'Light') { return 'Light' }
    try {
        $mode = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
            -Name AppsUseLightTheme -ErrorAction Stop
        if ($mode -eq 0) { return 'Dark' }
    }
    catch { Write-Verbose 'No app colour mode set; using light' }
    'Light'
}

function Get-ToolkitPalette {
    # Brushes the XAML asks for by name (DynamicResource). Both themes must have the same keys.
    param([ValidateSet('Light', 'Dark')] [string] $Theme = 'Light')
    if ($Theme -eq 'Dark') {
        return @{
            Bg = '#1C1C1C'; Panel = '#232323'; Card = '#2B2B2B'; Line = '#333333'; Line2 = '#4A4A4A'
            Fg = '#F3F3F3'; Fg2 = '#C8C8C8'; Muted = '#8C8C8C'; Hover = '#2F2F2F'
            Accent = '#2F7FD1'; AccentHover = '#3D8EE0'; OnAccent = '#FFFFFF'; AccentSoft = '#1B3550'; AccentText = '#A5CFFF'
            WarnBg = '#3A3012'; WarnFg = '#F5D27A'; OkBg = '#1D3A24'; OkFg = '#8EDB9F'; DangerBg = '#45201F'; DangerFg = '#F4A39C'
        }
    }
    @{
        Bg = '#F5F5F5'; Panel = '#FBFBFB'; Card = '#FFFFFF'; Line = '#E3E3E3'; Line2 = '#C9C9C9'
        Fg = '#1B1B1B'; Fg2 = '#3F3F3F'; Muted = '#707070'; Hover = '#EDEDED'
        Accent = '#0067C0'; AccentHover = '#1975C5'; OnAccent = '#FFFFFF'; AccentSoft = '#E3EEF9'; AccentText = '#0B4F8F'
        WarnBg = '#FFF4CE'; WarnFg = '#6B4E00'; OkBg = '#DFF6DD'; OkFg = '#0E5C0E'; DangerBg = '#FDE7E9'; DangerFg = '#A4262C'
    }
}

function ConvertTo-ToolkitGlyph {
    # 'E9D9' -> the icon-font character for it.
    param([Parameter(Mandatory)] [string] $Code)
    [string][char][Convert]::ToInt32($Code, 16)
}

function Get-ToolkitToolIcon {
    # The tool's icon code point from tools.json, or its category's.
    param([Parameter(Mandatory)] $Tool)
    if ($Tool.icon) { return [string]$Tool.icon }
    $byCategory = $script:GuiCategoryIcons[[string]$Tool.category]
    if ($byCategory) { return $byCategory }
    'E713'
}

function Get-ToolkitShortName {
    # The list shows "OEM drivers + BIOS"; the full "OEM drivers + BIOS (Dell / HP / Lenovo)" is the heading.
    param([Parameter(Mandatory)] [string] $Name)
    $short = ($Name -replace '\s*\([^)]*\)\s*$', '').Trim()
    if ($short) { $short } else { $Name }
}

function Get-ToolkitThemeToggle {
    # What the title-bar theme button shows in a given theme: the icon for the other one (E706 sun,
    # E708 moon), its tooltip, and the theme a click switches to.
    param([ValidateSet('Light', 'Dark')] [string] $Theme)
    if ($Theme -eq 'Dark') { return [pscustomobject]@{ Glyph = 'E706'; Tip = 'Switch to light mode'; Next = 'Light' } }
    [pscustomobject]@{ Glyph = 'E708'; Tip = 'Switch to dark mode'; Next = 'Dark' }
}

function Get-ToolkitToolTag {
    # The small labels beside a tool's name. Kind picks the colour: Neutral, Info, Warn, Ok or Danger.
    # readOnly in tools.json: true = changes nothing; "default" = changes nothing unless an option is ticked.
    param([Parameter(Mandatory)] $Tool, [bool] $IsAdmin)
    $tags = @()
    if ([string]$Tool.readOnly -eq 'default') { $tags += [pscustomobject]@{ Text = 'Read-only by default'; Kind = 'Ok' } }
    elseif ($Tool.readOnly -eq $true)         { $tags += [pscustomobject]@{ Text = 'Read-only'; Kind = 'Ok' } }
    else                                      { $tags += [pscustomobject]@{ Text = 'Changes the machine'; Kind = 'Danger' } }
    if ($Tool.admin) {
        if ($IsAdmin) { $tags += [pscustomobject]@{ Text = 'Runs as admin'; Kind = 'Info' } }
        else { $tags += [pscustomobject]@{ Text = 'Needs admin'; Kind = 'Warn' } }
    }
    if ($Tool.mode -eq 'window') { $tags += [pscustomobject]@{ Text = 'Opens a window'; Kind = 'Info' } }
    $tags
}

function Get-ToolkitRunPlan {
    # How the Run button starts a tool from the window, and what the button and footer say.
    param([Parameter(Mandatory)] $Tool, [bool] $IsAdmin)
    $elevate = [bool]$Tool.admin -and -not $IsAdmin
    # Glyphs: E8A7 open in new window, EA18 shield, E768 play.
    if ($Tool.mode -eq 'window' -and -not $elevate) {
        return [pscustomobject]@{ Kind = 'window'; Elevate = $false; Label = 'Open'; Glyph = 'E8A7'; Note = 'Opens in its own window.' }
    }
    if ($elevate) {
        return [pscustomobject]@{
            Kind = 'console'; Elevate = $true; Label = 'Run as admin'; Glyph = 'EA18'
            Note = 'Windows asks for admin rights (UAC), then it runs in its own PowerShell window.'
        }
    }
    [pscustomobject]@{
        Kind = 'console'; Elevate = $false; Label = 'Run'; Glyph = 'E768'
        Note = 'Runs in its own PowerShell window, so you can carry on here.'
    }
}

function Get-ToolkitPromptLabel {
    # The console asks "Skip the reboot?"; a checkbox reads better without the question mark.
    param([Parameter(Mandatory)] $Prompt)
    $label = ([string]$Prompt.prompt).Trim().TrimEnd('?').Trim()
    if ($Prompt.type -eq 'string' -and $Prompt.required) { $label += ' (required)' }
    $label
}

function ConvertTo-ToolkitGuiParameter {
    # The window's option values -> the parameters to run with, by the same rules as the console prompts:
    # switches only when on, a blank choice takes its default, a blank string takes its default or is left out,
    # and a blank required string is an error. Returns Parameters (ordered) and Errors.
    param(
        [Parameter(Mandatory)] $Tool,
        [System.Collections.IDictionary] $Values = @{}
    )
    $params = [ordered]@{}
    $errors = @()
    foreach ($p in @($Tool.prompts | Where-Object { $_ })) {
        $value = $Values[$p.param]
        switch ($p.type) {
            'switch' {
                $on = if ($null -eq $value) { [bool]$p.default } else { [bool]$value }
                if ($on) { $params[$p.param] = $true }
            }
            'choice' {
                $pick = if ([string]::IsNullOrWhiteSpace([string]$value)) { $p.default } else { ([string]$value).Trim() }
                if (@($p.options) -contains $pick) { $params[$p.param] = $pick }
                else { $errors += "Pick one of the options for '$(Get-ToolkitPromptLabel $p)'." }
            }
            default {
                $text = ([string]$value).Trim()
                if ($text) { $params[$p.param] = $text }
                elseif ($p.required) { $errors += "Fill in '$(Get-ToolkitPromptLabel $p)' first." }
                elseif ($p.default) { $params[$p.param] = $p.default }
            }
        }
    }
    [pscustomobject]@{ Parameters = $params; Errors = $errors }
}

function Start-ToolkitGuiRun {
    # Starts a tool from the window. Window tools launch directly. Everything else runs through
    # Invoke-ToolWindow.ps1 in its own PowerShell window, elevated (UAC) if the plan says so.
    # Returns that process, or $null for window tools.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only runs from the Run button, after the brief and any warning.')]
    param(
        [Parameter(Mandatory)] $Tool,
        [System.Collections.IDictionary] $Parameters = @{},
        [Parameter(Mandatory)] $Plan
    )
    if ($Plan.Kind -eq 'window') {
        [void](Invoke-ToolkitTool -Id $Tool.id -Parameters $Parameters)
        return $null
    }

    # Options go in a temp file; its SHA-256 goes on the command line, which can't be changed after
    # launch, so the runner refuses a file that's been altered in between.
    $json = ConvertTo-Json -InputObject $Parameters -Compress
    if (-not $json) { $json = '{}' }
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($json)
    $file  = Join-Path ([IO.Path]::GetTempPath()) ('etk-run-{0}.json' -f [guid]::NewGuid())
    [IO.File]::WriteAllBytes($file, $bytes)

    $runner  = Join-Path (Join-Path $script:ModuleRoot 'Gui') 'Invoke-ToolWindow.ps1'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File {0} -Id {1} -ParamFile {2} -ParamHash {3}' -f `
        (Format-ToolkitArgument $runner), (Format-ToolkitArgument $Tool.id), (Format-ToolkitArgument $file),
        (Get-ToolkitSha256 -Bytes $bytes)

    $start = @{
        FilePath         = (Get-ToolkitHostPath)
        ArgumentList     = $argLine
        WorkingDirectory = $script:ModuleRoot
        PassThru         = $true
        ErrorAction      = 'Stop'
    }
    if ($Plan.Elevate) { $start.Verb = 'RunAs' }
    try { Start-Process @start }
    catch {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        throw
    }
}

# ------------------------------------------------------------------------------------------------
#  Window
# ------------------------------------------------------------------------------------------------

function New-ToolkitGuiText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory control only.')]
    param([string] $Text, [string] $Brush, [double] $Size = 0, [switch] $Wrap, [switch] $Bold)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    if ($Brush) { $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $Brush) }
    if ($Size)  { $tb.FontSize = $Size }
    if ($Wrap)  { $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap }
    if ($Bold)  { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $tb
}

function New-ToolkitGuiIcon {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory control only.')]
    param([Parameter(Mandatory)] [string] $Code, [string] $Brush, [double] $Size = 14)
    $icon = New-ToolkitGuiText -Text (ConvertTo-ToolkitGlyph $Code) -Brush $Brush -Size $Size
    $icon.FontFamily = New-Object System.Windows.Media.FontFamily $script:GuiIconFont
    $icon.VerticalAlignment = 'Center'
    $icon
}

function New-ToolkitGuiPill {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory control only.')]
    param([string] $Text, [ValidateSet('Neutral', 'Info', 'Warn', 'Ok', 'Danger')] [string] $Kind = 'Info')
    $brushes = $script:GuiPillBrushes
    $pill = New-Object System.Windows.Controls.Border
    $pill.CornerRadius = New-Object System.Windows.CornerRadius 5
    $pill.Padding      = New-Object System.Windows.Thickness 8, 2, 8, 3
    $pill.Margin       = New-Object System.Windows.Thickness 0, 2, 6, 2
    $pill.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $brushes[$Kind][0])
    $pill.Child = New-ToolkitGuiText -Text $Text -Brush $brushes[$Kind][1] -Size 12
    $pill
}

function Use-ToolkitGuiTheme {
    # Paint the open window in a theme. Everything uses DynamicResource brushes, so swapping them
    # recolours the window live. Only for this window: nothing is saved.
    param([Parameter(Mandatory)] [ValidateSet('Light', 'Dark')] [string] $Theme)
    $g = $script:Gui
    $palette   = Get-ToolkitPalette -Theme $Theme
    $converter = New-Object System.Windows.Media.BrushConverter
    foreach ($key in $palette.Keys) { $g.Window.Resources[$key] = $converter.ConvertFromString($palette[$key]) }
    $g.Theme = $Theme
    $toggle = Get-ToolkitThemeToggle -Theme $Theme
    $g.C.ThemeButton.Content = ConvertTo-ToolkitGlyph $toggle.Glyph
    $g.C.ThemeButton.ToolTip = $toggle.Tip
}

function Show-ToolkitGuiMessage {
    # Error or info line under the options (red), or hide it with no text.
    param([string] $Text)
    $c = $script:Gui.C
    $c.ErrorText.Text = $Text
    $c.ErrorText.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
}

function Show-ToolkitGuiTool {
    # Fill the right-hand side for one tool: name, tags, brief, warning, options, Run button.
    param([string] $Id)
    $g = $script:Gui
    $c = $g.C
    $tool = $script:Tools | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    $g.Current = $tool
    $g.Options = @()
    Show-ToolkitGuiMessage ''
    $c.TagPanel.Children.Clear()
    $c.BriefPanel.Children.Clear()
    $c.OptionsPanel.Children.Clear()

    if (-not $tool) {
        $c.ToolName.Text = 'No tools match that search'
        $c.WarnBox.Visibility = 'Collapsed'
        $c.OptionsHeader.Visibility = 'Collapsed'
        $c.RunButton.Visibility = 'Collapsed'
        $c.FootText.Text = ''
        return
    }

    $c.ToolName.Text = $tool.name
    foreach ($tag in (Get-ToolkitToolTag -Tool $tool -IsAdmin $g.IsAdmin)) {
        [void]$c.TagPanel.Children.Add((New-ToolkitGuiPill -Text $tag.Text -Kind $tag.Kind))
    }

    # The brief is written as short console lines; here it reads as one paragraph.
    $lines = @($tool.brief | Where-Object { $_ })
    if (-not $lines) { $lines = @($tool.description) }
    $brief = New-ToolkitGuiText -Text ($lines -join ' ') -Brush 'Fg2' -Size 14 -Wrap
    $brief.LineHeight = 23
    [void]$c.BriefPanel.Children.Add($brief)

    if ($tool.confirm) {
        $c.WarnText.Text = "Warning: $($tool.confirm)"
        $c.WarnBox.Visibility = 'Visible'
    }
    else { $c.WarnBox.Visibility = 'Collapsed' }

    $options = @()
    foreach ($p in @($tool.prompts | Where-Object { $_ })) {
        $label = Get-ToolkitPromptLabel $p
        switch ($p.type) {
            'switch' {
                $box = New-Object System.Windows.Controls.CheckBox
                $box.Content   = New-ToolkitGuiText -Text $label -Wrap
                $box.IsChecked = [bool]$p.default
                [void]$c.OptionsPanel.Children.Add($box)
                $options += [pscustomobject]@{ Param = $p.param; Kind = 'switch'; Control = $box }
            }
            'choice' {
                $head = New-ToolkitGuiText -Text $label -Wrap
                $head.Margin = New-Object System.Windows.Thickness 0, 8, 0, 2
                $row = New-Object System.Windows.Controls.WrapPanel
                $radios = @()
                foreach ($o in @($p.options)) {
                    $radio = New-Object System.Windows.Controls.RadioButton
                    $radio.Content   = [string]$o
                    $radio.Tag       = [string]$o
                    $radio.GroupName = "etk-$($p.param)"
                    $radio.IsChecked = ([string]$o -eq [string]$p.default)
                    [void]$row.Children.Add($radio)
                    $radios += $radio
                }
                [void]$c.OptionsPanel.Children.Add($head)
                [void]$c.OptionsPanel.Children.Add($row)
                $options += [pscustomobject]@{ Param = $p.param; Kind = 'choice'; Control = $radios }
            }
            default {
                $head = New-ToolkitGuiText -Text $label -Wrap
                $head.Margin = New-Object System.Windows.Thickness 0, 8, 0, 4
                $box = New-Object System.Windows.Controls.TextBox
                $box.Width = 440
                $box.HorizontalAlignment = 'Left'
                if ($p.default) { $box.Text = [string]$p.default }
                [void]$c.OptionsPanel.Children.Add($head)
                [void]$c.OptionsPanel.Children.Add($box)
                $options += [pscustomobject]@{ Param = $p.param; Kind = 'string'; Control = $box }
            }
        }
    }
    if (-not $options) {
        [void]$c.OptionsPanel.Children.Add((New-ToolkitGuiText -Text 'None. It just runs.' -Brush 'Muted'))
    }
    $g.Options = $options
    $c.OptionsHeader.Visibility = 'Visible'

    $plan = Get-ToolkitRunPlan -Tool $tool -IsAdmin $g.IsAdmin
    $c.RunLabel.Text        = $plan.Label
    $c.RunIcon.Text         = ConvertTo-ToolkitGlyph $plan.Glyph
    $c.RunButton.Visibility = 'Visible'
    $c.FootText.Text        = $plan.Note
}

function Get-ToolkitGuiOptionValue {
    # Read the option controls for the selected tool into a hashtable of param name -> value.
    $values = @{}
    foreach ($o in @($script:Gui.Options)) {
        switch ($o.Kind) {
            'switch' { $values[$o.Param] = [bool]$o.Control.IsChecked }
            'choice' {
                $picked = @($o.Control | Where-Object { $_.IsChecked }) | Select-Object -First 1
                $values[$o.Param] = if ($picked) { [string]$picked.Tag } else { '' }
            }
            default { $values[$o.Param] = [string]$o.Control.Text }
        }
    }
    $values
}

function Invoke-ToolkitGuiFilter {
    # Show only the tools whose name, description, category or brief contain the search text.
    $g = $script:Gui
    $c = $g.C
    $query = $c.SearchBox.Text.Trim()
    $c.SearchHint.Visibility = if ($c.SearchBox.Text) { 'Collapsed' } else { 'Visible' }

    $shownCategories = @{}
    foreach ($entry in $g.Items) {
        $t = $entry.Tool
        $text = (@($t.name, $t.description, $t.category) + @($t.brief)) -join ' '
        $show = (-not $query) -or ($text.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        $entry.Item.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
        if ($show) { $shownCategories[$t.category] = $true }
    }
    foreach ($cat in @($g.Headers.Keys)) {
        $g.Headers[$cat].Visibility = if ($shownCategories[$cat]) { 'Visible' } else { 'Collapsed' }
    }

    $selected = $c.ToolList.SelectedItem
    if (-not $selected -or $selected.Visibility -ne 'Visible') {
        $first = $g.Items | Where-Object { $_.Item.Visibility -eq 'Visible' } | Select-Object -First 1
        if ($first) { $c.ToolList.SelectedItem = $first.Item }
        else {
            $c.ToolList.SelectedItem = $null
            Show-ToolkitGuiTool -Id ''
        }
    }
}

function Show-ToolkitGuiRunStatus {
    # One line per run in the bottom panel: running, then finished with its exit code and OK / CHECK LOG.
    param([Parameter(Mandatory)] $Run)
    $time = $Run.Started.ToString('HH:mm')
    if (-not $Run.Process) {
        $Run.Row.Text = "$time   $($Run.Tool.name) - opened in its own window"
        $Run.Row.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Fg2')
        $Run.Done = $true
        return
    }
    if (-not $Run.Process.HasExited) {
        $Run.Row.Text = "$time   $($Run.Tool.name) - running in its own window..."
        $Run.Row.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Fg2')
        return
    }
    $code   = $Run.Process.ExitCode
    $result = Get-ToolkitRunResult -Tool $Run.Tool -ExitCode $code
    $Run.Row.Text = "$time   $($Run.Tool.name) - finished, exit code $code [$result]"
    $brush = if ($result -eq 'OK') { 'OkFg' } else { 'WarnFg' }
    $Run.Row.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $brush)
    $Run.Done = $true
}

function Add-ToolkitGuiRun {
    param([Parameter(Mandatory)] $Tool, $Process)
    $g = $script:Gui
    $row = New-ToolkitGuiText -Text '' -Wrap
    $row.Margin = New-Object System.Windows.Thickness 0, 1, 0, 1
    $run = [pscustomobject]@{ Tool = $Tool; Process = $Process; Row = $row; Started = (Get-Date); Done = $false }
    Show-ToolkitGuiRunStatus -Run $run
    $g.C.RunsList.Children.Insert(0, $row)
    while ($g.C.RunsList.Children.Count -gt 5) { $g.C.RunsList.Children.RemoveAt($g.C.RunsList.Children.Count - 1) }
    $g.C.RunsPanel.Visibility = 'Visible'
    if ($Process) { $g.Runs.Add($run) }
}

function Invoke-ToolkitGuiRun {
    # The Run button: check the options, confirm anything with a warning, then start it.
    $g = $script:Gui
    $tool = $g.Current
    if (-not $tool) { return }
    Show-ToolkitGuiMessage ''

    $converted = ConvertTo-ToolkitGuiParameter -Tool $tool -Values (Get-ToolkitGuiOptionValue)
    if ($converted.Errors) {
        Show-ToolkitGuiMessage ($converted.Errors -join "`n")
        return
    }

    if ($tool.confirm) {
        $answer = [System.Windows.MessageBox]::Show($g.Window, "$($tool.confirm)`n`nRun $($tool.name)?",
            'Endpoint Toolkit', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    $plan = Get-ToolkitRunPlan -Tool $tool -IsAdmin $g.IsAdmin
    try { $process = Start-ToolkitGuiRun -Tool $tool -Parameters $converted.Parameters -Plan $plan }
    catch {
        $why = if ($_.Exception.Message -match 'cancel') { 'Admin rights were declined (UAC), so nothing ran.' }
               else { "Couldn't start it: $($_.Exception.Message)" }
        Show-ToolkitGuiMessage $why
        return
    }
    Add-ToolkitGuiRun -Tool $tool -Process $process
}

function New-ToolkitGuiWindow {
    # Builds the window from ToolkitWindow.xaml and wires it up. Doesn't show it; returns the Window.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory window only.')]
    param(
        [bool] $IsAdmin = (Test-ToolkitAdmin),
        [ValidateSet('Light', 'Dark')] [string] $Theme = (Get-ToolkitTheme)
    )
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    [xml] $xaml = Get-Content -LiteralPath (Join-Path (Join-Path $script:ModuleRoot 'Gui') 'ToolkitWindow.xaml') -Raw
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

    $c = @{}
    foreach ($name in $script:GuiControlNames) {
        $c[$name] = $window.FindName($name)
        if (-not $c[$name]) { throw "ToolkitWindow.xaml has no control named '$name'." }
    }

    $script:Gui = @{
        Window  = $window
        C       = $c
        IsAdmin = $IsAdmin
        Theme   = $Theme
        Items   = New-Object System.Collections.Generic.List[object]
        Headers = @{}
        Current = $null
        Options = @()
        Runs    = New-Object System.Collections.Generic.List[object]
        Timer   = $null
    }
    Use-ToolkitGuiTheme -Theme $Theme

    # Top bar
    $c.VersionText.Text = "v$($ExecutionContext.SessionState.Module.Version)"
    $dot  = [char]0x00B7
    $psv  = '{0}.{1}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor
    $info = "$env:COMPUTERNAME  $dot  PS $psv"
    $source = Get-ToolkitSource
    if ($source) { $info += "  $dot  $($source.ref) ($($source.downloaded))" }
    $c.HostText.Text = $info
    if ($IsAdmin) {
        $c.ElevatedText.Text = 'Elevated'
        $c.ElevatedPill.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'OkBg')
        $c.ElevatedText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'OkFg')
        $c.AdminButton.Visibility = 'Collapsed'
    }
    else {
        $c.ElevatedText.Text = 'Not elevated'
        $c.ElevatedPill.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'WarnBg')
        $c.ElevatedText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'WarnFg')
    }

    # Tool list, grouped by category in the manifest's order
    $order   = @($script:Manifest.categories)
    $ordered = @(foreach ($cat in $order) { $script:Tools | Where-Object { $_.category -eq $cat } })
    $ordered += @($script:Tools | Where-Object { $order -notcontains $_.category })
    $lastCat = $null
    foreach ($t in $ordered) {
        if ($t.category -ne $lastCat) {
            $header = New-Object System.Windows.Controls.ListBoxItem
            $header.Content          = New-ToolkitGuiText -Text $t.category -Brush 'Muted' -Size 12
            $header.Focusable        = $false
            $header.IsHitTestVisible = $false
            $top = if ($null -eq $lastCat) { 4 } else { 16 }
            $header.Padding = New-Object System.Windows.Thickness 10, $top, 10, 4
            [void]$c.ToolList.Items.Add($header)
            $script:Gui.Headers[$t.category] = $header
            $lastCat = $t.category
        }

        # Row: icon | short name | shield (needs admin) or new-window mark
        $grid = New-Object System.Windows.Controls.Grid
        foreach ($width in @('Auto', 'Star', 'Auto')) {
            $col = New-Object System.Windows.Controls.ColumnDefinition
            $col.Width = if ($width -eq 'Star') { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) }
                         else { [System.Windows.GridLength]::Auto }
            $grid.ColumnDefinitions.Add($col)
        }

        $icon = New-ToolkitGuiIcon -Code (Get-ToolkitToolIcon $t) -Size 15
        $icon.Width  = 18
        $icon.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
        [void]$grid.Children.Add($icon)

        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = Get-ToolkitShortName $t.name
        $name.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $name.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($name, 1)
        [void]$grid.Children.Add($name)

        $mark = $null
        if ($t.admin) { $mark = New-ToolkitGuiIcon -Code 'EA18' -Brush 'WarnFg' -Size 12 }
        elseif ($t.mode -eq 'window') { $mark = New-ToolkitGuiIcon -Code 'E8A7' -Brush 'Muted' -Size 12 }
        if ($mark) {
            $mark.Margin  = New-Object System.Windows.Thickness 8, 0, 0, 0
            $mark.ToolTip = if ($t.admin) { 'Needs admin' } else { 'Opens in its own window' }
            [System.Windows.Controls.Grid]::SetColumn($mark, 2)
            [void]$grid.Children.Add($mark)
        }

        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $grid
        $item.Tag     = $t.id
        $item.ToolTip = $t.description
        [void]$c.ToolList.Items.Add($item)
        $script:Gui.Items.Add([pscustomobject]@{ Item = $item; Tool = $t })
    }

    # Events. Handlers run in the module's scope, so they reach $script:Gui and the helpers above.
    $c.ToolList.Add_SelectionChanged({
        try {
            $picked = $script:Gui.C.ToolList.SelectedItem
            if ($picked -and $picked.Tag) { Show-ToolkitGuiTool -Id $picked.Tag }
        }
        catch { Show-ToolkitGuiMessage "Couldn't show that tool: $($_.Exception.Message)" }
    })
    $c.SearchBox.Add_TextChanged({
        try { Invoke-ToolkitGuiFilter } catch { Show-ToolkitGuiMessage "Search failed: $($_.Exception.Message)" }
    })
    $c.SearchBox.Add_PreviewKeyDown({
        $key = $args[1]   # Down arrow from the search box moves into the list
        if ($key.Key -eq 'Down' -and $script:Gui.C.ToolList.SelectedItem) {
            [void]$script:Gui.C.ToolList.SelectedItem.Focus()
            $key.Handled = $true
        }
    })
    $c.RunButton.Add_Click({
        try { Invoke-ToolkitGuiRun } catch { Show-ToolkitGuiMessage "Something went wrong: $($_.Exception.Message)" }
    })
    $c.AdminButton.Add_Click({
        try {
            Start-ElevatedToolkit -ErrorAction Stop
            $script:Gui.Window.Close()
        }
        catch { Show-ToolkitGuiMessage 'Admin rights were declined (UAC), so this window stays as it is.' }
    })

    # Our own title bar (WindowChrome): light / dark, minimise, maximise / restore, close.
    $c.ThemeButton.Add_Click({ Use-ToolkitGuiTheme -Theme (Get-ToolkitThemeToggle -Theme $script:Gui.Theme).Next })
    $c.MinButton.Add_Click({ $script:Gui.Window.WindowState = 'Minimized' })
    $c.MaxButton.Add_Click({
        $w = $script:Gui.Window
        $w.WindowState = if ($w.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
    })
    $c.CloseButton.Add_Click({ $script:Gui.Window.Close() })
    $window.Add_StateChanged({
        # A maximised window hangs a few pixels off each screen edge; pad it back in.
        $g = $script:Gui
        if ($g.Window.WindowState -eq 'Maximized') {
            $g.C.Root.Margin          = New-Object System.Windows.Thickness 7
            $g.C.Root.BorderThickness = New-Object System.Windows.Thickness 0
            $g.C.MaxButton.Content    = ConvertTo-ToolkitGlyph 'E923'
            $g.C.MaxButton.ToolTip    = 'Restore'
        }
        else {
            $g.C.Root.Margin          = New-Object System.Windows.Thickness 0
            $g.C.Root.BorderThickness = New-Object System.Windows.Thickness 1
            $g.C.MaxButton.Content    = ConvertTo-ToolkitGlyph 'E922'
            $g.C.MaxButton.ToolTip    = 'Maximise'
        }
    })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        foreach ($run in @($script:Gui.Runs | Where-Object { -not $_.Done })) {
            try { Show-ToolkitGuiRunStatus -Run $run } catch { $run.Done = $true }
        }
    })
    $script:Gui.Timer = $timer
    $window.Add_Loaded({ $script:Gui.Timer.Start(); [void]$script:Gui.C.SearchBox.Focus() })
    $window.Add_Closed({ $script:Gui.Timer.Stop() })

    $firstTool = $script:Gui.Items | Select-Object -First 1
    if ($firstTool) { $c.ToolList.SelectedItem = $firstTool.Item }
    $window
}

function Show-EndpointToolkitGui {
    <#
    .SYNOPSIS
        Opens the Endpoint Toolkit window.
    .DESCRIPTION
        Pick a tool on the left (or search) to see what it does, any warning and its options, then click Run.
        Each tool runs in its own PowerShell window, with a UAC prompt first if it needs admin, so you can
        carry on in this one. The bottom panel shows how each run finished.

        Where there's no desktop to draw on (remote session, RMM shell, Server Core) it opens the console
        menu instead. To always get the console menu, use Show-EndpointToolkit (etkc).
    .EXAMPLE
        Show-EndpointToolkitGui
    .EXAMPLE
        etk
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-ToolkitGuiAvailable)) {
        Write-Host 'No desktop here (remote session, RMM shell or Server Core), so opening the console menu.' -ForegroundColor Yellow
        Show-EndpointToolkit
        return
    }

    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        # WPF needs a single-threaded apartment; Windows PowerShell has one by default, other hosts may not.
        $starter = Join-Path $script:ModuleRoot 'Start-Toolkit.ps1'
        Start-Process -FilePath (Get-ToolkitHostPath) `
            -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -File {0}' -f (Format-ToolkitArgument $starter))
        Write-Host 'Toolkit window opening in its own PowerShell.' -ForegroundColor Green
        return
    }

    try { $window = New-ToolkitGuiWindow }
    catch {
        Write-Host "The window couldn't open ($($_.Exception.Message)), so here's the console menu instead." -ForegroundColor Yellow
        Show-EndpointToolkit
        return
    }
    Write-Host 'Toolkit window open. Close it to get this prompt back.' -ForegroundColor DarkGray
    [void]$window.ShowDialog()
}
