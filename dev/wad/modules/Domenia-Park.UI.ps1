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
        $targets=@();$excluded=@()
        if($null -ne $ScopeTargets){
            $targets=@($ScopeTargets|Where-Object{$null -ne $_ -and $_.distinguished_name -and $_.object_guid})
            if(-not $targets.Count){throw 'Poste selectionne sans DN ni GUID connu : relisez sa fiche.'}
            $DisplayedResults=[switch]$true
        }
        elseif($DisplayedResults){
            $grid=Get-DomeniaControl 'DgObjects'
            # Point 48: every displayed row is a candidate; the preview keeps the exact targets and says why the others stay out.
            $candidates=@(foreach($row in @($grid.Items)){if($null -ne $row){[pscustomobject]@{Name=[string]$row.Name;DN=[string]$row.DN;Guid=[string]$row.Guid;Type=[string]$row.Type}}})
            $preview=New-DomeniaCollectivePreview -OperationId 'ParkSweep' -Candidates $candidates -ExpectedType 'Machine'
            $excluded=@($preview.Excluded)
            $targets=@(foreach($target in @($preview.Targets)){[pscustomobject]@{name=[string]$target.Name;distinguished_name=[string]$target.DN;object_guid=[string]$target.Guid}})
            if(-not $targets.Count){throw 'Aucun poste dans les resultats affiches.'}
        }
        $script:ParkRun=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;Targets=@();Next=0;Pending=@{};Concurrency=([Math]::Max(1,[Math]::Min(8,[int](Get-DomeniaSetting 'Collection.Concurrency' '4'))));CacheMinutes=([Math]::Max(0,[Math]::Min(1440,[int](Get-DomeniaSetting 'Collection.CacheMinutes' '15'))));CachedMeasurements=0;Done=0;Online=0;Reused=0;Changed=0;Failed=0;Stopping=$false;Completed=$false;Loading=$true;Approved=$false;ObservationReader=(New-DomeniaObservationReader);Timer=$null;StatusText='';Generation=[long]$script:GlobalSearchGeneration;PingOnly=[bool]$PingOnly;WmiOnly=[bool]$WmiOnly;AccountGeneration=[long]$script:DomeniaAccountGeneration;StorePending=@{};Inventory=[bool]$Inventory;Probes=@(Add-DomeniaRemoteProbeDefinitionHash $Probes);FleetRefresh=$true;ScopeLabel=[string]$ScopeLabel;Scope=$(if($DisplayedResults){'Results'}else{'Park'})}
        $started=$true
        $script:ParkRun|Add-Member -NotePropertyName RefreshOperationId -NotePropertyValue $RefreshOperationId
        # Point 48: what was asked and what was left out before the local read, for the exact preview.
        $script:ParkRun|Add-Member -NotePropertyName Requested -NotePropertyValue @($targets)
        $script:ParkRun|Add-Member -NotePropertyName PreviewExcluded -NotePropertyValue @($excluded)
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
        if(-not $r.PingOnly){$message+=' '+$(if($r.CacheMinutes -gt 0){'Réutilisation des mesures encore fraîches, au plus '+$r.CacheMinutes+' min (1 min pour les sondes volatiles, 5 min pour l inventaire). Le ping et la console sont relus.'}else{'Relecture forcée de toutes les mesures demandées.'})}
        # Point 48: the exact list, what each target gets, the exclusions and why, the impact, a proportionate confirmation.
        $requested=@{};foreach($asked in @(Get-DomeniaMember $r 'Requested' @())){$requested[([string]$asked.distinguished_name).ToLowerInvariant()]=$asked}
        $returned=@{};foreach($target in @($r.Targets)){$returned[[string]$target.Key]=$true}
        $excluded=@(Get-DomeniaMember $r 'PreviewExcluded' @())
        foreach($key in @($requested.Keys)){if(-not $returned.ContainsKey([string]$key)){$asked=$requested[$key];$excluded+=@([pscustomobject]@{Name=[string]$asked.name;DN=[string]$asked.distinguished_name;Reason='Écarté par la base locale : nom de poste non valide ou DN en double'})}}
        $candidates=@(foreach($target in @($r.Targets)){$dn=[string]$target.Key;if($requested.ContainsKey($dn)){$dn=[string]$requested[$dn].distinguished_name};[pscustomobject]@{Name=[string]$target.Computer;DN=$dn;Guid=[string]$target.Guid;Type='Machine'}})
        $change=if($r.PingOnly){'ping ICMP'}elseif($r.WmiOnly){'lecture WMI'}elseif($r.Inventory){'ping, utilisateur console et relevé WMI léger'}elseif(@($r.Probes).Count){'requêtes WMI des widgets, ping et utilisateur console'}else{'ping puis utilisateur console'}
        $impactText=''
        try{$impactText=[string](Format-DomeniaOperationImpact -Estimate (Get-DomeniaOperationImpactEstimate -Operation 'ParkSweep' -ItemCount @($r.Targets).Count)).Sentence}catch{$impactText=''}
        $preview=New-DomeniaCollectivePreview -OperationId 'ParkSweep' -Candidates $candidates -Excluded $excluded -ExpectedType 'Machine' -Change $change -Impact $impactText
        Request-DomeniaInlineConfirmation -Title $(if($r.Inventory){'Analyser les postes affiches'}elseif(@($r.Probes).Count){'Sonder pour les widgets'}elseif($r.PingOnly){'Pinger les postes affiches'}elseif($r.Scope -eq 'Results'){'Detecter sur les resultats affiches'}else{'Detecter sur tout le parc'}) -Target ([string]$script:Conn.Domain) -Message $message -ConfirmText $(if($r.PingOnly){'Pinger'}elseif($r.Inventory){'Analyser'}else{'Verifier les sessions'}) -CancelText 'Annuler' -OnConfirm ({& $start $runId}.GetNewClosure()) -OnCancel ({& $stop -RunId $runId}.GetNewClosure()) -Changes @($preview.Lines) -Details ([string]$preview.Details) -DetailsTitle 'Liste exacte des cibles et des exclusions' -TypedConfirmation ([string]$preview.TypedText)
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
        if(-not $r.Approved -or ($save.Pending -eq 0 -and $r.StorePending.Count -eq 0) -or $save.Suspended){$r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()}}
    }
    Update-DomeniaParkRunStatus
}
function Invoke-DomeniaParkRunTick {
    $r=$script:ParkRun;if($null -eq $r){return}
    if($r.Epoch -ne [long]$script:SessionEpoch -or $r.Path -cne [string]$script:DatabaseScopedPath -or $r.AccountGeneration -ne [long]$script:DomeniaAccountGeneration -or $script:AsyncEngineClosing){$r.Stopping=$true;$r.Completed=$true;Clear-DomeniaParkTargetBuffers $r.Targets;if($null -ne $r.Timer){$r.Timer.Stop()};return}
    if($null -ne $r.PSObject.Properties['RefreshOperationId'] -and [string]$r.RefreshOperationId -and -not (Test-DomeniaOuRefreshCurrent ([string]$r.RefreshOperationId))){$r.Stopping=$true}
    # Cancelled workers never silently cause the rest of the fleet to start.
    foreach($id in @($r.Pending.Keys)){
        if(-not $script:AsyncJobs.Contains($id) -and -not @($script:DetachedReadJobs|Where-Object{$_.Id -eq $id}).Count){$r.Pending.Remove($id);$r.Stopping=$true;$r.Failed++}
    }
    if(($r.Stopping -or $r.Next -ge $r.Targets.Count) -and -not $r.Pending.Count){
        $save=Get-DomeniaPersistenceState
        if($r.StorePending.Count -gt 0 -or ($save.Pending -gt 0 -and -not $save.Suspended)){Update-DomeniaParkRunStatus;return}
        $r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()};Update-DomeniaParkRunStatus;return
    }
    if($r.Stopping -or -not $r.Approved){return}
    if($null -ne $script:DomeniaRemoteStoreQueue -and $script:DomeniaRemoteStoreQueue.Count -gt 0){return}
    if($r.StorePending.Count -ge 16){return}
    if($script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){return}
    if($null -ne $script:Persistence){
        if($script:Persistence.Failures -ge 3 -or $script:Persistence.Conflicts.Count){$r.Stopping=$true;Update-DomeniaParkRunStatus;return}
        if($script:Persistence.Pending.Count -ge 64 -or $script:Persistence.LinkBusy){return}
    }
    # One admission per tick keeps the Dispatcher responsive. The engine may impose a smaller provider budget.
    if($r.Pending.Count -ge $r.Concurrency -or $r.Next -ge $r.Targets.Count){return}
    $target=$r.Targets[$r.Next]
    try{Expand-DomeniaParkPrevious $target}catch{$r.Stopping=$true;Set-Status ('Cache du poste illisible : '+$target.Computer+'. Relancez le relevé après actualisation.') 'WARN';return}
    $plan=New-DomeniaCollectionPlan -Previous $target.Previous -Guid $target.Guid -Key $target.Key -Probes @($r.Probes) -Inventory ([bool]$r.Inventory) -CacheMinutes ([int]$r.CacheMinutes)
    $state=[pscustomobject]@{RunId=$r.Id;Epoch=$r.Epoch;Path=$r.Path;Target=$target;Job='';Plan=$plan;PingOnly=$r.PingOnly;WmiOnly=$r.WmiOnly;RemoteStartedUtc=[datetime]::UtcNow.ToString('o')}
    [void](Initialize-DomeniaRemoteStoreState -State $state -Guid $target.Guid -DN $target.Key -Generation $r.Generation)
    try{
        $id=Start-UiTask -Name ($(if($r.PingOnly){'Ping de la liste : '}else{$(if($r.WmiOnly){'WMI du perimetre : '}else{'Console du parc : '})})+$target.Computer) -OperationId 'LiveConsole' -Code (Get-DomeniaLiveProbeCode) -Payload ([pscustomobject]@{Computer=$target.Computer;Key=$target.Key;Guid=$target.Guid;Previous=$target.Previous;AllowIdentityCache=([int]$r.CacheMinutes -gt 0);MethodSeconds=4;CollectPing=(-not [bool]$r.WmiOnly);ValidateConsoleIdentity=$false;ProbeUser=(-not [bool]$r.PingOnly);Inventory=([bool]$plan.Inventory -and -not [bool]$r.PingOnly);Probes=$(if([bool]$r.PingOnly){@()}else{@($plan.Probes)});AllowedClasses=@(@(Get-DomeniaProbeCatalog)|ForEach-Object{[string]$_.Class})}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkSession' -ErrorHandler 'Fail-DomeniaParkSession' -TimeoutSeconds $(if(@($r.Probes).Count){[Math]::Min(150,20+8*@($r.Probes).Count)}else{20}) -TaskClass 'Explicit'
        if(-not $id){throw 'Lecture non admise.'}
        $state.Job=[string]$id;$r.Pending[[string]$id]=$state;$r.Next++
    }catch{$r.Stopping=$true;[void](Set-DomeniaControlText 'LblParkStatus' ('Releve interrompu : '+$_.Exception.Message+' Les resultats precedents sont conserves.'))}
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
        if($current -and ($packet.Outcome -eq 'AuthRejected' -or $packet.DirectoryAuthRejected)){$script:ParkRun.Stopping=$true}
        [void](Submit-DomeniaRemoteObservations -Result $packet -State $State -SuccessHandler 'Complete-DomeniaParkStored' -ErrorHandler 'Fail-DomeniaParkStored')
    }catch{Fail-DomeniaParkStored -Message $_.Exception.Message -State $State}
}

function Complete-DomeniaParkStored {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=$script:ParkRun;[void]$r.StorePending.Remove([string]$State.Job)
    if(-not (Test-DomeniaRemoteStoreContext $State $Result)){$r.Stopping=$true;return}
    $observation=Get-DomeniaCommittedObservation $Result $State
    if($null -eq $observation){return}
    $r.Done++;if([string]$observation.Presence -eq 'En ligne'){$r.Online++}
    if(-not $r.PingOnly){$r.CachedMeasurements += [int]$State.Plan.Reused}
    if(@($Result.Observations|Where-Object{[string]$_.Guid -ieq [string]$State.StoreGuid -and [string]$_.Status -eq 'Error'}).Count){$r.Failed++}
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
    Set-Status ('Mesure non publiee : enregistrement SQLite non confirme. '+$Message) 'ERROR'
    Update-DomeniaParkRunStatus
}

function Fail-DomeniaParkSession {
    param($Message,$State)
    $packet=[pscustomobject]@{Outcome='Unavailable';Key=$State.Target.Key;Guid=$State.Target.Guid;Computer=$State.Target.Computer;Detail=[string]$Message;Presence='Erreur de ping';PresenceDetail=[string]$Message;PresenceCheckedUtc=$(if(-not $State.WmiOnly){$State.RemoteStartedUtc}else{''});ConsoleAttempted=(-not $State.PingOnly);ConsoleCheckedUtc=$(if(-not $State.PingOnly){$State.RemoteStartedUtc}else{''});InventoryAttempted=[bool]$State.Plan.Inventory;InventoryCheckedUtc=$State.RemoteStartedUtc;InventoryError=[string]$Message;CacheReused=$false;DirectoryAuthRejected=$false}
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
