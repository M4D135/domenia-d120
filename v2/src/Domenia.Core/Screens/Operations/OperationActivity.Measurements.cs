namespace Domenia.Core;

public sealed partial class OperationActivity
{
    private long inventoriesReused;
    private long sharedInventories;
    private long sharedCimQueriesAvoided;
    public long SharedInventories => Interlocked.Read(ref sharedInventories);
    public long SharedCimQueriesAvoided => Interlocked.Read(ref sharedCimQueriesAvoided);
    public void RecordSharedInventory(int queriesIssued)
    {
        if (queriesIssued < 0) { throw new ArgumentOutOfRangeException(nameof(queriesIssued)); }
        Interlocked.Increment(ref sharedInventories);
        Interlocked.Add(ref sharedCimQueriesAvoided, queriesIssued);
    }


    /// <summary>One complete inventory skipped because an admissible fresh inventory was retained; not a count of WQL statements.</summary>
    public void RecordInventoryReused() => Interlocked.Increment(ref inventoriesReused);

    public long InventoriesReused => Interlocked.Read(ref inventoriesReused);

    /// <summary>One measured publication interval for a real, finished request; duplicates and stale ids do not pollute statistics.</summary>
    public bool RecordPublication(string requestId, double milliseconds)
    {
        if (string.IsNullOrWhiteSpace(requestId) || requestId.Length > 64 || !double.IsFinite(milliseconds) || milliseconds is < 0 or > 60000) { return false; }
        lock (gate)
        {
            var trace = traces.FirstOrDefault(t => !t.Open && t.RequestId == requestId);
            if (trace is null || trace.PublicationMs is not null) { return false; }
            trace.PublicationMs = milliseconds;
            // This interval includes frame scheduling. The CPU render category has its own instrumented measurements.
            var verdict = ActivityRules.Slowness(trace.Label, -1, -1, -1, interfaceMs: milliseconds);
            if (verdict.Slow)
            {
                slow.Enqueue(new SlowEvent(clock.GetUtcNow(), trace.Operation, trace.Reference, "Publication", milliseconds,
                    trace.EngineMs is double engine ? engine + milliseconds : milliseconds,
                    "Réponse reçue puis prochain rafraîchissement visible après " + ActivityRules.Duration(milliseconds) + " ; attente de rendu incluse."));
                while (slow.Count > ActivityRules.MaxSlowEvents) { slow.Dequeue(); }
            }
            return true;
        }
    }
}
