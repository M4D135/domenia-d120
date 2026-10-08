# Explicit whole-index scan, bounded concurrent reads and persistent changed-only associations.
function Test-DomeniaParkRunCurrent {
    param($State)
    return ($null -ne $script:ParkRun -and $null -ne $State -and $State.RunId -ceq $script:ParkRun.Id -and $State.Epoch -eq [long]$script:SessionEpoch -and [string]$State.Path -ceq [string]$script:DatabaseScopedPath)
}
function Update-DomeniaParkRunStatus {
    if($null -eq $script:ParkRun){return}
    $r=$script:ParkRun
    $status=if($r.Stopping){'Arret demande'}elseif($r.Completed){$(if($r.PingOnly){'Ping termine'}else{'Releve termine'})}else{$(if($r.PingOnly){'Ping en cours'}else{'Releve en cours'})}
    $text=if($r.PingOnly){$status+' : '+$r.Done+'/'+$r.Targets.Count+' postes pingues, '+$r.Online+' joignables, '+($r.Done-$r.Online)+' sans reponse.'}else{$status+' : '+$r.Done+'/'+$r.Targets.Count+' postes verifies, '+$r.Online+' joignables, '+$r.Reused+' identites en cache, '+$r.Changed+' associations actualisees, '+$r.Failed+' lectures non confirmees.'}
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
    param([switch]$DisplayedResults,[switch]$PingOnly,[switch]$Inventory,[object[]]$ScopeTargets=$null,[string]$ScopeLabel='',[object[]]$Probes=$null)
    $started=$false
    try{
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
        $script:ParkRun=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;Targets=@();Next=0;Pending=@{};Done=0;Online=0;Reused=0;Changed=0;Failed=0;Stopping=$false;Completed=$false;Loading=$true;Approved=$false;Timer=$null;StatusText='';Generation=[long]$script:GlobalSearchGeneration;PingOnly=[bool]$PingOnly;Inventory=[bool]$Inventory;Probes=@($Probes|Where-Object{$null -ne $_});FleetRefresh=$true;ScopeLabel=[string]$ScopeLabel;Scope=$(if($DisplayedResults){'Results'}else{'Park'})}
        $started=$true
        $r=$script:ParkRun;$state=[pscustomobject]@{RunId=$r.Id;Epoch=$r.Epoch;Path=$r.Path}
        $job=Start-UiTask -Name 'Preparer le releve du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{Action='ParkTargets';Path=$r.Path;BusyTimeoutMs=250;Scope=$r.Scope;Targets=$targets}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkTargets' -ErrorHandler 'Fail-DomeniaParkTargets' -NonCancellable -TimeoutSeconds 60 -TaskClass 'Explicit'
        if(-not $job){throw 'Lecture du parc non admise.'}
        [void](Set-DomeniaControlText 'LblParkStatus' 'Lecture des postes et des sessions conservees en cache...')
    }catch{if($started -and $null -ne $script:ParkRun -and $script:ParkRun.Loading){$script:ParkRun.Completed=$true};Set-Status ('Releve impossible : '+$_.Exception.Message) 'WARN'}
    Update-DomeniaParkControls
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
        $message=$r.Targets.Count.ToString()+$(if($r.Scope -eq 'Results'){' postes dans les resultats affiches.'}elseif($r.ScopeLabel){' postes de '+[string]$r.ScopeLabel+'.'}else{' postes du perimetre choisi.'})+' Lecture legere de la console Windows (CIM/DCOM), quatre postes au maximum a la fois. Seuls les comptes nouveaux ou modifies sont resolus dans AD. Les sessions RDP ne sont pas recensees. Associations et cache conserves entre les lancements ; aucun inventaire complet, aucune tache distante.'
        if($r.Inventory){$message=$r.Targets.Count.ToString()+' postes'+$(if($r.ScopeLabel){' de '+$r.ScopeLabel}else{' dans les resultats affiches'})+'. Ping, utilisateur console et releve WMI leger (modele, memoire, disque C:, build, demarrage)'+$(if(@($r.Probes).Count){', plus '+@($r.Probes).Count+' requete(s) WMI des widgets'}else{''})+', en lecture seule ; quatre postes au maximum a la fois. Associations actualisees si l utilisateur change ; resultats conserves pour les tableaux de bord.'}
        elseif(@($r.Probes).Count){$message=$r.Targets.Count.ToString()+' postes'+$(if($r.ScopeLabel){' de '+$r.ScopeLabel}else{''})+'. '+@($r.Probes).Count+' requete(s) WMI des widgets en lecture seule, plus ping et utilisateur console ; quatre postes au maximum a la fois. Resultats conserves pour les tableaux de bord.'}
        elseif($r.ScopeLabel){$message=$r.Targets.Count.ToString()+' postes de '+$r.ScopeLabel+'.'+$(if($r.PingOnly){' Ping ICMP seulement.'}else{' Ping puis utilisateur console ; associations actualisees si changement.'})}
        if($r.PingOnly -and -not $r.ScopeLabel){$message=$r.Targets.Count.ToString()+' postes dans les resultats affiches. Ping ICMP seulement, quatre postes au maximum a la fois ; aucune lecture de session ni association.'}
        Request-DomeniaInlineConfirmation -Title $(if($r.Inventory){'Analyser les postes affiches'}elseif(@($r.Probes).Count){'Sonder pour les widgets'}elseif($r.PingOnly){'Pinger les postes affiches'}elseif($r.Scope -eq 'Results'){'Detecter sur les resultats affiches'}else{'Detecter sur tout le parc'}) -Target ([string]$script:Conn.Domain) -Message $message -ConfirmText $(if($r.PingOnly){'Pinger'}elseif($r.Inventory){'Analyser'}else{'Verifier les sessions'}) -CancelText 'Annuler' -OnConfirm ({& $start $runId}.GetNewClosure()) -OnCancel ({& $stop -RunId $runId}.GetNewClosure())
    }catch{Fail-DomeniaParkTargets $_.Exception.Message $State}
}
function Fail-DomeniaParkTargets {
    param($Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $script:ParkRun.Completed=$true;$script:ParkRun.Loading=$false
    [void](Set-DomeniaControlText 'LblParkStatus' ('Releve non lance : '+[string]$Message))
    Update-DomeniaParkControls
}
function Start-DomeniaParkRunTimer {
    param([string]$RunId)
    $r=$script:ParkRun
    if($null -eq $r -or $r.Id -cne $RunId -or $r.Stopping -or $r.Completed -or $r.Epoch -ne [long]$script:SessionEpoch -or $r.Path -cne [string]$script:DatabaseScopedPath){return}
    if($null -ne $r.Timer){return}
    $r.Approved=$true
    $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
    $timer.Interval=[timespan]::FromMilliseconds(250);$timer.Add_Tick({Invoke-DomeniaParkRunTick});$r.Timer=$timer
    [void](Register-DomeniaOwnedTimer -Owner 'Timer:ParkRun' -Timer $timer)
    $timer.Start();Update-DomeniaParkRunStatus
}
function Stop-DomeniaOnlinePark {
    param([string]$RunId='')
    $r=$script:ParkRun;if($RunId -and $null -ne $r -and $r.Id -cne $RunId){return};if($null -eq $r){return}
    $r.Stopping=$true
    if(-not $r.Pending.Count -and -not $r.Loading){
        $save=Get-DomeniaPersistenceState
        if(-not $r.Approved -or $save.Pending -eq 0 -or $save.Suspended){$r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()}}
    }
    Update-DomeniaParkRunStatus
}
function Invoke-DomeniaParkRunTick {
    $r=$script:ParkRun;if($null -eq $r){return}
    if($r.Epoch -ne [long]$script:SessionEpoch -or $r.Path -cne [string]$script:DatabaseScopedPath -or $script:AsyncEngineClosing){$r.Stopping=$true;$r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()};return}
    # Cancelled workers never silently cause the rest of the fleet to start.
    foreach($id in @($r.Pending.Keys)){
        if(-not $script:AsyncJobs.Contains($id) -and -not @($script:DetachedReadJobs|Where-Object{$_.Id -eq $id}).Count){$r.Pending.Remove($id);$r.Stopping=$true;$r.Failed++}
    }
    if(($r.Stopping -or $r.Next -ge $r.Targets.Count) -and -not $r.Pending.Count){
        $save=Get-DomeniaPersistenceState
        if($save.Pending -gt 0 -and -not $save.Suspended){Update-DomeniaParkRunStatus;return}
        $r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()};Update-DomeniaParkRunStatus;return
    }
    if($r.Stopping -or -not $r.Approved){return}
    if($script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){return}
    if($null -ne $script:Persistence){
        if($script:Persistence.Failures -ge 3 -or $script:Persistence.Conflicts.Count){$r.Stopping=$true;Update-DomeniaParkRunStatus;return}
        if($script:Persistence.Pending.Count -ge 64 -or $script:Persistence.LinkBusy){return}
    }
    # One admission per tick keeps the Dispatcher responsive. The engine may impose a smaller provider budget.
    if($r.Pending.Count -ge 4 -or $r.Next -ge $r.Targets.Count){return}
    $target=$r.Targets[$r.Next]
    $state=[pscustomobject]@{RunId=$r.Id;Epoch=$r.Epoch;Path=$r.Path;Target=$target;Job=''}
    try{
        $id=Start-UiTask -Name ($(if($r.PingOnly){'Ping de la liste : '}else{'Console du parc : '})+$target.Computer) -OperationId 'LiveConsole' -Code (Get-DomeniaLiveProbeCode) -Payload ([pscustomobject]@{Computer=$target.Computer;Key=$target.Key;Guid=$target.Guid;Previous=$target.Previous;MethodSeconds=4;ProbeUser=(-not [bool]$r.PingOnly);Inventory=([bool]$r.Inventory -and -not [bool]$r.PingOnly);Probes=$(if([bool]$r.PingOnly){@()}else{@($r.Probes)})}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkSession' -ErrorHandler 'Fail-DomeniaParkSession' -TimeoutSeconds $(if(@($r.Probes).Count){[Math]::Min(150,20+8*@($r.Probes).Count)}else{20}) -TaskClass 'Explicit'
        if(-not $id){throw 'Lecture non admise.'}
        $state.Job=[string]$id;$r.Pending[[string]$id]=$state;$r.Next++
    }catch{$r.Stopping=$true;[void](Set-DomeniaControlText 'LblParkStatus' ('Releve interrompu : '+$_.Exception.Message+' Les resultats precedents sont conserves.'))}
}
function Complete-DomeniaParkSession {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=$script:ParkRun
    if(-not $r.Pending.ContainsKey([string]$State.Job)){return}
    [void]$r.Pending.Remove([string]$State.Job)
    $packet=Get-DomeniaEffectiveWorkerResult $Result @('Outcome','Key','Guid','Computer')
    if($null -eq $packet -or [string]$packet.Key -cne [string]$State.Target.Key -or [string]$packet.Guid -ine [string]$State.Target.Guid -or [string]$packet.Computer -ine [string]$State.Target.Computer){$r.Failed++;$r.Stopping=$true;Update-DomeniaParkRunStatus;return}
    $r.Done++;if($packet.Presence -eq 'En ligne'){$r.Online++}
    if(-not $r.PingOnly -and $packet.Outcome -notin @('Observed','NoConsole')){$r.Failed++}
    if($packet.Outcome -eq 'AuthRejected' -or $packet.DirectoryAuthRejected){$r.Stopping=$true}
    if($packet.CacheReused){$r.Reused++}
    $observation=ConvertTo-DomeniaParkSession $packet $State.Target.Previous
    # Widgets read the latest observation of each workstation without waiting for the next dashboard reload.
    if($null -eq $script:FleetObservations){$script:FleetObservations=@{}};$script:FleetObservations[([string]$observation.Key).ToLowerInvariant()]=$observation
    if(-not (Queue-DomeniaMetadata -Kind ParkSession -Key $observation.Key -Row $observation)){$r.Stopping=$true;Set-Status 'Observation en memoire seulement : stockage local indisponible.' 'WARN';return}
    $existing=Get-ExistingLinkForComputer $packet.Computer
    if(Test-DomeniaParkLinkChanged $observation $existing){
        $relation=[pscustomobject]@{UserLogin=$observation.LinkUser;Computer=$observation.Computer;Source='Console CIM/DCOM';Confidence=0;VerifiedInAD=$true;When=[datetime]::UtcNow.ToString('o');Details='Session console observee par le releve du parc ; sessions RDP non recensees.';UserGuid=$observation.UserGuid;ComputerGuid=$observation.Guid;UserDn=$observation.UserDn;ComputerDn=$observation.Key;Kind='Console'}
        $outcome=Add-DomeniaRelation -Relation $relation -NoSave -Quiet
        if($outcome.StoredChanged){$r.Changed++;Request-DomeniaLinkPersistence}
    }
    Update-DomeniaParkResultRows $packet $observation
    Update-DomeniaParkRunStatus
}
function Fail-DomeniaParkSession {
    param($Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $packet=[pscustomobject]@{Outcome='Unavailable';Key=$State.Target.Key;Guid=$State.Target.Guid;Computer=$State.Target.Computer;Detail=[string]$Message;Presence='Non verifie';CacheReused=$false;DirectoryAuthRejected=$false}
    Complete-DomeniaParkSession $packet $State
}

function Update-DomeniaParkResultRows {
    param($Packet,$Observation)
    $liveObservation=ConvertTo-DomeniaLiveObservation $Packet $null -NowUtc $Observation.CheckedUtc
    $liveObservation.LastUser=$Observation.RawAccount;$liveObservation.ObservedUtc=$Observation.ObservedUtc
    if($null -ne $script:Live){$script:Live.Observations[$Observation.Key]=$liveObservation}
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return}
    # Direct lookup in the live search map (keyed by lowercase DN): no scan of a list of thousands per result.
    $rows=$null
    if($null -ne $script:Live -and $null -ne $script:Live.Search -and $null -ne $script:Live.Search.Map){$hit=$script:Live.Search.Map[[string]$Observation.Key];$rows=if($null -ne $hit){@($hit)}else{@()}}
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
