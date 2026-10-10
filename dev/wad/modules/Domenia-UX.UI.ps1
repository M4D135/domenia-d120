# DOMENIA R1.11. Presentation only. No AD, remote execution or credential validation here.
# Help titles/descriptions come from a static catalogue, NEVER from a control value.
. (Join-Path $PSScriptRoot 'Domenia-Experience.Model.ps1')
. (Join-Path $PSScriptRoot 'Domenia-Experience.UI.ps1')
$script:UxModuleRoot = $PSScriptRoot
$script:UxHelpCatalogue = @{}
$script:UxShellInitialized = $false
$script:UxNavCollapsed = $false
$script:UxNavLayoutSignature = ''
$script:UxHelpVisible = $true
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
        try { $Name = [string]$Control.Name } catch { }
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
    # Preserve status reasons supplied by the existing security UI.
    # Do not reflect Text, Password, SelectedItem, DataContext, Content or Tag.
    try {
        $statusTip = $Control.ToolTip
        if ($statusTip -is [string] -and $statusTip -ne $description -and
            $statusTip -match '^(Desactive|Droit indetermine|Estimation ACL|Ecriture brute|Action distante|Fonction desactivee|Aucune valeur|Aucun secret|Selectionne une ligne|Charge d.abord)') {
            return $description + "`r`n`r`n" + [string]$statusTip
        }
    } catch { }
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
    } catch { }
}

function Initialize-DomeniaUxControlHelp {
    param($Control)
    if ($null -eq $Control -or $Control -isnot [Windows.FrameworkElement]) { return }
    Import-DomeniaUxHelpCatalogue
    $name = [string]$Control.Name
    if (-not $script:UxHelpCatalogue.ContainsKey($name)) { return }
    if ($Control.Resources.Contains('Domenia.UxHelpAttached')) { return }
    $entry = $script:UxHelpCatalogue[$name]
    $Control.ToolTip = [string]$entry.Text
    [Windows.Controls.ToolTipService]::SetShowOnDisabled($Control,$true)
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($Control,350)
    [Windows.Controls.ToolTipService]::SetBetweenShowDelay($Control,100)
    [Windows.Controls.ToolTipService]::SetShowDuration($Control,20000)
    [Windows.Automation.AutomationProperties]::SetName($Control,[string]$entry.Title)
    [Windows.Automation.AutomationProperties]::SetHelpText($Control,[string]$entry.Text)
    $Control.Resources['Domenia.UxHelpAttached'] = $true
    $Control.Add_MouseEnter({param($sender,$eventArgs) Show-DomeniaUxControlHelp -Control $sender})
    $Control.Add_GotKeyboardFocus({
        param($sender,$eventArgs)
        # A routed child focus must not let a parent overwrite the specific help.
        if ($sender -eq $eventArgs.OriginalSource) { Show-DomeniaUxControlHelp -Control $sender }
    })
    $Control.Add_ToolTipOpening({param($sender,$eventArgs) Show-DomeniaUxControlHelp -Control $sender})
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
    if ($null -ne $control) { $control.ToolTip = [string]$script:UxHelpCatalogue[$Name].Text }
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
    $current = '';try { $current = [string]$workspaces.SelectedItem.Name } catch { }
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
        # Never leave a hidden detail page selected. No AD read is performed.
        foreach ($name in @('DetailTabs','ComputerTabs','ApplicationToolTabs')) {
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
    # D006: under 940 WPF units of window height the search page folds secondary chrome so that the results grid
    # keeps its room. Pure plan; display state only: the saved journal, help and menu preferences never change.
    param([double]$Height=0,[double]$Width=0)
    $short = (($Height -gt 0) -and ($Height -lt 940))
    $low = (($Height -gt 0) -and ($Height -lt 700))
    # UI-05 (L08): under 1280 units of width the menu also folds for the session (half screen beside the ticket tool),
    # so that the top search keeps its room; the saved menu preference is never changed by a resize.
    $narrow = (($Width -gt 0) -and ($Width -lt 1280))
    return [pscustomobject]@{
        LowHeight=$low;Short=$short;FoldJournal=$short;InlineDomainBadge=$short;CloseHelp=$short;HideFilterCaptions=$short
        FoldNavigation=($narrow -or ($short -and ($Width -gt 0) -and ($Width -lt 1200)));Narrow=$narrow
        WorkViewWidth=$(if ($short) { 230.0 } else { 250.0 })
        FilterCardPadding=$(if ($low) { 4.0 } elseif ($short) { 12.0 } else { 16.0 });FilterCardBottom=$(if ($low) { 4.0 } elseif ($short) { 8.0 } else { 12.0 })
        ResultBarBottom=$(if ($low) { 2.0 } elseif ($short) { 6.0 } else { 10.0 });ResultLiveTop=$(if ($low) { 2.0 } elseif ($short) { 4.0 } else { 10.0 });ResultCountTop=0.0
    }
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
    # A slightly narrower work view selector keeps the filters on one line from about 1090 units wide.
    $workView = Get-DomeniaControl 'CmbWorkView'
    if ($null -ne $workView -and $workView.Parent -is [Windows.Controls.DockPanel] -and $workView.Parent.Parent -is [Windows.Controls.StackPanel]) { $workView.Parent.Parent.Width = [double]$Plan.WorkViewWidth }
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
    $pageTitle=Get-DomeniaControl 'LblUxPageTitle';if($pageTitle){$pageTitle.FontSize=if($compact){18.0}else{22.0}}
    if($badge){$badge.Padding=if($compact){[Windows.Thickness]::new(6,1,6,1)}else{[Windows.Thickness]::new(8,3,8,3)}}
    $subRow=Get-DomeniaControl 'UxPageSubRow'
    if($compact){if($title){$title.Orientation=[Windows.Controls.Orientation]::Vertical};if($subRow){$subRow.Margin=[Windows.Thickness]::new(0)}}
    $main=Get-DomeniaControl 'UxMainLayout';if($main){$main.Margin=if($compact){[Windows.Thickness]::new(18,6,16,6)}else{[Windows.Thickness]::new(18,12,16,12)}}
    $header=Get-DomeniaControl 'UxHeader';if($header){$header.Margin=if($compact){[Windows.Thickness]::new(0,0,0,4)}else{[Windows.Thickness]::new(0,0,0,10)}}
    $header=Get-DomeniaControl 'UxPageHeader';if($header){$header.Margin=if($compact){[Windows.Thickness]::new(2,0,0,6)}else{[Windows.Thickness]::new(2,0,0,12)}}
    foreach($name in @('UxSearchScopeTitle','UxOuIntro','UxOuScopeCaption','UxOuScopeCard')){
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
    $widths=@{CmbGlobalType=148.0;CmbPresenceFilter=138.0;TxtGlobalLimit=90.0}
    foreach($name in $widths.Keys){
        $control=Get-DomeniaControl $name
        if($control -and $control.Parent -is [Windows.Controls.StackPanel]){
            $control.Parent.Width=if($compact -and $name -eq 'TxtGlobalLimit'){70.0}else{$widths[$name]}
            $control.Parent.Margin=if($compact){[Windows.Thickness]::new(0,0,6,0)}else{[Windows.Thickness]::new(0,0,12,8)}
        }
    }
    if($workView -and $workView.Parent.Parent -is [Windows.Controls.StackPanel]){
        $workView.Parent.Parent.Width=if($compact){190.0}else{[double]$Plan.WorkViewWidth}
        $workView.Parent.Parent.Margin=if($compact){[Windows.Thickness]::new(0)}else{[Windows.Thickness]::new(0,0,12,8)}
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
    $consoleCheck=Get-DomeniaControl 'ChkLiveUsers';if($consoleCheck){$consoleCheck.Content=if($compact){'Console au clic'}else{'Utilisateur au clic'}}
    $recheck=Get-DomeniaControl 'BtnLiveRecheck';if($recheck){$recheck.Content=if($compact){'Revérifier'}else{'Revérifier ce poste'}}
    # Ping and detection of the list (lot 2026-10-07) keep the action row on one line in compact mode: short labels
    # and tighter buttons; every action stays in view (Arreter included).
    $parkPing=Get-DomeniaControl 'BtnParkPing';if($parkPing){$parkPing.Content=if($compact){'Pinger'}else{'Pinger la liste'}}
    $parkRun=Get-DomeniaControl 'BtnParkResults';if($parkRun){$parkRun.Content=if($compact){'Détecter'}else{'Détecter la liste'}}
    $parkAnalyze=Get-DomeniaControl 'BtnParkAnalyze';if($parkAnalyze){$parkAnalyze.Content=if($compact){'Analyser'}else{'Analyser la liste'}}
    foreach($name in @('BtnLiveRecheck','BtnParkPing','BtnParkResults','BtnParkAnalyze','BtnParkResultsStop')){
        $button=Get-DomeniaControl $name
        if($button){
            $button.Padding=if($compact){[Windows.Thickness]::new(6,4,6,4)}else{[Windows.Thickness]::new(10,4,10,4)}
            $button.Margin=if($compact){[Windows.Thickness]::new(0,0,4,4)}else{[Windows.Thickness]::new(0,0,8,4)}
        }
    }
    if($consoleCheck){$consoleCheck.Margin=if($compact){[Windows.Thickness]::new(0,0,8,4)}else{[Windows.Thickness]::new(0,0,14,4)}}
    $statuses=Get-DomeniaControl 'UxResultLiveStatuses'
    if($live -and $statuses){
        $live.ColumnDefinitions[0].Width=if($compact){[Windows.GridLength]::new(470)}else{[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}
        $live.ColumnDefinitions[1].Width=if($compact){[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)}else{[Windows.GridLength]::new(0)}
        [Windows.Controls.Grid]::SetRow($statuses,$(if($compact){0}else{1}))
        [Windows.Controls.Grid]::SetColumn($statuses,$(if($compact){1}else{0}))
        $statuses.Margin=if($compact){[Windows.Thickness]::new(8,0,0,0)}else{[Windows.Thickness]::new(0)}
    }
    $ouColumn=Get-DomeniaControl 'UxOuColumn'
    if($ouColumn){
        if($compact -and -not [bool]$script:UxCompactLayoutActive){$script:UxCompactOuWidth=$ouColumn.Width;$ouColumn.Width=[Windows.GridLength]::new(230)}
        elseif(-not $compact -and [bool]$script:UxCompactLayoutActive -and $null -ne $script:UxCompactOuWidth){$ouColumn.Width=$script:UxCompactOuWidth}
    }
    $ouPanel=Get-DomeniaControl 'SearchOuPanel';if($ouPanel){$ouPanel.Padding=if($compact){[Windows.Thickness]::new(10)}else{[Windows.Thickness]::new(16)}}
    $scope=Get-DomeniaControl 'UxOuScopeCard'
    if($scope){$scope.Padding=if($compact){[Windows.Thickness]::new(6)}else{[Windows.Thickness]::new(12)};$scope.Margin=if($compact){[Windows.Thickness]::new(0,0,0,6)}else{[Windows.Thickness]::new(0,0,0,12)}}
    # L03: 'Tout le domaine' sits in the WrapPanel of the OU tree menu, next to the pin button: its XAML margin is kept.
    # The 'Dans :' chip of the work views keeps a 24 px target, reduced to the scope line height on a short screen.
    $viewScope=Get-DomeniaControl 'CmbWorkViewScope'
    if($viewScope){$viewScope.Height=if($compact){18.0}else{24.0};$viewScope.Margin=if($compact){[Windows.Thickness]::new(8,0,0,0)}else{[Windows.Thickness]::new(8,0,0,2)}}
    $scopeName=Get-DomeniaControl 'LblOuScopeName';if($scopeName){$scopeName.MaxHeight=if($compact){40.0}else{[double]::PositiveInfinity}}
    $script:UxCompactLayoutActive=$compact

    # Journal shown folded while the screen is short, unless the operator unfolds it; the saved state is untouched.
    $hold = ([bool]$Plan.FoldJournal -and (-not [bool]$script:UxLogCollapsed) -and (-not [bool]$script:UxShortLogReleased))
    # Applied every time (idempotent): the held flag alone must not decide what the journal row shows.
    if ($hold) { $script:UxShortLogHeld = $true;Set-DomeniaExperienceJournalLayout -Collapsed $true -Transient }
    elseif ([bool]$script:UxShortLogHeld) { Set-DomeniaExperienceJournalLayout -Collapsed ([bool]$script:UxLogCollapsed) -Transient;$script:UxShortLogHeld = $false }
}

function Update-DomeniaUxLayout {
    if ($null -eq $script:Window) { return }
    $width = [double]$script:Window.ActualWidth
    if ($width -le 0) { $width = [double]$script:Window.Width }
    $height = [double]$script:Window.ActualHeight
    if ($height -le 0) { $height = [double]$script:Window.Height }
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
    $signature = '{0}:{1}:{2}:{3}:{4}:{5}' -f $plan.Compact,$plan.HelpShown,$plan.NavWidth,$script:UxShortScreen,$heightPlan.LowHeight,$plan.HeaderStacked
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
        $button.ToolTip = if ($plan.HelpShown) { 'Réduire le panneau d''aide. Les infobulles restent disponibles.' } else { 'Afficher le panneau d''aide contextuelle.' }
        [Windows.Automation.AutomationProperties]::SetName($button,$button.ToolTip)
    }
    Set-DomeniaUxShortLayout -Plan $heightPlan
}

function Switch-DomeniaUxHelp {
    if ($null -eq $script:Window) { return }
    if ([bool]$script:UxShortScreen) {
        # Short screen: the help opens for this session only; the saved choice is untouched.
        $script:UxShortHelpOpen = -not [bool]$script:UxShortHelpOpen
        Update-DomeniaUxLayout
        return
    }
    $width=[double]$script:Window.ActualWidth
    if($width -le 0){$width=[double]$script:Window.Width}
    $plan=Get-DomeniaUxLayoutPlan -Width $width -NavCollapsed $script:UxNavCollapsed -HelpVisible $script:UxHelpVisible -CompactHelpOpen $script:UxHelpCompactOpen
    # A deliberate toggle applies to both layout modes; resize must not undo it.
    $script:UxHelpVisible=-not $plan.HelpShown
    $script:UxHelpCompactOpen=$script:UxHelpVisible
    Update-DomeniaUxLayout
    Save-DomeniaUxLayoutSettings
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
    $script:UxHelpVisible=ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxHelpVisible' -Default $true) -Default $true
    $script:UxHelpCompactOpen=ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxHelpCompactOpen' -Default $false)
    $script:UxNavCollapsed=ConvertTo-DomeniaUxFlag (Get-DomeniaSetting -Name 'UxNavCollapsed' -Default $false)
    $script:UxNavLayoutSignature=''
    try { Update-DomeniaSearchScopeUi } catch { }
    $script:Window.Add_SizeChanged({Update-DomeniaUxLayout})
    $script:Window.Add_ContentRendered({Sync-DomeniaUxNavigation;Update-DomeniaUxLayout})
    $script:Window.Add_Closed({$script:UxShellInitialized=$false;$script:UxLayoutSignature='';$script:UxHelpCompactOpen=$false;$script:UxNavLayoutSignature='';$script:UxShortScreen=$false;$script:UxShortHelpOpen=$false;$script:UxShortLogHeld=$false;$script:UxShortLogReleased=$false;$script:UxShortNavFold=$false;$script:UxShortNavReleased=$false;$script:UxNavButtonCache=$null;Stop-DomeniaReadOnlyReturnTimer})
    # L08: subject chip, account of the menu foot, search bar (recent entries, local suggestions) and empty pages.
    $clear = Get-DomeniaControl 'BtnUxSubjectClear';if ($null -ne $clear) { $clear.Add_Click({ Clear-DomeniaUxSubject }) }
    $account = Get-DomeniaControl 'BtnUxNavAccount';if ($null -ne $account) { $account.Add_Click({ param($sender,$eventArgs) Show-DomeniaUxAccountMenu -Button $sender }) }
    Initialize-DomeniaUxSearchBar
    Initialize-DomeniaUxEmptyStates
    $script:UxShellInitialized=$true
    Initialize-DomeniaExperience
    Update-DomeniaUxProfileSwitch
    Update-DomeniaUxProfileVisibility
    Update-DomeniaUxThemeToggle
    Sync-DomeniaUxNavigation
    Update-DomeniaReadOnlySwitch
    Update-DomeniaUxLayout
}

function Set-DomeniaUxPalette {
    param($Window,[ValidateSet('Light','Dark')][string]$Theme='Light')
    if ($null -eq $Window) { return }
    $palette=Get-SuitePalette -Theme $Theme
    $converter=[Windows.Media.BrushConverter]::new()
    foreach ($key in $palette.Keys) { $Window.Resources[$key]=$converter.ConvertFromInvariantString([string]$palette[$key]) }
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
    $name=Get-DomeniaControl 'LblOuScopeName';$path=Get-DomeniaControl 'LblOuScopePath';$summary=Get-DomeniaControl 'LblSearchScope'
    if($null -ne $name){$name.Text=$display.Name;$name.ToolTip=$display.FullPath}
    if($null -ne $path){$path.Text=$display.Breadcrumb;$path.ToolTip=$display.FullPath}
    if($null -ne $summary){
        $depth=if($Scope.Scope -eq 'Subtree'){'Sous-OU incluses'}else{'Enfants directs'}
        # D032: browsing always reads 'Dans cette OU', the upper bar always 'Domaine entier'.
        $label='Dans : '+$display.Name+'  ·  '+$depth
        if($null -ne (Get-Command Get-DomeniaScopeLabel -CommandType Function -ErrorAction SilentlyContinue)){
            $label=Get-DomeniaScopeLabel -Mode Browse -OuName ([string]$display.Name) -Subtree ($Scope.Scope -eq 'Subtree')
        }
        $summary.Text=$label
        $summary.ToolTip='Racine LDAP : '+[string]$Scope.BaseDn+"`r`n"+$depth+"`r`nLe texte de la barre du haut ne filtre pas cette OU."
    }
}

function Copy-DomeniaUxOuPath {
    $box=Get-DomeniaControl 'TxtBranchDn'
    if($null -eq $box -or [string]::IsNullOrWhiteSpace([string]$box.Text)){return}
    try{
        [Windows.Clipboard]::SetText([string]$box.Text)
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
    } catch { }
}

function Get-DomeniaUxSubject {
    # The current subject: the loaded object, otherwise the object being read; never a former object.
    $name = ''; $type = ''
    if ($null -ne $script:SelectedObject) {
        try { $name = [string]$script:SelectedObject.Name; $type = [string]$script:SelectedObject.Type } catch { }
    }
    elseif ($null -ne $script:SelectionLoad) {
        try { $name = [string]$script:SelectionLoad.Context.Name; $type = [string]$script:SelectionLoad.Context.Type } catch { }
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
        try { if ([string]$script:Window.Title -cne [string]$title.WindowTitle) { $script:Window.Title = [string]$title.WindowTitle } } catch { }
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
    # UI-29 / SP-04: « Connecté à example.local », or « AD injoignable depuis HH:MM · données déjà lues seulement » while the
    # last directory request did not get an answer; back by itself at the next directory success, nothing is retried.
    $label = Get-DomeniaControl 'LblUxDomain'
    if ($null -eq $label) { return }
    $offline = $false
    $outage = $null
    try {
        $reach = $script:DirectoryReachability
        if (($null -ne $reach) -and ([long]$reach.Epoch -eq [long]$script:SessionEpoch)) { $offline = [bool]$reach.Offline; $outage = $reach.LastOutageUtc }
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
    $badge = Get-DomeniaSessionBadge -Domain $domain -Offline $offline -OfflineSince $script:UxAdOfflineSince -Demo $demo -DemoText $demoText
    # A badge without a domain yet keeps its startup text (« Session AD en préparation ») or an offline preview text.
    if (([string]$badge.State -eq 'Pending') -and (-not [string]::IsNullOrWhiteSpace([string]$label.Text))) { return }
    if ([string]$label.Text -cne [string]$badge.Text) { $label.Text = [string]$badge.Text; Send-DomeniaUxLiveChange -Control $label }
    if ([string]$badge.State -ne 'Demo') {
        $label.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,$(if ($offline) { 'StatusError' } else { 'InfoFg' }))
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
    if ($show) { Set-DomeniaContextHint -Title 'À propos de Domenia' -Text ([string]$script:DomeniaBuild + '. Les actions restent sous votre contrôle ; aucune écriture ne part sans votre geste.') }
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

function Update-DomeniaUxThemeToggle {
    # DS-10: name and tool tip of the theme button give the theme it switches to (the help catalogue sets a neutral
    # title at start-up; this restores the precise name).
    $button = Get-DomeniaControl 'BtnThemeToggle'
    if ($null -eq $button) { return }
    $icon = Get-DomeniaThemeToggleIcon -CurrentTheme ([string]$script:CurrentTheme)
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
            try { $script:UxSuggestTimer.Stop() } catch { }
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
    try { Add-DomeniaUiLog -Area 'Securite' -Level 'WARN' -Text 'Écriture active, confirmée dans la page.' } catch { }
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
        try { Add-DomeniaUiLog -Area 'Securite' -Level 'INFO' -Text $text } catch { }
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
    if ($null -ne $script:UxReadOnlyTimer) { try { $script:UxReadOnlyTimer.Stop() } catch { } }
}
