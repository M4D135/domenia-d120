function Get-DomeniaQueryWorkerCode {
    # LocalQuery: computation only. The loader has already verified the versioned library.
    return @'
$root=[string]$Payload.ModuleRoot
foreach($file in @('Domenia-Common.Model.ps1','Domenia-Boards.Model.ps1','Domenia-Probes.Model.ps1','Domenia-Query.Model.ps1')){. (Join-Path $root $file)}
if($null -eq ('M4D.Admin.Common.Query.QueryEngine' -as [type])){throw 'Moteur de requêtes non chargé.'}
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
$eligible=Select-DomeniaQueryPopulation $records $Payload.Recipe
$text=([string]$Payload.TextFilter).Trim();$state=[string]$Payload.StateFilter
if($text -or $state -in @('Actifs','Désactivés')){
    $filtered=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($r in $eligible){
        if($state -eq 'Actifs' -and -not [bool]$r.Values['active']){continue}
        if($state -eq 'Désactivés' -and [bool]$r.Values['active']){continue}
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
$fields=@(@(@($Payload.Recipe.Clauses)+@(Get-DomeniaMember $Payload.Recipe 'Refinements' @())) | ForEach-Object{[string]$_.Field} | Select-Object -Unique)
$rows=@(ConvertTo-DomeniaQueryGridRows -Rows $result.Rows -Fields $fields)
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
[pscustomobject]@{Rows=$rows;Records=$records;Widgets=$widgets;ProbeWidgets=$probeWidgets;Total=$result.Total;Matched=$result.Matched;Unknown=$result.Unknown;NotMatched=$result.NotMatched;ScopeTotal=$records.Count;Offset=$options.Offset;Selection=[string]$options.Selection}
'@
}
