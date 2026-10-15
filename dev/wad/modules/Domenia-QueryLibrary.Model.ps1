# Pure query-library contracts. This file never opens SQLite or executes a recipe.
# The central store owns transactions, revision checks and COMMIT + SELECT publication.
function Get-DomeniaQueryLibrarySchema {
    return @'
CREATE TABLE IF NOT EXISTS domenia_query_recipes (
 id TEXT PRIMARY KEY NOT NULL, domain_dn TEXT NOT NULL, name TEXT NOT NULL, name_fold TEXT NOT NULL,
 category TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), definition_version INTEGER NOT NULL,
 definition_json TEXT NOT NULL, definition_sha256 TEXT NOT NULL, created_utc TEXT NOT NULL,
 updated_utc TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1))
);
CREATE INDEX IF NOT EXISTS ix_domenia_query_recipes_page ON domenia_query_recipes(archived,name_fold,id);
CREATE INDEX IF NOT EXISTS ix_domenia_query_recipes_category ON domenia_query_recipes(archived,category,name_fold,id);
CREATE TABLE IF NOT EXISTS domenia_query_recipe_revisions (
 id TEXT NOT NULL, revision INTEGER NOT NULL, definition_version INTEGER NOT NULL,
 definition_json TEXT NOT NULL, definition_sha256 TEXT NOT NULL, at_utc TEXT NOT NULL,
 PRIMARY KEY(id,revision)
);
CREATE TABLE IF NOT EXISTS domenia_query_migrations (
 source_hash TEXT PRIMARY KEY NOT NULL, domain_dn TEXT NOT NULL, imported_at TEXT NOT NULL, revision INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS domenia_query_recipe_dependencies (
 recipe_id TEXT NOT NULL, consumer_kind TEXT NOT NULL, consumer_id TEXT NOT NULL,
 bound_revision INTEGER NOT NULL, PRIMARY KEY(recipe_id,consumer_kind,consumer_id)
);
'@
}
function ConvertTo-DomeniaQuerySearchKey {
    param([string]$Text)
    $builder=[Text.StringBuilder]::new()
    foreach($character in $Text.Normalize([Text.NormalizationForm]::FormD).ToCharArray()){
        if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne [Globalization.UnicodeCategory]::NonSpacingMark){[void]$builder.Append($character)}
    }
    return ([regex]::Replace($builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant(),'\s+',' ')).Trim()
}
function Assert-DomeniaQueryLibraryContext {
    param($Context)
    if($null -eq $Context -or [int](Get-DomeniaMember $Context 'Version' 0) -ne 1 -or -not [string](Get-DomeniaMember $Context 'StoreId') -or -not [string](Get-DomeniaMember $Context 'DomainDn') -or -not [IO.Path]::IsPathRooted([string](Get-DomeniaMember $Context 'Path'))){throw 'Contexte de base locale et de domaine requis pour la bibliothèque.'}
}
function New-DomeniaQueryLibraryRecord {
    param($Context,$Recipe,[Parameter(Mandatory=$true)][long]$ExpectedRevision,[string]$Category='Mes requêtes',[datetime]$NowUtc=[datetime]::UtcNow)
    Assert-DomeniaQueryLibraryContext $Context
    if($ExpectedRevision -lt 0 -or $ExpectedRevision -ge [long]::MaxValue){throw 'Révision attendue invalide.'}
    if($Category.Length -gt 80 -or $Category -match '[\p{Cc}]'){throw 'Catégorie de bibliothèque invalide (80 caractères).'}
    [void](ConvertTo-DomeniaCompiledQuery $Recipe)
    if([string]$Recipe.Id -like 'template.*'){throw 'Enregistrez une copie personnelle du modèle avant de le stocker.'}
    # JSON-roundtrip detaches the DTO, and the allowlist excludes executable/extension properties.
    $allowed=@('Format','Id','Name','Junction','Clauses','GroupBy','Refinements','ProbeSelection','ObjectIds','Parameters','ParameterValues','Expression','CoherenceHours','ReadDefinition')
    foreach($property in $Recipe.PSObject.Properties){if($property.Name -cnotin $allowed){throw ('Propriété de recette non reconnue : '+$property.Name)}}
    $copy=New-DomeniaQueryRecipe -Id $Recipe.Id -Name $Recipe.Name -Junction $Recipe.Junction -Clauses @($Recipe.Clauses) -GroupBy ([string](Get-DomeniaMember $Recipe 'GroupBy')) -Refinements @(Get-DomeniaMember $Recipe 'Refinements' @()) -ProbeSelection (Get-DomeniaMemberValue $Recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $Recipe 'ObjectIds') -Parameters @(Get-DomeniaMember $Recipe 'Parameters' @()) -ParameterValues (Get-DomeniaMemberValue $Recipe 'ParameterValues') -Expression (Get-DomeniaMemberValue $Recipe 'Expression') -CoherenceHours (Get-DomeniaMemberValue $Recipe 'CoherenceHours') -ReadDefinition (Get-DomeniaMemberValue $Recipe 'ReadDefinition')
    foreach($clause in @(@($copy.Clauses)+@($copy.Refinements))){foreach($property in $clause.PSObject.Properties){if($property.Name -cnotin @('Field','Operator','Value')){throw ('Propriété de condition non reconnue : '+$property.Name)}}}
    if($copy.Name -match '[\p{Cc}]'){throw 'Le nom ne peut pas contenir de caractère de contrôle.'}
    $json=ConvertTo-Json -InputObject $copy -Depth 32 -Compress;$bytes=[Text.Encoding]::UTF8.GetBytes($json)
    if($bytes.Length -gt 1048576){throw 'Une définition de requête accepte au maximum 1 Mio.'}
    $hash=[Security.Cryptography.SHA256]::Create();try{$sha=[BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    return [pscustomobject]@{Format='Domenia.QueryLibraryRecord/1';StoreId=[string]$Context.StoreId;DomainDn=[string]$Context.DomainDn;Id=$copy.Id;Name=$copy.Name;NameFold=(ConvertTo-DomeniaQuerySearchKey $copy.Name);Category=$Category;ExpectedRevision=$ExpectedRevision;Revision=($ExpectedRevision+1);DefinitionVersion=$(if($copy.Format -ceq 'Domenia.Query/2'){2}else{1});DefinitionJson=$json;DefinitionSHA256=$sha;UpdatedUtc=$NowUtc.ToUniversalTime().ToString('o');Archived=$false}
}
function New-DomeniaQueryLibraryRead {
    param($Context,[string]$Text='',[string]$Category='',[int]$Offset=0,[int]$Limit=100,[switch]$Archived,[switch]$IncludeArchived,[long]$MinimumRevision=0)
    Assert-DomeniaQueryLibraryContext $Context
    if($Text.Length -gt 256 -or $Category.Length -gt 80 -or $Offset -lt 0 -or $Limit -lt 1 -or $Limit -gt 250 -or $MinimumRevision -lt 0){throw 'Pagination ou filtre de bibliothèque invalide.'}
    # Text is a literal parameter. The eventual SQL adapter must escape %, _ and the escape character for LIKE.
    [pscustomobject]@{Kind='QueryLibrary';StoreId=[string]$Context.StoreId;DomainDn=[string]$Context.DomainDn;Term=(ConvertTo-DomeniaQuerySearchKey $Text);Category=$Category;Offset=$Offset;Limit=$Limit;Archived=[bool]$Archived;IncludeArchived=[bool]$IncludeArchived;MinimumRevision=$MinimumRevision;OrderBy='name_fold,id'}
}
function Get-DomeniaQueryDefinitionBinding {
    # Which versioned definition a consumer evaluates (list, indicator, report): the exact stored revision, a draft
    # modified since that revision, an unsaved draft, an archived revision or a delivered model. The comparison is
    # semantic (Compare-DomeniaQueryRecipeDefinitions), so key order or number scale never fakes a modification.
    # A delivered model is compared with the model as delivered (-Template); without it the state stays unknown.
    param($Recipe,$Row=$null,$Template=$null)
    $id=[string](Get-DomeniaMember $Recipe 'Id' '')
    if($id -like 'template.*'){
        if(($null -eq $Template) -or ([string](Get-DomeniaMember $Template 'Id' '') -cne $id)){return [pscustomobject]@{RecipeId=$id;Revision=0L;DefinitionSHA256='';State='Unknown';Label='modèle livré non préparé : définition non vérifiée'}}
        $changes=@(Compare-DomeniaQueryRecipeDefinitions -Before $Template -After $Recipe)
        if($changes.Count){return [pscustomobject]@{RecipeId=$id;Revision=0L;DefinitionSHA256='';State='Modified';Label=('brouillon modifié depuis le modèle livré ('+[string]$changes.Count+' différence(s))')}}
        return [pscustomobject]@{RecipeId=$id;Revision=0L;DefinitionSHA256='';State='Template';Label='modèle livré avec Domenia'}
    }
    if($null -eq $Row){return [pscustomobject]@{RecipeId=$id;Revision=0L;DefinitionSHA256='';State='Unsaved';Label='brouillon non enregistré'}}
    $stored=ConvertFrom-Json -InputObject ([string]$Row.DefinitionJson) -ErrorAction Stop
    $changes=@(Compare-DomeniaQueryRecipeDefinitions -Before $stored -After $Recipe)
    $state=if([bool]$Row.Archived){'Archived'}elseif($changes.Count){'Modified'}else{'Saved'}
    $label=switch($state){Archived{'révision '+[string]$Row.Revision+' archivée'};Modified{'brouillon modifié depuis la révision '+[string]$Row.Revision+' ('+[string]$changes.Count+' différence(s))'};default{'révision '+[string]$Row.Revision+' enregistrée'}}
    return [pscustomobject]@{RecipeId=$id;Revision=[long]$Row.Revision;DefinitionSHA256=[string]$Row.DefinitionSHA256;State=$state;Label=$label}
}
function Get-DomeniaQueryPackId {
    # Stable identity of a named pack across its versions: every version of one pack name shares this id.
    param([string]$PackName)
    return (Get-DomeniaQuerySha256 ('Domenia.QueryPack|'+(ConvertTo-DomeniaQuerySearchKey $PackName))).Substring(0,32)
}
function Get-DomeniaQueryPackContentHash {
    # Integrity of a versioned pack: identity, version and the canonical SHA-256 of every definition, in order.
    param([string]$PackId,[long]$PackVersion,[object[]]$Records=@())
    $lines=[Collections.Generic.List[string]]::new();$lines.Add('Domenia.QueryPack/2');$lines.Add($PackId);$lines.Add([string]$PackVersion)
    foreach($record in $Records){$lines.Add([string]$record.Id+':'+[string]$record.DefinitionSHA256)}
    return (Get-DomeniaQuerySha256 ([string]::Join("`n",$lines.ToArray())))
}
function Assert-DomeniaQueryPackIdentity {
    param([string]$PackName,[long]$PackVersion)
    if(-not $PackName.Trim() -or $PackName.Length -gt 80 -or $PackName -match '[\p{Cc}]'){throw 'Nom de pack invalide (1 à 80 caractères, sans caractère de contrôle).'}
    if($PackVersion -lt 1 -or $PackVersion -gt 1000000){throw 'Version de pack invalide (nombre entier de 1 à 1 000 000).'}
}
function New-DomeniaQueryPack {
    # Versioned, self-checking pack of personal recipes. Data only: importing it never executes anything.
    param($Context,[object[]]$Recipes=@(),[string]$PackName,[long]$PackVersion=1,[string]$Origin='',[datetime]$NowUtc=[datetime]::UtcNow)
    Assert-DomeniaQueryLibraryContext $Context
    $PackName=([string]$PackName).Trim();Assert-DomeniaQueryPackIdentity -PackName $PackName -PackVersion $PackVersion
    if($Origin.Length -gt 256 -or $Origin -match '[\p{Cc}]'){throw 'Provenance du pack invalide.'}
    if(@($Recipes).Count -gt 5000){throw 'Un pack contient au maximum 5 000 recettes ; exportez la sélection en plusieurs packs.'}
    # The fingerprint is computed on the same JSON form an importer parses, so number scales cannot diverge.
    $list=@(foreach($recipe in @($Recipes)){ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $recipe -Depth 32 -Compress) -ErrorAction Stop})
    $seen=@{};$records=@(foreach($recipe in $list){
        if($seen.ContainsKey([string]$recipe.Id)){throw 'Identifiant de recette dupliqué dans le pack.'};$seen[[string]$recipe.Id]=$true
        New-DomeniaQueryLibraryRecord -Context $Context -Recipe $recipe -ExpectedRevision 0
    })
    $id=Get-DomeniaQueryPackId $PackName
    [pscustomobject]@{Format='Domenia.QueryPack/2';PackId=$id;PackName=$PackName;PackVersion=$PackVersion;Origin=$Origin;DomainDn=[string]$Context.DomainDn;ExportedAtUtc=$NowUtc.ToUniversalTime().ToString('o');ContentSHA256=(Get-DomeniaQueryPackContentHash -PackId $id -PackVersion $PackVersion -Records $records);Recipes=$list}
}
function Format-DomeniaQueryChangeSummary {
    param([object[]]$Changes=@(),[string]$Status='')
    $rows=@($Changes|Where-Object{$null -ne $_})
    if($Status -eq 'Nouvelle'){return 'Nouvelle requête'}
    if(-not $rows.Count){return 'Aucune différence de définition'}
    $kinds=@($rows|ForEach-Object{[string]$_.Element}|Select-Object -Unique)
    return ([string]$rows.Count+' différence(s) : '+((@($kinds|Select-Object -First 3)) -join ', ')+$(if($kinds.Count -gt 3){', …'}else{''}))
}
function New-DomeniaQueryPackImportPlan {
    # Preview only: provenance, version, verified integrity, per-recipe differences and allowed choices.
    param($Context,[string]$Json,[object[]]$ExistingRows=@(),[object[]]$History=@())
    Assert-DomeniaQueryLibraryContext $Context
    if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 16777216){throw 'Pack de recettes trop volumineux (16 Mio).'}
    $pack=ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    $format=[string](Get-DomeniaMember $pack 'Format')
    if($format -cnotin @('Domenia.QueryPack/1','Domenia.QueryPack/2')){throw 'Format de pack inconnu.'}
    $recipes=@(Get-DomeniaMember $pack 'Recipes' @());if($recipes.Count -gt 5000){throw 'Le pack dépasse 5 000 recettes.'}
    $origin=[string](Get-DomeniaMember $pack 'Origin');if($origin.Length -gt 256 -or $origin -match '[\p{Cc}]'){throw 'Provenance du pack invalide.'}
    $existing=@{};foreach($row in $ExistingRows){$existing[[string]$row.Id]=$row}
    $records=[Collections.Generic.List[object]]::new()
    $seen=@{};$items=@(foreach($recipe in $recipes){
        if($seen.ContainsKey([string]$recipe.Id)){throw 'Identifiant de recette dupliqué dans le pack.'};$seen[[string]$recipe.Id]=$true
        $current=$existing[[string]$recipe.Id];$expected=if($null -ne $current){[long]$current.Revision}else{0L}
        $record=New-DomeniaQueryLibraryRecord -Context $Context -Recipe $recipe -ExpectedRevision $expected;$records.Add($record)
        $domainBound=($null -ne (Get-DomeniaQueryIdentitySelection $recipe))
        $foreign=($domainBound -and [string](Get-DomeniaMember $pack 'DomainDn') -ine [string]$Context.DomainDn)
        $archived=($null -ne $current -and [bool]$current.Archived)
        $status=if($foreign){'Domaine différent'}elseif($null -eq $current){'Nouvelle'}elseif($archived){'Archivée localement'}elseif([string]$current.DefinitionSHA256 -ceq $record.DefinitionSHA256){'Identique'}else{'Conflit'}
        $before=if($null -ne $current){ConvertFrom-Json -InputObject ([string]$current.DefinitionJson) -ErrorAction Stop}else{$null}
        $changes=@(Compare-DomeniaQueryRecipeDefinitions -Before $before -After (ConvertFrom-Json -InputObject $record.DefinitionJson -ErrorAction Stop))
        $allowed=if($foreign){@('Ignorer')}elseif($status -eq 'Nouvelle'){@('Ignorer','Créer')}elseif($status -in @('Conflit','Archivée localement')){@('Ignorer','Nouvelle copie','Remplacer après confirmation')}else{@('Ignorer')}
        [pscustomobject]@{Id=$record.Id;Name=$record.Name;Status=$status;ChangeSummary=(Format-DomeniaQueryChangeSummary -Changes $changes -Status $status);Changes=$changes;DefaultAction='Ignorer';Action='Ignorer';AllowedActions=$allowed;ExpectedRevision=$expected;Before=$current;After=$record}
    })
    $packId='';$packName='';$packVersion=0L;$verified=$false
    if($format -ceq 'Domenia.QueryPack/2'){
        $packId=[string](Get-DomeniaMember $pack 'PackId');$packName=[string](Get-DomeniaMember $pack 'PackName');$packVersion=[long](Get-DomeniaMember $pack 'PackVersion' 0)
        Assert-DomeniaQueryPackIdentity -PackName $packName -PackVersion $packVersion
        if($packId -cnotmatch '^[0-9a-f]{32}$' -or $packId -cne (Get-DomeniaQueryPackId $packName)){throw 'Identité du pack incohérente avec son nom. Aucune recette importée.'}
        if((Get-DomeniaQueryPackContentHash -PackId $packId -PackVersion $packVersion -Records $records.ToArray()) -cne [string](Get-DomeniaMember $pack 'ContentSHA256')){throw 'Pack modifié ou incomplet : son empreinte de contenu ne correspond pas. Aucune recette importée.'}
        $verified=$true
    }
    $previous=@($History|Where-Object{$null -ne $_ -and $packId -and [string]$_.PackId -ceq $packId}|Sort-Object -Property @{Expression={[long]$_.PackVersion};Descending=$true}|Select-Object -First 1)
    [pscustomobject]@{Format='Domenia.QueryImportPlan/2';PackFormat=$format;StoreId=$Context.StoreId;DomainDn=$Context.DomainDn;Origin=$origin;PackId=$packId;PackName=$packName;PackVersion=$packVersion;ExportedAtUtc=[string](Get-DomeniaMember $pack 'ExportedAtUtc');Verified=$verified;PreviousVersion=$(if($previous.Count){[long]$previous[0].PackVersion}else{0L});Items=$items;RequiresExplicitSelection=$true;Executable=$false}
}
function New-DomeniaQueryImportJournalEntry {
    # One durable line per import or rollback: pack provenance and, for each confirmed write, the definition it
    # replaced (or none for a creation) so the import can be undone after a restart. No secret is ever stored.
    # An interrupted rollback also lists, in Remaining, the source items it did not restore yet: they stay restorable.
    param($Context,[object[]]$Applied=@(),$Plan=$null,[string]$RollsBack='',[object[]]$Remaining=@(),[datetime]$NowUtc=[datetime]::UtcNow)
    Assert-DomeniaQueryLibraryContext $Context
    $normalize={
        param([object[]]$Changes)
        foreach($change in @($Changes|Where-Object{$null -ne $_}|Sort-Object Sequence)){
            $before=Get-DomeniaMemberValue $change 'Before'
            [pscustomobject]@{Id=[string]$change.Id;Name=[string](Get-DomeniaMember $change 'Name' '');Revision=[long]$change.Revision;Sequence=[int]$change.Sequence;Before=$(if($null -ne $before){[pscustomobject]@{Revision=[long]$before.Revision;Archived=[bool]$before.Archived;Category=[string]$before.Category;DefinitionJson=[string]$before.DefinitionJson;DefinitionSHA256=[string]$before.DefinitionSHA256}}else{$null})}
        }
    }
    $items=@(& $normalize $Applied)
    $left=@(if($RollsBack){& $normalize $Remaining})
    [pscustomobject]@{Format='Domenia.QueryImportJournal/1';Kind=$(if($RollsBack){'Rollback'}else{'Import'});ImportId=[guid]::NewGuid().ToString('N');RollsBack=$RollsBack;StoreId=[string]$Context.StoreId;DomainDn=[string]$Context.DomainDn;AtUtc=$NowUtc.ToUniversalTime().ToString('o');PackId=[string](Get-DomeniaMember $Plan 'PackId' '');PackName=[string](Get-DomeniaMember $Plan 'PackName' '');PackVersion=[long](Get-DomeniaMember $Plan 'PackVersion' 0);Origin=[string](Get-DomeniaMember $Plan 'Origin' '');Verified=[bool](Get-DomeniaMember $Plan 'Verified' $false);Items=$items;Remaining=$left}
}
function Format-DomeniaQueryImportJournalLabel {
    param($Entry,[bool]$Restorable)
    $at=ConvertFrom-DomeniaUtcText ([string]$Entry.AtUtc)
    $count=if([bool](Get-DomeniaMember $Entry 'Partial' $false)){' · restauration interrompue, '+@($Entry.Items).Count+' recette(s) encore à restaurer'}else{' · '+@($Entry.Items).Count+' recette(s)'}
    return ($(if($null -ne $at){$at.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}else{'Date inconnue'})+' · '+$(if([string]$Entry.PackName){[string]$Entry.PackName+' v'+[string]$Entry.PackVersion}else{'pack sans version'})+$count+$(if($Restorable){''}else{' · non restaurable'}))
}
function New-DomeniaQueryImportRestorePoint {
    # What a journal line still allows to undo: an import, or the part of an interrupted rollback not restored yet
    # (its Remaining items, under the rollback's own id). -Trusted skips the integrity check for a line of this session.
    param($Entry,[switch]$Trusted)
    $partial=([string](Get-DomeniaMember $Entry 'Kind') -ceq 'Rollback')
    $items=@(if($partial){Get-DomeniaMember $Entry 'Remaining' @()}else{Get-DomeniaMember $Entry 'Items' @()})
    $restorable=($items.Count -gt 0)
    if(-not $Trusted){
        foreach($item in $items){
            $before=Get-DomeniaMemberValue $item 'Before'
            if(([string]$item.Id -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$') -or ([long]$item.Revision -le 0)){$restorable=$false;break}
            if(($null -ne $before) -and ((Get-DomeniaQuerySha256 ([string]$before.DefinitionJson)) -cne [string]$before.DefinitionSHA256)){$restorable=$false;break}
        }
    }
    $view=[pscustomobject]@{Format=[string](Get-DomeniaMember $Entry 'Format' '');Kind=[string](Get-DomeniaMember $Entry 'Kind' '');ImportId=[string](Get-DomeniaMember $Entry 'ImportId' '');RollsBack=[string](Get-DomeniaMember $Entry 'RollsBack' '');StoreId=[string](Get-DomeniaMember $Entry 'StoreId' '');DomainDn=[string](Get-DomeniaMember $Entry 'DomainDn' '');AtUtc=[string](Get-DomeniaMember $Entry 'AtUtc' '');PackId=[string](Get-DomeniaMember $Entry 'PackId' '');PackName=[string](Get-DomeniaMember $Entry 'PackName' '');PackVersion=[long](Get-DomeniaMember $Entry 'PackVersion' 0);Origin=[string](Get-DomeniaMember $Entry 'Origin' '');Verified=[bool](Get-DomeniaMember $Entry 'Verified' $false);Items=$items;Partial=$partial;Restorable=$restorable;DisplayName=''}
    $view.DisplayName=Format-DomeniaQueryImportJournalLabel -Entry $view -Restorable $restorable
    return $view
}
function ConvertFrom-DomeniaQueryImportJournal {
    # Imports of this store that can still be undone, newest first. A rolled-back import, a foreign store, an
    # unreadable line or an altered replaced definition is never offered as restorable. The rest of an interrupted
    # rollback is offered under the rollback's id until a later rollback of that id completes it.
    param([string[]]$Lines=@(),[string]$StoreId,[int]$Limit=20)
    $imports=[Collections.Generic.List[object]]::new();$rolledBack=@{};$rejected=0
    foreach($line in @($Lines)){
        if(-not ([string]$line).Trim()){continue}
        try{$entry=ConvertFrom-Json -InputObject ([string]$line) -ErrorAction Stop}catch{$rejected++;continue}
        if([string](Get-DomeniaMember $entry 'Format') -cne 'Domenia.QueryImportJournal/1' -or [string](Get-DomeniaMember $entry 'StoreId') -cne $StoreId){continue}
        if([string](Get-DomeniaMember $entry 'ImportId') -cnotmatch '^[0-9a-f]{32}$'){$rejected++;continue}
        if([string]$entry.Kind -ceq 'Rollback'){
            $rolledBack[[string]$entry.RollsBack]=$true
            if(@(Get-DomeniaMember $entry 'Remaining' @()).Count){$imports.Add((New-DomeniaQueryImportRestorePoint -Entry $entry))}
            continue
        }
        if([string]$entry.Kind -cne 'Import'){$rejected++;continue}
        $imports.Add((New-DomeniaQueryImportRestorePoint -Entry $entry))
    }
    $available=@($imports|Where-Object{-not $rolledBack.ContainsKey([string]$_.ImportId)})
    [array]::Reverse($available)
    return [pscustomobject]@{Entries=@($available|Select-Object -First ([Math]::Max(1,[Math]::Min(100,$Limit))));Rejected=$rejected}
}
function Get-DomeniaQueryLibraryDefinitionValidationCode {
    # Trusted, versioned source definitions only. Never concatenate a recipe or user text into executable code.
    $definitions=[Collections.Generic.List[string]]::new()
    foreach($name in @('Domenia-Common.Model.ps1','Domenia-HealthRules.Model.ps1','Domenia-Boards.Model.ps1','Domenia-ProbeCatalog.Model.ps1','Domenia-Probes.Model.ps1','Domenia-QuerySchema.Model.ps1','Domenia-Workstation.Model.ps1','Domenia-Query.Model.ps1','Domenia-QueryLibrary.Model.ps1')){
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw ('Module de validation invalide : '+$name)}
        foreach($function in $ast.EndBlock.Statements){if($function -is [Management.Automation.Language.FunctionDefinitionAst]){$definitions.Add($function.Extent.Text)}}
    }
    $catalogJson=ConvertTo-Json -InputObject @(Get-DomeniaExtendedProbeCatalog) -Depth 16 -Compress
    $catalogBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($catalogJson))
    $definitions.Add("`$script:DomeniaExtendedProbeCatalog=@(ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$catalogBase64'))))")
    $definitions.Add(@'
function Assert-WQueryLibraryDefinition {
    param([string]$DefinitionJson,[int]$DefinitionVersion,[string]$RecipeId)
    if([Text.Encoding]::UTF8.GetByteCount($DefinitionJson) -gt 1048576){throw 'Definition de requete superieure a 1 Mio.'}
    $recipe=ConvertFrom-Json -InputObject $DefinitionJson -ErrorAction Stop
    $version=if([string]$recipe.Format -ceq 'Domenia.Query/2'){2}elseif([string]$recipe.Format -ceq 'Domenia.Query/1'){1}else{0}
    if($version -lt 1 -or $version -ne $DefinitionVersion -or [string]$recipe.Id -cne $RecipeId){throw 'Version ou identite de definition incoherente.'}
    $allowed=@('Format','Id','Name','Junction','Clauses','GroupBy','Refinements','ProbeSelection','ObjectIds','Parameters','ParameterValues','Expression','CoherenceHours','ReadDefinition')
    foreach($property in $recipe.PSObject.Properties){if($property.Name -cnotin $allowed){throw ('Propriete de recette inconnue : '+$property.Name)}}
    foreach($clause in @(@($recipe.Clauses)+@(Get-DomeniaMember $recipe 'Refinements' @()))){foreach($property in $clause.PSObject.Properties){if($property.Name -cnotin @('Field','Operator','Value')){throw ('Propriete de condition inconnue : '+$property.Name)}}}
    [void](ConvertTo-DomeniaCompiledQuery $recipe)
    return $recipe
}
'@)
    return [string]::Join("`r`n",$definitions.ToArray())
}

function ConvertTo-DomeniaQueryPowerShell {
    param($Recipe)
    [void](ConvertTo-DomeniaCompiledQuery $Recipe)
    $json=ConvertTo-Json -InputObject $Recipe -Depth 32 -Compress
    # Single-quoted PowerShell data literal. PowerShell also closes such a literal on U+2018, U+2019, U+201A and
    # U+201B, which ConvertTo-Json leaves as is: every one of them is doubled, so no recipe text becomes syntax.
    $literal="'"+[regex]::Replace($json,'[''\u2018\u2019\u201A\u201B]',{param($match)$match.Value+$match.Value})+"'"
    $prefix=@'
#requires -Version 5.1
# Requête Domenia exportée. Lecture locale uniquement : aucun accès AD, WMI ou réseau.
# Fournir les QueryRecord dʼun instantané local déjà lu ; -ShowDefinition affiche les critères sans exécution.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ModuleRoot,[object[]]$Records=@(),[switch]$ShowDefinition)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $ModuleRoot 'M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $ModuleRoot 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model')){. (Join-Path $ModuleRoot ('Domenia-'+$name+'.ps1'))}
'@
    $suffix=@'
if($ShowDefinition){$recipe|ConvertTo-Json -Depth 32;return}
$population=Select-DomeniaQueryPopulation -Records $Records -Recipe $recipe
$compiled=ConvertTo-DomeniaCompiledQuery $recipe
$summary=$compiled.Count($population)
Write-Verbose ('Correspondants : '+$summary.Matched+' ; inconnus : '+$summary.Unknown+' ; non correspondants : '+$summary.NotMatched)
foreach($record in $population){if($compiled.Evaluate($record.Values) -eq [M4D.Admin.Common.Query.MatchState]::Match){$record}}
'@
    return $prefix+"`r`n"+'$recipe=ConvertFrom-Json -InputObject '+$literal+"`r`n"+$suffix
}
