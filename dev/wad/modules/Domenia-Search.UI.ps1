# Search and navigation surfaces of the Rechercher page: syntax hint, work views, back and forward.
# Decisions come from Domenia-Search.Model.ps1. Nothing here contacts the directory or a workstation by itself:
# a search starts only from an explicit operator gesture, through Invoke-GlobalSearch.
$script:SearchUiInitialized = $false
$script:NavHistory = $null
$script:NavRestoring = $false

function Update-DomeniaSearchHint {
    # D033/D036: explains what the upper bar will search (explicit tokens, pasted identifier, unknown prefix).
    # Text parsing only: no request, no hidden filter.
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    if ($null -eq $box) { return }
    $text = ([string]$box.Text).Trim()
    $hint = ''
    if ($text -and $text -ne '*') {
        $minimum = [Math]::Max(1,[int](Get-CfgValue 'Browser' 'GlobalSearchMinChars' 2))
        $plan = Get-DomeniaGlobalSearchPlan -Text $text -TypeFilter (Get-TypeLdapFilter -Type 'Tous') -MinimumLength $minimum -SyntaxEnabled (Get-DomeniaFeatureFlag -Name 'SearchSyntax' -Default $true)
        $hint = [string]$plan.Hint
    }
    [void](Set-DomeniaControlText -Name 'LblSearchHint' -Text $hint)
}

function Update-DomeniaWorkViewList {
    # D038: ready-made read-only views. Choosing one in the list starts nothing.
    $combo = Get-DomeniaControl 'CmbWorkView'
    if ($null -eq $combo) { return }
    $combo.Items.Clear()
    foreach ($view in @(Get-DomeniaWorkViews)) {
        $item = [Windows.Controls.ComboBoxItem]::new()
        $item.Content = [string]$view.Name
        $item.Tag = [string]$view.Id
        $tip = [string]$view.Note
        if (-not $tip) { $tip = 'Vue en lecture seule.' }
        if ([bool]$view.NeedsOu) { $tip += ' Périmètre : OU sélectionnée.' } else { $tip += ' Périmètre : domaine entier.' }
        $item.ToolTip = $tip
        [void]$combo.Items.Add($item)
    }
}

function Invoke-DomeniaWorkView {
    # D038: explicit gesture only. The view carries a filter and a type: never an account, a right or a write mode.
    param([string]$ViewId='')
    if (-not $ViewId) {
        $combo = Get-DomeniaControl 'CmbWorkView'
        if ($null -ne $combo -and $null -ne $combo.SelectedItem) { $ViewId = [string]$combo.SelectedItem.Tag }
    }
    if (-not $ViewId) { Set-Status 'Choisissez dʼabord une vue de travail dans la liste.' 'WARN'; return }
    Invoke-GlobalSearch -ViewId $ViewId
}

function Get-DomeniaGridScrollViewer {
    param($Grid)
    if ($null -eq $Grid -or $Grid -isnot [Windows.DependencyObject]) { return $null }
    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($Grid)
    $visited = 0
    while ($queue.Count -gt 0 -and $visited -lt 200) {
        $node = $queue.Dequeue(); $visited++
        if ($node -is [Windows.Controls.ScrollViewer]) { return $node }
        $count = 0
        try { $count = [Windows.Media.VisualTreeHelper]::GetChildrenCount($node) } catch { $count = 0 }
        for ($i = 0; $i -lt $count; $i++) { $queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($node,$i)) }
    }
    return $null
}

function Get-DomeniaNavSnapshot {
    # D040: what the operator sees on a page, kept in memory only. No secret, no credential, no request.
    param([string]$Page='')
    if (-not $Page) {
        $tabs = Get-DomeniaControl 'WorkspaceTabs'
        try { if ($null -ne $tabs -and $null -ne $tabs.SelectedItem) { $Page = [string]$tabs.SelectedItem.Name } } catch { }
    }
    $grid = Get-DomeniaControl 'DgObjects'
    $selected = $null; $rows = $null; $scroll = -1.0
    if ($null -ne $grid) {
        try { $selected = $grid.SelectedItem; $rows = $grid.ItemsSource } catch { }
        try { $viewer = Get-DomeniaGridScrollViewer $grid; if ($null -ne $viewer) { $scroll = [double]$viewer.VerticalOffset } } catch { }
    }
    $inner = ''
    if ($Page -eq 'WsObject') {
        $detail = Get-DomeniaControl 'DetailTabs'
        try { if ($null -ne $detail -and $null -ne $detail.SelectedItem) { $inner = [string]$detail.SelectedItem.Name } } catch { }
    }
    $subtree = Get-DomeniaControl 'ChkSubtree'
    $count = Get-DomeniaControl 'LblBranchCount'
    $selectionGuid = ''; $selectionDn = ''
    if ($null -ne $selected) {
        try { $selectionDn = [string]$selected.DN } catch { }
        try { if ($null -ne $selected.PSObject.Properties['Guid']) { $selectionGuid = [string]$selected.Guid } } catch { }
    }
    $objectDn = ''
    if ($null -ne $script:SelectedObject) { $objectDn = [string]$script:SelectedObject.DN }
    return [pscustomobject]@{
        Page=$Page;Tab=$inner;Mode=(Get-DomeniaSearchMode)
        Text=(Get-DomeniaSearchText -Mode Global);BranchText=(Get-DomeniaSearchText -Mode OU)
        OuDn=[string]$script:SelectedBranchDn;Subtree=$(if ($null -ne $subtree) { [bool]$subtree.IsChecked } else { $true })
        SelectionGuid=$selectionGuid;SelectionDn=$selectionDn;Rows=$rows;Scroll=$scroll
        CountLabel=$(if ($null -ne $count) { [string]$count.Text } else { '' })
        Generation=[int]$script:GlobalSearchGeneration;ViewId=[string]$script:ActiveSearchViewId
        ObjectDn=$objectDn;At=[datetime]::UtcNow
    }
}

function Update-DomeniaNavButtons {
    $h = $script:NavHistory
    $back = Get-DomeniaControl 'BtnNavBack'
    $forward = Get-DomeniaControl 'BtnNavForward'
    if ($null -ne $back) { $back.IsEnabled = ($null -ne $h -and $h.Back.Count -gt 0) }
    if ($null -ne $forward) { $forward.IsEnabled = ($null -ne $h -and $h.Forward.Count -gt 0) }
}

function Register-DomeniaNavLocation {
    # Called by the real WorkspaceTabs.SelectionChanged: the page being left is refreshed, the new one recorded.
    param([string]$From='',[string]$To='')
    if ($script:NavRestoring -or $null -eq $script:NavHistory -or -not $To) { return }
    $h = $script:NavHistory
    if ($From -and $null -ne $h.Current -and [string]$h.Current.Page -eq $From) { $h.Current = Get-DomeniaNavSnapshot -Page $From }
    [void](Push-DomeniaNavState $h (Get-DomeniaNavSnapshot -Page $To))
    Update-DomeniaNavButtons
}

function Restore-DomeniaNavState {
    # Shows a remembered place again from memory. Never a search, a ping, a probe or a fiche read.
    param($State)
    if ($null -eq $State) { return }
    $script:NavRestoring = $true
    $oldRestoring = [bool]$script:RestoringSettings
    $oldSuppress = [bool]$script:SuppressBranchAutoLoad
    $script:RestoringSettings = $true
    $script:SuppressBranchAutoLoad = $true
    try {
        $grid = Get-DomeniaControl 'DgObjects'
        $otherRows = ($null -ne $grid -and $null -ne $State.Rows -and -not [object]::ReferenceEquals($grid.ItemsSource,$State.Rows))
        # Another list is displayed now: stop following it before showing the remembered rows.
        if ($otherRows) { Invalidate-DomeniaSearchResults }
        [void](Set-DomeniaControlText -Name 'TxtGlobalSearch' -Text ([string]$State.Text))
        [void](Set-DomeniaControlText -Name 'TxtBranchSearch' -Text ([string]$State.BranchText))
        try { if ($null -ne $script:LiveSearchTimer) { $script:LiveSearchTimer.Stop() } } catch { }
        $script:SelectedBranchDn = [string]$State.OuDn
        $check = Get-DomeniaControl 'ChkSubtree'
        if ($null -ne $check) { $check.IsChecked = [bool]$State.Subtree }
        Set-DomeniaSearchMode -Mode $(if ([string]$State.Mode -eq 'Global') { 'Global' } else { 'OU' })
        $script:ActiveSearchViewId = [string]$State.ViewId
        Update-DomeniaSearchScopeUi
        if ($otherRows) {
            $suppressed = [bool]$script:SuppressGridSelectionEvents
            $script:SuppressGridSelectionEvents = $true
            try {
                $grid.ItemsSource = $State.Rows
                $script:BranchObjects = $State.Rows
                $grid.SelectedItem = $null
                $match = $null
                if ($State.SelectionDn) { foreach ($row in @($grid.Items)) { if ([string]$row.DN -ieq [string]$State.SelectionDn) { $match = $row; break } } }
                if ($null -ne $match) { $grid.SelectedItem = $match }
                try {
                    $grid.UpdateLayout()
                    $viewer = Get-DomeniaGridScrollViewer $grid
                    if ($null -ne $viewer -and [double]$State.Scroll -ge 0) { $viewer.ScrollToVerticalOffset([double]$State.Scroll) }
                    elseif ($null -ne $match) { $grid.ScrollIntoView($match) }
                } catch { }
            }
            finally { $script:SuppressGridSelectionEvents = $suppressed }
            # The freshness of the remembered list is kept and stated as history.
            $script:BranchCountLabel = ([string]$State.CountLabel) + ' · historique, non relu'
            [void](Set-DomeniaControlText -Name 'LblBranchCount' -Text $script:BranchCountLabel)
        }
        $inner = ''
        if ([string]$State.Tab) { $inner = 'DetailTabs' }
        Select-DomeniaWorkspace -Workspace ([string]$State.Page) -Inner $inner -Tab ([string]$State.Tab)
    }
    finally {
        $script:RestoringSettings = $oldRestoring
        $script:SuppressBranchAutoLoad = $oldSuppress
        $script:NavRestoring = $false
    }
    if ([string]$State.Page -in @('WsObject','WsComputer') -and [string]$State.ObjectDn -and ($null -eq $script:SelectedObject -or [string]$script:SelectedObject.DN -ine [string]$State.ObjectDn)) {
        Set-Status 'La fiche de cette étape nʼest plus chargée : sélectionnez sa ligne pour la relire. Aucune lecture automatique.' 'WARN'
    }
}

function Invoke-DomeniaNavStep {
    # D040: back or forward. Refused while a write is active or while an unsaved draft waits for a decision.
    param([ValidateSet('Back','Forward')][string]$Direction='Back')
    $h = $script:NavHistory
    if ($null -eq $h) { return $null }
    if (Test-DomeniaAccessBusyWrite) { Set-Status 'Navigation différée : une écriture est active ou à vérifier.' 'WARN'; return $null }
    # The place being left is refreshed so that the opposite step finds it as it is now.
    if ($null -ne $h.Current) { $h.Current = Get-DomeniaNavSnapshot }
    $dirty = @(Get-DomeniaDirtyFields)
    $step = Step-DomeniaNavHistory -History $h -Direction $Direction -HasDraft ($dirty.Count -gt 0) -DraftDecisionTaken $false
    if ([bool]$step.Blocked) { Set-Status ([string]$step.Reason) 'WARN'; Update-DomeniaNavButtons; return $step }
    if (-not [bool]$step.Moved) { if ([string]$step.Reason) { Set-Status ([string]$step.Reason) }; Update-DomeniaNavButtons; return $step }
    Restore-DomeniaNavState -State $step.State
    Update-DomeniaNavButtons
    return $step
}

function Initialize-DomeniaSearchUi {
    if ($script:SearchUiInitialized) { return }
    $script:SearchUiInitialized = $true
    $script:NavHistory = New-DomeniaNavHistory -Capacity 40
    $script:NavRestoring = $false
    if ((Get-DomeniaControl 'CmbWorkView') -is [Windows.Controls.ComboBox]) { Update-DomeniaWorkViewList }
    $more = Get-DomeniaControl 'BtnSearchMore'
    if ($more -is [Windows.Controls.Primitives.ButtonBase]) { $more.Add_Click({ try { Invoke-DomeniaSearchMore } catch { Write-AppLog ('Charger la suite : '+$_.Exception.Message) 'ERROR'; Set-Status ('Suite non chargée : '+$_.Exception.Message) 'ERROR' } }) }
    $viewButton = Get-DomeniaControl 'BtnWorkView'
    if ($viewButton -is [Windows.Controls.Primitives.ButtonBase]) { $viewButton.Add_Click({ try { Invoke-DomeniaWorkView } catch { Write-AppLog ('Vue de travail : '+$_.Exception.Message) 'ERROR'; Set-Status ('Vue non affichée : '+$_.Exception.Message) 'ERROR' } }) }
    $back = Get-DomeniaControl 'BtnNavBack'
    if ($back -is [Windows.Controls.Primitives.ButtonBase]) { $back.Add_Click({ try { [void](Invoke-DomeniaNavStep -Direction Back) } catch { Write-AppLog ('Navigation précédente : '+$_.Exception.Message) 'WARN' } }) }
    $forward = Get-DomeniaControl 'BtnNavForward'
    if ($forward -is [Windows.Controls.Primitives.ButtonBase]) { $forward.Add_Click({ try { [void](Invoke-DomeniaNavStep -Direction Forward) } catch { Write-AppLog ('Navigation suivante : '+$_.Exception.Message) 'WARN' } }) }
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    if ($box -is [Windows.Controls.TextBox]) { $box.Add_TextChanged({ try { Update-DomeniaSearchHint } catch { } }) }
    $tabs = Get-DomeniaControl 'WorkspaceTabs'
    if ($tabs -is [Windows.Controls.TabControl]) {
        $tabs.Add_SelectionChanged({
            param($sender,$eventArgs)
            if ($sender -ne $eventArgs.OriginalSource) { return }
            $from = ''; $to = ''
            try { if (@($eventArgs.RemovedItems).Count -gt 0) { $from = [string]@($eventArgs.RemovedItems)[0].Name } } catch { }
            try { if (@($eventArgs.AddedItems).Count -gt 0) { $to = [string]@($eventArgs.AddedItems)[0].Name } } catch { }
            try { Register-DomeniaNavLocation -From $from -To $to } catch { Write-AppLog ('Historique de navigation : '+$_.Exception.Message) 'WARN' }
        })
        [void](Push-DomeniaNavState $script:NavHistory (Get-DomeniaNavSnapshot))
    }
    if ($script:Window -is [Windows.Window]) {
        $backCommand = [Windows.Input.RoutedCommand]::new('DomeniaNavBack',[Windows.Window])
        $backBinding = [Windows.Input.CommandBinding]::new($backCommand)
        $backBinding.Add_Executed({ try { [void](Invoke-DomeniaNavStep -Direction Back) } catch { Write-AppLog ('Alt+Gauche : '+$_.Exception.Message) 'WARN' } })
        [void]$script:Window.CommandBindings.Add($backBinding)
        [void]$script:Window.InputBindings.Add([Windows.Input.KeyBinding]::new($backCommand,[Windows.Input.KeyGesture]::new([Windows.Input.Key]::Left,[Windows.Input.ModifierKeys]::Alt)))
        $forwardCommand = [Windows.Input.RoutedCommand]::new('DomeniaNavForward',[Windows.Window])
        $forwardBinding = [Windows.Input.CommandBinding]::new($forwardCommand)
        $forwardBinding.Add_Executed({ try { [void](Invoke-DomeniaNavStep -Direction Forward) } catch { Write-AppLog ('Alt+Droite : '+$_.Exception.Message) 'WARN' } })
        [void]$script:Window.CommandBindings.Add($forwardBinding)
        [void]$script:Window.InputBindings.Add([Windows.Input.KeyBinding]::new($forwardCommand,[Windows.Input.KeyGesture]::new([Windows.Input.Key]::Right,[Windows.Input.ModifierKeys]::Alt)))
        $script:Window.Add_Closed({ $script:SearchUiInitialized = $false; $script:NavHistory = $null; $script:NavRestoring = $false })
    }
    Update-DomeniaNavButtons
    Update-DomeniaSearchHint
}
