# Engine runtime adapters (D014 to D020, C1, demo substitution of C2, D016 isolation wrapper).
# Dot-sourced in the core scope by the closed loader. Shared engine state is created lazily by
# Initialize-DomeniaEngineState: nothing runs at import time (D011) and no timer starts here.
# Pure decisions live in Domenia-Engine.Model.ps1; this file only applies them to the live engine.

# ---------------------------------------------------------------- state (D011, D015, D018, D019)
function Initialize-DomeniaEngineState {
    # Idempotent. Called by Start-UiTask, Complete-UiTasks, Dispose-AsyncEngine and the window handlers.
    if($null -eq $script:DirectoryReachability -or [long]$script:DirectoryReachability.Epoch -ne [long]$script:SessionEpoch){
        $script:DirectoryReachability=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Offline=$false;Slow=$false;LastOutageUtc=$null;LastSuccessUtc=$null;LastTimeoutUtc=$null}
    }
    if ($null -eq $script:DomeniaProviderState) { $script:DomeniaProviderState = New-DomeniaProviderState }
    if ($null -eq $script:DomeniaResources) { $script:DomeniaResources = New-DomeniaResourceRegistry }
    if ($null -eq $script:DomeniaTaskSequence) { $script:DomeniaTaskSequence = [long]0 }
    if ($null -eq $script:DomeniaSchedulerEnabled) { $script:DomeniaSchedulerEnabled = [bool](Get-DomeniaFeatureFlag 'Scheduler' $true) }
    # The async timer is created by the pinned Initialize-AsyncEngine: it is registered here, once per instance.
    if ($null -ne $script:AsyncTimer -and -not [object]::ReferenceEquals($script:DomeniaRegisteredAsyncTimer,$script:AsyncTimer)) {
        [void](Register-DomeniaOwnedTimer -Owner 'Timer:Async' -Timer $script:AsyncTimer)
        $script:DomeniaRegisteredAsyncTimer = $script:AsyncTimer
    }
}

function Test-DomeniaSchedulerEnabled {
    # Features.Scheduler is read once per session (Get-DomeniaFeatureFlag resolves a command on each call).
    if ($null -eq $script:DomeniaSchedulerEnabled) { $script:DomeniaSchedulerEnabled = [bool](Get-DomeniaFeatureFlag 'Scheduler' $true) }
    return [bool]$script:DomeniaSchedulerEnabled
}

function Get-DomeniaEngineLimits {
    # Same bounds as the historical Start-UiTask, plus the bounded queue of D015.
    $maxConcurrent = [Math]::Max(1,[Math]::Min(32,[int](Get-CfgValue 'Async' 'MaxThreads' 6)))
    $maxOutstanding = [Math]::Max($maxConcurrent,[Math]::Min(64,[int](Get-CfgValue 'Async' 'MaxOutstandingWorkers' 12)))
    $maxQueued = [Math]::Max(0,[Math]::Min(256,[int](Get-CfgValue 'Async' 'MaxQueued' 32)))
    $reserved = [Math]::Max(0,[Math]::Min(8,[int](Get-CfgValue 'Async' 'ReservedForeground' 2)))
    $maxWait = [Math]::Max(5,[Math]::Min(3600,[int](Get-CfgValue 'Async' 'MaxQueueWaitSeconds' 120)))
    # PF-04: time budget of one engine tick for promotions and for completions (replaces MaxCompletionsPerTick).
    $budget = [Math]::Max(5,[Math]::Min(250,[int](Get-CfgValue 'Async' 'TickBudgetMs' 25)))
    return [pscustomobject]@{MaxConcurrent=$maxConcurrent;MaxOutstanding=$maxOutstanding;MaxQueued=$maxQueued;ReservedForeground=$reserved;MaxQueueWaitSeconds=$maxWait;TickBudgetMs=$budget}
}

function Get-DomeniaEngineLoad {
    # A queued entry holds no thread. A detached read still holds one until its native call really ends.
    # MO-05: ProviderLoad counts the started workers of each provider, as the provider budget of the dispatch does.
    $queued = New-Object 'System.Collections.Generic.List[object]'
    $running = 0; $active = 0; $providers = @{}
    foreach ($job in @($script:AsyncJobs.Values)) {
        if ($null -eq $job) { continue }
        if ([string]$job.State -eq 'Queued') { $queued.Add($job); continue }
        $active++
        if (-not [bool]$job.CancelRequested) { $running++ }
        $provider = [string](Get-DomeniaMember $job 'Provider' '')
        if ($provider) { $providers[$provider] = [int]$providers[$provider] + 1 }
    }
    $detached = 0
    foreach ($job in @($script:DetachedReadJobs)) { if ($null -ne $job) { $detached++ } }
    return [pscustomobject]@{Queued=$queued.ToArray();QueuedCount=$queued.Count;Running=$running;Active=$active;Detached=$detached;Outstanding=($active + $detached);ProviderLoad=$providers}
}

function Get-DomeniaUiTaskAdmission {
    # D015 admission under Features.Scheduler. A refusal throws its reason, exactly like the historical
    # limits, so the callers that defer on an exception keep working. Writes are never queued.
    param([Parameter(Mandatory=$true)][string]$Class)
    $limits = Get-DomeniaEngineLimits
    $load = Get-DomeniaEngineLoad
    $decision = Test-DomeniaTaskAdmission -Class $Class -Running $load.Running -Outstanding $load.Outstanding -MaxConcurrent $limits.MaxConcurrent -MaxOutstanding $limits.MaxOutstanding -Queued $load.QueuedCount -MaxQueued $limits.MaxQueued -ReservedForeground $limits.ReservedForeground
    if ([string]$decision.Decision -eq 'Reject') { throw ([string]$decision.Reason) }
    return $decision
}

function Get-DomeniaNextTaskSequence {
    Initialize-DomeniaEngineState
    $script:DomeniaTaskSequence = [long]$script:DomeniaTaskSequence + 1
    return [long]$script:DomeniaTaskSequence
}

function Get-DomeniaContextCredentialIdentity {
    # Account that a worker context actually carries for its provider. The implicit Windows session is
    # named too, so an explicit account chosen later is distinguishable from the rejected one. An explicit
    # credential is also identified by its object: contexts hand the stored object over by reference, so an
    # automatic retry keeps the identity (still blocked), while the same user name typed again with a
    # corrected password is a new object, hence an explicit change of account (D018).
    param($Context,[string]$Provider)
    $remote = ($Provider -in @('Cim','Wts','Network'))
    $names = @('Credential')
    if ($remote) { $names = @('MachineCredential','RemoteAdminCredential','Credential') }
    foreach ($name in $names) {
        $credential = Get-DomeniaMember $Context $name $null
        if ($null -ne $credential) { try { return (([string]$credential.UserName).Trim() + '#' + [string][Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($credential)) } catch { } }
    }
    if ($remote) {
        $user = [string](Get-DomeniaMember $Context 'RemoteAdminUser' '')
        if ($user) { return $user.Trim() }
    }
    else {
        $bind = [string](Get-DomeniaMember $Context 'BindUser' '')
        if ($bind) { return $bind.Trim() }
    }
    return [string]$script:ProcessIdentity
}

function Get-DomeniaCredentialGuardFailures {
    # Keys, kinds and times only: never the exception, the request or a credential.
    param($Guard)
    if($null -eq $Guard){return @()}
    $out=[Collections.Generic.List[object]]::new()
    [Threading.Monitor]::Enter($Guard.SyncRoot)
    try{
        if($null -ne $Guard.Faults){foreach($key in @($Guard.Faults.Keys)){$f=$Guard.Faults[$key];$out.Add([pscustomobject]@{Key=[string]$key;Kind=[string]$f.Kind;AtUtc=$f.AtUtc})}}
        if($Guard.ContainsKey('AmbiguousOperations')){foreach($op in @($Guard.AmbiguousOperations.Keys)){$f=$Guard.AmbiguousOperations[$op];$out.Add([pscustomobject]@{Key='';Kind=[string]$f.Kind;AtUtc=$f.AtUtc})}}
    }finally{[Threading.Monitor]::Exit($Guard.SyncRoot)}
    return $out.ToArray()
}
function Add-DomeniaCredentialFailureHistory {
    param([object[]]$Failures)
    if($null -eq $script:DomeniaCredentialFailureHistory){$script:DomeniaCredentialFailureHistory=[Collections.Generic.List[object]]::new()}
    foreach($f in @($Failures)){if($null -ne $f){$script:DomeniaCredentialFailureHistory.Add($f)}}
    # Bounded: the last 64 refusals of this run are enough to date a lockout.
    while($script:DomeniaCredentialFailureHistory.Count -gt 64){$script:DomeniaCredentialFailureHistory.RemoveAt(0)}
}
function Get-DomeniaCredentialFailureHistory {
    $rows=[Collections.Generic.List[object]]::new()
    if($null -ne $script:DomeniaCredentialFailureHistory){foreach($h in $script:DomeniaCredentialFailureHistory){$rows.Add($h)}}
    foreach($f in @(Get-DomeniaCredentialGuardFailures $script:DomeniaCredentialGuard)){if($null -ne $f){$rows.Add($f)}}
    return ,$rows.ToArray()
}
function Set-DomeniaCredentialGuardContext {
    # One shared breaker for every use of the same account, independent of target/provider/scheduler.
    # A new login session gets a new map; a successful unrelated read never clears an existing refusal.
    param($Context,[string]$OperationId)
    if($null -eq $script:DomeniaCredentialGuard -or [long]$script:DomeniaCredentialGuard.Epoch -ne [long]$script:SessionEpoch){
        # Point 47: the refusals of the closing session stay available to the lockout diagnosis.
        if($null -ne $script:DomeniaCredentialGuard){Add-DomeniaCredentialFailureHistory @(Get-DomeniaCredentialGuardFailures $script:DomeniaCredentialGuard)}
        $script:DomeniaCredentialGuard=[hashtable]::Synchronized(@{Epoch=[long]$script:SessionEpoch;Faults=@{};Revision=0L;NotifiedRevision=0L})
    }
    $needs=Get-DomeniaOperationCredentialNeeds $OperationId
    $local=([string]$needs.Provider -in @('Storage','Local') -or $OperationId -in @('LiveSelectedPing','ComputerPing','SelectedPresence','PresenceScan','WakeOnLanSend','ParkSharedSync','ConnectorRead'))
    $directory='';$remote='';$remoteAdmin=''
    if(-not $local){
        if([bool]$needs.Directory){
            $user=if($null -ne $Context.Credential){[string]$Context.Credential.UserName}else{[string]$Context.ProcessIdentity}
            $directory=Get-DomeniaCredentialAccountKey $user ([string]$Context.Domain) ([string]$Context.Netbios)
        }
        if([bool]$needs.Remote -or [bool]$needs.Machine -or [bool]$needs.RemoteAdmin){
            $user=if($null -ne $Context.MachineCredential){[string]$Context.MachineCredential.UserName}elseif($null -ne $Context.RemoteAdminCredential){[string]$Context.RemoteAdminCredential.UserName}else{[string]$Context.ProcessIdentity}
            $remote=Get-DomeniaCredentialAccountKey $user ([string]$Context.Domain) ([string]$Context.Netbios) ([string]$Context.CredentialTarget)
            $admin=if($null -ne $Context.RemoteAdminCredential){[string]$Context.RemoteAdminCredential.UserName}else{$user}
            $remoteAdmin=Get-DomeniaCredentialAccountKey $admin ([string]$Context.Domain) ([string]$Context.Netbios) ([string]$Context.CredentialTarget)
        }
    }
    $Context | Add-Member -NotePropertyName CredentialGuard -NotePropertyValue $script:DomeniaCredentialGuard -Force
    $Context | Add-Member -NotePropertyName DirectoryAuthKey -NotePropertyValue $directory -Force
    $Context | Add-Member -NotePropertyName RemoteAuthKey -NotePropertyValue $remote -Force
    $Context | Add-Member -NotePropertyName RemoteAdminAuthKey -NotePropertyValue $remoteAdmin -Force
    $Context | Add-Member -NotePropertyName ActiveRemoteAuthKey -NotePropertyValue $remote -Force
    $Context | Add-Member -NotePropertyName LastAuthChannel -NotePropertyValue '' -Force
    return $Context
}

function Sync-DomeniaCredentialGuardUi {
    # Workers trip the shared map immediately, even if the UI is busy. This pass withdraws pending reads.
    $guard=$script:DomeniaCredentialGuard
    if($null -eq $guard){return}
    $revision=0L;$keys=@();$ambiguous=@()
    [Threading.Monitor]::Enter($guard.SyncRoot)
    try{
        $revision=[long]$guard.Revision
        if($revision -le [long]$guard.NotifiedRevision){return}
        $keys=@($guard.Faults.Keys);if($guard.ContainsKey('AmbiguousOperations')){$ambiguous=@($guard.AmbiguousOperations.Keys)};$guard.NotifiedRevision=$revision
    }finally{[Threading.Monitor]::Exit($guard.SyncRoot)}
    foreach($job in @($script:AsyncJobs.Values)){
        if($null -eq $job -or [bool]$job.IsWrite -or [bool]$job.NonCancellable -or [string]$job.State -ne 'Queued'){continue}
        $context=Get-DomeniaMember $job 'CredentialGuardContext' $null
        $affected=([string]$job.OperationId -in $ambiguous)
        foreach($key in @(Get-WCredentialGuardKeys $context)){if($keys -contains $key){$affected=$true;break}}
        if($affected -and -not [bool]$job.CancelRequested){Request-UiTaskStop -Id ([string]$job.Id) -Silent -Reason 'Protection du compte apres refus d authentification'}
    }
    if($ambiguous.Count){Set-Status 'Origine du refus d''authentification indeterminee : opération suspendue, sans declarer les autres comptes invalides. Reconnectez-vous pour reprendre.' 'WARN'}
    else{Set-Status 'Compte protege : collectes suspendues après un refus d''authentification. Reconnectez-vous ; la base locale reste consultable.' 'WARN'}
    Write-AppLog 'Protection du compte activee : aucun nouvel essai automatique avec les comptes refuses. Les appels deja transmis ne peuvent pas etre rappeles.' 'WARN'
}

function Save-DomeniaSupersededCollection {
    # A closed list of ingestion callbacks, never an ordinary renderer or an AD write callback.
    # The captured store context remains authoritative; each callback must fence its later GUI publication.
    param($Job,$Output,[string]$ErrorMessage='')
    if($null -eq $Job -or [bool]$Job.IsWrite -or [bool]$Job.Demo){return $false}
    $handlers=@{
        'Complete-DomeniaParkSession'='Fail-DomeniaParkSession'
        'Complete-DomeniaLiveProbe'='Fail-DomeniaLiveProbe'
        'Complete-DomeniaCommittedPresence'='Fail-DomeniaCommittedPresence'
        'Complete-DomeniaLastUserCollected'='Fail-DomeniaLastUserCollected'
        'Complete-DomeniaClassicCollected'='Fail-DomeniaClassicCollected'
        'Complete-DomeniaSessionsCollected'='Fail-DomeniaSessionsCollected'
    }
    $handler=[string]$Job.SuccessHandler
    if(-not $handlers.ContainsKey($handler) -or $null -eq $Job.CallbackState){return $false}
    $state=$Job.CallbackState
    $state | Add-Member -NotePropertyName SuppressPublish -NotePropertyValue $true -Force
    if($ErrorMessage){
        if(-not [bool]$Job.TimeoutErrorDelivered){& ([string]$handlers[$handler]) -Message $ErrorMessage -State $state}
    }elseif($null -ne $Output){& $handler -Result $Output -State $state}
    return $true
}

# ---------------------------------------------------------------- dispatch (D015, C2, D016, D018, D019)
function Invoke-DomeniaUiTaskDispatch {
    # Starts the worker of one engine entry. Shared by the direct start of Start-UiTask and by the promotion
    # of a queued entry, so the demonstration substitution and the provider budget apply to both.
    param([Parameter(Mandatory=$true)]$Job)
    Initialize-DomeniaEngineState
    $requested = [string]$Job.OperationId
    $isWrite = [bool]$Job.IsWrite
    if ([bool]$script:DemoMode -and $isWrite) { throw 'DOMENIA_DEMO_WRITE : ecritures desactivees en demonstration. Aucune ecriture tentee.' }
    # The production guards (circuit breaker, refused scopes, alternate accounts) run on the requested operation.
    $context = Set-DomeniaTargetCredentialContext -Context (Get-WorkerContext -OperationId $requested -Payload $Job.Payload) -Payload $Job.Payload
    $context | Add-Member -NotePropertyName CredentialTarget -NotePropertyValue ([string](Get-DomeniaMember $Job.Payload 'Computer' '')) -Force
    $context = Set-DomeniaCredentialGuardContext -Context $context -OperationId $requested
    if($requested -eq 'LiveConsole' -and -not [bool](Get-DomeniaMember $Job.Payload 'ValidateConsoleIdentity' $true)){$context.DirectoryAuthKey=''}
    if($requested -eq 'LiveConsole' -and -not [bool](Get-DomeniaMember $Job.Payload 'ProbeUser' $true) -and -not [bool](Get-DomeniaMember $Job.Payload 'Inventory' $false) -and @((Get-DomeniaMember $Job.Payload 'Probes' @())).Count -eq 0){
        $context.DirectoryAuthKey='';$context.RemoteAuthKey='';$context.RemoteAdminAuthKey='';$context.ActiveRemoteAuthKey=''
    }
    # Ping-only sweeps carry no authenticated work even though the legacy ParkSweep operation accepts accounts.
    if($requested -eq 'ParkSweep' -and [bool](Get-DomeniaMember $Job.Payload 'PingOnly' $false)){
        $context.DirectoryAuthKey='';$context.RemoteAuthKey='';$context.RemoteAdminAuthKey='';$context.ActiveRemoteAuthKey=''
    }
    if(-not [bool]$script:DemoMode){Assert-WCredentialAllowed -Context $context}
    # Keep only the map and account keys on the job, never a second reference to its credentials.
    $Job | Add-Member -NotePropertyName CredentialGuardContext -NotePropertyValue ([pscustomobject]@{CredentialGuard=$context.CredentialGuard;DirectoryAuthKey=$context.DirectoryAuthKey;RemoteAuthKey=$context.RemoteAuthKey;RemoteAdminAuthKey=$context.RemoteAdminAuthKey;ActiveRemoteAuthKey=$context.ActiveRemoteAuthKey;OperationId=$requested}) -Force
    $provider = [string]$Job.Provider
    if (-not $provider) { $provider = Get-DomeniaOperationProvider $requested }
    $Job.CredentialIdentity = Get-DomeniaContextCredentialIdentity -Context $context -Provider $provider
    if ([bool]$Job.SchedulerManaged) {
        # D018: a refused account is never retried on the same resource; repeated outages pause background reads.
        $runningForProvider = @(@($script:AsyncJobs.Values) | Where-Object { $null -ne $_ -and [string]$_.State -ne 'Queued' -and [string]$_.Provider -eq $provider -and -not [object]::ReferenceEquals($_,$Job) }).Count
        $budget = Test-DomeniaProviderAdmission -State $script:DomeniaProviderState -Provider $provider -Target ([string]$Job.ProviderTarget) -Class ([string]$Job.Class) -RunningForProvider $runningForProvider -Identity ([string]$Job.CredentialIdentity)
        if (-not [bool]$budget.Allowed) { throw ([string]$budget.Reason) }
    }
    $executed = $requested
    $code = [string]$Job.Code
    $payload = $Job.Payload
    $demo = $false; $isolated = $false
    if ([bool]$script:DemoMode) {
        if (@(Get-DomeniaDemoPassThroughOperations) -notcontains $requested) {
            $executed = 'DemoDirectory'
            $code = Get-DomeniaDemoDirectoryWorkerCode
            $payload = [pscustomobject]@{Operation=$requested;Request=$Job.Payload;Directory=$script:DemoDirectory}
            $context = ConvertTo-DomeniaDemoWorkerContext -Context $context -RequestedOperationId $requested
            $demo = $true
        }
    }
    else {
        $isolation = Get-DomeniaDispatchIsolation -Job $Job -Context $context
        if ([bool]$isolation.Isolate) {
            # The requested body is verified against its pin before it is handed to the helper process.
            [void](Assert-DomeniaWorkerOperationCode -OperationId $requested -Code $code)
            $payload = New-DomeniaIsolatedReadPayload -OperationId $requested -Code $code -Context $context -Payload $Job.Payload -TimeoutSeconds ([int]$Job.TimeoutSeconds)
            $executed = 'IsolatedRead'
            $code = Get-DomeniaIsolatedReadWorkerCode
            $isolated = $true
        }
    }
    $worker = $null; $ps = $null; $busyApplied = $false
    try {
        $worker = New-DomeniaWorkerRunspace -OperationId $executed -Code $code -IsWrite:$isWrite
        $ps = [System.Management.Automation.PowerShell]::Create()
        if ($null -ne $worker.PSObject.Properties['Pool']) { $ps.RunspacePool = $worker.Pool } else { $ps.Runspace = $worker.Runspace }
        [void]$ps.AddCommand([string]$worker.CommandName)
        [void]$ps.AddArgument($context)
        [void]$ps.AddArgument($payload)
        if (-not [bool]$Job.BusyApplied) {
            Set-ControlsBusy -Names $Job.DisableControls -Busy $true
            $busyApplied = $true
            $Job.BusyApplied = $true
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Job.StatusText)) { Set-Status ([string]$Job.StatusText) }
        if ($requested -eq 'GlobalSearch' -and -not $isWrite -and -not $demo -and -not $isolated) {
            $searchProgress = Get-DomeniaMember $Job.Payload 'SearchReadProgress' $null
            if ($searchProgress -is [Collections.IDictionary]) {
                # Initialize only when dispatched: time spent queued does not consume either budget.
                [Threading.Monitor]::Enter($searchProgress.SyncRoot)
                try {
                    $searchProgress.StartedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
                    $searchProgress.LastRowTimestamp = 0L
                    $searchProgress.RowsRead = 0L
                } finally { [Threading.Monitor]::Exit($searchProgress.SyncRoot) }
                Add-Member -InputObject $Job -NotePropertyName SearchReadProgress -NotePropertyValue $searchProgress -Force
            }
        }
        $handle = $ps.BeginInvoke()
    }
    catch {
        # Only the reference taken here is released: a control held by another task stays disabled.
        if ($busyApplied) { try { Set-ControlsBusy -Names $Job.DisableControls -Busy $false } catch { }; $Job.BusyApplied = $false }
        try { if ($null -ne $ps) { $ps.Dispose() } } catch { }
        try { if ($null -ne $worker -and $null -ne $worker.Runspace) { $worker.Runspace.Dispose() } } catch { }
        throw
    }
    $Job.PowerShell = $ps
    $Job.Runspace = $worker.Runspace
    $Job.Handle = $handle
    $Job.CodeHash = [string]$worker.CodeHash
    $Job.ExecutedOperationId = $executed
    $Job.Demo = $demo
    $Job.Isolated = $isolated
    $Job.State = 'Running'
    $Job.Started = Get-Date
    # Point 122: the series key reads the request, so it is fixed here before the request is released;
    # Add-DomeniaTaskRuntimeMetric runs at completion, when the payload is gone.
    $metricKey = $requested
    try { $metricKey = [string](Get-DomeniaRuntimeMetricOperationKey -OperationId $requested -Payload $Job.Payload) } catch { $metricKey = $requested }
    $Job | Add-Member -NotePropertyName MetricKey -NotePropertyValue $metricKey -Force
    # The body and the request are no longer needed once the worker holds them.
    $Job.Code = $null
    $Job.Payload = $null
    Register-DomeniaJobResources -Job $Job
    return $Job
}

function Get-DomeniaDispatchIsolation {
    # D016 decision for one entry. Disabled unless Features.IsolatedReads is true.
    param($Job,$Context)
    $enabled = [bool](Get-DomeniaFeatureFlag 'IsolatedReads' $false)
    if (-not $enabled) { return [pscustomobject]@{Isolate=$false;Reason='Lectures isolees desactivees (Features.IsolatedReads).'} }
    $hasCredential = $false
    foreach ($name in @('Credential','MachineCredential','RemoteAdminCredential')) { if ($null -ne (Get-DomeniaMember $Context $name $null)) { $hasCredential = $true } }
    $digest = Get-DomeniaPayloadDigest $Job.Payload
    return (Get-DomeniaIsolationDecision -OperationId ([string]$Job.OperationId) -Enabled $enabled -IsWrite ([bool]$Job.IsWrite) -HasCredential $hasCredential -PayloadDigest $digest -DemoMode ([bool]$script:DemoMode))
}

function New-DomeniaIsolatedReadPayload {
    # D016. Builds the request of the helper process: the verified body, the worker helpers and plain data.
    # Nothing secret crosses the boundary: the decision refused any credential object beforehand, and the
    # process command line never carries the request (it travels on the private pipe of the runspace).
    param([string]$OperationId,[string]$Code,$Context,$Payload,[int]$TimeoutSeconds=60)
    $contract = 'function Get-DomeniaStructuredError {' + "`r`n" + (Get-Command Get-DomeniaStructuredError -CommandType Function).Definition + "`r`n}"
    $childScript = 'param($ContextJson,$RequestJson)' + "`r`n" +
        '$ErrorActionPreference = "Stop"' + "`r`n" + '$ProgressPreference = "SilentlyContinue"' + "`r`n" +
        '$Context = ConvertFrom-Json $ContextJson' + "`r`n" + '$Payload = ConvertFrom-Json $RequestJson' + "`r`n" +
        $contract + "`r`n" + [string]$script:WorkerCommon + "`r`n" +
        '$DomeniaIsolatedResult = @(& {' + "`r`n" + 'try {' + "`r`n" + $Code + "`r`n" + '} catch {' + "`r`n" +
        '    $diagnostic=Get-DomeniaStructuredError $_ -Phase ([string]$Context.OperationId) -Provider ''Windows'' -Target ([string]$Context.Server)' + "`r`n" +
        '    throw [InvalidOperationException]::new(''[DOMENIA:''+$diagnostic.Kind+'';''+$diagnostic.NativeCode+'';''+$diagnostic.Code+''] ''+$_.Exception.Message,$_.Exception)' + "`r`n" +
        '}' + "`r`n" + '})' + "`r`n" +
        'ConvertTo-Json -InputObject $DomeniaIsolatedResult -Depth 8 -Compress'
    return [pscustomobject]@{
        Operation=$OperationId
        Script=$childScript
        ContextJson=($Context | ConvertTo-Json -Depth 6 -Compress)
        RequestJson=(ConvertTo-Json -InputObject $Payload -Depth 8 -Compress)
        TimeoutSeconds=[Math]::Max(5,[Math]::Min(300,$TimeoutSeconds))
    }
}

function Register-DomeniaJobResources {
    # D019: the PowerShell object and the private runspace of a job have the job as owner until their real end.
    param($Job)
    if ($null -eq $Job -or $null -eq $script:DomeniaResources) { return }
    $owner = [string]$Job.Id
    if ($null -ne $Job.PowerShell) {
        [void](Register-DomeniaResource -Registry $script:DomeniaResources -Owner $owner -Kind 'PowerShell' -Resource $Job.PowerShell -Release {param($r) try { $r.Dispose() } catch { }})
    }
    if ($null -ne $Job.Runspace) {
        [void](Register-DomeniaResource -Registry $script:DomeniaResources -Owner $owner -Kind 'Runspace' -Resource $Job.Runspace -Release {param($r) try { $r.Dispose() } catch { }})
    }
}

function Sync-DomeniaJobResources {
    # Releases the per-job resources whose job is neither in the engine nor detached any more.
    if ($null -eq $script:DomeniaResources) { return 0 }
    $alive = @{}
    foreach ($key in @($script:AsyncJobs.Keys)) { $alive[[string]$key] = $true }
    foreach ($job in @($script:DetachedReadJobs)) { if ($null -ne $job) { $alive[[string]$job.Id] = $true } }
    $released = 0
    foreach ($item in @($script:DomeniaResources.Items.ToArray())) {
        if ($item.Kind -notin @('PowerShell','Runspace')) { continue }
        if ($alive.ContainsKey([string]$item.Owner)) { continue }
        $result = Release-DomeniaResources -Registry $script:DomeniaResources -Id ([int]$item.Id)
        $released += [int]$result.Released
    }
    return $released
}

function Register-DomeniaOwnedTimer {
    # D019: one owner, one timer. A re-created timer replaces (and stops) the previous one of the same owner.
    param([Parameter(Mandatory=$true)][string]$Owner,$Timer)
    if ($null -eq $script:DomeniaResources) { $script:DomeniaResources = New-DomeniaResourceRegistry }
    $previous = @($script:DomeniaResources.Items.ToArray() | Where-Object { $_.Owner -eq $Owner })
    foreach ($item in $previous) {
        if ([object]::ReferenceEquals($item.Resource,$Timer)) { return [int]$item.Id }
    }
    [void](Release-DomeniaResources -Registry $script:DomeniaResources -Owner $Owner)
    if ($null -eq $Timer) { return 0 }
    return (Register-DomeniaResource -Registry $script:DomeniaResources -Owner $Owner -Kind 'Timer' -Resource $Timer -Release {param($t) try { $t.Stop() } catch { }})
}

function Register-DomeniaWorkerPool {
    # D019: the shared read pools are owned by the engine and closed at shutdown.
    param([string]$OperationId,$Pool)
    if ($null -eq $Pool) { return 0 }
    if ($null -eq $script:DomeniaResources) { $script:DomeniaResources = New-DomeniaResourceRegistry }
    return (Register-DomeniaResource -Registry $script:DomeniaResources -Owner ('Pool:' + $OperationId) -Kind 'RunspacePool' -Resource $Pool -Release {param($p) try { [void]$p.BeginClose($null,$null) } catch { }})
}

# ---------------------------------------------------------------- FI-05 / PF-06: protected timers and the engine heartbeat
function New-DomeniaTimer {
    # FI-05: the only factory of Dispatcher timers. Each timer has an owner (D019 registry), runs its tick inside a
    # try/catch, writes one journal line per error, stops after MaxFailures consecutive errors and, with -SessionBound,
    # as soon as the session epoch changes. PF-06: by default it subscribes to the engine heartbeat (one Dispatcher
    # timer, one interval per subscriber, nothing at all when no subscriber is enabled); -Standalone keeps its own
    # protected DispatcherTimer for what runs before the engine (startup window, login) or needs another priority.
    # The returned object behaves like a DispatcherTimer for its callers: Start(), Stop(), IsEnabled, Interval, Tag.
    # Start() on an enabled timer changes nothing; Stop() then Start() restarts the countdown, as for a DispatcherTimer.
    # -IdleIntervalMs with -Busy: when the Busy script block answers $false after a tick, the next one waits
    # IdleIntervalMs; any heartbeat wake-up that finds it busy again brings it back to IntervalMs.
    param(
        [Parameter(Mandatory=$true)][string]$Owner,
        [Parameter(Mandatory=$true)][int]$IntervalMs,
        [scriptblock]$Tick=$null,
        [switch]$Standalone,
        [ValidateSet('Background','Normal','Input','Loaded','Render','ContextIdle','ApplicationIdle')][string]$Priority='Background',
        [int]$IdleIntervalMs=0,
        [scriptblock]$Busy=$null,
        [switch]$SessionBound,
        [switch]$RunWhenHidden,
        [switch]$Transient,
        [int]$MaxFailures=3,
        [switch]$Start,
        $Tag=$null
    )
    $timer = [pscustomobject]@{
        Owner=$Owner;IntervalMs=[Math]::Max(1,$IntervalMs);IdleIntervalMs=[Math]::Max(0,$IdleIntervalMs);Tick=$Tick;Busy=$Busy
        Standalone=[bool]$Standalone;SessionBound=[bool]$SessionBound;RunWhenHidden=[bool]$RunWhenHidden;Transient=[bool]$Transient
        MaxFailures=[Math]::Max(1,$MaxFailures);Enabled=$false;DueMs=[double]0;Epoch=[long]$script:SessionEpoch;Failures=0;FaultStopped=$false
        Runs=[long]0;Errors=[long]0;LastError='';LateMs=[double]0;InTick=$false;Native=$null;Tag=$Tag
    }
    $timer.PSObject.TypeNames.Insert(0,'Domenia.Timer')
    Add-Member -InputObject $timer -MemberType ScriptMethod -Name Start -Value { Start-DomeniaTimer -Timer $this }
    Add-Member -InputObject $timer -MemberType ScriptMethod -Name Stop -Value { Stop-DomeniaTimer -Timer $this }
    Add-Member -InputObject $timer -MemberType ScriptProperty -Name IsEnabled -Value { [bool]$this.Enabled }
    Add-Member -InputObject $timer -MemberType ScriptProperty -Name Interval -Value { [TimeSpan]::FromMilliseconds([double]$this.IntervalMs) } -SecondValue { param($value) Set-DomeniaTimerInterval -Timer $this -Interval ([TimeSpan]$value) }
    if ($Standalone) {
        $native = New-Object System.Windows.Threading.DispatcherTimer ([System.Windows.Threading.DispatcherPriority]$Priority)
        $native.Interval = [TimeSpan]::FromMilliseconds([double]$timer.IntervalMs)
        $native.Tag = $timer
        $native.Add_Tick({ param($sender,$eventArgs) $script:DomeniaStandaloneTicks = [long]$script:DomeniaStandaloneTicks + 1; Invoke-DomeniaTimerTick -Timer $sender.Tag })
        $timer.Native = $native
    }
    [void](Register-DomeniaOwnedTimer -Owner $Owner -Timer $timer)
    if ($Start) { $timer.Start() }
    return $timer
}

function Get-DomeniaPulse {
    # PF-06: the heartbeat owned by the engine, created on the first subscriber. Its interval is always the delay
    # until the next due subscriber: no subscriber enabled, no wake-up at all.
    if ($null -ne $script:DomeniaPulse) { return $script:DomeniaPulse }
    $native = New-Object System.Windows.Threading.DispatcherTimer ([System.Windows.Threading.DispatcherPriority]::Background)
    $native.Interval = [TimeSpan]::FromMilliseconds(250)
    $native.Add_Tick({ param($sender,$eventArgs) Invoke-DomeniaPulse })
    $script:DomeniaPulse = [pscustomobject]@{Timer=$native;Active=([ordered]@{});Clock=[Diagnostics.Stopwatch]::StartNew();Wakeups=[long]0;Runs=[long]0}
    if ($null -eq $script:DomeniaResources) { $script:DomeniaResources = New-DomeniaResourceRegistry }
    [void](Register-DomeniaResource -Registry $script:DomeniaResources -Owner 'Timer:Pulse' -Kind 'Timer' -Resource $native -Release {param($t) try { $t.Stop() } catch { }})
    return $script:DomeniaPulse
}

function Get-DomeniaPulseNow {
    return [double](Get-DomeniaPulse).Clock.Elapsed.TotalMilliseconds
}

function Start-DomeniaTimer {
    param($Timer)
    if ($null -eq $Timer -or [bool]$Timer.Enabled) { return }
    $Timer.Enabled = $true
    $Timer.FaultStopped = $false
    if ([bool]$Timer.SessionBound) { $Timer.Epoch = [long]$script:SessionEpoch }
    # A one-shot timer left the registry when it stopped: it is registered again when it restarts.
    if ([bool]$Timer.Transient) { try { [void](Register-DomeniaOwnedTimer -Owner ([string]$Timer.Owner) -Timer $Timer) } catch { } }
    if ([bool]$Timer.Standalone) { $Timer.Native.Start(); return }
    $pulse = Get-DomeniaPulse
    $Timer.DueMs = [double]$pulse.Clock.Elapsed.TotalMilliseconds + [double]$Timer.IntervalMs
    # D019: one owner, one live timer: a newer timer of the same owner takes the slot.
    if ($pulse.Active.Contains([string]$Timer.Owner)) {
        $previous = $pulse.Active[[string]$Timer.Owner]
        if (-not [object]::ReferenceEquals($previous,$Timer)) { $previous.Enabled = $false }
        $pulse.Active.Remove([string]$Timer.Owner)
    }
    $pulse.Active[[string]$Timer.Owner] = $Timer
    Update-DomeniaPulseSchedule
}

function Stop-DomeniaTimer {
    param($Timer)
    if ($null -eq $Timer) { return }
    $Timer.Enabled = $false
    if ([bool]$Timer.Standalone) { try { $Timer.Native.Stop() } catch { } }
    elseif ($null -ne $script:DomeniaPulse -and $script:DomeniaPulse.Active.Contains([string]$Timer.Owner)) {
        if ([object]::ReferenceEquals($script:DomeniaPulse.Active[[string]$Timer.Owner],$Timer)) {
            $script:DomeniaPulse.Active.Remove([string]$Timer.Owner)
            Update-DomeniaPulseSchedule
        }
    }
    if ([bool]$Timer.Transient -and $null -ne $script:DomeniaResources) {
        # A one-shot timer (banner) leaves the registry once stopped: a long session does not accumulate them.
        foreach ($item in @($script:DomeniaResources.Items.ToArray())) {
            if ([object]::ReferenceEquals($item.Resource,$Timer)) { [void]$script:DomeniaResources.Items.Remove($item) }
        }
    }
}

function Set-DomeniaTimerInterval {
    # Same rule as DispatcherTimer.Interval: a new interval restarts the countdown of an enabled timer.
    param($Timer,[TimeSpan]$Interval)
    if ($null -eq $Timer) { return }
    $Timer.IntervalMs = [Math]::Max(1,[int][Math]::Round($Interval.TotalMilliseconds))
    if ([bool]$Timer.Standalone) { $Timer.Native.Interval = [TimeSpan]::FromMilliseconds([double]$Timer.IntervalMs); return }
    if ([bool]$Timer.Enabled -and $null -ne $script:DomeniaPulse) {
        $Timer.DueMs = [double]$script:DomeniaPulse.Clock.Elapsed.TotalMilliseconds + [double]$Timer.IntervalMs
        Update-DomeniaPulseSchedule
    }
}

function Invoke-DomeniaTimerSoon {
    # PF-06: work just arrived for a subscriber running at its idle pace: its next tick comes at its normal interval.
    param([Parameter(Mandatory=$true)][string]$Owner)
    $pulse = $script:DomeniaPulse
    if ($null -eq $pulse -or -not $pulse.Active.Contains($Owner)) { return }
    $timer = $pulse.Active[$Owner]
    $soon = [double]$pulse.Clock.Elapsed.TotalMilliseconds + [double]$timer.IntervalMs
    if ([double]$timer.DueMs -gt $soon) { $timer.DueMs = $soon; Update-DomeniaPulseSchedule }
}

function Invoke-DomeniaTimerTick {
    # FI-05: one protected tick. One journal line per error; MaxFailures consecutive errors stop the timer with one
    # more line; a tick of a stopped timer or of a former session does nothing.
    param($Timer)
    if ($null -eq $Timer -or -not [bool]$Timer.Enabled -or [bool]$Timer.InTick) { return }
    if ([bool]$Timer.SessionBound -and [long]$Timer.Epoch -ne [long]$script:SessionEpoch) { Stop-DomeniaTimer -Timer $Timer; return }
    if ($null -eq $Timer.Tick) { return }
    $Timer.InTick = $true
    try {
        $Timer.Runs = [long]$Timer.Runs + 1
        & $Timer.Tick $Timer ([EventArgs]::Empty)
        $Timer.Failures = 0
    }
    catch {
        $Timer.Failures = [int]$Timer.Failures + 1
        $Timer.Errors = [long]$Timer.Errors + 1
        $Timer.LastError = [string]$_.Exception.Message
        try { Write-AppLog ('Minuteur ' + [string]$Timer.Owner + ' : ' + [string]$_.Exception.Message) 'WARN' } catch { }
        if ([int]$Timer.Failures -ge [int]$Timer.MaxFailures) {
            $Timer.FaultStopped = $true
            Stop-DomeniaTimer -Timer $Timer
            try { Write-AppLog ('Minuteur ' + [string]$Timer.Owner + ' arrêté après ' + [int]$Timer.Failures + ' erreurs consécutives ; aucun nouvel essai automatique.') 'ERROR' } catch { }
        }
    }
    finally { $Timer.InTick = $false }
}

function Invoke-DomeniaPulse {
    # PF-06: one wake-up of the heartbeat runs every subscriber that is due, then sleeps until the next one.
    # The heartbeat is re-armed before the first tick runs: a tick that opens a nested Dispatcher frame (a sheet, a
    # dialog) does not freeze the other subscribers, and a subscriber never runs twice at once (InTick).
    $pulse = $script:DomeniaPulse
    if ($null -eq $pulse) { return }
    $now = [double]$pulse.Clock.Elapsed.TotalMilliseconds
    $pulse.Wakeups = [long]$pulse.Wakeups + 1
    $hidden = [bool]$script:DomeniaWindowSuspended
    $due = New-Object 'System.Collections.Generic.List[object]'
    foreach ($timer in @($pulse.Active.Values)) {
        if ($null -eq $timer -or [bool]$timer.InTick) { continue }
        if (-not (Test-DomeniaPulseDue -Subscriber $timer -NowMs $now -Hidden $hidden)) {
            # A subscriber at its rest pace that has work again comes back to its normal pace.
            if ([bool]$timer.Enabled -and [int]$timer.IdleIntervalMs -gt 0 -and $null -ne $timer.Busy -and ([double]$timer.DueMs - $now) -gt [double]$timer.IntervalMs) {
                $busy = $true
                try { $busy = [bool](& $timer.Busy) } catch { $busy = $true }
                if ($busy) { $timer.DueMs = $now + [double]$timer.IntervalMs }
            }
            continue
        }
        $timer.LateMs = [Math]::Max([double]0,$now - [double]$timer.DueMs)
        $timer.DueMs = $now + [double]$timer.IntervalMs
        $due.Add([pscustomobject]@{Timer=$timer;Planned=[double]$timer.DueMs})
    }
    Update-DomeniaPulseSchedule
    foreach ($entry in $due) {
        $timer = $entry.Timer
        # A nested wake-up (frame opened by an earlier tick) may already have run or restarted this subscriber.
        if (-not [bool]$timer.Enabled -or [double]$timer.DueMs -ne [double]$entry.Planned) { continue }
        $planned = [double]$timer.DueMs
        $pulse.Runs = [long]$pulse.Runs + 1
        Invoke-DomeniaTimerTick -Timer $timer
        if ([bool]$timer.Enabled -and [int]$timer.IdleIntervalMs -gt 0 -and [double]$timer.DueMs -eq $planned) {
            # Rest pace (no Busy block, or Busy answers $false): the next tick is aligned on a grid of IdleIntervalMs, so
            # that every subscriber at rest shares the same wake-up.
            $busy = $false
            if ($null -ne $timer.Busy) { try { $busy = [bool](& $timer.Busy) } catch { $busy = $true } }
            if (-not $busy) {
                $idle = [double]$timer.IdleIntervalMs
                $timer.DueMs = [Math]::Ceiling(($now + $idle / 2) / $idle) * $idle
            }
        }
    }
    Update-DomeniaPulseSchedule
}

function Update-DomeniaPulseSchedule {
    # The heartbeat sleeps until the next due subscriber; it stops when none is enabled (or all are suspended).
    $pulse = $script:DomeniaPulse
    if ($null -eq $pulse) { return }
    $now = [double]$pulse.Clock.Elapsed.TotalMilliseconds
    $delay = Get-DomeniaPulseDelay -Subscribers @($pulse.Active.Values) -NowMs $now -Hidden ([bool]$script:DomeniaWindowSuspended) -MinimumMs 15
    try {
        $pulse.Timer.Stop()
        if ($delay -lt 0) { return }
        $pulse.Timer.Interval = [TimeSpan]::FromMilliseconds([double]$delay)
        $pulse.Timer.Start()
    } catch { }
}

function Get-DomeniaPulseState {
    # Wake-ups of the heartbeat and of the standalone timers since the start of the process (TE-05, Santé).
    $wakeups = [long]0; $runs = [long]0; $active = @()
    if ($null -ne $script:DomeniaPulse) { $wakeups = [long]$script:DomeniaPulse.Wakeups; $runs = [long]$script:DomeniaPulse.Runs; $active = @($script:DomeniaPulse.Active.Keys | ForEach-Object { [string]$_ }) }
    return [pscustomobject]@{Wakeups=$wakeups;Runs=$runs;Standalone=[long]$script:DomeniaStandaloneTicks;Active=$active}
}

function Resume-DomeniaAsyncPoll {
    # PF-06: the engine poll runs only while the engine holds a task, a queued entry or a detached read.
    # A poll stopped by three consecutive faults (FI-02) is never restarted here.
    if ($null -eq $script:AsyncTimer -or [bool]$script:AsyncEngineFaultStopped -or [bool]$script:AsyncEngineClosing) { return }
    try { if (-not [bool]$script:AsyncTimer.IsEnabled) { $script:AsyncTimer.Start() } } catch { }
}

# ---------------------------------------------------------------- C7 runtime metrics (PF-05, TE-05, UX-32)
function Add-DomeniaRuntimeMetric {
    # Bounded in-memory series (512 last values each): worker durations, RunspaceOpen on the Dispatcher, queue wait,
    # heartbeat lateness. Nothing is written to disk and nothing leaves the process.
    param([string]$Provenance='',[string]$OperationId='',[double]$DurationMs=0)
    if ($null -eq $script:DomeniaRuntimeMetrics) { $script:DomeniaRuntimeMetrics = @{} }
    $key = [string]$Provenance + '|' + [string]$OperationId
    $series = $script:DomeniaRuntimeMetrics[$key]
    if ($null -eq $series) { $series = New-Object 'System.Collections.Generic.Queue[double]'; $script:DomeniaRuntimeMetrics[$key] = $series }
    $series.Enqueue([double]$DurationMs)
    while ($series.Count -gt 512) { [void]$series.Dequeue() }
    # Point 122: additions per series, so the response-time summaries are recomputed only when one of their series moved.
    if ($null -eq $script:DomeniaRuntimeMetricAdds) { $script:DomeniaRuntimeMetricAdds = @{} }
    $script:DomeniaRuntimeMetricAdds[$key] = [long]$script:DomeniaRuntimeMetricAdds[$key] + 1
}

function Get-DomeniaRuntimeMetricSummary {
    # p50, p95 and maximum of the series whose key starts with Provenance|Prefix.
    param([string]$Provenance='',[string]$Prefix='')
    $values = New-Object 'System.Collections.Generic.List[double]'
    if ($null -ne $script:DomeniaRuntimeMetrics) {
        $start = [string]$Provenance + '|' + [string]$Prefix
        foreach ($key in @($script:DomeniaRuntimeMetrics.Keys)) {
            if (-not ([string]$key).StartsWith($start,[StringComparison]::Ordinal)) { continue }
            foreach ($value in $script:DomeniaRuntimeMetrics[$key]) { $values.Add([double]$value) }
        }
    }
    if ($values.Count -eq 0) { return [pscustomobject]@{Count=0;P50=[double]0;P95=[double]0;Max=[double]0} }
    $sorted = $values.ToArray(); [Array]::Sort($sorted)
    $p50 = $sorted[[int][Math]::Min($sorted.Count - 1,[Math]::Max(0,[Math]::Ceiling(0.50 * $sorted.Count) - 1))]
    $p95 = $sorted[[int][Math]::Min($sorted.Count - 1,[Math]::Max(0,[Math]::Ceiling(0.95 * $sorted.Count) - 1))]
    return [pscustomobject]@{Count=$sorted.Count;P50=[Math]::Round($p50,2);P95=[Math]::Round($p95,2);Max=[Math]::Round($sorted[$sorted.Count - 1],2)}
}

function Get-DomeniaResponseTimeSummaries {
    # Point 122: median, 95th percentile and maximum per category of Get-DomeniaResponseTimeCategories (local search,
    # result processing on the interface thread, local base, directory, workstations, writes and remote actions), read
    # from the bounded series of this session. Local measures only: nothing is written to disk and nothing leaves the process.
    # The operations panel asks every second on the Dispatcher: a category is recomputed only when the series dictionary
    # was replaced or when one of its series received a value since the last call (additions counted by
    # Add-DomeniaRuntimeMetric); the heartbeat series belongs to no category and never forces a recomputation.
    $metrics = $script:DomeniaRuntimeMetrics
    $adds = $script:DomeniaRuntimeMetricAdds
    $cache = $script:DomeniaResponseTimeCache
    if (($null -eq $cache) -or (-not [object]::ReferenceEquals($cache.Metrics,$metrics))) {
        $cache = [pscustomobject]@{ Metrics=$metrics; Rows=@{} }
        $script:DomeniaResponseTimeCache = $cache
    }
    $keys = @()
    if ($metrics -is [Collections.IDictionary]) { $keys = @($metrics.Keys) }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($category in @(Get-DomeniaResponseTimeCategories)) {
        $id = [string]$category.Id
        # Signature: matching series, their additions and their sizes. Additions only grow while the dictionary is the
        # same object, so an unchanged signature means unchanged samples.
        $matched = 0; $added = [long]0; $held = [long]0
        foreach ($key in $keys) {
            $text = [string]$key
            $kept = $false
            foreach ($prefix in @($category.Include)) { if ($text.StartsWith([string]$prefix,[StringComparison]::Ordinal)) { $kept = $true; break } }
            if (-not $kept) { continue }
            foreach ($prefix in @($category.Exclude)) { if ($text.StartsWith([string]$prefix,[StringComparison]::Ordinal)) { $kept = $false; break } }
            if (-not $kept) { continue }
            $matched++
            if ($adds -is [Collections.IDictionary]) { $added += [long]$adds[$key] }
            $serie = $metrics[$key]
            if ($null -ne $serie) { try { $held += [long]$serie.Count } catch { } }
        }
        $signature = [string]$matched + '/' + [string]$added + '/' + [string]$held
        $row = $cache.Rows[$id]
        if (($null -eq $row) -or ([string]$row.Signature -cne $signature) -or ([string]$row.Label -cne [string]$category.Label)) {
            $samples = Select-DomeniaResponseTimeSamples -Series $metrics -Category $category
            $summary = Get-DomeniaLatencySummary -Samples $samples
            $row = [pscustomobject]@{ Id=$id; Label=[string]$category.Label; Summary=$summary; Text=(Format-DomeniaLatencySummaryText -Label ([string]$category.Label) -Summary $summary); Signature=$signature }
            $cache.Rows[$id] = $row
        }
        $rows.Add([pscustomobject]@{ Id=$id; Label=[string]$row.Label; Summary=$row.Summary; Text=[string]$row.Text })
    }
    # One row per category on the pipeline: callers wrap the call in @().
    return $rows.ToArray()
}

function Write-DomeniaTrace {
    # UX-04: the Trace level is written to Domenia.log only. The session journal keeps the facts useful to the operator.
    param([string]$Text,[string]$Area='Tache')
    try { Write-DomeniaAppLogFile -Text (Protect-DomeniaLogText ('[' + $Area + '] ' + [string]$Text)) -Level 'TRACE' -Source 'AppLog' } catch { }
}

# ---------------------------------------------------------------- sharing and queue (D015)
function Add-DomeniaTaskSubscriber {
    # D015: a strictly identical read (same operation, reader, session, generation and payload) joins the
    # one already queued or running instead of opening a second LDAP read or machine probe.
    param([string]$DedupKey,[string]$ReplaceKey,[string]$SuccessHandler,[string]$ErrorHandler,[scriptblock]$OnSuccess,[scriptblock]$OnError,$CallbackState,[string[]]$DisableControls=@())
    if ([string]::IsNullOrWhiteSpace($DedupKey)) { return '' }
    foreach ($job in @($script:AsyncJobs.Values)) {
        if ($null -eq $job -or [bool]$job.IsWrite -or [bool]$job.CancelRequested) { continue }
        if ([string]$job.DedupKey -cne $DedupKey -or [string]$job.ReplaceKey -cne $ReplaceKey) { continue }
        if ([long]$job.SessionEpoch -ne [long]$script:SessionEpoch) { continue }
        $controls = @($DisableControls | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($controls.Count) {
            Set-ControlsBusy -Names $controls -Busy $true
            $job.DisableControls = @($job.DisableControls) + $controls
        }
        if ($null -eq $job.Subscribers) { $job.Subscribers = New-Object System.Collections.ArrayList }
        [void]$job.Subscribers.Add([pscustomobject]@{SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler;OnSuccess=$OnSuccess;OnError=$OnError;CallbackState=$CallbackState})
        # UX-04: engine detail, Domenia.log only.
        Write-DomeniaTrace ('Lecture identique partagée : ' + [string]$job.Name + ' (' + [string]$job.OperationId + '), aucun second appel.')
        return [string]$job.Id
    }
    return ''
}

function Invoke-DomeniaTaskSubscribers {
    # Each subscriber of a shared read receives its own callback with its own state.
    param($Job,$Output,[string]$ErrorMessage='')
    foreach ($subscriber in @(Get-DomeniaMember $Job 'Subscribers' @())) {
        if ($null -eq $subscriber) { continue }
        try {
            if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$subscriber.SuccessHandler)) { Invoke-DomeniaUiHandler -HandlerName ([string]$subscriber.SuccessHandler) -Argument $Output -CallbackState $subscriber.CallbackState }
                elseif ($null -ne $subscriber.OnSuccess) { & $subscriber.OnSuccess $Output $subscriber.CallbackState }
            }
            else {
                if (-not [string]::IsNullOrWhiteSpace([string]$subscriber.ErrorHandler)) { Invoke-DomeniaUiHandler -HandlerName ([string]$subscriber.ErrorHandler) -Argument $ErrorMessage -CallbackState $subscriber.CallbackState }
                elseif ($null -ne $subscriber.OnError) { & $subscriber.OnError $ErrorMessage $subscriber.CallbackState }
            }
        }
        catch { try { Write-AppLog ('[' + [string]$Job.CorrelationId + '] Rappel d un abonne partage : ' + $_.Exception.Message) 'WARN' } catch { } }
    }
}

function Remove-DomeniaQueuedTask {
    # Withdraws an entry that was never sent: no call was made, so nothing has to be cleaned on the network side.
    param($Job,[switch]$Silent)
    if ($null -eq $Job) { return }
    $id = [string]$Job.Id
    if ($script:AsyncJobs.Contains($id)) { [void]$script:AsyncJobs.Remove($id) }
    if ([bool]$Job.BusyApplied) { try { Set-ControlsBusy -Names $Job.DisableControls -Busy $false } catch { }; $Job.BusyApplied = $false }
    if ([string]$script:LatestTaskId -eq $id) { $script:LatestTaskId = '' }
    $Job.State = 'Withdrawn'
    if (-not $Silent) { try { Set-Status (Get-DomeniaCancelStatusText -Name ([string]$Job.Name) -State 'Queued') 'WARN' } catch { } }
}

function Invoke-DomeniaQueuedTaskPromotion {
    # Called by Complete-UiTasks: withdraws stale or expired entries, then (PF-04) starts queued entries by priority
    # (Write, Explicit, Selection, Background) as long as the admission says Start and the tick budget lasts.
    # MO-05: an entry whose provider is saturated or paused stays queued; only a durable refusal is reported.
    # Returns $true when the engine content changed.
    param([int]$BudgetMs=0)
    if (-not (Test-DomeniaSchedulerEnabled)) { return $false }
    $changed = $false
    $limits = Get-DomeniaEngineLimits
    if ($BudgetMs -le 0) { $BudgetMs = [int]$limits.TickBudgetMs }
    foreach ($job in @($script:AsyncJobs.Values)) {
        if ($null -eq $job -or [string]$job.State -ne 'Queued') { continue }
        if ([bool]$script:AsyncEngineClosing -or [long]$job.SessionEpoch -ne [long]$script:SessionEpoch) {
            Remove-DomeniaQueuedTask -Job $job -Silent; $changed = $true; continue
        }
        if (Test-DomeniaQueuedTaskExpired -QueuedAt $job.QueuedAt -MaxWaitSeconds $limits.MaxQueueWaitSeconds) {
            Remove-DomeniaQueuedTask -Job $job -Silent
            $message = 'Lecture non envoyee : attente trop longue (' + $limits.MaxQueueWaitSeconds + ' s). Aucun appel n a ete fait.'
            try { Invoke-DomeniaJobErrorUi -Job $job -Message $message } catch { try { Set-Status $message 'WARN' } catch { } }
            Invoke-DomeniaTaskSubscribers -Job $job -Output $null -ErrorMessage $message
            $changed = $true
        }
    }
    if ([bool]$script:AsyncEngineClosing) { return $changed }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $BudgetMs) {
        $load = Get-DomeniaEngineLoad
        if ($load.QueuedCount -eq 0) { break }
        $next = Select-DomeniaNextQueuedTask -Queued $load.Queued -Running $load.Running -Outstanding $load.Outstanding -MaxConcurrent $limits.MaxConcurrent -MaxOutstanding $limits.MaxOutstanding -ReservedForeground $limits.ReservedForeground -ProviderLoad $load.ProviderLoad -ProviderState $script:DomeniaProviderState
        if ($null -eq $next) { break }
        $changed = $true
        try {
            [void](Invoke-DomeniaUiTaskDispatch -Job $next)
            # CO-02: Annuler and the progress label follow the foreground task, never a local save or a background read.
            if ([bool](Get-DomeniaMember $next 'Foreground' $true)) { $script:LatestTaskId = [string]$next.Id }
            if ($null -ne $next.QueuedAt) { try { Add-DomeniaRuntimeMetric -Provenance 'Queue' -OperationId ('Wait:' + [string]$next.Class) -DurationMs ([double]((Get-Date) - [datetime]$next.QueuedAt).TotalMilliseconds) } catch { } }
            Write-DomeniaTrace ('Demande sortie de la file : ' + [string]$next.Name + ' (' + [string]$next.Class + ').')
        }
        catch {
            $message = [string]$_.Exception.Message
            Remove-DomeniaQueuedTask -Job $next -Silent
            try { Invoke-DomeniaJobErrorUi -Job $next -Message $message } catch { try { Set-Status ([string]$next.Name + ' : ' + $message) 'ERROR' } catch { } }
            Invoke-DomeniaTaskSubscribers -Job $next -Output $null -ErrorMessage $message
        }
    }
    return $changed
}

# ---------------------------------------------------------------- outcomes (D018)
function Register-DomeniaTaskOutcome {
    # Records the end of one worker for its provider and target. Never decides a retry: an automatic retry
    # does not exist for a write, a refusal or a rejected account (Test-DomeniaAutoRetryAllowed).
    # CD-12: $ErrorInfo is the error analysed once by Complete-UiTasks (ConvertTo-DomeniaErrorInfo); without it the
    # message is analysed here, once.
    param($Job,[string]$ErrorMessage='',[switch]$TimedOut,[switch]$Cancelled,$ErrorInfo=$null)
    if($null -eq $Job){return $null}
    $failed = (-not [string]::IsNullOrWhiteSpace($ErrorMessage))
    $structured = $null; $category = ''
    if ($failed) {
        if ($null -ne $ErrorInfo) { $structured = Get-DomeniaMember $ErrorInfo 'Structured' $null; $category = [string](Get-DomeniaMember $ErrorInfo 'Category' '') }
        if ($null -eq $structured) {
            try { $structured = Get-DomeniaStructuredError $ErrorMessage -Phase ([string]$Job.OperationId) -Provider ([string]$Job.Provider) } catch { $structured = $null }
        }
        if (-not $category -and $null -ne $structured) {
            try { $category = [string](Get-DomeniaErrorDecision -Structured $structured -Text $ErrorMessage -Step ([string]$Job.OperationId)).Category } catch { $category = '' }
        }
    }
    # This guard also runs when the scheduler is disabled. Ignore other providers, demos,
    # cancelled reads and a previous account/session. No retry or worker is started here.
    if([string]$Job.Provider -eq 'Directory' -and -not [bool]$Job.Demo -and -not [bool]$Cancelled -and
       ($null -eq $Job.PSObject.Properties['SessionEpoch'] -or [long]$Job.SessionEpoch -eq [long]$script:SessionEpoch)){
        try {
            Initialize-DomeniaEngineState
            $reach='Success'
            if($TimedOut){$reach='Timeout'}
            elseif($failed){$reach=$category;if(-not $reach){$reach='Unknown'}}
            $next=Resolve-DomeniaDirectoryReachability $script:DirectoryReachability 'Directory' $reach
            $next | Add-Member -NotePropertyName Epoch -NotePropertyValue ([long]$script:SessionEpoch)
            $script:DirectoryReachability=$next
            if($next.Changed -and $null -ne $script:Ctrl){
                Apply-CurrentPermissionUi -StartupFastPath
                if(Test-DomeniaSelectionLoadCurrent){Update-DomeniaSelectionReadUi}
            }
        } catch { Write-AppLog ('Etat de connexion AD non applique : '+$_.Exception.Message) 'ERROR' }
    }
    if ($null -eq $Job -or -not [bool]$Job.SchedulerManaged -or $null -eq $script:DomeniaProviderState) { return $null }
    # The demonstration directory is not a provider: its answers never feed a budget.
    if ([bool]$Job.Demo) { return $null }
    $kind = ''
    if ($failed) { $kind = 'Unknown'; if ($null -ne $structured) { $kind = [string](Get-DomeniaMember $structured 'Kind' 'Unknown') } }
    $outcome = ConvertTo-DomeniaProviderOutcome -ErrorKind $kind -Cancelled ([bool]$Cancelled) -TimedOut ([bool]$TimedOut) -Failed $failed
    return (Register-DomeniaProviderOutcome -State $script:DomeniaProviderState -Provider ([string]$Job.Provider) -Target ([string]$Job.ProviderTarget) -Outcome $outcome -Identity ([string]$Job.CredentialIdentity))
}

function ConvertTo-DomeniaTaskErrorInfo {
    # CD-12: one analysis of a task error (ConvertTo-DomeniaErrorInfo: structured error, decision, operator text),
    # kept on the job for the provider outcome, the breaker and the callbacks.
    param($Job,[string]$Message)
    $info = $null
    try { $info = ConvertTo-DomeniaErrorInfo -ErrorRecordOrException $Message -Operation ([string]$Job.Name) -Phase ([string]$Job.OperationId) -Provider ([string]$Job.Provider) } catch { $info = $null }
    try { if ($null -ne $Job.PSObject.Properties['ErrorInfo']) { $Job.ErrorInfo = $info } else { $Job | Add-Member -NotePropertyName ErrorInfo -NotePropertyValue $info -Force } } catch { }
    return $info
}

function Add-DomeniaTaskRuntimeMetric {
    # C7: Add-DomeniaRuntimeMetric keeps a bounded series per provider and operation (no command lookup, PF-10).
    param($Job)
    if ($null -eq $Job) { return }
    try {
        $duration = ((Get-Date) - [datetime]$Job.Started).TotalMilliseconds
        $provenance = 'Ldap'
        switch ([string]$Job.Provider) { 'Cim' { $provenance = 'Cim' } 'Wts' { $provenance = 'Cim' } 'Storage' { $provenance = 'Sqlite' } 'Local' { $provenance = 'Queue' } 'Network' { $provenance = 'Cim' } }
        if ([bool]$Job.Demo) { $provenance = 'Cache' }
        # Point 122: a local search is kept apart from the other actions of the same reader. The dispatch fixed the key
        # (MetricKey) before releasing the request; a job without it falls back to its request, then to its identifier.
        $key = ''
        if ($null -ne $Job.PSObject.Properties['MetricKey']) { $key = [string]$Job.MetricKey }
        if ([string]::IsNullOrEmpty($key)) {
            $payload = $null
            if ($null -ne $Job.PSObject.Properties['Payload']) { $payload = $Job.Payload }
            $key = [string](Get-DomeniaRuntimeMetricOperationKey -OperationId ([string]$Job.OperationId) -Payload $payload)
        }
        # A write or a remote action is never counted among the reads of the same provider (Get-DomeniaResponseTimeCategories).
        if (($null -ne $Job.PSObject.Properties['IsWrite']) -and ([bool]$Job.IsWrite)) { $key = 'Write:' + $key }
        Add-DomeniaRuntimeMetric -Provenance $provenance -OperationId $key -DurationMs ([double]$duration)
    } catch { }
}

# ---------------------------------------------------------------- idle policy (D020, C1)
function Test-DomeniaIdlePolicyEnabled {
    # Features.IdlePolicy (default true): switched off, the policy stays null and every check is open.
    if ($null -eq $script:DomeniaIdlePolicyEnabled) { $script:DomeniaIdlePolicyEnabled = [bool](Get-DomeniaFeatureFlag 'IdlePolicy' $true) }
    return [bool]$script:DomeniaIdlePolicyEnabled
}

function Test-DomeniaBackgroundWorkAllowed {
    # C1. $true when the idle policy (D020) allows background work for this source
    # ('Live','Reconcile','ObjectChanges','Dashboard','Index','Park'); $true also while it is not initialized.
    param([string]$Source)
    if ($null -eq $script:DomeniaIdlePolicy) { return $true }
    try {
        $activity = Get-DomeniaIdleActivityForSource -Source $Source
        return [bool](Test-DomeniaIdleAllows -Policy $script:DomeniaIdlePolicy -Activity ([string]$activity.Activity) -Page ([string]$activity.Page))
    } catch { return $true }
}

function Update-DomeniaIdlePolicy {
    # Recomputes the policy from the real window. Saves, receipts and explicit work are never suspended.
    if (-not (Test-DomeniaIdlePolicyEnabled)) { $script:DomeniaIdlePolicy = $null; Set-DomeniaWindowSuspended -Suspended $false; return $null }
    $window = $script:Window
    if ($null -eq $window) { return $script:DomeniaIdlePolicy }
    $page = ''
    try { $tabs = Get-DomeniaControl -Name 'WorkspaceTabs'; if ($null -ne $tabs -and $null -ne $tabs.SelectedItem) { $page = [string]$tabs.SelectedItem.Name } } catch { }
    $pending = 0
    try { if ($null -ne $script:Persistence -and $null -ne $script:Persistence.Pending) { $pending += @($script:Persistence.Pending.Keys).Count } } catch { }
    try { if ($null -ne $script:Live -and $null -ne $script:Live.SaveQueue) { $pending += @($script:Live.SaveQueue).Count } } catch { }
    $writeInFlight = ((-not [string]::IsNullOrWhiteSpace([string]$script:ActiveWriteTaskId)) -or ([string]$script:WriteState -in @('Running','Unknown','UnknownPending')))
    $minimized = $false; $hidden = $false
    try { $minimized = ([string]$window.WindowState -eq 'Minimized') } catch { }
    try { $hidden = ($window.IsLoaded -and -not [bool]$window.IsVisible) } catch { }
    $script:DomeniaIdlePolicy = Get-DomeniaIdlePolicy -WindowActive ([bool]$window.IsActive) -Minimized $minimized -VisiblePage $page -WriteInFlight $writeInFlight -PendingSaves $pending -Hidden $hidden
    # PF-06: a minimized or hidden window suspends every heartbeat subscriber except tasks, saves and the journal.
    Set-DomeniaWindowSuspended -Suspended ($minimized -or $hidden)
    # A dashboard skipped while hidden is rebuilt once when it becomes visible again.
    if ([bool]$script:DashboardDirty -and (Test-DomeniaBackgroundWorkAllowed -Source 'Dashboard')) {
        $script:DashboardDirty = $false
        try { Request-DomeniaDashboardRefresh } catch { }
    }
    return $script:DomeniaIdlePolicy
}

function Set-DomeniaWindowSuspended {
    # PF-06: entering or leaving the suspension reschedules the heartbeat. On resume, the suspended subscribers are
    # due at once: their next run measures the real Dispatcher delay, not the time spent minimized.
    param([bool]$Suspended)
    $was = [bool]$script:DomeniaWindowSuspended
    $script:DomeniaWindowSuspended = $Suspended
    if ($was -eq $Suspended -or $null -eq $script:DomeniaPulse) { return }
    if (-not $Suspended) {
        $now = [double]$script:DomeniaPulse.Clock.Elapsed.TotalMilliseconds
        foreach ($timer in @($script:DomeniaPulse.Active.Values)) { if (-not [bool]$timer.RunWhenHidden -and [double]$timer.DueMs -lt $now) { $timer.DueMs = $now } }
    }
    Update-DomeniaPulseSchedule
}

function Initialize-DomeniaIdlePolicy {
    # D020: Activated, Deactivated and StateChanged of the main window, and the page selector, drive the policy.
    # The handlers only recompute a decision: an activation never starts a scan by itself.
    param($Window=$script:Window)
    if ($null -eq $Window -or [bool]$script:DomeniaIdlePolicyWired) { return }
    $Window.Add_Activated({ try { [void](Update-DomeniaIdlePolicy) } catch { } })
    $Window.Add_Deactivated({ try { [void](Update-DomeniaIdlePolicy) } catch { } })
    $Window.Add_StateChanged({ try { [void](Update-DomeniaIdlePolicy) } catch { } })
    $Window.Add_IsVisibleChanged({ try { [void](Update-DomeniaIdlePolicy) } catch { } })
    $tabs = Get-DomeniaControl -Name 'WorkspaceTabs'
    if ($null -ne $tabs) {
        # SelectionChanged bubbles from every grid of the page: only the page selector itself counts.
        $tabs.Add_SelectionChanged({ param($sender,$eventArgs) try { if ([object]::ReferenceEquals($eventArgs.OriginalSource,$sender)) { [void](Update-DomeniaIdlePolicy) } } catch { } })
    }
    $script:DomeniaIdlePolicyWired = $true
    [void](Update-DomeniaIdlePolicy)
}

# ---------------------------------------------------------------- D014: index search and shared park file off the Dispatcher
function Get-DomeniaIndexSearchSort {
    if($null -eq $script:DomeniaIndexSort){return [pscustomobject]@{Field='';Descending=$false}}
    return $script:DomeniaIndexSort
}
function Set-DomeniaIndexSearchSort {
    param($Grid,$EventArgs,[switch]$Reset)
    if($null -ne $EventArgs){$EventArgs.Handled=$true}
    if($null -eq $Grid){$Grid=Get-DomeniaControl 'DgIndex'}
    $field='';$descending=$false
    if(-not $Reset){
        if($null -eq $EventArgs -or $null -eq $EventArgs.Column){return}
        $field=[string]$EventArgs.Column.SortMemberPath
        if($field -notin @('Type','Name','Login','Upn','State','Description','Score','Reason','LastLogon','WhenChanged')){return}
        $previous=Get-DomeniaIndexSearchSort
        $descending=if($previous.Field -eq $field){-not $previous.Descending}else{$field -eq 'Score'}
    }
    $script:DomeniaIndexSort=[pscustomobject]@{Field=$field;Descending=$descending}
    $script:DomeniaIndexSearchRetry=$null;$script:DomeniaIndexSearchPage=$null
    if($null -ne $Grid){foreach($column in $Grid.Columns){$column.SortDirection=$null};if($field){$EventArgs.Column.SortDirection=if($descending){[ComponentModel.ListSortDirection]::Descending}else{[ComponentModel.ListSortDirection]::Ascending}}}
    Request-DomeniaIndexSearch
}

function Request-DomeniaIndexSearch {
    # Invalidate immediately: an older callback must not replace the list during the debounce.
    $script:DomeniaIndexSearchGeneration = [long]$script:DomeniaIndexSearchGeneration + 1
    # TextChanged only re-arms a 250 ms timer: no SQLite access runs on the keystroke itself.
    foreach($name in @('BtnIndexPrevious','BtnIndexNext')){$button=Get-DomeniaControl $name;if($null -ne $button){$button.IsEnabled=$false}}
    if ($null -eq $script:DomeniaIndexSearchTimer) {
        # FI-05: protected timer of the engine heartbeat, registered with its owner by the factory.
        $script:DomeniaIndexSearchTimer = New-DomeniaTimer -Owner 'Timer:IndexSearch' -IntervalMs 250 -Tick {
            param($sender,$eventArgs)
            # Stop the timer that ticked, not the script variable (see Request-DomeniaDashboardRefresh).
            try { $sender.Stop() } catch { }
            Search-DomeniaIndexUi
        }
    }
    $script:DomeniaIndexSearchTimer.Stop()
    $script:DomeniaIndexSearchTimer.Start()
}

function Get-DomeniaLocalDatabasePathForRead {
    $path = [string]$script:DatabaseScopedPath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = [string](Get-DomeniaDatabasePath) }
    return $path
}

function Start-DomeniaIndexSearch {
    # The query runs in the LocalIndexRead worker with a short busy timeout; a newer term supersedes it.
    param([AllowEmptyString()][string]$Term='',[int]$Limit=200,[int]$Attempt=0,[int]$Offset=0,[string]$SortField='',[bool]$Descending=$false)
    $Limit=[Math]::Max(1,[Math]::Min(500,$Limit));$Offset=[Math]::Max(0,$Offset)
    if(-not $PSBoundParameters.ContainsKey('SortField')){$sort=Get-DomeniaIndexSearchSort;$SortField=[string]$sort.Field;$Descending=[bool]$sort.Descending}
    $scope=Get-DomeniaIndexScope
    $scopeDn=if($null -ne $scope -and -not $scope.IsDomain){[string]$scope.BaseDn}else{''}
    if($null -ne $script:DomeniaIndexSearchTimer){$script:DomeniaIndexSearchTimer.Stop()}
    $script:DomeniaIndexSearchGeneration = [long]$script:DomeniaIndexSearchGeneration + 1
    $state = [pscustomobject]@{Term=$Term;Limit=$Limit;Offset=$Offset;Scope=$scopeDn;SortField=$SortField;Descending=$Descending;Attempt=$Attempt;Generation=[long]$script:DomeniaIndexSearchGeneration;Epoch=[long]$script:SessionEpoch;Watch=[Diagnostics.Stopwatch]::StartNew()}
    $payload = [pscustomobject]@{Action='Search';Path=(Get-DomeniaLocalDatabasePathForRead);Term=$Term;Limit=[Math]::Max(1,[Math]::Min(500,$Limit));Offset=$Offset;Scope=$scopeDn;SortField=$SortField;Descending=$Descending;Browse=$true;BusyTimeoutMs=50}
    foreach($name in @('BtnIndexPrevious','BtnIndexNext')){$button=Get-DomeniaControl $name;if($null -ne $button){$button.IsEnabled=$false}}
    [void](Set-DomeniaControlText -Name 'LblIndexStatus' -Text 'Recherche dans l index local en arriere-plan...')
    return (Start-UiTask -Name 'Recherche dans l index local' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload $payload -CallbackState $state -ReplaceKey 'index-search' -TimeoutSeconds 20 -SuccessHandler 'Complete-DomeniaIndexSearchUi' -ErrorHandler 'Fail-DomeniaIndexSearchUi' -TaskClass 'Explicit')
}

function Complete-DomeniaIndexSearchUi {
    param($Result,$State)
    if ([long]$State.Generation -ne [long]$script:DomeniaIndexSearchGeneration -or [long]$State.Epoch -ne [long]$script:SessionEpoch) { return }
    $effective = Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows','Busy')
    if ($null -eq $effective) { Fail-DomeniaIndexSearchUi -Message 'Resultat de l index local illisible.' -State $State; return }
    if ([bool]$effective.Busy) {
        # A locked database is not an empty result: one short delayed retry, then a visible message.
        if ([int]$State.Attempt -lt 2) {
            [void](Set-DomeniaControlText -Name 'LblIndexStatus' -Text 'Base locale occupee : nouvel essai dans un instant.')
            $script:DomeniaIndexSearchRetry = [pscustomobject]@{Term=[string]$State.Term;Attempt=([int]$State.Attempt + 1);Offset=[int]$State.Offset;Scope=[string]$State.Scope;Epoch=[long]$State.Epoch;Limit=[int]$State.Limit;SortField=[string](Get-DomeniaMember $State 'SortField' '');Descending=[bool](Get-DomeniaMember $State 'Descending' $false);Generation=([long]$State.Generation+1)}
            Request-DomeniaIndexSearch
            return
        }
        [void](Set-DomeniaControlText -Name 'LblIndexStatus' -Text 'Base locale occupee : recherche non effectuee. Reessayez dans un instant.')
        return
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in @($effective.Rows)) {
        if ($null -eq $row) { continue }
        $association = ''
        try { $association = [string](Get-DomeniaIndexAssociationText -Row $row) } catch { $association = '' }
        $row | Add-Member -NotePropertyName Association -NotePropertyValue $association -Force
        $rows.Add($row)
    }
    [void](Set-DomeniaItemsSource -Name 'DgIndex' -Rows $rows.ToArray())
    $elapsed = 0
    try { $elapsed = [int]$State.Watch.ElapsedMilliseconds } catch { }
    $total=[long](Get-DomeniaMember $effective 'Total' $rows.Count);$offset=[int](Get-DomeniaMember $effective 'Offset' 0)
    $script:DomeniaIndexSearchPage=[pscustomobject]@{Term=[string]$State.Term;Scope=[string]$State.Scope;Offset=$offset;Limit=[int]$State.Limit;Total=$total;Epoch=[long]$State.Epoch;Generation=[long]$State.Generation;SortField=[string](Get-DomeniaMember $State 'SortField' '');Descending=[bool](Get-DomeniaMember $State 'Descending' $false)}
    $previous=Get-DomeniaControl 'BtnIndexPrevious';if($null -ne $previous){$previous.IsEnabled=($offset -gt 0)}
    $next=Get-DomeniaControl 'BtnIndexNext';if($null -ne $next){$next.IsEnabled=([bool](Get-DomeniaMember $effective 'HasMore' $false))}
    $message = '{0} objet(s) affiché(s), {1} correspondant(s) dans la base · page {2} · {3} ms.' -f $rows.Count,$total,([int]($offset/[Math]::Max(1,[int]$State.Limit))+1),$elapsed
    if ($rows.Count -eq 0) { $message = 'Aucun objet de l index local ne correspond a ' + [char]39 + [string]$State.Term + [char]39 + '. L index peut etre incomplet.' }
    [void](Set-DomeniaControlText -Name 'LblIndexStatus' -Text $message)
}
function Move-DomeniaIndexSearchPage {
    param([int]$Direction=1)
    $page=$script:DomeniaIndexSearchPage
    if($null -eq $page -or [long]$page.Epoch -ne [long]$script:SessionEpoch -or [long](Get-DomeniaMember $page 'Generation' -1) -ne [long]$script:DomeniaIndexSearchGeneration){return}
    $term=([string](Get-DomeniaControl 'TxtIndexSearch').Text).Trim();$scope=Get-DomeniaIndexScope
    $scopeDn=if($null -ne $scope -and -not $scope.IsDomain){[string]$scope.BaseDn}else{''}
    $sort=Get-DomeniaIndexSearchSort
    if($term -cne [string]$page.Term -or $scopeDn -ine [string]$page.Scope -or [string]$sort.Field -cne [string](Get-DomeniaMember $page 'SortField' '') -or [bool]$sort.Descending -ne [bool](Get-DomeniaMember $page 'Descending' $false)){Search-DomeniaIndexUi;return}
    $offset=[Math]::Max(0,[int]$page.Offset+([Math]::Sign($Direction)*[int]$page.Limit))
    if($offset -ge [long]$page.Total){return}
    [void](Start-DomeniaIndexSearch -Term $term -Limit ([int]$page.Limit) -Offset $offset -SortField ([string]$sort.Field) -Descending ([bool]$sort.Descending))
}

function Fail-DomeniaIndexSearchUi {
    param($Message,$State)
    if ($null -ne $State -and ([long]$State.Generation -ne [long]$script:DomeniaIndexSearchGeneration -or [long]$State.Epoch -ne [long]$script:SessionEpoch)) { return }
    $detail = ([string]$Message).Trim()
    if (-not $detail) { $detail = 'Erreur inconnue.' }
    [void](Set-DomeniaControlText -Name 'LblIndexStatus' -Text ('Recherche locale non effectuee : ' + $detail))
    try { Add-DomeniaUiLog -Level 'WARN' -Area 'Index' -Text ('Recherche locale : ' + $detail) } catch { }
}

function Request-DomeniaParkStateReload {
    # The stored park state is read in the LocalIndexRead worker; the in-memory state stays usable meanwhile.
    if ($null -ne $script:DomeniaParkStateReloadJob -and $script:AsyncJobs.Contains([string]$script:DomeniaParkStateReloadJob)) { return }
    try {
        # Continuation of an explicit park result: never refused as background work, at worst queued.
        # Short local read (250 ms busy, 30 s cap): not offered to Annuler, whose cancel path calls no handler and
        # would strand the deferred park results (revue adversariale du 2026-10-02).
        $script:DomeniaParkStateReloadJob = Start-UiTask -Name 'Lecture du releve local du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{Action='ParkState';Path=(Get-DomeniaLocalDatabasePathForRead);BusyTimeoutMs=250}) -CallbackState ([pscustomobject]@{Epoch=[long]$script:SessionEpoch}) -TimeoutSeconds 30 -SuccessHandler 'Complete-DomeniaParkStateReloadUi' -ErrorHandler 'Fail-DomeniaParkStateReloadUi' -TaskClass 'Explicit' -NonCancellable
    } catch {
        # A refused start must not strand the deferred results: they are applied without the stored counters.
        Fail-DomeniaParkStateReloadUi -Message $_.Exception.Message -State $null
    }
}

function Add-DomeniaParkDeferredResult {
    # A park result that arrives before the stored park state is loaded is applied after the asynchronous read,
    # so its attempt counters build on the stored ones instead of restarting from zero.
    param([Parameter(Mandatory=$true)][string]$Handler,$Result,$State)
    if ($null -eq $script:DomeniaParkDeferred) { $script:DomeniaParkDeferred = New-Object System.Collections.ArrayList }
    if ($script:DomeniaParkDeferred.Count -ge 16) { $script:DomeniaParkDeferred.RemoveAt(0) }
    [void]$script:DomeniaParkDeferred.Add([pscustomobject]@{Handler=$Handler;Result=$Result;State=$State})
    [void](Set-DomeniaControlText -Name 'LblParkStatus' -Text 'Lecture du releve local en arriere-plan avant d integrer le resultat...')
    Request-DomeniaParkStateReload
}

function Invoke-DomeniaParkDeferredResults {
    $pending = @()
    if ($null -ne $script:DomeniaParkDeferred) { $pending = @($script:DomeniaParkDeferred.ToArray()); $script:DomeniaParkDeferred.Clear() }
    foreach ($item in $pending) {
        try { Invoke-DomeniaUiHandler -HandlerName ([string]$item.Handler) -Argument $item.Result -CallbackState $item.State }
        catch { try { Add-DomeniaUiLog -Level 'WARN' -Area 'Parc' -Text ('Resultat du parc non integre : ' + $_.Exception.Message) } catch { } }
    }
}

function Complete-DomeniaParkStateReloadUi {
    param($Result,$State)
    $script:DomeniaParkStateReloadJob = $null
    if ($null -ne $State -and [long]$State.Epoch -ne [long]$script:SessionEpoch) { return }
    $effective = Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Rows','Busy')
    if ($null -eq $effective -or [bool]$effective.Busy) { Fail-DomeniaParkStateReloadUi -Message 'Base locale occupee.' -State $State; return }
    $stored = @{}
    foreach ($r in @($effective.Rows)) {
        if ($null -eq $r) { continue }
        $stored[[string]$r.computer_key] = [pscustomobject]@{Computer=[string]$r.computer;LastProbe=[string]$r.last_probe;Status=[string]$r.status;User=[string]$r.user_login;Attempts=[int]$r.attempts}
    }
    $current = $script:ParkState
    if ($null -eq $current) { $current = @{} }
    # Stored rows are the base; anything observed in this session since then wins when it is more recent.
    $script:ParkState = (Merge-DomeniaParkState -Base $stored -Incoming $current).State
    Invoke-DomeniaParkDeferredResults
    [void](Set-DomeniaControlText -Name 'LblParkStatus' -Text (Get-DomeniaParkStatusTextSafe))
}

function Fail-DomeniaParkStateReloadUi {
    param($Message,$State)
    $script:DomeniaParkStateReloadJob = $null
    try { Add-DomeniaUiLog -Level 'WARN' -Area 'Parc' -Text ('Releve local non relu : ' + [string]$Message + ' Les resultats recus sont integres sans les compteurs enregistres.') } catch { }
    if ($null -eq $script:ParkState) { $script:ParkState = @{} }
    Invoke-DomeniaParkDeferredResults
}

function Get-DomeniaParkStatusTextSafe {
    # Coverage text without a synchronous database count: the count needs the in-memory index.
    if (@($script:IndexRows).Count -gt 0 -and $null -ne $script:ParkState) { return (Get-DomeniaParkCoverageText) }
    $count = 0
    if ($null -ne $script:ParkState) { $count = @($script:ParkState.Keys).Count }
    return ([string]$count + ' poste(s) releve(s) en memoire. La couverture du parc se calcule avec l index en memoire.')
}

function Start-DomeniaParkSharedSync {
    # The shared park file (possibly a UNC path, with a lock file and retries) is read, merged and written
    # in the ParkSharedSync worker. Returns the task id, or '' when no shared path is configured.
    param([switch]$WriteBack,[string]$Summary='')
    $path = Get-DomeniaParkSharedPath
    if ([string]::IsNullOrWhiteSpace($path)) { return '' }
    if ($null -ne $script:DomeniaParkSharedJob -and $script:AsyncJobs.Contains([string]$script:DomeniaParkSharedJob)) {
        $script:DomeniaParkSharedPending = $true
        return [string]$script:DomeniaParkSharedJob
    }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $script:ParkState) {
        foreach ($key in @($script:ParkState.Keys)) {
            $e = $script:ParkState[$key]
            $entries.Add([pscustomobject]@{Computer=[string]$e.Computer;LastProbe=[string]$e.LastProbe;Status=[string]$e.Status;User=[string]$e.User;Attempts=[int]$e.Attempts;ProbedBy=[string]$e.ProbedBy})
        }
    }
    $payload = [pscustomobject]@{Path=$path;WriteBack=[bool]$WriteBack;Entries=$entries.ToArray();Me=[string]$script:ProcessIdentityDisplay}
    $script:DomeniaParkSharedPending = $false
    $script:DomeniaParkSharedJob = Start-UiTask -Name 'Synchronisation du releve partage' -OperationId 'ParkSharedSync' -Code (Get-DomeniaParkSharedSyncWorkerCode) -Payload $payload -CallbackState ([pscustomobject]@{Epoch=[long]$script:SessionEpoch;Summary=$Summary}) -TimeoutSeconds 45 -SuccessHandler 'Complete-DomeniaParkSharedSyncUi' -ErrorHandler 'Fail-DomeniaParkSharedSyncUi' -TaskClass 'Background'
    return [string]$script:DomeniaParkSharedJob
}

function Complete-DomeniaParkSharedSyncUi {
    param($Result,$State)
    $script:DomeniaParkSharedJob = $null
    if ($null -ne $State -and [long]$State.Epoch -ne [long]$script:SessionEpoch) { return }
    $effective = Get-DomeniaEffectiveWorkerResult -Result $Result -RequiredProperties @('Recus','Actualises','Total','Ecrit','Entries')
    if ($null -eq $effective) { Fail-DomeniaParkSharedSyncUi -Message 'Resultat de synchronisation illisible.' -State $State; return }
    $incoming = @{}
    foreach ($e in @($effective.Entries)) {
        if ($null -eq $e -or [string]::IsNullOrWhiteSpace([string]$e.Computer)) { continue }
        $incoming[([string]$e.Computer).ToUpperInvariant()] = [pscustomobject]@{Computer=[string]$e.Computer;LastProbe=[string]$e.LastProbe;Status=[string]$e.Status;User=[string]$e.User;Attempts=[int]$e.Attempts;ProbedBy=[string]$e.ProbedBy}
    }
    $base = $script:ParkState
    if ($null -eq $base) { $base = @{} }
    $script:ParkState = (Merge-DomeniaParkState -Base $base -Incoming $incoming).State
    [void](Save-DomeniaParkState)
    $text = 'Partage : {0} recu(s), {1} actualise(s), {2} au total.' -f [int]$effective.Recus,[int]$effective.Actualises,[int]$effective.Total
    if (-not [bool]$effective.Ecrit -and [bool]$effective.Locked) { $text += ' Fichier partage verrouille par une autre console : ecriture reportee.' }
    try { Add-DomeniaUiLog -Area 'Parc' -Text $text } catch { }
    [void](Set-DomeniaControlText -Name 'LblParkStatus' -Text (Get-DomeniaParkStatusTextSafe))
    if ([bool]$script:DomeniaParkSharedPending) { [void](Start-DomeniaParkSharedSync -WriteBack) }
}

function Fail-DomeniaParkSharedSyncUi {
    param($Message,$State)
    $script:DomeniaParkSharedJob = $null
    try { Add-DomeniaUiLog -Area 'Parc' -Level 'WARN' -Text ('Releve partage inaccessible, travail en local : ' + [string]$Message) } catch { }
}
