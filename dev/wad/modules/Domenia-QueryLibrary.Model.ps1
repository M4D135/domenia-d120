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
function New-DomeniaQueryPackImportPlan {
    param($Context,[string]$Json,[object[]]$ExistingRows=@())
    Assert-DomeniaQueryLibraryContext $Context
    if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 16777216){throw 'Pack de recettes trop volumineux (16 Mio).'}
    $pack=ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    if([string](Get-DomeniaMember $pack 'Format') -cne 'Domenia.QueryPack/1'){throw 'Format de pack inconnu.'}
    $recipes=@(Get-DomeniaMember $pack 'Recipes' @());if($recipes.Count -gt 5000){throw 'Le pack dépasse 5 000 recettes.'}
    $origin=[string](Get-DomeniaMember $pack 'Origin');if($origin.Length -gt 256 -or $origin -match '[\p{Cc}]'){throw 'Provenance du pack invalide.'}
    $existing=@{};foreach($row in $ExistingRows){$existing[[string]$row.Id]=$row}
    $seen=@{};$items=@(foreach($recipe in $recipes){
        if($seen.ContainsKey([string]$recipe.Id)){throw 'Identifiant de recette dupliqué dans le pack.'};$seen[[string]$recipe.Id]=$true
        $current=$existing[[string]$recipe.Id];$expected=if($null -ne $current){[long]$current.Revision}else{0L}
        $record=New-DomeniaQueryLibraryRecord -Context $Context -Recipe $recipe -ExpectedRevision $expected
        $domainBound=($null -ne (Get-DomeniaQueryIdentitySelection $recipe))
        $foreign=($domainBound -and [string](Get-DomeniaMember $pack 'DomainDn') -ine [string]$Context.DomainDn)
        $status=if($foreign){'Domaine différent'}elseif($null -eq $current){'Nouvelle'}elseif([string]$current.DefinitionSHA256 -ceq $record.DefinitionSHA256){'Identique'}else{'Conflit'}
        [pscustomobject]@{Id=$record.Id;Name=$record.Name;Status=$status;DefaultAction='Ignorer';Action='Ignorer';AllowedActions=$(if($foreign){@('Ignorer')}elseif($status -eq 'Nouvelle'){@('Ignorer','Créer')}elseif($status -eq 'Conflit'){@('Ignorer','Nouvelle copie','Remplacer après confirmation')}else{@('Ignorer')});ExpectedRevision=$expected;Before=$current;After=$record}
    })
    [pscustomobject]@{Format='Domenia.QueryImportPlan/1';StoreId=$Context.StoreId;DomainDn=$Context.DomainDn;Origin=$origin;Items=$items;RequiresExplicitSelection=$true;Executable=$false}
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
    # Single-quoted PowerShell data literal: quotes are doubled; no recipe text becomes executable syntax.
    $literal="'"+$json.Replace("'","''")+"'"
    $prefix=@'
#requires -Version 5.1
# Requête Domenia exportée. Lecture locale uniquement : aucun accès AD, WMI ou réseau.
# Fournir les QueryRecord d’un instantané local déjà lu ; -ShowDefinition affiche les critères sans exécution.
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
