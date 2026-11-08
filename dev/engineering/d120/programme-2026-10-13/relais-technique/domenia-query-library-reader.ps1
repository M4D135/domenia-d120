function Invoke-StoreWLibraryQuery {
    param([string]$Sql,[IntPtr]$Db)
    return @(Invoke-IdxWQuery $Db $Sql)
}
function Convert-StoreWQueryRecipe {
    param($Row)
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$actual=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Row.definition_json))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    if($actual -cne [string]$Row.definition_sha256){throw 'Corruption de definition dans la bibliotheque locale.'}
    return [pscustomobject]@{Id=[string]$Row.id;DomainDn=[string]$Row.domain_dn;Name=[string]$Row.name;NameFold=[string]$Row.name_fold;Category=[string]$Row.category;Revision=[long]$Row.revision;DefinitionVersion=[int]$Row.definition_version;DefinitionJson=[string]$Row.definition_json;DefinitionSHA256=[string]$Row.definition_sha256;CreatedUtc=[string]$Row.created_utc;UpdatedUtc=[string]$Row.updated_utc;Archived=([int]$Row.archived -ne 0)}
}
function Read-StoreWQueryLibrary {
    param([IntPtr]$Db,$Query,[string]$DomainDn,[long]$SnapshotRevision,[string]$StoreId,[string[]]$RecipeIds=$null)
    if([string]$Query.StoreId -cne $StoreId -or [string]$Query.DomainDn -ine $DomainDn){throw 'Contexte de lecture de bibliotheque incoherent.'}
    if([long]$Query.MinimumRevision -gt $SnapshotRevision -or ([long]$Query.SnapshotRevision -gt 0 -and [long]$Query.SnapshotRevision -ne $SnapshotRevision)){throw 'Revision de bibliotheque demandee non disponible.'}
    $limit=100;if($null -ne $Query.PSObject.Properties['Limit']){$limit=[int]$Query.Limit};$offset=[int]$Query.Offset
    if($limit -lt 1 -or $limit -gt 250 -or $offset -lt 0 -or [string]$Query.OrderBy -notin @('','name_fold,id') -or ([string]$Query.Term).Length -gt 256 -or ([string]$Query.Category).Length -gt 80){throw 'Pagination ou filtre de bibliotheque invalide.'}
    $exists=@(Invoke-StoreWLibraryQuery "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_query_recipes';" $Db)
    $rows=@();$migrations=@();$dependencies=@();$total=0L
    if($exists.Count){
        $where='domain_dn='+(Get-IdxWLiteral $DomainDn)
        if(-not [bool]$Query.IncludeArchived){$where+=' AND archived='+[int][bool]$Query.Archived}
        # instr is literal: percent, underscore and quotes cannot widen this filter.
        if([string]$Query.Term){$where+=' AND instr(name_fold,'+(Get-IdxWLiteral ([string]$Query.Term))+')>0'}
        if([string]$Query.Category){$where+=' AND category='+(Get-IdxWLiteral ([string]$Query.Category))}
        if($null -ne $RecipeIds){
            if($RecipeIds.Count -gt 250){throw 'Trop de recettes pour une page.'}
            foreach($id in $RecipeIds){if($id -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$'){throw 'Identifiant de lecture de recette invalide.'}}
            if($RecipeIds.Count){$where+=' AND id IN ('+(@($RecipeIds|ForEach-Object{Get-IdxWLiteral $_}) -join ',')+')'}else{$where+=' AND 0=1'}
        }
        $total=[long](@(Invoke-StoreWLibraryQuery "SELECT count(*) AS n FROM domenia_query_recipes WHERE $where;" $Db)[0].n)
        $rows=@(Invoke-StoreWLibraryQuery "SELECT * FROM domenia_query_recipes WHERE $where ORDER BY name_fold,id LIMIT $limit OFFSET $offset;" $Db|ForEach-Object{Convert-StoreWQueryRecipe $_})
        if($rows.Count){$keys=@($rows|ForEach-Object{Get-IdxWLiteral $_.Id}) -join ',';$dependencies=@(Invoke-StoreWLibraryQuery "SELECT recipe_id AS RecipeId,consumer_kind AS ConsumerKind,consumer_id AS ConsumerId,bound_revision AS BoundRevision FROM domenia_query_recipe_dependencies WHERE recipe_id IN ($keys) ORDER BY recipe_id,consumer_kind,consumer_id;" $Db)}
        $migrationTable=@(Invoke-StoreWLibraryQuery "SELECT name FROM sqlite_master WHERE type='table' AND name='domenia_query_migrations';" $Db)
        if($migrationTable.Count){$migrations=@(Invoke-StoreWLibraryQuery ('SELECT source_hash AS SourceHash,domain_dn AS DomainDn,imported_at AS ImportedAtUtc,revision AS Revision FROM domenia_query_migrations WHERE domain_dn='+(Get-IdxWLiteral $DomainDn)+' ORDER BY source_hash;') $Db)}
    }
    return [pscustomobject]@{QueryRecipes=$rows;QueryDependencies=$dependencies;QueryMigrations=$migrations;Total=$total;Offset=$offset;Limit=$limit;SnapshotRevision=$SnapshotRevision}
}
