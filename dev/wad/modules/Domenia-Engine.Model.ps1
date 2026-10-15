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
    # Real operation identifiers of the closed worker registry. A caller that knows better passes -Hint
    # (for example IndexBuild started automatically at startup is Background, the same read started by a
    # button stays Explicit).
    param([Parameter(Mandatory=$true)][string]$OperationId,[bool]$IsWrite=$false,[string]$ReplaceKey='',[string]$Hint='')
    if ($IsWrite) { return 'Write' }
    if ($Hint -in @('Explicit','Selection','Background')) { return $Hint }
    $background = @('LiveCache','LiveDirectoryCheck','PresenceScan','ScopeReconcile','StartupWarmCache','LocalStore','ReceiptStore','ParkSharedSync')
    if ($background -contains $OperationId) { return 'Background' }
    # LiveConsole and LiveSelectedPing run the same pinned body, chosen by a check box after a selection.
    if ($OperationId -in @('SelectedPresence','LiveSelectedPing','LiveConsole') -or ($OperationId -eq 'OpenAdObject' -and $ReplaceKey -eq 'object')) { return 'Selection' }
    return 'Explicit'
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

function Get-DomeniaTaskDedupKey {
    # Two reads may share one worker only when everything that decides their result is identical.
    param([Parameter(Mandatory=$true)][string]$OperationId,[string]$ReaderIdentity='',[long]$Epoch=0,[long]$Generation=0,$Payload=$null,[bool]$IsWrite=$false,[string[]]$Shareable=@())
    if ($IsWrite) { return '' }
    $allowed = @('OpenAdObject','EmbeddedDirectoryLookup','SessionsList','ComputerQuickDiag','PasswordPolicyRead','LockoutDiagnosis','GroupPathRead','JoinStateRead','UpdateStateRead','GpoLinksRead','GpoAppliedRead','DcCompareRead','ComputerEventsRead','MachineIdentityRead') + @($Shareable)
    if ($allowed -notcontains $OperationId) { return '' }
    $digest = Get-DomeniaPayloadDigest $Payload
    if (-not $digest) { return '' }
    return (Get-DomeniaTextHash ($OperationId + '|' + $ReaderIdentity + '|' + $Epoch + '|' + $Generation + '|' + $digest))
}

function Test-DomeniaTaskAdmission {
    # Decides whether a request starts now, waits in the bounded queue, or is refused.
    # FI-03: reads (Selection, Background) stop at MaxOutstanding physical workers. An explicit action has one
    # reserved physical place above that cap and a write one more: detached reads never refuse a write.
    param(
        [Parameter(Mandatory=$true)][string]$Class,
        [int]$Running=0,[int]$Outstanding=0,[int]$MaxConcurrent=6,[int]$MaxOutstanding=12,
        [int]$Queued=0,[int]$MaxQueued=32,[int]$ReservedForeground=2
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
    if ($Class -eq 'Write') { return [pscustomobject]@{Decision='Reject';Reason='Moteur sature : aucune ecriture mise en attente silencieuse.'} }
    if ($Queued -lt $MaxQueued) {
        $why = 'Lectures en cours : demande placee en attente.'
        if ($Class -eq 'Background') { $why = 'Places reservees aux actions explicites : travail de fond en attente.' }
        return [pscustomobject]@{Decision='Queue';Reason=$why}
    }
    return [pscustomobject]@{Decision='Reject';Reason='File d attente pleine : aucune nouvelle lecture acceptee.'}
}

function Select-DomeniaNextQueuedTask {
    # Returns the queued task that may start now, or $null. Priority first, then arrival order.
    # MO-05: with -ProviderLoad (running workers per provider), a candidate whose provider is saturated or paused
    # is skipped and stays queued; a durable refusal (rejected account) is returned so that its start reports it.
    param([object[]]$Queued,[int]$Running=0,[int]$Outstanding=0,[int]$MaxConcurrent=6,[int]$MaxOutstanding=12,[int]$ReservedForeground=2,
        $ProviderLoad=$null,$ProviderState=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    $candidates = @(@($Queued) | Where-Object { $null -ne $_ })
    if (-not $candidates.Count) { return $null }
    foreach ($task in @(Get-DomeniaTaskOrder -Jobs $candidates)) {
        $class = [string](Get-DomeniaMember $task 'Class' 'Background')
        $decision = Test-DomeniaTaskAdmission -Class $class -Running $Running -Outstanding $Outstanding -MaxConcurrent $MaxConcurrent -MaxOutstanding $MaxOutstanding -Queued 0 -MaxQueued 1 -ReservedForeground $ReservedForeground
        if ($decision.Decision -ne 'Start') { continue }
        if ($null -ne $ProviderLoad) {
            $provider = [string](Get-DomeniaMember $task 'Provider' '')
            if ($provider) {
                $busy = 0
                if (($ProviderLoad -is [Collections.IDictionary]) -and $ProviderLoad.Contains($provider)) { $busy = [int]$ProviderLoad[$provider] }
                $budget = Test-DomeniaProviderAdmission -State $ProviderState -Provider $provider -Target ([string](Get-DomeniaMember $task 'ProviderTarget' '')) -Class $class -RunningForProvider $busy -NowUtc $NowUtc
                if ((-not [bool]$budget.Allowed) -and (-not [bool](Get-DomeniaMember $budget 'Durable' $false))) { continue }
            }
        }
        return $task
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

# ---------------------------------------------------------------- D018 provider budgets
function Get-DomeniaOperationProvider {
    param([Parameter(Mandatory=$true)][string]$OperationId)
    # Remote actions on a workstation (GPUpdate, restart, Rimotte, user probe, credential check) are budgeted
    # per target with the CIM provider: an outage there must never slow the directory.
    $cim = @('ComputerDiagnostics','ComputerInventory','SoftwareInventory','WmiNamespaces','WmiClasses','WmiQuery','QuerySchema','LiveConsole','ComputerLastUser','ComputerQuickDiag','JoinStateRead','UpdateStateRead','GpoAppliedRead','ComputerEventsRead','MachineIdentityRead','ParkSweep','BatchNetworkDiag','ComputerGpUpdate','ComputerRestart','RimotteRun','UserComputerProbe','RemoteCredentialCheck')
    $wts = @('SessionsList')
    $storage = @('LegacyMigration','LocalStore','LiveCache','ReceiptStore','DocumentStore','StorageUsage','StoragePurge','StorageBackup','StorageMaintenance','StorageRetention','LinkHistoryStore','LocalIndexRead','LocalQuery','QueryExport','QueryLibrary','QueryTransfer')
    $local = @('CmdletHelp','CmdletInventory','EngineSelfTest','EmbeddedPathBrowse','LocalAssistant','DemoDirectory','IsolatedRead')
    # ParkSharedSync reads and writes a shared file, possibly on a UNC path: network I/O, not the local base.
    $network = @('LiveSelectedPing','ComputerPing','ComputerAdminShare','SelectedPresence','PresenceScan','WakeOnLanSend','ConnectorRead','ParkSharedSync')
    if ($cim -contains $OperationId) { return 'Cim' }
    if ($wts -contains $OperationId) { return 'Wts' }
    if ($storage -contains $OperationId) { return 'Storage' }
    if ($local -contains $OperationId) { return 'Local' }
    if ($network -contains $OperationId) { return 'Network' }
    return 'Directory'
}

function Get-DomeniaOperationCredentialNeeds {
    # C3. Credential semantics of one operation, identical to the historical lists of Get-WorkerContext:
    # which account the worker receives, and whether a rejected logon may suspend the directory channel.
    # A provider is not a credential rule: ComputerLastUser and LiveConsole are CIM reads that also query LDAP.
    param([string]$OperationId)
    $remote = @('SessionsList','ComputerDiagnostics','ComputerLastUser','LiveConsole','ComputerPing','ComputerAdminShare','ComputerGpUpdate','ComputerRestart','ComputerInventory','SoftwareInventory','ParkSweep','BatchNetworkDiag','WmiNamespaces','WmiClasses','WmiQuery','QuerySchema','RimotteRun')
    $machine = @('SessionsList','ComputerAdminShare','ComputerDiagnostics','ComputerInventory','SoftwareInventory','ParkSweep','WmiNamespaces','WmiClasses','WmiQuery','QuerySchema','ComputerLastUser','LiveConsole','ComputerGpUpdate','ComputerRestart','UserComputerProbe','RimotteRun')
    # Local or storage operations that never bind to the directory. New D120 operations are classified here.
    $local = @('StorageUsage','StoragePurge','StorageBackup','StorageMaintenance','StorageRetention','LegacyMigration','CmdletHelp','CmdletInventory','EngineSelfTest','LiveCache','LiveSelectedPing','LocalStore','ReceiptStore','SessionsList','DocumentStore','EmbeddedPathBrowse','DemoDirectory','LocalIndexRead','LocalQuery','QueryExport','QueryLibrary','QueryTransfer','ParkSharedSync','IsolatedRead')
    $id = [string]$OperationId
    $isRemote = ($remote -contains $id)
    $nonDirectory = (($local -contains $id) -or $isRemote)
    $directory = (($id -in @('ComputerLastUser','LiveConsole')) -or -not $nonDirectory)
    # ReadBitLockerList and ReadBitLockerKey (lot acces, D058) read BitLocker exactly like ReadBitLocker, and so does
    # BitLockerPresence (lot L01: recovery objects of one OU, Secrets account, refusals kept on the BitLocker resource).
    $secrets = ($id -in @('ReadBitLocker','ReadBitLockerList','ReadBitLockerKey','ReadLaps','BitLockerPresence'))
    $resource = 'Directory'
    if ($id -eq 'ReadLaps') { $resource = 'Laps' }
    elseif ($id -in @('ReadBitLocker','ReadBitLockerList','ReadBitLockerKey','BitLockerPresence')) { $resource = 'BitLocker' }
    elseif ($isRemote -or ($machine -contains $id) -or $id -eq 'RemoteCredentialCheck') { $resource = 'Remote' }
    elseif ($id -in @('LiveSelectedPing','ComputerPing','SelectedPresence','PresenceScan','WakeOnLanSend','ConnectorRead','ParkSharedSync')) { $resource = 'Network' }
    elseif ($nonDirectory) { $resource = 'Local' }
    return [pscustomobject]@{
        OperationId=$id
        # The worker needs the directory channel (circuit breaker and AD account apply).
        Directory=$directory
        # The worker receives the AD account (ReceiptStore records the bind identity of a write).
        DirectoryCredential=($directory -or $id -eq 'ReceiptStore')
        Remote=$isRemote
        Machine=($machine -contains $id)
        RemoteAdmin=($isRemote -or ($machine -contains $id))
        Secrets=$secrets
        NonDirectory=$nonDirectory
        # A rejected logon suspends the AD channel only when the rejected account can be the AD account.
        DirectoryBreaker=($directory -and -not $isRemote)
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
    # is on the reviewed list. Stopping the helper can therefore never touch a write or the GUI.
    param([string]$OperationId,[bool]$Enabled=$false,[bool]$IsWrite=$false,[bool]$HasCredential=$false,[string]$PayloadDigest='',[bool]$DemoMode=$false)
    $eligible = @('ComputerPing','ComputerDiagnostics','ComputerInventory','SoftwareInventory','WmiNamespaces','WmiClasses','WmiQuery','TreeChildren')
    if (-not $Enabled) { return [pscustomobject]@{Isolate=$false;Reason='Lectures isolees desactivees (Features.IsolatedReads).'} }
    if ($IsWrite) { return [pscustomobject]@{Isolate=$false;Reason='Une ecriture n est jamais confiee au processus auxiliaire.'} }
    if ($DemoMode) { return [pscustomobject]@{Isolate=$false;Reason='Demonstration : aucun processus auxiliaire.'} }
    if ($eligible -notcontains [string]$OperationId) { return [pscustomobject]@{Isolate=$false;Reason='Operation non retenue pour l isolement.'} }
    if ($HasCredential) { return [pscustomobject]@{Isolate=$false;Reason='Un compte explicite ne traverse jamais la frontiere du processus.'} }
    if (-not $PayloadDigest) { return [pscustomobject]@{Isolate=$false;Reason='Charge utile vivante : lecture conservee dans le moteur.'} }
    return [pscustomobject]@{Isolate=$true;Reason='Lecture isolee dans un processus auxiliaire borne.'}
}

function Get-DomeniaProviderBudget {
    param([Parameter(Mandatory=$true)][string]$Provider)
    switch ($Provider) {
        'Directory' { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=4;TimeoutSeconds=30;FailureThreshold=3;BackoffSeconds=20;MaxBackoffSeconds=300} }
        'Cim'       { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=3;TimeoutSeconds=25;FailureThreshold=2;BackoffSeconds=60;MaxBackoffSeconds=600} }
        'Wts'       { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=2;TimeoutSeconds=20;FailureThreshold=2;BackoffSeconds=60;MaxBackoffSeconds=600} }
        'Storage'   { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=1;TimeoutSeconds=30;FailureThreshold=3;BackoffSeconds=15;MaxBackoffSeconds=120} }
        'Network'   { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=4;TimeoutSeconds=10;FailureThreshold=3;BackoffSeconds=30;MaxBackoffSeconds=300} }
        default     { return [pscustomobject]@{Provider=$Provider;MaxConcurrent=2;TimeoutSeconds=30;FailureThreshold=3;BackoffSeconds=10;MaxBackoffSeconds=60} }
    }
}

function New-DomeniaProviderState { return @{} }

function Get-DomeniaProviderStateKey {
    param([string]$Provider,[string]$Target='')
    return ($Provider + '|' + ([string]$Target).Trim().ToLowerInvariant())
}

function Register-DomeniaProviderOutcome {
    # $Identity is the account that was actually used. A credential refusal blocks that account for that
    # resource; an explicit change of account is a new decision of the operator and is not blocked.
    param($State,[Parameter(Mandatory=$true)][string]$Provider,[string]$Target='',
        [Parameter(Mandatory=$true)][ValidateSet('Success','Failure','Timeout','CredentialRejected','AccessDenied','Cancelled')][string]$Outcome,
        [datetime]$NowUtc=[datetime]::UtcNow,[string]$Identity='')
    if ($null -eq $State) { return $null }
    $key = Get-DomeniaProviderStateKey $Provider $Target
    if (-not $State.ContainsKey($key)) { $State[$key] = [pscustomobject]@{Provider=$Provider;Target=$Target;Failures=0;BackoffUntilUtc=[datetime]::MinValue;CredentialBlocked=$false;RejectedIdentity='';LastOutcome='';LastUtc=[datetime]::MinValue} }
    $entry = $State[$key]
    $entry.LastOutcome = $Outcome; $entry.LastUtc = $NowUtc
    switch ($Outcome) {
        # A success under another account does not unblock the rejected one: only a reconnection resets it.
        'Success' { $entry.Failures = 0; $entry.BackoffUntilUtc = [datetime]::MinValue }
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
            $budget = Get-DomeniaProviderBudget $Provider
            if ($entry.Failures -ge $budget.FailureThreshold) {
                $power = [Math]::Min(6,$entry.Failures - $budget.FailureThreshold)
                $delay = [Math]::Min([double]$budget.MaxBackoffSeconds,[double]$budget.BackoffSeconds * [Math]::Pow(2,$power))
                $entry.BackoffUntilUtc = $NowUtc.AddSeconds($delay)
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
    param($State,[Parameter(Mandatory=$true)][string]$Provider,[string]$Target='',[string]$Class='Explicit',[int]$RunningForProvider=0,[datetime]$NowUtc=[datetime]::UtcNow,[string]$Identity='')
    $budget = Get-DomeniaProviderBudget $Provider
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $State) {
        foreach ($key in @((Get-DomeniaProviderStateKey $Provider $Target),(Get-DomeniaProviderStateKey $Provider ''))) { if ($State.ContainsKey($key)) { $entries.Add($State[$key]) } }
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
    if ($Class -eq 'Background' -and $RunningForProvider -ge $budget.MaxConcurrent) {
        return [pscustomobject]@{Allowed=$false;Reason='Concurrence maximale atteinte pour ce fournisseur.';RetryAfterUtc=$null;Budget=$budget;Durable=$false}
    }
    return [pscustomobject]@{Allowed=$true;Reason='';RetryAfterUtc=$null;Budget=$budget;Durable=$false}
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
    $timeout = if ($isSearch) { 120.0 } else { 60.0 }
    try {
        $configured = [double](Get-DomeniaMember $Job 'TimeoutSeconds' $timeout)
        if (-not [double]::IsNaN($configured) -and -not [double]::IsInfinity($configured) -and $configured -gt 0) { $timeout = $configured }
    } catch { }
    $hardTimeout = 900.0
    if ($isSearch) {
        try {
            $configured = [double](Get-DomeniaMember $Job 'HardTimeoutSeconds' $hardTimeout)
            if (-not [double]::IsNaN($configured) -and -not [double]::IsInfinity($configured) -and $configured -gt 0) { $hardTimeout = $configured }
        } catch { }
    }

    $validProgress = $false
    if ($isSearch -and $TimestampFrequency -gt 0 -and $NowTimestamp -gt 0) {
        $progress = Get-DomeniaMemberValue $Job 'SearchReadProgress' $null
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
    # progress extension. Even healthy row arrivals cannot exceed the search total cap.
    if ($isSearch -and $result.ElapsedSeconds -gt $hardTimeout) {
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
        if (-not $isSearch) { $result.Message = "Timeout apres $($displayElapsed)s : $name" }
        else {
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
    }
    return $result
}
