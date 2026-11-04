#Requires -Version 5.1
<#
.SYNOPSIS
    Event Triage - a clean WPF front end for finding what's actually wrong in Windows event logs.

.DESCRIPTION
    v0.4
    - Queries local or remote machines (WinRM via Invoke-Command, or RPC via Get-WinEvent -ComputerName)
    - Runs every query in a background runspace so the UI never freezes
    - Groups events by Log + Provider + Event ID: count, first seen, last seen, most severe level
    - Presets: one-click views for crashes, disk, services, logon failures, Windows Update, TLS/Kerberos, Group Policy
    - Mute list: known-noise Provider:ID pairs are hidden (toggle to show); right-click a group to mute/unmute
    - Context view: pull everything from all logs in the minutes around an event to see what led up to it
    - Raw XML on demand, CSV export, one-click web search on an ID
    - Right-click any event or group: Copy AI prompt - a ready-made troubleshooting prompt with the event details,
      how often it occurs and (if loaded) the surrounding context, plain or with hostnames/users/IPs redacted

.NOTES
    Run as Administrator to read the Security log.
    Remote (WinRM) needs PowerShell Remoting enabled on the target.
    Remote (RPC) needs the "Remote Event Log Management" firewall rules on the target.
    Mutes are stored in %APPDATA%\EventTriage\EventTriage.mutes.json (seeded from the copy shipped beside the script).
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ------------------------------------------------------------------------------------------------
#  Shared state between the UI thread and background runspaces.
#  Workers only ever WRITE to $sync; a DispatcherTimer on the UI thread READS it and updates controls.
# ------------------------------------------------------------------------------------------------
$sync = [hashtable]::Synchronized(@{
    Job          = $null
    StatusText   = ''
    StatusDirty  = $false
    Rows         = $null
    GroupMap     = $null
    Events       = $null
    ResultReady  = $false
    Context      = $null
    ContextReady = $false
    ContextMins  = 5
    XmlText      = $null
    XmlReady     = $false
    LastTarget   = 'localhost'
    LastT        = $null
    LastLogs     = @('System', 'Application')
    LastRange    = 'not recorded'
    LastCred     = $null
    FilterText   = ''
    HideMuted    = $true
    Selected     = $null
    Mutes        = @()
})

# ------------------------------------------------------------------------------------------------
#  Mute list (known noise). Stored as JSON so you can edit it by hand.
# ------------------------------------------------------------------------------------------------
# Mutes live in %APPDATA%\EventTriage so they survive toolkit updates (the toolkit re-downloads into a
# fresh folder each run). First run seeds the file from the EventTriage.mutes.json shipped beside the script.
$DataDir  = Join-Path $env:APPDATA 'EventTriage'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
$MuteFile = Join-Path $DataDir 'EventTriage.mutes.json'
$BundledMutes = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'EventTriage.mutes.json' }
if (-not (Test-Path $MuteFile) -and $BundledMutes -and (Test-Path $BundledMutes)) {
    Copy-Item -LiteralPath $BundledMutes -Destination $MuteFile
}

$DefaultMutes = @(
    @{ provider = 'Microsoft-Windows-DistributedCOM';        id = 10016; note = 'DCOM permission noise - harmless' }
    @{ provider = 'Microsoft-Windows-Perflib';               id = 1008;  note = 'Perf counter failed to load - cosmetic' }
    @{ provider = 'Microsoft-Windows-User Profiles Service'; id = 1534;  note = 'Profile notification failure - cosmetic' }
    @{ provider = 'Microsoft-Windows-Kernel-EventTracing';   id = 2;     note = 'ETW session stopped - cosmetic' }
    @{ provider = 'Microsoft-Windows-Kernel-EventTracing';   id = 3;     note = 'ETW session failed to start - cosmetic' }
)

function Get-MuteKey([string]$Provider, $Id) { ('{0}|{1}' -f $Provider, $Id).ToLowerInvariant() }

function Load-Mutes {
    if (Test-Path $MuteFile) {
        try   { $sync.Mutes = @(Get-Content $MuteFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { $sync.Mutes = @(); Set-UiStatus "Couldn't read $MuteFile - starting with an empty mute list." }
    }
    else {
        $sync.Mutes = @($DefaultMutes | ForEach-Object { [pscustomobject]$_ })
        Save-Mutes
    }
}

function Save-Mutes {
    ConvertTo-Json -InputObject @($sync.Mutes) -Depth 3 | Set-Content -Path $MuteFile -Encoding UTF8
}

function Get-MuteKeys { [string[]]@($sync.Mutes | ForEach-Object { Get-MuteKey $_.provider $_.id }) }

# ------------------------------------------------------------------------------------------------
#  Presets. Logs/Provider/Ids are comma-separated strings; Levels is 'all' or 'cew' (Critical/Error/Warning).
# ------------------------------------------------------------------------------------------------
$Presets = @(
    @{ Name = 'Crashes and reboots';           Logs = 'System';               Levels = 'all'; Provider = '';                                   Ids = '12,13,41,1001,1074,6005,6006,6008' }
    @{ Name = 'Hardware errors (WHEA)';        Logs = 'System';               Levels = 'all'; Provider = 'Microsoft-Windows-WHEA-Logger';      Ids = '' }
    @{ Name = 'Disk and storage';              Logs = 'System';               Levels = 'cew'; Provider = '';                                   Ids = '7,11,51,55,98,129,137,140,153,157' }
    @{ Name = 'Service failures';              Logs = 'System';               Levels = 'all'; Provider = 'Service Control Manager';            Ids = '7000,7001,7009,7011,7022,7023,7024,7026,7031,7032,7034,7043,7045' }
    @{ Name = 'Application crashes';           Logs = 'Application';          Levels = 'all'; Provider = 'Application Error,Application Hang,.NET Runtime'; Ids = '1000,1002,1026' }
    @{ Name = 'Logon failures and lockouts';   Logs = 'Security';             Levels = 'all'; Provider = '';                                   Ids = '4625,4740,4771,4776' }
    @{ Name = 'Windows Update';                Logs = 'System,Setup';         Levels = 'all'; Provider = 'Microsoft-Windows-WindowsUpdateClient,Microsoft-Windows-Servicing'; Ids = '' }
    @{ Name = 'TLS, certificates and Kerberos'; Logs = 'System,Application';  Levels = 'cew'; Provider = 'Schannel,Microsoft-Windows-Security-Kerberos,Microsoft-Windows-Kerberos-Key-Distribution-Center,Microsoft-Windows-CAPI2'; Ids = '' }
    @{ Name = 'Group Policy';                  Logs = 'System,Microsoft-Windows-GroupPolicy/Operational'; Levels = 'cew'; Provider = 'Microsoft-Windows-GroupPolicy'; Ids = '' }
)

# ------------------------------------------------------------------------------------------------
#  XAML
# ------------------------------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Event Triage" Height="860" Width="1480" MinHeight="600" MinWidth="1000"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12"
        Background="#EEF1F5" Foreground="#1F2937">

  <Window.Resources>

    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#DDE2E8"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="12"/>
    </Style>

    <Style x:Key="Field" TargetType="StackPanel">
      <Setter Property="Margin" Value="0,0,16,8"/>
    </Style>

    <Style x:Key="Cap" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,0,0,3"/>
    </Style>

    <Style x:Key="H" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#111827"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="BorderBrush" Value="#CBD2DB"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="28"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,0,12,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#1F2937"/>
      <Setter Property="BorderBrush" Value="#CBD2DB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#1D4ED8"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#1D4ED8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,0"/>
    </Style>

    <Style TargetType="TabControl">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="0"/>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="10,4" Margin="0,0,6,0" Background="Transparent">
              <ContentPresenter ContentSource="Header" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#1D4ED8"/>
                <Setter Property="Foreground" Value="#111827"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="False">
                <Setter Property="Foreground" Value="#6B7280"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#F1F4F8"/>
      <Setter Property="AlternatingRowBackground" Value="#FAFBFC"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowHeight" Value="26"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#4B5563"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="BorderBrush" Value="#DDE2E8"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>

    <Style TargetType="DataGridRow">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#F3F6FA"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="8,0">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#DBEAFE"/>
          <Setter Property="Foreground" Value="#111827"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Severity colouring: the one place colour carries meaning -->
    <Style x:Key="LevelText" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Level}" Value="Critical">
          <Setter Property="Foreground" Value="#991B1B"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="Error">
          <Setter Property="Foreground" Value="#DC2626"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="Warning">
          <Setter Property="Foreground" Value="#B45309"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="Information">
          <Setter Property="Foreground" Value="#6B7280"/>
          <Setter Property="FontWeight" Value="Normal"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="Verbose">
          <Setter Property="Foreground" Value="#9CA3AF"/>
          <Setter Property="FontWeight" Value="Normal"/>
        </DataTrigger>
      </Style.Triggers>
    </Style>

    <!-- Context grid: the event you asked about is tinted so you can see what came before and after -->
    <Style x:Key="ContextRow" TargetType="DataGridRow" BasedOn="{StaticResource {x:Type DataGridRow}}">
      <Style.Triggers>
        <DataTrigger Binding="{Binding IsAnchor}" Value="True">
          <Setter Property="Background" Value="#FEF3C7"/>
        </DataTrigger>
      </Style.Triggers>
    </Style>

  </Window.Resources>

  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- ===================== Query bar ===================== -->
    <Border Grid.Row="0" Style="{StaticResource Panel}">
      <StackPanel>
        <WrapPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Computer"/>
            <TextBox Name="txtComputer" Width="180" ToolTip="Leave blank for this machine"/>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Remote method"/>
            <ComboBox Name="cboMethod" Width="90" SelectedIndex="0">
              <ComboBoxItem Content="WinRM"/>
              <ComboBoxItem Content="RPC"/>
            </ComboBox>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text=" "/>
            <CheckBox Name="chkCred" Content="Prompt for credentials" Height="28"/>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Logs"/>
            <StackPanel Orientation="Horizontal" Height="28">
              <CheckBox Name="chkSystem" Content="System" IsChecked="True"/>
              <CheckBox Name="chkApplication" Content="Application" IsChecked="True"/>
              <CheckBox Name="chkSecurity" Content="Security"/>
              <CheckBox Name="chkSetup" Content="Setup"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Other logs (comma separated)"/>
            <TextBox Name="txtCustomLogs" Width="280" ToolTip="e.g. Microsoft-Windows-GroupPolicy/Operational"/>
          </StackPanel>
        </WrapPanel>

        <WrapPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Preset"/>
            <ComboBox Name="cboPreset" Width="200"/>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Time range"/>
            <ComboBox Name="cboRange" Width="130" SelectedIndex="1">
              <ComboBoxItem Content="Last hour" Tag="1"/>
              <ComboBoxItem Content="Last 24 hours" Tag="24"/>
              <ComboBoxItem Content="Last 7 days" Tag="168"/>
              <ComboBoxItem Content="Last 30 days" Tag="720"/>
              <ComboBoxItem Content="All" Tag="0"/>
            </ComboBox>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Levels"/>
            <StackPanel Orientation="Horizontal" Height="28">
              <CheckBox Name="chkCritical" Content="Critical" IsChecked="True"/>
              <CheckBox Name="chkError" Content="Error" IsChecked="True"/>
              <CheckBox Name="chkWarning" Content="Warning" IsChecked="True"/>
              <CheckBox Name="chkInfo" Content="Information"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Providers (comma separated, wildcards ok)"/>
            <TextBox Name="txtProvider" Width="240" ToolTip="e.g. *Kernel-Power*, Schannel"/>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Event IDs"/>
            <TextBox Name="txtEventId" Width="120" ToolTip="Comma separated, e.g. 41,1001,7034"/>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text="Max events"/>
            <TextBox Name="txtMax" Width="70" Text="5000" ToolTip="0 = no limit (can be slow)"/>
          </StackPanel>
          <StackPanel Style="{StaticResource Field}">
            <TextBlock Style="{StaticResource Cap}" Text=" "/>
            <StackPanel Orientation="Horizontal">
              <Button Name="btnQuery" Content="Run query" Style="{StaticResource Primary}"/>
              <Button Name="btnCancel" Content="Cancel" IsEnabled="False"/>
            </StackPanel>
          </StackPanel>
        </WrapPanel>
      </StackPanel>
    </Border>

    <!-- ===================== Status ===================== -->
    <Grid Grid.Row="1" Margin="2,8,2,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBlock Name="txtStatus" Grid.Column="0" Foreground="#4B5563" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"
                 Text="Pick a preset or your own logs and time range, then run a query."/>
      <ProgressBar Name="prgBusy" Grid.Column="1" Width="160" Height="4" IsIndeterminate="True"
                   Foreground="#1D4ED8" Background="#E5E7EB" BorderThickness="0" Visibility="Collapsed"/>
    </Grid>

    <!-- ===================== Main ===================== -->
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="11*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="10*"/>
      </Grid.ColumnDefinitions>

      <!-- Triage -->
      <Border Grid.Column="0" Style="{StaticResource Panel}">
        <DockPanel>
          <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Name="txtTriageTitle" Grid.Column="0" Style="{StaticResource H}" Text="Triage"/>
            <TextBox Name="txtFilter" Grid.Column="1" Width="200" Margin="0,0,12,0"
                     ToolTip="Filter by provider, event ID, log or message"/>
            <CheckBox Name="chkHideMuted" Grid.Column="2" Content="Hide muted" IsChecked="True" ToolTip="Right-click a row to mute or unmute it"/>
            <Button Name="btnExportTriage" Grid.Column="3" Content="Export CSV" Margin="0"/>
          </Grid>
          <DataGrid Name="dgTriage">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Level" Binding="{Binding Level}" Width="85" ElementStyle="{StaticResource LevelText}"/>
              <DataGridTextColumn Header="Log" Binding="{Binding Log}" Width="95"/>
              <DataGridTextColumn Header="Provider" Binding="{Binding Provider}" Width="230"/>
              <DataGridTextColumn Header="ID" Binding="{Binding Id}" Width="60"/>
              <DataGridTextColumn Header="Count" Binding="{Binding Count}" Width="60"/>
              <DataGridTextColumn Header="First seen" Binding="{Binding FirstSeen, StringFormat='yyyy-MM-dd HH:mm'}" Width="120"/>
              <DataGridTextColumn Header="Last seen" Binding="{Binding LastSeen, StringFormat='yyyy-MM-dd HH:mm'}" Width="120"/>
              <DataGridCheckBoxColumn Header="Muted" Binding="{Binding Muted}" Width="55"/>
              <DataGridTextColumn Header="Latest message" Binding="{Binding Sample}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </Border>

      <GridSplitter Grid.Column="1" Width="8" Background="Transparent" HorizontalAlignment="Center" VerticalAlignment="Stretch"/>

      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Events / Context -->
        <Border Grid.Row="0" Style="{StaticResource Panel}">
          <TabControl Name="tabRight">
            <TabItem Name="tabEvents" Header="Events">
              <DockPanel Margin="0,10,0,0">
                <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Name="txtEventsTitle" Grid.Column="0" Foreground="#6B7280" VerticalAlignment="Center" Text="Select a group on the left"/>
                  <Button Name="btnExportEvents" Grid.Column="1" Content="Export CSV" Margin="0"/>
                </Grid>
                <DataGrid Name="dgEvents">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Time" Binding="{Binding TimeCreated, StringFormat='yyyy-MM-dd HH:mm:ss'}" Width="135"/>
                    <DataGridTextColumn Header="Level" Binding="{Binding Level}" Width="80" ElementStyle="{StaticResource LevelText}"/>
                    <DataGridTextColumn Header="Computer" Binding="{Binding MachineName}" Width="120"/>
                    <DataGridTextColumn Header="ID" Binding="{Binding Id}" Width="55"/>
                    <DataGridTextColumn Header="Message" Binding="{Binding Summary}" Width="*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </TabItem>
            <TabItem Name="tabContext" Header="Context">
              <DockPanel Margin="0,10,0,0">
                <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Name="txtContextTitle" Grid.Column="0" Foreground="#6B7280" VerticalAlignment="Center"
                             Text="Select an event, then use Show context to see everything around it"/>
                  <Button Name="btnExportContext" Grid.Column="1" Content="Export CSV" Margin="0"/>
                </Grid>
                <DataGrid Name="dgContext" RowStyle="{StaticResource ContextRow}">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Offset" Binding="{Binding Offset}" Width="70"/>
                    <DataGridTextColumn Header="Time" Binding="{Binding TimeCreated, StringFormat='HH:mm:ss'}" Width="75"/>
                    <DataGridTextColumn Header="Level" Binding="{Binding Level}" Width="80" ElementStyle="{StaticResource LevelText}"/>
                    <DataGridTextColumn Header="Log" Binding="{Binding LogName}" Width="90"/>
                    <DataGridTextColumn Header="Provider" Binding="{Binding ProviderName}" Width="170"/>
                    <DataGridTextColumn Header="ID" Binding="{Binding Id}" Width="55"/>
                    <DataGridTextColumn Header="Message" Binding="{Binding Summary}" Width="*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </TabItem>
          </TabControl>
        </Border>

        <GridSplitter Grid.Row="1" Height="8" Background="Transparent" HorizontalAlignment="Stretch" VerticalAlignment="Center"/>

        <!-- Detail -->
        <Border Grid.Row="2" Style="{StaticResource Panel}">
          <DockPanel>
            <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Style="{StaticResource H}" Text="Details"/>
              <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button Name="btnCopy" Content="Copy"/>
                <Button Name="btnXml" Content="Show XML"/>
                <Button Name="btnSearch" Content="Search the web"/>
                <ComboBox Name="cboCtxWindow" Width="90" SelectedIndex="1" Margin="0,0,8,0">
                  <ComboBoxItem Content="1 min" Tag="1"/>
                  <ComboBoxItem Content="5 min" Tag="5"/>
                  <ComboBoxItem Content="15 min" Tag="15"/>
                  <ComboBoxItem Content="60 min" Tag="60"/>
                </ComboBox>
                <Button Name="btnContext" Content="Show context" Style="{StaticResource Primary}" Margin="0"/>
              </StackPanel>
            </Grid>
            <TextBox Name="txtDetail" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap"
                     FontFamily="Consolas" FontSize="12" Height="Auto" Padding="8" BorderThickness="0"
                     VerticalContentAlignment="Top" Background="#FAFBFC" VerticalScrollBarVisibility="Auto"/>
          </DockPanel>
        </Border>
      </Grid>
    </Grid>
  </Grid>
</Window>
'@

# ------------------------------------------------------------------------------------------------
#  Load the window and grab every named control into $c
# ------------------------------------------------------------------------------------------------
[xml]$xamlDoc = $xaml
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlDoc))
$c = @{}
foreach ($node in $xamlDoc.SelectNodes('//*[@Name]')) { $n = $node.GetAttribute('Name'); $c[$n] = $window.FindName($n) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { $window.Title = 'Event Triage  (not elevated - Security log will be unavailable)' }

[void]$c.cboPreset.Items.Add('Choose a preset...')
foreach ($p in $Presets) { [void]$c.cboPreset.Items.Add($p.Name) }
$c.cboPreset.SelectedIndex = 0

# ------------------------------------------------------------------------------------------------
#  The per-event shaping that runs on the target (locally, or remotely inside Invoke-Command).
#  Kept as TEXT so each background runspace can rebuild it with [scriptblock]::Create.
#  Produces flat objects with the same shape whether they come back live or deserialized.
# ------------------------------------------------------------------------------------------------
$WorkerText = @'
param($gw)
$names = @{ 1 = 'Critical'; 2 = 'Error'; 3 = 'Warning'; 4 = 'Information'; 5 = 'Verbose' }
Get-WinEvent @gw | ForEach-Object {
    $e   = $_
    $sev = [int]$e.Level
    if ($sev -lt 1 -or $sev -gt 5) { $sev = 4 }
    $msg = if ([string]::IsNullOrWhiteSpace($e.Message)) { '(message not available - the querying host has no metadata for this provider)' } else { $e.Message }
    $summary = ($msg -split "`r?`n")[0].Trim()
    if ($summary.Length -gt 200) { $summary = $summary.Substring(0, 200) + ' ...' }
    $user = $null
    if ($e.UserId) { try { $user = $e.UserId.Translate([System.Security.Principal.NTAccount]).Value } catch { $user = $e.UserId.Value } }
    [pscustomobject]@{
        TimeCreated     = $e.TimeCreated
        Id              = $e.Id
        Sev             = $sev
        Level           = $names[$sev]
        LogName         = $e.LogName
        ProviderName    = $e.ProviderName
        MachineName     = $e.MachineName
        RecordId        = $e.RecordId
        TaskDisplayName = $e.TaskDisplayName
        User            = $user
        Message         = $msg
        Summary         = $summary
        Props           = @($e.Properties | ForEach-Object { [string]$_.Value })
    }
}
'@

# ------------------------------------------------------------------------------------------------
#  Background worker scripts. They run in their own runspace with $sync plus the variables passed in.
#  They never touch UI controls - they write results into $sync and set a flag.
# ------------------------------------------------------------------------------------------------

# Shared plumbing text: fetch + split errors from events. $T = target info, $gw = Get-WinEvent splat.
$FetchText = @'
function Set-Status([string]$Text) { $sync.StatusText = $Text; $sync.StatusDirty = $true }
function Get-EventsFromTarget($T, $gw) {
    $worker = [scriptblock]::Create($WorkerText)
    if ($T.IsLocal) {
        $raw = @(& $worker $gw 2>&1)
    }
    elseif ($T.Method -eq 'RPC') {
        $gw.ComputerName = $T.Target
        if ($T.Credential) { $gw.Credential = $T.Credential }
        $raw = @(& $worker $gw 2>&1)
    }
    else {
        $ic = @{ ComputerName = $T.Target; ScriptBlock = $worker; ArgumentList = @(, $gw); ErrorAction = 'Continue' }
        if ($T.Credential) { $ic.Credential = $T.Credential }
        $raw = @(Invoke-Command @ic 2>&1)
    }
    $events   = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $problems = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                 ForEach-Object { $_.Exception.Message } |
                 Where-Object { $_ -notmatch 'No events were found' } | Select-Object -Unique)
    $note = ''
    if ($problems.Count -gt 0) {
        $note = $problems[0]
        if     ($note -match 'WinRM|WS-Management') { $note += '   Tip: switch Remote method to RPC, or enable PS Remoting on the target.' }
        elseif ($note -match 'RPC server')          { $note += '   Tip: switch Remote method to WinRM, or allow "Remote Event Log Management" through the target firewall.' }
        elseif ($note -match 'unauthorized|Access is denied') { $note += '   Tip: run as Administrator (Security log), or use Prompt for credentials.' }
    }
    @{ Events = $events; Note = $note }
}
'@

$QueryScript = [scriptblock]::Create($FetchText + @'

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    Set-Status "Querying $($Q.Target) ..."

    $fh = @{ LogName = $Q.Logs }
    if ($Q.Levels)    { $fh.Level        = $Q.Levels }
    if ($Q.StartTime) { $fh.StartTime    = $Q.StartTime }
    if ($Q.Provider)  { $fh.ProviderName = $Q.Provider }
    if ($Q.Ids)       { $fh.ID           = $Q.Ids }
    $gw = @{ FilterHashtable = $fh; ErrorAction = 'Continue' }
    if ($Q.Max -gt 0) { $gw.MaxEvents = $Q.Max }

    $r      = Get-EventsFromTarget $Q $gw
    $events = $r.Events
    $note   = $r.Note

    # Group by Log + Provider + ID
    $levelNames = @{ 1 = 'Critical'; 2 = 'Error'; 3 = 'Warning'; 4 = 'Information'; 5 = 'Verbose' }
    $map   = @{}
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($e in $events) {
        $key = '{0}|{1}|{2}' -f $e.LogName, $e.ProviderName, $e.Id
        if (-not $map.ContainsKey($key)) {
            $map[$key] = New-Object System.Collections.Generic.List[object]
            $order.Add($key)
        }
        $map[$key].Add($e)
    }

    $rows = foreach ($key in $order) {
        $list   = $map[$key]
        $sorted = @($list | Sort-Object TimeCreated)
        $sev    = [int](($list | ForEach-Object { $_.Sev } | Measure-Object -Minimum).Minimum)
        $latest = $sorted[-1]
        $mkey   = ('{0}|{1}' -f $latest.ProviderName, $latest.Id).ToLowerInvariant()
        [pscustomobject]@{
            Key       = $key
            Sev       = $sev
            Level     = $levelNames[$sev]
            Log       = $latest.LogName
            Provider  = $latest.ProviderName
            Id        = $latest.Id
            Count     = $list.Count
            FirstSeen = $sorted[0].TimeCreated
            LastSeen  = $latest.TimeCreated
            Muted     = [bool]($MuteKeys -contains $mkey)
            Sample    = $latest.Summary
        }
    }
    $rows = @($rows | Sort-Object -Property @{ Expression = 'Sev' }, @{ Expression = 'Count'; Descending = $true })
    $rowList = New-Object System.Collections.Generic.List[object]
    foreach ($r2 in $rows) { $rowList.Add($r2) }

    $sync.Events      = $events
    $sync.GroupMap    = $map
    $sync.Rows        = $rowList
    $sync.ResultReady = $true

    $crit  = @($rows | Where-Object { $_.Sev -eq 1 -and -not $_.Muted }).Count
    $err   = @($rows | Where-Object { $_.Sev -eq 2 -and -not $_.Muted }).Count
    $warn  = @($rows | Where-Object { $_.Sev -eq 3 -and -not $_.Muted }).Count
    $muted = @($rows | Where-Object { $_.Muted }).Count
    $secs  = $sw.Elapsed.TotalSeconds.ToString('0.0')

    if ($events.Count -eq 0 -and $note) {
        Set-Status "Query failed: $note"
    }
    elseif ($events.Count -eq 0) {
        Set-Status "No events matched on $($Q.Target) ($secs s). Widen the time range or levels, or check the log names."
    }
    else {
        $status = "{0:N0} events in {1} groups on {2}  -  {3} critical, {4} error, {5} warning" -f $events.Count, $rows.Count, $Q.Target, $crit, $err, $warn
        if ($muted) { $status += "  -  $muted muted" }
        $status += "  -  $secs s"
        if ($note) { $status += "   Note: $note" }
        Set-Status $status
    }
}
catch {
    Set-Status "Query failed: $($_.Exception.Message)"
}
'@)

$ContextScript = [scriptblock]::Create($FetchText + @'

$ErrorActionPreference = 'Stop'
try {
    $anchor = [datetime]$X.Anchor
    Set-Status ("Loading everything within {0} min of {1:HH:mm:ss} on {2} ..." -f $X.Minutes, $anchor, $X.Target)

    $fh = @{ LogName = $X.Logs; StartTime = $anchor.AddMinutes(-$X.Minutes); EndTime = $anchor.AddMinutes($X.Minutes) }
    $gw = @{ FilterHashtable = $fh; ErrorAction = 'Continue'; MaxEvents = 4000 }

    $r      = Get-EventsFromTarget $X $gw
    $events = $r.Events

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($events | Sort-Object TimeCreated)) {
        $delta = $e.TimeCreated - $anchor
        $sign  = if ($delta.Ticks -lt 0) { '-' } else { '+' }
        $abs   = $delta.Duration()
        $off   = if ($abs.TotalHours -ge 1) { '{0}{1}:{2:00}:{3:00}' -f $sign, [int][math]::Floor($abs.TotalHours), $abs.Minutes, $abs.Seconds }
                 else                       { '{0}{1}:{2:00}' -f $sign, $abs.Minutes, $abs.Seconds }
        $isAnchor = ($e.RecordId -eq $X.RecordId) -and ($e.LogName -eq $X.LogName)
        $e | Add-Member -NotePropertyName Offset   -NotePropertyValue $off      -Force
        $e | Add-Member -NotePropertyName IsAnchor -NotePropertyValue $isAnchor -Force
        $list.Add($e)
    }

    $sync.Context      = $list
    $sync.ContextMins  = $X.Minutes
    $sync.ContextReady = $true

    if ($list.Count -eq 0 -and $r.Note) { Set-Status "Context failed: $($r.Note)" }
    else {
        $status = "{0} events within {1} min of {2:HH:mm:ss} across {3}" -f $list.Count, $X.Minutes, $anchor, ($X.Logs -join ', ')
        if ($r.Note) { $status += "   Note: $($r.Note)" }
        Set-Status $status
    }
}
catch {
    Set-Status "Context failed: $($_.Exception.Message)"
}
'@)

$XmlScript = {
    $ErrorActionPreference = 'Stop'
    function Set-Status([string]$Text) { $sync.StatusText = $Text; $sync.StatusDirty = $true }
    try {
        Set-Status "Fetching XML for record $($X.RecordId) ..."
        $gw = @{ LogName = $X.LogName; FilterXPath = "*[System[EventRecordID=$($X.RecordId)]]"; MaxEvents = 1; ErrorAction = 'Stop' }

        if ($X.IsLocal) {
            $raw = (Get-WinEvent @gw).ToXml()
        }
        elseif ($X.Method -eq 'RPC') {
            $gw.ComputerName = $X.Target
            if ($X.Credential) { $gw.Credential = $X.Credential }
            $raw = (Get-WinEvent @gw).ToXml()
        }
        else {
            $ic = @{ ComputerName = $X.Target; ScriptBlock = { param($p) (Get-WinEvent @p).ToXml() }; ArgumentList = @(, $gw) }
            if ($X.Credential) { $ic.Credential = $X.Credential }
            $raw = Invoke-Command @ic
        }

        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($raw)
        $sw = New-Object System.IO.StringWriter
        $xw = New-Object System.Xml.XmlTextWriter($sw)
        $xw.Formatting = 'Indented'
        $doc.WriteContentTo($xw)
        $xw.Flush()

        $sync.XmlText  = $sw.ToString()
        $sync.XmlReady = $true
        Set-Status "XML loaded for record $($X.RecordId)."
    }
    catch {
        Set-Status "XML fetch failed: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------------------------------------
#  Runspace runner
# ------------------------------------------------------------------------------------------------
function Start-Worker {
    param([scriptblock]$Script, [hashtable]$Vars)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('WorkerText', $WorkerText)
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script.ToString())

    $sync.Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

# ------------------------------------------------------------------------------------------------
#  UI helpers (main runspace, UI thread only)
# ------------------------------------------------------------------------------------------------
function Set-UiStatus([string]$Text) { $c.txtStatus.Text = $Text }

function Get-Target {
    $target  = $c.txtComputer.Text.Trim()
    $isLocal = [string]::IsNullOrWhiteSpace($target) -or ($target -in @('.', 'localhost', $env:COMPUTERNAME))
    @{
        Target     = $(if ($isLocal) { 'localhost' } else { $target })
        IsLocal    = $isLocal
        Method     = [string]$c.cboMethod.SelectedItem.Content
        Credential = $null
    }
}

function Get-LastTarget {
    # Target details from the last query - so context/XML hit the same box even if the textbox has changed since
    if ($sync.LastT) { return $sync.LastT }
    return (Get-Target)
}

function Apply-TriageFilter {
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($c.dgTriage.ItemsSource)
    if ($null -eq $view) { return }
    $sync.FilterText = $c.txtFilter.Text
    $sync.HideMuted  = [bool]$c.chkHideMuted.IsChecked
    $view.Filter = [Predicate[object]]{
        param($item)
        if ($sync.HideMuted -and $item.Muted) { return $false }
        $t = $sync.FilterText
        if ([string]::IsNullOrWhiteSpace($t)) { return $true }
        $hay = '{0} {1} {2} {3} {4}' -f $item.Level, $item.Log, $item.Provider, $item.Id, $item.Sample
        return ($hay.IndexOf($t, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    Update-TriageTitle
}

function Update-TriageTitle {
    if (-not $sync.Rows) { $c.txtTriageTitle.Text = 'Triage'; return }
    $muted = @($sync.Rows | Where-Object { $_.Muted }).Count
    $title = 'Triage  -  {0} groups' -f $sync.Rows.Count
    if ($muted -gt 0) { $title += $(if ($c.chkHideMuted.IsChecked) { " ($muted muted, hidden)" } else { " ($muted muted)" }) }
    $c.txtTriageTitle.Text = $title
}

function Show-EventDetail($ev) {
    if ($null -eq $ev) { $c.txtDetail.Text = ''; return }
    $sync.Selected = $ev
    $sb = New-Object System.Text.StringBuilder
    $line = { param($k, $v) [void]$sb.AppendLine(('{0,-10} {1}' -f $k, $v)) }
    & $line 'Time'      ('{0:yyyy-MM-dd HH:mm:ss}' -f $ev.TimeCreated)
    & $line 'Computer'  $ev.MachineName
    & $line 'Log'       $ev.LogName
    & $line 'Provider'  $ev.ProviderName
    & $line 'Event ID'  $ev.Id
    & $line 'Level'     $ev.Level
    & $line 'Task'      $ev.TaskDisplayName
    & $line 'User'      $ev.User
    & $line 'Record'    $ev.RecordId
    [void]$sb.AppendLine(('-' * 72))
    [void]$sb.AppendLine($ev.Message)
    if ($ev.Props) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('Event data')
        $i = 0
        foreach ($p in @($ev.Props)) { [void]$sb.AppendLine(('  [{0}] {1}' -f $i, $p)); $i++ }
    }
    $c.txtDetail.Text = $sb.ToString()
}

function Split-List([string]$Text) {
    [string[]]@($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Apply-Preset($p) {
    $logs = Split-List $p.Logs
    $c.chkSystem.IsChecked      = ($logs -contains 'System')
    $c.chkApplication.IsChecked = ($logs -contains 'Application')
    $c.chkSecurity.IsChecked    = ($logs -contains 'Security')
    $c.chkSetup.IsChecked       = ($logs -contains 'Setup')
    $c.txtCustomLogs.Text       = (@($logs | Where-Object { $_ -notin @('System', 'Application', 'Security', 'Setup') }) -join ', ')
    $all = ($p.Levels -eq 'all')
    $c.chkCritical.IsChecked = $true
    $c.chkError.IsChecked    = $true
    $c.chkWarning.IsChecked  = $true
    $c.chkInfo.IsChecked     = $all
    $c.txtProvider.Text = $p.Provider
    $c.txtEventId.Text  = $p.Ids
}

function Start-Query {
    if ($sync.Job) { return }

    $logs = @()
    if ($c.chkSystem.IsChecked)      { $logs += 'System' }
    if ($c.chkApplication.IsChecked) { $logs += 'Application' }
    if ($c.chkSecurity.IsChecked)    { $logs += 'Security' }
    if ($c.chkSetup.IsChecked)       { $logs += 'Setup' }
    $logs += Split-List $c.txtCustomLogs.Text
    if ($logs.Count -eq 0) { Set-UiStatus 'Pick at least one log to query.'; return }

    $levels = @()
    if ($c.chkCritical.IsChecked) { $levels += 1 }
    if ($c.chkError.IsChecked)    { $levels += 2 }
    if ($c.chkWarning.IsChecked)  { $levels += 3 }
    if ($c.chkInfo.IsChecked)     { $levels += 0, 4 }

    $hours = [int]$c.cboRange.SelectedItem.Tag
    $start = if ($hours -gt 0) { (Get-Date).AddHours(-$hours) } else { $null }

    $ids = @()
    if (-not [string]::IsNullOrWhiteSpace($c.txtEventId.Text)) {
        $ids = @($c.txtEventId.Text -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    }

    $max = 5000
    if ($c.txtMax.Text -match '^\d+$') { $max = [int]$c.txtMax.Text }

    $t = Get-Target
    if ($c.chkCred.IsChecked -and -not $t.IsLocal) {
        $cred = Get-Credential -Message "Credentials for $($t.Target)"
        if (-not $cred) { Set-UiStatus 'Query cancelled - no credentials supplied.'; return }
        $t.Credential = $cred
    }
    $sync.LastTarget = $t.Target
    $sync.LastT      = $t
    $sync.LastLogs   = [string[]]$logs
    $sync.LastRange  = if ($hours -gt 0) { '{0} (from {1:yyyy-MM-dd HH:mm} to {2:yyyy-MM-dd HH:mm})' -f ([string]$c.cboRange.SelectedItem.Content).ToLower(), $start, (Get-Date) } else { 'all available history' }

    $Q = @{
        Target     = $t.Target
        IsLocal    = $t.IsLocal
        Method     = $t.Method
        Credential = $t.Credential
        Logs       = [string[]]$logs
        Levels     = [int[]]$levels
        StartTime  = $start
        Provider   = Split-List $c.txtProvider.Text
        Ids        = [int[]]$ids
        Max        = $max
    }

    $c.dgTriage.ItemsSource  = $null
    $c.dgEvents.ItemsSource  = $null
    $c.dgContext.ItemsSource = $null
    $c.txtDetail.Text = ''
    $c.txtTriageTitle.Text  = 'Triage'
    $c.txtEventsTitle.Text  = 'Select a group on the left'
    $c.txtContextTitle.Text = 'Select an event, then use Show context to see everything around it'
    $c.tabRight.SelectedIndex = 0
    $sync.Selected = $null
    Set-UiStatus "Querying $($t.Target) ..."
    Start-Worker -Script $QueryScript -Vars @{ Q = $Q; MuteKeys = (Get-MuteKeys) }
}

function Start-Context {
    $ev = $sync.Selected
    if ($null -eq $ev) { Set-UiStatus 'Select an event first (in Events or Context), then Show context.'; return }
    if ($sync.Job) { return }
    $t    = Get-LastTarget
    $logs = [string[]]@(@('System', 'Application') + @($sync.LastLogs) | Select-Object -Unique)
    $X = @{
        Target     = $t.Target
        IsLocal    = $t.IsLocal
        Method     = $t.Method
        Credential = $t.Credential
        Logs       = $logs
        Anchor     = $ev.TimeCreated
        RecordId   = $ev.RecordId
        LogName    = $ev.LogName
        Minutes    = [int]$c.cboCtxWindow.SelectedItem.Tag
    }
    Start-Worker -Script $ContextScript -Vars @{ X = $X }
}

function Save-CsvDialog {
    param($Data, [string]$Prefix)
    if (-not $Data -or @($Data).Count -eq 0) { Set-UiStatus 'Nothing to export yet.'; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = '{0}_{1}_{2:yyyyMMdd_HHmm}.csv' -f $Prefix, ($sync.LastTarget -replace '[^\w\-]', '_'), (Get-Date)
    if ($dlg.ShowDialog()) {
        $Data | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
        Set-UiStatus "Exported $(@($Data).Count) rows to $($dlg.FileName)"
    }
}

# ------------------------------------------------------------------------------------------------
#  Shared actions for buttons and right-click menus
# ------------------------------------------------------------------------------------------------
function Get-GroupRow($ev) {
    if ($null -eq $ev -or -not $sync.Rows) { return $null }
    $key = '{0}|{1}|{2}' -f $ev.LogName, $ev.ProviderName, $ev.Id
    $sync.Rows | Where-Object { $_.Key -eq $key } | Select-Object -First 1
}

function Get-LatestEventInGroup($row) {
    if ($null -eq $row -or -not $sync.GroupMap) { return $null }
    $sync.GroupMap[$row.Key] | Sort-Object TimeCreated -Descending | Select-Object -First 1
}

function Protect-Text([string]$Text, $ev) {
    # Best-effort redaction for pasting into an external AI: hostnames, domain, user, IPs, emails, domain SIDs.
    $t  = $Text
    $ic = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $fqdn = [string]$ev.MachineName
    if ($fqdn) {
        $short = $fqdn.Split('.')[0]
        $t = [regex]::Replace($t, [regex]::Escape($fqdn), 'HOST01', $ic)
        if ($short.Length -ge 3) { $t = [regex]::Replace($t, '\b' + [regex]::Escape($short) + '\b', 'HOST01', $ic) }
        if ($fqdn.Contains('.')) {
            $dom = $fqdn.Substring($fqdn.IndexOf('.') + 1)
            $t = [regex]::Replace($t, [regex]::Escape($dom), 'example.local', $ic)
        }
    }
    $u = [string]$ev.User
    $builtin = @('NT AUTHORITY', 'NT SERVICE', 'BUILTIN', 'Window Manager', 'Font Driver Host', 'IIS APPPOOL')
    if ($u -and $u -match '^(?<d>[^\\]+)\\(?<n>.+)$' -and ($Matches.d -notin $builtin)) {
        $d = $Matches.d; $n = $Matches.n
        if ($n.Length -ge 3) { $t = [regex]::Replace($t, '\b' + [regex]::Escape($n) + '\b', 'USER', $ic) }
        if ($d.Length -ge 3) { $t = [regex]::Replace($t, '\b' + [regex]::Escape($d) + '\b', 'DOMAIN', $ic) }
    }
    $t = [regex]::Replace($t, '\b\d{1,3}(\.\d{1,3}){3}\b', 'x.x.x.x')
    $t = [regex]::Replace($t, '[\w.+-]+@[\w-]+(\.[\w-]+)+', 'user@example.com')
    $t = [regex]::Replace($t, 'S-1-5-21-[\d-]+', 'S-1-5-21-REDACTED')
    return $t
}

function New-AiPrompt($ev, [bool]$Redact) {
    $row = Get-GroupRow $ev
    $sb  = New-Object System.Text.StringBuilder
    $add = { param($s) [void]$sb.AppendLine([string]$s) }

    & $add '# Windows event log troubleshooting request'
    & $add ''
    & $add "I'm an IT systems engineer investigating an issue on a Windows machine using Event Viewer. Act as a senior Windows infrastructure engineer and help me diagnose and fix it."
    & $add ''
    & $add '## What I need from you'
    & $add '1. In plain English, what this event means.'
    & $add '2. The most likely root causes, ranked, and how to tell them apart.'
    & $add '3. How to confirm each cause: the specific PowerShell or CMD commands, logs or checks to run.'
    & $add '4. A step-by-step fix for the most likely cause, safest option first, including what could go wrong.'
    & $add '5. Whether this can be safely ignored, and why.'
    & $add ''
    & $add 'Prefer built-in Windows tools and PowerShell. Point me to the relevant Microsoft documentation. If you need more information, tell me exactly what to collect and how. Do not guess at facts you cannot infer from the details below - say what is uncertain.'
    & $add ''
    & $add '## Environment'
    & $add "- Computer: $($ev.MachineName)"
    & $add "- Query window: $($sync.LastRange)"
    & $add '- Notes: (add OS/build, server role, recent changes, anything already tried)'
    & $add ''
    & $add '## The event'
    & $add ('- Time: {0:yyyy-MM-dd HH:mm:ss}' -f $ev.TimeCreated)
    & $add "- Log: $($ev.LogName)"
    & $add "- Provider: $($ev.ProviderName)"
    & $add "- Event ID: $($ev.Id)"
    & $add "- Level: $($ev.Level)"
    if ($ev.TaskDisplayName) { & $add "- Task: $($ev.TaskDisplayName)" }
    if ($ev.User)            { & $add "- User: $($ev.User)" }
    & $add ''
    & $add 'Message:'
    & $add '```'
    $msg = [string]$ev.Message
    if ($msg.Length -gt 2500) { $msg = $msg.Substring(0, 2500) + ' [truncated]' }
    & $add $msg.TrimEnd()
    & $add '```'
    $props = @($ev.Props)
    if ($props.Count -gt 0) {
        & $add ''
        & $add 'Event data:'
        & $add '```'
        $i = 0
        foreach ($pv in $props) {
            if ($i -ge 30) { & $add ('... {0} more values omitted' -f ($props.Count - 30)); break }
            & $add ('[{0}] {1}' -f $i, $pv); $i++
        }
        & $add '```'
    }

    if ($row) {
        & $add ''
        & $add '## How often it happens'
        & $add ('- {0} occurrence(s) in the query window, first {1:yyyy-MM-dd HH:mm}, last {2:yyyy-MM-dd HH:mm}' -f $row.Count, $row.FirstSeen, $row.LastSeen)
        $others = @($sync.GroupMap[$row.Key] | Where-Object { $_.RecordId -ne $ev.RecordId } |
                    Sort-Object TimeCreated -Descending | Select-Object -ExpandProperty Summary -Unique |
                    Where-Object { $_ -ne $ev.Summary } | Select-Object -First 3)
        if ($others.Count -gt 0) {
            & $add '- Other recent messages from the same provider and ID:'
            foreach ($o in $others) { & $add "  - $o" }
        }
    }

    # Surrounding events, if the Context view has been loaded for this event
    $ctx = $sync.Context
    if ($ctx -and $ctx.Count -gt 0) {
        $idx = -1
        for ($k = 0; $k -lt $ctx.Count; $k++) {
            if ($ctx[$k].RecordId -eq $ev.RecordId -and $ctx[$k].LogName -eq $ev.LogName) { $idx = $k; break }
        }
        if ($idx -ge 0) {
            $from = [math]::Max(0, $idx - 12)
            $to   = [math]::Min($ctx.Count - 1, $idx + 12)
            & $add ''
            & $add ('## What happened around it ({0} min either side, all logs)' -f $sync.ContextMins)
            & $add '```'
            for ($k = $from; $k -le $to; $k++) {
                $x = $ctx[$k]
                $sm = [string]$x.Summary
                if ($sm.Length -gt 110) { $sm = $sm.Substring(0, 110) + '...' }
                $mark = if ($k -eq $idx) { '   <-- this event' } else { '' }
                & $add ('{0,-8} {1,-11} {2,-12} {3} {4}  {5}{6}' -f $x.Offset, $x.Level, $x.LogName, $x.ProviderName, $x.Id, $sm, $mark)
            }
            & $add '```'
        }
    }

    $text = $sb.ToString()
    if ($Redact) { $text = Protect-Text $text $ev }
    return $text
}

function Copy-AiPrompt($ev, [bool]$Redact) {
    if ($null -eq $ev) { Set-UiStatus 'Select an event first.'; return }
    $text = New-AiPrompt $ev $Redact
    [System.Windows.Clipboard]::SetText($text)
    $tag = if ($Redact) { ' (redacted)' } else { '' }
    Set-UiStatus ('AI prompt copied{0} - {1:N0} characters, ready to paste into any AI assistant.' -f $tag, $text.Length)
}

function Start-XmlFetch {
    $ev = $sync.Selected
    if ($null -eq $ev) { Set-UiStatus 'Select an event first.'; return }
    if ($sync.Job) { return }
    $t = Get-LastTarget
    $X = @{ Target = $t.Target; IsLocal = $t.IsLocal; Method = $t.Method; Credential = $t.Credential; LogName = $ev.LogName; RecordId = $ev.RecordId }
    Start-Worker -Script $XmlScript -Vars @{ X = $X }
}

function Search-Web {
    $ev  = $sync.Selected
    $row = $c.dgTriage.SelectedItem
    if ($ev)      { $prov = $ev.ProviderName; $id = $ev.Id }
    elseif ($row) { $prov = $row.Provider;    $id = $row.Id }
    else          { Set-UiStatus 'Select a group or event first.'; return }
    Start-Process ('https://www.google.com/search?q=' + [uri]::EscapeDataString(('"{0}" "event id {1}"' -f $prov, $id)))
}

function Copy-Details {
    if ($c.txtDetail.Text) { [System.Windows.Clipboard]::SetText($c.txtDetail.Text); Set-UiStatus 'Details copied to clipboard.' }
}

function Select-RowUnderMouse($grid, $e) {
    # Right-click doesn't select in a DataGrid by default; walk up from the clicked element to its row and select it
    $dep = $e.OriginalSource
    while ($dep -and -not ($dep -is [System.Windows.Controls.DataGridRow])) {
        if ($dep -is [System.Windows.Media.Visual] -or $dep -is [System.Windows.Media.Media3D.Visual3D]) {
            $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
        } else {
            $dep = [System.Windows.LogicalTreeHelper]::GetParent($dep)
        }
    }
    if ($dep) { $dep.IsSelected = $true }
}

function New-MenuItem([string]$Header, [scriptblock]$Action) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $Header
    $mi.Add_Click($Action)
    $mi
}

function New-EventMenu {
    $m = New-Object System.Windows.Controls.ContextMenu
    [void]$m.Items.Add((New-MenuItem 'Copy AI prompt'            { Copy-AiPrompt $sync.Selected $false }))
    [void]$m.Items.Add((New-MenuItem 'Copy AI prompt (redacted)' { Copy-AiPrompt $sync.Selected $true }))
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    [void]$m.Items.Add((New-MenuItem 'Show context'   { Start-Context }))
    [void]$m.Items.Add((New-MenuItem 'Show XML'       { Start-XmlFetch }))
    [void]$m.Items.Add((New-MenuItem 'Search the web' { Search-Web }))
    [void]$m.Items.Add((New-MenuItem 'Copy details'   { Copy-Details }))
    $m
}

function Set-RowMuted($row, [bool]$Mute) {
    if ($null -eq $row) { return }
    $key = Get-MuteKey $row.Provider $row.Id
    $existing = @($sync.Mutes | Where-Object { (Get-MuteKey $_.provider $_.id) -eq $key })
    if ($Mute -and $existing.Count -eq 0) {
        $sync.Mutes = @($sync.Mutes) + [pscustomobject]@{ provider = $row.Provider; id = [int]$row.Id; note = ('Muted {0:yyyy-MM-dd}' -f (Get-Date)) }
    }
    elseif (-not $Mute) {
        $sync.Mutes = @($sync.Mutes | Where-Object { (Get-MuteKey $_.provider $_.id) -ne $key })
    }
    Save-Mutes
    # Flip every group that shares the provider/ID (same ID can appear under more than one log)
    foreach ($r in $sync.Rows) { if ((Get-MuteKey $r.Provider $r.Id) -eq $key) { $r.Muted = $Mute } }
    $c.dgTriage.Items.Refresh()
    Apply-TriageFilter
    Set-UiStatus $(if ($Mute) { "Muted $($row.Provider) $($row.Id). Saved to $MuteFile" } else { "Unmuted $($row.Provider) $($row.Id)." })
}

# ------------------------------------------------------------------------------------------------
#  Right-click menu on the triage grid (built in code so FindName isn't needed)
# ------------------------------------------------------------------------------------------------
$menu = New-Object System.Windows.Controls.ContextMenu
$mnuMute   = New-MenuItem 'Mute this event ID'   { Set-RowMuted $c.dgTriage.SelectedItem $true }
$mnuUnmute = New-MenuItem 'Unmute this event ID' { Set-RowMuted $c.dgTriage.SelectedItem $false }
[void]$menu.Items.Add((New-MenuItem 'Copy AI prompt (latest event in group)' { Copy-AiPrompt (Get-LatestEventInGroup $c.dgTriage.SelectedItem) $false }))
[void]$menu.Items.Add((New-MenuItem 'Copy AI prompt (redacted)'              { Copy-AiPrompt (Get-LatestEventInGroup $c.dgTriage.SelectedItem) $true }))
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add($mnuMute)
[void]$menu.Items.Add($mnuUnmute)
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add((New-MenuItem 'Copy provider and ID' {
    $row = $c.dgTriage.SelectedItem
    if ($row) { [System.Windows.Clipboard]::SetText(('{0} (Event ID {1})' -f $row.Provider, $row.Id)); Set-UiStatus 'Copied.' }
}))
[void]$menu.Items.Add((New-MenuItem 'Search the web' {
    $row = $c.dgTriage.SelectedItem
    if ($row) { Start-Process ('https://www.google.com/search?q=' + [uri]::EscapeDataString(('"{0}" "event id {1}"' -f $row.Provider, $row.Id))) }
}))
$c.dgTriage.ContextMenu = $menu

# Select the row under the cursor on right-click, and show only the relevant mute/unmute item
$c.dgTriage.Add_PreviewMouseRightButtonDown({
    param($s, $e)
    Select-RowUnderMouse $c.dgTriage $e
    $row = $c.dgTriage.SelectedItem
    $mnuMute.Visibility   = if ($row -and -not $row.Muted) { 'Visible' } else { 'Collapsed' }
    $mnuUnmute.Visibility = if ($row -and $row.Muted)      { 'Visible' } else { 'Collapsed' }
})

# Right-click menus on the Events and Context grids
$c.dgEvents.ContextMenu  = New-EventMenu
$c.dgContext.ContextMenu = New-EventMenu
$c.dgEvents.Add_PreviewMouseRightButtonDown({  param($s, $e) Select-RowUnderMouse $c.dgEvents $e })
$c.dgContext.Add_PreviewMouseRightButtonDown({ param($s, $e) Select-RowUnderMouse $c.dgContext $e })

# ------------------------------------------------------------------------------------------------
#  Event handlers
# ------------------------------------------------------------------------------------------------
$c.btnQuery.Add_Click({ Start-Query })

$c.txtComputer.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Start-Query } })
$c.txtProvider.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Start-Query } })
$c.txtEventId.Add_KeyDown({  param($s, $e) if ($e.Key -eq 'Return') { Start-Query } })

$c.cboPreset.Add_SelectionChanged({
    $i = $c.cboPreset.SelectedIndex
    if ($i -le 0) { return }
    $p = $Presets[$i - 1]
    Apply-Preset $p
    $c.cboPreset.SelectedIndex = 0
    Set-UiStatus "Preset applied: $($p.Name)"
    Start-Query
})

$c.btnCancel.Add_Click({
    if ($sync.Job) {
        Set-UiStatus 'Cancelling ...'
        [void]$sync.Job.PS.BeginStop($null, $null)
    }
})

$c.txtFilter.Add_TextChanged({ Apply-TriageFilter })
$c.chkHideMuted.Add_Checked({   Apply-TriageFilter })
$c.chkHideMuted.Add_Unchecked({ Apply-TriageFilter })

$c.dgTriage.Add_SelectionChanged({
    $row = $c.dgTriage.SelectedItem
    $c.txtDetail.Text = ''
    if ($null -eq $row) { $c.dgEvents.ItemsSource = $null; $c.txtEventsTitle.Text = 'Select a group on the left'; return }
    $c.dgEvents.ItemsSource = $sync.GroupMap[$row.Key]
    $c.txtEventsTitle.Text  = '{0}  -  ID {1}  -  {2} events' -f $row.Provider, $row.Id, $row.Count
    $c.tabRight.SelectedIndex = 0
    if ($c.dgEvents.Items.Count -gt 0) { $c.dgEvents.SelectedIndex = 0 }
})

$c.dgEvents.Add_SelectionChanged({  if ($c.dgEvents.SelectedItem)  { Show-EventDetail $c.dgEvents.SelectedItem } })
$c.dgContext.Add_SelectionChanged({ if ($c.dgContext.SelectedItem) { Show-EventDetail $c.dgContext.SelectedItem } })

$c.btnContext.Add_Click({ Start-Context })

$c.btnCopy.Add_Click({   Copy-Details })
$c.btnXml.Add_Click({    Start-XmlFetch })
$c.btnSearch.Add_Click({ Search-Web })

$c.btnExportTriage.Add_Click({
    Save-CsvDialog -Prefix 'EventTriage' -Data ($sync.Rows | Select-Object Level, Log, Provider, Id, Count, FirstSeen, LastSeen, Muted, Sample)
})

$c.btnExportEvents.Add_Click({
    $list = $c.dgEvents.ItemsSource
    if (-not $list) { $list = $sync.Events }
    Save-CsvDialog -Prefix 'Events' -Data ($list | Select-Object TimeCreated, Level, MachineName, LogName, ProviderName, Id, User, Message)
})

$c.btnExportContext.Add_Click({
    Save-CsvDialog -Prefix 'Context' -Data ($sync.Context | Select-Object Offset, TimeCreated, Level, MachineName, LogName, ProviderName, Id, User, Message)
})

# ------------------------------------------------------------------------------------------------
#  UI timer: pulls results from $sync onto the controls, and cleans up finished jobs
# ------------------------------------------------------------------------------------------------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.Add_Tick({
    if ($sync.StatusDirty) {
        $sync.StatusDirty = $false
        $c.txtStatus.Text = $sync.StatusText
    }

    if ($sync.ResultReady) {
        $sync.ResultReady = $false
        $c.dgTriage.ItemsSource = $sync.Rows
        $c.dgEvents.ItemsSource = $null
        $c.txtDetail.Text = ''
        Apply-TriageFilter
    }

    if ($sync.ContextReady) {
        $sync.ContextReady = $false
        $c.dgContext.ItemsSource = $sync.Context
        $c.tabContext.Header = 'Context'
        $anchor = $sync.Context | Where-Object { $_.IsAnchor } | Select-Object -First 1
        $c.txtContextTitle.Text = $(if ($anchor) { '{0} min either side of {1} {2} at {3:HH:mm:ss}' -f $sync.ContextMins, $anchor.ProviderName, $anchor.Id, $anchor.TimeCreated } else { '{0} min window' -f $sync.ContextMins })
        $c.tabRight.SelectedIndex = 1
        if ($anchor) {
            $c.dgContext.UpdateLayout()
            $c.dgContext.SelectedItem = $anchor
            $c.dgContext.ScrollIntoView($anchor)
        }
    }

    if ($sync.XmlReady) {
        $sync.XmlReady = $false
        $c.txtDetail.Text = $c.txtDetail.Text.TrimEnd() + "`r`n`r`n" + ('-' * 72) + "`r`nXML`r`n" + $sync.XmlText
    }

    if ($sync.Job -and $sync.Job.Handle.IsCompleted) {
        $job = $sync.Job
        $sync.Job = $null
        try { [void]$job.PS.EndInvoke($job.Handle) }
        catch {
            $m = $_.Exception.Message
            if ($m -match 'stopped') { $c.txtStatus.Text = 'Query cancelled.' } else { $c.txtStatus.Text = "Error: $m" }
        }
        $job.PS.Dispose()
        $job.RS.Dispose()
    }

    $busy = $null -ne $sync.Job
    $c.prgBusy.Visibility  = if ($busy) { 'Visible' } else { 'Collapsed' }
    $c.btnQuery.IsEnabled  = -not $busy
    $c.cboPreset.IsEnabled = -not $busy
    $c.btnCancel.IsEnabled = $busy
    $c.btnXml.IsEnabled    = -not $busy
    $c.btnContext.IsEnabled = -not $busy
})
$timer.Start()

$window.Add_Closing({
    $timer.Stop()
    if ($sync.Job) {
        try { $sync.Job.PS.Stop(); $sync.Job.PS.Dispose(); $sync.Job.RS.Dispose() } catch { }
    }
})

Load-Mutes
[void]$window.ShowDialog()
