# Domenia - arborescence virtualisee (boulot D120, point 8).
# Donnees (Domenia.Tree.DomeniaTreeItem) separees des conteneurs TreeViewItem generes puis recycles par WPF.
# Un seul branchement : Initialize-DomeniaDirectoryTree posa le modele, les styles et les gestionnaires sur Update.
# Module sans Set-StrictMode : il est dot-source dans la portee du coeur.
# Requis : Domenia-Core.ps1 deja charge (Get-DomeniaControl, Set-DomeniaControlText, Load-TreeChildren,
# Set-SelectedBranch, Write-DomeniaSwallowed), $script:Conn, $script:SessionEpoch.

$script:DomeniaDirectoryTreeWired = $false
$script:DomeniaTreeProgrammaticSelectionToken = ''

function Add-DomeniaDirectoryTreeTypes {
    # C# 5 du Types file. Idempotent : un seul Add-Type par session.
    if ($null -ne ('Domenia.Tree.DomeniaTreeItem' -as [type])) { return }
    try {
        $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Domenia-DirectoryTree.Types.cs'
        Add-Type -Path $source -ReferencedAssemblies @('WindowsBase','PresentationCore','PresentationFramework','System','System.Core') -ErrorAction Stop
    }
    catch {
        Write-DomeniaSwallowed 'DirectoryTree' 'Add-DomeniaDirectoryTreeTypes' $_
        throw
    }
}

function Get-DomeniaDirectoryTreeHeaderTemplate {
    # Entete du DTO : texte lie a Header, etoile pilotable par FavoriteStatus (reste juste apres recyclage).
    if ($null -ne $script:DomeniaDirectoryTreeHeaderTemplate) { return $script:DomeniaDirectoryTreeHeaderTemplate }
    $xaml = @'
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <StackPanel x:Name="HeaderRoot" Orientation="Horizontal" Background="Transparent">
    <TextBlock Text="{Binding Header}" VerticalAlignment="Center"/>
    <Button x:Name="OuStar" Content="☆" Visibility="Hidden" Focusable="False" Margin="6,0,0,0" MinWidth="0" MinHeight="0" Cursor="Hand" FontFamily="Segoe UI Symbol" Foreground="{DynamicResource AccentText}" ToolTip="Épingler cette OU dans les favoris" AutomationProperties.Name="Épingler cette OU">
      <Button.Template><ControlTemplate TargetType="Button"><Border Background="Transparent" Padding="2,0"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border></ControlTemplate></Button.Template>
    </Button>
  </StackPanel>
  <DataTemplate.Triggers>
    <Trigger SourceName="HeaderRoot" Property="UIElement.IsMouseOver" Value="True"><Setter TargetName="OuStar" Property="UIElement.Visibility" Value="Visible"/></Trigger>
    <DataTrigger Binding="{Binding FavoriteStatus}" Value="Favori">
      <Setter TargetName="OuStar" Property="Visibility" Value="Visible"/>
      <Setter TargetName="OuStar" Property="Content" Value="★"/>
      <Setter TargetName="OuStar" Property="ToolTip" Value="Retirer cette OU des favoris"/>
    </DataTrigger>
  </DataTemplate.Triggers>
</DataTemplate>
'@
    $script:DomeniaDirectoryTreeHeaderTemplate = [Windows.Markup.XamlReader]::Parse($xaml)
    return $script:DomeniaDirectoryTreeHeaderTemplate
}

function New-DomeniaDirectoryTreeTemplate {
    # Modele hierarchique programmatique : le panel fils est notre DomeniaVirtualizingStackPanel
    # (la reference a une classe custom ne passe pas par XamlReader, le FrameworkElementFactory si).
    Add-DomeniaDirectoryTreeTypes
    $panelFactory = New-Object Windows.FrameworkElementFactory([Domenia.Tree.DomeniaVirtualizingStackPanel])
    $panelTemplate = New-Object Windows.ItemsPanelTemplate
    $panelTemplate.VisualTree = $panelFactory

    $template = New-Object Windows.HierarchicalDataTemplate
    $itemsBinding = New-Object Windows.Data.Binding('ChildrenView')
    $itemsBinding.Mode = [Windows.Data.BindingMode]::OneWay
    $template.ItemsSource = $itemsBinding
    $template.Panel = $panelTemplate
    $template.HeaderTemplate = Get-DomeniaDirectoryTreeHeaderTemplate
    $template.DataType = [Domenia.Tree.DomeniaTreeItem]
    return $template
}

function New-DomeniaDirectoryTreeContainerStyle {
    # Style des conteneurs generes par WPF : tout l'etat visuel vient du DTO par binding,
    # Marked recursif pour que chaque niveau recree le meme modele. TwoWay sur expansion/selection.
    Add-DomeniaDirectoryTreeTypes
    $style = New-Object Windows.Style
    $style.TargetType = [Windows.Controls.TreeViewItem]
    $expBinding = New-Object Windows.Data.Binding('IsExpanded'); $expBinding.Mode = [Windows.Data.BindingMode]::TwoWay
    $selBinding = New-Object Windows.Data.Binding('IsSelected'); $selBinding.Mode = [Windows.Data.BindingMode]::TwoWay
    $tagBinding = New-Object Windows.Data.Binding('Tag');      $tagBinding.Mode = [Windows.Data.BindingMode]::OneWay
    $visBinding = New-Object Windows.Data.Binding('Visibility'); $visBinding.Mode = [Windows.Data.BindingMode]::TwoWay
    $tipBinding = New-Object Windows.Data.Binding('ToolTip');  $tipBinding.Mode = [Windows.Data.BindingMode]::OneWay
    $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TreeViewItem]::IsExpandedProperty, $expBinding)))
    $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TreeViewItem]::IsSelectedProperty, $selBinding)))
    $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TreeViewItem]::IsEnabledProperty, (New-Object Windows.Data.Binding('IsEnabled'))))
    $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TreeViewItem]::TagProperty, $tagBinding)))
    $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TreeViewItem]::VisibilityProperty, $visBinding)))
    $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TreeViewItem]::ToolTipProperty, $tipBinding)))
    # Le meme style pour les niveaux fils de chaque conteneur genere (reference directe, pas de StaticResource circulaire).
    $style.Setters.Add((New-Object Windows.Setter([Windows.Controls.TreeViewItem]::ItemContainerStyleProperty, $style)))
    return $style
}

function Initialize-DomeniaDirectoryTree {
    # A appeler une fois, avant le premier remplissage (Load-TreeRoot).
    param([Windows.Controls.TreeView]$Tree)
    if ($null -eq $Tree) { return $false }
    if ($script:DomeniaDirectoryTreeWired) { return $true }
    Add-DomeniaDirectoryTreeTypes
    try {
        $tree.ItemsSource = $null
        $tree.ItemTemplate = New-DomeniaDirectoryTreeTemplate
        $tree.ItemContainerStyle = New-DomeniaDirectoryTreeContainerStyle
        # The root level panel is ours too; children panels come from the hierarchical template.
        $rootPanelFactory = New-Object Windows.FrameworkElementFactory([Domenia.Tree.DomeniaVirtualizingStackPanel])
        $rootPanelTemplate = New-Object Windows.ItemsPanelTemplate
        $rootPanelTemplate.VisualTree = $rootPanelFactory
        $tree.ItemsPanel = $rootPanelTemplate
        [void]$tree.SetValue([Windows.Controls.VirtualizingPanel]::IsVirtualizingProperty, $true)
        [void]$tree.SetValue([Windows.Controls.VirtualizingPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)
        [void]$tree.SetValue([Windows.Controls.ScrollViewer]::CanContentScrollProperty, $true)

        $tree.Add_Expanded({
            param($sender,$eventArgs)
            # Expansion opérateur seulement : l'expansion programmatique (restauration/favori) ne relit rien.
            if ($eventArgs.OriginalSource -isnot [Windows.Controls.TreeViewItem]) { return }
            if ([bool]$script:DomeniaTreeProgrammaticExpand) { return }
            $node = $eventArgs.OriginalSource.DataContext
            if ($node -is [Domenia.Tree.DomeniaTreeItem]) { Load-TreeChildren -Node $node }
        })
        $tree.Add_Selected({
            param($sender,$eventArgs)
            if ($eventArgs.OriginalSource -isnot [Windows.Controls.TreeViewItem]) { return }
            $node = $eventArgs.OriginalSource.DataContext
            if ($node -isnot [Domenia.Tree.DomeniaTreeItem]) { return }
            if ([string]$node.Dn -ceq [string]$script:DomeniaTreeProgrammaticSelectionToken) {
                # Realisation d'une selection programmee (favori/restauration/nav) : un seul geste disponible,
                # la lecture de contenu ou le filtre a deja ete demarre par la cible (or is never started here).
                $script:DomeniaTreeProgrammaticSelectionToken = ''
                Set-SelectedBranch -Node $node
                return
            }
            $script:DomeniaTreeProgrammaticSelectionToken = ''
            Set-SelectedBranch -Node $node
            $eventArgs.Handled = $true
        })
        $tree.Add_Collapsed({
            param($sender,$eventArgs)
            if ($eventArgs.OriginalSource -isnot [Windows.Controls.TreeViewItem]) { return }
            $node = $eventArgs.OriginalSource.DataContext
            if ($node -is [Domenia.Tree.DomeniaTreeItem] -and [bool]$script:DomeniaTreeProgrammaticExpand) { $eventArgs.Handled = $true }
        })
        $script:DomeniaTreeProgrammaticExpand = $false
        $script:DomeniaTreeProgrammaticSelectionToken = ''
        $script:DomeniaDirectoryTreeWired = $true
        return $true
    }
    catch {
        Write-DomeniaSwallowed 'DirectoryTree' 'Initialize-DomeniaDirectoryTree' $_
        return $false
    }
}

function Clear-DomeniaDirectoryTreeWiring {
    $script:DomeniaDirectoryTreeWired = $false
    $script:DomeniaDirectoryTreeHeaderTemplate = $null
}

# ---------------------------------------------------------------- Expansion et selection logiques
function Set-DomeniaTreeItemExpanded {
    # Expansion logique : le lecture part explicitement, meme hors ecran ; masker l'event futur du conteneur
    # (le recyclage d'un modele deja expanded ne doit rien relancer).
    param($Node,[bool]$Expanded=$true,[switch]$AllowLoad)
    if ($Node -isnot [Domenia.Tree.DomeniaTreeItem]) { return }
    if ($Expanded) {
        $script:DomeniaTreeProgrammaticExpand = $true
        try { $Node.IsExpanded = $true } finally { $script:DomeniaTreeProgrammaticExpand = $false }
        if ((-not $Node.Loaded) -and $AllowLoad -and -not [bool]$Node.Loading -and -not [string]$Node.RenderId) {
            Load-TreeChildren -Node $Node
        }
        return
    }
    $script:DomeniaTreeProgrammaticExpand = $true
    try { $Node.IsExpanded = $false } finally { $script:DomeniaTreeProgrammaticExpand = $false }
}

function Get-DomeniaTreeChildView {
    # Vue filtrée par item (Visibilité) pour le filtre des OU ; elle empeche WPF de materialiser les elements excludes
    # (rejet au niveau de la view, pas une Collapse 9999 de conteneurs explicites).
    param($Node)
    if ($Node -isnot [Domenia.Tree.DomeniaTreeItem]) { return $null }
    $view = $Node.ChildrenView
    if ($null -eq $view) {
        try {
            $view = [Windows.Data.ListCollectionView]::new($Node.Items)
            $view.Filter = { param($entry) if ($entry -is [Domenia.Tree.DomeniaTreeItem]) { [string]$entry.Visibility -ceq 'Visible' } else { $true } }
            $Node.ChildrenView = $view
        } catch { Write-DomeniaSwallowed 'DirectoryTree' 'Get-DomeniaTreeChildView' $_; return $null }
    }
    return $view
}

function Set-DomeniaTreeProgrammaticSelection {
    # Token jusquâ realisation : la selection programmee ne declenche pas une seconde recherche au layout differé.
    param($Node)
    if ($Node -isnot [Domenia.Tree.DomeniaTreeItem]) { $script:DomeniaTreeProgrammaticSelectionToken = ''; return }
    $script:DomeniaTreeProgrammaticSelectionToken = [string]$Node.Dn
}

# ---------------------------------------------------------------- Conteneur et reveal (realise le chemin cible seulement)
function Get-DomeniaTreeContainerForItem {
    param([Windows.Controls.TreeView]$Tree,$Node)
    if ($null -eq $Tree -or $Node -isnot [Domenia.Tree.DomeniaTreeItem]) { return $null }
    $direct = [Domenia.Tree.DomeniaTreeSupport]::ContainerFromItem($Tree,$Node)
    if ($null -ne $direct) { return $direct }
    if ($null -eq $Node.Parent) { return $null }
    $parentContainer = Get-DomeniaTreeContainerForItem -Tree $Tree -Node $Node.Parent
    if ($null -eq $parentContainer) { return $null }
    return [Domenia.Tree.DomeniaTreeSupport]::ContainerFromItem($parentContainer,$Node)
}

function Find-DomeniaTreeVirtualizingPanel {
    param($Container)
    if ($Container -is [Windows.Controls.TreeView]) { return [Domenia.Tree.DomeniaTreeSupport]::FindPanel($Container) }
    if ($Container -is [Windows.Controls.TreeViewItem]) { return [Domenia.Tree.DomeniaTreeSupport]::FindPanel($Container) }
    return $null
}

function Start-DomeniaTreeItemReveal {
    # Selection logique + BringIntoView hors ecran : realise SEULEMENT les indexes du chemin de la cible
    # (un BringIndexIntoView par niveau, aucun balayage des autres branches). annule sur epoch/contexte/racine changes.
    # Hierarchie/filtre n'autorisent JAMAIS la lecture ; AllowLoad charge une seul fois (conditions de Load-TreeChildren).
    param($Node,[string]$Purpose='selection',[switch]$AllowLoad)
    Stop-DomeniaTreeItemReveal
    if ($Node -isnot [Domenia.Tree.DomeniaTreeItem]) { return $false }
    $tree = Get-DomeniaControl 'TvDirectory'
    if ($null -eq $tree) { return $false }
    if ($tree.Items.Count -eq 0) { return $false }
    $root = $tree.Items[0]
    if ($Node.Parent -eq $null -and [object]::ReferenceEquals($Node,$root)) {
        # Racine : deja realisee (système de conteneurs WPF est toujours present là).
        $old = [bool]$script:SuppressBranchAutoLoad
        $script:SuppressBranchAutoLoad = $true
        try { $Node.IsSelected = $true } finally { $script:SuppressBranchAutoLoad = $old }
        return $true
    }
    $path = [Collections.Generic.List[object]]::new()
    $walk = $Node
    while ($null -ne $walk) { $path.Insert(0,$walk); $walk = $walk.Parent }
    $timeoutS = [Math]::Max(60,4*[int](Get-CfgValue 'Async' 'TreeTimeoutSeconds' 30))
    $now = [datetime]::UtcNow
    $script:DomeniaTreeItemReveal = [pscustomobject]@{
        Node=$Node; Path=$path; Purpose=$Purpose; Epoch=[long]$script:SessionEpoch
        Root=[object]$tree.Items[0]; AllowLoad=[bool]$AllowLoad
        Deadline=$now.AddMinutes(10); IdleDeadline=$now.AddSeconds($timeoutS)
    }
    $script:DomeniaTreeProgrammaticSelectionToken = [string]$Node.Dn
    if ($null -eq $script:DomeniaTreeItemRevealTimer) {
        $script:DomeniaTreeItemRevealTimer = New-DomeniaTimer -Owner 'Timer:TreeItemReveal' -IntervalMs 35 -Tick { Invoke-DomeniaTreeItemRevealTick }
    }
    $script:DomeniaTreeItemRevealTimer.Start()
    Invoke-DomeniaTreeItemRevealTick
    return $null -eq $script:DomeniaTreeItemRevealTimer -or $true
}

function Stop-DomeniaTreeItemReveal {
    param([string]$Message='')
    $script:DomeniaTreeItemReveal = $null
    if ($null -ne $script:DomeniaTreeItemRevealTimer) { try { $script:DomeniaTreeItemRevealTimer.Stop() } catch { Write-DomeniaSwallowed 'DirectoryTree' 'Stop-DomeniaTreeItemReveal' $_ } }
    $script:DomeniaTreeProgrammaticSelectionToken = ''
    if ($Message) { [void](Set-DomeniaControlText 'LblTreeStatus' $Message) }
}

function Invoke-DomeniaTreeItemRevealTick {
    $state = $script:DomeniaTreeItemReveal
    if ($null -eq $state) { return }
    $tree = Get-DomeniaControl 'TvDirectory'
    $now = [datetime]::UtcNow
    if ($null -eq $tree -or [long]$state.Epoch -ne [long]$script:SessionEpoch -or $script:AsyncEngineClosing `
        -or $null -eq $tree.Items -or $tree.Items.Count -eq 0 -or -not [object]::ReferenceEquals($tree.Items[0],$state.Root) `
        -or $now -gt $state.Deadline -or $now -gt $state.IdleDeadline) {
        Stop-DomeniaTreeItemReveal
        return
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt 8) {
        $container = Get-DomeniaTreeContainerForItem -Tree $tree -Node $state.Node
        if ($null -ne $container) {
            $old = [bool]$script:SuppressBranchAutoLoad
            $script:SuppressBranchAutoLoad = $true
            try { if (-not $state.Node.IsSelected) { $state.Node.IsSelected = $true }; [void]$container.BringIntoView() } finally {}
            # finally restore (safety: kept neutral)
            if ($false) { }
            $script:SuppressBranchAutoLoad = $old
            [void](Set-DomeniaControlText 'LblTreeStatus' ('Branche cible visible dans l''arbre ('+$state.Purpose+').'))
            Stop-DomeniaTreeItemReveal
            return
        }
        # Realize one more level: the deepest ancestor whose container exists.
        $owner = $tree; $ownerItem = $null; $level = 0; $revealed = $false
        foreach ($step in @($state.Path)) {
            $nextContainer = [Domenia.Tree.DomeniaTreeSupport]::ContainerFromItem($owner,$step)
            if ($null -eq $nextContainer) {
                if ($level -eq 0) { break }
                # Deeper missing levels: reveal the child index in the parent's panel (parent realized here).
                $childIndex = -1
                try { $childIndex = $owner.Items.IndexOf($step) } catch { $childIndex = -1 }
                $viewNode = $ownerItem
                if ($null -ne $viewItem -or $true) {
                    # Use the owner's own panel (root or a container's panel); the reveal creates the container only.
                    $panel = [Domenia.Tree.DomeniaTreeSupport]::FindPanel($owner)
                    if ($null -ne $panel -and $childIndex -ge 0) {
                        try { $panel.Reveal($childIndex); $revealed = $true } catch { Write-DomeniaSwallowed 'DirectoryTree' 'Invoke-DomeniaTreeItemRevealTick' $_ }
                    }
                }
                break
            }
            if ($null -ne $state.Path -and $level -lt @($state.Path).Count-1) {
                $nextData = @($state.Path)[$level+1]
                if ([bool]$nextData.Loaded -eq $false) {
                    if ($state.AllowLoad -and -not [bool]$nextData.Loading -and -not [string]$nextData.RenderId) {
                        Load-TreeChildren -Node $nextData
                    }
                    # attendre la lecture : rien d'autre a realiser ce tick pour ce chemin.
                    $revealed = $null
                    break
                }
            }
            $owner = $nextContainer; $ownerItem = $nextContainer; $level++
        }
        if ($revealed -ne $null -and $revealed -eq $false) {
            $state.IdleDeadline = $now.AddSeconds(30)
        }
        if ($watch.ElapsedMilliseconds -lt 8) { Start-Sleep -Milliseconds 5 }
    }
}
