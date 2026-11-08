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
CREATE TABLE IF NOT EXISTS domenia_query_recipe_provenance (
 recipe_id TEXT NOT NULL, revision INTEGER NOT NULL, provenance_json TEXT NOT NULL,
 PRIMARY KEY(recipe_id,revision)
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
function ConvertTo-DomeniaQueryProvenance {
    # Declared lineage, never a trusted publisher identity. Bound to each stored revision independently of the journal.
    param($Value,$DefaultHash='')
    if($null -eq $Value){return $null}
    $pack=[string](Get-DomeniaMember $Value 'PackId' '');$name=[string](Get-DomeniaMember $Value 'PackName' '');$version=[long](Get-DomeniaMember $Value 'PackVersion' 0)
    $origin=[string](Get-DomeniaMember $Value 'Origin' '');$id=[string](Get-DomeniaMember $Value 'SourceRecipeId' '')
    $hash=[string](Get-DomeniaMember $Value 'DefinitionSHA256' $DefaultHash)
    $verified=Get-DomeniaMember $Value 'Verified' $false
    if(($pack -and $pack -cnotmatch '^[0-9a-f]{32}$') -or $name.Length -gt 80 -or $version -lt 0 -or $version -gt 1000000 -or $origin.Length -gt 256 -or ($name+$origin) -match '[\p{Cc}]' -or $id -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$' -or $hash -cnotmatch '^[0-9a-f]{64}$' -or $verified -isnot [bool]){throw 'Provenance de recette invalide.'}
    if($pack){Assert-DomeniaQueryPackIdentity $name $version;if($pack -cne (Get-DomeniaQueryPackId $name)){throw 'Identité du pack de provenance incohérente.'}}
    elseif($verified -or $version -ne 0){throw 'Provenance de pack sans version incohérente.'}
    return [pscustomobject]@{PackId=$pack;PackName=$name;PackVersion=$version;Origin=$origin;SourceRecipeId=$id;DefinitionSHA256=$hash;Verified=$verified}
}
function New-DomeniaQueryLibraryRecord {
    param($Context,$Recipe,[Parameter(Mandatory=$true)][long]$ExpectedRevision,[string]$Category='Mes requêtes',[datetime]$NowUtc=[datetime]::UtcNow,$Provenance=$null)
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
    return [pscustomobject]@{Format='Domenia.QueryLibraryRecord/1';StoreId=[string]$Context.StoreId;DomainDn=[string]$Context.DomainDn;Id=$copy.Id;Name=$copy.Name;NameFold=(ConvertTo-DomeniaQuerySearchKey $copy.Name);Category=$Category;ExpectedRevision=$ExpectedRevision;Revision=($ExpectedRevision+1);DefinitionVersion=$(if($copy.Format -ceq 'Domenia.Query/2'){2}else{1});DefinitionJson=$json;DefinitionSHA256=$sha;UpdatedUtc=$NowUtc.ToUniversalTime().ToString('o');Archived=$false;Provenance=(ConvertTo-DomeniaQueryProvenance -Value $Provenance -DefaultHash $sha)}
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
    # Point 133: versions 1 and 2 are read (1 is a subset of 2); a pack written by a newer Domenia is refused with its
    # version, never read as an unknown file.
    [void](Assert-DomeniaContractFormat -Format $format -Family 'Domenia.QueryPack')
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
            [pscustomobject]@{Id=[string]$change.Id;Name=[string](Get-DomeniaMember $change 'Name' '');Revision=[long]$change.Revision;Sequence=[int]$change.Sequence;Before=$(if($null -ne $before){[pscustomobject]@{Revision=[long]$before.Revision;Archived=[bool]$before.Archived;Category=[string]$before.Category;DefinitionJson=[string]$before.DefinitionJson;DefinitionSHA256=[string]$before.DefinitionSHA256;Provenance=(Get-DomeniaMemberValue $before 'Provenance')}}else{$null})}
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
    # Validate the trusted catalog, then embed its source spelling. ConvertTo-Json differs between 5.1 and 7:
    # serializing objects here made the worker hash depend on the host. Only line endings are canonicalized.
    [void](Get-DomeniaExtendedProbeCatalog)
    $catalogJson=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Domenia-ProbeCatalog.json'),[Text.Encoding]::UTF8).Replace("`r`n","`n").Replace("`r","`n")
    $catalogBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($catalogJson))
    $definitions.Add("`$script:DomeniaExtendedProbeCatalog=@((ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$catalogBase64')))).Probes)")
    $definitions.Add(@'
function Assert-WQueryLibraryDefinition {
    param([string]$DefinitionJson,[int]$DefinitionVersion,[string]$RecipeId)
    if([Text.Encoding]::UTF8.GetByteCount($DefinitionJson) -gt 1048576){throw 'Definition de requete superieure a 1 Mio.'}
    $recipe=ConvertFrom-Json -InputObject $DefinitionJson -ErrorAction Stop
    # Point 133: the versions come from the contract catalog; a recipe of a newer Domenia is refused with its version.
    $format=Resolve-DomeniaContractFormat -Format ([string](Get-DomeniaMember $recipe 'Format' '')) -Family 'Domenia.Query'
    if(-not $format.Accepted){throw [string]$format.Message}
    if(([int]$format.Version -ne $DefinitionVersion) -or ([string]$recipe.Id -cne $RecipeId)){throw 'Version ou identite de definition incoherente.'}
    $allowed=@('Format','Id','Name','Junction','Clauses','GroupBy','Refinements','ProbeSelection','ObjectIds','Parameters','ParameterValues','Expression','CoherenceHours','ReadDefinition')
    foreach($property in $recipe.PSObject.Properties){if($property.Name -cnotin $allowed){throw ('Propriete de recette inconnue : '+$property.Name)}}
    foreach($clause in @(@($recipe.Clauses)+@(Get-DomeniaMember $recipe 'Refinements' @()))){foreach($property in $clause.PSObject.Properties){if($property.Name -cnotin @('Field','Operator','Value')){throw ('Propriete de condition inconnue : '+$property.Name)}}}
    [void](ConvertTo-DomeniaCompiledQuery $recipe)
    return $recipe
}
'@)
    return [string]::Join("`r`n",$definitions.ToArray())
}

function Get-DomeniaQueryRecipeImpact {
    # Consumers of one saved recipe before it changes: dashboard widgets with their transactional links, links whose
    # widget has disappeared and Search favourites. Pure: the caller supplies layouts, links and favourites.
    # Health alerts retain an immutable definition: list them explicitly, even when the library is archived.
    param([string]$RecipeId,[object[]]$Dependencies=@(),$Layouts=$null,[string[]]$SearchFavorites=@(),[object[]]$HealthRules=@(),[long]$CurrentRevision=0)
    if(-not $RecipeId){throw 'Recette à analyser absente.'}
    $boards=@{Fleet='Tableau de bord général';Computer='Tableau de bord du poste'}
    $links=@{}
    foreach($dependency in $Dependencies){if($null -ne $dependency -and [string]$dependency.RecipeId -ceq $RecipeId){$links[[string]$dependency.ConsumerKind+'|'+[string]$dependency.ConsumerId]=$dependency}}
    $rows=[Collections.Generic.List[object]]::new();$seen=@{};$widgets=0;$orphans=0;$views=0
    foreach($board in @('Fleet','Computer')){
        foreach($item in @(Get-DomeniaMember $Layouts $board @())){
            if($null -eq $item -or [string](Get-DomeniaMember $item 'Source') -cne 'Query' -or [string](Get-DomeniaMember $item 'Key') -cne $RecipeId){continue}
            $key=$board+'|'+[string]$item.Id;$seen[$key]=$true;$widgets++
            $link=$links[$key]
            $state=if($null -eq $link){'Widget sans lien enregistré : il affiche la définition courante'}elseif([long]$link.BoundRevision -lt $CurrentRevision){'Lié à une ancienne révision ('+[long]$link.BoundRevision+')'}else{'Lié à la révision '+[long]$link.BoundRevision}
            $title=[string](Get-DomeniaMember $item 'Title');if(-not $title){$title='Widget sans titre'}
            $rows.Add([pscustomobject]@{Kind='Widget';Element=$boards[$board];Name=$title;Link=$state;ConsumerKind=$board;ConsumerId=[string]$item.Id})
        }
    }
    foreach($key in @($links.Keys|Sort-Object)){
        if($seen.ContainsKey($key)){continue}
        $link=$links[$key];$orphans++
        $element=if($boards.ContainsKey([string]$link.ConsumerKind)){$boards[[string]$link.ConsumerKind]}else{[string]$link.ConsumerKind}
        $rows.Add([pscustomobject]@{Kind='Orphan';Element=$element;Name=('Widget absent de la disposition ('+[string]$link.ConsumerId+')');Link=('Lien enregistré à la révision '+[long]$link.BoundRevision+', sans widget affiché');ConsumerKind=[string]$link.ConsumerKind;ConsumerId=[string]$link.ConsumerId})
    }
    if(@($SearchFavorites) -ccontains ('local:'+$RecipeId)){$views++;$rows.Add([pscustomobject]@{Kind='View';Element='Vue de Recherche';Name='Favori de la liste des requêtes';Link='Affiche la définition courante';ConsumerKind='Search';ConsumerId=('local:'+$RecipeId)})}
    $alerts=0;foreach($entry in $HealthRules){$rule=$entry.Rule;if([string]$rule.QueryId -cne $RecipeId){continue};$alerts++;$rows.Add([pscustomobject]@{Kind='Health';Element=('Santé · '+[string]$entry.ScopeDn);Name=[string]$rule.Name;Link=('Révision '+[string]$rule.QueryRevision+' conservée ; actualisation explicite dans Santé');ConsumerKind='Health';ConsumerId=[string]$rule.Id})}
    return [pscustomobject]@{RecipeId=$RecipeId;Alerts=$alerts;Rows=$rows.ToArray();Widgets=$widgets;Orphans=$orphans;Views=$views;Count=$rows.Count;HasConsumers=($rows.Count -gt 0);CurrentRevision=$CurrentRevision}
}
function New-DomeniaQueryRecipeVersion {
    # Keeps the saved recipe and its consumers untouched: the modified definition becomes a new, independent recipe.
    param($Recipe,[string]$Suffix=' (nouvelle version)')
    $copy=Copy-DomeniaQueryRecipe $Recipe -Id ([guid]::NewGuid().ToString('N'))
    $name=[string]$Recipe.Name;$max=120-$Suffix.Length;if($name.Length -gt $max){$name=$name.Substring(0,$max)}
    $copy.Name=$name+$Suffix
    [void](ConvertTo-DomeniaCompiledQuery $copy)
    return $copy
}
function ConvertTo-DomeniaScriptCommentText {
    # One comment line of a generated script: no line terminator or control character can end the comment.
    param([string]$Text,[int]$MaxLength=400)
    $clean=([regex]::Replace([string]$Text,'[\p{Cc}\p{Zl}\p{Zp}\u0085]+',' ')).Trim()
    if($clean.Length -gt $MaxLength){$clean=$clean.Substring(0,$MaxLength)+'…'}
    return $clean
}
function ConvertTo-DomeniaAsciiJson {
    # Every non-ASCII character becomes a JSON \u escape: typographic quotes, which PowerShell also treats as
    # string delimiters, can never close the single-quoted data literal of a generated script.
    param([string]$Json)
    $builder=[Text.StringBuilder]::new($Json.Length+64)
    foreach($character in $Json.ToCharArray()){
        $code=[int]$character
        if($code -lt 32 -or $code -gt 126){[void]$builder.Append('\u').Append($code.ToString('x4'))}else{[void]$builder.Append($character)}
    }
    return $builder.ToString()
}
function ConvertTo-DomeniaQueryValueText {
    param($Value)
    if($null -eq $Value){return ''}
    $parameter=Get-DomeniaMemberValue $Value 'Parameter'
    if($null -ne $parameter){return ('paramètre '+[string]$parameter)}
    if($Value -is [bool]){if($Value){return 'Oui'};return 'Non'}
    return [Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture)
}
function Get-DomeniaQueryRecipeOutline {
    # Readable French description of a recipe: conditions, information sources, parameters and notes.
    # Pure; shared by the PowerShell export and the review panels. Never evaluates the recipe on data.
    param($Recipe)
    [void](ConvertTo-DomeniaCompiledQuery $Recipe)
    $fields=@{}
    foreach($entry in @(Get-DomeniaQueryCatalog)){$fields[[string]$entry.Id]=[pscustomobject]@{Name=[string]$entry.Name;Kind=[string]$entry.Kind;Source=[string]$entry.Source;Freshness=[string]$entry.Freshness}}
    foreach($entry in @(@(Get-DomeniaQueryInstanceFields)+@(Get-DomeniaQueryReadDefinitionFields $Recipe))){
        $source=if([string]$entry.Id -like 'detail:*'){'SELECT WMI mémorisé'}else{'Sonde WMI, propriété dʼune instance'}
        $fields[[string]$entry.Id]=[pscustomobject]@{Name=[string]$entry.Name;Kind=[string]$entry.Kind;Source=$source;Freshness='Date propre au relevé de la sonde ou du SELECT ; ce script ne la rajeunit pas.'}
    }
    $clauseText={param($Clause)
        $id=[string](Get-DomeniaMember $Clause 'Field');$field=$fields[$id];$name=if($null -ne $field){$field.Name}else{$id}
        $kind=if($null -ne $field){$field.Kind}else{'Text'}
        $operator=@(Get-DomeniaQueryOperators $kind|Where-Object{$_.Id -ceq [string](Get-DomeniaMember $Clause 'Operator')})
        $label=if($operator.Count){$operator[0].Name}else{[string](Get-DomeniaMember $Clause 'Operator')}
        $value=ConvertTo-DomeniaQueryValueText (Get-DomeniaMemberValue $Clause 'Value')
        if([string](Get-DomeniaMember $Clause 'Operator') -in @('IsMissing','IsPresent')){return ($name+' '+$label)}
        return ($name+' '+$label+' '+$value)
    }
    $conditions=[Collections.Generic.List[string]]::new()
    $clauses=@(Get-DomeniaMember $Recipe 'Clauses' @())
    if($clauses.Count){
        $conditions.Add($(if([string]$Recipe.Junction -eq 'Any'){'Au moins une des conditions suivantes (OU) :'}else{'Toutes les conditions suivantes (ET) :'}))
        $i=0;foreach($clause in $clauses){$i++;$conditions.Add(('  '+$i+'. '+(& $clauseText $clause)))}
    }
    $walk={param($Node,[int]$Depth)
        $indent='  '*($Depth+1);$kind=[string](Get-DomeniaMember $Node 'Kind')
        switch($kind){
            'Clause'{$conditions.Add($indent+'- '+(& $clauseText (Get-DomeniaMemberValue $Node 'Clause')))}
            'All'{$conditions.Add($indent+'Toutes les conditions suivantes (ET) :')}
            'Any'{$conditions.Add($indent+'Au moins une des conditions suivantes (OU) :')}
            'Not'{$conditions.Add($indent+'Aucune des conditions suivantes (NON) :')}
            'Collection'{
                $probe=Get-DomeniaProbe ([string]$Node.CollectionField).Substring(6);$probeName=if($null -ne $probe){[string]$probe.Name}else{[string]$Node.CollectionField}
                $quantifier=switch([string]$Node.Quantifier){'All'{'Toutes les instances'};'None'{'Aucune instance'};default{'Au moins une instance'}}
                $conditions.Add($indent+$quantifier+' de « '+$probeName+' » vérifie, sur la même instance :')
            }
        }
        if($kind -ne 'Clause'){foreach($child in @(Get-DomeniaMember $Node 'Children' @())){& $walk $child ($Depth+1)}}
    }
    $tree=Get-DomeniaMemberValue $Recipe 'Expression'
    if($null -ne $tree){if($clauses.Count){$conditions.Add('Et les groupes avancés suivants :')}else{$conditions.Add('Groupes de conditions :')};& $walk $tree 0}
    foreach($refinement in @(Get-DomeniaMember $Recipe 'Refinements' @())){$conditions.Add('Segment (ET) : '+(& $clauseText $refinement))}
    if(-not $conditions.Count){$conditions.Add('Aucune condition : tous les postes de lʼinstantané fourni correspondent.')}
    $notes=[Collections.Generic.List[string]]::new()
    $probeSelection=Get-DomeniaMemberValue $Recipe 'ProbeSelection'
    if($null -ne $probeSelection){$probe=Get-DomeniaProbe ([string]$probeSelection.Key);$notes.Add('Segment de sonde : '+$(if($null -ne $probe){[string]$probe.Name}else{[string]$probeSelection.Key})+' · mode '+[string]$probeSelection.Mode+'.')}
    $identities=Get-DomeniaQueryIdentitySelection $Recipe
    if($null -ne $identities){$notes.Add('Sélection figée de '+$identities.Count+' GUID : seuls ces postes sont évalués, pour le domaine dʼorigine.')}
    $coherence=Get-DomeniaMemberValue $Recipe 'CoherenceHours'
    if($null -ne $coherence){$notes.Add('Fenêtre commune : '+([double]$coherence).ToString('0.##',[Globalization.CultureInfo]::GetCultureInfo('fr-FR'))+' h au plus entre les dates des sources ; au-delà, ou sans date, le verdict est Inconnu.')}
    $definition=Get-DomeniaMemberValue $Recipe 'ReadDefinition'
    if($null -ne $definition){$notes.Add('Résultats WMI mémorisés : '+[string]$definition.Namespace+' · '+[string]$definition.CanonicalQuery+' (au plus '+[string]$definition.Limit+' instances). Ce script ne relit pas le poste.')}
    $groupBy=[string](Get-DomeniaMember $Recipe 'GroupBy')
    if($groupBy){$name=if($fields.ContainsKey($groupBy)){$fields[$groupBy].Name}else{$groupBy};$notes.Add('Répartition du widget : '+$name+'. Ce script rend les postes, pas la répartition.')}
    $sources=@(foreach($id in @(Get-DomeniaQueryRequestedFields $Recipe)){
        $field=$fields[$id];if($null -eq $field){continue}
        $field.Name+' : '+$field.Source+$(if($field.Freshness){' · '+$field.Freshness}else{''})
    })
    $parameters=@(foreach($parameter in @(Get-DomeniaMember $Recipe 'Parameters' @())){
        $field=$fields[[string]$parameter.Field];$current=Get-DomeniaMemberValue (Get-DomeniaMemberValue $Recipe 'ParameterValues') ([string]$parameter.Name) (Get-DomeniaMemberValue $parameter 'Default')
        [string]$parameter.Name+' : '+$(if($null -ne $field){$field.Name}else{[string]$parameter.Field})+', valeur '+(ConvertTo-DomeniaQueryValueText $current)
    })
    return [pscustomobject]@{Conditions=$conditions.ToArray();Sources=$sources;Parameters=$parameters;Notes=$notes.ToArray()}
}
function ConvertTo-DomeniaQueryPowerShell {
    # Readable, commented script that evaluates one recipe on an already read snapshot. The recipe is embedded as an
    # ASCII JSON data literal; the script holds no credential, opens no connection and is never run by the export.
    param($Recipe,[datetime]$ExportedUtc=[datetime]::UtcNow)
    $outline=Get-DomeniaQueryRecipeOutline $Recipe
    $json=ConvertTo-Json -InputObject $Recipe -Depth 32 -Compress
    $literal="'"+(ConvertTo-DomeniaAsciiJson $json).Replace("'","''")+"'"
    $lines=[Collections.Generic.List[string]]::new()
    # Leading spaces carry the nesting of groups and collections; only the text after them is sanitised.
    $comment={param([string]$Text)$indent=[regex]::Match($Text,'^ *').Value;$lines.Add(('# '+$indent+(ConvertTo-DomeniaScriptCommentText $Text)).TrimEnd())}
    $lines.Add('#requires -Version 5.1')
    & $comment '===== Requête Domenia exportée ====='
    & $comment ('Nom : '+[string]$Recipe.Name)
    & $comment ('Identifiant : '+[string]$Recipe.Id+' · format '+[string]$Recipe.Format)
    & $comment ('Exportée le '+$ExportedUtc.ToUniversalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)+' UTC. Lʼexport nʼa rien exécuté : relisez puis lancez ce script vous-même.')
    $lines.Add('#')
    & $comment 'Ce script ne contacte ni lʼannuaire, ni WMI, ni le réseau, nʼécrit rien et ne contient ni identifiant ni secret.'
    & $comment 'Il évalue la requête sur des enregistrements QueryRecord déjà lus (instantané local fourni par -Records).'
    $lines.Add('#')
    & $comment 'Conditions :'
    foreach($line in $outline.Conditions){& $comment ('  '+$line)}
    foreach($line in $outline.Notes){& $comment ('  '+$line)}
    $lines.Add('#')
    & $comment 'Informations utilisées et sources :'
    if(@($outline.Sources).Count){foreach($line in $outline.Sources){& $comment ('  - '+$line)}}else{& $comment '  (aucune)'}
    $lines.Add('#')
    & $comment 'Paramètres de la recette (modifiables avec -ParameterValues @{ Nom = valeur }) :'
    if(@($outline.Parameters).Count){foreach($line in $outline.Parameters){& $comment ('  - '+$line)}}else{& $comment '  (aucun)'}
    $lines.Add('#')
    & $comment 'Limites :'
    & $comment '  - Une information absente, expirée, en erreur ou incomplète donne Inconnu, jamais Faux ni zéro.'
    & $comment '  - Le résultat ne vaut que pour lʼinstantané fourni : ses dates et son périmètre restent ceux de la lecture.'
    & $comment '  - 64 conditions et 8 niveaux de groupes au plus ; aucune collecte nʼest déclenchée.'
    $lines.Add('#')
    & $comment 'Sortie : un objet par poste retenu (Id, Nom, CheminAD, Verdict, Valeurs, Etats). -Selection choisit Match, Unknown ou NoMatch.'
    & $comment 'Exemple : .\requete.ps1 -ModuleRoot C:\Domenia\wad\modules -Records $instantane -Selection Unknown'
    $body=@'
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ModuleRoot,
    [object[]]$Records=@(),
    [ValidateSet('Match','Unknown','NoMatch')][string]$Selection='Match',
    [hashtable]$ParameterValues=@{},
    [switch]$ShowDefinition
)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $ModuleRoot 'M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $ModuleRoot 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model')){. (Join-Path $ModuleRoot ('Domenia-'+$name+'.ps1'))}
$recipe=ConvertFrom-Json -InputObject @@LITERAL@@
if($ParameterValues.Count){
    $known=@(foreach($parameter in @($recipe.Parameters)){[string]$parameter.Name})
    $values=[ordered]@{}
    if($null -ne $recipe.ParameterValues){foreach($property in $recipe.ParameterValues.PSObject.Properties){$values[$property.Name]=$property.Value}}
    foreach($key in $ParameterValues.Keys){if([string]$key -cnotin $known){throw ('Paramètre inconnu pour cette requête : '+[string]$key)};$values[[string]$key]=$ParameterValues[$key]}
    $recipe.ParameterValues=[pscustomobject]$values
}
if($ShowDefinition){$recipe|ConvertTo-Json -Depth 32;return}
$compiled=ConvertTo-DomeniaCompiledQuery $recipe
$population=Select-DomeniaQueryPopulation -Records $Records -Recipe $recipe
$counts=$compiled.Execute($population,[M4D.Admin.Common.Query.QueryOptions]@{Limit=0})
Write-Verbose ('Postes évalués : '+$counts.Total+' ; correspondants : '+$counts.Matched+' ; inconnus : '+$counts.Unknown+' ; non correspondants : '+$counts.NotMatched)
$state=[M4D.Admin.Common.Query.MatchState]$Selection
$labels=@{Match='Correspond';Unknown='Inconnu';NoMatch='Ne correspond pas'};$verdict=$labels[$Selection]
$fields=@(Get-DomeniaQueryRequestedFields $recipe|Where-Object{$_ -notlike 'instance:*'})
foreach($record in $population){
    if($compiled.Evaluate($record.Values) -ne $state){continue}
    $values=[ordered]@{};$states=[ordered]@{}
    foreach($field in $fields){
        $presentation=Get-DomeniaQueryValuePresentation -Record $record -Field $field
        $values[$field]=$(if($presentation.Known){$record.Values[$field]}else{$null});$states[$field]=$presentation.State
    }
    [pscustomobject]@{Id=$record.Id;Nom=[string]$record.Values['name'];CheminAD=[string]$record.Values['dn'];Verdict=$verdict;Valeurs=[pscustomobject]$values;Etats=[pscustomobject]$states}
}
'@
    foreach($line in ($body.Replace("`r",'') -split "`n")){$lines.Add($line.Replace('@@LITERAL@@',$literal))}
    while($lines.Count -and -not $lines[$lines.Count-1]){$lines.RemoveAt($lines.Count-1)}
    return [string]::Join("`r`n",$lines.ToArray())+"`r`n"
}
