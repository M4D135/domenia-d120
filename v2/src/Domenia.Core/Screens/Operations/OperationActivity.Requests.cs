using System.Diagnostics;
using System.Globalization;

namespace Domenia.Core;

public enum RequestJobKind { Handler, Directory, Cim, Wts, Storage, Network, Other }
public enum RequestStorageKind { Read, Write, Control, ReadBatch, WriteBatch }

public sealed partial class OperationActivity
{
    /// <summary>One request owns its summary independently of the bounded UI task ring.</summary>
    public ActivityRequest? BeginRequest(string operation)
    {
        try { return new(this, clock, log, DeclarationOf(operation) is not null ? operation : "operation"); }
#pragma warning disable CA1031 // A diagnostic clock or sink cannot refuse the operation being observed.
        catch (Exception error) { try { Fault(error); } catch (Exception) { } return null; }
#pragma warning restore CA1031
    }
}

/// <summary>Bounded counters only. A request closes after its dispatcher, physical jobs, intervals and publications all
/// finish. No argument, result, target, SQL text, error message or page-supplied identifier is retained.</summary>
public sealed class ActivityRequest : IDisposable
{
    public const int MaximumReferences = 64;
    private readonly OperationActivity activity;
    private readonly TimeProvider clock;
    private readonly ITechnicalJournal log;
    private readonly string operation;
    private readonly long started;
    private readonly Lock gate = new();
    private readonly List<string> references = [];
    private readonly Dictionary<OperationPhase, (long Count, double Ms)> phases = [];
    private readonly Dictionary<RequestJobKind, (long Count, double Ms)> jobTimes = [];
    private readonly Dictionary<RequestStorageKind, (long Count, long Rows, double Ms, long Failed)> storage = [];
    private bool closed, emitted;
    private long physicalJobs;
    private readonly List<Action> physicalCompleted = [];
    private long active, jobs, dropped, publications, rows, unknownVolumes, publicationFailures;
    private double publicationMs;
    private double? admissionMs;
    private TaskOutcome? outcome;
    public string Reference { get; } = Guid.NewGuid().ToString("N");

    internal ActivityRequest(OperationActivity activity, TimeProvider clock, ITechnicalJournal log, string operation)
    { this.activity = activity; this.clock = clock; this.log = log; this.operation = operation; started = clock.GetTimestamp(); }

    public IDisposable? BeginJob(RequestJobKind kind, string? reference = null)
    {
        if (!Enum.IsDefined(kind)) return null;
        return Observe<IDisposable?>(() =>
        {
            var at = clock.GetTimestamp();
            lock (gate)
            {
                if (emitted) return null;
                active++; jobs++;
                if (kind != RequestJobKind.Handler) physicalJobs++;
                var id = reference is { Length: >= 8 and <= 32 } && reference.All(char.IsAsciiHexDigit) ? reference : Guid.NewGuid().ToString("N");
                if (references.Count < MaximumReferences) references.Add(kind + "/" + id); else dropped++;
            }
            if (activity.ReadTrace) Observe(() => log.Trace($"Lecture [{Reference}] {operation} : début fournisseur {kind}, travaux admis={jobs}."));
            return new Lease(this, () =>
            {
                try
                {
                    var old = jobTimes.GetValueOrDefault(kind);
                    jobTimes[kind] = (old.Count + 1, old.Ms + Math.Max(0, clock.GetElapsedTime(at).TotalMilliseconds));
                }
                finally { if (kind != RequestJobKind.Handler) physicalJobs--; }
            });
        });
    }

    public IDisposable? MeasurePhase(OperationPhase phase)
    {
        if (!Enum.IsDefined(phase)) return null;
        var at = Observe<long?>(() => clock.GetTimestamp());
        if (at is null) return null;
        return Hold(() =>
        {
            var elapsed = clock.GetElapsedTime(at.Value).TotalMilliseconds;
            var old = phases.GetValueOrDefault(phase);
            phases[phase] = (old.Count + 1, old.Ms + Math.Max(0, elapsed));
        });
    }

    public RequestStorageMeasure? MeasureStorage(RequestStorageKind kind)
    {
        if (!Enum.IsDefined(kind)) return null;
        return Observe<RequestStorageMeasure?>(() =>
        {
            lock (gate) { if (emitted) return null; active++; }
            return new(this, kind);
        });
    }

    /// <summary>Measures acceptance by the host publication callback, not browser rendering or CPU work.</summary>
    public void Publish(Action send, long? publishedRows)
    {
        var at = Observe<long?>(() => clock.GetTimestamp());
        if (at is null) { send(); return; }
        var succeeded = false;
        using var pending = Hold(() =>
        {
            publications++; publicationMs += Math.Max(0, clock.GetElapsedTime(at.Value).TotalMilliseconds);
            if (!succeeded) publicationFailures++;
            else if (publishedRows is >= 0) rows += publishedRows.Value;
            else unknownVolumes++;
        });
        send(); succeeded = true;
    }

    public void Outcome(TaskOutcome value) => Observe(() => { lock (gate) { if (!emitted) outcome = ActivityRules.Worst(outcome, value); } });
    public void Admission(double milliseconds) => Observe(() =>
    { lock (gate) { if (!emitted && double.IsFinite(milliseconds) && milliseconds >= 0) admissionMs ??= milliseconds; } });

    public void SharedRequest(ActivityRequest? request)
    {
        if (request is null || ReferenceEquals(request, this)) return;
        Observe(() =>
        {
            lock (gate)
            {
                if (emitted) return;
                if (references.Count < MaximumReferences) references.Add("SharedRequest/" + request.Reference); else dropped++;
            }
        });
    }

    private IDisposable? Hold(Action finish) => Observe<IDisposable?>(() =>
    {
        lock (gate) { if (emitted) return null; active++; }
        return new Lease(this, finish);
    });

    internal void StorageFinished(RequestStorageKind kind, double ms, long readRows, bool success) => Release(() =>
    {
        var old = storage.GetValueOrDefault(kind);
        storage[kind] = (old.Count + 1, old.Rows + readRows, old.Ms + Math.Max(0, ms), old.Failed + (success ? 0 : 1));
    });

    /// <summary>Observe actual physical completion only; does not cancel work or release its leases.</summary>
    internal bool AfterPhysicalCompletion(Action finish)
    {
        lock (gate)
        {
            if (physicalJobs == 0) return false;
            physicalCompleted.Add(finish);
            return true;
        }
    }

    private void Release(Action? finish) => Observe(() =>
    {
        string? line;
        Action[] completions;
        Exception? measurementFailure = null;
        lock (gate)
        {
            try { finish?.Invoke(); }
#pragma warning disable CA1031 // Release observers below must run even when diagnostic measurement fails.
            catch (Exception error) { measurementFailure = error; }
#pragma warning restore CA1031
            finally { active--; }
            line = measurementFailure is null ? SummaryLocked() : null;
            completions = physicalJobs == 0 ? [.. physicalCompleted] : [];
            if (physicalJobs == 0) physicalCompleted.Clear();
        }
        // Never call the task ring while holding the request gate.
        foreach (var completion in completions) Observe(completion);
        if (measurementFailure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(measurementFailure).Throw();
        if (line is not null) log.Trace(line);
    });

    public void Dispose() => Observe(() =>
    {
        string? line;
        lock (gate) { if (closed) return; closed = true; line = SummaryLocked(); }
        if (line is not null) log.Trace(line);
    });

    private string? SummaryLocked()
    {
        if (emitted || !closed || active != 0) return null;
        emitted = true;
        static string N(double n) => n.ToString("0.###", CultureInfo.InvariantCulture);
        var phaseText = phases.Count == 0 ? "non mesurées" : string.Join(", ", phases.OrderBy(p => p.Key).Select(p => $"{p.Key}={N(p.Value.Ms)}ms/{p.Value.Count}"));
        var jobText = jobTimes.Count == 0 ? "non mesurés" : string.Join(", ", jobTimes.OrderBy(p => p.Key).Select(p => $"{p.Key}={N(p.Value.Ms)}ms/{p.Value.Count}"));
        var sqlite = string.Join("; ", Enum.GetValues<RequestStorageKind>().Select(kind => storage.TryGetValue(kind, out var s)
            ? $"{kind}={N(s.Ms)}ms/{s.Count} intervalles/" + (kind == RequestStorageKind.Read ? $"{s.Rows} lignes/" : "") + $"{s.Failed} incomplets" : kind + "=non mesuré"));
        return $"Requête [{Reference}] {operation} : jobs={jobs} [{string.Join(",", references)}], références omises={dropped}; "
            + $"jobs cumulés [{jobText}]; admission=" + (admissionMs is double admission ? N(admission) + "ms" : "non mesurée")
            + $"; phases cumulées [{phaseText}]; SQLite [{sqlite}]; publications={publications}, lignes transmises={rows}, volumes non mesurés={unknownVolumes}, échecs={publicationFailures}, envoi={N(publicationMs)}ms; "
            + $"issue={outcome?.ToString() ?? "non qualifiée"}; total={N(clock.GetElapsedTime(started).TotalMilliseconds)}ms jusqu’à dernière publication et fin réelle des travaux. "
            + "Intervalles susceptibles de se chevaucher, non additionnables ; rendu visible mesuré séparément.";
    }

    private T? Observe<T>(Func<T?> action)
    {
        try { return action(); }
#pragma warning disable CA1031 // Diagnostics must never alter a real operation, publication or physical lease.
        catch (Exception ex)
        {
            // Fault increments the diagnostic counter first; even a broken journal must not change the real result.
            try { activity.Fault(ex); } catch (Exception) { }
            return default;
        }
#pragma warning restore CA1031
    }
    private void Observe(Action action) => Observe<object?>(() => { action(); return null; });
    private sealed class Lease(ActivityRequest owner, Action? finish) : IDisposable
    {
        private int disposed;
        public void Dispose() { if (Interlocked.Exchange(ref disposed, 1) == 0) owner.Release(finish); }
    }
}

/// <summary>One actual SQLite interval. Pause excludes a consumer's time between yielded rows.</summary>
public sealed class RequestStorageMeasure : IDisposable
{
    private readonly ActivityRequest owner;
    private readonly RequestStorageKind kind;
    private long started = Stopwatch.GetTimestamp(), elapsed, rows;
    private bool running = true, success;
    private int disposed;
    internal RequestStorageMeasure(ActivityRequest owner, RequestStorageKind kind) { this.owner = owner; this.kind = kind; }
    public void Row() => rows++;
    public void Success() => success = true;
    public void Pause() { if (running) { elapsed += Stopwatch.GetTimestamp() - started; running = false; } }
    public void Resume() { if (!running) { started = Stopwatch.GetTimestamp(); running = true; } }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        Pause(); owner.StorageFinished(kind, elapsed * 1000d / Stopwatch.Frequency, rows, success);
    }
}

/// <summary>Request context flows through Task.Run and native completions, without a process-wide identifier map.</summary>
public static class OperationRequests
{
    private static readonly AsyncLocal<ActivityRequest?> Current = new();
    public static ActivityRequest? CurrentRequest => Current.Value;
    public static IDisposable Enter(ActivityRequest? request)
    { var previous = Current.Value; Current.Value = request; return new Scope(previous); }
    public static IDisposable? BeginJob(RequestJobKind kind, string? reference = null) => Current.Value?.BeginJob(kind, reference);
    public static RequestStorageMeasure? MeasureStorage(RequestStorageKind kind) => Current.Value?.MeasureStorage(kind);
    private sealed class Scope(ActivityRequest? previous) : IDisposable
    {
        private bool disposed;
        public void Dispose() { if (disposed) return; disposed = true; Current.Value = previous; }
    }
}
