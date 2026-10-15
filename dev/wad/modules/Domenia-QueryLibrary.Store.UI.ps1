# Canonical personal recipes: a single domain-local SQLite authority. No raw draft is published on admission.
$script:DomeniaQueryLibraryStoreState=$null
function Test-DomeniaQueryLibraryStoreState {
    param($State)
    $current=$script:DomeniaQueryLibraryStoreState
    return ($null -ne $current -and $null -ne $State -and [long]$State.Epoch -eq [long]$script:SessionEpoch -and [long]$State.Generation -eq [long]$current.Generation -and [string]$State.StoreId -ceq [string]$current.Context.StoreId -and [string]$current.Context.Path -ieq [string]$script:DatabaseScopedPath -and [string]$current.Context.DomainDn -ieq [string]$script:Conn.BaseDn)
}
function Initialize-DomeniaQueryLibraryStore {
    param([switch]$Force)
    $current=$script:DomeniaQueryLibraryStoreState
    try{$context=New-DomeniaStoreContext -RequestId ('query-library-'+[guid]::NewGuid().ToString('N'))}catch{return $null}
    if(-not $Force -and $null -ne $current -and $current.Context.StoreId -ceq $context.StoreId -and $current.Context.SessionEpoch -eq $context.SessionEpoch -and ($current.Loaded -or $current.Loading)){return $current}
    if($null -ne $current -and $current.Saving -and $current.Context.StoreId -ceq $context.StoreId -and $current.Context.SessionEpoch -eq $context.SessionEpoch){throw 'Attendez la confirmation de lʼenregistrement de la requête.'}
    $generation=if($null -ne $current){[long]$current.Generation+1}else{1L};$context.Generation=$generation
    $state=[pscustomobject]@{Context=$context;Generation=$generation;Loading=$true;Loaded=$false;Saving=$false;Error='';Rows=@{};Recipes=@();ReadRows=@{};Offset=0;SnapshotRevision=-1L;Restarts=0;MigrationPending=$false;Dependencies=@()}
    $script:DomeniaQueryLibraryStoreState=$state
    if($null -ne $script:DomeniaQueryState){$script:DomeniaQueryState.Saved=@();$script:DomeniaQueryState.Widgets=@{};$script:DomeniaQueryState.WidgetLibrary='';$script:DomeniaQueryState.LibraryError='Bibliothèque locale en cours de lecture.'}
    Request-DomeniaQueryLibraryStorePage
    return $state
}
function Get-DomeniaSavedQueryRecipes {
    $state=Initialize-DomeniaQueryLibraryStore
    if($null -eq $state -or -not $state.Loaded){return @()}
    return @($state.Recipes)
}
function Request-DomeniaQueryLibraryStorePage {
    $state=$script:DomeniaQueryLibraryStoreState
    $callback=[pscustomobject]@{StoreId=$state.Context.StoreId;Epoch=$state.Context.SessionEpoch;Generation=$state.Generation;Offset=$state.Offset}
    try{
        $query=New-DomeniaQueryLibraryRead -Context $state.Context -Offset $state.Offset -Limit 250 -IncludeArchived
        $job=Request-DomeniaStoreRead -Context $state.Context -Query $query -SuccessHandler 'Complete-DomeniaQueryLibraryStoreRead' -ErrorHandler 'Fail-DomeniaQueryLibraryStoreRead' -CallbackState $callback
        if(-not $job){throw 'Lecture de la bibliothèque non admise.'}
    }catch{Fail-DomeniaQueryLibraryStoreRead $_.Exception.Message $callback}
}
function Complete-DomeniaQueryLibraryStoreRead {
    param($Result,$State)
    if(-not (Test-DomeniaQueryLibraryStoreState $State)){return}
    $store=$script:DomeniaQueryLibraryStoreState
    try{
        if($null -eq $Result -or [string]$Result.DataSource -cne 'SQLite' -or [string]$Result.StoreId -cne $State.StoreId -or [bool](Get-DomeniaMember $Result 'Missing' $false) -or [bool](Get-DomeniaMember $Result 'Busy' $false) -or $null -eq $Result.PSObject.Properties['QueryRecipes']){throw 'La base nʼa pas confirmé la lecture de la bibliothèque.'}
        $revision=[long]$Result.SnapshotRevision
        if($store.SnapshotRevision -ge 0 -and $revision -ne $store.SnapshotRevision){
            if($store.Restarts -ge 3){throw 'La base change pendant la lecture. Réessayez après les collectes.'}
            $store.Restarts++;$store.Offset=0;$store.ReadRows=@{};$store.SnapshotRevision=-1L;Request-DomeniaQueryLibraryStorePage;return
        }
        $store.SnapshotRevision=$revision;$rows=@($Result.QueryRecipes)
        $store.Dependencies=@(Get-DomeniaMember $Result 'QueryDependencies' @())
        if([long]$Result.Total -gt 20000){throw 'Bibliothèque supérieure au budget de 20 000 définitions (archives incluses).'}
        foreach($row in $rows){
            if($store.ReadRows.ContainsKey([string]$row.Id)){throw 'Identité de recette répétée entre les pages.'}
            $store.ReadRows[[string]$row.Id]=$row
        }
        $store.Offset+=$rows.Count
        if($store.Offset -lt [long]$Result.Total){if(-not $rows.Count){throw 'Pagination de bibliothèque sans progression.'};Request-DomeniaQueryLibraryStorePage;return}
        $store.Rows=$store.ReadRows;$store.ReadRows=@{}
        Complete-DomeniaQueryLibraryMigrationRead -Result $Result
    }catch{Fail-DomeniaQueryLibraryStoreRead $_.Exception.Message $State}
}
function Complete-DomeniaQueryLibraryMigrationRead {
    param($Result)
    $store=$script:DomeniaQueryLibraryStoreState
    $original=[string](Get-DomeniaSetting 'Query.Library' '')
    if(-not $original){Publish-DomeniaQueryLibraryStoreCache;return}
    $hash=Get-DomeniaStoreHash $original
    $markers=@(Get-DomeniaMember $Result 'QueryMigrations' @())
    if(@($markers|Where-Object{[string]$_.SourceHash -ceq $hash}).Count){Publish-DomeniaQueryLibraryStoreCache;return}
    $legacy=@(ConvertFrom-DomeniaQueryLibrary $original)
    $missing=[Collections.Generic.List[object]]::new()
    foreach($recipe in $legacy){if(-not $store.Rows.ContainsKey([string]$recipe.Id)){$missing.Add((New-DomeniaQueryLibraryRecord -Context $store.Context -Recipe $recipe -ExpectedRevision 0))}}
    $migration=[pscustomobject]@{SourceHash=$hash;RecipeIds=@($legacy|ForEach-Object{[string]$_.Id});Missing=$missing;Index=0;Batch=$null}
    $store|Add-Member -NotePropertyName Migration -NotePropertyValue $migration -Force
    $store.MigrationPending=$true
    Submit-DomeniaQueryLibraryMigrationBatch
}
function Submit-DomeniaQueryLibraryMigrationBatch {
    $store=$script:DomeniaQueryLibraryStoreState;$migration=$store.Migration
    if($null -eq $migration.Batch){
        $changes=[Collections.Generic.List[object]]::new();$index=$migration.Index;$bytes=0L
        while($index -lt $migration.Missing.Count -and $changes.Count -lt 50){
            $change=[pscustomobject]@{Kind='QueryRecipe';Record=$migration.Missing[$index]}
            $size=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $change -Depth 20 -Compress))
            if($changes.Count -gt 0 -and $bytes+$size -gt 2500000){break}
            $changes.Add($change);$bytes+=$size;$index++
        }
        $last=($index -ge $migration.Missing.Count)
        if($last){
            foreach($board in @('Fleet','Computer')){foreach($item in @(Get-DomeniaBoardLayout $board)){
                if([string]$item.Source -ne 'Query' -or [string]$item.Key -notin $migration.RecipeIds){continue}
                $current=$store.Rows[[string]$item.Key];if($null -ne $current -and [bool]$current.Archived){continue}
                $revision=if($null -ne $current){[long]$current.Revision}else{1L}
                $changes.Add([pscustomobject]@{Kind='QueryDependency';RecipeId=[string]$item.Key;ConsumerKind=$board;ConsumerId=[string]$item.Id;BoundRevision=$revision;Remove=$false})
            }}
            if($changes.Count -ge 250){throw 'Trop de widgets hérités pour certifier la migration en un lot.'}
            $changes.Add([pscustomobject]@{Kind='QueryMigration';SourceHash=$migration.SourceHash;RecipeIds=$migration.RecipeIds;StoreId=$store.Context.StoreId;DomainDn=$store.Context.DomainDn})
        }
        $migration.Batch=[pscustomobject]@{StoreId=$store.Context.StoreId;Epoch=$store.Context.SessionEpoch;Generation=$store.Generation;BatchId=[guid]::NewGuid().ToString('D');Changes=$changes.ToArray();Next=$index;Last=$last;SourceHash=$migration.SourceHash}
    }
    $state=$migration.Batch
    try{
        $admission=Submit-DomeniaStoreBatch -Context $store.Context -BatchId $state.BatchId -Sequence $migration.Index -Changes $state.Changes -SuccessHandler 'Complete-DomeniaQueryLibraryMigrationBatch' -ErrorHandler 'Fail-DomeniaQueryLibraryStoreRead' -CallbackState $state
        if(-not $admission.Accepted){if([string]$admission.Reason -ceq 'StorageMaintenance'){throw 'Maintenance de la base locale en cours : migration différée. Revenez dans lʼatelier à la fin de lʼassistant pour la reprendre ; le JSON original est conservé.'};throw 'Base occupée pendant la migration. Revenez dans lʼatelier pour la reprendre ; le JSON original est conservé.'}
    }catch{Fail-DomeniaQueryLibraryStoreRead $_.Exception.Message $state}
}
function Complete-DomeniaQueryLibraryMigrationBatch {
    param($Result,$State)
    if(-not (Test-DomeniaQueryLibraryStoreState $State)){return}
    $store=$script:DomeniaQueryLibraryStoreState
    try{
        if(-not [bool]$Result.Saved -or [string]$Result.DataSource -cne 'SQLite' -or [string]$Result.StoreId -cne $State.StoreId){throw 'Migration de recettes non confirmée par la base.'}
        $readback=@{};foreach($row in @(Get-DomeniaMember $Result 'QueryRecipes' @())){$readback[[string]$row.Id]=$row}
        foreach($change in $State.Changes){if($change.Kind -eq 'QueryRecipe'){
            if(-not $readback.ContainsKey([string]$change.Record.Id)){throw 'Recette migrée absente du reçu SQLite.'}
            $store.Rows[[string]$change.Record.Id]=$readback[[string]$change.Record.Id]
        }}
        $store.Migration.Index=$State.Next;$store.Migration.Batch=$null
        if($State.Last){
            $marker=@(Get-DomeniaMember $Result 'QueryMigrations' @()|Where-Object{[string]$_.SourceHash -ceq $State.SourceHash})
            if(-not $marker.Count){throw 'Marqueur durable de migration absent du reçu SQLite.'}
            $store.MigrationPending=$false
            if($null -ne $Result.PSObject.Properties['QueryDependencies']){$store.Dependencies=@($Result.QueryDependencies)}
            Publish-DomeniaQueryLibraryStoreCache
        }else{Submit-DomeniaQueryLibraryMigrationBatch}
    }catch{Fail-DomeniaQueryLibraryStoreRead $_.Exception.Message $State}
}
function Publish-DomeniaQueryLibraryStoreCache {
    $store=$script:DomeniaQueryLibraryStoreState
    $recipes=@(foreach($row in $store.Rows.Values){
        if([bool]$row.Archived){continue}
        $recipe=ConvertFrom-Json -InputObject ([string]$row.DefinitionJson) -ErrorAction Stop
        [void](ConvertTo-DomeniaCompiledQuery $recipe)
        if([string]$recipe.Id -cne [string]$row.Id){throw 'Identité de définition incohérente dans la base.'}
        $recipe
    })
    $recipes=@($recipes|Sort-Object Name,Id -Culture 'fr-FR')
    $store.Recipes=$recipes;$store.Loading=$false;$store.Loaded=$true;$store.Error=''
    if($null -ne $script:DomeniaQueryState){$script:DomeniaQueryState.Saved=$recipes;$script:DomeniaQueryState.LibraryError='';$script:DomeniaQueryState.Widgets=@{};$script:DomeniaQueryState.WidgetLibrary='';Update-DomeniaQueryLibraryControls}
    elseif($script:SearchUiInitialized){Update-DomeniaWorkViewList}
}
function Fail-DomeniaQueryLibraryStoreRead {
    param($Message,$State)
    if(-not (Test-DomeniaQueryLibraryStoreState $State)){return}
    $store=$script:DomeniaQueryLibraryStoreState;$store.Loading=$false;$store.Loaded=$false;$store.Error=[string]$Message
    if($null -ne $script:DomeniaQueryState){$script:DomeniaQueryState.LibraryError=$store.Error;[void](Set-DomeniaControlText 'LblQueryStatus' ('Bibliothèque non disponible : '+$store.Error))}
}
function Save-DomeniaQueryRecipe {
    param($Recipe,[string]$SuccessHandler='Complete-DomeniaQueryRecipeSaveUi',$CallbackState=$null,[switch]$Archive,[object[]]$AdditionalDependencies=@(),[string]$ErrorHandler='',[switch]$ImpactConfirmed)
    $store=Initialize-DomeniaQueryLibraryStore
    if($null -eq $store -or -not $store.Loaded){throw 'Attendez la lecture confirmée de la bibliothèque locale.'}
    if($store.Saving){throw 'Un enregistrement de requête est déjà en cours.'}
    if($ErrorHandler -and $ErrorHandler -notmatch '^[A-Za-z][A-Za-z0-9-]+$'){throw 'Callback d''erreur de recette invalide.'}
    if($SuccessHandler -notmatch '^[A-Za-z][A-Za-z0-9-]+$'){throw 'Callback de recette invalide.'}
    if([string]$Recipe.Id -like 'template.*'){
        if($Archive){throw 'Les modèles livrés sont conservés.'}
        $Recipe=New-DomeniaQueryRecipe -Name $Recipe.Name -Junction $Recipe.Junction -Clauses @($Recipe.Clauses) -GroupBy ([string](Get-DomeniaMember $Recipe 'GroupBy')) -Refinements @(Get-DomeniaMember $Recipe 'Refinements' @()) -ProbeSelection (Get-DomeniaMemberValue $Recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $Recipe 'ObjectIds') -Parameters @(Get-DomeniaMember $Recipe 'Parameters' @()) -ParameterValues (Get-DomeniaMemberValue $Recipe 'ParameterValues') -Expression (Get-DomeniaMemberValue $Recipe 'Expression') -CoherenceHours (Get-DomeniaMemberValue $Recipe 'CoherenceHours') -ReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition')
    }
    $previous=$store.Rows[[string]$Recipe.Id];$expected=if($null -ne $previous){[long]$previous.Revision}else{0L}
    if($Archive -and $null -eq $previous){throw 'Cette recette nʼest pas enregistrée.'}
    $record=New-DomeniaQueryLibraryRecord -Context $store.Context -Recipe $Recipe -ExpectedRevision $expected
    $record.Archived=[bool]$Archive
    $dependencies=@($store.Dependencies|Where-Object{[string]$_.RecipeId -ceq [string]$Recipe.Id})
    # The workshop shows its in-page impact review first (ImpactConfirmed); other callers keep the confirmation.
    if($dependencies.Count -and -not $ImpactConfirmed){
        $action=if($Archive){'Archiver cette requête et retirer ses widgets'}else{'Mettre à jour les widgets qui utilisent cette requête'}
        $details=($dependencies|ForEach-Object{[string]$_.ConsumerKind+' · '+[string]$_.ConsumerId+' · révision '+[string]$_.BoundRevision}) -join "`r`n"
        $answer=Show-DomeniaDialog -Title 'Éléments qui utilisent cette requête' -Message ($action+' ? '+$dependencies.Count+' lien(s) concerné(s). Les anciennes révisions restent conservées dans la base.') -Details $details -Kind Question -Buttons YesNo
        if([string]$answer -ne 'Yes'){throw 'Modification de la requête annulée.'}
    }
    $changes=[Collections.Generic.List[object]]::new()
    # Detach exact old revisions before an archive; updates bind consumers to the new canonical revision.
    if($Archive){foreach($dependency in $dependencies){$changes.Add([pscustomobject]@{Kind='QueryDependency';RecipeId=$Recipe.Id;ConsumerKind=$dependency.ConsumerKind;ConsumerId=$dependency.ConsumerId;BoundRevision=[long]$dependency.BoundRevision;Remove=$true})}}
    $changes.Add([pscustomobject]@{Kind='QueryRecipe';Record=$record})
    if(-not $Archive){
        $links=@{};foreach($dependency in @($dependencies)+@($AdditionalDependencies)){$links[([string]$dependency.ConsumerKind+'|'+[string]$dependency.ConsumerId)]=$dependency}
        foreach($dependency in $links.Values){$changes.Add([pscustomobject]@{Kind='QueryDependency';RecipeId=$Recipe.Id;ConsumerKind=[string]$dependency.ConsumerKind;ConsumerId=[string]$dependency.ConsumerId;BoundRevision=[long]$record.Revision;Remove=$false})}
    }
    if($changes.Count -gt 250){throw 'Cette requête a trop de dépendances pour un enregistrement atomique (249 maximum).'}
    $state=[pscustomobject]@{StoreId=$store.Context.StoreId;Epoch=$store.Context.SessionEpoch;Generation=$store.Generation;Record=$record;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler;CallbackState=$CallbackState;BatchId=[guid]::NewGuid().ToString('D')}
    $store.Saving=$true
    try{
        $admission=Submit-DomeniaStoreBatch -Context $store.Context -BatchId $state.BatchId -Sequence 0 -Changes $changes.ToArray() -SuccessHandler 'Complete-DomeniaQueryRecipeStore' -ErrorHandler 'Fail-DomeniaQueryRecipeStore' -CallbackState $state
        if(-not $admission.Accepted){if([string]$admission.Reason -ceq 'StorageMaintenance'){throw (Get-DomeniaStorageInputRefusal -Maintenance $script:StorageMaintenance)};throw 'Base occupée : la recette nʼa pas été enregistrée, réessayez.'}
        return $admission
    }catch{$store.Saving=$false;throw}
}
function Complete-DomeniaQueryRecipeStore {
    param($Result,$State)
    if(-not (Test-DomeniaQueryLibraryStoreState $State)){return}
    $store=$script:DomeniaQueryLibraryStoreState
    try{
        if(-not [bool]$Result.Saved -or [string]$Result.DataSource -cne 'SQLite' -or [string]$Result.StoreId -cne $State.StoreId){throw 'Écriture de recette non confirmée par SQLite.'}
        $rows=@($Result.QueryRecipes|Where-Object{[string]$_.Id -ceq [string]$State.Record.Id})
        if($rows.Count -ne 1 -or [long]$rows[0].Revision -le [long]$State.Record.ExpectedRevision){throw 'Révision de recette non confirmée par la base.'}
        $row=$rows[0];$store.Rows[[string]$row.Id]=$row;$store.Saving=$false
        if($null -ne $Result.PSObject.Properties['QueryDependencies']){$store.Dependencies=@($store.Dependencies|Where-Object{[string]$_.RecipeId -cne [string]$row.Id})+@($Result.QueryDependencies|Where-Object{[string]$_.RecipeId -ceq [string]$row.Id})}
        Publish-DomeniaQueryLibraryStoreCache
        $recipe=ConvertFrom-Json -InputObject ([string]$row.DefinitionJson) -ErrorAction Stop
        & ([string]$State.SuccessHandler) -Recipe $recipe -Record $row -State $State.CallbackState
    }catch{Fail-DomeniaQueryRecipeStore $_.Exception.Message $State}
}
function Fail-DomeniaQueryRecipeStore {
    param($Message,$State)
    if(-not (Test-DomeniaQueryLibraryStoreState $State)){return}
    $script:DomeniaQueryLibraryStoreState.Saving=$false
    if([string](Get-DomeniaMember $State 'ErrorHandler')){& ([string]$State.ErrorHandler) -Message ([string]$Message) -State $State.CallbackState}
    [void](Set-DomeniaControlText 'LblQueryStatus' ('Requête non enregistrée : '+[string]$Message))
}
function Complete-DomeniaQueryRecipeSaveUi {
    param($Recipe,$Record,$State)
    # A late receipt updates the saved catalog, but must not replace a draft edited since admission.
    $q=$script:DomeniaQueryState
    if($null -ne $q -and ($null -eq $State -or [long]$State.DraftGeneration -eq [long]$q.Generation)){Set-DomeniaQueryDraft $Recipe}
    [void](Set-DomeniaControlText 'LblQueryStatus' ('Requête enregistrée dans la base locale · révision '+$Record.Revision+'.'))
}
function Complete-DomeniaQueryRecipeArchiveUi {
    param($Recipe,$Record,$State)
    foreach($board in @('Fleet','Computer')){
        $layout=@(Get-DomeniaBoardLayout $board|Where-Object{-not ($_.Source -eq 'Query' -and $_.Key -eq $Recipe.Id)})
        Set-DomeniaBoardLayout -Board $board -Layout $layout -Undo 'Retrait du widget de la requête archivée'
    }
    $q=$script:DomeniaQueryState;if($null -ne $q -and $q.Recipe.Id -ceq $Recipe.Id){Set-DomeniaQueryDraft (New-DomeniaQueryRecipe)}
    [void](Set-DomeniaControlText 'LblQueryStatus' 'Requête archivée dans la base. Ses révisions et les données collectées sont conservées.')
}
