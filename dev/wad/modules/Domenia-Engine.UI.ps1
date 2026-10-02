# Engine runtime adapters (D014 to D020, C1, demo substitution of C2, D016 isolation wrapper).
# Dot-sourced in the core scope by the closed loader. Shared engine state is created lazily by
# Initialize-DomeniaEngineState: nothing runs at import time (D011) and no timer starts here.
# Pure decisions live in Domenia-Engine.Model.ps1; this file only applies them to the live engine.

# ---------------------------------------------------------------- state (D011, D015, D018, D019)
function Initialize-DomeniaEngineState {
    # Idempotent. Called by Start-UiTask, Complete-UiTasks, Dispose-AsyncEngine and the window handlers.
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
    return [pscustomobject]@{MaxConcurrent=$maxConcurrent;MaxOutstanding=$maxOutstanding;MaxQueued=$maxQueued;ReservedForeground=$reserved;MaxQueueWaitSeconds=$maxWait}
}

function Get-DomeniaEngineLoad {
    # A queued entry holds no thread. A detached read still holds one until its native call really ends.
    $queued = New-Object 'System.Collections.Generic.List[object]'
    $running = 0; $active = 0
    foreach ($job in @($script:AsyncJobs.Values)) {
        if ($null -eq $job) { continue }
        if ([string]$job.State -eq 'Queued') { $queued.Add($job); continue }
        $active++
        if (-not [bool]$job.CancelRequested) { $running++ }
    }
    $detached = @(@($script:DetachedReadJobs) | Where-Object { $null -ne $_ }).Count
    return [pscustomobject]@{Queued=$queued.ToArray();QueuedCount=$queued.Count;Running=$running;Active=$active;Detached=$detached;Outstanding=($active + $detached)}
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
    $context = Set-DomeniaTargetCredentialContext -Context (Get-WorkerContext -OperationId $requested) -Payload $Job.Payload
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
        try { Add-DomeniaUiLog -Area 'Tache' -Level 'INFO' -Text ('Lecture identique partagee : ' + [string]$job.Name + ' (' + [string]$job.OperationId + '), aucun second appel.') } catch { }
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
    # Called by Complete-UiTasks: withdraws stale or expired entries, then starts at most one entry per tick,
    # explicit actions first. Returns $true when the engine content changed.
    if (-not (Test-DomeniaSchedulerEnabled)) { return $false }
    $changed = $false
    $limits = Get-DomeniaEngineLimits
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
    $load = Get-DomeniaEngineLoad
    if ($load.QueuedCount -eq 0) { return $changed }
    $next = Select-DomeniaNextQueuedTask -Queued $load.Queued -Running $load.Running -Outstanding $load.Outstanding -MaxConcurrent $limits.MaxConcurrent -MaxOutstanding $limits.MaxOutstanding -ReservedForeground $limits.ReservedForeground
    if ($null -eq $next) { return $changed }
    try {
        [void](Invoke-DomeniaUiTaskDispatch -Job $next)
        $script:LatestTaskId = [string]$next.Id
        try { Add-DomeniaUiLog -Area 'Tache' -Level 'INFO' -Text ('Demande sortie de la file : ' + [string]$next.Name + ' (' + [string]$next.Class + ').') } catch { }
    }
    catch {
        $message = [string]$_.Exception.Message
        Remove-DomeniaQueuedTask -Job $next -Silent
        try { Invoke-DomeniaJobErrorUi -Job $next -Message $message } catch { try { Set-Status ([string]$next.Name + ' : ' + $message) 'ERROR' } catch { } }
        Invoke-DomeniaTaskSubscribers -Job $next -Output $null -ErrorMessage $message
    }
    return $true
}

# ---------------------------------------------------------------- outcomes (D018)
function Register-DomeniaTaskOutcome {
    # Records the end of one worker for its provider and target. Never decides a retry: an automatic retry
    # does not exist for a write, a refusal or a rejected account (Test-DomeniaAutoRetryAllowed).
    param($Job,[string]$ErrorMessage='',[switch]$TimedOut,[switch]$Cancelled)
    if ($null -eq $Job -or -not [bool]$Job.SchedulerManaged -or $null -eq $script:DomeniaProviderState) { return $null }
    # The demonstration directory is not a provider: its answers never feed a budget.
    if ([bool]$Job.Demo) { return $null }
    $kind = ''
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        try { $kind = [string](Get-DomeniaStructuredError $ErrorMessage -Phase ([string]$Job.OperationId) -Provider ([string]$Job.Provider)).Kind } catch { $kind = 'Unknown' }
    }
    $outcome = ConvertTo-DomeniaProviderOutcome -ErrorKind $kind -Cancelled ([bool]$Cancelled) -TimedOut ([bool]$TimedOut) -Failed (-not [string]::IsNullOrWhiteSpace($ErrorMessage))
    return (Register-DomeniaProviderOutcome -State $script:DomeniaProviderState -Provider ([string]$Job.Provider) -Target ([string]$Job.ProviderTarget) -Outcome $outcome -Identity ([string]$Job.CredentialIdentity))
}

function Add-DomeniaTaskRuntimeMetric {
    # C7 is optional: the diagnostic lot provides Add-DomeniaRuntimeMetric; absent, nothing is measured.
    param($Job)
    if ($null -eq $Job) { return }
    $metric = Get-Command -Name Add-DomeniaRuntimeMetric -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $metric) { return }
    try {
        $duration = ((Get-Date) - [datetime]$Job.Started).TotalMilliseconds
        $provenance = 'Ldap'
        switch ([string]$Job.Provider) { 'Cim' { $provenance = 'Cim' } 'Wts' { $provenance = 'Cim' } 'Storage' { $provenance = 'Sqlite' } 'Local' { $provenance = 'Queue' } 'Network' { $provenance = 'Cim' } }
        if ([bool]$Job.Demo) { $provenance = 'Cache' }
        Add-DomeniaRuntimeMetric -Provenance $provenance -OperationId ([string]$Job.OperationId) -DurationMs ([double]$duration)
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
    if (-not (Test-DomeniaIdlePolicyEnabled)) { $script:DomeniaIdlePolicy = $null; return $null }
    $window = $script:Window
    if ($null -eq $window) { return $script:DomeniaIdlePolicy }
    $page = ''
    try { $tabs = Get-DomeniaControl -Name 'WorkspaceTabs'; if ($null -ne $tabs -and $null -ne $tabs.SelectedItem) { $page = [string]$tabs.SelectedItem.Name } } catch { }
    $pending = 0
    try { if ($null -ne $script:Persistence -and $null -ne $script:Persistence.Pending) { $pending += @($script:Persistence.Pending.Keys).Count } } catch { }
    try { if ($null -ne $script:Live -and $null -ne $script:Live.SaveQueue) { $pending += @($script:Live.SaveQueue).Count } } catch { }
    $writeInFlight = ((-not [string]::IsNullOrWhiteSpace([string]$script:ActiveWriteTaskId)) -or ([string]$script:WriteState -in @('Running','Unknown','UnknownPending')))
    $minimized = $false
    try { $minimized = ([string]$window.WindowState -eq 'Minimized') } catch { }
    $script:DomeniaIdlePolicy = Get-DomeniaIdlePolicy -WindowActive ([bool]$window.IsActive) -Minimized $minimized -VisiblePage $page -WriteInFlight $writeInFlight -PendingSaves $pending
    # A dashboard skipped while hidden is rebuilt once when it becomes visible again.
    if ([bool]$script:DashboardDirty -and (Test-DomeniaBackgroundWorkAllowed -Source 'Dashboard')) {
        $script:DashboardDirty = $false
        try { Request-DomeniaDashboardRefresh } catch { }
    }
    return $script:DomeniaIdlePolicy
}

function Initialize-DomeniaIdlePolicy {
    # D020: Activated, Deactivated and StateChanged of the main window, and the page selector, drive the policy.
    # The handlers only recompute a decision: an activation never starts a scan by itself.
    param($Window=$script:Window)
    if ($null -eq $Window -or [bool]$script:DomeniaIdlePolicyWired) { return }
    $Window.Add_Activated({ try { [void](Update-DomeniaIdlePolicy) } catch { } })
    $Window.Add_Deactivated({ try { [void](Update-DomeniaIdlePolicy) } catch { } })
    $Window.Add_StateChanged({ try { [void](Update-DomeniaIdlePolicy) } catch { } })
    $tabs = Get-DomeniaControl -Name 'WorkspaceTabs'
    if ($null -ne $tabs) {
        # SelectionChanged bubbles from every grid of the page: only the page selector itself counts.
        $tabs.Add_SelectionChanged({ param($sender,$eventArgs) try { if ([object]::ReferenceEquals($eventArgs.OriginalSource,$sender)) { [void](Update-DomeniaIdlePolicy) } } catch { } })
    }
    $script:DomeniaIdlePolicyWired = $true
    [void](Update-DomeniaIdlePolicy)
}

# ---------------------------------------------------------------- D014: index search and shared park file off the Dispatcher
function Request-DomeniaIndexSearch {
    # TextChanged only re-arms a 250 ms timer: no SQLite access runs on the keystroke itself.
    if ($null -eq $script:DomeniaIndexSearchTimer) {
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(250)
        $timer.Add_Tick({
            try { $script:DomeniaIndexSearchTimer.Stop() } catch { }
            try { Search-DomeniaIndexUi } catch { }
        })
        $script:DomeniaIndexSearchTimer = $timer
        [void](Register-DomeniaOwnedTimer -Owner 'Timer:IndexSearch' -Timer $timer)
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
    param([Parameter(Mandatory=$true)][string]$Term,[int]$Limit=200,[int]$Attempt=0)
    $script:DomeniaIndexSearchGeneration = [long]$script:DomeniaIndexSearchGeneration + 1
    $state = [pscustomobject]@{Term=$Term;Limit=$Limit;Attempt=$Attempt;Generation=[long]$script:DomeniaIndexSearchGeneration;Epoch=[long]$script:SessionEpoch;Watch=[Diagnostics.Stopwatch]::StartNew()}
    $payload = [pscustomobject]@{Action='Search';Path=(Get-DomeniaLocalDatabasePathForRead);Term=$Term;Limit=[Math]::Max(1,[Math]::Min(500,$Limit));BusyTimeoutMs=50}
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
            $script:DomeniaIndexSearchRetry = [pscustomobject]@{Term=[string]$State.Term;Attempt=([int]$State.Attempt + 1)}
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
    $message = '{0} resultat(s) en {1} ms, sans appel reseau.' -f $rows.Count,$elapsed
    if ($rows.Count -eq 0) { $message = 'Aucun objet de l index local ne correspond a ' + [char]39 + [string]$State.Term + [char]39 + '. L index peut etre incomplet.' }
    [void](Set-DomeniaControlText -Name 'LblIndexStatus' -Text $message)
}

function Fail-DomeniaIndexSearchUi {
    param($Message,$State)
    if ($null -ne $State -and [long]$State.Generation -ne [long]$script:DomeniaIndexSearchGeneration) { return }
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
        $script:DomeniaParkStateReloadJob = Start-UiTask -Name 'Lecture du releve local du parc' -OperationId 'LocalIndexRead' -Code (Get-DomeniaLocalIndexReadWorkerCode) -Payload ([pscustomobject]@{Action='ParkState';Path=(Get-DomeniaLocalDatabasePathForRead);BusyTimeoutMs=250}) -CallbackState ([pscustomobject]@{Epoch=[long]$script:SessionEpoch}) -TimeoutSeconds 30 -SuccessHandler 'Complete-DomeniaParkStateReloadUi' -ErrorHandler 'Fail-DomeniaParkStateReloadUi' -TaskClass 'Explicit'
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
