# Every producer keeps its context and raw queue until SQLite COMMIT + SELECT.
# A replaced view stops displaying; it does not discard already harvested values.
$script:DomeniaDirectoryReads=@{}
$script:DomeniaDirectoryStoreTimer=$null
function Initialize-DomeniaDirectoryStore {
    if($null -ne $script:DomeniaDirectoryStoreTimer){return}
    $script:DomeniaDirectoryStoreTimer=New-DomeniaTimer -Owner 'Timer:DirectoryStore' -IntervalMs 80 -RunWhenHidden -Tick {Invoke-DomeniaDirectoryStoreTick}
}
function New-DomeniaDirectoryReadPipe {
    param($Context,$ReadyQueue=$null,$Search=$null,[string]$CommitHandler='', [string]$CompleteHandler='', [string]$ErrorHandler='', $CallbackState=$null)
    Initialize-DomeniaDirectoryStore
    $pipe=[pscustomobject]@{
        Context=$Context;Input=[Collections.Concurrent.ConcurrentQueue[object]]::new();Ready=$ReadyQueue;Search=$Search;Stop=$(if($null -ne $Search){$Search.Stop}else{[Threading.CancellationTokenSource]::new()})
        Collector=[hashtable]::Synchronized(@{Started=$false;Done=$false;Final=$null;Error=''});Sequence=0L;Batch=$null;InFlight=$false
        BuildChanges=[Collections.Generic.List[object]]::new();BuildBytes=0L;BuildStarted=[datetime]::MinValue
        Completed=$false;Final=$null;Error='';DisplayError='';Failure='';Saved=0L;Received=0L;Published=0L;LastAdmission=[datetime]::MinValue;Closed=$false
        CommitHandler=$CommitHandler;CompleteHandler=$CompleteHandler;ErrorHandler=$ErrorHandler;CallbackState=$CallbackState
    }
    $script:DomeniaDirectoryReads[[string]$Context.RequestId]=$pipe
    $script:DomeniaDirectoryStoreTimer.Start()
    return $pipe
}
function Complete-DomeniaDirectoryReadPipe {
    param($Pipe,$Final=$null,[string]$Error='')
    if($null -eq $Pipe -or $Pipe.Closed){return}
    $Pipe.Completed=$true;$Pipe.Final=$Final;$Pipe.Error=$Error
    if($null -ne $script:DomeniaDirectoryStoreTimer){$script:DomeniaDirectoryStoreTimer.Start()}
}
function Invoke-DomeniaDirectoryStoreTick {
    $slice=[Diagnostics.Stopwatch]::StartNew();$active=$false
    foreach($pipe in @($script:DomeniaDirectoryReads.Values)){
        if($pipe.Closed -or $pipe.Failure){continue}
        if([bool]$pipe.Collector.Done -and -not $pipe.Completed){Complete-DomeniaDirectoryReadPipe -Pipe $pipe -Final $pipe.Collector.Final -Error ([string]$pipe.Collector.Error)}
        $active=$true
        if($pipe.InFlight){continue}
        if($slice.ElapsedMilliseconds -ge 8){break}
        if($null -eq $pipe.Batch -and -not $pipe.Input.IsEmpty){
            $changes=$pipe.BuildChanges;$event=$null;$bytes=[long]$pipe.BuildBytes;$failure='';$full=$false
            if(-not $changes.Count){$pipe.BuildStarted=[datetime]::UtcNow}
            while($changes.Count -lt 100 -and $pipe.Input.TryPeek([ref]$event)){
                try{
                    $change=ConvertTo-DomeniaDirectoryStoreChange -Properties $event.Properties -Type ([string]$event.Type) -ObservedAtUtc ([string]$event.ObservedUtc) -Source ([string]$event.Source)
                    $size=[Text.Encoding]::UTF8.GetByteCount(($change|ConvertTo-Json -Depth 16 -Compress))
                    if($size -gt 3500000){throw 'Fiche AD trop volumineuse pour un lot local : donnees non publiees.'}
                    if($changes.Count -and $bytes+$size -gt 3500000){$full=$true;break}
                    $taken=$null;if(-not $pipe.Input.TryDequeue([ref]$taken)){break}
                    $changes.Add($change);$bytes+=$size;$pipe.Received++
                }catch{$failure=$_.Exception.Message;break}
                if($slice.ElapsedMilliseconds -ge 8){break}
                $event=$null
            }
            $pipe.BuildBytes=$bytes
            # Preserve a short Dispatcher slice while grouping later slices into useful SQL transactions.
            if($changes.Count -and ($failure -or $full -or $changes.Count -ge 100 -or $pipe.Input.IsEmpty -or $pipe.Saved -eq 0 -or ([datetime]::UtcNow-$pipe.BuildStarted).TotalMilliseconds -ge 160)){
                $pipe.Sequence++;$pipe.Batch=[pscustomobject]@{Id=[guid]::NewGuid().ToString('D');Sequence=$pipe.Sequence;Changes=$changes.ToArray()}
                $pipe.BuildChanges=[Collections.Generic.List[object]]::new();$pipe.BuildBytes=0L
            }
            if($failure){Fail-DomeniaDirectoryStoreBatch -Message $failure -State $pipe;continue}
        }
        if($null -ne $pipe.Batch -and ([datetime]::UtcNow-$pipe.LastAdmission).TotalMilliseconds -ge 250){
            $pipe.LastAdmission=[datetime]::UtcNow;$pipe.InFlight=$true
            try{
                $admission=Submit-DomeniaStoreBatch -Context $pipe.Context -BatchId $pipe.Batch.Id -Sequence $pipe.Batch.Sequence -Changes $pipe.Batch.Changes -SuccessHandler 'Complete-DomeniaDirectoryStoreBatch' -ErrorHandler 'Fail-DomeniaDirectoryStoreBatch' -CallbackState $pipe
                if(-not $admission.Accepted){
                    $pipe.InFlight=$false
                    if(-not $admission.Backpressure){throw ([string]$admission.Reason)}
                }
            }catch{Fail-DomeniaDirectoryStoreBatch -Message $_.Exception.Message -State $pipe}
        }
        $collectorFinished=(-not [bool]$pipe.Collector.Started -or [bool]$pipe.Collector.Done)
        if($pipe.Completed -and $collectorFinished -and $pipe.Input.IsEmpty -and $null -eq $pipe.Batch -and -not $pipe.InFlight -and -not $pipe.Failure){
            $s=$pipe.Search
            if($null -ne $s){$s.Final=$pipe.Final;$s.Ended=$true;$s.Error=$(if($pipe.Error){$pipe.Error}else{$pipe.DisplayError})}
            $pipe.Closed=$true
            [void]$script:DomeniaDirectoryReads.Remove([string]$pipe.Context.RequestId)
            if($pipe.Error -and $pipe.ErrorHandler){& $pipe.ErrorHandler -Message $pipe.Error -State $pipe.CallbackState}
            elseif($pipe.CompleteHandler){& $pipe.CompleteHandler -Result $pipe.Final -State $pipe.CallbackState}
        }
    }
    # Failed batches remain available for diagnosis/retry; no spinning timer while blocked.
    if(-not $active -or $script:DomeniaDirectoryReads.Count -eq 0){$script:DomeniaDirectoryStoreTimer.Stop()}
}
function Complete-DomeniaDirectoryStoreBatch {
    param($Result,$State)
    $pipe=$State
    if($null -eq $pipe -or $null -eq $pipe.Batch){return}
    if(-not $Result.Saved -or $Result.DataSource -cne 'SQLite' -or [string]$Result.BatchId -cne [string]$pipe.Batch.Id -or [string]$Result.StoreId -cne [string]$pipe.Context.StoreId){Fail-DomeniaDirectoryStoreBatch -Message 'Recu SQLite AD incoherent : aucune donnee publiee.' -State $pipe;return}
    # A confirmed transaction is acknowledged even if a renderer fails afterwards.
    # Retrying the committed batch or retaining InFlight would block the remaining harvest.
    $pipe.Saved+=@($Result.Rows).Count
    $pipe.Batch=$null;$pipe.InFlight=$false;$pipe.Failure=''
    try{
        # Old contexts commit to their original database but never repaint a new selection.
        $publish=($null -ne $pipe.Ready -and $null -ne $pipe.Search -and -not $pipe.Search.Stopped -and (Test-DomeniaLiveSearchActive) -and [object]::ReferenceEquals($script:Live.Search,$pipe.Search))
        foreach($stored in @($Result.Rows)){
            $displayLimit=if($null -ne $pipe.Search){[int](Get-DomeniaMember $pipe.Search.State 'Limit' 0)}else{0}
            if($publish -and ($displayLimit -le 0 -or $pipe.Published -lt $displayLimit)){
                $canonical=ConvertFrom-DomeniaDirectoryCommittedRow $stored
                $pipe.Published++
                $pipe.Ready.Enqueue([pscustomobject]@{Kind='Row';Row=$canonical.Row;ObservedUtc=[string](Get-DomeniaMember $stored 'ObservedAtUtc' '');DataSource='SQLite';Revision=$Result.SnapshotRevision})
            }
        }
        if($pipe.CommitHandler){& $pipe.CommitHandler -Result $Result -State $pipe.CallbackState}
    }catch{
        $pipe.DisplayError='Donnees enregistrees, affichage a recalculer : '+$_.Exception.Message
        Write-AppLog $pipe.DisplayError 'ERROR'
    }
    if($null -ne $script:DomeniaDirectoryStoreTimer){$script:DomeniaDirectoryStoreTimer.Start()}
    try{Invoke-DomeniaTimerSoon -Owner 'Timer:Live'}catch{}
}
function Fail-DomeniaDirectoryStoreBatch {
    param([string]$Message,$State)
    if($null -eq $State){return}
    $State.Failure=$Message;$State.InFlight=$false
    try{$State.Stop.Cancel()}catch{}
    if($null -ne $State.Search){
        try{$State.Search.Stop.Cancel()}catch{}
        $State.Search.Error='Enregistrement local non confirme : '+$Message;$State.Search.Ended=$true
    }
    if($State.ErrorHandler){& $State.ErrorHandler -Message $Message -State $State.CallbackState}
    Write-AppLog ('AD : donnees non publiees, ecriture locale non confirmee. '+$Message) 'ERROR'
}
function Submit-DomeniaDirectoryObjectRead {
    param($Result,$State)
    Complete-DomeniaDirectoryReadPipe -Pipe $State.DirectoryPipe -Final $Result
}
function Complete-DomeniaDirectoryObjectCommit {
    param($Result,$State)
    if(-not (Test-DomeniaObjectCallbackIsCurrent $State)){return}
    $rows=@($Result.Rows)
    if($rows.Count -ne 1){Fail-DomeniaDirectoryObjectCommit -Message 'Fiche absente du readback SQLite.' -State $State;return}
    $stored=ConvertFrom-DomeniaDirectoryCommittedRow $rows[0]
    $effective=[pscustomobject]@{Properties=$stored.Properties;DN=$stored.DN;Type=$stored.Type;Live=$true;DataSource='SQLite';ObservedUtc=[string](Get-DomeniaMember $rows[0] 'ObservedAtUtc' '');StoreRevision=$Result.SnapshotRevision;Demo=([string](Get-DomeniaMember $rows[0] 'Source' '') -ceq 'Demonstration')}
    Assert-DomeniaObjectResultIdentity -Result $effective -State $State
    Complete-DomeniaOpenObjectUi -Result $effective -CacheKey ([string]$State.CacheKey) -Dn $stored.DN -Type $stored.Type -NoNavigate:([bool]$State.NoNavigate) -SuppressRemoteProbes:([bool]$State.SuppressRemoteProbes)
    if($State.SelectionBound -and (Test-DomeniaSelectionLoadCurrent)){Update-DomeniaSelectionReadUi -Phase Ready}
    Clear-DomeniaCurrentObjectRequest ([string]$State.RequestId)
    $script:LastObjectOpenError=''
}
function Fail-DomeniaDirectoryObjectCommit {
    param([string]$Message,$State)
    Fail-DomeniaOpenObjectTaskUi -Message ('Ecriture locale non confirmee : '+$Message) -State $State
}
function Submit-DomeniaDirectoryTreeRead {
    param($Result,$State)
    $State|Add-Member NoteProperty ReadGuids @($Result.Records|ForEach-Object{[string](Get-DomeniaDirectoryPropertyValue $_.Properties 'objectguid')}) -Force
    $pipe=$State.DirectoryPipe
    Complete-DomeniaDirectoryReadPipe -Pipe $pipe -Final $Result
}
function Complete-DomeniaDirectoryTreeRead {
    param($Result,$State)
    $State|Add-Member NoteProperty ReadGuids @($Result.Records|ForEach-Object{[string](Get-DomeniaDirectoryPropertyValue $_.Properties 'objectguid')}) -Force
    Request-DomeniaDirectoryTreeSnapshot -State $State
}
function Test-DomeniaDirectoryTreeCurrent {
    param($State)
    return ($null -ne $State.Node -and [long]$State.StoreContext.SessionEpoch -eq [long]$script:SessionEpoch -and [string]$State.Node.Tag.DirectoryReadId -ceq [string]$State.StoreContext.RequestId)
}
function Request-DomeniaDirectoryTreeSnapshot {
    param($State,[int]$Offset=0)
    if(-not (Test-DomeniaDirectoryTreeCurrent $State)){return}
    if($null -eq $State.PSObject.Properties['StoredTreeRows']){$State|Add-Member NoteProperty StoredTreeRows ([Collections.Generic.List[object]]::new())}
    # A successful empty one-level LDAP enumeration is valid; never substitute older SQL children.
    if(-not @($State.ReadGuids).Count){Queue-DomeniaTreeRowsToNode -Node $State.Node -Rows @() -DisplayName ([string]$State.Name);return}
    $query=[pscustomobject]@{Kind='Directory';Guids=@($State.ReadGuids);ScopeDn=[string]$State.DN;Subtree=$false;Types=@('OU','Conteneur');Offset=$Offset;Limit=250}
    $read=[pscustomobject]@{Tree=$State;Offset=$Offset}
    try{[void](Request-DomeniaStoreRead -Context $State.StoreContext -Query $query -SuccessHandler 'Complete-DomeniaDirectoryTreeSnapshot' -ErrorHandler 'Fail-DomeniaDirectoryTreeSnapshot' -CallbackState $read)}
    catch{Fail-DomeniaDirectoryTreeSnapshot -Message $_.Exception.Message -State $read}
}
function Complete-DomeniaDirectoryTreeSnapshot {
    param($Result,$State)
    $tree=$State.Tree
    if(-not (Test-DomeniaDirectoryTreeCurrent $tree)){return}
    if($Result.Missing -or $Result.Busy -or $Result.DataSource -cne 'SQLite'){Fail-DomeniaDirectoryTreeSnapshot -Message 'Lecture locale de l arbre indisponible.' -State $State;return}
    foreach($row in @($Result.Rows)){$stored=ConvertFrom-DomeniaDirectoryCommittedRow $row;$tree.StoredTreeRows.Add([pscustomobject]@{Name=$stored.Row.Name;DN=$stored.DN;Kind=$stored.Type;Guid=$stored.Guid})}
    $next=[int]$State.Offset+@($Result.Rows).Count
    if($next -lt [long]$Result.Total -and @($Result.Rows).Count){Request-DomeniaDirectoryTreeSnapshot -State $tree -Offset $next;return}
    Queue-DomeniaTreeRowsToNode -Node $tree.Node -Rows @($tree.StoredTreeRows.ToArray()|Sort-Object Name) -DisplayName ([string]$tree.Name)
    Set-Status 'Sous-branches lues depuis la base locale apres enregistrement AD.'
}
function Fail-DomeniaDirectoryTreeSnapshot {
    param([string]$Message,$State)
    Fail-DomeniaDirectoryTreeCommit -Message $Message -State $State.Tree
}
function Fail-DomeniaDirectoryTreeCommit {
    param([string]$Message,$State)
    if(Test-DomeniaDirectoryTreeCurrent $State){Fail-DomeniaTreeChildrenUi -Message $Message -State $State}
}
function Test-DomeniaDirectoryChangesCurrent {
    param($State)
    return ($null -ne $script:Continuity -and (Test-DomeniaLiveSearchActive) -and [object]::ReferenceEquals($script:Live.Search,$State.Search) -and $State.Epoch -eq [long]$script:SessionEpoch -and $State.Identity -ceq $script:Live.Identity -and $State.Mutation -eq $script:Continuity.Mutation)
}
function Complete-DomeniaDirectoryChangesCommit {
    param($Result,$State)
    if(-not (Test-DomeniaDirectoryChangesCurrent $State)){return}
    foreach($row in @($Result.Rows)){
        $original=@($State.ChangeResults.Values|Where-Object{[string]$_.Guid -ieq [string]$row.Guid}|Select-Object -First 1)
        if(-not $original.Count){continue}
        $stored=ConvertFrom-DomeniaDirectoryCommittedRow $row
        $change=[pscustomobject]@{Guid=$stored.Guid;OldDN=[string]$original[0].OldDN;DN=$stored.DN;Stamp=[string]$original[0].Stamp;Status='Changed';Row=$stored.Row}
        $script:Continuity.ChangeEvents.Enqueue([pscustomobject]@{Row=$change;State=$State;At=[string](Get-DomeniaMember $row 'ObservedAtUtc' '')})
    }
}
function Complete-DomeniaDirectoryChangesRead {
    param($Result,$State)
    if(-not (Test-DomeniaDirectoryChangesCurrent $State)){return}
    foreach($row in @($State.ChangeResults.Values)){
        if($row.Status -eq 'Unconfirmed'){$script:Continuity.ChangeEvents.Enqueue([pscustomobject]@{Row=$row;State=$State;At=''})}
    }
    $script:Continuity.ChangeJob=''
    $script:Continuity|Add-Member NoteProperty CheckedAt ([datetime]::Now) -Force
    try{Update-DomeniaListRevalidationUi}catch{}
}
