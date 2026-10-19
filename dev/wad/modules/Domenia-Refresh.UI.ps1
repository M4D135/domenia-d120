# Explicit OU refresh orchestration. AD completion is not a storage receipt.
function Get-DomeniaOuRefreshContext {
    param([ValidateSet('Fleet','Search','Index')][string]$Source)
    $domain=([string]$script:Conn.BaseDn).Trim();$dn=''
    # A section with no OU of its own uses the saved root OU. An explicit domain stays empty here.
    if(Get-Command Get-DomeniaSectionOuDn -ErrorAction SilentlyContinue){$dn=[string](Get-DomeniaSectionOuDn -Source $Source)}
    else{switch($Source){'Fleet'{$dn=([string]$script:FleetScopeDn).Trim()};'Search'{$dn=([string]$script:SelectedBranchDn).Trim()};'Index'{$dn=([string]$script:IndexScopeDn).Trim()}}}
    if(-not $domain -or -not [string]$script:DatabaseScopedPath -or $dn -notmatch '^OU=' -or $dn -ieq $domain){return $null}
    $parent=$dn;$inside=$false
    while($parent){if($parent -ieq $domain){$inside=$true;break};$parent=Get-DomeniaRawDnParent $parent}
    if(-not $inside){return $null}
    [pscustomobject]@{Source=$Source;Dn=$dn;Subtree=$true;Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;DomainDn=$domain;Label=($dn+' et ses sous-OU')}
}
function Test-DomeniaOuRefreshCurrent {
    param([string]$OperationId)
    $r=$script:DomeniaOuRefresh
    if($null -eq $r -or $r.Id -cne $OperationId -or $r.Completed -or $r.Cancelled -or $script:AsyncEngineClosing){return $false}
    $context=Get-DomeniaOuRefreshContext -Source $r.Source
    return ($null -ne $context -and $context.Epoch -eq $r.Epoch -and $context.Path -ceq $r.Path -and $context.Dn -ieq $r.Dn -and $context.DomainDn -ieq $r.DomainDn)
}
function Update-DomeniaOuRefreshUi {
    $r=$script:DomeniaOuRefresh;$busy=($null -ne $r -and -not $r.Completed)
    foreach($source in @('Search','Fleet','Index')){
        $context=Get-DomeniaOuRefreshContext -Source $source
        $scopeText=if($null -eq $context){'Choisissez une OU. Les actualisations couvrent cette OU et ses sous-OU.'}else{'Actualisation : '+$context.Label+'. Les filtres de recherche restent inchangés.'}
        if($source -eq 'Search'){[void](Set-DomeniaControlText 'LblSearchOuRefreshScope' $scopeText)}
        $status=if($null -ne $r -and $r.Source -eq $source){$(if($null -eq $context -or $context.Dn -ine $r.Dn){'Précédente OU : '+$r.Label+' — '}else{''})+[string]$r.Status}else{$scopeText}
        $label=switch($source){'Search'{'LblSearchOuRefreshStatus'};'Fleet'{'LblFleetOuRefreshStatus'};'Index'{'LblIndexOuRefreshStatus'}}
        [void](Set-DomeniaControlText $label $status)
        $names=switch($source){'Search'{@('BtnSearchRefreshBase','BtnSearchRefreshPostes','BtnSearchRefreshBoth')};'Fleet'{@('BtnFleetRefreshAll','BtnFleetIndexScope','BtnFleetRefreshPostes','BtnFleetRefreshBoth')};'Index'{@('BtnIndexScopeUpdate')}}
        foreach($name in $names){$control=Get-DomeniaControl $name;if($null -ne $control){$control.IsEnabled=(($source -eq 'Index' -or $null -ne $context) -and -not $busy -and -not $script:DemoMode)}}
        $stop=Get-DomeniaControl ('Btn'+$source+'RefreshStop')
        if($null -ne $stop){$stop.IsEnabled=($busy -and $r.Source -eq $source)}
    }
}
function Stop-DomeniaOuRefresh {
    param([ValidateSet('','Fleet','Search','Index')][string]$Source='',[string]$OperationId='',[string]$Message='Actualisation arrêtée. Les écritures locales déjà engagées se terminent ; aucune nouvelle collecte ne sera lancée.')
    $r=$script:DomeniaOuRefresh
    if($null -eq $r -or $r.Completed -or ($Source -and $r.Source -ne $Source) -or ($OperationId -and $r.Id -cne $OperationId)){return}
    $r.Cancelled=$true;$r.Completed=$true;$r.Phase='Cancelled';$r.Status=$Message
    if($null -ne $r.Timer){$r.Timer.Stop()}
    foreach($id in @($r.DirectoryJob,$r.TargetJob)){if($id){try{Stop-UiTask -Id $id -Silent}catch{Write-DomeniaSwallowed 'Refresh' 'Stop-DomeniaOuRefresh' $_}}}
    if($r.ParkRunId){Stop-DomeniaOnlinePark -RunId $r.ParkRunId}
    if(($null -ne $r.PSObject.Properties['Outcome']) -and (-not [string]$r.Outcome)){$r.Outcome='Cancelled'}
    Submit-DomeniaOuRefreshRuns -Refresh $r
    Update-DomeniaOuRefreshUi
}
function Fail-DomeniaOuRefresh {
    param([string]$OperationId,[string]$Message)
    $r=$script:DomeniaOuRefresh
    if(-not $OperationId -or $null -eq $r -or $r.Id -cne $OperationId -or $r.Completed){return}
    # « Tout actualiser » of Accueil (decision David 2026-10-19): a failed or partial AD read does not stop ping and WMI. They
    # start on the workstations already known by the local base; the AD record keeps its failure and the status says so.
    if(($r.Mode -eq 'Both') -and ($r.Source -eq 'Fleet') -and (-not [bool]$r.BaseCommitted) -and ($r.Phase -in @('Directory','Saving')) -and (-not [string](Get-DomeniaMember $r 'DirectoryFallback' ''))){
        if([string]$r.Directory.Status -ne 'Partial'){$r.Directory.Status='Error'}
        if(-not [string]$r.Directory.Error){$r.Directory.Error=[string]$Message}
        if($r.DirectoryJob){try{Stop-UiTask -Id $r.DirectoryJob -Silent}catch{Write-DomeniaSwallowed 'Refresh' 'Fail-DomeniaOuRefresh' $_}}
        $r|Add-Member -NotePropertyName DirectoryFallback -NotePropertyValue ([string]$Message) -Force
        $r.Phase='WaitingCollection';$r.Status='Lecture AD non aboutie ('+[string]$Message+') : ping et WMI partent sur les postes déjà connus de la base locale.'
        Update-DomeniaOuRefreshUi
        return
    }
    # The run records keep the failure and its cause; Stop records them once.
    if($null -ne $r.PSObject.Properties['Outcome']){$r.Outcome='Error';$r.OutcomeMessage=[string]$Message}
    Stop-DomeniaOuRefresh -OperationId $OperationId -Message ('Actualisation interrompue : '+$Message+' Aucune nouvelle collecte ne sera lancée.')
    $r.Phase='Error';Update-DomeniaOuRefreshUi
}
function Set-DomeniaOuRefreshAwaitingCommit {
    param([string]$OperationId)
    if(-not (Test-DomeniaOuRefreshCurrent $OperationId)){return}
    $r=$script:DomeniaOuRefresh;$r.Phase='Saving';$r.Status='OU lue. Validation de lʼenregistrement local en cours ; aucun poste interrogé.'
    Update-DomeniaOuRefreshUi
}
function Complete-DomeniaOuRefreshCommit {
    param($Item)
    if($null -eq $Item -or $Item.Kind -ne 'IndexBulk' -or $null -eq $Item.Row -or $null -eq $Item.Row.PSObject.Properties['RefreshOperationId']){return}
    $id=[string]$Item.Row.RefreshOperationId
    if(-not (Test-DomeniaOuRefreshCurrent $id)){return}
    $r=$script:DomeniaOuRefresh
    if($r.Phase -notin @('Directory','Saving') -or [long]$Item.Epoch -ne $r.Epoch -or [string]$Item.Path -cne $r.Path -or [string]$Item.Row.BaseDn -ine $r.Dn -or [string]$Item.Row.SyncScope -ine ('ou:'+$r.Dn.ToLowerInvariant())){return}
    $r.Directory.FinishedUtc=[datetime]::UtcNow.ToString('o');$r.Directory.Controller=[string](Get-DomeniaMemberValue $Item.Row 'Server')
    $r.Directory.Count=[long]$(if($null -ne $Item.Row.PSObject.Properties['RowCount']){$Item.Row.RowCount}elseif($null -ne $Item.Row.PSObject.Properties['Rows']){@($Item.Row.Rows).Count}else{-1})
    if(($null -eq $Item.Row.PSObject.Properties['Complete']) -or (-not [bool]$Item.Row.Complete)){$r.Directory.Status='Partial';$r.Directory.Error='Lecture AD partielle : le dernier repère complet est conservé.';Fail-DomeniaOuRefresh -OperationId $id -Message 'Lecture AD partielle : le dernier repère complet est conservé.';return}
    $r.BaseCommitted=$true;$r.Directory.Status='Success'
    if($r.Mode -in @('AD','Base')){$r.Completed=$true;$r.Phase='Complete';$r.Status='Objets AD relus et enregistrés : '+$r.Label+'. Aucun ping ni relevé WMI.';if($null -ne $r.Timer){$r.Timer.Stop()};Submit-DomeniaOuRefreshRuns -Refresh $r}
    else{$r.Phase='WaitingCollection';$r.Status='Base locale enregistrée. Préparation du relevé des postes de '+$r.Label+'.'}
    Update-DomeniaOuRefreshUi
}
function Get-DomeniaOuRefreshProbePlan {
    # The workshop is lazy: read its validated saved library locally when no view has been opened.
    # Do not initialize that view, change its scope, or silently omit a configured query widget.
    # Paused widgets are left out of the WMI refresh of the OU (decision David 2026-10-14).
    $ids=@(Get-DomeniaBoardProbeIds)
    $widgets=@(foreach($board in @('Fleet','Computer')){Select-DomeniaActiveBoardItems -Layout @(Get-DomeniaBoardLayout -Board $board)|Where-Object{[string]$_.Source -eq 'Query'}})
    if($widgets.Count){
        if($null -eq $script:DomeniaQueryState){$saved=@(ConvertFrom-DomeniaQueryLibrary ([string](Get-DomeniaSetting 'Query.Library' '')))}
        else{
            if([string]$script:DomeniaQueryState.LibraryError){throw 'Bibliothèque des widgets illisible : rétablissez les requêtes enregistrées dans lʼAtelier.'}
            $saved=@($script:DomeniaQueryState.Saved)
        }
        foreach($widget in $widgets){
            $recipes=@($saved|Where-Object{[string]$_.Id -ceq [string]$widget.Key})
            if($recipes.Count -ne 1){throw 'Une requête de widget est absente ou ambiguë. Vérifiez les widgets et la bibliothèque avant de collecter.'}
            $ids+=@(Get-DomeniaQueryProbeIds $recipes[0])
        }
    }
    $ids=@($ids|Where-Object{[string]$_}|Sort-Object -Unique)
    if($ids.Count){ConvertTo-DomeniaProbePayload -Ids $ids}
}
function Invoke-DomeniaOuRefresh {
    # Legacy modes are retained for compatibility; the UI exposes AD, Ping, Wmi and Both (« Tout actualiser » on Accueil).
    # -BackupDone: continuation of the verified backup taken before an AD read (FI-13). Every check runs again, and the
    # OU, base and session confirmed by the click (-ExpectedDn, -ExpectedPath, -ExpectedEpoch) must still be the current
    # ones: an OU chosen during the backup is never read without its own click. -ExpectedProbes is the probe plan
    # snapshot taken at the click.
    param([ValidateSet('Fleet','Search','Index')][string]$Source,[ValidateSet('AD','Ping','Wmi','Base','Postes','Both')][string]$Mode,[switch]$BackupDone,[string]$ExpectedDn='',[string]$ExpectedPath='',[long]$ExpectedEpoch=-1,[object[]]$ExpectedProbes=@(),[string]$WidgetId='',$WidgetNeed=$null)
    $created=$false
    try{
        $context=Get-DomeniaOuRefreshContext $Source
        if($null -eq $context){throw 'Choisissez une OU explicite dans cette page.'}
        if($BackupDone -and ((-not $ExpectedDn) -or ($context.Dn -ine $ExpectedDn) -or ($context.Path -cne $ExpectedPath) -or ([long]$context.Epoch -ne $ExpectedEpoch))){throw 'lʼOU, la base ou la session a changé pendant la sauvegarde ; aucune lecture AD. Cliquez à nouveau pour lʼOU affichée.'}
        if($script:DemoMode){throw 'Actualisation distante indisponible en démonstration.'}
        if($null -ne $script:DomeniaOuRefresh -and -not $script:DomeniaOuRefresh.Completed){throw 'Une actualisation est déjà en cours.'}
        # FI-18: an OU refresh runs its survey in the scope of the lists; the survey of the open workstation is apart.
        if(Test-DomeniaParkRunActive -Slot 'List'){throw 'Un relevé de postes est déjà en cours.'}
        if(@($script:AsyncJobs.Values|Where-Object{$_.OperationId -in @('IndexBuild','StoragePurge','LegacyMigration')}).Count){throw 'Attendez la fin de la lecture AD ou de la maintenance locale.'}
        $save=Get-DomeniaPersistenceState
        if($save.Pending -gt 0 -or $save.Suspended -or $save.Conflicts -gt 0){throw 'Attendez ou rétablissez la confirmation des écritures locales.'}
        # Points 32 and 35: no new collection during a base maintenance or on a nearly full disk.
        $storageRefusal=Get-DomeniaStorageCollectionRefusal;if($storageRefusal){throw $storageRefusal}
        # Snapshot the selected dashboard probe plan now, before AD work or a later confirmation can change it. After the
        # backup, the snapshot taken at the click is kept.
        $probes=@()
        if($BackupDone){$probes=@($ExpectedProbes|Where-Object{$null -ne $_})}
        elseif($null -ne $WidgetNeed){if(@($WidgetNeed.ProbeIds).Count){$probes=@(ConvertTo-DomeniaProbePayload -Ids @($WidgetNeed.ProbeIds))}}
        elseif($Mode -in @('Wmi','Postes','Both')){$probes=@(Get-DomeniaOuRefreshProbePlan)}
        # FI-13: an AD read rewrites this OU in the local base (reconciliation included). Once every check above has
        # passed, a verified backup (StorageBackup worker) comes first, from the Index, Fleet and Search pages alike; the
        # refresh starts again from its receipt and checks everything again. Ping and WMI collections only add
        # observations and need no copy.
        if(($Mode -in @('AD','Base','Both')) -and (-not $BackupDone)){
            $refresh=${function:Invoke-DomeniaOuRefresh};$dn=[string]$context.Dn;$base=[string]$context.Path;$epoch=[long]$context.Epoch
            [void](Invoke-DomeniaGestureBackup -Gesture 'IndexUpdate' -Then ({& $refresh -Source $Source -Mode $Mode -BackupDone -ExpectedDn $dn -ExpectedPath $base -ExpectedEpoch $epoch -ExpectedProbes $probes -WidgetId $WidgetId -WidgetNeed $WidgetNeed}.GetNewClosure()))
            return
        }
        $r=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Source=$Source;Mode=$Mode;Dn=$context.Dn;Subtree=$true;DomainDn=$context.DomainDn;Label=$context.Label;Epoch=$context.Epoch;Path=$context.Path;Phase='Directory';Status='Lecture AD : '+$context.Label;DirectoryJob='';TargetJob='';ParkRunId='';BaseCommitted=$false;Cancelled=$false;Completed=$false;Timer=$null;Started=[datetime]::UtcNow}
        $r|Add-Member -NotePropertyName WidgetId -NotePropertyValue $WidgetId
        $r|Add-Member -NotePropertyName WidgetNeed -NotePropertyValue $WidgetNeed
        $r|Add-Member -NotePropertyName Probes -NotePropertyValue $probes
        # Points 4, 5 and 10: what the run records once finished (Submit-DomeniaOuRefreshRuns).
        $r|Add-Member -NotePropertyName Directory -NotePropertyValue ([pscustomobject]@{Started=$false;Status='';Error='';StartedUtc='';FinishedUtc='';Controller='';Count=-1L})
        $r|Add-Member -NotePropertyName Outcome -NotePropertyValue ''
        $r|Add-Member -NotePropertyName OutcomeMessage -NotePropertyValue ''
        $r|Add-Member -NotePropertyName RunsRecorded -NotePropertyValue $false
        $script:DomeniaOuRefresh=$r;$created=$true
        $r.Timer=New-DomeniaTimer -Owner 'Timer:OuRefresh' -IntervalMs 250 -RunWhenHidden -Tick {Invoke-DomeniaOuRefreshTick}
        if($Mode -in @('Ping','Wmi','Postes')){$r.Phase='WaitingCollection';$r.Status='Préparation des postes activés dans AD de '+$r.Label+'. '+$(if($Mode -eq 'Ping'){'Le ping seul sera relu.'}elseif($Mode -eq 'Wmi'){'Les informations WMI seront relues.'}else{'Ping et WMI seront relus après confirmation.'})}
        else{
            $directoryStarted=[datetime]::UtcNow.ToString('o')
            $r.DirectoryJob=[string](Start-DomeniaIndexScopeBuild -Dn $r.Dn -RefreshOperationId $r.Id)
            if(-not $r.DirectoryJob){throw 'Lecture AD non admise.'}
            $r.Directory.Started=$true;$r.Directory.StartedUtc=$directoryStarted
        }
        $r.Timer.Start();Update-DomeniaOuRefreshUi
        if($WidgetId){Register-DomeniaWidgetCollect -Board Fleet -Ids @($WidgetId) -Kind Directory -RunId $r.Id;Show-DomeniaBoard -Board Fleet -Quiet}
    }catch{
        if($created){Fail-DomeniaOuRefresh -OperationId $script:DomeniaOuRefresh.Id -Message $_.Exception.Message}
        if($created -and (-not [bool]$script:DomeniaOuRefresh.Completed)){Set-Status ('Lecture AD non lancée : '+$_.Exception.Message+' Ping et WMI suivent sur les postes déjà connus.') 'WARN'}
        else{Set-Status ('Actualisation non lancée : '+$_.Exception.Message) 'WARN'}
    }
}
function Invoke-DomeniaOuRefreshTick {
    $r=$script:DomeniaOuRefresh
    if($null -eq $r -or $r.Completed){return}
    if(-not (Test-DomeniaOuRefreshCurrent $r.Id)){Stop-DomeniaOuRefresh -OperationId $r.Id -Message 'Contexte ou OU modifié : actualisation arrêtée, aucune collecte supplémentaire.';return}
    if($r.Phase -eq 'Directory' -and $r.DirectoryJob -and -not $script:AsyncJobs.Contains($r.DirectoryJob)){
        Fail-DomeniaOuRefresh -OperationId $r.Id -Message 'Lecture AD interrompue ou sans reçu exploitable.';return
    }
    if($r.Phase -eq 'Resolving' -and $r.TargetJob -and -not $script:AsyncJobs.Contains($r.TargetJob)){
        Fail-DomeniaOuRefresh -OperationId $r.Id -Message 'Préparation locale interrompue.';return
    }
    if($r.Phase -eq 'WaitingCollection'){
        $save=Get-DomeniaPersistenceState
        if($save.Suspended -or $save.Conflicts -gt 0){Fail-DomeniaOuRefresh -OperationId $r.Id -Message 'Stockage local non confirmé.';return}
        if($save.Pending -gt 0){return}
        if($r.Mode -eq 'Both' -and -not $r.BaseCommitted -and -not [string](Get-DomeniaMember $r 'DirectoryFallback' '')){Fail-DomeniaOuRefresh -OperationId $r.Id -Message 'Le reçu de mise à jour de la base est absent.';return}
        try{
            $plan=Get-DomeniaFleetQueryPlan -Now ([datetime]::Now) -ObservationMaxAgeDays (Get-DomeniaObservationMaxAgeDays)
            $payload=[pscustomobject]@{Action='FleetStats';Path=$r.Path;Scope=$r.Dn;Subtree=$true;Plan=$plan;Keys=@();ScopeKey='';ComputeBoard=$false;ModuleRoot=$script:DashboardModuleRoot}
            $state=[pscustomobject]@{OperationId=$r.Id;Epoch=$r.Epoch;Path=$r.Path;Dn=$r.Dn}
            $r.Phase='Resolving';$r.Status='Lecture des postes actifs depuis la base locale : '+$r.Label+'.'
            $r.TargetJob=[string](Start-UiTask -Name 'Préparer lʼactualisation des postes de lʼOU' -OperationId LocalIndexRead -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaOuRefreshTargets' -ErrorHandler 'Fail-DomeniaOuRefreshTargets' -TimeoutSeconds 120 -TaskClass Explicit)
            if(-not $r.TargetJob){throw 'Lecture locale non admise.'}
        }catch{Fail-DomeniaOuRefresh -OperationId $r.Id -Message $_.Exception.Message}
    }
    if($r.ParkRunId){Update-DomeniaOuRefreshFromPark -Run (Get-DomeniaParkRunById ([string]$r.ParkRunId))}
    Update-DomeniaOuRefreshUi
}
function Complete-DomeniaOuRefreshTargets {
    param($Result,$State)
    if($null -eq $State -or -not (Test-DomeniaOuRefreshCurrent ([string]$State.OperationId))){return}
    $r=$script:DomeniaOuRefresh
    if($r.Phase -ne 'Resolving' -or [long]$State.Epoch -ne $r.Epoch -or [string]$State.Path -cne $r.Path -or [string]$State.Dn -ine $r.Dn){return}
    try{
        $packet=Get-DomeniaEffectiveWorkerResult $Result @('Targets','Busy')
        if($null -eq $packet -or $packet.Busy -or $packet.Missing -or [string]$packet.Scope -ine $r.Dn -or -not [bool]$packet.Subtree){throw 'Périmètre local absent, occupé ou incohérent ; aucun poste interrogé.'}
        $targets=@($packet.Targets|Where-Object{$null -ne $_})
        if(-not $targets.Count){$r.Completed=$true;$r.Phase='Complete';$r.Status='Aucun poste actif recensé dans '+$r.Label+'. Aucun ping ni WMI lancé.';$r.Timer.Stop();Submit-DomeniaOuRefreshRuns -Refresh $r;Update-DomeniaOuRefreshUi;return}
        $r.Phase='Confirming';$r.Status=[string]$targets.Count+' poste(s) activé(s) dans AD, '+$r.Label+'. Confirmation de la collecte en attente.'
        $args=@{ScopeTargets=$targets;ScopeLabel=$r.Label;ForceRefresh=$true;RefreshOperationId=$r.Id;PassThru=$true}
        $need=Get-DomeniaMemberValue $r 'WidgetNeed'
        if($null -ne $need){
            $args.WidgetBoard='Fleet';$args.WidgetIds=@([string]$r.WidgetId)
            $wmi=([bool]$need.Console -or [bool]$need.Inventory -or @($r.Probes).Count -gt 0)
            if([bool]$need.Ping -and -not $wmi){$args.PingOnly=$true}
            else{
                if(-not [bool]$need.Ping){$args.WmiOnly=$true}
                if(-not [bool]$need.Console){$args.NoConsole=$true}
                if([bool]$need.Inventory){$args.Inventory=$true}
                if(@($r.Probes).Count){$args.Probes=@($r.Probes)}
            }
        }
        elseif($r.Mode -eq 'Ping'){$args.PingOnly=$true}
        elseif($r.Mode -eq 'Postes'){$args.Inventory=$true;$args.Probes=@($r.Probes)}
        else{
            # Decision David 2026-10-19: one ping of every workstation first, then WMI on those that answered only (no
            # second echo, no second confirmation, no wait on switched-off workstations).
            $args.PingOnly=$true
            $args.ChainNote='Ensuite, lecture WMI (utilisateur console, inventaire, requêtes des widgets) des seuls postes qui répondent au ping, sans nouvel écho ni nouvelle confirmation.'
            $r|Add-Member -NotePropertyName ChainWmi -NotePropertyValue ([pscustomobject]@{Targets=@($targets);Probes=@($r.Probes)}) -Force
        }
        $r.ParkRunId=[string](Start-DomeniaOnlinePark @args)
        if(-not $r.ParkRunId){throw 'Préparation du relevé non admise.'}
        # Chained refresh: the ping step is kept for its own clock, even when the refresh stops before the WMI step.
        if($null -ne (Get-DomeniaMemberValue $r 'ChainWmi')){$r|Add-Member -NotePropertyName PingRun -NotePropertyValue (Get-DomeniaParkRunById ([string]$r.ParkRunId)) -Force}
        Update-DomeniaOuRefreshUi
    }catch{Fail-DomeniaOuRefresh -OperationId $r.Id -Message $_.Exception.Message}
}
function Fail-DomeniaOuRefreshTargets {
    param($Message,$State)
    if($null -ne $State){Fail-DomeniaOuRefresh -OperationId ([string]$State.OperationId) -Message ([string]$Message)}
}
function Update-DomeniaOuRefreshFromPark {
    param($Run)
    $r=$script:DomeniaOuRefresh
    if($null -eq $r -or $r.Completed -or $null -eq $Run -or $null -eq $Run.PSObject.Properties['RefreshOperationId'] -or [string]$Run.RefreshOperationId -cne $r.Id -or [string]$Run.Id -cne $r.ParkRunId){return}
    if(-not (Test-DomeniaOuRefreshCurrent $r.Id)){Stop-DomeniaOuRefresh -OperationId $r.Id -Message 'Contexte ou OU modifié : relevé arrêté.';return}
    if($Run.Completed){
        # Ping step of a chained refresh: WMI follows on the workstations that answered, with the same confirmation.
        $chain=Get-DomeniaMemberValue $r 'ChainWmi'
        if(($null -ne $chain) -and (-not [bool](Get-DomeniaMember $r 'ChainStarted' $false))){
            $r|Add-Member -NotePropertyName ChainStarted -NotePropertyValue $true -Force
            $r|Add-Member -NotePropertyName PingRun -NotePropertyValue $Run -Force
            $save=Get-DomeniaPersistenceState
            $pingOk=([bool]$Run.Approved -and (-not [bool]$Run.Stopping) -and (-not [string]$Run.FailureMessage) -and (-not ($save.Suspended -or $save.Conflicts -gt 0)))
            if($pingOk){
                $online=Get-DomeniaMemberValue $Run 'PingOnline' $null
                $answered=@(@($chain.Targets)|Where-Object{($online -is [Collections.IDictionary]) -and $online.ContainsKey(([string]$_.distinguished_name).ToLowerInvariant())})
                if($answered.Count){
                    $args=@{ScopeTargets=$answered;ScopeLabel=$r.Label;ForceRefresh=$true;RefreshOperationId=$r.Id;PassThru=$true;WmiOnly=$true;Inventory=$true;ChainApproved=$true}
                    if(@($chain.Probes).Count){$args.Probes=@($chain.Probes)}
                    $wmiId=''
                    try{$wmiId=[string](Start-DomeniaOnlinePark @args)}catch{$wmiId=''}
                    if($wmiId){
                        $r.ParkRunId=$wmiId;$r.Phase='Collecting'
                        $r.Status='Ping terminé : '+[string]$answered.Count+' poste(s) en ligne sur '+[string]$Run.Done+'. Lecture WMI de ces postes…'
                        Update-DomeniaOuRefreshUi
                        return
                    }
                    $r|Add-Member -NotePropertyName ChainError -NotePropertyValue 'lecture WMI non admise par le moteur' -Force
                }else{$r|Add-Member -NotePropertyName ChainError -NotePropertyValue 'aucun poste en ligne : aucune lecture WMI' -Force}
            }
        }
        $r.Completed=$true;$r.Timer.Stop()
        $save=Get-DomeniaPersistenceState
        if($save.Pending -gt 0 -or $save.Suspended -or $save.Conflicts -gt 0){$r.Phase='Error';$r.Status='Relevé terminé, mais enregistrement local non confirmé. Vérifiez Stockage ; aucune réussite complète annoncée.'}
        elseif($Run.FailureMessage){$r.Phase='Error';$r.Status='Relevé non terminé : '+[string]$Run.FailureMessage}
        elseif(-not $Run.Approved -or $Run.Stopping){$r.Phase='Cancelled';$r.Cancelled=$true;$r.Status='Relevé arrêté : '+[string]$Run.Done+' poste(s) traité(s). Les données déjà confirmées sont conservées.'}
        elseif([string](Get-DomeniaMember $r 'ChainError' '')){$r.Phase='Partial';$r.Status='Ping terminé ('+[string](Get-DomeniaMember (Get-DomeniaMemberValue $r 'PingRun') 'Done' 0)+' poste(s)) ; '+[string]$r.ChainError+'.'}
        elseif($Run.Failed -gt 0){$r.Phase='Partial';$r.Status='Relevé terminé avec '+[string]$Run.Failed+' lecture(s) non confirmée(s) sur '+[string]$Run.Done+'. Consultez les détails des postes.'}
        else{$r.Phase='Complete';$r.Status='Actualisation terminée : '+[string]$Run.Done+' poste(s) de '+$r.Label+'. '+$(if($r.Mode -eq 'Ping'){'Ping relu, données enregistrées. Les dates AD et WMI sont conservées.'}elseif(($r.Mode -eq 'Wmi') -and ($null -ne (Get-DomeniaMemberValue $r 'PingRun'))){'Ping de tous les postes puis WMI des postes en ligne, données enregistrées. La date AD est conservée.'}elseif($r.Mode -eq 'Wmi'){'WMI relu, données enregistrées. Les dates AD et ping sont conservées.'}elseif($r.Mode -eq 'Both'){$(if([string](Get-DomeniaMember $r 'DirectoryFallback' '')){'Ping et WMI relus sur les postes déjà connus ; lecture AD non aboutie : '+[string]$r.DirectoryFallback}else{'Objets AD, ping et WMI relus, données enregistrées.'})}else{'Ping et WMI relus, données enregistrées.'})}
        Submit-DomeniaOuRefreshRuns -Refresh $r
    }elseif($Run.Approved){$r.Phase='Collecting';$r.Status=[string]$Run.StatusText}
    Update-DomeniaOuRefreshUi
}
function Submit-DomeniaOuRefreshRuns {
    # Records the three collection clocks of a finished refresh once (points 4, 5 and 10), in the database and session
    # captured by the refresh: another session or database never receives them. A refused admission is reported and
    # never retried behind the operator; the measures already saved keep their own dates in every case.
    param($Refresh)
    $r=$Refresh
    if(($null -eq $r) -or ($null -eq $r.PSObject.Properties['RunsRecorded']) -or ([bool]$r.RunsRecorded)){return}
    $r.RunsRecorded=$true
    if(([long]$script:SessionEpoch -ne [long]$r.Epoch) -or ([string]$script:DatabaseScopedPath -cne [string]$r.Path) -or (([string]$script:Conn.BaseDn).Trim() -ine [string]$r.DomainDn)){return}
    try{
        $collection=$null
        # FI-18: the survey of this refresh is found by its id in its scope (List), never as the only survey.
        $run=$null;if([string]$r.ParkRunId){$run=Get-DomeniaParkRunById ([string]$r.ParkRunId)}
        $pingRun=Get-DomeniaMemberValue $r 'PingRun'
        $pingCollection=$null
        if($null -ne $pingRun){
            # The ping step of a chained refresh; when no WMI step followed, the run of this refresh is that ping itself.
            if([object]::ReferenceEquals($pingRun,$run)){$run=$null}
            $save=Get-DomeniaPersistenceState
            $pingCollection=[pscustomobject]@{Approved=[bool]$pingRun.Approved;StartedUtc=[string](Get-DomeniaMemberValue $pingRun 'ApprovedUtc');FinishedUtc=[datetime]::UtcNow.ToString('o');Targets=[long](@($pingRun.Targets).Count);Done=[long]$pingRun.Done;Failed=[long]$pingRun.Failed;Stopping=[bool]$pingRun.Stopping;FailureMessage=[string](Get-DomeniaMemberValue $pingRun 'FailureMessage');StorageConfirmed=(-not (($save.Pending -gt 0) -or [bool]$save.Suspended -or ($save.Conflicts -gt 0)))}
        }
        if($null -ne $run){
            $save=Get-DomeniaPersistenceState
            $collection=[pscustomobject]@{Approved=[bool]$run.Approved;StartedUtc=[string](Get-DomeniaMemberValue $run 'ApprovedUtc');FinishedUtc=[datetime]::UtcNow.ToString('o');Targets=[long](@($run.Targets).Count);Done=[long]$run.Done;Failed=[long]$run.Failed;Stopping=[bool]$run.Stopping;FailureMessage=[string](Get-DomeniaMemberValue $run 'FailureMessage');StorageConfirmed=(-not (($save.Pending -gt 0) -or ([bool]$save.Suspended) -or ($save.Conflicts -gt 0)))}
        }
        if($null -ne $pingCollection){
            # Chained refresh: presence dated by the ping of every workstation, inventory by the WMI of those that answered.
            $common=@{DomainDn=([string]$r.DomainDn);ScopeDn=([string]$r.Dn);Outcome=([string]$r.Outcome);OutcomeMessage=([string]$r.OutcomeMessage);CollectorVersion=([string]$script:MasterBuild);NowUtc=([datetime]::UtcNow)}
            $changes=@()
            if([string]$r.Mode -eq 'Both'){$changes+=@(New-DomeniaRefreshRunChanges -Mode AD -Directory $r.Directory @common)}
            $changes+=@(New-DomeniaRefreshRunChanges -Mode Ping -Collection $pingCollection @common)
            if($null -ne $collection){$changes+=@(New-DomeniaRefreshRunChanges -Mode Wmi -Collection $collection @common)}
        }else{
        $changes=@(New-DomeniaRefreshRunChanges -Mode ([string]$r.Mode) -DomainDn ([string]$r.DomainDn) -ScopeDn ([string]$r.Dn) -Directory $r.Directory -Collection $collection -Outcome ([string]$r.Outcome) -OutcomeMessage ([string]$r.OutcomeMessage) -CollectorVersion ([string]$script:MasterBuild) -NowUtc ([datetime]::UtcNow))
        }
        if($changes.Count -eq 0){return}
        $batchId=[guid]::NewGuid().ToString('D')
        $context=New-DomeniaStoreContext -RequestId ('ou-refresh-'+[string]$r.Id) -ScopeDn ([string]$r.Dn) -Subtree $true
        $state=[pscustomobject]@{OperationId=[string]$r.Id;Epoch=[long]$r.Epoch;Path=[string]$r.Path;BatchId=$batchId;Families=@($changes|ForEach-Object{[string]$_.Family})}
        $admission=Submit-DomeniaStoreBatch -Context $context -BatchId $batchId -Sequence 0 -Changes $changes -SuccessHandler 'Complete-DomeniaOuRefreshRunsStored' -ErrorHandler 'Fail-DomeniaOuRefreshRunsStored' -CallbackState $state
        if(-not [bool]$admission.Accepted){Set-Status ('Dates du relevé de lʼOU non enregistrées : file locale indisponible ('+[string]$admission.Reason+'). Les mesures déjà enregistrées gardent leurs propres dates.') 'WARN'}
    }catch{Set-Status ('Dates du relevé de lʼOU non enregistrées : '+$_.Exception.Message) 'WARN'}
}
function Complete-DomeniaOuRefreshRunsStored {
    param($Result,$State)
    if(($null -eq $State) -or ([long]$State.Epoch -ne [long]$script:SessionEpoch) -or ([string]$State.Path -cne [string]$script:DatabaseScopedPath)){return}
    $runs=@(Get-DomeniaMember $Result 'CollectionRuns' @())
    if((-not [bool](Get-DomeniaMember $Result 'Saved' $false)) -or ([string](Get-DomeniaMember $Result 'DataSource' '') -cne 'SQLite') -or ($runs.Count -lt @($State.Families).Count)){
        Set-Status 'Dates du relevé de lʼOU : reçu SQLite incomplet. La vue garde les dates déjà relues.' 'WARN';return
    }
    # The page shows these clocks only after reading them back from the committed snapshot.
    try{Request-DomeniaFleetRefresh -Force}catch{Write-DomeniaSwallowed 'Refresh' 'Complete-DomeniaOuRefreshRunsStored' $_}
    # Outils > Relevés, when shown, lists the new record at once (decision David 2026-10-19).
    try{$runsTab=Get-DomeniaControl 'TabCollectionLimits';if(($null -ne $runsTab) -and [bool]$runsTab.IsVisible){Update-DomeniaRunsPanel;Request-DomeniaCollectionRunsList}}catch{Write-DomeniaSwallowed 'Refresh' 'Complete-DomeniaOuRefreshRunsStored' $_}
}
function Fail-DomeniaOuRefreshRunsStored {
    param([string]$Message,$State)
    if(($null -eq $State) -or ([long]$State.Epoch -ne [long]$script:SessionEpoch)){return}
    Set-Status ('Dates du relevé de lʼOU non confirmées par la base locale : '+$Message) 'WARN'
}
