# Search and navigation surfaces of the Rechercher page: syntax hint, work views, back and forward, OU tree pacing,
# OU filter and header menu. Decisions come from Domenia-Search.Model.ps1. Nothing here contacts the directory or a
# workstation by itself: a search starts only from an explicit operator gesture, through Invoke-GlobalSearch.
$script:SearchUiInitialized = $false
$script:NavHistory = $null
$script:NavRestoring = $false
$script:NavSearchLaunching = $false
$script:NavHistoryRows = $null
$script:NavHistoryState = $null
$script:NavListShape = $null
$script:OuTreeFilterStatus = ''
$script:TreeSelectionSource = 'Mouse'
$script:PendingFilterChange = $null
$script:FilterChangeTimer = $null
$script:WorkViewScopeOu = ''

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
    # UX-33: a waiting entry is shown until a view is chosen; every view applies to the OU of the 'Dans :' chip.
    $combo = Get-DomeniaControl 'CmbWorkView'
    if ($null -eq $combo) { return }
    $combo.Items.Clear()
    $wait = [Windows.Controls.ComboBoxItem]::new()
    $wait.Content = 'Vues prêtes' + [string][char]0x2026
    $wait.Tag = ''
    $wait.IsEnabled = $false
    $wait.ToolTip = 'Choisissez une vue : le choix seul ne lance rien.'
    [void]$combo.Items.Add($wait)
    foreach ($view in @(Get-DomeniaWorkViews)) {
        $item = [Windows.Controls.ComboBoxItem]::new()
        $item.Content = [string]$view.Name
        $item.Tag = [string]$view.Id
        $tip = [string]$view.Note
        if (-not $tip) { $tip = 'Vue en lecture seule.' }
        $tip += ' Périmètre : lʼOU choisie dans lʼarbre (puce Dans :) ; tout le domaine seulement sur choix explicite, sans relevé des postes.'
        $item.ToolTip = $tip
        [void]$combo.Items.Add($item)
    }
    $combo.SelectedIndex = 0
}

function Get-DomeniaWorkViewScopeChoice {
    # UX-33: 'OU' (the OU chosen in the tree, default) or 'Domain' (explicit secondary choice of the chip).
    $combo = Get-DomeniaControl 'CmbWorkViewScope'
    try { if ($null -ne $combo -and $null -ne $combo.SelectedItem -and [string]$combo.SelectedItem.Tag -eq 'Domain') { return 'Domain' } } catch { }
    return 'OU'
}

function Update-DomeniaOuScopeChoices {
    # UX-33 / FO-04: the 'Dans :' chip of the work views names the OU chosen in the tree, and the pin button of the
    # tree menu says whether that OU is a favourite. Choosing another OU brings the chip back to that OU.
    param($Scope)
    if ($null -eq $Scope) { return }
    $name = 'OU choisie'
    if ([bool]$Scope.IsDomain) { $name = 'tout le domaine' }
    else { try { $name = [string](Get-DomeniaUxOuDisplay -DistinguishedName ([string]$Scope.BaseDn)).Name } catch { } }
    $combo = Get-DomeniaControl 'CmbWorkViewScope'
    if ($null -ne $combo -and $combo.Items.Count -gt 0) {
        $first = $combo.Items[0]
        $text = 'Vues dans : ' + $name
        $moved = ([string]$script:WorkViewScopeOu -ine [string]$Scope.BaseDn)
        $script:WorkViewScopeOu = [string]$Scope.BaseDn
        if ([string]$first.Content -cne $text -or ($moved -and $combo.SelectedIndex -ne 0)) {
            $first.Content = $text
            $first.ToolTip = 'Applique la vue à ' + $name + ' (' + [string]$Scope.BaseDn + ').'
            # The closed box shows the selected entry as it was selected: select it again to show the new name.
            $combo.SelectedIndex = -1
            $combo.SelectedIndex = 0
        }
        # DS-07: on the domain root with its sub-OU, 'tout le domaine' is already the first entry: the second one,
        # which says the same, is hidden.
        if ($combo.Items.Count -gt 1) {
            $second = $combo.Items[1]
            $same = ([bool]$Scope.IsDomain -and [string]$Scope.Scope -eq 'Subtree')
            $wanted = if ($same) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
            if ($second -is [Windows.UIElement] -and $second.Visibility -ne $wanted) { $second.Visibility = $wanted }
            if ($same -and $combo.SelectedIndex -eq 1) { $combo.SelectedIndex = 0 }
        }
    }
    $toggle = Get-DomeniaControl 'BtnOuFavouriteToggle'
    if ($null -ne $toggle) {
        $pinned = ($null -ne $script:OuFavouriteKeys -and $script:OuFavouriteKeys.ContainsKey(([string]$Scope.BaseDn).ToLowerInvariant()))
        $toggle.Content = if ($pinned) { 'Retirer des favoris' } else { 'Épingler cette OU' }
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
    # The list is described by the search that produced it, not by a text typed afterwards and not yet sent.
    $mode = Get-DomeniaSearchMode
    $text = Get-DomeniaSearchText -Mode Global
    $branchText = Get-DomeniaSearchText -Mode OU
    $ouDn = [string]$script:SelectedBranchDn
    $subtreeBox = Get-DomeniaControl 'ChkSubtree'
    $subtree = $true
    if ($null -ne $subtreeBox) { $subtree = [bool]$subtreeBox.IsChecked }
    $viewId = [string]$script:ActiveSearchViewId
    $surveyBlocked = [bool]$script:ListSurveyBlocked
    $viewChoice = ''
    # UX-25: the object type is the one that produced the list. The control may already show the type of the search
    # being launched (a type change or a favourite changes it before Enter-DomeniaNavSearch).
    $typeLabel = ''
    $typeBox = Get-DomeniaControl 'CmbGlobalType'
    try { if ($null -ne $typeBox -and $null -ne $typeBox.SelectedItem) { $typeLabel = [string]$typeBox.SelectedItem.Content } } catch { }
    $listState = $null
    if ($null -ne $script:Live -and $null -ne $script:Live.Search) {
        # A live list stays the same list while its local filter or presence repaints the grid ($script:BranchObjects).
        $liveRows = $script:Live.Search.Rows
        if (($null -ne $rows -and [object]::ReferenceEquals($rows,$liveRows)) -or [object]::ReferenceEquals($script:BranchObjects,$liveRows)) { $listState = $script:Live.Search.State }
    }
    $historyState = $null
    if ($null -eq $listState -and (Test-DomeniaHistoryListShown)) { $historyState = $script:NavHistoryState }
    if ($null -ne $listState) {
        $mode = $(if ([string]$listState.SearchMode -eq 'Global') { 'Global' } else { 'OU' })
        if ($mode -eq 'Global') { $text = [string]$listState.Search }
        else { $branchText = [string]$listState.Search; $ouDn = [string]$listState.BaseDn; $subtree = ([string]$listState.Scope -eq 'Subtree') }
        $viewId = ''
        if ($null -ne $listState.PSObject.Properties['ViewId']) { $viewId = [string]$listState.ViewId }
        if ($null -ne $listState.PSObject.Properties['SurveyAllowed']) { $surveyBlocked = (-not [bool]$listState.SurveyAllowed) }
        $viewChoice = [string](Get-DomeniaMember $listState 'ViewChoice' '')
        $stateType = [string](Get-DomeniaMember $listState 'TypeLabel' '')
        if (-not $stateType -and $mode -eq 'OU') { $stateType = Get-DomeniaTypeLabelOfFilter ([string]$listState.TypeFilter) }
        if ($stateType) { $typeLabel = $stateType }
    }
    elseif ($null -ne $historyState) {
        # A list shown from the history is described by its own remembered state, not by controls changed since.
        $mode = $(if ([string]$historyState.Mode -eq 'Global') { 'Global' } else { 'OU' })
        $text = [string]$historyState.Text; $branchText = [string]$historyState.BranchText
        $ouDn = [string]$historyState.OuDn; $subtree = [bool]$historyState.Subtree; $viewId = [string]$historyState.ViewId
        $surveyBlocked = [bool](Get-DomeniaMember $historyState 'SurveyBlocked' $false)
        $viewChoice = [string](Get-DomeniaMember $historyState 'ViewChoice' '')
        $stateType = [string](Get-DomeniaMember $historyState 'TypeLabel' '')
        if ($stateType) { $typeLabel = $stateType }
    }
    if (-not $viewChoice) { $viewChoice = $(if ($viewId -and $mode -eq 'Global') { 'Domain' } else { 'OU' }) }
    $inner = ''
    if ($Page -eq 'WsObject') {
        $detail = Get-DomeniaControl 'DetailTabs'
        try { if ($null -ne $detail -and $null -ne $detail.SelectedItem) { $inner = [string]$detail.SelectedItem.Name } } catch { }
    }
    $count = Get-DomeniaControl 'LblBranchCount'
    $selectionGuid = ''; $selectionDn = ''
    if ($null -ne $selected) {
        try { $selectionDn = [string]$selected.DN } catch { }
        try { if ($null -ne $selected.PSObject.Properties['Guid']) { $selectionGuid = [string]$selected.Guid } } catch { }
    }
    $objectDn = ''
    if ($null -ne $script:SelectedObject) { $objectDn = [string]$script:SelectedObject.DN }
    # UX-25: the local filter and the presence are those shown with the list. While a search is being launched, its
    # gesture may already have changed them (a favourite fills the local filter): the values last seen with this
    # same list are kept instead.
    $localBox = Get-DomeniaControl 'TxtSuiteResultFilter'
    $localFilter = ''
    if ($null -ne $localBox) { $localFilter = [string]$localBox.Text }
    $presence = [string]$script:CurrentPresenceFilter
    $shape = $script:NavListShape
    if ([bool]$script:NavSearchLaunching -and $null -ne $shape -and [object]::ReferenceEquals($shape.List,$script:BranchObjects)) {
        $localFilter = [string]$shape.LocalFilter; $presence = [string]$shape.Presence
    }
    else { $script:NavListShape = [pscustomobject]@{List=$script:BranchObjects;LocalFilter=$localFilter;Presence=$presence} }
    return [pscustomobject]@{
        Page=$Page;Tab=$inner;Mode=$mode;Text=$text;BranchText=$branchText;OuDn=$ouDn;Subtree=$subtree
        SelectionGuid=$selectionGuid;SelectionDn=$selectionDn;Rows=$rows;Scroll=$scroll
        CountLabel=$(if ($null -ne $count) { [string]$count.Text } else { '' })
        Generation=[int]$script:GlobalSearchGeneration;ViewId=$viewId
        TypeLabel=$typeLabel;Presence=$presence;LocalFilter=$localFilter
        SurveyBlocked=$surveyBlocked;ViewChoice=$viewChoice
        ObjectDn=$objectDn;At=[datetime]::UtcNow
    }
}

function Get-DomeniaTypeLabelOfFilter {
    # UX-25: the 'Type d objet' label whose LDAP filter produced a list ('' when none matches).
    param([AllowEmptyString()][string]$Filter)
    if (-not $Filter) { return '' }
    foreach ($label in @('Tous','Utilisateurs','Machines','Groupes','OU et conteneurs')) { if ([string](Get-TypeLdapFilter -Type $label) -ceq $Filter) { return $label } }
    return ''
}

function Get-DomeniaVisiblePageName {
    $tabs = Get-DomeniaControl 'WorkspaceTabs'
    try { if ($null -ne $tabs -and $null -ne $tabs.SelectedItem) { return [string]$tabs.SelectedItem.Name } } catch { }
    return ''
}

function Enter-DomeniaNavSearch {
    # Called by Invoke-GlobalSearch before it changes the list: the place being left is saved as it is now,
    # and the page switch made by the search does not overwrite it with a half-updated state.
    if ($script:NavRestoring -or $null -eq $script:NavHistory) { return }
    # A gesture that changes its controls before the search (a favourite) saved the place already: keep that one.
    if ([bool]$script:NavSearchLaunching) { return }
    $h = $script:NavHistory
    $page = Get-DomeniaVisiblePageName
    if ($null -ne $h.Current -and $page -and [string]$h.Current.Page -eq $page) { $h.Current = Get-DomeniaNavSnapshot -Page $page }
    $script:NavSearchLaunching = $true
}

function Exit-DomeniaNavSearch {
    # Called once the search has replaced the list: the new list becomes a place of the history.
    if (-not [bool]$script:NavSearchLaunching) { return }
    $script:NavSearchLaunching = $false
    if ($script:NavRestoring -or $null -eq $script:NavHistory) { return }
    [void](Push-DomeniaNavState $script:NavHistory (Get-DomeniaNavSnapshot))
    Update-DomeniaNavButtons
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
    # During a search launch the place being left was already saved by Enter-DomeniaNavSearch.
    if ($From -and -not [bool]$script:NavSearchLaunching -and $null -ne $h.Current -and [string]$h.Current.Page -eq $From) { $h.Current = Get-DomeniaNavSnapshot -Page $From }
    [void](Push-DomeniaNavState $h (Get-DomeniaNavSnapshot -Page $To))
    Update-DomeniaNavButtons
}

function Restore-DomeniaNavState {
    # Shows a remembered place again from memory. Never a search, a ping, a probe or a fiche read.
    param($State)
    if ($null -eq $State) { return }
    # PF-14: a tree walk or type change waiting for its pause belongs to the list being left.
    Stop-DomeniaPendingFilterChange
    $script:NavRestoring = $true
    $oldRestoring = [bool]$script:RestoringSettings
    $oldSuppress = [bool]$script:SuppressBranchAutoLoad
    $script:RestoringSettings = $true
    $script:SuppressBranchAutoLoad = $true
    try {
        $grid = Get-DomeniaControl 'DgObjects'
        $otherRows = ($null -ne $grid -and $null -ne $State.Rows -and -not [object]::ReferenceEquals($grid.ItemsSource,$State.Rows))
        # Another list is displayed now: stop following it before showing the remembered rows.
        if ($otherRows) { Invalidate-DomeniaSearchResults -KeepSelection }
        [void](Set-DomeniaControlText -Name 'TxtGlobalSearch' -Text ([string]$State.Text))
        # CO-21: no hidden term. A term of the remembered OU list is shown in the visible local filter instead.
        [void](Set-DomeniaControlText -Name 'TxtBranchSearch' -Text '')
        try { if ($null -ne $script:LiveSearchTimer) { $script:LiveSearchTimer.Stop() } } catch { }
        $script:SelectedBranchDn = [string]$State.OuDn
        $check = Get-DomeniaControl 'ChkSubtree'
        if ($null -ne $check) { $check.IsChecked = [bool]$State.Subtree }
        Set-DomeniaSearchMode -Mode $(if ([string]$State.Mode -eq 'Global') { 'Global' } else { 'OU' })
        $script:ActiveSearchViewId = [string]$State.ViewId
        Update-DomeniaSearchScopeUi
        if ($otherRows) {
            # UX-25: the type, the presence and the local filter that shaped the remembered list come back with it,
            # before its rows, so that the filters shown never contradict the list.
            $typeLabel = [string](Get-DomeniaMember $State 'TypeLabel' '')
            $typeBox = Get-DomeniaControl 'CmbGlobalType'
            if ($typeLabel -and $null -ne $typeBox) { foreach ($item in @($typeBox.Items)) { if ([string]$item.Content -eq $typeLabel) { $typeBox.SelectedItem = $item; break } } }
            $presence = [string](Get-DomeniaMember $State 'Presence' '')
            $presenceBox = Get-DomeniaControl 'CmbPresenceFilter'
            if ($presence) {
                $script:CurrentPresenceFilter = $presence
                if ($null -ne $presenceBox) { foreach ($item in @($presenceBox.Items)) { if ([string]$item.Content -eq $presence) { $presenceBox.SelectedItem = $item; break } } }
            }
            $local = [string](Get-DomeniaMember $State 'LocalFilter' '')
            if (-not $local -and [string]$State.Mode -ne 'Global') { $local = [string]$State.BranchText }
            $localBox = Get-DomeniaControl 'TxtSuiteResultFilter'
            if ($null -ne $localBox) {
                $oldExperience = [bool]$script:ExperienceRestoring
                $script:ExperienceRestoring = $true
                try { $localBox.Text = $local } finally { $script:ExperienceRestoring = $oldExperience }
            }
            $chip = Get-DomeniaControl 'CmbWorkViewScope'
            if ($null -ne $chip -and $chip.Items.Count -gt 1) { $chip.SelectedIndex = $(if ([string](Get-DomeniaMember $State 'ViewChoice' 'OU') -eq 'Domain') { 1 } else { 0 }) }
            $script:ListSurveyBlocked = [bool](Get-DomeniaMember $State 'SurveyBlocked' $false)
            $suppressed = [bool]$script:SuppressGridSelectionEvents
            $script:SuppressGridSelectionEvents = $true
            try {
                $grid.ItemsSource = $State.Rows
                try { Update-DomeniaLoginColumnFromRows $State.Rows } catch { }
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
            $label = [string]$State.CountLabel
            if (-not $label.Contains('historique, non relu')) { $label += ' · historique, non relu' }
            $script:BranchCountLabel = $label
            [void](Set-DomeniaControlText -Name 'LblBranchCount' -Text $script:BranchCountLabel)
            # UX-25: 'Liste de l'historique · Actualiser' stays in the results bar while these rows are the list, even
            # when the local filter or the presence repaints the grid with a filtered copy.
            $script:NavHistoryRows = $State.Rows
            $script:NavHistoryState = $State
            $script:NavListShape = [pscustomobject]@{List=$State.Rows;LocalFilter=$local;Presence=[string]$script:CurrentPresenceFilter}
            Update-DomeniaHistoryBanner
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
    [void](Restore-DomeniaNavState -State $step.State)
    Update-DomeniaNavButtons
    return $step
}

function Test-DomeniaHistoryListShown {
    # UX-25: true while the list is the one restored from the history (Précédent / Suivant), not a followed search.
    # The list is $script:BranchObjects: a local filter or a presence filter repaints the grid with a filtered copy
    # of it, while only a new list (search, invalidation, Effacer) replaces it.
    if ($null -eq $script:NavHistoryRows) { return $false }
    return [object]::ReferenceEquals($script:BranchObjects,$script:NavHistoryRows)
}

function Update-DomeniaHistoryBanner {
    # UX-25: 'Liste de l'historique · Actualiser' is shown exactly while the restored rows are on screen.
    $shown = Test-DomeniaHistoryListShown
    if (-not $shown) { $script:NavHistoryRows = $null; $script:NavHistoryState = $null }
    $banner = Get-DomeniaControl 'UxHistoryBanner'
    if ($null -eq $banner) { return }
    $wanted = if ($shown) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    if ($banner.Visibility -ne $wanted) { $banner.Visibility = $wanted }
}

function Invoke-DomeniaHistoryRefresh {
    # UX-25: explicit gesture. The list shown from the history is read again with its own perimeter, view and
    # filters, which the history step put back in the visible controls. No ping and no survey.
    if (-not (Test-DomeniaHistoryListShown)) { return }
    $viewId = [string]$script:ActiveSearchViewId
    if ($viewId) {
        # The view is read again over its own perimeter (OU or whole domain), not the one the chip shows now.
        $viewScope = [string](Get-DomeniaMember $script:NavHistoryState 'ViewChoice' '')
        if ($viewScope -notin @('OU','Domain')) { $viewScope = '' }
        Invoke-GlobalSearch -ViewId $viewId -SilentError -ViewScope $viewScope
        return
    }
    Invoke-GlobalSearch -SearchMode (Get-DomeniaSearchMode) -AllowEmpty -SilentError
}

function Get-DomeniaTreeSelectionSource {
    # PF-14: the last input received by the OU tree (keyboard or mouse) decides how a new selection is read.
    if ([string]$script:TreeSelectionSource -eq 'Keyboard') { return 'Keyboard' }
    return 'Mouse'
}

function Stop-DomeniaPendingFilterChange {
    $script:PendingFilterChange = $null
    try { if ($null -ne $script:FilterChangeTimer) { $script:FilterChangeTimer.Stop() } } catch { }
}

function Request-DomeniaSearchFilterChanged {
    # PF-14: a mouse click reads the OU at once; a keyboard walk in the tree or a change of object type waits 300 ms
    # and only the last stop is read. Nothing is planned while settings are restored or the tree is driven by code.
    param([string]$Source='Mouse')
    if ($script:RestoringSettings -or $script:SuppressBranchAutoLoad -or -not $script:Conn.Connected) { return }
    $delay = [int](Get-DomeniaTreeSelectionDelay -Source $Source)
    if ($delay -le 0) { Stop-DomeniaPendingFilterChange; Invoke-DomeniaSearchFilterChanged; return }
    $script:PendingFilterChange = [pscustomobject]@{ Dn=[string]$script:SelectedBranchDn; Generation=[int]$script:GlobalSearchGeneration; Source=$Source; DelayMs=$delay }
    if ($null -eq $script:FilterChangeTimer) {
        $timer = [Windows.Threading.DispatcherTimer]::new()
        $timer.Add_Tick({ try { Invoke-DomeniaPendingFilterChange } catch { Write-AppLog ('Lecture différée de lʼOU : '+$_.Exception.Message) 'WARN' } })
        $script:FilterChangeTimer = $timer
    }
    $script:FilterChangeTimer.Stop()
    $script:FilterChangeTimer.Interval = [TimeSpan]::FromMilliseconds($delay)
    $script:FilterChangeTimer.Start()
}

function Invoke-DomeniaPendingFilterChange {
    # The OU still chosen after the pause is read once. Another OU, or a search started meanwhile, wins.
    try { if ($null -ne $script:FilterChangeTimer) { $script:FilterChangeTimer.Stop() } } catch { }
    $pending = $script:PendingFilterChange
    $script:PendingFilterChange = $null
    if ($null -eq $pending) { return }
    if ([string]$pending.Dn -ine [string]$script:SelectedBranchDn -or [int]$pending.Generation -ne [int]$script:GlobalSearchGeneration) { return }
    Invoke-DomeniaSearchFilterChanged
}

function Get-DomeniaOuTreeNodeName {
    # Branch name without its 'OU' / 'CN' prefix, as the operator reads it.
    param($Node)
    $text = ''
    try { $text = [string]$Node.Header } catch { }
    $cut = $text.IndexOf('  ')
    if ($cut -ge 0 -and $cut -le 3) { $text = $text.Substring($cut + 2) }
    return $text
}

function Set-DomeniaOuTreeNodeFilter {
    # Returns true when the branch or one of its read sub-branches matches. A read branch holding a match unfolds:
    # unfolding a read branch reads nothing again.
    param($Node,[string]$Filter,[switch]$IsRoot)
    $childMatch = $false
    foreach ($child in @($Node.Items)) {
        if ($child -isnot [Windows.Controls.TreeViewItem]) { continue }
        if (Set-DomeniaOuTreeNodeFilter -Node $child -Filter $Filter) { $childMatch = $true }
    }
    $self = Test-DomeniaOuTreeMatch -Name (Get-DomeniaOuTreeNodeName $Node) -Filter $Filter
    $visible = ($IsRoot -or -not $Filter -or $self -or $childMatch)
    $wanted = if ($visible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    if ($Node.Visibility -ne $wanted) { $Node.Visibility = $wanted }
    $loaded = $false
    try { $loaded = [bool]$Node.Tag.Loaded } catch { }
    if ($Filter -and $childMatch -and $loaded -and -not $Node.IsExpanded) { $Node.IsExpanded = $true }
    return ($self -or $childMatch)
}

function Update-DomeniaOuTreeFilter {
    # DS-07: 'Filtrer les OU' filters the branches already read, by name. No directory read: a branch never unfolded
    # is not searched, and the domain root always stays visible.
    param([switch]$OnlyWhenActive)
    $box = Get-DomeniaControl 'TxtOuFilter'
    $filter = ''
    if ($null -ne $box) { $filter = ([string]$box.Text).Trim() }
    if ($OnlyWhenActive -and -not $filter) { return }
    $tree = Get-DomeniaControl 'TvDirectory'
    if ($null -eq $tree) { return }
    $matched = $false
    foreach ($root in @($tree.Items)) {
        if ($root -isnot [Windows.Controls.TreeViewItem]) { continue }
        if (Set-DomeniaOuTreeNodeFilter -Node $root -Filter $filter -IsRoot) { $matched = $true }
    }
    if ($filter) {
        $text = if ($matched) { 'Filtre des OU : ' + $filter + ' · branches déjà lues seulement' } else { 'Aucune branche lue ne contient ' + $filter + ' : dépliez une OU pour la parcourir.' }
        [void](Set-DomeniaControlText -Name 'LblTreeStatus' -Text $text)
        $script:OuTreeFilterStatus = $text
    }
    elseif ($script:OuTreeFilterStatus) {
        # The status no longer describes a filter that is gone; a newer tree status is left as it is.
        $status = Get-DomeniaControl 'LblTreeStatus'
        if ($null -ne $status -and [string]$status.Text -ceq [string]$script:OuTreeFilterStatus) { $status.Text = 'Filtre des OU effacé : toutes les branches lues sont affichées.' }
        $script:OuTreeFilterStatus = ''
    }
}

function Switch-DomeniaOuMenu {
    # DS-07: depth, whole domain, pin and LDAP path live in the header menu, so that the tree keeps the full height.
    # Opening the menu reads nothing.
    param([ValidateSet('Toggle','Open','Close')][string]$State='Toggle')
    $panel = Get-DomeniaControl 'UxOuMenuPanel'
    if ($null -eq $panel) { return }
    $show = ($panel.Visibility -ne [Windows.Visibility]::Visible)
    if ($State -eq 'Open') { $show = $true } elseif ($State -eq 'Close') { $show = $false }
    $panel.Visibility = if ($show) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $button = Get-DomeniaControl 'BtnOuMenu'
    if ($null -ne $button) { [Windows.Automation.AutomationProperties]::SetItemStatus($button,$(if ($show) { 'Menu ouvert' } else { 'Menu fermé' })) }
}

function Get-DomeniaTreeItemFromElement {
    # The OU node that holds a header element (the star of a branch).
    param($Element)
    $current = $Element
    $guard = 0
    while ($null -ne $current -and $guard -lt 64) {
        if ($current -is [Windows.Controls.TreeViewItem]) { return $current }
        $guard++
        try { $current = [Windows.Media.VisualTreeHelper]::GetParent($current) } catch { $current = $null }
    }
    return $null
}

function Initialize-DomeniaSearchUi {
    if ($script:SearchUiInitialized) { return }
    $script:SearchUiInitialized = $true
    $script:NavHistory = New-DomeniaNavHistory -Capacity 40
    $script:NavRestoring = $false
    $script:NavSearchLaunching = $false
    $script:NavHistoryRows = $null
    $script:NavHistoryState = $null
    $script:NavListShape = $null
    $script:OuTreeFilterStatus = ''
    $script:TreeSelectionSource = 'Mouse'
    $script:PendingFilterChange = $null
    if ((Get-DomeniaControl 'CmbWorkView') -is [Windows.Controls.ComboBox]) { Update-DomeniaWorkViewList }
    $menuButton = Get-DomeniaControl 'BtnOuMenu'
    if ($menuButton -is [Windows.Controls.Primitives.ButtonBase]) { $menuButton.Add_Click({ Switch-DomeniaOuMenu }) }
    $ouFilter = Get-DomeniaControl 'TxtOuFilter'
    if ($ouFilter -is [Windows.Controls.TextBox]) { $ouFilter.Add_TextChanged({ try { Update-DomeniaOuTreeFilter } catch { Write-AppLog ('Filtre des OU : '+$_.Exception.Message) 'WARN' } }) }
    $historyButton = Get-DomeniaControl 'BtnHistoryRefresh'
    if ($historyButton -is [Windows.Controls.Primitives.ButtonBase]) { $historyButton.Add_Click({ try { Invoke-DomeniaHistoryRefresh } catch { Write-AppLog ('Liste de lʼhistorique : '+$_.Exception.Message) 'WARN' } }) }
    $tree = Get-DomeniaControl 'TvDirectory'
    if ($tree -is [Windows.Controls.TreeView]) {
        # PF-14: remember whether the tree is driven by the keyboard or by the mouse.
        $tree.Add_PreviewKeyDown({ $script:TreeSelectionSource = 'Keyboard' })
        $tree.Add_PreviewMouseDown({ $script:TreeSelectionSource = 'Mouse' })
        # FO-04: the star of a branch pins or unpins it; the click does not select the branch.
        $tree.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent,[Windows.RoutedEventHandler]{
            param($sender,$eventArgs)
            $star = $eventArgs.OriginalSource
            if ($star -isnot [Windows.Controls.Button] -or [string]$star.Name -ne 'OuStar') { return }
            $eventArgs.Handled = $true
            $node = Get-DomeniaTreeItemFromElement $star
            if ($null -eq $node -or $null -eq $node.Tag -or [string]::IsNullOrWhiteSpace([string]$node.Tag.DN)) { return }
            try { [void](Save-DomeniaFavouriteSearch -Dn ([string]$node.Tag.DN) -Toggle) } catch { Write-AppLog ('Favori : '+$_.Exception.Message) 'WARN' }
        })
    }
    $grid = Get-DomeniaControl 'DgObjects'
    if ($grid -is [Windows.Controls.DataGrid]) {
        # UX-25: the history banner follows the rows actually shown, whatever replaced them.
        $descriptor = [ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.ItemsControl]::ItemsSourceProperty,[Windows.Controls.DataGrid])
        if ($null -ne $descriptor) { $descriptor.AddValueChanged($grid,[EventHandler]{ param($sender,$eventArgs) try { Update-DomeniaHistoryBanner } catch { } }) }
    }
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
        $script:Window.Add_Closed({ $script:SearchUiInitialized = $false; $script:NavHistory = $null; $script:NavRestoring = $false; $script:NavHistoryRows = $null; $script:NavHistoryState = $null; $script:NavListShape = $null; Stop-DomeniaPendingFilterChange })
    }
    Update-DomeniaNavButtons
    Update-DomeniaSearchHint
}
