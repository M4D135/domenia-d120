# Explicit whole-index scan, bounded concurrent reads and persistent changed-only associations.
function Test-DomeniaParkRunCurrent {
    param($State)
    return ($null -ne $script:ParkRun -and $null -ne $State -and $State.RunId -ceq $script:ParkRun.Id -and $State.Epoch -eq [long]$script:SessionEpoch -and [string]$State.Path -ceq [string]$script:DatabaseScopedPath)
}
function Update-DomeniaParkRunStatus {
    if($null -eq $script:ParkRun){return}
    $r=$script:ParkRun
    if($r.Completed){Clear-DomeniaParkTargetBuffers $r.Targets}
    $status=if($r.Completed -and $r.Stopping){'Relevé arrêté'}elseif($r.Completed){$(if($r.PingOnly){'Ping termine'}else{'Releve termine'})}elseif($r.Stopping){'Arret demande'}else{$(if($r.PingOnly){'Ping en cours'}else{'Releve en cours'})}
    $text=if($r.PingOnly){$status+' : '+$r.Done+'/'+$r.Targets.Count+' postes pingues, '+$r.Online+' joignables, '+($r.Done-$r.Online)+' sans reponse.'}else{$status+' : '+$r.Done+'/'+$r.Targets.Count+' postes verifies, '+$r.Online+' joignables, '+$r.Reused+' identites en cache, '+$r.Changed+' associations actualisees, '+$r.Failed+' lectures non confirmees.'}
    $text+=' '+$r.CachedMeasurements+' mesures encore fraîches réutilisées ; '+$r.Pending.Count+'/'+$r.Concurrency+' lectures en parallèle.'
    $detail=Get-DomeniaParkRunDetailText $r
    if($detail){$text+=' '+$detail}
    $save=Get-DomeniaPersistenceState
    if($save.Pending -gt 0){$text+=' Enregistrement local en attente.'}
    if($save.Suspended -or $save.Conflicts -gt 0){$text+=' Stockage a verifier dans Fiabilite.'}
    $r.StatusText=$text
    # A finished run that read workstations changed the observations: the selected workstation board is redrawn at
    # once, the home overview now or when Accueil is shown again.
    if($r.Completed -and [bool]$r.FleetRefresh -and -not [bool]$r.FleetRefreshed){
        $r|Add-Member -NotePropertyName FleetRefreshed -NotePropertyValue $true -Force
        if($r.Approved -and $r.Done -gt 0){
            if($null -ne $script:SelectedObject){try{Show-DomeniaBoard -Board Computer -Quiet}catch{}}
            try{Request-DomeniaFleetRefresh -Force}catch{}
        }
    }
    Update-DomeniaParkControls
    foreach($label in @('LblParkStatus','LblParkDetectionStatus')){[void](Set-DomeniaControlText $label $text)}
    if($r.Scope -eq 'Results'){[void](Set-DomeniaControlText 'LblLiveState' $text)}
}
function Get-DomeniaParkRunDetailText {
    # Points 13 to 20 in plain words: validated results and real waiting time, adapted or paused sources, transient
    # retries, capabilities remembered, CIM queries avoided and the durable plan. Unknown values are not shown.
    param($Run)
    $parts=New-Object 'System.Collections.Generic.List[string]'
    try{
        $started=Get-DomeniaMemberValue $Run 'StartedUtc'
        if($null -ne $started){
            $waiting=(Get-DomeniaParkListCount $Run 'Deferred')+(Get-DomeniaParkListCount $Run 'Retry')+[Math]::Max(0,@($Run.Targets).Count-[int]$Run.Next)
            $state=Get-DomeniaCampaignProgressState -Total @($Run.Targets).Count -Validated ([int]$Run.Done) -Pending ([int]$Run.Pending.Count) -Waiting $waiting -StartedUtc $started -LastValidatedUtc (Get-DomeniaMemberValue $Run 'LastValidatedUtc') -HeldSeconds ([double](Get-DomeniaMember $Run 'HeldSeconds' 0))
            if(-not [bool]$Run.Completed){$parts.Add('Progression : '+[string]$state.Text+'.')}
        }
        $sources=Get-DomeniaCampaignSourceSummary (Get-DomeniaMemberValue $Run 'Sources')
        if($sources){$parts.Add('Charge adaptée : '+$sources+'.')}
        $retried=[int](Get-DomeniaMember $Run 'Retried' 0);$waitingRetry=Get-DomeniaParkListCount $Run 'Retry'
        if($retried -gt 0){$parts.Add([string]$retried+' nouvel(s) essai(s) après incident transitoire'+$(if($waitingRetry){', '+[string]$waitingRetry+' en attente'}else{''})+$(if([int](Get-DomeniaMember $Run 'RetryExhausted' 0)){' ; '+[string](Get-DomeniaMember $Run 'RetryExhausted' 0)+' poste(s) sans réponse après trois essais'}else{''})+'.')}
        $skipped=[int](Get-DomeniaMember $Run 'CapabilitySkipped' 0)
        if($skipped -gt 0){$parts.Add([string]$skipped+' sonde(s) non relue(s) : classe WMI absente lors dʼun relevé récent.')}
        $cimSkipped=[int](Get-DomeniaMember $Run 'CimSkipped' 0)+[int](Get-DomeniaMember $Run 'SkippedTargets' 0)
        if($cimSkipped -gt 0){$parts.Add([string]$cimSkipped+' poste(s) sans lecture WMI : refus ou inaccessibilité mémorisés pour un temps limité.')}
        $avoided=[long](Get-DomeniaMember $Run 'CimAvoided' 0);$executed=[long](Get-DomeniaMember $Run 'CimExecuted' 0)
        if($avoided -gt 0){$parts.Add('Requêtes WMI : '+[string]$executed+' envoyées, '+[string]$avoided+' évitées par regroupement.')}
        $note=[string](Get-DomeniaMember $Run 'CampaignNote' '')
        if($note){$parts.Add($note)}
    }catch{}
    return ($parts.ToArray() -join ' ')
}
function Update-DomeniaParkControls {
    # The stop button is active only while a detection is running.
    $stop=Get-DomeniaControl 'BtnParkResultsStop'
    if($null -ne $stop -and -not $script:DemoMode){$stop.IsEnabled=($null -ne $script:ParkRun -and -not $script:ParkRun.Completed)}
}
function Start-DomeniaOnlinePark {
    # -PingOnly (decision David 2026-10-07): ping of the listed workstations only, no console reading.
    # -ScopeTargets: explicit workstations (the selected one for the queries of its board). -Inventory adds the light
    # WMI reading (Analyser la liste, decision David 2026-10-08). The whole domain is still refused.
    param([switch]$DisplayedResults,[switch]$PingOnly,[switch]$WmiOnly,[switch]$Inventory,[object[]]$ScopeTargets=$null,[string]$ScopeLabel='',[object[]]$Probes=$null,[switch]$ForceRefresh,[string]$RefreshOperationId='',[switch]$PassThru)
    $started=$false
    try{
        if($PingOnly -and $WmiOnly){throw 'Choisissez Ping ou WMI, pas les deux modes exclusifs.'}
        # Decision David 2026-10-05: whole-park detection removed; only the displayed, filtered rows are read.
        if(-not $DisplayedResults -and $null -eq $ScopeTargets){throw 'detection sur tout le parc retiree. Filtrez la liste dans Rechercher puis Detecter la liste.'}
        # UX-33: a work view listed over the whole domain is read-only: no ping, detection or analysis of its rows.
        if($null -eq $ScopeTargets -and [bool]$script:ListSurveyBlocked){throw 'vue sur tout le domaine : aucun relevé des postes. Choisissez une OU puis relancez la vue.'}
        if($script:DemoMode){throw 'Releve distant indisponible en demonstration.'}
        if($null -ne $script:ParkRun -and -not $script:ParkRun.Completed){throw 'Un releve est deja en cours.'}
        if(@($script:AsyncJobs.Values|Where-Object{$_.OperationId -in @('StoragePurge','IndexBuild','LegacyMigration')}).Count){throw 'Attendez la fin de la maintenance locale.'}
        if((Get-DomeniaPersistenceState).Pending -gt 0 -or ($null -ne $script:Persistence -and $script:Persistence.LinkBusy)){throw 'Attendez la confirmation des enregistrements locaux avant un nouveau releve.'}
        if(-not $script:DatabaseScopedPath){throw 'Aucune base autonome active.'}
        [void](Initialize-DomeniaWinSqliteNative)
        $targets=@()
        if($null -ne $ScopeTargets){
            $targets=@($ScopeTargets|Where-Object{$null -ne $_ -and $_.distinguished_name -and $_.object_guid})
            if(-not $targets.Count){throw 'Poste selectionne sans DN ni GUID connu : relisez sa fiche.'}
            $DisplayedResults=[switch]$true
        }
        elseif($DisplayedResults){
            $grid=Get-DomeniaControl 'DgObjects'
            $targets=@(foreach($row in @($grid.Items)){if($null -ne $row -and $row.Type -eq 'Machine' -and $row.DN -and $row.Guid){[pscustomobject]@{name=[string]$row.Name;distinguished_name=[string]$row.DN;object_guid=[string]$row.Guid}}})
            if(-not $targets.Count){throw 'Aucun poste dans les resultats affiches.'}
        }
        $script:ParkRun=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;Targets=@();Next=0;Pending=@{};Concurrency=([Math]::Max(1,[Math]::Min(8,[int](Get-DomeniaSetting 'Collection.Concurrency' '4'))));CacheMinutes=([Math]::Max(0,[Math]::Min(1440,[int](Get-DomeniaSetting 'Collection.CacheMinutes' '15'))));CachedMeasurements=0;Done=0;Online=0;Reused=0;Changed=0;Failed=0;Stopping=$false;Completed=$false;Loading=$true;Approved=$false;ObservationReader=(New-DomeniaObservationReader);Timer=$null;StatusText='';Generation=[long]$script:GlobalSearchGeneration;PingOnly=[bool]$PingOnly;WmiOnly=[bool]$WmiOnly;AccountGeneration=[long]$script:DomeniaAccountGeneration;StorePending=@{};Inventory=[bool]$Inventory;Probes=@(Add-DomeniaRemoteProbeDefinitionHash $Probes);FleetRefresh=$true;ScopeLabel=[string]$ScopeLabel;Scope=$(if($DisplayedResults){'Results'}else{'Park'})}
        $started=$true
        # Points 14 to 20: per-source budgets bounded by the chosen value, deferred and retried targets, durations of
        # the usage profile, measured progress and the durable plan (created on approval).
        $collection=[ordered]@{Sources=(New-DomeniaCampaignSources -MaxLimit ([int]$script:ParkRun.Concurrency));Deferred=(New-Object 'System.Collections.Generic.List[object]');Retry=(New-Object 'System.Collections.Generic.List[object]')
            Freshness=(Get-DomeniaActiveFreshnessTable);StartedUtc=$null;LastValidatedUtc=$null;HeldSeconds=[double]0;HeldSinceUtc=$null;Retried=0;RetryExhausted=0;CapabilitySkipped=0;CimSkipped=0;SkippedTargets=0
            CimExecuted=[long]0;CimAvoided=[long]0;CampaignProgress=$null;CampaignNote='';CampaignSavedUtc=[datetime]::MinValue;CampaignDirty=$false;StopReason=''}
        foreach($field in $collection.Keys){$script:ParkRun|Add-Member -NotePropertyName $field -NotePropertyValue $collection[$field] -Force}
        $script:ParkRun|Add-Member -NotePropertyName RefreshOperationId -NotePropertyValue $RefreshOperationId
        $script:ParkRun|Add-Member -NotePropertyName FailureMessage -NotePropertyValue ''
        if($ForceRefresh){$script:ParkRun.CacheMinutes=0}
        $r=$script:ParkRun;$state=[pscustomobject]@{RunId=$r.Id;Epoch=$r.Epoch;Path=$r.Path}
        # Read only the observation families used by this collection mode. No WMI payload is parsed for a ping refresh.
        $families=$null
        if($r.PingOnly){$families=@('Presence')}elseif($r.WmiOnly){$families=@('Console','Inventory')+@($r.Probes|ForEach-Object{'Probe:'+([string]$_.Id)})}
        $job=Start-UiTask -Name 'Preparer le releve du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{Action='ParkTargets';Path=$r.Path;BusyTimeoutMs=250;Scope=$r.Scope;Targets=$targets;ObservationFamilies=$families}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkTargets' -ErrorHandler 'Fail-DomeniaParkTargets' -NonCancellable -TimeoutSeconds 60 -TaskClass 'Explicit'
        if(-not $job){throw 'Lecture du parc non admise.'}
        [void](Set-DomeniaControlText 'LblParkStatus' 'Lecture des postes et des sessions conservees en cache...')
    }catch{if($started -and $null -ne $script:ParkRun -and $script:ParkRun.Loading){$script:ParkRun.Completed=$true;$script:ParkRun.FailureMessage=$_.Exception.Message};Set-Status ('Releve impossible : '+$_.Exception.Message) 'WARN'}
    Update-DomeniaParkControls
    if($PassThru){if($started -and $null -ne $script:ParkRun -and -not $script:ParkRun.Completed){return [string]$script:ParkRun.Id};return ''}
}
function Start-DomeniaParkAnalysis {
    # Analyser la liste (decision David 2026-10-08): ping, console user and light WMI reading of the displayed
    # workstations, plus the WMI queries of the dashboard widgets. Read only, confirmed with the count first.
    $probes=$null
    try{
        $ids=@(Get-DomeniaBoardProbeIds)
        if($ids.Count){$probes=@(ConvertTo-DomeniaProbePayload -Ids $ids)}
    }catch{Set-Status ('Requetes des widgets ignorees : '+$_.Exception.Message) 'WARN';$probes=$null}
    Start-DomeniaOnlinePark -DisplayedResults -Inventory -Probes $probes
}
function Complete-DomeniaParkTargets {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=$script:ParkRun
    try{
        $packet=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Busy')
        if($null -eq $packet -or $packet.Busy){throw 'Base occupee : aucun poste interroge.'}
        $r.Loading=$false;$r.Targets=@($packet.Rows|Where-Object{$null -ne $_})
        if($r.Stopping -or -not $r.Targets.Count){$r.Completed=$true;Update-DomeniaParkRunStatus;return}
        $start=${function:Start-DomeniaParkRunTimer};$stop=${function:Stop-DomeniaOnlinePark};$runId=$r.Id
        $message=$r.Targets.Count.ToString()+$(if($r.Scope -eq 'Results'){' postes dans les resultats affiches.'}elseif($r.ScopeLabel){' postes de '+[string]$r.ScopeLabel+'.'}else{' postes du perimetre choisi.'})+' Lecture legere de la console Windows (CIM/DCOM), '+$r.Concurrency+' postes au maximum a la fois. Identité AD revérifiée après cinq minutes, ou dès quʼun changement est connu. Les sessions RDP ne sont pas recensees. Associations et cache conserves entre les lancements ; aucun inventaire complet, aucune tache distante.'
        if($r.Inventory){$message=$r.Targets.Count.ToString()+' postes'+$(if($r.ScopeLabel){' de '+$r.ScopeLabel}else{' dans les resultats affiches'})+'. Ping, utilisateur console et releve WMI leger (modele, memoire, disque C:, build, demarrage)'+$(if(@($r.Probes).Count){', plus '+@($r.Probes).Count+' requete(s) WMI des widgets'}else{''})+', en lecture seule ; '+$r.Concurrency+' postes au maximum a la fois. Associations actualisees si l utilisateur change ; resultats conserves pour les tableaux de bord.'}
        elseif(@($r.Probes).Count){$message=$r.Targets.Count.ToString()+' postes'+$(if($r.ScopeLabel){' de '+$r.ScopeLabel}else{''})+'. '+@($r.Probes).Count+' requete(s) WMI des widgets en lecture seule, plus ping et utilisateur console ; '+$r.Concurrency+' postes au maximum a la fois. Resultats conserves pour les tableaux de bord.'}
        elseif($r.ScopeLabel){$message=$r.Targets.Count.ToString()+' postes de '+$r.ScopeLabel+'.'+$(if($r.PingOnly){' Ping ICMP seulement.'}else{' Ping puis utilisateur console ; associations actualisees si changement.'})}
        if($r.PingOnly -and -not $r.ScopeLabel){$message=$r.Targets.Count.ToString()+' postes dans les resultats affiches. Ping ICMP seulement, '+$r.Concurrency+' postes au maximum a la fois ; aucune lecture de session ni association.'}
        if($r.WmiOnly){$message=$r.Targets.Count.ToString()+' postes'+$(if($r.ScopeLabel){' de '+$r.ScopeLabel}else{' du perimetre choisi'})+'. Lecture WMI seulement : console'+$(if($r.Inventory){', inventaire leger'}else{''})+$(if(@($r.Probes).Count){' et sondes des widgets'}else{''})+'. Aucun ping ni validation AD supplementaire. '+$r.Concurrency+' lectures au maximum en parallele.'}
        if(-not $r.PingOnly){$message+=' '+$(if($r.CacheMinutes -gt 0){'Réutilisation des mesures encore fraîches selon le profil « '+[string](Get-DomeniaMember $r.Freshness 'Label' 'Standard')+' », au plus '+$r.CacheMinutes+' min. Le ping et la console sont relus.'}else{'Relecture forcée de toutes les mesures demandées.'})}
        if(-not $r.PingOnly){
            $cimPlan=Measure-DomeniaCimQueryPlan -ProbeUser $true -Inventory ([bool]$r.Inventory) -Probes @($r.Probes)
            if([int]$cimPlan.Avoided -gt 0){$message+=' Requêtes WMI prévues par poste : '+[string]$cimPlan.Executed+' au lieu de '+[string]$cimPlan.Requested+' grâce au regroupement.'}
        }
        $message+=' Les postes dʼun même sous-réseau présumé partagent un budget qui ralentit si leurs réponses tardent ; les autres continuent. Un incident transitoire est relu au plus deux fois, espacé ; aucun nouvel essai après un refus dʼidentifiants.'
        $message+=Get-DomeniaCollectionWindowCampaignNote
        $message+=Get-DomeniaCampaignReplacementNote
        Request-DomeniaInlineConfirmation -Title $(if($r.Inventory){'Analyser les postes affiches'}elseif(@($r.Probes).Count){'Sonder pour les widgets'}elseif($r.PingOnly){'Pinger les postes affiches'}elseif($r.Scope -eq 'Results'){'Detecter sur les resultats affiches'}else{'Detecter sur tout le parc'}) -Target ([string]$script:Conn.Domain) -Message $message -ConfirmText $(if($r.PingOnly){'Pinger'}elseif($r.Inventory){'Analyser'}else{'Verifier les sessions'}) -CancelText 'Annuler' -OnConfirm ({& $start $runId}.GetNewClosure()) -OnCancel ({& $stop -RunId $runId}.GetNewClosure())
    }catch{Fail-DomeniaParkTargets $_.Exception.Message $State}
}
function Fail-DomeniaParkTargets {
    param($Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $script:ParkRun.Completed=$true;$script:ParkRun.Loading=$false;Clear-DomeniaParkTargetBuffers $script:ParkRun.Targets
    if($null -ne $script:ParkRun.PSObject.Properties['FailureMessage']){$script:ParkRun.FailureMessage=[string]$Message}
    [void](Set-DomeniaControlText 'LblParkStatus' ('Releve non lance : '+[string]$Message))
    Update-DomeniaParkControls
}
function Start-DomeniaParkRunTimer {
    param([string]$RunId)
    $r=$script:ParkRun
    if($null -eq $r -or $r.Id -cne $RunId -or $r.Stopping -or $r.Completed -or $r.Epoch -ne [long]$script:SessionEpoch -or $r.Path -cne [string]$script:DatabaseScopedPath){return}
    if($null -ne $r.PSObject.Properties['RefreshOperationId'] -and [string]$r.RefreshOperationId -and -not (Test-DomeniaOuRefreshCurrent ([string]$r.RefreshOperationId))){Stop-DomeniaOnlinePark -RunId $RunId;return}
    if($null -ne $r.Timer){return}
    $r.Approved=$true
    # Points 17 and 20: the measured progress starts with the approval, and the plan becomes durable at once.
    try{$r.StartedUtc=[datetime]::UtcNow;[void](Save-DomeniaCampaignPlan -Run $r)}catch{}
    # FI-05: protected heartbeat timer, owned and registered by the factory; it also runs minimized (an approved run).
    $timer=New-DomeniaTimer -Owner 'Timer:ParkRun' -IntervalMs 250 -RunWhenHidden -Tick {Invoke-DomeniaParkRunTick};$r.Timer=$timer
    $timer.Start();Update-DomeniaParkRunStatus
}
function Stop-DomeniaOnlinePark {
    param([string]$RunId='')
    $r=$script:ParkRun;if($RunId -and $null -ne $r -and $r.Id -cne $RunId){return};if($null -eq $r){return}
    $r.Stopping=$true
    if(-not $r.Pending.Count -and -not $r.Loading){
        $save=Get-DomeniaPersistenceState
        if(-not $r.Approved -or ($save.Pending -eq 0 -and $r.StorePending.Count -eq 0) -or $save.Suspended){$r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()};try{Complete-DomeniaCampaignPlan $r}catch{}}
    }
    Update-DomeniaParkRunStatus
}
function Get-DomeniaParkListCount {
    # Count of a list held by the run (Deferred, Retry); 0 for a run created before these lists existed.
    param($Run,[string]$Name)
    $list=Get-DomeniaMemberValue $Run $Name $null
    if($null -eq $list){return 0}
    return [int]$list.Count
}
function Test-DomeniaParkWorkRemaining {
    # Targets never dispatched, deferred by their source budget, or waiting for a spaced retry.
    param($Run)
    if([int]$Run.Next -lt @($Run.Targets).Count){return $true}
    return (((Get-DomeniaParkListCount $Run 'Deferred') + (Get-DomeniaParkListCount $Run 'Retry')) -gt 0)
}
function Add-DomeniaParkHeldTime {
    # Point 17: real waiting time while places were free (budgets, retries, storage). At most five seconds per tick,
    # so that a suspended Dispatcher never counts as waiting.
    param($Run,[datetime]$NowUtc,[switch]$Clear)
    if($null -eq $Run.PSObject.Properties['HeldSinceUtc']){return}
    if($Clear){$Run.HeldSinceUtc=$null;return}
    if($null -ne $Run.HeldSinceUtc){$Run.HeldSeconds=[double]$Run.HeldSeconds+[Math]::Min(5.0,[Math]::Max(0.0,($NowUtc-[datetime]$Run.HeldSinceUtc).TotalSeconds))}
    $Run.HeldSinceUtc=$NowUtc
}
function Get-DomeniaParkTargetSourceKey {
    # Point 15: presumed subnet of the last address seen for the workstation: this session, its expanded stored
    # observation, or the ping detail of the stored JSON (read without decoding the whole observation).
    param($Run,$Target)
    $provider=if([bool]$Run.PingOnly){'Network'}else{'Cim'}
    $address=Get-DomeniaTargetAddress -Computer ([string]$Target.Computer) -Previous $Target.Previous
    if(-not $address){
        $json=[string](Get-DomeniaMemberValue $Target 'PreviousJson' '')
        if($json -and $json -match '"PresenceDetail"\s*:\s*"((?:[^"\\]|\\.){0,512})"'){$address=Register-DomeniaTargetAddress -Computer ([string]$Target.Computer) -Text $Matches[1]}
    }
    return (Get-DomeniaCollectionSourceKey -Provider $provider -Address $address)
}
function Select-DomeniaParkNextTarget {
    # Due retries first, then deferred targets, then the list in order. A target whose source refuses is deferred
    # (512 at most, with its source) so that a slow or paused site never blocks the others. Each source is asked once
    # per tick; the stored observation is decoded only for the target that leaves.
    param($Run,[datetime]$NowUtc)
    $running=@{};$verdict=@{}
    foreach($pending in @($Run.Pending.Values)){$key=[string](Get-DomeniaMemberValue $pending 'SourceKey');if($key){$running[$key]=[int]$running[$key]+1}}
    $admit={param([string]$Key)
        if(-not $verdict.ContainsKey($Key)){$verdict[$Key]=[bool](Test-DomeniaSourceAdmission -Health $Run.Sources.Health -Key $Key -Running ([int]$running[$Key]) -Policy (Get-DomeniaCampaignSourcePolicy $Run.Sources $Key) -NowUtc $NowUtc).Allowed}
        return [bool]$verdict[$Key]
    }
    for($i=0;$i -lt $Run.Retry.Count;$i++){
        $item=$Run.Retry[$i]
        if([datetime]$item.NotBeforeUtc -gt $NowUtc){continue}
        if(-not (& $admit ([string]$item.SourceKey))){continue}
        $Run.Retry.RemoveAt($i)
        return [pscustomobject]@{Index=[int]$item.Index;Target=$Run.Targets[[int]$item.Index];SourceKey=[string]$item.SourceKey;Attempt=[int]$item.Attempt}
    }
    for($i=0;$i -lt $Run.Deferred.Count;$i++){
        $item=$Run.Deferred[$i]
        if(-not (& $admit ([string]$item.SourceKey))){continue}
        $Run.Deferred.RemoveAt($i)
        $target=$Run.Targets[[int]$item.Index];Expand-DomeniaParkPrevious $target
        return [pscustomobject]@{Index=[int]$item.Index;Target=$target;SourceKey=[string]$item.SourceKey;Attempt=1}
    }
    $scanned=0
    while(([int]$Run.Next -lt @($Run.Targets).Count) -and ($scanned -lt 16)){
        $index=[int]$Run.Next;$target=$Run.Targets[$index]
        $key=Get-DomeniaParkTargetSourceKey $Run $target
        $scanned++
        if(& $admit $key){$Run.Next++;Expand-DomeniaParkPrevious $target;return [pscustomobject]@{Index=$index;Target=$target;SourceKey=$key;Attempt=1}}
        if($Run.Deferred.Count -ge 512){break}
        $Run.Deferred.Add([pscustomobject]@{Index=$index;SourceKey=$key});$Run.Next++
    }
    return $null
}
function Invoke-DomeniaParkRunTick {
    $r=$script:ParkRun;if($null -eq $r){return}
    if($r.Epoch -ne [long]$script:SessionEpoch -or $r.Path -cne [string]$script:DatabaseScopedPath -or $r.AccountGeneration -ne [long]$script:DomeniaAccountGeneration -or $script:AsyncEngineClosing){$r.Stopping=$true;$r.Completed=$true;Clear-DomeniaParkTargetBuffers $r.Targets;if($null -ne $r.Timer){$r.Timer.Stop()};try{Complete-DomeniaCampaignPlan $r}catch{};return}
    if($null -ne $r.PSObject.Properties['RefreshOperationId'] -and [string]$r.RefreshOperationId -and -not (Test-DomeniaOuRefreshCurrent ([string]$r.RefreshOperationId))){$r.Stopping=$true}
    # Cancelled workers never silently cause the rest of the fleet to start.
    foreach($id in @($r.Pending.Keys)){
        if(-not $script:AsyncJobs.Contains($id) -and -not @($script:DetachedReadJobs|Where-Object{$_.Id -eq $id}).Count){$r.Pending.Remove($id);$r.Stopping=$true;$r.Failed++;if($null -ne $r.PSObject.Properties['StopReason']){$r.StopReason='lecture dʼun poste arrêtée hors du relevé'}}
    }
    if(($r.Stopping -or -not (Test-DomeniaParkWorkRemaining $r)) -and -not $r.Pending.Count){
        $save=Get-DomeniaPersistenceState
        if($r.StorePending.Count -gt 0 -or ($save.Pending -gt 0 -and -not $save.Suspended)){Update-DomeniaParkRunStatus;return}
        $r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()};try{Complete-DomeniaCampaignPlan $r}catch{};Update-DomeniaParkRunStatus;return
    }
    # Point 20: progress written at most every ten seconds while the campaign runs.
    try{[void](Save-DomeniaCampaignProgress -Run $r)}catch{}
    if($r.Stopping -or -not $r.Approved){return}
    $nowUtc=[datetime]::UtcNow
    if($null -ne $script:DomeniaRemoteStoreQueue -and $script:DomeniaRemoteStoreQueue.Count -gt 0){Add-DomeniaParkHeldTime $r $nowUtc;return}
    if($r.StorePending.Count -ge 16){Add-DomeniaParkHeldTime $r $nowUtc;return}
    if($script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){Add-DomeniaParkHeldTime $r $nowUtc;return}
    if($null -ne $script:Persistence){
        if($script:Persistence.Failures -ge 3 -or $script:Persistence.Conflicts.Count){$r.Stopping=$true;if($null -ne $r.PSObject.Properties['StopReason']){$r.StopReason='enregistrement local suspendu'};Update-DomeniaParkRunStatus;return}
        if($script:Persistence.Pending.Count -ge 64 -or $script:Persistence.LinkBusy){Add-DomeniaParkHeldTime $r $nowUtc;return}
    }
    # One admission per tick keeps the Dispatcher responsive. The engine may impose a smaller provider budget.
    if($r.Pending.Count -ge $r.Concurrency){Add-DomeniaParkHeldTime $r $nowUtc -Clear;return}
    $pick=$null
    try{$pick=Select-DomeniaParkNextTarget -Run $r -NowUtc $nowUtc}catch{$r.Stopping=$true;$r.StopReason='cache dʼun poste illisible';Set-Status ('Cache du poste illisible. Relancez le relevé après actualisation. '+$_.Exception.Message) 'WARN';return}
    if($null -eq $pick){Add-DomeniaParkHeldTime $r $nowUtc;Update-DomeniaParkRunStatus;return}
    Add-DomeniaParkHeldTime $r $nowUtc -Clear
    $target=$pick.Target
    # Point 19: capabilities known missing on this workstation are not read again for a limited time; a forced
    # read (« Forcer la relecture ») ignores that memory.
    $build=[string](Get-DomeniaMember (Get-DomeniaMemberValue $target.Previous 'Inventory') 'Build' '')
    $capability=Get-DomeniaCapabilityPlan -Memory (Get-DomeniaCapabilityMemory) -Target ([string]$target.Computer) -Probes @($r.Probes) -Previous $target.Previous -NowUtc $nowUtc -Build $build -AccountGeneration ([long]$script:DomeniaAccountGeneration) -Force ([int]$r.CacheMinutes -eq 0)
    $skipCim=([bool]$capability.SkipCim -and -not [bool]$r.PingOnly)
    $r.CapabilitySkipped=[int]$r.CapabilitySkipped+@($capability.Skipped).Count
    if($skipCim -and [bool]$r.WmiOnly){
        # WMI only and WMI known refused or inaccessible: nothing to send for this workstation now.
        $r.SkippedTargets=[int]$r.SkippedTargets+1;Clear-DomeniaParkTargetBuffers @($target);Update-DomeniaParkRunStatus;return
    }
    if($skipCim){$r.CimSkipped=[int]$r.CimSkipped+1}
    $plan=New-DomeniaCollectionPlan -Previous $target.Previous -Guid $target.Guid -Key $target.Key -Probes @($capability.Probes) -Inventory ([bool]$r.Inventory) -CacheMinutes ([int]$r.CacheMinutes) -Freshness $r.Freshness
    $state=[pscustomobject]@{RunId=$r.Id;Epoch=$r.Epoch;Path=$r.Path;Target=$target;Job='';Plan=$plan;PingOnly=$r.PingOnly;WmiOnly=$r.WmiOnly;RemoteStartedUtc=[datetime]::UtcNow.ToString('o');Index=[int]$pick.Index;Attempt=[int]$pick.Attempt;SourceKey=[string]$pick.SourceKey;DispatchedUtc=$nowUtc;SkipCim=$skipCim}
    [void](Initialize-DomeniaRemoteStoreState -State $state -Guid $target.Guid -DN $target.Key -Generation $r.Generation)
    # Point 17: one step per finished ping or CIM query; no progress for the idle delay ends the read, and a read
    # that keeps progressing still stops at its total duration.
    $sendInventory=([bool]$plan.Inventory -and -not [bool]$r.PingOnly -and -not $skipCim)
    $sendProbes=@();if(-not ([bool]$r.PingOnly -or $skipCim)){$sendProbes=@($plan.Probes)}
    $probeCount=$sendProbes.Count
    $idle=if($probeCount -or $sendInventory){25}else{20}
    $total=if($probeCount -or $sendInventory){[Math]::Min(300,30+12*$probeCount+$(if($sendInventory){12}else{0}))}else{30}
    $readProgress=[hashtable]::Synchronized(@{StartedTimestamp=0L;LastRowTimestamp=0L;RowsRead=0L})
    # What was really asked: a failure is dated only for the families that were sent.
    $state|Add-Member -NotePropertyName SentConsole -NotePropertyValue (-not [bool]$r.PingOnly -and -not $skipCim) -Force
    $state|Add-Member -NotePropertyName SentInventory -NotePropertyValue $sendInventory -Force
    try{
        $id=Start-UiTask -Name ($(if($r.PingOnly){'Ping de la liste : '}else{$(if($r.WmiOnly){'WMI du perimetre : '}else{'Console du parc : '})})+$target.Computer) -OperationId 'LiveConsole' -Code (Get-DomeniaLiveProbeCode) -Payload ([pscustomobject]@{Computer=$target.Computer;Key=$target.Key;Guid=$target.Guid;Previous=$target.Previous;AllowIdentityCache=([int]$r.CacheMinutes -gt 0);MethodSeconds=4;CollectPing=(-not [bool]$r.WmiOnly);ValidateConsoleIdentity=$false;ProbeUser=(-not [bool]$r.PingOnly -and -not $skipCim);Inventory=$sendInventory;Probes=$sendProbes;AllowedClasses=@(@(Get-DomeniaProbeCatalog)|ForEach-Object{[string]$_.Class});ReadProgress=$readProgress}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkSession' -ErrorHandler 'Fail-DomeniaParkSession' -TimeoutSeconds $idle -HardTimeoutSeconds $total -TaskClass 'Explicit'
        if(-not $id){throw 'Lecture non admise.'}
        $state.Job=[string]$id;$r.Pending[[string]$id]=$state
    }catch{$r.Stopping=$true;$r.StopReason=[string]$_.Exception.Message;[void](Set-DomeniaControlText 'LblParkStatus' ('Releve interrompu : '+$_.Exception.Message+' Les resultats precedents sont conserves.'))}
}
function Complete-DomeniaParkSession {
    param($Result,$State)
    # Duplicate engine delivery must not resubmit a measurement or reopen pending accounting.
    if([string](Get-DomeniaMemberValue $State 'StoreBatchId')){return}
    # A completed collection belongs to its captured store even after selection/session changes.
    $packet=Get-DomeniaEffectiveWorkerResult $Result @('Outcome','Key','Guid','Computer')
    $current=Test-DomeniaParkRunCurrent $State
    if($current){[void]$script:ParkRun.Pending.Remove([string]$State.Job);$script:ParkRun.StorePending[[string]$State.Job]=$true}
    try{
        if($null -eq $packet -or [string]$packet.Key -ine [string]$State.Target.Key -or [string]$packet.Guid -ine [string]$State.Target.Guid -or [string]$packet.Computer -ine [string]$State.Target.Computer){throw 'Identite de la mesure distante incoherente.'}
        if($current -and ($packet.Outcome -eq 'AuthRejected' -or $packet.DirectoryAuthRejected)){$script:ParkRun.Stopping=$true;if($null -ne $script:ParkRun.PSObject.Properties['StopReason']){$script:ParkRun.StopReason='identifiants rejetés : reprise après un changement de compte'}}
        if($current){Register-DomeniaParkMeasurement -Run $script:ParkRun -Packet $packet -State $State}
        [void](Submit-DomeniaRemoteObservations -Result $packet -State $State -SuccessHandler 'Complete-DomeniaParkStored' -ErrorHandler 'Fail-DomeniaParkStored')
    }catch{Fail-DomeniaParkStored -Message $_.Exception.Message -State $State}
}

function Register-DomeniaParkMeasurement {
    # Points 13, 14, 15, 18, 19 and 160 for one workstation answer, before it is stored: the source budget learns
    # from the answer and its delay, a transient incident gets a bounded and spaced retry, missing capabilities are
    # remembered, the last address feeds the subnet budget and the CIM queries avoided are counted.
    param($Run,$Packet,$State)
    if($null -eq $Run.PSObject.Properties['Sources']){return}
    try{
        $nowUtc=[datetime]::UtcNow
        $failure=ConvertTo-DomeniaCollectionFailure -Outcome ([string]$Packet.Outcome) -Presence ([string](Get-DomeniaMember $Packet 'Presence' '')) -PingCollected (-not [bool]$State.WmiOnly) -JobFailed ([bool](Get-DomeniaMember $State 'JobFailed' $false)) -ErrorText ([string](Get-DomeniaMember $State 'JobError' ''))
        $latency=-1.0;$dispatched=Get-DomeniaMemberValue $State 'DispatchedUtc'
        if($null -ne $dispatched){$latency=[Math]::Max(0.0,($nowUtc-[datetime]$dispatched).TotalMilliseconds)}
        $key=[string](Get-DomeniaMember $State 'SourceKey' '')
        if($key){[void](Register-DomeniaSourceOutcome -Health $Run.Sources.Health -Key $key -Outcome ([string]$failure.Health) -LatencyMs $latency -Policy (Get-DomeniaCampaignSourcePolicy $Run.Sources $key) -NowUtc $nowUtc)}
        $retry=Get-DomeniaCollectionRetryDecision -Category ([string]$failure.Category) -Attempt ([int](Get-DomeniaMember $State 'Attempt' 1)) -NowUtc $nowUtc
        if([bool]$retry.Retry -and -not [bool]$Run.Stopping){
            $State|Add-Member -NotePropertyName WillRetry -NotePropertyValue $true -Force
            $Run.Retry.Add([pscustomobject]@{Index=[int]$State.Index;NotBeforeUtc=$retry.NotBeforeUtc;Attempt=([int]$State.Attempt+1);SourceKey=$key})
            $Run.Retried=[int]$Run.Retried+1
        }elseif([string]$failure.Category -eq 'Transient'){$Run.RetryExhausted=[int]$Run.RetryExhausted+1}
        $build=[string](Get-DomeniaMember (Get-DomeniaMemberValue $Packet 'Inventory') 'Build' '')
        if(-not $build){$build=[string](Get-DomeniaMember (Get-DomeniaMemberValue $State.Target.Previous 'Inventory') 'Build' '')}
        if(-not [bool](Get-DomeniaMember $State 'SkipCim' $false)){Register-DomeniaCollectionCapabilities -Computer ([string]$State.Target.Computer) -Packet $Packet -Probes @($State.Plan.Probes) -Build $build}
        [void](Register-DomeniaTargetAddress -Computer ([string]$Packet.Computer) -Text ([string](Get-DomeniaMember $Packet 'PresenceDetail' '')))
        $queries=Get-DomeniaMemberValue $Packet 'CimQueries'
        if($null -ne $queries){
            $Run.CimExecuted=[long]$Run.CimExecuted+[long](Get-DomeniaMember $queries 'Executed' 0);$Run.CimAvoided=[long]$Run.CimAvoided+[long](Get-DomeniaMember $queries 'Avoided' 0)
            $script:DomeniaCimQueriesExecuted=[long]$script:DomeniaCimQueriesExecuted+[long](Get-DomeniaMember $queries 'Executed' 0)
            $script:DomeniaCimQueriesAvoided=[long]$script:DomeniaCimQueriesAvoided+[long](Get-DomeniaMember $queries 'Avoided' 0)
        }
    }catch{try{Write-AppLog ('Budget de collecte non mis à jour : '+$_.Exception.Message) 'WARN'}catch{}}
}

function Complete-DomeniaParkStored {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=$script:ParkRun;[void]$r.StorePending.Remove([string]$State.Job)
    if(-not (Test-DomeniaRemoteStoreContext $State $Result)){$r.Stopping=$true;return}
    $observation=Get-DomeniaCommittedObservation $Result $State
    if($null -eq $observation){return}
    # Point 18: an attempt followed by a spaced retry is stored (its date and error are facts) but counted once,
    # with the last attempt. Point 20: a final result is never read again by a resume of this plan.
    if(-not [bool](Get-DomeniaMember $State 'WillRetry' $false)){
        $r.Done++;if([string]$observation.Presence -eq 'En ligne'){$r.Online++}
        if(-not $r.PingOnly){$r.CachedMeasurements += [int]$State.Plan.Reused}
        if(@($Result.Observations|Where-Object{[string]$_.Guid -ieq [string]$State.StoreGuid -and [string]$_.Status -eq 'Error'}).Count){$r.Failed++}
        if($null -ne $r.PSObject.Properties['LastValidatedUtc']){$r.LastValidatedUtc=[datetime]::UtcNow}
        try{Set-DomeniaCampaignTargetValidated -Run $r -Index ([int](Get-DomeniaMember $State 'Index' -1))}catch{}
    }
    Clear-DomeniaParkTargetBuffers @($State.Target)
    if($null -eq $script:FleetObservations){$script:FleetObservations=@{}}
    $keep=([string]$script:SelectedObject.DN -ieq [string]$observation.Key)
    if($null -ne $script:FleetLast){$keep=$keep -or (Test-DomeniaLiveRowInScope -Dn $observation.Key -BaseDn ([string]$script:FleetLast.Scope) -Scope $(if($script:FleetLast.Subtree){'Subtree'}else{'OneLevel'}))}
    if($keep){$script:FleetObservations[([string]$observation.Key).ToLowerInvariant()]=$observation}
    if($r.Generation -eq [long]$script:GlobalSearchGeneration){Update-DomeniaParkResultRows -Observation $observation}
    $script:FleetStale=$true
    Update-DomeniaParkRunStatus
}

function Fail-DomeniaParkStored {
    param([string]$Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=$script:ParkRun;[void]$r.StorePending.Remove([string]$State.Job);$r.Stopping=$true;$r.Failed++
    $r.FailureMessage=$Message
    if($null -ne $r.PSObject.Properties['StopReason']){$r.StopReason='enregistrement local non confirmé'}
    Set-Status ('Mesure non publiee : enregistrement SQLite non confirme. '+$Message) 'ERROR'
    Update-DomeniaParkRunStatus
}

function Fail-DomeniaParkSession {
    param($Message,$State)
    # Point 18: a worker that ended without answer (delay, engine refusal) is classified from its message.
    $State|Add-Member -NotePropertyName JobFailed -NotePropertyValue $true -Force
    $State|Add-Member -NotePropertyName JobError -NotePropertyValue ([string]$Message) -Force
    $consoleSent=-not [bool]$State.PingOnly;$inventorySent=[bool]$State.Plan.Inventory
    if($null -ne $State.PSObject.Properties['SentConsole']){$consoleSent=[bool]$State.SentConsole;$inventorySent=[bool]$State.SentInventory}
    $packet=[pscustomobject]@{Outcome='Unavailable';Key=$State.Target.Key;Guid=$State.Target.Guid;Computer=$State.Target.Computer;Detail=[string]$Message;Presence='Erreur de ping';PresenceDetail=[string]$Message;PresenceCheckedUtc=$(if(-not $State.WmiOnly){$State.RemoteStartedUtc}else{''});ConsoleAttempted=$consoleSent;ConsoleCheckedUtc=$(if($consoleSent){$State.RemoteStartedUtc}else{''});InventoryAttempted=$inventorySent;InventoryCheckedUtc=$State.RemoteStartedUtc;InventoryError=[string]$Message;CacheReused=$false;DirectoryAuthRejected=$false}
    Complete-DomeniaParkSession $packet $State
}

function Update-DomeniaParkResultRows {
    param($Packet,$Observation)
    # This value was read back from SQLite after COMMIT; do not regenerate dates in the view.
    $liveObservation=$Observation
    if($null -ne $script:Live){$script:Live.Observations[$Observation.Key]=$liveObservation}
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return}
    # Direct lookup in the live search map (keyed by lowercase DN): no scan of a list of thousands per result.
    $rows=$null
    if($null -ne $script:Live -and $null -ne $script:Live.Search -and $null -ne $script:Live.Search.Map){$hit=$script:Live.Search.Map[[string]$Observation.Key];$rows=@(if($null -ne $hit){$hit})}
    # Without a live search, snapshot Items before changing properties that may affect an active filter.
    if($null -eq $rows){$rows=@($grid.Items)}
    foreach($row in $rows){
        if([string]$row.Type -ne 'Machine' -or [string]$row.DN -ine $Observation.Key -or [string]$row.Guid -ine $Observation.Guid){continue}
        Set-DomeniaLiveObservationOnRow $row $liveObservation
        [void](Set-RowAssociationMetadata -Rows @($row))
        if([string]$row.Association){Set-DomeniaLoginColumnVisible $true}
    }
    # ResultRow notifies WPF; classic PSCustomObject rows need a refresh after the scan.
    if($null -ne $grid.ItemsSource -and $script:ParkRun.Next -ge $script:ParkRun.Targets.Count -and -not $script:ParkRun.Pending.Count){$grid.Items.Refresh()}
}

function Initialize-DomeniaRemoteStoreState {
    param($State,[string]$Guid,[string]$DN,[long]$Generation=0,[string]$RequestId='',[switch]$ReadOnly)
    if(-not $ReadOnly){$identity=[guid]::Empty;if(-not [guid]::TryParse($Guid,[ref]$identity) -or $identity -eq [guid]::Empty -or -not $DN){throw 'Identite AD de collecte incomplete.'}}
    $domain=([string]$script:Conn.BaseDn).Trim()
    if(-not $domain -or (-not [string]::Equals($DN,$domain,[StringComparison]::OrdinalIgnoreCase) -and -not $DN.EndsWith(','+$domain,[StringComparison]::OrdinalIgnoreCase))){throw 'Cible de collecte hors du domaine de connexion.'}
    if(-not $RequestId){$RequestId=[guid]::NewGuid().ToString('D')}
    $context=New-DomeniaStoreContext -RequestId $RequestId -Generation $Generation -ScopeDn $DN -Subtree $false
    $State|Add-Member -NotePropertyName StoreContext -NotePropertyValue $context -Force
    $State|Add-Member -NotePropertyName AccountGeneration -NotePropertyValue ([long]$script:DomeniaAccountGeneration) -Force
    $State|Add-Member -NotePropertyName StoreGuid -NotePropertyValue $Guid -Force
    $State|Add-Member -NotePropertyName StoreDn -NotePropertyValue $DN -Force
    return $State
}

function Submit-DomeniaRemoteObservations {
    param($Result,$State,[string]$SuccessHandler,[string]$ErrorHandler)
    $changes=@(ConvertTo-DomeniaRemoteObservationChanges -Result $Result -Guid ([string]$State.StoreGuid) -DN ([string]$State.StoreDn))
    return Submit-DomeniaRemoteChanges -Changes $changes -State $State -SuccessHandler $SuccessHandler -ErrorHandler $ErrorHandler
}

function Submit-DomeniaRemoteChanges {
    param([object[]]$Changes,$State,[string]$SuccessHandler,[string]$ErrorHandler)
    if([string](Get-DomeniaMemberValue $State 'StoreBatchId')){return $true}
    if($null -eq $script:DomeniaRemoteStoreQueue){$script:DomeniaRemoteStoreQueue=[Collections.Generic.Queue[object]]::new()}
    if($script:DomeniaRemoteStoreQueue.Count -ge 64){throw 'File de stockage pleine : nouvelles collectes suspendues.'}
    if($null -eq $State.StoreContext){throw 'Contexte de collecte absent : resultat non publiable.'}
    $batchId=[guid]::NewGuid().ToString('D')
    # Validate and freeze once. Backpressure never changes the batch id, source dates or content.
    $frozen=ConvertTo-DomeniaStoreBatch -Context $State.StoreContext -BatchId $batchId -Sequence 0 -Changes $Changes
    $packet=$frozen.Json|ConvertFrom-Json -ErrorAction Stop
    $item=[pscustomobject]@{BatchId=$batchId;Context=$packet.Context;Changes=@($packet.Changes);State=$State;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler;Failed=$false;Delivered=$false}
    $State|Add-Member -NotePropertyName StoreBatchId -NotePropertyValue $batchId -Force
    $script:DomeniaRemoteStoreQueue.Enqueue($item)
    if($null -eq $script:DomeniaRemoteStoreTimer){$script:DomeniaRemoteStoreTimer=New-DomeniaTimer -Owner 'Timer:RemoteStore' -IntervalMs 250 -RunWhenHidden -Tick {Invoke-DomeniaRemoteStoreQueue}}
    $script:DomeniaRemoteStoreTimer.Start()
    Invoke-DomeniaRemoteStoreQueue
    return $true
}

function Invoke-DomeniaRemoteStoreQueue {
    if($null -eq $script:DomeniaRemoteStoreQueue -or -not $script:DomeniaRemoteStoreQueue.Count){if($null -ne $script:DomeniaRemoteStoreTimer){$script:DomeniaRemoteStoreTimer.Stop()};return}
    if($script:AsyncEngineClosing){return}
    $item=$script:DomeniaRemoteStoreQueue.Peek()
    if($item.Failed){return}
    try{
        $admission=Submit-DomeniaStoreBatch -Context $item.Context -BatchId $item.BatchId -Sequence 0 -Changes $item.Changes -SuccessHandler 'Complete-DomeniaRemoteStoreBatch' -ErrorHandler 'Fail-DomeniaRemoteStoreBatch' -CallbackState $item
        if([bool]$admission.Accepted){[void]$script:DomeniaRemoteStoreQueue.Dequeue();return}
        if([bool]$admission.Backpressure){return}
        throw ('Enregistrement refuse : '+[string]$admission.Reason)
    }catch{
        # Retain an unadmitted immutable batch; stop producers instead of dropping measurements.
        $item.Failed=$true
        if($item.ErrorHandler){& $item.ErrorHandler -Message $_.Exception.Message -State $item.State}
        Write-AppLog ('Mesures non enregistrees ; collecte suspendue : '+$_.Exception.Message) 'ERROR'
    }
}

function Complete-DomeniaRemoteStoreBatch {
    param($Result,$State)
    if([bool]$State.Delivered){return}
    if(-not [bool]$Result.Saved -or [string]$Result.DataSource -cne 'SQLite' -or [string]$Result.BatchId -ine [string]$State.BatchId -or [string]$Result.StoreId -cne [string]$State.Context.StoreId -or [string]$Result.RequestId -cne [string]$State.Context.RequestId){
        Fail-DomeniaRemoteStoreBatch -Message 'Recu SQLite incoherent ; aucune mesure publiee.' -State $State;return
    }
    $State.Delivered=$true
    if($State.SuccessHandler){& $State.SuccessHandler -Result $Result -State $State.State}
}

function Fail-DomeniaRemoteStoreBatch {
    param([string]$Message,$State)
    if($State.ErrorHandler){& $State.ErrorHandler -Message $Message -State $State.State}
}

function Get-DomeniaCommittedObservation {
    param($Result,$State)
    if(-not (Test-DomeniaRemoteStoreContext $State $Result)){return $null}
    $rows=@($Result.ObservationRows|Where-Object{[string]$_.Guid -ieq [string]$State.StoreGuid -and [string]$_.Key -ieq [string]$State.StoreDn})
    if($rows.Count -ne 1){throw 'Mesure committée absente ou ambigue.'}
    return $rows[0]
}

function Start-DomeniaCommittedPresence {
    param([string]$Computer,[string]$Guid,[string]$DN,[string]$DisplayDN,[ValidateSet('Machine','Utilisateur')][string]$DisplayKind='Machine',[string]$Suffix='',[switch]$Explicit)
    try{
        $identity=[guid]::Empty
        if(-not [guid]::TryParse($Guid,[ref]$identity) -or $identity -eq [guid]::Empty -or -not $DN){throw 'Identite AD du poste non enregistree. Relisez sa fiche avant de mesurer sa presence.'}
        $state=[pscustomobject]@{Computer=$Computer;DisplayDN=$DisplayDN;DisplayKind=$DisplayKind;Suffix=$Suffix;Explicit=[bool]$Explicit;RemoteStartedUtc=[datetime]::UtcNow.ToString('o')}
        [void](Initialize-DomeniaRemoteStoreState -State $state -Guid $Guid -DN $DN -Generation ([long]$script:GlobalSearchGeneration))
        $job=Start-UiTask -Name ('Presence de '+$Computer) -OperationId 'SelectedPresence' -Code (Get-DomeniaLiveProbeCode) -Payload ([pscustomobject]@{Computer=$Computer;Key=$DN;Guid=$Guid;CollectPing=$true;ProbeUser=$false;Inventory=$false;Probes=@();ValidateConsoleIdentity=$false}) -CallbackState $state -ReplaceKey 'presence-selected' -TimeoutSeconds 8 -SuccessHandler 'Complete-DomeniaCommittedPresence' -ErrorHandler 'Fail-DomeniaCommittedPresence'
        if(-not $job){throw 'Controle de presence non admis.'}
        Set-Status ('Ping de '+$Computer+' en cours ; les valeurs affichees gardent leur date jusquʼa enregistrement.')
    }catch{Set-Status $_.Exception.Message 'WARN'}
}
function Complete-DomeniaCommittedPresence {
    param($Result,$State)
    try{
        $packet=Get-DomeniaEffectiveWorkerResult $Result @('Outcome','Key','Guid','Computer')
        [void](Submit-DomeniaRemoteObservations $packet $State 'Publish-DomeniaCommittedPresence' 'Fail-DomeniaCommittedPresenceStore')
    }catch{Fail-DomeniaCommittedPresenceStore $_.Exception.Message $State}
}
function Fail-DomeniaCommittedPresence {
    param([string]$Message,$State)
    $packet=[pscustomobject]@{Outcome='PresenceOnly';Key=$State.StoreDn;Guid=$State.StoreGuid;Computer=$State.Computer;Presence='Erreur de ping';PresenceDetail=$Message;PresenceCheckedUtc=$State.RemoteStartedUtc}
    Complete-DomeniaCommittedPresence $packet $State
}
function Publish-DomeniaCommittedPresence {
    param($Result,$State)
    $observation=Get-DomeniaCommittedObservation $Result $State
    if($null -eq $observation){return}
    if($null -ne $script:Live){$script:Live.Observations[[string]$observation.Key]=$observation}
    Set-DomeniaResultRowPresence -Dn $observation.Key -Target $State.Computer -Observation $observation
    if($null -eq $script:SelectedObject -or [string]$script:SelectedObject.DN -ine [string]$State.DisplayDN){return}
    $view=Get-DomeniaLivePresenceView $observation
    $label=[string]$view.Display
    if($State.DisplayKind -eq 'Utilisateur'){$label+='  '+[string]$State.Computer+[string]$State.Suffix}
    Set-DomeniaPresenceText -Name $(if($State.DisplayKind -eq 'Utilisateur'){'TxtUserPresence'}else{'TxtCompPresence'}) -State $label
    Update-DomeniaObjectPresence -State $label -Target $State.Computer
    if($State.Explicit){Set-Status ($State.Computer+' : '+$view.Display+' · '+$view.Detail)}
}
function Fail-DomeniaCommittedPresenceStore {
    param([string]$Message,$State)
    if(Test-DomeniaRemoteStoreContext $State $null){Set-Status ('Presence non mise à jour : enregistrement SQLite non confirme. '+$Message) 'WARN'}
}

function Submit-DomeniaRemoteDetail {
    # The caller supplies an allowlisted result and the completion time produced inside its worker.
    param($Data,$State,[bool]$Succeeded,[string]$SourceCompletedUtc,[string]$ErrorText='')
    if(-not [string]$State.ResultKind -or -not [string]$State.RequestKey){throw 'Identite du resultat detaille absente.'}
    $change=[pscustomobject]@{Kind='DetailResult';Guid=$State.StoreGuid;DN=$State.StoreDn;ResultKind=$State.ResultKind;RequestKey=$State.RequestKey;AttemptedAtUtc=$SourceCompletedUtc;ObservedAtUtc=$(if($Succeeded){$SourceCompletedUtc}else{''});Status=$(if($Succeeded){'Success'}else{'Error'});Error=$ErrorText;Data=$Data}
    return Submit-DomeniaRemoteChanges -Changes @($change) -State $State -SuccessHandler 'Complete-DomeniaRemoteDetailStored' -ErrorHandler 'Fail-DomeniaRemoteDetailStored'
}
function Complete-DomeniaRemoteDetailStored {
    param($Result,$State)
    if(-not (Test-DomeniaRemoteStoreContext $State $Result)){return}
    $details=@($Result.Details|Where-Object{[string]$_.Guid -ieq [string]$State.StoreGuid -and [string]$_.ResultKind -ceq [string]$State.ResultKind -and [string]$_.RequestKey -ceq [string]$State.RequestKey})
    if($details.Count -ne 1){Fail-DomeniaRemoteDetailStored 'Resultat detaille committé absent ou ambigu.' $State;return}
    $detail=$details[0]
    $data=if([string]$detail.Status -eq 'Error'){Get-DomeniaMemberValue $detail 'AttemptData'}else{$detail.Data}
    if($null -eq $data){Fail-DomeniaRemoteDetailStored ([string]$detail.Error) $State;return}
    if([string](Get-DomeniaMemberValue $data 'CollectionError')){if($State.PublishErrorHandler){& $State.PublishErrorHandler -Message ([string]$data.CollectionError) -State $State};return}
    # Provenance metadata is added only to a SQL readback; no network result reaches this handler.
    $data|Add-Member -NotePropertyName DataSource -NotePropertyValue 'SQLite' -Force
    $data|Add-Member -NotePropertyName StoreRevision -NotePropertyValue ([long]$Result.SnapshotRevision) -Force
    $data|Add-Member -NotePropertyName SourceCompletedUtc -NotePropertyValue ([string]$detail.LastAttemptAtUtc) -Force
    if($State.PublishHandler){& $State.PublishHandler -Result $data -State $State}
}
function Fail-DomeniaRemoteDetailStored {
    param([string]$Message,$State)
    if(-not (Test-DomeniaRemoteStoreContext $State $null)){return}
    if($State.PublishErrorHandler){& $State.PublishErrorHandler -Message ('Enregistrement SQLite non confirme : '+$Message) -State $State}
}

function Complete-DomeniaLastUserCollected {
    param($Result,$State)
    try{
        $packet=Get-DomeniaEffectiveWorkerResult $Result @('Computer','Success','Attempts','SourceCompletedUtc')
        if($null -eq $packet -or [string]$packet.Computer -ine [string]$State.Computer){throw 'Identite du resultat dernier utilisateur incoherente.'}
        $safe=[ordered]@{}
        foreach($name in @('Computer','UserLogin','RawAccount','Source','Confidence','VerifiedInAD','Details','Attempts','Success','FallbackTasks','FallbackTransport','TaskBytes','RemoteAccessFailed','UserSid','UserUpn','ObservedSid')){$safe[$name]=Get-DomeniaMemberValue $packet $name}
        [void](Submit-DomeniaRemoteDetail -Data ([pscustomobject]$safe) -State $State -Succeeded ([bool]$packet.Success) -SourceCompletedUtc ([string]$packet.SourceCompletedUtc) -ErrorText $(if(-not $packet.Success){[string]$packet.Details}else{''}))
    }catch{Fail-DomeniaRemoteDetailStored -Message $_.Exception.Message -State $State}
}
function Fail-DomeniaLastUserCollected {
    param([string]$Message,$State)
    $data=[pscustomobject]@{Computer=$State.Computer;UserLogin='';RawAccount='';Source='Lecture distante non confirmee';Confidence=0;VerifiedInAD=$false;Details=$Message;Attempts=@();Success=$false;FallbackTasks=0;RemoteAccessFailed=$true}
    try{[void](Submit-DomeniaRemoteDetail -Data $data -State $State -Succeeded $false -SourceCompletedUtc ([string]$State.RemoteStartedUtc) -ErrorText $Message)}catch{Fail-DomeniaRemoteDetailStored $_.Exception.Message $State}
}

function New-DomeniaClassicCollectionState {
    param([string]$Computer,[string]$ResultKind,[string]$RequestKey,[string]$PublishHandler,[string]$PublishErrorHandler)
    $dn=[string]$script:SelectedObject.DN;$guid=[string](Get-DomeniaMemberValue (Get-DomeniaMemberValue $script:SelectedObject 'Safety') 'Guid')
    $state=[pscustomobject]@{Computer=$Computer;DN=$dn;ResultKind=$ResultKind;RequestKey=$RequestKey;PublishHandler=$PublishHandler;PublishErrorHandler=$PublishErrorHandler;RemoteStartedUtc=[datetime]::UtcNow.ToString('o')}
    [void](Initialize-DomeniaRemoteStoreState $state $guid $dn ([long]$script:GlobalSearchGeneration))
    return $state
}
function ConvertTo-DomeniaClassicStoreData {
    param($Result,[string]$ResultKind)
    $safe=[ordered]@{}
    foreach($name in @('Computer','Success','DurationMs','FallbackTasks','TaskBytes','FallbackTransport','DomeniaTransport','DomeniaBytesSent','DomeniaBytesReceived','Transport','MethodsUsed','Namespace','ClassName','Query','InstanceCount','Truncated','Errors','Reader')){
        $value=Get-DomeniaMemberValue $Result $name
        if($null -ne $value){$safe[$name]=$value}
    }
    # Store only explicit presentation fields. A WMI property may itself name a secret; omit that row and its schema.
    $allowed=@('Category','Item','Value','Source','Scope','Name','Version','Publisher','InstallDate','Size','SizeKb','Location','UninstallString','Architecture','Method','Status','Items','DurationMs','Detail','Check','Namespace','Depth','Class','Properties','Methods','Kind','System','Property','Type','IsKey','Qualifiers','Instance','Account','Edition','Date','SizeMB','InstallLocation','PackageFullName')
    $secret='(?i)password|passwd|pwd|secret|token|credential|recoverypassword|recoverykey|privatekey|productkey|serialnumberkey|cleartext'
    $redacted=0
    foreach($name in @('Rows','Access','Namespaces','Classes','Schema','Instances')){
        $value=Get-DomeniaMemberValue $Result $name
        if($null -eq $value){continue}
        $rows=[Collections.Generic.List[object]]::new()
        foreach($row in @($value)){
            $label=([string](Get-DomeniaMemberValue $row 'Property')+' '+[string](Get-DomeniaMemberValue $row 'Item'))
            if($label -match $secret){$redacted++;continue}
            $fields=[ordered]@{}
            foreach($field in $allowed){$v=Get-DomeniaMemberValue $row $field;if($null -ne $v){$fields[$field]=$v}}
            $rows.Add([pscustomobject]$fields)
        }
        $safe[$name]=$rows.ToArray()
    }
    if($ResultKind -eq 'ClassicInventory'){
        # Dashboard metrics are numeric or labelled aggregates produced by the inventory worker.
        $metrics=Get-DomeniaMemberValue $Result 'Metrics'
        if($null -ne $metrics){$safe.Metrics=$metrics}
    }
    $safe.RedactedSecretRows=$redacted
    return [pscustomobject]$safe
}
function Complete-DomeniaClassicCollected {
    param($Result,$State)
    try{
        $packet=Get-DomeniaEffectiveWorkerResult $Result @('Computer','SourceCompletedUtc')
        if($null -eq $packet -or (Normalize-LinkComputer ([string]$packet.Computer)) -ine (Normalize-LinkComputer ([string]$State.Computer))){throw 'Resultat detaille sans identite du poste attendue.'}
        $safe=ConvertTo-DomeniaClassicStoreData -Result $packet -ResultKind $State.ResultKind
        $success=($null -eq $packet.PSObject.Properties['Success'] -or [bool]$packet.Success)
        if(-not $success){$safe|Add-Member -NotePropertyName CollectionError -NotePropertyValue 'Lecture distante non confirmee ; les dernieres donnees valides sont conservees.' -Force}
        [void](Submit-DomeniaRemoteDetail -Data $safe -State $State -Succeeded $success -SourceCompletedUtc ([string]$packet.SourceCompletedUtc) -ErrorText $(if($success){''}else{'Lecture distante non confirmee ; consulter le rapport dʼacces.'}))
    }catch{Fail-DomeniaRemoteDetailStored $_.Exception.Message $State}
}
function Fail-DomeniaClassicCollected {
    param([string]$Message,$State)
    $data=[pscustomobject]@{Computer=$State.Computer;Success=$false;CollectionError=$Message}
    try{[void](Submit-DomeniaRemoteDetail -Data $data -State $State -Succeeded $false -SourceCompletedUtc $State.RemoteStartedUtc -ErrorText $Message)}catch{Fail-DomeniaRemoteDetailStored $_.Exception.Message $State}
}
function Test-DomeniaClassicResultCurrent {
    param($Result,$State,[switch]$ContextOnly)
    if((-not $ContextOnly -and [string](Get-DomeniaMemberValue $Result 'DataSource') -cne 'SQLite') -or -not (Test-DomeniaRemoteStoreContext $State $null)){return $false}
    if($null -eq $script:SelectedObject -or [string]$script:SelectedObject.DN -ine [string]$State.StoreDn){return $false}
    $guid=[string](Get-DomeniaMemberValue (Get-DomeniaMemberValue $script:SelectedObject 'Safety') 'Guid')
    return ($guid -and $guid -ieq [string]$State.StoreGuid)
}

function Complete-DomeniaCachedInventoryRead {
    param($Result,$State)
    if(-not (Test-DomeniaRemoteStoreContext $State $null) -or $Result.Busy -or $Result.Missing -or [string]$Result.DataSource -cne 'SQLite' -or [string]$Result.StoreId -cne [string]$State.StoreContext.StoreId){return}
    $saved=@($Result.Details|Where-Object{[string]$_.Guid -ieq [string]$State.StoreGuid -and [string]$_.ResultKind -eq 'ClassicInventory' -and $null -ne $_.Data -and [string]$_.LastSuccessAtUtc}|Sort-Object LastSuccessAtUtc -Descending|Select-Object -First 1)
    if(-not $saved.Count){return}
    $data=$saved[0].Data
    $data|Add-Member -NotePropertyName DataSource -NotePropertyValue 'SQLite' -Force
    $data|Add-Member -NotePropertyName SourceCompletedUtc -NotePropertyValue ([string]$saved[0].LastSuccessAtUtc) -Force
    $data|Add-Member -NotePropertyName StoreRevision -NotePropertyValue ([long]$Result.SnapshotRevision) -Force
    if(-not (Test-DomeniaClassicResultCurrent $data $State)){return}
    # A late cache SELECT cannot replace a newer committed inventory already rendered in this view.
    $selectedAt=ConvertTo-DomeniaUtcDate $data.SourceCompletedUtc
    if($script:InventoryComputer -ieq $State.Computer -and $null -ne $script:InventoryCompletedAt -and $script:InventoryCompletedAt -gt $selectedAt){return}
    Complete-DomeniaInventoryUi -Result $data -State $State
}
function Fail-DomeniaCachedInventoryRead {
    param([string]$Message,$State)
    if(Test-DomeniaRemoteStoreContext $State $null){Write-AppLog ('Inventaire local non relu : '+$Message) 'WARN'}
}
