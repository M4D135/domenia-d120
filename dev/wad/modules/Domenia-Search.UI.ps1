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
$script:OuTreeFilterWork = $null
$script:OuTreeFilterTimer = $null
$script:TreeSelectionSource = 'Mouse'
$script:PendingFilterChange = $null
$script:FilterChangeTimer = $null
$script:WorkViewScopeOu = ''
$script:SearchQueryCatalog = @()
$script:SearchQueryRun = $null
$script:SearchQueryCatalogBusy = $false
$script:SearchQueryModuleRoot = $PSScriptRoot
$script:SearchQuerySelectorBound = $false
# FO-05: perimeter chip ('Everywhere' or 'Ou') and type key of the upper bar; session state only.
$script:SearchBarScope = 'Everywhere'
$script:SearchBarType = 'Tous'
$script:SearchBarUpdating = $false

function Update-DomeniaSearchHint {
    # D033/D036: explains what the upper bar will search (explicit tokens, pasted identifier, unknown prefix).
    # Text parsing only: no request, no hidden filter.
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    if ($null -eq $box) { return }
    $text = ([string]$box.Text).Trim()
    $hint = ''
    if ($text) {
        $minimum = [Math]::Max(1,[int](Get-CfgValue 'Browser' 'GlobalSearchMinChars' 2))
        # CO-34: an asterisk-only text is refused by the upper bar; say so before Entrée rather than after.
        if (Test-DomeniaWildcardOnly $text) { $hint = [string](Get-DomeniaSearchTextCheck -Text $text -Mode Global -MinimumLength $minimum).Reason }
        else {
            # FO-05: the plan uses the type chosen in the bar, as the search will.
            $plan = Get-DomeniaGlobalSearchPlan -Text $text -TypeFilter (Get-GlobalSelectedTypeFilter -Mode Global) -MinimumLength $minimum -SyntaxEnabled (Get-DomeniaFeatureFlag -Name 'SearchSyntax' -Default $true)
            $hint = [string]$plan.Hint
        }
    }
    [void](Set-DomeniaControlText -Name 'LblSearchHint' -Text $hint)
}

# ---------------------------------------------------------------- FO-05 perimeter chip and type selector of the bar
function Get-DomeniaSearchBarState {
    # The chip, the type and what they mean now (waiting text, summary). Reads the session state only, no request.
    $domain = ''
    if ($null -ne $script:Conn) { $domain = [string]$script:Conn.BaseDn }
    $ouDn = [string]$script:SelectedBranchDn
    $choice = 'Everywhere'
    if ([string]$script:SearchBarScope -eq 'Ou') { $choice = 'Ou' }
    $bar = $null
    if ($domain) { $bar = Get-DomeniaSearchBarScope -Choice $choice -OuDn $ouDn -DomainDn $domain }
    $ouName = ''
    if ($ouDn -and $domain) { try { $ouName = [string](Get-DomeniaUxOuDisplay -DistinguishedName $ouDn -IsDomain ($ouDn -ieq $domain)).Name } catch { $ouName = '' } }
    $effective = 'Everywhere'
    if (($null -ne $bar) -and [bool]$bar.Explicit) { $effective = 'Ou' }
    $type = [string]$script:SearchBarType
    if ($type -notin @('Tous','Utilisateurs','Machines','Groupes')) { $type = 'Tous' }
    $text = Get-DomeniaSearchBarText -Choice $effective -OuName $ouName -Type $type
    return [pscustomobject]@{
        Choice=$effective;OuAvailable=(($null -ne $bar) -and [bool]$bar.OuAvailable);OuName=$ouName;Type=$type
        Placeholder=[string]$text.Placeholder;Summary=[string]$text.Summary;Chip=[string]$text.Chip;TypeLabel=[string]$text.TypeLabel
    }
}

function Update-DomeniaSearchBarUi {
    # FO-05: « Dans « Postes » » follows the OU chosen in the tree; an OU that can no longer be used (none, the domain
    # root, another domain) brings the chip back to « Partout ». The waiting text of the field states both choices.
    $state = Get-DomeniaSearchBarState
    if (($state.Choice -ne 'Ou') -and ([string]$script:SearchBarScope -eq 'Ou')) { $script:SearchBarScope = 'Everywhere' }
    $old = [bool]$script:SearchBarUpdating
    $script:SearchBarUpdating = $true
    try {
        $ouText = 'Dans lʼOU choisie'
        if ([bool]$state.OuAvailable -and $state.OuName) { $ouText = 'Dans « ' + $state.OuName + ' »' }
        $item = Get-DomeniaControl 'ItmSearchBarScopeOu'
        if ($null -ne $item) {
            $item.IsEnabled = [bool]$state.OuAvailable
            [Windows.Automation.AutomationProperties]::SetName($item,$ouText)
        }
        $label = Get-DomeniaControl 'LblSearchBarScopeOu'
        if ($null -ne $label) { $label.Text = $ouText }
        $scopeList = Get-DomeniaControl 'LstSearchBarScope'
        if ($null -ne $scopeList) {
            $wanted = 0
            if ($state.Choice -eq 'Ou') { $wanted = 1 }
            if ($scopeList.SelectedIndex -ne $wanted) { $scopeList.SelectedIndex = $wanted }
        }
        $typeList = Get-DomeniaControl 'LstSearchBarType'
        if ($null -ne $typeList) {
            foreach ($entry in @($typeList.Items)) {
                if (([string]$entry.Tag -eq $state.Type) -and (-not [object]::ReferenceEquals($typeList.SelectedItem,$entry))) { $typeList.SelectedItem = $entry }
            }
        }
        $box = Get-DomeniaControl 'TxtGlobalSearch'
        if ($null -ne $box) { $box.Tag = [string]$state.Placeholder }
    }
    finally { $script:SearchBarUpdating = $old }
}

function Set-DomeniaSearchBarChoice {
    # FO-05: explicit choice of the operator on the chip or on the type selector. Nothing is read: the next Entrée (or
    # Rechercher) searches with it. A list on screen keeps describing the search that produced it.
    param([ValidateSet('Scope','Type')][string]$Kind,[AllowEmptyString()][string]$Value='')
    if ([bool]$script:SearchBarUpdating) { return }
    if ($Kind -eq 'Scope') {
        $script:SearchBarScope = 'Everywhere'
        if ($Value -eq 'Ou') { $script:SearchBarScope = 'Ou' }
    }
    else {
        $script:SearchBarType = 'Tous'
        if ($Value -in @('Tous','Utilisateurs','Machines','Groupes')) { $script:SearchBarType = $Value }
    }
    Update-DomeniaSearchBarUi
    $state = Get-DomeniaSearchBarState
    [void](Set-DomeniaControlText -Name 'LblSearchHint' -Text ('Recherche de la barre : ' + $state.Chip + ' · ' + $state.TypeLabel + '. Entrée lance la recherche ; rien nʼest lu avant.'))
}

# ---------------------------------------------------------------- FO-01 « contains » chip of a short global list
function Update-DomeniaSearchContainsOffer {
    # FO-01: under the counter, a finished global list with few names or none offers « Chercher aussi les noms qui
    # contiennent « compta » » (Get-DomeniaContainsSearchOffer). $null hides the chip (a new search starts). Display only.
    param($Search)
    $chip = Get-DomeniaControl 'BtnSearchContains'
    if ($null -eq $chip) { return }
    $offer = $null
    if ($null -ne $Search) {
        $state = $Search.State
        $offer = Get-DomeniaContainsSearchOffer -Text ([string]$state.Search) -Mode ([string]$state.SearchMode) -PlanKind ([string](Get-DomeniaMember $state 'PlanKind' '')) `
            -MatchMode ([string](Get-DomeniaMember $state 'MatchMode' '')) -Loaded ([int]$Search.Fresh.Count) -Finalized ([bool]$Search.Finalized) `
            -HasError (-not [string]::IsNullOrEmpty([string]$Search.Error)) -LimitReached (($null -ne $Search.Final) -and [bool](Get-DomeniaMember $Search.Final 'LimitReached' $false)) `
            -ViewId ([string](Get-DomeniaMember $state 'ViewId' ''))
    }
    $show = (($null -ne $offer) -and [bool]$offer.Show)
    if ($show) {
        $chip.Content = [string]$offer.Label
        $chip.ToolTip = [string]$offer.Tip
        [Windows.Automation.AutomationProperties]::SetName($chip,[string]$offer.Label)
        [Windows.Automation.AutomationProperties]::SetHelpText($chip,[string]$offer.Tip)
        $chip.Tag = [pscustomobject]@{Term=[string]$offer.Term;Generation=[long]$Search.State.Generation;Epoch=[long]$script:SessionEpoch}
    }
    else { $chip.Tag = $null }
    $wanted = if ($show) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    if ($chip.Visibility -ne $wanted) { $chip.Visibility = $wanted }
}

function Invoke-DomeniaSearchContains {
    # FO-01: explicit gesture of the chip. The search of the list on screen is read again for the names that contain
    # its text, with the same perimeter, type and limit. A chip left from another search reads nothing.
    $chip = Get-DomeniaControl 'BtnSearchContains'
    $offer = $null
    if ($null -ne $chip) { $offer = $chip.Tag }
    $current = (Test-DomeniaLiveSearchActive)
    if ($current) {
        $state = $script:Live.Search.State
        $current = (($null -ne $offer) -and ([long]$offer.Epoch -eq [long]$script:SessionEpoch) -and ([long]$offer.Generation -eq [long]$script:GlobalSearchGeneration) -and
            ([string]$state.SearchMode -eq 'Global') -and ([string]$state.Search -ceq [string]$offer.Term))
    }
    if (-not $current) {
        Update-DomeniaSearchContainsOffer -Search $null
        Set-Status 'La liste affichée nʼest plus la recherche courante : relancez la recherche avant de chercher les noms qui contiennent ce texte.' 'WARN'
        return
    }
    Update-DomeniaSearchContainsOffer -Search $null
    Invoke-GlobalSearch -SearchMode Global -Contains
}

# ---------------------------------------------------------------- DS-06 « ⋯ » menu of the result card
function Get-DomeniaSearchResultMenuEntries {
    # DS-06: Actualiser and Exporter CSV left the toolbar for the « ⋯ » menu. Each entry runs its original button, so
    # the handlers, the disabled state during an operation and the GuiElementPolicy choices stay those of the button.
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @(@{Name='BtnLoadBranch';Header='Actualiser'},@{Name='BtnExportResults';Header='Exporter CSV'})) {
        $button = Get-DomeniaControl $entry.Name
        if ($null -eq $button) { continue }
        $mode = ''
        if (($null -ne $script:GuiElementPolicy) -and $script:GuiElementPolicy.Contains($entry.Name)) { $mode = [string]$script:GuiElementPolicy[$entry.Name] }
        # An action hidden by the administrator stays hidden in the menu too.
        if ($mode.Trim() -match '^(?i:Hidden|Hide|Collapsed|Masque)$') { continue }
        $entries.Add([pscustomobject]@{Name=[string]$entry.Name;Header=[string]$entry.Header;Button=$button;Enabled=[bool]$button.IsEnabled;ToolTip=[string]$button.ToolTip})
    }
    return ,$entries.ToArray()
}

function New-DomeniaSearchResultMenu {
    # DS-06: builds the « ⋯ » menu of the result card. Building or opening it reads nothing; an entry acts only when clicked.
    $menu = [Windows.Controls.ContextMenu]::new()
    foreach ($entry in @(Get-DomeniaSearchResultMenuEntries)) {
        $item = [Windows.Controls.MenuItem]::new()
        $item.Header = $entry.Header
        $item.ToolTip = $entry.ToolTip
        $item.IsEnabled = [bool]$entry.Enabled
        $item.Tag = $entry.Button
        [Windows.Automation.AutomationProperties]::SetName($item,[string]$entry.Header)
        [Windows.Automation.AutomationProperties]::SetHelpText($item,[string]$entry.ToolTip)
        $item.Add_Click({ param($sender,$eventArgs) $target = $sender.Tag; if (($null -ne $target) -and [bool]$target.IsEnabled) { $target.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) } })
        [void]$menu.Items.Add($item)
    }
    # DS-20: the column choice of the result grid, also reachable from the keyboard here.
    if ($null -ne (Get-Command Add-DomeniaResultColumnMenuItems -CommandType Function -ErrorAction SilentlyContinue)) {
        if ($menu.Items.Count -gt 0) { [void]$menu.Items.Add([Windows.Controls.Separator]::new()) }
        $columns = [Windows.Controls.MenuItem]::new()
        $columns.Header = 'Colonnes…'
        [Windows.Automation.AutomationProperties]::SetName($columns,'Colonnes de la liste')
        Add-DomeniaResultColumnMenuItems -Target $columns
        [void]$menu.Items.Add($columns)
    }
    return $menu
}

function Open-DomeniaSearchResultMenu {
    # DS-06: opens the « ⋯ » menu under its button.
    param($Anchor)
    $menu = New-DomeniaSearchResultMenu
    if ($null -ne $Anchor) { $menu.PlacementTarget = $Anchor }
    $menu.Placement = [Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen = $true
    return $menu
}

function Update-DomeniaWorkViewList {
    $combo = Get-DomeniaControl 'CmbWorkView'
    if ($null -eq $combo) { return }
    $saved=@();$script:SearchQueryLibraryError=''
    try{
        $saved=@(Get-DomeniaSavedQueryRecipes)
        $library=$script:DomeniaQueryLibraryStoreState
        if($null -eq $library){$script:SearchQueryLibraryError='Connectez une base locale pour lire vos requêtes personnelles.'}
        elseif($library.Error){$script:SearchQueryLibraryError='Bibliothèque personnelle non confirmée : '+[string]$library.Error}
        elseif(-not $library.Loaded){$script:SearchQueryLibraryError='Lecture des requêtes personnelles dans la base locale en cours.'}
    }catch{$script:SearchQueryLibraryError='Bibliothèque personnelle illisible : '+$_.Exception.Message}
    $script:SearchQueryCatalog=@(Get-DomeniaSearchQueryCatalog -Saved $saved -Favorites @(Get-DomeniaSearchQueryFavorites))
    Update-DomeniaSearchQueryList
}

function Get-DomeniaSearchQueryFavorites {
    try{$decoded=ConvertFrom-Json -InputObject ([string](Get-DomeniaSetting 'Search.QueryFavorites' '[]')) -ErrorAction Stop;return @($decoded|Where-Object{$_ -is [string] -and $_ -match '^(ad|local):[a-zA-Z0-9_.-]{1,80}$'}|Select-Object -Unique -First 200)}catch{return @()}
}
function Initialize-DomeniaSearchQuerySelector {
    if($script:SearchQuerySelectorBound){return}
    Update-DomeniaWorkViewList
    $queryChoice=Get-DomeniaControl 'CmbWorkView';if($null -ne $queryChoice){$queryChoice.Add_SelectionChanged({Update-DomeniaSearchQueryDetails})}
    $queryFilter=Get-DomeniaControl 'TxtSearchQueryFilter';if($null -ne $queryFilter){$queryFilter.Add_TextChanged({Update-DomeniaSearchQueryList})}
    $queryFavorites=Get-DomeniaControl 'ChkSearchQueryFavorites';if($null -ne $queryFavorites){$queryFavorites.Add_Checked({Update-DomeniaSearchQueryList});$queryFavorites.Add_Unchecked({Update-DomeniaSearchQueryList})}
    $queryStar=Get-DomeniaControl 'BtnSearchQueryFavorite';if($null -ne $queryStar){$queryStar.Add_Click({try{Switch-DomeniaSearchQueryFavorite}catch{Set-Status ('Favori non enregistré : '+$_.Exception.Message) 'WARN'}})}
    $queryWorkshop=Get-DomeniaControl 'BtnSearchQueryWorkshop';if($null -ne $queryWorkshop){$queryWorkshop.Add_Click({try{Open-DomeniaSearchQueryWorkshop}catch{Set-Status ('Atelier non ouvert : '+$_.Exception.Message) 'WARN'}})}
    $queryRun=Get-DomeniaControl 'BtnWorkView';if($null -ne $queryRun){$queryRun.Add_Click({try{Invoke-DomeniaWorkView}catch{Write-AppLog ('Requête : '+$_.Exception.Message) 'ERROR';Set-Status ('Requête non exécutée : '+$_.Exception.Message) 'ERROR'}})}
    $queryClear=Get-DomeniaControl 'BtnQueryClearSearch';if($null -ne $queryClear){$queryClear.Add_Click({try{Clear-DomeniaSearchQuery}catch{Set-Status ('Requête non retirée : '+$_.Exception.Message) 'WARN'}})}
    $script:SearchQuerySelectorBound=$true
}
function Update-DomeniaSearchQueryList {
    if($script:SearchQueryCatalogBusy){return}
    $combo=Get-DomeniaControl 'CmbWorkView';if($null -eq $combo){return}
    $selected=[string]$combo.SelectedItem.Id;$text=Get-DomeniaControl 'TxtSearchQueryFilter';$favorites=Get-DomeniaControl 'ChkSearchQueryFavorites'
    $rows=@(Find-DomeniaSearchQuery -Entries $script:SearchQueryCatalog -Text ([string]$text.Text) -FavoritesOnly:($null -ne $favorites -and [bool]$favorites.IsChecked))
    $script:SearchQueryCatalogBusy=$true
    try{
        $combo.ItemsSource=$rows;$combo.DisplayMemberPath='DisplayName';$combo.SelectedIndex=-1
        foreach($row in $rows){if($row.Id -ceq $selected){$combo.SelectedItem=$row;break}}
    }finally{$script:SearchQueryCatalogBusy=$false}
    Update-DomeniaSearchQueryDetails
}
function Update-DomeniaSearchQueryDetails {
    if($script:SearchQueryCatalogBusy){return}
    $combo=Get-DomeniaControl 'CmbWorkView';if($null -eq $combo){return};$entry=$combo.SelectedItem
    $scope=$null
    if([string]$script:Conn.BaseDn -and [string]$script:SelectedBranchDn){try{$scope=Get-DomeniaSearchScope -Mode OU}catch{$scope=$null}}
    $execute=Get-DomeniaControl 'BtnWorkView';if($null -ne $execute){$execute.IsEnabled=($null -ne $entry -and $null -ne $scope)}
    $favorite=Get-DomeniaControl 'BtnSearchQueryFavorite';if($null -ne $favorite){$favorite.IsEnabled=($null -ne $entry)}
    $selection=Get-DomeniaControl 'CmbSearchQueryResult';if($null -ne $selection){$local=($null -ne $entry -and $entry.SourceId -eq 'Local');$selection.IsEnabled=$local;$selection.Visibility=if($local){'Visible'}else{'Collapsed'}}
    $star=Get-DomeniaControl 'BtnSearchQueryFavorite';if($null -ne $star){$star.Content=if($null -ne $entry -and $entry.Favorite){'★'}else{'☆'};$star.ToolTip=if($null -ne $entry -and $entry.Favorite){'Retirer des favoris'}else{'Ajouter aux favoris'}}
    $perimeter=if($null -ne $scope){[string]$scope.BaseDn+$(if([string]$scope.Scope -eq 'Subtree'){' · sous-OU incluses'}else{' · niveau direct'})}else{'Connectez-vous puis choisissez une OU dans lʼarbre'}
    $text=if($null -ne $entry){$entry.Source+' · '+$entry.TypeLabel+' · '+$perimeter+'. '+$entry.Description}else{'Choisissez une requête ; la sélection seule ne lance rien. '+$perimeter+'.'}
    if($null -ne $scope -and $null -ne $entry -and $entry.SourceId -eq 'Local'){$text+=' '+(Get-DomeniaSearchQueryCoverageText -ScopeDn ([string]$scope.BaseDn))}
    if($script:SearchQueryLibraryError){$text+=' '+$script:SearchQueryLibraryError}
    [void](Set-DomeniaControlText 'LblSearchQueryDetails' $text)
}
function Get-DomeniaSearchQueryCoverageText {
    param([string]$ScopeDn)
    $coverage=Get-DomeniaFleetFreshness -ScopeDn $ScopeDn -DomainDn ([string]$script:Conn.BaseDn) -SyncStates $script:IndexSyncStates
    $text=if($null -ne $coverage.At){'Dernière lecture complète couvrante : '+$coverage.At.ToLocalTime().ToString('dd/MM/yyyy HH:mm')+'.'}else{'Couverture AD complète non attestée : seuls les objets déjà recensés sont évalués.'}
    if($coverage.Partial){$text+=' Dernière tentative incomplète ; la couverture peut manquer des objets.'}
    return $text
}
function Switch-DomeniaSearchQueryFavorite {
    $entry=(Get-DomeniaControl 'CmbWorkView').SelectedItem;if($null -eq $entry){return}
    $ids=@(Get-DomeniaSearchQueryFavorites)
    if($ids -ccontains [string]$entry.Id){$ids=@($ids|Where-Object{$_ -cne $entry.Id})}else{if($ids.Count -ge 200){throw '200 favoris de requête au maximum.'};$ids+=@([string]$entry.Id)}
    $previous=[string](Get-DomeniaSetting 'Search.QueryFavorites' '[]')
    try{Set-DomeniaSetting 'Search.QueryFavorites' (ConvertTo-Json -InputObject @($ids) -Compress);Save-DomeniaSettings -Immediate -ThrowOnFailure}
    catch{Set-DomeniaSetting 'Search.QueryFavorites' $previous;throw}
    Update-DomeniaWorkViewList
}
function Reset-DomeniaSearchQueryFilters {
    # Replacing the query resets every list-level intersection, including a previous frozen GUID selection.
    $wasSuppressed=$script:SuppressBranchAutoLoad;$script:SuppressBranchAutoLoad=$true
    try{
        Stop-DomeniaPendingFilterChange
        $script:CurrentPresenceFilter='Tous'
        foreach($name in @('CmbPresenceFilter','CmbGlobalType')){$control=Get-DomeniaControl $name;if($null -ne $control){$control.SelectedIndex=0}}
        foreach($name in @('TxtSuiteResultFilter','TxtBranchSearch')){$control=Get-DomeniaControl $name;if($null -ne $control){$control.Text=''}}
        if($null -ne $script:DomeniaQueryState){$script:DomeniaQueryState.SearchRecipe=$null;$script:DomeniaQueryState.SearchRefinement=$null;$script:DomeniaQueryState.SearchRecords=@{}}
        Stop-DomeniaPendingFilterChange
    }finally{$script:SuppressBranchAutoLoad=$wasSuppressed}
    [void](Set-DomeniaControlText 'LblSearchQuery' 'Aucun filtre de requête supplémentaire.')
}
function Clear-DomeniaSearchQuery {
    $queryList=[bool][string]$script:ActiveSearchViewId
    if($queryList){Invalidate-DomeniaSearchResults;$script:ActiveSearchViewId='';$script:ListSurveyBlocked=$false}
    $script:SearchQueryRun=$null
    if($null -ne $script:DomeniaQueryState){$script:DomeniaQueryState.SearchRecipe=$null;$script:DomeniaQueryState.SearchRefinement=$null;$script:DomeniaQueryState.SearchRecords=@{}}
    if(-not $queryList){Apply-DomeniaPresenceFilter}
    $choice=Get-DomeniaControl 'CmbWorkView';if($null -ne $choice){$choice.SelectedIndex=-1}
    [void](Set-DomeniaControlText 'LblSearchQuery' 'Aucune requête appliquée. Choisissez une requête puis Exécuter ; aucune recherche automatique.')
    if($queryList){[void](Set-DomeniaControlText 'LblSearchHint' 'Requête annulée ou retirée ; ses résultats ont été effacés.');Update-DomeniaSearchMoreButton -Search $null}
    Update-DomeniaSearchQueryDetails
}
function Open-DomeniaSearchQueryWorkshop {
    $entry=(Get-DomeniaControl 'CmbWorkView').SelectedItem
    Show-DomeniaQueryWorkshop
    if($null -ne $entry -and $entry.SourceId -eq 'Local'){Set-DomeniaQueryDraft $entry.Recipe;(Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryCompose'}
    elseif($null -ne $entry){[void](Set-DomeniaControlText 'LblQueryStatus' 'Cette requête Annuaire conserve son filtre LDAP dédié. Le compositeur crée les requêtes locales sur les postes.');(Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryLibrary'}
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
        $text = 'Requêtes · ' + $name
        $moved = ([string]$script:WorkViewScopeOu -ine [string]$Scope.BaseDn)
        $script:WorkViewScopeOu = [string]$Scope.BaseDn
        if ([string]$first.Content -cne $text -or ($moved -and $combo.SelectedIndex -ne 0)) {
            $first.Content = $text
            $first.ToolTip = 'Exécute la requête dans ' + $name + ' (' + [string]$Scope.BaseDn + ').'
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
    Update-DomeniaSearchQueryDetails
}

function Invoke-DomeniaWorkView {
    # D038: explicit gesture only. The view carries a filter and a type: never an account, a right or a write mode.
    param([string]$ViewId='')
    if (-not $ViewId) {
        $combo = Get-DomeniaControl 'CmbWorkView'
        if ($null -ne $combo -and $null -ne $combo.SelectedItem) { $ViewId = [string]$combo.SelectedItem.Tag }
    }
    if (-not $ViewId) { Set-Status 'Choisissez dʼabord une requête dans la liste.' 'WARN'; return }
    if($ViewId.StartsWith('local:',[StringComparison]::Ordinal)){
        $entry=@($script:SearchQueryCatalog|Where-Object{$_.Id -ceq $ViewId}|Select-Object -First 1)
        if(-not $entry.Count){throw 'Cette requête locale nʼest plus disponible.'}
        Start-DomeniaSearchLocalQuery -Entry $entry[0]
        return
    }
    if($ViewId.StartsWith('ad:',[StringComparison]::Ordinal)){$ViewId=$ViewId.Substring(3)}
    if(-not @(Get-DomeniaWorkViews|Where-Object{$_.Id -ceq $ViewId}).Count){throw 'Requête Annuaire inconnue.'}
    Reset-DomeniaSearchQueryFilters
    $script:SearchQueryRun=$null
    Invoke-GlobalSearch -ViewId $ViewId -ViewScope OU
}

function Test-DomeniaSearchLocalQueryCurrent {
    param($State)
    if($null -eq $State -or $null -eq $script:SearchQueryRun -or -not [object]::ReferenceEquals($State,$script:SearchQueryRun)){return $false}
    if([long]$State.Epoch -ne [long]$script:SessionEpoch -or [int]$State.Generation -ne [int]$script:GlobalSearchGeneration -or [string]$State.Path -cne [string]$script:DatabaseScopedPath){return $false}
    $scope=Get-DomeniaSearchScope -Mode OU
    return ((Get-DomeniaSearchMode) -eq 'OU' -and [string]$State.BaseDn -ieq [string]$scope.BaseDn -and [string]$State.Scope -eq [string]$scope.Scope -and [string]$script:ActiveSearchViewId -ceq [string]$State.Id -and -not (Get-DomeniaSearchText -Mode OU))
}
function Start-DomeniaSearchLocalQuery {
    param($Entry,[ValidateSet('','Match','Unknown','NoMatch')][string]$SelectionOverride='',[int]$LimitOverride=0)
    if(Test-DomeniaAccessBusyWrite){Set-Status 'Requête différée : écriture active ou à vérifier.' 'WARN';return}
    if(-not (Test-DomeniaDraftNavigation -DN '')){return}
    $path=[string]$script:DatabaseScopedPath;$scope=Get-DomeniaSearchScope -Mode OU
    if(-not $path){throw 'Aucune base locale active. Actualisez dʼabord lʼOU dans Base de données.'}
    if(-not [string]$script:SelectedBranchDn -or -not [string]$scope.BaseDn){throw 'Choisissez une OU dans lʼarbre de Recherche.'}
    [void](ConvertTo-DomeniaCompiledQuery $Entry.Recipe)
    $limit=100;$control=Get-DomeniaControl 'TxtGlobalLimit';if($null -ne $control){[void][int]::TryParse([string]$control.Text,[ref]$limit)};$limit=[Math]::Max(1,[Math]::Min(20000,$limit))
    $selection=[string](Get-DomeniaControl 'CmbSearchQueryResult').SelectedItem.Tag;if($selection -notin @('Match','Unknown','NoMatch')){$selection='Match'}
    if($SelectionOverride){$selection=$SelectionOverride}
    if($LimitOverride -gt 0){$limit=[Math]::Min(20000,$LimitOverride)}
    Enter-DomeniaNavSearch
    try{
    Reset-DomeniaSearchQueryFilters
    Invalidate-DomeniaSearchResults
    Set-DomeniaSearchMode -Mode OU
    $script:ActiveSearchViewId=[string]$Entry.Id;$script:ListSurveyBlocked=([string]$scope.BaseDn -ieq [string]$script:Conn.BaseDn)
    $state=[pscustomobject]@{Id=$Entry.Id;Name=$Entry.Name;Recipe=$Entry.Recipe;Epoch=[long]$script:SessionEpoch;Generation=[int]$script:GlobalSearchGeneration;Path=$path;BaseDn=[string]$scope.BaseDn;Scope=[string]$scope.Scope;Selection=$selection;Limit=$limit;Coverage=(Get-DomeniaSearchQueryCoverageText ([string]$scope.BaseDn));Job=''}
    $script:SearchQueryRun=$state
    [void](Set-DomeniaControlText 'LblSearchQuery' ('Lecture locale : '+$state.Name+' · '+$state.BaseDn+' · '+$state.Coverage))
    Update-DomeniaSearchMoreButton -Search $null
    [void](Initialize-DomeniaWinSqliteNative)
    $payload=[pscustomobject]@{Action='FleetStats';Path=$path;BusyTimeoutMs=250;Scope=$state.BaseDn;Subtree=($state.Scope -eq 'Subtree');Plan=(Get-DomeniaFleetQueryPlan -ObservationMaxAgeDays (Get-DomeniaObservationMaxAgeDays));Keys=@();ScopeKey='';ComputeBoard=$false;ModuleRoot=$script:SearchQueryModuleRoot}
    $state.Job=Start-UiTask -Name 'Requête : lecture de la base locale' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'global' -SuccessHandler 'Complete-DomeniaSearchLocalRead' -ErrorHandler 'Fail-DomeniaSearchLocalQuery' -TimeoutSeconds 120 -TaskClass Explicit
    if(-not $state.Job){Fail-DomeniaSearchLocalQuery 'Lecture non admise, réessayez.' $state}
    }catch{Fail-DomeniaSearchLocalQuery $_.Exception.Message $state}
    finally{Exit-DomeniaNavSearch}
}
function Complete-DomeniaSearchLocalRead {
    param($Result,$State)
    if(-not (Test-DomeniaSearchLocalQueryCurrent $State)){return}
    try{
        $data=Get-DomeniaEffectiveWorkerResult $Result @('Busy','Missing')
        if($null -eq $data){throw 'Réponse locale incomplète.'}
        if($data.Busy){throw 'Base occupée ; réexécutez dans un instant.'}
        if($data.Missing){throw 'Base locale absente. Actualisez lʼOU dans Base de données.'}
        if($null -eq $data.PSObject.Properties['Machines'] -or $null -eq $data.PSObject.Properties['Groups'] -or [string]$data.Scope -ine [string]$State.BaseDn -or [bool]$data.Subtree -ne ($State.Scope -eq 'Subtree')){throw 'Le résultat ne correspond pas au périmètre demandé.'}
        $payload=[pscustomobject]@{ModuleRoot=$script:SearchQueryModuleRoot;Lifecycle=(Get-DomeniaWindowsLifecycleTable);Fleet=$data;Observations=@{};Records=$null;Recipe=$State.Recipe;Saved=@();SortField='name';Descending=$false;Offset=0;Selection=$State.Selection;MaxAgeDays=(Get-DomeniaObservationMaxAgeDays);TextFilter='';StateFilter='';SearchOutput=$true;Limit=$State.Limit}
        $State.Job=Start-UiTask -Name 'Requête : évaluation locale' -OperationId 'LocalQuery' -Code (Get-DomeniaQueryWorkerCode) -Payload $payload -CallbackState $State -ReplaceKey 'branch' -SuccessHandler 'Complete-DomeniaSearchLocalQuery' -ErrorHandler 'Fail-DomeniaSearchLocalQuery' -TimeoutSeconds 120 -TaskClass Explicit
        if(-not $State.Job){throw 'Calcul non admis, réexécutez la requête.'}
    }catch{Fail-DomeniaSearchLocalQuery $_.Exception.Message $State}
}
function Complete-DomeniaSearchLocalQuery {
    param($Result,$State)
    if(-not (Test-DomeniaSearchLocalQueryCurrent $State)){return}
    $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Matched','Unknown','NotMatched','ScopeTotal','Selection')
    if($null -eq $data -or [string]$data.Scope -ine [string]$State.BaseDn -or [bool]$data.Subtree -ne ($State.Scope -eq 'Subtree')){Fail-DomeniaSearchLocalQuery 'Résultat local incomplet ou hors périmètre.' $State;return}
    $total=switch([string]$State.Selection){'Unknown'{[long]$data.Unknown};'NoMatch'{[long]$data.NotMatched};default{[long]$data.Matched}}
    $selectionLabel=switch([string]$State.Selection){'Unknown'{'Inconnus'};'NoMatch'{'Non correspondants'};default{'Correspondants'}}
    $label=$selectionLabel+' : '+('{0} affiché(s) sur {1} dans cette sélection · {2} correspondants, {3} inconnus, {4} non correspondants / {5} postes recensés' -f @($data.Rows).Count,$total,$data.Matched,$data.Unknown,$data.NotMatched,$data.ScopeTotal)
    if($total -gt @($data.Rows).Count){$label+=' · limite '+$State.Limit+' : augmentez la limite puis réexécutez'}
    $State.Job=''
    Show-ObjectRows -Rows @($data.Rows) -Label $label -SkipPresenceScan -NoAutoOpen
    Update-DomeniaSearchMoreButton -Search $null
    $depth=if($State.Scope -eq 'Subtree'){'sous-OU incluses'}else{'niveau direct'}
    [void](Set-DomeniaControlText 'LblSearchQuery' ($State.Name+' · '+$selectionLabel+' · '+$State.BaseDn+' · '+$depth+' · calcul local du '+([datetime]$data.AtUtc).ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')+'. '+$State.Coverage))
    [void](Set-DomeniaControlText 'LblSearchHint' 'Résultats locaux : aucune lecture AD, aucun ping ni relevé lancé. Les informations manquantes restent inconnues.')
    Set-Status $label
}
function Fail-DomeniaSearchLocalQuery {
    param($Message,$State)
    if(-not (Test-DomeniaSearchLocalQueryCurrent $State)){return}
    $State.Job=''
    $script:SearchQueryRun=$null
    [void](Set-DomeniaControlText 'LblSearchQuery' ('Requête locale non terminée : '+[string]$Message))
    Set-Status ('Requête locale non terminée : '+[string]$Message) 'WARN'
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
    # FO-05: the chip and the type of the bar that produced a global list.
    $barScope = [string]$script:SearchBarScope
    $barType = [string]$script:SearchBarType
    # FO-01: a « contains » list is another place than the prefix list of the same text.
    $matchMode = ''
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
        $matchMode = [string](Get-DomeniaMember $listState 'MatchMode' '')
        if ($mode -eq 'Global') {
            $barScope = [string](Get-DomeniaMember $listState 'BarScope' $barScope)
            $barType = [string](Get-DomeniaMember $listState 'BarType' $barType)
            if ($barScope -eq 'Ou') { $ouDn = [string]$listState.BaseDn }
        }
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
        $barScope = [string](Get-DomeniaMember $historyState 'BarScope' $barScope)
        $barType = [string](Get-DomeniaMember $historyState 'BarType' $barType)
        $matchMode = [string](Get-DomeniaMember $historyState 'MatchMode' '')
    }
    if (-not $viewChoice) { $viewChoice = $(if ($viewId -and $mode -eq 'Global') { 'Domain' } else { 'OU' }) }
    $inner = '';$innerControl=''
    if ($Page -eq 'WsObject') {
        $detail = Get-DomeniaControl 'DetailTabs'
        try { if ($null -ne $detail -and $null -ne $detail.SelectedItem) { $inner = [string]$detail.SelectedItem.Name;$innerControl='DetailTabs' } } catch { }
    }
    if($Page -eq 'TabApplicationTools'){$detail=Get-DomeniaControl 'ApplicationToolTabs';if($null -ne $detail -and $null -ne $detail.SelectedItem){$inner=[string]$detail.SelectedItem.Name;$innerControl='ApplicationToolTabs'}}
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
    $localQuery=$null
    if($viewId -like 'local:*'){
        if($null -ne $historyState){$localQuery=Get-DomeniaMemberValue $historyState 'LocalQuery'}
        elseif($null -ne $script:SearchQueryRun -and $script:SearchQueryRun.Id -ceq $viewId){$run=$script:SearchQueryRun;$localQuery=[pscustomobject]@{Id=$run.Id;Name=$run.Name;Recipe=$run.Recipe;Selection=$run.Selection;Limit=$run.Limit}}
    }
    return [pscustomobject]@{
        Page=$Page;Tab=$inner;InnerControl=$innerControl;Mode=$mode;Text=$text;BranchText=$branchText;OuDn=$ouDn;Subtree=$subtree
        SelectionGuid=$selectionGuid;SelectionDn=$selectionDn;Rows=$rows;Scroll=$scroll
        CountLabel=$(if ($null -ne $count) { [string]$count.Text } else { '' })
        Generation=[int]$script:GlobalSearchGeneration;ViewId=$viewId
        TypeLabel=$typeLabel;Presence=$presence;LocalFilter=$localFilter;BarScope=$barScope;BarType=$barType;MatchMode=$matchMode
        SurveyBlocked=$surveyBlocked;ViewChoice=$viewChoice
        LocalQuery=$localQuery;QuerySelection=[string](Get-DomeniaMember $localQuery 'Selection');QueryLabel=[string](Get-DomeniaControl 'LblSearchQuery').Text
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
        # FO-05: the chip and the type of the bar come back with the place (checked again by Update-DomeniaSearchBarUi).
        $rememberedScope = [string](Get-DomeniaMember $State 'BarScope' '')
        if ($rememberedScope) { $script:SearchBarScope = $(if ($rememberedScope -eq 'Ou') { 'Ou' } else { 'Everywhere' }) }
        $rememberedType = [string](Get-DomeniaMember $State 'BarType' '')
        if ($rememberedType -in @('Tous','Utilisateurs','Machines','Groupes')) { $script:SearchBarType = $rememberedType }
        $script:ActiveSearchViewId = [string]$State.ViewId
        $script:SearchQueryRun=$null
        [void](Set-DomeniaControlText 'LblSearchQuery' ([string](Get-DomeniaMember $State 'QueryLabel' 'Aucune requête locale appliquée.')))
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
        if ([string]$State.Tab) { $inner = [string](Get-DomeniaMember $State 'InnerControl' 'DetailTabs');if(-not $inner){$inner='DetailTabs'} }
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
    if($viewId -like 'local:*'){
        $query=Get-DomeniaMemberValue $script:NavHistoryState 'LocalQuery'
        if($null -eq $query){Set-Status 'La définition de cette requête locale nʼest plus disponible. Choisissez-la dans Requêtes puis exécutez-la.' 'WARN';return}
        Start-DomeniaSearchLocalQuery -Entry $query -SelectionOverride ([string]$query.Selection) -LimitOverride ([int]$query.Limit)
        return
    }
    if ($viewId) {
        # The view is read again over its own perimeter (OU or whole domain), not the one the chip shows now.
        $viewScope = [string](Get-DomeniaMember $script:NavHistoryState 'ViewChoice' '')
        if ($viewScope -notin @('OU','Domain')) { $viewScope = '' }
        Invoke-GlobalSearch -ViewId $viewId -SilentError -ViewScope $viewScope -KeepLocalFilter
        return
    }
    # CO-05: the history list is read again with the filter of the list that came back with it.
    # FO-01: a « contains » list is read again as a « contains » list.
    $containsList = ([string](Get-DomeniaMember $script:NavHistoryState 'MatchMode' '') -eq 'Contains')
    Invoke-GlobalSearch -SearchMode (Get-DomeniaSearchMode) -AllowEmpty -SilentError -KeepLocalFilter -Contains:$containsList
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
        # FI-05: protected, session-bound heartbeat timer (debounce of the OU read), owned and registered by the factory.
        $script:FilterChangeTimer = New-DomeniaTimer -Owner 'Timer:FilterChange' -IntervalMs 300 -SessionBound -Tick { Invoke-DomeniaPendingFilterChange }
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
    # Work in small Dispatcher slices even when thousands of nodes have already been read.
    param([switch]$OnlyWhenActive)
    $box=Get-DomeniaControl 'TxtOuFilter';$filter=([string]$box.Text).Trim()
    if($OnlyWhenActive -and -not $filter){return}
    $tree=Get-DomeniaControl 'TvDirectory';if($null -eq $tree){return}
    Stop-DomeniaOuTreeFilter
    $stack=[Collections.Generic.List[object]]::new()
    $stack.Add([pscustomobject]@{Node=$null;Items=$tree.Items;Next=0;ChildMatch=$false;IsRoot=$false})
    $script:OuTreeFilterWork=[pscustomobject]@{Tree=$tree;Stack=$stack;Filter=$filter;Epoch=[long]$script:SessionEpoch;Matched=$false}
    Invoke-DomeniaOuTreeFilterSlice
    if($null -ne $script:OuTreeFilterWork){
        if($null -eq $script:OuTreeFilterTimer){$script:OuTreeFilterTimer=New-DomeniaTimer -Owner 'Timer:OuTreeFilter' -IntervalMs 25 -Tick {Invoke-DomeniaOuTreeFilterSlice}}
        $script:OuTreeFilterTimer.Start()
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
    Initialize-DomeniaSearchQuerySelector
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
    # DS-06: the « ⋯ » menu of the result card (Actualiser, Exporter CSV, Colonnes…).
    $resultMenu = Get-DomeniaControl 'BtnSearchResultMenu'
    if ($resultMenu -is [Windows.Controls.Primitives.ButtonBase]) { $resultMenu.Add_Click({ param($sender,$eventArgs) try { [void](Open-DomeniaSearchResultMenu -Anchor $sender) } catch { Write-AppLog ('Menu de la liste : '+$_.Exception.Message) 'WARN' } }) }
    # FO-01: the « contains » chip starts its read on click only.
    $containsChip = Get-DomeniaControl 'BtnSearchContains'
    if ($containsChip -is [Windows.Controls.Primitives.ButtonBase]) { $containsChip.Add_Click({ try { Invoke-DomeniaSearchContains } catch { Write-AppLog ('Recherche « contient » : '+$_.Exception.Message) 'ERROR'; Set-Status ('Recherche non lancée : '+$_.Exception.Message) 'ERROR' } }) }
    # MO-07: « Charger jusquʼà 1 000 » reads the missing rows in one explicit gesture.
    $jump = Get-DomeniaControl 'BtnSearchMoreJump'
    if ($jump -is [Windows.Controls.Primitives.ButtonBase]) { $jump.Add_Click({ try { Invoke-DomeniaSearchMore -Step Jump } catch { Write-AppLog ('Charger jusquʼà : '+$_.Exception.Message) 'ERROR'; Set-Status ('Suite non chargée : '+$_.Exception.Message) 'ERROR' } }) }
    $back = Get-DomeniaControl 'BtnNavBack'
    if ($back -is [Windows.Controls.Primitives.ButtonBase]) { $back.Add_Click({ try { [void](Invoke-DomeniaNavStep -Direction Back) } catch { Write-AppLog ('Navigation précédente : '+$_.Exception.Message) 'WARN' } }) }
    $forward = Get-DomeniaControl 'BtnNavForward'
    if ($forward -is [Windows.Controls.Primitives.ButtonBase]) { $forward.Add_Click({ try { [void](Invoke-DomeniaNavStep -Direction Forward) } catch { Write-AppLog ('Navigation suivante : '+$_.Exception.Message) 'WARN' } }) }
    $box = Get-DomeniaControl 'TxtGlobalSearch'
    if ($box -is [Windows.Controls.TextBox]) { $box.Add_TextChanged({ try { Update-DomeniaSearchHint } catch { } }) }
    # FO-05: the chip and the type of the bar are explicit choices; they never start a read.
    $barScope = Get-DomeniaControl 'LstSearchBarScope'
    if ($barScope -is [Windows.Controls.ListBox]) { $barScope.Add_SelectionChanged({ param($sender,$eventArgs) $item = $sender.SelectedItem; if ($null -ne $item) { try { Set-DomeniaSearchBarChoice -Kind Scope -Value ([string]$item.Tag) } catch { Write-AppLog ('Puce de la recherche : '+$_.Exception.Message) 'WARN' } } }) }
    $barType = Get-DomeniaControl 'LstSearchBarType'
    if ($barType -is [Windows.Controls.ListBox]) { $barType.Add_SelectionChanged({ param($sender,$eventArgs) $item = $sender.SelectedItem; if ($null -ne $item) { try { Set-DomeniaSearchBarChoice -Kind Type -Value ([string]$item.Tag) } catch { Write-AppLog ('Type de la recherche : '+$_.Exception.Message) 'WARN' } } }) }
    try { Update-DomeniaSearchBarUi } catch { Write-AppLog ('Puce de la recherche : '+$_.Exception.Message) 'WARN' }
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
        $script:Window.Add_Closed({ $script:SearchUiInitialized = $false; $script:SearchQuerySelectorBound=$false; $script:SearchQueryRun=$null; $script:NavHistory = $null; $script:NavRestoring = $false; $script:NavHistoryRows = $null; $script:NavHistoryState = $null; $script:NavListShape = $null; Stop-DomeniaPendingFilterChange })
    }
    Update-DomeniaNavButtons
    Update-DomeniaSearchHint
}

function Update-DomeniaOuBreadcrumb {
    param([string]$Dn)
    $panel=Get-DomeniaControl 'PnlOuBreadcrumb'
    if($null -eq $panel){return}
    $key=[string]$script:SessionEpoch+'|'+[string]$script:Conn.BaseDn+'|'+$Dn
    if([string]$panel.Tag -ceq $key){return}
    $panel.Tag=$key;$panel.Children.Clear()
    $path=Get-DomeniaTreeRevealPath -Dn $Dn -BaseDn ([string]$script:Conn.BaseDn)
    for($index=0;$index -lt $path.Count;$index++){
        $current=[string]$path[$index]
        $display=Get-DomeniaUxOuDisplay -DistinguishedName $current -IsDomain ($index -eq 0)
        if($index){$separator=[Windows.Controls.TextBlock]::new();$separator.Text='›';$separator.Margin=[Windows.Thickness]::new(3,2,3,2);$separator.VerticalAlignment='Center';[void]$panel.Children.Add($separator)}
        $label=[Windows.Controls.TextBlock]::new();$label.Text=$(if($index -eq 0){$display.FullPath}else{$display.Name});$label.TextTrimming='CharacterEllipsis';$label.MaxWidth=220;$label.ToolTip=$display.FullPath
        if($index -eq 0 -or $index -eq $path.Count-1){
            # The domain is context text, never a whole-domain collection shortcut.
            $label.Margin=[Windows.Thickness]::new(3,4,3,4)
            if($index -eq $path.Count-1){$label.FontWeight='SemiBold'}
            [void]$panel.Children.Add($label)
        }else{
            $button=[Windows.Controls.Button]::new();$button.Content=$label;$button.Padding=[Windows.Thickness]::new(5,2,5,2);$button.Margin=[Windows.Thickness]::new(0,0,0,0);$button.MinWidth=0;$button.MinHeight=26
            $button.Tag=[pscustomobject]@{DN=$current;BaseDn=[string]$script:Conn.BaseDn;Epoch=[long]$script:SessionEpoch}
            [Windows.Automation.AutomationProperties]::SetName($button,'Ouvrir la branche '+$display.FullPath)
            $button.Add_Click({param($sender,$eventArgs) try{Open-DomeniaOuBreadcrumb -Target $sender.Tag}catch{Set-Status ('Navigation : '+$_.Exception.Message) 'WARN'}})
            [void]$panel.Children.Add($button)
        }
    }
    if($path.Count){
        $copy=[Windows.Controls.Button]::new();$copy.Content='Copier le chemin';$copy.Padding=[Windows.Thickness]::new(6,2,6,2);$copy.Margin=[Windows.Thickness]::new(10,0,0,0);$copy.MinHeight=26;$copy.MinWidth=0
        $copy.Add_Click({Copy-DomeniaUxOuPath});[void]$panel.Children.Add($copy)
    }
}
function Open-DomeniaOuBreadcrumb {
    param($Target)
    if($null -eq $Target -or [long]$Target.Epoch -ne [long]$script:SessionEpoch -or [string]$Target.BaseDn -ine [string]$script:Conn.BaseDn){return}
    $path=Get-DomeniaTreeRevealPath -Dn ([string]$Target.DN) -BaseDn ([string]$script:Conn.BaseDn)
    if($path.Count -lt 2 -or [string]$Target.DN -ieq [string]$script:SelectedBranchDn){return}
    if(Test-DomeniaAccessBusyWrite){Set-Status 'Navigation en attente : une opération sur lʼannuaire est active.' 'WARN';return}
    if(-not (Test-DomeniaDraftNavigation '')){return}
    Enter-DomeniaNavSearch
    try{
        Stop-DomeniaPendingFilterChange
        $script:SelectedBranchDn=[string]$Target.DN
        [void](Set-DomeniaControlText 'TxtBranchSearch' '')
        Set-DomeniaSearchMode -Mode OU
        Update-DomeniaSearchScopeUi
        Invoke-GlobalSearch -SearchMode OU
        Start-DomeniaFavouriteTreeReveal -Dn ([string]$Target.DN)
    }finally{Exit-DomeniaNavSearch}
}
function Stop-DomeniaOuTreeFilter {
    if($null -ne $script:OuTreeFilterTimer){$script:OuTreeFilterTimer.Stop()}
    $script:OuTreeFilterWork=$null
}
function Invoke-DomeniaOuTreeFilterSlice {
    $state=$script:OuTreeFilterWork
    if($null -eq $state){return}
    $tree=Get-DomeniaControl 'TvDirectory'
    $box=Get-DomeniaControl 'TxtOuFilter'
    if($script:AsyncEngineClosing -or [long]$state.Epoch -ne [long]$script:SessionEpoch -or -not [object]::ReferenceEquals($tree,$state.Tree) -or [string]$state.Filter -cne ([string]$box.Text).Trim()){Stop-DomeniaOuTreeFilter;return}
    $clock=[Diagnostics.Stopwatch]::StartNew();$steps=0
    while($state.Stack.Count -and $steps -lt 512 -and $clock.ElapsedMilliseconds -lt 8){
        $steps++;$frame=$state.Stack[$state.Stack.Count-1]
        if($frame.Next -lt $frame.Items.Count){
            $child=$frame.Items[$frame.Next];$frame.Next++
            if($child -isnot [Windows.Controls.TreeViewItem]){continue}
            $state.Stack.Add([pscustomobject]@{Node=$child;Items=$child.Items;Next=0;ChildMatch=$false;IsRoot=($null -eq $frame.Node)})
            continue
        }
        $state.Stack.RemoveAt($state.Stack.Count-1)
        if($null -eq $frame.Node){$state.Matched=[bool]$frame.ChildMatch;continue}
        $self=Test-DomeniaOuTreeMatch -Name (Get-DomeniaOuTreeNodeName $frame.Node) -Filter $state.Filter
        $match=($self -or $frame.ChildMatch)
        $wanted=if($frame.IsRoot -or -not $state.Filter -or $match){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
        if($frame.Node.Visibility -ne $wanted){$frame.Node.Visibility=$wanted}
        if($state.Filter -and $frame.ChildMatch -and [bool]$frame.Node.Tag.Loaded -and -not $frame.Node.IsExpanded){$frame.Node.IsExpanded=$true}
        if($match -and $state.Stack.Count){$state.Stack[$state.Stack.Count-1].ChildMatch=$true}
    }
    if($state.Stack.Count){return}
    if($state.Filter){
        $message=if($state.Matched){'Filtre des OU : '+$state.Filter+' · branches déjà lues seulement'}else{'Aucune branche lue ne contient '+$state.Filter+' : dépliez une OU pour la parcourir.'}
        [void](Set-DomeniaControlText 'LblTreeStatus' $message);$script:OuTreeFilterStatus=$message
    }elseif($script:OuTreeFilterStatus){
        [void](Set-DomeniaControlText 'LblTreeStatus' 'Filtre effacé : toutes les branches lues sont affichées.');$script:OuTreeFilterStatus=''
    }
    Stop-DomeniaOuTreeFilter
}
