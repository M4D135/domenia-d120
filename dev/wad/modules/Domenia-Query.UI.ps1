# Shared query workshop. Expensive record preparation and evaluation run in LocalQuery, never in an input event.
$script:DomeniaQueryModuleRoot=$PSScriptRoot
$script:DomeniaQueryState=$null
function Initialize-DomeniaQueryWorkshop {
    if($null -ne $script:DomeniaQueryState){return}
    $saved=@();$errorText=''
    try{$saved=@(ConvertFrom-DomeniaQueryLibrary ([string](Get-DomeniaSetting 'Query.Library' '')))}catch{$errorText='Bibliothèque illisible, conservée sans modification : '+$_.Exception.Message}
    $script:DomeniaQueryState=[pscustomobject]@{Recipe=(New-DomeniaQueryRecipe);Saved=$saved;LibraryError=$errorText;Records=$null;SnapshotKey='';At=[datetime]::MinValue;WidgetLibrary='';SortField='name';SortDescending=$false;Generation=0;Widgets=@{};Result=$null;Offset=0;Job='';Busy=$false;Timer=$null;Bound=$false;SearchRecipe=$null;SearchRefinement=$null;SearchRecords=@{};SearchUnknown=0;SearchAt=[datetime]::MinValue;SearchSnapshotKey=''}
    $script:DomeniaQueryState|Add-Member -NotePropertyName ProbeWidgets -NotePropertyValue @{}
    $script:DomeniaQueryState|Add-Member -NotePropertyName ProbeLibrary -NotePropertyValue ''
    $fields=Get-DomeniaControl 'CmbQueryField'
    if($null -eq $fields){return}
    $fields.ItemsSource=@(Get-DomeniaQueryFields);$fields.DisplayMemberPath='Name';$fields.SelectedIndex=0
    $fields.Add_SelectionChanged({Update-DomeniaQueryOperators})
    (Get-DomeniaControl 'CmbQueryOperator').Add_SelectionChanged({$op=(Get-DomeniaControl 'CmbQueryOperator').SelectedItem;(Get-DomeniaControl 'TxtQueryValue').IsEnabled=($null -ne $op -and [string]$op.Id -notin @('IsMissing','IsPresent'))})
    Update-DomeniaQueryOperators
    foreach($entry in @(
        @('BtnQueryNew','New'),@('BtnQueryLoad','Load'),@('BtnQuerySave','Save'),@('BtnQueryDelete','Delete'),
        @('BtnQueryAddCondition','Add'),@('BtnQueryRemoveCondition','Remove'),@('BtnQueryRun','Run'),
        @('BtnQueryWidget','Widget'),@('BtnQueryCollect','Collect'),@('BtnQueryPrevious','Previous'),@('BtnQueryNext','Next'),
        @('BtnQueryClearSegment','ClearSegment'),@('BtnQueryObjectOpen','OpenObject'),@('BtnQueryObjectCollect','CollectObject'),@('BtnQueryObjectCopy','CopyObject'),
        @('BtnQueryExport','Export'),@('BtnQueryApplySearch','ApplySearch'),@('BtnQueryClearSearch','ClearSearch')
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
    $script:DomeniaQueryState.Bound=$true
    Update-DomeniaQueryLibraryControls
    Set-DomeniaQueryDraft $script:DomeniaQueryState.Recipe
    if($errorText){[void](Set-DomeniaControlText 'LblQueryStatus' $errorText)}
}
function Update-DomeniaQueryOperators {
    $field=(Get-DomeniaControl 'CmbQueryField').SelectedItem
    if($null -eq $field){return}
    $combo=Get-DomeniaControl 'CmbQueryOperator';$combo.ItemsSource=@(Get-DomeniaQueryOperators $field.Kind);$combo.DisplayMemberPath='Name';$combo.SelectedIndex=0
}
function Update-DomeniaQueryLibraryControls {
    $q=$script:DomeniaQueryState;if($null -eq $q){return}
    $combo=Get-DomeniaControl 'CmbFleetQuery'
    if($null -ne $combo){$combo.ItemsSource=@(@(Get-DomeniaQueryTemplates)+@($q.Saved));$combo.DisplayMemberPath='Name';$combo.SelectedIndex=0}
    foreach($name in @('BtnQuerySave','BtnQueryDelete','BtnQueryWidget')){$c=Get-DomeniaControl $name;if($null -ne $c){$c.IsEnabled=(-not $q.LibraryError)}}
}
function Reset-DomeniaQueryResults {
    # Clear counts and navigation together: an empty draft must not keep a previous page's total.
    $results=Get-DomeniaControl 'DgFleetMachines';if($null -ne $results){$results.ItemsSource=@()}
    [void](Set-DomeniaControlText 'LblFleetMachineCount' 'Aucun résultat calculé · exécutez la requête.')
    foreach($name in @('BtnQueryPrevious','BtnQueryNext')){$button=Get-DomeniaControl $name;if($null -ne $button){$button.IsEnabled=$false}}
    $details=Get-DomeniaControl 'DgQueryObjectFields';if($null -ne $details){$details.ItemsSource=@()}
    [void](Set-DomeniaControlText 'LblQueryObject' 'Sélectionnez un poste pour consulter ses données.')
}
function Set-DomeniaQueryDraft {
    param($Recipe)
    $q=$script:DomeniaQueryState;if($null -eq $q){return}
    $q.Recipe=$Recipe;$q.Offset=0;$q.Generation++;$q.Result=$null;$q.Busy=$false
    Reset-DomeniaQueryResults
    $title=Get-DomeniaControl 'TxtFleetQueryName';if($null -ne $title){$title.Text=[string]$Recipe.Name}
    $junction=Get-DomeniaControl 'CmbQueryJunction';if($null -ne $junction){$junction.SelectedIndex=$(if($Recipe.Junction -eq 'Any'){1}else{0})}
    $group=Get-DomeniaControl 'CmbQueryGroupField';if($null -ne $group){$group.SelectedIndex=0;foreach($entry in $group.ItemsSource){if($entry.Id -ceq [string](Get-DomeniaMember $Recipe 'GroupBy')){$group.SelectedItem=$entry}}}
    $fields=@{};foreach($field in @(Get-DomeniaQueryFields)){$fields[$field.Id]=$field}
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
    [void](Set-DomeniaControlText 'LblQueryStatus' 'Prêt. Exécuter applique ces conditions aux données locales du périmètre courant.')
}
function Get-DomeniaQueryDraft {
    $q=$script:DomeniaQueryState
    $name=[string](Get-DomeniaControl 'TxtFleetQueryName').Text
    $junction=if((Get-DomeniaControl 'CmbQueryJunction').SelectedIndex -eq 1){'Any'}else{'All'}
    $recipe=New-DomeniaQueryRecipe -Id $q.Recipe.Id -Name $name -Junction $junction -Clauses @($q.Recipe.Clauses) -GroupBy ([string](Get-DomeniaControl 'CmbQueryGroupField').SelectedItem.Id) -Refinements @(Get-DomeniaMember $q.Recipe 'Refinements' @()) -ProbeSelection (Get-DomeniaMemberValue $q.Recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $q.Recipe 'ObjectIds')
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
function Save-DomeniaQueryRecipe {
    param($Recipe)
    $q=$script:DomeniaQueryState
    if($q.LibraryError){throw $q.LibraryError}
    if([string]$Recipe.Id -like 'template.*'){$Recipe=New-DomeniaQueryRecipe -Name $Recipe.Name -Junction $Recipe.Junction -Clauses @($Recipe.Clauses) -GroupBy ([string](Get-DomeniaMember $Recipe 'GroupBy')) -Refinements @(Get-DomeniaMember $Recipe 'Refinements' @()) -ProbeSelection (Get-DomeniaMemberValue $Recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $Recipe 'ObjectIds')}
    $saved=@(@($q.Saved | Where-Object{$_.Id -ne $Recipe.Id})+@($Recipe))
    $json=ConvertTo-DomeniaQueryLibraryJson -Queries $saved
    Save-DomeniaQueryLibraryState $json
    $q.Saved=$saved;$q.Recipe=$Recipe
    # A saved definition changes the meaning of its tile. Never retain counts
    # computed from the previous library, including a callback still in flight.
    $q.Widgets=@{};$q.WidgetLibrary=''
    Update-DomeniaQueryLibraryControls
    try { Show-DomeniaBoard -Board Fleet -Quiet } catch { Write-AppLog ('Actualisation des sondes enregistrées : '+$_.Exception.Message) 'WARN' }
    return $Recipe
}
function Invoke-DomeniaQueryAction {
    param([string]$Action)
    try{
        Initialize-DomeniaQueryWorkshop;$q=$script:DomeniaQueryState
        if($null -ne $q.Timer){$q.Timer.Stop()}
        switch($Action){
            'New'{Set-DomeniaQueryDraft (New-DomeniaQueryRecipe);return}
            'ClearSegment'{$recipe=Get-DomeniaQueryDraft;$recipe.Refinements=@();$recipe|Add-Member NoteProperty ProbeSelection $null -Force;$recipe|Add-Member NoteProperty ObjectIds $null -Force;Set-DomeniaQueryDraft $recipe;return}
            'Load'{$selected=(Get-DomeniaControl 'CmbFleetQuery').SelectedItem;if($null -ne $selected){Set-DomeniaQueryDraft $selected};return}
            'Add'{
                $field=(Get-DomeniaControl 'CmbQueryField').SelectedItem;$op=(Get-DomeniaControl 'CmbQueryOperator').SelectedItem
                if($null -eq $field -or $null -eq $op){throw 'Choisissez un champ et un opérateur.'}
                $value=[string](Get-DomeniaControl 'TxtQueryValue').Text
                if($op.Id -in @('IsMissing','IsPresent')){$value=$null}
                elseif($field.Kind -eq 'Number'){$number=[decimal]0;if(-not [decimal]::TryParse($value.Replace(',','.'),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){throw 'Saisissez un nombre, par exemple 8 ou 10,5.'};$value=$number}
                elseif($field.Kind -eq 'Boolean'){if($value.Trim() -match '^(?i:true|vrai|oui|1)$'){$value=$true}elseif($value.Trim() -match '^(?i:false|faux|non|0)$'){$value=$false}else{throw 'Saisissez Oui ou Non.'}}
                $draft=Get-DomeniaQueryDraft;$draft.Clauses=@($draft.Clauses)+@([pscustomobject]@{Field=$field.Id;Operator=$op.Id;Value=$value})
                [void](ConvertTo-DomeniaCompiledQuery $draft);Set-DomeniaQueryDraft $draft;return
            }
            'Remove'{$grid=Get-DomeniaControl 'DgQueryConditions';$index=$grid.SelectedIndex;if($index -ge 0){$draft=Get-DomeniaQueryDraft;$draft.Clauses=@(for($i=0;$i -lt $draft.Clauses.Count;$i++){if($i -ne $index){$draft.Clauses[$i]}});Set-DomeniaQueryDraft $draft};return}
            'Save'{$recipe=Save-DomeniaQueryRecipe (Get-DomeniaQueryDraft);Set-DomeniaQueryDraft $recipe;[void](Set-DomeniaControlText 'LblQueryStatus' 'Requête enregistrée dans les préférences locales.');return}
            'Delete'{
                $id=[string]$q.Recipe.Id;if($id -like 'template.*'){throw 'Les modèles livrés sont conservés. Enregistrez une copie pour la personnaliser.'}
                if($q.LibraryError){throw $q.LibraryError}
                $saved=@($q.Saved|Where-Object{$_.Id -ne $id});Save-DomeniaQueryLibraryState (ConvertTo-DomeniaQueryLibraryJson $saved);$q.Saved=$saved
                $layout=@(Get-DomeniaBoardLayout Fleet|Where-Object{-not ($_.Source -eq 'Query' -and $_.Key -eq $id)})
                Set-DomeniaBoardLayout -Board Fleet -Layout $layout -Undo 'Suppression de la sonde enregistrée';Update-DomeniaQueryLibraryControls;Set-DomeniaQueryDraft (New-DomeniaQueryRecipe);return
            }
            'Widget'{
                $recipe=Save-DomeniaQueryRecipe (Get-DomeniaQueryDraft);Set-DomeniaQueryDraft $recipe
                $layout=@(Get-DomeniaBoardLayout Fleet)
                if(-not @($layout|Where-Object{$_.Source -eq 'Query' -and $_.Key -eq $recipe.Id}).Count){$item=New-DomeniaBoardItem -Source Query -Key $recipe.Id -Visual $(if($recipe.GroupBy){'Bar'}else{'Kpi'}) -Size M -Group 'Mes sondes' -Title $recipe.Name;Set-DomeniaBoardLayout Fleet -Layout @(Add-DomeniaBoardItem $layout $item) -Undo 'Ajout de la sonde'}
                Start-DomeniaQueryEvaluation;return
            }
            'OpenObject'{$row=Get-DomeniaQuerySelectedRow;Open-AdObject -Dn ([string]$row.distinguished_name) -Type Machine -ObjectGuid ([string]$row.Id) -SuppressRemoteProbes;return}
            'CopyObject'{$row=Get-DomeniaQuerySelectedRow;[Windows.Clipboard]::SetText([string]$row.distinguished_name);return}
            'CollectObject'{$row=Get-DomeniaQuerySelectedRow;$recipe=Get-DomeniaQueryDraft;Start-DomeniaOnlinePark -ScopeTargets @([pscustomobject]@{name=$row.name;distinguished_name=$row.distinguished_name;object_guid=$row.Id}) -ScopeLabel ([string]$row.name) -Inventory -Probes @(ConvertTo-DomeniaProbePayload (Get-DomeniaQueryProbeIds $recipe));return}
            'Collect'{
                $recipe=Get-DomeniaQueryDraft;$ids=@(Get-DomeniaQueryProbeIds $recipe)
                if($null -eq $script:FleetLast){throw 'Chargez dʼabord la base locale du parc.'}
                $targets=@($script:FleetLast.Targets)
                if(-not $targets.Count){throw 'Aucun compte ordinateur actif dans ce périmètre.'}
                Start-DomeniaOnlinePark -ScopeTargets $targets -ScopeLabel ('Atelier : '+(Get-DomeniaFleetScope).Name) -Inventory -Probes @(ConvertTo-DomeniaProbePayload $ids);return
            }
            'Previous'{$q.Offset=[Math]::Max(0,$q.Offset-200);Start-DomeniaQueryEvaluation -KeepPage;return}
            'Next'{if($null -ne $q.Result){$count=switch([string]$q.Result.Selection){'Match'{[long]$q.Result.Matched};'Unknown'{[long]$q.Result.Unknown};default{[long]$q.Result.NotMatched}};if(($q.Offset+200) -lt $count){$q.Offset+=200;Start-DomeniaQueryEvaluation -KeepPage}};return}
            'Export'{if($q.Busy -or $null -eq $q.Result){throw 'Attendez le résultat de la requête.'};$grid=Get-DomeniaControl 'DgFleetMachines';$export=Export-DomeniaCsv -Rows @($grid.ItemsSource) -Grid $grid -Subject $q.Recipe.Name;Show-DomeniaExportResult $export -Scope ('page affichée, '+$q.Result.Selection);return}
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
            'ClearSearch'{$q.SearchRecipe=$null;$q.SearchRefinement=$null;$q.SearchRecords=@{};Apply-DomeniaPresenceFilter;[void](Set-DomeniaControlText 'LblSearchQuery' 'Aucune requête enregistrée appliquée aux résultats.');return}
            default{Start-DomeniaQueryEvaluation}
        }
    }catch{[void](Set-DomeniaControlText 'LblQueryStatus' $_.Exception.Message);Set-Status ('Atelier : '+$_.Exception.Message) 'WARN'}
}
function Request-DomeniaQueryEvaluation {
    $q=$script:DomeniaQueryState;if($null -eq $q -or -not $q.Bound){return}
    if($null -eq $q.Timer){$q.Timer=New-DomeniaTimer -Owner 'Timer:QueryWorkshop' -IntervalMs 350 -SessionBound -Tick {$script:DomeniaQueryState.Timer.Stop();Start-DomeniaQueryEvaluation}}
    $q.Timer.Stop();$q.Timer.Start()
}
function Start-DomeniaQueryEvaluation {
    param([switch]$KeepPage)
    try{
        Initialize-DomeniaQueryWorkshop;$q=$script:DomeniaQueryState
        if($null -ne $q.Timer){$q.Timer.Stop()}
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
        $library=ConvertTo-DomeniaQueryLibraryJson @($q.Saved)
        $widgetCache=if($null -ne $records -and $library -ceq $q.WidgetLibrary){$q.Widgets}else{$null}
        $probeRequests=@(Get-DomeniaBoardLayout Fleet|Where-Object{$_.Source -eq 'Probe'}|Select-Object Key,Visual -Unique)
        $probeLibrary=ConvertTo-Json -InputObject $probeRequests -Compress
        $probeCache=if($null -ne $records -and $probeLibrary -ceq $q.ProbeLibrary){$q.ProbeWidgets}else{$null}
        $payload=[pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;Lifecycle=(Get-DomeniaWindowsLifecycleTable);Fleet=$script:FleetLast;Observations=$script:FleetObservations;Records=$records;Recipe=$recipe;Saved=@($q.Saved);CachedWidgets=$widgetCache;SortField=$q.SortField;Descending=$q.SortDescending;Offset=$q.Offset;Selection=$selection;MaxAgeDays=(Get-DomeniaObservationMaxAgeDays);TextFilter=[string](Get-DomeniaControl 'TxtFleetMachineFilter').Text;StateFilter=[string](Get-DomeniaControl 'CmbFleetMachineState').SelectedItem.Content}
        $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=$q.Generation;SnapshotKey=[string]$script:FleetQuerySnapshotKey;ScopeKey=$scope.Key;RecordsAt=$(if($null -ne $records){$q.At}else{[datetime]::UtcNow});WidgetLibrary=$library}
        $payload|Add-Member -NotePropertyName ProbeRequests -NotePropertyValue $probeRequests
        $payload|Add-Member -NotePropertyName CachedProbeWidgets -NotePropertyValue $probeCache
        $state|Add-Member -NotePropertyName ProbeLibrary -NotePropertyValue $probeLibrary
        $state|Add-Member -NotePropertyName RefreshWidgets -NotePropertyValue ($null -eq $widgetCache -or $null -eq $probeCache)
        $q.Job=Start-UiTask -Name 'Atelier de requêtes : calcul local' -OperationId 'LocalQuery' -Code (Get-DomeniaQueryWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'query:local' -SuccessHandler 'Complete-DomeniaQueryEvaluation' -ErrorHandler 'Fail-DomeniaQueryEvaluation' -TimeoutSeconds 120 -TaskClass 'Explicit'
        if(-not $q.Job){throw 'Calcul non admis, relancez Exécuter.'}
        [void](Set-DomeniaControlText 'LblQueryStatus' ('Calcul local en cours sur '+$scope.Name+'…'))
    }catch{if($null -ne $script:DomeniaQueryState){$script:DomeniaQueryState.Busy=$false};[void](Set-DomeniaControlText 'LblQueryStatus' ('Calcul impossible : '+$_.Exception.Message))}
}
function Complete-DomeniaQueryEvaluation {
    param($Result,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne $q.Generation -or $State.SnapshotKey -ne [string]$script:FleetQuerySnapshotKey -or [string]$State.ScopeKey -ne [string](Get-DomeniaFleetScope).Key){return}
    $r=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows','Matched','Unknown','Records')
    if($null -eq $r){Fail-DomeniaQueryEvaluation 'Résultat local incomplet.' $State;return}
    $q.Busy=$false;$q.Job='';$q.Result=$r;$q.Records=$r.Records;$q.At=[datetime]$State.RecordsAt;$q.SnapshotKey=[string]$State.SnapshotKey
    if ([string]$State.WidgetLibrary -ceq (ConvertTo-DomeniaQueryLibraryJson @($q.Saved))) {
        $q.Widgets=$r.Widgets;$q.WidgetLibrary=[string]$State.WidgetLibrary
    } else { $q.Widgets=@{};$q.WidgetLibrary='' }
    $q.ProbeWidgets=Get-DomeniaMemberValue $r 'ProbeWidgets' @{};$q.ProbeLibrary=[string]$State.ProbeLibrary
    (Get-DomeniaControl 'DgFleetMachines').ItemsSource=@($r.Rows)
    $text='{0} correspondants · {1} inconnus · {2} non correspondants / {3} postes filtrés, {4} recensés dans le périmètre. Page {5}.' -f $r.Matched,$r.Unknown,$r.NotMatched,$r.Total,$r.ScopeTotal,([int]($r.Offset/200)+1)
    [void](Set-DomeniaControlText 'LblFleetMachineCount' ('{0} ligne(s) sur cette page · données locales' -f @($r.Rows).Count))
    [void](Set-DomeniaControlText 'LblQueryStatus' ($text+' Les données expirées ou non lues restent inconnues.'))
    Add-DomeniaUiLog -Area 'Requêtes' -Text ($q.Recipe.Name+' · '+$text+' · calcul local du '+$q.At.ToLocalTime().ToString('dd/MM/yyyy HH:mm:ss'))
    (Get-DomeniaControl 'BtnQueryPrevious').IsEnabled=($q.Offset -gt 0)
    $count=switch([string]$r.Selection){'Match'{[long]$r.Matched};'Unknown'{[long]$r.Unknown};default{[long]$r.NotMatched}}
    (Get-DomeniaControl 'BtnQueryNext').IsEnabled=(($q.Offset+200) -lt $count)
    if([bool](Get-DomeniaMember $State 'RefreshWidgets' $true)){Show-DomeniaBoard -Board Fleet -Quiet}
}
function Fail-DomeniaQueryEvaluation {
    param($Message,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$State.Epoch -ne [long]$script:SessionEpoch -or $State.Generation -ne $q.Generation -or $State.SnapshotKey -ne [string]$script:FleetQuerySnapshotKey -or [string]$State.ScopeKey -ne [string](Get-DomeniaFleetScope).Key){return}
    $q.Busy=$false;$q.Job='';$q.Result=$null
    Reset-DomeniaQueryResults
    [void](Set-DomeniaControlText 'LblQueryStatus' ('Calcul non terminé : '+[string]$Message))
}
function Get-DomeniaQueryBoardEntry {
    param([string]$Id)
    $q=$script:DomeniaQueryState
    $recipe=@(if($null -ne $q){$q.Saved|Where-Object{$_.Id -eq $Id}|Select-Object -First 1})
    if(-not $recipe.Count){return (New-DomeniaBoardEntry -Key $Id -Kind Number -Value 'Requête absente' -Detail 'Ouvrez lʼatelier pour enregistrer une requête.' -State Off)}
    $count=if($q.Widgets.ContainsKey($Id)){$q.Widgets[$Id]}else{$null}
    if($null -ne $count -and $count.Error){return (New-DomeniaBoardEntry -Key $Id -Title $recipe[0].Name -Kind Number -Value 'Calcul à préciser' -Detail ('Réduisez le périmètre ou les catégories : '+$count.Error) -State Warn)}
    if($null -eq $count -or $q.SnapshotKey -ne [string]$script:FleetQuerySnapshotKey){return (New-DomeniaBoardEntry -Key $Id -Title $recipe[0].Name -Kind Number -Value 'À calculer' -Detail 'Exécuter la requête dans lʼatelier.' -State Off)}
    if([string](Get-DomeniaMember $count 'GroupBy')){return (New-DomeniaBoardEntry -Key $Id -Title $recipe[0].Name -Kind Distribution -Value ([string]$count.Matched+' postes') -Items @($count.Items) -CenterText ([string]$count.Matched+' postes') -Detail ('Répartition des correspondants · '+$count.Unknown+' résultats inconnus · clic pour détailler') -State $(if($count.Unknown){'Warn'}else{''}))}
    return (New-DomeniaBoardEntry -Key $Id -Title $recipe[0].Name -Kind Number -Value ([string]$count.Matched) -Number $count.Matched -Detail ('{0} recensés · {1} inconnus · {2} non correspondants' -f $count.Total,$count.Unknown,$count.NotMatched) -State $(if($count.Unknown){'Warn'}else{''}))
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
        if($key -eq 'fleet.health'){
            Show-DomeniaAttentionInWorkshop -Targets @(Get-DomeniaMember $script:FleetLast 'HealthyTargets' @()) -Label 'Sans point détecté dans les données disponibles'
            return
        }
        if($key -eq 'fleet.attention'){
            $targets=@{}
            foreach($point in (Get-DomeniaBoardState Fleet).Data.Attention){foreach($target in @(Get-DomeniaAttentionTargets $point)){$targets[[string]$target.object_guid]=$target}}
            Show-DomeniaAttentionInWorkshop -Targets @($targets.Values) -Label 'Postes concernés par les points dʼattention'
            return
        }
        if($key -like 'fleet.trend*'){
            $entry=(Get-DomeniaBoardState Fleet).Data.Entries[$key]
            Show-DomeniaDialog -Title 'Mesures quotidiennes' -Message 'Ces compteurs sont des instantanés agrégés. Les identités des postes à cette date ne sont pas conservées.' -Details (($entry.Items|ForEach-Object{[string]$_.Label+' : '+[string]$_.Value}) -join "`r`n") -Kind Info|Out-Null;return
        }
        if($Item.Source -eq 'Query'){
            $recipe=@($script:DomeniaQueryState.Saved|Where-Object{$_.Id -eq $key}|Select-Object -First 1)
            if(-not $recipe.Count){throw 'Cette requête enregistrée est absente.'};$recipe=$recipe[0]
            if($null -ne $Selection -and [string](Get-DomeniaMember $Selection 'Field')){$recipe=New-DomeniaQuerySegmentRecipe $recipe $Selection}
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
        (Get-DomeniaControl 'ExpFleetMachines').IsExpanded=$true
        Start-DomeniaQueryEvaluation
        (Get-DomeniaControl 'ExpFleetMachines').BringIntoView()
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
    if($null -eq $row){$fields.ItemsSource=@();[void](Set-DomeniaControlText 'LblQueryObject' 'Sélectionnez un poste pour consulter ses données.');return}
    $q=$script:DomeniaQueryState
    $record=$null;foreach($candidate in $q.Records){if($candidate.Id -ceq [string]$row.Id){$record=$candidate;break}}
    if($null -eq $record){return}
    $fields.ItemsSource=@(foreach($definition in @(Get-DomeniaQueryFields)){
        [pscustomobject]@{Name=$definition.Name;Value=$(if($record.Values.ContainsKey($definition.Id)){[string]$record.Values[$definition.Id]}else{'Inconnu · non lu, expiré ou lecture incomplète'})}
    })
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
        (Get-DomeniaControl 'ExpFleetMachines').IsExpanded=$true
        Start-DomeniaQueryEvaluation
        (Get-DomeniaControl 'ExpFleetMachines').BringIntoView()
    }catch{Set-Status ('Détail des postes : '+$_.Exception.Message) 'WARN'}
}
