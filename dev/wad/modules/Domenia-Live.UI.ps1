# Progressive search: only this module's timer touches the live WPF collection.
# LDAP, CIM and SQLite are executed by pinned operations in background runspaces.
$script:LiveModuleRoot=$PSScriptRoot
function Get-DomeniaLiveIdentityKey {
    # PF-01: cheap key of everything the identity signal depends on: the session epoch, the base DN, the account
    # objects in use (by reference) and the account generation counter of the temporary accounts. No command lookup,
    # no pipeline: the 80 ms tick compares it and rebuilds the full signal only when it changed.
    $access=$script:AccessState;$credentials=$null;$count=0
    if($null -ne $access){$credentials=$access.Credentials;if($null -ne $credentials){$count=[int]$credentials.Count}}
    $refs=[string][Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($script:Live)+'|'+[string][Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($script:Conn.Credential)+'|'+[string][Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($script:MachineCredential)+'|'+[string][Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($script:RemoteAdminCredential)+'|'+[string][Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($credentials)
    return ([string]$script:SessionEpoch+'|'+[string]$script:Conn.BaseDn+'|'+[string]$script:Conn.UseCredential+'|'+[string]$script:Conn.BindUser+'|'+[string]$script:ProcessIdentity+'|'+[string]$script:DomeniaAccountGeneration+'|'+$count+'|'+$refs+'|'+[string]$script:Live.Identity)
}
function Get-DomeniaLiveIdentitySignal {
    $ad=if($script:Conn.UseCredential){[string]$script:Conn.BindUser}else{[string]$script:ProcessIdentity}
    # PF-10: the closed loader provides Get-DomeniaRetryCredential; without it (isolated test) no retry account exists.
    $adRetry=$null;try{$adRetry=Get-DomeniaRetryCredential 'GlobalSearch'}catch{$adRetry=$null}
    if($null -ne $adRetry){$ad=[string]$adRetry.UserName}
    $adRef=if($null -ne $adRetry){[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($adRetry)}else{0}
    $remote=$script:MachineCredential
    if($null -eq $remote){$remote=$script:RemoteAdminCredential}
    if($null -eq $remote -and $script:Conn.UseCredential){$remote=$script:Conn.Credential}
    $remoteRetry=$null;try{$remoteRetry=Get-DomeniaRetryCredential 'LiveConsole'}catch{$remoteRetry=$null}
    if($null -ne $remoteRetry){$remote=$remoteRetry}
    $remoteUser=if($null -ne $remote){[string]$remote.UserName}else{[string]$script:ProcessIdentity}
    $reference=if($null -ne $remote){[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($remote)}else{0}
    $localIds='';if($null -ne $script:AccessState){$localIds=(@($script:AccessState.Credentials.Keys|Where-Object{$_ -like 'RemoteLocal|*'}|Sort-Object|ForEach-Object{$_+'='+$script:AccessState.Credentials[$_].UserName}) -join ';')}
    [pscustomobject]@{Scope=([string]$script:Conn.BaseDn+'|'+$ad+'|'+$remoteUser+'|'+$localIds).ToLowerInvariant();Signal=([string]$script:SessionEpoch+'|'+$adRef+'|'+$reference+'|'+[string]$script:Conn.BaseDn+'|'+$ad+'|'+$remoteUser+'|'+$localIds)}
}
function Initialize-DomeniaLive {
    if($null -ne $script:Live -or $null -eq $script:Window){return}
    try {
        if($null -eq ('Domenia.Live.ResultRow' -as [type])){
            try{Add-Type -Path (Join-Path $script:LiveModuleRoot 'Domenia-Live.Types.cs') -ErrorAction Stop}
            catch{Write-AppLog 'Notifications compilées indisponibles : rafraîchissement visuel groupé, aucune protection Windows contournée.' 'WARN'}
        }
        $cacheReady=$true
        try{[void](Initialize-DomeniaWinSqliteNative)}catch{$cacheReady=$false;Write-AppLog ('Cache sur disque indisponible : '+$_.Exception.Message) 'WARN'}
        $script:Live=[pscustomobject]@{
            Enabled=$true;DatabasePath='';IdentityRows=[Collections.Generic.Queue[object]]::new();CacheReady=$cacheReady;Notifying=($null -ne ('Domenia.Live.ResultRow' -as [type]));Deferred=[Collections.Generic.Queue[object]]::new();Identity='';Scope='';Epoch=[long]$script:SessionEpoch;Search=$null
            MemoryQueries=@{};Observations=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
            Pending=[Collections.Generic.Queue[object]]::new();PendingKeys=@{};Busy=@{};Done=@{}
            ObservationsLoaded=$false;Refresh=[Collections.Generic.Queue[object]]::new()
            SaveQueue=@{};QueryToSave=$null;SaveJob='';SaveAfter=[datetime]::MinValue;SaveFault='';SaveInFlight=0;SaveBatch=$null
            PresenceEvents=[Collections.Concurrent.ConcurrentQueue[object]]::new();PresenceSeen=@{};RemoteFaulted=$false;NextStart=[datetime]::MinValue;Timer=$null;InTick=$false;AutoDetect=$true;VerifyOnClick=$false;ProbeSelection=$null;LastFilter=[datetime]::MinValue;NegativeCache=(New-DomeniaNegativeCache)
        }
        Reset-DomeniaLiveIdentity
        # SP-15: a click only preloads the AD fiche unless « Vérifier au clic » is checked (saved preference, unchecked
        # by default). The user read is its sub-option; until chosen it follows Streaming.VerifyUserOnSelection.
        $userDefault=ConvertTo-SuiteFlag (Get-CfgValue 'Streaming' 'VerifyUserOnSelection' $true) -Default $true
        # The core provides the saved preferences; an isolated host without them keeps the defaults (no ping on click).
        $verifyStored=$false;$userStored=''
        try{$verifyStored=Get-DomeniaSetting 'LiveVerifyOnClick' $false;$userStored=Get-DomeniaSetting 'LiveUserOnClick' ''}catch{$verifyStored=$false;$userStored=''}
        $script:Live.VerifyOnClick=ConvertTo-SuiteFlag $verifyStored -Default $false
        $script:Live.AutoDetect=ConvertTo-SuiteFlag $userStored -Default $userDefault
        # The values are shown before the handlers are attached: restoring them never rewrites the preferences.
        foreach($pair in @(@('ChkLiveVerifyOnClick',[bool]$script:Live.VerifyOnClick),@('ChkLiveUsersOnClick',[bool]$script:Live.AutoDetect))){
            $check=Get-DomeniaControl $pair[0]
            if($null -eq $check){continue}
            $check.IsChecked=[bool]$pair[1]
            $check.Add_Checked({Set-DomeniaLiveClickOptions})
            $check.Add_Unchecked({Set-DomeniaLiveClickOptions})
        }
        $button=Get-DomeniaControl 'BtnLiveRecheck'
        if($null -ne $button){$button.Add_Click({Request-DomeniaLiveRecheck})}
        # FI-05 / PF-06: protected heartbeat timer, owned and registered by the factory (D019). 80 ms while the
        # search has work, once per second at rest (state line only); a search or a selection wakes it at once.
        $script:Live.Timer=New-DomeniaTimer -Owner 'Timer:Live' -IntervalMs 80 -IdleIntervalMs 1000 -Busy {Test-DomeniaLiveTickNeeded} -Start -Tick {Invoke-DomeniaLiveTick}
        $script:Window.Add_Closed({Stop-DomeniaLive -Closing})
    }catch{Write-AppLog ('Initialisation progressive impossible : '+$_.Exception.Message) 'ERROR';$script:Live=$null}
}
function Set-DomeniaLiveClickOptions {
    # SP-15: reads both check boxes and keeps them in the saved preferences. Turning the check on click off drops an
    # unsent click intent; an explicit Revérifier ce poste already asked is kept. Nothing is sent to the network.
    if($null -eq $script:Live){return}
    $verify=Get-DomeniaControl 'ChkLiveVerifyOnClick';$users=Get-DomeniaControl 'ChkLiveUsersOnClick'
    if($null -ne $verify){$script:Live.VerifyOnClick=[bool]$verify.IsChecked}
    if($null -ne $users){$script:Live.AutoDetect=[bool]$users.IsChecked}
    if(-not $script:Live.VerifyOnClick -and $null -ne $script:Live.ProbeSelection -and -not [bool]$script:Live.ProbeSelection.Manual){Clear-DomeniaLiveProbeIntent}
    try{
        Set-DomeniaSetting -Name 'LiveVerifyOnClick' -Value ([bool]$script:Live.VerifyOnClick)
        Set-DomeniaSetting -Name 'LiveUserOnClick' -Value ([bool]$script:Live.AutoDetect)
    }catch{Write-AppLog ('Préférence « Vérifier au clic » non enregistrée : '+$_.Exception.Message) 'WARN'}
}
function Reset-DomeniaLiveIdentity {
    if($null -eq $script:Live){return}
    # PF-01: nothing that the signal depends on changed since the last tick: no rebuild.
    $key=Get-DomeniaLiveIdentityKey
    if([string]$script:DomeniaLiveIdentityKey -ceq $key){return}
    $signal=Get-DomeniaLiveIdentitySignal
    if([string]$script:Live.Identity -ceq $signal.Signal){$script:DomeniaLiveIdentityKey=$key;return}
    if($null -ne $script:Live.Search){
        foreach($row in $script:Live.Search.Rows){if($row.Type -eq 'Machine'){$script:Live.IdentityRows.Enqueue($row)}}
    }
    Stop-DomeniaLiveProbes
    Stop-DomeniaLiveSearch
    $script:Live.DatabasePath=''
    $script:Live.Identity=$signal.Signal;$script:Live.Scope=Get-DomeniaLiveHash $signal.Scope;$script:Live.Epoch=[long]$script:SessionEpoch
    $script:Live.Observations=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
    $script:Live.ObservationsLoaded=$false;$script:Live.MemoryQueries=@{};$script:Live.Done=@{}
    $script:Live.SaveQueue=@{};$script:Live.QueryToSave=$null;$script:Live.SaveFault='';$script:Live.RemoteFaulted=$false
    $script:Live.Refresh.Clear();$script:Live.Deferred.Clear();$script:Live.SaveJob='';$script:Live.SaveAfter=[datetime]::MinValue;$script:Live.SaveInFlight=0
    $script:Live.NegativeCache=(New-DomeniaNegativeCache)
    # Old callbacks carry the old identity and can never repopulate this scope.
    $script:DomeniaLiveIdentityKey=Get-DomeniaLiveIdentityKey
}
function Stop-DomeniaLiveSearch {
    if($null -eq $script:Live -or $null -eq $script:Live.Search){return}
    $s=$script:Live.Search;$s.Stopped=$true
    try{$s.Stop.Cancel()}catch{}
    if($null -ne $s.PSObject.Properties['DirectoryPipe']){Complete-DomeniaDirectoryReadPipe -Pipe $s.DirectoryPipe -Error 'Lecture interrompue : les objets deja recoltes sont conserves.'}
    $script:Live.Search=$null
    Clear-DomeniaLiveProbeIntent
    $script:Live.Done=@{}
    $script:Live.PresenceSeen=@{}
}
function Stop-DomeniaLiveProbes {
    if($null -eq $script:Live){return}
    Clear-DomeniaLiveProbeIntent
    foreach($id in @($script:Live.Busy.Values)){
        if($script:AsyncJobs.Contains($id)){Request-UiTaskStop -Id $id -Silent -Reason 'Vérification sur sélection suspendue'}
    }
}
function Stop-DomeniaLive {
    param([switch]$Closing)
    if($null -eq $script:Live){return}
    if($null -ne $script:Live.Timer){$script:Live.Timer.Stop()}
    Stop-DomeniaLiveProbes;Stop-DomeniaLiveSearch
    # Never wait synchronously for LDAP/CIM/SQLite when closing a WPF window.
    if($Closing -and ($script:Live.SaveJob -or $script:Live.SaveQueue.Count -gt 0 -or $null -ne $script:Live.QueryToSave)){
        Write-AppLog 'Fermeture : des observations peuvent ne pas être encore enregistrées. Le dernier cache validé est conservé.' 'WARN'
    }
}
function Test-DomeniaLiveSearchActive {
    if($null -eq $script:Live -or $null -eq $script:Live.Search){return $false}
    if((Get-DomeniaLiveIdentitySignal).Signal -cne $script:Live.Identity){return $false}
    $s=$script:Live.Search
    return (-not $s.Stopped -and (Test-DomeniaLiveIdentity $s ([long]$script:SessionEpoch) $script:Live.Identity) -and (Test-DomeniaSearchStateCurrent $s.State))
}
function Set-DomeniaLoginColumnVisible {
    # Decision David 2026-10-05: the 'Compte' column (user login, linked account of a workstation, group account name)
    # is shown only when at least one listed row has such an account. DS-20: and only when the operator chose it.
    param([bool]$Visible)
    $script:SearchListHasAccount=$Visible
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return}
    $show=($Visible -and (($null -eq $script:ResultColumnChoice) -or (@($script:ResultColumnChoice) -contains 'Login')))
    $wanted=if($show){'Visible'}else{'Collapsed'}
    foreach($column in @($grid.Columns)){if([string]$column.Header -ceq 'Compte' -and [string]$column.Visibility -ne $wanted){$column.Visibility=$wanted}}
}
function Update-DomeniaLoginColumnFromRows {
    param($Rows)
    # One pass over the list: the 'Compte' column and the workstation-only actions follow what it holds.
    $hasAccount=$false;$hasMachine=$false;$hasUser=$false
    foreach($row in @($Rows)){
        if(-not $hasAccount -and (Test-DomeniaRowHasAccount $row)){$hasAccount=$true}
        if(-not $hasMachine -and $null -ne $row -and [string]$row.Type -eq 'Machine'){$hasMachine=$true}
        if(-not $hasUser -and $null -ne $row -and [string]$row.Type -eq 'Utilisateur'){$hasUser=$true}
        if($hasAccount -and $hasMachine -and $hasUser){break}
    }
    Set-DomeniaLoginColumnVisible $hasAccount
    $script:SearchListHasMachine=$hasMachine;$script:SearchListHasUser=$hasUser
    Set-DomeniaResultColumns
    Update-DomeniaSearchActionStates
}
function Set-DomeniaResultColumns {
    param([switch]$RevealOnly)
    # Decision David 2026-10-07: one table for every object type. Workstation columns appear only when the list
    # holds a workstation; association and logon columns only when it holds users or workstations.
    # DS-20 / SP-02: a column is shown only when the operator chose it too ($script:ResultColumnChoice; « Colonnes… »).
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return}
    $machine=[bool]$script:SearchListHasMachine;$linkable=($machine -or [bool]$script:SearchListHasUser)
    foreach($column in @($grid.Columns)){
        if($null -eq $column){continue}
        # Persisted key of the column (as Get-DomeniaGridColumnKey): its sort member, else its binding path.
        $key=[string]$column.SortMemberPath
        if(-not $key){try{if($null -ne $column.Binding){$key=[string]$column.Binding.Path.Path}}catch{}}
        # Compte follows the accounts of the listed rows (Set-DomeniaLoginColumnVisible).
        if($key -ceq 'Login'){continue}
        $show=Test-DomeniaResultColumnShown -Key $key -Visible $script:ResultColumnChoice -HasMachine $machine -HasLinkable $linkable -HasAccount ([bool]$script:SearchListHasAccount)
        if($RevealOnly -and (-not $show)){continue}
        $wanted=if($show){'Visible'}else{'Collapsed'}
        if([string]$column.Visibility -ne $wanted){$column.Visibility=$wanted}
    }
}
function Update-DomeniaSearchActionStates {
    # Decision David 2026-10-05: one search for every object type; a workstation-only action is greyed when it
    # does not apply (selection that is not a single workstation, list without any workstation).
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return}
    $ready=[bool]$grid.IsEnabled
    $selected=@($grid.SelectedItems)
    $recheck=Get-DomeniaControl 'BtnLiveRecheck'
    if($null -ne $recheck){$recheck.IsEnabled=($ready -and $selected.Count -eq 1 -and [string]$selected[0].Type -eq 'Machine')}
    # UI-23 / FO-18 / UX-33: « Vérifier la liste ▾ », its stop state and the bar of a multiple selection follow the list
    # and its surveys; a work view listed over the whole domain never offers a survey of its workstations.
    Update-DomeniaParkControls
}
function Test-DomeniaRowHasAccount {
    # User or group: its own account name. Workstation: the login of its linked account (decision David 2026-10-05).
    param($Row)
    if($null -eq $Row){return $false}
    $type=[string]$Row.Type
    if($type -eq 'Machine'){return [bool][string]$Row.Association}
    return ($type -in @('Utilisateur','Groupe') -and [bool][string]$Row.Login)
}
function Begin-DomeniaLiveSearch {
    param($State,$Payload)
    $script:SearchListHasMachine=$false;$script:SearchListHasUser=$false;Update-DomeniaSearchActionStates
    if($null -eq $script:Live){Initialize-DomeniaLive}
    if($null -eq $script:Live){throw 'Chargement progressif indisponible. Consulter le journal.'}
    Reset-DomeniaLiveIdentity;Stop-DomeniaLiveSearch
    $queue=[Collections.Concurrent.ConcurrentQueue[object]]::new();$cacheQueue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $stop=[Threading.CancellationTokenSource]::new()
    $keyText='search-v214|'+[string]$State.SearchMode+'|'+$script:Live.Scope+'|'+[string]$State.BaseDn+'|'+[string]$State.Scope+'|'+[string]$State.TypeFilter+'|'+[string]$State.Search+'|'+[string]$State.Limit
    $viewId='';if($null -ne $State.PSObject.Properties['ViewId']){$viewId=[string]$State.ViewId}
    if($viewId){$keyText+='|view:'+$viewId}
    # FO-01: a « contains » list is another query than the prefix list of the same text.
    if([string](Get-DomeniaMember $State 'MatchMode' '') -eq 'Contains'){$keyText+='|contains'}
    $key=Get-DomeniaLiveHash $keyText
    $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
    # D034/D037: the search rules are resolved once per search; without them the arrival order and the former counter remain.
    $rules=($null -ne (Get-Command Get-DomeniaSearchRank -CommandType Function -ErrorAction SilentlyContinue))
    $ranking=($rules -and [string]$State.SearchMode -eq 'Global' -and -not [string]::IsNullOrWhiteSpace([string]$State.Search) -and -not $viewId)
    if($ranking -and $null -ne (Get-Command Get-DomeniaFeatureFlag -CommandType Function -ErrorAction SilentlyContinue)){$ranking=[bool](Get-DomeniaFeatureFlag -Name 'SearchRanking' -Default $true)}
    # UX-03: resolved once per search, never in the tick (PF-10): the empty list explains a filter that hides every row.
    $emptyState=($null -ne (Get-Command Update-DomeniaFilteredEmptyState -CommandType Function -ErrorAction SilentlyContinue))
    # FO-01: resolved once per search as well; a new search hides the « contains » chip of the previous one.
    $containsOffer=($null -ne (Get-Command Update-DomeniaSearchContainsOffer -CommandType Function -ErrorAction SilentlyContinue))
    if($containsOffer){Update-DomeniaSearchContainsOffer -Search $null}
    $s=[pscustomobject]@{
        Identity=$script:Live.Identity;Epoch=[long]$script:SessionEpoch;State=$State;QueryKey=$key
        Rows=$rows;Map=@{};Fresh=@{};FreshOrder=[Collections.Generic.List[object]]::new();CacheKeys=[Collections.Generic.Queue[string]]::new();Progress=$queue;CacheProgress=$cacheQueue;Stop=$stop
        Stopped=$false;SelectionRestored=$false;Ended=$false;Final=$null;Error='';Finalized=$false;Prune=$null;CacheRequested=$true
        Started=[Diagnostics.Stopwatch]::StartNew();FirstMs=-1L;CacheUtc='';RefreshNeeded=$false;FilterPending=$false
        Ranking=[bool]$ranking;SearchRules=[bool]$rules;EmptyState=[bool]$emptyState;ContainsOffer=[bool]$containsOffer
    }
    $script:Live.Search=$s;$script:BranchObjects=$rows;$script:BranchCountLabel='Chargement progressif…'
    # PF-06: the first rows are shown at the normal pace, not after the rest interval. A new search (explicit gesture)
    # also restarts a timer stopped after three consecutive errors (FI-05).
    try{if($null -ne $script:Live.Timer -and -not [bool]$script:Live.Timer.IsEnabled){$script:Live.Timer.Start()};Invoke-DomeniaTimerSoon -Owner 'Timer:Live'}catch{}
    $grid=Get-DomeniaControl 'DgObjects'
    $suppressed=$script:SuppressGridSelectionEvents;$script:SuppressGridSelectionEvents=$true
    try{$grid.ItemsSource=$rows;$grid.SelectedIndex=-1}finally{$script:SuppressGridSelectionEvents=$suppressed}
    if($ranking){
        # Exact account first, then name matches. A column chosen by the operator replaces this order.
        try{
            $sortView=[Windows.Data.CollectionViewSource]::GetDefaultView($rows)
            $sortView.SortDescriptions.Clear()
            $sortView.SortDescriptions.Add([ComponentModel.SortDescription]::new('Rank',[ComponentModel.ListSortDirection]::Ascending))
            $sortView.SortDescriptions.Add([ComponentModel.SortDescription]::new('Name',[ComponentModel.ListSortDirection]::Ascending))
        }catch{$s.Ranking=$false;Write-AppLog ('Classement des résultats indisponible : '+$_.Exception.Message) 'WARN'}
    }
    Update-DomeniaLiveFilter
    Add-Member -InputObject $State -NotePropertyName LiveState -NotePropertyValue $s -Force
    $directoryPipe=New-DomeniaDirectoryReadPipe -Context $State.StoreContext -ReadyQueue $queue -Search $s
    Add-Member -InputObject $s -NotePropertyName DirectoryPipe -NotePropertyValue $directoryPipe -Force
    Add-Member -InputObject $Payload -NotePropertyName Progress -NotePropertyValue $directoryPipe.Input -Force
    Add-Member -InputObject $Payload -NotePropertyName DirectoryReadState -NotePropertyValue $directoryPipe.Collector -Force
    Add-Member -InputObject $Payload -NotePropertyName StopToken -NotePropertyValue $stop.Token -Force
    Add-Member -InputObject $Payload -NotePropertyName StreamPageSize -NotePropertyValue ([Math]::Max(100,[Math]::Min(1000,[int](Get-DomeniaMember $Payload 'StreamPageSize' 250)))) -Force
    # Only canonical SQL readbacks enter Progress. Legacy query snapshots are no longer a data source.
    return $s
}
function Resume-DomeniaLiveSearch {
    # MO-07: « Charger la suite » adds the next rows to the list on screen instead of reading it again. The same search
    # object keeps its rows, its identity map, its selection and its generation; a new SQLite pipe (new request id)
    # publishes the new rows only, and the list is finalized again when they are committed.
    param($State,$Payload)
    $s=$null;if($null -ne $script:Live){$s=$script:Live.Search}
    if(($null -eq $s) -or (-not (Test-DomeniaLiveSearchActive))){throw 'Liste courante introuvable : relancez la recherche.'}
    $stop=[Threading.CancellationTokenSource]::new()
    $s.Stop=$stop;$s.Ended=$false;$s.Finalized=$false;$s.Final=$null;$s.Error='';$s.Prune=$null;$s.RefreshNeeded=$true
    $s.State=$State
    $script:BranchCountLabel='Chargement de la suite…'
    Add-Member -InputObject $State -NotePropertyName LiveState -NotePropertyValue $s -Force
    $directoryPipe=New-DomeniaDirectoryReadPipe -Context $State.StoreContext -ReadyQueue $s.Progress -Search $s
    Add-Member -InputObject $s -NotePropertyName DirectoryPipe -NotePropertyValue $directoryPipe -Force
    Add-Member -InputObject $Payload -NotePropertyName Progress -NotePropertyValue $directoryPipe.Input -Force
    Add-Member -InputObject $Payload -NotePropertyName DirectoryReadState -NotePropertyValue $directoryPipe.Collector -Force
    Add-Member -InputObject $Payload -NotePropertyName StopToken -NotePropertyValue $stop.Token -Force
    Add-Member -InputObject $Payload -NotePropertyName StreamPageSize -NotePropertyValue ([Math]::Max(100,[Math]::Min(1000,[int](Get-DomeniaMember $Payload 'StreamPageSize' 250)))) -Force
    try{if($null -ne $script:Live.Timer -and -not [bool]$script:Live.Timer.IsEnabled){$script:Live.Timer.Start()};Invoke-DomeniaTimerSoon -Owner 'Timer:Live'}catch{}
    Update-DomeniaSearchMoreButton -Search $s
    return $s
}
function Complete-DomeniaLiveSearch {
    param($Result,$State)
    $s=$State.LiveState
    if($null -eq $s){return}
    $effective=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows','BaseDn','Scope')
    if($null -eq $effective -or [string]$effective.BaseDn -ine [string]$State.BaseDn -or [string]$effective.Scope -ne [string]$State.Scope){throw 'Résultat de recherche sans périmètre valide.'}
    # MO-07: a complete continuation moves the cursor of the next one to the last name it added.
    $continued=$effective.PSObject.Properties['Continuation'];$partialRead=$effective.PSObject.Properties['Partial'];$lastRead=$effective.PSObject.Properties['LastName']
    if(($null -ne $continued) -and [bool]$continued.Value -and (($null -eq $partialRead) -or -not [bool]$partialRead.Value) -and ($null -ne $lastRead) -and [string]$lastRead.Value){
        Add-Member -InputObject $s -NotePropertyName ContinuationCursor -NotePropertyValue ([string]$lastRead.Value) -Force
    }
    $errorText=''
    # Once AD completed, old cache rows can no longer contribute to the list. Detach the queue
    # even if a cache reader still owns it, so idle ticks cannot retain/revisit thousands of stale rows.
    if(-not $effective.Partial){$s.CacheProgress=[Collections.Concurrent.ConcurrentQueue[object]]::new()}
    if($effective.Partial){$errorText=[string]$effective.Failure;if(-not $errorText){$errorText='Résultat LDAP partiel.'}}
    Complete-DomeniaDirectoryReadPipe -Pipe $s.DirectoryPipe -Final $effective -Error $errorText
    # Finalization waits for the last COMMIT/readback, including partial and cancelled reads.
}
function Fail-DomeniaLiveSearch {
    param([string]$Message,$State)
    $s=$State.LiveState
    if($null -eq $s){return}
    try{$s.Stop.Cancel()}catch{}
    Complete-DomeniaDirectoryReadPipe -Pipe $s.DirectoryPipe -Error $Message
    Write-AppLog ('Recherche incomplète : '+$Message) 'WARN'
}
function Stop-DomeniaLiveJob {
    param($Job)
    if($null -eq $Job){return}
    if($Job.OperationId -in @('OpenAdObject','TreeChildren','LiveDirectoryCheck') -and $null -ne $Job.CallbackState -and $null -ne $Job.CallbackState.PSObject.Properties['DirectoryPipe']){
        $pipe=$Job.CallbackState.DirectoryPipe
        try{$pipe.Stop.Cancel()}catch{}
        Complete-DomeniaDirectoryReadPipe -Pipe $pipe -Error 'Lecture arretee : les informations deja recoltees sont conservees.'
    }
    if($null -eq $script:Live){return}
    if($Job.OperationId -in @('LiveConsole','LiveSelectedPing') -and $null -ne $Job.CallbackState){
        $key=[string]$Job.CallbackState.Key
        if($Job.CallbackState.Generation -eq $script:GlobalSearchGeneration -and -not $Job.Superseded){
            $script:Live.Done[$key]=$true
            if((Test-DomeniaLiveSearchActive) -and $script:Live.Search.Map.ContainsKey($key)){$script:Live.Search.Map[$key].SessionState='Non confirmé · arrêt demandé'}
        }
    }
    if($Job.OperationId -eq 'GlobalSearch' -and $null -ne $Job.CallbackState.LiveState){
        $s=$Job.CallbackState.LiveState
        try{$s.Stop.Cancel()}catch{}
        Complete-DomeniaDirectoryReadPipe -Pipe $s.DirectoryPipe -Error 'Lecture interrompue : objets recoltes conserves, couverture incomplete.'
    }
}
function Update-DomeniaLiveFilter {
    if($null -eq $script:Live -or $null -eq $script:Live.Search){return}
    $s=$script:Live.Search;$grid=Get-DomeniaControl 'DgObjects'
    if($null -eq $grid -or -not [object]::ReferenceEquals($grid.ItemsSource,$s.Rows)){return}
    # A write may disable the grid while the workshop changes its selection. Retry after it is enabled,
    # including ClearSearch (there may then be no active local filter to trigger a normal refresh).
    $s.FilterPending=$true
    if(-not $grid.IsEnabled){return}
    $view=[Windows.Data.CollectionViewSource]::GetDefaultView($s.Rows)
    $filter=Get-DomeniaControl 'TxtSuiteResultFilter'
    $query=if($null -ne $filter){[string]$filter.Text}else{''}
    $presence=[string]$script:CurrentPresenceFilter
    # CO-05: the filter of the list narrows a global list too (no request); the presence filter belongs to OU lists.
    if((Get-DomeniaSearchMode) -eq 'Global'){$presence='Tous'}
    # FI-16: the filter compares state keys. The key of the choice and the text-to-key table of rows built before the
    # key existed are resolved here: core functions are not visible inside the closure below.
    $wantedState=if(-not $presence -or $presence -eq 'Tous'){''}else{ConvertTo-DomeniaPresenceStateKey $presence}
    $stateKeys=@(Get-DomeniaPresenceStateKeys)
    $legacyStates=@{}
    foreach($label in @('En ligne','Sans réponse au ping','Hors ligne','Erreur de ping','Non vérifié','Inconnu','Vérification en cours','Sans objet','')){$legacyStates[$label]=ConvertTo-DomeniaPresenceStateKey $label}
    # Capture values, not controls; filtering performs no network or database I/O.
    if($query.Length -gt 120){$query=$query.Substring(0,120)}
    $terms=@($query.Trim() -split '\s+'|Where-Object {$_})
    # GetNewClosure runs in a dynamic module: application functions from the core script are not visible.
    # Capture the explicit GUID selection along with the other filters; Apply/Clear rebuild this predicate.
    # An active selection without a GUID map must stay empty, never silently admit every object.
    $queryState=$script:DomeniaQueryState
    $hasQuerySelection=($null -ne $queryState -and $null -ne $queryState.SearchRecipe)
    $queryRecords=if($hasQuerySelection){$queryState.SearchRecords}else{$null}
    $predicate={
        param($row)
        if($hasQuerySelection){
            if([string]$row.Type -ne 'Machine'){return $false}
            $guid=([string]$row.Guid).Trim().Trim('{','}').ToLowerInvariant()
            if(-not $guid -or $null -eq $queryRecords -or -not $queryRecords.ContainsKey($guid)){return $false}
        }
        # Ordinary searches and GUID-only selections do not need per-row text allocations.
        if($terms.Count -eq 0 -and -not $wantedState){return $true}
        if($wantedState){
            $network=[string]$row.PresenceState
            if($stateKeys -notcontains $network){
                $label=([string]$row.Presence -replace ' \(cache\)$','').Trim()
                $network=if($legacyStates.ContainsKey($label)){[string]$legacyStates[$label]}else{'Unknown'}
            }
            if($network -cne $wantedState){return $false}
        }
        if($terms.Count -eq 0){return $true}
        $parts=[Collections.Generic.List[string]]::new()
        foreach($name in @('Type','Name','Login','UPN','Association','Presence','SessionDisplay','SessionState')){
            $value=[string]$row.$name;if($value.Length -gt 2048){$value=$value.Substring(0,2048)};[void]$parts.Add($value)
        }
        $haystack=[string]::Join(' ',$parts.ToArray())
        foreach($term in $terms){if($haystack.IndexOf($term,[StringComparison]::OrdinalIgnoreCase) -lt 0){return $false}}
        return $true
    }.GetNewClosure()
    $old=$script:SuppressGridSelectionEvents;$script:SuppressGridSelectionEvents=$true
    try{$view.Filter=[Predicate[object]]$predicate;$view.Refresh()}finally{$script:SuppressGridSelectionEvents=$old}
    # The fraction counts displayed/loaded rows, never the total AD population. Keep an incomplete
    # read visible beside that fraction even when the branch counter is outside the current viewport.
    [void](Set-DomeniaControlText 'LblSuiteResultCount' ($(if($s.Error){'Liste partielle · '}elseif(-not $s.Finalized){'Chargement… · '}elseif(($null -ne $s.Final) -and ([bool]$s.Final.LimitReached)){'Limite atteinte · '}else{''})+"$($grid.Items.Count) / $($s.Rows.Count) lignes visibles · filtre de la liste"))
    # UX-03: every loaded row hidden by the filter of the list: the empty list says how many and offers to clear it.
    if([bool]$s.EmptyState){Update-DomeniaFilteredEmptyState -Loaded $s.Rows.Count -Visible $grid.Items.Count}
    $script:Live.LastFilter=[datetime]::UtcNow;$s.RefreshNeeded=$false;$s.FilterPending=$false
}
function Set-DomeniaLiveObservationOnRow {
    param($Row,$Observation,[switch]$Cached,[switch]$Pending)
    if($Row.Type -ne 'Machine'){return}
    # GUID mismatch means a recreated AD object, not the same cached machine.
    if($null -ne $Observation -and $Row.Guid -and $Observation.Guid -and [string]$Row.Guid -ine [string]$Observation.Guid){$Observation=$null}
    $view=Get-DomeniaLiveObservationView $Observation -Cached:$Cached -Pending:$Pending
    # Point 11: the durations of the usage profile decide « récent » or « à relire » (cached table, two setting reads).
    $freshnessTable=$null;try{$freshnessTable=Get-DomeniaActiveFreshnessTable}catch{$freshnessTable=$null}
    $Row.SessionDisplay=$view.Display;$Row.SessionState=$view.State;$Row.SessionDetail=$view.Detail+"`r`n"+(Get-DomeniaRecordFreshness $Observation 'Console' -Table $freshnessTable).Label
    $Row.SessionChecked=$view.Checked;$Row.SessionObserved=$view.Observed;$Row.SessionSource=$view.Source
    $key=Get-DomeniaLiveObjectKey $Row
    $historical=[bool]$Cached
    if($null -ne $script:Live -and $null -ne $script:Live.PresenceSeen -and $script:Live.PresenceSeen.ContainsKey($key)){$historical=$false}
    $network=Get-DomeniaLivePresenceView $Observation -Cached:$historical
    $Row.Presence=$network.Display;Set-DomeniaLiveRowValue $Row 'PresenceDetail' ($network.Detail+"`r`n"+(Get-DomeniaRecordFreshness $Observation 'Presence' -Table $freshnessTable).Label)
    # FI-16 / DS-15: the pill reads the state key; the age replaces the former '(cache)' suffix.
    Set-DomeniaLiveRowValue $Row 'PresenceState' ([string]$network.PresenceState)
    Set-DomeniaLiveRowValue $Row 'PresenceAge' ([string]$network.Age)
    Set-DomeniaLiveRowValue $Row 'PresenceCached' $(if([bool]$network.IsCached){'1'}else{''})
}
function Add-DomeniaLiveRow {
    param($Event)
    $s=$script:Live.Search;$source=$Event.Row
    $key=Get-DomeniaLiveObjectKey $source
    $fresh=([string]$Event.Kind -eq 'Row')
    if(-not $key -or $key.Length -gt 4096){if($fresh){$s.Error='Identité LDAP absente ou hors limite : résultat partiel.'};return}
    if(-not $fresh -and $s.Fresh.ContainsKey($key)){return}
    $snapshot=ConvertTo-DomeniaLiveSnapshot $source
    if($snapshot.Type -notin @('Utilisateur','Machine','Groupe','OU','Conteneur')){if($fresh){$s.Error='Type LDAP inattendu : résultat partiel.'};return}
    # A row outside the scope of this search (another OU, from the cache or a late result) is never displayed.
    if(-not (Test-DomeniaLiveRowInScope -Dn ([string]$snapshot.DN) -BaseDn ([string]$s.State.BaseDn) -Scope ([string]$s.State.Scope))){
        try{if(-not [bool]$s.PSObject.Properties['OutOfScopeLogged']){Write-AppLog ('Ligne hors perimetre ecartee ('+$(if($fresh){'AD'}else{'cache'})+') : '+[string]$snapshot.DN+' ; perimetre '+[string]$s.State.BaseDn) 'WARN';$s|Add-Member -NotePropertyName OutOfScopeLogged -NotePropertyValue $true -Force}}catch{}
        return
    }
    if([string]$snapshot.Type -eq 'Machine' -and -not $script:SearchListHasMachine){$script:SearchListHasMachine=$true;Update-DomeniaSearchActionStates;Set-DomeniaResultColumns -RevealOnly}
    if([string]$snapshot.Type -eq 'Utilisateur' -and -not $script:SearchListHasUser){$script:SearchListHasUser=$true;Set-DomeniaResultColumns -RevealOnly}
    if([string]$snapshot.Type -in @('Utilisateur','Groupe') -and [string]$snapshot.Login -and -not [bool]$s.PSObject.Properties['LoginShown']){Set-DomeniaLoginColumnVisible $true;$s|Add-Member -NotePropertyName LoginShown -NotePropertyValue $true -Force}
    $isNew=-not $s.Map.ContainsKey($key)
    if($isNew){
        if($s.Rows.Count -ge [int]$s.State.Limit){
            if(-not $fresh){return}
            # Old cached rows never occupy the quota at the expense of a fresh AD row.
            $old=$script:SuppressGridSelectionEvents;$script:SuppressGridSelectionEvents=$true
            try{
                while($s.Rows.Count -ge [int]$s.State.Limit -and $s.CacheKeys.Count -gt 0){
                    $evicted=$s.CacheKeys.Dequeue()
                    if($s.Map.ContainsKey($evicted) -and -not $s.Fresh.ContainsKey($evicted)){
                        [void]$s.Rows.Remove($s.Map[$evicted]);[void]$s.Map.Remove($evicted)
                    }
                }
            }finally{$script:SuppressGridSelectionEvents=$old}
            if($s.Rows.Count -ge [int]$s.State.Limit){return}
        }
        $row=New-DomeniaLiveResultRow;$s.Map[$key]=$row
    }else{$row=$s.Map[$key]}
    foreach($p in $snapshot.PSObject.Properties){Set-DomeniaLiveRowValue $row $p.Name ([string]$p.Value)}
    if($s.Ranking){Set-DomeniaLiveRowValue $row 'Rank' ([string](Get-DomeniaSearchRank $row ([string]$s.State.Search)))}
    # D034: adminCount comes with the fresh LDAP row only (never cached); the naming rule applies to every row.
    if($s.SearchRules){
        $adminRow=((Test-DomeniaAdminAccountRow $source) -or (Test-DomeniaAdminAccountRow $row))
        if($adminRow){Set-DomeniaLiveRowValue $row 'Admin' 'Compte admin'}
    }
    $row.DirectoryState=if($fresh){'AD vérifié'}else{'Cache · à vérifier'}
    Set-DomeniaLiveRowValue $row 'DirectoryFresh' $(if($fresh){'Verified'}else{'Cached'})
    $row.DirectoryChecked=[string]$Event.ObservedUtc
    if($fresh){if(-not $s.Fresh.ContainsKey($key)){[void]$s.FreshOrder.Add($snapshot)};$s.Fresh[$key]=$snapshot}
    if($isNew){
        [void](Set-RowAssociationMetadata -Rows @($row))
        if([string]$row.Type -eq 'Machine' -and [string]$row.Association -and -not [bool]$s.PSObject.Properties['LoginShown']){Set-DomeniaLoginColumnVisible $true;$s|Add-Member -NotePropertyName LoginShown -NotePropertyValue $true -Force}
        $row.Presence=$(if($row.Type -eq 'Machine'){'Non vérifié'}else{'Sans objet'})
        Set-DomeniaLiveRowValue $row 'PresenceState' $(if($row.Type -eq 'Machine'){'Unknown'}else{'None'})
        if(-not $fresh){$s.CacheKeys.Enqueue($key)}
        $observation=$null
        [void]$script:Live.Observations.TryGetValue($key,[ref]$observation)
        Set-DomeniaLiveObservationOnRow $row $observation -Cached
        if($null -eq $observation -and $row.Association){
            $row.SessionDisplay=$row.Association+' (historique)'
            $row.SessionDetail='Association antérieure : '+$row.LinkSource+'. Le compte console reste à vérifier.'
        }
        $old=$script:SuppressGridSelectionEvents;$script:SuppressGridSelectionEvents=$true
        try{[void]$s.Rows.Add($row)}finally{$script:SuppressGridSelectionEvents=$old}
        if($s.FirstMs -lt 0){$s.FirstMs=$s.Started.ElapsedMilliseconds}
    }
    if($fresh -and -not $s.SelectionRestored -and [string]$s.State.PreserveSelectionDn -ieq [string]$row.DN){
        $grid=Get-DomeniaControl 'DgObjects';$s.SelectionRestored=$true
        if($null -ne $grid -and $grid.SelectedIndex -lt 0){
            $old=$script:SuppressGridSelectionEvents;$script:SuppressGridSelectionEvents=$true
            try{$grid.SelectedItem=$row}finally{$script:SuppressGridSelectionEvents=$old}
        }
    }
    if($fresh -and -not $isNew){
        $observation=$null;[void]$script:Live.Observations.TryGetValue($key,[ref]$observation)
        if($null -ne $observation -and $row.Guid -and $observation.Guid -and $row.Guid -ine $observation.Guid){[void]$script:Live.Done.Remove($key)}
        if(-not $script:Live.Done.ContainsKey($key)){Set-DomeniaLiveObservationOnRow $row $observation -Cached}
    }
    if($fresh -and (Test-DomeniaLiveProbeIntent -Row $row)){
        Request-DomeniaLiveProbe -Row $row
    }
    $s.RefreshNeeded=$true
}
function Clear-DomeniaLiveProbeIntent {
    if($null -eq $script:Live){return}
    # Only an unsent request is discarded. Never pretend a native in-flight call stopped.
    foreach($item in @($script:Live.PendingKeys.Values)){
        if($null -eq $item.Row -or $script:Live.Busy.ContainsKey([string]$item.Key)){continue}
        if([string]$item.Row.SessionState -eq 'En attente de vérification' -or (Get-DomeniaRowPresenceState $item.Row) -eq 'Pending'){
            $known=$null;[void]$script:Live.Observations.TryGetValue([string]$item.Key,[ref]$known)
            Set-DomeniaLiveObservationOnRow $item.Row $known -Cached
        }
    }
    $script:Live.Pending.Clear();$script:Live.PendingKeys=@{};$script:Live.ProbeSelection=$null
}
function Test-DomeniaLiveProbeIntent {
    param($Row)
    if($null -eq $script:Live -or $null -eq $script:Live.ProbeSelection -or $null -eq $Row){return $false}
    $intent=$script:Live.ProbeSelection
    if($intent.Requested -or [string]$Row.Type -ne 'Machine'){return $false}
    if(-not (Test-DomeniaLiveIdentity $intent ([long]$script:SessionEpoch) $script:Live.Identity) -or $intent.Generation -ne $script:GlobalSearchGeneration){return $false}
    if([string]$intent.Key -cne (Get-DomeniaLiveObjectKey $Row)){return $false}
    if($intent.Guid -and $Row.Guid -and [string]$intent.Guid -ine [string]$Row.Guid){return $false}
    return $true
}
function Select-DomeniaLiveResult {
    # SP-15: -Manual is Revérifier ce poste (ping and user), -Explicit a fiche rendered with its probes (ping, user
    # when the sub-option is checked). A simple click sends a ping only when « Vérifier au clic » is checked.
    [CmdletBinding()]
    param([switch]$Force,[switch]$Manual,[switch]$Explicit)
    if($script:SuppressGridSelectionEvents -or (Test-DomeniaAccessBusyWrite)){return}
    if(-not (Test-DomeniaLiveSearchActive)){
        # UX-25: a list shown from the history is not followed: say so instead of a silent click.
        if($null -ne (Get-Command Test-DomeniaHistoryListShown -CommandType Function -ErrorAction SilentlyContinue) -and (Test-DomeniaHistoryListShown)){Set-Status 'Liste de lʼhistorique : ce clic ne vérifie pas le poste. Actualisez la liste pour la relire.'}
        return
    }
    $grid=Get-DomeniaControl 'DgObjects'
    if($null -eq $grid -or -not $grid.IsEnabled){return}
    $row=Get-DomeniaSelectedGridRow
    if($null -eq $row -or @($grid.SelectedItems).Count -ne 1 -or [string]$row.Type -ne 'Machine'){
        Clear-DomeniaLiveProbeIntent
        return
    }
    $key=Get-DomeniaLiveObjectKey $row
    if(-not $key -or -not $script:Live.Search.Map.ContainsKey($key)){Clear-DomeniaLiveProbeIntent;return}
    $previous=$script:Live.ProbeSelection
    $same=($null -ne $previous -and [string]$previous.Key -ceq $key -and [string]$previous.Guid -ieq [string]$row.Guid -and $previous.Generation -eq $script:GlobalSearchGeneration -and (Test-DomeniaLiveIdentity $previous ([long]$script:SessionEpoch) $script:Live.Identity))
    if(-not $Manual -and -not $Explicit -and -not [bool]$script:Live.VerifyOnClick){
        # The AD fiche is preloaded by the selection itself; no ping. A click elsewhere drops an intent left unsent.
        if(-not $same){Clear-DomeniaLiveProbeIntent}
        return
    }
    if($same -and -not $Force){Request-DomeniaLiveProbe -Row $row;return}
    Clear-DomeniaLiveProbeIntent
    # A mouse/keyboard selection is the only source of an automatic intent.
    # Fresh AD must confirm the target before the CIM probe is allowed to start.
    $script:Live.ProbeSelection=[pscustomobject]@{
        Key=$key;Guid=[string]$row.Guid;Identity=$script:Live.Identity;Epoch=[long]$script:SessionEpoch
        Generation=[int]$script:GlobalSearchGeneration;RequestId=[guid]::NewGuid().ToString('N')
        Requested=$false;Manual=[bool]$Manual;ReadyAfter=[datetime]::UtcNow.AddMilliseconds(180)
    }
    try{Invoke-DomeniaTimerSoon -Owner 'Timer:Live'}catch{}
    Request-DomeniaLiveProbe -Row $row
}
function Request-DomeniaLiveProbe {
    param($Row,[switch]$Priority)
    if(-not (Test-DomeniaLiveSearchActive) -or -not (Test-DomeniaLiveProbeIntent -Row $Row)){return}
    $intent=$script:Live.ProbeSelection
    $key=Get-DomeniaLiveObjectKey $Row
    if(-not $script:Live.Search.Fresh.ContainsKey($key)){return}
    $current=$script:Live.Search.Map[$key]
    if(-not [object]::ReferenceEquals($current,$Row)){return}
    if($script:Live.Busy.ContainsKey($key)){
        $busyId=[string]$script:Live.Busy[$key];$job=$null
        if($script:AsyncJobs.Contains($busyId)){$job=$script:AsyncJobs[$busyId]}
        if($null -eq $job){$job=@($script:DetachedReadJobs|Where-Object{[string]$_.Id -ceq $busyId}|Select-Object -First 1)}
        if($null -ne $job -and $null -ne $job.CallbackState -and [string]$job.CallbackState.Guid -ieq [string]$Row.Guid -and (Test-DomeniaLiveIdentity $job.CallbackState ([long]$script:SessionEpoch) $script:Live.Identity)){$intent.Requested=$true}
        return
    }
    if($script:Live.PendingKeys.ContainsKey($key)){return}
    # Exactly one unsent intent. Cycling selection never creates a park-wide backlog.
    $computer=Get-DomeniaLiveField $Row 'UPN'
    if(-not $computer){$computer=Get-DomeniaLiveField $Row 'Name'}
    $item=[pscustomobject]@{
        Key=$key;Computer=$computer;Guid=Get-DomeniaLiveField $Row 'Guid';Identity=$script:Live.Identity
        Epoch=[long]$script:SessionEpoch;Generation=[int]$script:GlobalSearchGeneration
        ReadyAfter=$intent.ReadyAfter;Row=$Row;RequestId=$intent.RequestId
    }
    $script:Live.PendingKeys[$key]=$item;$script:Live.Pending.Enqueue($item)
    if(($script:Live.AutoDetect -or $intent.Manual) -and -not $script:Live.RemoteFaulted -and -not $script:DirectoryCredentialFaulted){$Row.SessionState='En attente de vérification'}
}
function Request-DomeniaLiveSelectedProbe {
    param([string]$Computer)
    if(-not (Test-DomeniaLiveSearchActive)){return $false}
    $row=Get-DomeniaSelectedGridRow
    if($null -eq $row -or $row.Type -ne 'Machine' -or (Normalize-LinkComputer $row.Name) -ne (Normalize-LinkComputer $Computer)){return $false}
    # SP-15: the fiche of this workstation was rendered with its probes: an explicit opening, not a click.
    Select-DomeniaLiveResult -Explicit
    [void](Set-DomeniaControlText 'LblLinkProbeStatus' -Text 'Vérification du poste sélectionné ; les observations précédentes restent datées en cache.')
    # The selection path owns this machine even while disabled or waiting for AD.
    # Do not fall back to a second, heavier probe when opening the same fiche.
    return $true
}
function Request-DomeniaLiveRecheck {
    # Explicit recheck concerns one selected machine, never every returned row.
    Select-DomeniaLiveResult -Force -Manual
}
function Merge-DomeniaLiveLinkMemory {
    param($Observation)
    if($Observation.Outcome -ne 'Observed' -or -not $Observation.LinkUser -or -not $Observation.UserDn){return}
    $computer=Normalize-LinkComputer ([string]$Observation.Computer);$user=Normalize-LinkUser ([string]$Observation.LinkUser)
    if(-not $computer -or -not $user){return}
    # D042: the observed console joins the relations of the workstation through the upsert rule (memory only).
    # CD-06: the RC1.10.7 path (overwrite of the workstation row with a fixed score) is removed.
    # CO-29: the date is stored in UTC ISO 8601, like every other relation date.
    $observedUtc=ConvertTo-DomeniaUtcDate ([string]$Observation.ObservedUtc);if($null -eq $observedUtc){$observedUtc=[datetime]::UtcNow}
    $observed=[pscustomobject]@{UserLogin=$user;Computer=$computer;Source='Console CIM/DCOM';Confidence=0;VerifiedInAD=$true;When=$observedUtc.ToString('o');Details='Compte console observé ; sessions RDP non recensées.';UserGuid=[string]$Observation.UserGuid;ComputerGuid=[string]$Observation.Guid;UserDn=[string]$Observation.UserDn;ComputerDn=[string]$Observation.Key;Kind='Console'}
    [void](Add-DomeniaRelation -Relation $observed -NoSave -Quiet)
    # D028: persistence is requested once; LiveCache must not write user_machine_links.
    # The association is a view of the committed Console family; no independent observation writer.
}
function Complete-DomeniaLivePresence {
    param($Result,$State)
    # The provider's early ping result follows the same transaction barrier as every other value.
    Complete-DomeniaLiveProbe -Result $Result -State $State
}

function Complete-DomeniaLiveProbe {
    param($Result,$State)
    $packet=Get-DomeniaEffectiveWorkerResult $Result @('Outcome','Key','Computer')
    try{
        if($null -eq $packet){throw 'Resultat de collecte vide.'}
        # Authentication stops are operational controls and must not await a disk callback.
        if($null -ne $script:Live -and (Test-DomeniaLiveIdentity $State ([long]$script:SessionEpoch) $script:Live.Identity) -and [string]$packet.Outcome -eq 'AuthRejected'){$script:Live.RemoteFaulted=$true;$script:Live.Pending.Clear();$script:Live.PendingKeys=@{}}
        [void](Submit-DomeniaRemoteObservations -Result $packet -State $State -SuccessHandler 'Complete-DomeniaLiveStored' -ErrorHandler 'Fail-DomeniaLiveStored')
    }catch{Fail-DomeniaLiveStored -Message $_.Exception.Message -State $State}
}

function Complete-DomeniaLiveStored {
    param($Result,$State)
    if($null -eq $script:Live -or -not (Test-DomeniaLiveIdentity $State ([long]$script:SessionEpoch) $script:Live.Identity)){return}
    if($State.Generation -ne [long]$script:GlobalSearchGeneration){return}
    $observation=Get-DomeniaCommittedObservation $Result $State
    if($null -eq $observation){return}
    $result=$observation
    $script:Live.Observations[[string]$State.Key]=$observation
    $script:Live.Done[[string]$State.Key]=$true
    if([string]$observation.PresenceCheckedUtc){$script:Live.PresenceSeen[[string]$State.Key]=$true}
    if($null -ne $script:Live.NegativeCache){
        $target=[string]$State.Computer
        if([string]::IsNullOrWhiteSpace($target)){$target=[string]$result.Computer}
        if(-not [string]::IsNullOrWhiteSpace($target)){
            $failureKind=''
            if([string]$result.Outcome -ieq 'Timeout'){$failureKind='Timeout'}
            elseif([string]$result.Outcome -ieq 'Unavailable'){$failureKind='Unreachable'}
            elseif([string]$result.Outcome -ieq 'Denied'){$failureKind='AccessDenied'}
            elseif([string]$result.Outcome -ieq 'AuthRejected'){$failureKind='CredentialRejected'}
            if($failureKind){[void](Register-DomeniaFailure $script:Live.NegativeCache $target 'Cim' $failureKind)}
            elseif(([string]$result.Outcome -ieq 'Observed') -or ([string]$result.Outcome -ieq 'NoConsole')){Clear-DomeniaFailure $script:Live.NegativeCache $target 'Cim'}
            # Point 15: the address seen by this ping places later reads of the workstation in its presumed subnet.
            try{[void](Register-DomeniaTargetAddress -Computer $target -Text ([string]$result.PresenceDetail))}catch{}
        }
    }
    if($observation.Outcome -eq 'AuthRejected'){
        $script:Live.RemoteFaulted=$true;$script:Live.Pending.Clear();$script:Live.PendingKeys=@{}
        Write-AppLog 'Compte distant rejeté : vérifications sur sélection suspendues. Corriger le compte dans Comptes avant de réessayer.' 'ERROR'
    }
    if($observation.DirectoryAuthRejected){$script:DirectoryCredentialFaulted=$true;$script:DirectoryCredentialFaultMessage='Identifiants AD refusés lors de la validation du compte console.'}
    if([string]$observation.Outcome -eq 'Observed'){Merge-DomeniaLiveLinkMemory $observation}
    if(Test-DomeniaLiveSearchActive){
        $s=$script:Live.Search
        if($s.Map.ContainsKey([string]$State.Key)){
            $row=$s.Map[[string]$State.Key]
            if(-not $row.Guid -or -not $observation.Guid -or $row.Guid -ieq $observation.Guid){
                Set-DomeniaLiveObservationOnRow $row $observation -Cached:([string]$result.Outcome -eq 'PresenceOnly')
                if($null -ne $script:SelectedObject -and [string]$script:SelectedObject.DN -ieq [string]$row.DN){
                    $rowState=Get-DomeniaRowPresenceState $row
                    Set-DomeniaPresenceText 'TxtCompPresence' ([string]$row.Presence) -PresenceState $rowState
                    Update-DomeniaObjectPresence -State ([string]$row.Presence) -Target ([string]$State.Computer) -PresenceState $rowState
                    # DS-08 (X04): the header pill takes the time of this observation (a remembered state shows none).
                    try{Set-DomeniaComputerHeaderPresenceTime -Observation $observation}catch{}
                }
                [void](Set-RowAssociationMetadata -Rows @($row));$s.RefreshNeeded=$true
                if([string]$row.Association){Set-DomeniaLoginColumnVisible $true}
            }
        }
    }
    if([string]$result.Outcome -ne 'PresenceOnly' -and (Get-CurrentSelectedComputerName) -ieq (Normalize-LinkComputer ([string]$State.Computer))){
        $view=Get-DomeniaLiveObservationView $observation
        $freshnessTable=$null;try{$freshnessTable=Get-DomeniaActiveFreshnessTable}catch{$freshnessTable=$null}
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' -Text ($view.State+' : '+$view.Display+' · '+(Get-DomeniaRecordFreshness $observation 'Console' -Table $freshnessTable).Label))
        # Do not rebuild the complete associations grid for every background result.
        $link=Get-ExistingLinkForComputer ([string]$State.Computer)
        if($null -ne $link){
            [void](Set-DomeniaControlText 'TxtCompLinkedUser' ([string]$link.UserLogin))
            [void](Set-DomeniaControlText 'TxtCompLinkSource' ([string]$link.Source))
            [void](Set-DomeniaControlText 'TxtCompLinkWhen' ([string]$link.When))
        }
    }
}

function Fail-DomeniaLiveStored {
    param([string]$Message,$State)
    if($null -eq $script:Live -or -not (Test-DomeniaLiveIdentity $State ([long]$script:SessionEpoch) $script:Live.Identity)){return}
    $script:Live.SaveFault=$Message
    Write-AppLog ('Mesure non publiee : enregistrement SQLite non confirme. '+$Message) 'WARN'
}

function Fail-DomeniaLiveProbe {
    param([string]$Message,$State)
    $at=[string](Get-DomeniaMemberValue $State 'RemoteStartedUtc')
    $probeUser=[bool](Get-DomeniaMemberValue $State 'ProbeUser')
    $outcome=if($Message -match '(?i)timeout|délai|delai'){'Timeout'}else{'Unavailable'}
    $result=[pscustomobject]@{Key=$State.Key;Computer=$State.Computer;Guid=$State.Guid;Outcome=$(if($probeUser){$outcome}else{'PresenceOnly'});User='';Source='CIM/DCOM';Detail=$Message;Presence='Erreur de ping';PresenceDetail=$Message;PresenceCheckedUtc=$at;ConsoleAttempted=$probeUser;ConsoleCheckedUtc=$(if($probeUser){$at}else{''})}
    Complete-DomeniaLiveProbe $result $State
}

function Complete-DomeniaLiveCache {
    param($Result,$State)
    Reset-DomeniaLiveIdentity
    # D028: one LiveCache worker at a time, so a write callback always ends the write in flight, whatever its identity.
    if($null -ne $script:Live -and $State.Mode -eq 'Write'){$script:Live.SaveInFlight=0;$script:Live.SaveJob='';$script:Live|Add-Member -NotePropertyName SaveBatch -NotePropertyValue $null -Force}
    if($null -eq $script:Live -or -not (Test-DomeniaLiveIdentity $State ([long]$script:SessionEpoch) $script:Live.Identity)){return}
    if($State.Mode -eq 'Read'){
        $script:Live.ObservationsLoaded=$true
        if(Test-DomeniaLiveSearchActive){foreach($row in $script:Live.Search.Rows){$script:Live.Refresh.Enqueue($row)}}
    }else{
        $script:Live.SaveJob='';$script:Live.SaveFault=''
        $script:Live.SaveAfter=[datetime]::UtcNow.AddSeconds(1)
    }
}
function Fail-DomeniaLiveCache {
    param([string]$Message,$State)
    Reset-DomeniaLiveIdentity
    if($null -ne $script:Live -and $State.Mode -eq 'Write'){$script:Live.SaveInFlight=0;$script:Live.SaveJob='';$script:Live|Add-Member -NotePropertyName SaveBatch -NotePropertyValue $null -Force}
    if($null -eq $script:Live -or -not (Test-DomeniaLiveIdentity $State ([long]$script:SessionEpoch) $script:Live.Identity)){return}
    if($State.Mode -eq 'Write'){
        $script:Live.SaveJob='';$script:Live.SaveFault=$Message;$script:Live.SaveAfter=[datetime]::UtcNow.AddSeconds(10)
        foreach($entry in @($State.Observations)){
            if(-not $script:Live.SaveQueue.ContainsKey([string]$entry.Key)){$script:Live.SaveQueue[[string]$entry.Key]=$entry}
        }
        if($null -eq $script:Live.QueryToSave -and $null -ne $State.Query){$script:Live.QueryToSave=$State.Query}
    }else{$script:Live.SaveFault=$Message}
    Write-AppLog ('Cache progressif indisponible : '+$Message+'. La lecture AD et les données en mémoire restent indépendantes.') 'WARN'
}
function Get-DomeniaLiveWorkerCount {
    param([string]$Operation='')
    $count=0
    foreach($job in @($script:AsyncJobs.Values)+@($script:DetachedReadJobs)){
        if($null -ne $job -and (-not $Operation -or [string]$job.OperationId -eq $Operation)){$count++}
    }
    return $count
}
function Get-DomeniaLiveDatabasePath {
    if($script:Live.DatabasePath){return [string]$script:Live.DatabasePath}
    $base=([string]$script:Conn.BaseDn).Trim().ToLowerInvariant()
    if($script:DatabaseScopeIdentity -ceq $base -and $script:DatabaseScopedPath){
        $script:Live.DatabasePath=[string]$script:DatabaseScopedPath
    }else{
        # Startup normally resolved this already. The legacy recovery path is used at most once per scope.
        $script:Live.DatabasePath=[string](Get-DomeniaDatabasePath)
    }
    return [string]$script:Live.DatabasePath
}
function Start-DomeniaLiveBackgroundWork {
    if((Get-DomeniaLiveWorkerCount 'StoragePurge') -gt 0){return}
    if([datetime]::UtcNow -lt $script:Live.NextStart){return}
    # C2: no probe, cache read or cache write in demonstration. C1: the rest policy decides before any background work.
    if([bool]$script:DemoMode){return}
    if(-not (Test-DomeniaLiveBackgroundAllowed -Source 'Live')){return}
    if($script:AsyncEngineClosing -or $script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){return}
    $max=[Math]::Max(1,[Math]::Min(32,[int](Get-CfgValue 'Async' 'MaxThreads' 6)))
    $physical=Get-DomeniaLiveWorkerCount
    if($physical -ge [Math]::Max(1,$max-2)){return} # reserve slots for interactive reads/writes
    $s=$script:Live.Search;$grid=Get-DomeniaControl 'DgObjects'
    # Read observations only from the central store; search rows have their own committed AD pipeline.
    if(Test-DomeniaLiveSearchActive){
        $readKey=[string]$script:GlobalSearchGeneration+'|'+[string]$s.State.BaseDn+'|'+[string]$s.State.Scope
        if([string](Get-DomeniaMemberValue $script:Live 'ObservationReadKey') -cne $readKey){
            $state=[pscustomobject]@{Identity=$script:Live.Identity;Epoch=[long]$script:SessionEpoch;Generation=[long]$script:GlobalSearchGeneration;ReadKey=$readKey;Offset=0;ScopeDn=[string]$s.State.BaseDn;Subtree=([string]$s.State.Scope -ne 'OneLevel')}
            [void](Initialize-DomeniaRemoteStoreState -State $state -Guid '' -DN $state.ScopeDn -Generation $state.Generation -ReadOnly)
            $job=Request-DomeniaStoreRead -Context $state.StoreContext -Query ([pscustomobject]@{Kind='Observation';ScopeDn=$state.ScopeDn;Subtree=$state.Subtree;Offset=0;Limit=250}) -SuccessHandler 'Complete-DomeniaLiveObservationRead' -ErrorHandler 'Fail-DomeniaLiveObservationRead' -CallbackState $state
            if($job){$script:Live|Add-Member -NotePropertyName ObservationReadKey -NotePropertyValue $readKey -Force;return}
        }
    }
    if($null -ne $script:DomeniaRemoteStoreQueue -and $script:DomeniaRemoteStoreQueue.Count -gt 0){return}
    if(-not (Test-DomeniaLiveSearchActive)){return}
    if($null -eq $grid -or -not $grid.IsEnabled){return}
    $intent=$script:Live.ProbeSelection
    if($null -eq $intent -or $intent.Requested){return}
    $selected=Get-DomeniaSelectedGridRow
    if(@($grid.SelectedItems).Count -ne 1 -or -not (Test-DomeniaLiveProbeIntent -Row $selected)){Clear-DomeniaLiveProbeIntent;return}
    if(-not $s.Fresh.ContainsKey([string]$intent.Key)){return}
    Request-DomeniaLiveProbe -Row $selected
    $parallel=[Math]::Max(1,[Math]::Min(3,[int](Get-CfgValue 'Streaming' 'MaxUserProbes' 2)))
    if(((Get-DomeniaLiveWorkerCount 'LiveConsole')+(Get-DomeniaLiveWorkerCount 'LiveSelectedPing')) -ge $parallel){return}
    $item=$script:Live.PendingKeys[[string]$intent.Key]
    if($null -eq $item -or $item.RequestId -cne $intent.RequestId -or $item.ReadyAfter -gt [datetime]::UtcNow){return}
    if(-not (Test-DomeniaLiveIdentity $item ([long]$script:SessionEpoch) $script:Live.Identity) -or $item.Generation -ne $script:GlobalSearchGeneration){Clear-DomeniaLiveProbeIntent;return}
    if(-not [object]::ReferenceEquals($item.Row,$s.Map[[string]$item.Key])){Clear-DomeniaLiveProbeIntent;return}
    if($script:Live.Busy.ContainsKey([string]$item.Key)){return}
    if($null -ne (Get-DomeniaRunningComputerUserProbe -Computer ([string]$item.Computer))){
        $item.ReadyAfter=[datetime]::UtcNow.AddSeconds(2)
        return
    }
    $neg = Test-DomeniaNegativeCache $script:Live.NegativeCache ([string]$item.Computer) 'Cim' -Explicit:([bool]$intent.Manual)
    # D027: the rule already lets a manual attempt through, except after a credential refusal (no replay, D018).
    if (($null -ne $neg) -and [bool]$neg.Suppressed) {
        $reason = [string]$neg.Reason
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'Echec recent' }
        if ($null -ne $item.Row) { Set-DomeniaLiveRowValue $item.Row 'SessionState' $reason }
        $intent.Requested=$true
        [void]$script:Live.PendingKeys.Remove([string]$item.Key)
        $script:Live.Pending.Clear()
        return
    }
    [void]$script:Live.PendingKeys.Remove([string]$item.Key);$script:Live.Pending.Clear()
    # One attempt per explicit intent; a timeout does not silently replay it.
    $intent.Requested=$true
    $probeUser=($script:Live.AutoDetect -or $intent.Manual) -and -not $script:Live.RemoteFaulted -and -not $script:DirectoryCredentialFaulted
    if($null -ne $script:AccessState -and $script:AccessState.Faults.ContainsKey('Remote')){$probeUser=$false}
    if(-not [bool](Get-CfgValue 'Remote' 'UseCim' $true)){$probeUser=$false}
    $operation=if($probeUser){'LiveConsole'}else{'LiveSelectedPing'}
    Add-Member -InputObject $item -NotePropertyName 'ProbeUser' -NotePropertyValue ([bool]$probeUser) -Force
    [void](Initialize-DomeniaRemoteStoreState -State $item -Guid $item.Guid -DN $item.Key -Generation $item.Generation -RequestId $item.RequestId)
    $item|Add-Member -NotePropertyName RemoteStartedUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
    $payload=[pscustomobject]@{Key=$item.Key;Computer=$item.Computer;Guid=$item.Guid;MethodSeconds=4;ProbeUser=$probeUser;ValidateConsoleIdentity=$false}
    try{
        $id=Start-UiTask -Name ('Présence'+$(if($probeUser){' et utilisateur'}else{''})+' '+$item.Computer) -OperationId $operation -Code (Get-DomeniaLiveProbeCode) -Payload $payload -CallbackState $item -TimeoutSeconds 14 -SuccessHandler 'Complete-DomeniaLiveProbe' -ErrorHandler 'Fail-DomeniaLiveProbe'
        if([string]::IsNullOrWhiteSpace([string]$id)){throw 'Vérification du poste non admise.'}
        $script:Live.Busy[[string]$item.Key]=$id
        if($probeUser){$item.Row.SessionState='Vérification en cours'}
    }catch{
        if($probeUser){$item.Row.SessionState='Vérification non démarrée · réessayer'}
        Write-AppLog 'Controle non demarre ; les dernieres mesures enregistrees restent affichees.' 'WARN'
        throw
    }
}
function Invoke-DomeniaLiveTick {
    if($null -eq $script:Live -or $script:Live.InTick -or $script:AsyncEngineClosing){return}
    $script:Live.InTick=$true
    try{
        Reset-DomeniaLiveIdentity
        # A cancelled native call still occupies its slot until actually completed.
        foreach($key in @($script:Live.Busy.Keys)){
            $id=[string]$script:Live.Busy[$key]
            $exists=$script:AsyncJobs.Contains($id)
            if(-not $exists){foreach($job in @($script:DetachedReadJobs)){if([string]$job.Id -eq $id){$exists=$true;break}}}
            if(-not $exists){
                [void]$script:Live.Busy.Remove($key)
                if((Test-DomeniaLiveSearchActive) -and -not $script:Live.Done.ContainsKey($key) -and $script:Live.Search.Map.ContainsKey($key)){
                    $row=$script:Live.Search.Map[$key]
                    $row.SessionState='Non confirmé · lecture arrêtée'
                }
            }
        }
        if(-not $script:ActiveWriteTaskId -and $script:WriteState -notin @('Unknown','UnknownPending') -and $script:Live.Deferred.Count -gt 0){
            $deferred=$script:Live.Deferred.Dequeue();Complete-DomeniaLiveProbe $deferred.Result $deferred.State
        }
        if(-not $script:ActiveWriteTaskId -and $script:WriteState -notin @('Unknown','UnknownPending') -and $null -ne $script:Live.PresenceEvents){
            $packet=$null
            for($i=0;$i -lt 4 -and $script:Live.PresenceEvents.TryDequeue([ref]$packet);$i++){Complete-DomeniaLivePresence $packet.Result $packet.State;$packet=$null}
        }
        $grid=Get-DomeniaControl 'DgObjects'
        if(-not $script:ActiveWriteTaskId -and $script:WriteState -notin @('Unknown','UnknownPending')){
            for($i=0;$i -lt 12 -and $script:Live.IdentityRows.Count -gt 0;$i++){
                $stale=$script:Live.IdentityRows.Dequeue()
                $stale.SessionState='Compte changé · à revérifier'
                $stale.SessionDetail='Observation de la précédente identité de consultation. Relancez la recherche pour vérifier avec les comptes actuels.'
            }
        }
        $activeSearch=Test-DomeniaLiveSearchActive
        if($activeSearch){
            $s=$script:Live.Search
            if($null -ne $grid -and $grid.IsEnabled -and -not $script:ActiveWriteTaskId -and $script:WriteState -notin @('Unknown','UnknownPending')){
                # A large backlog (lists of several thousand rows) gets a wider slice so that 10 000 rows do not take a minute.
                $backlog=($s.Progress.Count+$s.CacheProgress.Count) -gt 200
                $maxRows=if($backlog){400}else{12};$sliceMs=if($backlog){30}else{6}
                $watch=[Diagnostics.Stopwatch]::StartNew();$done=0
                while($done -lt $maxRows -and $watch.ElapsedMilliseconds -lt $sliceMs){
                    $event=$null
                    if($s.Progress.TryDequeue([ref]$event)){Add-DomeniaLiveRow $event;$done++;continue}
                    if((-not $s.Ended -or $s.Error) -and $s.CacheProgress.TryDequeue([ref]$event)){Add-DomeniaLiveRow $event;$done++;continue}
                    if($script:Live.Refresh.Count -gt 0){
                        $row=$script:Live.Refresh.Dequeue();$key=Get-DomeniaLiveObjectKey $row
                        if($s.Map.ContainsKey($key) -and -not $script:Live.Done.ContainsKey($key)){
                            $observation=$null;[void]$script:Live.Observations.TryGetValue($key,[ref]$observation)
                            Set-DomeniaLiveObservationOnRow $row $observation -Cached -Pending:($script:Live.Busy.ContainsKey($key))
                        }
                        $done++;continue
                    }
                    break
                }
                if($s.Ended -and $s.Progress.IsEmpty -and -not $s.Finalized){
                    if(-not $s.Error){
                        if($null -eq $s.Prune){$s.Prune=[Collections.Generic.Queue[string]]::new();foreach($key in @($s.Map.Keys)){if(-not $s.Fresh.ContainsKey($key)){$s.Prune.Enqueue($key)}}}
                        $count=0
                        $old=$script:SuppressGridSelectionEvents;$script:SuppressGridSelectionEvents=$true
                        try{while($s.Prune.Count -gt 0 -and $count -lt 12){$key=$s.Prune.Dequeue();[void]$s.Rows.Remove($s.Map[$key]);[void]$s.Map.Remove($key);$count++}}finally{$script:SuppressGridSelectionEvents=$old}
                        if($s.Prune.Count -eq 0){
                            # Each displayed row already came from SQLite. Rendering creates no duplicate snapshot.
                            $s.Finalized=$true
                        }
                    }else{$s.Finalized=$true}
                    if($s.Finalized){
                        # Cached rows may have been pruned: the 'Compte' column and the workstation actions follow the final list.
                        Update-DomeniaLoginColumnFromRows $s.Rows
                        # The selection kept for this search is no longer in the list: clear it everywhere.
                        if($null -ne $grid -and @($grid.SelectedItems).Count -eq 0 -and ($null -ne $script:SelectionLoad -or $null -ne $script:SelectedObject)){Clear-DomeniaSelectionEverywhere}
                        $label=if($s.Error){'Liste partielle · '+$s.Fresh.Count+' résultat(s) AD · vérification incomplète'}else{"$($s.Fresh.Count) résultat(s) AD vérifiés"}
                        $limited=(($null -ne $s.Final) -and ([bool]$s.Final.LimitReached))
                        if($limited){$label+=' · limite atteinte, affiner'}
                        # D037: the counter states complete or limited; the former wording stays only without the search rules.
                        if($s.SearchRules -and -not $s.Error){$label=Get-DomeniaResultCounterText -Loaded $s.Fresh.Count -Limit ([int]$s.State.Limit) -Complete (-not $limited) -Visible ([int]$grid.Items.Count)}
                        $script:BranchCountLabel=$label
                        Set-Status $label $(if($s.Error){'WARN'}else{'INFO'})
                        # FO-01: few names or none: offer the « contains » search (a chip, read on click only).
                        if([bool]$s.ContainsOffer){Update-DomeniaSearchContainsOffer -Search $s}
                        Write-AppLog ("Chargement progressif : premier affichage=$($s.FirstMs) ms ; AD=$($s.Fresh.Count) ; total=$($s.Started.ElapsedMilliseconds) ms ; complet=$(-not [bool]$s.Error).") 'INFO'
                    }
                }
                if(-not $s.Finalized){
                    $script:BranchCountLabel="$($s.Rows.Count) ligne(s) affichée(s) · $($s.Fresh.Count) vérifiée(s) AD · chargement…"
                    if($s.SearchRules){$script:BranchCountLabel=(Get-DomeniaResultCounterText -Loaded $s.Fresh.Count -Limit ([int]$s.State.Limit) -Loading $true)+" · $($s.Rows.Count) ligne(s) affichée(s)"}
                }
                [void](Set-DomeniaControlText 'LblBranchCount' $script:BranchCountLabel)
                $filterBox=Get-DomeniaControl 'TxtSuiteResultFilter'
                # CO-05: the text of the list filters every list; the presence only the OU lists.
                $hasText=(($null -ne $filterBox) -and (-not [string]::IsNullOrWhiteSpace([string]$filterBox.Text)))
                $hasFilter=($hasText -or (((Get-DomeniaSearchMode) -ne 'Global') -and ($script:CurrentPresenceFilter -ne 'Tous')))
                if(($s.FilterPending -or (($hasFilter -or -not $script:Live.Notifying) -and $s.RefreshNeeded)) -and ([datetime]::UtcNow-$script:Live.LastFilter).TotalMilliseconds -ge 400){Update-DomeniaLiveFilter}
                [void](Set-DomeniaControlText 'LblSuiteResultCount' ($(if($s.Error){'Liste partielle · '}elseif(-not $s.Finalized){'Chargement… · '}elseif(($null -ne $s.Final) -and ([bool]$s.Final.LimitReached)){'Limite atteinte · '}else{''})+"$($grid.Items.Count) / $($s.Rows.Count) lignes visibles · filtre de la liste"))
            }
        }
        Update-DomeniaSearchMoreButton -Search $(if($activeSearch){$script:Live.Search}else{$null})
        try{Start-DomeniaLiveBackgroundWork}catch{$script:Live.NextStart=[datetime]::UtcNow.AddSeconds(2);Write-AppLog ('Travail différé : '+$_.Exception.Message) 'WARN'}
        # D028: the save state is the rule label shared with Fiabilite (Get-DomeniaPersistenceState, Storage.UI).
        $save=(Get-DomeniaPersistenceState).Label
        $probe=if($script:DirectoryCredentialFaulted){'validation AD suspendue · revoir la connexion'}elseif($script:Live.RemoteFaulted){'compte distant refusé · détection suspendue'}elseif($script:Live.PendingKeys.Count -or $script:Live.Busy.Count){"poste sélectionné : $($script:Live.PendingKeys.Count) en attente, $($script:Live.Busy.Count) en cours"}elseif(-not $script:Live.VerifyOnClick){'Clic : fiche AD seulement, sans ping · Revérifier ce poste : un ping'}elseif(-not $script:Live.AutoDetect){'Clic : un ping du poste, utilisateur non lu · aucun contrôle collectif'}else{'Clic : un ping et lʼutilisateur connecté · aucun contrôle collectif'}
        # UX-12: a survey of the list shows its own short count and bar (Update-DomeniaParkControls); this line keeps
        # the state of the click verification and of the local saves.
        [void](Set-DomeniaControlText 'LblLiveState' ($probe+' · '+$save))
    }finally{$script:Live.InTick=$false}
}
function Test-DomeniaLiveBackgroundAllowed {
    # C1 belongs to the engine lane. An absent or failing policy means allowed (open fallback of the same contract).
    # PF-10: no command lookup in the tick; a missing rule falls in the same open fallback.
    param([string]$Source='Live')
    try{return [bool](Test-DomeniaBackgroundWorkAllowed -Source $Source)}catch{return $true}
}
function Test-DomeniaLiveTickNeeded {
    # PF-06: the progressive search ticks every 80 ms only while it has visible work: rows, probes, presence events,
    # a selection to check, or (when the rest policy allows it) a cache read or write to start. Otherwise the state
    # line is refreshed once per second.
    $l=$script:Live
    if($null -eq $l){return $false}
    if($l.Busy.Count -or $l.Deferred.Count -or $l.Refresh.Count -or $l.IdentityRows.Count){return $true}
    if($null -ne $l.PresenceEvents -and -not $l.PresenceEvents.IsEmpty){return $true}
    $s=$l.Search
    if($null -ne $s){
        if(-not [bool]$s.Finalized){return $true}
        if(-not $s.Progress.IsEmpty -or -not $s.CacheProgress.IsEmpty){return $true}
        if($null -ne $s.Prune -and $s.Prune.Count){return $true}
    }
    $pendingBackground=($l.PendingKeys.Count -or $l.Pending.Count -or $l.SaveQueue.Count -or $null -ne $l.QueryToSave -or ($null -ne $l.ProbeSelection -and -not [bool]$l.ProbeSelection.Requested) -or ($null -ne $s -and -not [bool]$s.CacheRequested))
    if($pendingBackground -and (Test-DomeniaLiveBackgroundAllowed -Source 'Live')){return $true}
    return $false
}
function Update-DomeniaSearchMoreButton {
    # D037: 'Charger la suite' is enabled only for the current, finished and limited list, below 20 000 lines.
    # MO-07: « Charger jusquʼà 1 000 » (then 5 000, then 20 000) brings the list to that size in one gesture.
    param($Search)
    $button=Get-DomeniaControl 'BtnSearchMore'
    if($null -eq $button){return}
    $decision=$null
    # SearchRules is resolved once per search by Begin-DomeniaLiveSearch: no command lookup on each tick.
    if($null -ne $Search -and [bool]$Search.SearchRules){
        $decision=Get-DomeniaContinuationDecision -Finalized ([bool]$Search.Finalized) -HasError (-not [string]::IsNullOrEmpty([string]$Search.Error)) -LimitReached (($null -ne $Search.Final) -and ([bool]$Search.Final.LimitReached)) -Limit ([int]$Search.State.Limit) -Loaded ([int]$Search.Fresh.Count)
    }
    $enabled=($null -ne $decision -and [bool]$decision.Allowed -and -not (Test-DomeniaAccessBusyWrite))
    $tip=if($null -ne $decision){[string]$decision.Reason}else{'Aucune liste courante à prolonger : lancez une recherche.'}
    if([bool]$button.IsEnabled -ne $enabled){$button.IsEnabled=$enabled}
    if([string]$button.ToolTip -cne $tip){$button.ToolTip=$tip}
    $jump=Get-DomeniaControl 'BtnSearchMoreJump'
    if($null -eq $jump){return}
    $offer=($enabled -and ([int]$decision.JumpLimit -gt 0))
    $wanted=if($offer){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
    if($jump.Visibility -ne $wanted){$jump.Visibility=$wanted}
    if($offer){
        $text=[string]$decision.JumpText
        $jumpTip=$text+' : lit les '+([int]$decision.JumpPage).ToString('N0',[Globalization.CultureInfo]::GetCultureInfo('fr-FR'))+' lignes suivantes en une fois, sans relire les lignes déjà chargées. Plafond de sécurité : 20 000 lignes.'
        if([string]$jump.Content -cne $text){$jump.Content=$text}
        if([string]$jump.ToolTip -cne $jumpTip){$jump.ToolTip=$jumpTip;[Windows.Automation.AutomationProperties]::SetName($jump,$text);[Windows.Automation.AutomationProperties]::SetHelpText($jump,$jumpTip)}
    }
    if([bool]$jump.IsEnabled -ne $offer){$jump.IsEnabled=$offer}
}
function Invoke-DomeniaSearchMore {
    # D037 / MO-07: explicit continuation. Only the next rows of the same query, mode, view and perimeter are read,
    # sorted by name after the last name already read; the rows on screen stay and are never read or published again.
    # -Step Jump brings the list to the next milestone (« Charger jusquʼà 1 000 »). Nothing is replayed automatically.
    param([ValidateSet('Next','Jump')][string]$Step='Next')
    if(-not (Test-DomeniaLiveSearchActive)){Set-Status 'La liste affichée nʼest plus la recherche courante : relancez la recherche.' 'WARN';Update-DomeniaSearchMoreButton -Search $null;return}
    $s=$script:Live.Search
    $decision=Get-DomeniaContinuationDecision -Finalized ([bool]$s.Finalized) -HasError (-not [string]::IsNullOrEmpty([string]$s.Error)) -LimitReached (($null -ne $s.Final) -and ([bool]$s.Final.LimitReached)) -Limit ([int]$s.State.Limit) -Loaded ([int]$s.Fresh.Count)
    if(-not [bool]$decision.Allowed){Set-Status ([string]$decision.Reason) 'WARN';Update-DomeniaSearchMoreButton -Search $s;return}
    $target=[int]$decision.NextLimit
    if($Step -eq 'Jump'){
        if([int]$decision.JumpLimit -le 0){Set-Status 'Aucun palier supérieur : utilisez « Charger la suite ».' 'WARN';return}
        $target=[int]$decision.JumpLimit
    }
    $mode=if([string]$s.State.SearchMode -eq 'Global'){'Global'}else{'OU'}
    $viewId='';if($null -ne $s.State.PSObject.Properties['ViewId']){$viewId=[string]$s.State.ViewId}
    # D037 / UX-33: the same perimeter as the list (view chip choice, base, depth), not the one the chip or the tree show now.
    $viewScope='';if($viewId -and $null -ne $s.State.PSObject.Properties['ViewChoice'] -and [string]$s.State.ViewChoice -in @('OU','Domain')){$viewScope=[string]$s.State.ViewChoice}
    # MO-07: the filter that produced the list is kept from its first read; later continuations reuse it with their cursor.
    $baseFilter=[string](Get-DomeniaMember $s 'ContinuationBaseFilter' '')
    if(-not $baseFilter){$baseFilter=[string](Get-DomeniaMember $s.Final 'FilterUsed' '');if($baseFilter){Add-Member -InputObject $s -NotePropertyName ContinuationBaseFilter -NotePropertyValue $baseFilter -Force}}
    $loadedDns=[Collections.Generic.List[string]]::new()
    foreach($row in @($s.Rows)){if(($null -ne $row) -and [string]$row.DN){$loadedDns.Add([string]$row.DN)}}
    $request=New-DomeniaContinuationRequest -FilterUsed $baseFilter -Cursor ([string](Get-DomeniaMember $s 'ContinuationCursor' '')) -LoadedDns $loadedDns.ToArray() -Loaded ([int]$s.Fresh.Count) -Target $target -PageSize ([int](Get-CfgValue 'Browser' 'SearchPageSize' 250)) -Reader ([string]$script:Live.Identity) -Generation ([long]$script:GlobalSearchGeneration) -BaseDn ([string]$s.State.BaseDn)
    # FO-01: the next rows of a « contains » list are still the names that contain the text.
    $contains=([string](Get-DomeniaMember $s.State 'MatchMode' '') -eq 'Contains')
    if(-not [bool]$request.Valid){
        # A list without a known filter (an older result) is read again with the larger bound, as before MO-07.
        Write-AppLog ('Charger la suite : '+[string]$request.Reason) 'WARN'
        Invoke-GlobalSearch -SearchMode $mode -PreserveSelection -SilentError -ViewId $viewId -LimitOverride $target -ViewScope $viewScope -ExpectBaseDn ([string]$s.State.BaseDn) -ExpectScope ([string]$s.State.Scope) -Contains:$contains
        return
    }
    Invoke-GlobalSearch -SearchMode $mode -PreserveSelection -SilentError -ViewId $viewId -ViewScope $viewScope -ExpectBaseDn ([string]$s.State.BaseDn) -ExpectScope ([string]$s.State.Scope) -Continuation $request -Contains:$contains
}

function Complete-DomeniaLiveObservationRead {
    param($Result,$State)
    if($null -eq $script:Live -or -not (Test-DomeniaRemoteStoreContext $State $null) -or -not (Test-DomeniaLiveIdentity $State ([long]$script:SessionEpoch) $script:Live.Identity) -or $State.Generation -ne [long]$script:GlobalSearchGeneration){return}
    if($Result.Busy -or $Result.Missing -or [string]$Result.DataSource -ne 'SQLite' -or [string]$Result.StoreId -cne [string]$State.StoreContext.StoreId){Fail-DomeniaLiveObservationRead -Message 'Base indisponible : observations conservees sans mise a jour.' -State $State;return}
    foreach($observation in @($Result.ObservationRows)){
        if($null -eq $observation -or -not $observation.Key -or -not $observation.Guid){continue}
        $previous=$null;[void]$script:Live.Observations.TryGetValue([string]$observation.Key,[ref]$previous)
        if($null -ne $previous -and [long](Get-DomeniaMemberValue $previous 'Revision') -gt [long](Get-DomeniaMemberValue $observation 'Revision')){continue}
        $script:Live.Observations[[string]$observation.Key]=$observation
        if(Test-DomeniaLiveSearchActive){$row=$script:Live.Search.Map[[string]$observation.Key];if($null -ne $row -and [string]$row.Guid -ieq [string]$observation.Guid){$script:Live.Refresh.Enqueue($row)}}
    }
    if(([int]$State.Offset+250) -lt [int]$Result.Total){
        $State.Offset+=250
        $job=Request-DomeniaStoreRead -Context $State.StoreContext -Query ([pscustomobject]@{Kind='Observation';ScopeDn=$State.ScopeDn;Subtree=$State.Subtree;Offset=$State.Offset;Limit=250}) -SuccessHandler 'Complete-DomeniaLiveObservationRead' -ErrorHandler 'Fail-DomeniaLiveObservationRead' -CallbackState $State
        if(-not $job){Fail-DomeniaLiveObservationRead -Message 'Suite de lecture locale non admise.' -State $State};return
    }
    $script:Live.ObservationsLoaded=$true
}
function Fail-DomeniaLiveObservationRead {
    param([string]$Message,$State)
    if($null -eq $script:Live -or $State.Generation -ne [long]$script:GlobalSearchGeneration){return}
    $script:Live.SaveFault=$Message
    Write-AppLog ('Lecture des mesures enregistrees incomplete : '+$Message) 'WARN'
}
