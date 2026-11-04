<#
.SYNOPSIS
    Live, interactive TreeSize-style disk usage browser for Windows -- a WPF companion
    to Get-DiskUsageReport.ps1.

.DESCRIPTION
    Scans a folder tree once in the background (progress shown, cancellable), then lets
    you browse the result instantly: expand/collapse folders (largest first at every
    level), select a folder to see its files sorted by size, right-click to open a
    folder/file in Explorer or copy its path.

    Browse and identify only. There is no delete, rename or move anywhere in this
    script -- deliberately, so nothing here can act on your data.

    Local, interactive use only (it opens a window on the machine it runs on). Requires
    WPF (PresentationFramework), so it will not run on Server Core. Works on both
    Windows PowerShell 5.1 and PowerShell 7+, using a runspace pool for background work
    rather than PS7-only async, so it needs nothing installed beyond PowerShell itself.

.PARAMETER Path
    Folder to scan on launch. Defaults to the system drive. You can change it and
    rescan from the toolbar at any time.

.EXAMPLE
    .\Show-DiskUsageGui.ps1

.EXAMPLE
    .\Show-DiskUsageGui.ps1 -Path D:\Shares

.NOTES
    Known differences from TreeSize (shared with Get-DiskUsageReport.ps1):
      * Reports LOGICAL size (.Length), not size-on-disk.
      * Hard-linked files are counted once per link, so WinSxS reads larger than it
        really is.
      * Junctions and symlinks are skipped, not followed.
      * Paths over ~260 chars are skipped on PS 5.1 unless LongPathsEnabled is set.

    Run elevated to see other users' profiles and protected system folders.

    Shared data model (kept in sync with Get-DiskUsageReport.ps1):
      DiskNode : { Path/Name, ParentRef, OwnBytes, TotalBytes, Children[], Files[] }
      Walk     : iterative stack-based DFS over DirectoryInfo.EnumerateFiles()/
                 EnumerateDirectories(), skipping ReparsePoint directories, one
                 try/catch per directory for UnauthorizedAccessException /
                 PathTooLongException / DirectoryNotFoundException.
      Rollup   : OwnBytes -> TotalBytes by processing paths longest-first, adding each
                 child's total into its immediate parent.
      This script deliberately diverges from the report script: the pre-scan below
      keeps folder sizes only (no file retention at all -- cheaper than the report's
      walk), and fetches a folder's unfiltered file list lazily, one folder at a time,
      only when you select it in the tree. The report script instead keeps a
      -MinFileSizeMB-filtered file list per folder, gathered during the single walk, so
      a static HTML file doesn't balloon in size.
#>

[CmdletBinding()]
param(
    [string] $Path = $env:SystemDrive
)

if ($Path -match '^[A-Za-z]:$') { $Path = "$Path\" }   # e.g. "C:" -> "C:\", see Start-DiskScan

#--------------------------------------------------------------------------------
# Relaunch in STA if needed -- WPF requires it, and not every host defaults to it.
#--------------------------------------------------------------------------------

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $HostExe = (Get-Process -Id $PID).Path
    $RelaunchArgs = @('-STA', '-NoProfile', '-File', "`"$PSCommandPath`"", '-Path', "`"$Path`"")
    Start-Process -FilePath $HostExe -ArgumentList $RelaunchArgs | Out-Null
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms   # WPF has no built-in folder picker

#--------------------------------------------------------------------------------
# Data classes -- real CLR properties so WPF's reflection-based binding can see them.
# Built on the UI thread from the plain hashtables a background runspace returns.
#--------------------------------------------------------------------------------

class DiskNode {
    [string] $Name
    [string] $FullPath
    [long]   $Own
    [long]   $Total
    [string] $Label
    [bool]   $IsExpanded
    [System.Collections.ObjectModel.ObservableCollection[DiskNode]] $Children
    DiskNode() { $this.Children = [System.Collections.ObjectModel.ObservableCollection[DiskNode]]::new() }
}

class DiskFile {
    [string]   $Name
    [long]     $Bytes
    [string]   $SizeLabel
    [datetime] $Modified
    [string]   $ModifiedLabel
}

function Format-Size {
    param([double] $Bytes)
    if     ($Bytes -ge 1TB) { '{0:N2} TB' -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0} KB' -f ($Bytes / 1KB) }
    else                    { '{0:N0} B'  -f $Bytes }
}

function Get-AncestorOfType {
    param($Element, [type] $Type)
    $Current = $Element
    while ($Current -and -not ($Current -is $Type)) {
        if ($Current -is [System.Windows.Media.Visual] -or $Current -is [System.Windows.Media.Media3D.Visual3D]) {
            $Current = [System.Windows.Media.VisualTreeHelper]::GetParent($Current)
        }
        else {
            $Current = $null
        }
    }
    return $Current
}

function New-DiskNodeFromKey {
    param([string] $Key, $OwnMap, $TotalMap, $ChildrenOf, [string] $RootKey)

    $Node = [DiskNode]::new()
    $Node.FullPath = $Key
    $Node.Name     = if ($Key -eq $RootKey) { $Key } else { [IO.Path]::GetFileName($Key) }
    $Node.Own      = $OwnMap[$Key]
    $Node.Total    = $TotalMap[$Key]
    $Node.Label    = '{0}   ({1})' -f $Node.Name, (Format-Size $Node.Total)

    if ($ChildrenOf.ContainsKey($Key)) {
        $Kids = @($ChildrenOf[$Key] | Sort-Object { $TotalMap[$_] } -Descending)
        foreach ($K in $Kids) {
            $Node.Children.Add((New-DiskNodeFromKey -Key $K -OwnMap $OwnMap -TotalMap $TotalMap -ChildrenOf $ChildrenOf -RootKey $RootKey))
        }
    }
    return $Node
}

#--------------------------------------------------------------------------------
# Background work -- run as plain source text in a separate MTA runspace. No WPF
# objects cross the runspace boundary; only plain hashtables/arrays come back.
#--------------------------------------------------------------------------------

$ScanScriptBlock = {
    param($RootPath, $Sync)

    $Nodes  = @{}
    $Denied = 0; $TooLong = 0; $FileCount = 0; $DirCount = 0
    $RootKey = $RootPath.TrimEnd('\')
    if ($RootKey -match '^[A-Za-z]:$') { $RootKey = "$RootKey\" }  # e.g. "C:" -> "C:\": a bare
    # drive letter resolves against the process's current directory on that drive, not the
    # drive root, and GetDirectoryName() of a drive-root child (e.g. "C:\Users") returns
    # "C:\" (with the backslash), so the root key must match that shape or nothing scanned
    # under a drive root will roll up into the total.

    $Stack = New-Object System.Collections.Generic.Stack[string]
    $Stack.Push($RootKey)

    while ($Stack.Count -gt 0) {
        if ($Sync.CancelRequested) { break }
        $Current = $Stack.Pop()
        $DirCount++

        if (($DirCount % 500) -eq 0) {
            $Sync.DirCount  = $DirCount
            $Sync.FileCount = $FileCount
            $Sync.Status    = $Current
        }

        try {
            $Info  = New-Object System.IO.DirectoryInfo($Current)
            $Bytes = [long] 0

            foreach ($File in $Info.EnumerateFiles()) {
                $Bytes += $File.Length
                $FileCount++
            }
            $Nodes[$Current] = $Bytes

            foreach ($Sub in $Info.EnumerateDirectories()) {
                if ($Sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $Stack.Push($Sub.FullName)
            }
        }
        catch [System.UnauthorizedAccessException]   { $Denied++ }
        catch [System.IO.PathTooLongException]       { $TooLong++ }
        catch [System.IO.DirectoryNotFoundException] { }
        catch { }
    }

    $Total = @{}
    foreach ($Key in $Nodes.Keys) { $Total[$Key] = $Nodes[$Key] }
    foreach ($Key in ($Nodes.Keys | Sort-Object -Property Length -Descending)) {
        $Parent = [IO.Path]::GetDirectoryName($Key)
        if ($Parent -and $Total.ContainsKey($Parent)) { $Total[$Parent] += $Total[$Key] }
    }

    [PSCustomObject]@{
        Own       = $Nodes
        Total     = $Total
        RootKey   = $RootKey
        Denied    = $Denied
        TooLong   = $TooLong
        FileCount = $FileCount
        DirCount  = $DirCount
        Cancelled = [bool] $Sync.CancelRequested
    }
}

$FilesScriptBlock = {
    param($FolderPath)
    try {
        $Info = New-Object System.IO.DirectoryInfo($FolderPath)
        foreach ($File in ($Info.EnumerateFiles() | Sort-Object Length -Descending)) {
            [PSCustomObject]@{ Name = $File.Name; Bytes = $File.Length; Modified = $File.LastWriteTime }
        }
    }
    catch { }
}

$ScanScriptText  = $ScanScriptBlock.ToString()
$FilesScriptText = $FilesScriptBlock.ToString()

$Iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$Iss.ApartmentState = [System.Threading.ApartmentState]::MTA
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 2, $Iss, $Host)
$script:Pool.Open()

$script:ScanPS          = $null
$script:ScanAsync       = $null
$script:Sync            = $null
$script:SelectionToken  = 0
$script:PendingFileOps  = New-Object System.Collections.Generic.List[object]

#--------------------------------------------------------------------------------
# UI
#--------------------------------------------------------------------------------

[xml] $Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Disk Usage Browser" Height="740" Width="1150" WindowStartupLocation="CenterScreen">
  <DockPanel LastChildFill="True">
    <ToolBar DockPanel.Dock="Top">
      <TextBlock Text="Path:" VerticalAlignment="Center" Margin="4,0"/>
      <TextBox x:Name="PathBox" Width="420" VerticalAlignment="Center"/>
      <Button x:Name="BrowseButton" Content="Browse..." Margin="6,0,0,0"/>
      <Button x:Name="RescanButton" Content="Rescan" Margin="6,0,0,0"/>
      <Button x:Name="CancelButton" Content="Cancel" Margin="6,0,0,0" IsEnabled="False"/>
    </ToolBar>
    <Grid x:Name="ProgressGrid" DockPanel.Dock="Top" Margin="8,4" Visibility="Collapsed">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <ProgressBar x:Name="ScanProgress" Grid.Column="0" Height="14" IsIndeterminate="True"/>
      <TextBlock x:Name="ProgressText" Grid.Column="1" Margin="8,0,0,0" VerticalAlignment="Center"/>
    </Grid>
    <StatusBar DockPanel.Dock="Bottom">
      <StatusBarItem><TextBlock x:Name="StatusText" Text="Ready"/></StatusBarItem>
    </StatusBar>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="380" MinWidth="220"/>
        <ColumnDefinition Width="4"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <TreeView x:Name="Tree" Grid.Column="0"
                VirtualizingPanel.IsVirtualizing="True"
                VirtualizingPanel.VirtualizationMode="Recycling">
        <TreeView.ItemTemplate>
          <HierarchicalDataTemplate ItemsSource="{Binding Children}">
            <TextBlock Text="{Binding Label}"/>
          </HierarchicalDataTemplate>
        </TreeView.ItemTemplate>
      </TreeView>
      <GridSplitter Grid.Column="1" Width="4" HorizontalAlignment="Stretch" Background="#DDDDDD"/>
      <DataGrid x:Name="FilesGrid" Grid.Column="2" AutoGenerateColumns="False" IsReadOnly="True"
                EnableRowVirtualization="True" CanUserSortColumns="True" GridLinesVisibility="Horizontal">
        <DataGrid.Columns>
          <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="*"/>
          <DataGridTextColumn Header="Size" Binding="{Binding SizeLabel}" Width="110" SortMemberPath="Bytes"/>
          <DataGridTextColumn Header="Modified" Binding="{Binding ModifiedLabel}" Width="110" SortMemberPath="Modified"/>
        </DataGrid.Columns>
      </DataGrid>
    </Grid>
  </DockPanel>
</Window>
'@

$Reader = New-Object System.Xml.XmlNodeReader $Xaml
$Window = [Windows.Markup.XamlReader]::Load($Reader)

$PathBox      = $Window.FindName('PathBox')
$BrowseButton = $Window.FindName('BrowseButton')
$RescanButton = $Window.FindName('RescanButton')
$CancelButton = $Window.FindName('CancelButton')
$ProgressGrid = $Window.FindName('ProgressGrid')
$ScanProgress = $Window.FindName('ScanProgress')
$ProgressText = $Window.FindName('ProgressText')
$StatusText   = $Window.FindName('StatusText')
$Tree         = $Window.FindName('Tree')
$FilesGrid    = $Window.FindName('FilesGrid')

# Bind IsExpanded (two-way) and attach the folder context menu, in code -- avoids
# fragile XAML named-resource lookups for elements that live inside a ContextMenu.
$TreeItemStyle = New-Object System.Windows.Style ([System.Windows.Controls.TreeViewItem])
$ExpandBinding = New-Object System.Windows.Data.Binding 'IsExpanded'
$ExpandBinding.Mode = [System.Windows.Data.BindingMode]::TwoWay
$TreeItemStyle.Setters.Add((New-Object System.Windows.Setter -ArgumentList ([System.Windows.Controls.TreeViewItem]::IsExpandedProperty), $ExpandBinding))

$TreeMenu     = New-Object System.Windows.Controls.ContextMenu
$TreeMenuOpen = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Open in Explorer' }
$TreeMenuCopy = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Copy path' }
[void] $TreeMenu.Items.Add($TreeMenuOpen)
[void] $TreeMenu.Items.Add($TreeMenuCopy)
$TreeItemStyle.Setters.Add((New-Object System.Windows.Setter -ArgumentList ([System.Windows.Controls.TreeViewItem]::ContextMenuProperty), $TreeMenu))
$Tree.ItemContainerStyle = $TreeItemStyle

$FileMenu     = New-Object System.Windows.Controls.ContextMenu
$FileMenuOpen = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Open containing folder' }
$FileMenuCopy = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Copy path' }
[void] $FileMenu.Items.Add($FileMenuOpen)
[void] $FileMenu.Items.Add($FileMenuCopy)
$RowStyle = New-Object System.Windows.Style ([System.Windows.Controls.DataGridRow])
$RowStyle.Setters.Add((New-Object System.Windows.Setter -ArgumentList ([System.Windows.Controls.DataGridRow]::ContextMenuProperty), $FileMenu))
$FilesGrid.RowStyle = $RowStyle

#--------------------------------------------------------------------------------
# Actions -- browse/identify only. Nothing here deletes, renames or moves anything.
#--------------------------------------------------------------------------------

$TreeMenuOpen.Add_Click({
    $Node = $Tree.SelectedItem
    if ($Node) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Node.FullPath) }
})
$TreeMenuCopy.Add_Click({
    $Node = $Tree.SelectedItem
    if ($Node) { [System.Windows.Clipboard]::SetText($Node.FullPath) }
})
$FileMenuOpen.Add_Click({
    $Row = $FilesGrid.SelectedItem
    $Node = $Tree.SelectedItem
    if ($Row -and $Node) {
        $Full = Join-Path $Node.FullPath $Row.Name
        Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $Full)
    }
})
$FileMenuCopy.Add_Click({
    $Row = $FilesGrid.SelectedItem
    $Node = $Tree.SelectedItem
    if ($Row -and $Node) { [System.Windows.Clipboard]::SetText((Join-Path $Node.FullPath $Row.Name)) }
})

$Tree.Add_PreviewMouseRightButtonDown({
    param($sender, $e)
    $Item = Get-AncestorOfType -Element $e.OriginalSource -Type ([System.Windows.Controls.TreeViewItem])
    if ($Item) { $Item.IsSelected = $true }
})
$FilesGrid.Add_PreviewMouseRightButtonDown({
    param($sender, $e)
    $Row = Get-AncestorOfType -Element $e.OriginalSource -Type ([System.Windows.Controls.DataGridRow])
    if ($Row) { $Row.IsSelected = $true }
})

#--------------------------------------------------------------------------------
# Scan lifecycle
#--------------------------------------------------------------------------------

function Start-Scan {
    param([string] $TargetPath)

    if ($TargetPath -match '^[A-Za-z]:$') { $TargetPath = "$TargetPath\" }

    if (-not [IO.Directory]::Exists($TargetPath)) {
        $StatusText.Text = "Path not found: $TargetPath"
        return
    }
    $PathBox.Text = $TargetPath

    $script:Sync = [hashtable]::Synchronized(@{ DirCount = 0; FileCount = 0; Status = ''; CancelRequested = $false })
    $script:ScanPS = [powershell]::Create()
    $script:ScanPS.RunspacePool = $script:Pool
    [void] $script:ScanPS.AddScript($ScanScriptText).AddArgument($TargetPath).AddArgument($script:Sync)
    $script:ScanAsync = $script:ScanPS.BeginInvoke()

    $Tree.Items.Clear()
    $FilesGrid.ItemsSource = $null
    $ProgressGrid.Visibility  = 'Visible'
    $ScanProgress.IsIndeterminate = $false
    $ProgressText.Text = 'Scanning...'
    $BrowseButton.IsEnabled = $false
    $RescanButton.IsEnabled = $false
    $CancelButton.IsEnabled = $true
    $StatusText.Text = "Scanning $TargetPath ..."
}

function Complete-Scan {
    param($Result)

    $ChildrenOf = @{}
    foreach ($Key in $Result.Own.Keys) {
        $Parent = [IO.Path]::GetDirectoryName($Key)
        if ($Parent) {
            if (-not $ChildrenOf.ContainsKey($Parent)) { $ChildrenOf[$Parent] = New-Object System.Collections.Generic.List[string] }
            $ChildrenOf[$Parent].Add($Key)
        }
    }

    $RootNode = New-DiskNodeFromKey -Key $Result.RootKey -OwnMap $Result.Own -TotalMap $Result.Total -ChildrenOf $ChildrenOf -RootKey $Result.RootKey
    $RootNode.IsExpanded = $true

    $Tree.Items.Clear()
    [void] $Tree.Items.Add($RootNode)

    $ProgressGrid.Visibility = 'Collapsed'
    $BrowseButton.IsEnabled = $true
    $RescanButton.IsEnabled = $true
    $CancelButton.IsEnabled = $false

    $Msg = '{0:N0} folders, {1:N0} files' -f $Result.DirCount, $Result.FileCount
    if ($Result.Denied)    { $Msg += "  |  $($Result.Denied) denied" }
    if ($Result.TooLong)   { $Msg += "  |  $($Result.TooLong) too long" }
    if ($Result.Cancelled) { $Msg += '  |  cancelled -- partial results' }
    $StatusText.Text = $Msg
}

$BrowseButton.Add_Click({
    $Dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ([IO.Directory]::Exists($PathBox.Text)) { $Dlg.SelectedPath = $PathBox.Text }
    if ($Dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $PathBox.Text = $Dlg.SelectedPath
        Start-Scan -TargetPath $Dlg.SelectedPath
    }
})
$RescanButton.Add_Click({ Start-Scan -TargetPath $PathBox.Text })
$CancelButton.Add_Click({
    if ($script:Sync) { $script:Sync.CancelRequested = $true }
    $CancelButton.IsEnabled = $false
    $ProgressText.Text = 'Cancelling...'
})

$Tree.Add_SelectedItemChanged({
    $Node = $Tree.SelectedItem
    if (-not $Node) { return }
    $script:SelectionToken++
    $MyToken = $script:SelectionToken
    $FilesGrid.ItemsSource = $null

    $Ps = [powershell]::Create()
    $Ps.RunspacePool = $script:Pool
    [void] $Ps.AddScript($FilesScriptText).AddArgument($Node.FullPath)
    $Async = $Ps.BeginInvoke()
    $script:PendingFileOps.Add([PSCustomObject]@{ PS = $Ps; Async = $Async; Token = $MyToken })
})

#--------------------------------------------------------------------------------
# One timer polls both the scan and every in-flight file listing -- no cross-runspace
# Dispatcher calls, just IAsyncResult.IsCompleted checked from the UI thread.
#--------------------------------------------------------------------------------

$Timer = New-Object System.Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(175)
$Timer.Add_Tick({
    if ($script:ScanAsync) {
        if ($script:ScanAsync.IsCompleted) {
            $Result = $script:ScanPS.EndInvoke($script:ScanAsync)
            $script:ScanPS.Dispose()
            $script:ScanAsync = $null
            Complete-Scan -Result $Result[0]
        }
        else {
            $ProgressText.Text = '{0:N0} folders, {1:N0} files - {2}' -f $script:Sync.DirCount, $script:Sync.FileCount, $script:Sync.Status
        }
    }

    for ($i = $script:PendingFileOps.Count - 1; $i -ge 0; $i--) {
        $Op = $script:PendingFileOps[$i]
        if (-not $Op.Async.IsCompleted) { continue }

        $Files = $Op.PS.EndInvoke($Op.Async)
        $Op.PS.Dispose()
        $script:PendingFileOps.RemoveAt($i)

        if ($Op.Token -eq $script:SelectionToken) {
            $FilesGrid.ItemsSource = @($Files | ForEach-Object {
                $Df = [DiskFile]::new()
                $Df.Name          = $_.Name
                $Df.Bytes         = $_.Bytes
                $Df.SizeLabel     = Format-Size $_.Bytes
                $Df.Modified      = $_.Modified
                $Df.ModifiedLabel = $_.Modified.ToString('yyyy-MM-dd')
                $Df
            })
        }
    }
})
$Timer.Start()

$Window.Add_Closed({
    $Timer.Stop()
    if ($script:ScanPS) { try { $script:ScanPS.Dispose() } catch { } }
    foreach ($Op in $script:PendingFileOps) { try { $Op.PS.Dispose() } catch { } }
    if ($script:Pool) { $script:Pool.Close(); $script:Pool.Dispose() }
})

$PathBox.Text = $Path
Start-Scan -TargetPath $Path
[void] $Window.ShowDialog()
