function Get-DomeniaQueryWorkerCode {
    # LocalQuery: computation only. The loader has already verified the versioned library.
    return @'
$root=[string]$Payload.ModuleRoot
foreach($file in @('Domenia-Common.Model.ps1','Domenia-HealthRules.Model.ps1','Domenia-Boards.Model.ps1','Domenia-Probes.Model.ps1','Domenia-QuerySchema.Model.ps1','Domenia-Workstation.Model.ps1','Domenia-Query.Model.ps1')){. (Join-Path $root $file)}
if($null -eq ('M4D.Admin.Common.Query.QueryEngine' -as [type])){throw 'Moteur de requêtes non chargé.'}
if([bool](Get-DomeniaMember $Payload 'ProjectCollections' $false)){[pscustomobject]@{Projections=@(ConvertTo-DomeniaQueryCollectionProjections -Observations @($Payload.ObservationRows) -Nodes @($Payload.CollectionNodes) -MaxAgeDays ([int]$Payload.MaxAgeDays))};return}
$searchOutput=($null -ne $Payload.PSObject.Properties['SearchOutput'] -and [bool]$Payload.SearchOutput)
if($searchOutput){
    . (Join-Path $root 'Domenia-Search.Model.ps1')
    # FleetStats was read for Search's OU, independently of the dashboard. Its stored observations are already
    # validated against the row GUID; the common adapter also validates identity and each measurement's date.
    $observations=@{}
    foreach($item in @(Get-DomeniaMember $Payload.Fleet 'Presence' @())){if($null -ne $item -and [string]$item.object_key){$observations[([string]$item.object_key).ToLowerInvariant()]=$item.observation}}
    $Payload.Observations=$observations
}

$records=$Payload.Records
if($null -eq $records){$records=ConvertTo-DomeniaQueryRecords -Fleet $Payload.Fleet -Observations $Payload.Observations -MaxAgeDays ([int]$Payload.MaxAgeDays) -Lifecycle $Payload.Lifecycle}
$records=Add-DomeniaQueryCollectionProjectionRecords -Records $records -Projections @(Get-DomeniaMember $Payload 'CollectionProjections' @())
$records=Add-DomeniaQueryDetailRecords -Records $records -Details @(Get-DomeniaMember $Payload 'DetailRows' @()) -MaxAgeDays ([int]$Payload.MaxAgeDays)
if([bool](Get-DomeniaMember $Payload 'PlanCollection' $false)){[pscustomobject]@{Records=$records;CollectionPlan=(New-DomeniaQueryMissingCollectionPlan -Records $records -Recipe $Payload.Recipe -CacheMinutes ([int]$Payload.CacheMinutes))};return}
if([bool](Get-DomeniaMember $Payload 'CoverageOnly' $false)){[pscustomobject]@{Records=$records;Coverage=(Measure-DomeniaQueryCoverage -Records $records -Recipe $Payload.Recipe)};return}
$eligible=Select-DomeniaQueryPopulation $records $Payload.Recipe
$text=([string]$Payload.TextFilter).Trim();$state=[string]$Payload.StateFilter
if($text -or $state -in @('Actifs','Désactivés')){
    $filtered=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($r in $eligible){
        if($state -eq 'Actifs' -and -not [bool]$r.Values['active']){continue}
        if($state -eq 'Désactivés' -and (-not $r.Values.ContainsKey('active') -or [bool]$r.Values['active'])){continue}
        if($text -and ([string]$r.Values['name']).IndexOf($text,[StringComparison]::OrdinalIgnoreCase) -lt 0 -and ([string]$r.Values['dn']).IndexOf($text,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
        $filtered.Add($r)
    }
    $eligible=$filtered
}
$compiled=ConvertTo-DomeniaCompiledQuery $Payload.Recipe
$options=[M4D.Admin.Common.Query.QueryOptions]::new();$options.Offset=[int]$Payload.Offset;$options.Limit=200;$options.SortField=$(if($null -ne $Payload.PSObject.Properties['SortField'] -and [string]$Payload.SortField){[string]$Payload.SortField}else{'name'});$options.Descending=($null -ne $Payload.PSObject.Properties['Descending'] -and [bool]$Payload.Descending);$options.Selection=[Enum]::Parse([M4D.Admin.Common.Query.MatchState],[string]$Payload.Selection)
if($searchOutput){$limit=[int]$Payload.Limit;if($limit -lt 1 -or $limit -gt 20000){throw 'Limite de recherche locale invalide (1 à 20 000).'};$options.Limit=[Math]::Min(10000,$limit);$options.Offset=0}
$result=$compiled.Execute($eligible,$options)
if($searchOutput){
    $rows=@(ConvertTo-DomeniaSearchQueryRows -Records $result.Rows)
    # The shared DLL caps a page at 10,000. Search supports 20,000 explicitly: a second page of the SAME
    # immutable population preserves the global order and counts without changing the common library.
    if($limit -gt 10000 -and $rows.Count -eq 10000){$options.Offset=10000;$options.Limit=$limit-10000;$next=$compiled.Execute($eligible,$options);$rows+=@(ConvertTo-DomeniaSearchQueryRows -Records $next.Rows)}
    [pscustomobject]@{Rows=$rows;Total=$result.Total;Matched=$result.Matched;Unknown=$result.Unknown;NotMatched=$result.NotMatched;ScopeTotal=$records.Count;Limit=$limit;Selection=[string]$options.Selection;Scope=[string]$Payload.Fleet.Scope;Subtree=[bool]$Payload.Fleet.Subtree;AtUtc=[datetime]::UtcNow}
    return
}
$fields=@(Get-DomeniaQueryRequestedFields $Payload.Recipe)
$rows=@(ConvertTo-DomeniaQueryGridRows -Rows $result.Rows -Fields $fields)
# Complete distribution of the draft, computed like its widget on the whole scope (display filters excluded).
$groups=$null
if([string](Get-DomeniaMember $Payload.Recipe 'GroupBy')){
    try{$groups=Get-DomeniaQueryGroupSummary -Records $records -Recipe $Payload.Recipe}
    catch{$groups=[pscustomobject]@{Field=[string]$Payload.Recipe.GroupBy;Error=$_.Exception.Message}}
}
$widgets=$null;if($null -ne $Payload.PSObject.Properties['CachedWidgets']){$widgets=$Payload.CachedWidgets}
if($null -eq $widgets){
$widgets=@{}
foreach($recipe in @($Payload.Saved)){
    try{$widgets[[string]$recipe.Id]=Measure-DomeniaQueryWidget $records $recipe}
    catch{$widgets[[string]$recipe.Id]=[pscustomobject]@{Total=0;Matched=0;Unknown=0;NotMatched=0;Error=$_.Exception.Message}}
}
}
$probeWidgets=$null;if($null -ne $Payload.PSObject.Properties['CachedProbeWidgets']){$probeWidgets=$Payload.CachedProbeWidgets}
if($null -eq $probeWidgets){$requests=@();if($null -ne $Payload.PSObject.Properties['ProbeRequests']){$requests=@($Payload.ProbeRequests)};$probeWidgets=Measure-DomeniaFleetProbeEntries -Fleet $Payload.Fleet -Observations $Payload.Observations -Requests $requests -MaxAgeDays ([int]$Payload.MaxAgeDays)}
[pscustomobject]@{Rows=$rows;Records=$records;Widgets=$widgets;ProbeWidgets=$probeWidgets;Groups=$groups;Total=$result.Total;Matched=$result.Matched;Unknown=$result.Unknown;NotMatched=$result.NotMatched;ScopeTotal=$records.Count;Offset=$options.Offset;Selection=[string]$options.Selection}
'@
}
function Get-DomeniaQueryExportWorkerCode {
    # QueryExport: local files only. The explicit UI action captures the last completed
    # evaluation, never the current editable draft or a later database revision.
    return @'
$root=[string]$Payload.ModuleRoot
foreach($file in @('Domenia-Common.Model.ps1','Domenia-HealthRules.Model.ps1','Domenia-Boards.Model.ps1','Domenia-Probes.Model.ps1','Domenia-QuerySchema.Model.ps1','Domenia-Workstation.Model.ps1','Domenia-Query.Model.ps1')){. (Join-Path $root $file)}
$request=$Payload.Request
if($null -eq $request -or -not [string]$request.SnapshotKey){throw 'Instantané de lʼaperçu absent : relancez la requête.'}
$path=[IO.Path]::GetFullPath([string]$Payload.Path)
if([IO.Path]::GetExtension($path) -ine '.csv'){throw 'Le fichier dʼexport doit avoir lʼextension CSV.'}
$folder=[IO.Path]::GetDirectoryName($path)
if(-not [IO.Directory]::Exists($folder)){throw 'Le dossier dʼexport est indisponible.'}
if([IO.File]::Exists($path) -or [IO.File]::Exists($path+'.metadata.json')){throw 'Un fichier de ce nom existe déjà : choisissez un autre nom.'}
$recipe=ConvertFrom-Json -InputObject ([string]$request.RecipeJson) -ErrorAction Stop
$eligible=Select-DomeniaQueryPopulation $Payload.Records $recipe
$text=([string]$request.TextFilter).Trim();$state=[string]$request.StateFilter
if($text -or $state -in @('Actifs','Désactivés')){
    $filtered=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($record in $eligible){
        if($state -eq 'Actifs' -and (-not $record.Values.ContainsKey('active') -or -not [bool]$record.Values['active'])){continue}
        if($state -eq 'Désactivés' -and (-not $record.Values.ContainsKey('active') -or [bool]$record.Values['active'])){continue}
        if($text -and ([string]$record.Values['name']).IndexOf($text,[StringComparison]::OrdinalIgnoreCase) -lt 0 -and ([string]$record.Values['dn']).IndexOf($text,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
        $filtered.Add($record)
    }
    $eligible=$filtered
}
$options=[M4D.Admin.Common.Query.QueryOptions]::new()
$options.Selection=[Enum]::Parse([M4D.Admin.Common.Query.MatchState],[string]$request.Selection)
$options.SortField=[string]$request.SortField;$options.Descending=[bool]$request.Descending
$compiled=ConvertTo-DomeniaCompiledQuery $recipe
$snapshot=$compiled.PrepareSnapshot($eligible,$options,200000)
if($snapshot.SelectedCount -ne [long]$request.ExpectedRows){throw 'Lʼexport ne correspond pas à lʼaperçu validé ; aucun fichier créé.'}
$fields=@(Get-DomeniaQueryRequestedFields $recipe)
$columns=[ordered]@{GUID='Id';Nom='name';'Compte AD'='StateLabel';'Présence ping'='PresenceLabel';'Système AD'='OS';'Version AD'='Version';'Activité AD (jours)'='LogonDays';'Âge du ping'='Observation';'Chemin AD'='distinguished_name';'Valeurs de la requête'='QueryValues'}
$temporary=Join-Path $folder ('.domenia-query-'+[guid]::NewGuid().ToString('N')+'.tmp')
$metadataTemporary=$temporary+'.metadata.json';$writer=$null;$stream=$null;$publishedMetadata=$false;$publishedCsv=$false
$count=0L;$pages=0
try{
    $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($true),65536)
    $header=@(foreach($name in $columns.Keys){'"'+([string]$name).Replace('"','""')+'"'}) -join ';'
    $writer.WriteLine($header)
    for($offset=0;$offset -lt $snapshot.SelectedCount;$offset+=200){
        $page=$snapshot.ReadPage($offset,200);$pages++
        foreach($row in (ConvertTo-DomeniaQueryGridRows -Rows $page -Fields $fields)){
            $cells=@(foreach($property in $columns.Values){
                $value=[string]$row.$property
                # CSV data is literal even when Excel opens it. Neutralise formulas after leading whitespace.
                if($value -match '^[\s\p{Cf}]*[=+@\-\uFF1D\uFF0B\uFF0D\uFF20]' -or $value -match '^[\t\r\n]'){$value="'"+$value}
                '"'+$value.Replace('"','""')+'"'
            })
            $writer.WriteLine(($cells -join ';'));$count++
        }
    }
    $writer.Flush();$stream.Flush($true);$writer.Dispose();$writer=$null;$stream=$null
    $hash=[Security.Cryptography.SHA256]::Create();$csvInput=[IO.File]::OpenRead($temporary)
    try{$sha=[BitConverter]::ToString($hash.ComputeHash($csvInput)).Replace('-','').ToLowerInvariant()}finally{$csvInput.Dispose();$hash.Dispose()}
    $metadata=[pscustomobject]@{Format='Domenia.QueryExport/1';RowCount=$count;Pages=$pages;PageSize=200;CsvSHA256=$sha;CreatedUtc=[datetime]::UtcNow.ToString('o');SnapshotKey=[string]$request.SnapshotKey;EvaluatedAtUtc=[string]$request.EvaluatedAtUtc;ScopeDn=[string]$request.ScopeDn;Subtree=[bool]$request.Subtree;Selection=[string]$request.Selection;TextFilter=$text;StateFilter=$state;SortField=$options.SortField;Descending=$options.Descending;Recipe=$recipe;Total=$snapshot.Total;Matched=$snapshot.Matched;Unknown=$snapshot.Unknown;NotMatched=$snapshot.NotMatched}
    # Point 2: exact population of the preview (domain, OU, depth, types, criteria, snapshot) and the clocks of its
    # data, captured with the request; absent fields stay absent, never guessed by the worker.
    $metadata|Add-Member -NotePropertyName Population -NotePropertyValue $request.Population
    $metadata|Add-Member -NotePropertyName DataClocks -NotePropertyValue $request.DataClocks
    [IO.File]::WriteAllText($metadataTemporary,($metadata|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($true))
    [IO.File]::Move($metadataTemporary,$path+'.metadata.json');$publishedMetadata=$true
    [IO.File]::Move($temporary,$path);$publishedCsv=$true
    [pscustomobject]@{Path=$path;MetadataPath=($path+'.metadata.json');RowCount=$count;Pages=$pages;SHA256=$sha;SnapshotKey=[string]$request.SnapshotKey;Complete=$true}
}finally{
    if($null -ne $writer){$writer.Dispose()}elseif($null -ne $stream){$stream.Dispose()}
    if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
    if([IO.File]::Exists($metadataTemporary)){[IO.File]::Delete($metadataTemporary)}
    if($publishedMetadata -and -not $publishedCsv){[IO.File]::Delete($path+'.metadata.json')}
}
'@
}

function Get-DomeniaQueryLibraryWorkerCode {
    # QueryLibrary builds local descriptions only when the user visits the library.
    return @'
$root=[string]$Payload.ModuleRoot
foreach($file in @('Domenia-Common.Model.ps1','Domenia-HealthRules.Model.ps1','Domenia-Boards.Model.ps1','Domenia-Probes.Model.ps1','Domenia-QuerySchema.Model.ps1','Domenia-Workstation.Model.ps1','Domenia-Query.Model.ps1')){. (Join-Path $root $file)}
$rows=@(foreach($recipe in @(@(Get-DomeniaQueryTemplates)+@($Payload.Saved))){
    $template=([string]$recipe.Id -like 'template.*');$plan=Get-DomeniaQueryCollectionRequirements -Recipes @($recipe)
    $group=if($template){[string](Get-DomeniaMember $recipe 'Category' 'Modèles')}else{'Mes requêtes'}
    $description=[string](Get-DomeniaMember $recipe 'Description' 'Requête enregistrée : consultez et adaptez ses conditions dans le compositeur.')
    $source=if(-not $plan.Remote){'Base AD locale'}elseif($plan.ProbeIds.Count){'Relevé + '+$plan.ProbeIds.Count+' sonde(s)'}elseif($plan.Inventory){'Inventaire du poste'}else{'Présence et console'}
    [pscustomobject]@{Id=$recipe.Id;Name=$recipe.Name;Category=$group;Description=$description;DataSource=$source;SourceId=$(if($template){'Template'}else{'Saved'});Plan=$plan;Recipe=$recipe;SearchText=($recipe.Name+' '+$group+' '+$description+' '+$source)}
})
[pscustomobject]@{Rows=$rows}
'@
}
