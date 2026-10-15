# Explicit OU refresh orchestration. AD completion is not a storage receipt.
function Get-DomeniaOuRefreshContext {
    param([ValidateSet('Fleet','Search','Index')][string]$Source)
    $domain=([string]$script:Conn.BaseDn).Trim();$dn=''
    switch($Source){'Fleet'{$dn=([string]$script:FleetScopeDn).Trim()};'Search'{$dn=([string]$script:SelectedBranchDn).Trim()};'Index'{$dn=([string]$script:IndexScopeDn).Trim()}}
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
        $names=switch($source){'Search'{@('BtnSearchRefreshBase','BtnSearchRefreshPostes','BtnSearchRefreshBoth')};'Fleet'{@('BtnFleetIndexScope','BtnFleetRefreshPostes','BtnFleetRefreshBoth')};'Index'{@('BtnIndexScopeUpdate')}}
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
    foreach($id in @($r.DirectoryJob,$r.TargetJob)){if($id){try{Stop-UiTask -Id $id -Silent}catch{}}}
    if($r.ParkRunId){Stop-DomeniaOnlinePark -RunId $r.ParkRunId}
    Update-DomeniaOuRefreshUi
}
function Fail-DomeniaOuRefresh {
    param([string]$OperationId,[string]$Message)
    $r=$script:DomeniaOuRefresh
    if(-not $OperationId -or $null -eq $r -or $r.Id -cne $OperationId -or $r.Completed){return}
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
    if($null -eq $Item.Row.PSObject.Properties['Complete'] -or -not [bool]$Item.Row.Complete){Fail-DomeniaOuRefresh -OperationId $id -Message 'Lecture AD partielle : le dernier repère complet est conservé.';return}
    $r.BaseCommitted=$true
    if($r.Mode -in @('AD','Base')){$r.Completed=$true;$r.Phase='Complete';$r.Status='Objets AD relus et enregistrés : '+$r.Label+'. Aucun ping ni relevé WMI.';if($null -ne $r.Timer){$r.Timer.Stop()}}
    else{$r.Phase='WaitingCollection';$r.Status='Base locale enregistrée. Préparation du relevé des postes de '+$r.Label+'.'}
    Update-DomeniaOuRefreshUi
}
function Get-DomeniaOuRefreshProbePlan {
    # The workshop is lazy: read its validated saved library locally when no view has been opened.
    # Do not initialize that view, change its scope, or silently omit a configured query widget.
    $ids=@(Get-DomeniaBoardProbeIds)
    $widgets=@(foreach($board in @('Fleet','Computer')){Get-DomeniaBoardLayout -Board $board|Where-Object{[string]$_.Source -eq 'Query'}})
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
    # Legacy modes are retained for compatibility; the UI exposes only AD, Ping and Wmi.
    # -BackupDone: continuation of the verified backup taken before an AD read (FI-13); every check runs again.
    param([ValidateSet('Fleet','Search','Index')][string]$Source,[ValidateSet('AD','Ping','Wmi','Base','Postes','Both')][string]$Mode,[switch]$BackupDone)
    $created=$false
    try{
        $context=Get-DomeniaOuRefreshContext $Source
        if($null -eq $context){throw 'Choisissez une OU explicite dans cette page.'}
        if($script:DemoMode){throw 'Actualisation distante indisponible en démonstration.'}
        if($null -ne $script:DomeniaOuRefresh -and -not $script:DomeniaOuRefresh.Completed){throw 'Une actualisation est déjà en cours.'}
        if($null -ne $script:ParkRun -and -not $script:ParkRun.Completed){throw 'Un relevé de postes est déjà en cours.'}
        if(@($script:AsyncJobs.Values|Where-Object{$_.OperationId -in @('IndexBuild','StoragePurge','LegacyMigration')}).Count){throw 'Attendez la fin de la lecture AD ou de la maintenance locale.'}
        $save=Get-DomeniaPersistenceState
        if($save.Pending -gt 0 -or $save.Suspended -or $save.Conflicts -gt 0){throw 'Attendez ou rétablissez la confirmation des écritures locales.'}
        # Snapshot the selected dashboard probe plan now, before AD work or a later confirmation can change it.
        $probes=@()
        if($Mode -in @('Wmi','Postes','Both')){$probes=@(Get-DomeniaOuRefreshProbePlan)}
        # FI-13: an AD read rewrites this OU in the local base (reconciliation included). Once every check above has
        # passed, a verified backup (StorageBackup worker) comes first, from the Index, Fleet and Search pages alike; the
        # refresh starts again from its receipt and checks everything again. Ping and WMI collections only add
        # observations and need no copy.
        if(($Mode -in @('AD','Base','Both')) -and (-not $BackupDone)){
            $refresh=${function:Invoke-DomeniaOuRefresh}
            [void](Invoke-DomeniaGestureBackup -Gesture 'IndexUpdate' -Then ({& $refresh -Source $Source -Mode $Mode -BackupDone}.GetNewClosure()))
            return
        }
        $r=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Source=$Source;Mode=$Mode;Dn=$context.Dn;Subtree=$true;DomainDn=$context.DomainDn;Label=$context.Label;Epoch=$context.Epoch;Path=$context.Path;Phase='Directory';Status='Lecture AD : '+$context.Label;DirectoryJob='';TargetJob='';ParkRunId='';BaseCommitted=$false;Cancelled=$false;Completed=$false;Timer=$null;Started=[datetime]::UtcNow}
        $r|Add-Member -NotePropertyName Probes -NotePropertyValue $probes
        $script:DomeniaOuRefresh=$r;$created=$true
        $r.Timer=New-DomeniaTimer -Owner 'Timer:OuRefresh' -IntervalMs 250 -RunWhenHidden -Tick {Invoke-DomeniaOuRefreshTick}
        if($Mode -in @('Ping','Wmi','Postes')){$r.Phase='WaitingCollection';$r.Status='Préparation des postes activés dans AD de '+$r.Label+'. '+$(if($Mode -eq 'Ping'){'Le ping seul sera relu.'}elseif($Mode -eq 'Wmi'){'Les informations WMI seront relues.'}else{'Ping et WMI seront relus après confirmation.'})}
        else{
            $r.DirectoryJob=[string](Start-DomeniaIndexScopeBuild -Dn $r.Dn -RefreshOperationId $r.Id)
            if(-not $r.DirectoryJob){throw 'Lecture AD non admise.'}
        }
        $r.Timer.Start();Update-DomeniaOuRefreshUi
    }catch{
        if($created){Fail-DomeniaOuRefresh -OperationId $script:DomeniaOuRefresh.Id -Message $_.Exception.Message}
        Set-Status ('Actualisation non lancée : '+$_.Exception.Message) 'WARN'
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
        if($r.Mode -eq 'Both' -and -not $r.BaseCommitted){Fail-DomeniaOuRefresh -OperationId $r.Id -Message 'Le reçu de mise à jour de la base est absent.';return}
        try{
            $plan=Get-DomeniaFleetQueryPlan -Now ([datetime]::Now) -ObservationMaxAgeDays (Get-DomeniaObservationMaxAgeDays)
            $payload=[pscustomobject]@{Action='FleetStats';Path=$r.Path;Scope=$r.Dn;Subtree=$true;Plan=$plan;Keys=@();ScopeKey='';ComputeBoard=$false;ModuleRoot=$script:DashboardModuleRoot}
            $state=[pscustomobject]@{OperationId=$r.Id;Epoch=$r.Epoch;Path=$r.Path;Dn=$r.Dn}
            $r.Phase='Resolving';$r.Status='Lecture des postes actifs depuis la base locale : '+$r.Label+'.'
            $r.TargetJob=[string](Start-UiTask -Name 'Préparer lʼactualisation des postes de lʼOU' -OperationId LocalIndexRead -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -SuccessHandler 'Complete-DomeniaOuRefreshTargets' -ErrorHandler 'Fail-DomeniaOuRefreshTargets' -TimeoutSeconds 120 -TaskClass Explicit)
            if(-not $r.TargetJob){throw 'Lecture locale non admise.'}
        }catch{Fail-DomeniaOuRefresh -OperationId $r.Id -Message $_.Exception.Message}
    }
    if($r.ParkRunId){Update-DomeniaOuRefreshFromPark -Run $script:ParkRun}
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
        if(-not $targets.Count){$r.Completed=$true;$r.Phase='Complete';$r.Status='Aucun poste actif recensé dans '+$r.Label+'. Aucun ping ni WMI lancé.';$r.Timer.Stop();Update-DomeniaOuRefreshUi;return}
        $r.Phase='Confirming';$r.Status=[string]$targets.Count+' poste(s) activé(s) dans AD, '+$r.Label+'. Confirmation de la collecte en attente.'
        $args=@{ScopeTargets=$targets;ScopeLabel=$r.Label;ForceRefresh=$true;RefreshOperationId=$r.Id;PassThru=$true}
        if($r.Mode -eq 'Ping'){$args.PingOnly=$true}
        else{$args.Inventory=$true;$args.Probes=@($r.Probes);if($r.Mode -eq 'Wmi'){$args.WmiOnly=$true}}
        $r.ParkRunId=[string](Start-DomeniaOnlinePark @args)
        if(-not $r.ParkRunId){throw 'Préparation du relevé non admise.'}
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
        $r.Completed=$true;$r.Timer.Stop()
        $save=Get-DomeniaPersistenceState
        if($save.Pending -gt 0 -or $save.Suspended -or $save.Conflicts -gt 0){$r.Phase='Error';$r.Status='Relevé terminé, mais enregistrement local non confirmé. Vérifiez Stockage ; aucune réussite complète annoncée.'}
        elseif($Run.FailureMessage){$r.Phase='Error';$r.Status='Relevé non terminé : '+[string]$Run.FailureMessage}
        elseif(-not $Run.Approved -or $Run.Stopping){$r.Phase='Cancelled';$r.Cancelled=$true;$r.Status='Relevé arrêté : '+[string]$Run.Done+' poste(s) traité(s). Les données déjà confirmées sont conservées.'}
        elseif($Run.Failed -gt 0){$r.Phase='Partial';$r.Status='Relevé terminé avec '+[string]$Run.Failed+' lecture(s) non confirmée(s) sur '+[string]$Run.Done+'. Consultez les détails des postes.'}
        else{$r.Phase='Complete';$r.Status='Actualisation terminée : '+[string]$Run.Done+' poste(s) de '+$r.Label+'. '+$(if($r.Mode -eq 'Ping'){'Ping relu, données enregistrées. Les dates AD et WMI sont conservées.'}elseif($r.Mode -eq 'Wmi'){'WMI relu, données enregistrées. Les dates AD et ping sont conservées.'}else{'Ping et WMI relus, données enregistrées.'})}
    }elseif($Run.Approved){$r.Phase='Collecting';$r.Status=[string]$Run.StatusText}
    Update-DomeniaOuRefreshUi
}
