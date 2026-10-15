# Dashboards made of widgets (decision David 2026-10-07): every tile and chart of the workstation, fleet and
# software dashboards is a widget. Each one can be edited (title, representation allowed by its kind of data,
# size, section), moved (drag and drop or menu), removed (with undo) and new ones come from the built-in catalog
# or the ready-made WMI queries. Providers compute the data (Domenia-Board*.ps1), this module lays it out.
# Handlers read their sender's Tag or capture a callable explicitly before GetNewClosure.

$script:DomeniaBoardStates = @{}
$script:DomeniaBoardDrag = $null
$script:DomeniaBoardPendingDrop = $null
# Per-widget collections (decision David 2026-10-14): board|id -> activity shown on the widget, the widgets waiting
# for the park run in progress, and the light protected timer that follows them.
$script:DomeniaWidgetCollects = @{}
$script:DomeniaWidgetCollectQueue = New-Object System.Collections.ArrayList
$script:DomeniaWidgetCollectTimer = $null
# Saved queries of the Query widgets by Id, built once per library (Get-DomeniaWidgetRecipe): a board redraw never
# parses nor compiles the whole library again.
$script:DomeniaWidgetRecipeCache = $null

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
        # UndoStack: the last ten layout changes (FI-11); UndoLayout and UndoText mirror its top for the toolbar.
        $script:DomeniaBoardStates[$Board] = @{ Board = $Board; Data = $null; Editing = $false; UndoLayout = $null; UndoText = ''; UndoStack = (New-Object System.Collections.ArrayList); Highlight = ''; EmptyText = ''; Notice = ''; LastId = ''; RenderPending = $false; RenderContext = ''; RenderPanel = $null; DataAtUtc = $null }
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
function Sync-DomeniaBoardUndo {
    # The toolbar shows the top of the undo stack.
    param($State)
    if ($null -eq $State.UndoStack) { $State.UndoStack = New-Object System.Collections.ArrayList }
    if ($State.UndoStack.Count) { $top = $State.UndoStack[$State.UndoStack.Count - 1]; $State.UndoLayout = @($top.Layout); $State.UndoText = [string]$top.Text }
    else { $State.UndoLayout = $null; $State.UndoText = '' }
}
function Clear-DomeniaBoardUndo {
    # Forgets the layout changes that can be undone (another object selected, layout replaced without undo).
    param([string]$Board)
    $state = Get-DomeniaBoardState $Board
    $state.UndoStack = New-Object System.Collections.ArrayList
    Sync-DomeniaBoardUndo $state
}
function Set-DomeniaBoardLayout {
    # Saves the layout, keeps the previous one for "Annuler" when asked, redraws without the entrance motion.
    # -KeepUndo: the change comes from the undo stack itself (Annuler, Ctrl+Z), whose remaining steps stay.
    param([string]$Board,[object[]]$Layout = @(),[string]$Undo = '',[string]$Highlight = '',[switch]$KeepUndo)
    $state = Get-DomeniaBoardState $Board
    $current = @(Get-DomeniaBoardLayout -Board $Board)
    $json = ConvertTo-DomeniaBoardLayoutJson -Layout $Layout
    # A change that changes nothing (first widget moved left...) is neither saved nor offered for undo.
    $legacy = ($Board -in @('Computer','Fleet') -and [string](Get-DomeniaSetting -Name ('Widgets.' + $Board) -Default ''))
    if (-not $legacy -and [string](Get-DomeniaSetting -Name ('Dashboard.' + $Board + '.Layout') -Default '') -and $json -ceq (ConvertTo-DomeniaBoardLayoutJson -Layout $current)) { return }
    if ($null -eq $state.UndoStack) { $state.UndoStack = New-Object System.Collections.ArrayList }
    if ($Undo) {
        [void]$state.UndoStack.Add([pscustomobject]@{ Layout = @($current); Text = $Undo })
        while ($state.UndoStack.Count -gt 10) { $state.UndoStack.RemoveAt(0) }
    } elseif (-not $KeepUndo) { $state.UndoStack.Clear() }
    Sync-DomeniaBoardUndo $state
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
function Get-DomeniaBoardRenderContext {
    # A deferred render belongs to one session and one object/OU, never to the next selection.
    param([string]$Board)
    if ($Board -eq 'Fleet') { return ([string]$script:SessionEpoch + '|Fleet|' + [string](Get-DomeniaFleetScope).Key) }
    return ([string]$script:SessionEpoch + '|' + $Board + '|' + [string]$script:SelectedObject.Type + '|' + [string]$script:SelectedObject.DN + '|' + [string]$script:SelectedObject.Safety.Guid)
}
function Resume-DomeniaBoardRender {
    param([string]$Board,$Panel)
    if ($null -eq $Panel -or -not $Panel.IsVisible) { return }
    $state = Get-DomeniaBoardState $Board
    if (-not $state.RenderPending) { return }
    $state.RenderPending = $false
    if ([string]$state.RenderContext -cne (Get-DomeniaBoardRenderContext -Board $Board)) {
        # The current selection will supply its own data. Never flash the previous OU/object.
        $state.Data = $null
        $Panel.Children.Clear()
        return
    }
    try { Show-DomeniaBoard -Board $Board -Quiet }
    catch { $state.RenderPending = $true; Write-AppLog ('Tableau de bord différé : ' + $_.Exception.Message) 'WARN' }
}
function Show-DomeniaBoard {
    # Draws a board from its layout and the last data of its provider. -Data replaces the data (new reading),
    # -Quiet skips the entrance motion (layout edits).
    param([ValidateSet('Computer','Fleet','Software')][string]$Board,$Data = $null,[switch]$Quiet,[string]$EmptyText = '',[switch]$DeferIfHidden)
    $state = Get-DomeniaBoardState $Board
    # New data never removes the undo of a layout change (FI-11): a background recalculation of Accueil keeps
    # "Annuler"; Clear-DomeniaDashboards forgets it when another object is selected.
    # DataAtUtc: time of this local calculation, shown by the explanation of a figure (point 6).
    if ($null -ne $Data) { $state.Data = $Data; $state.DataAtUtc = [datetime]::UtcNow; $state.Notice = ''; $state.EmptyText = '' }
    if ($EmptyText) { $state.EmptyText = $EmptyText }
    $panel = Get-DomeniaControl (Get-DomeniaBoardPanelName $Board)
    if ($null -eq $panel) { return }
    if ($DeferIfHidden -and -not $panel.IsVisible) {
        $state.RenderPending = $true
        $state.RenderContext = Get-DomeniaBoardRenderContext -Board $Board
        if (-not [object]::ReferenceEquals($state.RenderPanel,$panel)) {
            # Capture the callable: handlers execute outside the launcher's private script scope.
            $resume = ${function:Resume-DomeniaBoardRender}; $boardName = $Board
            $panel.Add_IsVisibleChanged(({ param($sender,$eventArgs) if ([bool]$eventArgs.NewValue) { & $resume -Board $boardName -Panel $sender } }.GetNewClosure()))
            $state.RenderPanel = $panel
        }
        return
    }
    $state.RenderPending = $false
    # FI-04: only the visible workstation board needs this local observation read.
    if ($Board -eq 'Computer') { $script:DomeniaComputerQueryRecords=$null; try { [void](Request-DomeniaSelectedObservation) } catch { } }
    # Ctrl+Z on the board undoes the last layout change (text boxes keep their own undo).
    if (-not ($panel.Tag -is [hashtable] -and $panel.Tag.ContainsKey('UndoKey'))) {
        $panel.Tag = @{ UndoKey = $true; Board = $Board }
        $panel.Add_PreviewKeyDown({ param($s,$e) if (($e.Key -eq [System.Windows.Input.Key]::Z) -and ([System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) -and ($e.OriginalSource -isnot [System.Windows.Controls.Primitives.TextBoxBase])) { $board = [string]$s.Tag['Board']; if ((Get-DomeniaBoardState $board).UndoStack.Count) { Invoke-DomeniaBoardAction -Tag @{ Board = $board; Action = 'Undo' }; $e.Handled = $true } } })
    }
    if (-not (($panel.Tag -is [hashtable]) -and ($panel.Tag.ContainsKey('FitKey')))) {
        # Point 80: crisp edges at fractional DPI (125, 150 %), and widgets refitted when the page width changes.
        $panel.Tag['FitKey'] = $true
        $panel.UseLayoutRounding = $true
        $panel.Add_SizeChanged({ param($s,$e) if ($e.WidthChanged) { Update-DomeniaBoardFit -Panel $s } })
    }
    $panel.Children.Clear()
    $layout = @(Get-DomeniaBoardLayout -Board $Board)
    [void]$panel.Children.Add((New-DomeniaBoardToolbar -Board $Board -Layout $layout -State $state))
    # Live: widgets that show a figure or a collection state; a paused widget keeps its place but is not a reading,
    # so a board holding only paused widgets still says that it has no data yet.
    $live = 0
    foreach ($group in @(Get-DomeniaBoardGroups -Layout $layout)) {
        $section = New-Object System.Windows.Controls.StackPanel
        $wrap = New-DomeniaDashboardSection $section $group (Get-DomeniaBoardGroupSubtitle -Group $group -Board $Board)
        $wrap.AllowDrop = $true
        $wrap.Background = [System.Windows.Media.Brushes]::Transparent
        $wrap.Tag = @{ Board = $Board; Group = $group }
        $wrap.Add_DragOver({ param($s,$e) Invoke-DomeniaBoardAutoScroll $s $e; if ($e.Data.GetDataPresent('DomeniaBoardWidget')) { $e.Effects = [System.Windows.DragDropEffects]::Move } else { $e.Effects = [System.Windows.DragDropEffects]::None }; $e.Handled = $true })
        $wrap.Add_Drop({ param($s,$e) $id = [string]$e.Data.GetData('DomeniaBoardWidget'); if ($id) { Request-DomeniaBoardDrop -Board $s.Tag.Board -Id $id -Group $s.Tag.Group }; $e.Handled = $true })
        $count = 0
        $groupItems = @($layout | Where-Object { [string]$_.Group -eq $group })
        # SP-18: once the workstation board holds a reading, a section partly filled keeps a compact place for each
        # widget this inventory did not fill, saying why and offering its collection (decision David 2026-10-14).
        # Before any reading, and for a section left empty, only paused or collecting widgets are drawn.
        $partial = $false
        if (($Board -eq 'Computer') -and (-not $state.Editing) -and ($null -ne $state.Data) -and ($null -ne $state.Data.Entries)) {
            $partial = (@($groupItems | Where-Object { ([string]$_.Source -eq 'Probe') -or $state.Data.Entries.ContainsKey([string]$_.Key) }).Count -gt 0)
        }
        foreach ($item in $groupItems) {
            $element = New-DomeniaBoardWidget -Board $Board -Item $item -State $state -Placeholder:$partial
            if ($null -ne $element) { [void]$wrap.Children.Add($element); $count++; if (-not (Test-DomeniaBoardItemPaused -Item $item)) { $live++ } }
        }
        $hint = ''
        if ($null -ne $state.Data -and $null -ne $state.Data.Hints -and $state.Data.Hints.ContainsKey($group)) { $hint = [string]$state.Data.Hints[$group] }
        if ($state.Editing) { [void]$wrap.Children.Add((New-DomeniaBoardAddTile -Board $Board -Group $group)) }
        elseif (-not $count -and -not $hint) { continue }
        if (-not $count -and $hint) {
            $note = New-DomeniaBoardHint -Board $Board -Text $hint -Action (Get-DomeniaBoardHintAction -State $state -Group $group)
            $wrap.Parent.Children.Insert(1 + [int]($wrap.Parent.Children.Count -gt 2), $note)
        }
        Optimize-DomeniaBoardRow $wrap
        $block = $wrap.Parent
        $section.Children.Remove($block)
        $block.Margin = [System.Windows.Thickness]::new(0, $(if ($panel.Children.Count -gt 1) { 20 } else { 8 }), 0, 0)
        [void]$panel.Children.Add($block)
    }
    if ((-not $live) -and (-not $state.Editing)) {
        $none = -not @($layout).Count
        $message = if ($none) { 'Tous les widgets ont ete retires. Ajoutez-en un, ou revenez a la disposition par defaut avec Personnaliser.' } elseif ($state.EmptyText) { $state.EmptyText } else { 'Les widgets se remplissent apres la premiere lecture.' }
        $empty = New-DomeniaChartEmpty -Width 520 -Height 200 -Title $(if ($none) { 'Aucun widget' } else { 'Pas encore de donnees' }) -Message $message
        $empty.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        [void]$panel.Children.Add($empty)
    }
    Update-DomeniaBoardFit -Panel $panel
    if (-not $Quiet) { Invoke-DomeniaDashboardEntrance -Panel $panel }
    elseif ($state.Highlight) {
        $target = Find-DomeniaBoardHolder $panel $state.Highlight
        $state.Highlight = ''
        if ($null -ne $target) { Invoke-DomeniaDashboardEntrance -Panel $target }
    }
}
function Get-DomeniaBoardHolderList {
    # Every widget holder of a board (Tag with Chrome), whatever the rows and stacks that group them.
    param($Node)
    if ($Node -isnot [System.Windows.Controls.Panel]) { return }
    foreach ($child in @($Node.Children)) {
        if (($child -is [System.Windows.FrameworkElement]) -and ($child.Tag -is [hashtable]) -and ($child.Tag.ContainsKey('Chrome'))) { Write-Output -NoEnumerate $child }
        else { Get-DomeniaBoardHolderList $child }
    }
}
function Update-DomeniaBoardFit {
    # Point 80: a widget wider than the board (high DPI, narrow window) is scaled down as a whole by
    # Get-DomeniaBoardFitScale instead of being cut by the page edge; it gets its size back when the page widens.
    param($Panel)
    if ($null -eq $Panel) { return }
    $available = [double]$Panel.ActualWidth - 2
    if ($available -le 0) { return }
    foreach ($holder in @(Get-DomeniaBoardHolderList $Panel)) {
        if ($holder.Children.Count -lt 1) { continue }
        $card = $holder.Children[0]
        if (($card -isnot [System.Windows.FrameworkElement]) -or ([double]::IsNaN([double]$card.Width))) { continue }
        $scale = Get-DomeniaBoardFitScale -Needed ([double]$card.Width + $card.Margin.Left + $card.Margin.Right) -Available $available
        if ($scale -lt 1.0) { $holder.LayoutTransform = New-Object System.Windows.Media.ScaleTransform ($scale, $scale) }
        elseif (($null -ne $holder.LayoutTransform) -and ($holder.LayoutTransform -is [System.Windows.Media.ScaleTransform])) { $holder.LayoutTransform = [System.Windows.Media.Transform]::Identity }
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
        'Releves WMI' = 'Analyser la liste, dans Rechercher'
        'Synthese' = 'Calculee sur la liste chargee'
        'Santé' = 'Part des postes sans problème et points à vérifier'
        'Inventaire du périmètre' = 'Comptes ordinateur de lʼannuaire, base autonome locale'
        'Sécurité' = 'LAPS lu avec la base, BitLocker lu sur demande'
        'Versions de Windows' = 'operatingSystemVersion et fins de service'
        'Répartition' = 'Systèmes, activité et unités dʼorganisation'
        'Relevés des postes' = 'Observations de moins de 30 jours, depuis Rechercher'
        'Évolution' = 'Instantanés quotidiens locaux de lʼOU affichée'
    }
    if ($known.ContainsKey($Group)) { return $known[$Group] }
    return ''
}
function Get-DomeniaBoardHintAction {
    # Action offered under the hint of an empty section ({Id; Text; Tip; Link}), $null when the provider gives none.
    param($State,[string]$Group)
    if (($null -eq $State) -or ($null -eq $State.Data)) { return $null }
    $property = $State.Data.PSObject.Properties['HintActions']
    if (($null -eq $property) -or ($null -eq $property.Value) -or (-not $property.Value.ContainsKey($Group))) { return $null }
    return $property.Value[$Group]
}
function New-DomeniaBoardHint {
    # Hint of an empty section and, under it, the button of the existing action that fills it (decision David
    # 2026-10-08, SP-17): nothing runs without that click. On the home overview only a link to Rechercher is offered.
    param([string]$Board,[string]$Text,$Action = $null)
    $note = New-DomeniaChartText -Text $Text -Size 12.5 -Key 'MutedColor'
    if (($null -eq $Action) -or (-not [string]$Action.Id)) { $note.Margin = [System.Windows.Thickness]::new(7, 2, 7, 6); return $note }
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(7, 2, 7, 8)
    [void]$panel.Children.Add($note)
    if ([bool]$Action.Link) {
        $line = New-Object System.Windows.Controls.TextBlock
        $line.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0); $line.FontSize = 12.5
        $link = New-Object System.Windows.Documents.Hyperlink
        [void]$link.Inlines.Add([string]$Action.Text)
        $link.ToolTip = [string]$Action.Tip
        $link.Tag = @{ Board = $Board; Id = [string]$Action.Id }
        $link.Add_Click({ param($s,$e) Invoke-DomeniaBoardEntryAction -Board ([string]$s.Tag['Board']) -Id ([string]$s.Tag['Id']) })
        [void]$line.Inlines.Add($link)
        [System.Windows.Automation.AutomationProperties]::SetName($line, [string]$Action.Text)
        [void]$panel.Children.Add($line)
        return $panel
    }
    $button = New-DomeniaBoardButton '' ([string]$Action.Text) ([string]$Action.Tip) @{ Board = $Board; Action = 'EntryAction'; Value = [string]$Action.Id }
    $button.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    $button.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    # The state of the control it stands for (workstation selected, task running...) is checked on the click: the board
    # is often drawn while a reading still holds that control disabled.
    [void]$panel.Children.Add($button)
    return $panel
}
function Get-DomeniaBoardActionControl {
    # Existing button of the page that an action of a board stands for; $null for a route.
    param([string]$Id)
    $name = switch ($Id) { 'InventoryQuick' { 'BtnDashboardInventory' } 'InventoryFull' { 'BtnDashboardInventoryDeep' } 'LoadSoftware' { 'BtnLoadSoftware' } default { '' } }
    if (-not $name) { return $null }
    return (Get-DomeniaControl $name)
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
    $button.Add_Click({ param($s,$e) Invoke-DomeniaBoardAction -Tag $s.Tag; $e.Handled=$true })
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
    $buttons = New-Object System.Windows.Controls.WrapPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    foreach($row in 0..1){$definition=[Windows.Controls.RowDefinition]::new();$definition.Height=[Windows.GridLength]::Auto;[void]$bar.RowDefinitions.Add($definition)}
    [System.Windows.Controls.Grid]::SetColumn($buttons, 0);[System.Windows.Controls.Grid]::SetColumnSpan($buttons, 2);[System.Windows.Controls.Grid]::SetRow($buttons, 1);$buttons.HorizontalAlignment='Right'
    $probes = @(Select-DomeniaActiveBoardItems -Layout $Layout | Where-Object { [string]$_.Source -in @('Probe','Query') }).Count
    # Fleet queries run from Rechercher (Analyser la liste): the overview only displays (decision David 2026-10-08).
    if ($probes -and $Board -eq 'Computer') { [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE72C) 'Actualiser les requetes' 'Execute les requetes WMI des widgets (lecture seule) sur le perimetre, avec confirmation.' @{ Board = $Board; Action = 'Probe' })) }
    if($Board -eq 'Fleet'){[void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE9D9) 'Analyser la vue' 'Comparer les relevés et ouvrir les tableaux croisés avec leurs postes.' @{Board=$Board;Action='FleetAnalysis'}))}
    if($Board -in @('Fleet','Computer')){[void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE713) 'Règles de santé' 'Activer les contrôles, régler les seuils ou gérer vos alertes.' @{Board=$Board;Action='HealthRules'}))}
    if($Board -in @('Fleet','Computer')){[void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE8A1) 'Atelier' 'Créer une requête réutilisable et choisir où lʼafficher.' @{ Board=$Board;Action='Workshop' }))}
    [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE710) 'Ajouter un widget' 'Choisir une information du tableau de bord ou une requete prete a l emploi.' @{ Board = $Board; Action = 'Add'; Value = '' }))
    if ($State.Editing) {
        [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE777) 'Par defaut' 'Revient a la disposition livree (annulable).' @{ Board = $Board; Action = 'Reset' }))
        [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE73E) 'Terminer' 'Quitte la personnalisation.' @{ Board = $Board; Action = 'Customize' } 'RunButton'))
    } else {
        [void]$buttons.Children.Add((New-DomeniaBoardButton ([string][char]0xE70F) 'Personnaliser' 'Déplacer, redimensionner, modifier ou retirer les widgets.' @{ Board = $Board; Action = 'Customize' }))
    }
    [void]$bar.Children.Add($buttons)
    $left = New-Object System.Windows.Controls.StackPanel
    $left.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $left.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [Windows.Controls.Grid]::SetColumnSpan($left,2);[Windows.Controls.Grid]::SetRow($left,0)
    $say = { param([string]$Text) $line = New-DomeniaChartText -Text $Text -Size 12.5 -Key 'MutedColor' -OneLine; [void]$left.Children.Add($line) }
    if ($State.UndoText -and $null -ne $State.UndoLayout) {
        & $say ([string]$State.UndoText + '.')
        $undo = New-DomeniaBoardButton ([string][char]0xE7A7) 'Annuler' 'Revient a la disposition precedente.' @{ Board = $Board; Action = 'Undo' }
        $undo.Margin = [System.Windows.Thickness]::new(10, 0, 0, 0)
        [void]$left.Children.Add($undo)
    } elseif ($State.Notice) {
        & $say ([string]$State.Notice)
    } elseif ($State.Editing) {
        & $say 'Glissez un widget ou utilisez Alt+flèches pour le déplacer, Alt+Maj+flèches pour sa taille, Suppr pour le retirer ; clic droit ou Maj+F10 pour ses options.'
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
    } elseif([string]$Item.Source -eq 'Query' -and $Board -in @('Fleet','Computer')) {
        $entry=if($Board -eq 'Computer'){Get-DomeniaComputerQueryBoardEntry -Id ([string]$Item.Key) -Visual ([string]$Item.Visual)}else{Get-DomeniaQueryBoardEntry -Id ([string]$Item.Key) -Visual ([string]$Item.Visual)};$kind=[string]$entry.Kind;$name=[string]$entry.Title
    } else {
        $probe = Get-DomeniaProbe -Id ([string]$Item.Key)
        $kind = Get-DomeniaProbeKind -Probe $probe -Board $Board
        if ($null -ne $probe) {
            $name = [string]$probe.Name
            if($Board -eq 'Fleet'){
                $queryState=$script:DomeniaQueryState;$cacheKey=[string]$Item.Key+'|'+[string]$Item.Visual
                if($null -ne $queryState -and $queryState.SnapshotKey -eq [string]$script:FleetQuerySnapshotKey -and $null -ne $queryState.ProbeWidgets -and $queryState.ProbeWidgets.ContainsKey($cacheKey)){$entry=$queryState.ProbeWidgets[$cacheKey]}
                else{
                    $entry=New-DomeniaBoardEntry -Key ([string]$Item.Key) -Kind $kind -Value 'À calculer' -Detail 'Agrégation locale en arrière-plan.' -State Off
                    if($null -ne $queryState -and -not $queryState.Busy){Request-DomeniaQueryEvaluation}
                }
            }else{
            $results = @(Get-DomeniaWidgetResults -Board $Board -ProbeId ([string]$Item.Key))
            $measured = if ($results.Count) { Measure-DomeniaWidgetData -Probe $probe -Results $results -Visual ([string]$Item.Visual) } else { $null }
            $entry = ConvertFrom-DomeniaProbeMeasure -Probe $probe -Measured $measured -Board $Board -Key ([string]$Item.Key)
            if ($results.Count) {
                $coverage = Get-DomeniaWidgetCoverage -Board $Board -ProbeId ([string]$Item.Key)
                if ($null -ne $coverage) {
                    $entry.Detail = (@([string]$entry.Detail, [string]$coverage.Text) | Where-Object { $_ }) -join ' · '
                    # The coverage ('19 postes analysés sur 26, le 08/10') is the subtitle of a fleet chart (CO-16).
                    if (($Board -eq 'Fleet') -and ($null -ne $entry.PSObject.Properties['Subtitle'])) { $entry.Subtitle = [string]$coverage.Text }
                    if ([bool]$coverage.Old) { $entry.State = 'Off' }
                }
            }
            }
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
function Get-DomeniaBoardSelectHandler {
    # Only software charts filter their source list; Fleet details use an explicit chrome button.
    param([string]$Board,$Item=$null)
    if ($Board -ne 'Software') { return $null }
    return { param($Select) Request-DomeniaSoftwareChartFilter -Select $Select }
}
function New-DomeniaWidgetVisual {
    # A board entry drawn with one representation at one size.
    param($Entry,[string]$Visual,[string]$Title,$Size,[string]$Board = '',[scriptblock]$OnSelect = $null)
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
    # Line under the title of a chart ('19 postes', CO-16); entries made before it have none.
    $subtitle = ''; $subtitleProperty = $Entry.PSObject.Properties['Subtitle']; if ($null -ne $subtitleProperty) { $subtitle = [string]$subtitleProperty.Value }
    $badge = ''; $badgeProperty = $Entry.PSObject.Properties['Badge']; if ($null -ne $badgeProperty) { $badge = [string]$badgeProperty.Value }
    $action = $null; $actionProperty = $Entry.PSObject.Properties['Action']; if ($null -ne $actionProperty) { $action = $actionProperty.Value }
    if (-not $value -and $items.Count -and [string]$Entry.Kind -ne 'List') {
        $top = @($items | Where-Object { $null -ne $_.PSObject.Properties['Value'] } | Sort-Object { [double]$_.Value } -Descending | Select-Object -First 1)
        if ($top.Count) { $value = [string]$top[0].Label; $total = 0.0; foreach ($i in $items) { try { $total += [double]$i.Value } catch { } }; if ($total -gt 0 -and -not $detail) { $detail = [string][Math]::Round(100.0 * [double]$top[0].Value / $total) + ' % du total' } }
    }
    switch ($Visual) {
        'Gauge' {
            $maximum = 100.0; if ($null -ne $Entry.Maximum -and [double]$Entry.Maximum -gt 0) { $maximum = [double]$Entry.Maximum }
            # CO-14: the ring takes the state of the entry, computed with the shared thresholds.
            return New-DomeniaGauge -Title $Title -Value ([double]$Entry.Number) -Maximum $maximum -Unit $unit -LowIsBad:([bool]$Entry.LowIsBad) -Width $w -Height $h -Caption $detail -State ([string]$Entry.State)
        }
        'Pie' { return New-DomeniaDonutChart -Title $Title -Items $items -Width $w -Height $h -CenterText ([string]$Entry.CenterText) -OnSelect $OnSelect }
        'Bar' { return New-DomeniaBarChart -Title $Title -Items $items -Width $w -Height $h -Top 12 -GroupOverflow:($Board -eq 'Fleet' -and [string]$Entry.Kind -in @('Distribution','Series') -and -not $unit) -Unit $(if ($unit) { ' ' + $unit } else { '' }) -Subtitle $subtitle -OnSelect $OnSelect }
        'Column' { return New-DomeniaColumnChart -Title $Title -Items $items -Width $w -Height $h -Subtitle $subtitle -OnSelect $OnSelect }
        'Line' { return New-DomeniaLineChart -Title $Title -Points $items -Width $w -Height $h -Subtitle $subtitle }
        'Text' {
            # One workstation: its values only (a count of 1 next to each value says nothing).
            $listed = if ([string]$Entry.Kind -eq 'List') { @() } elseif ([string]$Entry.Kind -eq 'Value') { @($items | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Label } }) } else { $items }
            if ([string]$Entry.Kind -eq 'Value') { $min = [Math]::Min($min, 118.0) }
            return New-DomeniaListCard -Title $Title -Subtitle $detail -Items $listed -Width $w -Height $h -MinHeight $min -Unit $unit -Fallback $value
        }
        'List' { return New-DomeniaAttentionCard -Title $Title -Items $items -Width $w -MinHeight $min -Board $Board }
        'Health' { if($null -eq $Entry.Number){return New-DomeniaKpiTile -Title $Title -Value $value -Detail ((@($detail,$badge)|Where-Object{$_}) -join ' · ') -Width $w -Height $h -State Off};return New-DomeniaHealthCard -Title $Title -Score ([double]$Entry.Number) -Verdict $value -Detail $detail -State $(if ([string]$Entry.State) { [string]$Entry.State } else { 'Ok' }) -Width $w -Height $h -Badge $badge -Action $action -Board $Board }
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
    $button.Add_Click({ param($s,$e) Invoke-DomeniaBoardAction -Tag $s.Tag; $e.Handled=$true })
    return $button
}
function New-DomeniaBoardMenu {
    # Right-click menu of a widget (Maj+F10 from the keyboard): refresh, explain, pause or resume its measurement,
    # modify, representation, size, move, remove.
    param([string]$Board,$Item,[string]$Kind,[bool]$HasMaximum,[bool]$Paused = $false)
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
    if (-not $Paused) {
        & $add $menu 'Actualiser ce widget' 'Refresh' '' $false ([string][char]0xE72C)
        & $add $menu $(if ($Kind -eq 'Health') { 'Comprendre le score' } else { 'Comprendre ce chiffre' }) $(if ($Kind -eq 'Health') { 'HealthExplanation' } else { 'Explain' }) '' $false ([string][char]0xE946)
    }
    if ($Board -in @('Fleet','Computer')) {
        if ($Paused) { & $add $menu 'Reprendre la mesure' 'Resume' '' $false ([string][char]0xE768) }
        else { & $add $menu 'Suspendre la mesure' 'Pause' '' $false ([string][char]0xE769) }
    }
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    & $add $menu 'Modifier...' 'Edit' '' $false ([string][char]0xE70F)
    $names = Get-DomeniaBoardVisualNames
    $visuals = @(Get-DomeniaBoardVisuals -Kind $Kind -HasMaximum:$HasMaximum)
    if ($visuals.Count -gt 1) {
        $represent = New-Object System.Windows.Controls.MenuItem; $represent.Header = 'Représentation'
        foreach ($visual in $visuals) { & $add $represent ([string]$names[$visual]) 'Visual' $visual ($visual -eq [string]$Item.Visual) '' }
        [void]$menu.Items.Add($represent)
    }
    $sizeMenu = New-Object System.Windows.Controls.MenuItem; $sizeMenu.Header = 'Taille'
    $sizes = Get-DomeniaBoardSizeNames
    foreach ($size in $sizes.Keys) { & $add $sizeMenu ([string]$sizes[$size]) 'Size' $size ($size -eq [string]$Item.Size) '' }
    [void]$menu.Items.Add($sizeMenu)
    $move = New-Object System.Windows.Controls.MenuItem; $move.Header = 'Déplacer'
    & $add $move 'Au debut de la section' 'Move' 'First' $false ''
    & $add $move 'Vers la gauche' 'Move' 'Back' $false ''
    & $add $move 'Vers la droite' 'Move' 'Forward' $false ''
    & $add $move 'A la fin de la section' 'Move' 'Last' $false ''
    [void]$menu.Items.Add($move)
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    & $add $menu 'Retirer du tableau de bord' 'Remove' '' $false ([string][char]0xE74D)
    return $menu
}
function Set-DomeniaBoardSegmentSelection {
    # Metadata consumed by both chart clicks and exact local query drilldowns.
    param($Entry)
    $partIndex=0
    foreach($part in @($Entry.Items)){
        if($null -ne $part -and $null -ne $part.PSObject.Properties['Label']){
            $select=[pscustomobject]@{Label=[string]$part.Label;Index=$partIndex}
            foreach($property in @('Low','High','ExactValue','Excluded')){
                if($null -ne $part.PSObject.Properties[$property]){
                    Add-Member -InputObject $select -MemberType NoteProperty -Name $property -Value $part.$property
                }
            }
            Add-Member -InputObject $part -MemberType NoteProperty -Name Select -Value $select -Force
        }
        $partIndex++
    }
}
function New-DomeniaWidgetStateCard {
    # Card of a widget without a figure (decision David 2026-10-14): its title, why there is no figure and the button
    # that acts on it (Collecter, Relire, Reprendre la mesure...). Never a measure. Returns {Card; Message}: the message
    # line is updated in place while a collection runs.
    param([double]$Width,[double]$Height,[string]$Title,$Info,[string]$Board,[string]$Id)
    $compact = ($Height -lt 140)
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $stack.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    if (-not $compact) {
        $icon = New-DomeniaChartIcon ([string]$Info.Glyph) '#94A3B8' 30
        $icon.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
        [void]$stack.Children.Add($icon)
    }
    $head = New-DomeniaChartText -Text $Title -Size 13 -Weight SemiBold -Key 'TextColor' -OneLine
    $head.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $head.MaxWidth = [Math]::Max(80, $Width - 40)
    [void]$stack.Children.Add($head)
    $message = New-DomeniaChartText -Text ([string]$Info.Message) -Size $(if ($compact) { 11.5 } else { 12 }) -Key 'MutedColor'
    $message.TextAlignment = [System.Windows.TextAlignment]::Center
    $message.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $message.MaxWidth = [Math]::Max(80, $Width - 40)
    $message.ToolTip = [string]$Info.Message
    if ($compact) { $message.MaxHeight = 32; $message.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis }
    [void]$stack.Children.Add($message)
    if ([string]$Info.Action) {
        $tip = if ([string]$Info.Action -eq 'Resume') { 'Reprend la mesure de ce widget et collecte ce qui lui manque.' } else { 'Collecte seulement ce que ce widget affiche, pour son périmètre.' }
        $button = New-DomeniaBoardButton '' ([string]$Info.ActionText) $tip @{ Board = $Board; Id = $Id; Action = [string]$Info.Action }
        $button.MinHeight = 26
        $button.Padding = [System.Windows.Thickness]::new(10, 1, 10, 1)
        $button.Margin = [System.Windows.Thickness]::new(0, $(if ($compact) { 4 } else { 10 }), 0, 0)
        $button.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        [void]$stack.Children.Add($button)
    }
    return [pscustomobject]@{ Card = (New-DomeniaChartCard -Width $Width -Height $Height -Content $stack -Static); Message = $message }
}
function New-DomeniaBoardWidget {
    # -Placeholder: the board already holds data and the section is partly filled (SP-18): a widget without a figure
    # keeps a compact place saying why (decision David 2026-10-14: being collected, read by the complete inventory
    # only, absent from the last reading or not collected yet, with the button that collects it). Before any reading
    # it stays hidden unless it is paused or being collected. A paused widget keeps its size and title, says that it
    # is paused and is never resolved, so nothing is computed nor requested for it.
    param([string]$Board,$Item,$State,[switch]$Placeholder)
    $paused = Test-DomeniaBoardItemPaused -Item $Item
    $progress = if ($paused) { '' } else { Get-DomeniaWidgetCollectProgress -Board $Board -Id ([string]$Item.Id) }
    if ($paused) { $identity = Get-DomeniaBoardItemIdentity -Board $Board -Item $Item; $resolved = [pscustomobject]@{ Entry = $null; Kind = [string]$identity.Kind; Title = [string]$identity.Title; Name = [string]$identity.Title } }
    else { $resolved = Resolve-DomeniaBoardEntry -Board $Board -Item $Item -State $State }
    $entry = $resolved.Entry
    if (($null -eq $entry) -and (-not $State.Editing) -and (-not $Placeholder) -and (-not $paused) -and (-not $progress)) { return $null }
    # Without data the widget keeps its real kind, representation and size.
    $kind = if ($null -ne $entry) { [string]$entry.Kind } else { [string]$resolved.Kind }
    $hasMaximum = if ($null -ne $entry) { ($null -ne $entry.Maximum -and [double]$entry.Maximum -gt 0) } else { $kind -in @('Number','Health') }
    $visual = Resolve-DomeniaBoardVisual -Visual ([string]$Item.Visual) -Kind $kind -HasMaximum:$hasMaximum
    $size = Get-DomeniaBoardSize -Visual $visual -Size ([string]$Item.Size)
    if($Board -eq 'Fleet' -and $null -ne $entry -and $Item.Source -ne 'Query' -and $kind -ne 'Timeline'){
        Set-DomeniaBoardSegmentSelection -Entry $entry
    }
    $progressText = $null
    if ($null -ne $entry) { $card = New-DomeniaWidgetVisual -Entry $entry -Visual $visual -Title $resolved.Title -Size $size -Board $Board -OnSelect (Get-DomeniaBoardSelectHandler -Board $Board -Item $Item) }
    else {
        $need = Get-DomeniaWidgetNeed -Board $Board -Item $Item
        $collected = ($null -ne $State.Data)
        $deepRead = $false; $collectedAt = ''
        if ($Board -eq 'Computer') { $deepRead = Test-DomeniaComputerInventoryDeep -Result $script:LastComputerDashboardResult }
        if (($State.DataAtUtc -is [datetime]) -and ($collected)) { $collectedAt = $State.DataAtUtc.ToLocalTime().ToString('dd/MM HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
        $info = Get-DomeniaWidgetPlaceholder -Need $need -Paused $paused -Progress $progress -Collected $collected -DeepRead $deepRead -CollectedAt $collectedAt
        # A paused widget, or any widget while customising, keeps its own size; otherwise a compact place (SP-18).
        if (($paused) -or ($State.Editing)) { $width = $size.Width; $height = $(if ($size.Height -gt 0) { $size.Height } elseif ($size.MinHeight -gt 0) { $size.MinHeight } else { 118 }) }
        else { $compact = Get-DomeniaBoardSize -Visual Kpi -Size S; $width = $compact.Width; $height = $compact.Height }
        $stateCard = New-DomeniaWidgetStateCard -Width $width -Height $height -Title $resolved.Title -Info $info -Board $Board -Id ([string]$Item.Id)
        $card = $stateCard.Card
        if ($progress) { $progressText = $stateCard.Message }
    }

    $holder = New-Object System.Windows.Controls.Grid
    $holder.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    $holder.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $holder.AllowDrop = $true
    # Point 80: a widget takes the keyboard focus (Tab), so its menu (Maj+F10), its refresh (F5) and, while
    # customising, its move, size and removal keys work without a mouse.
    $holder.Focusable = $true
    [System.Windows.Automation.AutomationProperties]::SetName($holder, $resolved.Title)
    [System.Windows.Automation.AutomationProperties]::SetHelpText($holder, 'Maj+F10 : options du widget. F5 : actualiser ce widget. En personnalisation : Alt+flèches pour le déplacer, Alt+Maj+flèches pour sa taille, Suppr pour le retirer.')
    [void]$holder.Children.Add($card)
    $actionProperty = if ($null -ne $entry) { $entry.PSObject.Properties['Action'] } else { $null }
    # Rows: the card, the button of its entry, the progress line of a running collection.
    $rows = @{ Added = $false }
    $addRows = { if (-not $rows.Added) { [void]$holder.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)); foreach ($n in 1..2) { $auto = New-Object System.Windows.Controls.RowDefinition; $auto.Height = [System.Windows.GridLength]::Auto; [void]$holder.RowDefinitions.Add($auto) }; $rows.Added = $true } }
    # The score card draws its own button inside the card (UX-23).
    if (($null -ne $actionProperty) -and ($null -ne $actionProperty.Value) -and (-not $State.Editing) -and ($visual -ne 'Health' -or $null -eq $entry.Number)) {
        $action = $actionProperty.Value
        & $addRows
        $button = New-Object System.Windows.Controls.Button
        $button.SetResourceReference([System.Windows.Controls.Control]::StyleProperty, 'SecondaryButton')
        $button.Margin = [System.Windows.Thickness]::new(7, 0, 7, 7)
        $button.MinHeight = 30
        $button.Width = [Math]::Max(120, [double]$size.Width - 14)
        $button.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = [string]$action.Text; $label.TextWrapping = [System.Windows.TextWrapping]::Wrap; $label.FontSize = 12
        $button.Content = $label
        $button.ToolTip = [string]$action.Tip
        [System.Windows.Automation.AutomationProperties]::SetName($button, [string]$action.Text)
        $button.Tag = @{ Board = $Board; Action = 'EntryAction'; Value = [string]$action.Id }
        $button.Add_Click({ param($s,$e) Invoke-DomeniaBoardAction -Tag $s.Tag })
        [System.Windows.Controls.Grid]::SetRow($button, 1)
        [void]$holder.Children.Add($button)
    }
    if (($progress) -and ($null -eq $progressText)) {
        # The figure shown stays the last one stored; this line says that a collection is running for it.
        & $addRows
        $progressText = New-DomeniaChartText -Text $progress -Size 11.5 -Key 'AccentColor' -OneLine
        $progressText.Margin = [System.Windows.Thickness]::new(9, 0, 9, 6)
        $progressText.MaxWidth = [Math]::Max(120, [double]$size.Width - 18)
        $progressText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        [System.Windows.Controls.Grid]::SetRow($progressText, 2)
        [void]$holder.Children.Add($progressText)
    }
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
    # Point 73: a fleet figure opens only the list of the calculation it was drawn from.
    $snapshot = if ($Board -eq 'Fleet') { [string]$script:FleetQuerySnapshotKey } else { '' }
    if(-not $paused){
        if(($Board -eq 'Fleet') -or (($Board -eq 'Computer') -and ($Item.Source -eq 'Query'))){
            [void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE8A1) ('Ouvrir dans lʼatelier : ' + $resolved.Title) @{ Board = $Board; Id = [string]$Item.Id; Action = 'Details'; Snapshot = $snapshot }))
        }
        elseif(($Board -eq 'Computer') -and ($Item.Source -eq 'Probe')){
            [void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE8A5) ('Détails enregistrés : ' + $resolved.Title) @{Board=$Board;Id=[string]$Item.Id;Action='Details'}))
        }
        [void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE72C) ('Actualiser : ' + $resolved.Title) @{ Board = $Board; Id = [string]$Item.Id; Action = 'Refresh' }))
        if(($kind -eq 'Health') -and ($Board -in @('Fleet','Computer'))){[void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE946) 'Comprendre le score' @{Board=$Board;Action='HealthExplanation'}))}
        else{[void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE946) ('Comprendre ce chiffre : ' + $resolved.Title) @{ Board = $Board; Id = [string]$Item.Id; Action = 'Explain' }))}
    }
    if ($Board -in @('Fleet','Computer')) {
        if ($paused) { [void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE768) ('Reprendre la mesure : ' + $resolved.Title) @{ Board = $Board; Id = [string]$Item.Id; Action = 'Resume' })) }
        else { [void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE769) ('Suspendre la mesure : ' + $resolved.Title) @{ Board = $Board; Id = [string]$Item.Id; Action = 'Pause' })) }
    }
    [void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE70F) ('Modifier : ' + $resolved.Title) @{ Board = $Board; Id = [string]$Item.Id; Action = 'Edit' }))
    [void]$chrome.Children.Add((New-DomeniaBoardChromeButton ([string][char]0xE711) ('Retirer : ' + $resolved.Title) @{ Board = $Board; Id = [string]$Item.Id; Action = 'Remove' } -Danger))
    $chrome.Opacity = if ($State.Editing) { 1 } else { 0 }
    [void]$holder.Children.Add($chrome)
    $holder.Tag = @{ Board = $Board; Id = [string]$Item.Id; Chrome = $chrome; Mark = $mark; Editing = [bool]$State.Editing; Item = $Item; Progress = $progressText; Paused = $paused; Snapshot = $snapshot }
    $holder.ContextMenu = New-DomeniaBoardMenu -Board $Board -Item $Item -Kind $kind -HasMaximum $hasMaximum -Paused $paused
    # The round buttons appear on hover or keyboard focus (always while customising).
    $holder.Add_MouseEnter({ param($s,$e) Set-DomeniaHoverValue $s.Tag.Chrome ([System.Windows.UIElement]::OpacityProperty) 1 })
    $holder.Add_MouseLeave({ param($s,$e) if (-not $s.Tag.Editing -and -not $s.IsKeyboardFocusWithin) { Set-DomeniaHoverValue $s.Tag.Chrome ([System.Windows.UIElement]::OpacityProperty) 0 } })
    $holder.Add_IsKeyboardFocusWithinChanged({ param($s,$e) $s.Tag.Chrome.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); if ($s.IsKeyboardFocusWithin) { $s.Tag.Chrome.Opacity = 1 } elseif (-not $s.Tag.Editing -and -not $s.IsMouseOver) { $s.Tag.Chrome.Opacity = 0 } })
    # Keyboard (point 80): with Alt held WPF reports Key.System and the real key in SystemKey.
    $holder.Add_PreviewKeyDown({
        param($s,$e)
        if ($e.OriginalSource -is [System.Windows.Controls.Primitives.TextBoxBase]) { return }
        $key = if ($e.Key -eq [System.Windows.Input.Key]::System) { $e.SystemKey } else { $e.Key }
        $modifiers = [System.Windows.Input.Keyboard]::Modifiers
        $alt = (($modifiers -band [System.Windows.Input.ModifierKeys]::Alt) -eq [System.Windows.Input.ModifierKeys]::Alt)
        $shift = (($modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -eq [System.Windows.Input.ModifierKeys]::Shift)
        $control = (($modifiers -band [System.Windows.Input.ModifierKeys]::Control) -eq [System.Windows.Input.ModifierKeys]::Control)
        $gesture = Get-DomeniaBoardKeyGesture -Key ([string]$key) -Alt $alt -Shift $shift -Control $control -Editing ([bool]$s.Tag.Editing)
        if ($null -eq $gesture) { return }
        if (($gesture.Action -eq 'Refresh') -and ([bool]$s.Tag.Paused)) { return }
        Invoke-DomeniaBoardAction -Tag @{ Board = $s.Tag.Board; Id = $s.Tag.Id; Action = [string]$gesture.Action; Value = [string]$gesture.Value }
        $e.Handled = $true
    })
    # Drag and drop: a widget dropped on another one takes its place (and its section).
    $holder.Add_PreviewMouseLeftButtonDown({
        param($s,$e)
        if(-not $s.Tag.Editing){return}
        # Chrome buttons retain their click even while layouts can be dragged.
        $node=$e.OriginalSource
        while($null -ne $node -and -not [object]::ReferenceEquals($node,$s)){
            if($node -is [System.Windows.Controls.Primitives.ButtonBase]){$script:DomeniaBoardDrag=$null;return}
            if($node -is [System.Windows.Media.Visual]){$node=[System.Windows.Media.VisualTreeHelper]::GetParent($node)}else{$node=[System.Windows.LogicalTreeHelper]::GetParent($node)}
        }
        $script:DomeniaBoardDrag = @{ Source = $s; Start = $e.GetPosition($s) }
    })
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
    # A widget focused with the keyboard (point 80) gets the focus back after the redraw, not one of its buttons.
    $holderFocused = (($keyboard) -and ($focused -is [System.Windows.FrameworkElement]) -and ($focused.Tag -is [hashtable]) -and ($focused.Tag.ContainsKey('Chrome')))
    $editFocus = if ($holderFocused) { 'Holder' } else { 'Edit' }
    switch ($action) {
        'FleetAnalysis' { Show-DomeniaFleetAnalysis;return }
        'HealthExplanation' { [void](Show-DomeniaHealthExplanation -Board $board);return }
        'HealthRules' { [void](Show-DomeniaHealthRulesEditor -Board ([string]$Tag['Board']));return }
        'Details' {
            if($board -eq 'Computer'){
                $item=@(Get-DomeniaBoardLayout -Board $board|Where-Object{$_.Id -eq $id}|Select-Object -First 1)
                if($item.Count){
                    if($item[0].Source -eq 'Query'){Show-DomeniaComputerQueryWorkshop -RecipeId $item[0].Key}
                    elseif($item[0].Source -eq 'Probe'){Show-DomeniaProbeDetails -ProbeId ([string]$item[0].Key)}
                }
                return
            }
            if($board -ne 'Fleet'){return}
            # Point 73: the list opened is the one of the calculation the figure was drawn from.
            $drawn=[string]$Tag['Snapshot']
            if(($drawn) -and (-not (Test-DomeniaWidgetSnapshotCurrent -Drawn $drawn -Current ([string]$script:FleetQuerySnapshotKey)))){Set-Status 'Ce chiffre vient dʼun calcul remplacé depuis : le tableau est redessiné avec le calcul actuel, rouvrez son détail.' 'WARN';Show-DomeniaBoard -Board Fleet -Quiet;return}
            $item=@(Get-DomeniaBoardLayout -Board $board|Where-Object{[string]$_.Id -eq $id}|Select-Object -First 1)
            if($item.Count){Show-DomeniaFleetWidgetDetails -Item $item[0]}
            return
        }
        'Edit' { if (Show-DomeniaBoardEditor -Board $board -Id $id) { Restore-DomeniaBoardFocus $board 'Edit' $state.LastId } else { Restore-DomeniaBoardFocus $board 'Edit' $id }; return }
        'Add' {
            # Adding is the explicit gesture (decision David 2026-10-14): the widget collects at once what it misses.
            if (Show-DomeniaBoardEditor -Board $board -Group $value) { [void](Start-DomeniaWidgetRefresh -Board $board -Id ([string]$state.LastId) -Reason Add); Restore-DomeniaBoardFocus $board 'Edit' $state.LastId } else { Restore-DomeniaBoardFocus $board 'Add' '' }
            return
        }
        'Workshop' {if($board -eq 'Computer'){Show-DomeniaComputerQueryWorkshop}else{Show-DomeniaQueryWorkshop -Evaluate};return}
        'Customize' { $state.Editing = -not $state.Editing; Show-DomeniaBoard -Board $board -Quiet; if ($keyboard) { Restore-DomeniaBoardFocus $board 'Customize' '' }; return }
        'Probe' { Start-DomeniaWidgetProbe -Board $board; return }
        'Refresh' { [void](Start-DomeniaWidgetRefresh -Board $board -Id $id -Reason Refresh); if ($keyboard) { Restore-DomeniaBoardFocus $board $(if ($holderFocused) { 'Holder' } else { 'Refresh' }) $id }; return }
        'Pause' { Set-DomeniaBoardItemPaused -Board $board -Id $id -Paused $true; if ($keyboard) { Restore-DomeniaBoardFocus $board $(if ($holderFocused) { 'Holder' } else { 'Resume' }) $id }; return }
        'Resume' { Set-DomeniaBoardItemPaused -Board $board -Id $id -Paused $false; if ($keyboard) { Restore-DomeniaBoardFocus $board $(if ($holderFocused) { 'Holder' } else { 'Pause' }) $id }; return }
        'Explain' { Show-DomeniaWidgetExplanation -Board $board -Id $id; return }
        'Undo' {
            if (($null -eq $state.UndoStack) -or (-not $state.UndoStack.Count)) { return }
            $top = $state.UndoStack[$state.UndoStack.Count - 1]
            $state.UndoStack.RemoveAt($state.UndoStack.Count - 1)
            Sync-DomeniaBoardUndo $state
            Set-DomeniaBoardLayout -Board $board -Layout @($top.Layout) -KeepUndo
            if ($keyboard) { Restore-DomeniaBoardFocus $board $(if ($state.UndoStack.Count) { 'Undo' } else { 'Customize' }) '' }
            return
        }
        'EntryAction' { Invoke-DomeniaBoardEntryAction -Board $board -Id $value; return }
        'CopyTargets' { Copy-DomeniaFleetTargets -Targets @($Tag['Targets']); return }
        'QueryTargets' { Show-DomeniaAttentionInWorkshop -Targets @($Tag['Targets']) -Label ([string]$Tag['Label']); return }
        'Reset' { Set-DomeniaBoardLayout -Board $board -Layout @(Get-DomeniaBoardDefaultLayout -Board $board) -Undo 'Disposition par defaut appliquee'; if ($keyboard) { Restore-DomeniaBoardFocus $board 'Undo' '' }; return }
    }
    $layout = @(Get-DomeniaBoardLayout -Board $board)
    switch ($action) {
        'Remove' { Set-DomeniaBoardLayout -Board $board -Layout @(Remove-DomeniaBoardItem -Layout $layout -Id $id) -Undo 'Widget retire'; if ($keyboard) { Restore-DomeniaBoardFocus $board 'Undo' '' } }
        'Visual' { Set-DomeniaBoardLayout -Board $board -Layout @(Update-DomeniaBoardItem -Layout $layout -Id $id -Changes @{ Visual = $value }) -Undo 'Représentation modifiée' -Highlight $id; if ($keyboard) { Restore-DomeniaBoardFocus $board $editFocus $id } }
        'Size' {
            # Grow and Shrink come from the keyboard (Alt+Maj+flèches): one step, bounded to Compacte and Large.
            $sizeValue = $value
            if ($sizeValue -in @('Grow','Shrink')) {
                $current = @($layout | Where-Object { [string]$_.Id -eq $id } | Select-Object -First 1)
                if (-not $current.Count) { return }
                $sizeValue = Get-DomeniaBoardNextSize -Size ([string]$current[0].Size) -Step $(if ($value -eq 'Grow') { 1 } else { -1 })
                if ($sizeValue -eq [string]$current[0].Size) { return }
            }
            Set-DomeniaBoardLayout -Board $board -Layout @(Update-DomeniaBoardItem -Layout $layout -Id $id -Changes @{ Size = $sizeValue }) -Undo 'Taille changee' -Highlight $id; if ($keyboard) { Restore-DomeniaBoardFocus $board $editFocus $id }
        }
        'Move' { Set-DomeniaBoardLayout -Board $board -Layout @(Move-DomeniaBoardItem -Layout $layout -Id $id -Step $value) -Undo 'Widget deplace' -Highlight $id; if ($keyboard) { Restore-DomeniaBoardFocus $board $editFocus $id } }
    }
}
function Restore-DomeniaBoardFocus {
    # Focus on the button of the given action (and widget) in the redrawn board, else on the toolbar.
    param([string]$Board,[string]$Action,[string]$Id = '')
    $panel = Get-DomeniaControl (Get-DomeniaBoardPanelName $Board)
    if ($null -eq $panel) { return }
    if ($Action -eq 'Holder') {
        $holder = Find-DomeniaBoardHolder $panel $Id
        if ($null -ne $holder) { [void]$holder.Focus(); return }
        $Action = 'Edit'
    }
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
            # Points 135-136: a probe that does not satisfy Domenia.ProbeContract/1 is never offered, and the refusal is logged.
            $contractEntry = Get-DomeniaProbeContract ([string]$probe.Id)
            if (($null -eq $contractEntry) -or (-not [bool]$contractEntry.Check.Valid)) {
                $why = if ($null -ne $contractEntry) { @($contractEntry.Check.Errors) -join ' ' } else { 'contrat introuvable' }
                Write-AppLog ('Sonde ' + [string]$probe.Id + ' non proposée : contrat refusé (' + $why + ').') 'WARN'
                continue
            }
            $shown = $present.ContainsKey('Probe|' + [string]$probe.Id)
            $kind = Get-DomeniaProbeKind -Probe $probe -Board $Board
            # FI-17: a slow query is flagged before it is added.
            $slow = (($null -ne $probe.PSObject.Properties['Slow']) -and [bool]$probe.Slow)
            $probeDescription=[string](Get-DomeniaHealthValue $probe 'Description' '')
            $probeDescription+=' '+[string](Get-DomeniaHealthValue $probe 'Limitations' '')
            $probeDescription+=' '+[string](Get-DomeniaHealthValue $probe 'Compatibility' '')
            if($slow){$probeDescription+=' · Requête lente : collecte explicite recommandée.'}
            $probeDescription+=' '+(Get-DomeniaProbeContractSummary $contractEntry.Contract)
            [void]$rows.Add([pscustomobject]@{ Section = 'Requetes WMI · ' + [string]$probe.Category; Name = [string]$probe.Name; Description = $probeDescription; Badge = $(if ($shown) { 'affiche' } else { '' }); Source = 'Probe'; Key = [string]$probe.Id; Kind = $kind; Visual = (Resolve-DomeniaBoardVisual -Visual ([string]$probe.Visual) -Kind $kind); Size = ''; Group = [string]$probe.Category; Slow = $slow; Search = (ConvertTo-DomeniaSearchText ([string]$probe.Name + ' ' + [string]$probe.Category + ' ' + [string]$probe.Class + ' ' + $probeDescription)) })
        }
    }
    if($Board -in @('Fleet','Computer') -and $null -ne $script:DomeniaQueryState){foreach($recipe in @($script:DomeniaQueryState.Saved)){$rows.Add([pscustomobject]@{Section='Mes requêtes';Name=$recipe.Name;Description=$(if($Board -eq 'Computer'){'Requête enregistrée évaluée sur le poste sélectionné'}else{'Filtre enregistré sur les données locales du périmètre'});Badge=$(if($present.ContainsKey('Query|'+$recipe.Id)){'affiche'}else{''});Source='Query';Key=$recipe.Id;Kind='Distribution';Visual=$(if([string](Get-DomeniaMember $recipe 'GroupBy')){'Bar'}else{'Kpi'});Size='M';Group='Mes sondes';Slow=$false;Search=(ConvertTo-DomeniaSearchText $recipe.Name)})|Out-Null}}
    # Screen readers and type-ahead read an item through ToString: its name, its section, and whether it is shown.
    foreach ($row in $rows) { Add-Member -InputObject $row -MemberType ScriptMethod -Name ToString -Value { $this.Name + ', ' + $this.Section + $(if ($this.Badge) { ', deja affiche' } else { '' }) } -Force }
    return @($rows)
}
function Get-DomeniaBoardPreviewEntry {
    # Real data when the board has it, otherwise an example of the same kind.
    param([string]$Board,[string]$Source,[string]$Key,[string]$Kind,[string]$Visual='Kpi')
    $state = Get-DomeniaBoardState $Board
    $item = New-DomeniaBoardItem -Source $Source -Key $Key -Visual $Visual
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
    foreach ($bedI in 0..4) { $bedRow = [Windows.Controls.RowDefinition]::new(); $bedRow.Height = [Windows.GridLength]::Auto; [void]$bedForm.RowDefinitions.Add($bedRow) }
    $bedPlace = { param($Element,[int]$Row,[int]$Column) [Windows.Controls.Grid]::SetRow($Element, $Row); [Windows.Controls.Grid]::SetColumn($Element, $Column); $Element.Margin = [Windows.Thickness]::new(0, 4, 0, 4); [void]$bedForm.Children.Add($Element) }
    $bedRowLabel = 0
    foreach ($bedText in @('Titre','Représentation','Taille','Section')) { $bedLabel = New-DomeniaChartText -Text $bedText -Size 12.5 -Weight Medium -Key 'TextColor'; & $bedPlace $bedLabel $bedRowLabel 0; $bedRowLabel++ }
    $bedTitle = [Windows.Controls.TextBox]::new(); $bedTitle.MinHeight = 32; $bedTitle.Padding = [Windows.Thickness]::new(6, 4, 6, 4); & $bedPlace $bedTitle 0 1
    $bedVisual = [Windows.Controls.ComboBox]::new(); $bedVisual.MinHeight = 32; & $bedPlace $bedVisual 1 1
    $bedSize = [Windows.Controls.ComboBox]::new(); $bedSize.MinHeight = 32; & $bedPlace $bedSize 2 1
    foreach ($bedK in $bedSizes.Keys) { [void]$bedSize.Items.Add([string]$bedSizes[$bedK]) }
    # A plain list of sections, then "+ Nouvelle section..." which opens a name field (the application combo style
    # does not draw the text of an editable combo).
    $bedNewGroupItem = '+ Nouvelle section...'
    $bedGroup = [Windows.Controls.ComboBox]::new(); $bedGroup.MinHeight = 32; & $bedPlace $bedGroup 3 1
    foreach ($bedG in @(Get-DomeniaBoardGroups -Layout $bedLayout)) { [void]$bedGroup.Items.Add($bedG) }
    foreach ($bedC in @(Get-DomeniaBoardCatalog -Board $Board | ForEach-Object { $_.Group } | Select-Object -Unique)) { if (-not $bedGroup.Items.Contains($bedC)) { [void]$bedGroup.Items.Add($bedC) } }
    [void]$bedGroup.Items.Add($bedNewGroupItem)
    $bedNewGroup = [Windows.Controls.TextBox]::new(); $bedNewGroup.MinHeight = 32; $bedNewGroup.Padding = [Windows.Thickness]::new(6, 4, 6, 4); $bedNewGroup.Visibility = [Windows.Visibility]::Collapsed; & $bedPlace $bedNewGroup 4 1
    $bedNewGroup.ToolTip = 'Nom de la nouvelle section, cree a la fin du tableau de bord.'
    [Windows.Automation.AutomationProperties]::SetName($bedNewGroup, 'Nom de la nouvelle section')
    [Windows.Automation.AutomationProperties]::SetName($bedTitle, 'Titre du widget')
    [Windows.Automation.AutomationProperties]::SetName($bedVisual, 'Représentation')
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
        $bedV = 'Kpi'; foreach ($bedK in $bedNames.Keys) { if ([string]$bedNames[$bedK] -eq [string]$bedVisual.SelectedItem) { $bedV = $bedK } }
        $bedEntry = Get-DomeniaBoardPreviewEntry -Board $Board -Source $bedState.Source -Key $bedState.Key -Kind $bedState.Kind -Visual $bedV
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
        if (($null -ne $Row.PSObject.Properties['Slow']) -and [bool]$Row.Slow) { $bedKindText.Text += ' Requête lente : jusquʼà 10 s par poste, à réserver aux listes courtes.' }
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
        if (-not $bedMatch.Count -and $bedWantedGroup) { $bedGroup.Items.Insert($bedGroup.Items.Count - 1, $bedWantedGroup); $bedMatch = @($bedWantedGroup) }
        if ($bedMatch.Count) { $bedGroup.SelectedItem = $bedMatch[0] }
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
    $bedGroup.Add_SelectionChanged({
        $bedIsNew = ([string]$bedGroup.SelectedItem -eq $bedNewGroupItem)
        $bedNewGroup.Visibility = if ($bedIsNew) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        if ($bedIsNew -and -not $bedState.Loading) { [void]$bedNewGroup.Focus() }
    })
    $bedSize.Add_SelectionChanged({ & $bedRefresh })
    $bedTitle.Add_TextChanged({ & $bedRefresh })
    $bedSave.Add_Click({
        if (-not $bedState.Key) { return }
        $bedV = 'Kpi'; foreach ($bedK in $bedNames.Keys) { if ([string]$bedNames[$bedK] -eq [string]$bedVisual.SelectedItem) { $bedV = $bedK } }
        $bedEntry = Get-DomeniaBoardPreviewEntry -Board $Board -Source $bedState.Source -Key $bedState.Key -Kind $bedState.Kind -Visual $bedV
        $bedS = 'M'; foreach ($bedK in $bedSizes.Keys) { if ([string]$bedSizes[$bedK] -eq [string]$bedSize.SelectedItem) { $bedS = $bedK } }
        $bedT = $bedTitle.Text.Trim(); if ($bedT -ceq $bedState.DefaultTitle) { $bedT = '' }
        $bedG = if ([string]$bedGroup.SelectedItem -eq $bedNewGroupItem) { $bedNewGroup.Text.Trim() } else { ([string]$bedGroup.SelectedItem).Trim() }
        if (-not $bedG) { $bedG = 'Mes widgets' }
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
function Get-DomeniaWidgetObservations {
    # Observations usable by the query widgets (decision David 2026-10-08, FI-04): attached by GUID to the active
    # workstations of the overview (Fleet) or to the selected workstation (Computer), left out past the configured age,
    # flagged Old past seven days. Returns {Key; Observation; CheckedUtc; Old}.
    param([string]$Board)
    if ($null -eq $script:FleetObservations) { return @() }
    $maxDays = 30
    try { $maxDays = Get-DomeniaObservationMaxAgeDays } catch { $maxDays = 30 }
    $nowUtc = [datetime]::UtcNow
    $owners = @{}
    if ($Board -eq 'Fleet') {
        if ($null -eq $script:FleetLast) { return @() }
        foreach ($target in @($script:FleetLast.Targets)) { if ($null -ne $target) { $owners[([string]$target.distinguished_name).ToLowerInvariant()] = [string]$target.object_guid } }
    } elseif ($Board -eq 'Computer') {
        if ($null -eq $script:SelectedObject) { return @() }
        $dn = [string]$script:SelectedObject.DN
        if ([string]::IsNullOrWhiteSpace($dn)) { return @() }
        $guid = ''
        try { $guid = [string]$script:SelectedObject.Safety.Guid } catch { $guid = '' }
        $owners[$dn.ToLowerInvariant()] = $guid
    }
    $list = New-Object System.Collections.ArrayList
    foreach ($key in @($owners.Keys)) {
        if (-not $script:FleetObservations.ContainsKey($key)) { continue }
        $obs = $script:FleetObservations[$key]
        if ($null -eq $obs) { continue }
        $guidProperty = $obs.PSObject.Properties['Guid']
        $expected = [string]$owners[$key]
        # A workstation moved, deleted or recreated under the same DN does not inherit the old observation.
        if ($expected -and ($null -ne $guidProperty) -and [string]$guidProperty.Value -and ((ConvertTo-DomeniaWidgetGuid ([string]$guidProperty.Value)) -ne (ConvertTo-DomeniaWidgetGuid $expected))) { continue }
        if (($Board -eq 'Fleet') -and (($null -eq $guidProperty) -or (-not [string]$guidProperty.Value))) { continue }
        $checkedProperty = $obs.PSObject.Properties['CheckedUtc']
        $checked = if ($null -ne $checkedProperty) { [string]$checkedProperty.Value } else { '' }
        $age = Test-DomeniaObservationAge -CheckedUtc $checked -NowUtc $nowUtc -MaxDays $maxDays
        if ($age -eq 'Expired') { continue }
        [void]$list.Add([pscustomobject]@{ Key = $key; Observation = $obs; CheckedUtc = (ConvertFrom-DomeniaUtcText $checked); Old = ($age -eq 'Old') })
    }
    return @($list)
}
function ConvertTo-DomeniaWidgetGuid {
    param([string]$Text)
    return (([string]$Text).Trim().Trim('{','}')).ToLowerInvariant()
}
function Get-DomeniaWidgetResults {
    param(
        [string]$Board,
        [string]$ProbeId
    )
    return @(Get-DomeniaWidgetProbeObservations -Board $Board -ProbeId $ProbeId | ForEach-Object{$_.Result})
}
function Get-DomeniaWidgetProbeObservations {
    param([string]$Board,[string]$ProbeId)
    $probe=Get-DomeniaProbe $ProbeId
    foreach($item in @(Get-DomeniaWidgetObservations -Board $Board)){
        $probes=Get-DomeniaMemberValue $item.Observation 'Probes';$result=Get-DomeniaMemberValue $probes $ProbeId
        if($null -eq $result){continue}
        $at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $result 'CheckedUtc'))
        if((Test-DomeniaObservationAge -CheckedUtc $at -MaxDays (Get-DomeniaObservationMaxAgeDays)) -eq 'Expired'){continue}
        $usable=@(Get-DomeniaProbeValues -Probe $probe -Result $result).Count -gt 0
        [pscustomobject]@{Result=$result;CheckedUtc=$at;Key=$item.Key;Usable=$usable}
    }
}
function Get-DomeniaWidgetCoverage {
    # Coverage text of a query widget: 'N postes analysés sur M, le jj/MM' (Fleet), 'relevé il y a N j' (Computer).
    param([string]$Board,[string]$ProbeId)
    $items = @(Get-DomeniaWidgetProbeObservations -Board $Board -ProbeId $ProbeId | Where-Object{$_.Usable})
    if (-not $items.Count) { return $null }
    $newest = $null;$oldest=$null
    foreach ($item in $items) { if (($null -ne $item.CheckedUtc) -and (($null -eq $newest) -or ($item.CheckedUtc -gt $newest))) { $newest = $item.CheckedUtc };if($null -ne $item.CheckedUtc -and ($null -eq $oldest -or $item.CheckedUtc -lt $oldest)){$oldest=$item.CheckedUtc} }
    $old = (($null -eq $oldest) -or ((([datetime]::UtcNow) - $oldest).TotalDays -gt 7))
    if ($Board -eq 'Fleet') {
        $total = 0
        if ($null -ne $script:FleetLast) { $total = @($script:FleetLast.Targets).Count }
        return [pscustomobject]@{ Text = (Get-DomeniaCoverageText -Analysed $items.Count -Total $total -LastUtc $newest); Old = $old }
    }
    $text = if ($null -ne $newest) { 'relevé ' + (Format-DomeniaAge -FromUtc $newest -NowUtc ([datetime]::UtcNow)) } else { 'relevé de date inconnue' }
    return [pscustomobject]@{ Text = $text; Old = $old }
}
function Invoke-DomeniaBoardEntryAction {
    # Buttons carried by a widget (Action of its entry) or by the hint of an empty section, handled here: a rule never
    # starts anything. An inventory or a software list goes through the existing button of the page (same checks,
    # same confirmation); a route only opens a screen (SP-17, UX-23).
    param([string]$Board,[string]$Id)
    switch ($Id) {
        'BitLockerPresence' { [void](Start-DomeniaFleetBitLockerPresence) }
        { $_ -in @('InventoryQuick','InventoryFull','LoadSoftware') } {
            $target = Get-DomeniaBoardActionControl -Id $Id
            if (($null -eq $target) -or (-not $target.IsEnabled)) { Set-Status 'Action indisponible pour le moment : aucun poste sélectionné ou lecture déjà en cours.' 'WARN'; return }
            $target.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
        'OpenCard' { Invoke-DomeniaUxRoute -Route 'WsObject' }
        'GoSearch' { Invoke-DomeniaUxRoute -Route 'WsSearch' }
        'CollectFleet' {
            $context=Get-DomeniaFleetCollectionContext
            if($null -ne $context){Start-DomeniaOnlinePark -ScopeTargets $context.Targets -ScopeLabel $context.Scope.Name -Inventory}
        }
        default { Set-Status ('Action de widget inconnue : ' + $Id) 'WARN' }
    }
}
function Switch-DomeniaAttentionDetails {
    # A point unfolds a preview; the complete GUID-bound selection opens in the local workshop.
    param($Button)
    if (($null -eq $Button) -or ($Button.Tag -isnot [hashtable])) { return }
    $details = $Button.Tag['Details']
    if ($null -eq $details) { return }
    $chevron = $Button.Tag['Chevron']
    if ($details.Visibility -eq [System.Windows.Visibility]::Visible) {
        $details.Visibility = [System.Windows.Visibility]::Collapsed
        if ($null -ne $chevron) { $chevron.Text = [string][char]0xE70D }
        return
    }
    $item = $Button.Tag['Item']
    if ($details.Children.Count -eq 0) {
        $targets = @(Get-DomeniaAttentionTargets -Item $item)
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        $shown = 0
        foreach ($target in $targets) {
            if ($shown -ge 20) { break }
            $parent = ((([string]$target.distinguished_name) -split '(?<!\\),') | Where-Object { $_ -match '^(?i:OU|CN)=' } | Select-Object -Skip 1 -First 1)
            $ou = if ($parent) { ([string]$parent -replace '^(?i:OU|CN)=','') -replace '\\(.)','$1' } else { '' }
            $date = ''
            $logonProperty = $target.PSObject.Properties['logon']; $checkedProperty = $target.PSObject.Properties['checked']
            if (($null -ne $logonProperty) -and ([string]$logonProperty.Value -match '^(\d{4})-(\d{2})-(\d{2})$')) { $date = 'connexion ' + $Matches[3] + '/' + $Matches[2] + '/' + $Matches[1] }
            elseif (($null -ne $checkedProperty) -and [string]$checkedProperty.Value) { $date = 'relevé ' + [string]$checkedProperty.Value }
            $text = (@([string]$target.name, $ou, $date) | Where-Object { $_ }) -join ' · '
            $line = New-DomeniaChartText -Text $text -Size 12 -Key 'TextColor'
            $line.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
            [void]$details.Children.Add($line)
            $shown++
        }
        if ($targets.Count -gt $shown) { [void]$details.Children.Add((New-DomeniaChartText -Text ('et ' + [string]($targets.Count - $shown) + ' autre(s) poste(s) : Copier ou Détailler les postes pour la liste complète.') -Size 11.5 -Key 'MutedColor')) }
        if (-not $targets.Count) { [void]$details.Children.Add((New-DomeniaChartText -Text 'Postes non disponibles en mémoire : actualisez la vue dʼensemble.' -Size 11.5 -Key 'MutedColor')) }
        else {
            $actions = New-Object System.Windows.Controls.WrapPanel
            $actions.Margin = [System.Windows.Thickness]::new(0, 6, 0, 2)
            $copy = New-DomeniaBoardButton ([string][char]0xE8C8) 'Copier' 'Copie les noms des postes concernés.' @{ Targets = $targets; Label = [string]$item.Text }
            $copy.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
            $copy.Tag = @{ Board = 'Fleet'; Action = 'CopyTargets'; Targets = $targets; Label = [string]$item.Text }
            $search = New-DomeniaBoardButton ([string][char]0xE721) 'Détailler les postes' 'Ouvre la sélection complète dans le tableau du dashboard, avec filtres, export et fiche par poste.' @{ Board = 'Fleet'; Action = 'QueryTargets'; Targets = $targets; Label = [string]$item.Text }
            $search.Margin = [System.Windows.Thickness]::new(0, 0, 0, 0)
            [void]$actions.Children.Add($copy)
            [void]$actions.Children.Add($search)
            [void]$details.Children.Add($actions)
        }
    }
    $details.Visibility = [System.Windows.Visibility]::Visible
    if ($null -ne $chevron) { $chevron.Text = [string][char]0xE70E }
}
function Get-DomeniaBoardProbeIds {
    # Queries placed on the workstation and fleet boards, run by Analyser la liste in Rechercher.
    # Paused widgets are left out of every collection (decision David 2026-10-14).
    $ids=@(foreach ($board in @('Fleet','Computer')) { Select-DomeniaActiveBoardItems -Layout @(Get-DomeniaBoardLayout -Board $board) | Where-Object { [string]$_.Source -eq 'Probe' } | ForEach-Object { [string]$_.Key } })
    if($null -ne $script:DomeniaQueryState){foreach($board in @('Fleet','Computer')){foreach($item in @(Select-DomeniaActiveBoardItems -Layout @(Get-DomeniaBoardLayout $board)|Where-Object{$_.Source -eq 'Query'})){foreach($recipe in @($script:DomeniaQueryState.Saved|Where-Object{$_.Id -eq $item.Key})){$ids+=@(Get-DomeniaQueryProbeIds $recipe)}}}}
    return @($ids|Select-Object -Unique)
}
function Get-DomeniaFleetCollectionContext {
    # Every remote fleet read requires an explicit OU and the matching current local snapshot.
    $scope=Get-DomeniaFleetScope;$last=$script:FleetLast
    if($null -eq $scope -or [string]$scope.Dn -notmatch '^OU=' -or [string]$scope.Dn -ieq [string]$script:Conn.BaseDn){Set-Status 'Choisissez une OU dans le tableau de bord avant de préparer une collecte.' 'WARN';return $null}
    if($null -eq $last -or $script:FleetStale -or [string]$script:FleetJobId -or ([string]$last.Scope -ine [string]$scope.Dn) -or ([bool]$last.Subtree -ne [bool]$scope.Subtree) -or ($null -eq $last.PSObject.Properties['Epoch'] -or [long]$last.Epoch -ne [long]$script:SessionEpoch)){
        Set-Status 'Actualisez le tableau de bord de cette OU avant de préparer la collecte.' 'WARN';return $null
    }
    $targets=@($last.Targets|Where-Object{$null -ne $_})
    if(-not $targets.Count){Set-Status 'Aucun poste actif dans le périmètre chargé.' 'WARN';return $null}
    return [pscustomobject]@{Scope=$scope;Targets=$targets}
}
function Start-DomeniaWidgetProbe {
    # Collect only the remote fields required by saved recipes and explicit probe tiles, once per workstation.
    # Paused widgets are left out (decision David 2026-10-14).
    param([string]$Board)
    $active = @(Select-DomeniaActiveBoardItems -Layout @(Get-DomeniaBoardLayout -Board $Board))
    $probeIds = @($active | Where-Object { [string]$_.Source -eq 'Probe' } | ForEach-Object { [string]$_.Key } | Select-Object -Unique)
    $recipes=@(if(($Board -in @('Fleet','Computer')) -and ($null -ne $script:DomeniaQueryState)){foreach($item in @($active|Where-Object{$_.Source -eq 'Query'})){$script:DomeniaQueryState.Saved|Where-Object{$_.Id -eq $item.Key}}})
    $plan=Get-DomeniaQueryCollectionRequirements -Recipes $recipes -ProbeIds $probeIds
    if(-not $plan.Remote){Set-Status 'Ces widgets utilisent uniquement la base locale. Actualisez lʼOU choisie dans Base de données pour relire leurs informations AD.' 'INFO';return}
    $probes = @(ConvertTo-DomeniaProbePayload -Ids $plan.ProbeIds)
    if($Board -eq 'Fleet'){
        $context=Get-DomeniaFleetCollectionContext;if($null -eq $context){return}
        Start-DomeniaOnlinePark -ScopeTargets $context.Targets -ScopeLabel $context.Scope.Name -Inventory:([bool]$plan.Inventory) -Probes $probes;return
    }
    if ($Board -eq 'Computer') {
        if ($null -eq $script:SelectedObject -or [string]$script:SelectedObject.Type -ne 'Machine') { Set-Status 'Aucun poste sélectionné.' 'WARN'; return }
        $so = $script:SelectedObject
        $target = [pscustomobject]@{ name = $so.Name; distinguished_name = $so.DN; object_guid = [string]$so.Safety.Guid }
        Start-DomeniaOnlinePark -ScopeTargets @($target) -ScopeLabel ([string]$so.Name) -Inventory:([bool]$plan.Inventory) -Probes $probes
    }
}

# ---------------------------------------------------------------------------
# One widget at a time (decision David 2026-10-14): refresh a widget, collect what a widget just added or resumed
# is missing, pause a widget without removing it, explain its figure (point 6). Only existing gestures and pinned
# workers are used: the park run (LiveConsole) for endpoint reads, the inventory and software buttons of the
# workstation, the AD refresh of the OU, the BitLocker presence read and the local recalculation. The population
# is the selected workstation or the active workstations of the OU shown on Accueil, never the whole domain.
# ---------------------------------------------------------------------------
function Get-DomeniaWidgetRecipeIndex {
    # Id -> saved queries with that Id, from the workshop list or, when the workshop was never opened, from the
    # validated saved library (parsed and compiled once per library text, not once per widget and redraw). The
    # workshop always assigns a new list when its library changes, so the list itself is the key of the cache.
    $source = $null
    if ($null -ne $script:DomeniaQueryState) { $source = $script:DomeniaQueryState.Saved }
    else { $source = [string](Get-DomeniaSetting 'Query.Library' '') }
    $cache = $script:DomeniaWidgetRecipeCache
    if ($null -ne $cache) {
        if ([object]::ReferenceEquals($cache.Source, $source)) { return $cache.Index }
        if (($source -is [string]) -and ($cache.Source -is [string]) -and ([string]::Equals([string]$cache.Source, [string]$source, [StringComparison]::Ordinal))) { return $cache.Index }
    }
    $index = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $saved = @()
    if ($source -is [string]) { try { $saved = @(ConvertFrom-DomeniaQueryLibrary $source) } catch { $saved = @() } }
    else { $saved = @($source) }
    foreach ($recipe in $saved) {
        if ($null -eq $recipe) { continue }
        $id = [string]$recipe.Id
        if (-not $index.ContainsKey($id)) { $index[$id] = New-Object System.Collections.Generic.List[object] }
        $index[$id].Add($recipe)
    }
    $script:DomeniaWidgetRecipeCache = [pscustomobject]@{ Source = $source; Index = $index }
    return $index
}
function Get-DomeniaWidgetRecipe {
    # Saved query of a Query widget, $null when it is absent or ambiguous (several saved queries with its Id).
    param([string]$Id)
    $index = Get-DomeniaWidgetRecipeIndex
    if ((-not $index.ContainsKey($Id)) -or ($index[$Id].Count -ne 1)) { return $null }
    return $index[$Id][0]
}
function Get-DomeniaWidgetNeed {
    # What refreshing this widget reads (Get-DomeniaWidgetCollectionNeed), with the fields of its saved query.
    param([string]$Board,$Item)
    if ([string]$Item.Source -ne 'Query') { return (Get-DomeniaWidgetCollectionNeed -Board $Board -Item $Item) }
    $recipe = Get-DomeniaWidgetRecipe -Id ([string]$Item.Key)
    if ($null -eq $recipe) { return (Get-DomeniaWidgetCollectionNeed -Board $Board -Item $Item -RecipeMissing) }
    $fields = @()
    try { $fields = @(Get-DomeniaQueryRequestedFields $recipe) } catch { return (Get-DomeniaWidgetCollectionNeed -Board $Board -Item $Item -RecipeMissing) }
    return (Get-DomeniaWidgetCollectionNeed -Board $Board -Item $Item -Fields $fields)
}
function Get-DomeniaBoardItemIdentity {
    # Title and kind of a widget without reading its data (a paused widget is never resolved nor evaluated).
    param([string]$Board,$Item)
    $name = ''; $kind = 'Value'
    switch ([string]$Item.Source) {
        'Builtin' { $catalog = Get-DomeniaBoardCatalogItem -Board $Board -Key ([string]$Item.Key); if ($null -ne $catalog) { $name = [string]$catalog.Title; $kind = [string]$catalog.Kind } }
        'Probe' { $probe = Get-DomeniaProbe -Id ([string]$Item.Key); $kind = Get-DomeniaProbeKind -Probe $probe -Board $Board; if ($null -ne $probe) { $name = [string]$probe.Name } }
        'Query' { $recipe = Get-DomeniaWidgetRecipe -Id ([string]$Item.Key); if ($null -ne $recipe) { $name = [string]$recipe.Name }; $kind = $(if ([string]$Item.Visual -in @('Bar','Pie','Column')) { 'Distribution' } else { 'Number' }) }
    }
    $title = [string]$Item.Title
    if (-not $title) { $title = $(if ($name) { $name } else { [string]$Item.Key }) }
    return [pscustomobject]@{ Title = $title; Kind = $kind }
}
function Test-DomeniaWidgetOperationRunning {
    # True while the engine still holds a task of this operation (inventory, software list, BitLocker presence).
    param([string]$OperationId)
    if ($null -eq $script:AsyncJobs) { return $false }
    foreach ($job in @($script:AsyncJobs.Values)) { if (($null -ne $job) -and ([string](Get-DomeniaMember $job 'OperationId' '') -eq $OperationId)) { return $true } }
    return $false
}
function Get-DomeniaWidgetPopulationKey {
    # Identity of the population a widget gesture was made for: the selected workstation (DN and GUID) on the
    # workstation and software boards, the scope key of the OU shown on Accueil on the fleet board; '' when there is
    # none. A collection is shown, kept in the queue or started only for the population of its gesture.
    param([string]$Board)
    if ($Board -eq 'Fleet') {
        $scope = $null
        try { $scope = Get-DomeniaFleetScope } catch { $scope = $null }
        if ($null -eq $scope) { return '' }
        return [string]$scope.Key
    }
    $so = $script:SelectedObject
    if (($null -eq $so) -or ([string]$so.Type -ne 'Machine') -or (-not [string]$so.DN)) { return '' }
    $guid = ''
    try { $guid = [string]$so.Safety.Guid } catch { $guid = '' }
    return (([string]$so.DN).ToLowerInvariant() + '|' + $guid.Trim().Trim('{','}').ToLowerInvariant())
}
function Test-DomeniaWidgetPopulationCurrent {
    # True when a registered or queued activity belongs to the workstation or OU its board shows now.
    param($Entry)
    if ($null -eq $Entry) { return $false }
    return ([string](Get-DomeniaMember $Entry 'PopulationKey' '') -ceq (Get-DomeniaWidgetPopulationKey -Board ([string]$Entry.Board)))
}
function Register-DomeniaWidgetCollect {
    # The widgets that show the progress of an activity their gesture started. The figure stays the last one read.
    # -PopulationKey: the population of the gesture (default: the one shown now); another one never shows it.
    param([string]$Board,[string[]]$Ids = @(),[ValidateSet('Park','Inventory','Directory','BitLocker','Software','Local','Queued')][string]$Kind,[string]$RunId = '',[string]$PopulationKey = '')
    $population = if ($PSBoundParameters.ContainsKey('PopulationKey')) { $PopulationKey } else { Get-DomeniaWidgetPopulationKey -Board $Board }
    foreach ($id in @($Ids | Where-Object { $_ })) {
        $script:DomeniaWidgetCollects[$Board + '|' + [string]$id] = [pscustomobject]@{ Board = $Board; Id = [string]$id; Kind = $Kind; RunId = $RunId; Epoch = [long]$script:SessionEpoch; PopulationKey = $population }
    }
    if ($script:DomeniaWidgetCollects.Count) {
        if ($null -eq $script:DomeniaWidgetCollectTimer) { $script:DomeniaWidgetCollectTimer = New-DomeniaTimer -Owner 'Timer:WidgetCollect' -IntervalMs 1000 -SessionBound -Tick { Update-DomeniaWidgetCollectProgress } }
        $script:DomeniaWidgetCollectTimer.Start()
    }
}
function Get-DomeniaWidgetActivityText {
    # Progress text of one registered activity, '' once it ended, was replaced or belongs to another session.
    param($Entry)
    if (($null -eq $Entry) -or ([long]$Entry.Epoch -ne [long]$script:SessionEpoch)) { return '' }
    switch ([string]$Entry.Kind) {
        'Queued' {
            foreach ($queued in @($script:DomeniaWidgetCollectQueue)) {
                if (([string]$queued.Board -ne [string]$Entry.Board) -or ([string]$queued.Id -ne [string]$Entry.Id)) { continue }
                # Behind a survey of its scope it waits for that survey; once it ended, for the recalculation of the OU.
                if ((Get-DomeniaQueuedWidgetState -Entry $queued) -eq 'Wait') { return (Format-DomeniaWidgetCollectProgress -Phase Waiting) }
                return (Format-DomeniaWidgetCollectProgress -Phase Queued)
            }
            return ''
        }
        'Park' {
            # FI-18: the survey of this widget, whatever its scope (List for the OU of Accueil, Computer for the open
            # workstation).
            $run = Get-DomeniaParkRunById ([string]$Entry.RunId)
            if (($null -eq $run) -or ([bool]$run.Completed)) { return '' }
            if ([bool]$run.Loading) { return (Format-DomeniaWidgetCollectProgress -Phase Preparing) }
            if ([bool](Get-DomeniaMember $run 'Planning' $false)) { return (Format-DomeniaWidgetCollectProgress -Phase Planning -Done ([int](Get-DomeniaMember $run 'PlanNext' 0)) -Total @($run.Targets).Count -Fresh ([int](Get-DomeniaMember $run 'AlreadyFresh' 0))) }
            if (-not [bool]$run.Approved) { return (Format-DomeniaWidgetCollectProgress -Phase Confirming -Total @($run.Targets).Count) }
            return (Format-DomeniaWidgetCollectProgress -Phase Running -Done ([int]$run.Done) -Total @($run.Targets).Count -Fresh ([int](Get-DomeniaMember $run 'AlreadyFresh' 0)) -Failed ([int]$run.Failed))
        }
        'Directory' {
            $refresh = $script:DomeniaOuRefresh
            if (($null -ne $refresh) -and ([string]$refresh.Id -ceq [string]$Entry.RunId) -and (-not [bool]$refresh.Completed)) { return (Format-DomeniaWidgetCollectProgress -Phase Directory) }
            return ''
        }
        'Local' {
            $job = [string]$script:FleetJobId
            if (($job) -and ($null -ne $script:AsyncJobs) -and ($script:AsyncJobs.Contains($job))) { return (Format-DomeniaWidgetCollectProgress -Phase Local) }
            return ''
        }
    }
    $operation = switch ([string]$Entry.Kind) { 'Inventory' { 'ComputerInventory' } 'BitLocker' { 'BitLockerPresence' } 'Software' { 'SoftwareInventory' } default { '' } }
    if (($operation) -and (Test-DomeniaWidgetOperationRunning -OperationId $operation)) { return (Format-DomeniaWidgetCollectProgress -Phase ([string]$Entry.Kind)) }
    return ''
}
function Get-DomeniaWidgetCollectProgress {
    # Progress line of one widget, '' when nothing runs for it or when the activity belongs to another workstation
    # or OU than the one its board shows now.
    param([string]$Board,[string]$Id)
    $key = $Board + '|' + $Id
    if (-not $script:DomeniaWidgetCollects.ContainsKey($key)) { return '' }
    $entry = $script:DomeniaWidgetCollects[$key]
    if (-not (Test-DomeniaWidgetPopulationCurrent -Entry $entry)) { return '' }
    return (Get-DomeniaWidgetActivityText -Entry $entry)
}
function Update-DomeniaWidgetCollectProgress {
    # Called by the park run status and by the watch timer: updates the progress line of each collecting widget in
    # place, redraws the boards whose collection ended (their figure then comes from what was really stored), starts
    # the next queued widget and stops the timer once nothing is left to follow.
    $ended = @{}
    foreach ($key in @($script:DomeniaWidgetCollects.Keys)) {
        $entry = $script:DomeniaWidgetCollects[$key]
        $text = Get-DomeniaWidgetActivityText -Entry $entry
        if (-not $text) { [void]$script:DomeniaWidgetCollects.Remove($key); $ended[[string]$entry.Board] = $true; continue }
        # Followed until it ends, shown only on the board of its own workstation or OU.
        if (-not (Test-DomeniaWidgetPopulationCurrent -Entry $entry)) { continue }
        $panel = Get-DomeniaControl (Get-DomeniaBoardPanelName ([string]$entry.Board))
        if ($null -eq $panel) { continue }
        $holder = Find-DomeniaBoardHolder $panel ([string]$entry.Id)
        if (($null -ne $holder) -and ($holder.Tag['Progress'] -is [System.Windows.Controls.TextBlock])) { $holder.Tag['Progress'].Text = $text }
    }
    foreach ($board in @($ended.Keys)) { try { Show-DomeniaBoard -Board $board -Quiet -DeferIfHidden } catch { Write-AppLog ('Tableau de bord non redessiné après collecte : ' + $_.Exception.Message) 'WARN' } }
    Start-DomeniaQueuedWidgetCollect
    if ((-not $script:DomeniaWidgetCollects.Count) -and ($null -ne $script:DomeniaWidgetCollectTimer)) { $script:DomeniaWidgetCollectTimer.Stop() }
}
function Get-DomeniaQueuedWidgetState {
    # State of a queued widget collection. Ready: it may start now. Busy: a survey of its scope (FI-18,
    # Get-DomeniaWidgetCollectSlot) still runs; it starts at its end. Wait: the OU it was queued for is being
    # recalculated (a run just stored observations), and the collection context is refused until the new snapshot
    # is drawn; it starts then. Moved: the selected workstation or the OU shown changed since the gesture. Expired:
    # another session.
    param($Entry)
    if ([long]$Entry.Epoch -ne [long]$script:SessionEpoch) { return 'Expired' }
    if (Test-DomeniaParkRunActive -Slot (Get-DomeniaWidgetCollectSlot -Board ([string]$Entry.Board))) { return 'Busy' }
    if (-not (Test-DomeniaWidgetPopulationCurrent -Entry $Entry)) { return 'Moved' }
    if (([string]$Entry.Board -eq 'Fleet') -and (([bool]$script:FleetStale) -or ([bool][string]$script:FleetJobId))) { return 'Wait' }
    return 'Ready'
}
function Start-DomeniaQueuedWidgetCollect {
    # One survey per scope (FI-18): a widget added or refreshed while a survey of its scope runs waits here, then
    # starts once that survey ended, the local writes are confirmed and, on Accueil, the recalculation of its OU is
    # drawn. Its own checks (item, pause, population) run again then. A collection queued for another workstation or
    # OU than the one shown now is dropped and said so: it never starts on a population the operator did not ask for.
    if (-not $script:DomeniaWidgetCollectQueue.Count) { return }
    # Pending local writes of a finished survey are confirmed first; beside a survey of the other scope they are
    # expected (the admission of Start-DomeniaOnlinePark).
    $save = $null
    try { $save = Get-DomeniaPersistenceState } catch { $save = $null }
    if ((-not (Test-DomeniaParkRunActive)) -and ($null -ne $save) -and ([int]$save.Pending -gt 0)) { return }
    $index = 0
    while ($index -lt $script:DomeniaWidgetCollectQueue.Count) {
        $next = $script:DomeniaWidgetCollectQueue[$index]
        $state = Get-DomeniaQueuedWidgetState -Entry $next
        if ($state -in @('Busy','Wait')) { $index++; continue }
        $script:DomeniaWidgetCollectQueue.RemoveAt($index)
        [void]$script:DomeniaWidgetCollects.Remove([string]$next.Board + '|' + [string]$next.Id)
        if ($state -eq 'Ready') {
            # A refused start (population gone, widget removed or paused) said why; its queued line is redrawn away.
            if (-not (Start-DomeniaWidgetRefresh -Board ([string]$next.Board) -Id ([string]$next.Id) -Reason ([string]$next.Reason))) { try { Show-DomeniaBoard -Board ([string]$next.Board) -Quiet -DeferIfHidden } catch { Write-AppLog ('Tableau de bord non redessiné après la file : ' + $_.Exception.Message) 'WARN' } }
            return
        }
        if ($state -eq 'Moved') {
            $found = @(Get-DomeniaBoardLayout -Board ([string]$next.Board) | Where-Object { [string]$_.Id -eq [string]$next.Id } | Select-Object -First 1)
            $title = if ($found.Count) { [string](Get-DomeniaBoardItemIdentity -Board ([string]$next.Board) -Item $found[0]).Title } else { [string]$next.Id }
            Set-Status ('Collecte en file abandonnée pour « ' + $title + ' » : ' + $(if ([string]$next.Board -eq 'Fleet') { 'lʼOU affichée' } else { 'le poste sélectionné' }) + ' a changé depuis la demande. Actualisez le widget pour collecter ce qui est affiché maintenant.') 'INFO'
        }
    }
}
function Add-DomeniaWidgetCollectQueue {
    # At most 20 waiting widgets; the same widget is never queued twice: a new gesture on a queued widget replaces
    # its reason and its population.
    param([string]$Board,[string]$Id,[string]$Reason,[string]$PopulationKey)
    foreach ($queued in @($script:DomeniaWidgetCollectQueue)) {
        if (([string]$queued.Board -eq $Board) -and ([string]$queued.Id -eq $Id)) {
            $queued.Reason = $Reason; $queued.PopulationKey = $PopulationKey
            Register-DomeniaWidgetCollect -Board $Board -Ids @($Id) -Kind Queued -PopulationKey $PopulationKey
            return $true
        }
    }
    if ($script:DomeniaWidgetCollectQueue.Count -ge 20) { Set-Status 'Trop de widgets en attente de collecte : relancez celui-ci à la fin du relevé en cours.' 'WARN'; return $false }
    [void]$script:DomeniaWidgetCollectQueue.Add([pscustomobject]@{ Board = $Board; Id = $Id; Reason = $Reason; Epoch = [long]$script:SessionEpoch; PopulationKey = $PopulationKey })
    Register-DomeniaWidgetCollect -Board $Board -Ids @($Id) -Kind Queued -PopulationKey $PopulationKey
    return $true
}
function Get-DomeniaWidgetPopulation {
    # Workstations a widget collection may read: the selected workstation, or the active workstations of the OU shown
    # on Accueil from its current local snapshot (Get-DomeniaFleetCollectionContext refuses the domain root, another
    # OU, a stale or running snapshot). $null after the reason was given in the status bar.
    param([string]$Board)
    if ($Board -eq 'Computer') {
        $so = $script:SelectedObject
        if (($null -eq $so) -or ([string]$so.Type -ne 'Machine') -or (-not [string]$so.DN)) { Set-Status 'Aucun poste sélectionné : ouvrez la fiche dʼun poste pour collecter ce widget.' 'WARN'; return $null }
        $guid = ''
        try { $guid = [string]$so.Safety.Guid } catch { $guid = '' }
        if (-not $guid) { Set-Status 'Identité du poste non relue : rouvrez sa fiche avant de collecter.' 'WARN'; return $null }
        return [pscustomobject]@{ Label = [string]$so.Name; Targets = @([pscustomobject]@{ name = [string]$so.Name; distinguished_name = [string]$so.DN; object_guid = $guid }) }
    }
    $context = Get-DomeniaFleetCollectionContext
    if ($null -eq $context) { return $null }
    return [pscustomobject]@{ Label = [string]$context.Scope.Name; Targets = @($context.Targets) }
}
function Start-DomeniaWidgetRemoteCollect {
    # Endpoint reads of one widget through the existing park run, in the survey scope of its population (FI-18:
    # Get-DomeniaWidgetCollectSlot): only its probes, light inventory, ping or console, for its population. Add and
    # Resume read only what is missing: the run itself checks, before any network read and outside of this click, the
    # measurements stored for each workstation with the families of this widget (Invoke-DomeniaParkPlanStep), then
    # counts the workstations left to read. Refresh reads them again. The ceiling of a survey (SE-05) applies to every
    # widget collection. Adding a widget is the explicit gesture (decision David 2026-10-14): no confirmation up to
    # the limit of Get-DomeniaWidgetCollectAdmission (200 workstations to read); Refresh and Resume confirm the count.
    param([string]$Board,$Item,$Need,[string]$Reason)
    $id = [string]$Item.Id
    $populationKey = Get-DomeniaWidgetPopulationKey -Board $Board
    $slot = Get-DomeniaWidgetCollectSlot -Board $Board
    $running = Test-DomeniaParkRunActive -Slot $slot
    # The OU shown is being recalculated (a run just stored observations, or the OU changed): its collection context
    # is refused until the new snapshot is drawn, so the widget waits in the queue as it does behind a run.
    $recalculating = (($Board -eq 'Fleet') -and (([bool]$script:FleetStale) -or ([bool][string]$script:FleetJobId)))
    if (($running) -or ($recalculating)) {
        # Queued for the population shown now; the whole domain is never a population.
        if ((-not $populationKey) -or ($populationKey -eq '*')) { Set-Status $(if ($Board -eq 'Fleet') { 'Choisissez une OU dans le tableau de bord avant de préparer une collecte.' } else { 'Aucun poste sélectionné : ouvrez la fiche dʼun poste pour collecter ce widget.' }) 'WARN'; return $false }
        if (-not (Add-DomeniaWidgetCollectQueue -Board $Board -Id $id -Reason $Reason -PopulationKey $populationKey)) { return $false }
        if ($running) { Set-Status $(if ($slot -eq 'Computer') { 'Un relevé du poste est en cours : la collecte de ce widget démarrera à sa fin.' } else { 'Un relevé de la liste ou dʼune OU est en cours : la collecte de ce widget démarrera à sa fin.' }) 'INFO' }
        else {
            Set-Status 'Recalcul de lʼOU en cours : la collecte de ce widget démarrera à sa fin.' 'INFO'
            # The recalculation starts now if the OU is stale and Accueil is shown; it is never started twice.
            try { Request-DomeniaFleetRefresh } catch { Write-AppLog ('Recalcul de lʼOU non demandé : ' + $_.Exception.Message) 'WARN' }
        }
        Show-DomeniaBoard -Board $Board -Quiet
        return $true
    }
    $population = Get-DomeniaWidgetPopulation -Board $Board
    if ($null -eq $population) { return $false }
    $maxAge = 30
    try { $maxAge = Get-DomeniaObservationMaxAgeDays } catch { $maxAge = 30 }
    $targets = @($population.Targets)
    $probes = @()
    if (@($Need.ProbeIds).Count) { $probes = @(ConvertTo-DomeniaProbePayload -Ids @($Need.ProbeIds)) }
    $wmi = (([bool]$Need.Console) -or ([bool]$Need.Inventory) -or ($probes.Count -gt 0))
    # A query absent from the catalog leaves nothing to read: never announce a collection that reads nothing.
    if ((-not $wmi) -and (-not [bool]$Need.Ping)) { Set-Status 'Requête du widget absente du catalogue des sondes : rien à collecter.' 'WARN'; return $false }
    $arguments = @{ ScopeTargets = $targets; ScopeLabel = [string]$population.Label; Slot = $slot; WidgetBoard = $Board; WidgetIds = @($id); PassThru = $true }
    if ($Reason -eq 'Add') { $arguments.Preapproved = $true }
    if (([bool]$Need.Ping) -and (-not $wmi)) { $arguments.PingOnly = $true }
    else {
        if (-not [bool]$Need.Ping) { $arguments.WmiOnly = $true }
        if (-not [bool]$Need.Console) { $arguments.NoConsole = $true }
        if ([bool]$Need.Inventory) { $arguments.Inventory = $true }
        if ($probes.Count) { $arguments.Probes = $probes }
    }
    if ($Reason -eq 'Refresh') { $arguments.ForceRefresh = $true } else { $arguments.ReuseMaxAgeDays = $maxAge }
    $runId = [string](Start-DomeniaOnlinePark @arguments)
    if (-not $runId) { return $false }
    Register-DomeniaWidgetCollect -Board $Board -Ids @($id) -Kind Park -RunId $runId -PopulationKey $populationKey
    Show-DomeniaBoard -Board $Board -Quiet
    return $true
}
function Start-DomeniaWidgetRefresh {
    # One widget (decision David 2026-10-14). Reason Add: the widget was just placed on the board; Resume: its
    # measurement was just resumed; both collect only what it is missing. Refresh: its own button or F5 reads again
    # what it shows. Returns $true when a collection or a recalculation started or was queued.
    param([ValidateSet('Computer','Fleet','Software')][string]$Board,[string]$Id,[ValidateSet('Add','Refresh','Resume')][string]$Reason = 'Refresh')
    $found = @(Get-DomeniaBoardLayout -Board $Board | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1)
    if (-not $found.Count) { return $false }
    $item = $found[0]
    if (Test-DomeniaBoardItemPaused -Item $item) { Set-Status 'Widget suspendu : reprenez sa mesure pour lʼactualiser.' 'INFO'; return $false }
    $need = Get-DomeniaWidgetNeed -Board $Board -Item $item
    $state = Get-DomeniaBoardState $Board
    # A built-in widget is answered when its provider gave an entry; a query or probe widget is computed from the
    # local data on each display, so only its endpoint measurements can be missing (Remote).
    $hasEntry = (([string]$item.Source -ne 'Builtin') -or (($null -ne $state.Data) -and ($null -ne $state.Data.Entries) -and ($state.Data.Entries.ContainsKey([string]$item.Key))))
    $title = (Get-DomeniaBoardItemIdentity -Board $Board -Item $item).Title
    try {
        switch ([string]$need.Kind) {
            'Remote' { return (Start-DomeniaWidgetRemoteCollect -Board $Board -Item $item -Need $need -Reason $Reason) }
            'ComputerInventory' {
                $deepRead = Test-DomeniaComputerInventoryDeep -Result $script:LastComputerDashboardResult
                # An inventory of the needed depth already answered: running it again would read the same thing.
                if (($Reason -ne 'Refresh') -and ($null -ne $state.Data) -and (($hasEntry) -or (-not [bool]$need.Deep) -or ($deepRead))) { Set-Status ('Widget ' + $title + ' : le dernier inventaire du poste est déjà lu ; Actualiser le relit.') 'INFO'; return $false }
                Invoke-DomeniaBoardEntryAction -Board Computer -Id $(if ([bool]$need.Deep) { 'InventoryFull' } else { 'InventoryQuick' })
                if (Test-DomeniaWidgetOperationRunning -OperationId 'ComputerInventory') { Register-DomeniaWidgetCollect -Board $Board -Ids @($Id) -Kind Inventory; Show-DomeniaBoard -Board $Board -Quiet; return $true }
                return $false
            }
            'Software' {
                if (($Reason -ne 'Refresh') -and ($null -ne $state.Data)) { return $false }
                Invoke-DomeniaBoardEntryAction -Board Software -Id 'LoadSoftware'
                if (Test-DomeniaWidgetOperationRunning -OperationId 'SoftwareInventory') { Register-DomeniaWidgetCollect -Board $Board -Ids @($Id) -Kind Software; return $true }
                return $false
            }
            'Card' {
                if ($Reason -ne 'Refresh') { return $false }
                if (($null -eq $script:SelectedObject) -or ([string]$script:SelectedObject.Type -ne 'Machine')) { Set-Status 'Aucun poste sélectionné.' 'WARN'; return $false }
                Refresh-SelectedObject
                Set-Status ('Relecture de la fiche de ' + [string]$script:SelectedObject.Name + ' depuis lʼannuaire.') 'INFO'
                return $true
            }
            'Directory' {
                if (($Reason -ne 'Refresh') -and ($hasEntry)) { Set-Status ('Widget ' + $title + ' : calculé depuis la base locale de lʼOU, déjà à jour.') 'INFO'; return $false }
                if ($Board -ne 'Fleet') { return $false }
                # Only a new AD read started by this click is followed: a refused request (another refresh of the OU
                # running, ping or WMI included) leaves the reason in the status bar and shows nothing on the widget.
                $previousRefresh = if ($null -ne $script:DomeniaOuRefresh) { [string]$script:DomeniaOuRefresh.Id } else { '' }
                Invoke-DomeniaOuRefresh -Source Fleet -Mode AD
                $refresh = $script:DomeniaOuRefresh
                if (($null -ne $refresh) -and (-not [bool]$refresh.Completed) -and ([string]$refresh.Id -cne $previousRefresh)) { Register-DomeniaWidgetCollect -Board $Board -Ids @($Id) -Kind Directory -RunId ([string]$refresh.Id); Show-DomeniaBoard -Board $Board -Quiet; return $true }
                return $false
            }
            'BitLocker' {
                $read = (($hasEntry) -and ($null -ne $state.Data) -and ([string]$state.Data.Entries[[string]$item.Key].Value -ne 'Non lu'))
                if (($Reason -ne 'Refresh') -and ($read)) { return $false }
                if (Start-DomeniaFleetBitLockerPresence) { Register-DomeniaWidgetCollect -Board $Board -Ids @($Id) -Kind BitLocker; Show-DomeniaBoard -Board $Board -Quiet; return $true }
                return $false
            }
            'Local' {
                if (($Reason -ne 'Refresh') -and ($hasEntry)) { return $false }
                if ($Board -eq 'Fleet') {
                    Request-DomeniaFleetRefresh -Force
                    if ([string]$script:FleetJobId) { Register-DomeniaWidgetCollect -Board $Board -Ids @($Id) -Kind Local; Show-DomeniaBoard -Board $Board -Quiet; return $true }
                    return $false
                }
                Show-DomeniaBoard -Board $Board -Quiet
                return $true
            }
        }
        Set-Status ([string]$need.Label) 'WARN'
        return $false
    } catch {
        Set-Status ('Actualisation du widget impossible : ' + $_.Exception.Message) 'WARN'
        return $false
    }
}
function Set-DomeniaBoardItemPaused {
    # Pause or resume the measurement of one widget (decision David 2026-10-14). The widget keeps its place, size and
    # title; the change is saved with the layout and can be undone. A park run started only for paused widgets is
    # stopped; resuming collects what the widget is missing.
    param([string]$Board,[string]$Id,[bool]$Paused)
    $layout = @(Get-DomeniaBoardLayout -Board $Board)
    $found = @($layout | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1)
    if ((-not $found.Count) -or ((Test-DomeniaBoardItemPaused -Item $found[0]) -eq $Paused)) { return }
    $next = @(Update-DomeniaBoardItem -Layout $layout -Id $Id -Changes @{ Paused = $Paused })
    if ($Paused) {
        for ($i = $script:DomeniaWidgetCollectQueue.Count - 1; $i -ge 0; $i--) { if (([string]$script:DomeniaWidgetCollectQueue[$i].Board -eq $Board) -and ([string]$script:DomeniaWidgetCollectQueue[$i].Id -eq $Id)) { $script:DomeniaWidgetCollectQueue.RemoveAt($i) } }
        [void]$script:DomeniaWidgetCollects.Remove($Board + '|' + $Id)
        # A survey of either scope started only for widgets now paused is stopped (FI-18: one survey per scope).
        $active = @{}; foreach ($item in @(Select-DomeniaActiveBoardItems -Layout $next)) { $active[[string]$item.Id] = $true }
        foreach ($run in @((Get-DomeniaParkRuns).Values)) {
            if (($null -eq $run) -or ([bool]$run.Completed) -or ([string](Get-DomeniaMember $run 'WidgetBoard' '') -ne $Board)) { continue }
            if (-not @(@(Get-DomeniaMember $run 'WidgetIds' @()) | Where-Object { $active.ContainsKey([string]$_) }).Count) { Stop-DomeniaOnlinePark -RunId ([string]$run.Id) }
        }
    }
    Set-DomeniaBoardLayout -Board $Board -Layout $next -Undo $(if ($Paused) { 'Mesure suspendue' } else { 'Mesure reprise' }) -Highlight $Id
    if ($Paused) { Set-Status 'Mesure suspendue : le widget garde sa place et nʼest plus collecté. Reprendre la mesure le réactive.' 'INFO'; return }
    # A resumed fleet query or probe widget is evaluated again locally (it was left out while paused).
    if (($Board -eq 'Fleet') -and ($null -ne $script:DomeniaQueryState)) { Request-DomeniaQueryEvaluation }
    if (-not (Start-DomeniaWidgetRefresh -Board $Board -Id $Id -Reason Resume)) { Show-DomeniaBoard -Board $Board -Quiet }
}
function Get-DomeniaWidgetExplanationData {
    # Inputs of the explanation of one figure, from what the board already holds (point 6): no read is started.
    param([string]$Board,$Item)
    $state = Get-DomeniaBoardState $Board
    $resolved = Resolve-DomeniaBoardEntry -Board $Board -Item $Item -State $state
    $need = Get-DomeniaWidgetNeed -Board $Board -Item $Item
    $maxAge = 30
    try { $maxAge = Get-DomeniaObservationMaxAgeDays } catch { $maxAge = 30 }
    $scope = ''; $coverage = ''; $computed = $state.DataAtUtc; $count = -1; $members = 'None'; $formula = ''; $criteria = ''; $exclusions = ''
    $key = [string]$Item.Key
    if ($Board -eq 'Fleet') {
        $last = $script:FleetLast
        if ($null -ne $last) {
            $where = if ([string]$last.Scope) { [string]$last.Scope + $(if ([bool]$last.Subtree) { ' et ses sous-OU' } else { ' sans ses sous-OU' }) } else { 'Tout le domaine indexé (consultation)' }
            $scope = $where + ' · ' + [string]@($last.Targets).Count + ' compte(s) activé(s) sur ' + [string]@($last.Machines).Count + ' recensé(s) dans la base locale.'
            $freshness = Get-DomeniaMemberValue $last 'Freshness'
            $at = Get-DomeniaMemberValue $freshness 'ComputedAtUtc'
            if ($at -is [datetime]) { $computed = $at }
            $targets = Get-DomeniaMemberValue $last 'WidgetTargets'
            if (([string]$Item.Source -eq 'Builtin') -and ($targets -is [Collections.IDictionary]) -and (Test-DomeniaDictionaryKey $targets $key)) { $count = @($targets[$key]).Count; $members = 'Exact' }
        }
        # Probes and saved queries keep no frozen list: Afficher les postes evaluates them again from the snapshot shown.
        if ([string]$Item.Source -in @('Probe','Query')) { $members = 'Recomputed' }
    } elseif ($null -ne $script:SelectedObject) {
        $scope = $(if ($Board -eq 'Software') { 'Logiciels du poste ' } else { 'Poste ' }) + [string]$script:SelectedObject.Name + ' (' + [string]$script:SelectedObject.DN + ').'
        $members = 'Selected'
    }
    if ([string]$Item.Source -eq 'Probe') {
        $probe = Get-DomeniaProbe -Id $key
        if ($null -ne $probe) {
            # Documented catalog entry: class, namespace, properties and the limitations of the projection.
            $probeSource = Get-DomeniaProbeWidgetSource -Probe $probe -Board $Board
            $formula = [string]$probeSource.Formula; $criteria = [string]$probeSource.Criteria; $exclusions = [string]$probeSource.Exclusions
            if ($Board -eq 'Fleet') {
                # The coverage computed by the query worker with this very figure: the fleet is never aggregated
                # again on the interface thread to explain it.
                $coverage = [string](Get-DomeniaMember $resolved.Entry 'Subtitle' '')
            } else {
                # One workstation: its own stored observation only.
                $coverageInfo = Get-DomeniaWidgetCoverage -Board $Board -ProbeId $key
                if ($null -ne $coverageInfo) { $coverage = [string]$coverageInfo.Text }
            }
        }
    } elseif ([string]$Item.Source -eq 'Query') {
        $recipe = Get-DomeniaWidgetRecipe -Id $key
        if ($null -ne $recipe) {
            $formula = 'Postes qui correspondent à la requête enregistrée « ' + [string]$recipe.Name + ' ».'
            $clauses = @(@(Get-DomeniaMember $recipe 'Clauses' @()) | ForEach-Object { [string](Get-DomeniaMember $_ 'Field' '') + ' ' + [string](Get-DomeniaMember $_ 'Operator' '') + $(if ($null -ne (Get-DomeniaMember $_ 'Value')) { ' ' + [string](Get-DomeniaMember $_ 'Value') } else { '' }) })
            $criteria = $(if ($clauses.Count) { ($clauses -join $(if ([string](Get-DomeniaMember $recipe 'Junction' 'All') -eq 'Any') { ' OU ' } else { ' ET ' })) + '.' } else { 'Conditions de la requête : voir lʼatelier.' })
            $exclusions = 'Postes dont une information manque ou a expiré : comptés inconnus, jamais correspondants.'
        }
    } elseif (($Board -eq 'Fleet') -and ($key -eq 'fleet.health')) {
        $coverage = [string](Get-DomeniaHealthValue $state.Data 'HealthCoverage' '')
    }
    if ((-not $coverage) -and ($null -ne $resolved.Entry) -and ([string]$need.Kind -eq 'Remote')) { $coverage = [string]$resolved.Entry.Detail }
    return Get-DomeniaWidgetExplanation -Board $Board -Item $Item -Title ([string]$resolved.Title) -Entry $resolved.Entry -Need $need -Scope $scope -Coverage $coverage -ComputedAtUtc $computed -TargetCount $count -Members $members -Formula $formula -Criteria $criteria -Exclusions $exclusions -MaxAgeDays $maxAge
}
function Show-DomeniaWidgetExplanation {
    # Point 6: one panel in the page per figure: formula, perimeter, criteria, exclusions, coverage, dates and the
    # workstations of the total, with the exact list and the refresh of this widget at hand.
    param([string]$Board,[string]$Id)
    $weItem = @(Get-DomeniaBoardLayout -Board $Board | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1)
    if (-not $weItem.Count) { return }
    $weItem = $weItem[0]
    # Point 73: timers keep running while the panel is open; Afficher les postes opens only the calculation that
    # this panel explains, a newer one is refused and the board redrawn.
    $weSnapshot = if ($Board -eq 'Fleet') { [string]$script:FleetQuerySnapshotKey } else { '' }
    $weData = Get-DomeniaWidgetExplanationData -Board $Board -Item $weItem
    $weWindow = [Windows.Window]::new(); $weWindow.Title = 'Comprendre ce chiffre : ' + [string]$weData.Title; $weWindow.Width = 760; $weWindow.Height = 560
    $weRoot = [Windows.Controls.DockPanel]::new(); $weRoot.Margin = [Windows.Thickness]::new(12)
    $weButtons = [Windows.Controls.StackPanel]::new(); $weButtons.Orientation = 'Horizontal'; $weButtons.HorizontalAlignment = 'Right'; $weButtons.Margin = [Windows.Thickness]::new(0, 12, 0, 0)
    [Windows.Controls.DockPanel]::SetDock($weButtons, [Windows.Controls.Dock]::Bottom)
    $weResult = @{ Action = '' }
    $weAdd = {
        param([string]$Text,[string]$Tip,[string]$Action,[string]$Style)
        $button = [Windows.Controls.Button]::new(); $button.Content = $Text; $button.ToolTip = $Tip; $button.MinWidth = 120; $button.MinHeight = 30; $button.Margin = [Windows.Thickness]::new(10, 0, 0, 0)
        $button.SetResourceReference([Windows.Controls.Control]::StyleProperty, $Style)
        [Windows.Automation.AutomationProperties]::SetName($button, $Text)
        $button.Tag = $Action
        $button.Add_Click({ param($s,$e) $weResult.Action = [string]$s.Tag; Set-DomeniaSurfaceResult $weWindow $true })
        [void]$weButtons.Children.Add($button)
    }
    if (($Board -eq 'Fleet') -and ([string]$weData.Members -eq 'Exact')) { & $weAdd 'Afficher les postes' 'Ouvre la liste exacte des postes de ce chiffre, sans nouvelle lecture.' 'Details' 'SecondaryButton' }
    elseif (($Board -eq 'Fleet') -and ([string]$weData.Members -eq 'Recomputed')) { & $weAdd 'Afficher les postes' 'Recalcule la liste des postes de ce chiffre depuis le calcul affiché, sans nouvelle lecture.' 'Details' 'SecondaryButton' }
    if (-not (Test-DomeniaBoardItemPaused -Item $weItem)) { & $weAdd 'Actualiser ce widget' 'Relit seulement ce que ce widget affiche, pour son périmètre.' 'Refresh' 'SecondaryButton' }
    & $weAdd 'Fermer' 'Ferme cette explication.' '' 'RunButton'
    [void]$weRoot.Children.Add($weButtons)
    $weGrid = [Windows.Controls.DataGrid]::new(); $weGrid.IsReadOnly = $true; $weGrid.AutoGenerateColumns = $false; $weGrid.CanUserAddRows = $false; $weGrid.CanUserDeleteRows = $false; $weGrid.HeadersVisibility = 'Column'
    [Windows.Automation.AutomationProperties]::SetName($weGrid, 'Explication du chiffre')
    $weAspect = [Windows.Controls.DataGridTextColumn]::new(); $weAspect.Header = 'Élément'; $weAspect.Binding = [Windows.Data.Binding]::new('Aspect'); $weAspect.Width = [Windows.Controls.DataGridLength]::new(170)
    $weText = [Windows.Controls.DataGridTextColumn]::new(); $weText.Header = 'Explication'; $weText.Binding = [Windows.Data.Binding]::new('Text'); $weText.Width = [Windows.Controls.DataGridLength]::new(1, [Windows.Controls.DataGridLengthUnitType]::Star)
    $weWrap = [Windows.Style]::new([Windows.Controls.TextBlock]); [void]$weWrap.Setters.Add([Windows.Setter]::new([Windows.Controls.TextBlock]::TextWrappingProperty, [Windows.TextWrapping]::Wrap)); $weText.ElementStyle = $weWrap
    [void]$weGrid.Columns.Add($weAspect); [void]$weGrid.Columns.Add($weText)
    $weGrid.ItemsSource = @($weData.Rows)
    [void]$weRoot.Children.Add($weGrid)
    $weWindow.Content = $weRoot
    [void](Show-DomeniaEmbeddedWindow $weWindow)
    switch ([string]$weResult.Action) {
        'Details' { Invoke-DomeniaBoardAction -Tag @{ Board = $Board; Id = $Id; Action = 'Details'; Snapshot = $weSnapshot } }
        'Refresh' { [void](Start-DomeniaWidgetRefresh -Board $Board -Id $Id -Reason Refresh) }
    }
}
