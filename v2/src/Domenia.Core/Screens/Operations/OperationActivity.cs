using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;

namespace Domenia.Core;

/// <summary>
/// Activity of the engine for the session (Domenia 1 Register-DomeniaTrace, Get-DomeniaTraceRing, OPE-012 and OPE-015 to
/// OPE-021): every bridge operation the registry tracks is followed from its request to its end, in memory only. A task keeps its
/// operation name, its class, its steps (events it published), its duration, its volume and its end; never its arguments, its
/// result, a target name nor the message of an error (its code only). Reads can be stopped (their own cancellation, linked to
/// the lifetime of the application); writes never. The ring keeps 64 tasks; response times, slowness and per operation samples
/// feed the health and statistics of the screen. Thread safe; nothing here reads the disk or the network.
/// </summary>
public sealed partial class OperationActivity
{
    public const string TaskUnknown = "operations.taskUnknown";
    public const string TaskUnknownMessage = "Tâche introuvable ou déjà terminée : rien n’a été arrêté.";
    public const string TaskNotStoppable = "operations.taskNotStoppable";

    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly bool simulation;
    private readonly Lock gate = new();
    private readonly List<Trace> traces = [];
    private readonly Dictionary<string, Declaration> declared = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Queue<double>> categories = new(StringComparer.Ordinal);
    private readonly Dictionary<bool, Queue<double>> classes = [];
    private ImmutableArray<ResponseCategory>? categoriesCache;
    private long categoriesVersion;
    private long categoriesCachedVersion = -1;
    private DateTimeOffset? lastStall;
    private int stallsSilenced;
    private int sqliteBusy;
    private DateTimeOffset? sqliteBusyLast;
    private readonly Dictionary<string, Queue<OperationSample>> samples = new(StringComparer.Ordinal);
    private readonly Queue<SlowEvent> slow = new();
    private readonly Dictionary<string, int> errors = new(StringComparer.Ordinal);
    private readonly Queue<double> writeWaits = new();
    private DateTimeOffset? lastLocalWrite;
    private int faults;
    private bool windowAvailable = true;
    private bool idlePolicy;
    internal bool ReadTrace { get; private set; }
    public bool BackgroundAllowed => !idlePolicy || Volatile.Read(ref windowAvailable);
    public void SetWindowActivity(bool visible, bool active) => Volatile.Write(ref windowAvailable, visible && active);

    public OperationActivity(TimeProvider clock, ITechnicalJournal log, bool simulation)
    {
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(log);
        this.clock = clock;
        this.log = log;
        this.simulation = simulation;
    }

    /// <summary>The activity shared by every module of the context (one per session).</summary>
    public static OperationActivity From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new OperationActivity(c.Clock, c.Log, c.Mode == AppMode.Simulation)
        { idlePolicy = c.Configuration.Flag("Features", "IdlePolicy", true), ReadTrace = c.Configuration.Flag("Features", "ReadTrace", false) });
    }

    /// <summary>Incidents of the tracking itself, without effect on the operations (Domenia 1 DomeniaTraceFaults).</summary>
    public int Faults
    {
        get
        {
            lock (gate)
            {
                return faults;
            }
        }
    }

    /// <summary>Operations declared by the registry, with their kind (self-check: a single write door).</summary>
    public ImmutableArray<(string Operation, TaskKind Kind)> Declared
    {
        get
        {
            lock (gate)
            {
                return [.. declared.Values.OrderBy(d => d.Operation, StringComparer.Ordinal).Select(d => (d.Operation, d.Kind))];
            }
        }
    }

    /// <summary>Declares an operation of the registry (at startup): its short French label and its kind.</summary>
    public void Declare(string operation, TaskKind kind, string? description)
    {
        ArgumentNullException.ThrowIfNull(operation);
        var label = ActivityRules.LabelOf(operation, description);
        lock (gate)
        {
            declared[operation] = new Declaration(operation, ScreenOf(operation), kind, label);
        }
    }

    /// <summary>Short French label of a declared operation (its name when unknown).</summary>
    public string LabelOf(string operation)
    {
        ArgumentNullException.ThrowIfNull(operation);
        lock (gate)
        {
            return declared.TryGetValue(operation, out var d) ? d.Label : operation;
        }
    }

    /// <summary>
    /// Starts following one request. Reads get a cancellation of their own, linked to <paramref name="lifetime"/>, so that the
    /// operator can stop them (<see cref="Stop"/>); writes keep <paramref name="lifetime"/> and are never stopped.
    /// </summary>
    public ActivityTask Begin(string operation, TaskKind kind, CancellationToken lifetime, string? requestId = null, bool? foreground = null)
    {
        ArgumentNullException.ThrowIfNull(operation);
        var id = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        var now = clock.GetUtcNow();
        var timestamp = clock.GetTimestamp();
        var cancel = ActivityRules.IsStoppable(kind) ? CancellationTokenSource.CreateLinkedTokenSource(lifetime) : null;
        var trace = new Trace(id, operation, ScreenOf(operation), kind, foreground ?? ActivityRules.IsForeground(operation, kind), now, timestamp, cancel)
        { RequestId = requestId, Request = OperationRequests.CurrentRequest };
        trace.RequestJob = trace.Request?.BeginJob(RequestJobKind.Handler, trace.Reference);
        lock (gate)
        {
            trace.Label = declared.TryGetValue(operation, out var d) ? d.Label : operation;
            traces.Add(trace);
            EvictLocked();
        }
        return new ActivityTask(this, trace, cancel?.Token ?? lifetime);
    }

    /// <summary>
    /// Asks a read to stop (Domenia 1 Stop-DomeniaOperationRow, OPE-016): the right to stop is checked again on the real task. A
    /// write is never stopped (operations.taskNotStoppable); a finished or unknown task is refused (operations.taskUnknown). « Arrêt
    /// demandé » is not a confirmed cancellation: the row says so until the read really ends.
    /// </summary>
    public ActivityRow Stop(string id)
    {
        ArgumentNullException.ThrowIfNull(id);
        CancellationTokenSource? cancel;
        Trace trace;
        lock (gate)
        {
            trace = traces.FirstOrDefault(t => string.Equals(t.Id, id, StringComparison.Ordinal) && t.Open)
                ?? throw new DomeniaOperationException(TaskUnknown, TaskUnknownMessage);
            if (!ActivityRules.IsStoppable(trace.Kind) || trace.Cancel is null || trace.State == TaskState.Cleanup)
            {
                throw new DomeniaOperationException(TaskNotStoppable, ActivityRules.CancelText(trace.Label, trace.State, trace.Kind));
            }
            cancel = trace.StopRequested ? null : trace.Cancel;
            trace.StopRequested = true;
            trace.State = TaskState.StopRequested;
        }
        // Safe native stop requests are scoped to this exact read. Actual owners retain all leases until cleanup.
        if (cancel is not null && trace.Request is not null) _ = Resources.RequestReleaseAsync(owner: trace.Request.Reference);
        try
        {
            cancel?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // The read ended between the check and the request: its own end is recorded, nothing else to do.
        }
        log.Info($"Arrêt demandé pour l’opération {trace.Operation} [{trace.Reference}].");
        lock (gate)
        {
            return RowLocked(trace, clock.GetTimestamp());
        }
    }

    /// <summary>The tasks in progress, the ring (most recent first) and the summary; <paramref name="batches"/> are the collection batches of the readers.</summary>
    public ActivitySnapshot Snapshot(IReadOnlyList<ActivityRow>? batches = null)
    {
        var now = clock.GetTimestamp();
        lock (gate)
        {
            var open = traces.Where(t => t.Open).OrderBy(t => t.StartedAt).Select(t => RowLocked(t, now)).ToList();
            var recent = traces.Where(t => !t.Open).OrderByDescending(t => t.EndedAt).ThenByDescending(t => t.StartedAt).Select(t => RowLocked(t, now)).ToList();
            var batchRows = batches ?? [];
            var running = open.Count(r => r.State == TaskState.Running) + batchRows.Count(b => b.State == TaskState.Running);
            var stopping = open.Count(r => r.State == TaskState.StopRequested) + batchRows.Count(b => b.State == TaskState.StopRequested);
            var resources = traces.Count(t => t.Open && t.Cancel is not null);
            var cleanup = open.Count(r => r.State == TaskState.Cleanup) + batchRows.Count(b => b.State == TaskState.Cleanup);
            var summary = ActivityRules.Summary(running, 0, stopping, cleanup, resources);
            var held = Resources.Snapshot();
            if (held.Held > 0 || held.ReleaseFailures > 0 || held.Untracked > 0)
                summary = summary with { Resources = resources + held.Held,
                    ResourcesText = summary.ResourcesText + " ; " + string.Join(", ", held.ByKind.Where(r => r.Held > 0)
                        .Select(r => FrenchText.Integer(r.Held) + " " + (r.Kind switch
                        { RuntimeResourceKind.NativeProcess => "processus natif(s)", RuntimeResourceKind.NativeSession => "session(s) native(s)",
                          RuntimeResourceKind.ReadTimer => "minuterie(s)", _ => "travailleur(s)" })))
                        + "; " + FrenchText.Integer(held.StopRequested) + " fermeture(s) demandée(s), "
                        + FrenchText.Integer(held.ReleaseFailures) + " échec(s) de fermeture, " + FrenchText.Integer(held.Untracked) + " ressource(s) non suivie(s)." };
            var listed = recent.Count(r => r.Listed);
            var note = "Tâches de cette session seulement, en mémoire (64 au plus)" + FrenchText.Colon
                + "les demandes de l’opérateur sont toutes listées, les lectures automatiques seulement si elles finissent mal. Rien n’est relancé automatiquement.";
            return new ActivitySnapshot(clock.GetUtcNow(), summary, [.. batchRows, .. open], [.. recent], traces.Count, listed, faults, note);
        }
    }

    /// <summary>Count admitted tasks once, including stop/cleanup; excludes the current counter request.</summary>
    public int ActiveCount(string? exceptRequestId = null)
    {
        lock (gate) { return traces.Count(t => t.Open && (exceptRequestId is null || t.RequestId != exceptRequestId)); }
    }

    /// <summary>Number of writes in progress (« une écriture est en cours » of the unavailable reasons).</summary>
    public int OpenWrites
    {
        get
        {
            lock (gate)
            {
                return traces.Count(t => t.Open && t.Kind == TaskKind.Write);
            }
        }
    }

    /// <summary>
    /// Response times of the six categories of Domenia 1 (Get-DomeniaResponseTimeCategories, OPE-031): a measure is never counted
    /// twice, an unmeasured category says so, and the summaries are computed again only when a series moved.
    /// </summary>
    public ImmutableArray<ResponseCategory> Categories()
    {
        lock (gate)
        {
            if (categoriesCache is ImmutableArray<ResponseCategory> cached && categoriesCachedVersion == categoriesVersion)
            {
                return cached;
            }
            ImmutableArray<ResponseCategory> result =
            [
                .. ActivityRules.CategoryLabels(simulation).Select(c =>
                {
                    var values = categories.TryGetValue(c.Id, out var q) ? q.ToArray() : [];
                    var summary = ActivityRules.Latency(values);
                    return new ResponseCategory(c.Id, c.Label, summary, ActivityRules.LatencyText(c.Label, summary), ActivityRules.Histogram(values), ActivityRules.HistogramLabels);
                }),
            ];
            categoriesCache = result;
            categoriesCachedVersion = categoriesVersion;
            return result;
        }
    }

    /// <summary>
    /// Indicators of the collection by class of request (Domenia 1 Get-DomeniaCollectionHealthLines, OPE-001): explicit actions of the
    /// operator, automatic reads and writes. These samples measure handler duration; Bridge queue waits and promotions are
    /// separate and are not reconstructed from these durations. The single write channel has its own measured wait.
    /// </summary>
    public ImmutableArray<string> ClassLines()
    {
        lock (gate)
        {
            var explicitValues = classes.TryGetValue(true, out var e) ? e.ToArray() : [];
            var backgroundValues = classes.TryGetValue(false, out var b) ? b.ToArray() : [];
            var waits = ActivityRules.Latency(writeWaits);
            return
            [
                ClassLine("Actions explicites de l’opérateur", explicitValues),
                ClassLine("Lectures automatiques (affichage, actualisations)", backgroundValues),
                waits.Count > 0
                    ? ActivityRules.LatencyText("Écritures, une à la fois sur le canal unique" + FrenchText.Colon + "attente du canal", waits)
                    : "Écritures" + FrenchText.Colon + "canal unique, une à la fois ; aucune écriture dans cette session.",
                .. QueueLines(),
            ];
        }
    }

    private static string ClassLine(string label, double[] values)
    {
        if (values.Length == 0)
        {
            return label + FrenchText.Colon + "aucune demande terminée dans cette session ; aucune durée de traitement mesurée.";
        }
        var summary = ActivityRules.Latency(values);
        var text = label + FrenchText.Colon + FrenchText.Count(values.Length, "demande terminée", "demandes terminées") + ", après admission ; traitement médian "
            + ActivityRules.Duration(summary.P50 ?? -1);
        return text + (summary.P95Stated ? ", 95" + FrenchText.Nbsp + "% sous " + ActivityRules.Duration(summary.P95 ?? -1) + "." : " (trop peu de mesures pour un 95e centile).");
    }

    /// <summary>
    /// Interface work measured by the page (Domenia 1 Register-DomeniaJobPublication, OPE-031, OPE-034): each sample enters the
    /// « Traitement des résultats dans l’interface » category; one above 120 ms enters the explained slowness. Closed codes only.
    /// </summary>
    public int RecordInterface(IEnumerable<InterfaceSample> samples)
    {
        ArgumentNullException.ThrowIfNull(samples);
        var now = clock.GetUtcNow();
        var kept = 0;
        lock (gate)
        {
            foreach (var sample in samples)
            {
                if (ActivityRules.InterfaceWorkLabel(sample.Work) is not string label || !double.IsFinite(sample.Ms) || sample.Ms < 0)
                {
                    continue;
                }
                kept++;
                Push(categories.TryGetValue("render", out var q) ? q : categories["render"] = new Queue<double>(), sample.Ms);
                categoriesVersion++;
                var verdict = ActivityRules.Slowness(label, -1, -1, -1, interfaceMs: sample.Ms);
                if (verdict.Slow)
                {
                    slow.Enqueue(new SlowEvent(now, "interface." + sample.Work, "", verdict.Phase, verdict.DurationMs, verdict.TotalMs, "Interface lente" + FrenchText.Colon + verdict.Text));
                    while (slow.Count > ActivityRules.MaxSlowEvents)
                    {
                        slow.Dequeue();
                    }
                }
            }
        }
        return kept;
    }

    /// <summary>
    /// A stall of the interface reported by the page (Domenia 1 Register-DomeniaDispatcherLateness, OPE-035): one line in the
    /// technical journal at most every 5 s, attributed or said unattributed (never guessed); the others are counted. Returns true
    /// when a line was written.
    /// </summary>
    public bool RecordStall(StallReport stall)
    {
        ArgumentNullException.ThrowIfNull(stall);
        if (!double.IsFinite(stall.LateMs) || stall.LateMs < ActivityRules.StallThresholdMs)
        {
            return false;
        }
        var now = clock.GetUtcNow();
        int silenced;
        lock (gate)
        {
            if (lastStall is DateTimeOffset last && now - last < ActivityRules.StallInterval)
            {
                stallsSilenced++;
                return false;
            }
            lastStall = now;
            silenced = stallsSilenced;
            stallsSilenced = 0;
        }
        var more = silenced > 0 ? " (" + silenced.ToString(CultureInfo.InvariantCulture) + " autre(s) depuis la ligne précédente)" : "";
        log.Warning(ActivityRules.StallText(stall) + more);
        return true;
    }

    /// <summary>
    /// A wait for a lock of the local SQLite base that ran out (Domenia 1 Register-DomeniaSqliteBusyOutcome, OPE-032): counted for
    /// the session, with the time of the last one. Called by the local base (Domenia.Store) when it answers « busy ».
    /// </summary>
    public void RecordSqliteBusy()
    {
        var now = clock.GetUtcNow();
        lock (gate)
        {
            sqliteBusy++;
            sqliteBusyLast = now;
        }
        log.Warning("Base locale occupée : attente de verrou SQLite dépassée (comptée, rien n’est rejoué).");
    }

    /// <summary>Lock waits of the local base that ran out in this session, and the last one.</summary>
    public (int Count, DateTimeOffset? Last) SqliteBusy
    {
        get
        {
            lock (gate)
            {
                return (sqliteBusy, sqliteBusyLast);
            }
        }
    }

    /// <summary>The last explained slowness, most recent first (Domenia 1 OPE-034, 16 at most).</summary>
    public ImmutableArray<SlowEvent> Slow()
    {
        lock (gate)
        {
            return [.. slow.Reverse()];
        }
    }

    /// <summary>Waits of the write channel (from the request to the first check of the write): the only queue of the engine today.</summary>
    public LatencySummary WriteWaits()
    {
        lock (gate)
        {
            return ActivityRules.Latency(writeWaits);
        }
    }

    /// <summary>Error codes of the session and their counts (diagnostic: codes only, never a message).</summary>
    public ImmutableArray<(string Code, int Count)> Errors()
    {
        lock (gate)
        {
            return [.. errors.OrderBy(e => e.Key, StringComparer.Ordinal).Select(e => (e.Key, e.Value))];
        }
    }

    /// <summary>Last successful local write of the session (preferences, receipts, documents).</summary>
    public DateTimeOffset? LastLocalWrite
    {
        get
        {
            lock (gate)
            {
                return lastLocalWrite;
            }
        }
    }

    /// <summary>Samples of the session per operation (512 last per operation), for the statistics.</summary>
    public ImmutableArray<OperationSample> Samples()
    {
        lock (gate)
        {
            return [.. samples.Values.SelectMany(q => q)];
        }
    }

    /// <summary>Kind and screen of a declared operation; null when the registry did not declare it.</summary>
    public (TaskKind Kind, string Screen)? DeclarationOf(string operation)
    {
        lock (gate)
        {
            return declared.TryGetValue(operation, out var d) ? (d.Kind, d.Screen) : null;
        }
    }

    /// <summary>Counts a tracking incident (never an error of the operation itself).</summary>
    public void Fault(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        lock (gate)
        {
            faults++;
        }
        log.Warning($"Suivi des opérations : incident {exception.GetType().Name}, sans effet sur l’opération.");
    }

    // ---------------------------------------------------------------- called by ActivityTask

    internal void Step(Trace trace, string label, bool sequential)
    {
        var at = clock.GetElapsedTime(trace.StartTimestamp).TotalMilliseconds;
        lock (gate)
        {
            if (!trace.Open)
            {
                return;
            }
            if (sequential && trace.QueueMs is null && trace.Steps.Count == 0)
            {
                // From the request to the first check of the write: wait of the single write channel and checks of the plan.
                trace.QueueMs = at;
                Push(writeWaits, at);
            }
            var normalized = ActivityRules.Flat(label, ActivityRules.DetailLength);
            if (trace.Steps.LastOrDefault() is { } previous && previous.Label == normalized && previous.Sequential == sequential)
            {
                trace.Steps[^1] = previous with { Repetitions = previous.Repetitions + 1 };
                trace.LastAt = clock.GetUtcNow();
                return;
            }
            if (trace.Steps.Count >= ActivityRules.MaxEvents - 3)
            {
                trace.Dropped++;
                return;
            }
            trace.Steps.Add(new StepEvent(normalized, at, sequential));
            trace.LastAt = clock.GetUtcNow();
        }
    }

    internal void Rename(Trace trace, string label)
    {
        lock (gate)
        {
            trace.Label = ActivityRules.Flat(label, ActivityRules.NameLength);
        }
    }

    internal bool DeferPhysicalCompletion(Trace trace, Action finish)
    {
        lock (gate)
        {
            if (!ActivityRules.IsStoppable(trace.Kind) || trace.Request is null || !trace.Request.AfterPhysicalCompletion(finish)) return false;
            trace.State = TaskState.Cleanup;
            return true;
        }
    }

    internal void Complete(Trace trace, TaskOutcome outcome, string? category, long volume, long? bytes, bool volumeComplete = true, SyncCalibration? calibration = null)
    {
        var engineMs = clock.GetElapsedTime(trace.StartTimestamp).TotalMilliseconds;
        var now = clock.GetUtcNow();
        SlowEvent? slowEvent = null;
        lock (gate)
        {
            if (!trace.Open)
            {
                return;
            }
            trace.Open = false;
            trace.State = TaskState.Completed;
            trace.EngineMs = engineMs;
            trace.EndedAt = now;
            trace.LastAt = now;
            trace.Outcome = ActivityRules.Worst(trace.Outcome, outcome);
            trace.Category = outcome == TaskOutcome.Succeeded ? null : category;
            if (volume >= 0) trace.Volume = volume;
            trace.VolumeComplete = volume >= 0 && volumeComplete && outcome == TaskOutcome.Succeeded;
            if (outcome != TaskOutcome.Stopped)
            {
                var id = ActivityRules.CategoryOf(trace.Operation, trace.Kind);
                Push(categories.TryGetValue(id, out var q) ? q : categories[id] = new Queue<double>(), engineMs);
                Push(classes.TryGetValue(trace.Foreground, out var c) ? c : classes[trace.Foreground] = new Queue<double>(), engineMs);
                categoriesVersion++;
                // A remote request leaves once, never retried (no fallback transport in Domenia 2); the simulation reaches nothing.
                var remote = !simulation && trace.Kind is TaskKind.NetworkRead or TaskKind.Write ? 1 : 0;
                var perOperation = samples.TryGetValue(trace.Operation, out var s) ? s : samples[trace.Operation] = new Queue<OperationSample>();
                perOperation.Enqueue(new OperationSample(trace.Operation, now, engineMs, Math.Max(0, volume), outcome == TaskOutcome.Succeeded, true, bytes, remote, 0)
                    { Sync = !simulation && outcome == TaskOutcome.Succeeded && volumeComplete ? calibration : null });
                while (perOperation.Count > ActivityRules.SamplesPerSeries)
                {
                    perOperation.Dequeue();
                }
            }
            if (outcome != TaskOutcome.Succeeded && category is not null)
            {
                errors[category] = errors.TryGetValue(category, out var n) ? n + 1 : 1;
            }
            if (outcome == TaskOutcome.Succeeded && trace.Kind is TaskKind.LocalWrite)
            {
                lastLocalWrite = now;
            }
            // The wait of the write channel is part of the time in the engine: counted once, as its own phase.
            var processing = trace.QueueMs is double waited ? Math.Max(0, engineMs - waited) : engineMs;
            var verdict = ActivityRules.Slowness(trace.Label, trace.QueueMs ?? -1, processing, volume);
            if (verdict.Slow)
            {
                slowEvent = new SlowEvent(now, trace.Operation, trace.Reference, verdict.Phase, verdict.DurationMs, verdict.TotalMs, verdict.Text);
                slow.Enqueue(slowEvent);
                while (slow.Count > ActivityRules.MaxSlowEvents)
                {
                    slow.Dequeue();
                }
            }
        }
        try
        {
            trace.Cancel?.Dispose();
        }
        catch (ObjectDisposedException)
        {
            // Already released: nothing else holds it.
        }
        if (outcome is TaskOutcome.Stopped)
        {
            log.Info($"Opération {trace.Operation} [{trace.Reference}] arrêtée sur demande.");
        }
        else if (outcome is not TaskOutcome.Succeeded)
        {
            // Codes only: the reference ties the line to the row of the screen (Domenia 1: « Référence xxxxxxxx dans Domenia.log »).
            log.Warning($"Opération {trace.Operation} [{trace.Reference}] : {outcome} ({category ?? "sans code"}).");
        }
        if (slowEvent is not null)
        {
            log.Info($"Lenteur expliquée [{trace.Reference}] : {trace.Operation}, {engineMs.ToString("0", CultureInfo.InvariantCulture)} ms.");
        }
    }

    // ---------------------------------------------------------------- rows

    private ActivityRow RowLocked(Trace t, long now)
    {
        var elapsed = t.Open ? clock.GetElapsedTime(t.StartTimestamp, now).TotalMilliseconds : t.EngineMs ?? 0;
        var outcome = t.Open ? (TaskOutcome?)null : t.Outcome;
        var info = outcome is TaskOutcome end ? ActivityRules.Outcome(end) : null;
        var (tone, icon) = t.State switch
        {
            TaskState.StopRequested => (Tone.Warn, "pause"),
            TaskState.Running or TaskState.Queued => (Tone.Info, "activity"),
            _ => info is not null ? (info.Tone, info.Icon) : (Tone.Ok, "check"),
        };
        // Phases in time order (Domenia 1 OPE-019): request, wait of the write channel, the stages the operation published (or, without
        // them, its processing in the engine as a whole), publication in the interface, end. The total is given apart (DurationMs).
        var phases = new List<TaskPhaseRow> { new("request", "Demande", 0, null, "non mesurée", false, null, null) };
        if (t.AdmissionWaitMs is double admission)
        {
            phases.Add(new("admission", "Admission dans le moteur", 0, admission, ActivityRules.Duration(admission), true,
                "Attente avant le traitement ; exclue du total moteur" + (t.AdmissionPromoted ? " ; priorité promue après longue attente" : ""), null));
        }
        if (t.QueueMs is double queue)
        {
            phases.Add(new TaskPhaseRow("queue", "File d’attente du canal d’écriture et contrôles du plan", 0, queue, ActivityRules.Duration(queue), true, null, null));
        }
        var sequential = t.Steps.Any(step => step.Sequential) || t.MeasuredPhases.Count > 0;
        if (!sequential)
        {
            phases.Add(new TaskPhaseRow("work", "Traitement dans le moteur", 0, t.Open ? null : elapsed, t.Open ? ActivityRules.Duration(elapsed) + " (en cours)" : ActivityRules.Duration(elapsed),
                !t.Open, t.Volume >= 0 ? ActivityRules.Volume(t.Volume, complete: !t.Open && t.VolumeComplete) : null, null));
        }
        for (var i = 0; i < t.Steps.Count; i++)
        {
            var step = t.Steps[i];
            double? until = i + 1 < t.Steps.Count ? t.Steps[i + 1].AtMs : t.Open ? null : t.EngineMs;
            double? duration = step.Sequential && until is double u ? Math.Max(0, u - step.AtMs) : null;
            phases.Add(new TaskPhaseRow("step", step.Label, step.AtMs, duration, duration is double d ? ActivityRules.Duration(d) : t.Open && i == t.Steps.Count - 1 ? "en cours" : "non mesurée", duration is not null, step.Repetitions > 1 ? FrenchText.Integer(step.Repetitions) + " lots consécutifs regroupés" : null, null));
        }
        phases.AddRange(PhaseRows(t, now));
        phases = phases.OrderBy(p => p.AtMs).ToList();
        if (!t.Open)
        {
            phases.Add(new TaskPhaseRow("publish", "Publication dans l’interface", t.EngineMs ?? elapsed, t.PublicationMs, t.PublicationMs is double publication ? ActivityRules.Duration(publication) : "non mesurée", t.PublicationMs is not null, "réception de la réponse jusqu’au prochain rafraîchissement visible ; comprend l’attente de rendu, pas une mesure CPU", null));
        }
        if (!t.Open && info is not null)
        {
            phases.Add(new TaskPhaseRow("end", "Fin" + FrenchText.Colon + info.Label, t.EngineMs ?? elapsed, null, "—", false, t.Category, info.Code));
        }
        var measured = phases.Where(p => p.Measured && p.Phase is "admission" or "queue" or "step" or "work").ToList();
        var dominant = measured.Count > 0 ? measured.MaxBy(p => p.DurationMs ?? -1) : null;
        var text = string.Join(" → ", phases.Select(PhaseText)) + " · total " + ActivityRules.Duration(elapsed) + (t.Open ? " (en cours)" : "");
        if (t.Dropped > 0)
        {
            text += " (" + FrenchText.Integer(t.Dropped) + " événement(s) non conservé(s))";
        }
        var listed = ActivityRules.IsListed(t.Foreground, t.Kind, t.Open, outcome);
        var canStop = t.Open && t.State != TaskState.Cleanup && ActivityRules.IsStoppable(t.Kind) && t.Cancel is not null && !t.StopRequested;
        string? stopReason = canStop ? null
            : !t.Open ? "Tâche terminée" + FrenchText.Colon + "rien à arrêter."
            : t.StopRequested ? ActivityRules.CancelText(t.Label, TaskState.StopRequested, t.Kind)
            : ActivityRules.CancelText(t.Label, t.State, t.Kind);
        var advice = ActivityRules.Advice(outcome, t.Kind, t.Category, t.Reference);
        var detail = t.Open
            ? ActivityRules.OpenDetail(t.Kind, t.State, simulation)
            : (outcome == TaskOutcome.Succeeded ? "Terminée" : "Fin") + " après " + ActivityRules.Duration(elapsed) + (t.Volume >= 0 ? ", " + ActivityRules.Volume(t.Volume, complete: !t.Open && t.VolumeComplete) : "") + ".";
        return new ActivityRow(
            t.Id, t.Reference, t.Operation, t.Screen, t.Label, t.Kind, ActivityRules.KindLabel(t.Kind, simulation), t.Foreground, listed,
            t.State, ActivityRules.StateLabel(t.State, outcome), tone, icon, outcome, info?.Label, t.StartedAt, t.EndedAt,
            Math.Round(elapsed, 1), ActivityRules.Duration(elapsed), dominant?.Label, dominant?.DurationMs is double dm ? Math.Round(dm, 1) : null,
            t.Volume >= 0 ? t.Volume : null, t.Volume >= 0 ? ActivityRules.Volume(t.Volume, complete: !t.Open && t.VolumeComplete) : null, canStop, stopReason, detail,
            ActivityRules.Access(t.Kind, simulation), advice, ActivityRules.Next(outcome, t.Kind, t.Operation, advice), t.Category, text, t.Dropped, [.. phases], null);
    }

    private static string PhaseText(TaskPhaseRow phase) => phase.Phase switch
    {
        "request" => phase.Label,
        "end" => phase.Label,
        "publish" when !phase.Measured => phase.Label + " non mesurée",
        _ when phase.DurationMs is double => phase.Label + " " + phase.DurationText + (phase.Detail is string d ? ", " + d : ""),
        _ => phase.Label + (phase.Detail is string detail ? " " + detail : ""),
    };

    private void EvictLocked()
    {
        if (traces.Count <= ActivityRules.MaxTraces)
        {
            return;
        }
        var evicted = ActivityRules.Eviction(traces.Select(t => (t.Id, t.Open, ActivityRules.IsListed(t.Foreground, t.Kind, t.Open, t.Open ? null : t.Outcome), t.StartedAt, t.LastAt)));
        traces.RemoveAll(t => evicted.Contains(t.Id));
    }

    private static void Push(Queue<double> queue, double value)
    {
        queue.Enqueue(value);
        while (queue.Count > ActivityRules.SamplesPerSeries)
        {
            queue.Dequeue();
        }
    }

    private static string ScreenOf(string operation)
    {
        var dot = operation.IndexOf('.', StringComparison.Ordinal);
        return dot > 0 ? operation[..dot] : operation;
    }

    private sealed record Declaration(string Operation, string Screen, TaskKind Kind, string Label);

    internal sealed record StepEvent(string Label, double AtMs, bool Sequential)
    {
        public int Repetitions { get; init; } = 1;
    }

    /// <summary>One followed request. Mutable under the gate of its activity only.</summary>
    internal sealed class Trace(string id, string operation, string screen, TaskKind kind, bool foreground, DateTimeOffset startedAt, long startTimestamp, CancellationTokenSource? cancel)
    {
        public string Id { get; } = id;
        public string Reference { get; } = ActivityRules.Reference(id);
        public string Operation { get; } = operation;
        public string Screen { get; } = screen;
        public TaskKind Kind { get; } = kind;
        public bool Foreground { get; } = foreground;
        public DateTimeOffset StartedAt { get; } = startedAt;
        public long StartTimestamp { get; } = startTimestamp;
        public CancellationTokenSource? Cancel { get; } = cancel;
        public string Label { get; set; } = operation;
        public bool Open { get; set; } = true;
        public TaskState State { get; set; } = TaskState.Running;
        public bool StopRequested { get; set; }
        public TaskOutcome? Outcome { get; set; }
        public string? Category { get; set; }
        public long Volume { get; set; } = -1;
        public bool VolumeComplete { get; set; }
        public Dictionary<OperationPhase, MeasuredPhase> MeasuredPhases { get; } = [];
        public string? RequestId { get; init; }
        internal ActivityRequest? Request { get; init; }
        internal IDisposable? RequestJob { get; set; }
        public double? PublicationMs { get; set; }
        public double? EngineMs { get; set; }
        public double? QueueMs { get; set; }
        public double? AdmissionWaitMs { get; set; }
        public bool AdmissionPromoted { get; set; }
        public DateTimeOffset? EndedAt { get; set; }
        public DateTimeOffset LastAt { get; set; } = startedAt;
        public List<StepEvent> Steps { get; } = [];
        public int Dropped { get; set; }
    }
}

/// <summary>
/// Handle of one followed request (<see cref="OperationActivity.Begin"/>): its cancellation, its steps and its end. The end is
/// recorded once; disposing an unfinished task records it as failed (an end is never left open by mistake).
/// </summary>
public sealed class ActivityTask : IDisposable
{
    private readonly OperationActivity activity;
    private readonly OperationActivity.Trace trace;
    private int completed;

    internal ActivityTask(OperationActivity activity, OperationActivity.Trace trace, CancellationToken token)
    {
        this.activity = activity;
        this.trace = trace;
        Token = token;
    }

    public string Id => trace.Id;

    public string Reference => trace.Reference;

    /// <summary>Cancellation of the request: its own for a read (stoppable), the lifetime of the application for a write.</summary>
    public CancellationToken Token { get; }

    /// <summary>True when the operator asked this read to stop.</summary>
    public bool StopRequested => trace.StopRequested;

    /// <summary>
    /// Records a step published by the operation; <paramref name="sequential"/> steps (the stages of write.execute) follow each other,
    /// so the gap to the next one is their own duration.
    /// </summary>
    public void Step(string label, bool sequential) => activity.Step(trace, label, sequential);

    /// <summary>Gives the task a more precise label once known (the label of the plan of a write).</summary>
    public void Rename(string label) => activity.Rename(trace, label);

    public IDisposable Measure(OperationPhase phase) => activity.Measure(trace, phase);
    public void RecordAdmission(double? milliseconds, bool promoted) => activity.Admission(trace, milliseconds, promoted);
    public void Progress(long received) => activity.Progress(trace, received);

    /// <summary>Records the end once: its outcome, its code (never a message), its volume and the estimated bytes received (null when not measured).</summary>
    public void Complete(TaskOutcome outcome, string? category, long volume, long? bytes = null, bool volumeComplete = true, SyncCalibration? calibration = null)
    {
        if (Interlocked.Exchange(ref completed, 1) == 0)
        {
            Finish(outcome, category, volume, bytes, volumeComplete, calibration);
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref completed, 1) == 0)
        {
            Finish(TaskOutcome.Failed, "operation.failed", -1, null, false);
        }
    }

    private void Finish(TaskOutcome outcome, string? category, long volume, long? bytes, bool volumeComplete, SyncCalibration? calibration = null)
    {
        if (activity.DeferPhysicalCompletion(trace, () => FinishPhysical(outcome, category, volume, bytes, volumeComplete, calibration))) return;
        FinishPhysical(outcome, category, volume, bytes, volumeComplete, calibration);
    }

    private void FinishPhysical(TaskOutcome outcome, string? category, long volume, long? bytes, bool volumeComplete, SyncCalibration? calibration)
    {
        try { activity.Complete(trace, outcome, category, volume, bytes, volumeComplete, calibration); }
#pragma warning disable CA1031 // Tracking, including its clock and sink, must never replace the real handler result.
        catch (Exception error) { try { activity.Fault(error); } catch (Exception) { } }
#pragma warning restore CA1031
        finally
        {
            trace.Cancel?.Dispose();
            trace.Request?.Outcome(outcome); trace.RequestJob?.Dispose();
        }
    }
}
