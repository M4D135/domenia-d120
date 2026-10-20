# Directory data is independent of generated WPF containers. Types are loaded at first tree use.
$script:DomeniaTreeSelectedNode = $null
$script:DomeniaTreeItemReveal = $null
$script:DomeniaTreeItemRevealTimer = $null
function Add-DomeniaDirectoryTreeTypes {
    if ($null -ne ('Domenia.Tree.DomeniaTreeItem' -as [type])) { return }
    Add-Type -AssemblyName WindowsBase,PresentationCore,PresentationFramework
    $references = @([object].Assembly.Location,[ComponentModel.INotifyPropertyChanged].Assembly.Location,[Collections.ObjectModel.ObservableCollection[object]].Assembly.Location,[Windows.DependencyObject].Assembly.Location,[Windows.Media.Visual].Assembly.Location,[Windows.Controls.TreeView].Assembly.Location)
    Add-Type -Path (Join-Path $PSScriptRoot 'Domenia-DirectoryTree.Types.cs') -ReferencedAssemblies @($references | Select-Object -Unique) -ErrorAction Stop
}
function Get-DomeniaDirectoryTreeHeaderTemplate {
    $xaml = @'
<HierarchicalDataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" ItemsSource="{Binding ChildrenView}">
  <StackPanel x:Name="HeaderRoot" Orientation="Horizontal" Background="Transparent">
    <TextBlock Text="{Binding Header}" VerticalAlignment="Center"/>
    <Button x:Name="OuStar" Content="☆" Visibility="Hidden" Focusable="False" Margin="6,0,0,0" MinWidth="0" MinHeight="0" Cursor="Hand" FontFamily="Segoe UI Symbol" Foreground="{DynamicResource AccentText}" ToolTip="Épingler cette OU dans les favoris" AutomationProperties.Name="Épingler cette OU">
      <Button.Template><ControlTemplate TargetType="Button"><Border Background="Transparent" Padding="2,0"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
    </Button>
  </StackPanel>
  <HierarchicalDataTemplate.Triggers>
    <Trigger SourceName="HeaderRoot" Property="UIElement.IsMouseOver" Value="True"><Setter TargetName="OuStar" Property="UIElement.Visibility" Value="Visible"/></Trigger>
    <DataTrigger Binding="{Binding FavoriteStatus}" Value="Favori"><Setter TargetName="OuStar" Property="Visibility" Value="Visible"/><Setter TargetName="OuStar" Property="Content" Value="★"/><Setter TargetName="OuStar" Property="ToolTip" Value="Retirer cette OU des favoris"/></DataTrigger>
    <DataTrigger Binding="{Binding Tag.DN, TargetNullValue='', FallbackValue=''}" Value=""><Setter TargetName="OuStar" Property="Visibility" Value="Collapsed"/></DataTrigger>
  </HierarchicalDataTemplate.Triggers>
</HierarchicalDataTemplate>
'@
    return [Windows.Markup.XamlReader]::Parse($xaml)
}
function New-DomeniaDirectoryTreeTemplate {
    Add-DomeniaDirectoryTreeTypes
    return Get-DomeniaDirectoryTreeHeaderTemplate
}
function New-DomeniaDirectoryTreeContainerStyle {
    param($Tree)
    Add-DomeniaDirectoryTreeTypes
    $style = [Windows.Style]::new([Windows.Controls.TreeViewItem])
    if ($null -ne $Tree) {
        $base = $Tree.TryFindResource([Windows.Controls.TreeViewItem])
        if ($base -is [Windows.Style]) { $style.BasedOn = $base }
    }
    foreach ($name in @('IsExpanded','IsSelected','IsEnabled','ToolTip','Tag')) {
        $binding = [Windows.Data.Binding]::new($name)
        if ($name -in @('IsExpanded','IsSelected')) { $binding.Mode = [Windows.Data.BindingMode]::TwoWay }
        $property = [Windows.Controls.TreeViewItem].GetField(($name+'Property'),[Reflection.BindingFlags]'Public,Static,FlattenHierarchy').GetValue($null)
        $style.Setters.Add([Windows.Setter]::new($property,$binding))
    }
    $style.Setters.Add([Windows.Setter]::new([Windows.Automation.AutomationProperties]::ItemStatusProperty,[Windows.Data.Binding]::new('FavoriteStatus')))
    $factory = [Windows.FrameworkElementFactory]::new([Domenia.Tree.DomeniaVirtualizingStackPanel])
    $panel = [Windows.Controls.ItemsPanelTemplate]::new($factory)
    $style.Setters.Add([Windows.Setter]::new([Windows.Controls.ItemsControl]::ItemsPanelProperty,$panel))
    $style.Setters.Add([Windows.Setter]::new([Windows.Controls.VirtualizingPanel]::IsVirtualizingProperty,$true))
    $style.Setters.Add([Windows.Setter]::new([Windows.Controls.VirtualizingPanel]::VirtualizationModeProperty,[Windows.Controls.VirtualizationMode]::Recycling))
    return $style
}
function Initialize-DomeniaDirectoryTree {
    param($Tree)
    if ($null -eq $Tree) { return $false }
    if ($null -ne $Tree.PSObject.Properties['DomeniaDirectoryTreeWired'] -and [bool]$Tree.DomeniaDirectoryTreeWired) { return $true }
    Add-DomeniaDirectoryTreeTypes
    $style = New-DomeniaDirectoryTreeContainerStyle -Tree $Tree
    $template = New-DomeniaDirectoryTreeTemplate
    $template.ItemContainerStyle = $style
    $Tree.ItemTemplate = $template
    $Tree.ItemContainerStyle = $style
    $factory = [Windows.FrameworkElementFactory]::new([Domenia.Tree.DomeniaVirtualizingStackPanel])
    $Tree.ItemsPanel = [Windows.Controls.ItemsPanelTemplate]::new($factory)
    $Tree.SetValue([Windows.Controls.VirtualizingPanel]::IsVirtualizingProperty,$true)
    $Tree.SetValue([Windows.Controls.VirtualizingPanel]::VirtualizationModeProperty,[Windows.Controls.VirtualizationMode]::Recycling)
    $Tree.SetValue([Windows.Controls.ScrollViewer]::CanContentScrollProperty,$true)
    $Tree.AddHandler([Windows.Controls.TreeViewItem]::ExpandedEvent,[Windows.RoutedEventHandler]{
        param($sender,$eventArgs)
        $container = $eventArgs.OriginalSource
        if ($container -isnot [Windows.Controls.TreeViewItem]) { return }
        $node = $container.DataContext
        if ($node -isnot [Domenia.Tree.DomeniaTreeItem]) { return }
        if (-not $node.ExpansionReadHandled) {
            $node.ExpansionReadHandled = $true
            if ([string]$node.Tag.DN) { Load-TreeChildren -Node $node }
        }
    })
    $Tree.AddHandler([Windows.Controls.TreeViewItem]::SelectedEvent,[Windows.RoutedEventHandler]{
        param($sender,$eventArgs)
        $container = $eventArgs.OriginalSource
        if ($container -isnot [Windows.Controls.TreeViewItem]) { return }
        $node = $container.DataContext
        if ($node -isnot [Domenia.Tree.DomeniaTreeItem] -or -not [string]$node.Tag.DN) { return }
        $previous = $script:DomeniaTreeSelectedNode
        if ($null -ne $previous -and -not [object]::ReferenceEquals($previous,$node)) { $previous.IsSelected = $false }
        $script:DomeniaTreeSelectedNode = $node
        $old = [bool]$script:SuppressBranchAutoLoad
        if ($node.ProgrammaticSelection) { $script:SuppressBranchAutoLoad = $true }
        else { Stop-DomeniaTreeItemReveal }
        try { Set-SelectedBranch -Node $node } finally { $script:SuppressBranchAutoLoad = $old }
        $eventArgs.Handled = $true
    })
    $Tree.Add_PreviewMouseDown({ Stop-DomeniaTreeItemReveal })
    $Tree.Add_PreviewKeyDown({ Stop-DomeniaTreeItemReveal })
    $Tree | Add-Member NoteProperty DomeniaDirectoryTreeWired $true -Force
    return $true
}
function Clear-DomeniaDirectoryTreeWiring {
    Stop-DomeniaTreeItemReveal
    if ($null -ne $script:DomeniaTreeSelectedNode) { $script:DomeniaTreeSelectedNode.IsSelected = $false }
    $script:DomeniaTreeSelectedNode = $null
    $script:DomeniaDirectoryTreeHeaderTemplate = $null
}
function Set-DomeniaTreeItemExpanded {
    param($Node,[bool]$Expanded=$true,[switch]$AllowLoad)
    if ($null -eq $Node) { return }
    if ($Expanded) {
        $Node.ExpansionReadHandled = $true
        $Node.IsExpanded = $true
        if ($AllowLoad -and [string]$Node.Tag.DN -and -not [bool]$Node.Tag.Loaded -and -not [bool]$Node.Tag.Loading -and -not [string]$Node.Tag.RenderId) { Load-TreeChildren -Node $Node }
    } else { $Node.IsExpanded = $false }
}
function New-DomeniaTreeStatusItem {
    param([string]$Message='Chargement...')
    $node = [Domenia.Tree.DomeniaTreeItem]::new()
    $node.Header = $Message
    $node.Tag = [pscustomobject]@{Name=$Message;DN='';Kind='Placeholder';Loaded=$true;Loading=$false;RenderId=''}
    return $node
}
function Get-DomeniaTreeChildView {
    param($Node)
    return ,$Node.ChildrenView
}
function Set-DomeniaTreeProgrammaticSelection {
    param($Node)
    $old = $script:DomeniaTreeSelectedNode
    if ($null -ne $old -and -not [object]::ReferenceEquals($old,$Node)) { $old.IsSelected = $false }
    $script:DomeniaTreeSelectedNode = $Node
    if ($null -eq $Node) { return }
    $Node.ProgrammaticSelection = $true
    $Node.IsSelected = $true
}
function Get-DomeniaTreeContainerForItem {
    param($Tree,$Node)
    if ($null -eq $Tree -or $null -eq $Node) { return $null }
    if ($null -eq $Node.Parent) { return [Domenia.Tree.DomeniaTreeSupport]::ContainerFromItem($Tree,$Node) }
    $parent = Get-DomeniaTreeContainerForItem -Tree $Tree -Node $Node.Parent
    if ($null -eq $parent) { return $null }
    return [Domenia.Tree.DomeniaTreeSupport]::ContainerFromItem($parent,$Node)
}
function Find-DomeniaTreeVirtualizingPanel {
    param($Container)
    return [Domenia.Tree.DomeniaTreeSupport]::FindPanel($Container)
}
function Start-DomeniaTreeItemReveal {
    param($Node,[string]$Purpose='selection',[switch]$AllowLoad)
    Stop-DomeniaTreeItemReveal
    $tree = Get-DomeniaControl 'TvDirectory'
    if ($null -eq $Node -or $null -eq $tree -or $tree.Items.Count -eq 0) { return $false }
    $path = [Collections.Generic.List[object]]::new()
    $walk = $Node
    while ($null -ne $walk -and $path.Count -lt 128) { $path.Insert(0,$walk); $walk = $walk.Parent }
    if ($null -ne $walk -or -not [object]::ReferenceEquals($path[0],$tree.Items[0])) { return $false }
    Set-DomeniaTreeProgrammaticSelection -Node $Node
    $script:DomeniaTreeItemReveal = [pscustomobject]@{
        Node=$Node;Path=$path.ToArray();Purpose=$Purpose;Root=$tree.Items[0];Epoch=[long]$script:SessionEpoch
        Context=([string]$script:Conn.BaseDn+'|'+[string]$script:Conn.BindUser)
        Generation=[int]$script:GlobalSearchGeneration;AllowLoad=[bool]$AllowLoad;Deadline=[datetime]::UtcNow.AddSeconds(60)
    }
    if ($null -eq $script:DomeniaTreeItemRevealTimer) { $script:DomeniaTreeItemRevealTimer = New-DomeniaTimer -Owner 'Timer:TreeItemReveal' -IntervalMs 35 -Tick { Invoke-DomeniaTreeItemRevealTick } }
    $script:DomeniaTreeItemRevealTimer.Start()
    Invoke-DomeniaTreeItemRevealTick
    return $true
}
function Stop-DomeniaTreeItemReveal {
    param([string]$Message='')
    $script:DomeniaTreeItemReveal = $null
    if ($null -ne $script:DomeniaTreeItemRevealTimer) { $script:DomeniaTreeItemRevealTimer.Stop() }
    if ($Message) { [void](Set-DomeniaControlText 'LblTreeStatus' $Message) }
}
function Invoke-DomeniaTreeItemRevealTick {
    $state = $script:DomeniaTreeItemReveal
    if ($null -eq $state) { return }
    $tree = Get-DomeniaControl 'TvDirectory'
    if ($script:AsyncEngineClosing -or $null -eq $tree -or $tree.Items.Count -eq 0 -or [long]$state.Epoch -ne [long]$script:SessionEpoch -or [int]$state.Generation -ne [int]$script:GlobalSearchGeneration -or [string]$state.Context -cne ([string]$script:Conn.BaseDn+'|'+[string]$script:Conn.BindUser) -or -not [object]::ReferenceEquals($tree.Items[0],$state.Root) -or [datetime]::UtcNow -gt $state.Deadline) { Stop-DomeniaTreeItemReveal; return }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $owner = $tree
    for ($level=0; $level -lt $state.Path.Count; $level++) {
        if ($clock.ElapsedMilliseconds -ge 8) { return }
        $node = $state.Path[$level]
        $container = [Domenia.Tree.DomeniaTreeSupport]::ContainerFromItem($owner,$node)
        if ($null -eq $container) {
            [void]$owner.ApplyTemplate()
            $panel = [Domenia.Tree.DomeniaTreeSupport]::FindPanel($owner)
            $index = $owner.Items.IndexOf($node)
            if ($index -lt 0) { Stop-DomeniaTreeItemReveal 'La branche cible est masquée par le filtre de lʼarbre.'; return }
            if ($null -ne $panel) { $panel.Reveal($index) }
            return
        }
        if ($level -eq $state.Path.Count-1) {
            Set-DomeniaTreeProgrammaticSelection -Node $node
            [void]$container.BringIntoView()
            Stop-DomeniaTreeItemReveal
            return
        }
        Set-DomeniaTreeItemExpanded -Node $node -AllowLoad:([bool]$state.AllowLoad)
        $owner = $container
    }
}
