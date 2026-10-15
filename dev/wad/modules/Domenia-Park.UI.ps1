# Explicit whole-index scan, bounded concurrent reads and persistent changed-only associations.
# FI-18: one survey per scope in $script:ParkRuns: 'List' (Rechercher, its selection and the perimeter surveys of an OU,
# a board or a query) and 'Computer' (the workstation open in Poste). Each scope has its timer, its state and its
# Arrêter beside the button that started it; a survey of one scope never blocks the other.
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
    $grid=Get-DomeniaControl 'DgObjects'
    $machines=@();if($null -ne $grid){$machines=@(foreach($row in @($grid.Items)){if($null -ne $row -and [string]$row.Type -eq 'Machine'){$row}})}
    $targets=@(foreach($row in $machines){if($row.DN -and $row.Guid){[pscustomobject]@{name=[string]$row.Name;distinguished_name=[string]$row.DN;object_guid=[string]$row.Guid}}})
    return [pscustomobject]@{Machines=$machines;Targets=$targets;Skipped=($machines.Count-$targets.Count)}
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
    $short=Get-DomeniaParkProgressText -Done ([int]$r.Done) -Total (@($r.Targets).Count) -Online ([int]$r.Online) -NoReply ([int]$r.NoReply) -Errors ([int]$r.Errors) -Failed ([int]$r.Failed) -Unchecked ([int]$r.Unchecked) -PingRequested (-not [bool]$r.WmiOnly) -Completed ([bool]$r.Completed) -Stopped ([bool]$r.Stopping)
    $text=$status+' : '+$short+'.'
    if(-not $r.PingOnly){$text+=' '+$r.Reused+' identités en cache, '+$r.Changed+' associations actualisées, '+$r.CachedMeasurements+' mesures encore fraîches réutilisées.'}
    if(-not $r.Completed){$text+=' '+$(if($r.PingOnly){'Échos envoyés par lots de 32.'}else{[string]$r.Pending.Count+'/'+[string]$r.Concurrency+' lectures en parallèle.'})}
    $save=Get-DomeniaPersistenceState
    if($save.Pending -gt 0){$text+=' Enregistrement local en attente.'}
    if($save.Suspended -or $save.Conflicts -gt 0){$text+=' Stockage à vérifier dans Fiabilité.'}
    if([string]$r.FailureMessage){$text+=' '+[string]$r.FailureMessage}
    $r.StatusText=$text;$r.ShortText=$short
    if($r.Completed){Sync-DomeniaParkGrid -Run $r}
    # A finished run that read workstations changed the observations: the selected workstation board is redrawn at
    # once, the home overview now or when Accueil is shown again.
    if($r.Completed -and [bool]$r.FleetRefresh -and -not [bool]$r.FleetRefreshed){
        $r|Add-Member -NotePropertyName FleetRefreshed -NotePropertyValue $true -Force
        if($r.Approved -and $r.Done -gt 0){
            if($null -ne $script:SelectedObject){try{Show-DomeniaBoard -Board Computer -Quiet}catch{}}
            try{Request-DomeniaFleetRefresh -Force}catch{}
        }
    }
    if($r.Completed -and $r.Approved -and -not [bool]$r.Logged){$r.Logged=$true;try{Write-AppLog ('Relevé des postes ('+$(if($r.Slot -eq 'Computer'){'poste'}else{'liste'})+') : '+$text) 'INFO'}catch{}}
    Update-DomeniaParkControls
    foreach($label in @('LblParkStatus','LblParkDetectionStatus')){[void](Set-DomeniaControlText $label $text)}
}
function Get-DomeniaParkVerifyButtonText {
    # UI-23: the main part of the button names the reading it runs (the last one chosen in this session).
    $entry=@(Get-DomeniaParkVerifyModes|Where-Object{$_.Mode -eq [string]$script:ParkDefaultMode})
    if($entry.Count){return 'Vérifier : '+[string]$entry[0].Label}
    return 'Vérifier la liste'
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
        # UX-12: thin bar and short count of the survey of the list.
        $bar=Get-DomeniaControl 'PbParkProgress'
        if($null -ne $bar){$bar.Value=$(if($total -gt 0 -and $null -ne $list){[Math]::Min(100.0,100.0*[double]$list.Done/[double]$total)}else{0.0})}
        Set-DomeniaParkControlVisible 'PbParkProgress' ($listShown -and $listRunning -and [bool]$list.Approved)
        Set-DomeniaParkControlVisible 'UxParkProgress' $listShown
        Set-DomeniaParkControlVisible 'LblLiveState' (-not $listShown)
        if($listShown){
            $short=if([bool]$list.Loading){'Préparation du relevé…'}elseif($listRunning -and -not [bool]$list.Approved){'Confirmation en attente · '+[string]$total+' '+$(if($total -gt 1){'postes'}else{'poste'})}else{[string]$list.ShortText}
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
            $text=if([bool]$computer.Loading){'Préparation du relevé…'}elseif(-not [bool]$computer.Approved){'Confirmation en attente'}else{[string]$computer.ShortText}
            if(-not $sameComputer -and [string]$computer.ScopeLabel){$text=[string]$computer.ScopeLabel+' · '+$text}
            [void](Set-DomeniaControlText 'LblComputerParkStatus' $text)
        }
        $stop=Get-DomeniaControl 'BtnComputerParkStop'
        if($null -ne $stop){$stop.IsEnabled=($null -ne $computer -and -not [bool]$computer.Completed -and -not [bool]$computer.Stopping)}
    }catch{try{Write-AppLog ('Commandes du relevé non actualisées : '+$_.Exception.Message) 'WARN'}catch{}}
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
    $rows=@(Get-DomeniaSelectedGridRows|Where-Object{$null -ne $_ -and [string]$_.Type -eq 'Machine'})
    $targets=@(foreach($row in $rows){if([string]$row.DN -and [string]$row.Guid){[pscustomobject]@{name=[string]$row.Name;distinguished_name=[string]$row.DN;object_guid=[string]$row.Guid}}})
    return [pscustomobject]@{Rows=$rows;Targets=$targets;Skipped=($rows.Count-$targets.Count)}
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
    $machines=@($selected|Where-Object{[string]$_.Type -eq 'Machine'}).Count
    $text=[string]$selected.Count+' lignes sélectionnées'
    if($machines -eq $selected.Count){$text=[string]$machines+' postes sélectionnés'}
    elseif($machines -gt 0){$text+=' dont '+[string]$machines+' '+$(if($machines -gt 1){'postes'}else{'poste'})}
    [void](Set-DomeniaControlText 'LblSelectionBar' ($text+' :'))
    $survey=(($machines -gt 0) -and (-not $ListRunning) -and [bool]$grid.IsEnabled -and (-not [bool]$script:ListSurveyBlocked) -and (-not [bool]$script:DemoMode))
    foreach($name in @('BtnSelectionPing','BtnSelectionConsole')){$button=Get-DomeniaControl $name;if($null -ne $button){$button.IsEnabled=$survey}}
}
function Start-DomeniaParkSelectionSurvey {
    # FO-18: ping or console reading of the selected workstations only, with the confirmation and the ceiling of the list.
    param([ValidateSet('Ping','Console')][string]$Mode)
    $selection=Get-DomeniaParkSelectionTargets
    if(-not $selection.Rows.Count){Set-Status 'Aucun poste dans la sélection.' 'WARN';return}
    Start-DomeniaOnlinePark -Selection -ScopeTargets @($selection.Targets) -SkippedTargets ([int]$selection.Skipped) -PingOnly:($Mode -eq 'Ping')
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
    switch($Mode){
        'Ping' {Start-DomeniaOnlinePark -DisplayedResults -PingOnly}
        'Console' {Start-DomeniaOnlinePark -DisplayedResults}
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
    param([switch]$DisplayedResults,[switch]$Selection,[switch]$PingOnly,[switch]$WmiOnly,[switch]$Inventory,[object[]]$ScopeTargets=$null,[string]$ScopeLabel='',[object[]]$Probes=$null,[switch]$ForceRefresh,[string]$RefreshOperationId='',[switch]$PassThru,[ValidateSet('','List','Computer')][string]$Slot='',[int]$SkippedTargets=0)
    $started=$false;$r=$null
    try{
        if($PingOnly -and $WmiOnly){throw 'Choisissez Ping ou WMI, pas les deux modes exclusifs.'}
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
        [void](Initialize-DomeniaWinSqliteNative)
        $targets=@();$skipped=[Math]::Max(0,$SkippedTargets);$scopeKind='Scope';$label=[string]$ScopeLabel;$subtree=$false;$listLimit=0
        if($null -ne $ScopeTargets){
            $all=@($ScopeTargets|Where-Object{$null -ne $_})
            $targets=@($all|Where-Object{$_.distinguished_name -and $_.object_guid})
            $skipped+=($all.Count-$targets.Count)
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
            # UX-24: workstations without an AD identity are left out and the confirmation says so.
            $skipped+=[int]$displayed.Skipped
            # SE-05: ceiling, domain root without any other filter, global search without a term.
            $context=Get-DomeniaParkListContext
            $admission=Test-DomeniaParkTargetAdmission -Count $targets.Count -Maximum (Get-DomeniaParkMaxTargets) -ScopeDn $context.ScopeDn -BaseDn $context.BaseDn -HasFilter ([bool]$context.HasFilter) -Global ([bool]$context.Global) -HasSearchTerm ([bool]$context.HasSearchTerm)
            if(-not [bool]$admission.Allowed){throw ([string]$admission.Reason)}
            $scopeKind='Results';$label=[string]$context.Label;$subtree=[bool]$context.Subtree;$listLimit=[int]$context.ListLimit
        }
        $concurrency=([Math]::Max(1,[Math]::Min(8,[int](Get-DomeniaSetting 'Collection.Concurrency' '4'))))
        $r=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Slot=$slotName;Epoch=[long]$script:SessionEpoch;Path=[string]$script:DatabaseScopedPath;Targets=@();Requested=$targets.Count;Next=0;Pending=@{};Concurrency=$concurrency;CacheMinutes=([Math]::Max(0,[Math]::Min(1440,[int](Get-DomeniaSetting 'Collection.CacheMinutes' '15'))));CachedMeasurements=0;Done=0;Online=0;NoReply=0;Errors=0;Unchecked=0;Reused=0;Changed=0;Failed=0;Stopping=$false;Completed=$false;Loading=$true;Approved=$false;Logged=$false;ObservationReader=(New-DomeniaObservationReader);Timer=$null;StatusText='';ShortText='';Generation=[long]$script:GlobalSearchGeneration;PingOnly=[bool]$PingOnly;WmiOnly=[bool]$WmiOnly;AccountGeneration=[long]$script:DomeniaAccountGeneration;StorePending=@{};Inventory=[bool]$Inventory;Probes=@(Add-DomeniaRemoteProbeDefinitionHash $Probes);FleetRefresh=$true;ScopeLabel=$label;ScopeKind=$scopeKind;Scope='Results';Skipped=$skipped;Subtree=$subtree;ListLimit=$listLimit;RefreshOperationId=$RefreshOperationId;FailureMessage='';PingJob='';PingQueue=$null;PingBuffer=$null;PingReported=@{};TargetsByKey=@{};PendingRows=@{};TargetDn=$(if($targets.Count -eq 1){[string]$targets[0].distinguished_name}else{''});TargetGuid=$(if($targets.Count -eq 1){[string]$targets[0].object_guid}else{''});InlineRequestId='';GridStale=$false}
        $runs=Get-DomeniaParkRuns;$runs[$slotName]=$r
        $started=$true
        if($ForceRefresh){$r.CacheMinutes=0}
        $state=[pscustomobject]@{RunId=$r.Id;Slot=$r.Slot;Epoch=$r.Epoch;Path=$r.Path}
        # Read only the observation families used by this collection mode. No WMI payload is parsed for a ping refresh.
        $families=$null
        if($r.PingOnly){$families=@('Presence')}elseif($r.WmiOnly){$families=@('Console','Inventory')+@($r.Probes|ForEach-Object{'Probe:'+([string]$_.Id)})}
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
    $probes=$null
    try{
        $ids=@(Get-DomeniaBoardProbeIds)
        if($ids.Count){$probes=@(ConvertTo-DomeniaProbePayload -Ids $ids)}
    }catch{Set-Status ('Requêtes des widgets ignorées : '+$_.Exception.Message) 'WARN';$probes=$null}
    Start-DomeniaOnlinePark -DisplayedResults -Inventory -Probes $probes
}
function Complete-DomeniaParkTargets {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId)
    try{
        $packet=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Busy')
        if($null -eq $packet -or $packet.Busy){throw 'Base occupée : aucun poste interrogé.'}
        $r.Loading=$false;$r.Targets=@($packet.Rows|Where-Object{$null -ne $_})
        foreach($target in $r.Targets){$r.TargetsByKey[([string]$target.Key).ToLowerInvariant()]=$target}
        if($r.Stopping -or -not $r.Targets.Count){$r.Completed=$true;Update-DomeniaParkRunStatus -Run $r;return}
        $start=${function:Start-DomeniaParkRunTimer};$stop=${function:Stop-DomeniaOnlinePark};$runId=$r.Id
        # UX-24: three lines (which workstations and why the count differs, what is read, how long); the target is the
        # list, the selection or the OU, never the domain; the confirm button carries the count.
        $ignored=[Math]::Max(0,[int]$r.Requested-$r.Targets.Count)
        $text=New-DomeniaParkConfirmationText -Count $r.Targets.Count -Skipped ([int]$r.Skipped) -Ignored $ignored -ScopeKind ([string]$r.ScopeKind) -ScopeLabel ([string]$r.ScopeLabel) -Subtree ([bool]$r.Subtree) -ListLimit ([int]$r.ListLimit) -PingOnly ([bool]$r.PingOnly) -WmiOnly ([bool]$r.WmiOnly) -Inventory ([bool]$r.Inventory) -ProbeCount (@($r.Probes).Count) -Concurrency ([int]$r.Concurrency) -CacheMinutes ([int]$r.CacheMinutes)
        Update-DomeniaParkRunStatus -Run $r
        $answers=@(Request-DomeniaInlineConfirmation -Title ([string]$text.Title) -Target ([string]$text.Target) -Message ([string]$text.Message) -ConfirmText ([string]$text.ConfirmText) -CancelText 'Annuler' -OnConfirm ({& $start $runId}.GetNewClosure()) -OnCancel ({& $stop -RunId $runId}.GetNewClosure()))
        # UX-12: a request still shown in the page belongs to this survey: stopping the survey withdraws it.
        $request=$null;foreach($answer in $answers){if($null -ne $answer -and $null -ne $answer.PSObject.Properties['Presentation']){$request=$answer}}
        if($null -ne $request -and -not [bool]$request.Answered -and [string]$request.Id){$r.InlineRequestId=[string]$request.Id}
    }catch{Fail-DomeniaParkTargets $_.Exception.Message $State}
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
    param([string]$RunId)
    $r=Get-DomeniaParkRunById $RunId
    if($null -eq $r -or $r.Stopping -or $r.Completed -or $r.Epoch -ne [long]$script:SessionEpoch -or $r.Path -cne [string]$script:DatabaseScopedPath){return}
    if([string]$r.RefreshOperationId -and -not (Test-DomeniaOuRefreshCurrent ([string]$r.RefreshOperationId))){Stop-DomeniaOnlinePark -RunId $RunId;return}
    if($null -ne $r.Timer){return}
    $r.Approved=$true;$r.InlineRequestId=''
    # UX-12: every target of the run carries its « relevé en cours » marker until its measure is stored.
    Set-DomeniaParkPendingRows -Run $r
    # FI-05: protected heartbeat timer, owned and registered by the factory; it also runs minimized (an approved run).
    # FI-18: one owner per scope, so that the survey of the list and the one of the open workstation run side by side.
    $tick=if($r.Slot -eq 'Computer'){{Invoke-DomeniaParkRunTick -Slot 'Computer'}}else{{Invoke-DomeniaParkRunTick -Slot 'List'}}
    $timer=New-DomeniaTimer -Owner ('Timer:ParkRun:'+$r.Slot) -IntervalMs 250 -RunWhenHidden -Tick $tick;$r.Timer=$timer
    $timer.Start();Update-DomeniaParkRunStatus -Run $r
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
            try{Complete-DomeniaInlineRequest -Dismiss -Reason 'Relevé annulé avant sa confirmation.'}catch{try{Write-AppLog ('Demande du relevé non retirée : '+$_.Exception.Message) 'WARN'}catch{}}
            if([bool]$r.Completed){return}
        }
    }
    $r.Stopping=$true
    Stop-DomeniaParkPingWorker -Run $r
    if(-not $r.Pending.Count -and -not $r.Loading -and -not (Test-DomeniaParkPingBuffered -Run $r)){
        $save=Get-DomeniaPersistenceState
        if(-not $r.Approved -or ($save.Pending -eq 0 -and $r.StorePending.Count -eq 0) -or $save.Suspended){$r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()}}
    }
    Update-DomeniaParkRunStatus -Run $r
}
function Stop-DomeniaParkPingWorker {
    # MO-08: the batch ping is a single worker: it is asked to stop; echoes already reported are kept.
    param($Run)
    if($null -ne $Run -and [string]$Run.PingJob -and $script:AsyncJobs.Contains([string]$Run.PingJob)){try{Request-UiTaskStop -Id ([string]$Run.PingJob) -Silent -Reason 'Relevé arrêté'}catch{}}
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
function Invoke-DomeniaParkRunTick {
    param([ValidateSet('List','Computer')][string]$Slot='List')
    $r=Get-DomeniaParkRun -Slot $Slot;if($null -eq $r){return}
    if($r.Epoch -ne [long]$script:SessionEpoch -or $r.Path -cne [string]$script:DatabaseScopedPath -or $r.AccountGeneration -ne [long]$script:DomeniaAccountGeneration -or $script:AsyncEngineClosing){$r.Stopping=$true;$r.Completed=$true;Clear-DomeniaParkTargetBuffers $r.Targets;Clear-DomeniaParkPendingRows -Run $r;if($null -ne $r.Timer){$r.Timer.Stop()};return}
    if([string]$r.RefreshOperationId -and -not (Test-DomeniaOuRefreshCurrent ([string]$r.RefreshOperationId))){$r.Stopping=$true}
    # Cancelled workers never silently cause the rest of the fleet to start.
    foreach($id in @($r.Pending.Keys)){
        if(-not $script:AsyncJobs.Contains($id) -and -not @($script:DetachedReadJobs|Where-Object{$_.Id -eq $id}).Count){
            $r.Pending.Remove($id);$r.Stopping=$true
            if([string]$r.PingJob -ceq [string]$id){Complete-DomeniaParkPingWithdrawn -Run $r}else{$r.Failed++}
        }
    }
    # MO-08: echoes reported by the batch ping are stored by batches, the storage keeping its own backpressure.
    if($r.PingOnly){Submit-DomeniaParkPingResults -Run $r}
    Close-DomeniaParkStoreBacklog -Run $r
    if(($r.Stopping -or $r.Next -ge $r.Targets.Count) -and -not $r.Pending.Count -and -not (Test-DomeniaParkPingBuffered -Run $r)){
        $save=Get-DomeniaPersistenceState
        if($r.StorePending.Count -gt 0 -or ($save.Pending -gt 0 -and -not $save.Suspended)){Update-DomeniaParkRunStatus -Run $r;return}
        $r.Completed=$true;if($null -ne $r.Timer){$r.Timer.Stop()};Update-DomeniaParkRunStatus -Run $r;return
    }
    if($r.Stopping -or -not $r.Approved){return}
    if($r.PingOnly){Start-DomeniaParkPingJob -Run $r;return}
    if($null -ne $script:DomeniaRemoteStoreQueue -and $script:DomeniaRemoteStoreQueue.Count -gt 0){return}
    if($r.StorePending.Count -ge 16){return}
    if($script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){return}
    if($null -ne $script:Persistence){
        if($script:Persistence.Failures -ge 3 -or $script:Persistence.Conflicts.Count){$r.Stopping=$true;Update-DomeniaParkRunStatus -Run $r;return}
        if($script:Persistence.Pending.Count -ge 64 -or $script:Persistence.LinkBusy){return}
    }
    # One admission per tick keeps the Dispatcher responsive. The engine may impose a smaller provider budget.
    if($r.Pending.Count -ge $r.Concurrency -or $r.Next -ge $r.Targets.Count){return}
    $target=$r.Targets[$r.Next]
    try{Expand-DomeniaParkPrevious $target}catch{$r.Stopping=$true;Set-Status ('Cache du poste illisible : '+$target.Computer+'. Relancez le relevé après actualisation.') 'WARN';return}
    $plan=New-DomeniaCollectionPlan -Previous $target.Previous -Guid $target.Guid -Key $target.Key -Probes @($r.Probes) -Inventory ([bool]$r.Inventory) -CacheMinutes ([int]$r.CacheMinutes)
    $state=[pscustomobject]@{RunId=$r.Id;Slot=$r.Slot;Epoch=$r.Epoch;Path=$r.Path;Target=$target;Job='';Plan=$plan;PingOnly=$r.PingOnly;WmiOnly=$r.WmiOnly;RemoteStartedUtc=[datetime]::UtcNow.ToString('o')}
    [void](Initialize-DomeniaRemoteStoreState -State $state -Guid $target.Guid -DN $target.Key -Generation $r.Generation)
    try{
        $id=Start-UiTask -Name ($(if($r.WmiOnly){'WMI du perimetre : '}else{'Console du parc : '})+$target.Computer) -OperationId 'LiveConsole' -Code (Get-DomeniaLiveProbeCode) -Payload ([pscustomobject]@{Computer=$target.Computer;Key=$target.Key;Guid=$target.Guid;Previous=$target.Previous;AllowIdentityCache=([int]$r.CacheMinutes -gt 0);MethodSeconds=4;CollectPing=(-not [bool]$r.WmiOnly);ValidateConsoleIdentity=$false;ProbeUser=$true;Inventory=([bool]$plan.Inventory);Probes=@($plan.Probes);AllowedClasses=@(@(Get-DomeniaProbeCatalog)|ForEach-Object{[string]$_.Class})}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkSession' -ErrorHandler 'Fail-DomeniaParkSession' -TimeoutSeconds $(if(@($r.Probes).Count){[Math]::Min(150,20+8*@($r.Probes).Count)}else{20}) -TaskClass 'Explicit'
        if(-not $id){throw 'Lecture non admise.'}
        $state.Job=[string]$id;$r.Pending[[string]$id]=$state;$r.Next++
    }catch{$r.Stopping=$true;$r.FailureMessage='Relevé interrompu : '+$_.Exception.Message+' Les résultats précédents sont conservés.';[void](Set-DomeniaControlText 'LblParkStatus' $r.FailureMessage)}
}
function Start-DomeniaParkPingJob {
    # MO-08: the targets not sent yet go to one ParkPing worker (echoes in parallel, 32 at a time). The storage of the
    # reported batches keeps its own backpressure; the four parallel reads stay for console and WMI surveys.
    param($Run)
    $r=$Run
    if([string]$r.PingJob -or $r.Next -ge $r.Targets.Count){return}
    if($script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){return}
    $batch=@(for($i=$r.Next;$i -lt $r.Targets.Count;$i++){$t=$r.Targets[$i];[pscustomobject]@{Key=[string]$t.Key;Guid=[string]$t.Guid;Computer=[string]$t.Computer}})
    if($null -eq $r.PingQueue){$r.PingQueue=[Collections.Concurrent.ConcurrentQueue[object]]::new()}
    if($null -eq $r.PingBuffer){$r.PingBuffer=[Collections.Generic.Queue[object]]::new()}
    $state=[pscustomobject]@{RunId=$r.Id;Slot=$r.Slot;Epoch=$r.Epoch;Path=$r.Path;Job='';Count=$batch.Count}
    # The engine budget follows the worker's own waits (name resolution and echo delay per batch of 32).
    $timeoutMs=1000;$batchSize=32
    $timeout=Get-DomeniaParkPingTimeoutSeconds -Count $batch.Count -TimeoutMs $timeoutMs -BatchSize $batchSize
    try{
        $id=Start-UiTask -Name ('Ping de la liste : '+[string]$batch.Count+' postes') -OperationId 'ParkPing' -Code (Get-DomeniaParkPingWorkerCode) -Payload ([pscustomobject]@{Targets=$batch;TimeoutMs=$timeoutMs;BatchSize=$batchSize;Progress=$r.PingQueue}) -CallbackState $state -SuccessHandler 'Complete-DomeniaParkPingJob' -ErrorHandler 'Fail-DomeniaParkPingJob' -TimeoutSeconds $timeout -TaskClass 'Explicit'
        if(-not $id){throw 'Ping non admis.'}
        $state.Job=[string]$id;$r.PingJob=[string]$id;$r.Pending[[string]$id]=$state;$r.Next=$r.Targets.Count
    }catch{$r.Stopping=$true;$r.Unchecked+=$batch.Count;$r.FailureMessage='Ping non lancé : '+$_.Exception.Message;[void](Set-DomeniaControlText 'LblParkStatus' $r.FailureMessage)}
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
    }
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
    Complete-DomeniaParkPingWithdrawn -Run $r
    Update-DomeniaParkRunStatus -Run $r
}
function Fail-DomeniaParkPingJob {
    param($Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId)
    [void]$r.Pending.Remove([string]$State.Job);$r.PingJob=''
    Receive-DomeniaParkPingQueue -Run $r
    if(-not $r.Stopping){$r.FailureMessage='Ping de la liste interrompu : '+[string]$Message}
    $r.Stopping=$true
    Complete-DomeniaParkPingWithdrawn -Run $r
    Update-DomeniaParkRunStatus -Run $r
}
function Complete-DomeniaParkPingWithdrawn {
    # The batch ping ended, failed or was stopped: the targets it never reported stay as they were, counted as not
    # checked (no measure is invented for them).
    param($Run)
    $r=$Run;$r.PingJob=''
    Receive-DomeniaParkPingQueue -Run $r
    $missing=@($r.TargetsByKey.Keys|Where-Object{-not $r.PingReported.ContainsKey($_)}).Count
    $r.Unchecked=$missing
    if($missing -gt 0){foreach($key in @($r.TargetsByKey.Keys|Where-Object{-not $r.PingReported.ContainsKey($_)})){Clear-DomeniaParkPendingRow -Run $r -Key $key}}
}
function Complete-DomeniaParkPingStored {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId);[void]$r.StorePending.Remove([string]$State.Job)
    if(-not (Test-DomeniaRemoteStoreContext $State $Result)){$r.Stopping=$true;return}
    foreach($target in @($State.Targets)){
        $rows=@($Result.ObservationRows|Where-Object{[string]$_.Guid -ieq [string]$target.Guid -and [string]$_.Key -ieq [string]$target.Key})
        if($rows.Count -ne 1){$r.Failed++;Clear-DomeniaParkPendingRow -Run $r -Key ([string]$target.Key);continue}
        Publish-DomeniaParkObservation -Run $r -Observation $rows[0]
    }
    Sync-DomeniaParkGrid -Run $r
    Update-DomeniaParkRunStatus -Run $r
}
function Fail-DomeniaParkPingStored {
    param([string]$Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId);[void]$r.StorePending.Remove([string]$State.Job)
    $r.Stopping=$true;$r.Failed+=@($State.Targets).Count;$r.FailureMessage='Mesures de ping non publiées : enregistrement SQLite non confirmé. '+$Message
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
        if($current -and ($packet.Outcome -eq 'AuthRejected' -or $packet.DirectoryAuthRejected)){$r.Stopping=$true}
        [void](Submit-DomeniaRemoteObservations -Result $packet -State $State -SuccessHandler 'Complete-DomeniaParkStored' -ErrorHandler 'Fail-DomeniaParkStored')
    }catch{Fail-DomeniaParkStored -Message $_.Exception.Message -State $State}
}

function Complete-DomeniaParkStored {
    param($Result,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId);[void]$r.StorePending.Remove([string]$State.Job)
    if(-not (Test-DomeniaRemoteStoreContext $State $Result)){$r.Stopping=$true;return}
    $observation=Get-DomeniaCommittedObservation $Result $State
    if($null -eq $observation){return}
    if(-not $r.PingOnly){$r.CachedMeasurements += [int]$State.Plan.Reused}
    if(@($Result.Observations|Where-Object{[string]$_.Guid -ieq [string]$State.StoreGuid -and [string]$_.Status -eq 'Error' -and [string]$_.Family -ne 'Presence'}).Count){$r.Failed++}
    Clear-DomeniaParkTargetBuffers @($State.Target)
    Publish-DomeniaParkObservation -Run $r -Observation $observation
    Update-DomeniaParkRunStatus -Run $r
}

function Publish-DomeniaParkObservation {
    # One committed measure of a survey: counters (CO-19: en ligne, sans réponse, erreur, from the committed
    # presence), row of the list, observation kept for the boards.
    param($Run,$Observation)
    $r=$Run
    $r.Done++
    switch(Get-DomeniaParkOutcomeKind -Presence ([string]$Observation.Presence) -PingRequested (-not [bool]$r.WmiOnly)){
        'Online' {$r.Online++}
        'NoReply' {$r.NoReply++}
        'Error' {$r.Errors++}
    }
    if($null -eq $script:FleetObservations){$script:FleetObservations=@{}}
    $keep=($null -ne $script:SelectedObject -and [string]$script:SelectedObject.DN -ieq [string]$Observation.Key)
    if($null -ne $script:FleetLast){$keep=$keep -or (Test-DomeniaLiveRowInScope -Dn $Observation.Key -BaseDn ([string]$script:FleetLast.Scope) -Scope $(if($script:FleetLast.Subtree){'Subtree'}else{'OneLevel'}))}
    if($keep){$script:FleetObservations[([string]$Observation.Key).ToLowerInvariant()]=$Observation}
    if($r.Generation -eq [long]$script:GlobalSearchGeneration){Update-DomeniaParkResultRows -Observation $Observation -Run $r}
    Clear-DomeniaParkPendingRow -Run $r -Key ([string]$Observation.Key)
    $script:FleetStale=$true
}

function Fail-DomeniaParkStored {
    param([string]$Message,$State)
    if(-not (Test-DomeniaParkRunCurrent $State)){return}
    $r=Get-DomeniaParkRunById ([string]$State.RunId);[void]$r.StorePending.Remove([string]$State.Job);$r.Stopping=$true;$r.Failed++
    $r.FailureMessage='Mesure non publiée : enregistrement SQLite non confirmé. '+$Message
    Clear-DomeniaParkPendingRow -Run $r -Key ([string]$State.Target.Key)
    Set-Status $r.FailureMessage 'ERROR'
    Update-DomeniaParkRunStatus -Run $r
}

function Fail-DomeniaParkSession {
    param($Message,$State)
    $packet=[pscustomobject]@{Outcome='Unavailable';Key=$State.Target.Key;Guid=$State.Target.Guid;Computer=$State.Target.Computer;Detail=[string]$Message;Presence='Erreur de ping';PresenceDetail=[string]$Message;PresenceCheckedUtc=$(if(-not $State.WmiOnly){$State.RemoteStartedUtc}else{''});ConsoleAttempted=(-not $State.PingOnly);ConsoleCheckedUtc=$(if(-not $State.PingOnly){$State.RemoteStartedUtc}else{''});InventoryAttempted=[bool]$State.Plan.Inventory;InventoryCheckedUtc=$State.RemoteStartedUtc;InventoryError=[string]$Message;CacheReused=$false;DirectoryAuthRejected=$false}
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
    if($null -ne $grid -and $null -ne $grid.ItemsSource){try{$grid.Items.Refresh()}catch{try{Write-AppLog ('Liste non actualisée après le relevé : '+$_.Exception.Message) 'WARN'}catch{}}}
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
    Set-DomeniaPresenceText -Name $(if($State.DisplayKind -eq 'Utilisateur'){'TxtUserPresence'}else{'TxtCompPresence'}) -State $label -PresenceState ([string]$view.PresenceState)
    Update-DomeniaObjectPresence -State $label -Target $State.Computer -PresenceState ([string]$view.PresenceState)
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
