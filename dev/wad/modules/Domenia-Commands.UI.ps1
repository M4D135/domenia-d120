# W13 (points 115, 117, 120): command palette in the page, discoverable shortcuts and presentation undo of the result
# list. The rules live in Domenia-Commands.Model.ps1; this adapter reads the page and applies their decisions.
$script:CommandPalette=$null
$script:DomeniaCommandsModuleRoot=$PSScriptRoot
$script:DomeniaPaletteReturnFocus=$null
$script:DomeniaPaletteFocusTarget=$null
$script:DomeniaPresentationHistory=$null
$script:DomeniaPresentationApplying=$false
$script:DomeniaPresentationTimer=$null

# ---------------------------------------------------------------- reach of a control of the page
function Get-DomeniaControlReach {
    # A control can be reached when it and every ancestor are shown (a tab of another profile or object type is
    # collapsed). Path: the tabs and expanders to open on the way, outermost first.
    param($Control)
    $path = New-Object 'System.Collections.Generic.List[object]'
    $reachable = ($null -ne $Control)
    $node = $Control; $guard = 0
    while (($null -ne $node) -and ($guard -lt 256)) {
        $guard++
        if (($node -is [Windows.UIElement]) -and ($node.Visibility -ne [Windows.Visibility]::Visible)) { $reachable = $false }
        if (($node -is [Windows.Controls.TabItem]) -or ($node -is [Windows.Controls.Expander])) { $path.Insert(0,$node) }
        $node = [Windows.LogicalTreeHelper]::GetParent($node)
    }
    return [pscustomobject]@{Reachable=$reachable;Path=$path.ToArray()}
}

function Show-DomeniaControlInPage {
    # Brings a control forward: its workspace through Select-DomeniaWorkspace (profile and Expert rules), its inner
    # tabs, its expanders, then the focus once the layout is done. Never clicks it. $false when it cannot be reached.
    param([string]$Name)
    $control = Get-DomeniaControl $Name
    if ($null -eq $control) { return $false }
    $reach = Get-DomeniaControlReach $control
    if (-not [bool]$reach.Reachable) { return $false }
    $workspaces = Get-DomeniaControl 'WorkspaceTabs'
    foreach ($item in @($reach.Path)) {
        if ($item -is [Windows.Controls.Expander]) { $item.IsExpanded = $true; continue }
        if (($null -ne $workspaces) -and $workspaces.Items.Contains($item) -and [string]$item.Name) {
            Select-DomeniaWorkspace -Workspace ([string]$item.Name)
            if (-not [bool]$item.IsSelected) { return $false }
            continue
        }
        $item.IsSelected = $true
    }
    $script:DomeniaPaletteFocusTarget = $control
    try {
        [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded,[Action]{
            try {
                $target = $script:DomeniaPaletteFocusTarget; $script:DomeniaPaletteFocusTarget = $null
                if ($null -ne $target) { $target.BringIntoView(); [void]$target.Focus() }
            } catch { }
        })
    } catch { }
    return $true
}

# ---------------------------------------------------------------- palette (point 117)
function Get-DomeniaPaletteContext {
    # What the palette needs to judge each command: selection, connection, mode and the state of the target buttons
    # (shown, enabled, their reason when disabled). Read from the page only; nothing is queried.
    $type = ''
    try { if ($null -ne $script:SelectedObject) { $type = [string]$script:SelectedObject.Type } } catch { $type = '' }
    $machines = 0
    try { $machines = @(Get-DomeniaSelectedMachineRows).Count } catch { $machines = 0 }
    $connected = $false
    try { $connected = (($null -ne $script:Conn) -and (-not [string]::IsNullOrWhiteSpace([string]$script:Conn.BaseDn))) } catch { $connected = $false }
    $controls = @{}
    foreach ($command in @(Get-DomeniaCommandCatalogue)) {
        $name = [string]$command.Target
        if ((-not $name) -or $controls.ContainsKey($name)) { continue }
        $control = Get-DomeniaControl $name
        if ($null -eq $control) { continue }
        $reach = Get-DomeniaControlReach $control
        $tip = ''
        if ($control.ToolTip -is [string]) { $tip = [string]$control.ToolTip }
        $controls[$name] = [pscustomobject]@{Reachable=[bool]$reach.Reachable;Enabled=[bool]$control.IsEnabled;ToolTip=$tip}
    }
    $undoText = ''
    try { $undoText = Get-DomeniaPresentationUndoText $script:DomeniaPresentationHistory } catch { $undoText = '' }
    return [pscustomobject]@{Connected=$connected;SelectionType=$type;MachineRows=$machines;ReadOnly=[bool]$script:ReadOnlyMode;Demo=[bool]$script:DemoMode;UndoAvailable=([bool]$undoText);UndoText=$undoText;Controls=$controls}
}

function Initialize-DomeniaCommandPalette {
    # The palette view (Domenia-CommandPalette.xaml) is loaded once, at its first opening, in DomeniaDialogLayer:
    # same model as the operations panel (Initialize-DomeniaOperationsPanel). No window is created.
    if ($null -ne $script:CommandPalette) { return $true }
    if ($null -eq $script:Window) { return $false }
    $layer = $script:Window.FindName('DomeniaDialogLayer')
    if ($null -eq $layer) { return $false }
    $path = Join-Path $script:DomeniaCommandsModuleRoot 'Domenia-CommandPalette.xaml'
    [xml]$document = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    $reader = New-Object Xml.XmlNodeReader $document
    try { $view = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    foreach ($element in $document.SelectNodes('//*')) {
        $name = $element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $control = if ($name -eq [string]$view.Name) { $view } else { $view.FindName($name) }
        if (($null -ne $control) -and ($null -ne $script:Ctrl)) { $script:Ctrl[$name] = $control }
    }
    $search = $view.FindName('TxtPaletteSearch'); $list = $view.FindName('LstPaletteCommands')
    $search.Add_TextChanged({ Update-DomeniaCommandPaletteList })
    $search.Add_PreviewKeyDown({ param($sender,$eventArgs) Invoke-DomeniaCommandPaletteKey -KeyEvent $eventArgs })
    $list.Add_PreviewKeyDown({ param($sender,$eventArgs) Invoke-DomeniaCommandPaletteKey -KeyEvent $eventArgs -FromList })
    $list.Add_SelectionChanged({ Update-DomeniaCommandPaletteDetail })
    $list.Add_MouseDoubleClick({
        param($sender,$eventArgs)
        # Only a double click on an item runs it, never one on the scroll bar or the empty space.
        $node = $eventArgs.OriginalSource
        while (($null -ne $node) -and ($node -isnot [Windows.Controls.ListBoxItem])) {
            if ($node -is [Windows.Media.Visual]) { $node = [Windows.Media.VisualTreeHelper]::GetParent($node) }
            elseif ($node -is [Windows.DependencyObject]) { $node = [Windows.LogicalTreeHelper]::GetParent($node) }
            else { $node = $null }
        }
        if ($node -is [Windows.Controls.ListBoxItem]) { $eventArgs.Handled = $true; Invoke-DomeniaCommandPaletteEntry -Row $node.DataContext }
    })
    $view.FindName('BtnPaletteClose').Add_Click({ Hide-DomeniaCommandPalette })
    # A click beside the palette (on the transparent layer itself) closes it, like the operations panel.
    $layer.Add_MouseLeftButtonDown({ param($sender,$eventArgs) if ([object]::ReferenceEquals($eventArgs.OriginalSource,$sender) -and (Test-DomeniaCommandPaletteOpen)) { $eventArgs.Handled = $true; Hide-DomeniaCommandPalette } })
    $script:CommandPalette = [pscustomobject]@{View=$view;Layer=$layer;Open=$false;Entries=@();Context=$null}
    return $true
}

function Set-DomeniaCommandPalettePosition {
    # Centred near the top of the page, inside the window whatever its width and height (RDP, zoom).
    $palette = $script:CommandPalette
    if ($null -eq $palette) { return }
    $width = 640.0; $left = 16.0; $top = 56.0
    try {
        $layerWidth = [double]$palette.Layer.ActualWidth
        if ($layerWidth -gt 0) { $width = [Math]::Min(640.0,[Math]::Max(300.0,$layerWidth - 32)); $left = [Math]::Max(16.0,($layerWidth - $width) / 2) }
        $layerHeight = [double]$palette.Layer.ActualHeight
        if ($layerHeight -gt 0) {
            $top = [Math]::Min($top,[Math]::Max(8.0,$layerHeight * 0.08))
            $palette.View.MaxHeight = [Math]::Max(200.0,$layerHeight - $top - 16)
        }
    } catch { }
    $palette.View.Width = $width
    $palette.View.Margin = [Windows.Thickness]::new($left,$top,0,0)
}

function Show-DomeniaCommandPaletteView {
    # Returns $false when the palette cannot open (no main window, or a sheet waiting for an answer holds the layer).
    $ready = $false
    try { $ready = Initialize-DomeniaCommandPalette } catch { Write-AppLog ('Palette de commandes indisponible : ' + $_.Exception.Message) 'WARN'; $ready = $false }
    if (-not $ready) { return $false }
    if (($null -ne $script:DomeniaSurfaceState) -and (-not $script:DomeniaSurfaceState.Done)) { return $false }
    try { if (Test-DomeniaOperationsPanelOpen) { Hide-DomeniaOperationsPanel } } catch { }
    $palette = $script:CommandPalette; $layer = $palette.Layer
    # The keyboard focus, or the logical focus of the window when it is not active, comes back on closing.
    $focused = [Windows.Input.Keyboard]::FocusedElement
    if ($null -eq $focused) { try { $focused = [Windows.Input.FocusManager]::GetFocusedElement($script:Window) } catch { $focused = $null } }
    $script:DomeniaPaletteReturnFocus = $focused
    if (-not $layer.Children.Contains($palette.View)) { $layer.Children.Clear(); [void]$layer.Children.Add($palette.View) }
    $layer.Background = [Windows.Media.Brushes]::Transparent
    $layer.Visibility = [Windows.Visibility]::Visible
    Set-DomeniaCommandPalettePosition
    $palette.Context = Get-DomeniaPaletteContext
    $palette.Entries = @(Get-DomeniaPaletteEntries -Context $palette.Context)
    $palette.Open = $true
    $search = Get-DomeniaControl 'TxtPaletteSearch'
    if ([string]$search.Text) { $search.Text = '' } else { Update-DomeniaCommandPaletteList }
    try { [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Input,[Action]{ try { $box = Get-DomeniaControl 'TxtPaletteSearch'; if ($null -ne $box) { [void]$box.Focus() } } catch { } }) } catch { }
    return $true
}

function Hide-DomeniaCommandPalette {
    # -KeepFocus: an action takes the focus itself (Show-DomeniaControlInPage); otherwise it goes back where it was.
    param([switch]$KeepFocus)
    $palette = $script:CommandPalette
    if (($null -eq $palette) -or (-not [bool]$palette.Open)) { return }
    $palette.Open = $false
    $layer = $palette.Layer
    if ($layer.Children.Contains($palette.View)) { [void]$layer.Children.Remove($palette.View) }
    if ($layer.Children.Count -eq 0) { $layer.Visibility = [Windows.Visibility]::Collapsed; $layer.ClearValue([Windows.Controls.Panel]::BackgroundProperty) }
    if ($KeepFocus) { return }
    $back = $script:DomeniaPaletteReturnFocus; $script:DomeniaPaletteReturnFocus = $null
    try {
        if (($back -is [Windows.UIElement]) -and $back.IsVisible) { [void]$back.Focus() }
        else { $button = Get-DomeniaControl 'BtnCommandPalette'; if ($null -ne $button) { [void]$button.Focus() } }
    } catch { }
}

function Test-DomeniaCommandPaletteOpen {
    return (($null -ne $script:CommandPalette) -and [bool]$script:CommandPalette.Open)
}

function Get-DomeniaPaletteGlyph {
    # The kind of action is read by a symbol and by the words of its line, not by a colour (point 116).
    param($Entry)
    if (-not [bool]$Entry.Available) { return [string][char]0x2298 }
    switch ([string]$Entry.Effect) {
        'Navigate' { return [string][char]0x2192 }
        'Read' { return [string][char]0x25B6 }
        'Sensitive' { return [string][char]0x2691 }
        'PrepareWrite' { return [string][char]0x270E }
    }
    return [string][char]0x2022
}

function Update-DomeniaCommandPaletteList {
    $palette = $script:CommandPalette
    if (($null -eq $palette) -or (-not [bool]$palette.Open)) { return }
    $list = Get-DomeniaControl 'LstPaletteCommands'
    $box = Get-DomeniaControl 'TxtPaletteSearch'
    if (($null -eq $list) -or ($null -eq $box)) { return }
    $query = [string]$box.Text
    $rows = @(foreach ($entry in @(Select-DomeniaPaletteEntries -Entries $palette.Entries -Query $query -Maximum 60)) {
        $line = [string]$entry.Group + ' · ' + (([string]$entry.Detail) -split "`r?`n")[0]
        $spoken = [string]$entry.Label + '. ' + [string]$entry.Group + '. ' + (([string]$entry.Detail) -replace "`r?`n",' ; ')
        if ([string]$entry.Shortcut) { $spoken += '. Raccourci ' + [string]$entry.Shortcut }
        [pscustomobject]@{Id=[string]$entry.Id;Label=[string]$entry.Label;Shortcut=[string]$entry.Shortcut;Available=[bool]$entry.Available;Glyph=(Get-DomeniaPaletteGlyph $entry);Line=$line;Spoken=$spoken;Entry=$entry}
    })
    $list.ItemsSource = $rows
    if ($rows.Count -gt 0) { $list.SelectedIndex = 0; $list.ScrollIntoView($list.SelectedItem) }
    $unavailable = @($rows | Where-Object { -not $_.Available }).Count
    $status = ''
    if ($rows.Count -eq 0) { $status = 'Aucune action ne correspond à « ' + (ConvertTo-DomeniaFlatText $query 40) + ' ». Effacez la saisie pour tout revoir.' }
    else { $status = [string]$rows.Count + ' action(s), dont ' + [string]$unavailable + ' indisponible(s) pour cette fiche ou ce mode. Entrée exécute, Échap ferme.' }
    [void](Set-DomeniaControlText 'LblPaletteStatus' $status)
    Update-DomeniaCommandPaletteDetail
}

function Update-DomeniaCommandPaletteDetail {
    $list = Get-DomeniaControl 'LstPaletteCommands'
    $text = ''
    if (($null -ne $list) -and ($null -ne $list.SelectedItem)) {
        $row = $list.SelectedItem
        $text = [string]$row.Label
        if ([string]$row.Shortcut) { $text += ' (' + [string]$row.Shortcut + ')' }
        $text += "`r`n" + [string]$row.Entry.Detail
    }
    [void](Set-DomeniaControlText 'LblPaletteDetail' $text)
}

function Invoke-DomeniaCommandPaletteKey {
    # In the field: arrows and page keys move the choice without leaving it. Everywhere: Entrée runs, Échap closes.
    param($KeyEvent,[switch]$FromList)
    if ($null -eq $KeyEvent) { return }
    $list = Get-DomeniaControl 'LstPaletteCommands'
    if ($null -eq $list) { return }
    $key = $KeyEvent.Key
    if ($key -eq [Windows.Input.Key]::Escape) { $KeyEvent.Handled = $true; Hide-DomeniaCommandPalette; return }
    if ($key -eq [Windows.Input.Key]::Enter) { $KeyEvent.Handled = $true; Invoke-DomeniaCommandPaletteEntry -Row $list.SelectedItem; return }
    if ($FromList) { return }
    $step = 0
    if ($key -eq [Windows.Input.Key]::Down) { $step = 1 } elseif ($key -eq [Windows.Input.Key]::Up) { $step = -1 }
    elseif ($key -eq [Windows.Input.Key]::PageDown) { $step = 8 } elseif ($key -eq [Windows.Input.Key]::PageUp) { $step = -8 }
    if (($step -eq 0) -or ($list.Items.Count -eq 0)) { return }
    $KeyEvent.Handled = $true
    $list.SelectedIndex = [Math]::Max(0,[Math]::Min($list.Items.Count - 1,$list.SelectedIndex + $step))
    $list.ScrollIntoView($list.SelectedItem)
}

function Invoke-DomeniaCommandPaletteEntry {
    # Runs the decision of Get-DomeniaPaletteDecision. An unavailable entry keeps the palette open and says why.
    param($Row)
    if ($null -eq $Row) { return }
    $entry = $Row.Entry
    if ([string]$entry.Id -ceq 'shortcuts') {
        Update-DomeniaCommandPaletteDetail
        [void](Set-DomeniaControlText 'LblPaletteStatus' 'Raccourcis clavier affichés ci-dessus. Échap ferme la palette.')
        return
    }
    $decision = Get-DomeniaPaletteDecision -Entry $entry
    if ([string]$decision.Action -eq 'None') { [void](Set-DomeniaControlText 'LblPaletteStatus' ([string]$decision.Status)); return }
    Hide-DomeniaCommandPalette -KeepFocus:([string]$decision.Action -ne 'Run')
    Invoke-DomeniaSafeUiAction -Operation ([string]$entry.Label) -Action { Invoke-DomeniaPaletteDecision -Entry $entry -Decision $decision }
}

function Invoke-DomeniaPaletteDecision {
    # Focus: the button is brought forward, never clicked (writes, protected reads). Click: an enabled read button,
    # checked again now. Run: an action of the shell.
    param($Entry,$Decision)
    $label = [string]$Entry.Label
    switch ([string]$Decision.Action) {
        'Focus' {
            if (-not (Show-DomeniaControlInPage -Name ([string]$Decision.Target))) { Set-Status ($label + ' : bouton non accessible dans cette vue ; rien nʼa été lancé.') 'WARN'; return }
            Set-Status ([string]$Decision.Status)
        }
        'Click' {
            if (-not (Show-DomeniaControlInPage -Name ([string]$Decision.Target))) { Set-Status ($label + ' : bouton non accessible dans cette vue ; rien nʼa été lancé.') 'WARN'; return }
            $button = Get-DomeniaControl ([string]$Decision.Target)
            if (($null -eq $button) -or (-not [bool]$button.IsEnabled) -or ($button -isnot [Windows.Controls.Primitives.ButtonBase])) { Set-Status ($label + ' : action devenue indisponible ; rien nʼa été lancé.') 'WARN'; return }
            $button.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }
        'Run' { Invoke-DomeniaPaletteCommand -Id ([string]$Entry.Id) }
    }
}

function Invoke-DomeniaPaletteCommand {
    # Actions of the shell offered by the palette, the same as their shortcuts and buttons.
    param([string]$Id)
    switch ($Id) {
        'search' {
            Select-DomeniaWorkspace -Workspace 'WsSearch'
            $box = Get-DomeniaControl 'TxtGlobalSearch'
            if ($null -ne $box) { [void]$box.Focus(); $box.SelectAll() }
        }
        'dashboard' { Select-DomeniaWorkspace -Workspace 'TabDashboard' }
        'operations' { [void](Show-DomeniaOperationsPanel) }
        'journal' { Invoke-DomeniaJournalShortcut }
        'index' { Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'TabIndex' }
        'queries' { Show-DomeniaQueryWorkshop }
        'accounts' { Select-DomeniaWorkspace -Workspace 'TabAccounts'; Update-DomeniaAccountUi }
        'relations' { Select-DomeniaWorkspace -Workspace 'TabRelations'; Refresh-LinkGrid }
        'tools' { Select-DomeniaWorkspace -Workspace 'TabApplicationTools' }
        'theme' { Toggle-DomeniaTheme }
        'undo' { Undo-DomeniaResultPresentation }
        'summary' { Copy-ObjectSummary }
        'parent' { Open-SelectedParentBranch }
        'diagnostic' { Export-DomeniaTechnicalDossier }
        'selfcheck' { Start-SelfCheck }
        'tree' { Load-TreeRoot -ForceRefresh }
        'batch' { Show-DomeniaBatchNetworkReport -Rows (Get-DomeniaSelectedMachineRows) }
    }
}

# ---------------------------------------------------------------- presentation undo of the result list (point 120)
function Get-DomeniaCurrentPresentation {
    # Columns and sort of the list (Get-DomeniaResultPresentation), its local filter and its presence filter.
    $presentation = Get-DomeniaResultPresentation
    $filterText = ''; $presenceText = ''
    $filter = Get-DomeniaControl 'TxtSuiteResultFilter'
    if ($null -ne $filter) { $filterText = [string]$filter.Text }
    $presence = Get-DomeniaControl 'CmbPresenceFilter'
    if (($null -ne $presence) -and ($null -ne $presence.SelectedItem)) { $presenceText = [string]$presence.SelectedItem.Content }
    return [pscustomobject]@{Columns=@($presentation.Columns);Sort=@($presentation.Sort);LocalFilter=$filterText;Presence=$presenceText}
}

function Initialize-DomeniaPresentationUndo {
    # Ten steps, Ctrl+Z in the list and an « Annuler » chip beside the filters, like the layout of the boards. A new
    # list (search) becomes the reference without a step; only presentation is undone, never an operation.
    if ($null -ne $script:DomeniaPresentationHistory) { return }
    $grid = Get-DomeniaControl 'DgObjects'
    if ($null -eq $grid) { return }
    $script:DomeniaPresentationHistory = New-DomeniaPresentationHistory -Maximum 10
    [void](Add-DomeniaPresentationState -History $script:DomeniaPresentationHistory -State (Get-DomeniaCurrentPresentation))
    $script:DomeniaPresentationTimer = New-DomeniaTimer -Owner 'Timer:PresentationUndo' -IntervalMs 900 -Tick { $script:DomeniaPresentationTimer.Stop(); Save-DomeniaPresentationStep }
    $grid.Add_ColumnReordered({ Request-DomeniaPresentationStep -Soon })
    $grid.Add_Sorting({ Request-DomeniaPresentationStep -Soon })
    $grid.Add_PreviewMouseLeftButtonUp({ Request-DomeniaPresentationStep -Soon })
    $grid.Add_PreviewKeyDown({
        param($sender,$eventArgs)
        if (($eventArgs.Key -eq [Windows.Input.Key]::Z) -and ([Windows.Input.Keyboard]::Modifiers -eq [Windows.Input.ModifierKeys]::Control) -and ($eventArgs.OriginalSource -isnot [Windows.Controls.Primitives.TextBoxBase])) {
            $eventArgs.Handled = $true; Undo-DomeniaResultPresentation
        }
    })
    $filter = Get-DomeniaControl 'TxtSuiteResultFilter'
    if ($null -ne $filter) { $filter.Add_TextChanged({ Request-DomeniaPresentationStep }) }
    $presence = Get-DomeniaControl 'CmbPresenceFilter'
    if ($null -ne $presence) { $presence.Add_SelectionChanged({ Request-DomeniaPresentationStep -Soon }) }
    $descriptor = [ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.ItemsControl]::ItemsSourceProperty,[Windows.Controls.DataGrid])
    if ($null -ne $descriptor) { $descriptor.AddValueChanged($grid,[EventHandler]{ param($sender,$eventArgs) Request-DomeniaPresentationRebase }) }
}

function Request-DomeniaPresentationStep {
    # -Soon: after the current input (a sort or a column drag is applied after its event); otherwise once the typing
    # of the filter stopped for 900 ms, so that a word is one step, not one step per letter.
    param([switch]$Soon)
    if ([bool]$script:DomeniaPresentationApplying -or ($null -eq $script:DomeniaPresentationHistory)) { return }
    if ($Soon) {
        try { [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,[Action]{ Save-DomeniaPresentationStep }) } catch { }
        return
    }
    if ($null -ne $script:DomeniaPresentationTimer) { $script:DomeniaPresentationTimer.Stop(); $script:DomeniaPresentationTimer.Start() }
}

function Request-DomeniaPresentationRebase {
    # A new list: its presentation becomes the reference once its sort is set (Begin-DomeniaLiveSearch), no step.
    if ($null -eq $script:DomeniaPresentationHistory) { return }
    try {
        [void]$script:Window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ApplicationIdle,[Action]{
            try { if (-not [bool]$script:DomeniaPresentationApplying) { Reset-DomeniaPresentationCurrent -History $script:DomeniaPresentationHistory -State (Get-DomeniaCurrentPresentation) } } catch { }
        })
    } catch { }
}

function Save-DomeniaPresentationStep {
    if ([bool]$script:DomeniaPresentationApplying -or ($null -eq $script:DomeniaPresentationHistory)) { return }
    try {
        if (Add-DomeniaPresentationState -History $script:DomeniaPresentationHistory -State (Get-DomeniaCurrentPresentation)) { Update-DomeniaSearchFilterChips }
    } catch { Write-AppLog ('Annulation de présentation : ' + $_.Exception.Message) 'WARN' }
}

function Undo-DomeniaResultPresentation {
    # Gives back the previous presentation of the list: columns, sort, local filter, presence filter. A filter still
    # being typed is recorded first, so Ctrl+Z gives back the list before it.
    $history = $script:DomeniaPresentationHistory
    if ($null -eq $history) { return }
    if ($null -ne $script:DomeniaPresentationTimer) { $script:DomeniaPresentationTimer.Stop() }
    Save-DomeniaPresentationStep
    $step = Undo-DomeniaPresentationState -History $history
    if ($null -eq $step) { Set-Status 'Aucune présentation de la liste à annuler.'; return }
    $script:DomeniaPresentationApplying = $true
    try {
        Restore-DomeniaResultPresentation ([pscustomobject]@{Columns=@($step.State.Columns);Sort=@($step.State.Sort)})
        $filter = Get-DomeniaControl 'TxtSuiteResultFilter'
        if (($null -ne $filter) -and ([string]$filter.Text -cne [string]$step.State.LocalFilter)) { $filter.Text = [string]$step.State.LocalFilter }
        $presence = Get-DomeniaControl 'CmbPresenceFilter'
        if ($null -ne $presence) {
            $current = ''
            if ($null -ne $presence.SelectedItem) { $current = [string]$presence.SelectedItem.Content }
            if ($current -cne [string]$step.State.Presence) {
                foreach ($item in @($presence.Items)) { if ([string]$item.Content -ceq [string]$step.State.Presence) { $presence.SelectedItem = $item; break } }
            }
        }
        # The saved column layout follows the list, as after a drag of the operator.
        $grid = Get-DomeniaControl 'DgObjects'
        if ($null -ne $grid) { try { Save-DomeniaGridLayout $grid } catch { } }
    }
    finally { $script:DomeniaPresentationApplying = $false }
    Update-DomeniaSearchFilterChips
    Set-Status ('Présentation de la liste rétablie (' + [string]$step.Text + '). Aucune opération sur lʼannuaire nʼest annulée.')
}

function New-DomeniaPresentationUndoChip {
    # The « Annuler » chip beside the filters says what it gives back; $null when there is nothing to undo.
    $text = ''
    try { $text = Get-DomeniaPresentationUndoText $script:DomeniaPresentationHistory } catch { $text = '' }
    if (-not $text) { return $null }
    $help = 'Revient à la présentation précédente de la liste (' + $text + '). Ctrl+Z dans la liste fait de même. Aucune opération sur lʼannuaire nʼest annulée.'
    $button = [Windows.Controls.Button]::new()
    $button.Content = [string][char]0x21B6 + ' Annuler : ' + $text
    $button.Margin = '0,0,6,4'; $button.Padding = '8,2'
    $button.ToolTip = $help
    [Windows.Controls.ToolTipService]::SetShowOnDisabled($button,$true)
    [Windows.Automation.AutomationProperties]::SetName($button,('Annuler la présentation : ' + $text))
    [Windows.Automation.AutomationProperties]::SetHelpText($button,$help)
    $button.Add_Click({ Undo-DomeniaResultPresentation })
    return $button
}
