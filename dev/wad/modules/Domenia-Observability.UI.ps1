# W13 (points 118, 121, 123, 124): traces of the operations of this session, explained slowness and the redacted
# diagnostic. State kept in memory only, bounded by Get-DomeniaTraceLimits; nothing is written here except through
# Write-DomeniaTrace (Domenia.log, Trace level) and the explicit export of the diagnostic.
$script:DomeniaTraceRing=$null
$script:DomeniaSlowEvents=$null
$script:DomeniaUiWork=$null
$script:DomeniaLastStall=$null

function Get-DomeniaTraceNow {
    # One monotonic clock for every trace, UI work and heartbeat measure (milliseconds).
    return [double]([Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency)
}

function Get-DomeniaTraceRing {
    if ($null -eq $script:DomeniaTraceRing) { $script:DomeniaTraceRing = New-Object System.Collections.Specialized.OrderedDictionary }
    return $script:DomeniaTraceRing
}

function Register-DomeniaTrace {
    # The trace of one request identifier, created at its first job. A full ring drops its oldest finished traces.
    param([Parameter(Mandatory=$true)][string]$TraceId,[string]$OperationId='',[string]$Name='',[bool]$IsWrite=$false,[bool]$Foreground=$true)
    $ring = Get-DomeniaTraceRing
    if ($ring.Contains($TraceId)) { return $ring[$TraceId] }
    $trace = New-DomeniaOperationTrace -TraceId $TraceId -OperationId $OperationId -Name $Name -IsWrite $IsWrite -AtMs (Get-DomeniaTraceNow) -Foreground $Foreground
    $ring[$TraceId] = $trace
    $maximum = [int](Get-DomeniaTraceLimits).MaxTraces
    if ($ring.Count -gt $maximum) {
        foreach ($id in @(Select-DomeniaTraceEviction -Traces @($ring.Values) -Maximum $maximum)) { $ring.Remove([string]$id) }
    }
    return $trace
}

function Get-DomeniaTraceContextHint {
    # A task that feeds a local store context (search, fiche) belongs to the request of that context: its request id
    # (the one of the directory read pipe and of the SQLite commit) becomes the trace identifier.
    param($Payload=$null,$CallbackState=$null)
    $context = Get-DomeniaMemberValue $CallbackState 'StoreContext' $null
    $id = [string](Get-DomeniaMember $context 'RequestId' '')
    if ($id) { return $id }
    $collector = Get-DomeniaMemberValue $Payload 'DirectoryReadState' $null
    if (($null -ne $collector) -and ($null -ne $script:DomeniaDirectoryReads)) {
        foreach ($pipe in @($script:DomeniaDirectoryReads.Values)) {
            if ($null -eq $pipe) { continue }
            if ([object]::ReferenceEquals($pipe.Collector,$collector)) { return [string]$pipe.Context.RequestId }
        }
    }
    return ''
}

function Start-DomeniaJobTrace {
    # Start-UiTask: the job joins the trace of its request (Resolve-DomeniaTraceId): explicit identifier, then the job
    # whose callback is running (the next step of the same request), then its store context, then its own correlation.
    param($Job,[string]$RequestedTraceId='',$Payload=$null,$CallbackState=$null)
    if ($null -eq $Job) { return $null }
    $ambient = ''
    if ($null -ne $script:AccessCurrentJob) { $ambient = [string](Get-DomeniaMember $script:AccessCurrentJob 'TraceId' '') }
    $hint = Get-DomeniaTraceContextHint -Payload $Payload -CallbackState $CallbackState
    $traceId = Resolve-DomeniaTraceId -Requested $RequestedTraceId -Ambient $ambient -ContextRequestId $hint -CorrelationId ([string]$Job.CorrelationId)
    if (-not $traceId) { return $null }
    $Job | Add-Member -NotePropertyName TraceId -NotePropertyValue $traceId -Force
    $foreground = [bool](Get-DomeniaMember $Job 'Foreground' $true)
    $trace = Register-DomeniaTrace -TraceId $traceId -OperationId ([string]$Job.OperationId) -Name ([string]$Job.Name) -IsWrite ([bool]$Job.IsWrite) -Foreground $foreground
    $reference = ConvertTo-DomeniaTraceJobRef ([string]$Job.CorrelationId)
    [void](Add-DomeniaTraceJob -Trace $trace -JobRef $reference -IsWrite ([bool]$Job.IsWrite) -Foreground $foreground)
    [void](Add-DomeniaOperationTraceEvent -Trace $trace -Phase 'Request' -AtMs (Get-DomeniaTraceNow) -Detail ([string]$Job.OperationId) -JobRef $reference)
    return $trace
}

function Add-DomeniaJobTraceEvent {
    # One event on the trace of a job (lecture partagée, lecture locale...). Ignored when the job has no trace.
    param($Job,[Parameter(Mandatory=$true)][string]$Phase,[string]$Detail='',[long]$Volume=-1,[double]$DurationMs=-1)
    if ($null -eq $Job) { return }
    $traceId = [string](Get-DomeniaMember $Job 'TraceId' '')
    $ring = Get-DomeniaTraceRing
    if ((-not $traceId) -or (-not $ring.Contains($traceId))) { return }
    [void](Add-DomeniaOperationTraceEvent -Trace $ring[$traceId] -Phase $Phase -AtMs (Get-DomeniaTraceNow) -Detail $Detail -Volume $Volume -DurationMs $DurationMs -JobRef (ConvertTo-DomeniaTraceJobRef ([string]$Job.CorrelationId)))
}

function Add-DomeniaRequestTraceEvent {
    # One event on the trace of a request id (directory read pipe, store context). A request without trace is ignored:
    # no trace is created from a pipe alone.
    param([string]$RequestId='',[Parameter(Mandatory=$true)][string]$Phase,[string]$Detail='',[long]$Volume=-1,[double]$DurationMs=-1,[switch]$Final)
    $ring = Get-DomeniaTraceRing
    if ((-not $RequestId) -or (-not $ring.Contains($RequestId))) { return }
    $trace = $ring[$RequestId]
    [void](Add-DomeniaOperationTraceEvent -Trace $trace -Phase $Phase -AtMs (Get-DomeniaTraceNow) -Detail $Detail -Volume $Volume -DurationMs $DurationMs)
    if ($Final) { Write-DomeniaTraceSummaryLog -Trace $trace }
}

function Write-DomeniaRequestTraceLog {
    # Summary line of the trace of a request id (fiche relue, pipe without list), when that request has a trace.
    param([string]$RequestId='')
    $ring = Get-DomeniaTraceRing
    if ((-not $RequestId) -or (-not $ring.Contains($RequestId))) { return }
    Write-DomeniaTraceSummaryLog -Trace $ring[$RequestId]
}

function Get-DomeniaJobPhaseMeasures {
    # Queue: from the admission in the queue to the dispatch; Collect: from the dispatch to the end of the worker.
    # Measured from the job dates; -1 for a phase the job did not go through.
    param($Job,[datetime]$WorkerEnd=(Get-Date),[switch]$NotDispatched)
    $now = Get-Date
    $queuedAt = Get-DomeniaMember $Job 'QueuedAt' $null
    $started = Get-DomeniaMember $Job 'Started' $null
    $queueMs = [double]-1; $queueAgoMs = [double]-1; $collectMs = [double]-1; $collectAgoMs = [double]-1
    if ($queuedAt -is [datetime]) {
        $queueEnd = $now
        if ((-not $NotDispatched) -and ($started -is [datetime]) -and ($started -ge $queuedAt)) { $queueEnd = $started }
        $queueMs = [Math]::Max(0,($queueEnd - $queuedAt).TotalMilliseconds)
        $queueAgoMs = [Math]::Max(0,($now - $queuedAt).TotalMilliseconds)
    }
    if ((-not $NotDispatched) -and ($started -is [datetime])) {
        $collectMs = [Math]::Max(0,($WorkerEnd - $started).TotalMilliseconds)
        $collectAgoMs = [Math]::Max(0,($now - $started).TotalMilliseconds)
    }
    return [pscustomobject]@{QueueMs=$queueMs;QueueAgoMs=$queueAgoMs;CollectMs=$collectMs;CollectAgoMs=$collectAgoMs}
}

function Register-DomeniaUiWork {
    # One piece of interface work (callback, timer tick) kept for the attribution of a late heartbeat.
    param([string]$Name='',[string]$OperationId='',[string]$Handler='',[string]$Reference='',[double]$StartMs=0,[double]$EndMs=0)
    if ($null -eq $script:DomeniaUiWork) { $script:DomeniaUiWork = New-Object 'System.Collections.Generic.List[object]' }
    $script:DomeniaUiWork.Add([pscustomobject]@{Name=$Name;OperationId=$OperationId;Handler=$Handler;Reference=$Reference;StartMs=$StartMs;EndMs=$EndMs})
    $maximum = [int](Get-DomeniaTraceLimits).MaxUiWork
    while ($script:DomeniaUiWork.Count -gt $maximum) { $script:DomeniaUiWork.RemoveAt(0) }
}

function Add-DomeniaSlowEvent {
    # Bounded list of the explained slowness of this session, newest last.
    param([string]$Text='',[string]$OperationId='',[string]$Phase='',[string]$Handler='',[double]$DurationMs=-1,[double]$TotalMs=-1,[long]$Volume=-1,[string]$Reference='')
    if ($null -eq $script:DomeniaSlowEvents) { $script:DomeniaSlowEvents = New-Object 'System.Collections.Generic.List[object]' }
    $script:DomeniaSlowEvents.Add([pscustomobject]@{Time=(Get-Date);Text=$Text;OperationId=$OperationId;Phase=$Phase;Handler=$Handler;DurationMs=$DurationMs;TotalMs=$TotalMs;Volume=$Volume;Reference=$Reference})
    $maximum = [int](Get-DomeniaTraceLimits).MaxSlowEvents
    while ($script:DomeniaSlowEvents.Count -gt $maximum) { $script:DomeniaSlowEvents.RemoveAt(0) }
}

function Register-DomeniaJobPublication {
    # The interface callback of a job ran: its own cost (modal waits excluded), the volume it received and its handler
    # are kept for the trace; the work is kept for the heartbeat attribution. Returns the explanation of the slowness
    # when the cost exceeds the threshold, '' otherwise (the caller writes it in its journal line).
    param($Job,[double]$PublishMs=0,[long]$Volume=-1,[double]$ThresholdMs=120,[double]$ValidateMs=-1,[datetime]$WorkerEnd=(Get-Date))
    if ($null -eq $Job) { return '' }
    $now = Get-DomeniaTraceNow
    $Job | Add-Member -NotePropertyName TracePublishMs -NotePropertyValue ([double]$PublishMs) -Force
    $Job | Add-Member -NotePropertyName TraceVolume -NotePropertyValue ([long]$Volume) -Force
    $reference = Get-DomeniaTraceReference ([string](Get-DomeniaMember $Job 'TraceId' ''))
    if ($PublishMs -ge 30) { Register-DomeniaUiWork -Name ([string]$Job.Name) -OperationId ([string]$Job.OperationId) -Handler ([string]$Job.SuccessHandler) -Reference $reference -StartMs ($now - $PublishMs) -EndMs $now }
    if ($PublishMs -le $ThresholdMs) { return '' }
    $measures = Get-DomeniaJobPhaseMeasures -Job $Job -WorkerEnd $WorkerEnd
    $verdict = Get-DomeniaSlownessVerdict -Name ([string]$Job.Name) -OperationId ([string]$Job.OperationId) -Handler ([string]$Job.SuccessHandler) -QueueMs $measures.QueueMs -CollectMs $measures.CollectMs -ValidateMs $ValidateMs -PublishMs $PublishMs -Volume $Volume -PublishThresholdMs $ThresholdMs
    $Job | Add-Member -NotePropertyName TraceSlowRecorded -NotePropertyValue $true -Force
    Add-DomeniaSlowEvent -Text ([string]$verdict.Text) -OperationId ([string]$verdict.OperationId) -Phase ([string]$verdict.Phase) -Handler ([string]$verdict.Handler) -DurationMs ([double]$verdict.DurationMs) -TotalMs ([double]$verdict.TotalMs) -Volume $Volume -Reference $reference
    $text = 'Interface lente : ' + [string]$verdict.Text
    if ($reference) { $text += ' Trace ' + $reference + '.' }
    return $text
}

function Complete-DomeniaJobTrace {
    # One call per end of job (Complete-UiTasks, detachment, withdrawal from the queue). Writes the measured phases of
    # the job in their time order (queue, collect, validation, publication), then its end; idempotent per job. A job
    # slower than five seconds in total is added to the explained slowness of the session.
    param(
        $Job,
        [Parameter(Mandatory=$true)][ValidateSet('Succeeded','Superseded','Withdrawn','Stopped','TimedOut','Refused','Failed','Unknown')][string]$Outcome,
        [double]$ValidateMs=-1,
        [string]$Category='',
        [string]$Detail='',
        [datetime]$WorkerEnd=(Get-Date),
        [switch]$NotDispatched
    )
    if ($null -eq $Job) { return $null }
    if ([bool](Get-DomeniaMember $Job 'TraceClosed' $false)) { return $null }
    $traceId = [string](Get-DomeniaMember $Job 'TraceId' '')
    $ring = Get-DomeniaTraceRing
    if ((-not $traceId) -or (-not $ring.Contains($traceId))) { return $null }
    $Job | Add-Member -NotePropertyName TraceClosed -NotePropertyValue $true -Force
    $trace = $ring[$traceId]
    $now = Get-DomeniaTraceNow
    $reference = ConvertTo-DomeniaTraceJobRef ([string]$Job.CorrelationId)
    $measures = Get-DomeniaJobPhaseMeasures -Job $Job -WorkerEnd $WorkerEnd -NotDispatched:$NotDispatched
    $publishMs = [double](Get-DomeniaMember $Job 'TracePublishMs' -1)
    $volume = [long](Get-DomeniaMember $Job 'TraceVolume' -1)
    if ([double]$measures.QueueMs -ge 0) { [void](Add-DomeniaOperationTraceEvent -Trace $trace -Phase 'Queue' -AtMs ($now - [double]$measures.QueueAgoMs) -DurationMs ([double]$measures.QueueMs) -JobRef $reference) }
    if ([double]$measures.CollectMs -ge 0) {
        $where = ''
        if ([bool](Get-DomeniaMember $Job 'Demo' $false)) { $where = 'démonstration' } elseif ([bool](Get-DomeniaMember $Job 'Isolated' $false)) { $where = 'processus isolé' }
        [void](Add-DomeniaOperationTraceEvent -Trace $trace -Phase 'Collect' -AtMs ($now - [double]$measures.CollectAgoMs) -DurationMs ([double]$measures.CollectMs) -Detail $where -JobRef $reference)
    }
    $afterValidate = [double]0
    if ($publishMs -ge 0) { $afterValidate = $publishMs }
    if ($ValidateMs -ge 0) { [void](Add-DomeniaOperationTraceEvent -Trace $trace -Phase 'Validate' -AtMs ($now - $afterValidate - $ValidateMs) -DurationMs $ValidateMs -JobRef $reference) }
    if ($publishMs -ge 0) { [void](Add-DomeniaOperationTraceEvent -Trace $trace -Phase 'Publish' -AtMs ($now - $publishMs) -DurationMs $publishMs -Volume $volume -Detail ([string]$Job.SuccessHandler) -JobRef $reference) }
    $category = ''
    if ($Category -match '^[A-Za-z]{2,40}$') { $category = $Category }
    [void](Complete-DomeniaTraceJob -Trace $trace -JobRef $reference -Outcome $Outcome -AtMs $now -Category $category -Detail $Detail)
    if (-not [bool](Get-DomeniaMember $Job 'TraceSlowRecorded' $false)) {
        $verdict = Get-DomeniaSlownessVerdict -Name ([string]$Job.Name) -OperationId ([string]$Job.OperationId) -Handler ([string]$Job.SuccessHandler) -QueueMs ([double]$measures.QueueMs) -CollectMs ([double]$measures.CollectMs) -ValidateMs $ValidateMs -PublishMs $publishMs -Volume $volume -PublishThresholdMs ([double]::MaxValue) -TotalThresholdMs 5000
        if ([bool]$verdict.Slow) { Add-DomeniaSlowEvent -Text ([string]$verdict.Text) -OperationId ([string]$verdict.OperationId) -Phase ([string]$verdict.Phase) -Handler ([string]$verdict.Handler) -DurationMs ([double]$verdict.DurationMs) -TotalMs ([double]$verdict.TotalMs) -Volume $volume -Reference ([string]$trace.Reference) }
    }
    if ($trace.OpenJobs.Count -eq 0) { Write-DomeniaTraceSummaryLog -Trace $trace }
    return $trace
}

function Write-DomeniaTraceSummaryLog {
    # One Domenia.log line (Trace level) per finished request: reference, job references, phases and total. No target
    # name: the chain carries operation identifiers, handler names and measures only.
    param($Trace)
    if ($null -eq $Trace) { return }
    try {
        $summary = Get-DomeniaOperationTraceSummary -Trace $Trace -NowMs (Get-DomeniaTraceNow)
        $jobs = ''
        if ($Trace.JobRefs.Count -gt 0) { $jobs = ' tâches ' + ($Trace.JobRefs.ToArray() -join ', ') + ' :' }
        Write-DomeniaTrace -Area 'Opération' -Text ('[trace ' + [string]$summary.Reference + ']' + $jobs + ' ' + [string]$summary.OperationId + ' ' + [string]$summary.Text + ' ; total ' + [string]$summary.TotalText + '.')
    } catch { }
}

function Register-DomeniaDispatcherLateness {
    # Guard heartbeat: a lateness of 400 ms or more is explained by the interface work that overlapped it (at most one
    # explanation every five seconds, unless a longer one). Domenia.log keeps the line; the Santé block shows it.
    param([double]$LateMs=0)
    if ($LateMs -lt 400) { return $null }
    $now = Get-DomeniaTraceNow
    if (($null -ne $script:DomeniaLastStall) -and (($now - [double]$script:DomeniaLastStall.AtMs) -lt 5000) -and ($LateMs -le [double]$script:DomeniaLastStall.LateMs)) { return $null }
    $recent = @()
    if ($null -ne $script:DomeniaUiWork) { $recent = $script:DomeniaUiWork.ToArray() }
    $attribution = Get-DomeniaStallAttribution -LateMs $LateMs -NowMs $now -Recent $recent -ThresholdMs 400
    if ($null -eq $attribution) { return $null }
    $script:DomeniaLastStall = [pscustomobject]@{AtMs=$now;LateMs=$LateMs}
    $operation = ''; $handler = ''; $reference = ''
    if ([bool]$attribution.Attributed) {
        $first = @($attribution.Culprits)[0].Work
        $operation = [string](Get-DomeniaMember $first 'OperationId' ''); $handler = [string](Get-DomeniaMember $first 'Handler' ''); $reference = [string](Get-DomeniaMember $first 'Reference' '')
    }
    Add-DomeniaSlowEvent -Text ([string]$attribution.Text) -OperationId $operation -Phase 'Stall' -Handler $handler -DurationMs $LateMs -Reference $reference
    Write-DomeniaTrace -Area 'Lenteur' -Text ([string]$attribution.Text)
    return $attribution
}

function Get-DomeniaSlowEventLines {
    # The latest explained slowness for the Santé block, newest first.
    param([int]$Maximum=3)
    if (($null -eq $script:DomeniaSlowEvents) -or ($script:DomeniaSlowEvents.Count -eq 0)) { return @() }
    $items = $script:DomeniaSlowEvents.ToArray()
    $out = New-Object 'System.Collections.Generic.List[string]'
    for ($i = $items.Count - 1; ($i -ge 0) -and ($out.Count -lt $Maximum); $i--) {
        $out.Add(([datetime]$items[$i].Time).ToString('HH:mm:ss') + ' · ' + [string]$items[$i].Text)
    }
    return $out.ToArray()
}

function Get-DomeniaRecentTraceRows {
    # Rows of « Dernières opérations », newest first. The end is read by a glyph and a word (Get-DomeniaStatusGlyph);
    # an open trace says « En cours ». Detail: the phase chain and what the operator can do next.
    param([int]$Maximum=20)
    $ring = Get-DomeniaTraceRing
    $now = Get-DomeniaTraceNow
    $traces = @($ring.Values | Where-Object { Test-DomeniaTraceListed $_ } | Sort-Object -Property @{Expression={[double]$_.StartedMs};Descending=$true} | Select-Object -First ([Math]::Max(1,$Maximum)))
    foreach ($trace in $traces) {
        $summary = Get-DomeniaOperationTraceSummary -Trace $trace -NowMs $now
        $glyph = Get-DomeniaStatusGlyph ([string]$summary.OutcomeStatus)
        $advice = ''
        if (-not [bool]$summary.Open) { $advice = Get-DomeniaTraceAdvice -Outcome ([string]$summary.Outcome) -IsWrite ([bool]$trace.IsWrite) -Category ([string]$summary.Category) -Reference ([string]$summary.Reference) }
        $state = [string]$glyph.Glyph + ' ' + [string]$summary.OutcomeLabel
        if ([bool]$summary.Open) { $state = [string]$glyph.Glyph + ' En cours' }
        $phase = ''
        if ([string]$summary.DominantLabel) { $phase = [string]$summary.DominantLabel }
        $detail = [string]$summary.Name + ' (' + [string]$summary.Kind + ', réf. ' + [string]$summary.Reference + ') : ' + [string]$summary.Text + '.'
        if ($advice) { $detail += [Environment]::NewLine + $advice }
        [pscustomobject]@{Id=[string]$summary.TraceId;State=$state;Name=[string]$summary.Name;Kind=[string]$summary.Kind;Duration=[string]$summary.TotalText;Phase=$phase;Reference=[string]$summary.Reference;Detail=$detail}
    }
}

function Get-DomeniaDiagnosticInputs {
    # Inputs of New-DomeniaRedactedDiagnostic, read from this session only (no network, no disk).
    $versions = [ordered]@{Domenia=[string]$script:Version;Build=[string]$script:MasterBuild;PowerShell=[string]$PSVersionTable.PSVersion;Bitness=$(if ([Environment]::Is64BitProcess) { '64' } else { '32' });UiProfile=[string]$script:CurrentUiProfile}
    try { $versions['Clr'] = [string][Environment]::Version } catch { }
    try { $versions['Os'] = [string][Environment]::OSVersion.Version } catch { }
    $counters = [ordered]@{Tasks=0;QueuedTasks=0;DetachedReads=0;ReadOnly=[bool]$script:ReadOnlyMode;DemoMode=[bool]$script:DemoMode;WriteStateUnknown=([string]$script:WriteState -in @('Unknown','UnknownPending'))}
    if ($null -ne $script:AsyncJobs) {
        foreach ($job in @($script:AsyncJobs.Values)) {
            if ($null -eq $job) { continue }
            if ([string]$job.State -eq 'Queued') { $counters['QueuedTasks'] = [int]$counters['QueuedTasks'] + 1 } else { $counters['Tasks'] = [int]$counters['Tasks'] + 1 }
        }
    }
    if ($null -ne $script:DetachedReadJobs) { $counters['DetachedReads'] = @($script:DetachedReadJobs).Count }
    try { $counters['ReceiptPending'] = [int]$script:ReceiptPending } catch { }
    if ($null -ne $script:Persistence) { try { $counters['PendingLocalWrites'] = [int]$script:Persistence.Pending.Count; $counters['LocalWriteFailures'] = [int]$script:Persistence.Failures } catch { } }
    try { $process = [Diagnostics.Process]::GetCurrentProcess(); try { $counters['MemoryMb'] = [Math]::Round($process.PrivateMemorySize64 / 1MB) } finally { $process.Dispose() } } catch { }
    try { $pulse = Get-DomeniaRuntimeMetricSummary -Provenance 'Dispatcher' -Prefix 'Pulse'; if ([int]$pulse.Count -gt 0) { $counters['DispatcherP50Ms'] = [double]$pulse.P50; $counters['DispatcherP95Ms'] = [double]$pulse.P95 } } catch { }
    $metrics = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $script:DomeniaRuntimeMetrics) {
        foreach ($key in @($script:DomeniaRuntimeMetrics.Keys | Sort-Object)) {
            $parts = ([string]$key).Split([char]'|',2)
            if ($parts.Count -ne 2) { continue }
            $values = @($script:DomeniaRuntimeMetrics[$key] | ForEach-Object { [double]$_ })
            if ($values.Count -eq 0) { continue }
            $sorted = @($values | Sort-Object)
            $metrics.Add([pscustomobject]@{Provenance=$parts[0];OperationId=$parts[1];Count=$values.Count;P50=(Get-DomeniaPercentile $values 50);P95=(Get-DomeniaPercentile $values 95);Max=[double]$sorted[$sorted.Count - 1]})
        }
    }
    $errors = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $script:DomeniaErrorOccurrences) {
        foreach ($signature in @($script:DomeniaErrorOccurrences.Keys)) {
            $entry = $script:DomeniaErrorOccurrences[$signature]
            # Signature = type|message|source (Get-DomeniaErrorSignature): the message is never read here.
            $segments = ([string]$signature).Split([char]'|')
            $where = ''
            $located = [regex]::Match([string]$segments[$segments.Count - 1],'([A-Za-z0-9_.-]{1,80}\.ps1:[0-9]{1,6})$')
            if (($segments.Count -ge 3) -and $located.Success) { $where = [string]$located.Groups[1].Value }
            $errors.Add([pscustomobject]@{Code=[string]$entry.Code;Count=[int]$entry.Count;Type=[string]$segments[0];Where=$where})
        }
    }
    $counters['ErrorsDistinct'] = $errors.Count
    $ring = Get-DomeniaTraceRing
    $counters['TracesKept'] = $ring.Count
    $now = Get-DomeniaTraceNow
    $traces = @($ring.Values | ForEach-Object { Get-DomeniaOperationTraceSummary -Trace $_ -NowMs $now })
    $slow = @()
    if ($null -ne $script:DomeniaSlowEvents) { $slow = $script:DomeniaSlowEvents.ToArray() }
    return [pscustomobject]@{Versions=[pscustomobject]$versions;Counters=[pscustomobject]$counters;Metrics=$metrics.ToArray();Errors=$errors.ToArray();Traces=$traces;Slow=$slow}
}

function New-DomeniaSessionDiagnostic {
    # The redacted diagnostic of this session and its JSON text, ready for the preview.
    $inputs = Get-DomeniaDiagnosticInputs
    $diagnostic = New-DomeniaRedactedDiagnostic -Versions $inputs.Versions -Counters $inputs.Counters -Metrics $inputs.Metrics -Errors $inputs.Errors -Traces $inputs.Traces -Slow $inputs.Slow -CapturedUtc ([datetime]::UtcNow.ToString('o'))
    return [pscustomobject]@{Diagnostic=$diagnostic;Json=($diagnostic | ConvertTo-Json -Depth 6);Preview=(Get-DomeniaDiagnosticPreviewText -Diagnostic $diagnostic)}
}

# ---------------------------------------------------------------- operations panel (points 118, 123, 124)
$script:DomeniaOperationsRecentSignature=''

function Sync-DomeniaOperationsRecent {
    # « Dernières opérations »: rebuilt only when a trace changed (or an open one ages), the selection kept by trace.
    # The signature is read on the traces themselves (cheap, once a second while the panel is open); the rows, their
    # summaries and advice are built only when it changes. An open trace ages by whole seconds.
    $grid = Get-DomeniaControl 'DgOperationsRecent'
    if ($null -eq $grid) { return }
    $now = Get-DomeniaTraceNow
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($trace in @((Get-DomeniaTraceRing).Values)) {
        $part = [string]$trace.TraceId + '=' + [string]$trace.Outcome + '/' + [string]$trace.OpenJobs.Count + '/' + [string]$trace.Events.Count
        if ($trace.OpenJobs.Count -gt 0) { $part += '/' + [string][long][Math]::Floor(($now - [double]$trace.StartedMs) / 1000) }
        $parts.Add($part)
    }
    $signature = $parts.ToArray() -join '|'
    if ($signature -ceq [string]$script:DomeniaOperationsRecentSignature) { return }
    $script:DomeniaOperationsRecentSignature = $signature
    $rows = @(Get-DomeniaRecentTraceRows -Maximum 20)
    $selected = ''
    if ($null -ne $grid.SelectedItem) { $selected = [string]$grid.SelectedItem.Id }
    $grid.ItemsSource = $rows
    if ($selected) { foreach ($row in $rows) { if ([string]$row.Id -ceq $selected) { $grid.SelectedItem = $row; break } } }
    Update-DomeniaOperationsTraceDetail
}

function Update-DomeniaOperationsTraceDetail {
    # Detail of the chosen operation: its steps with their own measures and what can be done next.
    $grid = Get-DomeniaControl 'DgOperationsRecent'
    $row = $null
    if ($null -ne $grid) { $row = $grid.SelectedItem }
    $text = 'Sélectionnez une opération pour lire ses étapes : demande, file dʼattente, collecte, validation, lecture locale et publication.'
    if ($null -ne $row) { $text = [string]$row.Detail }
    elseif (($null -ne $grid) -and (@($grid.Items).Count -eq 0)) { $text = 'Aucune opération suivie depuis lʼouverture de cette session.' }
    [void](Set-DomeniaControlText 'LblOperationsTrace' $text)
    $copy = Get-DomeniaControl 'BtnOperationsCopyTrace'
    if ($null -ne $copy) { $copy.IsEnabled = ($null -ne $row) }
}

function Copy-DomeniaOperationsTrace {
    $grid = Get-DomeniaControl 'DgOperationsRecent'
    if (($null -eq $grid) -or ($null -eq $grid.SelectedItem)) { Set-Status 'Sélectionnez une opération à copier.' 'WARN'; return }
    try {
        Set-ClipboardSafe (Protect-DomeniaLogText ([string]$grid.SelectedItem.Detail))
        Set-Status 'Détail de lʼopération copié. Le nom de la cible peut y figurer : relisez avant envoi.'
    } catch { Set-Status ('Copie impossible : ' + $_.Exception.Message) 'WARN' }
}

function Open-DomeniaOperationsJournal {
    # Same route as Ctrl+L: the session journal in Essentiel, Outils > Journal in Expert.
    Hide-DomeniaOperationsPanel
    try { Invoke-DomeniaJournalShortcut } catch { Write-AppLog ('Ouverture du journal : ' + $_.Exception.Message) 'WARN' }
}

function Start-DomeniaOperationsDiagnostic {
    # The preview of the diagnostic takes the dialog layer: the panel is closed first, the operations continue.
    Hide-DomeniaOperationsPanel
    Invoke-DomeniaSafeUiAction -Operation 'Diagnostic expurgé' -Action { Export-DomeniaTechnicalDossier }
}
