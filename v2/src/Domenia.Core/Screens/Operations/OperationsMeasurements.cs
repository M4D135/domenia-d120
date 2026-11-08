namespace Domenia.Core;

/// <summary>Observer propagated through awaited native reads and Task.Run, scoped to the originating session.</summary>
public static class OperationsMeasurements
{
    private static readonly AsyncLocal<OperationActivity?> Current = new();
    public static OperationActivity? Activity => Current.Value;

    public static IDisposable Enter(OperationActivity activity)
    {
        ArgumentNullException.ThrowIfNull(activity);
        var previous = Current.Value;
        Current.Value = activity;
        return new Scope(previous);
    }

    public static int SqliteBusyTimeoutMs => Current.Value?.SqliteBusyTimeoutMs ?? 2500;
    public static void RecordSqliteBusy(OperationActivity? owner = null) => (owner ?? Current.Value)?.RecordSqliteBusy();
    public static void RecordReadPerformance(ReadPerformanceSample sample)
    {
        try { Current.Value?.RecordReadPerformance(sample); }
#pragma warning disable CA1031 // Optional diagnostics never replace a provider result or interrupt physical cleanup.
        catch (Exception error) { try { Current.Value?.Fault(error); } catch (Exception) { } }
#pragma warning restore CA1031
    }

    private sealed class Scope(OperationActivity? previous) : IDisposable
    {
        private bool disposed;
        public void Dispose()
        {
            if (disposed) { return; }
            disposed = true;
            Current.Value = previous;
        }
    }
}
