# Dashboards made of widgets (decision David 2026-10-07): every tile and chart of the workstation, fleet and
# software dashboards is a widget. Each one can be edited (title, representation allowed by its kind of data,
# size, section), moved (drag and drop or menu), removed (with undo) and new ones come from the built-in catalog
# or the ready-made WMI queries. Providers compute the data (Domenia-Board*.ps1), this module lays it out.
# Handlers read their sender's Tag and never use GetNewClosure, so they can call the application functions.

$script:DomeniaBoardStates = @{}
$script:DomeniaBoardDrag = $null
$script:DomeniaBoardPendingDrop = $null

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------
function Get-DomeniaWidgetList {
    # Widgets of the first version (separate "Widgets" part), read once to be merged into the layout.
    param([string]$Board)
    $raw = [string](Get-DomeniaSetting -Name ('Widgets.' + $Board) -Default '')
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try {
        $list = ConvertFrom-Json -InputObject $raw
        if ($null -eq $list) { return @() }
        return @($list)
    } catch { return @() }
}
function Get-DomeniaBoardPanelName {
    param([string]$Board)
    switch ($Board) { 'Computer' { return 'PnlComputerDashboard' } 'Fleet' { return 'PnlFleetDashboard' } default { return 'PnlSoftwareDashboard' } }
}
function Get-DomeniaBoardState {
    param([string]$Board)
    if (-not $script:DomeniaBoardStates.ContainsKey($Board)) {
        $script:DomeniaBoardStates[$Board] = @{ Board = $Board; Data = $null; Editing = $false; UndoLayout = $null; UndoText = ''; Highlight = ''; EmptyText = ''; Notice = ''; LastId = '' }
    }
    return $script:DomeniaBoardStates[$Board]
}
function Get-DomeniaBoardLayout {
    param([string]$Board)
    $json = [string](Get-DomeniaSetting -Name ('Dashboard.' + $Board + '.Layout') -Default '')
    $legacy = if (-not $json -and $Board -in @('Computer','Fleet')) { @(Get-DomeniaWidgetList -Board $Board) } else { @() }
    $probes = if ($Board -eq 'Software') { @() } else { @(Get-DomeniaProbeCatalog) }
    return @(ConvertTo-DomeniaBoardLayout -Board $Board -Json $json -LegacyWidgets $legacy -ProbeCatalog $probes)
}
function Set-DomeniaBoardLayout {
    # Saves the layout, keeps the previous one for "Annuler" when asked, redraws without the entrance motion.
    param([string]$Board,[object[]]$Layout = @(),[string]$Undo = '',[string]$Highlight = '')
    $state = Get-DomeniaBoardState $Board
    $current = @(Get-DomeniaBoardLayout -Board $Board)
    $json = ConvertTo-DomeniaBoardLayoutJson -Layout $Layout
    # A change that changes nothing (first widget moved left...) is neither saved nor offered for undo.
    $legacy = ($Board -in @('Computer','Fleet') -and [string](Get-DomeniaSetting -Name ('Widgets.' + $Board) -Default ''))
    if (-not $legacy -and [string](Get-DomeniaSetting -Name ('Dashboard.' + $Board + '.Layout') -Default '') -and $json -ceq (ConvertTo-DomeniaBoardLayoutJson -Layout $current)) { return }
    if ($Undo) { $state.UndoLayout = $current; $state.UndoText = $Undo } else { $state.UndoLayout = $null; $state.UndoText = '' }
    $state.Notice = ''
    Set-DomeniaSetting -Name ('Dashboard.' + $Board + '.Layout') -Value $json
    if ($legacy) { Set-DomeniaSetting -Name ('Widgets.' + $Board) -Value '' }
    $state.Highlight = $Highlight
    if ($Highlight) { $state.LastId = $Highlight }
    Show-DomeniaBoard -Board $Board -Quiet
    if ($Highlight -and -not $state.Editing) {
        $panel = Get-DomeniaControl (Get-DomeniaBoardPanelName $Board)
        if ($null -ne $panel -and $null -eq (Find-DomeniaBoardHolder $panel $Highlight)) {
            $state.Notice = 'Widget enregistre : il s affichera des que ses donnees seront lues.'
            Show-DomeniaBoard -Board $Board -Quiet
        }
    }
}

# ---------------------------------------------------------------------------
# Board
# ---------------------------------------------------------------------------
function Show-DomeniaBoard {
    # Draws a board from its layout and the last data of its provider. -Data replaces the data (new reading),
    # -Quiet skips the entrance motion (layout edits).
    param([ValidateSet('Computer','Fleet','Software')][string]$Board,$Data = $null,[switch]$Quiet,[string]$EmptyText = '')
    $state = Get-DomeniaBoardState $Board
    if ($null -ne $Data) { $state.Data = $Data; $state.UndoLayout = $null; $state.UndoText = ''; $state.Notice = ''; $state.EmptyText = '' }
    if ($EmptyText) { $state.EmptyText = $EmptyText }
    $panel = Get-DomeniaControl (Get-DomeniaBoardPanelName $Board)
    if ($null -eq $panel) { return }
    $panel.Children.Clear()
    $layout = @(Get-DomeniaBoardLayout -Board $Board)
    [void]$panel.Children.Add((New-DomeniaBoardToolbar -Board $Board -Layout $layout -State $state))
    $shown = 0
    foreach ($group in @(Get-DomeniaBoardGroups -Layout $layout)) {
        $section = New-Object System.Windows.Controls.StackPanel
        $wrap = New-DomeniaDashboardSection $section $group (Get-DomeniaBoardGroupSubtitle -Group $group -Board $Board)
        $wrap.AllowDrop = $true
        $wrap.Background = [System.Windows.Media.Brushes]::Transparent
        $wrap.Tag = @{ Board = $Board; Group = $group }
        $wrap.Add_DragOver({ param($s,$e) Invoke-DomeniaBoardAutoScroll $s $e; if ($e.Data.GetDataPresent('DomeniaBoardWidget')) { $e.Effects = [System.Windows.DragDropEffects]::Move } else { $e.Effects = [System.Windows.DragDropEffects]::None }; $e.Handled = $true })
        $wrap.Add_Drop({ param($s,$e) $id = [string]$e.Data.GetData('DomeniaBoardWidget'); if ($id) { Request-DomeniaBoardDrop -Board $s.Tag.Board -Id $id -Group $s.Tag.Group }; $e.Handled = $true })
        $count = 0
        foreach ($item in @($layout | Where-Object { [string]$_.Group -eq $group })) {
            $element = New-DomeniaBoardWidget -Board $Board -Item $item -State $state
            if ($null -ne $element) { [void]$wrap.Children.Add($element); $count++ }
        }
        $hint = ''
        if ($null -ne $state.Data -and $null -ne $state.Data.Hints -and $state.Data.Hints.ContainsKey($group)) { $hint = [string]$state.Data.Hints[$group] }
        if ($state.Editing) { [void]$wrap.Children.Add((New-DomeniaBoardAddTile -Board $Board -Group $group)) }
        elseif (-not $count -and -not $hint) { continue }
        if (-not $count -and $hint) {
            $note = New-DomeniaChartText -Text $hint -Size 12.5 -Key 'MutedColor'
            $note.Margin = [System.Windows.Thickness]::new(7, 2, 7, 6)
            $wrap.Parent.Children.Insert(1 + [int]($wrap.Parent.Children.Count -gt 2), $note)
        }
        Optimize-DomeniaBoardRow $wrap
        $block = $wrap.Parent
        $section.Children.Remove($block)
        $block.Margin = [System.Windows.Thickness]::new(0, $(if ($panel.Children.Count -gt 1) { 20 } else { 8 }), 0, 0)
        [void]$panel.Children.Add($block)
        $shown += $count
    }
    if (-not $shown -and -not $state.Editing) {
        $none = -not @($layout).Count
        $message = if ($none) { 'Tous les widgets ont ete retires. Ajoutez-en un, ou revenez a la disposition par defaut avec Personnaliser.' } elseif ($state.EmptyText) { $state.EmptyText } else { 'Les widgets se remplissent apres la premiere lecture.' }
        $empty = New-DomeniaChartEmpty -Width 520 -Height 200 -Title $(if ($none) { 'Aucun widget' } else { 'Pas encore de donnees' }) -Message $message
        $empty.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        [void]$panel.Children.Add($empty)
    }
    if (-not $Quiet) { Invoke-DomeniaDashboardEntrance -Panel $panel }
    elseif ($state.Highlight) {
        $target = Find-DomeniaBoardHolder $panel $state.Highlight
        $state.Highlight = ''
        if ($null -ne $target) { Invoke-DomeniaDashboardEntrance -Panel $target }
    }
}
function Find-DomeniaBoardHolder {
    param($Node,[string]$Id)
    if ($Node -isnot [System.Windows.Controls.Panel]) { return $null }
    foreach ($child in @($Node.Children)) {
        if ($child -is [System.Windows.FrameworkElement] -and $child.Tag -is [hashtable] -and [string]$child.Tag['Id'] -eq $Id -and $child.Tag.ContainsKey('Chrome')) { return $child }
        $found = Find-DomeniaBoardHolder $child $Id
        if ($null -ne $found) { return $found }
    }
    return $null
}
function Get-DomeniaBoardGroupSubtitle {
    param([string]$Group,[string]$Board = '')
    if ($Board -eq 'Software') { if ($Group -eq 'Repartition') { return 'Editeurs, architecture, portee et taille' } }
    $known = @{
        'Vue d ensemble' = 'Etat general et points a verifier'
        'Identite du poste' = 'Materiel, systeme et session'
        'Compte machine dans Active Directory' = 'Attributs lus dans l annuaire avec la fiche'
        'Ressources' = 'Mesurees pendant l inventaire'
        'Activite' = 'Services, processus et journal Systeme'
        'Securite et etat' = 'Protection, correctifs et configuration'
        'Inventaire du perimetre' = 'Base autonome locale'
        'Repartition' = 'Systemes, activite et unites d organisation'
        'Releves WMI' = 'Derniere analyse de l OU'
        'Synthese' = 'Calculee sur la liste chargee'
    }
    if ($known.ContainsKey($Group)) { return $known[$Group] }
    return ''
}
function New-DomeniaBoardButton {
    # Compact toolbar button: Fluent glyph and label.
    param([string]$Glyph,[string]$Text,[string]$Tip,$Tag,[string]$Style = 'SecondaryButton')
    $button = New-Object System.Windows.Controls.Button
    $button.SetResourceReference([System.Windows.Controls.Control]::StyleProperty, $Style)
    $button.MinHeight = 30
    $button.Padding = [System.Windows.Thickness]::new(12, 3, 12, 3)
    $button.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $content = New-Object System.Windows.Controls.StackPanel
    $content.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    if ($Glyph) {
        $icon = New-Object System.Windows.Controls.TextBlock
        $icon.Text = $Glyph
        $icon.FontFamily = [System.Windows.Media.FontFamily]::new($script:DomeniaChartIconFont)
        $icon.FontSize = 12
        $icon.Margin = [System.Windows.Thickness]::new(0, 1, 7, 0)
        $icon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void]$content.Children.Add($icon)
    }
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$content.Children.Add($label)
    $button.Content = $content
    $button.ToolTip = $Tip
    [System.Windows.Automation.AutomationProperties]::SetName($button, $Text)
    $button.Tag = $Tag
    $button.Add_Click({ param($s,$e) Invoke-DomeniaBoardAction -Tag $s.Tag })
    return $button
}
function New-DomeniaBoardToolbar {
    # Right: add, customise / done, reset (while customising), refresh the queries. Left: hint or undo.
    param([string]$Board,[object[]]$Layout = @(),$State)
    $bar = New-Object System.Windows.Controls.Grid
    $bar.Margin = [System.Windows.Thickness]::new(7, 2, 7, 0)
    $fill = New-Object System.Windows.Controls.ColumnDefinition; $fill.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $auto = New-Object System.Windows.Controls.ColumnDefinition; $auto.Width = [System.Windows.GridLength]::Auto
    [void]$bar.ColumnDefinitions.Add($fill); [void]$bar.ColumnDefinitions.Add($auto)
    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    [System.Windows.Controls.Grid]::SetColumn($buttons, 1)
    $probes = @($Layout | Where-Object { [string]$_.Source -eq 'Probe' }).Count
    if ($probes -and $Board -ne 'Software') { [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE72C) 'Actualiser les requetes' 'Execute les requetes WMI des widgets (lecture seule) sur le perimetre, avec confirmation.' @{ Board = $Board; Action = 'Probe' })) }
    [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE710) 'Ajouter un widget' 'Choisir une information du tableau de bord ou une requete prete a l emploi.' @{ Board = $Board; Action = 'Add'; Value = '' }))
    if ($State.Editing) {
        [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE777) 'Par defaut' 'Revient a la disposition livree (annulable).' @{ Board = $Board; Action = 'Reset' }))
        [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE73E) 'Terminer' 'Quitte la personnalisation.' @{ Board = $Board; Action = 'Customize' } 'RunButton'))
    } else {
        [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE70F) 'Personnaliser' 'Deplacer, redimensionner, modifier ou retirer les widgets.' @{ Board = $Board; Action = 'Customize' }))
    }
    [void]$bar.Children.Add($buttons)
    $left = New-Object System.Windows.Controls.StackPanel
    $left.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $left.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $say = { param([string]$Text) $line = New-DomeniaChartText -Text $Text -Size 12.5 -Key 'MutedColor' -OneLine; [void]$left.Children.Add($line) }
    if ($State.UndoText -and $null -ne $State.UndoLayout) {
        & $say ([string]$State.UndoText + '.')
        $undo = New-DomeniaBoardButton ([string][char]0xE7A7) 'Annuler' 'Revient a la disposition precedente.' @{ Board = $Board; Action = 'Undo' }
        $undo.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
        [void]$left.Children.Add($undo)
    } elseif ($State.Notice) {
        & $say ([string]$State.Notice)
    } elseif ($State.Editing) {
        & $say 'Glissez un widget pour le deplacer ; clic droit pour sa representation, sa taille ou sa place.'
    }
    $left.ClipToBounds = $true
    [void]$bar.Children.Add($left)
    return $bar
}
function New-DomeniaBoardAddTile {
    # Dashed tile at the end of a section while customising (a button: reachable with the keyboard).
    param([string]$Board,[string]$Group)
    $xaml = @'
<Button xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="230" Height="118" Margin="7" Cursor="Hand" VerticalAlignment="Top" HorizontalAlignment="Left">
  <Button.Template>
    <ControlTemplate TargetType="Button">
      <Grid Background="Transparent">
        <Rectangle x:Name="Edge" RadiusX="14" RadiusY="14" StrokeThickness="1.5" StrokeDashArray="4 3" Stroke="{DynamicResource BorderColor}" Fill="Transparent"/>
        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
          <Border x:Name="Disc" Width="32" Height="32" CornerRadius="16" Background="{DynamicResource AccentSoft}" HorizontalAlignment="Center" Margin="0,0,0,8">
            <TextBlock x:Name="Plus" Text="&#xE710;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Foreground="{DynamicResource AccentColor}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="Ajouter ici" FontWeight="SemiBold" FontSize="13" HorizontalAlignment="Center" Foreground="{DynamicResource TextColor}"/>
        </StackPanel>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="Edge" Property="Stroke" Value="{DynamicResource AccentColor}"/>
          <Setter TargetName="Disc" Property="Background" Value="{DynamicResource AccentColor}"/>
          <Setter TargetName="Plus" Property="Foreground" Value="White"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter TargetName="Edge" Property="Stroke" Value="{DynamicResource AccentColor}"/>
          <Setter TargetName="Edge" Property="StrokeThickness" Value="2"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </Button.Template>
</Button>
'@
    $tile = [Windows.Markup.XamlReader]::Parse($xaml)
    $tile.ToolTip = 'Ajouter un widget dans la section ' + $Group + '.'
    [System.Windows.Automation.AutomationProperties]::SetName($tile, 'Ajouter un widget dans ' + $Group)
    $tile.Tag = @{ Board = $Board; Action = 'Add'; Value = $Group }
    $tile.Add_Click({ param($s,$e) Invoke-DomeniaBoardAction -Tag $s.Tag })
    return $tile
}
function Optimize-DomeniaBoardRow {
    # In a section mixing tall cards and compact tiles, compact tiles are stacked two by two so rows line up.
    param($Wrap)
    $children = @($Wrap.Children)
    $heights = @{}
    foreach ($child in $children) {
        $card = $child
        if ($child -is [System.Windows.Controls.Panel] -and [string]$child.Uid -ne 'DomeniaCard' -and $child.Children.Count) { $card = $child.Children[0] }
        $h = if ($card -is [System.Windows.FrameworkElement]) { [double]$card.Height } else { [double]::NaN }
        # A content-sized card with a compact minimum (a short list) is as short as a tile.
        if ([double]::IsNaN($h) -and $card -is [System.Windows.FrameworkElement] -and $card.MinHeight -gt 0 -and $card.MinHeight -lt 140) { $h = [double]$card.MinHeight }
        $heights[$child.GetHashCode()] = $h
    }
    $isSmall = { param($e) $h = [double]$heights[$e.GetHashCode()]; (-not [double]::IsNaN($h)) -and $h -gt 0 -and $h -lt 140 }
    $small = @($children | Where-Object { & $isSmall $_ }).Count
    $tall = @($children | Where-Object { -not (& $isSmall $_) }).Count
    if (-not $tall -or $small -lt 2) { return }
    $Wrap.Children.Clear()
    $pending = $null
    foreach ($child in $children) {
        if (-not (& $isSmall $child)) {
            if ($null -ne $pending) { [void]$Wrap.Children.Add($pending); $pending = $null }
            [void]$Wrap.Children.Add($child)
            continue
        }
        if ($null -eq $pending) {
            $pending = New-Object System.Windows.Controls.StackPanel
            $pending.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
            [void]$pending.Children.Add($child)
        } else {
            [void]$pending.Children.Add($child)
            [void]$Wrap.Children.Add($pending)
            $pending = $null
        }
    }
    if ($null -ne $pending) { [void]$Wrap.Children.Add($pending) }
}

# ---------------------------------------------------------------------------
# One widget
# ---------------------------------------------------------------------------
function Resolve-DomeniaBoardEntry {
    # Data, kind and title of a layout item (built-in from the provider, query from its results).
    param([string]$Board,$Item,$State)
    $entry = $null; $title = ''; $kind = 'Value'; $name = ''
    if ([string]$Item.Source -eq 'Builtin') {
        $catalog = Get-DomeniaBoardCatalogItem -Board $Board -Key ([string]$Item.Key)
        if ($null -ne $catalog) { $kind = [string]$catalog.Kind; $name = [string]$catalog.Title }
        if ($null -ne $State.Data -and $null -ne $State.Data.Entries -and $State.Data.Entries.ContainsKey([string]$Item.Key)) { $entry = $State.Data.Entries[[string]$Item.Key] }
    } else {
        $probe = Get-DomeniaProbe -Id ([string]$Item.Key)
        $kind = Get-DomeniaProbeKind -Probe $probe -Board $Board
        if ($null -ne $probe) {
            $name = [string]$probe.Name
            $results = @(Get-DomeniaWidgetResults -Board $Board -ProbeId ([string]$Item.Key))
            $measured = if ($results.Count) { Measure-DomeniaWidgetData -Probe $probe -Results $results -Visual ([string]$Item.Visual) } else { $null }
            $entry = ConvertFrom-DomeniaProbeMeasure -Probe $probe -Measured $measured -Board $Board -Key ([string]$Item.Key)
        } else {
            $name = 'Requete inconnue'
            $entry = New-DomeniaBoardEntry -Key ([string]$Item.Key) -Kind Value -Value 'Requete inconnue' -Detail 'Retirez ce widget' -State Off
        }
    }
    if ($null -ne $entry) { $kind = [string]$entry.Kind }
    $title = [string]$Item.Title
    if (-not $title -and $null -ne $entry -and [string]$entry.Title -and [string]$Item.Source -eq 'Builtin') { $title = [string]$entry.Title }
    if (-not $title -and $null -ne $entry -and [string]$entry.Title -and [string]$Item.Source -eq 'Probe' -and $Board -ne 'Computer') { $title = [string]$entry.Title }
    if (-not $title) { $title = $name }
    return [pscustomobject]@{ Entry = $entry; Kind = $kind; Title = $title; Name = $name }
}
function New-DomeniaWidgetVisual {
    # A board entry drawn with one representation at one size.
    param($Entry,[string]$Visual,[string]$Title,$Size)
    $w = [double]$Size.Width; $h = [double]$Size.Height; $min = [double]$Size.MinHeight
    $items = @($Entry.Items | Where-Object { $null -ne $_ })
    # Numeric buckets of a query: empty buckets before the first and after the last value are not drawn.
    if ([string]$Entry.Kind -eq 'Measure' -and $items.Count) {
        $first = -1; $last = -1
        for ($i = 0; $i -lt $items.Count; $i++) { $n = 0.0; try { $n = [double]$items[$i].Value } catch { }; if ($n -gt 0) { if ($first -lt 0) { $first = $i }; $last = $i } }
        if ($first -ge 0) { $items = @($items[$first..$last]) }
    }
    $unit = [string]$Entry.Unit
    $value = [string]$Entry.Value; $detail = [string]$Entry.Detail
    if (-not $value -and $items.Count -and [string]$Entry.Kind -ne 'List') {
        $top = @($items | Where-Object { $null -ne $_.PSObject.Properties['Value'] } | Sort-Object { [double]$_.Value } -Descending | Select-Object -First 1)
        if ($top.Count) { $value = [string]$top[0].Label; $total = 0.0; foreach ($i in $items) { try { $total += [double]$i.Value } catch { } }; if ($total -gt 0 -and -not $detail) { $detail = [string][Math]::Round(100.0 * [double]$top[0].Value / $total) + ' % du total' } }
    }
    switch ($Visual) {
        'Gauge' {
            $maximum = 100.0; if ($null -ne $Entry.Maximum -and [double]$Entry.Maximum -gt 0) { $maximum = [double]$Entry.Maximum }
            return New-DomeniaGauge -Title $Title -Value ([double]$Entry.Number) -Maximum $maximum -Unit $unit -LowIsBad:([bool]$Entry.LowIsBad) -Width $w -Height $h -Caption $detail
        }
        'Pie' { return New-DomeniaDonutChart -Title $Title -Items $items -Width $w -Height $h -CenterText ([string]$Entry.CenterText) }
        'Bar' { return New-DomeniaBarChart -Title $Title -Items $items -Width $w -Height $h -Top 12 -Unit $(if ($unit) { ' ' + $unit } else { '' }) }
        'Column' { return New-DomeniaColumnChart -Title $Title -Items $items -Width $w -Height $h }
        'Line' { return New-DomeniaLineChart -Title $Title -Points $items -Width $w -Height $h }
        'Text' {
            # One workstation: its values only (a count of 1 next to each value says nothing).
            $listed = if ([string]$Entry.Kind -eq 'List') { @() } elseif ([string]$Entry.Kind -eq 'Value') { @($items | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Label } }) } else { $items }
            if ([string]$Entry.Kind -eq 'Value') { $min = [Math]::Min($min, 118.0) }
            return New-DomeniaListCard -Title $Title -Subtitle $detail -Items $listed -Width $w -Height $h -MinHeight $min -Unit $unit -Fallback $value
        }
        'List' { return New-DomeniaAttentionCard -Title $Title -Items $items -Width $w -MinHeight $min }
        'Health' { return New-DomeniaHealthCard -Title $Title -Score ([double]$Entry.Number) -Verdict $value -Detail $detail -State $(if ([string]$Entry.State) { [string]$Entry.State } else { 'Ok' }) -Width $w -Height $h }
        default { return New-DomeniaKpiTile -Title $Title -Value $(if ($value) { $value } else { 'Non lu' }) -Detail $detail -Width $w -Height $h -State ([string]$Entry.State) }
    }
}
function New-DomeniaBoardChromeButton {
    # Small round button over a widget (modify, remove).
    param([string]$Glyph,[string]$Tip,$Tag,[switch]$Danger)
    $hover = if ($Danger) { '#F87171' } else { '#60A5FA' }
    $Tip = [Security.SecurityElement]::Escape($Tip)
    $xaml = @"
<Button xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="26" Height="26" Margin="4,0,0,0" Cursor="Hand" ToolTip="$Tip" AutomationProperties.Name="$Tip">
  <Button.Template>
    <ControlTemplate TargetType="Button">
      <Border x:Name="Disc" CornerRadius="13" Background="{DynamicResource BgCard}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1">
        <TextBlock x:Name="Mark" Text="$Glyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{DynamicResource MutedColor}"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="Disc" Property="Background" Value="$hover"/>
          <Setter TargetName="Disc" Property="BorderBrush" Value="$hover"/>
          <Setter TargetName="Mark" Property="Foreground" Value="White"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter TargetName="Disc" Property="BorderBrush" Value="$hover"/>
          <Setter TargetName="Disc" Property="BorderThickness" Value="2"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
  </Button.Template>
</Button>
"@
    $button = [Windows.Markup.XamlReader]::Parse($xaml)
    $button.Tag = $Tag
    $button.Add_Click({ param($s,$e) Invoke-DomeniaBoardAction -Tag $s.Tag })
    return $button
}
function New-DomeniaBoardMenu {
    # Right-click menu of a widget: modify, representation, size, move, remove.
    param([string]$Board,$Item,[string]$Kind,[bool]$HasMaximum)
    $menu = New-Object System.Windows.Controls.ContextMenu
    $add = {
        param($Parent,[string]$Header,[string]$Action,[string]$Value,[bool]$Checked,[string]$Glyph)
        $entry = New-Object System.Windows.Controls.MenuItem
        $entry.Header = $Header
        $entry.Tag = @{ Board = $Board; Id = [string]$Item.Id; Action = $Action; Value = $Value }
        if ($Checked) { $entry.IsChecked = $true }
        if ($Glyph) { $icon = New-Object System.Windows.Controls.TextBlock; $icon.Text = $Glyph; $icon.FontFamily = [System.Windows.Media.FontFamily]::new($script:DomeniaChartIconFont); $icon.FontSize = 12; $entry.Icon = $icon }
        $entry.Add_Click({ param($s,$e) Invoke-DomeniaBoardAction -Tag $s.Tag })
        [void]$Parent.Items.Add($entry)
    }
    & $add $menu 'Modifier...' 'Edit' '' $false ([string][char]0xE70F)
    $names = Get-DomeniaBoardVisualNames
    $visuals = @(Get-DomeniaBoardVisuals -Kind $Kind -HasMaximum:$HasMaximum)
    if ($visuals.Count -gt 1) {
        $represent = New-Object System.Windows.Controls.MenuItem; $represent.Header = 'Representation'
        foreach ($visual in $visuals) { & $add $represent ([string]$names[$visual]) 'Visual' $visual ($visual -eq [string]$Item.Visual) '' }
        [void]$menu.Items.Add($represent)
    }
    $sizeMenu = New-Object System.Windows.Controls.MenuItem; $sizeMenu.Header = 'Taille'
    $sizes = Get-DomeniaBoardSizeNames
    foreach ($size in $sizes.Keys) { & $add $sizeMenu ([string]$sizes[$size]) 'Size' $size ($size -eq [string]$Item.Size) '' }
    [void]$menu.Items.Add($sizeMenu)
    $move = New-Object System.Windows.Controls.MenuItem; $move.Header = 'Deplacer'
    & $add $move 'Au debut de la section' 'Move' 'First' $false ''
    & $add $move 'Vers la gauche' 'Move' 'Back' $false ''
    & $add $move 'Vers la droite' 'Move' 'Forward' $false ''
    & $add $move 'A la fin de la section' 'Move' 'Last' $false ''
    [void]$menu.Items.Add($move)
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    & $add $menu 'Retirer du tableau de bord' 'Remove' '' $false ([string][char]0xE74D)
    return $menu
}
function New-DomeniaBoardWidget {
    param([string]$Board,$Item,$State)
    $resolved = Resolve-DomeniaBoardEntry -Board $Board -Item $Item -State $State
    $entry = $resolved.Entry
    if ($null -eq $entry -and -not $State.Editing) { return $null }
    # Without data (shown only while customising) the widget keeps its real kind, representation and size.
    $kind = if ($null -ne $entry) { [string]$entry.Kind } else { [string]$resolved.Kind }
    $hasMaximum = if ($null -ne $entry) { ($null -ne $entry.Maximum -and [double]$entry.Maximum -gt 0) } else { $kind -in @('Number','Health') }
    $visual = Resolve-DomeniaBoardVisual -Visual ([string]$Item.Visual) -Kind $kind -HasMaximum:$hasMaximum
    $size = Get-DomeniaBoardSize -Visual $visual -Size ([string]$Item.Size)
    if ($null -ne $entry) { $card = New-DomeniaWidgetVisual -Entry $entry -Visual $visual -Title $resolved.Title -Size $size }
    else { $card = New-DomeniaChartEmpty -Width $size.Width -Height $(if ($size.Height -gt 0) { $size.Height } elseif ($size.MinHeight -gt 0) { $size.MinHeight } else { 118 }) -Title $resolved.Title -Message 'Aucune donnee pour le moment' }

    $holder = New-Object System.Windows.Controls.Grid
    $holder.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $holder.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $holder.AllowDrop = $true
    [System.Windows.Automation.AutomationProperties]::SetName($holder, $resolved.Title)
    [void]$holder.Children.Add($card)
    $mark = New-Object System.Windows.Controls.Border
    $mark.Width = 4; $mark.CornerRadius = [System.Windows.CornerRadius]::new(2)
    $mark.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $mark.Margin = [System.Windows.Thickness]::new(0, 18, 0, 18)
    $mark.Background = ConvertTo-DomeniaChartBrush '#60A5FA'
    $mark.Visibility = [System.Windows.Visibility]::Collapsed
    $mark.IsHitTestVisible = $false
    [void]$holder.Children.Add($mark)
    $chrome = New-Object System.Windows.Controls.StackPanel
    $chrome.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $chrome.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $chrome.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    # Round buttons on the top-right corner of the card, above its title line.
    $chrome.Margin = [System.Windows.Thickness]::new(0, -4, -4, 0)
    [void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE70F) ('Modifier : ' + $resolved.Title) @{ Board = $Board; Id = [string]$Item.Id; Action = 'Edit' }))
    [void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE711) ('Retirer : ' + $resolved.Title) @{ Board = $Board; Id = [string]$Item.Id; Action = 'Remove' } -Danger))
    $chrome.Opacity = if ($State.Editing) { 1 } else { 0 }
    [void]$holder.Children.Add($chrome)
    $holder.Tag = @{ Board = $Board; Id = [string]$Item.Id; Chrome = $chrome; Mark = $mark; Editing = [bool]$State.Editing }
    $holder.ContextMenu = New-DomeniaBoardMenu -Board $Board -Item $Item -Kind $kind -HasMaximum $hasMaximum
    # The two round buttons appear on hover or keyboard focus (always while customising).
    $holder.Add_MouseEnter({ param($s,$e) Set-DomeniaHoverValue $s.Tag.Chrome ([System.Windows.UIElement]::OpacityProperty) 1 })
    $holder.Add_MouseLeave({ param($s,$e) if (-not $s.Tag.Editing -and -not $s.IsKeyboardFocusWithin) { Set-DomeniaHoverValue $s.Tag.Chrome ([System.Windows.UIElement]::OpacityProperty) 0 } })
    $holder.Add_IsKeyboardFocusWithinChanged({ param($s,$e) $s.Tag.Chrome.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); if ($s.IsKeyboardFocusWithin) { $s.Tag.Chrome.Opacity = 1 } elseif (-not $s.Tag.Editing -and -not $s.IsMouseOver) { $s.Tag.Chrome.Opacity = 0 } })
    # Drag and drop: a widget dropped on another one takes its place (and its section).
    $holder.Add_PreviewMouseLeftButtonDown({ param($s,$e) $script:DomeniaBoardDrag = @{ Source = $s; Start = $e.GetPosition($s) } })
    $holder.Add_PreviewMouseMove({
        param($s,$e)
        $drag = $script:DomeniaBoardDrag
        if ($null -eq $drag -or $drag.Source -ne $s -or $e.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
        $point = $e.GetPosition($s)
        if ([Math]::Abs($point.X - $drag.Start.X) -lt 8 -and [Math]::Abs($point.Y - $drag.Start.Y) -lt 8) { return }
        $script:DomeniaBoardDrag = $null
        $s.Opacity = 0.45
        try { [void][System.Windows.DragDrop]::DoDragDrop($s, [System.Windows.DataObject]::new('DomeniaBoardWidget', [string]$s.Tag.Id), [System.Windows.DragDropEffects]::Move) }
        finally { $s.Opacity = 1 }
    })
    $holder.Add_PreviewMouseLeftButtonUp({ param($s,$e) $script:DomeniaBoardDrag = $null })
    $holder.Add_DragOver({ param($s,$e) Invoke-DomeniaBoardAutoScroll $s $e; if ($e.Data.GetDataPresent('DomeniaBoardWidget') -and [string]$e.Data.GetData('DomeniaBoardWidget') -ne [string]$s.Tag.Id) { $e.Effects = [System.Windows.DragDropEffects]::Move; $s.Tag.Mark.Visibility = [System.Windows.Visibility]::Visible } else { $e.Effects = [System.Windows.DragDropEffects]::None }; $e.Handled = $true })
    $holder.Add_DragLeave({ param($s,$e) $s.Tag.Mark.Visibility = [System.Windows.Visibility]::Collapsed })
    $holder.Add_Drop({
        param($s,$e)
        $s.Tag.Mark.Visibility = [System.Windows.Visibility]::Collapsed
        $id = [string]$e.Data.GetData('DomeniaBoardWidget')
        if ($id -and $id -ne [string]$s.Tag.Id) { Request-DomeniaBoardDrop -Board $s.Tag.Board -Id $id -Onto ([string]$s.Tag.Id) }
        $e.Handled = $true
    })
    return $holder
}
function Invoke-DomeniaBoardAutoScroll {
    # While dragging near the top or bottom edge of the page, the page scrolls (the drag loop is modal).
    param($Source,$EventArgs)
    $node = $Source
    while ($null -ne $node -and $node -isnot [System.Windows.Controls.ScrollViewer]) { $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node) }
    if ($null -eq $node) { return }
    $point = $EventArgs.GetPosition($node)
    if ($point.Y -lt 48) { $node.ScrollToVerticalOffset([Math]::Max(0, $node.VerticalOffset - 24)) }
    elseif ($point.Y -gt $node.ActualHeight - 48) { $node.ScrollToVerticalOffset($node.VerticalOffset + 24) }
}
function Request-DomeniaBoardDrop {
    # Applied once the drag loop has returned (the dragged element is part of the board being redrawn).
    param([string]$Board,[string]$Id,[string]$Before = '',[string]$Group = '',[string]$Onto = '')
    $script:DomeniaBoardPendingDrop = @{ Board = $Board; Id = $Id; Before = $Before; Group = $Group; Onto = $Onto }
    $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    [void]$dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ Complete-DomeniaBoardDrop })
}
function Complete-DomeniaBoardDrop {
    $drop = $script:DomeniaBoardPendingDrop
    $script:DomeniaBoardPendingDrop = $null
    if ($null -eq $drop) { return }
    $layout = @(Get-DomeniaBoardLayout -Board $drop.Board)
    if ($drop.Onto) { $next = @(Move-DomeniaBoardItem -Layout $layout -Id $drop.Id -Onto $drop.Onto) }
    elseif ($drop.Before) { $next = @(Move-DomeniaBoardItem -Layout $layout -Id $drop.Id -Before $drop.Before) }
    else {
        $moving = @($layout | Where-Object { [string]$_.Id -eq $drop.Id })
        if (-not $moving.Count) { return }
        if ([string]$moving[0].Group -eq $drop.Group) { $next = @(Move-DomeniaBoardItem -Layout $layout -Id $drop.Id -Step Last) }
        else { $next = @(Update-DomeniaBoardItem -Layout $layout -Id $drop.Id -Changes @{ Group = $drop.Group }) }
    }
    Set-DomeniaBoardLayout -Board $drop.Board -Layout $next -Undo 'Widget deplace' -Highlight $drop.Id
}
function Invoke-DomeniaBoardAction {
    # Every button, menu entry and tile of the boards ends here.
    param($Tag)
    if ($Tag -isnot [hashtable]) { return }
    $board = [string]$Tag['Board']; $id = [string]$Tag['Id']; $value = [string]$Tag['Value']; $action = [string]$Tag['Action']
    $state = Get-DomeniaBoardState $board
    # The board is redrawn after an action: the keyboard focus is put back on the matching control.
    $panel = Get-DomeniaControl (Get-DomeniaBoardPanelName $board)
    $focused = [System.Windows.Input.Keyboard]::FocusedElement
    $keyboard = ($null -ne $panel -and $focused -is [System.Windows.DependencyObject] -and $panel.IsAncestorOf($focused))
    switch ($action) {
        'Edit' { if (Show-DomeniaBoardEditor -Board $board -Id $id) { Restore-DomeniaBoardFocus $board 'Edit' $state.LastId } else { Restore-DomeniaBoardFocus $board 'Edit' $id }; return }
        'Add' { if (Show-DomeniaBoardEditor -Board $board -Group $value) { Restore-DomeniaBoardFocus $board 'Edit' $state.LastId } else { Restore-DomeniaBoardFocus $board 'Add' '' }; return }
        'Customize' { $state.Editing = -not $state.Editing; Show-DomeniaBoard -Board $board -Quiet; if ($keyboard) { Restore-DomeniaBoardFocus $board 'Customize' '' }; return }
        'Probe' { Start-DomeniaWidgetProbe -Board $board; return }
        'Undo' {
            if ($null -eq $state.UndoLayout) { return }
            $previous = @($state.UndoLayout)
            Set-DomeniaBoardLayout -Board $board -Layout $previous
            if ($keyboard) { Restore-DomeniaBoardFocus $board 'Customize' '' }
            return
        }
        'Reset' { Set-DomeniaBoardLayout -Board $board -Layout @(Get-DomeniaBoardDefaultLayout -Board $board) -Undo 'Disposition par defaut appliquee'; if ($keyboard) { Restore-DomeniaBoardFocus $board 'Undo' '' }; return }
    }
    $layout = @(Get-DomeniaBoardLayout -Board $board)
    switch ($action) {
        'Remove' { Set-DomeniaBoardLayout -Board $board -Layout @(Remove-DomeniaBoardItem -Layout $layout -Id $id) -Undo 'Widget retire'; if ($keyboard) { Restore-DomeniaBoardFocus $board 'Undo' '' } }
        'Visual' { Set-DomeniaBoardLayout -Board $board -Layout @(Update-DomeniaBoardItem -Layout $layout -Id $id -Changes @{ Visual = $value }) -Undo 'Representation changee' -Highlight $id; if ($keyboard) { Restore-DomeniaBoardFocus $board 'Edit' $id } }
        'Size' { Set-DomeniaBoardLayout -Board $board -Layout @(Update-DomeniaBoardItem -Layout $layout -Id $id -Changes @{ Size = $value }) -Undo 'Taille changee' -Highlight $id; if ($keyboard) { Restore-DomeniaBoardFocus $board 'Edit' $id } }
        'Move' { Set-DomeniaBoardLayout -Board $board -Layout @(Move-DomeniaBoardItem -Layout $layout -Id $id -Step $value) -Undo 'Widget deplace' -Highlight $id; if ($keyboard) { Restore-DomeniaBoardFocus $board 'Edit' $id } }
    }
}
function Restore-DomeniaBoardFocus {
    # Focus on the button of the given action (and widget) in the redrawn board, else on the toolbar.
    param([string]$Board,[string]$Action,[string]$Id = '')
    $panel = Get-DomeniaControl (Get-DomeniaBoardPanelName $Board)
    if ($null -eq $panel) { return }
    $buttons = @(Get-DomeniaLogicalControls $panel | Where-Object { $_ -is [System.Windows.Controls.Button] -and $_.Tag -is [hashtable] })
    $target = @($buttons | Where-Object { [string]$_.Tag['Action'] -eq $Action -and ((-not $Id) -or [string]$_.Tag['Id'] -eq $Id) } | Select-Object -First 1)
    if (-not $target.Count) { $target = @($buttons | Where-Object { [string]$_.Tag['Action'] -eq 'Customize' } | Select-Object -First 1) }
    if ($target.Count) { [void]$target[0].Focus() }
}

# ---------------------------------------------------------------------------
# Editor (side sheet in the page): search, representation, size, section, live preview
# ---------------------------------------------------------------------------
function Get-DomeniaBoardSources {
    # Everything that can become a widget on a board: its built-in information, then the WMI queries.
    param([string]$Board,[object[]]$Layout = @())
    $present = @{}; foreach ($item in @($Layout)) { $present[[string]$item.Source + '|' + [string]$item.Key] = $true }
    $rows = New-Object System.Collections.ArrayList
    foreach ($item in @(Get-DomeniaBoardCatalog -Board $Board)) {
        $shown = $present.ContainsKey('Builtin|' + $item.Key)
        [void]$rows.Add([pscustomobject]@{ Section = 'Tableau de bord · ' + $item.Group; Name = $item.Title; Description = $item.Description; Badge = $(if ($shown) { 'affiche' } else { '' }); Source = 'Builtin'; Key = $item.Key; Kind = $item.Kind; Visual = $item.Visual; Size = $item.Size; Group = $item.Group; Search = (ConvertTo-DomeniaSearchText ($item.Title + ' ' + $item.Description + ' ' + $item.Group)) })
    }
    if ($Board -ne 'Software') {
        foreach ($probe in @(Get-DomeniaProbeCatalog)) {
            $shown = $present.ContainsKey('Probe|' + [string]$probe.Id)
            $kind = Get-DomeniaProbeKind -Probe $probe -Board $Board
            [void]$rows.Add([pscustomobject]@{ Section = 'Requetes WMI · ' + [string]$probe.Category; Name = [string]$probe.Name; Description = ([string]$probe.Class + ' (' + [string]$probe.Namespace + ')'); Badge = $(if ($shown) { 'affiche' } else { '' }); Source = 'Probe'; Key = [string]$probe.Id; Kind = $kind; Visual = (Resolve-DomeniaBoardVisual -Visual ([string]$probe.Visual) -Kind $kind); Size = ''; Group = [string]$probe.Category; Search = (ConvertTo-DomeniaSearchText ([string]$probe.Name + ' ' + [string]$probe.Category + ' ' + [string]$probe.Class)) })
        }
    }
    # Screen readers and type-ahead read an item through ToString: its name, its section, and whether it is shown.
    foreach ($row in $rows) { Add-Member -InputObject $row -MemberType ScriptMethod -Name ToString -Value { $this.Name + ', ' + $this.Section + $(if ($this.Badge) { ', deja affiche' } else { '' }) } -Force }
    return @($rows)
}
function Get-DomeniaBoardPreviewEntry {
    # Real data when the board has it, otherwise an example of the same kind.
    param([string]$Board,[string]$Source,[string]$Key,[string]$Kind)
    $state = Get-DomeniaBoardState $Board
    $item = New-DomeniaBoardItem -Source $Source -Key $Key -Visual 'Kpi'
    $resolved = Resolve-DomeniaBoardEntry -Board $Board -Item $item -State $state
    if ($null -ne $resolved.Entry -and [string]$resolved.Entry.State -ne 'Off') { return $resolved.Entry }
    return New-DomeniaBoardSample -Key $Key -Kind $Kind
}
function Show-DomeniaBoardEditor {
    # Add (with -Group preset) or modify (-Id) a widget. Handlers run while Show-DomeniaEmbeddedWindow waits in
    # this function, so its variables are in scope (they all start with $bed).
    param([string]$Board,[string]$Id = '',[string]$Group = '')
    $bedLayout = @(Get-DomeniaBoardLayout -Board $Board)
    $bedItem = $null; foreach ($bedI in $bedLayout) { if ($Id -and [string]$bedI.Id -eq $Id) { $bedItem = $bedI } }
    if ($Id -and $null -eq $bedItem) { return $false }
    $bedEditing = ($null -ne $bedItem)
    $bedNames = Get-DomeniaBoardVisualNames
    $bedSizes = Get-DomeniaBoardSizeNames
    $bedSources = @(Get-DomeniaBoardSources -Board $Board -Layout $bedLayout)
    $bedState = @{ Source = ''; Key = ''; Kind = 'Value'; DefaultTitle = ''; Loading = $false }

    $bedW = [Windows.Window]::new()
    $bedW.Title = if ($bedEditing) { 'Modifier le widget' } else { 'Ajouter un widget' }
    $bedW.Width = 900; $bedW.Height = 640
    $bedRoot = [Windows.Controls.Grid]::new()
    $bedC0 = [Windows.Controls.ColumnDefinition]::new(); $bedC0.Width = [Windows.GridLength]::new($(if ($bedEditing) { 0 } else { 330 }))
    $bedC1 = [Windows.Controls.ColumnDefinition]::new(); $bedC1.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    [void]$bedRoot.ColumnDefinitions.Add($bedC0); [void]$bedRoot.ColumnDefinitions.Add($bedC1)
    $bedR0 = [Windows.Controls.RowDefinition]::new(); $bedR0.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $bedR1 = [Windows.Controls.RowDefinition]::new(); $bedR1.Height = [Windows.GridLength]::Auto
    [void]$bedRoot.RowDefinitions.Add($bedR0); [void]$bedRoot.RowDefinitions.Add($bedR1)

    # Left: search and list of every available information.
    $bedLeft = [Windows.Controls.DockPanel]::new(); $bedLeft.Margin = [Windows.Thickness]::new(0, 0, 16, 0)
    $bedSearchHost = [Windows.Controls.Grid]::new(); $bedSearchHost.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
    [Windows.Controls.DockPanel]::SetDock($bedSearchHost, [Windows.Controls.Dock]::Top)
    $bedSearch = [Windows.Controls.TextBox]::new(); $bedSearch.MinHeight = 34; $bedSearch.Padding = [Windows.Thickness]::new(8, 6, 8, 6)
    [Windows.Automation.AutomationProperties]::SetName($bedSearch, 'Rechercher une information')
    $bedSearchHint = New-DomeniaChartText -Text 'Rechercher : disque, utilisateur, BitLocker...' -Size 12.5 -Key 'MutedColor'
    $bedSearchHint.Margin = [Windows.Thickness]::new(11, 0, 0, 0); $bedSearchHint.IsHitTestVisible = $false
    [void]$bedSearchHost.Children.Add($bedSearch); [void]$bedSearchHost.Children.Add($bedSearchHint)
    [void]$bedLeft.Children.Add($bedSearchHost)
    $bedList = [Windows.Controls.ListBox]::new()
    $bedList.BorderThickness = [Windows.Thickness]::new(0)
    $bedList.Background = [Windows.Media.Brushes]::Transparent
    $bedList.IsSynchronizedWithCurrentItem = $false
    [Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($bedList, [Windows.Controls.ScrollBarVisibility]::Disabled)
    [Windows.Controls.TextSearch]::SetTextPath($bedList, 'Name')
    [Windows.Automation.AutomationProperties]::SetName($bedList, 'Informations disponibles')
    $bedList.ItemTemplate = [Windows.Markup.XamlReader]::Parse(@'
<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <StackPanel Margin="2,5,2,5">
    <DockPanel>
      <TextBlock DockPanel.Dock="Right" Text="{Binding Badge}" FontSize="11" Foreground="{DynamicResource MutedColor}" Margin="8,0,0,0"/>
      <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" Foreground="{DynamicResource TextColor}"/>
    </DockPanel>
    <TextBlock Text="{Binding Description}" FontSize="11.5" Foreground="{DynamicResource MutedColor}" TextTrimming="CharacterEllipsis"/>
  </StackPanel>
</DataTemplate>
'@)
    $bedList.GroupStyle.Add([Windows.Markup.XamlReader]::Parse(@'
<GroupStyle xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <GroupStyle.HeaderTemplate>
    <DataTemplate>
      <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="11.5" Margin="4,12,0,4" Foreground="{DynamicResource MutedColor}"/>
    </DataTemplate>
  </GroupStyle.HeaderTemplate>
</GroupStyle>
'@))
    $bedView = [Windows.Data.ListCollectionView]::new([Collections.ArrayList]@($bedSources))
    [void]$bedView.GroupDescriptions.Add([Windows.Data.PropertyGroupDescription]::new('Section'))
    $bedList.ItemsSource = $bedView
    [void]$bedLeft.Children.Add($bedList)
    [Windows.Controls.Grid]::SetColumn($bedLeft, 0)
    if ($bedEditing) { $bedLeft.Visibility = [Windows.Visibility]::Collapsed }
    [void]$bedRoot.Children.Add($bedLeft)

    # Right: options and live preview.
    $bedRight = [Windows.Controls.StackPanel]::new()
    [Windows.Controls.Grid]::SetColumn($bedRight, 1)
    $bedForm = [Windows.Controls.Grid]::new()
    $bedFc0 = [Windows.Controls.ColumnDefinition]::new(); $bedFc0.Width = [Windows.GridLength]::new(120)
    [void]$bedForm.ColumnDefinitions.Add($bedFc0); [void]$bedForm.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    foreach ($bedI in 0..3) { $bedRow = [Windows.Controls.RowDefinition]::new(); $bedRow.Height = [Windows.GridLength]::Auto; [void]$bedForm.RowDefinitions.Add($bedRow) }
    $bedPlace = { param($Element,[int]$Row,[int]$Column) [Windows.Controls.Grid]::SetRow($Element, $Row); [Windows.Controls.Grid]::SetColumn($Element, $Column); $Element.Margin = [Windows.Thickness]::new(0, 4, 0, 4); [void]$bedForm.Children.Add($Element) }
    $bedRowLabel = 0
    foreach ($bedText in @('Titre','Representation','Taille','Section')) { $bedLabel = New-DomeniaChartText -Text $bedText -Size 12.5 -Weight Medium -Key 'TextColor'; & $bedPlace $bedLabel $bedRowLabel 0; $bedRowLabel++ }
    $bedTitle = [Windows.Controls.TextBox]::new(); $bedTitle.MinHeight = 32; $bedTitle.Padding = [Windows.Thickness]::new(6, 4, 6, 4); & $bedPlace $bedTitle 0 1
    $bedVisual = [Windows.Controls.ComboBox]::new(); $bedVisual.MinHeight = 32; & $bedPlace $bedVisual 1 1
    $bedSize = [Windows.Controls.ComboBox]::new(); $bedSize.MinHeight = 32; & $bedPlace $bedSize 2 1
    foreach ($bedK in $bedSizes.Keys) { [void]$bedSize.Items.Add([string]$bedSizes[$bedK]) }
    $bedGroup = [Windows.Controls.ComboBox]::new(); $bedGroup.MinHeight = 32; $bedGroup.IsEditable = $true; & $bedPlace $bedGroup 3 1
    foreach ($bedG in @(Get-DomeniaBoardGroups -Layout $bedLayout)) { [void]$bedGroup.Items.Add($bedG) }
    foreach ($bedC in @(Get-DomeniaBoardCatalog -Board $Board | ForEach-Object { $_.Group } | Select-Object -Unique)) { if (-not $bedGroup.Items.Contains($bedC)) { [void]$bedGroup.Items.Add($bedC) } }
    [Windows.Automation.AutomationProperties]::SetName($bedTitle, 'Titre du widget')
    [Windows.Automation.AutomationProperties]::SetName($bedVisual, 'Representation')
    [Windows.Automation.AutomationProperties]::SetName($bedSize, 'Taille')
    [Windows.Automation.AutomationProperties]::SetName($bedGroup, 'Section')
    [void]$bedRight.Children.Add($bedForm)
    $bedKindText = New-DomeniaChartText -Text '' -Size 11.5 -Key 'MutedColor'
    $bedKindText.Margin = [Windows.Thickness]::new(120, 0, 0, 10)
    [void]$bedRight.Children.Add($bedKindText)
    $bedPreviewLabel = New-DomeniaChartText -Text 'Apercu' -Size 12.5 -Weight SemiBold -Key 'TextColor'
    $bedPreviewLabel.Margin = [Windows.Thickness]::new(0, 6, 0, 6)
    [void]$bedRight.Children.Add($bedPreviewLabel)
    $bedPreview = [Windows.Controls.Border]::new()
    $bedPreview.CornerRadius = [Windows.CornerRadius]::new(14)
    $bedPreview.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'WindowBg')
    $bedPreview.Height = 320
    $bedPreview.Padding = [Windows.Thickness]::new(10)
    $bedPreviewHost = [Windows.Controls.Grid]::new()
    $bedPreview.Child = $bedPreviewHost
    [void]$bedRight.Children.Add($bedPreview)
    [void]$bedRoot.Children.Add($bedRight)

    $bedButtons = [Windows.Controls.StackPanel]::new(); $bedButtons.Orientation = 'Horizontal'; $bedButtons.HorizontalAlignment = 'Right'; $bedButtons.Margin = [Windows.Thickness]::new(0, 14, 0, 0)
    $bedCancel = [Windows.Controls.Button]::new(); $bedCancel.Content = 'Annuler'; $bedCancel.IsCancel = $true; $bedCancel.MinWidth = 110
    $bedCancel.ToolTip = 'Ferme sans rien changer.'; [Windows.Automation.AutomationProperties]::SetName($bedCancel, 'Annuler')
    $bedCancel.SetResourceReference([Windows.Controls.Control]::StyleProperty, 'SecondaryButton')
    $bedSave = [Windows.Controls.Button]::new(); $bedSave.Content = $(if ($bedEditing) { 'Enregistrer' } else { 'Ajouter' }); $bedSave.IsDefault = $true; $bedSave.MinWidth = 130; $bedSave.Margin = [Windows.Thickness]::new(10, 0, 0, 0)
    $bedSave.SetResourceReference([Windows.Controls.Control]::StyleProperty, 'RunButton')
    $bedSave.ToolTip = $(if ($bedEditing) { 'Enregistre les changements de ce widget.' } else { 'Ajoute le widget choisi au tableau de bord.' })
    [Windows.Automation.AutomationProperties]::SetName($bedSave, [string]$bedSave.Content)
    if (-not $bedEditing) { $bedSave.IsEnabled = $false }
    [void]$bedButtons.Children.Add($bedCancel); [void]$bedButtons.Children.Add($bedSave)
    [Windows.Controls.Grid]::SetRow($bedButtons, 1); [Windows.Controls.Grid]::SetColumnSpan($bedButtons, 2)
    [void]$bedRoot.Children.Add($bedButtons)
    $bedW.Content = $bedRoot

    $bedKindNames = @{ Value = 'Information textuelle : chiffre cle ou liste.'; Number = 'Mesure : jauge, chiffre cle ou liste.'; Distribution = 'Repartition : anneau, barres, histogramme, liste ou chiffre cle.'; Measure = 'Valeurs numeriques : histogramme, barres, courbe, chiffre cle ou liste.'; Series = 'Serie ordonnee : histogramme, courbe, barres, liste ou chiffre cle.'; List = 'Liste de points a verifier.'; Health = 'Score de sante : anneau ou chiffre cle.' }
    $bedRefresh = {
        if ($bedState.Loading -or -not $bedState.Key) { return }
        $bedPreviewHost.Children.Clear()
        $bedEntry = Get-DomeniaBoardPreviewEntry -Board $Board -Source $bedState.Source -Key $bedState.Key -Kind $bedState.Kind
        $bedV = 'Kpi'; foreach ($bedK in $bedNames.Keys) { if ([string]$bedNames[$bedK] -eq [string]$bedVisual.SelectedItem) { $bedV = $bedK } }
        $bedS = 'M'; foreach ($bedK in $bedSizes.Keys) { if ([string]$bedSizes[$bedK] -eq [string]$bedSize.SelectedItem) { $bedS = $bedK } }
        $bedT = $bedTitle.Text.Trim(); if (-not $bedT) { $bedT = $bedState.DefaultTitle }
        $bedCard = New-DomeniaWidgetVisual -Entry $bedEntry -Visual $bedV -Title $bedT -Size (Get-DomeniaBoardSize -Visual $bedV -Size $bedS)
        $bedFit = [Windows.Controls.Viewbox]::new(); $bedFit.StretchDirection = [Windows.Controls.StretchDirection]::DownOnly; $bedFit.Child = $bedCard
        [void]$bedPreviewHost.Children.Add($bedFit)
        Invoke-DomeniaDashboardEntrance -Panel $bedPreviewHost
    }
    $bedSelect = {
        param($Row)
        $bedState.Loading = $true
        $bedState.Source = [string]$Row.Source; $bedState.Key = [string]$Row.Key; $bedState.Kind = [string]$Row.Kind; $bedState.DefaultTitle = [string]$Row.Name
        $bedKindText.Text = [string]$bedKindNames[[string]$Row.Kind]
        $bedVisual.Items.Clear()
        $bedHasMax = ([string]$Row.Kind -in @('Number','Health'))
        foreach ($bedV in @(Get-DomeniaBoardVisuals -Kind ([string]$Row.Kind) -HasMaximum:$bedHasMax)) { [void]$bedVisual.Items.Add([string]$bedNames[$bedV]) }
        $bedWanted = if ($bedEditing) { [string]$bedItem.Visual } else { [string]$Row.Visual }
        $bedVisual.SelectedItem = [string]$bedNames[(Resolve-DomeniaBoardVisual -Visual $bedWanted -Kind ([string]$Row.Kind) -HasMaximum:$bedHasMax)]
        $bedWantedSize = if ($bedEditing) { [string]$bedItem.Size } elseif ([string]$Row.Size) { [string]$Row.Size } elseif ([string]$Row.Visual -eq 'Kpi') { 'S' } else { 'M' }
        $bedSize.SelectedItem = [string]$bedSizes[$bedWantedSize]
        $bedTitle.Text = if ($bedEditing -and [string]$bedItem.Title) { [string]$bedItem.Title } else { [string]$Row.Name }
        # An editable combo shows a value reliably through its selected item; Text only for a new section name.
        $bedWantedGroup = if ($bedEditing) { [string]$bedItem.Group } elseif ($Group) { $Group } else { [string]$Row.Group }
        $bedMatch = @($bedGroup.Items | Where-Object { [string]$_ -eq $bedWantedGroup } | Select-Object -First 1)
        if ($bedMatch.Count) { $bedGroup.SelectedItem = $bedMatch[0] } else { $bedGroup.SelectedItem = $null; $bedGroup.Text = $bedWantedGroup }
        $bedState.Loading = $false
        & $bedRefresh
    }
    $bedSearch.Add_TextChanged({
        $script:DomeniaBoardEditorQuery = ConvertTo-DomeniaSearchText $bedSearch.Text.Trim()
        $bedSearchHint.Visibility = if ($bedSearch.Text) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
        $bedView.Filter = if ($script:DomeniaBoardEditorQuery) { [Predicate[object]]{ param($o) $words = @($script:DomeniaBoardEditorQuery -split '\s+' | Where-Object { $_ }); foreach ($word in $words) { if (([string]$o.Search).IndexOf($word) -lt 0) { return $false } }; return $true } } else { $null }
    })
    $bedList.Add_SelectionChanged({
        if ($null -ne $bedList.SelectedItem) { $bedSave.IsEnabled = $true; & $bedSelect $bedList.SelectedItem; return }
        if ($bedEditing) { return }
        # Filtered out of the list: nothing is chosen any more.
        $bedState.Key = ''; $bedSave.IsEnabled = $false; $bedPreviewHost.Children.Clear()
        $bedKindText.Text = 'Choisissez une information dans la liste.'
    })
    $bedVisual.Add_SelectionChanged({ & $bedRefresh })
    $bedSize.Add_SelectionChanged({ & $bedRefresh })
    $bedTitle.Add_TextChanged({ & $bedRefresh })
    $bedSave.Add_Click({
        if (-not $bedState.Key) { return }
        $bedV = 'Kpi'; foreach ($bedK in $bedNames.Keys) { if ([string]$bedNames[$bedK] -eq [string]$bedVisual.SelectedItem) { $bedV = $bedK } }
        $bedS = 'M'; foreach ($bedK in $bedSizes.Keys) { if ([string]$bedSizes[$bedK] -eq [string]$bedSize.SelectedItem) { $bedS = $bedK } }
        $bedT = $bedTitle.Text.Trim(); if ($bedT -ceq $bedState.DefaultTitle) { $bedT = '' }
        $bedG = ([string]$bedGroup.Text).Trim(); if (-not $bedG) { $bedG = 'Mes widgets' }
        $bedNow = @(Get-DomeniaBoardLayout -Board $Board)
        if ($bedEditing) {
            Set-DomeniaBoardLayout -Board $Board -Layout @(Update-DomeniaBoardItem -Layout $bedNow -Id ([string]$bedItem.Id) -Changes @{ Visual = $bedV; Size = $bedS; Title = $bedT; Group = $bedG }) -Undo 'Widget modifie' -Highlight ([string]$bedItem.Id)
            (Get-DomeniaBoardState $Board).LastId = [string]$bedItem.Id
        } else {
            $bedNew = New-DomeniaBoardItem -Source $bedState.Source -Key $bedState.Key -Visual $bedV -Size $bedS -Group $bedG -Title $bedT
            Set-DomeniaBoardLayout -Board $Board -Layout @(Add-DomeniaBoardItem -Layout $bedNow -Item $bedNew) -Undo 'Widget ajoute' -Highlight ([string]$bedNew.Id)
            (Get-DomeniaBoardState $Board).LastId = [string]$bedNew.Id
        }
        Set-DomeniaSurfaceResult $bedW $true
    })
    # Runs inside Show-DomeniaEmbeddedWindow after its theme pass (which recolours plain borders and texts):
    # the editor's own colours come back, then the first preview is built with its real colours.
    Register-DomeniaSurfaceReady $bedW {
        $bedSearchHint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MutedColor')
        $bedKindText.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MutedColor')
        $bedCancel.SetResourceReference([Windows.Controls.Control]::StyleProperty, 'SecondaryButton')
        $bedList.Background = [Windows.Media.Brushes]::Transparent
        if ($bedEditing) {
            $bedRowItem = @($bedSources | Where-Object { [string]$_.Source -eq [string]$bedItem.Source -and [string]$_.Key -eq [string]$bedItem.Key } | Select-Object -First 1)
            if ($bedRowItem.Count) { & $bedSelect $bedRowItem[0] }
            [void]$bedTitle.Focus()
        } else {
            $bedFirst = @($bedSources | Where-Object { -not [string]$_.Badge -and ((-not $Group) -or [string]$_.Group -eq $Group) } | Select-Object -First 1)
            if (-not $bedFirst.Count) { $bedFirst = @($bedSources | Select-Object -First 1) }
            if ($bedFirst.Count) { $bedList.SelectedItem = $bedFirst[0]; $bedList.ScrollIntoView($bedFirst[0]) }
            [void]$bedSearch.Focus()
        }
    }
    return [bool](Show-DomeniaEmbeddedWindow $bedW)
}

# ---------------------------------------------------------------------------
# Query results and launching (read-only, scope rules unchanged)
# ---------------------------------------------------------------------------
function Get-DomeniaWidgetResults {
    param(
        [string]$Board,
        [string]$ProbeId
    )
    $results = @()
    if ($null -eq $script:FleetObservations) { return @() }
    if ($Board -eq 'Fleet') {
        $scope = if ($null -ne $script:FleetLast) { [string]$script:FleetLast.Scope } else { '' }
        foreach ($dn in @($script:FleetObservations.Keys)) {
            $obs = $script:FleetObservations[$dn]
            if ($null -eq $obs -or $null -eq $obs.Probes) { continue }
            if (-not [string]::IsNullOrWhiteSpace($scope) -and -not ([string]$dn).ToLowerInvariant().EndsWith(',' + $scope.ToLowerInvariant())) { continue }
            if ($obs.Probes.PSObject.Properties.Name -contains $ProbeId) {
                $res = $obs.Probes.$ProbeId
                if ($null -ne $res) { $results += $res }
            }
        }
    } elseif ($Board -eq 'Computer') {
        if ($null -eq $script:SelectedObject) { return @() }
        $dn = [string]$script:SelectedObject.DN
        if ([string]::IsNullOrWhiteSpace($dn)) { return @() }
        $dnLower = $dn.ToLowerInvariant()
        if ($script:FleetObservations.ContainsKey($dnLower)) {
            $obs = $script:FleetObservations[$dnLower]
            if ($null -ne $obs -and $null -ne $obs.Probes -and $obs.Probes.PSObject.Properties.Name -contains $ProbeId) {
                $res = $obs.Probes.$ProbeId
                if ($null -ne $res) { $results += $res }
            }
        }
    }
    return $results
}
function Start-DomeniaWidgetProbe {
    # Runs the queries of the board's widgets: an OU (never the whole domain) or the selected workstation.
    param([string]$Board)
    $probeIds = @(Get-DomeniaBoardLayout -Board $Board | Where-Object { [string]$_.Source -eq 'Probe' } | ForEach-Object { [string]$_.Key } | Select-Object -Unique)
    if (-not $probeIds.Count) { Set-Status 'Aucune requete WMI sur ce tableau de bord : ajoutez un widget de requete.' 'WARN'; return }
    $probes = ConvertTo-DomeniaProbePayload -Ids $probeIds
    if ($Board -eq 'Fleet') {
        $scope = if ($null -ne $script:FleetLast) { [string]$script:FleetLast.Scope } else { '' }
        if ([string]::IsNullOrWhiteSpace($scope) -or $scope -eq [string]$script:Conn.BaseDn) { Set-Status 'Choisissez une OU : jamais le domaine entier.' 'WARN'; return }
        $epoch = if ($null -ne $script:FleetLast.PSObject.Properties['Epoch']) { [long]$script:FleetLast.Epoch } else { -1L }
        if ($epoch -ne [long]$script:SessionEpoch -or $scope -ne (Get-DomeniaFleetScope)) { Set-Status 'Actualisez la vue du parc : le perimetre a change depuis le dernier calcul.' 'WARN'; return }
        $targets = @($script:FleetLast.Targets)
        if (-not $targets.Count) { Set-Status 'Aucun poste dans le perimetre.' 'WARN'; return }
        $ouName = ($scope -split '(?<!\\),')[0] -replace '^OU=',''
        Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel $ouName -Probes $probes
    } elseif ($Board -eq 'Computer') {
        if ($null -eq $script:SelectedObject) { Set-Status 'Aucun poste selectionne.' 'WARN'; return }
        $so = $script:SelectedObject
        $target = [pscustomobject]@{ name = $so.Name; distinguished_name = $so.DN; object_guid = [string]$so.Safety.Guid }
        Start-DomeniaOnlinePark -ScopeTargets @($target) -ScopeLabel ([string]$so.Name) -Probes $probes
    }
}
