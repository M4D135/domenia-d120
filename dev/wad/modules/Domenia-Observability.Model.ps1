# W13 (points 121, 123, 124): operation traces, attribution of slowness and redacted diagnostic.
# Pure rules: no WPF, no network, no disk and no clock read. The caller gives the times (milliseconds of one monotonic
# clock) and the values; nothing here reads the process, the session or the directory.

function Get-DomeniaTraceLimits {
    # Explicit bounds of the observability state kept in memory for one session.
    return [pscustomobject]@{MaxEvents=32;MaxTraces=64;MaxSlowEvents=16;MaxUiWork=32;DetailLength=120;NameLength=80}
}

function Get-DomeniaTracePhases {
    # Closed catalogue of the phases of one operation. Measured: the phase carries a duration of its own.
    return @(
        [pscustomobject]@{Code='Request';Label='Demande';Measured=$false}
        [pscustomobject]@{Code='Queue';Label='File dʼattente';Measured=$true}
        [pscustomobject]@{Code='Shared';Label='Lecture partagée';Measured=$false}
        [pscustomobject]@{Code='Collect';Label='Collecte';Measured=$true}
        [pscustomobject]@{Code='Validate';Label='Validation';Measured=$true}
        [pscustomobject]@{Code='StoreRead';Label='Lecture locale';Measured=$true}
        [pscustomobject]@{Code='Publish';Label='Publication dans lʼinterface';Measured=$true}
        [pscustomobject]@{Code='End';Label='Fin';Measured=$false}
    )
}

function Get-DomeniaTraceOutcomes {
    # Closed catalogue of the ends of an operation. Rank: the worst end of the jobs of one trace is the one shown.
    # Status: key of Get-DomeniaStatusGlyph, so that every end is read by a glyph and a word, not by a colour.
    return @(
        [pscustomobject]@{Code='Succeeded';Label='Terminée';Status='Success';Rank=0}
        [pscustomobject]@{Code='Superseded';Label='Remplacée par une demande plus récente';Status='Info';Rank=1}
        [pscustomobject]@{Code='Withdrawn';Label='Retirée de la file avant envoi';Status='Info';Rank=1}
        [pscustomobject]@{Code='Stopped';Label='Arrêtée';Status='Warning';Rank=2}
        [pscustomobject]@{Code='TimedOut';Label='Délai dépassé';Status='Warning';Rank=3}
        [pscustomobject]@{Code='Refused';Label='Refusée avant envoi';Status='Refused';Rank=4}
        [pscustomobject]@{Code='Failed';Label='Échec';Status='Error';Rank=5}
        [pscustomobject]@{Code='Unknown';Label='Résultat inconnu : relire avant toute nouvelle tentative';Status='Uncertain';Rank=6}
    )
}

function Get-DomeniaTraceOutcome {
    # One entry of the catalogue; an unknown code is refused rather than shown as a success.
    param([AllowEmptyString()][string]$Code='')
    foreach ($row in @(Get-DomeniaTraceOutcomes)) { if ([string]$row.Code -ceq $Code) { return $row } }
    return $null
}

function Get-DomeniaTraceReference {
    # Short reference read on a screen and searched in Domenia.log: the first eight characters of the identifier.
    param([AllowEmptyString()][string]$TraceId='')
    $compact = ([string]$TraceId -replace '[^A-Za-z0-9]','').ToLowerInvariant()
    if ($compact.Length -lt 8) { return '' }
    return $compact.Substring(0,8)
}

function Resolve-DomeniaTraceId {
    # The identifier shared by the events of one request: an explicit one first, then the request of the work in
    # progress (a callback that starts the next step), then the request id of the local store context, otherwise the
    # task correlation identifier. A value that is not an identifier is ignored, never copied.
    param([AllowEmptyString()][string]$Requested='',[AllowEmptyString()][string]$Ambient='',[AllowEmptyString()][string]$ContextRequestId='',[AllowEmptyString()][string]$CorrelationId='')
    foreach ($candidate in @($Requested,$Ambient,$ContextRequestId,$CorrelationId)) {
        if ([string]$candidate -match '^[A-Za-z0-9-]{8,64}$') { return [string]$candidate }
    }
    return ''
}

function New-DomeniaOperationTrace {
    # One request followed from the operator gesture to the publication in the interface.
    # Foreground: the request comes from an operator gesture (write, explicit read, selection); automatic work is not.
    param([Parameter(Mandatory=$true)][string]$TraceId,[AllowEmptyString()][string]$OperationId='',[AllowEmptyString()][string]$Name='',[bool]$IsWrite=$false,[double]$AtMs=0,[bool]$Foreground=$true)
    if ($TraceId -notmatch '^[A-Za-z0-9-]{8,64}$') { throw 'Identifiant de trace invalide.' }
    $limits = Get-DomeniaTraceLimits
    $operation = ''
    if ($OperationId -match '^[A-Za-z][A-Za-z0-9]{2,63}$') { $operation = $OperationId }
    $label = ConvertTo-DomeniaFlatText $Name ([int]$limits.NameLength)
    if (-not $label) { $label = $operation }
    $kind = 'Lecture'
    if ($IsWrite) { $kind = 'Écriture' }
    return [pscustomobject]@{
        TraceId=$TraceId;Reference=(Get-DomeniaTraceReference $TraceId);OperationId=$operation;Name=$label;Kind=$kind;IsWrite=[bool]$IsWrite;Foreground=[bool]$Foreground
        StartedMs=[double]$AtMs;EndedMs=[double]-1;LastMs=[double]$AtMs;Outcome='';Category=''
        OpenJobs=(New-Object 'System.Collections.Generic.List[string]');JobRefs=(New-Object 'System.Collections.Generic.List[string]');Jobs=0
        Events=(New-Object 'System.Collections.Generic.List[object]');Dropped=0
    }
}

function Add-DomeniaTraceJob {
    # A job (worker) joins the trace; the trace stays open while one of its jobs runs.
    # -Stage: a step of the request carried by the interface, not by a worker (the directory read pipe that stores,
    # reads back and publishes the rows of a search or a fiche). It keeps the trace open like a job, but it is neither
    # counted as a job nor listed among the job references of Domenia.log.
    param([Parameter(Mandatory=$true)]$Trace,[AllowEmptyString()][string]$JobRef='',[bool]$IsWrite=$false,[bool]$Foreground=$false,[switch]$Stage)
    $reference = ConvertTo-DomeniaTraceJobRef $JobRef
    if ($reference -and -not $Trace.OpenJobs.Contains($reference)) {
        $Trace.OpenJobs.Add($reference)
        if (-not $Stage) { $Trace.Jobs = [int]$Trace.Jobs + 1 }
    }
    # The first eight job references are kept: they are the [correlation] prefixes of the lines of Domenia.log.
    if ((-not $Stage) -and $reference -and ($Trace.JobRefs.Count -lt 8) -and -not $Trace.JobRefs.Contains($reference)) { $Trace.JobRefs.Add($reference) }
    if ($IsWrite -and -not [bool]$Trace.IsWrite) { $Trace.IsWrite = $true; $Trace.Kind = 'Écriture' }
    if ($Foreground -or $IsWrite) { $Trace.Foreground = $true }
    $Trace.EndedMs = [double]-1
    return $Trace
}

function ConvertTo-DomeniaTraceJobRef {
    # Short job reference (first eight characters of its correlation identifier); anything else is dropped.
    param([AllowEmptyString()][string]$JobRef='')
    $compact = ([string]$JobRef -replace '[^A-Za-z0-9]','').ToLowerInvariant()
    if ($compact.Length -lt 4) { return '' }
    if ($compact.Length -gt 8) { $compact = $compact.Substring(0,8) }
    return $compact
}

function Add-DomeniaOperationTraceEvent {
    # Appends one event. Streaming phases (local reads, publications) arrive by batches: consecutive batches of one
    # phase are merged, so a search of thousands of rows stays a handful of events. Bounded: past MaxEvents only the
    # end is kept, in place of the oldest event after the request; the other events are counted as dropped.
    param(
        [Parameter(Mandatory=$true)]$Trace,
        [Parameter(Mandatory=$true)][string]$Phase,
        [double]$AtMs=0,
        [AllowEmptyString()][string]$Detail='',
        [long]$Volume=-1,
        [double]$DurationMs=-1,
        [AllowEmptyString()][string]$JobRef=''
    )
    $phaseRow = $null
    foreach ($row in @(Get-DomeniaTracePhases)) { if ([string]$row.Code -ceq $Phase) { $phaseRow = $row } }
    if ($null -eq $phaseRow) { throw 'Phase de trace hors catalogue.' }
    $limits = Get-DomeniaTraceLimits
    $events = $Trace.Events
    $detailText = ConvertTo-DomeniaFlatText $Detail ([int]$limits.DetailLength)
    $reference = ConvertTo-DomeniaTraceJobRef $JobRef
    if ([double]$AtMs -gt [double]$Trace.LastMs) { $Trace.LastMs = [double]$AtMs }
    # An event that arrives after the end of a closed trace moves its end: the total never leaves out a step.
    if (([double]$Trace.EndedMs -ge 0) -and ([double]$AtMs -gt [double]$Trace.EndedMs)) { $Trace.EndedMs = [double]$AtMs }
    if (($events.Count -gt 0) -and ($Phase -in @('StoreRead','Publish'))) {
        # Only batches of one source merge: the callback of a job and the rows handed to the list stay apart.
        $last = $events[$events.Count - 1]
        if (([string]$last.Phase -ceq $Phase) -and ([string]$last.JobRef -ceq $reference)) {
            $last.Batches = [int]$last.Batches + 1
            if ([double]$AtMs -gt [double]$last.LastAtMs) { $last.LastAtMs = [double]$AtMs }
            if ($Volume -ge 0) {
                if ([long]$last.Volume -lt 0) { $last.Volume = [long]0; $last.VolumeComplete = $false }
                $last.Volume = [long]$last.Volume + $Volume
            } else { $last.VolumeComplete = $false }
            if ($DurationMs -ge 0) {
                if ([double]$last.DurationMs -lt 0) { $last.DurationMs = [double]0; $last.DurationComplete = $false }
                $last.DurationMs = [double]$last.DurationMs + $DurationMs
            } else { $last.DurationComplete = $false }
            return $Trace
        }
    }
    if ($events.Count -ge [int]$limits.MaxEvents) {
        if ($Phase -cne 'End') { $Trace.Dropped = [int]$Trace.Dropped + 1; return $Trace }
        if ($events.Count -gt 1) { $events.RemoveAt(1); $Trace.Dropped = [int]$Trace.Dropped + 1 }
    }
    $events.Add([pscustomobject]@{
        Phase=$Phase;Label=[string]$phaseRow.Label;AtMs=[double]$AtMs;LastAtMs=[double]$AtMs;Detail=$detailText
        Volume=[long]$Volume;VolumeComplete=($Volume -ge 0);DurationMs=[double]$DurationMs;DurationComplete=($DurationMs -ge 0)
        Batches=1;JobRef=$reference;Outcome=''
    })
    return $Trace
}

function Complete-DomeniaTraceJob {
    # One job of the trace ended. The trace takes the worst end of its jobs (Get-DomeniaTraceOutcomes) and is closed
    # once no job remains open; a category is a short code (AccessDenied, Timeout...), never an error message.
    param([Parameter(Mandatory=$true)]$Trace,[AllowEmptyString()][string]$JobRef='',[Parameter(Mandatory=$true)][string]$Outcome,[double]$AtMs=0,[AllowEmptyString()][string]$Category='',[AllowEmptyString()][string]$Detail='')
    $row = Get-DomeniaTraceOutcome $Outcome
    if ($null -eq $row) { throw 'Fin de trace hors catalogue.' }
    $reference = ConvertTo-DomeniaTraceJobRef $JobRef
    [void](Add-DomeniaOperationTraceEvent -Trace $Trace -Phase 'End' -AtMs $AtMs -Detail $Detail -JobRef $reference)
    $Trace.Events[$Trace.Events.Count - 1].Outcome = [string]$row.Code
    if ($reference) { [void]$Trace.OpenJobs.Remove($reference) }
    $previous = Get-DomeniaTraceOutcome ([string]$Trace.Outcome)
    if (($null -eq $previous) -or ([int]$row.Rank -ge [int]$previous.Rank)) {
        $Trace.Outcome = [string]$row.Code
        if ($Category -match '^[A-Za-z]{2,40}$') { $Trace.Category = $Category } elseif ([int]$row.Rank -gt 0) { $Trace.Category = '' }
    }
    if ($Trace.OpenJobs.Count -eq 0) { $Trace.EndedMs = [double]$AtMs }
    return $Trace
}

function Format-DomeniaDurationText {
    # French duration for an operator: < 1 ms, 850 ms, 2,3 s, 1 min 05 s. A negative value was not measured.
    param([double]$Milliseconds)
    if ($Milliseconds -lt 0) { return 'non mesurée' }
    if ($Milliseconds -lt 1) { return '< 1 ms' }
    if ($Milliseconds -lt 1000) { return ([string][Math]::Round($Milliseconds)) + ' ms' }
    if ($Milliseconds -lt 60000) {
        $seconds = [Math]::Round($Milliseconds / 1000.0,1)
        return $seconds.ToString('0.0',[Globalization.CultureInfo]::InvariantCulture).Replace('.',',') + ' s'
    }
    $whole = [long][Math]::Round($Milliseconds / 1000.0)
    return ([string][long][Math]::Floor($whole / 60)) + ' min ' + ($whole % 60).ToString('00',[Globalization.CultureInfo]::InvariantCulture) + ' s'
}

function Format-DomeniaVolumeText {
    # Number of items handled; an incomplete count (one batch not counted) says « au moins ».
    param([long]$Volume=-1,[bool]$Complete=$true)
    if ($Volume -lt 0) { return 'volume non mesuré' }
    $text = [string]$Volume + ' élément'
    if ($Volume -gt 1) { $text += 's' }
    if (-not $Complete) { $text = 'au moins ' + $text }
    return $text
}

function Get-DomeniaOperationTraceSummary {
    # Reading of one trace: phases in time order with their own measures, total, dominant phase and end.
    # Durations are those measured at the source (worker, callback, store); nothing is inferred from the gaps
    # between events, because streaming phases overlap.
    param([Parameter(Mandatory=$true)]$Trace,[double]$NowMs=-1)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    foreach ($traceEvent in $Trace.Events) { $rows.Add([pscustomobject]@{Event=$traceEvent;Index=$index;AtMs=[double]$traceEvent.AtMs}); $index++ }
    $ordered = @($rows.ToArray() | Sort-Object -Property @{Expression={[double]$_.AtMs}},@{Expression={[int]$_.Index}})
    $measured = @{}
    foreach ($phase in @(Get-DomeniaTracePhases)) { $measured[[string]$phase.Code] = [bool]$phase.Measured }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $phases = New-Object 'System.Collections.Generic.List[object]'
    $dominant = ''; $dominantLabel = ''; $dominantMs = [double]-1
    foreach ($row in $ordered) {
        $traceEvent = $row.Event
        $text = [string]$traceEvent.Label
        if ([string]$traceEvent.Phase -ceq 'End') {
            $end = Get-DomeniaTraceOutcome ([string]$traceEvent.Outcome)
            if ($null -ne $end) { $text = 'Fin : ' + [string]$end.Label }
        } else {
            $bits = New-Object 'System.Collections.Generic.List[string]'
            if ([double]$traceEvent.DurationMs -ge 0) {
                $prefix = ''
                if (-not [bool]$traceEvent.DurationComplete) { $prefix = 'au moins ' }
                $bits.Add($prefix + (Format-DomeniaDurationText ([double]$traceEvent.DurationMs)))
            }
            if ([long]$traceEvent.Volume -ge 0) { $bits.Add((Format-DomeniaVolumeText -Volume ([long]$traceEvent.Volume) -Complete ([bool]$traceEvent.VolumeComplete))) }
            if ([int]$traceEvent.Batches -gt 1) { $bits.Add([string]$traceEvent.Batches + ' lots') }
            if ([string]$traceEvent.Detail) { $bits.Add([string]$traceEvent.Detail) }
            if ($bits.Count -gt 0) { $text += ' ' + ($bits.ToArray() -join ', ') }
        }
        $parts.Add($text)
        $phases.Add([pscustomobject]@{Phase=[string]$traceEvent.Phase;Label=[string]$traceEvent.Label;DurationMs=[double]$traceEvent.DurationMs;Volume=[long]$traceEvent.Volume;Batches=[int]$traceEvent.Batches;Outcome=[string]$traceEvent.Outcome})
        if ([bool]$measured[[string]$traceEvent.Phase] -and ([double]$traceEvent.DurationMs -gt $dominantMs)) {
            $dominant = [string]$traceEvent.Phase; $dominantLabel = [string]$traceEvent.Label; $dominantMs = [double]$traceEvent.DurationMs
        }
    }
    $open = ($Trace.OpenJobs.Count -gt 0)
    $total = [double]$Trace.LastMs - [double]$Trace.StartedMs
    if ([double]$Trace.EndedMs -ge 0) { $total = [double]$Trace.EndedMs - [double]$Trace.StartedMs }
    elseif ($open -and ($NowMs -ge 0)) { $total = $NowMs - [double]$Trace.StartedMs }
    if ($total -lt 0) { $total = 0 }
    $outcome = Get-DomeniaTraceOutcome ([string]$Trace.Outcome)
    $outcomeLabel = 'En cours'; $outcomeStatus = 'Pending'
    if ($null -ne $outcome) { $outcomeLabel = [string]$outcome.Label; $outcomeStatus = [string]$outcome.Status }
    if ($open -and ($null -ne $outcome)) { $outcomeLabel = 'En cours (' + [string]$outcome.Label + ' pour une étape)' }
    if ($open) { $outcomeStatus = 'Pending' }
    $chain = ($parts.ToArray() -join (' ' + [string][char]0x2192 + ' '))
    if ([int]$Trace.Dropped -gt 0) { $chain += ' (' + [string]$Trace.Dropped + ' événement(s) non conservé(s))' }
    return [pscustomobject]@{
        TraceId=[string]$Trace.TraceId;Reference=[string]$Trace.Reference;OperationId=[string]$Trace.OperationId;Name=[string]$Trace.Name;Kind=[string]$Trace.Kind
        Open=$open;Outcome=[string]$Trace.Outcome;OutcomeLabel=$outcomeLabel;OutcomeStatus=$outcomeStatus;Category=[string]$Trace.Category
        TotalMs=$total;TotalText=(Format-DomeniaDurationText $total);Dominant=$dominant;DominantLabel=$dominantLabel;DominantMs=$dominantMs
        Phases=$phases.ToArray();Text=$chain;Dropped=[int]$Trace.Dropped
    }
}

function Test-DomeniaTraceListed {
    # « Dernières opérations » lists the requests of the operator and, among the automatic ones, only those that did not
    # end well (out of time, refused, failed, unknown): a burst of background saves never hides a search or a write.
    param([Parameter(Mandatory=$true)]$Trace)
    if ([bool]$Trace.Foreground -or [bool]$Trace.IsWrite) { return $true }
    $outcome = Get-DomeniaTraceOutcome ([string]$Trace.Outcome)
    return (($Trace.OpenJobs.Count -eq 0) -and ($null -ne $outcome) -and ([int]$outcome.Rank -ge 3))
}

function Select-DomeniaTraceEviction {
    # Which traces leave a full ring: finished automatic ones first, then finished operator requests, oldest first;
    # an open one only as a last resort.
    param([object[]]$Traces=@(),[int]$Maximum=64)
    $all = @($Traces | Where-Object { $null -ne $_ })
    $excess = $all.Count - [Math]::Max(1,$Maximum)
    if ($excess -le 0) { return @() }
    $background = @($all | Where-Object { ($_.OpenJobs.Count -eq 0) -and -not (Test-DomeniaTraceListed $_) } | Sort-Object -Property @{Expression={[double]$_.LastMs}})
    $finished = @($all | Where-Object { ($_.OpenJobs.Count -eq 0) -and (Test-DomeniaTraceListed $_) } | Sort-Object -Property @{Expression={[double]$_.LastMs}})
    $open = @($all | Where-Object { $_.OpenJobs.Count -gt 0 } | Sort-Object -Property @{Expression={[double]$_.StartedMs}})
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($trace in @($background + $finished + $open)) {
        if ($out.Count -ge $excess) { break }
        $out.Add([string]$trace.TraceId)
    }
    return $out.ToArray()
}

function Get-DomeniaOutputVolume {
    # Number of items handed back to the interface, read without enumerating anything: -1 when it cannot be known
    # cheaply (a lazy sequence is never walked to count it).
    param($Output)
    if ($null -eq $Output) { return [long]0 }
    if (($Output -is [string]) -or ($Output -is [ValueType])) { return [long]1 }
    $names = @('Rows','Items','Results','Objects','Records','Entries')
    if ($Output -is [Collections.IDictionary]) {
        foreach ($name in $names) {
            $value = Get-DomeniaMemberValue $Output $name $null
            if ($value -is [Collections.ICollection]) { return [long]$value.Count }
        }
        return [long]1
    }
    if ($Output -is [Collections.ICollection]) { return [long]$Output.Count }
    # A generic collection that is not an ICollection (HashSet, read-only views) still knows its count.
    if ($null -ne $Output.GetType().GetInterface('ICollection`1')) { return [long]$Output.Count }
    foreach ($name in $names) {
        $value = Get-DomeniaMemberValue $Output $name $null
        if ($value -is [Collections.ICollection]) { return [long]$value.Count }
        if (($null -ne $value) -and ($null -ne $value.GetType().GetInterface('ICollection`1'))) { return [long]$value.Count }
        if (($null -ne $value) -and ($value -isnot [string]) -and ($value -is [Collections.IEnumerable])) { return [long]-1 }
    }
    if ($Output -is [Collections.IEnumerable]) { return [long]-1 }
    return [long]1
}

function Get-DomeniaSlownessVerdict {
    # Explains a slowness by the operation, its phases, its volume and the interface handler. A phase that was not
    # measured is said so (« non mesurée »), never counted as zero. Slow: the interface handler exceeded its threshold,
    # or the measured phases together exceeded the total threshold.
    param(
        [AllowEmptyString()][string]$Name='',
        [AllowEmptyString()][string]$OperationId='',
        [AllowEmptyString()][string]$Handler='',
        [double]$QueueMs=-1,
        [double]$CollectMs=-1,
        [double]$ValidateMs=-1,
        [double]$PublishMs=-1,
        [long]$Volume=-1,
        [double]$PublishThresholdMs=120,
        [double]$TotalThresholdMs=5000
    )
    $segments = @(
        @('Queue','la file dʼattente',$QueueMs),@('Collect','la collecte (worker)',$CollectMs),
        @('Validate','la validation',$ValidateMs),@('Publish','le traitement dans lʼinterface',$PublishMs)
    )
    $total = [double]0; $count = 0; $phase = ''; $label = ''; $max = [double]-1
    foreach ($segment in $segments) {
        $value = [double]$segment[2]
        if ($value -lt 0) { continue }
        $total += $value; $count++
        if ($value -gt $max) { $max = $value; $phase = [string]$segment[0]; $label = [string]$segment[1] }
    }
    $slowPublish = (($PublishMs -ge 0) -and ($PublishMs -gt $PublishThresholdMs))
    $slowTotal = (($count -gt 0) -and ($total -gt $TotalThresholdMs))
    if ($slowPublish) { $phase = 'Publish'; $label = 'le traitement dans lʼinterface'; $max = $PublishMs }
    $operation = ''
    if ($OperationId -match '^[A-Za-z][A-Za-z0-9]{2,63}$') { $operation = $OperationId }
    $handlerText = ''
    if ($Handler -match '^[A-Za-z][A-Za-z0-9-]{2,80}$') { $handlerText = $Handler }
    $title = ConvertTo-DomeniaFlatText $Name 80
    if (-not $title) { $title = $operation }
    if (-not $title) { $title = 'Opération' }
    if ($count -eq 0) {
        $text = $title + ' : durée non mesurée.'
    } else {
        $text = $title + ' : ' + (Format-DomeniaDurationText $total) + ', surtout ' + $label + ' (' + (Format-DomeniaDurationText $max) + ')'
        if ($Volume -ge 0) {
            $text += ' pour ' + (Format-DomeniaVolumeText -Volume $Volume)
            if (($phase -ceq 'Publish') -and ($Volume -gt 1) -and ($PublishMs -ge 0)) { $text += ', soit ' + (Format-DomeniaDurationText ($PublishMs / $Volume)) + ' par élément' }
        } else { $text += ' ; volume non mesuré' }
        if ($handlerText) { $text += ' ; traitement ' + $handlerText }
        $text += ' (file ' + (Format-DomeniaDurationText $QueueMs) + ', collecte ' + (Format-DomeniaDurationText $CollectMs) + ', validation ' + (Format-DomeniaDurationText $ValidateMs) + ', interface ' + (Format-DomeniaDurationText $PublishMs) + ').'
    }
    return [pscustomobject]@{
        Slow=($slowPublish -or $slowTotal);Phase=$phase;PhaseLabel=$label;DurationMs=$max;TotalMs=$total;Volume=$Volume
        Handler=$handlerText;OperationId=$operation;Text=$text
    }
}

function Get-DomeniaStallAttribution {
    # A late heartbeat means the Dispatcher was held between the moment it was due and the moment it ran. The work
    # followed by Domenia (callbacks, timer ticks) that overlaps that window is named; when none does, the cause is
    # said to be unattributed (layout, rendering or a call outside the engine), never guessed.
    # $Recent: {Name, OperationId, Handler, Reference, StartMs, EndMs} on the same clock as $NowMs.
    param([double]$LateMs=0,[double]$NowMs=0,[object[]]$Recent=@(),[double]$ThresholdMs=400)
    if ($LateMs -lt $ThresholdMs) { return $null }
    $from = $NowMs - $LateMs
    $culprits = New-Object 'System.Collections.Generic.List[object]'
    foreach ($work in @($Recent)) {
        if ($null -eq $work) { continue }
        $start = [double](Get-DomeniaMember $work 'StartMs' 0); $end = [double](Get-DomeniaMember $work 'EndMs' 0)
        $overlap = [Math]::Min($end,$NowMs) - [Math]::Max($start,$from)
        if ($overlap -le 0) { continue }
        $culprits.Add([pscustomobject]@{Work=$work;OverlapMs=$overlap;DurationMs=($end - $start)})
    }
    $top = @($culprits.ToArray() | Sort-Object -Property @{Expression={[double]$_.OverlapMs};Descending=$true} | Select-Object -First 3)
    $late = Format-DomeniaDurationText $LateMs
    if ($top.Count -eq 0) {
        return [pscustomobject]@{LateMs=$LateMs;Attributed=$false;Culprits=@();Text=('Interface en retard de ' + $late + ' : aucune opération suivie ne lʼexplique (cause non attribuée : mise en page, rendu ou appel hors du moteur).')}
    }
    $names = @(foreach ($item in $top) {
        $work = $item.Work
        $label = ConvertTo-DomeniaFlatText ([string](Get-DomeniaMember $work 'Name' '')) 80
        if (-not $label) { $label = 'Opération' }
        $handler = [string](Get-DomeniaMember $work 'Handler' '')
        if ($handler -match '^[A-Za-z][A-Za-z0-9:-]{2,80}$') { $label += ' (traitement ' + $handler + ', ' + (Format-DomeniaDurationText ([double]$item.DurationMs)) + ')' }
        else { $label += ' (' + (Format-DomeniaDurationText ([double]$item.DurationMs)) + ')' }
        $label
    })
    return [pscustomobject]@{LateMs=$LateMs;Attributed=$true;Culprits=$top;Text=('Interface en retard de ' + $late + ' pendant : ' + ($names -join ' ; ') + '.')}
}

function New-DomeniaRedactedDiagnostic {
    # D124: the support diagnostic is built from an allow-list. Free texts (messages, names, paths, targets) are never
    # copied: a value is kept only when it has the shape of a version, a code identifier or a number, so a name, an
    # address or a secret cannot pass even when a caller hands it by mistake. Bounded: 200 metrics, 200 errors,
    # 64 traces, 16 slowness explanations.
    # Point 145: -Compatibility carries the compatibility of this workstation (Get-DomeniaCompatibilitySupportFields):
    # versions and statuses only, filtered by the same allow-list rule (short codes, numbers, booleans).
    param($Versions=$null,$Counters=$null,[object[]]$Metrics=@(),[object[]]$Errors=@(),[object[]]$Traces=@(),[object[]]$Slow=@(),[AllowEmptyString()][string]$CapturedUtc='',$Compatibility=$null)
    $versionKeys = @('Domenia','Build','PowerShell','Clr','Os','Bitness','UiProfile','Theme')
    $versionsOut = [ordered]@{}
    foreach ($key in $versionKeys) {
        $value = [string](Get-DomeniaMember $Versions $key '')
        if ($value -match '^[A-Za-z0-9 ._()+-]{1,64}$') { $versionsOut[$key] = $value }
    }
    $counterKeys = @('Tasks','QueuedTasks','DetachedReads','ReceiptPending','PendingLocalWrites','LocalWriteFailures','MemoryMb','DispatcherP50Ms','DispatcherP95Ms','ErrorsDistinct','TracesKept','TraceFaults','InterfaceFaults','ReadOnly','DemoMode','WriteStateUnknown')
    $countersOut = [ordered]@{}
    foreach ($key in $counterKeys) {
        $value = Get-DomeniaMember $Counters $key $null
        if ($value -is [bool]) { $countersOut[$key] = [bool]$value }
        elseif (($value -is [int]) -or ($value -is [long]) -or ($value -is [double]) -or ($value -is [decimal]) -or ($value -is [single])) { $countersOut[$key] = [Math]::Round([double]$value,2) }
    }
    $metricsOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($metric in @($Metrics)) {
        if ($metricsOut.Count -ge 200) { break }
        $provenance = [string](Get-DomeniaMember $metric 'Provenance' '')
        $operation = [string](Get-DomeniaMember $metric 'OperationId' '')
        if (($provenance -notmatch '^[A-Za-z]{2,24}$') -or ($operation -notmatch '^[A-Za-z][A-Za-z0-9]{1,63}(:[A-Za-z][A-Za-z0-9]{1,63})?$')) { continue }
        $metricsOut.Add([ordered]@{Provenance=$provenance;OperationId=$operation;Count=[int](Get-DomeniaMember $metric 'Count' 0);P50Ms=[Math]::Round([double](Get-DomeniaMember $metric 'P50' 0),1);P95Ms=[Math]::Round([double](Get-DomeniaMember $metric 'P95' 0),1);MaxMs=[Math]::Round([double](Get-DomeniaMember $metric 'Max' 0),1)})
    }
    $errorsOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($Errors)) {
        if ($errorsOut.Count -ge 200) { break }
        $code = [string](Get-DomeniaMember $item 'Code' '')
        if ($code -notmatch '^INC-[0-9A-F]{4}$') { continue }
        $type = [string](Get-DomeniaMember $item 'Type' '')
        if ($type -notmatch '^[A-Za-z_][A-Za-z0-9_.`+]{1,120}$') { $type = '' }
        $where = [string](Get-DomeniaMember $item 'Where' '')
        if ($where -notmatch '^[A-Za-z0-9_.-]{1,80}\.ps1:[0-9]{1,6}$') { $where = '' }
        $errorsOut.Add([ordered]@{Code=$code;Count=[int](Get-DomeniaMember $item 'Count' 0);Type=$type;Where=$where})
    }
    $tracesOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($summary in @($Traces)) {
        if ($tracesOut.Count -ge 64) { break }
        $reference = [string](Get-DomeniaMember $summary 'Reference' '')
        $operation = [string](Get-DomeniaMember $summary 'OperationId' '')
        if (($reference -notmatch '^[a-z0-9]{8}$') -or ($operation -notmatch '^[A-Za-z][A-Za-z0-9]{2,63}$')) { continue }
        $outcome = [string](Get-DomeniaMember $summary 'Outcome' '')
        if ($null -eq (Get-DomeniaTraceOutcome $outcome)) { $outcome = '' }
        $category = [string](Get-DomeniaMember $summary 'Category' '')
        if ($category -notmatch '^[A-Za-z]{2,40}$') { $category = '' }
        $kind = 'Lecture'
        if ([string](Get-DomeniaMember $summary 'Kind' '') -ceq 'Écriture') { $kind = 'Écriture' }
        $phasesOut = New-Object 'System.Collections.Generic.List[object]'
        $codes = @(Get-DomeniaTracePhases | ForEach-Object { [string]$_.Code })
        foreach ($phase in @(Get-DomeniaMember $summary 'Phases' @())) {
            $phaseCode = [string](Get-DomeniaMember $phase 'Phase' '')
            if ($codes -cnotcontains $phaseCode) { continue }
            $phasesOut.Add([ordered]@{Phase=$phaseCode;DurationMs=[Math]::Round([double](Get-DomeniaMember $phase 'DurationMs' -1),1);Volume=[long](Get-DomeniaMember $phase 'Volume' -1);Batches=[int](Get-DomeniaMember $phase 'Batches' 1)})
        }
        $tracesOut.Add([ordered]@{Reference=$reference;OperationId=$operation;Kind=$kind;Outcome=$outcome;Category=$category;Open=[bool](Get-DomeniaMember $summary 'Open' $false);TotalMs=[Math]::Round([double](Get-DomeniaMember $summary 'TotalMs' 0),1);Phases=$phasesOut.ToArray()})
    }
    $slowOut = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($Slow)) {
        if ($slowOut.Count -ge 16) { break }
        $operation = [string](Get-DomeniaMember $item 'OperationId' '')
        if ($operation -notmatch '^[A-Za-z][A-Za-z0-9]{2,63}$') { $operation = '' }
        $phase = [string](Get-DomeniaMember $item 'Phase' '')
        if ($phase -notin @('Queue','Collect','Validate','Publish','Stall')) { $phase = '' }
        $handler = [string](Get-DomeniaMember $item 'Handler' '')
        if ($handler -notmatch '^[A-Za-z][A-Za-z0-9:-]{2,80}$') { $handler = '' }
        if ((-not $operation) -and (-not $phase)) { continue }
        $slowOut.Add([ordered]@{OperationId=$operation;Phase=$phase;Handler=$handler;DurationMs=[Math]::Round([double](Get-DomeniaMember $item 'DurationMs' -1),1);TotalMs=[Math]::Round([double](Get-DomeniaMember $item 'TotalMs' -1),1);Volume=[long](Get-DomeniaMember $item 'Volume' -1)})
    }
    $compatibilityOut = [ordered]@{}
    foreach ($key in @('Compatibility','CompatibilityMatrix','CompatibilityWindows','CompatibilityPowerShell','CompatibilityDotNet','CompatibilitySqlite','WindowsBuild','WindowsProduct','DotNetRelease','WinSqlite')) {
        $value = Get-DomeniaMemberValue $Compatibility $key $null
        if ($value -is [bool]) { $compatibilityOut[$key] = [bool]$value }
        elseif (($value -is [int]) -or ($value -is [long])) { $compatibilityOut[$key] = [long]$value }
        elseif (($value -is [string]) -and ($value -match '^[A-Za-z0-9._-]{1,32}$')) { $compatibilityOut[$key] = [string]$value }
    }
    $captured = ''
    if ($CapturedUtc -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]{8,16}(Z|[+-][0-9]{2}:[0-9]{2})?$') { $captured = $CapturedUtc }
    return [pscustomobject]@{
        Format='Domenia.Diagnostic.2';CapturedUtc=$captured
        ContainsNames=$false;ContainsMessages=$false;ContainsSecrets=$false;ContainsTargets=$false
        Versions=[pscustomobject]$versionsOut;Counters=[pscustomobject]$countersOut;Compatibility=[pscustomobject]$compatibilityOut
        Metrics=$metricsOut.ToArray();Errors=$errorsOut.ToArray();Traces=$tracesOut.ToArray();Slowness=$slowOut.ToArray()
    }
}

function Get-DomeniaDiagnosticPreviewText {
    # What the operator reads before saving: what the file contains and, as important, what it never contains.
    param([Parameter(Mandatory=$true)]$Diagnostic)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $versions = @($Diagnostic.Versions.PSObject.Properties | ForEach-Object { [string]$_.Name + ' ' + [string]$_.Value })
    $lines.Add('Versions : ' + $(if ($versions.Count) { $versions -join ' · ' } else { 'aucune' }) + '.')
    $compatibility = Get-DomeniaMemberValue $Diagnostic 'Compatibility' $null
    $verdict = [string](Get-DomeniaMember $compatibility 'Compatibility' '')
    if ($verdict) { $lines.Add('Compatibilité du poste : ' + $verdict + ', versions de Windows, PowerShell, .NET et SQLite et statut de chaque dimension.') }
    $lines.Add('Mesures locales : ' + @($Diagnostic.Metrics).Count + ' série(s) (médiane, 95e centile, maximum).')
    $lines.Add('Erreurs : ' + @($Diagnostic.Errors).Count + ' code(s) incident, avec leur nombre, leur type .NET et leur ligne de script.')
    $lines.Add('Opérations : ' + @($Diagnostic.Traces).Count + ' trace(s) par identifiant dʼopération, phases et durées.')
    $lines.Add('Lenteurs expliquées : ' + @($Diagnostic.Slowness).Count + '.')
    $lines.Add('Jamais inclus : mots de passe, clés, messages dʼerreur, noms de comptes, de postes ou de groupes, chemins AD, adresses et contenu du journal.')
    return ($lines.ToArray() -join "`r`n")
}

function Get-DomeniaTraceAdvice {
    # What the operator can do after the end of an operation, in plain words: never an automatic retry, and a write is
    # never replayed. The reference ties the advice to the lines of Domenia.log.
    param([AllowEmptyString()][string]$Outcome='',[bool]$IsWrite=$false,[AllowEmptyString()][string]$Category='',[AllowEmptyString()][string]$Reference='')
    $ref = ''
    if ($Reference -match '^[a-z0-9]{8}$') { $ref = ' Référence ' + $Reference + ' dans Domenia.log.' }
    # X04/X05: a write whose receipt waits for a check is counted on « opérations à vérifier » (header pill and this
    # panel), which opens the receipts: the advice points there instead of a second list.
    $receipt = ' Son reçu, sʼil attend une vérification, sʼouvre depuis « opérations à vérifier » (en-tête ou panneau Opérations).'
    $write = 'Écriture non confirmée : relisez lʼobjet avant toute nouvelle tentative ; Domenia ne rejoue jamais une écriture.' + $receipt
    switch ($Outcome) {
        'Succeeded' { return '' }
        'Superseded' { return 'Une demande plus récente a pris sa place : rien à faire.' }
        'Withdrawn' { return 'Retirée de la file avant tout envoi : aucun appel nʼa été fait.' }
        'Refused' { return ('Refusée avant envoi (limite du moteur, compte suspendu ou maintenance) : aucun appel nʼa été fait. Relancez lʼaction depuis son écran une fois la cause levée.' + $ref) }
        'Unknown' { return ('Résultat inconnu : relisez lʼobjet avant toute nouvelle tentative ; Domenia ne rejoue jamais une écriture.' + $receipt + $ref) }
        'Stopped' {
            if ($IsWrite) { return ($write + $ref) }
            return 'Arrêtée sur demande : ce qui était déjà enregistré est conservé. Relancez lʼaction depuis son écran si besoin.'
        }
        'TimedOut' {
            if ($IsWrite) { return ($write + $ref) }
            return ('Délai dépassé : la cible ou le réseau nʼa pas répondu à temps. Aucune relance automatique ; relancez quand la cible est joignable.' + $ref)
        }
        'Failed' {
            $text = 'Échec : relancez lʼaction depuis son écran après lecture du journal.'
            if ($Category -in @('CredentialsRejected','AccountState','AccountLocked','LogonFailure','CredentialPaused')) {
                $text = 'Compte refusé ou suspendu : vérifiez-le dans Comptes et accès avant de relancer. Aucune nouvelle tentative nʼest faite automatiquement (protection contre le verrouillage).'
            } elseif ($Category -in @('AccessDenied','DecryptionDenied')) {
                $text = 'Droit insuffisant pour ce compte sur cette ressource : utilisez un compte autorisé, puis relancez lʼaction.'
            } elseif ($Category -in @('Timeout','Network','Unavailable','AccountUnavailable')) {
                $text = 'Cible ou réseau indisponible : relancez quand la cible est joignable.'
            } elseif ($Category -in @('Prerequisite','ModuleUnavailable')) {
                $text = 'Prérequis absent sur ce poste : lancez Vérifier lʼapplication avant de relancer.'
            }
            if ($IsWrite) { $text = $write + ' ' + $text }
            return ($text + $ref)
        }
    }
    return ''
}
