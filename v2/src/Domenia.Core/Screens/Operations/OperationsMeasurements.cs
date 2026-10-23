namespace Domenia.Core;

/// <summary>Observer propagated through awaited native reads and Task.Run, scoped to the originating session.</summary>
public static class OperationsMeasurements
{
    private static readonly AsyncLocal<OperationActivity?> Current = new();

    public static IDisposable Enter(OperationActivity activity)
    {
        ArgumentNullException.ThrowIfNull(activity);
        var previous = Current.Value;
        Current.Value = activity;
        return new Scope(previous);
    }

    public static void RecordSqliteBusy() => Current.Value?.RecordSqliteBusy();

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
