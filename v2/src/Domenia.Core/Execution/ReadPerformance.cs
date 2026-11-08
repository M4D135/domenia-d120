namespace Domenia.Core;

/// <summary>Actual read transports, never an inferred capability or an automatically launched benchmark.</summary>
public enum ReadPerformanceMethod { Ping, Ldap, WmiDcom, WinRm, Registry, ScheduledTask, PsExec, WindowsSessions, SecurityLog, WindowsRpc, WmiProcess, WinRmScript }
public enum ReadPerformanceOutcome { Success, Partial, Failure, Refused, Cancelled }

/// <summary>One completed attempt. Durations use a monotonic clock; queueing is separate from execution.
/// Operation is a fixed feature name, never a target, query, command, account or other collected value.</summary>
public sealed record ReadPerformanceSample(ReadPerformanceMethod Method, string Operation, long QueueMs, long ExecutionMs,
    ReadPerformanceOutcome Outcome, bool CacheHit = false, int Retry = 0)
{
    /// <summary>Optional measured child launch and authenticated pipe handshake. Included in ExecutionMs, never added to it.</summary>
    public long? StartupMs { get; init; }
}

/// <summary>An operation-scoped sink. No global history, retained hosts or additional network work.</summary>
public static class ReadPerformance
{
    private static readonly AsyncLocal<Scope?> Current = new();
    private static readonly AsyncLocal<int> AttemptNumber = new();
    public static IDisposable Attempt(int retry)
    {
        if (retry is < 0 or > 4) { throw new ArgumentOutOfRangeException(nameof(retry)); }
        var previous = AttemptNumber.Value; AttemptNumber.Value = retry; return new AttemptScope(previous);
    }
    private sealed class AttemptScope(int previous) : IDisposable
    {
        public void Dispose() => AttemptNumber.Value = previous;
    }

    public static IDisposable Observe(Action<ReadPerformanceSample> observer)
    {
        ArgumentNullException.ThrowIfNull(observer);
        var scope = new Scope(Current.Value, observer);
        Current.Value = scope;
        return scope;
    }

    public static bool Observed => Current.Value is { Active: true };

    public static void Publish(ReadPerformanceSample sample)
    {
        ArgumentNullException.ThrowIfNull(sample);
        OperationsMeasurements.RecordReadPerformance(sample);
        if (Current.Value is { Active: true } scope) { scope.Deliver(sample with { Retry = Math.Max(sample.Retry, AttemptNumber.Value) }); }
    }

    public static long Milliseconds(TimeSpan elapsed) => (long)Math.Clamp(elapsed.TotalMilliseconds, 0, long.MaxValue);

    private sealed class Scope(Scope? previous, Action<ReadPerformanceSample> observer) : IDisposable
    {
        private int active = 1;
        private int failed;
        internal bool Active => Volatile.Read(ref active) == 1;
        internal void Deliver(ReadPerformanceSample sample)
        {
            if (Volatile.Read(ref failed) != 0) { return; }
            try { observer(sample); }
            catch (Exception)
            {
                // Telemetry must not replace a provider's result/refusal or interrupt native cleanup.
                // Stop this sink after its first failure; no exception text or collected value is logged.
                if (Interlocked.Exchange(ref failed, 1) == 0)
                {
                    try { System.Diagnostics.Trace.TraceWarning("Observateur de mesures de lecture désactivé après une erreur locale."); }
                    catch (Exception) { /* A custom trace listener must not affect a provider either. */ }
                }
            }
        }
        public void Dispose()
        {
            if (Interlocked.Exchange(ref active, 0) == 0) { return; }
            if (ReferenceEquals(Current.Value, this)) { Current.Value = previous; }
        }
    }
}
