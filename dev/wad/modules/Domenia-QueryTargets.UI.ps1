# Shared recipes on the selected workstation. All inputs are already in memory; no directory or endpoint read.
function Get-DomeniaComputerQueryRecords {
    $so=$script:SelectedObject
    $empty=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    if($null -eq $so -or [string]$so.Type -ne 'Machine'){$script:DomeniaComputerQueryLookup=$null;return ,$empty}
    $dn=([string]$so.DN).Trim();$guid=ConvertTo-DomeniaGuidText $so.Safety.Guid
    if(-not $dn -or -not $guid){$script:DomeniaComputerQueryLookup=$null;return ,$empty}
    $machine=[ordered]@{name=[string]$so.Name;distinguished_name=$dn;object_guid=$guid;st='';gid='computer-query';logon=''}
    $group=[ordered]@{gid='computer-query';os='';ver='';lb=5;cr='';pw='';lk='';bk=''}
    $scope=Get-DomeniaRawDnParent $dn;$knownState=$false;$hasGroup=$false
    # Cache only the snapshot lookup, never the query values or observations. The snapshot is immutable after
    # publication; any new fleet, arrays, session, store or selected identity invalidates this bounded lookup.
    $snapshot=$script:FleetLast;$lookup=$script:DomeniaComputerQueryLookup
    if($null -ne $snapshot -and $null -ne $snapshot.PSObject.Properties['Epoch'] -and [long]$snapshot.Epoch -ne [long]$script:SessionEpoch){$snapshot=$null}
    $snapshotMachines=Get-DomeniaMemberValue $snapshot 'Machines';$snapshotGroups=Get-DomeniaMemberValue $snapshot 'Groups'
    $sameLookup=($null -ne $lookup -and $lookup.Guid -ceq $guid -and $lookup.Dn -ieq $dn -and $lookup.Epoch -eq [long]$script:SessionEpoch -and $lookup.Path -ceq [string]$script:DatabaseScopedPath -and [object]::ReferenceEquals($lookup.Fleet,$snapshot) -and [object]::ReferenceEquals($lookup.Machines,$snapshotMachines) -and [object]::ReferenceEquals($lookup.Groups,$snapshotGroups))
    if(-not $sameLookup){
        $row=$null;$matchedGroup=$null
        if($null -ne $snapshot){
            foreach($candidate in $snapshotMachines){if([string]$candidate.object_guid -ieq $guid -and [string]$candidate.distinguished_name -ieq $dn){$row=$candidate;break}}
            if($null -ne $row){foreach($candidate in $snapshotGroups){if([string]$candidate.gid -eq [string]$row.gid){$matchedGroup=$candidate;break}}}
        }
        $lookup=[pscustomobject]@{Guid=$guid;Dn=$dn;Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;Fleet=$snapshot;Machines=$snapshotMachines;Groups=$snapshotGroups;Row=$row;Group=$matchedGroup}
        $script:DomeniaComputerQueryLookup=$lookup
    }
    # Copy matching values before applying newer selected-object attributes. Shared fleet rows stay untouched.
    if($null -ne $lookup.Row){
        foreach($key in @('name','st','logon')){$machine[$key]=[string](Get-DomeniaMember $lookup.Row $key)}
        $knownState=([string]$machine.st -in @('A','D'))
        $scope=[string](Get-DomeniaMember $snapshot 'Scope')
        if($null -ne $lookup.Group){foreach($key in @('os','ver','lb','cr','pw','lk','bk')){$group[$key]=Get-DomeniaMember $lookup.Group $key};$hasGroup=$true}
    }
    # A materialized attribute dictionary is safe to inspect; never touch a live DirectoryEntry property collection.
    $properties=$null
    if($null -ne $so.Entry -and $so.Entry.GetType().FullName -ne 'System.DirectoryServices.DirectoryEntry'){$properties=Get-DomeniaMemberValue $so.Entry 'Properties'}
    if($properties -is [Collections.IDictionary]){
        $attrs=@{};foreach($key in $properties.Keys){$list=@($properties[$key]);if($list.Count){$attrs[[string]$key]=$list[0]}}
        foreach($pair in @(@('operatingSystem','os'),@('operatingSystemVersion','ver'))){if($attrs.ContainsKey($pair[0])){$group[$pair[1]]=[string]$attrs[$pair[0]];$hasGroup=$true}}
        $uac=0L;if($attrs.ContainsKey('userAccountControl') -and [long]::TryParse([string]$attrs['userAccountControl'],[ref]$uac)){$machine.st=if(($uac -band 2) -eq 0){'A'}else{'D'};$knownState=$true}
    }
    # Convert the final OS/build once so osLabel, release, family, lifecycle and win10 stay consistent.
    $fleet=[pscustomobject]@{Machines=@([pscustomobject]$machine);Groups=@(if($hasGroup){[pscustomobject]$group});Scope=$scope}
    $observations=@{};if($null -ne $script:FleetObservations -and $script:FleetObservations.ContainsKey($dn.ToLowerInvariant())){$observations[$dn.ToLowerInvariant()]=$script:FleetObservations[$dn.ToLowerInvariant()]}
    $records=ConvertTo-DomeniaQueryRecords -Fleet $fleet -Observations $observations -MaxAgeDays (Get-DomeniaObservationMaxAgeDays) -Lifecycle (Get-DomeniaWindowsLifecycleTable)
    if($records.Count -and -not $knownState){
        # QueryRecord.Values is immutable. Build a new record instead of editing the common DLL's read-only view.
        $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($pair in $records[0].Values.GetEnumerator()){if($pair.Key -ne 'active'){$values[$pair.Key]=$pair.Value}}
        $clean=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
        $clean.Add([M4D.Admin.Common.Query.QueryRecord]::new($records[0].Id,$values));return ,$clean
    }
    return ,$records
}
function ConvertTo-DomeniaQueryCountEntry {
    param([string]$Id,[string]$Title,$Count,[string]$Visual='Kpi',[string]$Context='')
    $detail=$Context+' · '+('{0} correspondant(s), {1} inconnu(s), {2} non correspondant(s)' -f $Count.Matched,$Count.Unknown,$Count.NotMatched)
    $state=if($Count.Unknown){'Warn'}else{''}
    if([string]$Count.GroupBy -or $Visual -in @('Bar','Pie','Column')){
        $items=if([string]$Count.GroupBy){@($Count.Items)}else{@([pscustomobject]@{Label='Correspondants';Value=[double]$Count.Matched},[pscustomobject]@{Label='Inconnus';Value=[double]$Count.Unknown},[pscustomobject]@{Label='Non correspondants';Value=[double]$Count.NotMatched})}
        $represented=if([string]$Count.GroupBy){$Count.Matched}else{$Count.Total}
        return (New-DomeniaBoardEntry -Key $Id -Title $Title -Kind Distribution -Value ([string]$Count.Matched) -Items $items -CenterText ([string]$represented+' poste(s)') -Detail $detail -State $state)
    }
    return (New-DomeniaBoardEntry -Key $Id -Title $Title -Kind Number -Value ([string]$Count.Matched) -Number $Count.Matched -Detail $detail -State $state)
}
function Get-DomeniaComputerQueryBoardEntry {
    param([string]$Id,[string]$Visual='Kpi')
    $q=$script:DomeniaQueryState
    $recipe=@(if($null -ne $q){$q.Saved|Where-Object{$_.Id -eq $Id}|Select-Object -First 1})
    if(-not $recipe.Count){return (New-DomeniaBoardEntry -Key $Id -Kind Number -Value 'Requête absente' -Detail 'Enregistrez une requête dans lʼatelier.' -State Off)}
    try{
        # One local record is inexpensive; rebuilding avoids stale identity, context or observation caches.
        $records=Get-DomeniaComputerQueryRecords
        if(-not $records.Count){return (New-DomeniaBoardEntry -Key $Id -Title $recipe[0].Name -Kind Number -Value 'Choisir un poste' -Detail 'Ouvrez une fiche de poste pour évaluer cette requête.' -State Off)}
        $count=Measure-DomeniaQueryWidget -Records $records -Recipe $recipe[0]
        return (ConvertTo-DomeniaQueryCountEntry -Id $Id -Title $recipe[0].Name -Count $count -Visual $Visual -Context ([string]$script:SelectedObject.Name+' · données locales'))
    }catch{return (New-DomeniaBoardEntry -Key $Id -Title $recipe[0].Name -Kind Number -Value 'Calcul indisponible' -Detail $_.Exception.Message -State Warn)}
}
function Show-DomeniaWorkshopComputerPreview {
    try{
        $records=Get-DomeniaComputerQueryRecords
        if(-not $records.Count){[void](Set-DomeniaControlText 'LblQueryComputerPreview' 'Ouvrez la fiche dʼun poste pour tester cette requête sur ses données locales.');return}
        $recipe=Get-DomeniaQueryDraft;$count=Measure-DomeniaQueryWidget -Records $records -Recipe $recipe
        $result=if(-not $count.Total){'hors de la sélection enregistrée'}elseif($count.Unknown){'résultat inconnu : une information manque ou a expiré'}elseif($count.Matched){'correspond à la requête'}else{'ne correspond pas à la requête'}
        [void](Set-DomeniaControlText 'LblQueryComputerPreview' ([string]$script:SelectedObject.Name+' : '+$result+'. Évaluation locale, aucune collecte lancée.'))
    }catch{[void](Set-DomeniaControlText 'LblQueryComputerPreview' ('Aperçu indisponible : '+$_.Exception.Message))}
}
function Show-DomeniaComputerQueryWorkshop {
    param([string]$RecipeId='')
    Show-DomeniaQueryWorkshop
    if($RecipeId){$recipe=@($script:DomeniaQueryState.Saved|Where-Object{$_.Id -eq $RecipeId}|Select-Object -First 1);if($recipe.Count){Set-DomeniaQueryDraft $recipe[0]}}
    $tabs=Get-DomeniaControl 'QueryWorkspaceTabs';if($null -ne $tabs){$tabs.SelectedItem=Get-DomeniaControl 'TabQueryCompose'}
    $destination=Get-DomeniaControl 'CmbQueryWidgetDestination';if($null -ne $destination){foreach($item in $destination.Items){if([string]$item.Tag -eq 'Computer'){$destination.SelectedItem=$item;break}}}
    Show-DomeniaWorkshopComputerPreview
}
function Add-DomeniaWorkshopWidget {
    $recipe=Get-DomeniaQueryDraft
    # Give copies their permanent identity before creating the transactional widget dependency.
    if([string]$recipe.Id -like 'template.*'){$recipe=New-DomeniaQueryRecipe -Name $recipe.Name -Junction $recipe.Junction -Clauses @($recipe.Clauses) -GroupBy ([string](Get-DomeniaMember $recipe 'GroupBy')) -Refinements @(Get-DomeniaMember $recipe 'Refinements' @()) -ProbeSelection (Get-DomeniaMemberValue $recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $recipe 'ObjectIds') -Parameters @(Get-DomeniaMember $recipe 'Parameters' @()) -ParameterValues (Get-DomeniaMemberValue $recipe 'ParameterValues') -Expression (Get-DomeniaMemberValue $recipe 'Expression') -CoherenceHours (Get-DomeniaMemberValue $recipe 'CoherenceHours') -ReadDefinition (Get-DomeniaMemberValue $recipe 'ReadDefinition')}
    $board=if([string](Get-DomeniaControl 'CmbQueryWidgetDestination').SelectedItem.Tag -eq 'Computer'){'Computer'}else{'Fleet'}
    $visual=[string](Get-DomeniaControl 'CmbQueryWidgetVisual').SelectedItem.Tag;if($visual -notin @('Kpi','Text','Bar','Pie','Column')){$visual='Kpi'}
    $existing=@(Get-DomeniaBoardLayout $board|Where-Object{$_.Source -eq 'Query' -and $_.Key -eq $recipe.Id}|Select-Object -First 1)
    $item=if($existing.Count){$existing[0]}else{New-DomeniaBoardItem -Source Query -Key $recipe.Id -Visual $visual -Size M -Group 'Mes sondes' -Title $recipe.Name}
    $state=[pscustomobject]@{DraftGeneration=$script:DomeniaQueryState.Generation;Destination=$board;Visual=$visual;Item=$item}
    # Same category rule as Enregistrer: the category typed in the workshop applies to the recipe saved for the widget.
    [void](Save-DomeniaQueryRecipe -Recipe $recipe -SuccessHandler 'Complete-DomeniaWorkshopWidgetSave' -CallbackState $state -AdditionalDependencies @([pscustomobject]@{ConsumerKind=$board;ConsumerId=[string]$item.Id}) -Category (Get-DomeniaQuerySaveCategory))
    [void](Set-DomeniaControlText 'LblQueryStatus' 'Enregistrement de la requête et de son lien avant création du widget…')
}
function Complete-DomeniaWorkshopWidgetSave {
    param($Recipe,$Record,$State)
    $sameDraft=($null -ne $script:DomeniaQueryState -and [long]$State.DraftGeneration -eq [long]$script:DomeniaQueryState.Generation)
    # The confirmed user action installs its captured widget; a later draft is never replaced.
    if($sameDraft){Set-DomeniaQueryDraft $Recipe}
    $destination=Get-DomeniaControl 'CmbQueryWidgetDestination';$visualControl=Get-DomeniaControl 'CmbQueryWidgetVisual'
    $board=if([string]$State.Destination -eq 'Computer'){'Computer'}else{'Fleet'}
    $visual=[string]$State.Visual
    if($visual -notin @('Kpi','Text','Bar','Pie','Column')){$visual='Kpi'}
    $layout=@(Get-DomeniaBoardLayout $board);$existing=@($layout|Where-Object{$_.Source -eq 'Query' -and $_.Key -eq $recipe.Id}|Select-Object -First 1)
    if($existing.Count){$layout=@(Update-DomeniaBoardItem -Layout $layout -Id $existing[0].Id -Changes @{Visual=$visual;Title=$recipe.Name});$id=$existing[0].Id}
    else{$item=$State.Item;$id=$item.Id;$layout=@(Add-DomeniaBoardItem $layout $item)}
    Set-DomeniaBoardLayout -Board $board -Layout $layout -Undo 'Ajout ou mise à jour de la requête' -Highlight $id
    if($sameDraft){if($board -eq 'Fleet'){Start-DomeniaQueryEvaluation}else{Show-DomeniaWorkshopComputerPreview}}
    [void](Set-DomeniaControlText 'LblQueryStatus' ('Requête enregistrée et ajoutée au tableau de bord '+$(if($board -eq 'Computer'){'Poste'}else{'général'})+'. Sa disposition est conservée. Aucune collecte lancée.'))
}
