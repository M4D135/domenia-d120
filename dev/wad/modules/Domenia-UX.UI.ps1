# DOMENIA R1.11. Presentation only. No AD, remote execution or credential validation here.
# Help titles/descriptions come from a static catalogue, NEVER from a control value.
. (Join-Path $PSScriptRoot 'Domenia-Experience.Model.ps1')
. (Join-Path $PSScriptRoot 'Domenia-Experience.UI.ps1')
$script:UxModuleRoot = $PSScriptRoot
$script:UxHelpCatalogue = @{}
$script:UxShellInitialized = $false
$script:UxNavCollapsed = $false
$script:UxNavLayoutSignature = ''
# UI-11: closed at start; the saved choice is read by Initialize-DomeniaUxShell.
$script:UxHelpVisible = $false
$script:UxHelpCompactOpen = $false
$script:UxLayoutSignature = ''
$script:UxLogCollapsed = $false
$script:UxLogHeight = 142.0
$script:UxProfileUpdating = $false
# D006 short screen: display state only, never saved.
$script:UxShortScreen = $false
$script:UxShortHelpOpen = $false
$script:UxShortLogHeld = $false
$script:UxShortLogReleased = $false
$script:UxShortNavFold = $false
$script:UxShortNavReleased = $false
# FO-22: high contrast state of the painted palette, its system colours, and the WPF handler that follows a change of it.
$script:DomeniaPaintedHighContrast = $false
$script:DomeniaPaintedSystemColors = ''
$script:DomeniaHighContrastHandler = $null

function Import-DomeniaUxHelpCatalogue {
    if ($script:UxHelpCatalogue.Count -gt 0) { return }
    $file = Join-Path $script:UxModuleRoot 'Domenia-UX.help.json'
    $items = [IO.File]::ReadAllText($file,[Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($item in @($items)) {
        if ([string]::IsNullOrWhiteSpace([string]$item.Name) -or
            [string]::IsNullOrWhiteSpace([string]$item.Title) -or
            [string]::IsNullOrWhiteSpace([string]$item.Text)) { throw 'Catalogue d aide incomplet.' }
        if ($script:UxHelpCatalogue.ContainsKey([string]$item.Name)) { throw 'Nom duplique dans le catalogue d aide.' }
        $script:UxHelpCatalogue[[string]$item.Name] = $item
    }
}

function Get-DomeniaUxHelpEntry {
    param($Control,[string]$Name='')
    Import-DomeniaUxHelpCatalogue
    if ([string]::IsNullOrWhiteSpace($Name) -and $null -ne $Control) {
        try { $Name = [string]$Control.Name } catch { Write-DomeniaSwallowed 'UX' 'Get-DomeniaUxHelpEntry' $_ }
    }
    if ($script:UxHelpCatalogue.ContainsKey($Name)) { return $script:UxHelpCatalogue[$Name] }
    # Unknown dynamic controls receive a neutral description; no value reflection.
    return [pscustomobject]@{
        Name=$Name;Title='Aide';Text='Consultez le libelle et les actions de cette zone. Aucun contenu saisi n est recopie dans cette aide.';Kind='Unknown'
    }
}

function Get-DomeniaUxControlHelpText {
    param($Control)
    $entry = Get-DomeniaUxHelpEntry -Control $Control
    $description = [string]$entry.Text
    # Preserve status reasons supplied by the existing security UI, written with or without accents (the dot stands
    # for an accented letter or an apostrophe, so this file stays ASCII-safe).
    # Do not reflect Text, Password, SelectedItem, DataContext, Content or Tag.
    try {
        $statusTip = $Control.ToolTip
        if (($statusTip -is [string]) -and ($statusTip -ne $description) -and
            ($statusTip -match '^(D.sactiv|Droit ind.termin|Estimation ACL|.criture brute|Action distante|Fonction d.sactiv|Aucune valeur|Aucun secret|S.lectionne une ligne|S.lectionnez une ligne|S.lectionnez d.abord une ligne|Lancez d.abord|Charge d.abord)')) {
            return $description + "`r`n`r`n" + [string]$statusTip
        }
    } catch { Write-DomeniaSwallowed 'UX' 'Get-DomeniaUxControlHelpText' $_ }
    return $description
}

function Show-DomeniaUxControlHelp {
    param($Control)
    if ($null -eq $Control -or $null -eq $script:Window) { return }
    try {
        # A login window cannot send password-related context to the main window.
        if ([Windows.Window]::GetWindow($Control) -ne $script:Window) { return }
        $entry = Get-DomeniaUxHelpEntry -Control $Control
        Set-DomeniaContextHint -Title ([string]$entry.Title) -Text (Get-DomeniaUxControlHelpText -Control $Control)
    } catch { Write-DomeniaSwallowed 'UX' 'Show-DomeniaUxControlHelp' $_ }
}

function Get-DomeniaUxHelpRole {
    # UI-10: role of a control for its help (Get-DomeniaHelpPresentation). A container is a page host, a grid, a tree,
    # a list view, a layout panel, a border around such a panel or a read-only multi-line text (journal, report).
    param($Control)
    if ($null -eq $Control) { return 'Control' }
    foreach ($type in @([Windows.Controls.TabControl],[Windows.Controls.DataGrid],[Windows.Controls.TreeView],[Windows.Controls.ListView],[Windows.Controls.ScrollViewer],[Windows.Controls.Panel])) {
        if ($Control -is $type) { return 'Container' }
    }
    if (($Control -is [Windows.Controls.Border]) -and ($Control.Child -is [Windows.Controls.Panel])) { return 'Container' }
    if (($Control -is [Windows.Controls.TextBox]) -and ([bool]$Control.IsReadOnly) -and ([bool]$Control.AcceptsReturn)) { return 'Container' }
    if (($Control -is [Windows.Controls.Button]) -and (-not ($Control.Content -is [string]))) { return 'IconButton' }
    return 'Control'
}

function Set-DomeniaUxCatalogueToolTip {
    # PF-24: tool tip of a catalogued control from Domenia-UX.help.json only, shown as its role allows (UI-10).
    param($Control,$Entry)
    $presentation = Get-DomeniaHelpPresentation -Text ([string]$Entry.Text) -Role (Get-DomeniaUxHelpRole -Control $Control)
    if ($presentation.ToolTip) { $Control.ToolTip = [string]$presentation.ToolTip } else { $Control.ClearValue([Windows.FrameworkElement]::ToolTipProperty) }
    return $presentation
}

function Initialize-DomeniaUxControlHelp {
    param($Control)
    if ($null -eq $Control -or $Control -isnot [Windows.FrameworkElement]) { return }
    Import-DomeniaUxHelpCatalogue
    $name = [string]$Control.Name
    if (-not $script:UxHelpCatalogue.ContainsKey($name)) { return }
    if ($Control.Resources.Contains('Domenia.UxHelpAttached')) { return }
    $entry = $script:UxHelpCatalogue[$name]
    # PF-24: the main XAML carries no ToolTip, HelpText nor ShowOnDisabled for a catalogued control; they are set here.
    $presentation = Set-DomeniaUxCatalogueToolTip -Control $Control -Entry $entry
    [Windows.Controls.ToolTipService]::SetShowOnDisabled($Control,$true)
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($Control,350)
    [Windows.Controls.ToolTipService]::SetBetweenShowDelay($Control,100)
    [Windows.Controls.ToolTipService]::SetShowDuration($Control,20000)
    [Windows.Automation.AutomationProperties]::SetName($Control,[string]$entry.Title)
    [Windows.Automation.AutomationProperties]::SetHelpText($Control,[string]$presentation.HelpText)
    $Control.Resources['Domenia.UxHelpAttached'] = $true
    # R40 (startup time): the three handlers are identical for every catalogued control. They are converted to delegates
    # once per session and shared; a script block written in each call was compiled into a new delegate for each control
    # (about 2 400 conversions for the 813 entries of the catalogue, while the main window was being built).
    if ($null -eq $script:UxHelpHandlers) {
        $script:UxHelpHandlers = [pscustomobject]@{
            MouseEnter = [Windows.Input.MouseEventHandler]{param($sender,$eventArgs) Show-DomeniaUxControlHelp -Control $sender}
            ToolTipOpening = [Windows.Controls.ToolTipEventHandler]{param($sender,$eventArgs) Show-DomeniaUxControlHelp -Control $sender}
            GotKeyboardFocus = [Windows.Input.KeyboardFocusChangedEventHandler]{
                param($sender,$eventArgs)
                # A routed child focus must not let a parent overwrite the specific help.
                if ($sender -eq $eventArgs.OriginalSource) { Show-DomeniaUxControlHelp -Control $sender }
            }
        }
    }
    # UI-10: hovering a container (a page, a grid, a journal) does not rewrite the help panel; its keyboard focus does.
    if ([bool]$presentation.HoverHelp) {
        $Control.Add_MouseEnter($script:UxHelpHandlers.MouseEnter)
        $Control.Add_ToolTipOpening($script:UxHelpHandlers.ToolTipOpening)
    }
    $Control.Add_GotKeyboardFocus($script:UxHelpHandlers.GotKeyboardFocus)
}

function Initialize-DomeniaUxWindowHelp {
    param($Window,[string]$XamlText='')
    if ($null -eq $Window) { return }
    Import-DomeniaUxHelpCatalogue
    if (-not [string]::IsNullOrWhiteSpace($XamlText)) {
        foreach ($match in [regex]::Matches($XamlText,'x:Name\s*=\s*"([^"]+)"')) {
            $control = $Window.FindName([string]$match.Groups[1].Value)
            if ($null -ne $control) { Initialize-DomeniaUxControlHelp -Control $control }
        }
    }
}

function Restore-DomeniaUxBaseToolTip {
    param([string]$Name)
    if ($null -eq $script:UxHelpCatalogue -or -not $script:UxHelpCatalogue.ContainsKey($Name)) { return }
    $control = Get-DomeniaControl -Name $Name
    if ($null -ne $control) { [void](Set-DomeniaUxCatalogueToolTip -Control $control -Entry $script:UxHelpCatalogue[$Name]) }
}

function Get-DomeniaUxRouteNames {
    return @('TabDashboard','WsSearch','TabDirectory','WsObject','WsComputer','TabRelations','TabAccounts','TabApplicationTools')
}

function Invoke-DomeniaUxRoute {
    param([Parameter(Mandatory=$true)][string]$Route)
    if ($Route -notin @(Get-DomeniaUxRouteNames)) { throw 'Destination interface non autorisee.' }
    if ($Route -eq 'TabDirectory') { $Route = 'WsSearch' }
    $target = Get-DomeniaControl -Name $Route
    if ($null -eq $target -or -not $target.IsEnabled -or $target.Visibility -ne [Windows.Visibility]::Visible) {
        Set-DomeniaContextHint -Title 'Page indisponible' -Text 'Cette page nʼest pas disponible pour le moment. Les autres rubriques du menu restent accessibles.'
        return
    }
    Select-DomeniaWorkspace -Workspace $Route
    if ($Route -eq 'WsSearch') {
        $box = Get-DomeniaControl 'TxtGlobalSearch'
        if ($null -ne $box) { [void]$box.Focus() }
    }
    Sync-DomeniaUxNavigation
}

function Get-DomeniaUxNavButtons {
    # PF-28 (L08): the navigation buttons and their base help are collected once per window, not on every page change
    # (the former loop matched every named control against a regular expression and rebuilt each help text).
    if (($null -ne $script:UxNavButtonCache) -and [object]::ReferenceEquals($script:UxNavButtonCacheWindow,$script:Window) -and ([int]$script:UxNavButtonCacheCount -eq $script:Ctrl.Count)) {
        return $script:UxNavButtonCache
    }
    $allowed = @(Get-DomeniaUxRouteNames)
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pair in @($script:Ctrl.GetEnumerator())) {
        if ([string]$pair.Key -notmatch '^BtnUx(Nav|Home|Step|HelpAccounts)') { continue }
        $button = $pair.Value
        if ($button -isnot [Windows.Controls.Button]) { continue }
        $route = [string]$button.Uid
        if ($route -notin $allowed) { continue }
        $list.Add([pscustomobject]@{Name=[string]$pair.Key;Button=$button;Route=$route;Tip=[string](Get-DomeniaUxHelpEntry -Control $button).Text;Menu=([string]$pair.Key -like 'BtnUxNav*')})
    }
    $script:UxNavButtonCache = $list.ToArray()
    $script:UxNavButtonCacheWindow = $script:Window
    $script:UxNavButtonCacheCount = $script:Ctrl.Count
    return $script:UxNavButtonCache
}

function Sync-DomeniaUxNavigation {
    if ($null -eq $script:Ctrl) { return }
    $workspaces = Get-DomeniaControl 'WorkspaceTabs'
    if ($null -eq $workspaces) { return }
    $current = '';try { $current = [string]$workspaces.SelectedItem.Name } catch { Write-DomeniaSwallowed 'UX' 'Sync-DomeniaUxNavigation' $_ }
    foreach ($entry in @(Get-DomeniaUxNavButtons)) {
        $button = $entry.Button
        $route = [string]$entry.Route
        $target = Get-DomeniaControl -Name $route
        $available = ($null -ne $target -and $target.IsEnabled -and $target.Visibility -eq [Windows.Visibility]::Visible)
        # These are navigation buttons only; no permission-bearing control is enabled here.
        $button.IsEnabled = $available
        $active = ($route -eq $current)
        $button.Tag = if ($active) { 'Active' } else { '' }
        # UI-13: the active menu entry is announced as the current page.
        if ([bool]$entry.Menu) { [Windows.Automation.AutomationProperties]::SetItemStatus($button,$(if ($active) { 'Page actuelle' } else { '' })) }
        $tip = [string]$entry.Tip
        if (-not $available) {
            if ($route -eq 'TabSupport') { $tip += ' Atelier indisponible : consultez le journal.' }
            else { $tip += ' Page indisponible pour le moment.' }
        }
        $button.ToolTip = $tip
    }
    # UI-29 / UI-01: page title = menu label followed by its subject; window title and subject chip follow.
    Update-DomeniaUxPageTitle
    Update-DomeniaUxSessionBadge
    Update-DomeniaUxEmptyStates
    Update-DomeniaUxAccountFooter
    Update-DomeniaUxHelpGuide
    $selectionLabel = Get-DomeniaControl 'LblUxSelected'
    if ($null -ne $selectionLabel) {
        $selectionLabel.Text = 'Aucune sélection'
        if ($null -ne $script:SelectionLoad) {
            $selectionLabel.Text = $script:SelectionLoad.Context.Type + ' : ' + $script:SelectionLoad.Context.Name
        }
        elseif ($null -ne $script:SelectedObject) {
            $selectionLabel.Text = ([string]$script:SelectedObject.Type + ' · ' + [string]$script:SelectedObject.Name).Trim([char[]]@(' ','·'))
        }
    }
    Update-DomeniaExperienceIdentity
}

function Update-DomeniaUxProfileVisibility {
    param([AllowEmptyString()][string]$ObjectType='')
    if ($script:UxProfileUpdating -or $null -eq $script:Ctrl) { return }
    $script:UxProfileUpdating = $true
    try {
        if (-not $PSBoundParameters.ContainsKey('ObjectType')) {
            try { $ObjectType = [string]$script:SelectedObject.Type } catch { $ObjectType = '' }
        }
        $expert = ([string]$script:CurrentUiProfile -eq 'Admin')
        $hasObject = -not [string]::IsNullOrWhiteSpace($ObjectType)
        $rules = @{
            TabRaw=($expert -and $hasObject);TabPermissions=($expert -and $hasObject)
            TabWmi=($expert -and $ObjectType -eq 'Machine');TabSelfCheck=$expert;TabCmdlets=$false;TabLog=$expert
            # SE-10 : les options de compte a haut risque ne se proposent qu'en Expert.
            ExpAccountSecurityOptions=$expert
            # UX-27 : Classe et GUID ne regardent que l'Expert ; la fiche reste lisible sans eux.
            LblObjClass=$expert;TxtObjClass=$expert;LblObjGuid=$expert;TxtObjGuid=$expert
        }
        foreach ($name in $rules.Keys) {
            $tab = Get-DomeniaControl $name
            if ($null -ne $tab) { $tab.Visibility = if ($rules[$name]) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
        }
        # UX-37 : la colonne Source de l inventaire du poste nomme la propriete WMI d ou vient une valeur
        # (Win32_ComputerSystem, Registre...). Elle sert a relire une valeur, pas a piloter : elle reste en
        # Expert, et l export ne l emporte plus avec lui en mode Essentiel.
        $gridInventory = Get-DomeniaControl 'DgInventory'
        if ($null -ne $gridInventory) {
            foreach ($column in @($gridInventory.Columns)) {
                if (([string]$column.Header) -eq 'Source') { $column.Visibility = if ($expert) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
            }
        }
        # UX-17 : « par quel transport » et « en combien de millisecondes » repondent a une question
        # d expert, pas a celle de l operateur qui appelle un poste. Elles prennent 210 px sur un ecran
        # d appui et les meme informations se relisent dans le journal de session.
        $gridDiag = Get-DomeniaControl 'DgComputerDiag'
        if ($null -ne $gridDiag) {
            foreach ($column in @($gridDiag.Columns)) {
                if (([string]$column.Header) -eq 'Methode' -or ([string]$column.Header) -eq 'Duree ms') { $column.Visibility = if ($expert) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
            }
        }
        # DS-09: Score and Correspondance explain the ranking of the local search; they stay in Expert so that the grid
        # of Base autonome keeps its width for the columns the operator reads.
        $gridIndex = Get-DomeniaControl 'DgIndex'
        if ($null -ne $gridIndex) {
            foreach ($column in @($gridIndex.Columns)) {
                if ((([string]$column.Header) -eq 'Score') -or (([string]$column.Header) -eq 'Correspondance')) { $column.Visibility = if ($expert) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
            }
        }
        # Never leave a hidden detail page selected. No AD read is performed.
        foreach ($name in @('DetailTabs','ComputerTabs','ComputerDetailTabs','ComputerDiagTabs','ApplicationToolTabs')) {
            $tabs = Get-DomeniaControl $name
            if ($null -eq $tabs) { continue }
            if ($null -ne $tabs.SelectedItem -and $tabs.SelectedItem.Visibility -ne [Windows.Visibility]::Visible) {
                foreach ($item in @($tabs.Items)) {
                    if ($item.Visibility -eq [Windows.Visibility]::Visible) { $tabs.SelectedItem=$item;break }
                }
            }
        }
    } finally { $script:UxProfileUpdating = $false }
}

function Get-DomeniaUxHeightPlan {
    # D006: under 940 logical viewport units the search page folds secondary chrome so that the results grid
    # keeps its room. Pure plan; display state only: the saved journal, help and menu preferences never change.
    param([double]$Height=0,[double]$Width=0)
    $short = (($Height -gt 0) -and ($Height -lt 940))
    $low = (($Height -gt 0) -and ($Height -lt 700))
    # UI-05 (L08): under 1280 units of width the menu also folds for the session (half screen beside the ticket tool),
    # so that the top search keeps its room; the saved menu preference is never changed by a resize.
    $narrow = (($Width -gt 0) -and ($Width -lt 1280))
    return [pscustomobject]@{
        QueryOptionsCompact=((($Height -gt 0) -and ($Height -lt 560)) -or ($short -and ($Width -gt 0) -and ($Width -lt 1100)))
        TinyHeight=(($Height -gt 0) -and ($Height -lt 560));LowHeight=$low;Short=$short;FoldJournal=$short;InlineDomainBadge=$short;CloseHelp=$short;HideFilterCaptions=$short
        FoldNavigation=($narrow -or ($short -and ($Width -gt 0) -and ($Width -lt 1200)));Narrow=$narrow
        WorkViewWidth=$(if ($short) { 230.0 } else { 250.0 })
        FilterCardPadding=$(if ($low) { 4.0 } else { 10.0 });FilterCardBottom=$(if ($low) { 4.0 } else { 8.0 })
        ResultBarBottom=$(if ($low) { 2.0 } else { 4.0 });ResultLiveTop=$(if ($low) { 2.0 } elseif ($short) { 4.0 } else { 6.0 });ResultCountTop=0.0
    }
}

function Set-DomeniaSearchQueryOptionsLayout {
    param([bool]$Compact)
    $button=Get-DomeniaControl 'BtnSearchQueryOptions'
    $layout=Get-DomeniaControl 'UxSearchFilterQueryLayout'
    $panel=Get-DomeniaControl 'UxSearchQueryOptionsScroll'
    $content=Get-DomeniaControl 'UxSearchQueryOptionsContent'
    $query=Get-DomeniaControl 'UxSearchQueryBar'
    if($null -eq $button -or $null -eq $layout -or $null -eq $panel -or $null -eq $content -or $null -eq $query){return}
    $state=$button.Resources['Domenia.QueryOptions']
    if($null -eq $state){
        $items=New-Object 'System.Collections.Generic.List[object]'
        foreach($name in @('UxSearchQueryHeader','LblSearchQueryDetails','UxSearchQueryResultBar','CmbWorkViewScope','BtnSearchQueryFavorite','BtnQueryClearSearch')){
            $control=Get-DomeniaControl $name
            if($null -ne $control -and $control.Parent -is [Windows.Controls.Panel]){
                $items.Add([pscustomobject]@{Control=$control;Parent=$control.Parent;Index=$control.Parent.Children.IndexOf($control);Row=[Windows.Controls.Grid]::GetRow($control);Column=[Windows.Controls.Grid]::GetColumn($control);Margin=$control.Margin;Content=$(if($control -is [Windows.Controls.Button]){$control.Content}else{$null})})
            }
        }
        $state=[pscustomobject]@{Compact=$false;Open=$false;Items=$items.ToArray()}
        $button.Resources['Domenia.QueryOptions']=$state
        $population=Get-DomeniaControl 'CmbSearchQueryResult';$label=Get-DomeniaControl 'LblSearchQuery'
        # Capture controls and function bodies: closures run after the launcher's private script scope has returned.
        $refresh={
            $caption='Options de requête'
            if($null -ne $population -and $population.Visibility -eq [Windows.Visibility]::Visible -and $null -ne $population.SelectedItem){$caption='Options · '+[string]$population.SelectedItem.Content}
            elseif($null -ne $label -and -not [string]::IsNullOrWhiteSpace([string]$label.Text) -and [string]$label.Text -notlike 'Aucune requête*'){$caption='Options · Requête active'}
            $button.Content=$caption
            $button.ToolTip='Recherche de modèle, favoris, source et état des résultats. '+$(if($null -ne $label){[string]$label.Text}else{''})
            [Windows.Automation.AutomationProperties]::SetItemStatus($button,$(if($state.Open){'Options développées'}else{'Options repliées'}))
        }.GetNewClosure()
        $state | Add-Member -NotePropertyName Refresh -NotePropertyValue $refresh
        $button.Add_Click({
            if(-not $state.Compact){return}
            $state.Open=-not $state.Open
            $panel.Visibility=if($state.Open){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
            & $refresh
        }.GetNewClosure())
        $panel.Add_PreviewKeyDown({
            param($sender,$e)
            if($state.Compact -and $state.Open -and $e.Key -eq [Windows.Input.Key]::Escape){
                $state.Open=$false;$panel.Visibility=[Windows.Visibility]::Collapsed;[void]$button.Focus();& $refresh;$e.Handled=$true
            }
        }.GetNewClosure())
        if($null -ne $population){
            $population.Add_SelectionChanged({param($sender,$e)& $refresh}.GetNewClosure())
            # IsVisibleChanged would miss a local Visibility change while the options parent is folded.
            $visibilityDescriptor=[ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.UIElement]::VisibilityProperty,[Windows.Controls.ComboBox])
            $visibilityChanged=[EventHandler]({param($sender,$e)& $refresh}.GetNewClosure())
            $visibilityDescriptor.AddValueChanged($population,$visibilityChanged)
            if($null -ne $script:Window){$script:Window.Add_Closed({$visibilityDescriptor.RemoveValueChanged($population,$visibilityChanged)}.GetNewClosure())}
        }
        if($null -ne $label){
            $descriptor=[ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.TextBlock]::TextProperty,[Windows.Controls.TextBlock])
            $labelChanged=[EventHandler]({param($sender,$e)& $refresh}.GetNewClosure())
            $descriptor.AddValueChanged($label,$labelChanged)
            if($null -ne $script:Window){$script:Window.Add_Closed({$descriptor.RemoveValueChanged($label,$labelChanged)}.GetNewClosure())}
        }
    }
    if($Compact -ne [bool]$state.Compact){
        if($Compact){
            foreach($item in $state.Items){
                $control=$item.Control;[void]$item.Parent.Children.Remove($control)
                if($control.Name -eq 'BtnQueryClearSearch'){
                    $scope=Get-DomeniaControl 'UxSearchScopeInfo';[void]$scope.Children.Add($control)
                    [Windows.Controls.Grid]::SetColumn($control,3);[Windows.Controls.Grid]::SetRow($control,0)
                    $control.Content='Effacer';$control.Margin=[Windows.Thickness]::new(6,0,0,2)
                }
                elseif($control.Name -eq 'BtnSearchQueryFavorite'){$header=Get-DomeniaControl 'UxSearchQueryHeader';[void]$header.Children.Add($control)}
                else{[void]$content.Children.Add($control)}
            }
        }
        else{
            $restoreFocus=$null
            if($panel.IsKeyboardFocusWithin){$restoreFocus=[Windows.Input.Keyboard]::FocusedElement}
            foreach($item in $state.Items){
                $control=$item.Control;[void]$control.Parent.Children.Remove($control)
                $at=[Math]::Min([int]$item.Index,$item.Parent.Children.Count);$item.Parent.Children.Insert($at,$control)
                [Windows.Controls.Grid]::SetColumn($control,[int]$item.Column);[Windows.Controls.Grid]::SetRow($control,[int]$item.Row)
                if($control.Name -eq 'BtnQueryClearSearch'){$control.Margin=$item.Margin}
                if($control.Name -eq 'BtnQueryClearSearch'){$control.Content=$item.Content}
            }
            if($null -ne $restoreFocus){
                $restored=$false
                try{$restored=[bool]$restoreFocus.Focus()}catch{Write-DomeniaSwallowed 'UX' 'Set-DomeniaSearchQueryOptionsLayout' $_}
                if(-not $restored){[void](Get-DomeniaControl 'CmbWorkView').Focus()}
            }
        }
        $state.Compact=$Compact
    }
    $button.Visibility=if($Compact){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
    $panel.Visibility=if($Compact -and $state.Open){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
    $layout.ColumnDefinitions[0].Width=if($Compact){[Windows.GridLength]::new(252)}else{[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}
    $layout.ColumnDefinitions[1].Width=if($Compact){[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}else{[Windows.GridLength]::new(0)}
    [Windows.Controls.Grid]::SetRow($query,$(if($Compact){0}else{1}));[Windows.Controls.Grid]::SetColumn($query,$(if($Compact){1}else{0}))
    if($Compact){$query.Margin=[Windows.Thickness]::new(6,0,0,0)}
    $widths=@{CmbGlobalType=94.0;CmbPresenceFilter=96.0;TxtGlobalLimit=44.0}
    foreach($name in $widths.Keys){
        $control=Get-DomeniaControl $name
        if($null -eq $control){continue}
        # DS-03: the limit sits with its unit in a DockPanel; the field width is set on the filter host.
        $field=$control.Parent;if($field -is [Windows.Controls.DockPanel]){$field=$field.Parent}
        $control.MinHeight=if($Compact){28.0}else{36.0}
        if($Compact){$field.Width=$widths[$name];$field.Margin=[Windows.Thickness]::new(0,0,6,0);$control.Padding=[Windows.Thickness]::new(4,1,4,1)}
        elseif($control -is [Windows.Controls.ComboBox]){$control.ClearValue([Windows.Controls.Control]::PaddingProperty)}
    }
    # On the tiniest screens the unit gives way to the number; the tooltip and the accessible name keep its meaning.
    $unit=Get-DomeniaControl 'LblGlobalLimitUnit'
    if($null -ne $unit){$unit.Visibility=if($Compact){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
    $selector=Get-DomeniaControl 'CmbWorkView'
    if($null -ne $selector){if($Compact){$selector.Padding=[Windows.Thickness]::new(4,1,4,1)}else{$selector.ClearValue([Windows.Controls.Control]::PaddingProperty)}}
    & $state.Refresh
}

function Set-DomeniaUxShortLayout {
    param($Plan)
    if ($null -eq $Plan) { return }
    $title = Get-DomeniaControl 'UxPageTitleStack';$badge = Get-DomeniaControl 'UxPageSubRow'
    # The session badge (and the subject chip beside it) stays visible (demo, domain): it moves beside the title
    # instead of disappearing.
    if ($null -ne $title) { $title.Orientation = if ([bool]$Plan.InlineDomainBadge) { [Windows.Controls.Orientation]::Horizontal } else { [Windows.Controls.Orientation]::Vertical } }
    if ($null -ne $badge) { $badge.Margin = if ([bool]$Plan.InlineDomainBadge) { [Windows.Thickness]::new(12,0,0,0) } else { [Windows.Thickness]::new(0,5,0,0) } }
    $badge = Get-DomeniaControl 'UxDomainBadge'
    # Filter captions fold away; every filter keeps its tooltip and automation name.
    $filters = Get-DomeniaControl 'UxSearchFilters'
    if ($null -ne $filters) {
        foreach ($field in @($filters.Children)) {
            if ($field -isnot [Windows.Controls.Panel]) { continue }
            foreach ($caption in @($field.Children)) {
                if ($caption -is [Windows.Controls.TextBlock]) { $caption.Visibility = if ([bool]$Plan.HideFilterCaptions) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible } }
            }
        }
    }
    $card = Get-DomeniaControl 'UxSearchFilterCard'
    if ($null -ne $card) { $card.Padding = [Windows.Thickness]::new([double]$Plan.FilterCardPadding);$card.Margin = [Windows.Thickness]::new(0,0,0,[double]$Plan.FilterCardBottom) }
    $bar = Get-DomeniaControl 'UxResultBar';if ($null -ne $bar) { $bar.Margin = [Windows.Thickness]::new(0,0,0,[double]$Plan.ResultBarBottom) }
    $live = Get-DomeniaControl 'UxResultLive';if ($null -ne $live) { $live.Margin = [Windows.Thickness]::new(0,[double]$Plan.ResultLiveTop,0,0) }
    $count = Get-DomeniaControl 'LblSuiteResultCount';if ($null -ne $count) { $count.Margin = [Windows.Thickness]::new(0,[double]$Plan.ResultCountTop,0,0) }
    # A low viewport keeps all commands and both trees reachable; only explanatory
    # captions and the duplicate OU summary fold (scope stays above the results and in LDAP details).
    # This is transient and never updates saved layout preferences.
    $compact=[bool]$Plan.LowHeight
    if($script:UxCompactLayoutWindow -ne $script:Window){$script:UxCompactLayoutActive=$false;$script:UxCompactLayoutWindow=$script:Window}
    # Point 112: compact pages title at the Title level of the scale, otherwise at the PageTitle level.
    $pageTitle=Get-DomeniaControl 'LblUxPageTitle';if($pageTitle){$pageTitle.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty,$(if($compact){'FontSizeTitle'}else{'FontSizePageTitle'}))}
    if($badge){$badge.Padding=if($compact){[Windows.Thickness]::new(6,1,6,1)}else{[Windows.Thickness]::new(8,3,8,3)}}
    $subRow=Get-DomeniaControl 'UxPageSubRow'
    if($compact){if($title){$title.Orientation=[Windows.Controls.Orientation]::Vertical};if($subRow){$subRow.Margin=[Windows.Thickness]::new(0)}}
    $main=Get-DomeniaControl 'UxMainLayout';if($main){$main.Margin=if($compact){[Windows.Thickness]::new(18,6,16,6)}else{[Windows.Thickness]::new(18,12,16,12)}}
    $header=Get-DomeniaControl 'UxHeader';if($header){$header.Margin=if($compact){[Windows.Thickness]::new(0,0,0,4)}else{[Windows.Thickness]::new(0,0,0,10)}}
    $header=Get-DomeniaControl 'UxPageHeader';if($header){$header.Margin=if($compact){[Windows.Thickness]::new(2,0,0,6)}else{[Windows.Thickness]::new(2,0,0,12)}}
    foreach($name in @('UxOuIntro','UxOuScopeCaption','UxOuScopeCard')){
        $control=Get-DomeniaControl $name
        if($control){$control.Visibility=if($compact){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
    }
    $scopeInfo=Get-DomeniaControl 'UxSearchScopeInfo';$hint=Get-DomeniaControl 'LblSearchHint'
    if($scopeInfo -and $hint){
        $scopeInfo.ColumnDefinitions[1].Width=if($compact){[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}else{[Windows.GridLength]::new(0)}
        [Windows.Controls.Grid]::SetRow($hint,$(if($compact){0}else{1}))
        [Windows.Controls.Grid]::SetColumn($hint,$(if($compact){1}else{0}))
        $hint.Margin=if($compact){[Windows.Thickness]::new(6,0,0,2)}else{[Windows.Thickness]::new(0,0,0,8)}
    }
    # DS-03: « 100 lignes max » needs its unit beside the number; the field host is the StackPanel of the filter.
    $widths=@{CmbGlobalType=148.0;CmbPresenceFilter=138.0;TxtGlobalLimit=128.0}
    foreach($name in $widths.Keys){
        $control=Get-DomeniaControl $name
        $field=$null
        if($control){$field=$control.Parent;if($field -is [Windows.Controls.DockPanel]){$field=$field.Parent}}
        if($field -is [Windows.Controls.StackPanel]){
            $field.Width=if($compact -and $name -eq 'TxtGlobalLimit'){120.0}else{$widths[$name]}
            $field.Margin=if($compact){[Windows.Thickness]::new(0,0,6,0)}else{[Windows.Thickness]::new(0,0,12,8)}
        }
    }
    # Queries have their own fluid Grid. Compact only its vertical rhythm, never the width of an ancestor.
    $queryBar=Get-DomeniaControl 'UxSearchQueryBar'
    if($queryBar){$queryBar.Margin=[Windows.Thickness]::new(0,$(if($compact){2}else{6}),0,0)}
    $queryHeader=Get-DomeniaControl 'UxSearchQueryHeader'
    if($queryHeader){$queryHeader.Margin=[Windows.Thickness]::new(0,0,0,$(if($compact){3}else{4}))}
    foreach($name in @('LblSearchQueryDetails','UxSearchQueryResultBar')){
        $control=Get-DomeniaControl $name
        if($control){$control.Margin=[Windows.Thickness]::new(0,3,0,0)}
    }
    # The local catalog filter is a single-line command field. Its inherited TextBox padding
    # otherwise consumes a result row together with the surrounding gaps, even at 1080p.
    $queryFilter=Get-DomeniaControl 'TxtSearchQueryFilter'
    if($queryFilter){$queryFilter.Padding=[Windows.Thickness]::new(6,2,6,2)}
    # The workshop lives inside Tools. Reclaim nested card spacing on short viewports so rows remain visible.
    $toolsScroll=Get-DomeniaControl 'UxResultToolsScroll'
    if($toolsScroll){$toolsScroll.MaxHeight=if([bool]$Plan.TinyHeight){100.0}elseif([bool]$Plan.Short){90.0}else{150.0}}
    $toolsCard=Get-DomeniaControl 'UxApplicationToolsCard'
    if($toolsCard){$toolsCard.Padding=[Windows.Thickness]::new($(if([bool]$Plan.Short){2.0}else{10.0}));$toolsCard.Margin=[Windows.Thickness]::new($(if([bool]$Plan.Short){0.0}else{4.0}))}
    $workshopCompact=[bool]$Plan.Short
    foreach($name in @('UxQueryLayout','UxQueryResultsLayout')){
        $control=Get-DomeniaControl $name
        if($control){$normal=if($name -eq 'UxQueryLayout'){12.0}else{10.0};$control.Margin=[Windows.Thickness]::new($(if($workshopCompact){4.0}else{$normal}))}
    }
    $control=Get-DomeniaControl 'UxQueryCard'
    if($control){$control.Padding=[Windows.Thickness]::new($(if($workshopCompact){6.0}else{18.0}))}
    foreach($name in @('UxQueryScopeBar','UxQueryHeader')){
        $control=Get-DomeniaControl $name
        if($control){$normal=if($name -eq 'UxQueryScopeBar'){8.0}else{10.0};$control.Margin=[Windows.Thickness]::new(0,0,0,$(if($workshopCompact){4.0}else{$normal}))}
    }
    $control=Get-DomeniaControl 'UxQueryCardLayout'
    if($control){$control.Margin=[Windows.Thickness]::new(0,$(if($workshopCompact){0.0}else{8.0}),0,0)}
    $control=Get-DomeniaControl 'LblQueryStatus'
    if($control){$control.Margin=if($workshopCompact){[Windows.Thickness]::new(0,2,0,2)}else{[Windows.Thickness]::new(0,4,0,8)}}
    $queryHeights=@{TxtSearchQueryFilter=30.0;CmbWorkView=34.0;BtnWorkView=34.0;BtnSearchQueryFavorite=34.0;BtnSearchQueryWorkshop=34.0;CmbSearchQueryResult=30.0;BtnQueryClearSearch=30.0}
    foreach($name in $queryHeights.Keys){
        $control=Get-DomeniaControl $name
        if($control){$control.MinHeight=if($compact){28.0}else{$queryHeights[$name]}}
    }
    foreach($name in @('TxtGlobalLimit','TxtSuiteResultFilter','BtnSuiteResultClear')){
        $control=Get-DomeniaControl $name
        if($control){
            if($compact){$control.Padding=[Windows.Thickness]::new(6,2,6,2)}
            else{$control.ClearValue([Windows.Controls.Control]::PaddingProperty)}
        }
    }
    $results=Get-DomeniaControl 'UxResultsCard';if($results){$results.Padding=if($compact){[Windows.Thickness]::new(6)}else{[Windows.Thickness]::new(12)}}
    $actions=Get-DomeniaControl 'UxResultActionsRow';if($actions){$actions.Margin=if($compact){[Windows.Thickness]::new(0,0,0,4)}else{[Windows.Thickness]::new(0,0,0,8)}}
    # SP-15: check on click and its user sub-option keep a short wording in compact mode.
    $consoleCheck=Get-DomeniaControl 'ChkLiveVerifyOnClick';if($consoleCheck){$consoleCheck.Content=if($compact){'Au clic'}else{'Vérifier au clic'}}
    $userCheck=Get-DomeniaControl 'ChkLiveUsersOnClick';if($userCheck){$userCheck.Content=if($compact){'+ utilisateur'}else{'+ utilisateur connecté'}}
    $recheck=Get-DomeniaControl 'BtnLiveRecheck';if($recheck){$recheck.Content=if($compact){'Revérifier'}else{'Revérifier ce poste'}}
    # UI-23: « Vérifier la liste ▾ » keeps its own label (the reading of the session, or Arrêter during a survey);
    # compact mode only tightens the buttons so that the action row stays on one line. The two parts of the split
    # button stay joined: the spacing of the row goes on the panel that holds them, never between them.
    foreach($name in @('BtnLiveRecheck','BtnParkVerify')){
        $button=Get-DomeniaControl $name
        if($button){
            $button.Padding=if($compact){[Windows.Thickness]::new(6,4,6,4)}else{[Windows.Thickness]::new(10,4,10,4)}
            $spaced=$button
            if($name -eq 'BtnParkVerify'){$spaced=$button.Parent}
            if($spaced -is [Windows.FrameworkElement]){$spaced.Margin=if($compact){[Windows.Thickness]::new(0,0,4,4)}else{[Windows.Thickness]::new(0,0,8,4)}}
        }
    }
    if($consoleCheck){$consoleCheck.Margin=if($compact){[Windows.Thickness]::new(0,0,4,4)}else{[Windows.Thickness]::new(0,0,8,4)}}
    if($userCheck){$userCheck.Margin=if($compact){[Windows.Thickness]::new(0,0,8,4)}else{[Windows.Thickness]::new(0,0,14,4)}}
    $statuses=Get-DomeniaControl 'UxResultLiveStatuses'
    if($live -and $statuses){
        $live.ColumnDefinitions[0].Width=if($compact){[Windows.GridLength]::new(470)}else{[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}
        $live.ColumnDefinitions[1].Width=if($compact){[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}else{[Windows.GridLength]::new(0)}
        [Windows.Controls.Grid]::SetRow($statuses,$(if($compact){0}else{1}))
        [Windows.Controls.Grid]::SetColumn($statuses,$(if($compact){1}else{0}))
        $statuses.Margin=if($compact){[Windows.Thickness]::new(8,0,0,0)}else{[Windows.Thickness]::new(0)}
        # DS-06: the selection and list states share one line of two halves in the normal layout (no help rows under
        # the actions); in compact mode they stack in the column beside the actions. The short count of the survey of
        # the list (UX-12) takes the place of the list state, so it follows the same slot.
        if($statuses.ColumnDefinitions.Count -ge 2){
            $statuses.ColumnDefinitions[1].Width=if($compact){[Windows.GridLength]::new(0)}else{[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}
            foreach($name in @('LblLiveState','UxParkProgress')){
                $liveState=Get-DomeniaControl $name
                if($null -eq $liveState){continue}
                [Windows.Controls.Grid]::SetRow($liveState,$(if($compact){1}else{0}))
                [Windows.Controls.Grid]::SetColumn($liveState,$(if($compact){0}else{1}))
                $liveState.Margin=if($compact){[Windows.Thickness]::new(0)}else{[Windows.Thickness]::new(12,0,0,0)}
            }
        }
    }
    $ouColumn=Get-DomeniaControl 'UxOuColumn'
    if($ouColumn){
        if($compact -and -not [bool]$script:UxCompactLayoutActive){$script:UxCompactOuWidth=$ouColumn.Width;$ouColumn.Width=[Windows.GridLength]::new(230)}
        elseif(-not $compact -and [bool]$script:UxCompactLayoutActive -and $null -ne $script:UxCompactOuWidth){$ouColumn.Width=$script:UxCompactOuWidth}
    }
    $ouPanel=Get-DomeniaControl 'SearchOuPanel';if($ouPanel){$ouPanel.Padding=if($compact){[Windows.Thickness]::new(10)}else{[Windows.Thickness]::new(16)}}
    # The OU refresh footer must leave room for navigation on a short viewport.
    # Keep the four commands visible in two rows; only duplicate explanatory text
    # becomes single-line (the selected scope also remains above the results).
    $ouRefresh=Get-DomeniaControl 'UxSearchOuRefresh'
    if($ouRefresh){
        $ouRefresh.Padding=[Windows.Thickness]::new($(if($compact){4.0}else{8.0}))
        $ouRefresh.Margin=[Windows.Thickness]::new(0,$(if($compact){4.0}else{8.0}),0,0)
    }
    $ouRefreshTitle=Get-DomeniaControl 'UxSearchOuRefreshTitle'
    if($ouRefreshTitle){$ouRefreshTitle.Visibility=if($compact){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
    foreach($name in @('LblSearchOuRefreshScope','LblSearchOuRefreshStatus')){
        $control=Get-DomeniaControl $name
        if($control){
            $control.TextWrapping=if($compact){[Windows.TextWrapping]::NoWrap}else{[Windows.TextWrapping]::Wrap}
            $control.MaxHeight=if($compact){18.0}elseif($name -eq 'LblSearchOuRefreshScope'){48.0}else{58.0}
        }
    }
    $ouRefreshActions=Get-DomeniaControl 'UxSearchOuRefreshActions'
    if($ouRefreshActions){$ouRefreshActions.Margin=[Windows.Thickness]::new(0,$(if($compact){2.0}else{6.0}),0,0)}
    foreach($name in @('BtnSearchRefreshBase','BtnSearchRefreshPostes','BtnSearchRefreshBoth','BtnSearchRefreshStop')){
        $button=Get-DomeniaControl $name
        if($button){
            $button.MinHeight=if($compact){28.0}else{30.0}
            $button.Padding=if($compact){[Windows.Thickness]::new(6,2,6,2)}else{[Windows.Thickness]::new(8,3,8,3)}
            $button.Margin=[Windows.Thickness]::new(0,0,$(if($name -eq 'BtnSearchRefreshStop'){0.0}else{4.0}),$(if($compact){2.0}else{4.0}))
            if($compact){$button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty,'FontSizeSmall')}else{$button.ClearValue([Windows.Controls.Control]::FontSizeProperty)}
        }
    }
    $ouRefreshPostes=Get-DomeniaControl 'BtnSearchRefreshPostes'
    if($ouRefreshPostes){$ouRefreshPostes.Content='Ping'}
    $scope=Get-DomeniaControl 'UxOuScopeCard'
    if($scope){$scope.Padding=if($compact){[Windows.Thickness]::new(6)}else{[Windows.Thickness]::new(12)};$scope.Margin=if($compact){[Windows.Thickness]::new(0,0,0,6)}else{[Windows.Thickness]::new(0,0,0,12)}}
    # The 'Dans :' chip of the work views keeps a 24 px target, reduced to the scope line height on a short screen.
    $viewScope=Get-DomeniaControl 'CmbWorkViewScope'
    if($viewScope){$viewScope.Height=if($compact){18.0}else{24.0};$viewScope.Margin=if($compact){[Windows.Thickness]::new(8,0,0,0)}else{[Windows.Thickness]::new(8,0,0,2)}}
    $scopeName=Get-DomeniaControl 'LblOuScopeName';if($scopeName){$scopeName.MaxHeight=if($compact){40.0}else{[double]::PositiveInfinity}}
    # A low or short-and-narrow viewport keeps the query command beside the filters.
    # This choice is independent from tiny spacing and from the operator's saved OU width.
    Set-DomeniaSearchQueryOptionsLayout -Compact ([bool]$Plan.QueryOptionsCompact)
    if([bool]$Plan.TinyHeight){
        if($title){$title.Orientation=[Windows.Controls.Orientation]::Horizontal}
        if($subRow){$subRow.Margin=[Windows.Thickness]::new(10,0,0,0)}
        # At the minimum viewport retain full-size controls and spend fewer pixels on empty gaps.
        if($main){$main.Margin=[Windows.Thickness]::new(18,2,16,2)}
        $topHeader=Get-DomeniaControl 'UxHeader';if($topHeader){$topHeader.Margin=[Windows.Thickness]::new(0,0,0,2)}
        $pageHeader=Get-DomeniaControl 'UxPageHeader';if($pageHeader){$pageHeader.Margin=[Windows.Thickness]::new(2,0,0,2)}
        if($card){$card.Padding=[Windows.Thickness]::new(3);$card.Margin=[Windows.Thickness]::new(0,0,0,2)}
        if($results){$results.Padding=[Windows.Thickness]::new(3)}
        if($bar){$bar.Margin=[Windows.Thickness]::new(0)}
        if($actions){$actions.Margin=[Windows.Thickness]::new(0)}
    }
    # Only an entry into the tiny layout folds optional controls. Operator expansion survives
    # ordinary layout updates; leaving the tiny viewport restores the full command panels.
    $tiny=[bool]$Plan.TinyHeight
    if(($script:UxDetailsLayoutWindow -ne $script:Window) -or ($script:UxDetailsTiny -ne $tiny)){
        $refresh=Get-DomeniaControl 'UxOuRefreshExpander'
        if($refresh){$refresh.IsExpanded=(-not $tiny)}
        # Actions, filtres et vues start folded and a short window keeps them folded.
        # Leaving that height does not reopen the panel.
        $tools=Get-DomeniaControl 'UxResultToolsExpander'
        if($tools -and ($script:UxDetailsLayoutWindow -ne $script:Window -or $tiny)){$tools.IsExpanded=$false}
        $script:UxDetailsLayoutWindow=$script:Window;$script:UxDetailsTiny=$tiny
    }
    $script:UxCompactLayoutActive=$compact

    # Journal shown folded while the screen is short, unless the operator unfolds it; the saved state is untouched.
    $hold = ([bool]$Plan.FoldJournal -and (-not [bool]$script:UxLogCollapsed) -and (-not [bool]$script:UxShortLogReleased))
    # Applied every time (idempotent): the held flag alone must not decide what the journal row shows.
    if ($hold) { $script:UxShortLogHeld = $true;Set-DomeniaExperienceJournalLayout -Collapsed $true -Transient }
    elseif ([bool]$script:UxShortLogHeld) { Set-DomeniaExperienceJournalLayout -Collapsed ([bool]$script:UxLogCollapsed) -Transient;$script:UxShortLogHeld = $false }
}

function Get-DomeniaUxAvailableSize {
    # Responsive breakpoints follow the same logical viewport as the zoomed shell.
    # The footer and the window chrome stay outside that viewport.
    $width = [double]$script:Window.ActualWidth
    if ($width -le 0) { $width = [double]$script:Window.Width }
    $height = [double]$script:Window.ActualHeight
    if ($height -le 0) { $height = [double]$script:Window.Height }
    $scroll = Get-DomeniaControl 'RootScroll'
    if ($null -ne $scroll) {
        if ($scroll.ViewportWidth -gt 0) { $width = [double]$scroll.ViewportWidth }
        if ($scroll.ViewportHeight -gt 0) { $height = [double]$scroll.ViewportHeight }
    }
    $percent = [int]$script:DomeniaUiZoomPercent
    if ($percent -lt 80 -or $percent -gt 150) { $percent = 100 }
    $scale = [double]$percent / 100.0
    return [pscustomobject]@{Width=[Math]::Max(900.0,$width/$scale);Height=[Math]::Max(450.0,$height/$scale)}
}

function Update-DomeniaUxLayout {
    if ($null -eq $script:Window) { return }
    $availableSize = Get-DomeniaUxAvailableSize
    $width = [double]$availableSize.Width;$height = [double]$availableSize.Height
    $heightPlan = Get-DomeniaUxHeightPlan -Height $height -Width $width
    if ([bool]$heightPlan.Short -ne [bool]$script:UxShortScreen) {
        $script:UxShortScreen = [bool]$heightPlan.Short;$script:UxShortHelpOpen = $false;$script:UxShortLogReleased = $false;$script:UxShortNavReleased = $false
    }
    $script:UxShortNavFold = [bool]$heightPlan.FoldNavigation
    Update-DomeniaUxSidebar
    $panel = Get-DomeniaControl 'UxHelpPanel';$column = Get-DomeniaControl 'UxHelpColumn'
    if ($null -eq $panel -or $null -eq $column) { return }
    $helpVisible = $script:UxHelpVisible;$compactOpen = $script:UxHelpCompactOpen
    if ([bool]$script:UxShortScreen) { $helpVisible = [bool]$script:UxShortHelpOpen;$compactOpen = [bool]$script:UxShortHelpOpen }
    $plan = Get-DomeniaUxLayoutPlan -Width $width -NavCollapsed (Test-DomeniaUxNavFolded) -HelpVisible $helpVisible -CompactHelpOpen $compactOpen
    $signature = '{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}' -f $plan.Compact,$plan.HelpShown,$plan.NavWidth,$script:UxShortScreen,$heightPlan.LowHeight,$plan.HeaderStacked,$heightPlan.TinyHeight,$heightPlan.QueryOptionsCompact
    if ($signature -eq $script:UxLayoutSignature) { return }
    $script:UxLayoutSignature=$signature
    Set-DomeniaUxHeaderLayout -Stacked ([bool]$plan.HeaderStacked)
    $button = Get-DomeniaControl 'BtnUxHelpToggle'
    if (-not $plan.HelpShown -and $panel.IsKeyboardFocusWithin -and $null -ne $button) { [void]$button.Focus() }
    $column.Width = [Windows.GridLength]::new([double]$plan.ColumnWidth)
    if ($plan.Compact) {
        [Windows.Controls.Grid]::SetColumn($panel,0)
        $panel.Width=$plan.HelpWidth;$panel.HorizontalAlignment=[Windows.HorizontalAlignment]::Right
        [Windows.Controls.Panel]::SetZIndex($panel,20)
    } else {
        [Windows.Controls.Grid]::SetColumn($panel,1)
        $panel.Width=[double]::NaN;$panel.HorizontalAlignment=[Windows.HorizontalAlignment]::Stretch
        [Windows.Controls.Panel]::SetZIndex($panel,0)
    }
    $panel.Visibility = if ($plan.HelpShown) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $workspaces=Get-DomeniaControl 'WorkspaceTabs'
    if($null -ne $workspaces){$workspaces.Margin=[Windows.Thickness]::new(0,0,[double]$plan.WorkspaceGap,0)}
    if ($null -ne $button) {
        # PF-24 / UI-10: an icon button keeps a one-line tool tip; the whole catalogue text stays its help text.
        $button.ToolTip = if ($plan.HelpShown) { 'Réduire le panneau dʼaide.' } else { 'Afficher le panneau dʼaide.' }
        [Windows.Automation.AutomationProperties]::SetName($button,$(if ($plan.HelpShown) { 'Réduire lʼaide' } else { 'Afficher lʼaide' }))
    }
    Set-DomeniaUxShortLayout -Plan $heightPlan
}

function Switch-DomeniaUxHelp {
    if ($null -eq $script:Window) { return }
    if ([bool]$script:UxShortScreen) {
        # Short screen: the help opens for this session only; the saved choice is untouched.
        $script:UxShortHelpOpen = -not [bool]$script:UxShortHelpOpen
        $opened = [bool]$script:UxShortHelpOpen
        Update-DomeniaUxLayout
        # UI-11: opening the help removes the dot of the first launch here too.
        if ($opened) { Hide-DomeniaUxHelpBadge }
        return
    }
    $width=[double](Get-DomeniaUxAvailableSize).Width
    $plan=Get-DomeniaUxLayoutPlan -Width $width -NavCollapsed $script:UxNavCollapsed -HelpVisible $script:UxHelpVisible -CompactHelpOpen $script:UxHelpCompactOpen
    # A deliberate toggle applies to both layout modes; resize must not undo it.
    $script:UxHelpVisible=-not $plan.HelpShown
    $script:UxHelpCompactOpen=$script:UxHelpVisible
    Update-DomeniaUxLayout
    Hide-DomeniaUxHelpBadge
    Save-DomeniaUxLayoutSettings
}

function Initialize-DomeniaUxHelpBadge {
    # UI-11: at the first launch, while the help is closed, a dot on « ? » shows where the explanations are. The launch
    # marks it as seen in memory; the preferences saved during the session or at closing keep it.
    $seen = ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxHelpIntroSeen' -Default $false)
    $state = Get-DomeniaHelpBadgeState -IntroSeen $seen -HelpShown ([bool]$script:UxHelpVisible)
    Set-DomeniaUxHelpBadge -Show ([bool]$state.Show) -ItemStatus ([string]$state.ItemStatus)
    if ([bool]$state.MarkSeen) { Set-DomeniaSetting -Name 'UxHelpIntroSeen' -Value $true }
}

function Set-DomeniaUxHelpBadge {
    param([bool]$Show=$false,[AllowEmptyString()][string]$ItemStatus='')
    $badge = Get-DomeniaControl 'UxHelpBadge'
    if ($null -ne $badge) { $badge.Visibility = if ($Show) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
    $button = Get-DomeniaControl 'BtnUxHelpToggle'
    if ($null -ne $button) { [Windows.Automation.AutomationProperties]::SetItemStatus($button,$ItemStatus) }
}

function Hide-DomeniaUxHelpBadge {
    # UI-11: opening the help once is enough; the dot does not come back.
    Set-DomeniaUxHelpBadge -Show $false
    Set-DomeniaSetting -Name 'UxHelpIntroSeen' -Value $true
}

function Get-DomeniaUxHelpGuidePage {
    # UI-11: page whose guide chapter the help names. The query workshop is a tab of Outils (ApplicationToolTabs) with
    # its own chapter; the other tools keep the chapter of Outils.
    $page = ''
    try { $page = [string](Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name } catch { $page = '' }
    if ($page -eq 'TabApplicationTools') {
        $tool = ''
        try { $tool = [string](Get-DomeniaControl 'ApplicationToolTabs').SelectedItem.Name } catch { $tool = '' }
        if ($tool -eq 'WsQueryWorkshop') { return $tool }
    }
    return $page
}

function Update-DomeniaUxHelpGuide {
    # UI-11: chapter of the guide for the page shown (no file access here; the PDF is looked up on the click).
    $label = Get-DomeniaControl 'LblUxHelpGuide'
    if ($null -eq $label) { return }
    $label.Text = [string](Get-DomeniaHelpGuideChapter -Page (Get-DomeniaUxHelpGuidePage)).Text
}

function Open-DomeniaHelpGuide {
    # UI-11, explicit gesture: opens the PDF of the guide of the page with the program associated with PDF files. The file
    # is looked up in the folder DOC beside Domenia (the package, its parent or the delivery folder); nothing is read on
    # the network and nothing is downloaded. Without the file, the help says where to place it.
    $chapter = Get-DomeniaHelpGuideChapter -Page (Get-DomeniaUxHelpGuidePage)
    $root = [string]$script:RootDir
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($root) {
        $candidates.Add((Join-Path $root ('DOC\' + $chapter.File)))
        $parent = Split-Path -Parent $root
        if ($parent) {
            $candidates.Add((Join-Path $parent ('DOC\' + $chapter.File)))
            $grand = Split-Path -Parent $parent
            if ($grand) { $candidates.Add((Join-Path $grand ('DOC\' + $chapter.File))) }
        }
    }
    $path = ''
    foreach ($candidate in $candidates) { if ([IO.File]::Exists($candidate)) { $path = $candidate; break } }
    if (-not $path) {
        Set-DomeniaContextHint -Title ([string]$chapter.GuideTitle + ' introuvable') -Text ('Placez ' + [string]$chapter.File + ' dans un dossier DOC à côté de Domenia, puis réessayez. En attendant : ' + [string]$chapter.Text + '.')
        return
    }
    try {
        Start-Process -FilePath $path
        Set-DomeniaContextHint -Title ([string]$chapter.GuideTitle) -Text ('Le guide sʼouvre. Chapitre de cette page : ' + [string]$chapter.Chapter + ', ' + [string]$chapter.Title + '.')
    } catch {
        Set-DomeniaContextHint -Title 'Guide non ouvert' -Text ('Aucun lecteur de PDF nʼa ouvert ' + $path + '. Le chapitre de cette page : ' + [string]$chapter.Text + '.')
    }
}

function Switch-DomeniaUxLog {
    $row=Get-DomeniaControl 'UxLogRow'
    if($null -eq $row){return}
    if([bool]$script:UxShortLogHeld){
        # Short screen: the operator unfolds the journal for this session; the saved state stays as it was.
        $script:UxShortLogReleased=$true;$script:UxShortLogHeld=$false
        Set-DomeniaExperienceJournalLayout -Collapsed $false -Transient
        return
    }
    if(-not $script:UxLogCollapsed){$script:UxLogHeight=ConvertTo-SuiteNumber $row.ActualHeight -Default 180 -Minimum 100 -Maximum 600}
    Set-DomeniaExperienceJournalLayout -Collapsed (-not $script:UxLogCollapsed)
    Save-DomeniaExperiencePreferences
}

function Initialize-DomeniaUxShell {
    if ($null -eq $script:Window -or $script:UxShellInitialized) { return }
    Import-DomeniaUxHelpCatalogue
    foreach ($control in @($script:Ctrl.Values)) { Initialize-DomeniaUxControlHelp -Control $control }
    foreach ($pair in @($script:Ctrl.GetEnumerator())) {
        if ([string]$pair.Key -notmatch '^BtnUx(Nav|Home|Step|HelpAccounts)') { continue }
        $button=$pair.Value
        if ($button -is [Windows.Controls.Button] -and [string]$button.Uid -in @(Get-DomeniaUxRouteNames)) {
            $button.Add_Click({param($sender,$eventArgs) Invoke-DomeniaUxRoute -Route ([string]$sender.Uid)})
        }
    }
    (Get-DomeniaControl 'BtnUxHelpToggle').Add_Click({Switch-DomeniaUxHelp})
    (Get-DomeniaControl 'BtnUxHelpClose').Add_Click({Switch-DomeniaUxHelp})
    (Get-DomeniaControl 'BtnUxSidebarToggle').Add_Click({Switch-DomeniaUxSidebar})
    (Get-DomeniaControl 'BtnUxCopyOuPath').Add_Click({Copy-DomeniaUxOuPath})
    (Get-DomeniaControl 'BtnUxLogToggle').Add_Click({Switch-DomeniaUxLog})
    (Get-DomeniaControl 'WorkspaceTabs').Add_SelectionChanged({
        param($sender,$eventArgs)
        if ($sender -eq $eventArgs.OriginalSource) { Sync-DomeniaUxNavigation }
    })
    # UI-11: a tool chosen inside Outils (the query workshop has its own chapter) updates the chapter of the guide.
    $tools = Get-DomeniaControl 'ApplicationToolTabs'
    if ($null -ne $tools) {
        $tools.Add_SelectionChanged({
            param($sender,$eventArgs)
            if ($sender -eq $eventArgs.OriginalSource) { Update-DomeniaUxHelpGuide }
        })
    }
    $script:UxHelpVisible=ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxHelpVisible' -Default $false) -Default $false
    $script:UxHelpCompactOpen=ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxHelpCompactOpen' -Default $false)
    $script:UxNavCollapsed=ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxNavCollapsed' -Default $false)
    $script:UxNavLayoutSignature=''
    try { Update-DomeniaSearchScopeUi } catch { Write-DomeniaSwallowed 'UX' 'Initialize-DomeniaUxShell' $_ }
    $script:Window.Add_SizeChanged({Update-DomeniaUxLayout})
    $script:Window.Add_ContentRendered({Sync-DomeniaUxNavigation;Update-DomeniaUxLayout})
    $script:Window.Add_Closed({$script:UxShellInitialized=$false;$script:UxLayoutSignature='';$script:UxHelpCompactOpen=$false;$script:UxNavLayoutSignature='';$script:UxShortScreen=$false;$script:UxShortHelpOpen=$false;$script:UxShortLogHeld=$false;$script:UxShortLogReleased=$false;$script:UxShortNavFold=$false;$script:UxShortNavReleased=$false;$script:UxNavButtonCache=$null;Stop-DomeniaReadOnlyReturnTimer})
    # UI-11: dot of the first launch on « ? » and the chapter of the guide of the page.
    $guide = Get-DomeniaControl 'BtnUxHelpGuide';if ($null -ne $guide) { $guide.Add_Click({ Open-DomeniaHelpGuide }) }
    Initialize-DomeniaUxHelpBadge
    # L08: subject chip, account of the menu foot, search bar (recent entries, local suggestions) and empty pages.
    $clear = Get-DomeniaControl 'BtnUxSubjectClear';if ($null -ne $clear) { $clear.Add_Click({ Clear-DomeniaUxSubject }) }
    $account = Get-DomeniaControl 'BtnUxNavAccount';if ($null -ne $account) { $account.Add_Click({ param($sender,$eventArgs) Show-DomeniaUxAccountMenu -Button $sender }) }
    Initialize-DomeniaUxSearchBar
    Initialize-DomeniaUxEmptyStates
    # FO-22: theme menu, and the Automatique choice or high contrast followed on the UI thread only.
    Initialize-DomeniaUxThemeMenu
    $script:Window.Add_Activated({Update-DomeniaAutoTheme})
    if ($null -eq $script:DomeniaHighContrastHandler) {
        $script:DomeniaHighContrastHandler=[ComponentModel.PropertyChangedEventHandler]{param($sender,$eventArgs) if([string]$eventArgs.PropertyName -eq 'HighContrast'){Update-DomeniaAutoTheme}}
        [Windows.SystemParameters]::add_StaticPropertyChanged($script:DomeniaHighContrastHandler)
        $script:Window.Add_Closed({if($null -ne $script:DomeniaHighContrastHandler){[Windows.SystemParameters]::remove_StaticPropertyChanged($script:DomeniaHighContrastHandler);$script:DomeniaHighContrastHandler=$null}})
    }
    $script:UxShellInitialized=$true
    Initialize-DomeniaExperience
    Update-DomeniaUxProfileSwitch
    Update-DomeniaUxProfileVisibility
    Update-DomeniaUxThemeToggle
    Sync-DomeniaUxNavigation
    Update-DomeniaReadOnlySwitch
    Update-DomeniaUxLayout
}

function Get-DomeniaSystemColorTable {
    # FO-22: colours of the current Windows theme (high contrast included), as '#RRGGBB', by system role.
    $table=[ordered]@{}
    foreach ($name in @('Window','WindowText','Control','ControlText','Highlight','HighlightText','HotTrack','GrayText')) {
        $color=[Windows.SystemColors]::($name + 'Color')
        $table[$name]=('#{0:X2}{1:X2}{2:X2}' -f $color.R,$color.G,$color.B)
    }
    return $table
}

function Get-DomeniaSystemColorSignature {
    # FO-22: one text for the system colours of a high contrast theme, compared by Update-DomeniaAutoTheme.
    param($Table)
    if ($null -eq $Table) { $Table = Get-DomeniaSystemColorTable }
    return (@(foreach ($name in @($Table.Keys)) { [string]$name + '=' + [string]$Table[$name] }) -join ';')
}

function Set-DomeniaUxPalette {
    param($Window,[ValidateSet('Light','Dark')][string]$Theme='Light')
    if ($null -eq $Window) { return }
    $palette=Get-SuitePalette -Theme $Theme
    # FO-22: a Windows high contrast theme replaces every token by a system colour (Get-DomeniaHighContrastRoles).
    $highContrast=$false
    try { $highContrast=[bool][Windows.SystemParameters]::HighContrast } catch { $highContrast=$false }
    # The system colours painted are kept as a signature: moving from one high contrast theme to another (Noir to
    # Blanc) leaves HighContrast true and must still repaint (Update-DomeniaAutoTheme).
    $systemColors=''
    if ($highContrast) {
        $system=Get-DomeniaSystemColorTable
        $palette=ConvertTo-DomeniaHighContrastPalette -Palette $palette -SystemColors $system
        $systemColors=Get-DomeniaSystemColorSignature -Table $system
    }
    $script:DomeniaPaintedHighContrast=$highContrast
    $script:DomeniaPaintedSystemColors=$systemColors
    $converter=[Windows.Media.BrushConverter]::new()
    foreach ($key in $palette.Keys) { $Window.Resources[$key]=$converter.ConvertFromInvariantString([string]$palette[$key]) }
    # CD-05: colours drawn by code (charts, presence) read this painted palette through Get-DomeniaThemeColor.
    $script:DomeniaPaintedPalette=$palette
    $Window.Background=$Window.Resources['WindowBg'];$Window.Foreground=$Window.Resources['TextColor']
    # Native popup/control brushes in the same window scope, not a system-wide change.
    $Window.Resources[[Windows.SystemColors]::WindowBrushKey]=$Window.Resources['BgInput']
    $Window.Resources[[Windows.SystemColors]::WindowTextBrushKey]=$Window.Resources['TextColor']
    $Window.Resources[[Windows.SystemColors]::ControlBrushKey]=$Window.Resources['BgCard']
    $Window.Resources[[Windows.SystemColors]::ControlTextBrushKey]=$Window.Resources['TextColor']
    foreach ($tuple in @(@('TxtUiLog','Background','LogBg'),@('TxtUiLog','Foreground','LogFg'),@('LogPanel','Background','BgCard'),@('LogPanel','BorderBrush','BorderColor'))) {
        $element=$Window.FindName([string]$tuple[0])
        if ($null -eq $element) { continue }
        if ($tuple[1] -eq 'Foreground') { $element.Foreground=$Window.Resources[[string]$tuple[2]] }
        elseif ($tuple[1] -eq 'BorderBrush') { $element.BorderBrush=$Window.Resources[[string]$tuple[2]] }
        else { $element.Background=$Window.Resources[[string]$tuple[2]] }
    }
}

function Set-DomeniaWindowFrameTheme {
    # DS-18: the Windows title bar of a Domenia window follows its theme (DWM, Domenia-Identity.Types.cs). Before the
    # window owns a handle, the theme is kept and applied once the handle exists (SourceInitialized, once per window).
    # Returns $true when Windows accepted the colour now; never throws (an older Windows keeps its title bar).
    param($Window,[AllowEmptyString()][string]$Theme='')
    if (($null -eq $Window) -or ($Window -isnot [Windows.Window])) { return $false }
    if ($Theme -notin @('Light','Dark')) { $Theme = [string](Get-Variable -Name BootTheme -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    if ($Theme -ne 'Dark') { $Theme = 'Light' }
    if ($null -eq ('Domenia.WindowFrame' -as [type])) { return $false }
    try {
        $Window.Resources['Domenia.FrameTheme'] = $Theme
        $handle = [Windows.Interop.WindowInteropHelper]::new($Window).Handle
        if ($handle -eq [IntPtr]::Zero) {
            if (-not $Window.Resources.Contains('Domenia.FrameHooked')) {
                $Window.Resources['Domenia.FrameHooked'] = $true
                $Window.Add_SourceInitialized({ param($sender,$eventArgs) [void](Set-DomeniaWindowFrameTheme -Window $sender -Theme ([string]$sender.Resources['Domenia.FrameTheme'])) })
            }
            return $false
        }
        return [bool][Domenia.WindowFrame]::SetDarkTitleBar($handle,($Theme -eq 'Dark'))
    } catch { return $false }
}

function ConvertTo-DomeniaUxFlag {
    param($Value,[bool]$Default=$false)
    if ($Value -is [bool]) { return $Value }
    $parsed = $false
    if ($null -ne $Value -and [bool]::TryParse([string]$Value,[ref]$parsed)) { return $parsed }
    return $Default
}

function Get-DomeniaUxLayoutPlan {
    param([double]$Width=1360,[bool]$NavCollapsed=$false,[bool]$HelpVisible=$true,[bool]$CompactHelpOpen=$false)
    # Dimensions in WPF device-independent units, not physical pixels.
    $navWidth = if ($NavCollapsed) { 68.0 } else { 204.0 }
    $available = [Math]::Max(900.0,$Width) - $navWidth - 40.0
    $compact = $available -lt 1040.0
    $shown = if ($compact) { $CompactHelpOpen } else { $HelpVisible }
    [pscustomobject]@{
        # SP-03 (L08): below 1000 units of main area the read-only switch moves to the top bar, so the page title keeps
        # room beside the fixed slots of the activity strip (504 units) instead of being clipped.
        HeaderStacked=($available -lt 1000.0)
        NavWidth=$navWidth;Compact=$compact;HelpShown=$shown
        HelpWidth=300.0
        ColumnWidth=$(if ($shown -and -not $compact) {300.0} else {0.0})
        WorkspaceGap=$(if ($shown -and -not $compact) {12.0} else {0.0})
    }
}

function Save-DomeniaUxLayoutSettings {
    Set-DomeniaSetting -Name 'UxNavCollapsed' -Value ([bool]$script:UxNavCollapsed)
    Set-DomeniaSetting -Name 'UxHelpVisible' -Value ([bool]$script:UxHelpVisible)
    Set-DomeniaSetting -Name 'UxHelpCompactOpen' -Value ([bool]$script:UxHelpCompactOpen)
    if ($null -ne (Get-Command Save-DomeniaSettings -CommandType Function -ErrorAction SilentlyContinue)) {
        Save-DomeniaSettings -Immediate
    }
}

function Test-DomeniaUxNavFolded {
    # Saved choice, or a temporary fold on a short and narrow screen (D006) that the operator can undo.
    return ([bool]$script:UxNavCollapsed -or ([bool]$script:UxShortNavFold -and (-not [bool]$script:UxShortNavReleased)))
}

function Switch-DomeniaUxSidebar {
    if ((-not [bool]$script:UxNavCollapsed) -and [bool]$script:UxShortNavFold -and (-not [bool]$script:UxShortNavReleased)) {
        # Short screen: the operator unfolds the menu for this session; the saved choice is untouched.
        $script:UxShortNavReleased = $true
        Update-DomeniaUxLayout
        return
    }
    $script:UxNavCollapsed = -not $script:UxNavCollapsed
    Update-DomeniaUxLayout
    Save-DomeniaUxLayoutSettings
}

function Update-DomeniaUxSidebar {
    $collapsed = [bool](Test-DomeniaUxNavFolded)
    if ($script:UxNavLayoutSignature -ceq [string]$collapsed) { return }
    $column = Get-DomeniaControl 'UxNavColumn'; $sidebar=Get-DomeniaControl 'UxSidebar'
    if ($null -eq $column -or $null -eq $sidebar) { return }
    $column.Width=[Windows.GridLength]::new($(if($collapsed){68.0}else{204.0}))
    $sidebar.Padding=[Windows.Thickness]::new($(if($collapsed){8.0}else{10.0}))
    foreach ($name in @('UxBrandExpanded','UxNavFooter')) {
        $c=Get-DomeniaControl $name
        if ($null -ne $c) { $c.Visibility=if($collapsed){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible} }
    }
    $brand=Get-DomeniaControl 'UxBrandCompact'
    if($null -ne $brand){$brand.Visibility=if($collapsed){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}}
    foreach($suffix in @('Home','Search','Object','Relations','Computer','Support','Accounts','Tools')) {
        $label=Get-DomeniaControl ('UxNavLabel'+$suffix)
        $icon=Get-DomeniaControl ('UxNavIcon'+$suffix)
        $content=Get-DomeniaControl ('UxNavContent'+$suffix)
        $button=Get-DomeniaControl ('BtnUxNav'+$suffix)
        if($null -ne $label){$label.Visibility=if($collapsed){[Windows.Visibility]::Collapsed}else{[Windows.Visibility]::Visible}}
        if($null -ne $icon){$icon.Margin=[Windows.Thickness]::new(0,0,$(if($collapsed){0}else{10}),0)}
        if($null -ne $content){$content.HorizontalAlignment=if($collapsed){[Windows.HorizontalAlignment]::Center}else{[Windows.HorizontalAlignment]::Left}}
        if($null -ne $button){$button.HorizontalContentAlignment=if($collapsed){[Windows.HorizontalAlignment]::Center}else{[Windows.HorizontalAlignment]::Stretch}}
        # Keep IsEnabled, route and Active tag untouched: this is not a permission update.
    }
    $toggle=Get-DomeniaControl 'BtnUxSidebarToggle'
    if($null -ne $toggle){
        $toggle.ToolTip=if($collapsed){'Déployer le menu : icônes et libellés.'}else{'Réduire le menu : conserver uniquement les icônes.'}
        $toggle.HorizontalAlignment=if($collapsed){[Windows.HorizontalAlignment]::Center}else{[Windows.HorizontalAlignment]::Left}
        [Windows.Automation.AutomationProperties]::SetName($toggle,$toggle.ToolTip)
    }
    $content=Get-DomeniaControl 'UxSidebarToggleContent'
    if($null -ne $content){$content.HorizontalAlignment=if($collapsed){[Windows.HorizontalAlignment]::Center}else{[Windows.HorizontalAlignment]::Left}}
    $glyph=Get-DomeniaControl 'UxSidebarToggleGlyph'
    if($null -ne $glyph){
        $glyph.Margin=[Windows.Thickness]::new(0)
        $path=if($collapsed){'M2,2 L20,2 20,18 2,18 Z M8,2 L8,18 M12,6 L16,10 12,14'}else{'M2,2 L20,2 20,18 2,18 Z M8,2 L8,18 M16,6 L12,10 16,14'}
        $glyph.Data=[Windows.Media.Geometry]::Parse($path)
    }
    $script:UxNavLayoutSignature=[string]$collapsed
}

function Get-DomeniaUxOuDisplay {
    param([AllowEmptyString()][string]$DistinguishedName,[bool]$IsDomain=$false)
    # Parse separators only for display. Never rebuild the LDAP search root from this label.
    $parts=New-Object 'System.Collections.Generic.List[string]'
    $start=0; $escaped=$false; $quoted=$false
    for($i=0;$i -lt $DistinguishedName.Length;$i++){
        $c=$DistinguishedName[$i]
        if($escaped){$escaped=$false;continue}
        if($c -eq [char]92){$escaped=$true;continue}
        if($c -eq [char]34){$quoted=-not $quoted;continue}
        if($c -eq [char]44 -and -not $quoted){$parts.Add($DistinguishedName.Substring($start,$i-$start).Trim());$start=$i+1}
    }
    if($start -lt $DistinguishedName.Length){$parts.Add($DistinguishedName.Substring($start).Trim())}
    $names=New-Object 'System.Collections.Generic.List[string]'
    $domain=New-Object 'System.Collections.Generic.List[string]'
    foreach($part in $parts){
        $equals=$part.IndexOf('=');if($equals -lt 1){continue}
        $kind=$part.Substring(0,$equals).Trim();$value=$part.Substring($equals+1)
        # Escaped UTF-8 octets and escaped separators can occur in an AD distinguished name.
        $value=[regex]::Replace($value,'(?:\\[0-9A-Fa-f]{2})+',{
            param($match)
            $bytes=New-Object 'System.Collections.Generic.List[byte]'
            foreach($hex in [regex]::Matches($match.Value,'[0-9A-Fa-f]{2}')){$bytes.Add([Convert]::ToByte($hex.Value,16))}
            [Text.Encoding]::UTF8.GetString($bytes.ToArray())
        })
        $value=[regex]::Replace($value,'\\([,+=<>#;"\\ ])','$1')
        if($kind -ieq 'DC'){$domain.Add($value)}else{$names.Add($value)}
    }
    $leaf=if($IsDomain -or $names.Count -eq 0){'Tout le domaine'}else{[string]$names[0]}
    $path=New-Object 'System.Collections.Generic.List[string]'
    if($domain.Count -gt 0){$path.Add(($domain -join '.'))}
    for($i=$names.Count-1;$i -ge 0;$i--){$path.Add($names[$i])}
    $full=if($path.Count -gt 0){$path -join ' / '}else{$DistinguishedName}
    $trail=if($path.Count -gt 3){'… / '+($path.GetRange($path.Count-3,3) -join ' / ')}else{$full}
    [pscustomobject]@{Name=$leaf;Breadcrumb=$trail;FullPath=$full;DistinguishedName=$DistinguishedName}
}

function Update-DomeniaUxOuScope {
    param($Scope)
    if($null -eq $Scope){return}
    $display=Get-DomeniaUxOuDisplay -DistinguishedName ([string]$Scope.BaseDn) -IsDomain ([bool]$Scope.IsDomain)
    Update-DomeniaOuBreadcrumb -Dn ([string]$Scope.BaseDn)
    $name=Get-DomeniaControl 'LblOuScopeName';$path=Get-DomeniaControl 'LblOuScopePath';$summary=Get-DomeniaControl 'LblSearchScope'
    if($null -ne $name){$name.Text=$display.Name;$name.ToolTip=$display.FullPath}
    if($null -ne $path){$path.Text=$display.Breadcrumb;$path.ToolTip=$display.FullPath}
    if($null -ne $summary){
        $depth=if($Scope.Scope -eq 'Subtree'){'Sous-OU incluses'}else{'Enfants directs'}
        # D032: browsing always reads 'Dans cette OU', the upper bar always 'Domaine entier'.
        # Point 52: an OU below another one is named with its parent, so that two OU of the same name stay distinct.
        $ouName=[string]$display.Name
        if(-not [bool]$Scope.IsDomain){try{$names=@(Get-DomeniaOuPathNames ([string]$Scope.BaseDn));if($names.Count -ge 2){$ouName+=' (dans '+[string]$names[1]+')'}}catch{Write-DomeniaSwallowed 'UX' 'Update-DomeniaUxOuScope' $_}}
        $label='Dans : '+$ouName+'  ·  '+$depth
        if($null -ne (Get-Command Get-DomeniaScopeLabel -CommandType Function -ErrorAction SilentlyContinue)){
            $label=Get-DomeniaScopeLabel -Mode Browse -OuName $ouName -Subtree ($Scope.Scope -eq 'Subtree')
        }
        $summary.Text=$label
        $summary.ToolTip='Racine LDAP : '+[string]$Scope.BaseDn+"`r`n"+$depth+"`r`nLe texte de la barre du haut ne filtre pas cette OU."
    }
}

function Copy-DomeniaUxOuPath {
    # -Dn: the exact DN of the breadcrumb that was clicked (point 52); without it, the DN of the menu box.
    param([AllowEmptyString()][string]$Dn='')
    $text=([string]$Dn).Trim()
    if(-not $text){$box=Get-DomeniaControl 'TxtBranchDn';if($null -ne $box){$text=([string]$box.Text).Trim()}}
    if([string]::IsNullOrWhiteSpace($text)){return}
    try{
        [Windows.Clipboard]::SetText($text)
        Set-DomeniaContextHint -Title 'Chemin LDAP copié' -Text 'Le DN de la branche sélectionnée est dans le presse-papiers. Le filtre et les résultats restent inchangés.'
    }catch{
        Set-DomeniaContextHint -Title 'Copie indisponible' -Text 'Le presse-papiers est occupé. Dépliez le chemin LDAP pour le sélectionner et le copier manuellement.'
    }
}

function Initialize-DomeniaUxLoginPresentation {
    param($Window)
    if($null -eq $Window){return}
    # A short login by default; long errors/details remain scrollable on small screens.
    $work=[Windows.SystemParameters]::WorkArea
    $Window.MaxHeight=[Math]::Max(280.0,[Math]::Min(800.0,$work.Height-24.0))
    $Window.MaxWidth=[Math]::Max(340.0,$work.Width-24.0)
    if($Window.Width -gt $Window.MaxWidth){$Window.Width=$Window.MaxWidth}
    if (-not $Window.Resources.Contains('DomeniaLoginWaitWired')) {
        $waitCancel = $Window.FindName('BtnLoginWaitCancel')
        if ($null -ne $waitCancel) {
            $waitCancel.Add_Click({
                param($sender,$eventArgs)
                $owner = (Get-DomeniaOwningDialog $sender)
                $cancel = $owner.FindName('BtnCancel')
                if ($null -ne $cancel) { $cancel.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
            })
            $Window.Add_PreviewKeyDown({
                param($sender,$eventArgs)
                $wait = $sender.FindName('PanelSplash')
                if ($eventArgs.Key -eq [Windows.Input.Key]::Escape -and $null -ne $wait -and $wait.IsVisible) {
                    $eventArgs.Handled = $true
                    $cancel = $sender.FindName('BtnCancel')
                    if ($null -ne $cancel) { $cancel.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
                }
            })
        }
        $Window.Resources['DomeniaLoginWaitWired'] = $true
    }
    Initialize-DomeniaExperienceLogin -Window $Window
}

# ---------------------------------------------------------------- L08 header, menu foot, search bar and read-only switch
function Test-DomeniaUxExpertAllowed {
    # SP-13: UI.AllowExpertProfile, true by default. False hides Expert at the menu foot and keeps Ctrl+L on the journal.
    try { return [bool](Get-CfgValue 'UI' 'AllowExpertProfile' $true) } catch { return $true }
}

function Send-DomeniaUxLiveChange {
    # UI-13: tells a screen reader that a polite live region changed (page title, last journal line, write state).
    # Best effort and only when an automation client listens: the text itself is always updated by the caller.
    param($Control)
    if ($null -eq $Control) { return }
    try {
        $liveEvent = [Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged
        if (-not [Windows.Automation.Peers.AutomationPeer]::ListenerExists($liveEvent)) { return }
        $peer = [Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($Control)
        if ($null -ne $peer) { $peer.RaiseAutomationEvent($liveEvent) }
    } catch { Write-DomeniaSwallowed 'UX' 'Send-DomeniaUxLiveChange' $_ }
}

function Set-DomeniaLiveText {
    # W13 (point 116): text of a polite live region (state of the result list, palette, operations panel). WPF raises
    # no LiveRegionChanged by itself: the text is rewritten only when it changes, then the change is announced once.
    # Returns $true when the text changed.
    param($Control,[AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Control) { return $false }
    if ([string]$Control.Text -ceq [string]$Text) { return $false }
    $Control.Text = [string]$Text
    Send-DomeniaUxLiveChange -Control $Control
    return $true
}

function Get-DomeniaUxSubject {
    # The current subject: the loaded object, otherwise the object being read; never a former object.
    $name = ''; $type = ''
    if ($null -ne $script:SelectedObject) {
        try { $name = [string]$script:SelectedObject.Name; $type = [string]$script:SelectedObject.Type } catch { Write-DomeniaSwallowed 'UX' 'Get-DomeniaUxSubject' $_ }
    }
    elseif ($null -ne $script:SelectionLoad) {
        try { $name = [string]$script:SelectionLoad.Context.Name; $type = [string]$script:SelectionLoad.Context.Type } catch { Write-DomeniaSwallowed 'UX' 'Get-DomeniaUxSubject' $_ }
    }
    return [pscustomobject]@{Name=$name;Type=$type}
}

function Update-DomeniaUxPageTitle {
    # UI-01 / UI-29: the page header shows the menu label, followed by the subject on Fiche, Poste and Utilisateurs et
    # postes (« Fiche · Camille Martin »); the window title reads « Fiche · Camille Martin — Domenia » (Alt+Tab) and a
    # « Poste · nom » chip with ✕ sits beside the session badge.
    if ($null -eq $script:Ctrl) { return }
    $page = ''
    try { $page = [string](Get-DomeniaControl 'WorkspaceTabs').SelectedItem.Name } catch { $page = '' }
    if ([string]::IsNullOrWhiteSpace($page)) { $page = 'TabDashboard' }
    $subject = Get-DomeniaUxSubject
    $application = [string]$script:BaseWindowTitle
    if ([string]::IsNullOrWhiteSpace($application)) { $application = 'Domenia' }
    $title = Get-DomeniaPageTitle -Page $page -TargetName $subject.Name -TargetType $subject.Type -WriteEnabled (-not [bool]$script:ReadOnlyMode) -ApplicationName $application
    $label = Get-DomeniaControl 'LblUxPageTitle'
    if ($null -ne $label) {
        $text = [string]$title.PageLabel
        if (($page -in @('WsObject','WsComputer','TabRelations')) -and [bool]$title.HasTarget) { $text = [string]$title.Header }
        if ([string]$label.Text -cne $text) { $label.Text = $text; Send-DomeniaUxLiveChange -Control $label }
    }
    if ($null -ne $script:Window) {
        try { if ([string]$script:Window.Title -cne [string]$title.WindowTitle) { $script:Window.Title = [string]$title.WindowTitle } } catch { Write-DomeniaSwallowed 'UX' 'Update-DomeniaUxPageTitle' $_ }
    }
    $chipValue = ''
    if (-not [string]::IsNullOrWhiteSpace($subject.Name)) { $chipValue = [string](Get-DomeniaPageTitle -Page 'WsObject' -TargetName $subject.Name -TargetType $subject.Type).Chip }
    $chipText = Get-DomeniaControl 'LblUxSubject'
    if ($null -ne $chipText) { $chipText.Text = $chipValue }
    $chip = Get-DomeniaControl 'UxSubjectChip'
    if ($null -ne $chip) { $chip.Visibility = if ($chipValue) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
    Add-DomeniaUxRecentObject
}

function Update-DomeniaUxSessionBadge {
    # UI-29 / SP-04: network outage and query deadline are distinct session warnings.
    # Back by itself at the next directory success; nothing is retried here.
    $label = Get-DomeniaControl 'LblUxDomain'
    if ($null -eq $label) { return }
    $offline = $false
    $slow = $false
    $outage = $null
    try {
        $reach = $script:DirectoryReachability
        if (($null -ne $reach) -and ([long]$reach.Epoch -eq [long]$script:SessionEpoch)) { $offline = [bool]$reach.Offline; $slow = [bool](Get-DomeniaMember $reach 'Slow' $false); $outage = $reach.LastOutageUtc }
    } catch { $offline = $false }
    if ($offline) {
        # « depuis » is the first failure of the outage, not the latest one.
        if ($null -eq $script:UxAdOfflineSince) {
            $since = Get-Date
            try { if ($null -ne $outage) { $since = ([datetime]$outage).ToLocalTime() } } catch { $since = Get-Date }
            $script:UxAdOfflineSince = $since
        }
    } else { $script:UxAdOfflineSince = $null }
    $domain = ''
    try { $domain = [string]$script:Conn.Domain } catch { $domain = '' }
    if ([string]::IsNullOrWhiteSpace($domain)) { try { $domain = [string](Get-DomeniaControl 'TxtDashDomain').Text } catch { $domain = '' } }
    $demo = [bool]$script:DemoMode
    $demoText = ''
    if ($demo -and ($null -ne (Get-Command -Name Get-DomeniaDemoBannerText -CommandType Function -ErrorAction SilentlyContinue))) { $demoText = [string](Get-DomeniaDemoBannerText) }
    $badge = Get-DomeniaSessionBadge -Domain $domain -Server ([string]$script:Conn.Server) -Offline $offline -OfflineSince $script:UxAdOfflineSince -Demo $demo -DemoText $demoText -Slow $slow
    # A badge without a domain yet keeps its startup text (« Session AD en préparation ») or an offline preview text.
    if (([string]$badge.State -eq 'Pending') -and (-not [string]::IsNullOrWhiteSpace([string]$label.Text))) { return }
    if ([string]$label.Text -cne [string]$badge.Text) { $label.Text = [string]$badge.Text; Send-DomeniaUxLiveChange -Control $label }
    $label.ToolTip = [string]$badge.ToolTip
    if ([string]$badge.State -ne 'Demo') {
        $label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,$(if ($offline) { 'StatusError' } elseif ($slow) { 'StatusWarning' } else { 'InfoFg' }))
    }
}

function Update-DomeniaUxAccountFooter {
    # DS-12: the account and the domain in use at the foot of the menu (they were only in the help panel).
    $account = Get-DomeniaControl 'LblUxNavAccount'
    $domainLabel = Get-DomeniaControl 'LblUxNavDomain'
    if (($null -eq $account) -and ($null -eq $domainLabel)) { return }
    $user = ''; $domain = ''
    try { $user = [string]$script:Conn.BindUser } catch { $user = '' }
    if ([string]::IsNullOrWhiteSpace($user)) { try { $user = [string]$script:Conn.User } catch { $user = '' } }
    try { $domain = [string]$script:Conn.Domain } catch { $domain = '' }
    if ($null -ne $account) { $account.Text = if ([string]::IsNullOrWhiteSpace($user)) { 'Aucun compte connecté' } else { ConvertTo-DomeniaFlatText $user 60 } }
    if ($null -ne $domainLabel) { $domainLabel.Text = if ([string]::IsNullOrWhiteSpace($domain)) { 'Domaine non connecté' } else { ConvertTo-DomeniaFlatText $domain 60 } }
}

function Show-DomeniaUxAccountMenu {
    # DS-12: menu of the account at the foot of the menu: change of account (page Comptes) and « À propos » (version).
    param($Button)
    if ($null -eq $Button) { return }
    $menu = New-Object Windows.Controls.ContextMenu
    $change = New-Object Windows.Controls.MenuItem
    $change.Header = 'Changer de compte'
    $change.ToolTip = 'Ouvre la page Comptes : compte AD, compte pour les postes et compte pour les secrets.'
    $change.Add_Click({ Invoke-DomeniaUxRoute -Route 'TabAccounts' })
    $about = New-Object Windows.Controls.MenuItem
    $about.Header = 'À propos de Domenia'
    $about.ToolTip = 'Affiche la version de Domenia au pied du menu.'
    $about.Add_Click({ Switch-DomeniaUxAbout })
    [void]$menu.Items.Add($change)
    [void]$menu.Items.Add($about)
    $menu.PlacementTarget = $Button
    $menu.Placement = [Windows.Controls.Primitives.PlacementMode]::Top
    $Button.ContextMenu = $menu
    $menu.IsOpen = $true
}

function Switch-DomeniaUxAbout {
    # « À propos » shows the version line that left the menu foot (DS-12), and says it in the help panel.
    $panel = Get-DomeniaControl 'UxAboutPanel'
    if ($null -eq $panel) { return }
    $show = ($panel.Visibility -ne [Windows.Visibility]::Visible)
    $panel.Visibility = if ($show) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    if ($show) {
        # Point 145: local facts only (registry, winsqlite3.dll version), read once per session.
        try { Update-DomeniaAboutCompatibility } catch { Write-AppLog ('Compatibilité du poste non évaluée : ' + $_.Exception.Message) 'WARN' }
        Set-DomeniaContextHint -Title 'À propos de Domenia' -Text ([string]$script:DomeniaBuild + '. Les actions restent sous votre contrôle ; aucune écriture ne part sans votre geste.')
    }
}

function Clear-DomeniaUxSubject {
    # UI-01: ✕ of the subject chip. Same path as an empty selection in the result list (the unsaved-input guard
    # applies); nothing is read or written.
    try {
        $grid = Get-DomeniaControl 'DgObjects'
        if (($null -ne $grid) -and (@($grid.SelectedItems).Count -gt 0)) { $grid.UnselectAll() }
        elseif ($null -ne (Get-Command -Name Queue-DomeniaSelectedObjectOpen -CommandType Function -ErrorAction SilentlyContinue)) { Queue-DomeniaSelectedObjectOpen -Immediate }
        elseif ($null -ne (Get-Command -Name Clear-DomeniaSelectionEverywhere -CommandType Function -ErrorAction SilentlyContinue)) { Clear-DomeniaSelectionEverywhere }
    } catch { Write-AppLog ('Désélection depuis lʼen-tête : ' + $_.Exception.Message) 'WARN' }
    Sync-DomeniaUxNavigation
}

function Update-DomeniaUxProfileSwitch {
    # UI-30 / SP-13: the Essentiel | Expert choice of the menu foot follows the profile; Expert is hidden (and never
    # applied) when the administrator sets UI.AllowExpertProfile to false.
    $allowed = Test-DomeniaUxExpertAllowed
    $expert = Get-DomeniaControl 'LstUiProfileExpert'
    if ($null -ne $expert) { $expert.Visibility = if ($allowed) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
    if ((-not $allowed) -and ([string]$script:CurrentUiProfile -eq 'Admin')) {
        if ($null -ne (Get-Command -Name Apply-DomeniaUiProfile -CommandType Function -ErrorAction SilentlyContinue)) { Apply-DomeniaUiProfile -Profile 'Tech' } else { $script:CurrentUiProfile = 'Tech' }
    }
    $segment = Get-DomeniaControl 'LstUiProfile'
    if ($null -ne $segment) {
        foreach ($item in @($segment.Items)) {
            if ([string]$item.Tag -eq [string]$script:CurrentUiProfile) { if (-not [object]::ReferenceEquals($segment.SelectedItem,$item)) { $segment.SelectedItem = $item }; break }
        }
    }
}

function Invoke-DomeniaJournalShortcut {
    # CO-06 / SP-13: Ctrl+L never changes the interface profile. In Expert it opens Outils > Journal; in Essentiel, or
    # when Expert is hidden by the administrator, it unfolds the session journal at the bottom of the window.
    if (([string]$script:CurrentUiProfile -eq 'Admin') -and (Test-DomeniaUxExpertAllowed)) {
        Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'TabLog'
        return
    }
    if ($null -ne (Get-Command -Name Open-DomeniaExperienceJournal -CommandType Function -ErrorAction SilentlyContinue)) { Open-DomeniaExperienceJournal }
    $list = Get-DomeniaControl 'LstUiLogReadable'
    if (($null -ne $list) -and $list.IsVisible) { [void]$list.Focus() }
}

function Initialize-DomeniaUxThemeMenu {
    # FO-22: right click (or the menu key) on the theme button offers Clair, Sombre and Automatique (follow Windows).
    # A choice is saved like the click on the button; nothing else changes.
    $button = Get-DomeniaControl 'BtnThemeToggle'
    if (($null -eq $button) -or ($null -ne $button.ContextMenu)) { return }
    $menu = New-Object Windows.Controls.ContextMenu
    foreach ($choice in @(Get-DomeniaThemeChoices)) {
        $item = New-Object Windows.Controls.MenuItem
        $item.Header = [string]$choice.Label
        $item.Tag = [string]$choice.Value
        $item.IsCheckable = $true
        $item.Add_Click({ param($sender,$eventArgs) Set-DomeniaThemePreference -Preference ([string]$sender.Tag) })
        [void]$menu.Items.Add($item)
    }
    $menu.Add_Opened({ param($sender,$eventArgs) foreach ($entry in @($sender.Items)) { $entry.IsChecked = ([string]$entry.Tag -eq [string]$script:ThemePreference) } })
    $menu.PlacementTarget = $button
    $menu.Placement = [Windows.Controls.Primitives.PlacementMode]::Bottom
    $button.ContextMenu = $menu
}

function Update-DomeniaAutoTheme {
    # FO-22: on the return to Domenia (window activated) and when Windows switches high contrast, the Automatique
    # choice follows the Windows choice again and the palette follows high contrast. One registry value is read, no
    # preference is written. The UI thread only: Activated and SystemParameters.StaticPropertyChanged are raised there.
    if ($null -eq $script:Window) { return }
    $theme = [string]$script:CurrentTheme
    if ([string]$script:ThemePreference -eq 'Auto') { $theme = [string](Resolve-DomeniaEffectiveTheme -Preference 'Auto' -WindowsTheme (Get-DomeniaWindowsAppTheme)).Theme }
    $highContrast = $false
    try { $highContrast = [bool][Windows.SystemParameters]::HighContrast } catch { $highContrast = $false }
    # A change of high contrast theme (Noir to Blanc) keeps HighContrast true: its system colours tell it apart.
    $systemColors = ''
    if ($highContrast) { try { $systemColors = Get-DomeniaSystemColorSignature } catch { $systemColors = '' } }
    if (($theme -eq [string]$script:CurrentTheme) -and ($highContrast -eq [bool]$script:DomeniaPaintedHighContrast) -and ($systemColors -ceq [string]$script:DomeniaPaintedSystemColors)) { return }
    $script:BootTheme = $theme
    Apply-DomeniaTheme -Theme $theme
}

function Update-DomeniaUxThemeToggle {
    # DS-10: name and tool tip of the theme button give the theme it switches to (the help catalogue sets a neutral
    # title at start-up; this restores the precise name).
    $button = Get-DomeniaControl 'BtnThemeToggle'
    if ($null -eq $button) { return }
    $icon = Get-DomeniaThemeToggleIcon -CurrentTheme ([string]$script:CurrentTheme) -Preference ([string]$script:ThemePreference)
    $button.ToolTip = [string]$icon.ToolTip
    [Windows.Automation.AutomationProperties]::SetName($button,[string]$icon.Name)
    $sun = Get-DomeniaControl 'ThemeIconSun';$moon = Get-DomeniaControl 'ThemeIconMoon'
    if ($null -ne $sun) { $sun.Visibility = if ($icon.Glyph -eq 'Sun') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
    if ($null -ne $moon) { $moon.Visibility = if ($icon.Glyph -eq 'Moon') { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
}

function Set-DomeniaUxHeaderLayout {
    # SP-03: on a narrow main area the read-only switch leaves the page header for the top bar, before the icon
    # buttons: the page title gains the room of the switch, no row is added (the short screens of D006 keep their
    # results) and the activity strip keeps its fixed slots (D082). A resize only; the switch itself is unchanged.
    param([bool]$Stacked=$false)
    $switchHost = Get-DomeniaControl 'UxReadOnlyHost'
    $bar = Get-DomeniaControl 'UxPageHeaderBar'
    $tools = Get-DomeniaControl 'UxHeaderTools'
    if (($null -eq $switchHost) -or ($null -eq $bar) -or ($null -eq $tools)) { return }
    $parent = $switchHost.Parent
    if ($Stacked) {
        if (-not [object]::ReferenceEquals($parent,$tools)) {
            if ($null -ne $parent) { $parent.Children.Remove($switchHost) }
            [void]$tools.Children.Insert(0,$switchHost)
        }
        $switchHost.Margin = [Windows.Thickness]::new(0,0,6,0)
    } else {
        if (-not [object]::ReferenceEquals($parent,$bar)) {
            if ($null -ne $parent) { $parent.Children.Remove($switchHost) }
            [void]$bar.Children.Add($switchHost)
        }
        [Windows.Controls.Grid]::SetColumn($switchHost,2)
        $switchHost.Margin = [Windows.Thickness]::new(12,0,0,0)
    }
}

# ---------------------------------------------------------------- L08 recent searches and fiches (local memory)
function Get-DomeniaUxRecentEntries {
    if ($null -eq $script:UxRecentEntries) {
        $json = '[]'
        try { $json = [string](Get-DomeniaSetting -Name 'UxRecentJson' -Default '[]') } catch { $json = '[]' }
        $script:UxRecentEntries = @(ConvertFrom-DomeniaRecentJson -Json $json)
    }
    return $script:UxRecentEntries
}

function Add-DomeniaUxRecentEntry {
    # FO-03: the 8 latest searches and fiches are kept in the local preferences of this workstation only.
    param([ValidateSet('Recherche','Fiche')][string]$Kind='Recherche',[AllowEmptyString()][string]$Text='',[AllowEmptyString()][string]$Type='',[AllowEmptyString()][string]$Dn='')
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $script:UxRecentEntries = @(Add-DomeniaRecentEntry -Entries @(Get-DomeniaUxRecentEntries) -Kind $Kind -Text $Text -Type $Type -Dn $Dn -Maximum 8)
    try { Set-DomeniaSetting -Name 'UxRecentJson' -Value (ConvertTo-Json -InputObject @($script:UxRecentEntries) -Depth 3 -Compress) }
    catch { Write-AppLog ('Mémoire des recherches récentes non enregistrée : ' + $_.Exception.Message) 'WARN' }
}

function Add-DomeniaUxRecentObject {
    # A fiche enters the recent list once really loaded (never a row merely clicked), once per object.
    $object = $script:SelectedObject
    if ($null -eq $object) { return }
    $dn = ''
    try { $dn = [string]$object.DN } catch { $dn = '' }
    if ([string]::IsNullOrWhiteSpace($dn) -or ($dn -ieq [string]$script:UxRecentLastDn)) { return }
    $script:UxRecentLastDn = $dn
    Add-DomeniaUxRecentEntry -Kind Fiche -Text ([string]$object.Name) -Type ([string]$object.Type) -Dn $dn
}

# ---------------------------------------------------------------- L08 search bar: clear, recent entries, local suggestions
function Initialize-DomeniaUxSearchBar {
    # FO-03 / SP-01: magnifier, ✕, the latest searches and fiches on a click, suggestions of the local base while typing.
    # Typing never queries AD: Entrée (or Rechercher) remains the only gesture of the bar that reads the directory.
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    if ($box -isnot [Windows.Controls.TextBox]) { return }
    # The latest entries open on a gesture only (click in the field, typing, Down arrow), never when Domenia itself puts
    # the focus in the bar (opening Rechercher, Ctrl+K, a route).
    $box.Add_PreviewMouseLeftButtonUp({ param($sender,$eventArgs) Update-DomeniaUxSearchSuggestions })
    $box.Add_LostKeyboardFocus({ param($sender,$eventArgs) Hide-DomeniaUxSearchSuggestions })
    $box.Add_TextChanged({
        param($sender,$eventArgs)
        Update-DomeniaUxSearchClear
        if ($sender.IsKeyboardFocusWithin) { Update-DomeniaUxSearchSuggestions -Typing }
    })
    $box.Add_PreviewKeyDown({ param($sender,$eventArgs) Invoke-DomeniaUxSearchKey -Box $sender -KeyEvent $eventArgs })
    $clear = Get-DomeniaControl 'BtnGlobalSearchClear'
    if ($null -ne $clear) { $clear.Add_Click({ $field = Get-DomeniaControl 'TxtGlobalSearch'; if ($null -ne $field) { $field.Clear(); [void]$field.Focus() } }) }
    $search = Get-DomeniaControl 'BtnGlobalSearch'
    if ($null -ne $search) { $search.Add_Click({ Register-DomeniaUxSearchGesture }) }
    $list = Get-DomeniaControl 'LstSearchSuggest'
    if ($null -ne $list) { $list.Add_PreviewMouseLeftButtonDown({ param($sender,$eventArgs) Select-DomeniaUxSuggestion -List $sender -MouseEvent $eventArgs }) }
    Update-DomeniaUxSearchClear
}

function Update-DomeniaUxSearchClear {
    $box = Get-DomeniaControl 'TxtGlobalSearch';$clear = Get-DomeniaControl 'BtnGlobalSearchClear'
    if (($null -eq $box) -or ($null -eq $clear)) { return }
    $clear.Visibility = if ([string]::IsNullOrEmpty([string]$box.Text)) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
}

function Update-DomeniaUxSearchSuggestions {
    # Recent entries matching the text at once; local-base rows after a 300 ms pause in the typing (worker, no network).
    param([switch]$Typing)
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    if (($null -eq $box) -or (-not $box.IsEnabled)) { Hide-DomeniaUxSearchSuggestions; return }
    $text = ([string]$box.Text).Trim()
    $script:UxSuggestWanted = $true
    $script:UxSuggestGeneration = [long]$script:UxSuggestGeneration + 1
    if ($null -ne $script:UxSuggestTimer) { $script:UxSuggestTimer.Stop() }
    $script:UxSuggestRecent = @(Select-DomeniaRecentEntries -Entries @(Get-DomeniaUxRecentEntries) -Kind @('Recherche','Fiche') -Text $text -Maximum 8)
    $script:UxSuggestLocal = @()
    Set-DomeniaUxSuggestionItems -Text $text
    if ($Typing -and ($text.Length -ge 2)) { Request-DomeniaUxLocalSuggestions -Text $text }
}

function Set-DomeniaUxSuggestionItems {
    param([AllowEmptyString()][string]$Text='')
    $panel = Get-DomeniaControl 'UxSearchSuggest';$list = Get-DomeniaControl 'LstSearchSuggest'
    if (($null -eq $panel) -or ($null -eq $list)) { return }
    $items = @(Get-DomeniaSearchSuggestionItems -Recent @($script:UxSuggestRecent) -LocalRows @($script:UxSuggestLocal) -Maximum 8)
    $list.ItemsSource = $items
    $list.SelectedIndex = -1
    $title = Get-DomeniaControl 'LblSearchSuggestTitle'
    if ($null -ne $title) { $title.Text = if ([string]::IsNullOrWhiteSpace($Text)) { 'Recherches et fiches récentes' } else { 'Suggestions, sans requête AD' } }
    $show = ([bool]$script:UxSuggestWanted -and ($items.Count -gt 0))
    $panel.Visibility = if ($show) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
}

function Hide-DomeniaUxSearchSuggestions {
    $script:UxSuggestWanted = $false
    $script:UxSuggestGeneration = [long]$script:UxSuggestGeneration + 1
    if ($null -ne $script:UxSuggestTimer) { $script:UxSuggestTimer.Stop() }
    $panel = Get-DomeniaControl 'UxSearchSuggest'
    if ($null -ne $panel) { $panel.Visibility = [Windows.Visibility]::Collapsed }
}

function Request-DomeniaUxLocalSuggestions {
    param([Parameter(Mandatory=$true)][string]$Text)
    $script:UxSuggestTerm = $Text
    if ($null -eq $script:UxSuggestTimer) {
        # FI-05: protected timer of the engine factory; one shot restarted on each keystroke (300 ms debounce).
        $script:UxSuggestTimer = New-DomeniaTimer -Owner 'Timer:SearchSuggest' -IntervalMs 300 -Priority Normal -Standalone -Tick {
            try { $script:UxSuggestTimer.Stop() } catch { Write-DomeniaSwallowed 'UX' 'Request-DomeniaUxLocalSuggestions' $_ }
            Start-DomeniaUxLocalSuggestions -Text ([string]$script:UxSuggestTerm)
        }
    }
    $script:UxSuggestTimer.Stop()
    $script:UxSuggestTimer.Start()
}

function Start-DomeniaUxLocalSuggestions {
    # The local base is read by the LocalIndexRead worker (read-only SQLite, short busy timeout): no AD request, no
    # probe, nothing on the Dispatcher. A newer text or a closed list supersedes the answer.
    param([Parameter(Mandatory=$true)][string]$Text)
    if (-not [bool]$script:UxSuggestWanted) { return }
    if ($null -eq (Get-Command -Name Start-UiTask -CommandType Function -ErrorAction SilentlyContinue)) { return }
    $path = ''
    try { $path = [string](Get-DomeniaLocalDatabasePathForRead) } catch { $path = '' }
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $state = [pscustomobject]@{Term=$Text;Generation=[long]$script:UxSuggestGeneration;Epoch=[long]$script:SessionEpoch}
    $payload = [pscustomobject]@{Action='Search';Path=$path;Term=$Text;Limit=8;BusyTimeoutMs=50}
    [void](Start-UiTask -Name 'Suggestions de la base locale' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'bar-suggest' -TimeoutSeconds 10 -SuccessHandler 'Complete-DomeniaUxLocalSuggestionsUi' -ErrorHandler 'Fail-DomeniaUxLocalSuggestionsUi' -TaskClass 'Explicit')
}

function Complete-DomeniaUxLocalSuggestionsUi {
    param($Result,$State)
    if (($null -eq $State) -or ([long]$State.Generation -ne [long]$script:UxSuggestGeneration) -or ([long]$State.Epoch -ne [long]$script:SessionEpoch)) { return }
    $effective = Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows','Busy')
    if (($null -eq $effective) -or [bool]$effective.Busy) { return }
    # A list closed meanwhile (focus left the field, Entrée, Échap) changed the generation above: nothing reopens it.
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    if (($null -eq $box) -or (([string]$box.Text).Trim() -cne [string]$State.Term) -or (-not [bool]$script:UxSuggestWanted)) { return }
    $script:UxSuggestLocal = @($effective.Rows)
    Set-DomeniaUxSuggestionItems -Text ([string]$State.Term)
}

function Fail-DomeniaUxLocalSuggestionsUi {
    # Suggestions are optional: a locked or missing local base leaves the recent entries and the search unaffected.
    param($Message,$State)
}

function Register-DomeniaUxSearchGesture {
    # Entrée or Rechercher: the text joins the recent searches and the list closes; the search itself is started by
    # the existing handlers of the bar (Wire-Events), the only AD read of the bar.
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    Hide-DomeniaUxSearchSuggestions
    if ($null -eq $box) { return }
    $text = ([string]$box.Text).Trim()
    if ($text.Length -ge 2) { Add-DomeniaUxRecentEntry -Kind Recherche -Text $text }
}

function Invoke-DomeniaUxSearchKey {
    # Arrows choose a suggestion, Échap closes the list (a second Échap keeps its former meaning), Entrée copies the
    # chosen suggestion into the field and lets the bar search it.
    param($Box,$KeyEvent)
    if (($null -eq $Box) -or ($null -eq $KeyEvent)) { return }
    $panel = Get-DomeniaControl 'UxSearchSuggest';$list = Get-DomeniaControl 'LstSearchSuggest'
    $open = (($null -ne $panel) -and ($panel.Visibility -eq [Windows.Visibility]::Visible) -and ($null -ne $list) -and ($list.Items.Count -gt 0))
    $key = $KeyEvent.Key
    if ($key -eq [Windows.Input.Key]::Down) {
        if ($open) { $list.SelectedIndex = [Math]::Min($list.Items.Count - 1,$list.SelectedIndex + 1); $list.ScrollIntoView($list.SelectedItem); $KeyEvent.Handled = $true }
        else { Update-DomeniaUxSearchSuggestions }
    }
    elseif ($key -eq [Windows.Input.Key]::Up) {
        if ($open) { $list.SelectedIndex = [Math]::Max(-1,$list.SelectedIndex - 1); $KeyEvent.Handled = $true }
    }
    elseif ($key -eq [Windows.Input.Key]::Escape) {
        if ($open) { Hide-DomeniaUxSearchSuggestions; $KeyEvent.Handled = $true }
    }
    elseif ($key -eq [Windows.Input.Key]::Enter) {
        if ($open -and ($null -ne $list.SelectedItem)) { $Box.Text = [string]$list.SelectedItem.Text; $Box.CaretIndex = $Box.Text.Length }
        # Not handled: the KeyDown of the bar (Wire-Events) starts the global search with this text.
        Register-DomeniaUxSearchGesture
    }
}

function Select-DomeniaUxSuggestion {
    # A click copies the suggestion into the field and keeps the focus there: nothing is read until Entrée.
    param($List,$MouseEvent)
    if (($null -eq $List) -or ($null -eq $MouseEvent)) { return }
    $container = [Windows.Controls.ItemsControl]::ContainerFromElement($List,$MouseEvent.OriginalSource)
    if ($container -isnot [Windows.Controls.ListBoxItem]) { return }
    $MouseEvent.Handled = $true
    $item = $container.DataContext
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    if (($null -eq $item) -or ($null -eq $box)) { return }
    $box.Text = [string]$item.Text
    $box.CaretIndex = $box.Text.Length
    [void]$box.Focus()
    Hide-DomeniaUxSearchSuggestions
    Set-DomeniaContextHint -Title 'Suggestion recopiée' -Text 'Le texte est dans la barre de recherche. Entrée lance la recherche dans tout le domaine ; rien nʼa été lu.'
}

# ---------------------------------------------------------------- L08 empty Fiche and Poste pages (UX-09)
function Initialize-DomeniaUxEmptyStates {
    foreach ($kind in @('Object','Computer')) {
        $box = Get-DomeniaControl ('Txt' + $kind + 'EmptySearch')
        if ($box -is [Windows.Controls.TextBox]) {
            $box.Add_KeyDown({ param($sender,$eventArgs) if ($eventArgs.Key -eq [Windows.Input.Key]::Enter) { $eventArgs.Handled = $true; Invoke-DomeniaUxEmptySearch -Text ([string]$sender.Text) } })
        }
        $list = Get-DomeniaControl ('Lst' + $kind + 'EmptyRecent')
        if ($list -is [Windows.Controls.ListBox]) {
            $list.Tag = 'Txt' + $kind + 'EmptySearch'
            $list.Add_SelectionChanged({
                param($sender,$eventArgs)
                $item = $sender.SelectedItem
                if ($null -eq $item) { return }
                $field = Get-DomeniaControl ([string]$sender.Tag)
                if ($null -ne $field) { $field.Text = [string]$item.Text; $field.CaretIndex = $field.Text.Length }
            })
            $list.Add_KeyDown({ param($sender,$eventArgs) if (($eventArgs.Key -eq [Windows.Input.Key]::Enter) -and ($null -ne $sender.SelectedItem)) { $eventArgs.Handled = $true; Invoke-DomeniaUxEmptySearch -Text ([string]$sender.SelectedItem.Text) } })
        }
    }
}

function Update-DomeniaUxEmptyStates {
    # UX-09: Fiche and Poste stay open without a subject and show an empty page (search field and recent fiches from
    # the local memory) instead of a greyed menu entry. Nothing is read here.
    $loadType = ''; $objectType = ''
    try { if ($null -ne $script:SelectionLoad) { $loadType = [string]$script:SelectionLoad.Context.Type } } catch { $loadType = '' }
    try { if ($null -ne $script:SelectedObject) { $objectType = [string]$script:SelectedObject.Type } } catch { $objectType = '' }
    $hasSubject = ((-not [string]::IsNullOrWhiteSpace($loadType)) -or (-not [string]::IsNullOrWhiteSpace($objectType)))
    $hasMachine = (($loadType -eq 'Machine') -or ($objectType -eq 'Machine'))
    foreach ($page in @(@('Object',(-not $hasSubject),''),@('Computer',(-not $hasMachine),'Machine'))) {
        $state = Get-DomeniaControl ([string]$page[0] + 'EmptyState')
        if ($null -eq $state) { continue }
        $show = [bool]$page[1]
        $state.Visibility = if ($show) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        if (-not $show) { continue }
        $rows = @(Select-DomeniaRecentEntries -Entries @(Get-DomeniaUxRecentEntries) -Kind @('Fiche') -Type ([string]$page[2]) -Maximum 8 | ForEach-Object {
            $label = [string]$_.Text
            if (-not [string]::IsNullOrWhiteSpace([string]$_.Type)) { $label += '  ·  ' + [string]$_.Type }
            [pscustomobject]@{Label=$label;Text=[string]$_.Text;Type=[string]$_.Type}
        })
        $list = Get-DomeniaControl ('Lst' + [string]$page[0] + 'EmptyRecent')
        if ($null -ne $list) { $list.ItemsSource = $rows; $list.Visibility = if ($rows.Count -gt 0) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
        $none = Get-DomeniaControl ('Lbl' + [string]$page[0] + 'EmptyRecentNone')
        if ($null -ne $none) { $none.Visibility = if ($rows.Count -gt 0) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible } }
    }
}

function Invoke-DomeniaUxEmptySearch {
    # Entrée in the field of an empty Fiche or Poste page: the global search of the top bar, on this explicit gesture.
    param([AllowEmptyString()][string]$Text='')
    $clean = ([string]$Text).Trim()
    if (-not $clean) { return }
    $top = Get-DomeniaControl 'TxtGlobalSearch'
    if ($null -ne $top) { $top.Text = $clean }
    Add-DomeniaUxRecentEntry -Kind Recherche -Text $clean
    Select-DomeniaWorkspace -Workspace 'WsSearch'
    try { Invoke-GlobalSearch -SearchMode Global }
    catch {
        Write-AppLog ('Recherche depuis une page vide : ' + $_.Exception.Message) 'ERROR'
        Set-Status ('La recherche nʼa pas pu être lancée : ' + $_.Exception.Message) 'ERROR'
    }
}

# ---------------------------------------------------------------- W13 (point 119): empty result list
$script:DomeniaSearchEmptyTimer=$null
$script:DomeniaSearchEmptyBound=$false

function Get-DomeniaSearchEmptyInputs {
    # What the list really observed: rows displayed and loaded, the search in progress or finished, its error kind,
    # its text and its scope. Read from the page and the search state only; nothing is queried.
    $grid = Get-DomeniaControl 'DgObjects'
    $displayed = 0; $loaded = 0; $pending = $false
    if ($null -ne $grid) {
        $displayed = [int]$grid.Items.Count
        $source = $grid.ItemsSource
        if ($source -is [Collections.ICollection]) { $loaded = [int]$source.Count }
        # UX-03: a repainted copy holds only its visible rows; the filter pass recorded how many rows the whole list has
        # (Update-DomeniaFilteredEmptyState). The counts speak only for the list they were recorded with.
        $counts = $script:DomeniaListFilterCounts
        if ($null -ne $counts) {
            if (($null -ne $source) -and [object]::ReferenceEquals($counts.Source,$source)) {
                $counts.Pending = $false
                if ([int]$counts.Loaded -gt $loaded) { $loaded = [int]$counts.Loaded }
            } elseif (($null -eq $source) -and [bool]$counts.Pending) {
                # The grid is between two lists (the copy is assigned right after): no verdict on an empty instant.
                $pending = $true
            }
        }
    }
    $search = $null
    try { if ($null -ne $script:Live) { $search = $script:Live.Search } } catch { $search = $null }
    $inFlight = $false; $completed = $false; $partial = $false; $errorKind = ''; $query = ''; $scope = ''; $completeness = 'Unknown'; $limit = 0; $type = 'Tous'
    # The state of the search speaks only for its own rows; another list (query, history, cleared list) is foreign.
    $live = (($null -ne $search) -and ($null -ne $grid) -and [object]::ReferenceEquals($grid.ItemsSource,$search.Rows))
    $foreign = ((-not $live) -and ($null -ne $grid) -and ($null -ne $grid.ItemsSource))
    if ($live) {
        $inFlight = ((-not [bool]$search.Stopped) -and (-not [bool]$search.Finalized))
        $completed = [bool]$search.Finalized
        $partial = [bool](Get-DomeniaMember (Get-DomeniaMemberValue $search 'Final' $null) 'Partial' $false)
        $failure = [string](Get-DomeniaMember $search 'Error' '')
        if ($failure -and (-not $partial)) {
            try { $errorKind = [string](ConvertTo-DomeniaErrorInfo -ErrorRecordOrException $failure -Operation 'Recherche').Kind } catch { $errorKind = 'Unexpected' }
            if (-not $errorKind) { $errorKind = 'Unexpected' }
        }
        $state = Get-DomeniaMemberValue $search 'State' $null
        $limit=[int](Get-DomeniaMember $state 'Limit' 0)
        $type=[string](Get-DomeniaMember $state 'Type' 'Tous')
        $final=Get-DomeniaMemberValue $search 'Final' $null
        $limited=[bool](Get-DomeniaMember $final 'LimitReached' $false)
        $completeness=if($inFlight){'Loading'}elseif($partial -or $failure){'Partial'}elseif($limited){'Limited'}elseif($completed -and ($null -ne $final)){'Complete'}else{'Unknown'}
        $query = [string](Get-DomeniaMember $state 'Search' '')
        if ([string](Get-DomeniaMember $state 'SearchMode' '') -eq 'Global') { $scope = 'tout le domaine' }
        else {
            $dn = [string](Get-DomeniaMember $state 'BaseDn' '')
            if ($dn) { try { $scope = [string](Get-DomeniaUxOuDisplay -DistinguishedName $dn).Name } catch { $scope = '' } }
        }
    }
    $filterText = ''
    $filter = Get-DomeniaControl 'TxtSuiteResultFilter'
    if ($null -ne $filter) { $filterText = [string]$filter.Text }
    # UX-03: the presence filter belongs to the OU lists; the global search never applies it.
    $presence = [string]$script:CurrentPresenceFilter
    try { if ((Get-DomeniaSearchMode) -eq 'Global') { $presence = 'Tous' } } catch { $script:DomeniaInterfaceFaults = [int]$script:DomeniaInterfaceFaults + 1 }
    $localFilter = $filterText
    if ($presence -and ($presence -ne 'Tous')) {
        if ($localFilter) { $localFilter += ' · ' }
        $localFilter += 'présence ' + $presence
    }
    return [pscustomobject]@{Displayed=$displayed;Loaded=$loaded;InFlight=$inFlight;Completed=$completed;ErrorKind=$errorKind;Partial=$partial;Query=$query;Scope=$scope;LocalFilter=$localFilter;FilterText=$filterText;Presence=$presence;Foreign=$foreign;Pending=$pending;Completeness=$completeness;Limit=$limit;Type=$type}
}

function Update-DomeniaSearchEmptyState {
    # One empty state for the result list (UI-15): while a read runs it says so, then why the list is empty and the
    # next action. Texts are only rewritten when they change, so the screen reader announces a change once.
    $panel = Get-DomeniaControl 'UxSearchEmpty'
    if ($null -eq $panel) { return }
    $inputs = Get-DomeniaSearchEmptyInputs
    if (([int]$inputs.Displayed -gt 0) -or [bool]$inputs.Pending) {
        if ($null -ne $script:DomeniaSearchEmptyTimer) { $script:DomeniaSearchEmptyTimer.Stop() }
        return
    }
    $kind = Resolve-DomeniaSearchEmptyKind -Displayed ([int]$inputs.Displayed) -Loaded ([int]$inputs.Loaded) -InFlight ([bool]$inputs.InFlight) -Completed ([bool]$inputs.Completed) -ErrorKind ([string]$inputs.ErrorKind) -Partial ([bool]$inputs.Partial)
    $title = ''; $text = ''; $label = ''; $command = ''
    if (($kind -eq 'NothingQueried') -and [bool]$inputs.Foreign) {
        # An empty list of another origin (query, history, list cleared): nothing is claimed about what was read.
        $title = 'Aucune ligne à afficher'
        $text = 'Cette liste est vide : elle ne renseigne pas sur lʼétat réel de lʼannuaire.'
        $label = 'Rechercher un nom ou choisir une OU'; $command = 'StartRead'
        if ($null -ne $script:DomeniaSearchEmptyTimer) { $script:DomeniaSearchEmptyTimer.Stop() }
    } elseif (-not $kind) {
        $title = 'Lecture en cours'
        $text = 'Les résultats sʼaffichent dès leur enregistrement local ; la lecture se poursuit sans autre geste.'
        $query = ConvertTo-DomeniaFlatText ([string]$inputs.Query) 60
        if ($query) { $text = 'Recherche de « ' + $query + ' » en cours. Les résultats sʼaffichent dès leur enregistrement local.' }
        if ($null -eq $script:DomeniaSearchEmptyTimer) { $script:DomeniaSearchEmptyTimer = New-DomeniaTimer -Owner 'Timer:SearchEmpty' -IntervalMs 400 -Tick { Update-DomeniaSearchEmptyState } }
        $script:DomeniaSearchEmptyTimer.Start()
    } else {
        $state = Get-DomeniaEmptyState -Kind $kind -Query ([string]$inputs.Query) -Scope ([string]$inputs.Scope) -LocalFilter ([string]$inputs.LocalFilter) -Total ([int]$inputs.Loaded)
        $title = [string]$state.Title; $text = [string]$state.Text
        $label = [string]$state.NextAction.Label; $command = [string]$state.NextAction.Command
        if ($kind -eq 'LocalFilterEmpty') {
            # UX-03: the filter of the list (its text or the presence) hides every loaded row: how many, which filter,
            # and « Effacer le filtre », which shows them again without any request.
            $filtered = Get-DomeniaFilteredEmptyState -Loaded ([int]$inputs.Loaded) -Visible ([int]$inputs.Displayed) -LocalText ([string]$inputs.FilterText) -Presence ([string]$inputs.Presence)
            if ([bool]$filtered.Show) { $title = [string]$filtered.Text; $text = [string]$filtered.Detail }
        }
        if ($null -ne $script:DomeniaSearchEmptyTimer) { $script:DomeniaSearchEmptyTimer.Stop() }
    }
    if($kind -and ($kind -notin @('NothingQueried')) -and (-not [bool]$inputs.Foreign)){
        $text+=' '+(Get-DomeniaSearchAbsenceHint -Scope ([string]$inputs.Scope) -LocalFilter ([string]$inputs.LocalFilter) -Type ([string]$inputs.Type) -Completeness ([string]$inputs.Completeness) -Limit ([int]$inputs.Limit))
    }
    # Both blocks are polite live regions: a new verdict (refusée, aucun résultat...) is announced once, then its
    # explanation; an unchanged text is not announced again.
    [void](Set-DomeniaLiveText -Control (Get-DomeniaControl 'LblSearchEmptyTitle') -Text $title)
    [void](Set-DomeniaLiveText -Control (Get-DomeniaControl 'LblSearchEmptyText') -Text $text)
    $button = Get-DomeniaControl 'BtnSearchEmptyNext'
    if ($null -ne $button) {
        $button.Tag = $command
        if ($command) {
            if ([string]$button.Content -cne $label) { $button.Content = $label }
            $button.Visibility = [Windows.Visibility]::Visible
        } else { $button.Visibility = [Windows.Visibility]::Collapsed }
    }
}

function Invoke-DomeniaSearchEmptyAction {
    # The next action of the empty list, on the click of the operator only. A read starts only when the action is a
    # read (relire) and its own button is shown and enabled; otherwise the field or the view is brought forward.
    $button = Get-DomeniaControl 'BtnSearchEmptyNext'
    $command = ''
    if ($null -ne $button) { $command = [string]$button.Tag }
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    switch ($command) {
        'ClearLocalFilter' {
            # UX-03 (Clear-DomeniaResultFilters): text of the list and presence back to everything, no request.
            Clear-DomeniaResultFilters
            Set-Status 'Filtre de la liste effacé : la liste montre de nouveau toutes les lignes déjà chargées. Aucune nouvelle lecture.'
        }
        { $_ -in @('WidenScope','StartRead') } {
            if ($null -ne $box) { [void]$box.Focus(); $box.SelectAll() }
            Set-DomeniaContextHint -Title 'Lancer ou élargir la recherche' -Text 'Saisissez ou corrigez un nom dans la barre du haut puis Entrée pour chercher dans tout le domaine, ou choisissez une OU dans lʼarbre (sous-OU comprises). Rien nʼest lu avant ce geste.'
        }
        { $_ -in @('ChooseSource','ChangeAccount') } {
            Select-DomeniaWorkspace -Workspace 'TabAccounts'
            Set-Status 'Comptes et accès : vérifiez la connexion à lʼannuaire ou choisissez un compte autorisé, puis relancez la recherche. Aucune nouvelle tentative nʼest faite automatiquement.'
        }
        'RetryMissing' {
            $retry = Get-DomeniaControl 'BtnSearchRefreshBase'
            if ((Get-DomeniaSearchMode) -eq 'Global') { $retry = Get-DomeniaControl 'BtnGlobalSearch' }
            if (($null -ne $retry) -and $retry.IsEnabled -and $retry.IsVisible) { $retry.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
            else {
                if ($null -ne $box) { [void]$box.Focus() }
                Set-Status 'Relecture indisponible pour lʼinstant : relancez la recherche quand une lecture se termine.' 'WARN'
            }
        }
    }
}

function Initialize-DomeniaSearchEmptyState {
    # The empty state follows the list (rows added, filter, new list) and the button of its next action.
    if ([bool]$script:DomeniaSearchEmptyBound) { return }
    $grid = Get-DomeniaControl 'DgObjects'
    if ($null -eq $grid) { return }
    $script:DomeniaSearchEmptyBound = $true
    # Cheap while rows arrive: the handler returns at once when the list is not empty.
    ([Collections.Specialized.INotifyCollectionChanged]$grid.Items).add_CollectionChanged({ param($sender,$eventArgs) if ($sender.Count -eq 0) { Update-DomeniaSearchEmptyState } })
    $descriptor = [ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.ItemsControl]::ItemsSourceProperty,[Windows.Controls.DataGrid])
    if ($null -ne $descriptor) { $descriptor.AddValueChanged($grid,[EventHandler]{ param($sender,$eventArgs) Update-DomeniaSearchEmptyState }) }
    $button = Get-DomeniaControl 'BtnSearchEmptyNext'
    if ($null -ne $button) { $button.Add_Click({ Invoke-DomeniaSearchEmptyAction }) }
    Update-DomeniaSearchEmptyState
}

# ---------------------------------------------------------------- L08 read-only switch and automatic return (DS-02, SE-06)
function Get-DomeniaUxReadOnlyDelay {
    $value = 15
    try { $value = [int](Get-CfgValue 'Security' 'ReadOnlyReturnMinutes' 15) } catch { $value = 15 }
    return [int](Get-DomeniaReadOnlyReturnPlan -WriteEnabled $false -DelayMinutes $value -Now (Get-Date)).DelayMinutes
}

function Request-DomeniaWriteMode {
    # Unchecked handler of the switch. The switch goes back to « Lecture seule » at once and a one-sentence request is
    # shown in a panel of the page (Request-DomeniaInlineConfirmation): no window. Only « Autoriser » enables writes.
    if ([bool]$script:UxWriteModeConfirmed) { return }
    $switch = Get-DomeniaControl 'ChkReadOnlyMode'
    $script:ReadOnlyMode = $true
    $script:UxReadOnlySwitchUpdating = $true
    try { if ($null -ne $switch) { $switch.IsChecked = $true } } finally { $script:UxReadOnlySwitchUpdating = $false }
    if ([bool]$script:DemoMode) {
        Set-Status 'Écritures désactivées en démonstration : la lecture seule reste active.' 'WARN'
        return
    }
    $delay = Get-DomeniaUxReadOnlyDelay
    $message = 'Vous allez autoriser les modifications Active Directory : chaque action garde ses contrôles et sa confirmation, et la lecture seule revient seule après ' + [string]$delay + ' min sans écriture.'
    [void](Request-DomeniaInlineConfirmation -Title 'Autoriser les modifications ?' -Message $message -Target 'write-mode' -ConfirmText 'Autoriser les modifications' -CancelText 'Rester en lecture seule' -OnConfirm { Enable-DomeniaWriteMode } -OnCancel { Set-Status 'Lecture seule conservée.' 'INFO' } -Risk 'Danger')
}

function Enable-DomeniaWriteMode {
    # Confirmed answer of the request: write mode starts with its countdown (SE-06).
    if ([bool]$script:DemoMode) { return }
    $script:UxWriteModeConfirmed = $true
    try {
        $switch = Get-DomeniaControl 'ChkReadOnlyMode'
        if ($null -ne $switch) { $switch.IsChecked = $false }
    } finally { $script:UxWriteModeConfirmed = $false }
    $script:ReadOnlyMode = $false
    $script:UxWriteModeSince = Get-Date
    $script:UxWriteModeLastWrite = $null
    $script:UxWriteSeenInProgress = $false
    Apply-CurrentPermissionUi
    Start-DomeniaReadOnlyReturnTimer
    Set-Status ('Écriture active : les garde-fous restent actifs et chaque action sensible demande confirmation. Retour en lecture seule après ' + [string](Get-DomeniaUxReadOnlyDelay) + ' min sans écriture.') 'WARN'
    try { Add-DomeniaUiLog -Area 'Securite' -Level 'WARN' -Text 'Écriture active, confirmée dans la page.' } catch { Write-DomeniaSwallowed 'UX' 'Enable-DomeniaWriteMode' $_ }
}

function Enter-DomeniaReadOnlyMode {
    # Checked handler of the switch: back to read-only at once (switch, « Repasser en lecture », timer, new account).
    $reason = [string]$script:UxReadOnlyReturnReason
    $script:ReadOnlyMode = $true
    Stop-DomeniaReadOnlyReturnTimer
    $script:UxWriteModeSince = $null
    $script:UxWriteModeLastWrite = $null
    if ([bool]$script:UxReadOnlySwitchUpdating) { return }
    Apply-CurrentPermissionUi
    if ($reason -eq 'Automatic') {
        $text = 'Retour automatique en lecture seule après ' + [string](Get-DomeniaUxReadOnlyDelay) + ' min sans écriture.'
        Set-Status $text 'INFO'
        try { Add-DomeniaUiLog -Area 'Securite' -Level 'INFO' -Text $text } catch { Write-DomeniaSwallowed 'UX' 'Enter-DomeniaReadOnlyMode' $_ }
    }
    else { Set-Status 'Lecture seule active : écritures AD, GPUpdate et redémarrage distant bloqués.' 'INFO' }
}

function Exit-DomeniaWriteMode {
    # Back to read-only from the « Repasser en lecture » button or from the timer. The timer only asks it when the
    # plan says so, that is never while a write is in progress.
    param([ValidateSet('Manual','Automatic')][string]$Reason='Manual')
    $script:UxReadOnlyReturnReason = $Reason
    try {
        $switch = Get-DomeniaControl 'ChkReadOnlyMode'
        if (($null -ne $switch) -and (-not [bool]$switch.IsChecked)) { $switch.IsChecked = $true }
        else { Enter-DomeniaReadOnlyMode }
    } finally { $script:UxReadOnlyReturnReason = '' }
}

function Update-DomeniaReadOnlySwitch {
    # Label and tool tip of the switch (« Lecture seule » or « Écriture active · 12 min »). A write running, or ending
    # since the last update, restarts the delay. Display only: the return itself is decided by the timer.
    param($Now=$null,[switch]$PassThru)
    if ($null -eq $Now) { $Now = Get-Date }
    $plan = Get-DomeniaUxReadOnlyPlan -Now ([datetime]$Now)
    $switch = Get-DomeniaControl 'ChkReadOnlyMode'
    if ($null -ne $switch) {
        $changed = ([string]$switch.Content -cne [string]$plan.Label)
        $switch.Content = [string]$plan.Label
        $switch.ToolTip = [string]$plan.ToolTip
        [Windows.Automation.AutomationProperties]::SetHelpText($switch,[string]$plan.ToolTip)
        if ($changed) { Send-DomeniaUxLiveChange -Control $switch }
    }
    if ($PassThru) { return $plan }
}

function Get-DomeniaUxReadOnlyPlan {
    param([datetime]$Now)
    $writeEnabled = -not [bool]$script:ReadOnlyMode
    $inProgress = ((-not [string]::IsNullOrWhiteSpace([string]$script:ActiveWriteTaskId)) -or ([string]$script:WriteState -eq 'Running'))
    if ($writeEnabled -and ($inProgress -or [bool]$script:UxWriteSeenInProgress)) { $script:UxWriteModeLastWrite = $Now }
    $script:UxWriteSeenInProgress = ($writeEnabled -and $inProgress)
    return (Get-DomeniaReadOnlyReturnPlan -WriteEnabled $writeEnabled -EnabledAt $script:UxWriteModeSince -LastWriteAt $script:UxWriteModeLastWrite -Now $Now -DelayMinutes (Get-DomeniaUxReadOnlyDelay) -WriteInProgress $inProgress)
}

function Invoke-DomeniaReadOnlyReturnTick {
    # Timer tick (every 15 s while writes are allowed): countdown, then the return once the delay has passed without
    # any write. A write in progress defers it to its end; it is never interrupted.
    param($Now=$null)
    if ([bool]$script:ReadOnlyMode) { Stop-DomeniaReadOnlyReturnTimer; return $null }
    $plan = Update-DomeniaReadOnlySwitch -Now $Now -PassThru
    if ([bool]$plan.Expired) { Exit-DomeniaWriteMode -Reason Automatic }
    return $plan
}

function Start-DomeniaReadOnlyReturnTimer {
    if ($null -eq $script:UxReadOnlyTimer) {
        # FI-05: protected timer of the engine factory (errors journaled, stopped after repeated failures).
        $script:UxReadOnlyTimer = New-DomeniaTimer -Owner 'Timer:ReadOnlyReturn' -IntervalMs 15000 -RunWhenHidden -Tick { [void](Invoke-DomeniaReadOnlyReturnTick) }
    }
    $script:UxReadOnlyTimer.Stop()
    $script:UxReadOnlyTimer.Start()
}

function Stop-DomeniaReadOnlyReturnTimer {
    if ($null -ne $script:UxReadOnlyTimer) { try { $script:UxReadOnlyTimer.Stop() } catch { Write-DomeniaSwallowed 'UX' 'Stop-DomeniaReadOnlyReturnTimer' $_ } }
}

function Get-DomeniaUiZoomLayoutSize {
    # Align down before LayoutTransform: upward layout rounding can otherwise create an Auto
    # scrollbar, shrink the viewport, remove the scrollbar and repeat indefinitely.
    param([double]$ViewportWidth,[double]$ViewportHeight,[int]$Percent=100,[double]$DpiScaleX=1.0,[double]$DpiScaleY=1.0)
    $scale=[double]([Math]::Max(80,[Math]::Min(150,$Percent)))/100.0
    if([double]::IsNaN($DpiScaleX) -or [double]::IsInfinity($DpiScaleX) -or $DpiScaleX -le 0){$DpiScaleX=1.0}
    if([double]::IsNaN($DpiScaleY) -or [double]::IsInfinity($DpiScaleY) -or $DpiScaleY -le 0){$DpiScaleY=1.0}
    $width=900.0;$height=450.0
    if($ViewportWidth -gt 0 -and -not [double]::IsInfinity($ViewportWidth)){$width=[Math]::Max(900.0,[Math]::Floor(($ViewportWidth/$scale)*$DpiScaleX)/$DpiScaleX)}
    if($ViewportHeight -gt 0 -and -not [double]::IsInfinity($ViewportHeight)){$height=[Math]::Max(450.0,[Math]::Floor(($ViewportHeight/$scale)*$DpiScaleY)/$DpiScaleY)}
    return [pscustomobject]@{Width=$width;Height=$height;Scale=$scale}
}

function Set-DomeniaUiZoom {
    param([int]$Percent=100,[switch]$Persist)
    $percent=[Math]::Max(80,[Math]::Min(150,$Percent))
    $script:DomeniaUiZoomPercent=$percent
    $shell=Get-DomeniaControl 'UxShellGrid';$scroll=Get-DomeniaControl 'RootScroll'
    if($null -eq $shell -or $null -eq $scroll){return}
    $scale=[double]$percent/100.0
    if($shell.LayoutTransform -isnot [Windows.Media.ScaleTransform] -or $shell.LayoutTransform.ScaleX -ne $scale){$shell.LayoutTransform=[Windows.Media.ScaleTransform]::new($scale,$scale)}
    # Keep the fitted dimensions on the WPF layout pixel grid. The minimum-size overflow
    # still scrolls normally; fitting a viewport must not manufacture a fractional overflow.
    $dpiX=1.0;$dpiY=1.0
    try{$dpi=[Windows.Media.VisualTreeHelper]::GetDpi($shell);$dpiX=$dpi.DpiScaleX;$dpiY=$dpi.DpiScaleY}catch{Write-DomeniaSwallowed 'UX' 'Set-DomeniaUiZoom' $_}
    $size=Get-DomeniaUiZoomLayoutSize -ViewportWidth $scroll.ViewportWidth -ViewportHeight $scroll.ViewportHeight -Percent $percent -DpiScaleX $dpiX -DpiScaleY $dpiY
    if($scroll.ViewportWidth -gt 0 -and $shell.Width -ne $size.Width){$shell.Width=$size.Width}
    if($scroll.ViewportHeight -gt 0 -and $shell.Height -ne $size.Height){$shell.Height=$size.Height}
    $minus=Get-DomeniaControl 'BtnUiZoomOut';$plus=Get-DomeniaControl 'BtnUiZoomIn';$reset=Get-DomeniaControl 'BtnUiZoomReset'
    if($null -ne $minus){$minus.IsEnabled=($percent -gt 80)}
    if($null -ne $plus){$plus.IsEnabled=($percent -lt 150)}
    if($null -ne $reset){$reset.Content=([string]$percent+' %')}
    # A zoom gesture does not resize the outer Window, so its SizeChanged cannot update the breakpoints.
    Update-DomeniaUxLayout
    if($Persist){Set-DomeniaSetting 'Ui.ZoomPercent' $percent;Save-DomeniaSettings}
}
function Update-DomeniaUiZoomForDpi {
    # W13 (point 114): a DPI change of the window (moved to a screen of another scale, scale changed while open) fits
    # the zoomed page again on the new pixel grid. Layout only: the typed text, the caret and the focus are not touched.
    # WPF raises Window.DpiChanged only in a per-monitor DPI aware process. Domenia runs in powershell.exe, which is
    # system DPI aware: there Windows scales the whole window itself, the DPI seen by WPF does not change, and a change of
    # resolution reaches the page through RootScroll.ScrollChanged. This handler is the path of a per-monitor host.
    try { Set-DomeniaUiZoom -Percent $script:DomeniaUiZoomPercent } catch { $script:DomeniaInterfaceFaults = [int]$script:DomeniaInterfaceFaults + 1 }
}
function Initialize-DomeniaUiZoom {
    $reset=Get-DomeniaControl 'BtnUiZoomReset'
    if($null -eq $reset -or [string]$reset.Tag -eq 'ZoomBound'){return}
    $reset.Tag='ZoomBound'
    (Get-DomeniaControl 'BtnUiZoomOut').Add_Click({Set-DomeniaUiZoom -Percent ($script:DomeniaUiZoomPercent-10) -Persist})
    (Get-DomeniaControl 'BtnUiZoomIn').Add_Click({Set-DomeniaUiZoom -Percent ($script:DomeniaUiZoomPercent+10) -Persist})
    $reset.Add_Click({Set-DomeniaUiZoom -Percent 100 -Persist})
    (Get-DomeniaControl 'RootScroll').Add_ScrollChanged({param($s,$e)if([object]::ReferenceEquals($s,$e.OriginalSource) -and ($e.ViewportWidthChange -ne 0 -or $e.ViewportHeightChange -ne 0)){Set-DomeniaUiZoom -Percent $script:DomeniaUiZoomPercent}})
    # W13 (point 114): Update-DomeniaUiZoomForDpi on Window.DpiChanged. Only a per-monitor DPI aware process receives it;
    # under powershell.exe (system DPI aware) Windows scales the whole window and RootScroll.ScrollChanged fits again.
    try{if(($null -ne $script:Window) -and ($null -ne $script:Window.GetType().GetEvent('DpiChanged'))){$script:Window.Add_DpiChanged({Update-DomeniaUiZoomForDpi})}}catch { $script:DomeniaInterfaceFaults = [int]$script:DomeniaInterfaceFaults + 1 }
    $percent=100
    try{$percent=[int](Get-DomeniaSetting 'Ui.ZoomPercent' '100')}catch{$percent=100}
    Set-DomeniaUiZoom -Percent $percent
}
