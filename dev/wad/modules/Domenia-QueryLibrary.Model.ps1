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

function Get-DomeniaQueryRecipeImpact {
    # Consumers of one saved recipe before it changes: dashboard widgets with their transactional links, links whose
    # widget has disappeared and Search favourites. Pure: the caller supplies layouts, links and favourites.
    # No alert references a recipe in this version; the review panel says so instead of listing an empty kind.
    param([string]$RecipeId,[object[]]$Dependencies=@(),$Layouts=$null,[string[]]$SearchFavorites=@(),[long]$CurrentRevision=0)
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
    return [pscustomobject]@{RecipeId=$RecipeId;Rows=$rows.ToArray();Widgets=$widgets;Orphans=$orphans;Views=$views;Count=$rows.Count;HasConsumers=($rows.Count -gt 0);CurrentRevision=$CurrentRevision}
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
    $comment={param([string]$Text)$lines.Add(('# '+(ConvertTo-DomeniaScriptCommentText $Text)).TrimEnd())}
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
