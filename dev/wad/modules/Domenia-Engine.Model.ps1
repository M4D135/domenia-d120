# Engine rules: startup order, selection identity, task scheduling, cancellation states,
# provider budgets, resource ownership and idle policy. Pure decisions only: no runspace,
# no timer and no network call is created here.

# ---------------------------------------------------------------- D011 startup order
function Get-DomeniaStartupPhases {
    return @('Bootstrap','Resources','Modules','Authentication','Interface')
}

function Get-DomeniaFunctionProviderMap {
    param([object[]]$Modules)
    $map = @{}
    foreach ($module in @($Modules)) {
        foreach ($name in @(Get-DomeniaMember $module 'Functions' @())) {
            if (-not $map.ContainsKey([string]$name)) { $map[[string]$name] = [string](Get-DomeniaMember $module 'File' '') }
        }
    }
    return $map
}

function Test-DomeniaStartupPlan {
    # Validates the declared module plan before the first import: phases, dependencies, cycles, duplicate providers.
    param([object[]]$Modules)
    $phases = @(Get-DomeniaStartupPhases)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $byFile = @{}
    $owners = @{}
    foreach ($module in @($Modules)) {
        $file = [string](Get-DomeniaMember $module 'File' '')
        if (-not $file) { $errors.Add('Module sans nom de fichier.'); continue }
        if ($byFile.ContainsKey($file)) { $errors.Add('Module declare deux fois : ' + $file); continue }
        $byFile[$file] = $module
        $phase = [string](Get-DomeniaMember $module 'Phase' 'Modules')
        if ($phases -notcontains $phase) { $errors.Add('Phase inconnue pour ' + $file + ' : ' + $phase) }
        foreach ($function in @(Get-DomeniaMember $module 'Functions' @())) {
            $name = [string]$function
            if ($owners.ContainsKey($name)) { $errors.Add('Fonction ' + $name + ' fournie par ' + $owners[$name] + ' et ' + $file) }
            else { $owners[$name] = $file }
        }
    }
    foreach ($file in @($byFile.Keys)) {
        $module = $byFile[$file]
        $phaseIndex = [Array]::IndexOf($phases,[string](Get-DomeniaMember $module 'Phase' 'Modules'))
        foreach ($dependency in @(Get-DomeniaMember $module 'Requires' @())) {
            $required = [string]$dependency
            if (-not $required) { continue }
            if (-not $byFile.ContainsKey($required)) { $errors.Add($file + ' requiert un module absent : ' + $required); continue }
            $requiredIndex = [Array]::IndexOf($phases,[string](Get-DomeniaMember $byFile[$required] 'Phase' 'Modules'))
            if ($requiredIndex -gt $phaseIndex) { $errors.Add($file + ' requiert ' + $required + ' charge dans une phase ulterieure.') }
        }
    }
    # Depth-first ordering inside the declared order; a grey node met again is a cycle.
    $order = New-Object 'System.Collections.Generic.List[string]'
    $state = @{}
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    foreach ($module in @($Modules)) {
        $start = [string](Get-DomeniaMember $module 'File' '')
        if (-not $start -or -not $byFile.ContainsKey($start) -or $state.ContainsKey($start)) { continue }
        $stack.Push(@($start,0))
        while ($stack.Count -gt 0) {
            $frame = $stack.Pop()
            $current = [string]$frame[0]; $index = [int]$frame[1]
            if ($index -eq 0) {
                if ($state.ContainsKey($current)) { continue }
                $state[$current] = 'Grey'
            }
            $requires = @(@(Get-DomeniaMember $byFile[$current] 'Requires' @()) | Where-Object { $_ -and $byFile.ContainsKey([string]$_) })
            if ($index -lt $requires.Count) {
                $stack.Push(@($current,($index + 1)))
                $next = [string]$requires[$index]
                if (-not $state.ContainsKey($next)) { $stack.Push(@($next,0)) }
                elseif ($state[$next] -eq 'Grey') { $errors.Add('Cycle de dependances : ' + $current + ' -> ' + $next) }
                continue
            }
            $state[$current] = 'Black'
            $order.Add($current)
        }
    }
    return [pscustomobject]@{Valid=($errors.Count -eq 0);Order=$order.ToArray();Errors=$errors.ToArray()}
}

function Test-DomeniaPhaseCall {
    # A caller running in $CurrentPhase may only use a provider loaded in the same or an earlier phase.
    param([Parameter(Mandatory=$true)][string]$CurrentPhase,[Parameter(Mandatory=$true)][string]$ProviderPhase)
    $phases = @(Get-DomeniaStartupPhases)
    $current = [Array]::IndexOf($phases,$CurrentPhase); $provider = [Array]::IndexOf($phases,$ProviderPhase)
    if ($current -lt 0 -or $provider -lt 0) { return $false }
    return ($provider -le $current)
}

# ---------------------------------------------------------------- D012 selection identity
function New-DomeniaSelectionIdentity {
    # Builds the immutable identity used by Fiche, Relations and Assistance. Returns $null when the row has no usable GUID.
    param($Row,[string]$Domain,[string]$Reader='',[long]$Epoch=0,[long]$Generation=0)
    if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($Domain)) { return $null }
    $guid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $Row 'Guid' '')
    $type = [string](Get-DomeniaMember $Row 'Type' '')
    if (-not $guid -or -not $type) { return $null }
    if ($null -eq ('Domenia.SelectionIdentity' -as [type])) { throw 'Type Domenia.SelectionIdentity non charge.' }
    return New-Object Domenia.SelectionIdentity -ArgumentList @(
        $Domain,$guid,(ConvertTo-DomeniaSidText (Get-DomeniaMember $Row 'Sid' '')),$type,
        [string](Get-DomeniaMember $Row 'DN' ''),[string](Get-DomeniaMember $Row 'Name' ''),[string](Get-DomeniaMember $Row 'Login' ''),
        $Reader,$Epoch,$Generation)
}

function Test-DomeniaIdentityCurrent {
    # $Captured was stored when the operation was prepared; $Current is the selection right now.
    param($Captured,$Current)
    if ($null -eq $Captured -or $null -eq $Current) { return $false }
    if ($Captured -isnot [Domenia.SelectionIdentity] -or $Current -isnot [Domenia.SelectionIdentity]) { return $false }
    return $Captured.SameContext($Current)
}

# ---------------------------------------------------------------- D015 scheduler
function Get-DomeniaTaskClass {
    # Class of the operation in the table (Get-DomeniaOperationTable); an unknown identifier is Explicit. A caller
    # that knows better passes -Hint (for example IndexBuild started automatically at startup is Background, the same
    # read started by a button stays Explicit).
    param([Parameter(Mandatory=$true)][string]$OperationId,[bool]$IsWrite=$false,[string]$ReplaceKey='',[string]$Hint='')
    if ($IsWrite) { return 'Write' }
    if ($Hint -in @('Explicit','Selection','Background')) { return $Hint }
    $row = Get-DomeniaOperationRow $OperationId
    if ($null -eq $row) { return 'Explicit' }
    $class = [string]$row.Class
    if ($class.StartsWith('Selection:')) {
        if ($ReplaceKey -eq $class.Substring(10)) { return 'Selection' }
        return 'Explicit'
    }
    return $class
}

function Get-DomeniaTaskPriority {
    # Lower value starts first.
    param([Parameter(Mandatory=$true)][string]$Class)
    switch ($Class) { 'Write' { return 0 } 'Explicit' { return 1 } 'Selection' { return 2 } default { return 3 } }
}

function Get-DomeniaPayloadDigest {
    # Stable text for simple payloads. Returns '' when the payload carries a live object (queue, credential...):
    # such a request is never shared with another one.
    param($Payload,[int]$Depth=0)
    if ($Depth -gt 4) { return '' }
    if ($null -eq $Payload) { return 'null' }
    if ($Payload -is [string]) { return 's:' + $Payload }
    if ($Payload -is [bool] -or $Payload -is [int] -or $Payload -is [long] -or $Payload -is [double] -or $Payload -is [decimal]) { return 'v:' + [string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0}',$Payload) }
    if ($Payload -is [guid]) { return 'g:' + $Payload.ToString('D') }
    if ($Payload -is [datetime]) { return 'd:' + $Payload.ToUniversalTime().ToString('o') }
    if ($Payload -is [Collections.IDictionary]) {
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($key in @($Payload.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $inner = Get-DomeniaPayloadDigest $Payload[$key] ($Depth + 1)
            if (-not $inner) { return '' }
            $parts.Add($key + '=' + $inner)
        }
        return 'h{' + ($parts.ToArray() -join ';') + '}'
    }
    if ($Payload -is [array] -or $Payload -is [Collections.IList]) {
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in @($Payload)) {
            $inner = Get-DomeniaPayloadDigest $item ($Depth + 1)
            if (-not $inner) { return '' }
            $parts.Add($inner)
        }
        return 'a[' + ($parts.ToArray() -join ',') + ']'
    }
    if ($Payload -is [Management.Automation.PSCustomObject]) {
        $parts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($property in @($Payload.PSObject.Properties | Sort-Object Name)) {
            $inner = Get-DomeniaPayloadDigest $property.Value ($Depth + 1)
            if (-not $inner) { return '' }
            $parts.Add([string]$property.Name + '=' + $inner)
        }
        return 'o{' + ($parts.ToArray() -join ';') + '}'
    }
    return ''
}

function Get-DomeniaTaskReaderIdentity {
    # Point 12: the account part of a shared read. The reader named by the caller (else the directory bind account),
    # the process identity and the account generation: any change of the workstation, secrets or alternate accounts
    # increments that generation, so a read prepared with another account is never joined.
    param([AllowEmptyString()][string]$Reader='',[AllowEmptyString()][string]$BindUser='',[AllowEmptyString()][string]$ProcessIdentity='',[long]$AccountGeneration=0)
    $name = ([string]$Reader).Trim()
    if (-not $name) { $name = ([string]$BindUser).Trim() }
    return ($name.ToLowerInvariant() + '|' + ([string]$ProcessIdentity).Trim().ToLowerInvariant() + '|comptes=' + [string]$AccountGeneration)
}

function Get-DomeniaTaskRequirements {
    # Point 12: what the caller requires from the read besides its payload. A read waiting for 60 s never joins a
    # read allowed 10 s, and a request for the isolated helper never joins an in-process read.
    param([int]$TimeoutSeconds=0,[int]$HardTimeoutSeconds=0,[bool]$NonCancellable=$false,[AllowEmptyString()][string]$TaskClass='')
    return ('delai=' + [string]$TimeoutSeconds + ';total=' + [string]$HardTimeoutSeconds + ';protege=' + [string][bool]$NonCancellable + ';classe=' + [string]$TaskClass)
}

function Get-DomeniaTaskDedupKey {
    # Two reads may share one worker only when everything that decides their result is identical: operation, target
    # and request (payload), account (reader identity), context (session, generation) and requirements.
    param([Parameter(Mandatory=$true)][string]$OperationId,[string]$ReaderIdentity='',[long]$Epoch=0,[long]$Generation=0,$Payload=$null,[bool]$IsWrite=$false,[string[]]$Shareable=@(),[string]$Requirements='')
    if ($IsWrite) { return '' }
    # Shareable reads carry the flag Shared in the operation table (Get-DomeniaOperationTable); a caller may add its own.
    $row = Get-DomeniaOperationRow $OperationId
    $shared = (($null -ne $row) -and ([bool]$row.Shareable))
    if ((-not $shared) -and (@($Shareable) -notcontains $OperationId)) { return '' }
    $digest = Get-DomeniaPayloadDigest $Payload
    if (-not $digest) { return '' }
    return (Get-DomeniaTextHash ($OperationId + '|' + $ReaderIdentity + '|' + $Epoch + '|' + $Generation + '|' + $digest + '|' + $Requirements))
}

function Test-DomeniaTaskAdmission {
    # Decides whether a request starts now, waits in the bounded queue, or is refused.
    # FI-03: reads (Selection, Background) stop at MaxOutstanding physical workers. An explicit action has one
    # reserved physical place above that cap and a write one more: detached reads never refuse a write.
    # Point 16: background work that waited AgingSeconds while no other background work runs may take one of the
    # reserved places (never above MaxConcurrent): a long background campaign keeps progressing under load.
    # BackgroundRunning -1 means unknown: no aging.
    param(
        [Parameter(Mandatory=$true)][string]$Class,
        [int]$Running=0,[int]$Outstanding=0,[int]$MaxConcurrent=6,[int]$MaxOutstanding=12,
        [int]$Queued=0,[int]$MaxQueued=32,[int]$ReservedForeground=2,
        [double]$WaitedSeconds=0,[int]$BackgroundRunning=-1,[int]$AgingSeconds=30
    )
    $reserved = [Math]::Max(0,[Math]::Min($ReservedForeground,$MaxConcurrent - 1))
    $physical = $MaxOutstanding
    if ($Class -eq 'Explicit') { $physical = $MaxOutstanding + 1 }
    if ($Class -eq 'Write') { $physical = $MaxOutstanding + 2 }
    if ($Outstanding -ge $physical) {
        if ($Class -ne 'Write' -and $Queued -lt $MaxQueued) { return [pscustomobject]@{Decision='Queue';Reason='Workers encore actifs ou en nettoyage : attente de leur liberation reelle.'} }
        return [pscustomobject]@{Decision='Reject';Reason='Limite physique atteinte : des workers restent actifs ou en nettoyage.'}
    }
    $startReason = ''
    if ($Class -eq 'Write' -and $Outstanding -ge $MaxOutstanding) { $startReason = 'Des lectures se terminent ; lʼécriture partira dans un instant.' }
    $limit = $MaxConcurrent
    if ($Class -eq 'Background') { $limit = $MaxConcurrent - $reserved }
    # A write is never starved by reads: it may use one slot above the read limit.
    if ($Class -eq 'Write') { $limit = $MaxConcurrent + 1 }
    if ($Running -lt $limit) { return [pscustomobject]@{Decision='Start';Reason=$startReason} }
    if (($Class -eq 'Background') -and (Test-DomeniaBackgroundAgingDue -WaitedSeconds $WaitedSeconds -BackgroundRunning $BackgroundRunning -AgingSeconds $AgingSeconds) -and ($Running -lt $MaxConcurrent)) {
        return [pscustomobject]@{Decision='Start';Reason=('Travail de fond en attente depuis ' + [string][int]$WaitedSeconds + ' s : une place lui est accordée pour quʼil progresse.');Aged=$true}
    }
    if ($Class -eq 'Write') { return [pscustomobject]@{Decision='Reject';Reason='Moteur sature : aucune ecriture mise en attente silencieuse.'} }
    if ($Queued -lt $MaxQueued) {
        $why = 'Lectures en cours : demande placee en attente.'
        if ($Class -eq 'Background') { $why = 'Places reservees aux actions explicites : travail de fond en attente.' }
        return [pscustomobject]@{Decision='Queue';Reason=$why}
    }
    return [pscustomobject]@{Decision='Reject';Reason='File d attente pleine : aucune nouvelle lecture acceptee.'}
}

function Test-DomeniaBackgroundAgingDue {
    # Point 16: true when background work waited long enough and no other background work holds a place.
    param([double]$WaitedSeconds=0,[int]$BackgroundRunning=-1,[int]$AgingSeconds=30)
    if (($BackgroundRunning -ne 0) -or ($AgingSeconds -le 0)) { return $false }
    return ($WaitedSeconds -ge $AgingSeconds)
}

function Get-DomeniaQueuedSeconds {
    # Seconds spent in the queue; QueuedAt is the local time of Start-UiTask. 0 when unknown.
    param($Task,[datetime]$Now=(Get-Date))
    $queuedAt = Get-DomeniaMember $Task 'QueuedAt' $null
    if ($null -eq $queuedAt) { return [double]0 }
    try { return [Math]::Max([double]0,($Now - [datetime]$queuedAt).TotalSeconds) } catch { return [double]0 }
}

function Select-DomeniaNextQueuedTask {
    # Returns the queued task that may start now, or $null (see Select-DomeniaNextQueuedEntry).
    param([object[]]$Queued,[int]$Running=0,[int]$Outstanding=0,[int]$MaxConcurrent=6,[int]$MaxOutstanding=12,[int]$ReservedForeground=2,
        $ProviderLoad=$null,$ProviderState=$null,[datetime]$NowUtc=[datetime]::UtcNow,
        [int]$BackgroundRunning=-1,[int]$AgingSeconds=30,[datetime]$Now=(Get-Date),$SourceLoad=$null)
    $entry = Select-DomeniaNextQueuedEntry -Queued $Queued -Running $Running -Outstanding $Outstanding -MaxConcurrent $MaxConcurrent -MaxOutstanding $MaxOutstanding -ReservedForeground $ReservedForeground -ProviderLoad $ProviderLoad -ProviderState $ProviderState -NowUtc $NowUtc -BackgroundRunning $BackgroundRunning -AgingSeconds $AgingSeconds -Now $Now -SourceLoad $SourceLoad
    if ($null -eq $entry) { return $null }
    return $entry.Task
}

function Select-DomeniaNextQueuedEntry {
    # Returns {Task; Aged} for the queued task that may start now, or $null. Priority first, then arrival order.
    # MO-05: with -ProviderLoad (running workers per provider), a candidate whose provider is saturated or paused
    # is skipped and stays queued; a durable refusal (rejected account) is returned so that its start reports it.
    # Point 16: with -BackgroundRunning 0, the oldest background entry that waited AgingSeconds goes first; it may take
    # one reserved place and start above its provider or site budget (never on a paused source). Aged says that it
    # started only thanks to its wait, so that the dispatch applies the same exception and the start is counted.
    # Points 15 and 160: -SourceLoad counts running workers per 'Provider|target' and 'Provider|group:<g>'.
    param([object[]]$Queued,[int]$Running=0,[int]$Outstanding=0,[int]$MaxConcurrent=6,[int]$MaxOutstanding=12,[int]$ReservedForeground=2,
        $ProviderLoad=$null,$ProviderState=$null,[datetime]$NowUtc=[datetime]::UtcNow,
        [int]$BackgroundRunning=-1,[int]$AgingSeconds=30,[datetime]$Now=(Get-Date),$SourceLoad=$null)
    $candidates = @(@($Queued) | Where-Object { $null -ne $_ })
    if (-not $candidates.Count) { return $null }
    $ordered = @(Get-DomeniaTaskOrder -Jobs $candidates)
    if ($BackgroundRunning -eq 0) {
        $aged = @($ordered | Where-Object { ([string](Get-DomeniaMember $_ 'Class' 'Background') -eq 'Background') -and (Test-DomeniaBackgroundAgingDue -WaitedSeconds (Get-DomeniaQueuedSeconds $_ $Now) -BackgroundRunning 0 -AgingSeconds $AgingSeconds) } | Select-Object -First 1)
        if ($aged.Count) { $ordered = @($aged) + @($ordered | Where-Object { -not [object]::ReferenceEquals($_,$aged[0]) }) }
    }
    foreach ($task in $ordered) {
        $class = [string](Get-DomeniaMember $task 'Class' 'Background')
        $waited = Get-DomeniaQueuedSeconds $task $Now
        $agingDue = (($class -eq 'Background') -and (Test-DomeniaBackgroundAgingDue -WaitedSeconds $waited -BackgroundRunning $BackgroundRunning -AgingSeconds $AgingSeconds))
        $decision = Test-DomeniaTaskAdmission -Class $class -Running $Running -Outstanding $Outstanding -MaxConcurrent $MaxConcurrent -MaxOutstanding $MaxOutstanding -Queued 0 -MaxQueued 1 -ReservedForeground $ReservedForeground -WaitedSeconds $waited -BackgroundRunning $BackgroundRunning -AgingSeconds $AgingSeconds
        if ($decision.Decision -ne 'Start') { continue }
        $startedByAge = [bool](Get-DomeniaMember $decision 'Aged' $false)
        if ($null -ne $ProviderLoad) {
            $provider = [string](Get-DomeniaMember $task 'Provider' '')
            if ($provider) {
                $busy = 0
                if (($ProviderLoad -is [Collections.IDictionary]) -and $ProviderLoad.Contains($provider)) { $busy = [int]$ProviderLoad[$provider] }
                $target = [string](Get-DomeniaMember $task 'ProviderTarget' '')
                $group = [string](Get-DomeniaMember $task 'ProviderGroup' '')
                $forTarget = -1; $forGroup = -1
                if ($SourceLoad -is [Collections.IDictionary]) {
                    $targetKey = Get-DomeniaProviderStateKey $provider $target
                    $forTarget = 0; if ($SourceLoad.Contains($targetKey)) { $forTarget = [int]$SourceLoad[$targetKey] }
                    if ($group) { $groupKey = Get-DomeniaProviderStateKey $provider ('group:' + $group); $forGroup = 0; if ($SourceLoad.Contains($groupKey)) { $forGroup = [int]$SourceLoad[$groupKey] } }
                }
                $budget = Test-DomeniaProviderAdmission -State $ProviderState -Provider $provider -Target $target -Class $class -RunningForProvider $busy -NowUtc $NowUtc -Group $group -RunningForTarget $forTarget -RunningForGroup $forGroup -Aged $agingDue
                if ((-not [bool]$budget.Allowed) -and (-not [bool](Get-DomeniaMember $budget 'Durable' $false))) { continue }
                if ([bool](Get-DomeniaMember $budget 'Aged' $false)) { $startedByAge = $true }
            }
        }
        return [pscustomobject]@{Task=$task;Aged=$startedByAge}
    }
    return $null
}

function Test-DomeniaForegroundTaskClass {
    # CO-02: the classes the operator waits for. Only they drive Annuler, the progress label and LatestTaskId.
    param([string]$Class)
    return ($Class -in @('Write','Explicit','Selection'))
}

function Get-DomeniaTaskOrder {
    # PF-04: completions and promotions are handled by class priority (Write, Explicit, Selection, Background),
    # then in arrival order, so that the record the operator clicked never waits behind background probes.
    param([object[]]$Jobs=@())
    return @(@($Jobs) | Where-Object { $null -ne $_ } | Sort-Object @{Expression={ Get-DomeniaTaskPriority ([string](Get-DomeniaMember $_ 'Class' 'Background')) }},@{Expression={ [long](Get-DomeniaMember $_ 'Sequence' 0) }})
}

# ---------------------------------------------------------------- PF-06 heartbeat schedule
function Test-DomeniaPulseDue {
    # A subscriber runs when it is due, or due within a quarter of its interval (100 ms at most): nearby
    # subscribers share one wake-up instead of waking the Dispatcher one after the other.
    param($Subscriber,[double]$NowMs=0,[bool]$Hidden=$false)
    if ($null -eq $Subscriber -or -not [bool](Get-DomeniaMember $Subscriber 'Enabled' $false)) { return $false }
    if ($Hidden -and -not [bool](Get-DomeniaMember $Subscriber 'RunWhenHidden' $false)) { return $false }
    $interval = [double](Get-DomeniaMember $Subscriber 'IntervalMs' 0)
    $tolerance = [Math]::Min(100.0,[Math]::Max(0.0,$interval / 4.0))
    return (([double](Get-DomeniaMember $Subscriber 'DueMs' 0) - $NowMs) -le $tolerance)
}

function Get-DomeniaPulseDelay {
    # Delay in milliseconds until the next subscriber is due, or -1 when nothing is enabled (the heartbeat stops).
    # A minimized or hidden window keeps only the subscribers marked RunWhenHidden (tasks, saves).
    param([object[]]$Subscribers=@(),[double]$NowMs=0,[bool]$Hidden=$false,[int]$MinimumMs=15)
    $next = [double]::MaxValue
    foreach ($subscriber in @($Subscribers)) {
        if ($null -eq $subscriber -or -not [bool](Get-DomeniaMember $subscriber 'Enabled' $false)) { continue }
        if ($Hidden -and -not [bool](Get-DomeniaMember $subscriber 'RunWhenHidden' $false)) { continue }
        $due = [double](Get-DomeniaMember $subscriber 'DueMs' 0)
        if ($due -lt $next) { $next = $due }
    }
    if ($next -eq [double]::MaxValue) { return -1 }
    return [int][Math]::Max([double][Math]::Max(1,$MinimumMs),[Math]::Ceiling($next - $NowMs))
}

# ---------------------------------------------------------------- D017 cancellation states
function Get-DomeniaTaskState {
    # Exact state of one engine job. A job whose native call is still alive is never reported as finished.
    param($Job,[bool]$Detached=$false)
    if ($null -eq $Job) { return 'Completed' }
    if ($Detached) {
        # Same rule as Complete-DomeniaDetachedReadJobs: the invocation AND the stop request must both be
        # finished. An absent stop handle counts as finished.
        $invokeDone = $false; $stopDone = $true
        try { $handle = Get-DomeniaMember $Job 'Handle' $null; if ($null -ne $handle) { $invokeDone = [bool]$handle.IsCompleted } else { $invokeDone = $true } } catch { $invokeDone = $false }
        try { $stop = Get-DomeniaMember $Job 'StopHandle' $null; if ($null -ne $stop) { $stopDone = [bool]$stop.IsCompleted } } catch { $stopDone = $false }
        if ($invokeDone -and $stopDone) { return 'Completed' }
        return 'Cleanup'
    }
    if ([string](Get-DomeniaMember $Job 'State' '') -eq 'Queued') { return 'Queued' }
    if ([bool](Get-DomeniaMember $Job 'CancelRequested' $false)) { return 'StopRequested' }
    return 'Running'
}

function Get-DomeniaTaskStateSummary {
    param([object[]]$Jobs=@(),[object[]]$Detached=@())
    $counts = @{Queued=0;Running=0;StopRequested=0;Cleanup=0}
    foreach ($job in @($Jobs)) { if ($null -ne $job) { $state = Get-DomeniaTaskState $job; if ($counts.ContainsKey($state)) { $counts[$state]++ } } }
    foreach ($job in @($Detached)) { if ($null -ne $job) { $state = Get-DomeniaTaskState $job $true; if ($counts.ContainsKey($state)) { $counts[$state]++ } } }
    # Active = everything that still holds a thread, a handle or a pending native call.
    $active = $counts.Running + $counts.StopRequested + $counts.Cleanup
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($counts.Running) { $parts.Add([string]$counts.Running + ' en cours') }
    if ($counts.Queued) { $parts.Add([string]$counts.Queued + ' en attente') }
    if ($counts.StopRequested) { $parts.Add([string]$counts.StopRequested + ' arret demande') }
    if ($counts.Cleanup) { $parts.Add([string]$counts.Cleanup + ' nettoyage') }
    $text = 'Aucune tache'
    if ($parts.Count) { $text = $parts.ToArray() -join ' · ' }
    return [pscustomobject]@{Queued=$counts.Queued;Running=$counts.Running;StopRequested=$counts.StopRequested;Cleanup=$counts.Cleanup;Active=$active;Total=($active + $counts.Queued);Text=$text}
}

function Get-DomeniaCancelStatusText {
    param([string]$Name,[Parameter(Mandatory=$true)][string]$State,[bool]$IsWrite=$false)
    if ($IsWrite) { return ('Ecriture ' + $Name + ' : non annulable apres envoi. Attente de la relecture de verification.') }
    switch ($State) {
        'Queued' { return ('Demande retiree de la file avant tout envoi : ' + $Name + '.') }
        'StopRequested' { return ('Arret demande : ' + $Name + '. La lecture est encore active.') }
        'Cleanup' { return ('Lecture detachee de l interface : ' + $Name + '. Son appel natif reste compte jusqu a sa fin reelle.') }
        'Completed' { return ('Lecture arretee : ' + $Name + '.') }
        default { return ('Lecture en cours : ' + $Name + '.') }
    }
}

# ---------------------------------------------------------------- P-CD-07 one declarative table of the operations
function Get-DomeniaOperationTable {
    # P-CD-07: the single classification of the operation identifiers, read once per session (cache). One line per
    # identifier, OperationId|Worker|Provider|Effect|Class|Accounts|Resource|Flags; # starts a comment.
    #   Worker   Pinned: body pinned in the closed worker registry (tools/operation-contracts.json, one line each);
    #            Unpinned: named by the access, safety, storage or assistance rules without a pinned body of its own.
    #   Provider budget of the scheduler (D018): Directory, Cim, Wts, Storage, Local or Network.
    #   Effect   Read, LocalWrite, DirectoryWrite (every Write<Name>, granted by the name only), RemoteMutation, or
    #            Unknown: never treated as a read (fail closed).
    #   Class    scheduling class without a hint (D015): Explicit, Selection or Background; Selection:<key> is Selection
    #            for that replace key only, Explicit otherwise.
    #   Accounts what the worker receives (C3): Directory (directory channel and account), Remote (remote target and
    #            its account), Machine (workstation account), Bind (directory account without the channel); - none.
    #   Resource protected resource of its account (D051): Directory, Laps, BitLocker, Remote, Network or Local.
    #   Flags    Shared (an identical read joins the running one, point 12), Pool (prepared runspace pool, PF-05),
    #            Isolable (may run in the bounded helper process, D016); - none.
    # Get-DomeniaOperationProvider, Get-DomeniaOperationCredentialNeeds, Get-DomeniaTaskClass, Get-DomeniaTaskDedupKey,
    # Get-DomeniaIsolationDecision, Get-DomeniaOperationEffect (Safety.Model), Get-DomeniaOperationResource
    # (Access.Model) and the runspace pools of the core read it; tests/rules/Engine.Tests.ps1 keeps it equal to the
    # registry and to the answers of the former lists. A new operation is declared here, on one line.
    $cached = Get-Variable -Name DomeniaOperationTable -Scope Script -ErrorAction SilentlyContinue
    if (($null -ne $cached) -and ($null -ne $cached.Value)) { return $cached.Value }
    $text = @'
# Pinned operations of the closed worker registry (tools/operation-contracts.json), one line each.
AccountAliasRead       |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|-
AdConsistencyScan      |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
AdHealthRead           |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
AdSchemaRead           |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
# BatchNetworkDiag: remote actions are budgeted per target with the CIM provider: an outage never slows the directory.
BatchNetworkDiag       |Pinned  |Cim      |Read          |Explicit        |Remote                  |Remote   |-
# BitLockerPresence: lot L01: recovery objects of one OU, Secrets account, refusals kept on the BitLocker resource.
BitLockerPresence      |Pinned  |Directory|Unknown       |Explicit        |Directory               |BitLocker|-
CmdletHelp             |Pinned  |Local    |Read          |Explicit        |-                       |Local    |-
CmdletInventory        |Pinned  |Local    |Read          |Explicit        |-                       |Local    |-
ComputerAdminShare     |Pinned  |Network  |Read          |Explicit        |Remote,Machine          |Remote   |-
ComputerDiagnostics    |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |Isolable
ComputerGpUpdate       |Pinned  |Cim      |RemoteMutation|Explicit        |Remote,Machine          |Remote   |-
ComputerInventory      |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |Isolable
# ComputerLastUser: a CIM read that also queries LDAP (so does LiveConsole): a provider is not a credential rule.
ComputerLastUser       |Pinned  |Cim      |Read          |Explicit        |Directory,Remote,Machine|Remote   |-
ComputerPing           |Pinned  |Network  |Read          |Explicit        |Remote                  |Remote   |Pool,Isolable
ComputerRestart        |Pinned  |Cim      |RemoteMutation|Explicit        |Remote,Machine          |Remote   |-
# ComputerServiceControl: UX-38 (X04): starts or restarts one service of the selected workstation through CIM.
ComputerServiceControl |Pinned  |Cim      |RemoteMutation|Explicit        |Remote,Machine          |Remote   |-
# DcServicesRead: points 105, 108 and 109 (also GpoAppliedRead, MachineIdentityRead): a computer read by CIM only.
DcServicesRead         |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |Shared
DelegationRead         |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
# DemoDirectory: answers every read in demonstration (in-memory directory, no network): pooled like the reads.
DemoDirectory          |Pinned  |Local    |Read          |Explicit        |-                       |Local    |Pool
DirectoryAbsenceCheck  |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
DocumentStore          |Pinned  |Storage  |LocalWrite    |Explicit        |-                       |Local    |-
DomainOverview         |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|-
EmbeddedDirectoryLookup|Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
EmbeddedPathBrowse     |Pinned  |Local    |Read          |Explicit        |-                       |Local    |-
EngineSelfTest         |Pinned  |Local    |Read          |Explicit        |-                       |Local    |-
GlobalSearch           |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Pool
GpoAppliedRead         |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |Shared
GpoLinksRead           |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
GroupPathRead          |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
IndexBuild             |Pinned  |Directory|LocalWrite    |Explicit        |Directory               |Directory|-
IndexOuList            |Pinned  |Directory|Unknown       |Explicit        |Directory               |Directory|-
IsolatedRead           |Pinned  |Local    |Unknown       |Explicit        |-                       |Local    |-
LegacyMigration        |Pinned  |Storage  |Unknown       |Explicit        |-                       |Local    |-
LiveCache              |Pinned  |Storage  |LocalWrite    |Background      |-                       |Local    |Pool
# LiveConsole: same pinned body as LiveSelectedPing, chosen by a check box after a selection.
LiveConsole            |Pinned  |Cim      |Read          |Selection       |Directory,Remote,Machine|Remote   |Pool
LiveDirectoryCheck     |Pinned  |Directory|Read          |Background      |Directory               |Directory|Pool
LiveSelectedPing       |Pinned  |Network  |Read          |Selection       |-                       |Network  |Pool
LocalIndexRead         |Pinned  |Storage  |Unknown       |Explicit        |-                       |Local    |Pool
LocalQuery             |Pinned  |Storage  |Unknown       |Explicit        |-                       |Local    |Pool
LocalStore             |Pinned  |Storage  |LocalWrite    |Background      |-                       |Local    |Pool
LockoutDiagnosis       |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
LogonByDcRead          |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
LogonHarvest           |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|-
MachineIdentityRead    |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |Shared
# OfflineDossier: point 139: reads the base read-only and writes in Exports; it never holds the storage lane.
OfflineDossier         |Pinned  |Local    |LocalWrite    |Explicit        |-                       |Local    |-
# OpenAdObject: Selection for the replace key of the selected object only, Explicit otherwise.
OpenAdObject           |Pinned  |Directory|Read          |Selection:object|Directory               |Directory|Shared,Pool
OpenLinkedObject       |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|-
# ParkPing: MO-08: ICMP echoes of a list in parallel batches, network only, no credential.
ParkPing               |Pinned  |Network  |Read          |Explicit        |-                       |Network  |-
# ParkSharedSync: reads and writes a shared file, possibly on a UNC path: network I/O, not the local base.
ParkSharedSync         |Pinned  |Network  |Unknown       |Background      |-                       |Network  |-
ParkSweep              |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |-
PasswordPolicyRead     |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Shared
PermissionAnalysis     |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|-
PresenceScan           |Pinned  |Network  |Read          |Background      |Directory               |Network  |-
PruneLinks             |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|-
QueryExport            |Pinned  |Storage  |Unknown       |Explicit        |-                       |Local    |-
QueryLibrary           |Pinned  |Storage  |Unknown       |Explicit        |-                       |Local    |-
QueryTransfer          |Pinned  |Storage  |Unknown       |Explicit        |-                       |Local    |-
ReadBitLocker          |Pinned  |Directory|Read          |Explicit        |Directory               |BitLocker|-
ReadBitLockerKey       |Pinned  |Directory|Read          |Explicit        |Directory               |BitLocker|-
# ReadBitLockerList: D058: ReadBitLockerList and ReadBitLockerKey read BitLocker exactly like ReadBitLocker.
ReadBitLockerList      |Pinned  |Directory|Unknown       |Explicit        |Directory               |BitLocker|-
ReadLaps               |Pinned  |Directory|Read          |Explicit        |Directory               |Laps     |-
# ReceiptStore: records the bind identity of a write: the directory account, without the directory channel.
ReceiptStore           |Pinned  |Storage  |LocalWrite    |Background      |Bind                    |Local    |-
# RelationHistoryRead: point 107: stored history of the relations, read from the local base only.
RelationHistoryRead    |Pinned  |Storage  |Read          |Explicit        |-                       |Local    |Shared
RemoteCredentialCheck  |Pinned  |Cim      |Read          |Explicit        |Directory               |Remote   |-
RimotteRun             |Pinned  |Cim      |RemoteMutation|Explicit        |Remote,Machine          |Remote   |-
ScopeReconcile         |Pinned  |Directory|Read          |Background      |Directory               |Directory|-
SelectedPresence       |Pinned  |Network  |Read          |Selection       |Directory               |Network  |Pool
SelfCheck              |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|-
# SessionsList: remote and machine account (formerly also listed as local, which changed no answer).
SessionsList           |Pinned  |Wts      |Read          |Explicit        |Remote,Machine          |Remote   |Shared
SoftwareInventory      |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |Isolable
StartupWarmCache       |Pinned  |Directory|Read          |Background      |Directory               |Directory|-
StorageBackup          |Pinned  |Storage  |LocalWrite    |Explicit        |-                       |Local    |-
StorageIntegrity       |Pinned  |Storage  |Read          |Explicit        |-                       |Local    |-
StorageMaintenance     |Pinned  |Storage  |LocalWrite    |Explicit        |-                       |Local    |-
StoragePurge           |Pinned  |Storage  |LocalWrite    |Explicit        |-                       |Local    |-
StorageUsage           |Pinned  |Storage  |Read          |Explicit        |-                       |Local    |-
TreeChildren           |Pinned  |Directory|Read          |Explicit        |Directory               |Directory|Pool,Isolable
UserComputerProbe      |Pinned  |Cim      |Read          |Explicit        |Directory,Machine       |Remote   |-
WmiClasses             |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |Isolable
WmiNamespaces          |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |Isolable
WmiQuery               |Pinned  |Cim      |Read          |Explicit        |Remote,Machine          |Remote   |Isolable
WriteAccountDisabled   |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteAccountOptions    |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteAttributes        |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteCreateOu          |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteDeleteObject      |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteExpiration        |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteExpirePassword    |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteGroupMember       |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteMoveObject        |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteObjectGroup       |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteRenameComputer    |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteResetPassword     |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
WriteUnlock            |Pinned  |Directory|DirectoryWrite|Explicit        |Directory               |Directory|-
# Identifiers without a pinned body of their own, named by the access, safety, storage or assistance rules.
ComputerEventsRead     |Unpinned|Cim      |Read          |Explicit        |Directory               |Directory|Shared
ComputerQuickDiag      |Unpinned|Cim      |Read          |Explicit        |Directory               |Directory|Shared
ConnectorRead          |Unpinned|Network  |Read          |Explicit        |Directory               |Network  |-
DcCompareRead          |Unpinned|Directory|Read          |Explicit        |Directory               |Directory|Shared
IndexRefresh           |Unpinned|Directory|LocalWrite    |Explicit        |Directory               |Directory|-
JoinStateRead          |Unpinned|Cim      |Read          |Explicit        |Directory               |Directory|Shared
LinkHistoryStore       |Unpinned|Storage  |LocalWrite    |Explicit        |Directory               |Directory|-
LocalAssistant         |Unpinned|Local    |Unknown       |Explicit        |Directory               |Directory|-
ObjectChanges          |Unpinned|Directory|Read          |Explicit        |Directory               |Directory|-
# QuerySchema: launched by the query editor, not pinned yet (known debt, PendingPins of Test-DomeniaCollectCircuit).
QuerySchema            |Unpinned|Cim      |Read          |Explicit        |Remote,Machine          |Remote   |-
ReconcileScope         |Unpinned|Directory|Read          |Explicit        |Directory               |Directory|-
StartupWarmup          |Unpinned|Directory|Read          |Explicit        |Directory               |Directory|-
# StorageRetention: launched by the storage assistant, not pinned yet (known debt, PendingPins of Test-DomeniaCollectCircuit).
StorageRetention       |Unpinned|Storage  |LocalWrite    |Explicit        |-                       |Local    |-
UpdateStateRead        |Unpinned|Cim      |Read          |Explicit        |Directory               |Directory|Shared
WakeOnLanSend          |Unpinned|Network  |RemoteMutation|Explicit        |Directory               |Network  |-
'@
    $table = @{}
    foreach ($raw in ($text -split "`n")) {
        $line = $raw
        $comment = $line.IndexOf('#')
        if ($comment -ge 0) { $line = $line.Substring(0,$comment) }
        $line = $line.Trim()
        if (-not $line) { continue }
        $cells = @($line.Split('|') | ForEach-Object { $_.Trim() })
        if ($cells.Count -ne 8) { throw ('Table des opérations : ligne illisible <' + $line + '>.') }
        $id = $cells[0]
        if ($id -cnotmatch '^[A-Za-z][A-Za-z0-9]{2,63}$') { throw ('Table des opérations : identifiant invalide <' + $id + '>.') }
        if ($table.ContainsKey($id)) { throw ('Table des opérations : ' + $id + ' déclarée deux fois.') }
        $accounts = @(); if ($cells[5] -cne '-') { $accounts = @($cells[5].Split(',')) }
        $flags = @(); if ($cells[7] -cne '-') { $flags = @($cells[7].Split(',')) }
        $valid = (($cells[1] -cin @('Pinned','Unpinned')) -and ($cells[2] -cin @('Directory','Cim','Wts','Storage','Local','Network')) -and
            ($cells[3] -cin @('Read','LocalWrite','DirectoryWrite','RemoteMutation','Unknown')) -and ($cells[4] -cmatch '^(Explicit|Selection|Background|Selection:[A-Za-z]+)$') -and
            ($cells[6] -cin @('Directory','Laps','BitLocker','Remote','Network','Local')) -and
            (@($accounts | Where-Object { $_ -cnotin @('Directory','Remote','Machine','Bind') }).Count -eq 0) -and
            (@($flags | Where-Object { $_ -cnotin @('Shared','Pool','Isolable') }).Count -eq 0))
        if (-not $valid) { throw ('Table des opérations : valeur inconnue pour ' + $id + '.') }
        $table[$id] = [pscustomobject]@{
            OperationId=$id; Pinned=($cells[1] -ceq 'Pinned'); Provider=$cells[2]; Effect=$cells[3]; Class=$cells[4]
            Accounts=[string[]]$accounts; Resource=$cells[6]
            Shareable=($flags -ccontains 'Shared'); Pooled=($flags -ccontains 'Pool'); Isolable=($flags -ccontains 'Isolable')
        }
    }
    $script:DomeniaOperationTable = $table
    return $table
}

function Get-DomeniaOperationRow {
    # The table row of one identifier, matched without regard to case like the former lists; $null when it is unknown.
    param([AllowEmptyString()][AllowNull()][string]$OperationId)
    $table = Get-DomeniaOperationTable
    $id = [string]$OperationId
    if ($table.ContainsKey($id)) { return $table[$id] }
    return $null
}

# ---------------------------------------------------------------- D018 provider budgets
function Get-DomeniaOperationProvider {
    # Provider budget of the operation in the table (Get-DomeniaOperationTable); an unknown identifier is a directory read.
    param([Parameter(Mandatory=$true)][string]$OperationId)
    $row = Get-DomeniaOperationRow $OperationId
    if ($null -eq $row) { return 'Directory' }
    return [string]$row.Provider
}

function Get-DomeniaOperationCredentialNeeds {
    # C3. Credential semantics of one operation, identical to the historical lists of Get-WorkerContext:
    # which account the worker receives, and whether a rejected logon may suspend the directory channel.
    # A provider is not a credential rule: ComputerLastUser and LiveConsole are CIM reads that also query LDAP.
    # P-CD-07: the accounts and the resource come from the operation table (Get-DomeniaOperationTable); an unknown
    # identifier is a directory read with the directory account.
    param([string]$OperationId)
    $id = [string]$OperationId
    $accounts = @('Directory'); $resource = 'Directory'
    $row = Get-DomeniaOperationRow $id
    if ($null -ne $row) { $accounts = @($row.Accounts); $resource = [string]$row.Resource }
    $directory = ($accounts -contains 'Directory')
    $isRemote = ($accounts -contains 'Remote')
    $machine = ($accounts -contains 'Machine')
    return [pscustomobject]@{
        OperationId=$id
        # The worker needs the directory channel (circuit breaker and AD account apply).
        Directory=$directory
        # The worker receives the AD account (ReceiptStore records the bind identity of a write: Bind).
        DirectoryCredential=($directory -or ($accounts -contains 'Bind'))
        Remote=$isRemote
        Machine=$machine
        RemoteAdmin=($isRemote -or $machine)
        Secrets=($resource -in @('Laps','BitLocker'))
        # A remote read never binds to the directory, unless it also reads it (ComputerLastUser, LiveConsole).
        NonDirectory=($isRemote -or (-not $directory))
        # A rejected logon suspends the AD channel only when the rejected account can be the AD account.
        DirectoryBreaker=($directory -and (-not $isRemote))
        Provider=(Get-DomeniaOperationProvider $id)
        Resource=$resource
    }
}

function ConvertTo-DomeniaProviderOutcome {
    # Maps the end of one worker to the outcome recorded for its provider budget (D018).
    param([string]$ErrorKind='',[bool]$Cancelled=$false,[bool]$TimedOut=$false,[bool]$Failed=$false)
    if ($Cancelled) { return 'Cancelled' }
    if ($TimedOut) { return 'Timeout' }
    if (-not $Failed) { return 'Success' }
    if ($ErrorKind -in @('LogonFailure','AccountLocked','AccountUnavailable','CredentialPaused')) { return 'CredentialRejected' }
    if ($ErrorKind -eq 'AccessDenied') { return 'AccessDenied' }
    return 'Failure'
}

function Test-DomeniaQueuedTaskExpired {
    # A queued read that waited too long is withdrawn before any call: nothing was sent.
    param($QueuedAt,[int]$MaxWaitSeconds=120,[datetime]$Now=(Get-Date))
    if ($null -eq $QueuedAt) { return $false }
    try { return (($Now - [datetime]$QueuedAt).TotalSeconds -gt [Math]::Max(5,$MaxWaitSeconds)) } catch { return $false }
}

function Get-DomeniaIsolationDecision {
    # D016. A read may run in a bounded helper process only when the switch is on, it is not a write, its
    # payload is plain data, no credential object would have to cross the process boundary and the operation
    # is reviewed for it (flag Isolable). Stopping the helper can therefore never touch a write or the GUI.
    param([string]$OperationId,[bool]$Enabled=$false,[bool]$IsWrite=$false,[bool]$HasCredential=$false,[string]$PayloadDigest='',[bool]$DemoMode=$false)
    if (-not $Enabled) { return [pscustomobject]@{Isolate=$false;Reason='Lectures isolees desactivees (Features.IsolatedReads).'} }
    if ($IsWrite) { return [pscustomobject]@{Isolate=$false;Reason='Une ecriture n est jamais confiee au processus auxiliaire.'} }
    if ($DemoMode) { return [pscustomobject]@{Isolate=$false;Reason='Demonstration : aucun processus auxiliaire.'} }
    # The reviewed list is the flag Isolable of the operation table (Get-DomeniaOperationTable).
    $row = Get-DomeniaOperationRow ([string]$OperationId)
    if (($null -eq $row) -or (-not [bool]$row.Isolable)) { return [pscustomobject]@{Isolate=$false;Reason='Operation non retenue pour l isolement.'} }
    if ($HasCredential) { return [pscustomobject]@{Isolate=$false;Reason='Un compte explicite ne traverse jamais la frontiere du processus.'} }
    if (-not $PayloadDigest) { return [pscustomobject]@{Isolate=$false;Reason='Charge utile vivante : lecture conservee dans le moteur.'} }
    return [pscustomobject]@{Isolate=$true;Reason='Lecture isolee dans un processus auxiliaire borne.'}
}

function Get-DomeniaProviderBudget {
    # Point 15: MaxPerGroup bounds the background reads of one controller or presumed subnet, so that one slow site
    # never takes every place of its provider. GroupFailureThreshold consecutive time-outs suspend that site only.
    # Every directory read of a session goes to the controller of the connection: its controller budget equals the
    # provider budget (no hidden reduction), and the group only adds the pause of that controller.
    param([Parameter(Mandatory=$true)][string]$Provider)
    switch ($Provider) {
        'Directory' { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=4;TimeoutSeconds=30;FailureThreshold=3;BackoffSeconds=20;MaxBackoffSeconds=300;MaxPerGroup=4;GroupFailureThreshold=3} }
        'Cim'       { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=3;TimeoutSeconds=25;FailureThreshold=2;BackoffSeconds=60;MaxBackoffSeconds=600;MaxPerGroup=2;GroupFailureThreshold=3} }
        'Wts'       { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=2;TimeoutSeconds=20;FailureThreshold=2;BackoffSeconds=60;MaxBackoffSeconds=600;MaxPerGroup=1;GroupFailureThreshold=3} }
        'Storage'   { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=1;TimeoutSeconds=30;FailureThreshold=3;BackoffSeconds=15;MaxBackoffSeconds=120;MaxPerGroup=1;GroupFailureThreshold=0} }
        'Network'   { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=4;TimeoutSeconds=10;FailureThreshold=3;BackoffSeconds=30;MaxBackoffSeconds=300;MaxPerGroup=3;GroupFailureThreshold=3} }
        default     { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=2;TimeoutSeconds=30;FailureThreshold=3;BackoffSeconds=10;MaxBackoffSeconds=60;MaxPerGroup=2;GroupFailureThreshold=0} }
    }
}

function New-DomeniaProviderState { return @{} }

function Get-DomeniaProviderStateKey {
    param([string]$Provider,[string]$Target='')
    return ($Provider + '|' + ([string]$Target).Trim().ToLowerInvariant())
}

function New-DomeniaProviderStateEntry {
    param([string]$Provider,[string]$Target='')
    return [pscustomobject]@{Provider=$Provider;Target=$Target;Failures=0;BackoffUntilUtc=[datetime]::MinValue;CredentialBlocked=$false;RejectedIdentity='';LastOutcome='';LastUtc=[datetime]::MinValue;Recovering=$false;RecoveryLimit=0;Suspensions=0}
}

function Register-DomeniaProviderOutcome {
    # $Identity is the account that was actually used. A credential refusal blocks that account for that
    # resource; an explicit change of account is a new decision of the operator and is not blocked.
    # Point 160: after a pause, background reads come back one at a time (RecoveryLimit), one more per success.
    # Point 15: -Group (controller or presumed subnet) keeps a second entry: consecutive time-outs on different
    # targets of one site pause that site only, never the whole directory or every workstation.
    param($State,[Parameter(Mandatory=$true)][string]$Provider,[string]$Target='',
        [Parameter(Mandatory=$true)][ValidateSet('Success','Failure','Timeout','CredentialRejected','AccessDenied','Cancelled')][string]$Outcome,
        [datetime]$NowUtc=[datetime]::UtcNow,[string]$Identity='',[string]$Group='')
    if ($null -eq $State) { return $null }
    $key = Get-DomeniaProviderStateKey $Provider $Target
    if (-not $State.ContainsKey($key)) { $State[$key] = New-DomeniaProviderStateEntry $Provider $Target }
    $entry = $State[$key]
    foreach ($field in @('Recovering','RecoveryLimit','Suspensions')) {
        if ($null -eq $entry.PSObject.Properties[$field]) { $entry | Add-Member -NotePropertyName $field -NotePropertyValue $(if ($field -eq 'Recovering') { $false } else { 0 }) }
    }
    $entry.LastOutcome = $Outcome; $entry.LastUtc = $NowUtc
    $budget = Get-DomeniaProviderBudget $Provider
    switch ($Outcome) {
        # A success under another account does not unblock the rejected one: only a reconnection resets it.
        'Success' {
            $entry.Failures = 0; $entry.BackoffUntilUtc = [datetime]::MinValue
            if ([bool]$entry.Recovering) {
                $entry.RecoveryLimit = [int]$entry.RecoveryLimit + 1
                if ([int]$entry.RecoveryLimit -ge [int]$budget.MaxConcurrent) { $entry.Recovering = $false; $entry.RecoveryLimit = 0 }
            }
        }
        'Cancelled' { }
        'CredentialRejected' {
            # No timed retry: the same credentials would be rejected again and could lock the account.
            $entry.CredentialBlocked = $true
            $entry.RejectedIdentity = ([string]$Identity).Trim()
        }
        'AccessDenied' {
            # A refusal is a stable answer, not an outage: no failure escalation, no automatic retry either.
        }
        default {
            $entry.Failures = [int]$entry.Failures + 1
            if ($entry.Failures -ge $budget.FailureThreshold) {
                $power = [Math]::Min(6,$entry.Failures - $budget.FailureThreshold)
                $delay = [Math]::Min([double]$budget.MaxBackoffSeconds,[double]$budget.BackoffSeconds * [Math]::Pow(2,$power))
                $entry.BackoffUntilUtc = $NowUtc.AddSeconds($delay)
                $entry.Recovering = $true; $entry.RecoveryLimit = 1; $entry.Suspensions = [int]$entry.Suspensions + 1
            }
        }
    }
    if ($Group -and ([int]$budget.GroupFailureThreshold -gt 0)) {
        $groupKey = Get-DomeniaProviderStateKey $Provider ('group:' + $Group)
        if (-not $State.ContainsKey($groupKey)) { $State[$groupKey] = New-DomeniaProviderStateEntry $Provider ('group:' + $Group) }
        $site = $State[$groupKey]
        $site.LastOutcome = $Outcome; $site.LastUtc = $NowUtc
        if ($Outcome -in @('Success','AccessDenied')) {
            # Any answer from the site proves its path; the recovery widens one place per answer.
            $site.Failures = 0; $site.BackoffUntilUtc = [datetime]::MinValue
            if ([bool]$site.Recovering) {
                $site.RecoveryLimit = [int]$site.RecoveryLimit + 1
                if ([int]$site.RecoveryLimit -ge [int]$budget.MaxPerGroup) { $site.Recovering = $false; $site.RecoveryLimit = 0 }
            }
        }
        elseif ($Outcome -eq 'Timeout') {
            # Only time-outs count for a site: a refused or absent machine says nothing about the link.
            $site.Failures = [int]$site.Failures + 1
            if ([int]$site.Failures -ge [int]$budget.GroupFailureThreshold) {
                $power = [Math]::Min(6,[int]$site.Failures - [int]$budget.GroupFailureThreshold)
                $delay = [Math]::Min([double]$budget.MaxBackoffSeconds,[double]$budget.BackoffSeconds * [Math]::Pow(2,$power))
                $site.BackoffUntilUtc = $NowUtc.AddSeconds($delay)
                $site.Recovering = $true; $site.RecoveryLimit = 1; $site.Suspensions = [int]$site.Suspensions + 1
            }
        }
    }
    return $entry
}

function Reset-DomeniaProviderState {
    # Called after an explicit credential change or a voluntary reconnection.
    param($State,[string]$Provider='',[string]$Target='')
    if ($null -eq $State) { return }
    foreach ($key in @($State.Keys)) {
        $entry = $State[$key]
        if ($Provider -and $entry.Provider -ne $Provider) { continue }
        if ($Target -and ([string]$entry.Target) -ine $Target) { continue }
        [void]$State.Remove($key)
    }
}

function Test-DomeniaProviderAdmission {
    # Points 15 and 160: -Group, -RunningForTarget and -RunningForGroup add the site budget and the progressive
    # recovery for background reads. -1 means unknown and keeps the historical decision.
    # Point 16: -Aged (background work that waited its aging delay while no other background work runs) may start
    # above the provider and site budgets, which explicit reads may fill on their own: it is then the only background
    # read in flight, so the excess is one read at most. A pause, a recovery or a rejected account is never bypassed.
    param($State,[Parameter(Mandatory=$true)][string]$Provider,[string]$Target='',[string]$Class='Explicit',[int]$RunningForProvider=0,[datetime]$NowUtc=[datetime]::UtcNow,[string]$Identity='',
        [string]$Group='',[int]$RunningForTarget=-1,[int]$RunningForGroup=-1,[bool]$Aged=$false)
    $budget = Get-DomeniaProviderBudget $Provider
    $agedException = ($Aged -and ($Class -eq 'Background'))
    $usedExtra = $false
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $State) {
        foreach ($key in @((Get-DomeniaProviderStateKey $Provider $Target),(Get-DomeniaProviderStateKey $Provider ''))) { if ($State.ContainsKey($key)) { $entries.Add($State[$key]) } }
    }
    $site = $null
    if ($Group -and ($null -ne $State)) {
        $groupKey = Get-DomeniaProviderStateKey $Provider ('group:' + $Group)
        if ($State.ContainsKey($groupKey)) { $site = $State[$groupKey] }
    }
    foreach ($entry in $entries) {
        if (-not [bool]$entry.CredentialBlocked) { continue }
        # Same account (or unknown account): refused. Another account chosen explicitly: allowed once more.
        $rejected = [string](Get-DomeniaMember $entry 'RejectedIdentity' '')
        if (-not $rejected -or -not $Identity -or $rejected -ieq ([string]$Identity).Trim()) {
            return [pscustomobject]@{Allowed=$false;Reason='Identifiants rejetes pour cette ressource : aucun nouvel essai avant un changement de compte explicite.';RetryAfterUtc=$null;Budget=$budget;Durable=$true}
        }
    }
    foreach ($entry in $entries) {
        # Only background reads pause: a read the operator asked for (Explicit) or caused by a selection
        # (an object opened, a presence check) is still sent, and its outcome keeps feeding the budget.
        if (([datetime]$entry.BackoffUntilUtc -gt $NowUtc) -and ($Class -eq 'Background')) {
            return [pscustomobject]@{Allowed=$false;Reason='Pannes repetees : nouvelles lectures de fond suspendues temporairement.';RetryAfterUtc=[datetime]$entry.BackoffUntilUtc;Budget=$budget;Durable=$false}
        }
    }
    if ($Class -eq 'Background') {
        if (($null -ne $site) -and ([datetime]$site.BackoffUntilUtc -gt $NowUtc)) {
            return [pscustomobject]@{Allowed=$false;Reason=('Délais répétés sur ce site (' + $Group + ') : lectures de fond suspendues jusquʼà ' + ([datetime]$site.BackoffUntilUtc).ToLocalTime().ToString('HH:mm:ss') + ' ; les autres sites continuent.');RetryAfterUtc=[datetime]$site.BackoffUntilUtc;Budget=$budget;Durable=$false}
        }
        foreach ($entry in $entries) {
            if (([bool](Get-DomeniaMember $entry 'Recovering' $false)) -and ($RunningForTarget -ge 0) -and ($RunningForTarget -ge [Math]::Max(1,[int](Get-DomeniaMember $entry 'RecoveryLimit' 1)))) {
                return [pscustomobject]@{Allowed=$false;Reason='Reprise progressive après des pannes : une lecture de fond de plus à chaque réponse.';RetryAfterUtc=$null;Budget=$budget;Durable=$false}
            }
        }
        if (($null -ne $site) -and ([bool](Get-DomeniaMember $site 'Recovering' $false)) -and ($RunningForGroup -ge 0) -and ($RunningForGroup -ge [Math]::Max(1,[int](Get-DomeniaMember $site 'RecoveryLimit' 1)))) {
            return [pscustomobject]@{Allowed=$false;Reason=('Reprise progressive du site ' + $Group + ' : une lecture de fond de plus à chaque réponse.');RetryAfterUtc=$null;Budget=$budget;Durable=$false}
        }
        if ($Group -and ($RunningForGroup -ge [int]$budget.MaxPerGroup)) {
            if (-not $agedException) {
                return [pscustomobject]@{Allowed=$false;Reason=('Budget du site ' + $Group + ' atteint : les autres sites gardent leurs places.');RetryAfterUtc=$null;Budget=$budget;Durable=$false}
            }
            $usedExtra = $true
        }
        if ($RunningForProvider -ge [int]$budget.MaxConcurrent) {
            if (-not $agedException) {
                return [pscustomobject]@{Allowed=$false;Reason='Concurrence maximale atteinte pour ce fournisseur.';RetryAfterUtc=$null;Budget=$budget;Durable=$false}
            }
            $usedExtra = $true
        }
    }
    return [pscustomobject]@{Allowed=$true;Reason='';RetryAfterUtc=$null;Budget=$budget;Durable=$false;Aged=$usedExtra}
}

function Get-DomeniaProviderStateSummary {
    # Point 160: plain lines for the operations panel. Paused sources are named with their provider; healthy sources
    # are not listed, and no line ever says that the whole directory is unreachable. Sites, controllers and whole
    # providers get one line each; single workstations are counted per provider and state (a campaign over a slow
    # site may leave thousands of them in progressive recovery), with a few names.
    param($State,[datetime]$NowUtc=[datetime]::UtcNow,[int]$MaxNames=3)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $State) { return @() }
    $names = @{Directory='annuaire';Cim='WMI';Wts='sessions';Network='réseau';Storage='base locale';Local='local'}
    $groups = [ordered]@{}
    foreach ($key in @($State.Keys | Sort-Object)) {
        $entry = $State[$key]
        $provider = [string]$entry.Provider
        $label = $provider
        if ($names.ContainsKey($provider)) { $label = [string]$names[$provider] }
        $raw = [string]$entry.Target
        $kind = ''
        if ([bool]$entry.CredentialBlocked) { $kind = 'Blocked' }
        elseif ([datetime]$entry.BackoffUntilUtc -gt $NowUtc) { $kind = 'Paused' }
        elseif ([bool](Get-DomeniaMember $entry 'Recovering' $false)) { $kind = 'Recovering' }
        if (-not $kind) { continue }
        if ($raw -and ($raw -notlike 'group:*')) {
            $groupKey = $label + '|' + $kind
            if (-not $groups.Contains($groupKey)) { $groups[$groupKey] = [pscustomobject]@{Label=$label;Kind=$kind;Names=(New-Object 'System.Collections.Generic.List[string]');Until=[datetime]::MinValue;Limit=1} }
            $group = $groups[$groupKey]
            $group.Names.Add($raw)
            if ([datetime]$entry.BackoffUntilUtc -gt [datetime]$group.Until) { $group.Until = [datetime]$entry.BackoffUntilUtc }
            $group.Limit = [int](Get-DomeniaMember $entry 'RecoveryLimit' 1)
            continue
        }
        $target = if ($raw -like 'group:*') { 'site ' + $raw.Substring(6) } else { 'toutes cibles' }
        switch ($kind) {
            'Blocked' { $lines.Add($label + ' · ' + $target + ' : identifiants rejetés, reprise après un changement de compte explicite.') }
            'Paused' { $lines.Add($label + ' · ' + $target + ' : lectures de fond suspendues jusquʼà ' + ([datetime]$entry.BackoffUntilUtc).ToLocalTime().ToString('HH:mm:ss') + '.') }
            default { $lines.Add($label + ' · ' + $target + ' : reprise progressive (' + [string][int](Get-DomeniaMember $entry 'RecoveryLimit' 1) + ' lecture(s) de fond à la fois).') }
        }
    }
    foreach ($group in @($groups.Values)) {
        $count = $group.Names.Count
        if ($count -eq 1) {
            $who = $group.Label + ' · ' + $group.Names[0]
            switch ([string]$group.Kind) {
                'Blocked' { $lines.Add($who + ' : identifiants rejetés, reprise après un changement de compte explicite.') }
                'Paused' { $lines.Add($who + ' : lectures de fond suspendues jusquʼà ' + ([datetime]$group.Until).ToLocalTime().ToString('HH:mm:ss') + '.') }
                default { $lines.Add($who + ' : reprise progressive (' + [string][int]$group.Limit + ' lecture(s) de fond à la fois).') }
            }
            continue
        }
        $shown = @($group.Names | Select-Object -First ([Math]::Max(1,$MaxNames)))
        $list = $shown -join ', '
        if ($count -gt $shown.Count) { $list += ' et ' + [string]($count - $shown.Count) + ' autre(s)' }
        $who = $group.Label + ' · ' + [string]$count + ' cibles (' + $list + ')'
        switch ([string]$group.Kind) {
            'Blocked' { $lines.Add($who + ' : identifiants rejetés, reprise après un changement de compte explicite.') }
            'Paused' { $lines.Add($who + ' : lectures de fond suspendues, au plus tard jusquʼà ' + ([datetime]$group.Until).ToLocalTime().ToString('HH:mm:ss') + '.') }
            default { $lines.Add($who + ' : reprise progressive, une lecture de fond de plus à chaque réponse.') }
        }
    }
    return $lines.ToArray()
}

function Test-DomeniaAutoRetryAllowed {
    # A write is never replayed. A rejected credential or a refusal is never retried automatically.
    param([bool]$IsWrite,[Parameter(Mandatory=$true)][string]$Outcome,[int]$Attempt=0)
    if ($IsWrite) { return $false }
    if ($Outcome -in @('CredentialRejected','AccessDenied','Cancelled','Success')) { return $false }
    return ($Attempt -lt 1)
}

# ---------------------------------------------------------------- D019 resource ownership
function New-DomeniaResourceRegistry {
    return [pscustomobject]@{Items=(New-Object System.Collections.ArrayList);Sequence=0;Released=0;Failures=0}
}

function Register-DomeniaResource {
    param($Registry,[Parameter(Mandatory=$true)][string]$Owner,[Parameter(Mandatory=$true)][string]$Kind,$Resource,[scriptblock]$Release)
    if ($null -eq $Registry) { return 0 }
    $Registry.Sequence = [int]$Registry.Sequence + 1
    [void]$Registry.Items.Add([pscustomobject]@{Id=[int]$Registry.Sequence;Owner=$Owner;Kind=$Kind;Resource=$Resource;Release=$Release;CreatedUtc=[datetime]::UtcNow})
    return [int]$Registry.Sequence
}

function Release-DomeniaResources {
    # Releases the resources of one owner, one kind, or all. Every release runs even if a previous one failed.
    # -Kind lets the shutdown release timers and pools without disposing a job still active on its thread.
    param($Registry,[string]$Owner='',[int]$Id=0,[string]$Kind='')
    $released = 0; $errors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Registry) { return [pscustomobject]@{Released=0;Failed=0;Errors=@()} }
    foreach ($item in @($Registry.Items.ToArray())) {
        if ($Owner -and $item.Owner -ne $Owner) { continue }
        if ($Id -gt 0 -and $item.Id -ne $Id) { continue }
        if ($Kind -and $item.Kind -ne $Kind) { continue }
        try {
            if ($null -ne $item.Release) { & $item.Release $item.Resource }
            elseif ($item.Resource -is [IDisposable]) { $item.Resource.Dispose() }
            $released++
        } catch { $errors.Add($item.Kind + ' (' + $item.Owner + ') : ' + $_.Exception.Message) }
        finally { [void]$Registry.Items.Remove($item) }
    }
    $Registry.Released = [int]$Registry.Released + $released
    $Registry.Failures = [int]$Registry.Failures + $errors.Count
    return [pscustomobject]@{Released=$released;Failed=$errors.Count;Errors=$errors.ToArray()}
}

function Get-DomeniaResourceSummary {
    param($Registry)
    $byKind = @{}
    $total = 0
    if ($null -ne $Registry) {
        foreach ($item in @($Registry.Items.ToArray())) { $total++; if ($byKind.ContainsKey($item.Kind)) { $byKind[$item.Kind]++ } else { $byKind[$item.Kind] = 1 } }
    }
    $text = @($byKind.Keys | Sort-Object | ForEach-Object { $_ + ' : ' + $byKind[$_] }) -join ' · '
    if (-not $text) { $text = 'Aucune ressource detenue' }
    return [pscustomobject]@{Total=$total;ByKind=$byKind;Text=$text}
}

# ---------------------------------------------------------------- D020 idle policy
function Get-DomeniaIdlePolicy {
    # UX-30: a view is rebuilt while the window is visible, active or not (a home page on a second screen stays
    # current); only a minimized or hidden window suspends it. Background network reads keep needing the active window.
    param([bool]$WindowActive=$true,[bool]$Minimized=$false,[string]$VisiblePage='',[bool]$WriteInFlight=$false,[int]$PendingSaves=0,[bool]$ExplicitActivity=$false,[bool]$Hidden=$false)
    $visible = ((-not $Minimized) -and (-not $Hidden))
    $reason = 'Fenêtre active.'
    if ($Minimized) { $reason = 'Fenêtre réduite : rafraîchissements suspendus.' }
    elseif ($Hidden) { $reason = 'Fenêtre masquée : rafraîchissements suspendus.' }
    elseif (-not $WindowActive) { $reason = 'Fenêtre inactive : lectures réseau de fond suspendues, affichage tenu à jour.' }
    return [pscustomobject]@{
        Visible=$visible;Active=$WindowActive;VisiblePage=$VisiblePage
        # Background network refreshes need the active window; a write in flight also pauses them.
        AllowBackgroundRefresh=($visible -and $WindowActive -and (-not $WriteInFlight))
        AllowHiddenViewRebuild=$false
        # Explicit work, receipts and saves are never abandoned by the idle policy.
        AllowExplicitWork=$true;KeepReceiptTracking=$true;KeepStorageWrites=$true
        PendingSaves=$PendingSaves;WriteInFlight=$WriteInFlight;ExplicitActivity=$ExplicitActivity;Reason=$reason
    }
}

function Get-DomeniaIdleActivityForSource {
    # C1 sources mapped to the idle-policy activities. An unknown source is treated as background work.
    param([string]$Source)
    switch ([string]$Source) {
        'Live' { return [pscustomobject]@{Activity='LiveProbe';Page=''} }
        'Reconcile' { return [pscustomobject]@{Activity='Reconcile';Page='WsSearch'} }
        'ObjectChanges' { return [pscustomobject]@{Activity='Reconcile';Page='WsSearch'} }
        'Dashboard' { return [pscustomobject]@{Activity='ViewRebuild';Page='TabDashboard'} }
        'Index' { return [pscustomobject]@{Activity='Presence';Page=''} }
        'Park' { return [pscustomobject]@{Activity='Presence';Page=''} }
        'Storage' { return [pscustomobject]@{Activity='Storage';Page=''} }
        'Receipts' { return [pscustomobject]@{Activity='Receipts';Page=''} }
        default { return [pscustomobject]@{Activity='Presence';Page=''} }
    }
}

function Test-DomeniaIdleAllows {
    # $Activity: Presence, Dashboard, Reconcile, LiveProbe, ViewRebuild, Storage, Receipts, Explicit.
    param($Policy,[Parameter(Mandatory=$true)][string]$Activity,[string]$Page='')
    if ($null -eq $Policy) { return $true }
    switch ($Activity) {
        'Storage' { return $true }
        'Receipts' { return $true }
        'Explicit' { return $true }
        'ViewRebuild' {
            # A hidden page is rebuilt when it is shown again, not while it is hidden. UX-30: an inactive but
            # visible window keeps its view current; only a minimized or hidden window suspends the rebuild.
            if (-not [bool]$Policy.Visible) { return $false }
            if ($Page -and [string]$Policy.VisiblePage -and $Page -ne [string]$Policy.VisiblePage) { return $false }
            return $true
        }
        default {
            if (-not [bool]$Policy.AllowBackgroundRefresh) { return $false }
            if ($Page -and [string]$Policy.VisiblePage -and $Page -ne [string]$Policy.VisiblePage) { return $false }
            return $true
        }
    }
}

# ---------------------------------------------------------------- Directory read deadlines
function Get-DomeniaReadTimeoutState {
    # GlobalSearch receives a dispatch-owned monotonic clock. Only raw LDAP arrivals
    # advance it: cached rows, queue draining and UI callbacks are not network progress.
    # Point 17: any other read whose payload carried a ReadProgress channel (a campaign workstation: one step per
    # finished ping or CIM query) follows the same rule: no progress for TimeoutSeconds ends it (Idle), and a
    # progressing read still stops at HardTimeoutSeconds (Total). Without a valid channel the total-elapsed rule stays.
    # This function only decides; the existing caller retains cancellation/partial results.
    param($Job,[double]$ElapsedSeconds,
        [long]$NowTimestamp=[Diagnostics.Stopwatch]::GetTimestamp(),
        [long]$TimestampFrequency=[Diagnostics.Stopwatch]::Frequency)
    $elapsed = $ElapsedSeconds
    if ([double]::IsNaN($elapsed) -or $elapsed -lt 0) { $elapsed = 0.0 }
    $result = [pscustomobject]@{Expired=$false;Reason='';ElapsedSeconds=$elapsed;IdleSeconds=$elapsed;RowsRead=[long]0;Message=''}
    if ($null -eq $Job) { return $result }
    if ([bool](Get-DomeniaMember $Job 'IsWrite' $false) -or
        [bool](Get-DomeniaMember $Job 'CancelRequested' $false) -or
        [bool](Get-DomeniaMember $Job 'Superseded' $false) -or
        [string](Get-DomeniaMember $Job 'State' '') -in @('Queued','Withdrawn','Completed','StopRequested','Cleanup','Cancelled','Canceled')) { return $result }

    $isSearch = ([string](Get-DomeniaMember $Job 'OperationId' '') -eq 'GlobalSearch')
    $channelName = 'ReadProgress'
    if ($isSearch) { $channelName = 'SearchReadProgress' }
    $progress = Get-DomeniaMemberValue $Job $channelName $null
    $tracked = ($isSearch -or ($progress -is [Collections.IDictionary]))
    $timeout = if ($isSearch) { 120.0 } else { 60.0 }
    try {
        $configured = [double](Get-DomeniaMember $Job 'TimeoutSeconds' $timeout)
        if (-not [double]::IsNaN($configured) -and -not [double]::IsInfinity($configured) -and $configured -gt 0) { $timeout = $configured }
    } catch { }
    $hardTimeout = 900.0
    if (-not $isSearch) { $hardTimeout = $timeout }
    if ($tracked) {
        try {
            $configured = [double](Get-DomeniaMember $Job 'HardTimeoutSeconds' $hardTimeout)
            if (-not [double]::IsNaN($configured) -and -not [double]::IsInfinity($configured) -and $configured -gt 0) { $hardTimeout = $configured }
        } catch { }
        if ($hardTimeout -lt $timeout) { $hardTimeout = $timeout }
    }

    $validProgress = $false
    if ($tracked -and $TimestampFrequency -gt 0 -and $NowTimestamp -gt 0) {
        if ($progress -is [Collections.IDictionary]) {
            $syncRoot = $null; $locked = $false
            try {
                # The worker uses this same lock only for three primitive assignments.
                # Snapshot first, release, then parse/compute outside the critical section.
                $syncRoot = ([Collections.ICollection]$progress).SyncRoot
                [Threading.Monitor]::Enter($syncRoot); $locked = $true
                $startedValue = $progress['StartedTimestamp']
                $lastValue = $progress['LastRowTimestamp']
                $rowsValue = $progress['RowsRead']
            } catch { $startedValue = $null; $lastValue = $null; $rowsValue = $null }
            finally { if ($locked) { [Threading.Monitor]::Exit($syncRoot) } }
            # A row can arrive between function entry and the locked snapshot. Sample
            # the real clock afterwards, or that legitimate arrival looks future-dated.
            # Explicit test clocks remain untouched so malformed timestamps stay testable.
            if (-not $PSBoundParameters.ContainsKey('NowTimestamp')) { $NowTimestamp = [Diagnostics.Stopwatch]::GetTimestamp() }
            $started = [long]0; $last = [long]0; $rows = [long]0
            if ([long]::TryParse([string]$startedValue,[ref]$started) -and
                [long]::TryParse([string]$lastValue,[ref]$last) -and
                [long]::TryParse([string]$rowsValue,[ref]$rows) -and
                $started -gt 0 -and $started -le $NowTimestamp -and $rows -ge 0 -and
                (($last -eq 0 -and $rows -eq 0) -or ($rows -gt 0 -and $last -ge $started -and $last -le $NowTimestamp))) {
                $validProgress = $true
                $result.ElapsedSeconds = [double]($NowTimestamp - $started) / $TimestampFrequency
                $idleStart = if ($last -gt 0) { $last } else { $started }
                $result.IdleSeconds = [double]($NowTimestamp - $idleStart) / $TimestampFrequency
                $result.RowsRead = $rows
            }
        }
    }
    # Invalid/missing clocks keep the former total-elapsed rule, never an open-ended
    # progress extension. Even healthy row arrivals cannot exceed the total cap.
    if ($tracked -and $result.ElapsedSeconds -gt $hardTimeout) {
        $result.Expired = $true; $result.Reason = 'Total'
    }
    elseif ($validProgress -and $result.IdleSeconds -gt $timeout) {
        $result.Expired = $true; $result.Reason = 'Idle'
    }
    elseif (-not $validProgress -and $result.ElapsedSeconds -gt $timeout) {
        $result.Expired = $true; $result.Reason = 'Timeout'
    }
    if ($result.Expired) {
        $displayElapsed = [int][Math]::Min([int]::MaxValue,$result.ElapsedSeconds)
        $name = [string](Get-DomeniaMember $Job 'Name' '')
        if (-not $tracked) { $result.Message = "Timeout apres $($displayElapsed)s : $name" }
        elseif ($isSearch) {
            $displayIdle = [int][Math]::Min([int]::MaxValue,$result.IdleSeconds)
            $reason = switch ($result.Reason) {
                'Total' { 'durée totale maximale atteinte' }
                'Idle' { 'aucune nouvelle ligne AD reçue' }
                default { 'délai atteint ; progression AD indisponible' }
            }
            $received = if ($validProgress) { "$($result.RowsRead) ligne(s) AD reçue(s)" } else { 'nombre de lignes AD reçues non confirmé' }
            $idleText = if ($validProgress) { "$($displayIdle) s sans nouvelle ligne AD" } else { 'activité AD non confirmée' }
            $result.Message = "Timeout : $name — $reason ; $($displayElapsed) s écoulées, $idleText, $received. Résultats partiels."
        }
        else {
            $displayIdle = [int][Math]::Min([int]::MaxValue,$result.IdleSeconds)
            $reason = switch ($result.Reason) {
                'Total' { 'durée totale maximale atteinte malgré la progression' }
                'Idle' { 'aucune étape terminée pendant le délai' }
                default { 'délai atteint ; progression indisponible' }
            }
            $steps = if ($validProgress) { "$($result.RowsRead) étape(s) terminée(s)" } else { 'étapes terminées non confirmées' }
            $idleText = if ($validProgress) { "$($displayIdle) s sans nouvelle étape" } else { 'activité non confirmée' }
            $result.Message = "Délai dépassé : $name — $reason ; $($displayElapsed) s écoulées, $idleText, $steps. Aucune mesure partielle nʼest conservée."
        }
    }
    return $result
}

# ---------------------------------------------------------------- Point 122: response-time percentiles
function Get-DomeniaRuntimeMetricOperationKey {
    # Series key of one finished worker (Add-DomeniaTaskRuntimeMetric). The local index reader and the query worker
    # serve several screens: a closed list of actions keeps a local search apart from a dashboard or collection read,
    # so its median is not blended with a 20 000-row board computation. Any other value keeps the plain identifier.
    param([string]$OperationId,$Payload=$null)
    $id = [string]$OperationId
    if ($id -ceq 'LocalIndexRead') {
        $action = [string](Get-DomeniaMember $Payload 'Action' '')
        if ($action -cin @('Search','FleetStats','ParkTargets','ParkState','StoreRead','ResolveNames','IndexMetadata','UserMachineLinks','SecretIndexEntry','OperationStats','DirectorySync','SnapshotCompare')) { return ($id + ':' + $action) }
        return $id
    }
    if ($id -ceq 'LocalQuery') {
        $search = $false
        try { $search = [bool](Get-DomeniaMember $Payload 'SearchOutput' $false) } catch { $search = $false }
        if ($search) { return ($id + ':Search') }
    }
    return $id
}

function Get-DomeniaResponseTimeCategories {
    # Closed list of the response times shown in the operations panel. Each category names the series of
    # Add-DomeniaRuntimeMetric it gathers ('Provenance|prefix', ordinal); Exclude removes the series counted by another
    # category, so that one measure is never reported twice. Dispatcher|Callback: is the processing and display of a
    # result on the interface thread (rendering included); worker durations never enter it. Add-DomeniaTaskRuntimeMetric
    # prefixes a write or remote action with 'Write:' (password reset, unlock, restart, policy refresh...): it has its own
    # category and never enters the reads of its provider. A local base write stays in the local base category.
    $search = @('Sqlite|LocalIndexRead:Search','Sqlite|LocalQuery:Search')
    $writes = @('Ldap|Write:','Cim|Write:')
    return @(
        [pscustomobject]@{ Id='LocalSearch'; Label='Recherche locale'; Include=$search; Exclude=@() }
        [pscustomobject]@{ Id='Render'; Label='Traitement des résultats dans lʼinterface'; Include=@('Dispatcher|Callback:'); Exclude=@() }
        [pscustomobject]@{ Id='Sqlite'; Label='Autres lectures et écritures de la base locale'; Include=@('Sqlite|'); Exclude=$search }
        [pscustomobject]@{ Id='Directory'; Label='Lectures de lʼannuaire'; Include=@('Ldap|'); Exclude=@('Ldap|Write:') }
        [pscustomobject]@{ Id='Computers'; Label='Collecte sur les postes (réseau et WMI)'; Include=@('Cim|'); Exclude=@('Cim|Write:') }
        [pscustomobject]@{ Id='Writes'; Label='Écritures dans lʼannuaire et actions sur les postes'; Include=$writes; Exclude=@() }
    )
}

function Select-DomeniaResponseTimeSamples {
    # Durations (ms) of every series whose key starts with one Include prefix and with no Exclude prefix.
    # Series: dictionary 'Provenance|OperationId' -> enumerable of numbers. Negative, NaN and infinite values are not
    # measures and are dropped. Returns double[] (possibly empty), never $null.
    param($Series,$Category)
    $values = New-Object 'System.Collections.Generic.List[double]'
    if (($null -eq $Series) -or ($null -eq $Category) -or ($Series -isnot [Collections.IDictionary])) { return ,($values.ToArray()) }
    $include = @(Get-DomeniaMember $Category 'Include' @())
    $exclude = @(Get-DomeniaMember $Category 'Exclude' @())
    foreach ($key in @($Series.Keys)) {
        $text = [string]$key
        $kept = $false
        foreach ($prefix in $include) { if ($text.StartsWith([string]$prefix,[StringComparison]::Ordinal)) { $kept = $true; break } }
        if (-not $kept) { continue }
        foreach ($prefix in $exclude) { if ($text.StartsWith([string]$prefix,[StringComparison]::Ordinal)) { $kept = $false; break } }
        if (-not $kept) { continue }
        $serie = $Series[$key]
        if ($null -eq $serie) { continue }
        if (($serie -is [Collections.Generic.Queue[double]]) -or ($serie -is [double[]])) {
            # Runtime series (Add-DomeniaRuntimeMetric): already doubles, one comparison pair per value. NaN fails both.
            foreach ($number in $serie) { if (($number -ge 0) -and ($number -lt [double]::PositiveInfinity)) { $values.Add($number) } }
            continue
        }
        foreach ($value in $serie) {
            # The runtime series hold doubles; any other value is read as an invariant number or skipped.
            $number = [double]::NaN
            if ($value -is [double]) { $number = $value }
            elseif (-not [double]::TryParse([string]$value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { continue }
            if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or ($number -lt 0)) { continue }
            $values.Add($number)
        }
    }
    return ,($values.ToArray())
}

function Get-DomeniaLatencySummary {
    # Median, 95th percentile and maximum of measured durations, nearest-rank like Get-DomeniaRuntimeMetricSummary.
    # Below MinimumForP95 samples the 95th percentile is not stated (P95Stated=$false, P95=$null): with ten samples it
    # would only repeat the maximum. No sample gives Count=0 and null values, never 0 ms.
    param([double[]]$Samples=@(),[ValidateRange(1,10000)][int]$MinimumForP95=20)
    $kept = New-Object 'System.Collections.Generic.List[double]'
    foreach ($value in $Samples) {
        $number = [double]$value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or ($number -lt 0)) { continue }
        $kept.Add($number)
    }
    if ($kept.Count -eq 0) { return [pscustomobject]@{ Count=0; P50=$null; P95=$null; Max=$null; P95Stated=$false; MinimumForP95=$MinimumForP95 } }
    $sorted = $kept.ToArray(); [Array]::Sort($sorted)
    $n = $sorted.Length
    $p50 = $sorted[[int][Math]::Min($n - 1,[Math]::Max(0,[Math]::Ceiling(0.50 * $n) - 1))]
    $stated = ($n -ge $MinimumForP95)
    $p95 = $null
    if ($stated) { $p95 = [Math]::Round($sorted[[int][Math]::Min($n - 1,[Math]::Max(0,[Math]::Ceiling(0.95 * $n) - 1))],2) }
    return [pscustomobject]@{ Count=$n; P50=[Math]::Round($p50,2); P95=$p95; Max=[Math]::Round($sorted[$n - 1],2); P95Stated=$stated; MinimumForP95=$MinimumForP95 }
}

function Format-DomeniaLatencySummaryText {
    # One sentence of the operations panel. An unmeasured category stays unmeasured: no invented 0 ms.
    param([string]$Label,$Summary)
    $count = 0
    try { $count = [int](Get-DomeniaMember $Summary 'Count' 0) } catch { $count = 0 }
    if ($count -le 0) { return ($Label + ' : aucune mesure dans cette session.') }
    $p50 = [Math]::Round([double]$Summary.P50)
    $max = [Math]::Round([double]$Summary.Max)
    $plural = if ($count -gt 1) { 'mesures' } else { 'mesure' }
    if (-not [bool](Get-DomeniaMember $Summary 'P95Stated' $false)) {
        return ($Label + ' : médiane ' + $p50 + ' ms ; maximum ' + $max + ' ms (' + $count + ' ' + $plural + ', trop peu pour un 95e centile).')
    }
    return ($Label + ' : médiane ' + $p50 + ' ms ; 95 % sous ' + [Math]::Round([double]$Summary.P95) + ' ms ; maximum ' + $max + ' ms (' + $count + ' ' + $plural + ').')
}
