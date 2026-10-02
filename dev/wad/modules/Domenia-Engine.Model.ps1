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
    param([Parameter(Mandatory=$true)][string]$OperationId,[bool]$IsWrite=$false,[string]$ReplaceKey='',[string]$Hint='')
    if ($IsWrite) { return 'Write' }
    if ($Hint -in @('Explicit','Selection','Background')) { return $Hint }
    $background = @('LiveConsole','LiveCache','LiveDirectoryCheck','PresenceScan','ParkSweep','IndexBuild','IndexRefresh','ReconcileScope','LocalStore','LogonHarvest','StartupWarmup','ReceiptStore','ObjectChanges')
    if ($background -contains $OperationId) { return 'Background' }
    if ($OperationId -in @('SelectedPresence','LiveSelectedPing') -or ($OperationId -eq 'OpenAdObject' -and $ReplaceKey -eq 'object')) { return 'Selection' }
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
    param(
        [Parameter(Mandatory=$true)][string]$Class,
        [int]$Running=0,[int]$Outstanding=0,[int]$MaxConcurrent=6,[int]$MaxOutstanding=12,
        [int]$Queued=0,[int]$MaxQueued=32,[int]$ReservedForeground=2
    )
    $reserved = [Math]::Max(0,[Math]::Min($ReservedForeground,$MaxConcurrent - 1))
    if ($Outstanding -ge $MaxOutstanding) {
        if ($Class -ne 'Write' -and $Queued -lt $MaxQueued) { return [pscustomobject]@{Decision='Queue';Reason='Workers encore actifs ou en nettoyage : attente de leur liberation reelle.'} }
        return [pscustomobject]@{Decision='Reject';Reason='Limite physique atteinte : des workers restent actifs ou en nettoyage.'}
    }
    $limit = $MaxConcurrent
    if ($Class -eq 'Background') { $limit = $MaxConcurrent - $reserved }
    # A write is never starved by reads: it may use one slot above the read limit.
    if ($Class -eq 'Write') { $limit = $MaxConcurrent + 1 }
    if ($Running -lt $limit) { return [pscustomobject]@{Decision='Start';Reason=''} }
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
    param([object[]]$Queued,[int]$Running=0,[int]$Outstanding=0,[int]$MaxConcurrent=6,[int]$MaxOutstanding=12,[int]$ReservedForeground=2)
    $candidates = @(@($Queued) | Where-Object { $null -ne $_ })
    if (-not $candidates.Count) { return $null }
    $ordered = @($candidates | Sort-Object @{Expression={ Get-DomeniaTaskPriority ([string](Get-DomeniaMember $_ 'Class' 'Background')) }},@{Expression={ [long](Get-DomeniaMember $_ 'Sequence' 0) }})
    foreach ($task in $ordered) {
        $decision = Test-DomeniaTaskAdmission -Class ([string](Get-DomeniaMember $task 'Class' 'Background')) -Running $Running -Outstanding $Outstanding -MaxConcurrent $MaxConcurrent -MaxOutstanding $MaxOutstanding -Queued 0 -MaxQueued 1 -ReservedForeground $ReservedForeground
        if ($decision.Decision -eq 'Start') { return $task }
    }
    return $null
}

# ---------------------------------------------------------------- D017 cancellation states
function Get-DomeniaTaskState {
    # Exact state of one engine job. A job whose native call is still alive is never reported as finished.
    param($Job,[bool]$Detached=$false)
    if ($null -eq $Job) { return 'Completed' }
    if ($Detached) {
        $done = $false
        try { $handle = Get-DomeniaMember $Job 'Handle' $null; if ($null -ne $handle) { $done = [bool]$handle.IsCompleted } else { $done = $true } } catch { $done = $false }
        if ($done) { return 'Completed' }
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
    $cim = @('ComputerDiagnostics','ComputerInventory','SoftwareInventory','WmiNamespaces','WmiClasses','WmiQuery','LiveConsole','ComputerLastUser','ComputerQuickDiag','JoinStateRead','UpdateStateRead','GpoAppliedRead','ComputerEventsRead','MachineIdentityRead','ParkSweep','BatchNetworkDiag')
    $wts = @('SessionsList')
    $storage = @('LocalStore','LiveCache','ReceiptStore','DocumentStore','StorageUsage','StoragePurge','LinkHistoryStore')
    $local = @('CmdletHelp','CmdletInventory','EngineSelfTest','EmbeddedPathBrowse','LocalAssistant','DemoDirectory')
    $network = @('LiveSelectedPing','ComputerPing','SelectedPresence','PresenceScan','WakeOnLanSend','ConnectorRead')
    if ($cim -contains $OperationId) { return 'Cim' }
    if ($wts -contains $OperationId) { return 'Wts' }
    if ($storage -contains $OperationId) { return 'Storage' }
    if ($local -contains $OperationId) { return 'Local' }
    if ($network -contains $OperationId) { return 'Network' }
    return 'Directory'
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
    param($State,[Parameter(Mandatory=$true)][string]$Provider,[string]$Target='',
        [Parameter(Mandatory=$true)][ValidateSet('Success','Failure','Timeout','CredentialRejected','AccessDenied','Cancelled')][string]$Outcome,
        [datetime]$NowUtc=[datetime]::UtcNow)
    if ($null -eq $State) { return $null }
    $key = Get-DomeniaProviderStateKey $Provider $Target
    if (-not $State.ContainsKey($key)) { $State[$key] = [pscustomobject]@{Provider=$Provider;Target=$Target;Failures=0;BackoffUntilUtc=[datetime]::MinValue;CredentialBlocked=$false;LastOutcome='';LastUtc=[datetime]::MinValue} }
    $entry = $State[$key]
    $entry.LastOutcome = $Outcome; $entry.LastUtc = $NowUtc
    switch ($Outcome) {
        'Success' { $entry.Failures = 0; $entry.BackoffUntilUtc = [datetime]::MinValue }
        'Cancelled' { }
        'CredentialRejected' {
            # No timed retry: the same credentials would be rejected again and could lock the account.
            $entry.CredentialBlocked = $true
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
    param($State,[Parameter(Mandatory=$true)][string]$Provider,[string]$Target='',[string]$Class='Explicit',[int]$RunningForProvider=0,[datetime]$NowUtc=[datetime]::UtcNow)
    $budget = Get-DomeniaProviderBudget $Provider
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $State) {
        foreach ($key in @((Get-DomeniaProviderStateKey $Provider $Target),(Get-DomeniaProviderStateKey $Provider ''))) { if ($State.ContainsKey($key)) { $entries.Add($State[$key]) } }
    }
    foreach ($entry in $entries) {
        if ([bool]$entry.CredentialBlocked) { return [pscustomobject]@{Allowed=$false;Reason='Identifiants rejetes pour cette ressource : aucun nouvel essai avant un changement de compte explicite.';RetryAfterUtc=$null;Budget=$budget} }
    }
    foreach ($entry in $entries) {
        if ([datetime]$entry.BackoffUntilUtc -gt $NowUtc -and $Class -ne 'Explicit' -and $Class -ne 'Write') {
            return [pscustomobject]@{Allowed=$false;Reason='Pannes repetees : nouvelles lectures de fond suspendues temporairement.';RetryAfterUtc=[datetime]$entry.BackoffUntilUtc;Budget=$budget}
        }
    }
    if ($Class -eq 'Background' -and $RunningForProvider -ge $budget.MaxConcurrent) {
        return [pscustomobject]@{Allowed=$false;Reason='Concurrence maximale atteinte pour ce fournisseur.';RetryAfterUtc=$null;Budget=$budget}
    }
    return [pscustomobject]@{Allowed=$true;Reason='';RetryAfterUtc=$null;Budget=$budget}
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
    # Releases the resources of one owner (or all). Every release runs even if a previous one failed.
    param($Registry,[string]$Owner='',[int]$Id=0)
    $released = 0; $errors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Registry) { return [pscustomobject]@{Released=0;Failed=0;Errors=@()} }
    foreach ($item in @($Registry.Items.ToArray())) {
        if ($Owner -and $item.Owner -ne $Owner) { continue }
        if ($Id -gt 0 -and $item.Id -ne $Id) { continue }
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
    param([bool]$WindowActive=$true,[bool]$Minimized=$false,[string]$VisiblePage='',[bool]$WriteInFlight=$false,[int]$PendingSaves=0,[bool]$ExplicitActivity=$false)
    $visible = ($WindowActive -and -not $Minimized)
    $reason = 'Fenetre active.'
    if ($Minimized) { $reason = 'Fenetre reduite : rafraichissements suspendus.' }
    elseif (-not $WindowActive) { $reason = 'Fenetre inactive : rafraichissements suspendus.' }
    return [pscustomobject]@{
        Visible=$visible;VisiblePage=$VisiblePage
        # Background refreshes need a visible window; a write in flight also pauses them.
        AllowBackgroundRefresh=($visible -and -not $WriteInFlight)
        AllowHiddenViewRebuild=$false
        # Explicit work, receipts and saves are never abandoned by the idle policy.
        AllowExplicitWork=$true;KeepReceiptTracking=$true;KeepStorageWrites=$true
        PendingSaves=$PendingSaves;WriteInFlight=$WriteInFlight;ExplicitActivity=$ExplicitActivity;Reason=$reason
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
            # A hidden page is rebuilt when it is shown again, not while it is hidden.
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
