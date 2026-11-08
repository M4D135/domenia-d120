# Explicit whole-index scan, bounded concurrent reads and persistent changed-only associations.
# FI-18: one survey per scope in $script:ParkRuns: 'List' (Rechercher, its selection and the perimeter surveys of an OU,
# a board or a query) and 'Computer' (the workstation open in Poste). Each scope has its timer, its state and its
# Arrêter beside the button that started it; a survey of one scope never blocks the other.
# Widget collections (decision David 2026-10-14) run in the scope of their population (Get-DomeniaWidgetCollectSlot):
# a widget of the OU shown on Accueil in 'List', a widget of the open workstation in 'Computer'.
# Collection engine (roadmap points 13 to 20, 159 and 160): every survey of either scope, the batch ping (MO-08) and
# the widget collections included, goes through the same budgets per presumed subnet (Domenia-Collection.Model.ps1),
# the same classification before a retry, the same capability memory and the same collection window; a survey of
# the scope of the lists keeps a durable plan for its resumption.
function Get-DomeniaParkRuns {
    if($null -eq $script:ParkRuns){$script:ParkRuns=@{}}
    return $script:ParkRuns
}
function Get-DomeniaParkRun {
    param([string]$Slot='List')
    $runs=Get-DomeniaParkRuns
    if($runs.ContainsKey($Slot)){return $runs[$Slot]}
    return $null
}
function Get-DomeniaParkRunById {
    param([string]$RunId)
    if(-not $RunId){return $null}
    foreach($run in @((Get-DomeniaParkRuns).Values)){if($null -ne $run -and [string]$run.Id -ceq $RunId){return $run}}
    return $null
}
function Test-DomeniaParkRunActive {
    # A survey still preparing, reading or storing, in one scope or in any scope without -Slot.
    param([string]$Slot='')
    foreach($run in @((Get-DomeniaParkRuns).Values)){
        if($null -eq $run -or [bool]$run.Completed){continue}
        if(-not $Slot -or [string]$run.Slot -eq $Slot){return $true}
    }
    return $false
}
function Get-DomeniaParkStateSlot {
    param($State)
    $slot=[string](Get-DomeniaMemberValue $State 'Slot')
    if($slot -in @('List','Computer')){return $slot}
    return 'List'
}
function Test-DomeniaParkRunCurrent {
    param($State)
    if($null -eq $State){return $false}
    $run=Get-DomeniaParkRun -Slot (Get-DomeniaParkStateSlot $State)
    return ($null -ne $run -and [string]$State.RunId -ceq [string]$run.Id -and $State.Epoch -eq [long]$script:SessionEpoch -and [string]$State.Path -ceq [string]$script:DatabaseScopedPath)
}
function Get-DomeniaParkMaxTargets {
    # SE-05: ceiling of a survey of the displayed list or of its selection (Park.MaxTargets, 500 by default).
    $value=500
    try{$value=[int](Get-CfgValue 'Park' 'MaxTargets' 500)}catch{$value=500}
    return $value
}
function Get-DomeniaWidgetMaxTargets {
    # Ceiling of a widget collection (setting « Plafond des widgets », Collection.WidgetMaxTargets): 0 = no ceiling,
    # the default since 2026-10-19 (the count is still confirmed above the direct limit). Bounded to 100000.
    $value=0
    try{$value=[int](Get-DomeniaSetting 'Collection.WidgetMaxTargets' '0')}catch{$value=0}
    return [Math]::Max(0,[Math]::Min(100000,$value))
}
function Get-DomeniaCollectionRetrySettings {
    # Spaced retries of a WMI read after a transient incident (settings « Nouveaux essais WMI » and « Premier délai »):
    # 0 to 4 new attempts (2 by default), first delay 10 to 120 s (30 s by default), then x4 up to 5 min.
    $retries=2;$delay=30
    try{$retries=[int](Get-DomeniaSetting 'Collection.WmiRetries' '2')}catch{$retries=2}
    try{$delay=[int](Get-DomeniaSetting 'Collection.WmiRetryDelaySeconds' '30')}catch{$delay=30}
    return [pscustomobject]@{MaxAttempts=(1+[Math]::Max(0,[Math]::Min(4,$retries)));BaseDelaySeconds=[Math]::Max(10,[Math]::Min(120,$delay))}
}
function Initialize-DomeniaCollectionLimitsUi {
    # Decision David 2026-10-19: ceiling of the widget collections and WMI retries (Outils > Relevés); read at the
    # start of each run. Wired once, during Wire-Events, before the preferences are loaded: the choices shown are set
    # by Update-DomeniaCollectionLimitsUi, called again once the preferences are read (Initialize-DomeniaPresentation).
    if([bool]$script:DomeniaCollectionLimitsWired){return}
    $widgetMax=Get-DomeniaControl 'CmbCollectionWidgetMax'
    if($null -ne $widgetMax){$widgetMax.ItemsSource=@([pscustomobject]@{Name='Sans plafond';Value=0},[pscustomobject]@{Name='500 postes';Value=500},[pscustomobject]@{Name='1000 postes';Value=1000},[pscustomobject]@{Name='2000 postes';Value=2000},[pscustomobject]@{Name='5000 postes';Value=5000});$widgetMax.Add_SelectionChanged({param($s,$e)if(($null -ne $s.SelectedItem) -and (-not [bool]$script:DomeniaCollectionLimitsUpdating) -and ($null -ne $script:Settings)){Set-DomeniaSetting 'Collection.WidgetMaxTargets' ([string]$s.SelectedItem.Value);Save-DomeniaSettings}})}
    $retries=Get-DomeniaControl 'CmbCollectionWmiRetries'
    if($null -ne $retries){$retries.ItemsSource=@(0,1,2,3,4);$retries.Add_SelectionChanged({param($s,$e)if(($null -ne $s.SelectedItem) -and (-not [bool]$script:DomeniaCollectionLimitsUpdating) -and ($null -ne $script:Settings)){Set-DomeniaSetting 'Collection.WmiRetries' ([string]$s.SelectedItem);Save-DomeniaSettings}})}
    $retryDelay=Get-DomeniaControl 'CmbCollectionWmiRetryDelay'
    if($null -ne $retryDelay){$retryDelay.ItemsSource=@([pscustomobject]@{Name='10 s';Seconds=10},[pscustomobject]@{Name='30 s';Seconds=30},[pscustomobject]@{Name='1 min';Seconds=60},[pscustomobject]@{Name='2 min';Seconds=120});$retryDelay.Add_SelectionChanged({param($s,$e)if(($null -ne $s.SelectedItem) -and (-not [bool]$script:DomeniaCollectionLimitsUpdating) -and ($null -ne $script:Settings)){Set-DomeniaSetting 'Collection.WmiRetryDelaySeconds' ([string]$s.SelectedItem.Seconds);Save-DomeniaSettings}})}
    $tab=Get-DomeniaControl 'TabCollectionLimits'
    if($null -ne $tab){$tab.Add_IsVisibleChanged({param($s,$e)if([bool]$s.IsVisible){try{Update-DomeniaCollectionLimitsUi;Update-DomeniaRunsPanel;Request-DomeniaCollectionRunsList}catch{Write-DomeniaSwallowed 'Park' 'Initialize-DomeniaCollectionLimitsUi' $_}}})}
    # Running, interrupted and recorded surveys (Domenia-Collection.UI.ps1).
    $runsStop=Get-DomeniaControl 'BtnRunsStop';if($null -ne $runsStop){$runsStop.Add_Click({try{Stop-DomeniaRunsPanelSurvey}catch{Set-Status ('Relevé non arrêté : '+$_.Exception.Message) 'WARN'}})}
    $runsResume=Get-DomeniaControl 'BtnRunsResume';if($null -ne $runsResume){$runsResume.Add_Click({Start-DomeniaCampaignResume})}
    $runsDiscard=Get-DomeniaControl 'BtnRunsResumeDiscard';if($null -ne $runsDiscard){$runsDiscard.Add_Click({Clear-DomeniaCampaignPlan})}
    $runsRefresh=Get-DomeniaControl 'BtnRunsRefresh';if($null -ne $runsRefresh){$runsRefresh.Add_Click({Request-DomeniaCollectionRunsList})}
    $script:DomeniaCollectionLimitsWired=$true
    Update-DomeniaCollectionLimitsUi
}
function Update-DomeniaCollectionLimitsUi {
    # Shows the stored choices of Outils > Relevés without writing them back.
    $script:DomeniaCollectionLimitsUpdating=$true
    try{
        $widgetMax=Get-DomeniaControl 'CmbCollectionWidgetMax'
        if($null -ne $widgetMax){$current=Get-DomeniaWidgetMaxTargets;$widgetMax.SelectedIndex=0;foreach($entry in @($widgetMax.ItemsSource)){if([int]$entry.Value -eq $current){$widgetMax.SelectedItem=$entry}}}
        $retryPolicy=Get-DomeniaCollectionRetrySettings
        $retries=Get-DomeniaControl 'CmbCollectionWmiRetries'
        if($null -ne $retries){$retries.SelectedItem=([int]$retryPolicy.MaxAttempts-1)}
        $retryDelay=Get-DomeniaControl 'CmbCollectionWmiRetryDelay'
        if($null -ne $retryDelay){$retryDelay.SelectedIndex=1;foreach($entry in @($retryDelay.ItemsSource)){if([int]$entry.Seconds -eq [int]$retryPolicy.BaseDelaySeconds){$retryDelay.SelectedItem=$entry}}}
    }finally{$script:DomeniaCollectionLimitsUpdating=$false}
}
function Get-DomeniaParkListContext {
    # SE-05 / UX-24: what the displayed list covers, read from the running search: base, depth, term and filters.
    $state=$null;$final=$null
    if($null -ne $script:Live -and $null -ne $script:Live.Search){$state=$script:Live.Search.State;$final=$script:Live.Search.Final}
    $global=$false;$scope='';$term='';$subtree=$false;$limit=0
    if($null -ne $state){
        $global=([string]$state.SearchMode -eq 'Global');$scope=[string]$state.BaseDn;$term=([string]$state.Search).Trim();$subtree=([string]$state.Scope -ne 'OneLevel')
        if($null -ne $final -and [bool](Get-DomeniaMemberValue $final 'LimitReached')){$limit=[int]$state.Limit}
    }else{
        $global=((Get-DomeniaSearchMode) -eq 'Global');$scope=[string]$script:SelectedBranchDn
        $box=Get-DomeniaControl $(if($global){'TxtGlobalSearch'}else{'TxtBranchSearch'})
        if($null -ne $box){$term=([string]$box.Text).Trim()}
    }
    $filterBox=Get-DomeniaControl 'TxtSuiteResultFilter'
    $localText=if($null -ne $filterBox){([string]$filterBox.Text).Trim()}else{''}
    $presence=[string]$script:CurrentPresenceFilter
    $querySelection=($null -ne $script:DomeniaQueryState -and $null -ne $script:DomeniaQueryState.SearchRecipe)
    # A global search ignores the local filters (D031): only its term narrows it.
    $hasFilter=([bool]$term -or $querySelection -or ((-not $global) -and ([bool]$localText -or ($presence -and $presence -ne 'Tous'))))
    $base=([string]$script:Conn.BaseDn).Trim()
    # UX-24: the target names the search or the OU; a filtered list of the domain root stays « les résultats
    # affichés » (empty label), never the domain.
    $label=''
    if($global){$label=$(if($term){'recherche « '+$term+' »'}else{'recherche globale'})}
    elseif($scope -and -not ($base -and $scope -ieq $base)){$label='OU '+[string](Get-DomeniaUxOuDisplay -DistinguishedName $scope -IsDomain $false).Name}
    return [pscustomobject]@{ScopeDn=$scope;BaseDn=$base;Global=$global;HasSearchTerm=[bool]$term;HasFilter=$hasFilter;Subtree=$subtree;ListLimit=$limit;Label=$label}
}
function Get-DomeniaParkDisplayedTargets {
    # The workstations of the displayed list (after its filters), with their AD identity; a row without DN or GUID is
    # counted, never sent.
    # Point 48: every other displayed row is named in the exact preview with the reason it stays out (another type, or
    # a workstation without identity); only the workstations without identity count as skipped (UX-24).
    $grid=Get-DomeniaControl 'DgObjects'
    $machines=New-Object 'System.Collections.Generic.List[object]';$targets=New-Object 'System.Collections.Generic.List[object]';$excluded=New-Object 'System.Collections.Generic.List[object]';$skipped=0
    if($null -ne $grid){
        foreach($row in @($grid.Items)){
            if($null -eq $row){continue}
            $type=[string]$row.Type
            if($type -ne 'Machine'){
                $kind=if($type){'Type '+$type}else{'Type non renseigné'}
                $excluded.Add([pscustomobject]@{Name=[string]$row.Name;DN=[string]$row.DN;Reason=($kind+' hors du périmètre de lʼopération')});continue
            }
            $machines.Add($row)
            if($row.DN -and $row.Guid){$targets.Add([pscustomobject]@{name=[string]$row.Name;distinguished_name=[string]$row.DN;object_guid=[string]$row.Guid})}
            else{$skipped++;$excluded.Add([pscustomobject]@{Name=[string]$row.Name;DN=[string]$row.DN;Reason='Identité incomplète (DN ou GUID absent) : relisez la fiche'})}
        }
    }
    return [pscustomobject]@{Machines=$machines.ToArray();Targets=$targets.ToArray();Excluded=$excluded.ToArray();Skipped=$skipped}
}
function Test-DomeniaParkListStoppable {
    # FI-18 / UI-23: a survey of the scope of the lists stops from « Vérifier la liste » (the list, its selection, the
    # perimeter surveys of a board or a query). An OU refresh keeps its own Arrêter beside its refresh buttons.
    param($Run)
    return ($null -ne $Run -and -not [bool]$Run.Completed -and -not [string]$Run.RefreshOperationId)
}
function Update-DomeniaParkRunStatus {
    # One survey, or every survey when called without one. The short count goes beside the button that started it;
    # the long text to the Base and Relations status lines, and once to the journal when the survey ends.
    param($Run=$null)
    if($null -eq $Run){
        foreach($item in @((Get-DomeniaParkRuns).Values)){if($null -ne $item){Update-DomeniaParkRunStatus -Run $item}}
        Update-DomeniaParkControls
        return
    }
    $r=$Run
    if($r.Completed){Clear-DomeniaParkTargetBuffers $r.Targets;Clear-DomeniaParkPendingRows -Run $r}
    $status=if($r.Completed -and $r.Stopping){'Relevé arrêté'}elseif($r.Completed){$(if($r.PingOnly){'Ping terminé'}else{'Relevé terminé'})}elseif($r.Stopping){'Arrêt demandé'}else{$(if($r.PingOnly){'Ping en cours'}else{'Relevé en cours'})}
    $fresh=[int](Get-DomeniaMember $r 'AlreadyFresh' 0)
    if(([bool](Get-DomeniaMember $r 'Planning' $false)) -and (-not [bool]$r.Completed)){
        # A widget collection checking the stored measurements: nothing is read on the network yet.
        $short=Format-DomeniaWidgetCollectProgress -Phase Planning -Done ([int]$r.PlanNext) -Total (@($r.Targets).Count) -Fresh $fresh
        $text='Préparation de la collecte : '+[string][int]$r.PlanNext+'/'+[string]@($r.Targets).Count+' postes vérifiés dans la base locale, '+[string]$fresh+' déjà à jour ; aucun poste contacté pour lʼinstant.'
    }else{
        $short=Get-DomeniaParkProgressText -Done ([int]$r.Done) -Total (@($r.Targets).Count) -Online ([int]$r.Online) -NoReply ([int]$r.NoReply) -Errors ([int]$r.Errors) -Failed ([int]$r.Failed) -Unchecked ([int]$r.Unchecked) -PingRequested (-not [bool]$r.WmiOnly) -Completed ([bool]$r.Completed) -Stopped ([bool]$r.Stopping)
        $text=$status+' : '+$short+'.'
        if(-not $r.PingOnly){$text+=' '+$r.Reused+' identités en cache, '+$r.Changed+' association(s) créée(s) ou changée(s), '+$r.CachedMeasurements+' mesures encore fraîches réutilisées.'}
        if(-not $r.Completed){
            $retryWait=0
            # PS 5.1 throws "Argument types do not match" on Properties['Retry'] for this run object.
            try{
                $retryMember=$null
                foreach($member in @($r.PSObject.Properties)){if([string]$member.Name -ceq 'Retry'){$retryMember=$member;break}}
                if($null -ne $retryMember -and $null -ne $retryMember.Value){$retryWait=@($retryMember.Value).Count}
            }catch{$retryWait=0}
            $phase=$(if($r.PingOnly){'Échos envoyés par lots.'}else{[string]$r.Pending.Count+' en WMI / '+[string]$r.Concurrency})
            if([string]$r.PingJob){$phase+=', ping en cours'}
            if($retryWait -gt 0){$phase+=', '+[string]$retryWait+' en nouvel essai (hors des créneaux)'}
            $text+=' '+$phase+'.'
        }
        # Widget collections: the workstations whose stored measurement already answered were never contacted.
        if($fresh -gt 0){$text+=' '+[string]$fresh+' '+(Get-DomeniaParkPlural $fresh 'poste déjà à jour' 'postes déjà à jour')+', sans lecture.'}
        if($r.Completed){
            $skipped=[int](Get-DomeniaMember $r 'SkippedTargets' 0)+[int](Get-DomeniaMember $r 'Skipped' 0)
            $pingSummary=Get-DomeniaMemberValue $r 'PingSummary' $null
            if($null -ne $pingSummary){$skipped+=[int]$pingSummary.Skipped}
            $pingCount=if($null -ne $pingSummary){[int]$pingSummary.Done}else{[int]$r.Online+[int]$r.NoReply}
            $silentCount=if($null -ne $pingSummary){[int]$pingSummary.NoReply}else{[int]$r.NoReply}
            $text+=' Bilan : '+[string]$pingCount+' pinglés, '+[string]$silentCount+' muets, '+[string][int]$r.Done+' lus, '+[string][int]$r.CachedMeasurements+' réutilisés, '+[string]$skipped+' sautés.'
            if($null -ne $pingSummary -and ([int]$pingSummary.Errors+[int]$pingSummary.Failed) -gt 0){$text+=' Ping préparatoire : '+[string]([int]$pingSummary.Errors+[int]$pingSummary.Failed)+' erreur(s).'}
        }
        # Points 13 to 20: validated results, adapted or paused sources, retries, capabilities and the durable plan.
        $detail=Get-DomeniaParkRunDetailText $r
        if($detail){$text+=' '+$detail}
    }
    $save=Get-DomeniaPersistenceState
    if($save.Pending -gt 0){$text+=' Enregistrement local en attente.'}
    if(([bool]$save.Suspended) -or ($save.Conflicts -gt 0)){$text+=' Stockage local à vérifier : Base autonome, onglet Stockage.'}
    if([string]$r.FailureMessage){$text+=' '+[string]$r.FailureMessage}
    elseif($r.Stopping -and [string]$r.StopReason){$text+=' Motif : '+[string]$r.StopReason+'.'}
    $r.StatusText=$text;$r.ShortText=$short
    if($r.Completed){Sync-DomeniaParkGrid -Run $r}
    # A finished run that read workstations changed the observations: the selected workstation board is redrawn at
    # once, the home overview now or when Accueil is shown again.
    if($r.Completed -and [bool]$r.FleetRefresh -and -not [bool]$r.FleetRefreshed){
        $r|Add-Member -NotePropertyName FleetRefreshed -NotePropertyValue $true -Force
        if($r.Approved -and $r.Done -gt 0){
            if($null -ne $script:SelectedObject){try{Show-DomeniaBoard -Board Computer -Quiet}catch{Write-DomeniaSwallowed 'Park' 'Update-DomeniaParkRunStatus' $_}}
            # The survey the operator started changed the local measures. One overview recalculation lets a queued widget proceed.
            try{Request-DomeniaFleetRefresh -Force}catch{Write-DomeniaSwallowed 'Park' 'Update-DomeniaParkRunStatus' $_}
        }
    }
    try{Invoke-DomeniaParkLiveUpdates -Run $r}catch{Write-DomeniaSwallowed 'Park' 'Update-DomeniaParkRunStatus' $_}
    try{$runsTab=Get-DomeniaControl 'TabCollectionLimits';if(($null -ne $runsTab) -and [bool]$runsTab.IsVisible){Update-DomeniaRunsPanel}}catch{Write-DomeniaSwallowed 'Park' 'Update-DomeniaParkRunStatus' $_}
    if($r.Completed -and $r.Approved -and -not [bool]$r.Logged){$r.Logged=$true;try{Write-AppLog ('Relevé des postes ('+$(if($r.Slot -eq 'Computer'){'poste'}else{'liste'})+') : '+$text) 'INFO'}catch{Write-DomeniaSwallowed 'Park' 'Update-DomeniaParkRunStatus' $_}}
    Update-DomeniaParkControls
    foreach($label in @('LblParkStatus','LblParkDetectionStatus')){[void](Set-DomeniaControlText $label $text)}
    # A run started by a widget shows its progress on that widget; at the end of any run the next queued widget
    # starts (the watch timer of the widgets does it too, once the recalculation of the OU is drawn).
    if(([string](Get-DomeniaMember $r 'WidgetBoard' '')) -or (($null -ne $script:DomeniaWidgetCollectQueue) -and ($script:DomeniaWidgetCollectQueue.Count -gt 0))){try{Update-DomeniaWidgetCollectProgress}catch{Write-AppLog ('Progression du widget non affichée : '+$_.Exception.Message) 'WARN'}}
}
function Invoke-DomeniaParkLiveUpdates {
    # Decision David 2026-10-19: while a survey of the lists runs, the overview and its widgets are recalculated from
    # the measures already stored, every 15 seconds at most (one calculation at a time, Request-DomeniaFleetRefresh),
    # and the console associations created so far are queued for saving. At the end, stopped or not, the associations
    # left are queued once; the overview is recalculated by the end of the run itself.
    param($Run)
    if($null -eq $Run){return}
    $nowUtc=[datetime]::UtcNow
    if([bool]$Run.Completed){
        if([bool](Get-DomeniaMember $Run 'LinksPending' $false)){$Run|Add-Member -NotePropertyName LinksPending -NotePropertyValue $false -Force;Request-DomeniaLinkPersistence}
        return
    }
    if(([string]$Run.Slot -ne 'List') -or (-not [bool]$Run.Approved)){return}
    $last=Get-DomeniaMemberValue $Run 'LiveUpdateUtc'
    if(($last -is [datetime]) -and (($nowUtc-$last).TotalSeconds -lt 15)){return}
    $Run|Add-Member -NotePropertyName LiveUpdateUtc -NotePropertyValue $nowUtc -Force
    if([bool](Get-DomeniaMember $Run 'LinksPending' $false)){$Run|Add-Member -NotePropertyName LinksPending -NotePropertyValue $false -Force;Request-DomeniaLinkPersistence}
}
function Register-DomeniaParkConsoleLink {
    # Decision David 2026-10-19: the console account observed by a survey becomes a user-workstation association, with
    # the rule of a click on one workstation (Merge-DomeniaLiveLinkMemory): only an account found in AD (UserDn), upsert
    # next to the existing relations, never a declared or imported assignment replaced. A workstation already associated
    # with the same account is left as it is (no rewrite of the whole fleet at each survey). Saved by the run, in batches.
    param($Run,$Observation)
    if(($null -eq $Run) -or ($null -eq $Observation) -or ([string]$Observation.Outcome -ne 'Observed')){return}
    if((-not [string](Get-DomeniaMember $Observation 'LinkUser' '')) -or (-not [string](Get-DomeniaMember $Observation 'UserDn' ''))){return}
    $computer=Normalize-LinkComputer ([string]$Observation.Computer);$user=Normalize-LinkUser ([string]$Observation.LinkUser)
    if((-not $computer) -or (-not $user)){return}
    $login=ConvertTo-DomeniaRelationLoginKey $user
    foreach($link in @(Get-LinksForComputer $computer|Where-Object{$null -ne $_})){if((ConvertTo-DomeniaRelationLoginKey ([string]$link.UserLogin)) -eq $login){return}}
    $observedUtc=ConvertTo-DomeniaUtcDate ([string](Get-DomeniaMember $Observation 'ObservedUtc' ''));if($null -eq $observedUtc){$observedUtc=[datetime]::UtcNow}
    $relation=[pscustomobject]@{UserLogin=$user;Computer=$computer;Source='Console CIM/DCOM';Confidence=0;VerifiedInAD=$true;When=$observedUtc.ToString('o');Details='Compte console observé lors dʼun relevé ; sessions RDP non recensées.';UserGuid=[string](Get-DomeniaMember $Observation 'UserGuid' '');ComputerGuid=[string]$Observation.Guid;UserDn=[string]$Observation.UserDn;ComputerDn=[string]$Observation.Key;Kind='Console'}
    $outcome=Add-DomeniaRelation -Relation $relation -NoSave -Quiet
    if([bool]$outcome.StoredChanged){$Run.Changed=[int]$Run.Changed+1;$Run|Add-Member -NotePropertyName LinksPending -NotePropertyValue $true -Force}
}
function Get-DomeniaParkInFlightCount {
    # Workstations read right now: one per console or WMI read, every echo of the batch ping job in flight (MO-08).
    param($Run)
    $count=0
    foreach($state in @($Run.Pending.Values)){
        if($null -eq $state){continue}
        if($null -ne $state.PSObject.Properties['Keys']){$count+=@($state.Keys).Count}else{$count++}
    }
    return $count
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
            $state=Get-DomeniaCampaignProgressState -Total @($Run.Targets).Count -Validated ([int]$Run.Done) -Pending (Get-DomeniaParkInFlightCount $Run) -Waiting $waiting -StartedUtc $started -LastValidatedUtc (Get-DomeniaMemberValue $Run 'LastValidatedUtc') -HeldSeconds ([double](Get-DomeniaMember $Run 'HeldSeconds' 0))
            if(-not [bool]$Run.Completed){
                $parts.Add('Progression : '+[string]$state.Text+'.')
                $parts.Add('File : '+[string]$waiting+' poste(s) à lire ; '+[string](Get-DomeniaParkListCount $Run 'StorePending')+' enregistrement(s) à confirmer.')
                # At most the bounded campaign slots are inspected; no fleet scan and no remote work here.
                $current=[Collections.Generic.List[string]]::new()
                foreach($pending in @($Run.Pending.Values)){
                    $target=Get-DomeniaMemberValue $pending 'Target'
                    if($null -eq $target){continue}
                    $snapshot=Get-DomeniaParkReadProgressSnapshot $pending
                    $current.Add([string]$target.Computer+' : '+[string]$snapshot.RowsRead+' étape(s) terminée(s)')
                    if($current.Count -ge 8){break}
                }
                if($current.Count){$parts.Add('En cours : '+($current.ToArray() -join ' ; ')+'.')}
            }
        }
        $sources=Get-DomeniaCampaignSourceSummary (Get-DomeniaMemberValue $Run 'Sources')
        if($sources){$parts.Add('Charge adaptée : '+$sources+'.')}
        $retried=[int](Get-DomeniaMember $Run 'Retried' 0);$waitingRetry=Get-DomeniaParkListCount $Run 'Retry';$exhausted=[int](Get-DomeniaMember $Run 'RetryExhausted' 0);$attempts=[int](Get-DomeniaMember $Run 'RetryMaxAttempts' 3)
        if(($retried -gt 0) -or ($exhausted -gt 0)){$parts.Add([string]$retried+' nouvel(s) essai(s) après incident transitoire'+$(if($waitingRetry){', '+[string]$waitingRetry+' en attente'}else{''})+$(if($exhausted){' ; '+[string]$exhausted+' poste(s) sans réponse après '+[string]$attempts+' essai(s)'}else{''})+'.')}
        $skipped=[int](Get-DomeniaMember $Run 'CapabilitySkipped' 0)
        if($skipped -gt 0){$parts.Add([string]$skipped+' sonde(s) non relue(s) : classe WMI absente lors dʼun relevé récent.')}
        $cimSkipped=[int](Get-DomeniaMember $Run 'CimSkipped' 0)+[int](Get-DomeniaMember $Run 'SkippedTargets' 0)
        if($cimSkipped -gt 0){$parts.Add([string]$cimSkipped+' poste(s) sans lecture WMI : refus ou inaccessibilité mémorisés pour un temps limité.')}
        $avoided=[long](Get-DomeniaMember $Run 'CimAvoided' 0);$executed=[long](Get-DomeniaMember $Run 'CimExecuted' 0)
        if($avoided -gt 0){$parts.Add('Requêtes WMI : '+[string]$executed+' envoyées, '+[string]$avoided+' évitées par regroupement.')}
        $note=[string](Get-DomeniaMember $Run 'CampaignNote' '')
        if($note){$parts.Add($note)}
    }catch{try{Write-AppLog ('Détail du relevé non calculé : '+$_.Exception.Message) 'WARN'}catch{Write-DomeniaSwallowed 'Park' 'Get-DomeniaParkRunDetailText' $_}}
    return ($parts.ToArray() -join ' ')
}
function Get-DomeniaParkVerifyButtonText {
    # UI-23: the main part of the button names the reading it runs (the last one chosen in this session).
    # Point 60 (W08): it also names the scope chosen beside the results when that scope is the selected rows.
    $selected=((Get-DomeniaResultScopeMode) -eq 'Selected')
    $entry=@(Get-DomeniaParkVerifyModes|Where-Object{$_.Mode -eq [string]$script:ParkDefaultMode})
    if($entry.Count){return $(if($selected){'Vérifier la sélection : '}else{'Vérifier : '})+[string]$entry[0].Label}
    return $(if($selected){'Vérifier la sélection'}else{'Vérifier la liste'})
}
function Set-DomeniaParkControlVisible {
    param([string]$Name,[bool]$Visible)
    $control=Get-DomeniaControl $Name
    if($null -eq $control){return}
    $wanted=if($Visible){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
    if($control.Visibility -ne $wanted){$control.Visibility=$wanted}
}
function Update-DomeniaParkControls {
    # UI-23 / UX-12 / FI-18 / FO-18: the single « Vérifier la liste ▾ » button of Rechercher (it becomes « Arrêter
    # (12/48) » while its survey runs), the thin bar and the short count of that survey, the three outcome pills at the
    # end of a ping (CO-19), the bar of a multiple selection, and the state and Arrêter of the open workstation.
    # Nothing here starts a survey. A display refresh never breaks the accounting of a survey: an error is logged.
    try{
        $list=Get-DomeniaParkRun -Slot 'List'
        $listRunning=($null -ne $list -and -not [bool]$list.Completed)
        $listResults=($null -ne $list -and [string]$list.ScopeKind -in @('Results','Selection'))
        # The scope of the lists also runs the perimeter surveys of a board or a query: « Vérifier la liste » shows and
        # stops them as its own. An OU refresh keeps its Arrêter beside its refresh buttons: the button waits for it and
        # the short count says why.
        $listOwn=(Test-DomeniaParkListStoppable $list)
        $listApproved=($listOwn -and [bool]$list.Approved)
        # A finished survey stays shown (count and pills) for the list it measured, not after a new search; a
        # perimeter survey only while it runs.
        $listShown=($null -ne $list -and [long]$list.Epoch -eq [long]$script:SessionEpoch -and ($listRunning -or ($listResults -and [bool]$list.Approved -and [long]$list.Generation -eq [long]$script:GlobalSearchGeneration)))
        $grid=Get-DomeniaControl 'DgObjects'
        $ready=($null -ne $grid -and [bool]$grid.IsEnabled)
        $available=($ready -and [bool]$script:SearchListHasMachine -and (-not [bool]$script:ListSurveyBlocked) -and (-not [bool]$script:DemoMode))
        $total=0
        if($null -ne $list){$total=@($list.Targets).Count;if(-not $total){$total=[int]$list.Requested}}
        $verify=Get-DomeniaControl 'BtnParkVerify'
        if($null -ne $verify){
            if($listApproved){
                $verify.Content=$(if([bool]$list.Stopping){'Arrêt en cours…'}else{'Arrêter ('+[string]$list.Done+'/'+[string]$total+')'})
                $verify.IsEnabled=((-not [bool]$list.Stopping) -and (-not [bool]$script:DemoMode))
            }elseif($listOwn){
                # Prepared or waiting for its confirmation: the button withdraws it, nothing has been sent yet.
                $verify.Content=$(if($listResults){'Annuler la vérification'}else{'Annuler le relevé'})
                $verify.IsEnabled=((-not [bool]$list.Stopping) -and (-not [bool]$script:DemoMode))
            }else{
                $verify.Content=Get-DomeniaParkVerifyButtonText
                $verify.IsEnabled=($available -and -not $listRunning)
            }
        }
        $menu=Get-DomeniaControl 'BtnParkVerifyMenu'
        if($null -ne $menu){$menu.IsEnabled=($available -and -not $listRunning)}
        $modeReady=($available -and -not $listRunning)
        foreach($modeName in @('BtnParkModePing','BtnParkModeConsole','BtnParkModeAnalyse','BtnParkModeComplet','BtnParkRetryUnaddressed')){
            $modeButton=Get-DomeniaControl $modeName
            if($null -ne $modeButton){$modeButton.IsEnabled=$modeReady}
        }
        # UX-12: thin bar and short count of the survey of the list.
        $bar=Get-DomeniaControl 'PbParkProgress'
        if($null -ne $bar){$bar.Value=$(if($total -gt 0 -and $null -ne $list){[Math]::Min(100.0,100.0*[double]$list.Done/[double]$total)}else{0.0})}
        Set-DomeniaParkControlVisible 'PbParkProgress' ($listShown -and $listRunning -and [bool]$list.Approved)
        Set-DomeniaParkControlVisible 'UxParkProgress' $listShown
        Set-DomeniaParkControlVisible 'LblLiveState' (-not $listShown)
        if($listShown){
            # A widget collection first checks the stored measurements (Planning): its short text says so.
            $short=if([bool]$list.Loading){'Préparation du relevé…'}elseif($listRunning -and [bool](Get-DomeniaMember $list 'Planning' $false)){[string]$list.ShortText}elseif($listRunning -and -not [bool]$list.Approved){'Confirmation en attente · '+[string]$total+' '+$(if($total -gt 1){'postes'}else{'poste'})}else{[string]$list.ShortText}
            # A perimeter survey names what it reads; an OU refresh says that it is stopped from its own buttons.
            if(-not $listResults){
                $what=$(if([string]$list.RefreshOperationId){'Actualisation'}else{'Relevé'})+$(if([string]$list.ScopeLabel){' de '+[string]$list.ScopeLabel}else{' du périmètre'})
                if([string]$list.RefreshOperationId){$short=$what+' · '+$short+' · arrêt avec lʼactualisation'}else{$short=$what+' · '+$short}
            }
            [void](Set-DomeniaControlText 'LblParkProgress' $short)
        }
        Update-DomeniaParkOutcomePills -Run $list -Shown ($listShown -and $listResults)
        Update-DomeniaParkSelectionBar -ListRunning $listRunning
        # FI-18: the survey of the open workstation, beside the buttons of its board.
        # A finished survey is shown only beside the board of the workstation it read; a running one stays shown (and
        # stoppable) on any workstation, named when it reads another one.
        $computer=Get-DomeniaParkRun -Slot 'Computer'
        $computerRunning=($null -ne $computer -and -not [bool]$computer.Completed)
        $sameComputer=Test-DomeniaParkRunOnOpenComputer $computer
        $computerShown=($null -ne $computer -and [long]$computer.Epoch -eq [long]$script:SessionEpoch -and ($computerRunning -or ([bool]$computer.Approved -and $sameComputer)))
        Set-DomeniaParkControlVisible 'UxComputerParkRun' $computerShown
        if($computerShown){
            $text=if([bool]$computer.Loading){'Préparation du relevé…'}elseif($computerRunning -and [bool](Get-DomeniaMember $computer 'Planning' $false)){[string]$computer.ShortText}elseif(-not [bool]$computer.Approved){'Confirmation en attente'}else{[string]$computer.ShortText}
            if(-not $sameComputer -and [string]$computer.ScopeLabel){$text=[string]$computer.ScopeLabel+' · '+$text}
            [void](Set-DomeniaControlText 'LblComputerParkStatus' $text)
        }
        $stop=Get-DomeniaControl 'BtnComputerParkStop'
        if($null -ne $stop){$stop.IsEnabled=($null -ne $computer -and -not [bool]$computer.Completed -and -not [bool]$computer.Stopping)}
    }catch{try{Write-AppLog ('Commandes du relevé non actualisées : '+$_.Exception.Message) 'WARN'}catch{Write-DomeniaSwallowed 'Park' 'Update-DomeniaParkControls' $_}}
    # Point 20: when the survey of the lists starts or ends, the resume area of the collection settings follows (the
    # plan file is read on these transitions only), whatever happened to the controls above.
    try{
        $listActive=Test-DomeniaParkRunActive -Slot 'List'
        if($listActive -ne [bool]$script:DomeniaParkRunningShown){$script:DomeniaParkRunningShown=$listActive;Update-DomeniaCampaignResumeUi}
    }catch{try{Write-AppLog ('Zone de reprise du relevé non actualisée : '+$_.Exception.Message) 'WARN'}catch{Write-DomeniaSwallowed 'Park' 'Update-DomeniaParkControls' $_}}
}
function Test-DomeniaParkRunOnOpenComputer {
    # FI-18: the survey of the Computer scope reads the workstation open in Poste (same DN, same GUID when both are known).
    param($Run)
    if($null -eq $Run -or $null -eq $script:SelectedObject -or [string]$script:SelectedObject.Type -ne 'Machine'){return $false}
    $dn=[string]$script:SelectedObject.DN
    if(-not $dn -or [string]$Run.TargetDn -ine $dn){return $false}
    $guid=[string](Get-DomeniaMemberValue (Get-DomeniaMemberValue $script:SelectedObject 'Safety') 'Guid')
    return (-not $guid -or -not [string]$Run.TargetGuid -or [string]$Run.TargetGuid -ieq $guid)
}
function Update-DomeniaParkOutcomePills {
    # CO-19: at the end of a ping of the list, three pills (en ligne, sans réponse, erreurs) that filter the list by
    # presence. The presence filter applies to an OU list; a global search is never filtered locally (D031).
    param($Run,[bool]$Shown)
    $show=($Shown -and $null -ne $Run -and [bool]$Run.Completed -and [bool]$Run.Approved -and -not [bool]$Run.WmiOnly)
    Set-DomeniaParkControlVisible 'PnlParkOutcome' $show
    if(-not $show){return}
    $filterable=((Get-DomeniaSearchMode) -ne 'Global')
    foreach($pill in @(@('BtnParkOutcomeOnline',[int]$Run.Online,'en ligne','en ligne'),@('BtnParkOutcomeNoReply',[int]$Run.NoReply,'sans réponse','sans réponse'),@('BtnParkOutcomeError',[int]$Run.Errors,'erreur','erreurs'))){
        $button=Get-DomeniaControl $pill[0]
        if($null -eq $button){continue}
        $text=[string]$pill[1]+' '+$(if([int]$pill[1] -gt 1){[string]$pill[3]}else{[string]$pill[2]})
        $label=$null;try{$label=@($button.Content.Children)[1]}catch{$label=$null}
        if($label -is [Windows.Controls.TextBlock]){$label.Text=$text}else{$button.Content=$text}
        $button.IsEnabled=($filterable -and [int]$pill[1] -gt 0)
    }
}
function Set-DomeniaParkOutcomeFilter {
    # CO-19: a pill sets the presence filter of the list; a second click on the same pill removes it. Local filter
    # of the loaded rows only: no network, no new search.
    param([ValidateSet('Online','NoReply','Error')][string]$Outcome)
    $label=Get-DomeniaPresenceStateLabel $Outcome
    $wanted=if([string]$script:CurrentPresenceFilter -ceq $label){'Tous'}else{$label}
    $box=Get-DomeniaControl 'CmbPresenceFilter'
    if($null -ne $box){foreach($item in @($box.Items)){if([string]$item.Content -ceq $wanted){$box.SelectedItem=$item;break}}}
    if([string]$script:CurrentPresenceFilter -cne $wanted){$script:CurrentPresenceFilter=$wanted;Apply-DomeniaPresenceFilter}
}
function Get-DomeniaParkSelectionTargets {
    # FO-18: the selected workstations of the list, with their AD identity (DN and GUID); a row without them is counted.
    # Point 60 (W08): the rows come from the 'Selected' plan of the list, the one the export of the selection uses:
    # selected rows still shown, in the displayed order, each once. Plan: its statement for an empty selection.
    $grid=Get-DomeniaControl 'DgObjects';$visible=@()
    if($null -ne $grid){$visible=@($grid.Items)}
    $plan=Get-DomeniaSearchSelectionPlan -VisibleRows $visible -SelectedRows @(Get-DomeniaSelectedGridRows) -Mode Selected
    $rows=@($plan.Rows|Where-Object{($null -ne $_) -and ([string]$_.Type -eq 'Machine')})
    $targets=@(foreach($row in $rows){if(([string]$row.DN) -and ([string]$row.Guid)){[pscustomobject]@{name=[string]$row.Name;distinguished_name=[string]$row.DN;object_guid=[string]$row.Guid}}})
    return [pscustomobject]@{Rows=$rows;Targets=$targets;Skipped=($rows.Count-$targets.Count);Plan=$plan}
}
function Update-DomeniaParkSelectionBar {
    # FO-18: from two selected rows, a bar replaces the selection line: « 3 postes sélectionnés : Pinger · Qui est
    # connecté ? · Copier · Exporter ». The surveys of the selection follow the same confirmation and ceiling.
    param([bool]$ListRunning=$false)
    $grid=Get-DomeniaControl 'DgObjects'
    $selected=@();if($null -ne $grid){$selected=@(Get-DomeniaSelectedGridRows)}
    $show=($selected.Count -ge 2)
    Set-DomeniaParkControlVisible 'UxSelectionBar' $show
    Set-DomeniaParkControlVisible 'LblSelectionReadState' (-not $show)
    if(-not $show){return}
    $machines=0;foreach($row in $selected){if([string]$row.Type -eq 'Machine'){$machines++}}
    # Point 60 (W08): the same statement of the selection as the scope announced before an export or a survey.
    [void](Set-DomeniaControlText 'LblSelectionBar' ((Get-DomeniaSearchSelectionText -SelectedCount $selected.Count -MachineCount $machines)+' :'))
    $survey=(($machines -gt 0) -and (-not $ListRunning) -and [bool]$grid.IsEnabled -and (-not [bool]$script:ListSurveyBlocked) -and (-not [bool]$script:DemoMode))
    foreach($name in @('BtnSelectionPing','BtnSelectionConsole')){$button=Get-DomeniaControl $name;if($null -ne $button){$button.IsEnabled=$survey}}
}
function Start-DomeniaParkSelectionSurvey {
    # FO-18: ping, console reading or analysis of the selected workstations only, with the confirmation and the ceiling
    # of the list. Point 60 (W08): « Vérifier la liste ▾ » runs it too when the scope chosen beside the results is the
    # selected rows.
    param([ValidateSet('Ping','Console','Analyse')][string]$Mode)
    $selection=Get-DomeniaParkSelectionTargets
    if(-not $selection.Rows.Count){Set-Status $(if([int]$selection.Plan.Count -gt 0){'Aucun poste dans la sélection.'}else{[string]$selection.Plan.Label}) 'WARN';return}
    if($Mode -eq 'Analyse'){Start-DomeniaParkAnalysis -Selection -ScopeTargets @($selection.Targets) -SkippedTargets ([int]$selection.Skipped);return}
    Start-DomeniaOnlinePark -Selection -ScopeTargets @($selection.Targets) -SkippedTargets ([int]$selection.Skipped) -PingOnly:($Mode -eq 'Ping') -PingBeforeWmi:($Mode -eq 'Console') -Inventory:($Mode -eq 'Console')
}
function Invoke-DomeniaParkVerify {
    # UI-23: the main part of « Vérifier la liste ▾ » stops the running survey of the list, runs the reading chosen
    # last in this session, or opens the choices when none was made. -Mode runs one reading and remembers it for the
    # session only (never saved).
    param([AllowEmptyString()][string]$Mode='',$Anchor=$null)
    $list=Get-DomeniaParkRun -Slot 'List'
    if(-not $Mode -and (Test-DomeniaParkListStoppable $list)){Stop-DomeniaOnlinePark -RunId ([string]$list.Id);return}
    if(-not $Mode){$Mode=[string]$script:ParkDefaultMode}
    if(-not $Mode){Open-DomeniaParkVerifyMenu -Anchor $Anchor;return}
    if($Mode -notin @('Ping','Console','Analyse')){Set-Status ('Vérification inconnue : '+$Mode) 'WARN';return}
    $script:ParkDefaultMode=$Mode
    # Point 60 (W08): the scope chosen beside the results decides what is read: the list as shown after its filters,
    # or the selected rows only (same confirmation and ceiling as the bar of a multiple selection).
    if((Get-DomeniaResultScopeMode) -eq 'Selected'){Start-DomeniaParkSelectionSurvey -Mode $Mode;Update-DomeniaParkControls;return}
    switch($Mode){
        'Ping' {Start-DomeniaOnlinePark -DisplayedResults -PingOnly}
        'Console' {Start-DomeniaOnlinePark -DisplayedResults -PingBeforeWmi -Inventory}
        'Analyse' {Start-DomeniaParkAnalysis}
    }
    Update-DomeniaParkControls
}
function Open-DomeniaParkVerifyMenu {
    # UI-23: the three graduated readings, the current default marked. A choice runs at once (with its confirmation).
    param($Anchor=$null)
    if($null -eq $Anchor){$Anchor=Get-DomeniaControl 'BtnParkVerifyMenu'}
    if($null -eq $Anchor){return}
    $menu=New-Object System.Windows.Controls.ContextMenu
    foreach($mode in @(Get-DomeniaParkVerifyModes)){
        $item=New-Object System.Windows.Controls.MenuItem
        $item.Header=[string]$mode.Label;$item.ToolTip=[string]$mode.Detail;$item.Tag=[string]$mode.Mode
        $item.IsChecked=([string]$mode.Mode -eq [string]$script:ParkDefaultMode)
        [Windows.Automation.AutomationProperties]::SetHelpText($item,[string]$mode.Detail)
        $item.Add_Click({param($sender,$e) try{Invoke-DomeniaParkVerify -Mode ([string]$sender.Tag)}catch{[void](Show-DomeniaOperationError -Operation 'Vérifier la liste' -ErrorRecordOrException $_)}})
        [void]$menu.Items.Add($item)
    }
    $menu.PlacementTarget=$Anchor
    $menu.Placement=[Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen=$true
}
function Start-DomeniaOnlinePark {
    # -PingOnly (decision David 2026-10-07): ping of the listed workstations only, no console reading.
    # -ScopeTargets: explicit workstations (the selected one for the queries of its board). -Inventory adds the light
    # WMI reading (Analyser la liste, decision David 2026-10-08). The whole domain is still refused.
    # -Selection (FO-18): the ScopeTargets are the selected rows of the list: same confirmation and same ceiling.
    # -Slot (FI-18): 'List' or 'Computer'; without it the scope follows the request (Get-DomeniaParkRunSlot).
    # Widget collections (decision David 2026-10-14): -NoConsole reads no console user, -ReuseMaxAgeDays collects only
    # what is missing (the stored measurements of each workstation are checked before any read by
    # Invoke-DomeniaParkPlanStep and an answered workstation is never contacted; the workshop's collection of the
    # missing information of a recipe uses it too), -WidgetBoard/-WidgetIds name the
    # widgets that show the progress of the run and -Preapproved (an added widget: the add click is the gesture)
    # starts without the confirmation up to the limit of Get-DomeniaWidgetCollectAdmission. Every widget collection
    # keeps the ceiling of a survey (SE-05), counted on the workstations left to read.
    param([switch]$DisplayedResults,[switch]$Selection,[switch]$PingOnly,[switch]$WmiOnly,[switch]$PingBeforeWmi,[switch]$IncludeUnaddressed,[switch]$OnlyUnaddressed,[switch]$Inventory,[object[]]$ScopeTargets=$null,[string]$ScopeLabel='',[object[]]$Probes=$null,[switch]$ForceRefresh,[string]$RefreshOperationId='',[switch]$PassThru,[ValidateSet('','List','Computer')][string]$Slot='',[int]$SkippedTargets=0,[switch]$NoConsole,[int]$ReuseMaxAgeDays=0,[switch]$Preapproved,[string]$WidgetBoard='',[string[]]$WidgetIds=@(),[switch]$ChainApproved,[string]$ChainNote='')
    $started=$false;$r=$null
    try{
        if($PingOnly -and $WmiOnly){throw 'Choisissez Ping ou WMI, pas les deux modes exclusifs.'}
        if($PingOnly -and $PingBeforeWmi){throw 'Le ping seul ne prépare pas une lecture WMI.'}
        if($Selection -and $null -eq $ScopeTargets){throw 'Sélection sans poste : choisissez des lignes de la liste.'}
        # Decision David 2026-10-05: whole-park detection removed; only the displayed, filtered rows are read.
        if(-not $DisplayedResults -and $null -eq $ScopeTargets){throw 'relevé de tout le parc retiré. Filtrez la liste dans Rechercher puis Vérifier la liste.'}
        # UX-33: a work view listed over the whole domain is read-only: no ping, detection or analysis of its rows.
        if(($null -eq $ScopeTargets -or $Selection) -and [bool]$script:ListSurveyBlocked){throw 'vue sur tout le domaine : aucun relevé des postes. Choisissez une OU puis relancez la vue.'}
        if($script:DemoMode){throw 'Relevé distant indisponible en démonstration.'}
        $openDn='';if($null -ne $script:SelectedObject -and [string]$script:SelectedObject.Type -eq 'Machine'){$openDn=[string]$script:SelectedObject.DN}
        $slotName=Get-DomeniaParkRunSlot -Slot $Slot -DisplayedResults ([bool]($DisplayedResults -or $Selection)) -Targets @($ScopeTargets) -OpenComputerDn $openDn
        $existing=Get-DomeniaParkRun -Slot $slotName
        if($null -ne $existing -and -not [bool]$existing.Completed){
            if($slotName -eq 'Computer'){
                if((Test-DomeniaParkRunOnOpenComputer $existing) -or -not [string]$existing.ScopeLabel){throw 'Un relevé de ce poste est déjà en cours : arrêtez-le ou attendez sa fin.'}
                throw ('Un relevé du poste '+[string]$existing.ScopeLabel+' est déjà en cours : arrêtez-le ou attendez sa fin.')
            }
            if([string]$existing.ScopeKind -in @('Results','Selection')){throw 'Un relevé de la liste est déjà en cours : arrêtez-le ou attendez sa fin.'}
            throw ('Un relevé des postes'+$(if([string]$existing.ScopeLabel){' de '+[string]$existing.ScopeLabel}else{''})+' est déjà en cours : arrêtez-le ou attendez sa fin.')
        }
        if(@($script:AsyncJobs.Values|Where-Object{$_.OperationId -in @('StoragePurge','IndexBuild','LegacyMigration')}).Count){throw 'Attendez la fin de la maintenance locale.'}
        # Pending local saves of a survey of the other scope are expected; otherwise wait for their confirmation.
        if(-not (Test-DomeniaParkRunActive) -and ((Get-DomeniaPersistenceState).Pending -gt 0 -or ($null -ne $script:Persistence -and $script:Persistence.LinkBusy))){throw 'Attendez la confirmation des enregistrements locaux avant un nouveau relevé.'}
        if(-not $script:DatabaseScopedPath){throw 'Aucune base autonome active.'}
        # Points 32 and 35: no new collection during a base maintenance, a suspended writer or a nearly full disk.
        $storageRefusal=Get-DomeniaStorageCollectionRefusal;if($storageRefusal){throw $storageRefusal}
        [void](Initialize-DomeniaWinSqliteNative)
        $targets=@();$excluded=@();$skipped=[Math]::Max(0,$SkippedTargets);$scopeKind='Scope';$label=[string]$ScopeLabel;$subtree=$false;$listLimit=0
        if($null -ne $ScopeTargets){
            $all=@($ScopeTargets|Where-Object{$null -ne $_})
            $targets=@($all|Where-Object{$_.distinguished_name -and $_.object_guid})
            $skipped+=($all.Count-$targets.Count)
            # Point 48: the exact preview names each row left out, with its reason.
            $excluded=@(foreach($row in $all){if(-not ($row.distinguished_name -and $row.object_guid)){[pscustomobject]@{Name=[string]$row.name;DN=[string]$row.distinguished_name;Reason='Identité incomplète (DN ou GUID absent) : relisez la fiche'}}})
            if($Selection){
                $scopeKind='Selection';$label='la sélection'
                if((-not $targets.Count) -and ($skipped -gt 0)){throw 'Postes sélectionnés sans identifiant AD connu : relancez la recherche puis sélectionnez-les à nouveau.'}
                # SE-05: the ceiling of the list applies to its selection; a selection of every displayed workstation
                # (Ctrl+A) is the list itself: an unfiltered domain root or a global search without a term is refused.
                $context=Get-DomeniaParkListContext
                $chosen=@{};foreach($target in $targets){$chosen[([string]$target.distinguished_name).ToLowerInvariant()]=$true}
                $shown=@((Get-DomeniaParkDisplayedTargets).Targets)
                $covers=($shown.Count -gt 0 -and @($shown|Where-Object{-not $chosen.ContainsKey(([string]$_.distinguished_name).ToLowerInvariant())}).Count -eq 0)
                $admission=Test-DomeniaParkTargetAdmission -Count $targets.Count -Maximum (Get-DomeniaParkMaxTargets) -ScopeDn $context.ScopeDn -BaseDn $context.BaseDn -HasFilter ([bool]$context.HasFilter) -Global ([bool]$context.Global) -HasSearchTerm ([bool]$context.HasSearchTerm) -Selection $true -SelectionCoversList $covers
                if(-not [bool]$admission.Allowed){throw ([string]$admission.Reason)}
            }elseif(-not $targets.Count){throw 'Poste sélectionné sans DN ni GUID connu : relisez sa fiche.'}
            $DisplayedResults=[switch]$true
        }
        elseif($DisplayedResults){
            $displayed=Get-DomeniaParkDisplayedTargets
            $targets=@($displayed.Targets)
            # UX-24: workstations without an AD identity are left out and the confirmation says so; point 48: the exact
            # preview names each of them with its reason.
            $skipped+=[int]$displayed.Skipped
            $excluded=@($displayed.Excluded)
            # SE-05: ceiling, domain root without any other filter, global search without a term.
            $context=Get-DomeniaParkListContext
            $admission=Test-DomeniaParkTargetAdmission -Count $targets.Count -Maximum (Get-DomeniaParkMaxTargets) -ScopeDn $context.ScopeDn -BaseDn $context.BaseDn -HasFilter ([bool]$context.HasFilter) -Global ([bool]$context.Global) -HasSearchTerm ([bool]$context.HasSearchTerm)
            if(-not [bool]$admission.Allowed){throw ([string]$admission.Reason)}
            $scopeKind='Results';$label=[string]$context.Label;$subtree=[bool]$context.Subtree;$listLimit=[int]$context.ListLimit
        }
        # A forced refresh reads everything again; otherwise a reuse age lets the run set aside the answered
        # workstations first. Without it every workstation of a widget collection is read: the ceiling applies to the
        # population here, before any local read (else to the workstations left to read, Request-DomeniaParkAdmission).
        $reuseDays=$(if($ForceRefresh){0}else{[Math]::Max(0,[Math]::Min(3650,$ReuseMaxAgeDays))})
        $widgetBoard=[string]$WidgetBoard
        if($widgetBoard -and ($reuseDays -le 0)){
            $widgetAdmission=Get-DomeniaWidgetCollectAdmission -TargetCount $targets.Count -Maximum (Get-DomeniaWidgetMaxTargets)
            if(-not [bool]$widgetAdmission.Allowed){throw ([string]$widgetAdmission.Reason)}
        }
        $concurrency=([Math]::Max(1,[Math]::Min(8,[int](Get-DomeniaSetting 'Collection.Concurrency' '4'))))
        $waveLimit=$(if((-not [bool]$PingOnly) -and (-not $widgetBoard) -and (@($targets).Count -gt 200)){200}else{0})
        $r=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Slot=$slotName;Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;Targets=@();Requested=$targets.Count;Next=0;Pending=@{};Concurrency=$concurrency;WaveLimit=$waveLimit;WaveContacts=0;CacheMinutes=([Math]::Max(0,[Math]::Min(1440,[int](Get-DomeniaSetting 'Collection.CacheMinutes' '15'))));CachedMeasurements=0;Done=0;Online=0;NoReply=0;Errors=0;Unchecked=0;Reused=0;Changed=0;Failed=0;Stopping=$false;Completed=$false;Loading=$true;Approved=$false;Logged=$false;ObservationReader=(New-DomeniaObservationReader);Timer=$null;StatusText='';ShortText='';Generation=[long]$script:GlobalSearchGeneration;PingOnly=[bool]$PingOnly;WmiOnly=[bool]$WmiOnly;AccountGeneration=[long]$script:DomeniaAccountGeneration;StorePending=@{};Inventory=[bool]$Inventory;Probes=@(Add-DomeniaRemoteProbeDefinitionHash $Probes);FleetRefresh=$true;ScopeLabel=$label;ScopeKind=$scopeKind;Scope='Results';Skipped=$skipped;Subtree=$subtree;ListLimit=$listLimit;RefreshOperationId=$RefreshOperationId;FailureMessage='';PingJob='';PingQueue=$null;PingBuffer=$null;PingReported=@{};TargetsByKey=@{};PendingRows=@{};TargetDn=$(if($targets.Count -eq 1){[string]$targets[0].distinguished_name}else{''});TargetGuid=$(if($targets.Count -eq 1){[string]$targets[0].object_guid}else{''});InlineRequestId='';GridStale=$false;NoConsole=(([bool]$NoConsole) -and (-not [bool]$PingOnly));ReuseMaxAgeDays=$reuseDays;Preapproved=(([bool]$Preapproved) -and ([bool]$widgetBoard));WidgetBoard=$widgetBoard;WidgetIds=@($WidgetIds|Where-Object{$_});AlreadyFresh=0;Planning=$false;PlanNext=0;ToRead=([Collections.Generic.List[object]]::new())}
        # The preapproval belongs to the gesture of a widget only; ToRead keeps the workstations left to read once a
        # widget collection checked the stored measurements (Invoke-DomeniaParkPlanStep).
        # Points 14 to 20: per-source budgets bounded by the chosen value (the 32 echoes of one batch for the batch
        # ping), deferred and retried targets, durations of the usage profile, measured progress and the durable plan
        # (created on approval). IndexByKey gives the place of a workstation in the plan; PingSourceKeys the budget each
        # echo was admitted on; PingMissing the workstations a batch ping never reported.
        # Decision David 2026-10-19 (ping too slow): one batch ping of 192 echoes at once (was 32), its source budget alike.
        $sourceLimit=$(if([bool]$PingOnly){192}else{$concurrency})
        $retryPolicy=Get-DomeniaCollectionRetrySettings
        $collection=[ordered]@{Sources=(New-DomeniaCampaignSources -MaxLimit $sourceLimit);Deferred=(New-Object 'System.Collections.Generic.List[object]');Retry=(New-Object 'System.Collections.Generic.List[object]')
            Freshness=(Get-DomeniaActiveFreshnessTable);StartedUtc=$null;LastValidatedUtc=$null;HeldSeconds=[double]0;HeldSinceUtc=$null;HeldShownUtc=[datetime]::MinValue;Retried=0;RetryExhausted=0;RetryMaxAttempts=[int]$retryPolicy.MaxAttempts;RetryBaseDelaySeconds=[int]$retryPolicy.BaseDelaySeconds;CapabilitySkipped=0;CimSkipped=0;SkippedTargets=0
            CimExecuted=[long]0;CimAvoided=[long]0;CampaignProgress=$null;CampaignNote='';CampaignSavedUtc=[datetime]::MinValue;CampaignDirty=$false;StopReason='';IndexByKey=@{};PingSourceKeys=@{};PingMissing=@{}}
        foreach($field in $collection.Keys){$r|Add-Member -NotePropertyName $field -NotePropertyValue $collection[$field] -Force}
        $runs=Get-DomeniaParkRuns;$runs[$slotName]=$r
        $started=$true
        if($ForceRefresh){$r.CacheMinutes=0}
        # A list survey does not contact a workstation whose stored measure is still inside the profile window.
        if((-not $ForceRefresh) -and (-not $widgetBoard) -and ([int]$r.ReuseMaxAgeDays -le 0) -and ([int]$r.CacheMinutes -gt 0)){$r.ReuseMaxAgeDays=1}
        # Point 48: what was asked and what was left out before the local read, for the exact preview.
        $r|Add-Member -NotePropertyName RequestedTargets -NotePropertyValue @($targets)
        # Decision David 2026-10-19: « Tout actualiser » and WMI ping every workstation once, then read WMI on those that
        # answered only. The WMI step was confirmed with the ping (ChainApproved); the ping confirmation says so (ChainNote).
        $r|Add-Member -NotePropertyName ChainApproved -NotePropertyValue ([bool]$ChainApproved -and [bool]$RefreshOperationId)
        $r|Add-Member -NotePropertyName PingBeforeWmi -NotePropertyValue ([bool]$PingBeforeWmi)
        $r|Add-Member -NotePropertyName IncludeUnaddressed -NotePropertyValue (([bool]$IncludeUnaddressed) -or ([string]$slotName -eq 'Computer') -or (@($targets).Count -le 1))
        $r|Add-Member -NotePropertyName OnlyUnaddressed -NotePropertyValue ([bool]$OnlyUnaddressed)
        $r|Add-Member -NotePropertyName ChainNote -NotePropertyValue ([string]$ChainNote)
        $r|Add-Member -NotePropertyName PingOnline -NotePropertyValue @{}
        $r|Add-Member -NotePropertyName PreviewExcluded -NotePropertyValue @($excluded)
        $state=[pscustomobject]@{RunId=$r.Id;Slot=$r.Slot;Epoch=$r.Epoch;Path=$r.Path}
        # Read only the observation families used by this collection mode. No WMI payload is parsed for a ping refresh.
        $families=$null
        if($r.PingOnly){$families=@('Presence')}elseif(([bool]$r.WmiOnly) -and ([bool]$r.NoConsole)){$families=@(if($r.Inventory){'Inventory'})+@($r.Probes|ForEach-Object{'Probe:'+([string]$_.Id)})}elseif($r.WmiOnly){$families=@('Console','Inventory')+@($r.Probes|ForEach-Object{'Probe:'+([string]$_.Id)})}
        $job=Start-UiTask -Name 'Preparer le releve du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{Action='ParkTargets';Path=$r.Path;Scope=$r.Scope;Targets=$targets;ObservationFamilies=$families}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkTargets' -ErrorHandler 'Fail-DomeniaParkTargets' -NonCancellable -TimeoutSeconds 60 -TaskClass 'Explicit'
        if(-not $job){throw 'Lecture du parc non admise.'}
        [void](Set-DomeniaControlText 'LblParkStatus' 'Lecture des postes et des sessions conservées en cache…')
    }catch{
        if($started -and $null -ne $r -and $r.Loading){$r.Completed=$true;$r.FailureMessage=$_.Exception.Message}
        Set-Status ('Relevé impossible : '+$_.Exception.Message) 'WARN'
    }
    Update-DomeniaParkControls
    if($PassThru){if($started -and $null -ne $r -and -not $r.Completed){return [string]$r.Id};return ''}
}
function Start-DomeniaParkAnalysis {
    # Analyser la liste (decision David 2026-10-08): ping, console user and light WMI reading of the displayed
    # workstations, plus the WMI queries of the dashboard widgets. Read only, confirmed with the count first.
    # Point 60 / FO-18: -Selection analyses only the selected workstations given in -ScopeTargets, with the
    # confirmation and the ceiling of a selection of the list.
    param([switch]$Selection,[object[]]$ScopeTargets=$null,[int]$SkippedTargets=0)
    $probes=$null
    try{
        $ids=@(Get-DomeniaBoardProbeIds)
        if($ids.Count){$probes=@(ConvertTo-DomeniaProbePayload -Ids $ids)}
        # A mass survey stays on a few classes. Process lists, hotfixes and product scans stay on the single-computer inventory.
        $probes=@($probes|Where-Object{$null -ne $_ -and (-not [bool](Get-DomeniaMember $_ 'Slow' $false)) -and [string]$_.Class -notmatch '^(?i:Win32_Process|Win32_QuickFixEngineering|Win32_Product)$' -and [string]$_.Id -notmatch '(?i)process|hotfix|evt\.'})
    }catch{Set-Status ('Requêtes des widgets ignorées : '+$_.Exception.Message) 'WARN';$probes=$null}
    if($Selection){Start-DomeniaOnlinePark -Selection -ScopeTargets @($ScopeTargets) -SkippedTargets $SkippedTargets -Inventory -Probes $probes -PingBeforeWmi;return}
    Start-DomeniaOnlinePark -DisplayedResults -Inventory -Probes $probes -PingBeforeWmi
}
function Start-DomeniaUnaddressedSurvey {
    # Hosts with no known address are left out of a normal wave. This button reads only those.
    Start-DomeniaOnlinePark -DisplayedResults -PingBeforeWmi -Inventory -IncludeUnaddressed -OnlyUnaddressed
}
function Start-DomeniaCompleteSurvey {
    # Mass complete read: light inventory plus hotfixes and startup commands. No Win32_Product and no process list.
    $ids=@('soft.hotfixcount','soft.startup','soft.stoppedauto','sec.tpmversion','sec.tpmenabled','hw.bios','hw.serialmissing')
    $probes=$null
    try{$probes=@(ConvertTo-DomeniaProbePayload -Ids $ids)}catch{Set-Status ('Relevé complet sans les sondes lourdes : '+$_.Exception.Message) 'WARN';$probes=$null}
    Start-DomeniaOnlinePark -DisplayedResults -PingBeforeWmi -Inventory -Probes $probes
}
function Complete-DomeniaParkTargets {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId)
    try{
        $packet=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Busy')
        if($null -eq $packet -or $packet.Busy){throw 'Base occupée : aucun poste interrogé.'}
        $r.Loading=$false;$r.Targets=@($packet.Rows|Where-Object{$null -ne $_})
        if($r.Stopping -or -not $r.Targets.Count){$r.Completed=$true;Update-DomeniaParkRunStatus -Run $r;return}
        # Point 48: only the exact targets are contacted. A row the local base set aside, a GUID listed twice (an old
        # and a new DN in the local base) or a row past the limit is never probed; the preview names each of them.
        $requested=@{};foreach($asked in @(Get-DomeniaMember $r 'RequestedTargets' @())){$requested[([string]$asked.distinguished_name).ToLowerInvariant()]=$asked}
        $returned=@{};foreach($target in @($r.Targets)){$returned[([string]$target.Key).ToLowerInvariant()]=$true}
        $excluded=@(Get-DomeniaMember $r 'PreviewExcluded' @())
        foreach($key in @($requested.Keys)){if(-not $returned.ContainsKey([string]$key)){$asked=$requested[$key];$excluded+=@([pscustomobject]@{Name=[string]$asked.name;DN=[string]$asked.distinguished_name;Reason='Écarté par la base locale : nom de poste non valide ou DN en double'})}}
        $candidates=@(foreach($target in @($r.Targets)){$dn=[string]$target.Key;$lower=$dn.ToLowerInvariant();if($requested.ContainsKey($lower)){$dn=[string]$requested[$lower].distinguished_name};[pscustomobject]@{Name=[string]$target.Computer;DN=$dn;Guid=[string]$target.Guid;Type='Machine'}})
        $exact=New-DomeniaCollectivePreview -OperationId 'ParkSweep' -Candidates $candidates -Excluded $excluded -ExpectedType 'Machine'
        $all=@($r.Targets);$keptIndex=@{};foreach($target in @($exact.Targets)){$keptIndex[[int]$target.Index]=$true}
        $kept=New-Object 'System.Collections.Generic.List[object]';$dropped=New-Object 'System.Collections.Generic.List[object]'
        for($i=0;$i -lt $all.Count;$i++){if($keptIndex.ContainsKey($i)){$kept.Add($all[$i])}else{$dropped.Add($all[$i])}}
        $r.Targets=$kept.ToArray();Clear-DomeniaParkTargetBuffers $dropped.ToArray()
        $r|Add-Member -NotePropertyName PreviewExcluded -NotePropertyValue @($exact.Excluded) -Force
        if(-not $r.Targets.Count){throw ('aucun poste exploitable. '+(@($exact.Lines|Where-Object{([string]$_) -match '^\d+ exclue'}) -join ' '))}
        # The index (batch ping, place of each workstation in the durable plan, point 20) follows the exact targets.
        Set-DomeniaParkTargetIndex -Run $r
        # A collection that reads only what is missing (a widget, or the workshop for a recipe) first checks the
        # stored measurements of each workstation, without any network read; its admission then counts the
        # workstations left to read.
        if([int](Get-DomeniaMember $r 'ReuseMaxAgeDays' 0) -gt 0){$r.Planning=$true;Start-DomeniaParkRunTimer -RunId $r.Id -Planning;return}
        Request-DomeniaParkAdmission -Run $r
    }catch{Fail-DomeniaParkTargets $_.Exception.Message $State}
}
function Set-DomeniaParkTargetIndex {
    # TargetsByKey (lowercase DN) for the batch ping and IndexByKey, the place of each workstation in the targets of
    # the run: the durable plan (point 20) marks a workstation validated by that place.
    param($Run)
    $Run.TargetsByKey=@{}
    $index=@{}
    for($i=0;$i -lt @($Run.Targets).Count;$i++){
        $key=([string]$Run.Targets[$i].Key).ToLowerInvariant()
        $Run.TargetsByKey[$key]=$Run.Targets[$i];$index[$key]=$i
    }
    if($null -ne $Run.PSObject.Properties['IndexByKey']){$Run.IndexByKey=$index}
}
function Get-DomeniaParkTargetIndex {
    param($Run,[string]$Key)
    $index=Get-DomeniaMemberValue $Run 'IndexByKey' $null
    $k=([string]$Key).ToLowerInvariant()
    if(($index -is [Collections.IDictionary]) -and $index.ContainsKey($k)){return [int]$index[$k]}
    return -1
}
function Request-DomeniaParkAdmission {
    # UX-24: three lines (which workstations and why the count differs, what is read, how long); the target is the
    # list, the selection or the OU, never the domain; the confirm button carries the count. Asked before any read.
    # Widget collections (decision David 2026-10-14) keep the ceiling of a survey (SE-05) on the workstations left to
    # read; an added widget (Preapproved: the add click is the gesture) starts at once up to the limit of
    # Get-DomeniaWidgetCollectAdmission, and its count is confirmed above it. Refresh and resume always confirm.
    # Collection engine: the text names the usage profile (point 11), the WMI queries saved by grouping (point 13)
    # and the budgets per presumed subnet (points 14, 15 and 18). Outside the collection window of the profile
    # (point 159) a survey starts only on its confirmation, so an added widget asks too. A durable survey says that it
    # replaces the plan of an interrupted campaign (point 20).
    param($Run)
    $r=$Run
    $start=${function:Start-DomeniaParkRunTimer};$stop=${function:Stop-DomeniaOnlinePark};$runId=$r.Id
    $widget=[bool][string](Get-DomeniaMember $r 'WidgetBoard' '')
    $preapproved=[bool](Get-DomeniaMember $r 'Preapproved' $false)
    $fresh=[int](Get-DomeniaMember $r 'AlreadyFresh' 0)
    $directLimit=0;$direct=$false
    if($widget){
        $admission=Get-DomeniaWidgetCollectAdmission -TargetCount $r.Targets.Count -Maximum (Get-DomeniaWidgetMaxTargets)
        if(-not [bool]$admission.Allowed){
            # Nothing was read: the run ends with its reason.
            $r.Completed=$true;$r.FailureMessage=[string]$admission.Reason;if($null -ne $r.Timer){$r.Timer.Stop()}
            Set-Status ('Collecte du widget non lancée : '+[string]$admission.Reason) 'WARN'
            Update-DomeniaParkRunStatus -Run $r
            return
        }
        if($preapproved){$directLimit=[int]$admission.Limit;$direct=[bool]$admission.Direct}
    }
    # The count differs from the request by the workstations without a usable name or in double, and by those whose
    # stored measurement already answers (widget collections, counted apart).
    $ignored=[Math]::Max(0,[int]$r.Requested-$r.Targets.Count-$fresh)
    $noConsole=[bool](Get-DomeniaMember $r 'NoConsole' $false)
    $cimRequested=0;$cimExecuted=0
    if(-not [bool]$r.PingOnly){$cimPlan=Measure-DomeniaCimQueryPlan -ProbeUser (-not $noConsole) -Inventory ([bool]$r.Inventory) -Probes @($r.Probes);$cimRequested=[int]$cimPlan.Requested;$cimExecuted=[int]$cimPlan.Executed}
    $text=New-DomeniaParkConfirmationText -Count $r.Targets.Count -Skipped ([int]$r.Skipped) -Ignored $ignored -ScopeKind ([string]$r.ScopeKind) -ScopeLabel ([string]$r.ScopeLabel) -Subtree ([bool]$r.Subtree) -ListLimit ([int]$r.ListLimit) -PingOnly ([bool]$r.PingOnly) -WmiOnly ([bool]$r.WmiOnly) -Inventory ([bool]$r.Inventory) -ProbeCount (@($r.Probes).Count) -Concurrency ([int]$r.Concurrency) -CacheMinutes ([int]$r.CacheMinutes) -NoConsole $noConsole -ReuseMaxAgeDays ([int](Get-DomeniaMember $r 'ReuseMaxAgeDays' 0)) -AlreadyFresh $fresh -Widget $widget -DirectLimit $directLimit -ProfileLabel ([string](Get-DomeniaMember (Get-DomeniaMemberValue $r 'Freshness') 'Label' '')) -CimRequested $cimRequested -CimExecuted $cimExecuted -SourceBudgets $true
    $notes=New-Object 'System.Collections.Generic.List[string]'
    $windowNote=''
    try{$windowNote=([string](Get-DomeniaCollectionWindowCampaignNote)).Trim()}catch{
        # An unreadable window never lets a survey start on its own: the count is confirmed.
        $direct=$false;Write-AppLog ('Fenêtre de collecte non lue : '+$_.Exception.Message) 'WARN'
    }
    if($windowNote){$notes.Add($windowNote);$direct=$false}
    if(Test-DomeniaCampaignRunDurable $r){$replacement=([string](Get-DomeniaCampaignReplacementNote)).Trim();if($replacement){$notes.Add($replacement)}}
    $message=[string]$text.Message
    $chainNote=([string](Get-DomeniaMember $r 'ChainNote' '')).Trim();if($chainNote){$notes.Insert(0,$chainNote)}
    if($notes.Count){$message+="`r`n"+($notes.ToArray() -join ' ')}
    if($direct){Set-Status ('Collecte du widget lancée : '+[string]$text.Lines[0]+'. '+[string]$text.Lines[1]);& $start $runId;return}
    if([bool](Get-DomeniaMember $r 'ChainApproved' $false)){Set-Status ('Lecture WMI des postes en ligne : '+[string]$text.Lines[0]+'.');& $start $runId;return}
    # Point 48: the exact list of the workstations to read (the ones set aside as already answered are not in it), each
    # row left out with its reason, and a confirmation in proportion: past the threshold the count must be typed.
    $change=if([bool]$r.PingOnly){'ping ICMP'}elseif([bool]$r.WmiOnly){'lecture WMI'}elseif([bool]$r.Inventory){'ping, utilisateur console et relevé WMI léger'}elseif(@($r.Probes).Count){'requêtes WMI des widgets, ping et utilisateur console'}else{'ping puis utilisateur console'}
    $requested=@{};foreach($asked in @(Get-DomeniaMember $r 'RequestedTargets' @())){$requested[([string]$asked.distinguished_name).ToLowerInvariant()]=[string]$asked.distinguished_name}
    $candidates=@(foreach($target in @($r.Targets)){$dn=[string]$target.Key;$lower=$dn.ToLowerInvariant();if($requested.ContainsKey($lower)){$dn=[string]$requested[$lower]};[pscustomobject]@{Name=[string]$target.Computer;DN=$dn;Guid=[string]$target.Guid;Type='Machine'}})
    $preview=New-DomeniaCollectivePreview -OperationId 'ParkSweep' -Candidates $candidates -Excluded @(Get-DomeniaMember $r 'PreviewExcluded' @()) -ExpectedType 'Machine' -Change $change
    # Nothing ticks while the operator decides; the confirmation starts the run timer again.
    if($null -ne $r.Timer){$r.Timer.Stop()}
    Update-DomeniaParkRunStatus -Run $r
    $answers=@(Request-DomeniaInlineConfirmation -Title ([string]$text.Title) -Target ([string]$text.Target) -Message $message -ConfirmText ([string]$text.ConfirmText) -CancelText 'Annuler' -OnConfirm ({& $start $runId}.GetNewClosure()) -OnCancel ({& $stop -RunId $runId}.GetNewClosure()) -Changes @($preview.Lines) -Details ([string]$preview.Details) -DetailsTitle 'Liste exacte des cibles et des exclusions' -TypedConfirmation ([string]$preview.TypedText))
    # UX-12: a request still shown in the page belongs to this survey: stopping the survey withdraws it.
    $request=$null;foreach($answer in $answers){if($null -ne $answer -and $null -ne $answer.PSObject.Properties['Presentation']){$request=$answer}}
    if($null -ne $request -and -not [bool]$request.Answered -and [string]$request.Id){$r.InlineRequestId=[string]$request.Id}
}
function Fail-DomeniaParkTargets {
    param($Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId)
    $r.Completed=$true;$r.Loading=$false;Clear-DomeniaParkTargetBuffers $r.Targets
    $r.FailureMessage=[string]$Message
    [void](Set-DomeniaControlText 'LblParkStatus' ('Relevé non lancé : '+[string]$Message))
    Set-Status ('Relevé non lancé : '+[string]$Message) 'WARN'
    Update-DomeniaParkControls
}
function Start-DomeniaParkRunTimer {
    # -Planning (widget collections): the stored measurements are checked first and nothing is contacted, so the
    # timer runs without the approval; the admission or the confirmation approves the run afterwards.
    param([string]$RunId,[switch]$Planning)
    $r=Get-DomeniaParkRunById $RunId
    if($null -eq $r -or $r.Stopping -or $r.Completed -or $r.Epoch -ne [long]$script:SessionEpoch -or $r.Path -cne [string]$script:DatabaseScopedPath){return}
    if([string]$r.RefreshOperationId -and -not (Test-DomeniaOuRefreshCurrent ([string]$r.RefreshOperationId))){Stop-DomeniaOnlinePark -RunId $RunId;return}
    if(-not $Planning){
        if(([bool]$r.Approved) -and ($null -ne $r.Timer)){return}
        # Start of the confirmed collection, kept from its first approval: the attempt time of its scope clocks
        # (Refresh.UI), never a measure date.
        if(-not [bool]$r.Approved){$r|Add-Member -NotePropertyName ApprovedUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force}
        $r.Approved=$true;$r.InlineRequestId=''
        # Points 17 and 20: the measured progress starts with the approval, and the plan of a durable survey is saved
        # at once (Save-DomeniaCampaignPlan reports its own failure in the status of the survey).
        if($null -ne $r.PSObject.Properties['StartedUtc']){$r.StartedUtc=[datetime]::UtcNow;[void](Save-DomeniaCampaignPlan -Run $r)}
        # UX-12: every target of the run carries its « relevé en cours » marker until its measure is stored.
        Set-DomeniaParkPendingRows -Run $r
    }
    # FI-05: protected heartbeat timer, owned and registered by the factory; it also runs minimized (an approved run).
    # FI-18: one owner per scope, so that the survey of the list and the one of the open workstation run side by side.
    if($null -eq $r.Timer){
        $tick=if($r.Slot -eq 'Computer'){{Invoke-DomeniaParkRunTick -Slot 'Computer'}}else{{Invoke-DomeniaParkRunTick -Slot 'List'}}
        $r.Timer=New-DomeniaTimer -Owner ('Timer:ParkRun:'+$r.Slot) -IntervalMs 250 -RunWhenHidden -Tick $tick
    }
    $r.Timer.Start();Update-DomeniaParkRunStatus -Run $r
}
function Stop-DomeniaOnlinePark {
    # Stops the survey named by -RunId, else the survey of -Slot (the list by default). Measures already received
    # are still stored; nothing is replayed.
    param([string]$RunId='',[ValidateSet('List','Computer')][string]$Slot='List')
    $r=if($RunId){Get-DomeniaParkRunById $RunId}else{Get-DomeniaParkRun -Slot $Slot}
    if($null -eq $r){return}
    # UX-12: a survey still waiting for its confirmation withdraws the request shown in the page (its Annuler runs and
    # stops the survey), so that no « Pinger N postes » stays on screen for a survey already stopped.
    if((-not [bool]$r.Approved) -and [string]$r.InlineRequestId){
        $requestId=[string]$r.InlineRequestId;$r.InlineRequestId=''
        $pending=$null;try{$pending=Get-DomeniaInlinePendingRequest}catch{$pending=$null}
        if($null -ne $pending -and [string](Get-DomeniaMemberValue $pending 'Id') -ceq $requestId){
            try{Complete-DomeniaInlineRequest -Dismiss -Reason 'Relevé annulé avant sa confirmation.'}catch{try{Write-AppLog ('Demande du relevé non retirée : '+$_.Exception.Message) 'WARN'}catch{Write-DomeniaSwallowed 'Park' 'Stop-DomeniaOnlinePark' $_}}
            if([bool]$r.Completed){return}
        }
    }
    $r.Stopping=$true
    try{Submit-DomeniaParkPingResults -Run $r}catch{Write-DomeniaSwallowed 'Park' 'Stop-DomeniaOnlinePark' $_}
    Stop-DomeniaParkPingWorker -Run $r
    if(-not $r.Pending.Count -and -not $r.Loading -and -not (Test-DomeniaParkPingBuffered -Run $r)){
        $save=Get-DomeniaPersistenceState
        if(-not $r.Approved -or ($save.Pending -eq 0 -and $r.StorePending.Count -eq 0) -or $save.Suspended){
            # Echoes of a batch ping never sent are not checked; the durable plan keeps what remains to read.
            if([bool]$r.PingOnly -and [bool]$r.Approved){Close-DomeniaParkPingJobTargets -Run $r}
            $r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()};Close-DomeniaParkCampaign $r
        }
    }
    Update-DomeniaParkRunStatus -Run $r
}
function Close-DomeniaParkCampaign {
    # Point 20: end of a survey for its durable plan: a complete plan disappears, the others keep their remaining
    # workstations for a resume. A failure there never prevents the survey itself from ending.
    param($Run)
    try{Complete-DomeniaCampaignPlan $Run}catch{try{Write-AppLog ('Plan de reprise non mis à jour : '+$_.Exception.Message) 'WARN'}catch{Write-DomeniaSwallowed 'Park' 'Close-DomeniaParkCampaign' $_}}
}
function Set-DomeniaParkStopReason {
    # Point 20: why a survey stopped, for its durable plan. -KeepFirst keeps a reason already given.
    param($Run,[AllowEmptyString()][string]$Reason,[switch]$KeepFirst)
    if(($null -eq $Run) -or ($null -eq $Run.PSObject.Properties['StopReason'])){return}
    if($KeepFirst -and [string]$Run.StopReason){return}
    $Run.StopReason=[string]$Reason
}
function Get-DomeniaParkListCount {
    # Count of a list held by the run (Deferred, Retry); 0 for a run created without these lists.
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
    # so that a suspended Dispatcher never counts as waiting. Once nothing remains to send, the last reads in flight
    # are not a wait.
    param($Run,[datetime]$NowUtc,[switch]$Clear)
    if($null -eq $Run.PSObject.Properties['HeldSinceUtc']){return}
    if($Clear -or -not (Test-DomeniaParkWorkRemaining $Run)){$Run.HeldSinceUtc=$null;return}
    if($null -ne $Run.HeldSinceUtc){$Run.HeldSeconds=[double]$Run.HeldSeconds+[Math]::Min(5.0,[Math]::Max(0.0,($NowUtc-[datetime]$Run.HeldSinceUtc).TotalSeconds))}
    $Run.HeldSinceUtc=$NowUtc
}
function Update-DomeniaParkHeldStatus {
    # Nothing could leave on this tick (budgets, paused sources, retries not due): the status says so at most once
    # per second, never four times a second for the whole wait.
    param($Run,[datetime]$NowUtc)
    $shown=Get-DomeniaMemberValue $Run 'HeldShownUtc' $null
    if(($null -ne $shown) -and (($NowUtc-[datetime]$shown).TotalSeconds -lt 1)){return}
    if($null -ne $Run.PSObject.Properties['HeldShownUtc']){$Run.HeldShownUtc=$NowUtc}
    Update-DomeniaParkRunStatus -Run $Run
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
    # Hosts with no known address wait until the addressed ones have been offered. They must not occupy a WMI slot first.
    $unknown={param([string]$Key) $Key -in @('site:?','dc:?')}
    $addressedRemain=([int]$Run.Next -lt @($Run.Targets).Count)
    for($i=0;$i -lt $Run.Retry.Count;$i++){
        $item=$Run.Retry[$i]
        if([datetime]$item.NotBeforeUtc -gt $NowUtc){continue}
        # A delayed local writer must finish before the retry can reuse the committed successful families.
        $storeJob=[string](Get-DomeniaMember $item 'StoreJob' '')
        if($storeJob -and $Run.StorePending.ContainsKey($storeJob)){continue}
        if(-not (& $admit ([string]$item.SourceKey))){continue}
        $Run.Retry.RemoveAt($i)
        return [pscustomobject]@{Index=[int]$item.Index;Target=$Run.Targets[[int]$item.Index];SourceKey=[string]$item.SourceKey;Attempt=[int]$item.Attempt}
    }
    for($i=0;$i -lt $Run.Deferred.Count;$i++){
        $item=$Run.Deferred[$i]
        if($addressedRemain -and (& $unknown ([string]$item.SourceKey))){continue}
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
        $isUnknown=[bool](& $unknown $key)
        $includeUnknown=[bool](Get-DomeniaMember $Run 'IncludeUnaddressed' $false)
        $onlyUnknown=[bool](Get-DomeniaMember $Run 'OnlyUnaddressed' $false)
        if($onlyUnknown -and -not $isUnknown){$Run.Next++;continue}
        if($isUnknown -and -not $includeUnknown){$Run.Next++;$Run.Unchecked++;continue}
        if(& $admit $key){$Run.Next++;Expand-DomeniaParkPrevious $target;return [pscustomobject]@{Index=$index;Target=$target;SourceKey=$key;Attempt=1}}
        if($Run.Deferred.Count -ge 512){break}
        $Run.Deferred.Add([pscustomobject]@{Index=$index;SourceKey=$key});$Run.Next++
    }
    return $null
}
function Select-DomeniaParkPingBatch {
    # Points 14, 15 and 160 for the batch ping (MO-08): up to $Size workstations for the next ParkPing job, each
    # admitted by the budget of its presumed subnet; the echoes of that job are the reads in flight of their source.
    # Deferred workstations first, then the list in order. A workstation whose source refuses is deferred (512 at
    # most, with its source), so that a slow or paused site waits while the others go on. The stored observations are
    # never decoded here: the address comes from this session or from the ping detail of the stored JSON.
    param($Run,[datetime]$NowUtc,[int]$Size=32)
    $batch=New-Object 'System.Collections.Generic.List[object]'
    $running=@{};$refused=@{}
    $admit={param([string]$Key)
        if($refused.ContainsKey($Key)){return $false}
        $allowed=[bool](Test-DomeniaSourceAdmission -Health $Run.Sources.Health -Key $Key -Running ([int]$running[$Key]) -Policy (Get-DomeniaCampaignSourcePolicy $Run.Sources $Key) -NowUtc $NowUtc).Allowed
        if($allowed){$running[$Key]=[int]$running[$Key]+1}else{$refused[$Key]=$true}
        return $allowed
    }
    $i=0
    while(($i -lt $Run.Deferred.Count) -and ($batch.Count -lt $Size)){
        $item=$Run.Deferred[$i]
        if(& $admit ([string]$item.SourceKey)){$Run.Deferred.RemoveAt($i);$batch.Add([pscustomobject]@{Index=[int]$item.Index;Target=$Run.Targets[[int]$item.Index];SourceKey=[string]$item.SourceKey});continue}
        $i++
    }
    $scanned=0
    while(([int]$Run.Next -lt @($Run.Targets).Count) -and ($batch.Count -lt $Size) -and ($scanned -lt (4*$Size))){
        $index=[int]$Run.Next;$target=$Run.Targets[$index]
        $key=Get-DomeniaParkTargetSourceKey $Run $target
        $scanned++
        $isUnknown=($key -in @('site:?','dc:?'))
        $includeUnknown=[bool](Get-DomeniaMember $Run 'IncludeUnaddressed' $false)
        $onlyUnknown=[bool](Get-DomeniaMember $Run 'OnlyUnaddressed' $false)
        if($onlyUnknown -and -not $isUnknown){$Run.Next++;continue}
        if($isUnknown -and -not $includeUnknown){$Run.Next++;$Run.Unchecked++;continue}
        if(& $admit $key){$Run.Next++;$batch.Add([pscustomobject]@{Index=$index;Target=$target;SourceKey=$key});continue}
        if($Run.Deferred.Count -ge 512){break}
        $Run.Deferred.Add([pscustomobject]@{Index=$index;SourceKey=$key});$Run.Next++
    }
    return $batch.ToArray()
}
function Stop-DomeniaParkPingWorker {
    # MO-08: the batch ping is a single worker: it is asked to stop; echoes already reported are kept.
    param($Run)
    if($null -ne $Run -and [string]$Run.PingJob -and $script:AsyncJobs.Contains([string]$Run.PingJob)){try{Request-UiTaskStop -Id ([string]$Run.PingJob) -Silent -Reason 'Relevé arrêté'}catch{Write-DomeniaSwallowed 'Park' 'Stop-DomeniaParkPingWorker' $_}}
}
function Test-DomeniaRemoteStoreBlocked {
    # A batch the storage refused stays at the head of the remote store queue (a measure is never dropped): nothing
    # queued behind it is delivered in this session.
    $queue=$script:DomeniaRemoteStoreQueue
    if($null -eq $queue -or $queue.Count -eq 0){return $false}
    return [bool]$queue.Peek().Failed
}
function Close-DomeniaParkStoreBacklog {
    # The measures of a survey queued behind a refused batch will not be stored in this session: they are counted as
    # not stored, their rows lose their « relevé en cours » mark, and the survey can end instead of waiting for them.
    param($Run)
    $r=$Run
    if($null -eq $r -or $r.StorePending.Count -eq 0 -or -not (Test-DomeniaRemoteStoreBlocked)){return}
    $released=0
    foreach($item in @($script:DomeniaRemoteStoreQueue.ToArray())){
        $state=$item.State
        if([bool]$item.Failed -or [bool]$item.Delivered -or $null -eq $state -or [string](Get-DomeniaMemberValue $state 'RunId') -cne [string]$r.Id){continue}
        $job=[string](Get-DomeniaMemberValue $state 'Job')
        if(-not $job -or -not $r.StorePending.ContainsKey($job)){continue}
        [void]$r.StorePending.Remove($job)
        $keys=if($null -ne $state.PSObject.Properties['Targets']){@(@($state.Targets)|ForEach-Object{[string]$_.Key})}else{@([string]$state.Target.Key)}
        $r.Failed+=$keys.Count;$released+=$keys.Count
        foreach($key in $keys){Clear-DomeniaParkPendingRow -Run $r -Key $key}
    }
    if($released -gt 0){
        $r.Stopping=$true;Stop-DomeniaParkPingWorker -Run $r
        if(-not [string]$r.FailureMessage){$r.FailureMessage='Mesures non enregistrées : la file dʼenregistrement est bloquée par un lot refusé (voir Fiabilité).'}
    }
}
function Test-DomeniaParkEngineAvailable {
    # A timed-out CIM call may still occupy a physical slot while it is being stopped. Keep the
    # next workstation in the campaign until the engine can admit it; saturation is not a batch failure.
    $limits=Get-DomeniaEngineLimits;$load=Get-DomeniaEngineLoad
    if(Test-DomeniaSchedulerEnabled){
        $decision=Test-DomeniaTaskAdmission -Class Explicit -Running $load.Running -Outstanding $load.Outstanding -MaxConcurrent $limits.MaxConcurrent -MaxOutstanding $limits.MaxOutstanding -Queued $load.QueuedCount -MaxQueued $limits.MaxQueued -ReservedForeground $limits.ReservedForeground
        return ([string]$decision.Decision -ne 'Reject')
    }
    return (($load.Outstanding -lt $limits.MaxOutstanding) -and ($load.Running -lt $limits.MaxConcurrent))
}

function Invoke-DomeniaParkRunTick {
    param([ValidateSet('List','Computer')][string]$Slot='List')
    $r=Get-DomeniaParkRun -Slot $Slot;if($null -eq $r){return}
    if($r.Epoch -ne [long]$script:SessionEpoch -or $r.Path -cne [string]$script:DatabaseScopedPath -or $r.AccountGeneration -ne [long]$script:DomeniaAccountGeneration -or $script:AsyncEngineClosing){
        # Point 20: the durable plan says why the survey stopped; closing Domenia is recorded as such by the plan.
        Set-DomeniaParkStopReason $r $(if($r.AccountGeneration -ne [long]$script:DomeniaAccountGeneration){'changement de compte pendant le relevé'}elseif($r.Path -cne [string]$script:DatabaseScopedPath){'changement de base locale pendant le relevé'}else{'nouvelle session pendant le relevé'}) -KeepFirst
        $r.Stopping=$true;$r.Completed=$true;Clear-DomeniaParkTargetBuffers $r.Targets;Clear-DomeniaParkPendingRows -Run $r;if($null -ne $r.Timer){$r.Timer.Stop()};Close-DomeniaParkCampaign $r;return
    }
    if([string]$r.RefreshOperationId -and -not (Test-DomeniaOuRefreshCurrent ([string]$r.RefreshOperationId))){$r.Stopping=$true}
    # Cancelled workers never silently cause the rest of the fleet to start.
    foreach($id in @($r.Pending.Keys)){
        if(-not $script:AsyncJobs.Contains($id) -and -not @($script:DetachedReadJobs|Where-Object{$_.Id -eq $id}).Count){
            $gone=$r.Pending[$id];$wasStopping=[bool]$r.Stopping
            $r.Pending.Remove($id);$r.Stopping=$true
            if([string]$r.PingJob -ceq [string]$id){
                # Arrêter withdraws the batch ping itself; any other end is a stop outside the survey.
                if(-not $wasStopping){Set-DomeniaParkStopReason $r 'ping de la liste arrêté hors du relevé'}
                Complete-DomeniaParkPingWithdrawn -Run $r -State $gone
            }else{$r.Failed++;Set-DomeniaParkStopReason $r 'lecture dʼun poste arrêtée hors du relevé'}
        }
    }
    # MO-08: echoes reported by the batch ping are stored by batches, the storage keeping its own backpressure.
    if($r.PingOnly -or ([bool](Get-DomeniaMember $r 'PingBeforeWmi' $false) -and -not [bool](Get-DomeniaMember $r 'PingSwept' $false))){Submit-DomeniaParkPingResults -Run $r}
    if(([bool](Get-DomeniaMember $r 'PingBeforeWmi' $false)) -and -not [bool](Get-DomeniaMember $r 'PingSwept' $false) -and -not $r.Stopping){
        $pingBusy=((Test-DomeniaParkWorkRemaining $r) -or [string]$r.PingJob -or (Test-DomeniaParkPingBuffered $r) -or ($r.Pending.Count -gt 0) -or ($r.StorePending.Count -gt 0))
        if($pingBusy){Start-DomeniaParkPingJob -Run $r -NowUtc ([datetime]::UtcNow);return}
        $kept=New-Object System.Collections.Generic.List[object]
        $online=Get-DomeniaMemberValue $r 'PingOnline' $null
        foreach($target in @($r.Targets)){
            $key=([string]$target.Key).ToLowerInvariant()
            if(($online -is [Collections.IDictionary]) -and $online.ContainsKey($key)){[void]$kept.Add($target)}
        }
        $silent=[Math]::Max(0,@($r.Targets).Count-$kept.Count)
        # The ping phase does not count as a completed WMI read. Preserve its summary and the
        # original durable-plan indices before filtering the targets for the second phase.
        $r|Add-Member -NotePropertyName PingSummary -NotePropertyValue ([pscustomobject]@{Done=[int]$r.Done;NoReply=[int]$r.NoReply;Errors=[int]$r.Errors;Failed=[int]$r.Failed;Skipped=$silent}) -Force
        $r|Add-Member -NotePropertyName CampaignIndexByKey -NotePropertyValue $r.IndexByKey -Force
        $r.Done=0;$r.Online=0;$r.NoReply=0;$r.Errors=0;$r.Failed=0
        $r.Targets=$kept.ToArray();$r.Next=0
        if($null -ne $r.Deferred){$r.Deferred.Clear()}
        if($null -ne $r.Retry){$r.Retry.Clear()}
        Set-DomeniaParkTargetIndex -Run $r
        $r|Add-Member -NotePropertyName PingSwept -NotePropertyValue $true -Force
        Set-Status ('Ping terminé. Lecture WMI de '+[string]$kept.Count+' poste(s) en ligne. '+[string]$silent+' muet(s) ne sont pas contactés.')
        if(-not $kept.Count){$r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()};Close-DomeniaParkCampaign $r;Update-DomeniaParkRunStatus -Run $r;return}
    }
    Close-DomeniaParkStoreBacklog -Run $r
    if(($r.Stopping -or -not (Test-DomeniaParkWorkRemaining $r)) -and -not $r.Pending.Count -and -not (Test-DomeniaParkPingBuffered -Run $r)){
        $save=Get-DomeniaPersistenceState
        if($r.StorePending.Count -gt 0 -or ($save.Pending -gt 0 -and -not $save.Suspended)){Update-DomeniaParkRunStatus -Run $r;return}
        if([bool]$r.PingOnly -and [bool]$r.Approved){Close-DomeniaParkPingJobTargets -Run $r}
        $r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()};Close-DomeniaParkCampaign $r;Update-DomeniaParkRunStatus -Run $r;return
    }
    # Point 20: progress written at most every ten seconds while the survey runs.
    [void](Save-DomeniaCampaignProgress -Run $r)
    # Widget collections check the stored measurements first, a bounded slice per tick, with nothing read.
    if([bool](Get-DomeniaMember $r 'Planning' $false)){Invoke-DomeniaParkPlanStep -Run $r;return}
    if($r.Stopping -or -not $r.Approved){return}
    $nowUtc=[datetime]::UtcNow
    if($r.PingOnly){Start-DomeniaParkPingJob -Run $r -NowUtc $nowUtc;return}
    if($null -ne $script:DomeniaRemoteStoreQueue -and $script:DomeniaRemoteStoreQueue.Count -gt 0){Add-DomeniaParkHeldTime $r $nowUtc;return}
    if($r.StorePending.Count -ge 40){Add-DomeniaParkHeldTime $r $nowUtc;return}
    if($script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){Add-DomeniaParkHeldTime $r $nowUtc;return}
    if($null -ne $script:Persistence){
        if($script:Persistence.Failures -ge 3 -or $script:Persistence.Conflicts.Count){$r.Stopping=$true;Set-DomeniaParkStopReason $r 'enregistrement local suspendu';Update-DomeniaParkRunStatus -Run $r;return}
        # Points 32 and 35: started workers finish and are saved; no further target is admitted. The durable plan
        # keeps the remaining workstations with this reason (point 20).
        $storageRefusal=Get-DomeniaStorageCollectionRefusal
        if($storageRefusal){$r.Stopping=$true;Set-DomeniaParkStopReason $r ([string]$storageRefusal);Update-DomeniaParkRunStatus -Run $r;return}
        if($script:Persistence.Pending.Count -ge 64 -or $script:Persistence.LinkBusy){Add-DomeniaParkHeldTime $r $nowUtc;return}
    }
    # One admission per tick keeps the Dispatcher responsive. The engine may impose a smaller provider budget.
    if(([int](Get-DomeniaMember $r 'WaveLimit' 0)) -gt 0 -and ([int](Get-DomeniaMember $r 'WaveContacts' 0)) -ge ([int]$r.WaveLimit)){
        $r.Stopping=$true
        Set-DomeniaParkStopReason $r 'vague de 200 postes atteinte. Relancez pour la suite : les postes déjà lus restent en cache.'
        Update-DomeniaParkRunStatus -Run $r
        return
    }
    if($r.Pending.Count -ge $r.Concurrency){Add-DomeniaParkHeldTime $r $nowUtc -Clear;return}
    if(-not (Test-DomeniaParkEngineAvailable)){Add-DomeniaParkHeldTime $r $nowUtc;Update-DomeniaParkHeldStatus -Run $r -NowUtc $nowUtc;return}
    $pick=$null
    try{$pick=Select-DomeniaParkNextTarget -Run $r -NowUtc $nowUtc}catch{$r.Stopping=$true;Set-DomeniaParkStopReason $r 'cache dʼun poste illisible';Set-Status ('Cache du poste illisible. Relancez le relevé après actualisation. '+$_.Exception.Message) 'WARN';return}
    if($null -eq $pick){Add-DomeniaParkHeldTime $r $nowUtc;Update-DomeniaParkHeldStatus -Run $r -NowUtc $nowUtc;return}
    Add-DomeniaParkHeldTime $r $nowUtc -Clear
    $target=$pick.Target
    $noConsole=[bool](Get-DomeniaMember $r 'NoConsole' $false)
    # Point 19: capabilities known missing on this workstation are not read again for a limited time; a forced
    # read (« Forcer la relecture », the refresh of a widget) ignores that memory.
    $build=[string](Get-DomeniaMember (Get-DomeniaMemberValue $target.Previous 'Inventory') 'Build' '')
    $capability=Get-DomeniaCapabilityPlan -Memory (Get-DomeniaCapabilityMemory) -Target ([string]$target.Computer) -Probes @($r.Probes) -Previous $target.Previous -NowUtc $nowUtc -Build $build -AccountGeneration ([long]$script:DomeniaAccountGeneration) -Force ([int]$r.CacheMinutes -eq 0)
    $skipCim=[bool]$capability.SkipCim
    $r.CapabilitySkipped=[int]$r.CapabilitySkipped+@($capability.Skipped).Count
    # Point 11: the durations of the usage profile; widget collections also reuse what is younger than their age.
    $plan=New-DomeniaCollectionPlan -Previous $target.Previous -Guid $target.Guid -Key $target.Key -Probes @($capability.Probes) -Inventory ([bool]$r.Inventory) -CacheMinutes ([int]$r.CacheMinutes) -Freshness $r.Freshness -ReuseMaxAgeDays ([int](Get-DomeniaMember $r 'ReuseMaxAgeDays' 0))
    $sendConsole=((-not $noConsole) -and (-not $skipCim))
    $sendInventory=([bool]$plan.Inventory -and -not $skipCim)
    $sendProbes=@();if(-not $skipCim){$sendProbes=@($plan.Probes)}
    if([bool]$r.WmiOnly -and (-not $sendConsole) -and (-not $sendInventory) -and ($sendProbes.Count -eq 0) -and ($skipCim -or (@($capability.Skipped).Count -gt 0))){
        # WMI only and nothing left to ask this workstation now: WMI known refused or inaccessible, or every probe
        # left out for a class known absent. It is not contacted and stays in the plan of the campaign (point 20).
        $r.SkippedTargets=[int]$r.SkippedTargets+1;Clear-DomeniaParkTargetBuffers @($target);Clear-DomeniaParkPendingRow -Run $r -Key ([string]$target.Key);Update-DomeniaParkRunStatus -Run $r;return
    }
    if($skipCim){$r.CimSkipped=[int]$r.CimSkipped+1}
    $state=[pscustomobject]@{RunId=$r.Id;Slot=$r.Slot;Epoch=$r.Epoch;Path=$r.Path;Target=$target;Job='';Plan=$plan;PingOnly=$r.PingOnly;WmiOnly=$r.WmiOnly;NoConsole=$noConsole;RemoteStartedUtc=[datetime]::UtcNow.ToString('o');Index=[int]$pick.Index;Attempt=[int]$pick.Attempt;SourceKey=[string]$pick.SourceKey;SkipCim=$skipCim}
    [void](Initialize-DomeniaRemoteStoreState -State $state -Guid $target.Guid -DN $target.Key -Generation $r.Generation)
    # Point 17: one step per finished ping or CIM query; no progress for the idle delay ends the read, and a read
    # that keeps progressing still stops at its total duration.
    $probeCount=$sendProbes.Count
    $slowProbeCount=@($sendProbes|Where-Object{[bool](Get-DomeniaMember $_ 'Slow' $false)}).Count
    $idle=if($probeCount -or $sendInventory){25}else{20}
    $total=if($probeCount -or $sendInventory){[Math]::Min(300,30+12*$probeCount+3*$slowProbeCount+$(if($sendInventory){12}else{0}))}else{30}
    $readProgress=[hashtable]::Synchronized(@{StartedTimestamp=0L;LastRowTimestamp=0L;RowsRead=0L})
    # Points 14 and 18: the answer reads back the dispatch clock (latency per step) and the ping step of a stopped read.
    $state|Add-Member -NotePropertyName ReadProgress -NotePropertyValue $readProgress -Force
    # What was really asked: a failure is dated only for the families that were sent.
    $state|Add-Member -NotePropertyName SentConsole -NotePropertyValue $sendConsole -Force
    $state|Add-Member -NotePropertyName SentInventory -NotePropertyValue $sendInventory -Force
    $state|Add-Member -NotePropertyName SentProbes -NotePropertyValue $sendProbes -Force
    try{
        $id=Start-UiTask -Name ($(if(([bool]$r.WmiOnly) -or $noConsole){'WMI du perimetre : '}else{'Console du parc : '})+$target.Computer) -OperationId 'LiveConsole' -Code (Get-DomeniaLiveProbeCode) -Payload ([pscustomobject]@{Computer=$target.Computer;Key=$target.Key;Guid=$target.Guid;Previous=$target.Previous;AllowIdentityCache=([int]$r.CacheMinutes -gt 0);MethodSeconds=4;ProbeTimeoutSeconds=10;SlowProbeTimeoutSeconds=15;CollectPing=(-not [bool]$r.WmiOnly);RequirePing=([bool](Get-DomeniaMember $r 'PingBeforeWmi' $false));ValidateConsoleIdentity=$false;ProbeUser=$sendConsole;Inventory=$sendInventory;Probes=$sendProbes;AllowedClasses=@(@(Get-DomeniaProbeCatalog)|ForEach-Object{[string]$_.Class});ReadProgress=$readProgress}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkSession' -ErrorHandler 'Fail-DomeniaParkSession' -TimeoutSeconds $idle -HardTimeoutSeconds $total -TaskClass 'Explicit'
        if(-not $id){throw 'Lecture non admise.'}
        $state.Job=[string]$id;$r.Pending[[string]$id]=$state
        $r.WaveContacts=[int](Get-DomeniaMember $r 'WaveContacts' 0)+1
    }catch{$r.Stopping=$true;Set-DomeniaParkStopReason $r ([string]$_.Exception.Message);$r.FailureMessage='Relevé interrompu : '+$_.Exception.Message+' Les résultats précédents sont conservés.';[void](Set-DomeniaControlText 'LblParkStatus' $r.FailureMessage)}
}
function Invoke-DomeniaParkPlanStep {
    # The single "collect only what is missing" planner (decision David 2026-10-14): widget collections and the
    # workshop's collection of the missing information of a recipe (New-DomeniaMissingCollectionPlan proposes the
    # workstations and counts the estimate with the same reuse age). The stored observation of each
    # workstation, read by ParkTargets with the observation families of this run, is checked against what the run
    # reads: a workstation already answered is counted apart and never contacted. A slice per tick, bounded in count
    # and in time, keeps the Dispatcher responsive whatever the size of the OU, and nothing is read on the network
    # meanwhile. At the end, the admission applies to the workstations left to read (Request-DomeniaParkAdmission).
    param($Run,[int]$MaxTargets=400,[int]$BudgetMs=30)
    $r=$Run
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $days=[int](Get-DomeniaMember $r 'ReuseMaxAgeDays' 0)
    $ping=(-not [bool]$r.WmiOnly)
    $console=((-not [bool]$r.PingOnly) -and (-not [bool](Get-DomeniaMember $r 'NoConsole' $false)))
    $checked=0
    while(([int]$r.PlanNext -lt $r.Targets.Count) -and ($checked -lt $MaxTargets) -and (($checked -eq 0) -or ($clock.ElapsedMilliseconds -lt $BudgetMs))){
        $target=$r.Targets[[int]$r.PlanNext];$r.PlanNext=[int]$r.PlanNext+1;$checked++
        try{Expand-DomeniaParkPrevious $target}catch{$r.Planning=$false;$r.Stopping=$true;Set-Status ('Cache du poste illisible : '+$target.Computer+'. Relancez le relevé après actualisation.') 'WARN';Update-DomeniaParkRunStatus -Run $r;return}
        $plan=New-DomeniaCollectionPlan -Previous $target.Previous -Guid $target.Guid -Key $target.Key -Probes @($r.Probes) -Inventory ([bool]$r.Inventory) -CacheMinutes ([int]$r.CacheMinutes) -Freshness (Get-DomeniaMemberValue $r 'Freshness') -ReuseMaxAgeDays $days
        if(Test-DomeniaParkTargetAnswered -Previous $target.Previous -Guid $target.Guid -Key $target.Key -Plan $plan -Ping $ping -Console $console -ReuseMaxAgeDays $days){
            $r.AlreadyFresh=[int]$r.AlreadyFresh+1;$r.CachedMeasurements=[int]$r.CachedMeasurements+[int]$plan.Reused
            Clear-DomeniaParkTargetBuffers @($target)
        }else{$r.ToRead.Add($target)}
    }
    if([int]$r.PlanNext -lt $r.Targets.Count){Update-DomeniaParkRunStatus -Run $r;return}
    $r.Planning=$false;$r.Targets=$r.ToRead.ToArray();$r.ToRead.Clear();$r.Next=0
    # The batch ping and its accounting follow the workstations left to read only (MO-08: a target set aside is
    # never counted as not checked); the durable plan (point 20) is made of them too.
    Set-DomeniaParkTargetIndex -Run $r
    if(-not $r.Targets.Count){
        # Every workstation already answers: the run ends without contacting any of them and without approval.
        $r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()}
        Update-DomeniaParkRunStatus -Run $r
        $subject=if([string](Get-DomeniaMember $r 'WidgetBoard' '')){'Widget à jour : '+[int]$r.AlreadyFresh+' poste(s)'+$(if($r.ScopeLabel){' de '+$r.ScopeLabel}else{''})}else{'Rien à relire : les '+[int]$r.AlreadyFresh+' poste(s) proposés'}
        Set-Status ($subject+' ont déjà une mesure exploitable de moins de '+$days+' jours ; aucun poste contacté.') 'INFO'
        return
    }
    Update-DomeniaParkRunStatus -Run $r
    Request-DomeniaParkAdmission -Run $r
}
function Start-DomeniaParkPingJob {
    # MO-08: the next batch of echoes (32 at a time) goes to one ParkPing worker, one batch in flight. Points 14, 15
    # and 160: each workstation of the batch is admitted by the budget of its presumed subnet, as a console or WMI
    # read is, so that a slow or paused site waits while the others go on. The storage of the reported batches keeps
    # its own backpressure; the four parallel reads stay for console and WMI surveys.
    param($Run,[datetime]$NowUtc=[datetime]::UtcNow)
    $r=$Run
    if([string]$r.PingJob -or -not (Test-DomeniaParkWorkRemaining $r)){return}
    if($script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){Add-DomeniaParkHeldTime $r $NowUtc;return}
    # Points 32 and 35, as for the console and WMI reads: the echoes already reported are still saved, no further
    # batch is sent during a base maintenance, a suspended writer or a nearly full disk.
    if($null -ne $script:Persistence){
        $storageRefusal=Get-DomeniaStorageCollectionRefusal
        if($storageRefusal){$r.Stopping=$true;Set-DomeniaParkStopReason $r ([string]$storageRefusal);Update-DomeniaParkRunStatus -Run $r;return}
    }
    if(-not (Test-DomeniaParkEngineAvailable)){Add-DomeniaParkHeldTime $r $NowUtc;Update-DomeniaParkHeldStatus -Run $r -NowUtc $NowUtc;return}
    $batchSize=192
    $picked=@(Select-DomeniaParkPingBatch -Run $r -NowUtc $NowUtc -Size $batchSize)
    if(-not $picked.Count){Add-DomeniaParkHeldTime $r $NowUtc;Update-DomeniaParkHeldStatus -Run $r -NowUtc $NowUtc;return}
    Add-DomeniaParkHeldTime $r $NowUtc -Clear
    $batch=@(foreach($pick in $picked){$t=$pick.Target;[pscustomobject]@{Key=[string]$t.Key;Guid=[string]$t.Guid;Computer=[string]$t.Computer}})
    $keys=@(foreach($pick in $picked){$key=([string]$pick.Target.Key).ToLowerInvariant();$r.PingSourceKeys[$key]=[string]$pick.SourceKey;$key})
    if($null -eq $r.PingQueue){$r.PingQueue=[Collections.Concurrent.ConcurrentQueue[object]]::new()}
    if($null -eq $r.PingBuffer){$r.PingBuffer=[Collections.Generic.Queue[object]]::new()}
    $state=[pscustomobject]@{RunId=$r.Id;Slot=$r.Slot;Epoch=$r.Epoch;Path=$r.Path;Job='';Count=$batch.Count;Keys=$keys}
    # The engine budget follows the worker's own waits (name resolution and echo delay of its batch).
    $timeoutMs=1000
    $timeout=Get-DomeniaParkPingTimeoutSeconds -Count $batch.Count -TimeoutMs $timeoutMs -BatchSize $batchSize
    try{
        $id=Start-UiTask -Name ('Ping de la liste : '+[string]$batch.Count+' postes') -OperationId 'ParkPing' -Code (Get-DomeniaParkPingWorkerCode) -Payload ([pscustomobject]@{Targets=$batch;TimeoutMs=$timeoutMs;BatchSize=$batchSize;Progress=$r.PingQueue}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkPingJob' -ErrorHandler 'Fail-DomeniaParkPingJob' -TimeoutSeconds $timeout -TaskClass 'Explicit'
        if(-not $id){throw 'Ping non admis.'}
        $state.Job=[string]$id;$r.PingJob=[string]$id;$r.Pending[[string]$id]=$state
    }catch{$r.Stopping=$true;Set-DomeniaParkStopReason $r ([string]$_.Exception.Message);$r.FailureMessage='Ping non lancé : '+$_.Exception.Message;[void](Set-DomeniaControlText 'LblParkStatus' $r.FailureMessage)}
    Update-DomeniaParkRunStatus -Run $r
}
function Receive-DomeniaParkPingQueue {
    # Moves the batches reported by the worker to the buffer of the run; a target is taken once.
    param($Run,[object[]]$Extra=@())
    $r=$Run
    if($null -eq $r.PingBuffer){$r.PingBuffer=[Collections.Generic.Queue[object]]::new()}
    $items=[Collections.Generic.List[object]]::new()
    if($null -ne $r.PingQueue){
        $packet=$null
        for($n=0;$n -lt 256 -and $r.PingQueue.TryDequeue([ref]$packet);$n++){foreach($result in @($packet.Results)){if($null -ne $result){$items.Add($result)}};$packet=$null}
    }
    foreach($result in @($Extra)){if($null -ne $result){$items.Add($result)}}
    foreach($result in $items){
        $key=([string]$result.Key).ToLowerInvariant()
        if(-not $key -or $r.PingReported.ContainsKey($key) -or -not $r.TargetsByKey.ContainsKey($key)){continue}
        $r.PingReported[$key]=$true;$r.PingBuffer.Enqueue($result)
        if([string]$result.Presence -eq 'En ligne'){$online=Get-DomeniaMemberValue $r 'PingOnline' $null;if($online -is [Collections.IDictionary]){$online[$key]=$true}}
        Register-DomeniaParkPingOutcome -Run $r -Key $key -Result $result
    }
}
function Register-DomeniaParkPingOutcome {
    # Points 14, 15 and 160 for one echo: its answer teaches the budget of the presumed subnet it was admitted on
    # (the round trip time is the latency of the step; no reply or a name error says nothing about the site), and its
    # address feeds the subnet of the next reads of the workstation. The budget never decides a measure.
    param($Run,[string]$Key,$Result)
    try{
        [void](Register-DomeniaTargetAddress -Computer ([string]$Result.Computer) -Text ([string]$Result.PresenceDetail))
        $map=Get-DomeniaMemberValue $Run 'PingSourceKeys' $null
        if(($map -isnot [Collections.IDictionary]) -or -not $map.ContainsKey($Key)){return}
        $source=[string]$map[$Key]
        $failure=ConvertTo-DomeniaCollectionFailure -Outcome 'PresenceOnly' -Presence ([string]$Result.Presence) -PingCollected $true
        $latency=[double]-1
        if(([string]$Result.Presence -eq 'En ligne') -and ([string]$Result.PresenceDetail -match '(\d+)\s*ms')){$latency=[double]$Matches[1]}
        [void](Register-DomeniaSourceOutcome -Health $Run.Sources.Health -Key $source -Outcome ([string]$failure.Health) -LatencyMs $latency -Policy (Get-DomeniaCampaignSourcePolicy $Run.Sources $source) -NowUtc ([datetime]::UtcNow))
    }catch{try{Write-AppLog ('Budget du ping non mis à jour : '+$_.Exception.Message) 'WARN'}catch{Write-DomeniaSwallowed 'Park' 'Register-DomeniaParkPingOutcome' $_}}
}
function Test-DomeniaParkPingBuffered {
    # True while echoes reported by the batch ping still wait to be stored.
    param($Run)
    if($null -eq $Run){return $false}
    if($null -ne $Run.PingBuffer -and $Run.PingBuffer.Count -gt 0){return $true}
    return ($null -ne $Run.PingQueue -and -not $Run.PingQueue.IsEmpty)
}
function Submit-DomeniaParkPingResults {
    # MO-08: one store batch (one SQLite transaction) per group of 32 echoes, at most four batches in flight.
    param($Run)
    $r=$Run
    Receive-DomeniaParkPingQueue -Run $r
    if($null -eq $r.PingBuffer -or -not $r.PingBuffer.Count){return}
    # Suspended or conflicting storage, or a store queue held by a refused batch: the buffered echoes cannot be stored
    # in this survey. They are counted as not stored and the survey ends instead of waiting for them.
    if($null -ne $script:Persistence -and ([int]$script:Persistence.Failures -ge 3 -or ($null -ne $script:Persistence.Conflicts -and $script:Persistence.Conflicts.Count -gt 0))){Close-DomeniaParkPingBuffer -Run $r -Reason 'stockage local suspendu ou en conflit (voir Fiabilité)';return}
    for($round=0;$round -lt 4 -and $r.PingBuffer.Count -gt 0 -and $r.StorePending.Count -lt 4;$round++){
        # A batch refused at the head of the store queue (also by the batch just sent) holds everything behind it.
        if(Test-DomeniaRemoteStoreBlocked){Close-DomeniaParkPingBuffer -Run $r -Reason 'file dʼenregistrement bloquée par un lot refusé (voir Fiabilité)';return}
        # A full queue drains on its own timer: the echoes wait in the buffer.
        if($null -ne $script:DomeniaRemoteStoreQueue -and $script:DomeniaRemoteStoreQueue.Count -ge 48){return}
        $items=[Collections.Generic.List[object]]::new()
        while($items.Count -lt 32 -and $r.PingBuffer.Count -gt 0){$items.Add($r.PingBuffer.Dequeue())}
        $state=[pscustomobject]@{RunId=$r.Id;Slot=$r.Slot;Epoch=$r.Epoch;Path=$r.Path;Job=('ping-'+[guid]::NewGuid().ToString('N'));Targets=@()}
        $targets=[Collections.Generic.List[object]]::new();$changes=[Collections.Generic.List[object]]::new();$mismatched=0
        try{
            foreach($item in $items){
                $target=$r.TargetsByKey[([string]$item.Key).ToLowerInvariant()]
                if($null -eq $target -or [string]$item.Guid -ine [string]$target.Guid -or [string]$item.Computer -ine [string]$target.Computer){$r.Failed++;$mismatched++;continue}
                $packet=[pscustomobject]@{Key=[string]$target.Key;Guid=[string]$target.Guid;Computer=[string]$target.Computer;Outcome='PresenceOnly';Presence=[string]$item.Presence;PresenceDetail=[string]$item.PresenceDetail;PresenceCheckedUtc=[string]$item.PresenceCheckedUtc}
                foreach($change in @(ConvertTo-DomeniaRemoteObservationChanges -Result $packet -Guid ([string]$target.Guid) -DN ([string]$target.Key))){$changes.Add($change)}
                $targets.Add([pscustomobject]@{Key=[string]$target.Key;Guid=[string]$target.Guid;Computer=[string]$target.Computer})
            }
            if(-not $changes.Count){continue}
            $state.Targets=$targets.ToArray()
            # The batch spans several workstations of the domain: its context is the domain, each change names its own.
            $context=New-DomeniaStoreContext -RequestId ([guid]::NewGuid().ToString('D')) -Generation ([long]$r.Generation) -ScopeDn ([string]$script:Conn.BaseDn) -Subtree $true
            $state|Add-Member -NotePropertyName StoreContext -NotePropertyValue $context -Force
            $state|Add-Member -NotePropertyName AccountGeneration -NotePropertyValue ([long]$r.AccountGeneration) -Force
            $r.StorePending[[string]$state.Job]=$true
            [void](Submit-DomeniaRemoteChanges -Changes $changes.ToArray() -State $state -SuccessHandler 'Complete-DomeniaParkPingStored' -ErrorHandler 'Fail-DomeniaParkPingStored')
        }catch{
            # The storage refused this batch: neither it nor the rest of the buffer will be stored in this survey.
            $message=$_.Exception.Message
            [void]$r.StorePending.Remove([string]$state.Job)
            $r.Failed+=($items.Count-$mismatched)
            foreach($item in $items){Clear-DomeniaParkPendingRow -Run $r -Key ([string]$item.Key)}
            Close-DomeniaParkPingBuffer -Run $r -Reason $message
            Set-Status ('Mesures de ping non enregistrées : '+$message) 'ERROR'
            return
        }
    }
}
function Close-DomeniaParkPingBuffer {
    # MO-08: the storage refuses the echoes of this survey: those still buffered are counted as not stored, their rows
    # lose their « relevé en cours » mark, and the batch ping is asked to stop (the echoes it still reports are closed
    # the same way on the next tick).
    param($Run,[string]$Reason)
    $r=$Run
    $r.Stopping=$true
    Stop-DomeniaParkPingWorker -Run $r
    $count=0
    if($null -ne $r.PingBuffer){
        while($r.PingBuffer.Count -gt 0){$item=$r.PingBuffer.Dequeue();$count++;Clear-DomeniaParkPendingRow -Run $r -Key ([string]$item.Key)}
    }
    $r.Failed+=$count
    if(-not [string]$r.FailureMessage){$r.FailureMessage='Mesures de ping non enregistrées : '+[string]$Reason+'.'}
}
function Complete-DomeniaParkPingJob {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId)
    [void]$r.Pending.Remove([string]$State.Job);$r.PingJob=''
    $packet=Get-DomeniaEffectiveWorkerResult $Result @('Results')
    # Every batch was reported through the queue; the final list only covers a queue left unread.
    Receive-DomeniaParkPingQueue -Run $r -Extra $(if($null -ne $packet){@($packet.Results)}else{@()})
    Complete-DomeniaParkPingWithdrawn -Run $r -State $State
    Update-DomeniaParkRunStatus -Run $r
}
function Fail-DomeniaParkPingJob {
    # A failed batch ping stops the survey: its unreported workstations are not checked, and a worker failure says
    # nothing about their sites (no source outcome is registered for them).
    param($Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId)
    [void]$r.Pending.Remove([string]$State.Job);$r.PingJob=''
    Receive-DomeniaParkPingQueue -Run $r
    if(-not $r.Stopping){$r.FailureMessage='Ping de la liste interrompu : '+[string]$Message}
    $r.Stopping=$true
    Complete-DomeniaParkPingWithdrawn -Run $r -State $State
    Update-DomeniaParkRunStatus -Run $r
}
function Complete-DomeniaParkPingWithdrawn {
    # One batch ping ended, failed or was stopped: the echoes it reported are taken, the rest is closed by
    # Close-DomeniaParkPingJobTargets.
    param($Run,$State=$null)
    $r=$Run;$r.PingJob=''
    Receive-DomeniaParkPingQueue -Run $r
    Close-DomeniaParkPingJobTargets -Run $r -State $State
}
function Close-DomeniaParkPingJobTargets {
    # Workstations a batch ping never reported stay as they were, counted as not checked and without their « relevé
    # en cours » mark (no measure is invented for them). Once the survey stops or has nothing left to send, every
    # workstation never reported, sent or not, is closed the same way. Without -State, only that final pass runs.
    param($Run,$State=$null)
    $r=$Run
    $missing=Get-DomeniaMemberValue $r 'PingMissing' $null
    if($missing -isnot [Collections.IDictionary]){$missing=@{};$r|Add-Member -NotePropertyName PingMissing -NotePropertyValue $missing -Force}
    $close={param([string]$Key)
        if((-not $Key) -or $r.PingReported.ContainsKey($Key) -or $missing.ContainsKey($Key)){return}
        $missing[$Key]=$true;Clear-DomeniaParkPendingRow -Run $r -Key $Key
    }
    if($null -ne $State){foreach($key in @(Get-DomeniaMember $State 'Keys' @())){& $close ([string]$key)}}
    if([bool]$r.Stopping -or -not (Test-DomeniaParkWorkRemaining $r)){foreach($key in @($r.TargetsByKey.Keys)){& $close ([string]$key)}}
    $r.Unchecked=$missing.Count
}
function Complete-DomeniaParkPingStored {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId);[void]$r.StorePending.Remove([string]$State.Job)
    if(-not (Test-DomeniaRemoteStoreContext $State $Result)){$r.Stopping=$true;return}
    foreach($target in @($State.Targets)){
        $rows=@($Result.ObservationRows|Where-Object{[string]$_.Guid -ieq [string]$target.Guid -and [string]$_.Key -ieq [string]$target.Key})
        if($rows.Count -ne 1){$r.Failed++;Clear-DomeniaParkPendingRow -Run $r -Key ([string]$target.Key);continue}
        $incomplete=([string]$rows[0].Presence -eq 'Erreur de ping')
        Publish-DomeniaParkObservation -Run $r -Observation $rows[0] -Index (Get-DomeniaParkTargetIndex -Run $r -Key ([string]$target.Key)) -Incomplete:$incomplete
    }
    Sync-DomeniaParkGrid -Run $r
    Update-DomeniaParkRunStatus -Run $r
}
function Fail-DomeniaParkPingStored {
    param([string]$Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId);[void]$r.StorePending.Remove([string]$State.Job)
    $r.Stopping=$true;$r.Failed+=@($State.Targets).Count;$r.FailureMessage='Mesures de ping non publiées : enregistrement SQLite non confirmé. '+$Message
    Set-DomeniaParkStopReason $r 'enregistrement local non confirmé'
    foreach($target in @($State.Targets)){Clear-DomeniaParkPendingRow -Run $r -Key ([string]$target.Key)}
    Set-Status $r.FailureMessage 'ERROR'
    Update-DomeniaParkRunStatus -Run $r
}
function Complete-DomeniaParkSession {
    param($Result,$State)
    # Duplicate engine delivery must not resubmit a measurement or reopen pending accounting.
    if([string](Get-DomeniaMemberValue $State 'StoreBatchId')){return}
    # A completed collection belongs to its captured store even after selection/session changes.
    $packet=Get-DomeniaEffectiveWorkerResult $Result @('Outcome','Key','Guid','Computer')
    $current=Test-DomeniaParkRunCurrent $State
    $r=$null
    if($current){$r=Get-DomeniaParkRunById ([string]$State.RunId);[void]$r.Pending.Remove([string]$State.Job);$r.StorePending[[string]$State.Job]=$true}
    try{
        if($null -eq $packet -or [string]$packet.Key -ine [string]$State.Target.Key -or [string]$packet.Guid -ine [string]$State.Target.Guid -or [string]$packet.Computer -ine [string]$State.Target.Computer){throw 'Identité de la mesure distante incohérente.'}
        if($current -and ($packet.Outcome -eq 'AuthRejected' -or $packet.DirectoryAuthRejected)){$r.Stopping=$true;Set-DomeniaParkStopReason $r 'identifiants rejetés : reprise après un changement de compte'}
        if($current){Register-DomeniaParkMeasurement -Run $r -Packet $packet -State $State}
        [void](Submit-DomeniaRemoteObservations -Result $packet -State $State -SuccessHandler 'Complete-DomeniaParkStored' -ErrorHandler 'Fail-DomeniaParkStored')
    }catch{Fail-DomeniaParkStored -Message $_.Exception.Message -State $State}
}

function Get-DomeniaParkReadProgressSnapshot {
    # Fields of the progress channel of one workstation read, copied under the lock its worker uses.
    param($State)
    $snapshot=[pscustomobject]@{StartedTimestamp=0L;LastRowTimestamp=0L;RowsRead=0L;Presence=''}
    $progress=Get-DomeniaMemberValue $State 'ReadProgress' $null
    if($progress -isnot [Collections.IDictionary]){return $snapshot}
    $syncRoot=([Collections.ICollection]$progress).SyncRoot;$locked=$false
    try{
        [Threading.Monitor]::Enter($syncRoot);$locked=$true
        $snapshot.StartedTimestamp=[long]$progress['StartedTimestamp'];$snapshot.LastRowTimestamp=[long]$progress['LastRowTimestamp'];$snapshot.RowsRead=[long]$progress['RowsRead'];$snapshot.Presence=[string]$progress['Presence']
    }finally{if($locked){[Threading.Monitor]::Exit($syncRoot)}}
    return $snapshot
}
function Register-DomeniaParkMeasurement {
    # Points 13, 14, 15, 18, 19 and 160 for one workstation answer, before it is stored: the source budget learns
    # from the answer and its delay, a transient incident gets a bounded and spaced retry, missing capabilities are
    # remembered, the last address feeds the subnet budget and the CIM queries avoided are counted.
    param($Run,$Packet,$State)
    if($null -eq $Run.PSObject.Properties['Sources']){return}
    try{
        $nowUtc=[datetime]::UtcNow
        # A read stopped by the engine is classified from the ping step its worker reported, never from the packet
        # built for the store (which records the failed attempt only).
        $jobFailed=[bool](Get-DomeniaMember $State 'JobFailed' $false)
        $presence=if($jobFailed){[string](Get-DomeniaMember $State 'JobPresence' '')}else{[string](Get-DomeniaMember $Packet 'Presence' '')}
        $failure=ConvertTo-DomeniaCollectionFailure -Outcome ([string]$Packet.Outcome) -Presence $presence -PingCollected (-not [bool]$State.WmiOnly) -JobFailed $jobFailed -ErrorText ([string](Get-DomeniaMember $State 'JobError' ''))
        # Point 14: mean duration of one finished step on the dispatch clock: no queue wait, comparable between a
        # plan of reused measurements and a full read.
        $snapshot=Get-DomeniaParkReadProgressSnapshot $State
        $latency=Get-DomeniaReadStepLatencyMs -StartedTimestamp ([long]$snapshot.StartedTimestamp) -LastTimestamp ([long]$snapshot.LastRowTimestamp) -Steps ([long]$snapshot.RowsRead)
        $key=[string](Get-DomeniaMember $State 'SourceKey' '')
        if($key){[void](Register-DomeniaSourceOutcome -Health $Run.Sources.Health -Key $key -Outcome ([string]$failure.Health) -LatencyMs $latency -Policy (Get-DomeniaCampaignSourcePolicy $Run.Sources $key) -NowUtc $nowUtc)}
        $retry=Get-DomeniaCollectionRetryDecision -Category ([string]$failure.Category) -Attempt ([int](Get-DomeniaMember $State 'Attempt' 1)) -MaxAttempts ([int](Get-DomeniaMember $Run 'RetryMaxAttempts' 3)) -BaseDelaySeconds ([int](Get-DomeniaMember $Run 'RetryBaseDelaySeconds' 30)) -NowUtc $nowUtc
        if([bool]$retry.Retry -and -not [bool]$Run.Stopping){
            $State|Add-Member -NotePropertyName WillRetry -NotePropertyValue $true -Force
            $Run.Retry.Add([pscustomobject]@{Index=[int]$State.Index;NotBeforeUtc=$retry.NotBeforeUtc;Attempt=([int]$State.Attempt+1);SourceKey=$key;StoreJob=[string]$State.Job})
            $Run.Retried=[int]$Run.Retried+1
        }elseif([string]$failure.Category -eq 'Transient'){$Run.RetryExhausted=[int]$Run.RetryExhausted+1}
        $build=[string](Get-DomeniaMember (Get-DomeniaMemberValue $Packet 'Inventory') 'Build' '')
        if(-not $build){$build=[string](Get-DomeniaMember (Get-DomeniaMemberValue $State.Target.Previous 'Inventory') 'Build' '')}
        if(-not [bool](Get-DomeniaMember $State 'SkipCim' $false)){Register-DomeniaCollectionCapabilities -Computer ([string]$State.Target.Computer) -Packet $Packet -Probes @(Get-DomeniaMember $State 'SentProbes' @($State.Plan.Probes)) -Build $build}
        [void](Register-DomeniaTargetAddress -Computer ([string]$Packet.Computer) -Text ([string](Get-DomeniaMember $Packet 'PresenceDetail' '')))
        $queries=Get-DomeniaMemberValue $Packet 'CimQueries'
        if($null -ne $queries){
            $Run.CimExecuted=[long]$Run.CimExecuted+[long](Get-DomeniaMember $queries 'Executed' 0);$Run.CimAvoided=[long]$Run.CimAvoided+[long](Get-DomeniaMember $queries 'Avoided' 0)
            $script:DomeniaCimQueriesExecuted=[long]$script:DomeniaCimQueriesExecuted+[long](Get-DomeniaMember $queries 'Executed' 0)
            $script:DomeniaCimQueriesAvoided=[long]$script:DomeniaCimQueriesAvoided+[long](Get-DomeniaMember $queries 'Avoided' 0)
        }
    }catch{try{Write-AppLog ('Budget de collecte non mis à jour : '+$_.Exception.Message) 'WARN'}catch{Write-DomeniaSwallowed 'Park' 'Register-DomeniaParkMeasurement' $_}}
}

function Complete-DomeniaParkStored {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId);[void]$r.StorePending.Remove([string]$State.Job)
    if(-not (Test-DomeniaRemoteStoreContext $State $Result)){$r.Stopping=$true;return}
    $observation=Get-DomeniaCommittedObservation $Result $State
    if($null -eq $observation){return}
    # Point 18: an attempt followed by a spaced retry is stored (its date and error are facts) but counted once, with
    # the last attempt. Point 20: successful targets leave the durable plan; final failures remain resumable.
    $retrying=[bool](Get-DomeniaMember $State 'WillRetry' $false)
    # A committed failed attempt counts as finished for this run, but stays in the durable resume plan.
    $requestedFamilies=@(Get-DomeniaMember $State 'ObservedFamilies' @())
    $failedFamilies=@($Result.Observations|Where-Object{[string]$_.Guid -ieq [string]$State.StoreGuid -and [string]$_.Status -eq 'Error' -and (($requestedFamilies.Count -eq 0) -or ($requestedFamilies -contains [string]$_.Family))})
    $incomplete=(@($failedFamilies|Where-Object{[string]$_.Error -cne 'Sonde non applicable au systeme.'}).Count -gt 0)
    if($retrying){
        $State.Target.Previous=$observation
        if($null -ne $State.Target.PSObject.Properties['PreviousJson']){$State.Target.PreviousJson=''}
    }
    if(-not $retrying){
        if(-not $r.PingOnly){$r.CachedMeasurements += [int]$State.Plan.Reused}
        if(@($failedFamilies|Where-Object{[string]$_.Family -ne 'Presence'}).Count){$r.Failed++}
        # A target that will be read again keeps its previous observation: the retry reuses its fresh measurements
        # and its capability evidence. Its buffers are released after the last attempt (or when the run ends).
        Clear-DomeniaParkTargetBuffers @($State.Target)
    }
    Publish-DomeniaParkObservation -Run $r -Observation $observation -Index ([int](Get-DomeniaMember $State 'Index' -1)) -Retrying:$retrying -Incomplete:$incomplete
    if(-not $retrying){try{Register-DomeniaParkConsoleLink -Run $r -Observation $observation}catch{Write-AppLog ('Association de console non créée pour '+[string]$observation.Computer+' : '+$_.Exception.Message) 'WARN'}}
    Update-DomeniaParkRunStatus -Run $r
}

function Publish-DomeniaParkObservation {
    # One committed measure of a survey: counters (CO-19: en ligne, sans réponse, erreur, from the committed
    # presence), row of the list, observation kept for the boards. Point 17: the last validated result; point 20: the
    # workstation at -Index is validated in the durable plan. -Retrying (point 18): an attempt that will be read again
    # is shown but neither counted nor validated, and its row keeps its « relevé en cours » mark.
    # -Incomplete counts a final failed attempt in this run while keeping the target available for explicit resume.
    param($Run,$Observation,[int]$Index=-1,[switch]$Retrying,[switch]$Incomplete)
    $r=$Run
    if(-not $Retrying){
        $r.Done++
        switch(Get-DomeniaParkOutcomeKind -Presence ([string]$Observation.Presence) -PingRequested (-not [bool]$r.WmiOnly)){
            'Online' {$r.Online++}
            'NoReply' {$r.NoReply++}
            'Error' {$r.Errors++}
        }
        if($null -ne $r.PSObject.Properties['LastValidatedUtc']){$r.LastValidatedUtc=[datetime]::UtcNow}
        $preflight=([bool](Get-DomeniaMember $r 'PingBeforeWmi' $false) -and -not [bool](Get-DomeniaMember $r 'PingSwept' $false))
        $online=(Get-DomeniaParkOutcomeKind -Presence ([string]$Observation.Presence) -PingRequested $true) -eq 'Online'
        # An online ping is only preparation; interrupted WMI work must remain resumable.
        if(($Index -ge 0) -and (-not $Incomplete) -and (-not $preflight -or -not $online)){
            $planIndex=$Index
            $original=Get-DomeniaMemberValue $r 'CampaignIndexByKey' $null
            $key=([string]$Observation.Key).ToLowerInvariant()
            if($null -ne $original -and $original.ContainsKey($key)){$planIndex=[int]$original[$key]}
            Set-DomeniaCampaignTargetValidated -Run $r -Index $planIndex
        }
    }
    if($null -eq $script:FleetObservations){$script:FleetObservations=@{}}
    $keep=($null -ne $script:SelectedObject -and [string]$script:SelectedObject.DN -ieq [string]$Observation.Key)
    if($null -ne $script:FleetLast){$keep=$keep -or (Test-DomeniaLiveRowInScope -Dn $Observation.Key -BaseDn ([string]$script:FleetLast.Scope) -Scope $(if($script:FleetLast.Subtree){'Subtree'}else{'OneLevel'}))}
    if($keep){$script:FleetObservations[([string]$Observation.Key).ToLowerInvariant()]=$Observation}
    if($r.Generation -eq [long]$script:GlobalSearchGeneration){Update-DomeniaParkResultRows -Observation $Observation -Run $r}
    if(-not $Retrying){Clear-DomeniaParkPendingRow -Run $r -Key ([string]$Observation.Key)}
    $script:FleetStale=$true
}

function Fail-DomeniaParkStored {
    param([string]$Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId);[void]$r.StorePending.Remove([string]$State.Job);$r.Stopping=$true;$r.Failed++
    $r.FailureMessage='Mesure non publiée : enregistrement SQLite non confirmé. '+$Message
    Set-DomeniaParkStopReason $r 'enregistrement local non confirmé'
    Clear-DomeniaParkPendingRow -Run $r -Key ([string]$State.Target.Key)
    Set-Status $r.FailureMessage 'ERROR'
    Update-DomeniaParkRunStatus -Run $r
}

function Fail-DomeniaParkSession {
    param($Message,$State)
    # Point 18: a worker that ended without answer (delay, engine refusal) is classified from its message and from
    # the ping step it reported before it was stopped.
    $State|Add-Member -NotePropertyName JobFailed -NotePropertyValue $true -Force
    $State|Add-Member -NotePropertyName JobError -NotePropertyValue ([string]$Message) -Force
    $State|Add-Member -NotePropertyName JobPresence -NotePropertyValue ([string](Get-DomeniaParkReadProgressSnapshot $State).Presence) -Force
    # What was really asked (point 19 may have left the console, the inventory or probes out): a failure is dated
    # only for the families that were sent.
    $console=((-not [bool]$State.PingOnly) -and (-not [bool](Get-DomeniaMember $State 'NoConsole' $false)))
    $inventory=[bool]$State.Plan.Inventory;$probes=@($State.Plan.Probes)
    if($null -ne $State.PSObject.Properties['SentConsole']){$console=[bool]$State.SentConsole;$inventory=[bool]$State.SentInventory;$probes=@($State.SentProbes)}
    $packet=[pscustomobject]@{Outcome='Unavailable';Key=$State.Target.Key;Guid=$State.Target.Guid;Computer=$State.Target.Computer;Detail=[string]$Message;Presence='Erreur de ping';PresenceDetail=[string]$Message;PresenceCheckedUtc=$(if(-not $State.WmiOnly){$State.RemoteStartedUtc}else{''});ConsoleAttempted=$console;ConsoleCheckedUtc=$(if($console){$State.RemoteStartedUtc}else{''});InventoryAttempted=$inventory;InventoryCheckedUtc=$State.RemoteStartedUtc;InventoryError=[string]$Message;CacheReused=$false;DirectoryAuthRejected=$false}
    if((-not $console) -and (-not [bool]$State.PingOnly) -and ($probes.Count -gt 0)){
        # Without a console read, the failed probes themselves carry the dated attempt (never a measurement).
        $failed=[ordered]@{};foreach($probe in $probes){$failed[[string]$probe.Id]=[pscustomobject]@{Rows=@();Count=0;Error=[string]$Message;Truncated=$false;DefinitionHash=[string](Get-DomeniaMemberValue $probe 'DefinitionHash');CheckedUtc=[string]$State.RemoteStartedUtc}}
        $packet|Add-Member -NotePropertyName Probes -NotePropertyValue ([pscustomobject]$failed)
    }
    Complete-DomeniaParkSession $packet $State
}

function Get-DomeniaParkResultRowIndex {
    # Rows of the list by lowercase DN: the map of the live search when it exists, else one pass over the grid (never
    # one scan of the list per target).
    if($null -ne $script:Live -and $null -ne $script:Live.Search -and $null -ne $script:Live.Search.Map){return $script:Live.Search.Map}
    $index=@{}
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return $index}
    foreach($row in @($grid.Items)){
        if($null -eq $row -or [string]$row.Type -ne 'Machine' -or -not [string]$row.DN){continue}
        $key=([string]$row.DN).ToLowerInvariant()
        if(-not $index.ContainsKey($key)){$index[$key]=$row}
    }
    return $index
}
function Set-DomeniaParkPendingRows {
    # UX-12: the rows of the list read by an approved survey show « relevé en cours » until their measure is stored.
    param($Run)
    if($null -eq $Run -or [string]$Run.ScopeKind -notin @('Results','Selection') -or $Run.Generation -ne [long]$script:GlobalSearchGeneration){return}
    $index=Get-DomeniaParkResultRowIndex
    foreach($target in @($Run.Targets)){
        $key=([string]$target.Key).ToLowerInvariant()
        $row=$index[$key]
        if($null -eq $row -or [string]$row.Guid -ine [string]$target.Guid){continue}
        Set-DomeniaLiveRowValue $row 'ProbePending' '1';$Run.PendingRows[$key]=$row
    }
}
function Clear-DomeniaParkPendingRow {
    param($Run,[string]$Key)
    if($null -eq $Run -or $null -eq $Run.PendingRows){return}
    $k=([string]$Key).ToLowerInvariant()
    if(-not $Run.PendingRows.ContainsKey($k)){return}
    Set-DomeniaLiveRowValue $Run.PendingRows[$k] 'ProbePending' '';[void]$Run.PendingRows.Remove($k)
}
function Clear-DomeniaParkPendingRows {
    param($Run)
    if($null -eq $Run -or $null -eq $Run.PendingRows -or -not $Run.PendingRows.Count){return}
    foreach($key in @($Run.PendingRows.Keys)){Clear-DomeniaParkPendingRow -Run $Run -Key $key}
}

function Update-DomeniaParkResultRows {
    param($Packet,$Observation,$Run=$null)
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
        # The view is refreshed once per stored batch or at the end of the survey (Sync-DomeniaParkGrid), never per row.
        if($null -ne $Run){$Run.GridStale=$true}
    }
}
function Sync-DomeniaParkGrid {
    # ResultRow notifies WPF; classic PSCustomObject rows and an active filter need one refresh of the view. One
    # refresh per stored batch of echoes, or once when the survey ends.
    param($Run)
    if($null -eq $Run -or -not [bool]$Run.GridStale){return}
    $Run.GridStale=$false
    if($Run.Generation -ne [long]$script:GlobalSearchGeneration){return}
    $grid=Get-DomeniaControl 'DgObjects'
    if($null -ne $grid -and $null -ne $grid.ItemsSource){
        try{
            # Refresh the source view: ItemCollection.Refresh can leave its cached filter unchanged.
            $view=[Windows.Data.CollectionViewSource]::GetDefaultView($grid.ItemsSource)
            if($null -ne $view){$view.Refresh()}
        }catch{try{Write-AppLog ('Liste non actualisée après le relevé : '+$_.Exception.Message) 'WARN'}catch{Write-DomeniaSwallowed 'Park' 'Sync-DomeniaParkGrid' $_}}
    }
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
    # SQL readback also contains older families. Only this attempt decides completion of this campaign target.
    if(-not [string](Get-DomeniaMemberValue $State 'StoreBatchId')){$State|Add-Member -NotePropertyName ObservedFamilies -NotePropertyValue @($changes|ForEach-Object{[string]$_.Family}|Select-Object -Unique) -Force}
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
    # MO-08: up to eight frozen batches are handed to the storage per call (one call per 250 ms otherwise caps a
    # survey at four workstations a second); the storage keeps its own backpressure and order.
    for($round=0;$round -lt 8 -and $script:DomeniaRemoteStoreQueue.Count -gt 0;$round++){
        $item=$script:DomeniaRemoteStoreQueue.Peek()
        if($item.Failed){return}
        try{
            $admission=Submit-DomeniaStoreBatch -Context $item.Context -BatchId $item.BatchId -Sequence 0 -Changes $item.Changes -SuccessHandler 'Complete-DomeniaRemoteStoreBatch' -ErrorHandler 'Fail-DomeniaRemoteStoreBatch' -CallbackState $item
            if([bool]$admission.Accepted){[void]$script:DomeniaRemoteStoreQueue.Dequeue();continue}
            if([bool]$admission.Backpressure){return}
            throw ('Enregistrement refuse : '+[string]$admission.Reason)
        }catch{
            # Retain an unadmitted immutable batch; stop producers instead of dropping measurements.
            $item.Failed=$true
            if($item.ErrorHandler){& $item.ErrorHandler -Message $_.Exception.Message -State $item.State}
            Write-AppLog ('Mesures non enregistrees ; collecte suspendue : '+$_.Exception.Message) 'ERROR'
            return
        }
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
        # Point 1: this ping-only read runs the pinned live probe body, registered as LiveSelectedPing (credential free).
        # SelectedPresence pins another body (Get-DomeniaSelectedPresenceWorkerCode): the engine refused this pairing.
        $job=Start-UiTask -Name ('Presence de '+$Computer) -OperationId 'LiveSelectedPing' -Code (Get-DomeniaLiveProbeCode) -Payload ([pscustomobject]@{Computer=$Computer;Key=$DN;Guid=$Guid;CollectPing=$true;ProbeUser=$false;Inventory=$false;Probes=@();ValidateConsoleIdentity=$false}) -CallbackState $state -ReplaceKey 'presence-selected' -TimeoutSeconds 8 -SuccessHandler 'Complete-DomeniaCommittedPresence' -ErrorHandler 'Fail-DomeniaCommittedPresence'
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
    Set-DomeniaPresenceText -Name $(if($State.DisplayKind -eq 'Utilisateur'){'TxtUserPresence'}else{'TxtCompPresence'}) -State $label -PresenceState ([string]$view.PresenceState)
    Update-DomeniaObjectPresence -State $label -Target $State.Computer -PresenceState ([string]$view.PresenceState)
    # DS-08 (X04): the header pill of the workstation takes the time of this observation, even when the answer is the
    # same as the previous test (same text, no TextChanged).
    if($State.DisplayKind -ne 'Utilisateur'){try{Set-DomeniaComputerHeaderPresenceTime -Observation $observation}catch{Write-DomeniaSwallowed 'Park' 'Publish-DomeniaCommittedPresence' $_}}
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
        $reason='Lecture distante non confirmee ; les dernieres donnees valides sont conservees.'
        if(-not $success){
            $named=[string](Get-DomeniaMemberValue $packet 'FailureReason')
            if($named){$reason=$named}else{
                $bad=@(@(Get-DomeniaMemberValue $packet 'Access')|Where-Object{$null -ne $_ -and [string](Get-DomeniaMemberValue $_ 'Detail') -and [string](Get-DomeniaMemberValue $_ 'Status') -notin @('OK','VIDE','IGNORE')}|Select-Object -Last 1)
                if($bad.Count -and [string](Get-DomeniaMemberValue $bad[0] 'Detail')){$reason=[string](Get-DomeniaMemberValue $bad[0] 'Detail')}
            }
            $safe|Add-Member -NotePropertyName CollectionError -NotePropertyValue $reason -Force
        }
        [void](Submit-DomeniaRemoteDetail -Data $safe -State $State -Succeeded $success -SourceCompletedUtc ([string]$packet.SourceCompletedUtc) -ErrorText $(if($success){''}else{$reason}))
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

# ---------------------------------------------------------------- FI-13 : « Oublier les relevés »
function Request-DomeniaParkReset {
    # FI-13: confirmed in the page (no dialog box), with the backup notice of the gesture. The associations are kept.
    $message='Effacer lʼétat du parc ? Les associations déjà créées sont conservées ; seul lʼhistorique des relevés (dernier passage, statut, tentatives) est effacé, en mémoire et dans la base locale. Le prochain relevé repartira de zéro. '+(Get-DomeniaGestureBackupNotice (Get-DomeniaGestureBackupState))
    $run=${function:Invoke-DomeniaParkReset}
    [void](Request-DomeniaInlineConfirmation -Title 'Oublier les relevés' -Message $message -Target 'park:reset' -ConfirmText 'Oublier les relevés' -CancelText 'Conserver' -OnConfirm ({& $run}.GetNewClosure()) -OnCancel {Set-Status 'Relevés du parc conservés.'})
}
function Invoke-DomeniaParkReset {
    # FI-13: the verified backup comes first (StorageBackup worker); the reset runs from its success callback.
    [void](Invoke-DomeniaGestureBackup -Gesture 'ParkReset' -Then {Clear-DomeniaParkRecords})
}
function Clear-DomeniaParkRecords {
    # Clears the memory state and asks the single writer to delete park_state (ParkReset item). Park rows still waiting
    # for this base are obsolete and leave the queue first; a lot already being written commits before the reset.
    $script:ParkState=@{}
    $path=[string]$script:DatabaseScopedPath
    if($null -ne $script:Persistence){
        foreach($key in @($script:Persistence.Pending.Keys)){
            $item=$script:Persistence.Pending[$key]
            if(($null -ne $item) -and ([string]$item.Kind -eq 'Park') -and ([string]$item.Path -ceq $path)){$script:Persistence.Pending.Remove($key)}
        }
    }
    $queued=Queue-DomeniaMetadata -Kind ParkReset -Key 'park-reset' -Row ([pscustomobject]@{At=[datetime]::UtcNow.ToString('o')})
    [void](Set-DomeniaControlText -Name 'LblParkStatus' -Text (Get-DomeniaParkCoverageText))
    if($queued){Set-Status 'État du parc effacé ; la suppression des relevés enregistrés part dans la base locale.'}
    else{Set-Status 'État du parc effacé en mémoire seulement : la base locale nʼa pas accepté la suppression (file pleine ou base indisponible). Réessayez.' 'WARN'}
}
