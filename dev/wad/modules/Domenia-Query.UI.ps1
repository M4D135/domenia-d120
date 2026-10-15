# Shared query workshop. Expensive record preparation and evaluation run in LocalQuery, never in an input event.
$script:DomeniaQueryModuleRoot=$PSScriptRoot
$script:DomeniaQueryState=$null
function Initialize-DomeniaQueryView {
    $hostControl=Get-DomeniaControl 'QueryWorkshopHost'
    if($null -eq $hostControl -or $null -ne $hostControl.Content){return}
    [xml]$document=[IO.File]::ReadAllText((Join-Path $script:DomeniaQueryModuleRoot 'Domenia-Query.xaml'),[Text.Encoding]::UTF8)
    $reader=New-Object Xml.XmlNodeReader $document
    try{$view=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $controls=@{}
    foreach($element in $document.SelectNodes('//*')){
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if(-not $name){continue}
        if($script:Ctrl.ContainsKey($name)){throw ('Nom de contrôle déjà présent : '+$name)}
        $control=if($name -eq [string]$view.Name){$view}else{$view.FindName($name)}
        if($null -eq $control){throw ('Contrôle atelier introuvable : '+$name)}
        $controls[$name]=$control
    }
    foreach($name in $controls.Keys){$script:Ctrl[$name]=$controls[$name]}
    # Re-entering Tools can reveal the same selected inner tab without any SelectionChanged event.
    # Refresh presentation only; scope ownership, navigation origin and evaluation remain untouched.
    $refreshScope=${function:Update-DomeniaQueryScopeLabel};$queryView=$view
    $view.Add_IsVisibleChanged({param($sender,$eventArgs)
        if($queryView.IsVisible){& $refreshScope}
    }.GetNewClosure())
    $hostControl.Content=$view
    # Point 54: the Atelier chooses its OU with the same shared picker as the tableau de bord (same scope).
    $scopeButton=Get-DomeniaControl 'BtnQueryScope'
    if($null -ne $scopeButton){$scopeButton.Add_Click({try{Show-DomeniaFleetScopeSource;Update-DomeniaQueryScopeLabel}catch{Set-Status ('Sélecteur dʼOU indisponible : '+$_.Exception.Message) 'WARN'}})}
    # Newly attached controls must receive the current compact/zoom layout even if the viewport did not change.
    $script:UxLayoutSignature=''
    if($null -ne (Get-Command Update-DomeniaUxLayout -CommandType Function -ErrorAction SilentlyContinue)){Update-DomeniaUxLayout}
    (Get-DomeniaControl 'BtnQueryBack').Add_Click({
        $route=[string]$script:DomeniaQueryReturnRoute
        if(-not $route){$route='TabDashboard'}
        Select-DomeniaWorkspace -Workspace $route -Inner ([string]$script:DomeniaQueryReturnInner) -Tab ([string]$script:DomeniaQueryReturnTab)
        $focus=$script:DomeniaQueryReturnFocus
        if($null -ne $focus -and $focus.IsVisible -and $focus.IsEnabled){[void]$focus.Focus()}
    })
}
function Update-DomeniaQueryScopeLabel {
    # The workshop evaluates Fleetʼs explicit scope, independently of the OU used by Search.
    $scope=Get-DomeniaFleetScope
    $text=if($null -eq $scope){'Périmètre du tableau de bord : connectez-vous puis choisissez une OU.'}elseif(-not [string]$scope.Dn){'Périmètre du tableau de bord : tout le domaine indexé (consultation).'}else{'Périmètre du tableau de bord : '+[string]$scope.Name+' · '+[string]$scope.Path+$(if([bool]$scope.Subtree){' · sous-OU incluses'}else{' · sans les sous-OU'})}
    [void](Set-DomeniaControlText 'LblQueryScope' $text)
}
function Show-DomeniaQueryWorkshop {
    param([switch]$Evaluate)
    Initialize-DomeniaQueryWorkshop
    $tabs=Get-DomeniaControl 'WorkspaceTabs'
    $tools=Get-DomeniaControl 'ApplicationToolTabs'
    $inWorkshop=($null -ne $tabs -and [string]$tabs.SelectedItem.Name -eq 'TabApplicationTools' -and $null -ne $tools -and [string]$tools.SelectedItem.Name -eq 'WsQueryWorkshop')
    if($null -ne $tabs -and $null -ne $tabs.SelectedItem -and -not $inWorkshop){
        $script:DomeniaQueryReturnRoute=[string]$tabs.SelectedItem.Name
        $script:DomeniaQueryReturnInner='';$script:DomeniaQueryReturnTab=''
        if($script:DomeniaQueryReturnRoute -eq 'TabApplicationTools' -and $null -ne $tools -and $null -ne $tools.SelectedItem){$script:DomeniaQueryReturnInner='ApplicationToolTabs';$script:DomeniaQueryReturnTab=[string]$tools.SelectedItem.Name}
        $script:DomeniaQueryReturnFocus=[Windows.Input.Keyboard]::FocusedElement
    }
    Update-DomeniaQueryScopeLabel
    if(-not $inWorkshop){
        $wasNavigating=$script:DomeniaQueryNavigating;$script:DomeniaQueryNavigating=$true
        try{Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'WsQueryWorkshop'}finally{$script:DomeniaQueryNavigating=$wasNavigating}
    }
    if($Evaluate){$inner=Get-DomeniaControl 'QueryWorkspaceTabs';if($null -ne $inner){$inner.SelectedItem=Get-DomeniaControl 'TabQueryResults'};Start-DomeniaQueryEvaluation}
    $back=Get-DomeniaControl 'BtnQueryBack'
    if($null -ne $back){[void]$back.Focus()}
}
function Initialize-DomeniaQueryWorkshop {
    Initialize-DomeniaQueryView
    if($null -ne $script:DomeniaQueryState){[void](Initialize-DomeniaQueryLibraryStore);return}
    $saved=@(Get-DomeniaSavedQueryRecipes);$store=$script:DomeniaQueryLibraryStoreState
    $errorText=if($null -eq $store -or -not $store.Loaded){'Bibliothèque locale en attente de lecture confirmée.'}else{[string]$store.Error}
    $script:DomeniaQueryState=[pscustomobject]@{Recipe=(New-DomeniaQueryRecipe);Saved=$saved;LibraryError=$errorText;Records=$null;SnapshotKey='';At=[datetime]::MinValue;WidgetLibrary='';SortField='name';SortDescending=$false;Generation=0;Widgets=@{};Result=$null;Offset=0;Job='';Busy=$false;Timer=$null;Bound=$false;SearchRecipe=$null;SearchRefinement=$null;SearchRecords=@{};SearchUnknown=0;SearchAt=[datetime]::MinValue;SearchSnapshotKey=''}
    $script:DomeniaQueryState|Add-Member -NotePropertyName ProbeWidgets -NotePropertyValue @{}
    $script:DomeniaQueryState|Add-Member -NotePropertyName ProbeLibrary -NotePropertyValue ''
    $script:DomeniaQueryState|Add-Member -NotePropertyName GroupSummary -NotePropertyValue $null
    $script:DomeniaQueryState|Add-Member -NotePropertyName GroupOffset -NotePropertyValue 0
    $script:DomeniaQueryState|Add-Member -NotePropertyName CoherenceProposal -NotePropertyValue $null
    $script:DomeniaQueryState|Add-Member -NotePropertyName ImpactPending -NotePropertyValue $null
    $fields=Get-DomeniaControl 'CmbQueryField'
    if($null -eq $fields){return}
    $fields.ItemsSource=@(Get-DomeniaQueryFields);$fields.DisplayMemberPath='Name';$fields.SelectedIndex=0
    $fields.Add_SelectionChanged({Update-DomeniaQueryOperators})
    (Get-DomeniaControl 'CmbQueryOperator').Add_SelectionChanged({$op=(Get-DomeniaControl 'CmbQueryOperator').SelectedItem;$enabled=($null -ne $op -and [string]$op.Id -notin @('IsMissing','IsPresent'));foreach($name in @('TxtQueryValue','CmbQueryValueChoice')){(Get-DomeniaControl $name).IsEnabled=$enabled}})
    (Get-DomeniaControl 'CmbQueryValueChoice').Add_SelectionChanged({param($s,$e)if($null -ne $s.SelectedItem){(Get-DomeniaControl 'TxtQueryValue').Text=[Convert]::ToString($s.SelectedItem.Value,[Globalization.CultureInfo]::InvariantCulture)}})
    Update-DomeniaQueryOperators
    foreach($entry in @(
        @('BtnQueryNew','New'),@('BtnQueryLoad','Load'),@('BtnQuerySave','Save'),@('BtnQueryDelete','Delete'),
        @('BtnQueryAddCondition','Add'),@('BtnQueryRemoveCondition','Remove'),@('BtnQueryRun','Run'),
        @('BtnQueryWidget','Widget'),@('BtnQueryCollect','Collect'),@('BtnQueryPrevious','Previous'),@('BtnQueryNext','Next'),
        @('BtnQueryClearSegment','ClearSegment'),@('BtnQueryObjectOpen','OpenObject'),@('BtnQueryObjectCollect','CollectObject'),@('BtnQueryObjectCopy','CopyObject'),
        @('BtnQueryCoverage','Coverage'),@('BtnQueryExport','Export'),@('BtnQueryApplySearch','ApplySearch'),@('BtnQueryPreview','Run')
    )){$control=Get-DomeniaControl $entry[0];if($null -ne $control){$control.Tag=$entry[1];$control.Add_Click({param($s,$e)Invoke-DomeniaQueryAction ([string]$s.Tag)})}}
    (Get-DomeniaControl 'CmbQueryResult').Add_SelectionChanged({Request-DomeniaQueryEvaluation})
    (Get-DomeniaControl 'DgFleetMachines').Add_SelectionChanged({Show-DomeniaQueryObjectDetails})
    (Get-DomeniaControl 'DgFleetMachines').Add_MouseDoubleClick({(Get-DomeniaControl 'ExpQueryObject').IsExpanded=$true;Show-DomeniaQueryObjectDetails})
    (Get-DomeniaControl 'DgFleetMachines').Add_Sorting({param($s,$e)
        $e.Handled=$true
        $map=@{name='name';StateLabel='active';PresenceLabel='presenceBucket';OS='os';Version='version';LogonDays='logonDays';Observation='checkedDays';distinguished_name='dn'}
        $field=[string]$e.Column.SortMemberPath;if(-not $map.ContainsKey($field)){return}
        $q=$script:DomeniaQueryState;$q.SortDescending=($q.SortField -eq $map[$field] -and -not $q.SortDescending);$q.SortField=$map[$field]
        foreach($column in $s.Columns){$column.SortDirection=$null};$e.Column.SortDirection=if($q.SortDescending){[ComponentModel.ListSortDirection]::Descending}else{[ComponentModel.ListSortDirection]::Ascending}
        Request-DomeniaQueryEvaluation
    })

    $parallel=Get-DomeniaControl 'CmbCollectionConcurrency'
    if($null -ne $parallel){$parallel.ItemsSource=@(1,2,4,6,8);$parallel.SelectedItem=[int](Get-DomeniaSetting 'Collection.Concurrency' '4');if($parallel.SelectedIndex -lt 0){$parallel.SelectedIndex=2};$parallel.Add_SelectionChanged({param($s,$e)if($null -ne $s.SelectedItem){Set-DomeniaSetting 'Collection.Concurrency' ([string]$s.SelectedItem);Save-DomeniaSettings}})}
    $cache=Get-DomeniaControl 'CmbCollectionCache'
    if($null -ne $cache){$cache.ItemsSource=@([pscustomobject]@{Name='Forcer la relecture';Minutes=0},[pscustomobject]@{Name='Au plus 5 minutes';Minutes=5},[pscustomobject]@{Name='Au plus 15 minutes';Minutes=15},[pscustomobject]@{Name='Au plus 60 minutes';Minutes=60});$cache.DisplayMemberPath='Name';$minutes=[int](Get-DomeniaSetting 'Collection.CacheMinutes' '15');$cache.SelectedIndex=2;foreach($entry in $cache.ItemsSource){if($entry.Minutes -eq $minutes){$cache.SelectedItem=$entry}};$cache.Add_SelectionChanged({param($s,$e)if($null -ne $s.SelectedItem){Set-DomeniaSetting 'Collection.CacheMinutes' ([string]$s.SelectedItem.Minutes);Save-DomeniaSettings}})}
    $group=Get-DomeniaControl 'CmbQueryGroupField';if($null -ne $group){$group.ItemsSource=@(@([pscustomobject]@{Id='';Name='Compteur de postes'})+@(Get-DomeniaQueryFields));$group.DisplayMemberPath='Name';$group.SelectedIndex=0}
    Initialize-DomeniaQueryCatalog
    Initialize-DomeniaQueryAdvanced
    Initialize-DomeniaQuerySchemaUi
    Initialize-DomeniaQueryTransferUi
    (Get-DomeniaControl 'TxtQueryFieldSearch').Add_TextChanged({
        $control=Get-DomeniaControl 'CmbQueryField';$selected=[string]$control.SelectedItem.Id
        $control.ItemsSource=@(Find-DomeniaQueryCatalogEntries -Entries @($script:DomeniaQueryState.Catalog) -Text ([string](Get-DomeniaControl 'TxtQueryFieldSearch').Text))
        $control.SelectedIndex=0;foreach($field in $control.ItemsSource){if($field.Id -ceq $selected){$control.SelectedItem=$field;break}}
        Update-DomeniaQueryOperators
    })
    (Get-DomeniaControl 'BtnQueryContinueSave').Add_Click({(Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryPublish'})
    (Get-DomeniaControl 'BtnQueryRevise').Add_Click({(Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryCompose'})
    Update-DomeniaQueryOperators
    (Get-DomeniaControl 'TxtQueryLibrarySearch').Add_TextChanged({Update-DomeniaQueryLibrary})
    (Get-DomeniaControl 'CmbQueryLibraryCategory').Add_SelectionChanged({Update-DomeniaQueryLibrary})
    (Get-DomeniaControl 'CmbQueryLibrarySource').Add_SelectionChanged({Update-DomeniaQueryLibrary})
    (Get-DomeniaControl 'DgQueryLibrary').Add_SelectionChanged({Show-DomeniaQueryLibraryDetails})
    (Get-DomeniaControl 'BtnQueryLibraryUse').Add_Click({Use-DomeniaQueryLibrarySelection})
    (Get-DomeniaControl 'BtnQueryPreviewComputer').Add_Click({Show-DomeniaWorkshopComputerPreview})
    $groupFilter=Get-DomeniaControl 'TxtQueryGroupFilter';if($null -ne $groupFilter){$groupFilter.Add_TextChanged({$script:DomeniaQueryState.GroupOffset=0;Update-DomeniaQueryGroups})}
    foreach($entry in @(@('BtnQueryGroupsPrevious',-1),@('BtnQueryGroupsNext',1))){$control=Get-DomeniaControl $entry[0];if($null -ne $control){$control.Tag=$entry[1];$control.Add_Click({param($s,$e)Move-DomeniaQueryGroupPage ([int]$s.Tag)})}}
    $groupShow=Get-DomeniaControl 'BtnQueryGroupsShow';if($null -ne $groupShow){$groupShow.Add_Click({Show-DomeniaQueryGroupMachines})}
    $applyCoherence=Get-DomeniaControl 'BtnQueryApplyCoherence';if($null -ne $applyCoherence){$applyCoherence.Add_Click({Use-DomeniaQueryCoherenceProposal})}
    foreach($entry in @(@('BtnQueryImpactMigrate','Migrate'),@('BtnQueryImpactKeep','Keep'),@('BtnQueryImpactArchive','Archive'),@('BtnQueryImpactCancel','Cancel'))){$control=Get-DomeniaControl $entry[0];if($null -ne $control){$control.Tag=$entry[1];$control.Add_Click({param($s,$e)Invoke-DomeniaQueryImpactAction ([string]$s.Tag)})}}
    $groupGrid=Get-DomeniaControl 'DgQueryGroups';if($null -ne $groupGrid){$groupGrid.Add_SelectionChanged({$button=Get-DomeniaControl 'BtnQueryGroupsShow';if($null -ne $button){$button.IsEnabled=($null -ne (Get-DomeniaControl 'DgQueryGroups').SelectedItem)}});$groupGrid.Add_MouseDoubleClick({Show-DomeniaQueryGroupMachines})}
    (Get-DomeniaControl 'QueryWorkspaceTabs').Add_SelectionChanged({param($sender,$args)if([object]::ReferenceEquals($sender,$args.OriginalSource) -and [string]$sender.SelectedItem.Name -eq 'TabQueryLibrary'){Start-DomeniaQueryLibraryLoad}})
    (Get-DomeniaControl 'BtnQueryLibraryPrevious').Add_Click({$q=$script:DomeniaQueryState;$q.LibraryOffset=[Math]::Max(0,$q.LibraryOffset-100);Update-DomeniaQueryLibrary -KeepPage})
    (Get-DomeniaControl 'BtnQueryLibraryNext').Add_Click({$q=$script:DomeniaQueryState;$q.LibraryOffset+=100;Update-DomeniaQueryLibrary -KeepPage})
    $script:DomeniaQueryState.Bound=$true
    Update-DomeniaQueryLibraryControls
    Set-DomeniaQueryDraft $script:DomeniaQueryState.Recipe
    if($errorText){[void](Set-DomeniaControlText 'LblQueryStatus' $errorText)}
}
function Initialize-DomeniaQueryCatalog {
    $grid=Get-DomeniaControl 'DgQueryCatalog';if($null -eq $grid){return}
    $entries=@(Get-DomeniaQueryCatalog)
    $script:DomeniaQueryState|Add-Member -NotePropertyName Catalog -NotePropertyValue $entries -Force
    $sources=Get-DomeniaControl 'CmbQueryCatalogSource'
    $sources.ItemsSource=@([pscustomobject]@{Id='';Name='Toutes les sources'},[pscustomobject]@{Id='Ad';Name='Annuaire AD'},[pscustomobject]@{Id='Local';Name='Calcul local'},[pscustomobject]@{Id='Observation';Name='Relevé du poste'},[pscustomobject]@{Id='Probe';Name='Sonde WMI'})
    $sources.DisplayMemberPath='Name';$sources.SelectedIndex=0
    $categories=Get-DomeniaControl 'CmbQueryCatalogCategory'
    $categories.ItemsSource=@(@('Toutes les catégories')+@($entries|ForEach-Object{$_.Category}|Sort-Object -Unique -Culture 'fr-FR'));$categories.SelectedIndex=0
    (Get-DomeniaControl 'TxtQueryCatalogSearch').Add_TextChanged({Update-DomeniaQueryCatalog})
    $sources.Add_SelectionChanged({Update-DomeniaQueryCatalog});$categories.Add_SelectionChanged({Update-DomeniaQueryCatalog})
    $grid.Add_SelectionChanged({Show-DomeniaQueryCatalogDetails})
    (Get-DomeniaControl 'BtnQueryCatalogUse').Add_Click({Use-DomeniaQueryCatalogField})
    (Get-DomeniaControl 'BtnQueryBrowseCatalog').Add_Click({(Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryCatalog';[void](Get-DomeniaControl 'TxtQueryCatalogSearch').Focus()})
    Update-DomeniaQueryCatalog
}
function Update-DomeniaQueryCatalog {
    $q=$script:DomeniaQueryState;$grid=Get-DomeniaControl 'DgQueryCatalog'
    if($null -eq $q -or $null -eq $grid -or $null -eq $q.PSObject.Properties['Catalog']){return}
    $selectedId=[string](Get-DomeniaMember $grid.SelectedItem 'Id')
    $source=Get-DomeniaControl 'CmbQueryCatalogSource';$category=Get-DomeniaControl 'CmbQueryCatalogCategory'
    $categoryName=if($category.SelectedIndex -gt 0){[string]$category.SelectedItem}else{''}
    $rows=@(Find-DomeniaQueryCatalogEntries -Entries @($q.Catalog) -Text ([string](Get-DomeniaControl 'TxtQueryCatalogSearch').Text) -SourceId ([string]$source.SelectedItem.Id) -Category $categoryName)
    $grid.ItemsSource=$rows
    $selected=@($rows|Where-Object{$_.Id -ceq $selectedId}|Select-Object -First 1)
    if($selected.Count){$grid.SelectedItem=$selected[0]}elseif($rows.Count){$grid.SelectedIndex=0}
    [void](Set-DomeniaControlText 'LblQueryCatalogCount' ($rows.Count.ToString()+' information(s) sur '+@($q.Catalog).Count+' disponibles. Consultation locale, sans collecte.'))
    Show-DomeniaQueryCatalogDetails
}
function Show-DomeniaQueryCatalogDetails {
    $entry=(Get-DomeniaControl 'DgQueryCatalog').SelectedItem
    $button=Get-DomeniaControl 'BtnQueryCatalogUse';$button.IsEnabled=($null -ne $entry)
    $detail=Get-DomeniaControl 'PnlQueryCatalogDetail';$detail.Visibility=if($null -ne $entry){'Visible'}else{'Collapsed'}
    [void](Set-DomeniaControlText 'LblQueryCatalogTitle' $(if($null -ne $entry){[string]$entry.Name}else{'Aucune information ne correspond aux filtres.'}))
    if($null -eq $entry){return}
    [void](Set-DomeniaControlText 'LblQueryCatalogDescription' ([string]$entry.Description))
    [void](Set-DomeniaControlText 'LblQueryCatalogValue' ('Source : '+$entry.Source+' · '+$entry.Category+"`r`n"+'Valeur : '+$entry.TypeLabel+' · unité : '+$entry.Unit+$(if($entry.Example){"`r`n"+'Exemples / codes : '+$entry.Example}else{''})))
    [void](Set-DomeniaControlText 'LblQueryCatalogCollection' ([string]$entry.Collection))
    [void](Set-DomeniaControlText 'LblQueryCatalogAvailability' ([string]$entry.Availability+"`r`n"+$entry.Cost+"`r`n"+$entry.Freshness))
    [void](Set-DomeniaControlText 'LblQueryCatalogTechnical' ([string]$entry.Technical))
}
function Use-DomeniaQueryCatalogField {
    $entry=(Get-DomeniaControl 'DgQueryCatalog').SelectedItem;if($null -eq $entry){return}
    (Get-DomeniaControl 'TxtQueryFieldSearch').Text=''
    $fieldControl=Get-DomeniaControl 'CmbQueryField'
    $field=@($fieldControl.ItemsSource|Where-Object{[string]$_.Id -ceq [string]$entry.Id}|Select-Object -First 1)
    if(-not $field.Count){[void](Set-DomeniaControlText 'LblQueryStatus' 'Ce champ nʼest plus disponible dans le moteur de requêtes.');return}
    # Only prepare the editor. Existing conditions, saved recipe, results and collected data remain untouched.
    $fieldControl.SelectedItem=$field[0];Update-DomeniaQueryOperators
    $value=Get-DomeniaControl 'TxtQueryValue';if($value.Visibility -ne 'Collapsed'){$value.Text=''}
    (Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryCompose'
    [void](Set-DomeniaControlText 'LblQueryStatus' ('Champ préparé : '+$entry.Name+'. Choisissez la condition et la valeur, puis Ajouter. Aucune collecte lancée.'))
    $focus=if($value.Visibility -eq 'Collapsed'){Get-DomeniaControl 'CmbQueryValueChoice'}else{$value}
    [void]$focus.Focus();$focus.BringIntoView()
}
function Update-DomeniaQueryOperators {
    $field=(Get-DomeniaControl 'CmbQueryField').SelectedItem
    if($null -eq $field){[void](Set-DomeniaControlText 'LblQueryFieldHelp' 'Aucune information ne correspond à cette recherche.');(Get-DomeniaControl 'BtnQueryAddCondition').IsEnabled=$false;return}
    (Get-DomeniaControl 'BtnQueryAddCondition').IsEnabled=$true
    $combo=Get-DomeniaControl 'CmbQueryOperator';$combo.ItemsSource=@(Get-DomeniaQueryOperators $field.Kind);$combo.DisplayMemberPath='Name';$combo.SelectedIndex=0
    $catalog=@(Get-DomeniaMember $script:DomeniaQueryState 'Catalog' @());$entry=@($catalog|Where-Object{$_.Id -ceq $field.Id}|Select-Object -First 1)
    $choice=Get-DomeniaControl 'CmbQueryValueChoice';$value=Get-DomeniaControl 'TxtQueryValue'
    $choices=if($entry.Count){@($entry[0].Choices)}else{@()}
    if($null -ne $choice){$choice.ItemsSource=$choices;$choice.Visibility=if($choices.Count){'Visible'}else{'Collapsed'};$choice.SelectedIndex=if($choices.Count){0}else{-1}}
    if($null -ne $value){$value.Visibility=if($choices.Count){'Collapsed'}else{'Visible'}}
    if($entry.Count){[void](Set-DomeniaControlText 'LblQueryFieldHelp' ($entry[0].Source+' · '+$entry[0].Unit+' · '+$entry[0].Description+"`r`n"+$entry[0].Cost+"`r`n"+$entry[0].Freshness))}
}
function Update-DomeniaQueryLibraryControls {
    $q=$script:DomeniaQueryState;if($null -eq $q){return}
    # A short recent-personal list is ready immediately. The complete searchable catalog is lazy.
    $combo=Get-DomeniaControl 'CmbFleetQuery'
    if($null -ne $combo){
        $selectedId=[string]$combo.SelectedItem.Id;$recipes=@(@($q.Saved|Select-Object -Last 100))
        if($null -ne $q.Recipe -and $q.Recipe.Id -notin @($recipes.Id)){$recipes=@($q.Recipe)+$recipes}
        $combo.ItemsSource=$recipes;$combo.DisplayMemberPath='Name';$combo.SelectedIndex=0
        foreach($recipe in $recipes){if($recipe.Id -eq $selectedId){$combo.SelectedItem=$recipe;break}}
    }
    foreach($name in @('BtnQuerySave','BtnQueryDelete','BtnQueryWidget')){$c=Get-DomeniaControl $name;if($null -ne $c){$c.IsEnabled=(-not $q.LibraryError)}}
    $q|Add-Member -NotePropertyName LibraryGeneration -NotePropertyValue ([long](Get-DomeniaMember $q 'LibraryGeneration' 0)+1) -Force
    $q|Add-Member -NotePropertyName LibraryReady -NotePropertyValue $false -Force
    $q|Add-Member -NotePropertyName LibraryBusy -NotePropertyValue $false -Force
    $q|Add-Member -NotePropertyName LibraryRows -NotePropertyValue @() -Force
    $q|Add-Member -NotePropertyName LibraryOffset -NotePropertyValue 0 -Force
    $tabs=Get-DomeniaControl 'QueryWorkspaceTabs'
    if($null -ne $tabs -and [string]$tabs.SelectedItem.Name -eq 'TabQueryLibrary'){Start-DomeniaQueryLibraryLoad}
    if($script:SearchUiInitialized -and $null -ne (Get-Command Update-DomeniaWorkViewList -CommandType Function -ErrorAction SilentlyContinue)){Update-DomeniaWorkViewList}
}
function Start-DomeniaQueryLibraryLoad {
    $q=$script:DomeniaQueryState
    if($null -eq $q -or -not $q.Bound -or [bool](Get-DomeniaMember $q 'LibraryBusy' $false) -or [bool](Get-DomeniaMember $q 'LibraryReady' $false)){return}
    $q.LibraryBusy=$true;$q.LibraryGeneration++
    $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=$q.LibraryGeneration}
    [void](Set-DomeniaControlText 'LblQueryLibraryCount' 'Préparation locale de la bibliothèque…')
    try{
        $job=Start-UiTask -Name 'Préparer la bibliothèque de requêtes' -OperationId 'QueryLibrary' -Code (Get-DomeniaQueryLibraryWorkerCode) -Payload ([pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Saved=@($q.Saved)}) -CallbackState $state -ReplaceKey 'query:library' -SuccessHandler 'Complete-DomeniaQueryLibraryLoad' -ErrorHandler 'Fail-DomeniaQueryLibraryLoad' -TimeoutSeconds 120 -TaskClass 'Explicit'
        if(-not $job){throw 'Préparation non admise : revenez dans Bibliothèque.'}
    }catch{Fail-DomeniaQueryLibraryLoad $_.Exception.Message $state}
}
function Complete-DomeniaQueryLibraryLoad {
    param($Result,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne $q.LibraryGeneration){return}
    $result=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows')
    if($null -eq $result){Fail-DomeniaQueryLibraryLoad 'Bibliothèque incomplète.' $State;return}
    $q.LibraryBusy=$false;$q.LibraryReady=$true;$q.LibraryRows=@($result.Rows);$q.LibraryOffset=0
    $category=Get-DomeniaControl 'CmbQueryLibraryCategory'
    $script:DomeniaQueryLibraryRefreshing=$true
    try{
        $selectedCategory=[string]$category.SelectedItem.Id
        $category.ItemsSource=@(@([pscustomobject]@{Id='';Name='Toutes les catégories'})+@($q.LibraryRows.Category|Sort-Object -Unique -Culture 'fr-FR'|ForEach-Object{[pscustomobject]@{Id=$_;Name=$_}}));$category.DisplayMemberPath='Name';$category.SelectedIndex=0
        foreach($entry in $category.ItemsSource){if($entry.Id -eq $selectedCategory){$category.SelectedItem=$entry;break}}
    }finally{$script:DomeniaQueryLibraryRefreshing=$false}
    Update-DomeniaQueryLibrary
}
function Fail-DomeniaQueryLibraryLoad {
    param($Message,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne $q.LibraryGeneration){return}
    $q.LibraryBusy=$false
    [void](Set-DomeniaControlText 'LblQueryLibraryCount' ('Bibliothèque non chargée : '+[string]$Message))
}
function Update-DomeniaQueryLibrary {
    param([switch]$KeepPage)
    if($script:DomeniaQueryLibraryRefreshing){return}
    $q=$script:DomeniaQueryState;$grid=Get-DomeniaControl 'DgQueryLibrary';if($null -eq $q -or $null -eq $grid){return}
    if(-not [bool](Get-DomeniaMember $q 'LibraryReady' $false)){return}
    if(-not $KeepPage){$q.LibraryOffset=0}
    $source=Get-DomeniaControl 'CmbQueryLibrarySource';$category=Get-DomeniaControl 'CmbQueryLibraryCategory';$search=Get-DomeniaControl 'TxtQueryLibrarySearch'
    $selectedId=[string]$grid.SelectedItem.Id
    $rows=@(Find-DomeniaQueryCatalogEntries -Entries @($q.LibraryRows) -Text ([string]$search.Text) -SourceId ([string]$source.SelectedItem.Tag) -Category ([string]$category.SelectedItem.Id))
    if($q.LibraryOffset -ge $rows.Count){$q.LibraryOffset=[Math]::Max(0,([int][Math]::Ceiling($rows.Count/100.0)-1)*100)}
    $page=@($rows|Select-Object -Skip $q.LibraryOffset -First 100);$grid.ItemsSource=$page
    foreach($row in $page){if($row.Id -eq $selectedId){$grid.SelectedItem=$row;break}}
    (Get-DomeniaControl 'BtnQueryLibraryPrevious').IsEnabled=($q.LibraryOffset -gt 0)
    (Get-DomeniaControl 'BtnQueryLibraryNext').IsEnabled=($q.LibraryOffset+100 -lt $rows.Count)
    [void](Set-DomeniaControlText 'LblQueryLibraryCount' ($rows.Count.ToString()+' requête(s) · '+$page.Count+' affichée(s) · page '+([int]($q.LibraryOffset/100)+1)))
    Show-DomeniaQueryLibraryDetails
}
function Show-DomeniaQueryLibraryDetails {
    $row=(Get-DomeniaControl 'DgQueryLibrary').SelectedItem;$button=Get-DomeniaControl 'BtnQueryLibraryUse'
    if($null -ne $button){$button.IsEnabled=($null -ne $row)}
    if($null -eq $row){[void](Set-DomeniaControlText 'LblQueryLibraryDescription' 'Sélectionnez une requête pour consulter son usage.');[void](Set-DomeniaControlText 'LblQueryLibraryCollection' '');return}
    [void](Set-DomeniaControlText 'LblQueryLibraryDescription' ($row.Name+' — '+$row.Description))
    $collection=if($row.Plan.Remote){'Données déjà relevées, ou collecte explicite à préparer dans le compositeur. Les valeurs absentes ou expirées restent inconnues.'}else{'Calcul local sur la base AD. Actualisez lʼOU choisie si nécessaire ; aucun accès aux postes.'}
    [void](Set-DomeniaControlText 'LblQueryLibraryCollection' ($collection+' Utilisable pour le parc ou le poste sélectionné.'))
}
function Use-DomeniaQueryLibrarySelection {
    $row=(Get-DomeniaControl 'DgQueryLibrary').SelectedItem;if($null -eq $row){return}
    $source=$row.Recipe
    $recipe=New-DomeniaQueryRecipe -Id $source.Id -Name $source.Name -Junction $source.Junction -Clauses @($source.Clauses) -GroupBy ([string](Get-DomeniaMember $source 'GroupBy')) -Refinements @(Get-DomeniaMember $source 'Refinements' @()) -ProbeSelection (Get-DomeniaMemberValue $source 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $source 'ObjectIds') -Parameters @(Get-DomeniaMember $source 'Parameters' @()) -ParameterValues (Get-DomeniaMemberValue $source 'ParameterValues') -Expression (Get-DomeniaMemberValue $source 'Expression') -CoherenceHours (Get-DomeniaMemberValue $source 'CoherenceHours') -ReadDefinition (Get-DomeniaMemberValue $source 'ReadDefinition')
    Set-DomeniaQueryDraft $recipe
    (Get-DomeniaControl 'QueryWorkspaceTabs').SelectedItem=Get-DomeniaControl 'TabQueryCompose'
    [void](Set-DomeniaControlText 'LblQueryStatus' 'Requête chargée. Adaptez les conditions, puis exécutez, prévisualisez le poste ou ajoutez un widget. Aucune collecte lancée.')
}
function Reset-DomeniaQueryResults {
    # Clear counts and navigation together: an empty draft must not keep a previous page's total.
    $results=Get-DomeniaControl 'DgFleetMachines';if($null -ne $results){$results.ItemsSource=@()}
    [void](Set-DomeniaControlText 'LblFleetMachineCount' 'Aucun résultat calculé · exécutez la requête.')
    foreach($name in @('BtnQueryPrevious','BtnQueryNext','BtnQueryExport')){$button=Get-DomeniaControl $name;if($null -ne $button){$button.IsEnabled=$false}}
    foreach($detailName in @('DgQueryObjectFields','DgQueryExplanation')){$details=Get-DomeniaControl $detailName;if($null -ne $details){$details.ItemsSource=@()}}
    [void](Set-DomeniaControlText 'LblQueryObject' 'Sélectionnez un poste pour consulter ses données.')
    [void](Set-DomeniaControlText 'LblQueryPublishSummary' 'Aperçu à recalculer après modification des critères. La sauvegarde conserve la définition de la requête.')
    # A distribution belongs to one computed preview; it disappears with the counts it was computed with.
    $q=$script:DomeniaQueryState;if($null -ne $q -and $null -ne $q.PSObject.Properties['GroupSummary']){$q.GroupSummary=$null;$q.GroupOffset=0}
    Update-DomeniaQueryGroups
}
function Set-DomeniaQueryControlProperty {
    # Sets one member of a workshop control only when the control exposes it (view not loaded, inert double).
    param($Control,[string]$Name,$Value)
    if($null -eq $Control -or $null -eq $Control.PSObject.Properties[$Name]){return}
    $Control.$Name=$Value
}
function Reset-DomeniaQueryCoherence {
    $q=$script:DomeniaQueryState;if($null -ne $q -and $null -ne $q.PSObject.Properties['CoherenceProposal']){$q.CoherenceProposal=$null}
    Set-DomeniaQueryControlProperty (Get-DomeniaControl 'DgQueryCoherenceSources') 'ItemsSource' @()
    [void](Set-DomeniaControlText 'LblQueryCoherenceProposal' '')
    Set-DomeniaQueryControlProperty (Get-DomeniaControl 'BtnQueryApplyCoherence') 'IsEnabled' $false
}
function Show-DomeniaQueryCoherence {
    # Dates of each source and the proposed common window. Nothing is applied until the explicit button.
    param($Coverage)
    $q=$script:DomeniaQueryState;if($null -eq $q){return}
    $proposal=Get-DomeniaMemberValue $Coverage 'Proposal'
    $grid=Get-DomeniaControl 'DgQueryCoherenceSources';if($null -ne $grid){$grid.ItemsSource=@(Get-DomeniaMember $Coverage 'Sources' @())}
    $current=Get-DomeniaMemberValue $q.Recipe 'CoherenceHours'
    $text=[string](Get-DomeniaMember $proposal 'Text')
    $applicable=($null -ne $proposal -and [bool]$proposal.Needed -and $null -ne $proposal.Hours)
    if($applicable -and $null -ne $current -and [double]$current -eq [double]$proposal.Hours){$text+=' Cette fenêtre est déjà celle du brouillon.';$applicable=$false}
    elseif($null -ne $current){$text+=' Fenêtre actuelle du brouillon : '+(Format-DomeniaQueryHours ([double]$current))+'.'}
    $q|Add-Member -NotePropertyName CoherenceProposal -NotePropertyValue $(if($applicable){$proposal}else{$null}) -Force
    [void](Set-DomeniaControlText 'LblQueryCoherenceProposal' $text)
    $button=Get-DomeniaControl 'BtnQueryApplyCoherence';if($null -ne $button){$button.IsEnabled=$applicable}
}
function Use-DomeniaQueryCoherenceProposal {
    try{
        $q=$script:DomeniaQueryState;$proposal=Get-DomeniaMemberValue $q 'CoherenceProposal'
        if($null -eq $proposal -or $null -eq $proposal.Hours){throw 'Aucune fenêtre proposée : vérifiez dʼabord les informations disponibles.'}
        $recipe=Get-DomeniaQueryDraft;$recipe.CoherenceHours=[double]$proposal.Hours;$recipe.Format='Domenia.Query/2'
        [void](ConvertTo-DomeniaCompiledQuery $recipe)
        Set-DomeniaQueryDraft $recipe
        [void](Set-DomeniaControlText 'LblQueryStatus' ('Fenêtre commune de '+(Format-DomeniaQueryHours ([double]$proposal.Hours))+' appliquée au brouillon : une date absente ou un écart plus grand donne Inconnu. Relancez lʼaperçu ; rien nʼest enregistré ni collecté.'))
    }catch{[void](Set-DomeniaControlText 'LblQueryStatus' ('Fenêtre non appliquée : '+$_.Exception.Message))}
}
function Get-DomeniaQueryDraftImpact {
    # Consumers to review before a saved definition changes or is archived; $null when nothing depends on it,
    # for a new recipe, or when the saved definition is unchanged.
    param($Recipe,[switch]$Archive)
    $store=$script:DomeniaQueryLibraryStoreState
    if($null -eq $store -or -not $store.Loaded){throw 'Attendez la lecture confirmée de la bibliothèque locale.'}
    $previous=$store.Rows[[string]$Recipe.Id]
    if($null -eq $previous -or [bool]$previous.Archived){return $null}
    if(-not $Archive){
        $record=New-DomeniaQueryLibraryRecord -Context $store.Context -Recipe $Recipe -ExpectedRevision ([long]$previous.Revision)
        if([string]$record.DefinitionSHA256 -ceq [string]$previous.DefinitionSHA256){return $null}
    }
    $favorites=@();if($null -ne (Get-Command Get-DomeniaSearchQueryFavorites -CommandType Function -ErrorAction SilentlyContinue)){$favorites=@(Get-DomeniaSearchQueryFavorites)}
    $layouts=@{Fleet=@(Get-DomeniaBoardLayout Fleet);Computer=@(Get-DomeniaBoardLayout Computer)}
    $impact=Get-DomeniaQueryRecipeImpact -RecipeId ([string]$Recipe.Id) -Dependencies @($store.Dependencies) -Layouts $layouts -SearchFavorites $favorites -CurrentRevision ([long]$previous.Revision)
    if(-not $impact.HasConsumers){return $null}
    return $impact
}
function Request-DomeniaQueryRecipeSave {
    # Explicit save or archive. When widgets, links or views depend on the saved definition, nothing is written
    # before the operator chooses in the in-page review: update them, keep the old version, archive or cancel.
    param([switch]$Archive)
    $q=$script:DomeniaQueryState;$recipe=Get-DomeniaQueryDraft
    $impact=Get-DomeniaQueryDraftImpact -Recipe $recipe -Archive:$Archive
    if($null -ne $impact){Show-DomeniaQueryImpact -Impact $impact -Recipe $recipe -Mode $(if($Archive){'Archive'}else{'Save'});return}
    if($Archive){[void](Save-DomeniaQueryRecipe -Recipe $recipe -Archive -ImpactConfirmed -SuccessHandler 'Complete-DomeniaQueryRecipeArchiveUi');[void](Set-DomeniaControlText 'LblQueryStatus' 'Archivage de la requête dans la base…');return}
    [void](Save-DomeniaQueryRecipe -Recipe $recipe -ImpactConfirmed -CallbackState ([pscustomobject]@{DraftGeneration=$q.Generation}))
    [void](Set-DomeniaControlText 'LblQueryStatus' 'Enregistrement de la requête dans la base…')
}
function Show-DomeniaQueryImpact {
    # Widget mode: the dashboard widget requested from the workshop is added only after the choice (Widget holds it).
    param($Impact,$Recipe,[ValidateSet('Save','Archive','Widget')][string]$Mode,$Widget=$null)
    $q=$script:DomeniaQueryState
    if(($Mode -eq 'Widget') -ne ($null -ne $Widget)){throw 'Widget en attente incohérent avec la revue demandée.'}
    $q|Add-Member -NotePropertyName ImpactPending -NotePropertyValue ([pscustomobject]@{Mode=$Mode;Recipe=$Recipe;Generation=[long]$q.Generation;RecipeId=[string]$Recipe.Id;Revision=[long]$Impact.CurrentRevision;Count=[int]$Impact.Count;Widget=$Widget}) -Force
    (Get-DomeniaControl 'DgQueryImpact').ItemsSource=@($Impact.Rows)
    $parts=@($Impact.Widgets.ToString()+' widget(s)',$Impact.Views.ToString()+' vue(s) de Recherche');if($Impact.Orphans){$parts+=@($Impact.Orphans.ToString()+' lien(s) sans widget affiché')}
    $text=$Impact.Count.ToString()+' élément(s) utilisent la révision '+$Impact.CurrentRevision+' de « '+[string]$Recipe.Name+' » : '+($parts -join ', ')+'. Aucune alerte ne dépend des requêtes dans cette version.'
    if($Mode -eq 'Archive'){$text+=' Archiver retire ces widgets des tableaux de bord et la vue favorite ne proposera plus cette requête. Les révisions et les données collectées sont conservées.'}
    else{$text+=' Choisissez : mettre à jour ces éléments avec la nouvelle définition, ou garder lʼancienne version intacte et enregistrer la modification comme une nouvelle requête.'}
    if($Mode -eq 'Widget'){$text+=' Le widget demandé est ajouté au tableau de bord '+$(if([string]$Widget.Destination -eq 'Computer'){'Poste'}else{'général'})+' seulement après ce choix, avec la requête retenue.'}
    [void](Set-DomeniaControlText 'LblQueryImpact' $text)
    $family=if($Mode -eq 'Archive'){'Archive'}else{'Save'}
    foreach($entry in @(@('BtnQueryImpactMigrate','Save'),@('BtnQueryImpactKeep','Save'),@('BtnQueryImpactArchive','Archive'))){$button=Get-DomeniaControl $entry[0];if($null -ne $button){$button.Visibility=$(if($entry[1] -eq $family){'Visible'}else{'Collapsed'})}}
    (Get-DomeniaControl 'PnlQueryImpact').Visibility='Visible'
    [void](Set-DomeniaControlText 'LblQueryStatus' 'Modification en attente de votre choix : rien nʼest encore enregistré.')
}
function Clear-DomeniaQueryImpact {
    $q=$script:DomeniaQueryState;if($null -ne $q -and $null -ne $q.PSObject.Properties['ImpactPending']){$q.ImpactPending=$null}
    Set-DomeniaQueryControlProperty (Get-DomeniaControl 'PnlQueryImpact') 'Visibility' 'Collapsed'
    Set-DomeniaQueryControlProperty (Get-DomeniaControl 'DgQueryImpact') 'ItemsSource' @()
}
function Invoke-DomeniaQueryImpactAction {
    param([ValidateSet('Migrate','Keep','Archive','Cancel')][string]$Action)
    try{
        $q=$script:DomeniaQueryState;$pending=Get-DomeniaMemberValue $q 'ImpactPending'
        if($Action -eq 'Cancel'){Clear-DomeniaQueryImpact;[void](Set-DomeniaControlText 'LblQueryStatus' 'Modification non enregistrée : la requête et ses éléments liés restent inchangés.');return}
        $changed='Le brouillon a changé depuis la revue : cliquez à nouveau sur Enregistrer ou Archiver pour revoir les éléments liés.'
        if($null -eq $pending -or [long]$pending.Generation -ne [long]$q.Generation){Clear-DomeniaQueryImpact;throw $changed}
        if((ConvertTo-Json -InputObject (Get-DomeniaQueryDraft) -Depth 32 -Compress) -cne (ConvertTo-Json -InputObject $pending.Recipe -Depth 32 -Compress)){Clear-DomeniaQueryImpact;throw $changed}
        $store=$script:DomeniaQueryLibraryStoreState;$row=if($null -ne $store){$store.Rows[[string]$pending.RecipeId]}else{$null}
        if($null -eq $row -or [long]$row.Revision -ne [long]$pending.Revision){Clear-DomeniaQueryImpact;throw 'La requête a été modifiée entre-temps : revoyez les éléments liés avant de choisir.'}
        if(($Action -eq 'Archive') -ne ($pending.Mode -eq 'Archive')){throw 'Ce choix ne correspond pas à lʼaction demandée.'}
        switch($Action){
            'Migrate'{
                if($pending.Mode -eq 'Widget'){
                    # The requested widget joins the linked elements in the same atomic batch as the new definition.
                    $widget=$pending.Widget
                    [void](Save-DomeniaQueryRecipe -Recipe $pending.Recipe -ImpactConfirmed -SuccessHandler 'Complete-DomeniaWorkshopWidgetSave' -CallbackState $widget -AdditionalDependencies @([pscustomobject]@{ConsumerKind=[string]$widget.Destination;ConsumerId=[string]$widget.Item.Id}))
                    $status='Enregistrement de la nouvelle définition ; '+$pending.Count+' élément(s) liés lʼutiliseront, puis le widget sera ajouté…'
                }else{
                    [void](Save-DomeniaQueryRecipe -Recipe $pending.Recipe -ImpactConfirmed -CallbackState ([pscustomobject]@{DraftGeneration=$q.Generation}))
                    $status='Enregistrement de la nouvelle définition ; '+$pending.Count+' élément(s) liés lʼutiliseront…'
                }
            }
            'Keep'{
                $copy=New-DomeniaQueryRecipeVersion $pending.Recipe
                if($pending.Mode -eq 'Widget'){
                    # The widget is created for the copy; the saved recipe and its linked elements stay untouched.
                    $widget=$pending.Widget
                    $item=New-DomeniaBoardItem -Source Query -Key $copy.Id -Visual ([string]$widget.Visual) -Size M -Group 'Mes sondes' -Title $copy.Name
                    $state=[pscustomobject]@{DraftGeneration=$q.Generation;Destination=[string]$widget.Destination;Visual=[string]$widget.Visual;Item=$item;KeptName=[string]$row.Name;KeptRevision=[long]$pending.Revision;Count=[int]$pending.Count}
                    [void](Save-DomeniaQueryRecipe -Recipe $copy -ImpactConfirmed -SuccessHandler 'Complete-DomeniaWorkshopWidgetSave' -CallbackState $state -AdditionalDependencies @([pscustomobject]@{ConsumerKind=$state.Destination;ConsumerId=[string]$item.Id}))
                    $status='Enregistrement de la copie et de son widget ; la requête enregistrée et ses éléments liés restent inchangés…'
                }else{
                    [void](Save-DomeniaQueryRecipe -Recipe $copy -ImpactConfirmed -SuccessHandler 'Complete-DomeniaQueryRecipeVersionUi' -CallbackState ([pscustomobject]@{DraftGeneration=$q.Generation;KeptName=[string]$row.Name;KeptRevision=[long]$pending.Revision;Count=[int]$pending.Count}))
                    $status='Enregistrement de la copie ; la requête enregistrée et ses éléments liés restent inchangés…'
                }
            }
            'Archive'{
                [void](Save-DomeniaQueryRecipe -Recipe $pending.Recipe -Archive -ImpactConfirmed -SuccessHandler 'Complete-DomeniaQueryRecipeArchiveUi')
                $status='Archivage de la requête et retrait de ses widgets…'
            }
        }
        Clear-DomeniaQueryImpact
        [void](Set-DomeniaControlText 'LblQueryStatus' $status)
    }catch{[void](Set-DomeniaControlText 'LblQueryStatus' ('Choix non appliqué : '+$_.Exception.Message))}
}
function Complete-DomeniaQueryRecipeVersionUi {
    param($Recipe,$Record,$State)
    $q=$script:DomeniaQueryState
    if($null -ne $q -and ($null -eq $State -or [long]$State.DraftGeneration -eq [long]$q.Generation)){Set-DomeniaQueryDraft $Recipe}
    [void](Set-DomeniaControlText 'LblQueryStatus' ('Nouvelle requête « '+[string]$Recipe.Name+' » enregistrée (révision '+$Record.Revision+'). « '+[string]$State.KeptName+' » et ses '+$State.Count+' élément(s) liés restent à la révision '+$State.KeptRevision+'.'))
}
function Update-DomeniaQueryGroups {
    $q=$script:DomeniaQueryState;$expander=Get-DomeniaControl 'ExpQueryGroups';$grid=Get-DomeniaControl 'DgQueryGroups'
    if($null -eq $q -or $null -eq $expander -or $null -eq $grid){return}
    $summary=Get-DomeniaMemberValue $q 'GroupSummary'
    foreach($name in @('BtnQueryGroupsPrevious','BtnQueryGroupsNext','BtnQueryGroupsShow')){Set-DomeniaQueryControlProperty (Get-DomeniaControl $name) 'IsEnabled' $false}
    if($null -eq $summary){Set-DomeniaQueryControlProperty $expander 'Visibility' 'Collapsed';Set-DomeniaQueryControlProperty $grid 'ItemsSource' @();[void](Set-DomeniaControlText 'LblQueryGroups' '');return}
    Set-DomeniaQueryControlProperty $expander 'Visibility' 'Visible'
    if([string](Get-DomeniaMember $summary 'Error')){Set-DomeniaQueryControlProperty $grid 'ItemsSource' @();[void](Set-DomeniaControlText 'LblQueryGroups' ('Répartition non calculée : '+[string]$summary.Error));return}
    $filter=Get-DomeniaControl 'TxtQueryGroupFilter';$text=if($null -ne $filter){[string]$filter.Text}else{''}
    $page=Get-DomeniaQueryGroupPage -Summary $summary -Offset ([int]$q.GroupOffset) -Limit 100 -Text $text
    $q|Add-Member -NotePropertyName GroupOffset -NotePropertyValue ([int]$page.Offset) -Force;Set-DomeniaQueryControlProperty $grid 'ItemsSource' @($page.Rows)
    $culture=[Globalization.CultureInfo]::GetCultureInfo('fr-FR')
    $label=$page.CategoryCount.ToString('N0',$culture)+' valeur(s) distincte(s) pour '+$page.Matched.ToString('N0',$culture)+' poste(s) correspondant(s), total exact'
    if($page.Missing){$label+=', dont '+$page.Missing.ToString('N0',$culture)+' sans valeur lisible'}
    $label+='. '+$(if($page.Filtered){'Valeurs '+($page.Offset+1).ToString('N0',$culture)+' à '+($page.Offset+@($page.Rows).Count).ToString('N0',$culture)+' sur '+$page.Filtered.ToString('N0',$culture)}else{'Aucune valeur ne correspond au filtre'})
    $label+='. Même calcul que le widget, sur tout le périmètre ; les filtres dʼaffichage de la liste ne sʼappliquent pas.'
    [void](Set-DomeniaControlText 'LblQueryGroups' $label)
    Set-DomeniaQueryControlProperty (Get-DomeniaControl 'BtnQueryGroupsPrevious') 'IsEnabled' ([bool]$page.HasPrevious)
    Set-DomeniaQueryControlProperty (Get-DomeniaControl 'BtnQueryGroupsNext') 'IsEnabled' ([bool]$page.HasNext)
}
function Move-DomeniaQueryGroupPage {
    param([int]$Direction)
    $q=$script:DomeniaQueryState;if($null -eq $q -or $null -eq (Get-DomeniaMemberValue $q 'GroupSummary')){return}
    $q.GroupOffset=[Math]::Max(0,[int]$q.GroupOffset+(100*[Math]::Sign($Direction)))
    Update-DomeniaQueryGroups
}
function Show-DomeniaQueryGroupMachines {
    try{
        $q=$script:DomeniaQueryState;$row=(Get-DomeniaControl 'DgQueryGroups').SelectedItem
        if($null -eq $q -or $null -eq $row){throw 'Sélectionnez une valeur de la répartition.'}
        $summary=Get-DomeniaMemberValue $q 'GroupSummary'
        if($null -eq $summary -or $q.Busy -or [string]$summary.Field -cne [string](Get-DomeniaMember $q.Recipe 'GroupBy')){throw 'La répartition ne correspond plus à la requête affichée : relancez lʼaperçu.'}
        $recipe=New-DomeniaQuerySegmentRecipe $q.Recipe $row.Select
        Set-DomeniaQueryDraft $recipe
        (Get-DomeniaControl 'CmbQueryResult').SelectedIndex=0
        Start-DomeniaQueryEvaluation
    }catch{[void](Set-DomeniaControlText 'LblQueryStatus' $_.Exception.Message)}
}
function Set-DomeniaQueryDraft {
    param($Recipe)
    $q=$script:DomeniaQueryState;if($null -eq $q){return}
    $q.Recipe=$Recipe;$q.Offset=0;$q.Generation++;$q.Result=$null;$q.Busy=$false
    $coverage=Get-DomeniaControl 'DgQueryCoverage';if($null -ne $coverage){$coverage.ItemsSource=@()}
    [void](Set-DomeniaControlText 'LblQueryCoverage' 'Vérifiez la couverture des informations avant lʼaperçu.')
    Reset-DomeniaQueryCoherence
    Clear-DomeniaQueryImpact
    Reset-DomeniaQueryResults
    $title=Get-DomeniaControl 'TxtFleetQueryName';if($null -ne $title){$title.Text=[string]$Recipe.Name}
    $junction=Get-DomeniaControl 'CmbQueryJunction';if($null -ne $junction){$junction.SelectedIndex=$(if($Recipe.Junction -eq 'Any'){1}else{0})}
    $group=Get-DomeniaControl 'CmbQueryGroupField';if($null -ne $group){$group.SelectedIndex=0;foreach($entry in $group.ItemsSource){if($entry.Id -ceq [string](Get-DomeniaMember $Recipe 'GroupBy')){$group.SelectedItem=$entry}}}
    $fields=@{};foreach($field in @(@(Get-DomeniaQueryFields)+@(Get-DomeniaQueryReadDefinitionFields $Recipe))){$fields[$field.Id]=$field}
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @())
    $segmentLabels=@(foreach($clause in $refinements){
        $field=$fields[[string]$clause.Field]
        $operator=@(Get-DomeniaQueryOperators $field.Kind|Where-Object{$_.Id -eq $clause.Operator})[0]
        [string]$field.Name+' '+[string]$operator.Name+' '+[string]$clause.Value
    })
    [void](Set-DomeniaControlText 'LblQuerySegment' ('Conditions du segment (ET) : '+($segmentLabels -join ' ; ')))
    $probeSegment=Get-DomeniaMemberValue $Recipe 'ProbeSelection'
    if($null -ne $probeSegment){[void](Set-DomeniaControlText 'LblQuerySegment' ('Segment de sonde : '+(Get-DomeniaProbe $probeSegment.Key).Name+' · '+$Recipe.Name+' · au moins une valeur correspondante par poste'))}
    $identitySelection=Get-DomeniaQueryIdentitySelection $Recipe
    if($null -ne $identitySelection){[void](Set-DomeniaControlText 'LblQuerySegment' ('Sélection figée : '+$identitySelection.Count+' GUID dans le périmètre courant · Effacer le segment pour retrouver tous les postes.'))}
    $hasSegment=($refinements.Count -gt 0 -or $null -ne $probeSegment -or $null -ne $identitySelection)
    foreach($name in @('LblQuerySegment','BtnQueryClearSegment')){
        $control=Get-DomeniaControl $name
        if($null -ne $control){$control.Visibility=$(if($hasSegment){'Visible'}else{'Collapsed'})}
    }
    $grid=Get-DomeniaControl 'DgQueryConditions'
    if($null -ne $grid){$grid.ItemsSource=@(foreach($c in @($Recipe.Clauses)){[pscustomobject]@{Field=$c.Field;Operator=$c.Operator;Value=$c.Value;FieldLabel=$fields[[string]$c.Field].Name;OperatorLabel=[string](@(Get-DomeniaQueryOperators $fields[[string]$c.Field].Kind | Where-Object{$_.Id -eq $c.Operator})[0].Name)}})}
    Update-DomeniaQueryAdvancedDraft $Recipe
    [void](Set-DomeniaControlText 'LblQueryStatus' 'Prêt. Exécuter applique ces conditions aux données locales du périmètre courant.')
}
function Get-DomeniaQueryDraft {
    $q=$script:DomeniaQueryState
    $name=[string](Get-DomeniaControl 'TxtFleetQueryName').Text
    $junction=if((Get-DomeniaControl 'CmbQueryJunction').SelectedIndex -eq 1){'Any'}else{'All'}
    $recipe=New-DomeniaQueryRecipe -Id $q.Recipe.Id -Name $name -Junction $junction -Clauses @($q.Recipe.Clauses) -GroupBy ([string](Get-DomeniaControl 'CmbQueryGroupField').SelectedItem.Id) -Refinements @(Get-DomeniaMember $q.Recipe 'Refinements' @()) -ProbeSelection (Get-DomeniaMemberValue $q.Recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $q.Recipe 'ObjectIds') -Parameters @(Get-DomeniaMember $q.Recipe 'Parameters' @()) -ParameterValues (Get-DomeniaMemberValue $q.Recipe 'ParameterValues') -Expression (Get-DomeniaMemberValue $q.Recipe 'Expression') -CoherenceHours (Get-DomeniaMemberValue $q.Recipe 'CoherenceHours') -ReadDefinition (Get-DomeniaMemberValue $q.Recipe 'ReadDefinition')
    $recipe=Copy-DomeniaQueryRecipe $recipe
    $parameters=Get-DomeniaControl 'DgQueryParameters'
    if($null -ne $parameters){
        [void]$parameters.CommitEdit();$values=@{}
        foreach($row in @($parameters.ItemsSource)){$values[[string]$row.Name]=$row.Value}
        $recipe.ParameterValues=$values
    }
    $coherence=Get-DomeniaControl 'TxtQueryCoherenceHours'
    if($null -ne $coherence){
        $text=([string]$coherence.Text).Trim();$hours=0.0
        if(-not $text){$recipe.CoherenceHours=$null}
        elseif([double]::TryParse($text.Replace(',','.'),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$hours) -and $hours -gt 0 -and $hours -le 8760){$recipe.CoherenceHours=$hours}
        else{throw 'Saisissez une fenêtre comprise entre plus de 0 et 8 760 heures, ou laissez ce champ vide.'}
    }
    $recipe.Format=if(@($recipe.Parameters).Count -or $null -ne $recipe.Expression -or $null -ne $recipe.CoherenceHours -or $null -ne $recipe.ReadDefinition){'Domenia.Query/2'}else{'Domenia.Query/1'}
    [void](ConvertTo-DomeniaCompiledQuery $recipe)
    return $recipe
}
function Save-DomeniaQueryLibraryState {
    param([string]$Json)
    if($null -eq $script:Settings){$script:Settings=Get-DomeniaDefaultSettings}
    $hadValue=$script:Settings.Contains('Query.Library');$previous=$script:Settings['Query.Library']
    try{
        # Avoid a deferred write containing a change that the explicit save refused.
        $script:Settings['Query.Library']=$Json
        Save-DomeniaSettings -Immediate -ThrowOnFailure
    }catch{
        if($hadValue){$script:Settings['Query.Library']=$previous}else{$script:Settings.Remove('Query.Library')}
        throw
    }
}
function Invoke-DomeniaQueryAction {
    param([string]$Action)
    try{
        Initialize-DomeniaQueryWorkshop;$q=$script:DomeniaQueryState
        if($null -ne $q.Timer){$q.Timer.Stop()}
        $inner=Get-DomeniaControl 'QueryWorkspaceTabs'
        if($null -ne $inner){
            if($Action -in @('New','Load','Add','Remove')){$inner.SelectedItem=Get-DomeniaControl 'TabQueryCompose'}
            elseif($Action -in @('Save','Delete','Widget')){$inner.SelectedItem=Get-DomeniaControl 'TabQueryPublish'}
            elseif($Action -in @('Run','Previous','Next')){$inner.SelectedItem=Get-DomeniaControl 'TabQueryResults'}
        }
        switch($Action){
            'New'{Set-DomeniaQueryDraft (New-DomeniaQueryRecipe);return}
            'ClearSegment'{$recipe=Get-DomeniaQueryDraft;$recipe.Refinements=@();$recipe|Add-Member NoteProperty ProbeSelection $null -Force;$recipe|Add-Member NoteProperty ObjectIds $null -Force;Set-DomeniaQueryDraft $recipe;return}
            'Load'{$selected=(Get-DomeniaControl 'CmbFleetQuery').SelectedItem;if($null -ne $selected){Set-DomeniaQueryDraft $selected};return}
            'Add'{
                $field=(Get-DomeniaControl 'CmbQueryField').SelectedItem;$op=(Get-DomeniaControl 'CmbQueryOperator').SelectedItem
                if($null -eq $field -or $null -eq $op){throw 'Choisissez un champ et un opérateur.'}
                $value=[string](Get-DomeniaControl 'TxtQueryValue').Text
                if($op.Id -in @('IsMissing','IsPresent')){$value=$null}
                elseif($field.Kind -eq 'Number'){$value=ConvertTo-DomeniaQueryNumber -Text $value -Field $field.Id}
                elseif($field.Kind -eq 'Boolean'){if($value.Trim() -match '^(?i:true|vrai|oui|1)$'){$value=$true}elseif($value.Trim() -match '^(?i:false|faux|non|0)$'){$value=$false}else{throw 'Saisissez Oui ou Non.'}}
                $draft=Get-DomeniaQueryDraft;$draft.Clauses=@($draft.Clauses)+@([pscustomobject]@{Field=$field.Id;Operator=$op.Id;Value=$value})
                [void](ConvertTo-DomeniaCompiledQuery $draft);Set-DomeniaQueryDraft $draft;return
            }
            'Remove'{$grid=Get-DomeniaControl 'DgQueryConditions';$index=$grid.SelectedIndex;if($index -ge 0){$draft=Get-DomeniaQueryDraft;$draft.Clauses=@(for($i=0;$i -lt $draft.Clauses.Count;$i++){if($i -ne $index){$draft.Clauses[$i]}});Set-DomeniaQueryDraft $draft};return}
            'Save'{Request-DomeniaQueryRecipeSave;return}
            'Delete'{Request-DomeniaQueryRecipeSave -Archive;return}
            'Widget'{Add-DomeniaWorkshopWidget;return}
            'OpenObject'{$row=Get-DomeniaQuerySelectedRow;Open-AdObject -Dn ([string]$row.distinguished_name) -Type Machine -ObjectGuid ([string]$row.Id) -SuppressRemoteProbes;return}
            'CopyObject'{$row=Get-DomeniaQuerySelectedRow;[Windows.Clipboard]::SetText([string]$row.distinguished_name);return}
            'CollectObject'{$row=Get-DomeniaQuerySelectedRow;$recipe=Get-DomeniaQueryDraft;Start-DomeniaOnlinePark -ScopeTargets @([pscustomobject]@{name=$row.name;distinguished_name=$row.distinguished_name;object_guid=$row.Id}) -ScopeLabel ([string]$row.name) -Inventory -Probes @(ConvertTo-DomeniaProbePayload (Get-DomeniaQueryProbeIds $recipe));return}
            'Collect'{
                $recipe=Get-DomeniaQueryDraft;$plan=Get-DomeniaQueryCollectionRequirements -Recipes @($recipe)
                if(-not $plan.Remote){throw 'Cette requête utilise uniquement la base locale. Actualisez lʼOU choisie dans Base de données pour relire ses informations AD.'}
                Start-DomeniaQueryEvaluation -PlanCollection;return
            }
            'Previous'{$q.Offset=[Math]::Max(0,$q.Offset-200);Start-DomeniaQueryEvaluation -KeepPage;return}
            'Next'{if($null -ne $q.Result){$count=switch([string]$q.Result.Selection){'Match'{[long]$q.Result.Matched};'Unknown'{[long]$q.Result.Unknown};default{[long]$q.Result.NotMatched}};if(($q.Offset+200) -lt $count){$q.Offset+=200;Start-DomeniaQueryEvaluation -KeepPage}};return}
            'Coverage'{Start-DomeniaQueryEvaluation -CoverageOnly;return}
            'Export'{Start-DomeniaQueryExport;return}
            'ApplySearch'{
                if($q.Busy -or $null -eq $q.Records -or $q.SnapshotKey -ne [string]$script:FleetQuerySnapshotKey -or ([datetime]::UtcNow-$q.At).TotalMinutes -ge 1){throw 'Exécutez dʼabord la requête pour disposer de données locales actuelles.'}
                $recipe=Get-DomeniaQueryDraft;$q.SearchRecipe=ConvertTo-DomeniaCompiledQuery $recipe;$q.SearchRefinement=ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses @(Get-DomeniaMember $recipe 'Refinements' @()));$q.SearchAt=$q.At;$q.SearchSnapshotKey=$q.SnapshotKey
                # A search filter is an explicit, dated selection of identities. Keep only matching GUIDs:
                # expiry, another dashboard OU or a new draft must not silently change this selection.
                $q.SearchRecords=Get-DomeniaQueryMatchIds -Records $q.Records -Recipe $recipe
                $q.SearchUnknown=0;Apply-DomeniaPresenceFilter
                [void](Set-DomeniaControlText 'LblSearchQuery' ('Sélection locale du '+$q.At.ToLocalTime().ToString('dd/MM HH:mm:ss')+' : '+$recipe.Name+' · '+$q.SearchRecords.Count+' GUID correspondants, champs inconnus exclus. Réappliquez depuis lʼatelier pour actualiser cette sélection.'))
                Select-DomeniaWorkspace 'WsSearch';return
            }
            'ClearSearch'{if($null -ne (Get-Command Clear-DomeniaSearchQuery -CommandType Function -ErrorAction SilentlyContinue)){Clear-DomeniaSearchQuery}else{$q.SearchRecipe=$null;$q.SearchRefinement=$null;$q.SearchRecords=@{};Apply-DomeniaPresenceFilter;[void](Set-DomeniaControlText 'LblSearchQuery' 'Aucune requête enregistrée appliquée aux résultats.')};return}
            default{Start-DomeniaQueryEvaluation}
        }
    }catch{[void](Set-DomeniaControlText 'LblQueryStatus' $_.Exception.Message);Set-Status ('Atelier : '+$_.Exception.Message) 'WARN'}
}
function Request-DomeniaQueryEvaluation {
    $q=$script:DomeniaQueryState;if($null -eq $q -or -not $q.Bound){return}
    if($null -eq $q.Timer){$q.Timer=New-DomeniaTimer -Owner 'Timer:QueryWorkshop' -IntervalMs 350 -SessionBound -Tick {$script:DomeniaQueryState.Timer.Stop();Start-DomeniaQueryEvaluation}}
    $q.Timer.Stop();$q.Timer.Start()
}
function Get-DomeniaQueryWidgetRecipes {
    # Saved library size must not multiply a 20k fleet scan. Evaluate only visible board dependencies; a paused
    # widget is not evaluated (decision David 2026-10-14).
    $q=$script:DomeniaQueryState;if($null -eq $q){return @()}
    $ids=@{};foreach($item in @(Select-DomeniaActiveBoardItems -Layout @(Get-DomeniaBoardLayout Fleet))){if([string]$item.Source -eq 'Query'){$ids[[string]$item.Key]=$true}}
    return @($q.Saved|Where-Object{$ids.ContainsKey([string]$_.Id)})
}
function Start-DomeniaQueryEvaluation {
    param([switch]$KeepPage,[switch]$CoverageOnly,[switch]$PlanCollection)
    try{
        Initialize-DomeniaQueryWorkshop;$q=$script:DomeniaQueryState
        if($null -ne $q.Timer){$q.Timer.Stop()}
        if([bool]$script:FleetStale -or [string]$script:FleetJobId){
            $q.Generation++;$q.Busy=$false;$q.Result=$null
            Reset-DomeniaQueryResults
            [void](Set-DomeniaControlText 'LblQueryStatus' 'Actualisation des données locales en cours… La requête sera recalculée dès leur disponibilité.')
            Request-DomeniaFleetRefresh
            return
        }
        if($null -eq $script:FleetLast){[void](Set-DomeniaControlText 'LblQueryStatus' 'Chargez la base locale ou mettez-la à jour pour consulter le parc.');return}
        if(-not $KeepPage){$q.Offset=0}
        $recipe=Get-DomeniaQueryDraft;$q.Recipe=$recipe
        $q.Generation++;$q.Busy=$true;$q.Result=$null
        Reset-DomeniaQueryResults
        $scope=Get-DomeniaFleetScope
        if([string]$script:FleetLast.Scope -ine [string]$scope.Dn -or [bool]$script:FleetLast.Subtree -ne [bool]$scope.Subtree){
            $q.Busy=$false
            [void](Set-DomeniaControlText 'LblQueryStatus' 'Le périmètre a changé. Attendez le calcul de cette OU avant dʼexécuter la requête.')
            Request-DomeniaFleetRefresh -Force
            return
        }
        $selection=@('Match','Unknown','NoMatch')[[Math]::Max(0,(Get-DomeniaControl 'CmbQueryResult').SelectedIndex)]
        $records=$null
        if($q.SnapshotKey -eq [string]$script:FleetQuerySnapshotKey -and ([datetime]::UtcNow-$q.At).TotalMinutes -lt 1){$records=$q.Records}
        $widgetRecipes=@(Get-DomeniaQueryWidgetRecipes)
        $library=ConvertTo-DomeniaQueryLibraryJson $widgetRecipes
        $widgetCache=if($null -ne $records -and $library -ceq $q.WidgetLibrary){$q.Widgets}else{$null}
        $probeRequests=@(Select-DomeniaActiveBoardItems -Layout @(Get-DomeniaBoardLayout Fleet)|Where-Object{$_.Source -eq 'Probe'}|Select-Object Key,Visual -Unique)
        $probeLibrary=ConvertTo-Json -InputObject $probeRequests -Compress
        $probeCache=if($null -ne $records -and $probeLibrary -ceq $q.ProbeLibrary){$q.ProbeWidgets}else{$null}
        $payload=[pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Lifecycle=(Get-DomeniaWindowsLifecycleTable);Fleet=$script:FleetLast;Observations=$script:FleetObservations;Records=$records;Recipe=$recipe;Saved=$widgetRecipes;CachedWidgets=$widgetCache;SortField=$q.SortField;Descending=$q.SortDescending;Offset=$q.Offset;Selection=$selection;MaxAgeDays=(Get-DomeniaObservationMaxAgeDays);TextFilter=[string](Get-DomeniaControl 'TxtFleetMachineFilter').Text;StateFilter=[string](Get-DomeniaControl 'CmbFleetMachineState').SelectedItem.Content}
        $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=$q.Generation;SnapshotKey=[string]$script:FleetQuerySnapshotKey;ScopeKey=$scope.Key;RecordsAt=$(if($null -ne $records){$q.At}else{[datetime]::UtcNow});WidgetLibrary=$library}
        $payload|Add-Member NoteProperty PlanCollection ([bool]$PlanCollection)
        $payload|Add-Member NoteProperty CacheMinutes ([int](Get-DomeniaSetting 'Collection.CacheMinutes' '15'))
        $state|Add-Member NoteProperty PlanCollection ([bool]$PlanCollection)
        $payload|Add-Member -NotePropertyName CoverageOnly -NotePropertyValue ([bool]$CoverageOnly)
        $state|Add-Member -NotePropertyName CoverageOnly -NotePropertyValue ([bool]$CoverageOnly)
        $payload|Add-Member -NotePropertyName ProbeRequests -NotePropertyValue $probeRequests
        $payload|Add-Member -NotePropertyName CachedProbeWidgets -NotePropertyValue $probeCache
        $state|Add-Member -NotePropertyName ExportRequest -NotePropertyValue ([pscustomobject]@{SnapshotKey=$state.SnapshotKey;RecipeJson=(ConvertTo-Json -InputObject $recipe -Depth 32 -Compress);TextFilter=$payload.TextFilter;StateFilter=$payload.StateFilter;Selection=$selection;SortField=$payload.SortField;Descending=$payload.Descending;ExpectedRows=0L;EvaluatedAtUtc=$state.RecordsAt.ToUniversalTime().ToString('o');ScopeDn=[string]$scope.Dn;Subtree=[bool]$scope.Subtree})
        $state|Add-Member -NotePropertyName ProbeLibrary -NotePropertyValue $probeLibrary
        $state|Add-Member -NotePropertyName RefreshWidgets -NotePropertyValue ($null -eq $widgetCache -or $null -eq $probeCache)
        Start-DomeniaQueryDetailRead -Payload $payload -State $state
        [void](Set-DomeniaControlText 'LblQueryStatus' ('Calcul local en cours sur '+$scope.Name+'…'))
    }catch{if($null -ne $script:DomeniaQueryState){$script:DomeniaQueryState.Busy=$false};[void](Set-DomeniaControlText 'LblQueryStatus' ('Calcul impossible : '+$_.Exception.Message))}
}
function Complete-DomeniaQueryEvaluation {
    param($Result,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne $q.Generation -or $State.SnapshotKey -ne [string]$script:FleetQuerySnapshotKey -or [string]$State.ScopeKey -ne [string](Get-DomeniaFleetScope).Key){return}
    if([bool](Get-DomeniaMember $State 'PlanCollection' $false)){
        $read=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('CollectionPlan','Records')
        if($null -eq $read){Fail-DomeniaQueryEvaluation 'Plan de collecte local incomplet.' $State;return}
        $q.Busy=$false;$q.Job='';$q.Records=$read.Records;$q.At=[datetime]$State.RecordsAt;$q.SnapshotKey=[string]$State.SnapshotKey
        $plan=$read.CollectionPlan
        if(-not @($plan.Targets).Count){[void](Set-DomeniaControlText 'LblQueryStatus' ('Aucun poste à relire : '+$plan.Reused+' à jour, '+$plan.Disabled+' désactivés et '+$plan.UnknownState+' avec état AD inconnu.'));return}
        $scope=Get-DomeniaFleetScope
        $label='Atelier : '+$scope.Name+' · '+@($plan.Targets).Count+' postes avec données manquantes ou anciennes, '+$plan.Reused+' déjà à jour'
        Start-DomeniaOnlinePark -ScopeTargets @($plan.Targets) -ScopeLabel $label -PingOnly:([bool]$plan.Ping -and -not [bool]$plan.Wmi) -WmiOnly:([bool]$plan.Wmi -and -not [bool]$plan.Ping) -Inventory:([bool]$plan.Inventory) -Probes @(ConvertTo-DomeniaProbePayload $plan.ProbeIds)
        [void](Set-DomeniaControlText 'LblQueryStatus' 'Plan préparé : seuls les postes incomplets ou trop anciens sont proposés. Le moteur vérifie à nouveau chaque mesure avant de la relire.')
        return
    }
    if([bool](Get-DomeniaMember $State 'CoverageOnly' $false)){
        $read=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Coverage','Records')
        if($null -eq $read){Fail-DomeniaQueryEvaluation 'Couverture locale incomplète.' $State;return}
        $q.Busy=$false;$q.Job='';$q.Records=$read.Records;$q.At=[datetime]$State.RecordsAt;$q.SnapshotKey=[string]$State.SnapshotKey
        $coverage=$read.Coverage;(Get-DomeniaControl 'DgQueryCoverage').ItemsSource=@($coverage.Rows)
        (Get-DomeniaControl 'ExpQueryCoverage').IsExpanded=$true
        $text=$coverage.Complete.ToString()+' / '+$coverage.Total+' postes possèdent tous les champs demandés ; '+$coverage.Incomplete+' incomplets.'
        $window=Format-DomeniaQueryHours ([double]$coverage.CoherenceHours)
        $windowText=if([string](Get-DomeniaMember $coverage 'WindowSource') -eq 'Recette'){'fenêtre de la requête'}else{'référence : la requête nʼa pas de fenêtre commune'}
        if($coverage.MixedPeriod){$text+=' '+$coverage.MixedPeriod+' postes ont des valeurs espacées de plus de '+$window+' ('+$windowText+').'}
        if($coverage.Undated){$text+=' '+$coverage.Undated+' postes ont une date de source manquante.'}
        [void](Set-DomeniaControlText 'LblQueryCoverage' ($text+' État du '+$q.At.ToLocalTime().ToString('dd/MM HH:mm:ss')+'.'))
        Show-DomeniaQueryCoherence -Coverage $coverage
        [void](Set-DomeniaControlText 'LblQueryStatus' 'Couverture vérifiée localement. Aperçu local applique ensuite les conditions ; aucune collecte nʼa été lancée.')
        return
    }
    $r=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows','Matched','Unknown','Records')
    if($null -eq $r){Fail-DomeniaQueryEvaluation 'Résultat local incomplet.' $State;return}
    $q.Busy=$false;$q.Job='';$q.Result=$r;$q.Records=$r.Records;$q.At=[datetime]$State.RecordsAt;$q.SnapshotKey=[string]$State.SnapshotKey
    if ([string]$State.WidgetLibrary -ceq (ConvertTo-DomeniaQueryLibraryJson @(Get-DomeniaQueryWidgetRecipes))) {
        $q.Widgets=$r.Widgets;$q.WidgetLibrary=[string]$State.WidgetLibrary
    } else { $q.Widgets=@{};$q.WidgetLibrary='' }
    $q.ProbeWidgets=Get-DomeniaMemberValue $r 'ProbeWidgets' @{};$q.ProbeLibrary=[string]$State.ProbeLibrary
    (Get-DomeniaControl 'DgFleetMachines').ItemsSource=@($r.Rows)
    $text='{0} correspondants · {1} inconnus · {2} non correspondants / {3} postes filtrés, {4} recensés dans le périmètre. Page {5}.' -f $r.Matched,$r.Unknown,$r.NotMatched,$r.Total,$r.ScopeTotal,([int]($r.Offset/200)+1)
    [void](Set-DomeniaControlText 'LblFleetMachineCount' ('{0} ligne(s) sur cette page · données locales' -f @($r.Rows).Count))
    [void](Set-DomeniaControlText 'LblQueryStatus' ($text+' Les données expirées ou non lues restent inconnues.'))
    [void](Set-DomeniaControlText 'LblQueryPublishSummary' ($text+' Aperçu local calculé le '+$q.At.ToLocalTime().ToString('dd/MM HH:mm:ss')+'.'))
    Add-DomeniaUiLog -Area 'Requêtes' -Text ($q.Recipe.Name+' · '+$text+' · calcul local du '+$q.At.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss'))
    (Get-DomeniaControl 'BtnQueryPrevious').IsEnabled=($q.Offset -gt 0)
    $count=switch([string]$r.Selection){'Match'{[long]$r.Matched};'Unknown'{[long]$r.Unknown};default{[long]$r.NotMatched}}
    (Get-DomeniaControl 'BtnQueryNext').IsEnabled=(($q.Offset+200) -lt $count)
    $exportRequest=Get-DomeniaMemberValue $State 'ExportRequest'
    if($null -ne $exportRequest){$exportRequest.ExpectedRows=$count;$q|Add-Member -NotePropertyName ExportRequest -NotePropertyValue $exportRequest -Force}
    $exportButton=Get-DomeniaControl 'BtnQueryExport';if($null -ne $exportButton){$exportButton.IsEnabled=($null -ne $exportRequest -and -not [bool](Get-DomeniaMember $q 'ExportBusy' $false))}
    $q|Add-Member -NotePropertyName GroupSummary -NotePropertyValue (Get-DomeniaMemberValue $r 'Groups') -Force;$q|Add-Member -NotePropertyName GroupOffset -NotePropertyValue 0 -Force;Update-DomeniaQueryGroups

    if([bool](Get-DomeniaMember $State 'RefreshWidgets' $true)){Show-DomeniaBoard -Board Fleet -Quiet -DeferIfHidden}
}
function Fail-DomeniaQueryEvaluation {
    param($Message,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne $q.Generation -or $State.SnapshotKey -ne [string]$script:FleetQuerySnapshotKey -or [string]$State.ScopeKey -ne [string](Get-DomeniaFleetScope).Key){return}
    $q.Busy=$false;$q.Job='';$q.Result=$null
    Reset-DomeniaQueryResults
    [void](Set-DomeniaControlText 'LblQueryStatus' ('Calcul non terminé : '+[string]$Message))
}
function Start-DomeniaQueryExport {
    $q=$script:DomeniaQueryState
    if($null -eq $q -or $q.Busy -or $null -eq $q.Result -or $null -eq $q.Records){throw 'Attendez un aperçu terminé avant lʼexport.'}
    if([bool](Get-DomeniaMember $q 'ExportBusy' $false)){throw 'Un export de requête est déjà en cours.'}
    $request=Get-DomeniaMemberValue $q 'ExportRequest'
    if($null -eq $request -or [string]$request.SnapshotKey -cne $q.SnapshotKey){throw 'Relancez lʼaperçu avant lʼexport.'}
    $recipe=ConvertFrom-Json -InputObject ([string]$request.RecipeJson) -ErrorAction Stop
    $folder=Get-DomeniaExportDirectory;$name=Get-DomeniaExportFileName -Subject ([string]$recipe.Name)
    $path=Join-Path $folder $name;$suffix=2
    while([IO.File]::Exists($path) -or [IO.File]::Exists($path+'.metadata.json')){$path=Join-Path $folder ([IO.Path]::GetFileNameWithoutExtension($name)+'-'+$suffix+'.csv');$suffix++}
    # The worker owns the immutable records reference and copied request. Editing the UI cannot change it.
    $frozen=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $request -Depth 32 -Compress) -ErrorAction Stop
    $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;ExportId=[guid]::NewGuid().ToString('N');Name=[string]$recipe.Name;Selection=$frozen.Selection}
    $q|Add-Member -NotePropertyName ExportBusy -NotePropertyValue $true -Force
    $q|Add-Member -NotePropertyName ExportId -NotePropertyValue $state.ExportId -Force
    (Get-DomeniaControl 'BtnQueryExport').IsEnabled=$false
    try{
        $job=Start-UiTask -Name 'Exporter tous les résultats de la requête' -OperationId 'QueryExport' -Code (Get-DomeniaQueryExportWorkerCode) -Payload ([pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Path=$path;Records=$q.Records;Request=$frozen}) -CallbackState $state -SuccessHandler 'Complete-DomeniaQueryExport' -ErrorHandler 'Fail-DomeniaQueryExport' -TimeoutSeconds 300 -TaskClass 'Explicit'
        if(-not $job){throw 'Export non admis, réessayez.'}
        [void](Set-DomeniaControlText 'LblQueryStatus' ('Export de '+$frozen.ExpectedRows+' postes en cours ; vous pouvez continuer à consulter lʼatelier.'))
    }catch{Fail-DomeniaQueryExport $_.Exception.Message $state}
}
function Complete-DomeniaQueryExport {
    param($Result,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.ExportId -cne [string](Get-DomeniaMember $q 'ExportId')){return}
    $result=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Path','RowCount','Complete','MetadataPath')
    if($null -eq $result -or -not $result.Complete){Fail-DomeniaQueryExport 'Lʼexport complet nʼa pas été confirmé.' $State;return}
    $q.ExportBusy=$false;(Get-DomeniaControl 'BtnQueryExport').IsEnabled=($null -ne $q.Result -and -not $q.Busy)
    Show-DomeniaExportResult $result -Scope ('résultat complet : '+$State.Name+' · '+$State.Selection) -Also 'Critères, périmètre et empreinte SHA-256 dans le fichier metadata.json associé.'
    [void](Set-DomeniaControlText 'LblQueryStatus' ($result.RowCount.ToString()+' postes exportés en '+$result.Pages+' page(s), sans modifier le périmètre de lʼaperçu.'))
}
function Fail-DomeniaQueryExport {
    param($Message,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or [string]$State.ExportId -cne [string](Get-DomeniaMember $q 'ExportId')){return}
    $q.ExportBusy=$false;(Get-DomeniaControl 'BtnQueryExport').IsEnabled=($null -ne $q.Result -and -not $q.Busy)
    [void](Set-DomeniaControlText 'LblQueryStatus' ('Export non terminé : '+[string]$Message))
}
function Get-DomeniaQueryBoardEntry {
    param([string]$Id,[string]$Visual='Kpi')
    $q=$script:DomeniaQueryState
    $recipe=@(if($null -ne $q){$q.Saved|Where-Object{$_.Id -eq $Id}|Select-Object -First 1})
    if(-not $recipe.Count){return (New-DomeniaBoardEntry -Key $Id -Kind Number -Value 'Requête absente' -Detail 'Ouvrez lʼatelier pour enregistrer une requête.' -State Off)}
    $count=if($q.Widgets.ContainsKey($Id)){$q.Widgets[$Id]}else{$null}
    if($null -ne $count -and $count.Error){return (New-DomeniaBoardEntry -Key $Id -Title $recipe[0].Name -Kind Number -Value 'Calcul à préciser' -Detail ('Réduisez le périmètre ou les catégories : '+$count.Error) -State Warn)}
    if($null -eq $count -or $q.SnapshotKey -ne [string]$script:FleetQuerySnapshotKey){return (New-DomeniaBoardEntry -Key $Id -Title $recipe[0].Name -Kind Number -Value 'À calculer' -Detail 'Exécuter la requête dans lʼatelier.' -State Off)}
    return (ConvertTo-DomeniaQueryCountEntry -Id $Id -Title $recipe[0].Name -Count $count -Visual $Visual -Context ([string]$count.Total+' postes recensés dans lʼOU'))
}
function Test-DomeniaSearchQueryRow {
    param($Row)
    $q=$script:DomeniaQueryState;if($null -eq $q -or $null -eq $q.SearchRecipe){return $true}
    if([string](Get-DomeniaMember $Row 'Type') -ne 'Machine'){return $false}
    $guid=([string](Get-DomeniaMember $Row 'Guid')).Trim().Trim('{','}').ToLowerInvariant()
    return ($guid -and $q.SearchRecords.ContainsKey($guid))
}
function Show-DomeniaFleetWidgetDetails {
    param($Item,$Selection=$null)
    try{
        Initialize-DomeniaQueryWorkshop
        $key=[string]$Item.Key;$label=[string](Get-DomeniaMember $Selection 'Label')
        $targets=Get-DomeniaMemberValue $script:FleetLast 'WidgetTargets'
        $targetKey=if($null -ne $Selection -and $label){$key+'|'+$label}else{$key}
        $labels=@(Get-DomeniaMember $Selection 'Labels' @())
        # Point 73: the exact GUID list kept with the calculation, named with the count it showed and its date.
        $computedAt=Get-DomeniaMemberValue (Get-DomeniaMemberValue $script:FleetLast 'Freshness') 'ComputedAtUtc'
        $widgetTitle=[string](Get-DomeniaMember $Item 'Title' '');if(-not $widgetTitle){$catalogItem=Get-DomeniaBoardCatalogItem -Board Fleet -Key $key;$widgetTitle=$(if($null -ne $catalogItem){[string]$catalogItem.Title}else{$key})}
        if($Item.Source -ne 'Query' -and $labels.Count -and $targets -is [Collections.IDictionary]){
            $complete=$true;$union=@{}
            foreach($part in $labels){$partKey=$key+'|'+[string]$part;if(-not $targets.Contains($partKey)){$complete=$false;break};foreach($target in @($targets[$partKey])){$id=[string]$target.object_guid;if($id){$union[$id]=$target}}}
            if($complete){Show-DomeniaAttentionInWorkshop -Targets @($union.Values) -Label (Format-DomeniaWidgetDetailLabel -Title ($widgetTitle+' · '+$label) -Count $union.Count -ComputedAtUtc $computedAt);return}
            throw 'Ce regroupement ne possède pas tous ses détails ; recalculez le tableau de bord.'
        }
        if($Item.Source -ne 'Query' -and $null -ne $targets -and $targets -is [Collections.IDictionary] -and $targets.Contains($targetKey)){
            $title=$widgetTitle;if($label){$title+=' · '+$label}
            Show-DomeniaAttentionInWorkshop -Targets @($targets[$targetKey]) -Label (Format-DomeniaWidgetDetailLabel -Title $title -Count @($targets[$targetKey]).Count -ComputedAtUtc $computedAt)
            return
        }
        if($key -eq 'fleet.health'){
            $healthy=@(Get-DomeniaMember $script:FleetLast 'HealthyTargets' @())
            Show-DomeniaAttentionInWorkshop -Targets $healthy -Label (Format-DomeniaWidgetDetailLabel -Title 'Sans point détecté dans les données disponibles' -Count $healthy.Count -ComputedAtUtc $computedAt)
            return
        }
        if($key -eq 'fleet.attention'){
            $targets=@{}
            foreach($point in (Get-DomeniaBoardState Fleet).Data.Attention){foreach($target in @(Get-DomeniaAttentionTargets $point)){$targets[[string]$target.object_guid]=$target}}
            Show-DomeniaAttentionInWorkshop -Targets @($targets.Values) -Label (Format-DomeniaWidgetDetailLabel -Title 'Postes concernés par les points dʼattention' -Count $targets.Count -ComputedAtUtc $computedAt)
            return
        }
        if($key -like 'fleet.trend*'){
            $entry=(Get-DomeniaBoardState Fleet).Data.Entries[$key]
            Show-DomeniaDialog -Title 'Mesures quotidiennes' -Message 'Ces compteurs sont des instantanés agrégés. Les identités des postes à cette date ne sont pas conservées.' -Details (($entry.Items|ForEach-Object{[string]$_.Label+' : '+[string]$_.Value}) -join "`r`n") -Kind Info|Out-Null;return
        }
        if($Item.Source -eq 'Query'){
            $recipe=@($script:DomeniaQueryState.Saved|Where-Object{$_.Id -eq $key}|Select-Object -First 1)
            if(-not $recipe.Count){throw 'Cette requête enregistrée est absente.'};$recipe=$recipe[0]
            $segments=@(Get-DomeniaMember $Selection 'Selections' @())
            if($segments.Count){
                $q=$script:DomeniaQueryState
                if($null -eq $q.Records -or $q.SnapshotKey -cne [string]$script:FleetQuerySnapshotKey){throw 'Recalculez le tableau de bord avant de détailler ce regroupement.'}
                $union=@{}
                foreach($segment in $segments){if(-not [string](Get-DomeniaMember $segment 'Field')){throw 'Définition de segment manquante.'};$part=New-DomeniaQuerySegmentRecipe $recipe $segment;$matches=Get-DomeniaQueryMatchIds -Records $q.Records -Recipe $part;foreach($id in $matches.Keys){$union[$id]=$true}}
                $recipe=New-DomeniaQueryRecipe -Name ($recipe.Name.Substring(0,[Math]::Min(105,$recipe.Name.Length))+' · Autres') -Clauses @($recipe.Clauses) -Junction $recipe.Junction -GroupBy ([string](Get-DomeniaMember $recipe 'GroupBy')) -Refinements @(Get-DomeniaMember $recipe 'Refinements' @()) -ProbeSelection (Get-DomeniaMemberValue $recipe 'ProbeSelection') -ObjectIds @($union.Keys)
            }elseif($null -ne $Selection -and [string](Get-DomeniaMember $Selection 'Field')){$recipe=New-DomeniaQuerySegmentRecipe $recipe $Selection}
        }else{
            $clauses=[Collections.Generic.List[object]]::new()
            if($key -ne 'fleet.machines' -and $key -ne 'fleet.disabled'){$clauses.Add([pscustomobject]@{Field='active';Operator='Equal';Value=$true})}
            $field='';$op='IsPresent';$value=$null;$probeSelection=$null
            if($Item.Source -eq 'Probe'){
                $field='probe:'+$key;$probe=Get-DomeniaProbe $key
                if($null -ne $Selection){
                    $probeSelection=[pscustomobject]@{Key=$key;Mode='Equal';Value=$label}
                    if($null -ne $Selection.PSObject.Properties['Low']){
                        $probeSelection=[pscustomobject]@{Key=$key;Mode='Range';Low=$(if([double]::IsNegativeInfinity($Selection.Low)){$null}else{[double]$Selection.Low});High=$(if([double]::IsPositiveInfinity($Selection.High)){$null}else{[double]$Selection.High})}
                    }elseif($null -ne $Selection.PSObject.Properties['Excluded']){$probeSelection=[pscustomobject]@{Key=$key;Mode='Other';Excluded=@($Selection.Excluded)}}
                    elseif($null -ne $Selection.PSObject.Properties['ExactValue']){$probeSelection.Value=$Selection.ExactValue}
                }
            }else{
                switch($key){
                    'fleet.machines'{}
                    'fleet.disabled'{$field='active';$op='Equal';$value=$false}
                    'fleet.stale'{$field='logonBucket';$op='GreaterOrEqual';$value=3;$clauses.Add([pscustomobject]@{Field='logonBucket';Operator='LessOrEqual';Value=4})}
                    'fleet.created'{$field='createdRecent';$op='Equal';$value=$true}
                    'fleet.pwdold'{$field='passwordOld';$op='Equal';$value=$true}
                    'fleet.laps'{$field='laps';$op='Equal';$value='N'}
                    'fleet.bitlocker'{$field='bitlocker';$op='Equal';$value='N'}
                    'fleet.win10'{$field='win10';$op='Equal';$value=$true}
                    'fleet.eos'{$field='lifeStatus';$op='Equal';$value='Ended'}
                    'fleet.lowdisk'{$field='diskFreePercent';$op='Less';$value=[double](Get-DomeniaBoardThresholds).DiskFreeAlert}
                    'fleet.uptime'{$field='uptimeDays';$op='Greater';$value=30}
                    'fleet.lastcheck'{$field='checkedDays'}
                    'fleet.users'{$field='user'}
                    'fleet.os'{$field='osLabel'}
                    'fleet.versions'{$field='release'}
                    'fleet.servers'{$field='osFamily'}
                    'fleet.ou'{$field='site'}
                    'fleet.models'{$field='model'}
                    'fleet.presence'{$field='presenceBucket'}
                    'fleet.releases'{$field='observedRelease'}
                    'fleet.lastlogon'{$field='logonBucket';if($null -ne $Selection){$op='Equal';$value=[int]$Selection.Index}}
                    'fleet.ram'{$field='ramGB';if($null -ne $Selection){$bounds=@(0.0,4.5,8.5,16.5,32.5,[double]::PositiveInfinity);$index=[int]$Selection.Index;$clauses.Add([pscustomobject]@{Field=$field;Operator='Greater';Value=$bounds[$index]});if($index -lt 4){$op='LessOrEqual';$value=$bounds[$index+1]}}}
                    'fleet.diskfree'{$field='diskFreePercent';if($null -ne $Selection){$limits=Get-DomeniaBoardThresholds;$bounds=@(0.0,[double]$limits.DiskFreeAlert,[double]$limits.DiskFreeWarn,50.0,101.0);$index=[int]$Selection.Index;$clauses.Add([pscustomobject]@{Field=$field;Operator='GreaterOrEqual';Value=$bounds[$index]});$op='Less';$value=$bounds[$index+1]}}
                }
                if($label -and $field -in @('osLabel','release','osFamily','site','model','presenceBucket','observedRelease')){
                    if($label -eq 'Autres'){
                        $entry=(Get-DomeniaBoardState Fleet).Data.Entries[$key]
                        foreach($part in @($entry.Items|Where-Object{$_.Label -ne 'Autres'})){$clauses.Add([pscustomobject]@{Field=$field;Operator='NotEqual';Value=[string]$part.Label})}
                    }else{$op='Equal';$value=$label}
                }
            }
            if($field){$clauses.Add([pscustomobject]@{Field=$field;Operator=$op;Value=$value})}
            $name=if($Item.Title){[string]$Item.Title}elseif($Item.Source -eq 'Probe'){[string](Get-DomeniaProbe $key).Name}else{[string](Get-DomeniaBoardCatalogItem Fleet $key).Title}
            if($key -eq 'fleet.users'){$name='Postes avec un utilisateur console observé'}
            if($label){$name+=' · '+$label}
            $recipe=New-DomeniaQueryRecipe -Name $name -Clauses $clauses.ToArray() -ProbeSelection $probeSelection
        }
        Set-DomeniaQueryDraft $recipe
        (Get-DomeniaControl 'TxtFleetMachineFilter').Text='';(Get-DomeniaControl 'CmbFleetMachineState').SelectedIndex=0;(Get-DomeniaControl 'CmbQueryResult').SelectedIndex=0
        Show-DomeniaQueryWorkshop -Evaluate
    }catch{Set-Status ('Détail du widget : '+$_.Exception.Message) 'WARN'}
}

function Get-DomeniaQuerySelectedRow {
    $q=$script:DomeniaQueryState
    if($null -eq $q -or $q.Busy -or $null -eq $q.Result -or $q.SnapshotKey -ne [string]$script:FleetQuerySnapshotKey){throw 'Exécutez la requête pour actualiser les objets disponibles.'}
    $row=(Get-DomeniaControl 'DgFleetMachines').SelectedItem
    if($null -eq $row -or -not $row.Id -or -not $row.distinguished_name){throw 'Sélectionnez un poste dans le tableau.'}
    return $row
}
function Show-DomeniaQueryObjectDetails {
    $fields=Get-DomeniaControl 'DgQueryObjectFields';if($null -eq $fields){return}
    $row=(Get-DomeniaControl 'DgFleetMachines').SelectedItem
    $explanation=Get-DomeniaControl 'DgQueryExplanation';if($null -ne $explanation){$explanation.ItemsSource=@()}
    if($null -eq $row){$fields.ItemsSource=@();[void](Set-DomeniaControlText 'LblQueryObject' 'Sélectionnez un poste pour consulter ses données.');return}
    $q=$script:DomeniaQueryState
    $record=$null;foreach($candidate in $q.Records){if($candidate.Id -ceq [string]$row.Id){$record=$candidate;break}}
    if($null -eq $record){return}
    $fields.ItemsSource=@(foreach($definition in @(Get-DomeniaQueryFields)){
        $presentation=Get-DomeniaQueryValuePresentation -Record $record -Field $definition.Id
        [pscustomobject]@{Name=$definition.Name;Value=$presentation.Value;State=$presentation.State;ObservedAt=$presentation.ObservedAt}
    })
    $exportRequest=Get-DomeniaMemberValue $q 'ExportRequest'
    if($null -ne $explanation -and $null -ne $exportRequest){$evaluatedRecipe=ConvertFrom-Json -InputObject ([string]$exportRequest.RecipeJson);$explanation.ItemsSource=@(Get-DomeniaQueryExplanation -Record $record -Recipe $evaluatedRecipe)}
    [void](Set-DomeniaControlText 'LblQueryObject' ([string]$row.name+' · GUID '+[string]$row.Id+"`n"+[string]$row.distinguished_name+"`n"+'Calcul local du '+$q.At.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss')+'. Ouvrir la fiche AD relit cet objet avant toute action.'))
}

function Show-DomeniaAttentionInWorkshop {
    param([object[]]$Targets=@(),[string]$Label='')
    try{
        Initialize-DomeniaQueryWorkshop
        $ids=@($Targets|ForEach-Object{[string]$_.object_guid}|Select-Object -Unique)
        $name='Sélection : '+$Label;if($name.Length -gt 120){$name=$name.Substring(0,120)}
        $recipe=New-DomeniaQueryRecipe -Name $name -ObjectIds $ids
        [void](ConvertTo-DomeniaCompiledQuery $recipe)
        Set-DomeniaQueryDraft $recipe
        (Get-DomeniaControl 'TxtFleetMachineFilter').Text=''
        (Get-DomeniaControl 'CmbFleetMachineState').SelectedIndex=0
        (Get-DomeniaControl 'CmbQueryResult').SelectedIndex=0
        Show-DomeniaQueryWorkshop -Evaluate
    }catch{Set-Status ('Détail des postes : '+$_.Exception.Message) 'WARN'}
}

function Initialize-DomeniaQueryAdvanced {
    foreach($entry in @(@('BtnQueryGroupAll','All'),@('BtnQueryGroupAny','Any'),@('BtnQueryGroupNot','Not'),@('BtnQueryTreeCondition','Clause'),@('BtnQueryTreeRemove','Remove'),@('BtnQueryTreeUp','Up'),@('BtnQueryTreeDown','Down'),@('BtnQueryTreeClear','Clear'),@('BtnQueryCollectionAdd','Collection'),@('BtnQueryInstanceAdd','Instance'),@('BtnQueryParameterAdd','Parameter'),@('BtnQueryParameterFreeze','Freeze'))){
        $control=Get-DomeniaControl $entry[0];if($null -ne $control){$control.Tag=$entry[1];$control.Add_Click({param($sender,$eventArgs)Invoke-DomeniaQueryAdvancedAction ([string]$sender.Tag)})}
    }
    $probe=Get-DomeniaControl 'CmbQueryCollectionProbe'
    if($null -ne $probe){$probe.ItemsSource=@(Get-DomeniaProbeCatalog|Where-Object{@($_.Properties).Count}|Sort-Object Name);$probe.Add_SelectionChanged({Update-DomeniaQueryInstanceFields});$probe.SelectedIndex=0}
    $field=Get-DomeniaControl 'CmbQueryInstanceField';if($null -ne $field){$field.Add_SelectionChanged({$f=(Get-DomeniaControl 'CmbQueryInstanceField').SelectedItem;$operator=Get-DomeniaControl 'CmbQueryInstanceOperator';$operator.ItemsSource=@(if($null -ne $f){Get-DomeniaQueryOperators $f.Kind});$operator.SelectedIndex=0})}
    Update-DomeniaQueryInstanceFields
}
function Update-DomeniaQueryInstanceFields {
    $probe=(Get-DomeniaControl 'CmbQueryCollectionProbe').SelectedItem;$fields=Get-DomeniaControl 'CmbQueryInstanceField'
    if($null -ne $fields){$fields.ItemsSource=@(Get-DomeniaQueryInstanceFields|Where-Object{$_.ProbeId -eq [string]$probe.Id});$fields.SelectedIndex=0}
}
function Update-DomeniaQueryAdvancedDraft {
    param($Recipe)
    $tree=Get-DomeniaControl 'LstQueryExpression';if($null -ne $tree){$tree.ItemsSource=@(Get-DomeniaQueryExpressionOutline (Get-DomeniaMemberValue $Recipe 'Expression'));if($tree.ItemsSource.Count){$tree.SelectedIndex=0}}
    $parameters=Get-DomeniaControl 'DgQueryParameters'
    if($null -ne $parameters){$fields=@{};foreach($field in @(@(Get-DomeniaQueryFields)+@(Get-DomeniaQueryInstanceFields))){$fields[$field.Id]=$field};$parameters.ItemsSource=@(foreach($parameter in @(Get-DomeniaMember $Recipe 'Parameters' @())){[pscustomobject]@{Name=$parameter.Name;Field=$parameter.Field;FieldName=[string]$fields[[string]$parameter.Field].Name;Value=(Get-DomeniaMemberValue (Get-DomeniaMemberValue $Recipe 'ParameterValues') ([string]$parameter.Name) (Get-DomeniaMemberValue $parameter 'Default'))}})}
    $coherence=Get-DomeniaControl 'TxtQueryCoherenceHours';if($null -ne $coherence){$coherence.Text=[Convert]::ToString((Get-DomeniaMemberValue $Recipe 'CoherenceHours'),[Globalization.CultureInfo]::InvariantCulture)}
}
function New-DomeniaQueryUiClause {
    param([switch]$Instance)
    $prefix=if($Instance){'Instance'}else{''}
    $field=(Get-DomeniaControl ('CmbQuery'+$prefix+'Field')).SelectedItem;$operator=(Get-DomeniaControl ('CmbQuery'+$prefix+'Operator')).SelectedItem
    if($null -eq $field -or $null -eq $operator){throw 'Choisissez une information et un opérateur.'}
    $value=[string](Get-DomeniaControl ('TxtQuery'+$prefix+'Value')).Text
    if($operator.Id -in @('IsMissing','IsPresent')){$value=$null}
    elseif($field.Kind -eq 'Number'){$value=ConvertTo-DomeniaQueryNumber -Text $value -Field $field.Id}
    elseif($field.Kind -eq 'Boolean'){if($value.Trim() -match '^(?i:true|vrai|oui|1)$'){$value=$true}elseif($value.Trim() -match '^(?i:false|faux|non|0)$'){$value=$false}else{throw 'Saisissez Oui ou Non.'}}
    [pscustomobject]@{Kind='Clause';Clause=[pscustomobject]@{Field=$field.Id;Operator=$operator.Id;Value=$value}}
}
function Invoke-DomeniaQueryAdvancedAction {
    param([string]$Action)
    try{
        $recipe=Get-DomeniaQueryDraft;$selected=(Get-DomeniaControl 'LstQueryExpression').SelectedItem;$path=if($null -ne $selected){[string]$selected.Path}else{''};$node=$null
        switch($Action){
            'Parameter'{
                $index=(Get-DomeniaControl 'DgQueryConditions').SelectedIndex
                if($index -lt 0 -or $index -ge @($recipe.Clauses).Count){throw 'Sélectionnez un critère simple à paramétrer.'}
                $name=([string](Get-DomeniaControl 'TxtQueryParameterName').Text).Trim()
                if($name -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$' -or @($recipe.Parameters|Where-Object{$_.Name -ieq $name}).Count){throw 'Choisissez un nom de paramètre unique : une lettre, puis lettres, chiffres ou tiret bas.'}
                $clause=$recipe.Clauses[$index];if($clause.Operator -in @('IsMissing','IsPresent') -or $null -ne (Get-DomeniaMemberValue $clause.Value 'Parameter')){throw 'Ce critère ne reçoit pas de nouveau paramètre.'}
                $recipe.Parameters=@($recipe.Parameters)+@([pscustomobject]@{Name=$name;Field=$clause.Field;Default=$clause.Value});$clause.Value=[pscustomobject]@{Parameter=$name};$recipe.Format='Domenia.Query/2'
                [void](ConvertTo-DomeniaCompiledQuery $recipe);Set-DomeniaQueryDraft $recipe;return
            }
            'Freeze'{$recipe=Resolve-DomeniaQueryParameters $recipe;Set-DomeniaQueryDraft $recipe;return}
            'All'{$node=[pscustomobject]@{Kind='All';Children=@()}}
            'Any'{$node=[pscustomobject]@{Kind='Any';Children=@()}}
            'Not'{$node=[pscustomobject]@{Kind='Not';Children=@([pscustomobject]@{Kind='All';Children=@()})}}
            'Collection'{
                $probe=(Get-DomeniaControl 'CmbQueryCollectionProbe').SelectedItem;if($null -eq $probe){throw 'Choisissez une collection.'}
                $node=[pscustomobject]@{Kind='Collection';CollectionField=('probe:'+$probe.Id);Quantifier=[string](Get-DomeniaControl 'CmbQueryQuantifier').SelectedItem.Tag;Children=@([pscustomobject]@{Kind='All';Children=@()})}
            }
            'Clause'{$node=New-DomeniaQueryUiClause}
            'Instance'{$node=New-DomeniaQueryUiClause -Instance}
        }
        $operation=if($Action -in @('Remove','Up','Down','Clear')){$Action}else{'Add'}
        $updated=Edit-DomeniaQueryExpression -Recipe $recipe -Path $path -Operation $operation -Node $node
        Set-DomeniaQueryDraft $updated
        $tree=Get-DomeniaControl 'LstQueryExpression';foreach($row in @($tree.ItemsSource)){if($row.Path -ceq $path){$tree.SelectedItem=$row;break}}
        [void](Set-DomeniaControlText 'LblQueryStatus' 'Conditions mises à jour. Consultez l''aperçu local avant d''enregistrer.')
    }catch{[void](Set-DomeniaControlText 'LblQueryStatus' ('Condition non appliquée : '+$_.Exception.Message))}
}
