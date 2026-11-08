namespace Domenia.Core;

public enum PhysicalWorkPriority { Background, Selection, Explicit, Write }
public enum PhysicalWorkRoute { Directory, Cim, Wts, Storage, Network, Other }
public sealed record PhysicalWorkLoad(int Outstanding, int Background, IReadOnlyList<int> ByRoute);

/// <summary>Application-wide admission of physical work, including detached calls still completing or cleaning up.
/// Acquire at the leaf before launching; dispose only after native resources and credentials are actually released.
/// Awaiting admission holds no payload, credential, timer or native resource; it is cancelled by the caller.</summary>
public static class PhysicalWorkBudget
{
    public const int ReadLimit = 12, ExplicitLimit = 13, WriteLimit = 14;
    private static readonly Lock Gate = new();
    private static readonly AsyncLocal<Policy?> Current = new();
    private static readonly int[] Routes = new int[6];
    private static int outstanding, background;
    private static TaskCompletionSource changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public static bool InWriteContext => Current.Value?.Priority == PhysicalWorkPriority.Write;

    public static PhysicalWorkLoad Snapshot()
    { lock (Gate) { return new(outstanding, background, Array.AsReadOnly((int[])Routes.Clone())); } }

    /// <summary>Observes actual lease release. The host first fences new operations and cancels callers; a timeout
    /// of its own wait must never decrement this count or dispose a native worker's resources.</summary>
    public static async Task WaitForIdleAsync()
    {
        while (true)
        {
            Task wake;
            lock (Gate) { if (outstanding == 0) return; wake = changed.Task; }
            await wake.ConfigureAwait(false);
        }
    }

    /// <summary>Trusted server classification. ExecutionContext carries this value to child tasks; no page value is accepted.</summary>
    public static IDisposable Enter(PhysicalWorkPriority priority, bool aged = false, int maximumReads = ReadLimit)
    {
        if (!Enum.IsDefined(priority)) { throw new ArgumentOutOfRangeException(nameof(priority)); }
        var previous = Current.Value;
        // A nested read performed by the write circuit cannot downgrade that circuit's reserved physical admission.
        Current.Value = previous?.Priority == PhysicalWorkPriority.Write ? previous : new(priority, aged, Math.Clamp(maximumReads, 1, ReadLimit));
        return new Scope(previous);
    }

    public static IDisposable Acquire(PhysicalWorkRoute route, PhysicalWorkPriority? priority = null)
    {
        if (!Enum.IsDefined(route) || priority is { } given && !Enum.IsDefined(given)) { throw new ArgumentOutOfRangeException(nameof(route)); }
        var policy = Current.Value ?? new(PhysicalWorkPriority.Selection, false);
        var kind = policy.Priority == PhysicalWorkPriority.Write ? PhysicalWorkPriority.Write : priority ?? policy.Priority;
        var limit = kind switch { PhysicalWorkPriority.Write => Math.Min(WriteLimit, policy.MaximumReads + 2), PhysicalWorkPriority.Explicit => Math.Min(ExplicitLimit, policy.MaximumReads + 1), _ => policy.MaximumReads };
        lock (Gate)
        {
            if (outstanding >= limit)
            { throw Busy("Limite physique atteinte : des appels restent actifs ou en nettoyage. Aucun nouveau travail envoyé."); }
            var routeLimit = route switch
            { PhysicalWorkRoute.Directory => 4, PhysicalWorkRoute.Cim => 3, PhysicalWorkRoute.Wts => 2, PhysicalWorkRoute.Storage => 1, PhysicalWorkRoute.Network => 4, _ => 2 };
            var extra = kind == PhysicalWorkPriority.Background && policy.Aged && background == 0 ? 1 : 0;
            if (kind == PhysicalWorkPriority.Background && Routes[(int)route] >= routeLimit + extra)
            { throw Busy("Budget physique du fournisseur atteint pour les lectures de fond. Aucun nouveau travail envoyé."); }
            outstanding++; Routes[(int)route]++;
            if (kind == PhysicalWorkPriority.Background) { background++; }
            return new Lease(route, kind, OperationRequests.BeginJob(route switch
            {
                PhysicalWorkRoute.Directory => RequestJobKind.Directory, PhysicalWorkRoute.Cim => RequestJobKind.Cim,
                PhysicalWorkRoute.Wts => RequestJobKind.Wts, PhysicalWorkRoute.Storage => RequestJobKind.Storage,
                PhysicalWorkRoute.Network => RequestJobKind.Network, _ => RequestJobKind.Other,
            }));
        }
    }

    /// <summary>Wait for an occupied physical place before starting a network deadline. No native call or retry is
    /// scheduled here, and cancellation never releases an existing worker's place.</summary>
    public static async ValueTask<IDisposable> AcquireAsync(PhysicalWorkRoute route, CancellationToken token,
        PhysicalWorkPriority? priority = null)
    {
        while (true)
        {
            token.ThrowIfCancellationRequested();
            Task wake;
            lock (Gate)
            {
                try { return Acquire(route, priority); }
                catch (DomeniaOperationException ex) when (ex.Code == "operation.physicalBusy") { wake = changed.Task; }
            }
            await wake.WaitAsync(token).ConfigureAwait(false);
        }
    }

    private static DomeniaOperationException Busy(string message) => new("operation.physicalBusy", message);
    private sealed record Policy(PhysicalWorkPriority Priority, bool Aged, int MaximumReads = ReadLimit);
    private sealed class Scope(Policy? previous) : IDisposable
    {
        private bool disposed;
        public void Dispose() { if (disposed) { return; } disposed = true; Current.Value = previous; }
    }
    private sealed class Lease(PhysicalWorkRoute route, PhysicalWorkPriority priority, IDisposable? traceJob) : IDisposable
    {
        private int disposed;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) { return; }
            lock (Gate)
            {
                outstanding--; Routes[(int)route]--; if (priority == PhysicalWorkPriority.Background) { background--; }
                var previous = changed;
                changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
                previous.TrySetResult();
            }
            traceJob?.Dispose();
        }
    }
}
