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
public sealed class OperationActivity
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
    private readonly Dictionary<TaskKind, Queue<double>> categories = [];
    private readonly Dictionary<string, Queue<OperationSample>> samples = new(StringComparer.Ordinal);
    private readonly Queue<SlowEvent> slow = new();
    private readonly Dictionary<string, int> errors = new(StringComparer.Ordinal);
    private readonly Queue<double> writeWaits = new();
    private DateTimeOffset? lastLocalWrite;
    private int faults;

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
        return context.Shared(static c => new OperationActivity(c.Clock, c.Log, c.Mode == AppMode.Simulation));
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
    public ActivityTask Begin(string operation, TaskKind kind, CancellationToken lifetime)
    {
        ArgumentNullException.ThrowIfNull(operation);
        var id = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        var cancel = ActivityRules.IsStoppable(kind) ? CancellationTokenSource.CreateLinkedTokenSource(lifetime) : null;
        var now = clock.GetUtcNow();
        var trace = new Trace(id, operation, ScreenOf(operation), kind, ActivityRules.IsForeground(operation, kind), now, clock.GetTimestamp(), cancel);
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
            if (!ActivityRules.IsStoppable(trace.Kind) || trace.Cancel is null)
            {
                throw new DomeniaOperationException(TaskNotStoppable, ActivityRules.CancelText(trace.Label, trace.State, trace.Kind));
            }
            cancel = trace.StopRequested ? null : trace.Cancel;
            trace.StopRequested = true;
            trace.State = TaskState.StopRequested;
        }
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
            var summary = ActivityRules.Summary(running, 0, stopping, 0, resources);
            var listed = recent.Count(r => r.Listed);
            var note = "Tâches de cette session seulement, en mémoire (64 au plus)" + FrenchText.Colon
                + "les demandes de l’opérateur sont toutes listées, les lectures automatiques seulement si elles finissent mal. Rien n’est relancé automatiquement.";
            return new ActivitySnapshot(clock.GetUtcNow(), summary, [.. batchRows, .. open], [.. recent], traces.Count, listed, faults, note);
        }
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

    /// <summary>Response times per category of the session (Domenia 1 OPE-031), one measure never counted twice.</summary>
    public ImmutableArray<ResponseCategory> Categories()
    {
        (TaskKind Kind, string Id, string Label)[] list =
        [
            (TaskKind.Local, "local", "Calcul local et état de la session"),
            (TaskKind.LocalRead, "localRead", simulation ? "Lectures locales (annuaire fictif en mémoire, reçus, préférences)" : "Lectures locales (base, reçus, préférences)"),
            (TaskKind.NetworkRead, "networkRead", simulation ? "Lectures de l’annuaire fictif (gestes de l’opérateur)" : "Lectures de l’annuaire et des postes"),
            (TaskKind.LocalWrite, "localWrite", "Écritures locales (préférences, reçus, documents)"),
            (TaskKind.Write, "write", simulation ? "Écritures sur l’annuaire fictif" : "Écritures dans l’annuaire et actions sur les postes"),
        ];
        lock (gate)
        {
            return
            [
                .. list.Select(c =>
                {
                    var values = categories.TryGetValue(c.Kind, out var q) ? q.ToArray() : [];
                    var summary = ActivityRules.Latency(values);
                    return new ResponseCategory(c.Id, c.Label, summary, ActivityRules.LatencyText(c.Label, summary), ActivityRules.Histogram(values), ActivityRules.HistogramLabels);
                }),
            ];
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
            if (trace.Steps.Count >= ActivityRules.MaxEvents - 3)
            {
                trace.Dropped++;
                return;
            }
            trace.Steps.Add(new StepEvent(ActivityRules.Flat(label, ActivityRules.DetailLength), at, sequential));
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

    internal void Complete(Trace trace, TaskOutcome outcome, string? category, long volume)
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
            trace.Volume = volume;
            if (outcome != TaskOutcome.Stopped)
            {
                Push(categories.TryGetValue(trace.Kind, out var q) ? q : categories[trace.Kind] = new Queue<double>(), engineMs);
                var perOperation = samples.TryGetValue(trace.Operation, out var s) ? s : samples[trace.Operation] = new Queue<OperationSample>();
                perOperation.Enqueue(new OperationSample(trace.Operation, now, engineMs, Math.Max(0, volume), outcome == TaskOutcome.Succeeded, true));
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
            var verdict = ActivityRules.Slowness(trace.Label, trace.QueueMs ?? -1, engineMs, volume);
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
        var phases = new List<TaskPhaseRow>
        {
            new("request", "Demande", 0, null, "non mesurée", false, null, null),
            new("engine", "Traitement dans le moteur", 0, elapsed, t.Open ? ActivityRules.Duration(elapsed) + " (en cours)" : ActivityRules.Duration(elapsed), !t.Open, t.Volume >= 0 ? ActivityRules.Volume(t.Volume) : null, null),
        };
        if (t.QueueMs is double queue)
        {
            phases.Add(new TaskPhaseRow("queue", "File d’attente du canal d’écriture et contrôles du plan", 0, queue, ActivityRules.Duration(queue), true, null, null));
        }
        for (var i = 0; i < t.Steps.Count; i++)
        {
            var step = t.Steps[i];
            double? until = i + 1 < t.Steps.Count ? t.Steps[i + 1].AtMs : t.Open ? null : t.EngineMs;
            double? duration = step.Sequential && until is double u ? Math.Max(0, u - step.AtMs) : null;
            phases.Add(new TaskPhaseRow("step", step.Label, step.AtMs, duration, duration is double d ? ActivityRules.Duration(d) : t.Open && i == t.Steps.Count - 1 ? "en cours" : "non mesurée", duration is not null, null, null));
        }
        if (!t.Open && info is not null)
        {
            phases.Add(new TaskPhaseRow("end", "Fin" + FrenchText.Colon + info.Label, t.EngineMs ?? elapsed, null, "—", false, t.Category, info.Code));
        }
        var measured = phases.Where(p => p.Measured && p.Phase is "queue" or "step").ToList();
        var dominant = measured.Count > 0 ? measured.MaxBy(p => p.DurationMs ?? -1) : !t.Open ? phases[1] : null;
        var text = string.Join(" → ", phases.Select(PhaseText));
        if (t.Dropped > 0)
        {
            text += " (" + FrenchText.Integer(t.Dropped) + " événement(s) non conservé(s))";
        }
        var listed = ActivityRules.IsListed(t.Foreground, t.Kind, t.Open, outcome);
        var canStop = t.Open && ActivityRules.IsStoppable(t.Kind) && t.Cancel is not null && !t.StopRequested;
        string? stopReason = canStop ? null
            : !t.Open ? "Tâche terminée" + FrenchText.Colon + "rien à arrêter."
            : t.StopRequested ? ActivityRules.CancelText(t.Label, TaskState.StopRequested, t.Kind)
            : ActivityRules.CancelText(t.Label, t.State, t.Kind);
        var detail = t.Open
            ? ActivityRules.OpenDetail(t.Kind, t.State, simulation)
            : (outcome == TaskOutcome.Succeeded ? "Terminée" : "Fin") + " après " + ActivityRules.Duration(elapsed) + (t.Volume >= 0 ? ", " + ActivityRules.Volume(t.Volume) : "") + ".";
        return new ActivityRow(
            t.Id, t.Reference, t.Operation, t.Screen, t.Label, t.Kind, ActivityRules.KindLabel(t.Kind, simulation), t.Foreground, listed,
            t.State, ActivityRules.StateLabel(t.State, outcome), tone, icon, outcome, info?.Label, t.StartedAt, t.EndedAt,
            Math.Round(elapsed, 1), ActivityRules.Duration(elapsed), dominant?.Label, dominant?.DurationMs is double dm ? Math.Round(dm, 1) : null,
            t.Volume >= 0 ? t.Volume : null, t.Volume >= 0 ? ActivityRules.Volume(t.Volume) : null, canStop, stopReason, detail,
            ActivityRules.Access(t.Kind, simulation), ActivityRules.Advice(outcome, t.Kind, t.Category, t.Reference), t.Category, text, t.Dropped, [.. phases], null);
    }

    private static string PhaseText(TaskPhaseRow phase) => phase.Phase switch
    {
        "request" => phase.Label,
        "end" => phase.Label,
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

    internal sealed record StepEvent(string Label, double AtMs, bool Sequential);

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
        public double? EngineMs { get; set; }
        public double? QueueMs { get; set; }
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

    public void Complete(TaskOutcome outcome, string? category, long volume)
    {
        if (Interlocked.Exchange(ref completed, 1) == 0)
        {
            activity.Complete(trace, outcome, category, volume);
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref completed, 1) == 0)
        {
            activity.Complete(trace, TaskOutcome.Failed, "operation.failed", -1);
        }
    }
}
