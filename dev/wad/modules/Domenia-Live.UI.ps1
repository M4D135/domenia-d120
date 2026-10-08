# Progressive search: only this module's timer touches the live WPF collection.
# LDAP, CIM and SQLite are executed by pinned operations in background runspaces.
$script:LiveModuleRoot=$PSScriptRoot
function Get-DomeniaLiveIdentitySignal {
    $ad=if($script:Conn.UseCredential){[string]$script:Conn.BindUser}else{[string]$script:ProcessIdentity}
    $adRetry=$null;if(Get-Command Get-DomeniaRetryCredential -ErrorAction SilentlyContinue){$adRetry=Get-DomeniaRetryCredential 'GlobalSearch'}
    if($null -ne $adRetry){$ad=[string]$adRetry.UserName}
    $adRef=if($null -ne $adRetry){[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($adRetry)}else{0}
    $remote=$script:MachineCredential
    if($null -eq $remote){$remote=$script:RemoteAdminCredential}
    if($null -eq $remote -and $script:Conn.UseCredential){$remote=$script:Conn.Credential}
    $remoteRetry=$null;if(Get-Command Get-DomeniaRetryCredential -ErrorAction SilentlyContinue){$remoteRetry=Get-DomeniaRetryCredential 'LiveConsole'}
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
            SaveQueue=@{};QueryToSave=$null;SaveJob='';SaveAfter=[datetime]::MinValue;SaveFault='';SaveInFlight=0
            PresenceEvents=[Collections.Concurrent.ConcurrentQueue[object]]::new();PresenceSeen=@{};RemoteFaulted=$false;NextStart=[datetime]::MinValue;Timer=$null;InTick=$false;AutoDetect=$true;ProbeSelection=$null;LastFilter=[datetime]::MinValue;NegativeCache=(New-DomeniaNegativeCache)
        }
        Reset-DomeniaLiveIdentity
        $check=Get-DomeniaControl 'ChkLiveUsers'
        if($null -ne $check){
            $check.IsChecked=ConvertTo-SuiteFlag (Get-CfgValue 'Streaming' 'VerifyUserOnSelection' $true) -Default $true
            $script:Live.AutoDetect=[bool]$check.IsChecked
            $check.Add_Checked({if($null -ne $script:Live){$script:Live.AutoDetect=$true;Select-DomeniaLiveResult}})
            $check.Add_Unchecked({if($null -ne $script:Live){$script:Live.AutoDetect=$false}})
        }
        $button=Get-DomeniaControl 'BtnLiveRecheck'
        if($null -ne $button){$button.Add_Click({Request-DomeniaLiveRecheck})}
        $timer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
        $timer.Interval=[TimeSpan]::FromMilliseconds(80)
        $timer.Add_Tick({try{Invoke-DomeniaLiveTick}catch{Write-AppLog ('Chargement progressif : '+$_.Exception.Message) 'ERROR'}})
        $script:Live.Timer=$timer;$timer.Start()
        # D019: owned timer, stopped by the resource registry at shutdown.
        if($null -ne (Get-Command Register-DomeniaOwnedTimer -CommandType Function -ErrorAction SilentlyContinue)){try{[void](Register-DomeniaOwnedTimer -Owner 'Timer:Live' -Timer $timer)}catch{}}
        $script:Window.Add_Closed({Stop-DomeniaLive -Closing})
    }catch{Write-AppLog ('Initialisation progressive impossible : '+$_.Exception.Message) 'ERROR';$script:Live=$null}
}
function Reset-DomeniaLiveIdentity {
    if($null -eq $script:Live){return}
    $signal=Get-DomeniaLiveIdentitySignal
    if([string]$script:Live.Identity -ceq $signal.Signal){return}
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
}
function Stop-DomeniaLiveSearch {
    if($null -eq $script:Live -or $null -eq $script:Live.Search){return}
    $s=$script:Live.Search;$s.Stopped=$true
    try{$s.Stop.Cancel()}catch{}
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
    # is shown only when at least one listed row has such an account.
    param([bool]$Visible)
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return}
    $wanted=if($Visible){'Visible'}else{'Collapsed'}
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
    $grid=Get-DomeniaControl 'DgObjects';if($null -eq $grid){return}
    $machine=[bool]$script:SearchListHasMachine;$linkable=($machine -or [bool]$script:SearchListHasUser)
    foreach($column in @($grid.Columns)){
        $header=[string]$column.Header
        $show=$null
        if($header -in @('Utilisateur connecté (console)','Vérification utilisateur','Présence réseau','OS')){$show=$machine}
        elseif($header -in @('Association mémorisée','Source lien','Qualification','Derniere connexion')){$show=$linkable}
        if($null -eq $show -or ($RevealOnly -and -not $show)){continue}
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
    foreach($name in @('BtnParkResults','BtnParkPing','BtnParkAnalyze')){$button=Get-DomeniaControl $name;if($null -ne $button -and -not $script:DemoMode){$button.IsEnabled=($ready -and [bool]$script:SearchListHasMachine)}}
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
    $key=Get-DomeniaLiveHash $keyText
    $rows=[Collections.ObjectModel.ObservableCollection[object]]::new()
    # D034/D037: the search rules are resolved once per search; without them the arrival order and the former counter remain.
    $rules=($null -ne (Get-Command Get-DomeniaSearchRank -CommandType Function -ErrorAction SilentlyContinue))
    $ranking=($rules -and [string]$State.SearchMode -eq 'Global' -and -not [string]::IsNullOrWhiteSpace([string]$State.Search) -and -not $viewId)
    if($ranking -and $null -ne (Get-Command Get-DomeniaFeatureFlag -CommandType Function -ErrorAction SilentlyContinue)){$ranking=[bool](Get-DomeniaFeatureFlag -Name 'SearchRanking' -Default $true)}
    $s=[pscustomobject]@{
        Identity=$script:Live.Identity;Epoch=[long]$script:SessionEpoch;State=$State;QueryKey=$key
        Rows=$rows;Map=@{};Fresh=@{};FreshOrder=[Collections.Generic.List[object]]::new();CacheKeys=[Collections.Generic.Queue[string]]::new();Progress=$queue;CacheProgress=$cacheQueue;Stop=$stop
        Stopped=$false;SelectionRestored=$false;Ended=$false;Final=$null;Error='';Finalized=$false;Prune=$null;CacheRequested=$false
        Started=[Diagnostics.Stopwatch]::StartNew();FirstMs=-1L;CacheUtc='';RefreshNeeded=$false
        Ranking=[bool]$ranking;SearchRules=[bool]$rules
    }
    $script:Live.Search=$s;$script:BranchObjects=$rows;$script:BranchCountLabel='Chargement progressif…'
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
    Add-Member -InputObject $Payload -NotePropertyName Progress -NotePropertyValue $queue -Force
    Add-Member -InputObject $Payload -NotePropertyName StopToken -NotePropertyValue $stop.Token -Force
    Add-Member -InputObject $Payload -NotePropertyName StreamPageSize -NotePropertyValue 40 -Force
    if($script:Live.MemoryQueries.ContainsKey($key)){
        $cached=$script:Live.MemoryQueries[$key]
        foreach($r in @($cached.Rows)){$cacheQueue.Enqueue([pscustomobject]@{Kind='CachedRow';Row=$r;ObservedUtc=[string]$cached.ObservedUtc})}
    }
    return $s
}
function Complete-DomeniaLiveSearch {
    param($Result,$State)
    if(-not (Test-DomeniaLiveSearchActive) -or -not [object]::ReferenceEquals($script:Live.Search,$State.LiveState)){return}
    $s=$script:Live.Search
    $effective=Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows','BaseDn','Scope')
    if($null -eq $effective -or [string]$effective.BaseDn -ine [string]$State.BaseDn -or [string]$effective.Scope -ne [string]$State.Scope){throw 'Résultat de recherche sans périmètre valide.'}
    $s.Final=$effective;$s.Ended=$true
    if($effective.Partial){$s.Error=[string]$effective.Failure;if(-not $s.Error){$s.Error='Résultat LDAP partiel.'}}
    # The worker has already published the rows. Finalization waits for the UI queue.
}
function Fail-DomeniaLiveSearch {
    param([string]$Message,$State)
    if(-not (Test-DomeniaLiveSearchActive) -or -not [object]::ReferenceEquals($script:Live.Search,$State.LiveState)){return}
    $s=$script:Live.Search;$s.Error=$Message;$s.Ended=$true
    try{$s.Stop.Cancel()}catch{}
    Write-AppLog ('Recherche incomplète : '+$Message) 'WARN'
}
function Stop-DomeniaLiveJob {
    param($Job)
    if($null -eq $Job -or $null -eq $script:Live){return}
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
        if(-not $Job.Superseded -and [object]::ReferenceEquals($s,$script:Live.Search)){$s.Ended=$true;$s.Error='Lecture interrompue : liste partielle, non enregistrée comme complète.'}
    }
}
function Update-DomeniaLiveFilter {
    if($null -eq $script:Live -or $null -eq $script:Live.Search){return}
    $s=$script:Live.Search;$grid=Get-DomeniaControl 'DgObjects'
    if($null -eq $grid -or -not $grid.IsEnabled -or -not [object]::ReferenceEquals($grid.ItemsSource,$s.Rows)){return}
    $view=[Windows.Data.CollectionViewSource]::GetDefaultView($s.Rows)
    $filter=Get-DomeniaControl 'TxtSuiteResultFilter'
    $query=if($null -ne $filter){[string]$filter.Text}else{''}
    $presence=[string]$script:CurrentPresenceFilter
    if((Get-DomeniaSearchMode) -eq 'Global'){$query='';$presence='Tous'}
    # Capture values, not controls; filtering performs no network or database I/O.
    if($query.Length -gt 120){$query=$query.Substring(0,120)}
    $terms=@($query.Trim() -split '\s+'|Where-Object {$_})
    $predicate={
        param($row)
        $network=([string]$row.Presence -replace ' \(cache\)$','').Trim()
        if($network -in @('','Inconnu')){$network='Non vérifié'}
        $wanted=$presence
        if($wanted -eq 'Inconnu'){$wanted='Non vérifié'}
        if($wanted -eq 'Hors ligne'){$wanted='Sans réponse au ping'}
        if($network -eq 'Hors ligne'){$network='Sans réponse au ping'}
        if($wanted -and $wanted -ne 'Tous' -and $network -ne $wanted){return $false}
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
    [void](Set-DomeniaControlText 'LblSuiteResultCount' ("$($grid.Items.Count) / $($s.Rows.Count) lignes visibles"+$(if((Get-DomeniaSearchMode) -eq 'Global'){' · recherche globale sans filtre local'}else{' · filtre local'})))
    $script:Live.LastFilter=[datetime]::UtcNow;$s.RefreshNeeded=$false
}
function Set-DomeniaLiveObservationOnRow {
    param($Row,$Observation,[switch]$Cached,[switch]$Pending)
    if($Row.Type -ne 'Machine'){return}
    # GUID mismatch means a recreated AD object, not the same cached machine.
    if($null -ne $Observation -and $Row.Guid -and $Observation.Guid -and [string]$Row.Guid -ine [string]$Observation.Guid){$Observation=$null}
    $view=Get-DomeniaLiveObservationView $Observation -Cached:$Cached -Pending:$Pending
    $Row.SessionDisplay=$view.Display;$Row.SessionState=$view.State;$Row.SessionDetail=$view.Detail+"`r`n"+(Get-DomeniaRecordFreshness $Observation 'Console').Label
    $Row.SessionChecked=$view.Checked;$Row.SessionObserved=$view.Observed;$Row.SessionSource=$view.Source
    $key=Get-DomeniaLiveObjectKey $Row
    $historical=[bool]$Cached
    if($null -ne $script:Live -and $null -ne $script:Live.PresenceSeen -and $script:Live.PresenceSeen.ContainsKey($key)){$historical=$false}
    $network=Get-DomeniaLivePresenceView $Observation -Cached:$historical
    $Row.Presence=$network.Display;Set-DomeniaLiveRowValue $Row 'PresenceDetail' ($network.Detail+"`r`n"+(Get-DomeniaRecordFreshness $Observation 'Presence').Label)
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
    $row.DirectoryChecked=[string]$Event.ObservedUtc
    if($fresh){if(-not $s.Fresh.ContainsKey($key)){[void]$s.FreshOrder.Add($snapshot)};$s.Fresh[$key]=$snapshot}
    if($isNew){
        [void](Set-RowAssociationMetadata -Rows @($row))
        if([string]$row.Type -eq 'Machine' -and [string]$row.Association -and -not [bool]$s.PSObject.Properties['LoginShown']){Set-DomeniaLoginColumnVisible $true;$s|Add-Member -NotePropertyName LoginShown -NotePropertyValue $true -Force}
        $row.Presence=$(if($row.Type -eq 'Machine'){'Non vérifié'}else{'Sans objet'})
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
        if([string]$item.Row.SessionState -eq 'En attente de vérification' -or [string]$item.Row.Presence -eq 'Vérification en cours'){
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
    [CmdletBinding()]
    param([switch]$Force,[switch]$Manual)
    if($script:SuppressGridSelectionEvents -or -not (Test-DomeniaLiveSearchActive) -or (Test-DomeniaAccessBusyWrite)){return}
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
    if($same -and -not $Force){Request-DomeniaLiveProbe -Row $row;return}
    Clear-DomeniaLiveProbeIntent
    # A mouse/keyboard selection is the only source of an automatic intent.
    # Fresh AD must confirm the target before the CIM probe is allowed to start.
    $script:Live.ProbeSelection=[pscustomobject]@{
        Key=$key;Guid=[string]$row.Guid;Identity=$script:Live.Identity;Epoch=[long]$script:SessionEpoch
        Generation=[int]$script:GlobalSearchGeneration;RequestId=[guid]::NewGuid().ToString('N')
        Requested=$false;Manual=[bool]$Manual;ReadyAfter=[datetime]::UtcNow.AddMilliseconds(180)
    }
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
    $Row.Presence='Vérification en cours'
    if(($script:Live.AutoDetect -or $intent.Manual) -and -not $script:Live.RemoteFaulted -and -not $script:DirectoryCredentialFaulted){$Row.SessionState='En attente de vérification'}
}
function Request-DomeniaLiveSelectedProbe {
    param([string]$Computer)
    if(-not (Test-DomeniaLiveSearchActive)){return $false}
    $row=Get-DomeniaSelectedGridRow
    if($null -eq $row -or $row.Type -ne 'Machine' -or (Normalize-LinkComputer $row.Name) -ne (Normalize-LinkComputer $Computer)){return $false}
    Select-DomeniaLiveResult
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
    Request-DomeniaLinkPersistence
}
function Complete-DomeniaLivePresence {
    param($Result,$State)
    if($null -eq $script:Live -or -not (Test-DomeniaLiveIdentity $State ([long]$script:SessionEpoch) $script:Live.Identity)){return}
    if([string]$Result.Key -cne [string]$State.Key -or [string]$Result.Guid -ine [string]$State.Guid){return}
    $previous=$null;[void]$script:Live.Observations.TryGetValue([string]$State.Key,[ref]$previous)
    if($null -ne $previous -and $previous.Guid -and $State.Guid -and [string]$previous.Guid -ine [string]$State.Guid){return}
    $observation=ConvertTo-DomeniaLiveObservation $Result $previous
    [void](Copy-DomeniaObservationTimes $previous $observation)
    $presenceAt=ConvertTo-DomeniaUtcDate (Get-DomeniaLiveField $Result 'PresenceCheckedUtc')
    if($null -ne $presenceAt){
        [void](Set-DomeniaObservationTime $observation 'Presence' $presenceAt -Succeeded:([string]$Result.Presence -in @('En ligne','Sans réponse au ping')))
    }
    $script:Live.Observations[[string]$State.Key]=$observation
    $script:Live.SaveQueue[[string]$State.Key]=$observation
    if(Test-DomeniaLiveSearchActive){
        $s=$script:Live.Search;$row=$s.Map[[string]$State.Key]
        if($null -ne $row -and [string]$row.Guid -ieq [string]$State.Guid){
            $script:Live.PresenceSeen[[string]$State.Key]=$true
            $view=Get-DomeniaLivePresenceView $observation
            $row.Presence=$view.Display;Set-DomeniaLiveRowValue $row 'PresenceDetail' ($view.Detail+"`r`n"+(Get-DomeniaRecordFreshness $observation 'Presence').Label);$s.RefreshNeeded=$true
            if($null -ne $script:SelectedObject -and [string]$script:SelectedObject.DN -ieq [string]$row.DN){
                Set-DomeniaPresenceText 'TxtCompPresence' $view.Display
                Update-DomeniaObjectPresence -State $view.Display -Target ([string]$State.Computer)
            }
        }
    }
}
function Complete-DomeniaLiveProbe {
    param($Result,$State)
    if($null -eq $script:Live){return}
    Reset-DomeniaLiveIdentity
    if(-not (Test-DomeniaLiveIdentity $State ([long]$script:SessionEpoch) $script:Live.Identity)){return}
    if($script:ActiveWriteTaskId -or $script:WriteState -in @('Unknown','UnknownPending')){
        $script:Live.Deferred.Enqueue([pscustomobject]@{Result=$Result;State=$State});return
    }
    $result=Get-DomeniaEffectiveWorkerResult $Result @('Outcome','Key','Computer')
    if($null -eq $result -or [string]$result.Key -cne [string]$State.Key){throw 'Résultat de session sans cible valide.'}
    if([string]$result.Guid -ine [string]$State.Guid){throw 'Identité machine incohérente dans le résultat.'}
    if(Test-DomeniaLiveSearchActive){
        $current=$script:Live.Search.Map[[string]$State.Key]
        if($null -ne $current -and $current.Guid -and $State.Guid -and $current.Guid -ine $State.Guid){return}
    }
    $previous=$null;[void]$script:Live.Observations.TryGetValue([string]$State.Key,[ref]$previous)
    $presenceAt=ConvertTo-DomeniaUtcDate (Get-DomeniaLiveField $result 'PresenceCheckedUtc')
    $presenceChecked=($null -ne $presenceAt)
    $observation=ConvertTo-DomeniaLiveObservation $result $previous
    [void](Copy-DomeniaObservationTimes $previous $observation)
    if($null -ne $observation){
        if($presenceChecked){
            $presenceSucceeded=([string]$result.Presence -in @('En ligne','Sans réponse au ping'))
            [void](Set-DomeniaObservationTime $observation 'Presence' $presenceAt -Succeeded:$presenceSucceeded)
        }
        # The projection preserves the previous console Outcome for a ping-only result.
        # Only the worker result says whether a console read really happened.
        if([string]$result.Outcome -ne 'PresenceOnly'){
            $consoleSucceeded=([string]$result.Outcome -in @('Observed','NoConsole'))
            [void](Set-DomeniaObservationTime $observation 'Console' ([datetime]::UtcNow) -Succeeded:$consoleSucceeded)
        }
    }
    $script:Live.Observations[[string]$State.Key]=$observation;if($State.Generation -eq $script:GlobalSearchGeneration -or ((Test-DomeniaLiveSearchActive) -and $script:Live.Search.Fresh.ContainsKey([string]$State.Key))){$script:Live.Done[[string]$State.Key]=$true}
    $script:Live.SaveQueue[[string]$State.Key]=$observation
    if($presenceChecked){$script:Live.PresenceSeen[[string]$State.Key]=$true}
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
        }
    }
    if($observation.Outcome -eq 'AuthRejected'){
        $script:Live.RemoteFaulted=$true;$script:Live.Pending.Clear();$script:Live.PendingKeys=@{}
        Write-AppLog 'Compte distant rejeté : vérifications sur sélection suspendues. Corriger le compte dans Comptes avant de réessayer.' 'ERROR'
    }
    if($observation.DirectoryAuthRejected){$script:DirectoryCredentialFaulted=$true;$script:DirectoryCredentialFaultMessage='Identifiants AD refusés lors de la validation du compte console.'}
    if([string]$result.Outcome -ne 'PresenceOnly'){Merge-DomeniaLiveLinkMemory $observation}
    if(Test-DomeniaLiveSearchActive){
        $s=$script:Live.Search
        if($s.Map.ContainsKey([string]$State.Key)){
            $row=$s.Map[[string]$State.Key]
            if(-not $row.Guid -or -not $observation.Guid -or $row.Guid -ieq $observation.Guid){
                Set-DomeniaLiveObservationOnRow $row $observation -Cached:([string]$result.Outcome -eq 'PresenceOnly')
                if($null -ne $script:SelectedObject -and [string]$script:SelectedObject.DN -ieq [string]$row.DN){
                    Set-DomeniaPresenceText 'TxtCompPresence' ([string]$row.Presence)
                    Update-DomeniaObjectPresence -State ([string]$row.Presence) -Target ([string]$State.Computer)
                }
                [void](Set-RowAssociationMetadata -Rows @($row));$s.RefreshNeeded=$true
                if([string]$row.Association){Set-DomeniaLoginColumnVisible $true}
            }
        }
    }
    if([string]$result.Outcome -ne 'PresenceOnly' -and (Get-CurrentSelectedComputerName) -ieq (Normalize-LinkComputer ([string]$State.Computer))){
        $view=Get-DomeniaLiveObservationView $observation
        [void](Set-DomeniaControlText 'LblLinkProbeStatus' -Text ($view.State+' : '+$view.Display+' · '+(Get-DomeniaRecordFreshness $observation 'Console').Label))
        # Do not rebuild the complete associations grid for every background result.
        $link=Get-ExistingLinkForComputer ([string]$State.Computer)
        if($null -ne $link){
            [void](Set-DomeniaControlText 'TxtCompLinkedUser' ([string]$link.UserLogin))
            [void](Set-DomeniaControlText 'TxtCompLinkSource' ([string]$link.Source))
            [void](Set-DomeniaControlText 'TxtCompLinkWhen' ([string]$link.When))
        }
    }
}
function Fail-DomeniaLiveProbe {
    param([string]$Message,$State)
    Reset-DomeniaLiveIdentity
    if($null -eq $script:Live -or -not (Test-DomeniaLiveIdentity $State ([long]$script:SessionEpoch) $script:Live.Identity)){return}
    if($null -ne $State.PSObject.Properties['ProbeUser'] -and -not [bool]$State.ProbeUser){
        $result=[pscustomobject]@{Key=$State.Key;Computer=$State.Computer;Guid=$State.Guid;Outcome='PresenceOnly';Presence='Erreur de ping';PresenceCheckedUtc=[datetime]::UtcNow.ToString('o');PresenceDetail='Le contrôle réseau n''a pas abouti : délai ou erreur du worker. Aucun verdict hors ligne.'}
        Complete-DomeniaLiveProbe $result $State
        return
    }
    $outcome=if($Message -match '(?i)timeout|délai|delai'){'Timeout'}else{'Unavailable'}
    $result=[pscustomobject]@{Key=$State.Key;Computer=$State.Computer;Guid=$State.Guid;Outcome=$outcome;User='';Source='CIM/DCOM';Detail=$Message;Presence='Inconnu'}
    Complete-DomeniaLiveProbe $result $State
}
function Complete-DomeniaLiveCache {
    param($Result,$State)
    Reset-DomeniaLiveIdentity
    # D028: one LiveCache worker at a time, so a write callback always ends the write in flight, whatever its identity.
    if($null -ne $script:Live -and $State.Mode -eq 'Write'){$script:Live.SaveInFlight=0}
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
    if($null -ne $script:Live -and $State.Mode -eq 'Write'){$script:Live.SaveInFlight=0}
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
    # Cache work has its own concurrency gate. Writes are batched, never per UI row.
    if($script:Live.CacheReady -and (Get-DomeniaLiveWorkerCount 'LiveCache') -eq 0 -and (Get-DomeniaLiveWorkerCount 'LocalStore') -eq 0 -and (Get-DomeniaLiveWorkerCount 'LegacyMigration') -eq 0){
        if(($script:Live.SaveQueue.Count -gt 0 -or $null -ne $script:Live.QueryToSave) -and [datetime]::UtcNow -ge $script:Live.SaveAfter){
            $observations=@($script:Live.SaveQueue.Values);$query=$script:Live.QueryToSave
            $state=[pscustomobject]@{Mode='Write';Identity=$script:Live.Identity;Epoch=[long]$script:SessionEpoch;Observations=$observations;Query=$query}
            $payload=[pscustomobject]@{Mode='Write';Path=Get-DomeniaLiveDatabasePath;Scope=$script:Live.Scope;Observations=$observations;Query=$query}
            $id=Start-UiTask -Name 'Mémorisation des observations' -OperationId 'LiveCache' -Code (Get-DomeniaLiveCacheCode) -Payload $payload -CallbackState $state -TimeoutSeconds 15 -SuccessHandler 'Complete-DomeniaLiveCache' -ErrorHandler 'Fail-DomeniaLiveCache' -NonCancellable -TaskClass 'Background'
            $script:Live.SaveQueue=@{};$script:Live.QueryToSave=$null;$script:Live.SaveJob=$id
            # D028: the observations left SaveQueue but are not on disk yet; the save state keeps counting them.
            $script:Live.SaveInFlight=@($observations).Count+$(if($null -ne $query){1}else{0})
            return
        }
        if((Test-DomeniaLiveSearchActive) -and -not $s.CacheRequested){
            $state=[pscustomobject]@{Mode='Read';Identity=$s.Identity;Epoch=$s.Epoch}
            $payload=[pscustomobject]@{Mode='Read';Path=Get-DomeniaLiveDatabasePath;Scope=$script:Live.Scope;QueryKey=$s.QueryKey;Limit=$s.State.Limit;Progress=$s.CacheProgress;ObservationStore=$script:Live.Observations;LoadObservations=(-not $script:Live.ObservationsLoaded)}
            [void](Start-UiTask -Name 'Lecture du cache de recherche' -OperationId 'LiveCache' -Code (Get-DomeniaLiveCacheCode) -Payload $payload -CallbackState $state -TimeoutSeconds 12 -SuccessHandler 'Complete-DomeniaLiveCache' -ErrorHandler 'Fail-DomeniaLiveCache' -TaskClass 'Background')
            $s.CacheRequested=$true
            return
        }
    }
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
    $state=[pscustomobject]@{Key=$item.Key;Computer=$item.Computer;Guid=$item.Guid;Identity=$item.Identity;Epoch=$item.Epoch;Generation=$item.Generation;RequestId=$item.RequestId}
    $payload=[pscustomobject]@{Key=$item.Key;Computer=$item.Computer;Guid=$item.Guid;MethodSeconds=4;ProbeUser=$probeUser;PresenceProgress=$script:Live.PresenceEvents;PresenceState=$state}
    try{
        $id=Start-UiTask -Name ('Présence'+$(if($probeUser){' et utilisateur'}else{''})+' '+$item.Computer) -OperationId $operation -Code (Get-DomeniaLiveProbeCode) -Payload $payload -CallbackState $item -TimeoutSeconds 14 -SuccessHandler 'Complete-DomeniaLiveProbe' -ErrorHandler 'Fail-DomeniaLiveProbe'
        $script:Live.Busy[[string]$item.Key]=$id;$item.Row.Presence='Vérification en cours'
        if($probeUser){$item.Row.SessionState='Vérification en cours'}
    }catch{
        if($probeUser){$item.Row.SessionState='Vérification non démarrée · réessayer'}
        $item.Row.Presence='Non vérifié';Set-DomeniaLiveRowValue $item.Row 'PresenceDetail' 'Contrôle non démarré ; sélectionner à nouveau ou utiliser Revérifier ce poste.'
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
                            $query=[pscustomobject]@{QueryKey=$s.QueryKey;ObservedUtc=[datetime]::UtcNow.ToString('o');Rows=$s.FreshOrder.ToArray()}
                            $script:Live.MemoryQueries[$s.QueryKey]=$query
                            if($script:Live.MemoryQueries.Count -gt 20){$oldest=@($script:Live.MemoryQueries.Values|Sort-Object ObservedUtc|Select-Object -First 1);[void]$script:Live.MemoryQueries.Remove([string]$oldest[0].QueryKey)}
                            $script:Live.QueryToSave=$query;$s.Finalized=$true
                        }
                    }else{$s.Finalized=$true}
                    if($s.Finalized){
                        # Cached rows may have been pruned: the 'Compte' column and the workstation actions follow the final list.
                        Update-DomeniaLoginColumnFromRows $s.Rows
                        # The selection kept for this search is no longer in the list: clear it everywhere.
                        if($null -ne $grid -and @($grid.SelectedItems).Count -eq 0 -and ($null -ne $script:SelectionLoad -or $null -ne $script:SelectedObject)){Clear-DomeniaSelectionEverywhere}
                        $label=if($s.Error){'Liste partielle · '+$s.Fresh.Count+' résultat(s) AD · vérification incomplète'}else{"$($s.Fresh.Count) résultat(s) AD vérifiés"}
                        $limited=($null -ne $s.Final -and [bool]$s.Final.LimitReached)
                        if($limited){$label+=' · limite atteinte, affiner'}
                        # D037: the counter states complete or limited; the former wording stays only without the search rules.
                        if($s.SearchRules -and -not $s.Error){$label=Get-DomeniaResultCounterText -Loaded $s.Fresh.Count -Limit ([int]$s.State.Limit) -Complete (-not $limited) -Visible ([int]$grid.Items.Count)}
                        $script:BranchCountLabel=$label
                        Set-Status $label $(if($s.Error){'WARN'}else{'INFO'})
                        Write-AppLog ("Chargement progressif : premier affichage=$($s.FirstMs) ms ; AD=$($s.Fresh.Count) ; total=$($s.Started.ElapsedMilliseconds) ms ; complet=$(-not [bool]$s.Error).") 'INFO'
                    }
                }
                if(-not $s.Finalized){
                    $script:BranchCountLabel="$($s.Rows.Count) ligne(s) affichée(s) · $($s.Fresh.Count) vérifiée(s) AD · chargement…"
                    if($s.SearchRules){$script:BranchCountLabel=(Get-DomeniaResultCounterText -Loaded $s.Fresh.Count -Limit ([int]$s.State.Limit) -Loading $true)+" · $($s.Rows.Count) ligne(s) affichée(s)"}
                }
                [void](Set-DomeniaControlText 'LblBranchCount' $script:BranchCountLabel)
                $filterBox=Get-DomeniaControl 'TxtSuiteResultFilter'
                $hasFilter=((Get-DomeniaSearchMode) -ne 'Global' -and ($script:CurrentPresenceFilter -ne 'Tous' -or ($null -ne $filterBox -and -not [string]::IsNullOrWhiteSpace([string]$filterBox.Text))))
                if(($hasFilter -or -not $script:Live.Notifying) -and $s.RefreshNeeded -and ([datetime]::UtcNow-$script:Live.LastFilter).TotalMilliseconds -ge 400){Update-DomeniaLiveFilter}
                [void](Set-DomeniaControlText 'LblSuiteResultCount' ("$($grid.Items.Count) / $($s.Rows.Count) lignes visibles"+$(if((Get-DomeniaSearchMode) -eq 'Global'){' · recherche globale sans filtre local'}else{' · filtre local'})))
            }
        }
        Update-DomeniaSearchMoreButton -Search $(if($activeSearch){$script:Live.Search}else{$null})
        try{Start-DomeniaLiveBackgroundWork}catch{$script:Live.NextStart=[datetime]::UtcNow.AddSeconds(2);Write-AppLog ('Travail différé : '+$_.Exception.Message) 'WARN'}
        # D028: the save state is the rule label shared with Fiabilite (Get-DomeniaPersistenceState, Storage.UI).
        $save=(Get-DomeniaPersistenceState).Label
        $probe=if($script:DirectoryCredentialFaulted){'validation AD suspendue · revoir la connexion'}elseif($script:Live.RemoteFaulted){'compte distant refusé · détection suspendue'}elseif(-not $script:Live.AutoDetect){'ping à la sélection · utilisateur désactivé'}elseif($script:Live.PendingKeys.Count -or $script:Live.Busy.Count){"poste sélectionné : $($script:Live.PendingKeys.Count) en attente, $($script:Live.Busy.Count) en cours"}else{'Sélection : un ping + utilisateur si activé · double-clic : fiche · aucun contrôle collectif'}
        $stateText=$probe+' · '+$save
        if($null -ne $script:ParkRun -and $script:ParkRun.Scope -eq 'Results' -and $script:ParkRun.StatusText -and $script:ParkRun.Epoch -eq [long]$script:SessionEpoch -and $script:ParkRun.Generation -eq [long]$script:GlobalSearchGeneration){$stateText=$script:ParkRun.StatusText}
        [void](Set-DomeniaControlText 'LblLiveState' $stateText)
    }finally{$script:Live.InTick=$false}
}
function Test-DomeniaLiveBackgroundAllowed {
    # C1 belongs to the engine lane. An absent or failing policy means allowed (open fallback of the same contract).
    param([string]$Source='Live')
    if($null -eq (Get-Command Test-DomeniaBackgroundWorkAllowed -CommandType Function -ErrorAction SilentlyContinue)){return $true}
    try{return [bool](Test-DomeniaBackgroundWorkAllowed -Source $Source)}catch{return $true}
}
function Update-DomeniaSearchMoreButton {
    # D037: 'Charger la suite' is enabled only for the current, finished and limited list, below 20 000 lines.
    param($Search)
    $button=Get-DomeniaControl 'BtnSearchMore'
    if($null -eq $button){return}
    $decision=$null
    # SearchRules is resolved once per search by Begin-DomeniaLiveSearch: no command lookup on each tick.
    if($null -ne $Search -and [bool]$Search.SearchRules){
        $decision=Get-DomeniaContinuationDecision -Finalized ([bool]$Search.Finalized) -HasError (-not [string]::IsNullOrEmpty([string]$Search.Error)) -LimitReached ($null -ne $Search.Final -and [bool]$Search.Final.LimitReached) -Limit ([int]$Search.State.Limit)
    }
    $enabled=($null -ne $decision -and [bool]$decision.Allowed -and -not (Test-DomeniaAccessBusyWrite))
    $tip=if($null -ne $decision){[string]$decision.Reason}else{'Aucune liste courante à prolonger : lancez une recherche.'}
    if([bool]$button.IsEnabled -ne $enabled){$button.IsEnabled=$enabled}
    if([string]$button.ToolTip -cne $tip){$button.ToolTip=$tip}
}
function Invoke-DomeniaSearchMore {
    # D037: explicit continuation. The same query, mode and view are read again with a doubled bound (20 000 at most).
    # Rows are deduplicated by directory identity and the older generation is discarded; nothing is replayed automatically.
    if(-not (Test-DomeniaLiveSearchActive)){Set-Status 'La liste affichée nʼest plus la recherche courante : relancez la recherche.' 'WARN';Update-DomeniaSearchMoreButton -Search $null;return}
    $s=$script:Live.Search
    $decision=Get-DomeniaContinuationDecision -Finalized ([bool]$s.Finalized) -HasError (-not [string]::IsNullOrEmpty([string]$s.Error)) -LimitReached ($null -ne $s.Final -and [bool]$s.Final.LimitReached) -Limit ([int]$s.State.Limit)
    if(-not [bool]$decision.Allowed){Set-Status ([string]$decision.Reason) 'WARN';Update-DomeniaSearchMoreButton -Search $s;return}
    $mode=if([string]$s.State.SearchMode -eq 'Global'){'Global'}else{'OU'}
    $viewId='';if($null -ne $s.State.PSObject.Properties['ViewId']){$viewId=[string]$s.State.ViewId}
    Invoke-GlobalSearch -SearchMode $mode -PreserveSelection -SilentError -ViewId $viewId -LimitOverride ([int]$decision.NextLimit)
}
