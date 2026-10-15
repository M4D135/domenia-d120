function Start-DomeniaQueryDetailRead {
    # Saved WMI SELECT summaries and collection verdicts are read before the local computation, for the workshop and
    # for a Search run alike: a nested or collection condition keeps the same meaning in both places.
    param($Payload,$State,[ValidateSet('Workshop','Search')][string]$Owner='Workshop')
    $definitions=@{};foreach($recipe in @($Payload.Recipe)+@($Payload.Saved)){$definition=Get-DomeniaMemberValue $recipe 'ReadDefinition';if($null -ne $definition){$definitions[[string]$definition.RequestKey]=$definition}}
    $collections=@{};foreach($recipe in @($Payload.Recipe)+@($Payload.Saved)){foreach($node in @(Get-DomeniaQueryCollectionNodes $recipe)){$collections[$node.ProjectionKey]=$node}}
    $requests=[Collections.Generic.List[object]]::new()
    foreach($definition in @($definitions.Values|Sort-Object RequestKey)){$requests.Add([pscustomobject]@{Kind='Detail';RequestKey=$definition.RequestKey;Nodes=@()})}
    foreach($group in @($collections.Values|Group-Object ProbeId)){$requests.Add([pscustomobject]@{Kind='Observation';RequestKey=[string]$group.Name;Nodes=@($group.Group)})}
    if(-not $requests.Count){$Payload|Add-Member NoteProperty DetailRows @() -Force;$Payload|Add-Member NoteProperty CollectionProjections @() -Force;Start-DomeniaQueryDetailCompute -Payload $Payload -State $State -Owner $Owner;return}
    if(($definitions.Count -gt 64) -or ($collections.Count -gt 64)){throw 'Un aperçu accepte au maximum 64 définitions WMI distinctes.'}
    if($Owner -eq 'Search'){$scopeDn=[string]$State.BaseDn;$subtree=([string]$State.Scope -eq 'Subtree')}else{$scopeDn=[string]$State.ExportRequest.ScopeDn;$subtree=[bool]$State.ExportRequest.Subtree}
    $context=New-DomeniaStoreContext -RequestId ([guid]::NewGuid().ToString('D')) -Generation ([long]$State.Generation) -ScopeDn $scopeDn -Subtree $subtree
    $read=[pscustomobject]@{Owner=$Owner;Context=$context;Payload=$Payload;State=$State;Definitions=$requests.ToArray();DefinitionIndex=0;Offset=0;Revision=-1L;Restarts=0;Rows=[Collections.Generic.List[object]]::new();Seen=@{};Bytes=0L;Projections=[Collections.Generic.List[object]]::new()}
    if($Owner -eq 'Search'){$State|Add-Member NoteProperty DetailRead $read -Force}else{$script:DomeniaQueryState|Add-Member NoteProperty DetailRead $read -Force}
    Request-DomeniaQueryDetailPage -Read $read
}
function Start-DomeniaQueryDetailCompute {
    param($Payload,$State,[string]$Owner='Workshop')
    if($Owner -eq 'Search'){Start-DomeniaSearchLocalCompute -Payload $Payload -State $State}else{Start-DomeniaQueryCompute -Payload $Payload -State $State}
}
function Clear-DomeniaQueryDetailRead {
    param($Read)
    if([string](Get-DomeniaMember $Read 'Owner' 'Workshop') -eq 'Search'){$Read.State.DetailRead=$null}else{$script:DomeniaQueryState.DetailRead=$null}
}
function Test-DomeniaQueryDetailReadCurrent {
    param($Read)
    if([string](Get-DomeniaMember $Read 'Owner' 'Workshop') -eq 'Search'){
        return ($null -ne $Read -and [object]::ReferenceEquals((Get-DomeniaMemberValue $Read.State 'DetailRead'),$Read) -and (Test-DomeniaSearchLocalQueryCurrent $Read.State) -and [string]$Read.Context.Path -ceq [string]$script:DatabaseScopedPath)
    }
    $q=$script:DomeniaQueryState
    return ($null -ne $q -and [object]::ReferenceEquals((Get-DomeniaMemberValue $q 'DetailRead'),$Read) -and [long]$Read.State.Epoch -eq [long]$script:SessionEpoch -and [long]$Read.State.Generation -eq [long]$q.Generation -and [string]$Read.State.SnapshotKey -ceq [string]$script:FleetQuerySnapshotKey -and [string]$Read.Context.Path -ceq [string]$script:DatabaseScopedPath -and [string]$Read.State.ScopeKey -ceq [string](Get-DomeniaFleetScope).Key)
}
function Request-DomeniaQueryDetailPage {
    param($Read)
    if(-not (Test-DomeniaQueryDetailReadCurrent $Read)){return}
    $definition=$Read.Definitions[$Read.DefinitionIndex]
    $query=if($definition.Kind -eq 'Detail'){[pscustomobject]@{Kind='Detail';ResultKind='WmiQuery';RequestKey=$definition.RequestKey;ScopeDn=$Read.Context.ScopeDn;Subtree=$Read.Context.Subtree;Offset=$Read.Offset;Limit=250;Projection='List';DetailProjection='QuerySummary'}}else{[pscustomobject]@{Kind='Observation';Family=('Probe:'+$definition.RequestKey);ScopeDn=$Read.Context.ScopeDn;Subtree=$Read.Context.Subtree;Offset=$Read.Offset;Limit=25;Projection='List'}}
    if($Read.Revision -gt 0){$query|Add-Member NoteProperty SnapshotRevision $Read.Revision}
    $job=Request-DomeniaStoreRead -Context $Read.Context -Query $query -SuccessHandler 'Complete-DomeniaQueryDetailPage' -ErrorHandler 'Fail-DomeniaQueryDetailPage' -CallbackState $Read
    if(-not $job){Fail-DomeniaQueryDetailPage 'Lecture des SELECT mémorisés non admise.' $Read}
}
function Complete-DomeniaQueryDetailPage {
    param($Result,$State)
    $read=$State;if(-not (Test-DomeniaQueryDetailReadCurrent $read)){return}
    try{
        if([string]$Result.DataSource -cne 'SQLite' -or [string]$Result.StoreId -cne [string]$read.Context.StoreId -or [bool]$Result.Busy -or [bool]$Result.Missing){throw 'Lecture des résultats WMI non confirmée par la base.'}
        $revision=[long]$Result.SnapshotRevision
        if($read.Revision -ge 0 -and $read.Revision -ne $revision){
            if($read.Restarts -ge 2){throw 'La base change pendant la lecture des résultats WMI. Réessayez après les collectes.'}
            $read.Restarts++;$read.DefinitionIndex=0;$read.Offset=0;$read.Revision=-1L;$read.Rows.Clear();$read.Projections.Clear();$read.Seen=@{};$read.Bytes=0;Request-DomeniaQueryDetailPage $read;return
        }
        $read.Revision=$revision
        if([long]$Result.Total -gt 200000){throw 'La lecture WMI locale dépasse le budget explicite de 200 000 identités par définition.'}
        $definition=$read.Definitions[$read.DefinitionIndex]
        if($definition.Kind -eq 'Observation'){
            $observations=@($Result.Observations)
            foreach($observation in $observations){if([string]$observation.Family -cne ('Probe:'+$definition.RequestKey)){throw 'La base a renvoyé une autre famille de sonde.'}}
            $payload=[pscustomobject]@{ModuleRoot=$script:DomeniaQueryModuleRoot;ProjectCollections=$true;ObservationRows=$observations;CollectionNodes=$definition.Nodes;MaxAgeDays=(Get-DomeniaObservationMaxAgeDays)}
            $page=[pscustomobject]@{Read=$read;Count=@($Result.Rows).Count;Total=[long]$Result.Total}
            $job=Start-UiTask -Name 'Atelier : interpréter une page de collections locales' -OperationId 'LocalQuery' -Code (Get-DomeniaQueryWorkerCode) -Payload $payload -CallbackState $page -SuccessHandler 'Complete-DomeniaQueryCollectionPage' -ErrorHandler 'Fail-DomeniaQueryCollectionPage' -TimeoutSeconds 60 -TaskClass Explicit
            if(-not $job){throw 'Interprétation de la collection non admise.'};if($read.Owner -eq 'Search'){$read.State.Job=$job}else{$script:DomeniaQueryState.Job=$job};return
        }
        $details=@($Result.Details)
        foreach($detail in $details){
            if([string]$detail.RequestKey -cne [string]$definition.RequestKey -or [string]$detail.ResultKind -cne 'WmiQuery'){throw 'La base a renvoyé une autre définition WMI.'}
            if($null -ne $detail.Data -and $null -ne $detail.Data.PSObject.Properties['Rows']){throw 'Projection SQL résumée indisponible : chargement massif des détails refusé.'}
            $key=[string]$detail.Guid+'|'+[string]$detail.RequestKey;if($read.Seen.ContainsKey($key)){throw 'Identité de résultat WMI répétée entre les pages.'}
            $read.Seen[$key]=$true;$read.Rows.Add($detail)
            $read.Bytes+=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $detail -Depth 8 -Compress))
            if($read.Bytes -gt 134217728){throw 'Les résumés WMI dépassent 128 Mio. Réduisez l''OU ou le nombre de widgets actifs.'}
        }
        Move-DomeniaQueryDetailPage -Read $read -Count @($Result.Rows).Count -Total ([long]$Result.Total)
    }catch{Fail-DomeniaQueryDetailPage $_.Exception.Message $read}
}
function Fail-DomeniaQueryDetailPage {
    param($Message,$State)
    if(-not (Test-DomeniaQueryDetailReadCurrent $State)){return}
    Clear-DomeniaQueryDetailRead $State
    if($State.Owner -eq 'Search'){Fail-DomeniaSearchLocalQuery -Message ([string]$Message) -State $State.State;return}
    Fail-DomeniaQueryEvaluation -Message ([string]$Message) -State $State.State
}
function Start-DomeniaQueryCompute {
    param($Payload,$State)
    $q=$script:DomeniaQueryState
    if($null -eq $q -or [long]$q.Generation -ne [long]$State.Generation -or [long]$State.Epoch -ne [long]$script:SessionEpoch){return}
    $q.Job=Start-UiTask -Name 'Atelier de requêtes : calcul local' -OperationId 'LocalQuery' -Code (Get-DomeniaQueryWorkerCode) -Payload $Payload -CallbackState $State -ReplaceKey 'query:local' -SuccessHandler 'Complete-DomeniaQueryEvaluation' -ErrorHandler 'Fail-DomeniaQueryEvaluation' -TimeoutSeconds 120 -TaskClass 'Explicit'
    if(-not $q.Job){Fail-DomeniaQueryEvaluation 'Calcul non admis, relancez l''aperçu.' $State}
}

function Move-DomeniaQueryDetailPage {
    param($Read,[int]$Count,[long]$Total)
    if(-not (Test-DomeniaQueryDetailReadCurrent $Read)){return}
    $Read.Offset+=$Count
    if($Read.Offset -lt $Total){if(-not $Count){throw 'Lecture locale paginée sans progression.'};Request-DomeniaQueryDetailPage $Read;return}
    $Read.DefinitionIndex++;$Read.Offset=0
    if($Read.DefinitionIndex -lt $Read.Definitions.Count){Request-DomeniaQueryDetailPage $Read;return}
    $Read.Payload|Add-Member NoteProperty DetailRows ($Read.Rows.ToArray()) -Force
    $Read.Payload|Add-Member NoteProperty CollectionProjections ($Read.Projections.ToArray()) -Force
    if($Read.Owner -ne 'Search'){$Read.State.ExportRequest|Add-Member NoteProperty DetailSnapshotRevision $Read.Revision -Force}
    Clear-DomeniaQueryDetailRead $Read
    Start-DomeniaQueryDetailCompute -Payload $Read.Payload -State $Read.State -Owner $Read.Owner
}
function Complete-DomeniaQueryCollectionPage {
    param($Result,$State)
    $read=$State.Read;if(-not (Test-DomeniaQueryDetailReadCurrent $read)){return}
    try{
        $packet=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Projections');if($null -eq $packet){throw 'Projection de collection incomplète.'}
        foreach($projection in @($packet.Projections)){
            $key=[string]$projection.Guid+'|'+[string]$projection.ProjectionKey;if($read.Seen.ContainsKey($key)){throw 'Collection répétée entre les pages.'}
            $read.Seen[$key]=$true;$read.Projections.Add($projection);$read.Bytes+=512
            if($read.Bytes -gt 134217728){throw 'Les verdicts des collections dépassent 128 Mio. Réduisez les widgets actifs ou le périmètre.'}
        }
        Move-DomeniaQueryDetailPage -Read $read -Count $State.Count -Total $State.Total
    }catch{Fail-DomeniaQueryDetailPage $_.Exception.Message $read}
}
function Fail-DomeniaQueryCollectionPage {
    param($Message,$State)
    Fail-DomeniaQueryDetailPage -Message $Message -State $State.Read
}
